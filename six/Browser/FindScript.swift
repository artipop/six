import Foundation

/// The page half of finding text — the same shape as `HighlightScript.swift`, and mostly its own
/// text index: a plain function body run through `WebPage.six` (`callJavaScript` in six's own
/// content world, see `PageScripts.swift`), so nothing declared here can be read or overwritten by
/// the page, and anything that must outlive one call is kept on `window` instead of a local.
///
/// Matches are painted with the CSS Custom Highlight API, the same one `HighlightScript` uses, so
/// a hundred matches on a long article cost nothing in the DOM — no `<mark>` wraps a text node, and
/// no script the page runs of its own ever sees one. Where the API is missing (an older engine)
/// the same `<mark>`-wrapping fallback stands in.
///
/// No imports beyond `Foundation` and nothing that assumes WebKit, for the same reason
/// `TranslationScript` gives: this text is what a Linux or Android front would run too, once one
/// of them exposes a way to call it (`PageScriptRunner`).
nonisolated enum FindScript {
    static let library = #"""
    // Elements a search should never look inside: not text a reader would call "on the page"
    // (SCRIPT/STYLE), and not a value already spoken for by a form control's own semantics.
    // Deliberately narrower than `HighlightScript`'s set: a search should still find a quote sitting
    // inside a <pre> or <code> block, which is exactly the text `HighlightScript` skips for being
    // "not prose".
    const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','CANVAS','IFRAME','OBJECT','EMBED','VIDEO','AUDIO','TEXTAREA','INPUT','SELECT','BUTTON']);
    const ALL = 'six-find-all', CURRENT = 'six-find-current';

    function visible(el) {
        for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
            if (SKIP.has(e.tagName)) return false;
            if (e.hidden || e.getAttribute('aria-hidden') === 'true') return false;
            const cs = getComputedStyle(e);
            if (cs.display === 'none' || cs.visibility === 'hidden') return false;
        }
        return true;
    }

    // The text index: [{node, start}] over visible text nodes, and the concatenated text — the same
    // shape `HighlightScript.index()` builds, kept separate because the two run in different calls
    // and neither may assume the other's copy of it is still standing.
    function index() {
        const nodes = [];
        let text = '';
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
            acceptNode(node) {
                if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
                return visible(node.parentElement) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
            }
        });
        for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            nodes.push({ node: n, start: text.length });
            text += n.nodeValue;
        }
        return { nodes, text };
    }

    function boundary(idx, position) {
        let lo = 0, hi = idx.nodes.length - 1, found = null;
        while (lo <= hi) {
            const mid = (lo + hi) >> 1;
            const e = idx.nodes[mid];
            if (position < e.start) hi = mid - 1;
            else if (position > e.start + e.node.nodeValue.length) lo = mid + 1;
            else { found = e; break; }
        }
        if (!found) found = idx.nodes[Math.max(0, Math.min(idx.nodes.length - 1, lo))];
        if (!found) return null;
        return { node: found.node, offset: Math.max(0, Math.min(found.node.nodeValue.length, position - found.start)) };
    }

    function rangeFromPositions(idx, start, end) {
        const a = boundary(idx, start), b = boundary(idx, end);
        if (!a || !b) return null;
        const range = document.createRange();
        range.setStart(a.node, a.offset);
        range.setEnd(b.node, b.offset);
        return range;
    }

    // State that must survive from one call to the next — a search, then however many steps —
    // keyed on nothing but the fact that there is only ever one find running on a page at a time.
    function state() {
        if (!window.__sixFind) window.__sixFind = { ranges: [], current: -1 };
        return window.__sixFind;
    }

    function ensureStyle() {
        const css = `::highlight(${ALL}) { background-color: rgba(255, 214, 10, 0.45); color: inherit; }
            ::highlight(${CURRENT}) { background-color: rgba(255, 138, 0, 0.85); color: inherit; }
            mark.${ALL} { background-color: rgba(255, 214, 10, 0.45); color: inherit; }
            mark.${CURRENT} { background-color: rgba(255, 138, 0, 0.85); color: inherit; }`;
        // A constructed stylesheet, the same as `HighlightScript.ensureStyle`: nothing lands in the
        // DOM, and a page's CSP has no say over it. A <style> element only where that API is missing.
        if (document.adoptedStyleSheets !== undefined && typeof CSSStyleSheet === 'function') {
            if (window.__sixFindSheet) return;
            try {
                const sheet = new CSSStyleSheet();
                sheet.replaceSync(css);
                document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
                window.__sixFindSheet = sheet;
                return;
            } catch {}
        }
        if (document.getElementById('six-find-style')) return;
        const style = document.createElement('style');
        style.id = 'six-find-style';
        style.textContent = css;
        (document.head || document.documentElement).appendChild(style);
    }

    function hasRegistry() { return 'highlights' in CSS; }

    // Repainted from scratch on every call rather than diffed against the last one: a find bar
    // redraws on every keystroke anyway, and a hundred `Range`s is nothing next to walking the page
    // again to find them.
    function paint(ranges, current) {
        clearMarks();
        if (!ranges.length) return;
        ensureStyle();
        if (hasRegistry()) {
            const all = new Highlight(), one = new Highlight();
            ranges.forEach((r, i) => (i === current ? one : all).add(r));
            CSS.highlights.set(ALL, all);
            CSS.highlights.set(CURRENT, one);
            return;
        }
        ranges.forEach((range, i) => {
            const nodes = [];
            const walker = document.createTreeWalker(range.commonAncestorContainer, NodeFilter.SHOW_TEXT);
            for (let n = walker.nextNode(); n; n = walker.nextNode()) if (range.intersectsNode(n)) nodes.push(n);
            for (const n of nodes) {
                const s = n === range.startContainer ? range.startOffset : 0;
                const e = n === range.endContainer ? range.endOffset : n.nodeValue.length;
                if (e <= s) continue;
                const r = document.createRange();
                r.setStart(n, s); r.setEnd(n, e);
                const mark = document.createElement('mark');
                mark.className = i === current ? CURRENT : ALL;
                try { r.surroundContents(mark); } catch {}
            }
        });
    }

    function clearMarks() {
        if (hasRegistry()) { CSS.highlights.delete(ALL); CSS.highlights.delete(CURRENT); return; }
        for (const mark of document.querySelectorAll(`mark.${ALL}, mark.${CURRENT}`)) {
            const parent = mark.parentNode;
            if (!parent) continue;
            while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
            parent.removeChild(mark);
        }
    }

    function scrollToRange(range) {
        const rect = range.getBoundingClientRect();
        window.scrollBy({ top: rect.top - window.innerHeight / 3, behavior: 'smooth' });
    }
    """#

    /// Finds every occurrence of `query` (plain text, case-insensitive), paints them and lands on
    /// the first. `{ count, current }` — both zero for an empty query or nothing found.
    static let search = library + #"""

    const s = state();
    if (!query) { s.ranges = []; s.current = -1; clearMarks(); return { count: 0, current: 0 }; }
    const idx = index();
    const haystack = idx.text.toLowerCase();
    const needle = query.toLowerCase();
    const ranges = [];
    for (let i = haystack.indexOf(needle); i !== -1 && ranges.length < 2000; i = haystack.indexOf(needle, i + needle.length)) {
        const range = rangeFromPositions(idx, i, i + needle.length);
        if (range) ranges.push(range);
    }
    s.ranges = ranges;
    s.current = ranges.length ? 0 : -1;
    paint(ranges, s.current);
    if (s.current >= 0) scrollToRange(ranges[s.current]);
    return { count: ranges.length, current: s.current + 1 };
    """#

    /// Moves `delta` matches, wrapping either way, repaints and scrolls. `{ count, current }`.
    static let step = library + #"""

    const s = state();
    if (!s.ranges.length) return { count: 0, current: 0 };
    s.current = (s.current + delta + s.ranges.length) % s.ranges.length;
    paint(s.ranges, s.current);
    scrollToRange(s.ranges[s.current]);
    return { count: s.ranges.length, current: s.current + 1 };
    """#

    /// The bar closed, or the page is going away: drop the highlights and the state behind them.
    static let clear = library + #"""

    clearMarks();
    window.__sixFind = null;
    return true;
    """#
}
