import Foundation

/// The page half of translation: JavaScript in string literals, and nothing else.
///
/// It is written as a `library` of helpers plus small entry points, the same shape as
/// `HighlightScript`, and for the same reason — every entry point needs the same walker. It runs
/// through `PageScriptRunner`, which on Apple is `WebPage.six(_:arguments:)` in six's own
/// `WKContentWorld` and on Linux will be WebKitGTK's async function call.
///
/// **This file is the contract, not an implementation.** `android.md` counts `HighlightScript` as
/// "JavaScript in string literals" when it argues that a Swift core buys little on Android; the
/// point cuts the other way here. The Linux front runs *this exact text*, and Android carries it
/// across as text. That is what makes translation one feature on four fronts rather than four
/// features. So: no imports beyond `Foundation`, and nothing in here that assumes WebKit.
///
/// Every body is a plain function body — `callJavaScript` runs a function, not an async one, so
/// **no `await`**. Anything that has to wait (the observer watching a feed hydrate) runs
/// fire-and-forget in the page and Swift asks for the outcome later, through `drain`.
nonisolated enum TranslationScript {

    /// Shared helpers. No top-level statements: each entry point appends its own.
    static let library = #"""
    // ---- State, in six's world. The page cannot see or erase any of it. --------------------------
    //
    // Identity lives in a Map from integer id to entry, because a text node cannot carry an
    // attribute. An entry keeps its own original string(s), and **every write is in place** —
    // `node.data = translation` — so node identity survives translation and Show Original is a write
    // of the saved strings back. Nothing is cloned, nothing is reparented; a page script holding a
    // reference to a paragraph still holds it, and re-translating after a restore needs no re-walk.

    function state() {
        if (!window.__sixTranslate) {
            window.__sixTranslate = {
                seq: 0,
                entries: new Map(),   // id -> entry
                seen: new WeakSet(),  // text nodes already registered
                attrSeen: new WeakMap(), // element -> attributes already registered
                pending: [],          // segments found by the observer, waiting for Swift
                applied: false,
                observer: null,
                scroll: null,
                timer: null,
                chars: 0,
                lang: null,
                dir: null,
                savedLang: false
            };
        }
        return window.__sixTranslate;
    }

    // ---- What may be translated -----------------------------------------------------------------
    //
    // A third predicate, deliberately. `HighlightScript.visible()` skips BUTTON, INPUT and SELECT,
    // and a translator must translate a button's label and an <option>'s text. `ReadablePage`'s
    // walker drops NAV, ASIDE and FOOTER, and a translator must keep them — they are the site's
    // navigation, which is most of what a reader needs translated. Do not "deduplicate" these three.

    const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','MATH','CANVAS','IFRAME',
                          'OBJECT','EMBED','VIDEO','AUDIO','CODE','PRE','KBD','SAMP','VAR',
                          'TEXTAREA','TIME','RUBY','RT']);
    const INLINE = new Set(['inline','contents','ruby','ruby-base','ruby-text',
                            'ruby-base-container','ruby-text-container']);
    const ENDS = /[.!?…。！？:;»”"')\]]\s*$/;
    const NOTHING = /^[\s\d\p{P}\p{S}]*$/u;
    const ADDRESS = /^(https?:\/\/|www\.|[^\s@]+@[^\s@]+\.)/i;

    // `getComputedStyle` is the expensive call in here and it is asked for the same elements over
    // and over as the walker climbs. One map per pass pays for itself many times on a long page.
    let styles = new Map();
    function css(el) {
        let s = styles.get(el);
        if (!s) { s = getComputedStyle(el); styles.set(el, s); }
        return s;
    }

    function translatable(el) {
        for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
            if (SKIP.has(e.tagName)) return false;
            if (e.hidden || e.getAttribute('aria-hidden') === 'true') return false;
            if (e.getAttribute('translate') === 'no') return false;
            if (e.classList && e.classList.contains('notranslate')) return false;
            // Both, and not only the property: `isContentEditable` is the live answer, but the
            // attribute is what a page in the middle of hydrating has already set.
            if (e.isContentEditable) return false;
            const editable = e.getAttribute('contenteditable');
            if (editable === '' || editable === 'true' || editable === 'plaintext-only') return false;
            const s = css(e);
            if (s.display === 'none' || s.visibility === 'hidden') return false;
        }
        return true;
    }

    function worthTranslating(text) {
        const t = text.trim();
        return t.length > 1 && !NOTHING.test(t) && !ADDRESS.test(t);
    }

    /// The block that owns a text node: the nearest ancestor that is not laid out inline. Asked of
    /// the computed style rather than of a tag list, so a `<span style="display:block">` is a unit
    /// and a `<div style="display:inline">` is not.
    function unitOf(node) {
        let e = node.parentElement;
        while (e && e.parentElement && INLINE.has(css(e).display)) e = e.parentElement;
        return e;
    }

    // ---- Cutting a unit into segments ------------------------------------------------------------
    //
    // The rule, and the whole quality of the result: a sentence must not be cut at an inline tag.
    // `<p>Hello <b>world</b>, how are you?</p>` is three text nodes, and translating them apart
    // translates "Hello", "world" and ", how are you?" as three unrelated things.

    function midSentence(before, after) {
        const b = before.replace(/\s+$/, '');
        const a = after.replace(/^\s+/, '');
        if (!b || !a) return false;
        if (!ENDS.test(b)) return true;
        const c = a[0];
        return c.toLowerCase() === c && c.toUpperCase() !== c;
    }

    function textNodesOf(unit, all) {
        return all.filter(n => unitOf(n) === unit);
    }

    /// One unit's worth of entries, following the rule:
    ///
    ///   one text node          -> one segment, and sentences are whole for free
    ///   the unit has a link    -> one segment per node: a dead link is worse than a clumsy clause
    ///   no boundary mid-sentence -> one segment per node: markup kept *and* sentences whole
    ///   otherwise              -> one flat segment for the unit
    ///
    /// The flat case writes the whole translation into the first text node and empties the rest, so
    /// `<em>` inside that one paragraph stops showing. That is the trade, it fires only for
    /// paragraphs that both break a sentence across markup and hold no link, and it is exactly
    /// reversible: every node keeps its own original string.
    function segmentsFor(unit, texts) {
        if (texts.length === 1) return [{ kind: 'text', node: texts[0] }];
        if (unit.querySelector && unit.querySelector('a[href]')) {
            return texts.map(n => ({ kind: 'text', node: n }));
        }
        let broken = false;
        for (let i = 1; i < texts.length; i++) {
            if (midSentence(texts[i - 1].data, texts[i].data)) { broken = true; break; }
        }
        if (!broken) return texts.map(n => ({ kind: 'text', node: n }));
        return [{ kind: 'flat', el: unit, nodes: texts.slice() }];
    }

    function textOf(entry) {
        if (entry.kind === 'text') return entry.node.data;
        if (entry.kind === 'flat') return entry.nodes.map(n => n.data).join('');
        return entry.el.getAttribute(entry.attr) || '';
    }

    function remember(entry) {
        if (entry.kind === 'text') entry.original = entry.node.data;
        else if (entry.kind === 'flat') entry.originals = entry.nodes.map(n => n.data);
        else entry.original = entry.el.getAttribute(entry.attr);
    }

    /// An engine returns its translation trimmed, and the page needs the spacing back.
    ///
    /// `<p>see <a>the docs</a> for more</p>` is three text nodes, and the first one really is
    /// `"see "` with the space that holds it off the link. Write back a trimmed `"смотри"` and the
    /// words run together — `contentWeb documents, Computer filesAnd their catalogs`, which is what
    /// ru.wikipedia.org looked like before this existed. So the original's own leading and trailing
    /// whitespace is put back around whatever comes out.
    function padded(text, original) {
        if (original === undefined || original === null) return text;
        const lead = (original.match(/^\s+/) || [''])[0];
        const tail = (original.match(/\s+$/) || [''])[0];
        return lead + text.trim() + tail;
    }

    function write(entry, text) {
        if (entry.kind === 'text') {
            entry.node.data = padded(text, entry.original);
        } else if (entry.kind === 'flat') {
            // The unit's whole translation lands in the first node, so it is held off its
            // neighbours by the first node's lead and the last node's tail.
            const last = entry.originals ? entry.originals[entry.originals.length - 1] : '';
            const lead = (((entry.originals || [''])[0]).match(/^\s+/) || [''])[0];
            const tail = ((last || '').match(/\s+$/) || [''])[0];
            entry.nodes[0].data = lead + text.trim() + tail;
            for (let i = 1; i < entry.nodes.length; i++) entry.nodes[i].data = '';
        } else {
            entry.el.setAttribute(entry.attr, text);
        }
    }

    /// An entry is only worth putting back if it was ever written over, and most of them are not:
    /// `collect` registers the whole page at once while translation arrives a batch at a time, so a
    /// run stopped early — a language still downloading, another language picked, a page navigated
    /// away from — leaves hundreds of entries that were never touched.
    ///
    /// Their `original` is `undefined`, and `node.data = undefined` does not throw. It writes the
    /// **string** `"undefined"`. Restoring an interrupted run used to replace most of the page with
    /// that word, which is as bad as this code can get: not a failure to translate, but a page
    /// destroyed by the thing meant to undo the translation.
    ///
    /// `null` is a different answer from `undefined` here and has to stay one — an attribute that
    /// was remembered as absent is removed, an attribute never remembered is left alone.
    function putBack(entry) {
        if (entry.kind === 'text') {
            if (entry.original === undefined) return;
            entry.node.data = entry.original;
        } else if (entry.kind === 'flat') {
            if (entry.originals === undefined) return;
            for (let i = 0; i < entry.nodes.length; i++) entry.nodes[i].data = entry.originals[i];
        } else if (entry.original === undefined) {
            return;
        } else if (entry.original === null) {
            entry.el.removeAttribute(entry.attr);
        } else {
            entry.el.setAttribute(entry.attr, entry.original);
        }
    }

    // ---- The walk --------------------------------------------------------------------------------

    const ATTRS = ['alt', 'title', 'placeholder', 'aria-label'];

    /// Registers everything under `root` that has not been registered before, and returns the new
    /// segments as `{id, text, y}` — `y` being where it is on the screen, which is what puts the
    /// first batch where the reader is looking.
    function collectUnder(root) {
        const S = state();
        const out = [];
        if (!root) return out;

        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode(node) {
                if (S.seen.has(node)) return NodeFilter.FILTER_REJECT;
                if (!node.data || !node.data.trim()) return NodeFilter.FILTER_REJECT;
                if (!node.parentElement || !translatable(node.parentElement)) return NodeFilter.FILTER_REJECT;
                return NodeFilter.FILTER_ACCEPT;
            }
        });

        const texts = [];
        for (let n = walker.nextNode(); n; n = walker.nextNode()) texts.push(n);

        // Group by owning block, in document order.
        const units = [];
        const byUnit = new Map();
        for (const n of texts) {
            const unit = unitOf(n);
            if (!unit) continue;
            if (!byUnit.has(unit)) { byUnit.set(unit, []); units.push(unit); }
            byUnit.get(unit).push(n);
        }

        for (const unit of units) {
            const mine = byUnit.get(unit);
            let top = 0;
            try { top = unit.getBoundingClientRect().top; } catch (e) { top = 0; }
            for (const entry of segmentsFor(unit, mine)) {
                const text = textOf(entry);
                if (!worthTranslating(text)) continue;
                const nodes = entry.kind === 'flat' ? entry.nodes : [entry.node];
                for (const n of nodes) S.seen.add(n);
                const id = ++S.seq;
                S.entries.set(id, entry);
                S.chars += text.length;
                out.push({ id: id, text: text, y: top });
            }
        }

        // Tooltips and labels, after all the visible words: they are the first thing to drop when a
        // page runs into its budget.
        const holder = root.nodeType === 1 ? root : document.body;
        if (holder && holder.querySelectorAll) {
            for (const attr of ATTRS) {
                for (const el of holder.querySelectorAll('[' + attr + ']')) {
                    const value = el.getAttribute(attr);
                    if (!value || !worthTranslating(value)) continue;
                    if (!translatable(el)) continue;
                    // Kept in the run's own state rather than on the element, so dropping the
                    // state forgets them. A property left on the element would survive a reset and
                    // make the second language skip every tooltip on the page.
                    let marks = S.attrSeen.get(el);
                    if (!marks) { marks = new Set(); S.attrSeen.set(el, marks); }
                    if (marks.has(attr)) continue;
                    marks.add(attr);
                    const entry = { kind: 'attr', el: el, attr: attr };
                    const id = ++S.seq;
                    S.entries.set(id, entry);
                    S.chars += value.length;
                    out.push({ id: id, text: value, y: 1e8 });
                }
            }
        }
        return out;
    }

    /// Viewport first, then down the page, then what is above the fold. One sort, and the largest
    /// win there is in how fast the page *feels* translated.
    function inReadingOrder(segments) {
        return segments.sort((a, b) => {
            const ka = a.y >= -50 ? a.y : 1e9 - a.y;
            const kb = b.y >= -50 ? b.y : 1e9 - b.y;
            return ka - kb;
        });
    }

    function strip(segments) {
        return segments.map(s => ({ id: s.id, text: s.text }));
    }

    /// Why this page cannot be translated at all, or ''. The same two cases `HighlightScript`
    /// reports, for the same reason: there is no text to work on, and saying so is better than a
    /// spinner that never stops.
    function unsupported() {
        if (document.contentType === 'application/pdf') return 'pdf';
        if (!document.body) return 'empty';
        const length = (document.body.innerText || '').trim().length;
        if (length < 200 && document.body.querySelector('canvas')) return 'canvas';
        if (length === 0) return 'empty';
        return '';
    }
    """#

    // MARK: - Entry points

    /// Cheap: is there anything to translate here, and what language does the page claim to be?
    /// `sample` is for the caller's own detector when the page claims nothing.
    static let plan = library + #"""

    styles = new Map();
    const why = unsupported();
    const html = document.documentElement;
    return {
        unsupported: why,
        language: (html.getAttribute('lang') || '').trim(),
        dir: (html.getAttribute('dir') || '').trim(),
        sample: why ? '' : (document.body.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 1200),
        translated: !!(window.__sixTranslate && window.__sixTranslate.applied)
    };
    """#

    /// Registers the page and hands back what needs translating, in reading order.
    /// `budget` caps the characters this page may spend.
    static let collect = library + #"""

    styles = new Map();
    const why = unsupported();
    if (why) return { unsupported: why, segments: [], characters: 0 };
    const S = state();
    const found = inReadingOrder(collectUnder(document.body));
    return { unsupported: '', segments: strip(found), characters: S.chars, over: S.chars > budget };
    """#

    /// Writes one batch. Originals are saved *before* the first write to an entry, so a run that is
    /// torn down half way still restores exactly.
    static let apply = library + #"""

    const S = state();
    let written = 0;
    for (const item of list) {
        const entry = S.entries.get(item.id);
        if (!entry) continue;                       // the page re-rendered under us; not an error
        if (entry.original === undefined && entry.originals === undefined) remember(entry);
        try { write(entry, item.text); written++; } catch (e) { /* detached node */ }
    }
    if (!S.savedLang) {
        S.lang = document.documentElement.getAttribute('lang');
        S.dir = document.documentElement.getAttribute('dir');
        S.savedLang = true;
    }
    if (lang) document.documentElement.setAttribute('lang', lang);
    // Only on <html>, and only when it actually changes. An RTL page sets `dir` per element for its
    // own code blocks and quotations; rewriting those breaks the page to fix nothing.
    if (dir && dir !== (S.dir || 'ltr')) document.documentElement.setAttribute('dir', dir);
    S.applied = true;
    return { written: written };
    """#

    /// Watches for what a feed loads next. Sets a flag and collects; it cannot translate, because a
    /// script body has no `await`. Swift comes back for the result through `drain`.
    static let observe = library + #"""

    const S = state();
    if (S.observer) return { watching: true };

    const scan = () => {
        S.timer = null;
        styles = new Map();
        const found = collectUnder(document.body);
        if (found.length) S.pending.push.apply(S.pending, inReadingOrder(found));
    };
    const schedule = () => {
        if (S.timer) return;
        S.timer = setTimeout(scan, 400);
    };

    S.observer = new MutationObserver(schedule);
    S.observer.observe(document.body, { childList: true, subtree: true, characterData: false });
    // Some virtualised lists recycle nodes without a childList record we would catch.
    S.scroll = () => schedule();
    window.addEventListener('scroll', S.scroll, { passive: true });
    return { watching: true };
    """#

    /// What the observer has found since last time, up to `limit`, and whether more is waiting.
    static let drain = library + #"""

    const S = state();
    const take = S.pending.splice(0, limit);
    return { segments: strip(take), more: S.pending.length, characters: S.chars };
    """#

    /// Back to the page as it was written. Exact, because every entry kept its own string.
    static let restore = library + #"""

    const S = state();
    for (const entry of S.entries.values()) {
        try { putBack(entry); } catch (e) { /* detached */ }
    }
    if (S.savedLang) {
        if (S.lang === null) document.documentElement.removeAttribute('lang');
        else document.documentElement.setAttribute('lang', S.lang);
        if (S.dir === null) document.documentElement.removeAttribute('dir');
        else document.documentElement.setAttribute('dir', S.dir);
    }
    S.applied = false;
    return { restored: S.entries.size };
    """#

    /// Back to the original *and* forgotten, so the page can be translated again — into another
    /// language, or after the reader turned it off and changed their mind.
    ///
    /// This is not `restore`. Show Original is a toggle and has to keep every entry, because the
    /// whole point of it is that coming back costs no translation. Changing language is the
    /// opposite: everything registered belongs to the language being left, and `seen` holds every
    /// text node on the page, so a second run over the same state collects nothing at all and
    /// reports itself finished having done nothing. That was the bug.
    static let reset = library + #"""

    const S = window.__sixTranslate;
    if (!S) return { reset: false };
    for (const entry of S.entries.values()) {
        try { putBack(entry); } catch (e) { /* detached */ }
    }
    if (S.observer) { S.observer.disconnect(); }
    if (S.scroll) { window.removeEventListener('scroll', S.scroll); }
    if (S.timer) { clearTimeout(S.timer); }
    if (S.savedLang) {
        if (S.lang === null) document.documentElement.removeAttribute('lang');
        else document.documentElement.setAttribute('lang', S.lang);
        if (S.dir === null) document.documentElement.removeAttribute('dir');
        else document.documentElement.setAttribute('dir', S.dir);
    }
    window.__sixTranslate = null;
    return { reset: true };
    """#

    /// Puts the translations back on without asking an engine again: the entries and their originals
    /// are still here, so Show Original is a toggle rather than a stop.
    static let reapply = library + #"""

    const S = state();
    let written = 0;
    for (const item of list) {
        const entry = S.entries.get(item.id);
        if (!entry) continue;
        try { write(entry, item.text); written++; } catch (e) {}
    }
    if (lang) document.documentElement.setAttribute('lang', lang);
    S.applied = true;
    return { written: written };
    """#

    /// Stops watching. Called on Show Original and on navigation.
    static let stop = library + #"""

    const S = state();
    if (S.observer) { S.observer.disconnect(); S.observer = null; }
    if (S.scroll) { window.removeEventListener('scroll', S.scroll); S.scroll = null; }
    if (S.timer) { clearTimeout(S.timer); S.timer = null; }
    S.pending = [];
    return { stopped: true };
    """#

    /// The page's current selection, and whether replacing it would mean anything.
    static let selection = library + #"""

    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return { text: '', editable: false };
    const node = sel.anchorNode;
    const el = node && node.nodeType === 1 ? node : (node ? node.parentElement : null);
    return {
        text: sel.toString().trim(),
        editable: !!(el && el.isContentEditable)
    };
    """#
}
