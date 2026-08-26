import Foundation

/// The page-side half of highlights, run through `WebPage.callJavaScript` as function bodies. One
/// library string is prepended to each entry point, so nothing is installed in the page and nothing
/// of the page's is touched except the highlight registry (`CSS.highlights`) — or, where that API is
/// missing, wrapper `<mark>` elements.
///
/// Text positions are offsets into the page's *text index*: every visible text node under `<body>`
/// concatenated, in document order. Quote, position and range selectors are all computed from and
/// resolved against that one index, and re-anchoring walks a ladder: exact quote (disambiguated by
/// context and by the recorded position), the XPath range, then a fuzzy search around the recorded
/// position that gives up below a similarity threshold rather than mark the wrong sentence.
nonisolated enum HighlightScript {
    static let library = #"""
    const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','CANVAS','IFRAME','OBJECT','EMBED','VIDEO','AUDIO','TEXTAREA','INPUT','SELECT','BUTTON']);
    const BLOCK = 'p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th, pre, dd, dt, figcaption, summary, div, section, article';
    const CONTEXT = 32;
    const NAME = 'six-highlight';

    function visible(el) {
        for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
            if (SKIP.has(e.tagName)) return false;
            if (e.hidden || e.getAttribute('aria-hidden') === 'true') return false;
            const cs = getComputedStyle(e);
            if (cs.display === 'none' || cs.visibility === 'hidden') return false;
        }
        return true;
    }

    // The text index: [{node, start}] over visible text nodes, and the concatenated text.
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

    function positionOf(idx, node, offset) {
        // A boundary inside an element: move to the text node it points at.
        if (node.nodeType !== 3) {
            const children = node.childNodes;
            if (offset < children.length) {
                let target = children[offset];
                while (target && target.nodeType !== 3 && target.firstChild) target = target.firstChild;
                if (target && target.nodeType === 3) { node = target; offset = 0; }
                else {
                    // Fall back to the next indexed text node after `node`.
                    const after = idx.nodes.find(e => node.compareDocumentPosition(e.node) & Node.DOCUMENT_POSITION_FOLLOWING);
                    return after ? after.start : idx.text.length;
                }
            } else {
                let last = null;
                for (const e of idx.nodes) { if (node.contains(e.node)) last = e; }
                return last ? last.start + last.node.nodeValue.length : idx.text.length;
            }
        }
        const entry = idx.nodes.find(e => e.node === node);
        if (!entry) {
            const after = idx.nodes.find(e => node.compareDocumentPosition(e.node) & Node.DOCUMENT_POSITION_FOLLOWING);
            return after ? after.start : idx.text.length;
        }
        return entry.start + Math.min(offset, node.nodeValue.length);
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

    function xpath(node) {
        const parts = [];
        for (let n = node; n && n !== document; n = n.parentNode) {
            if (n.nodeType === 9) break;
            let i = 1;
            for (let s = n.previousSibling; s; s = s.previousSibling) {
                if (s.nodeType === n.nodeType && (n.nodeType !== 1 || s.nodeName === n.nodeName)) i++;
            }
            parts.unshift(n.nodeType === 3 ? `text()[${i}]` : `${n.nodeName.toLowerCase()}[${i}]`);
        }
        return '/' + parts.join('/');
    }

    function resolveXPath(path) {
        try { return document.evaluate(path, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue; }
        catch { return null; }
    }

    function blockOf(node) {
        for (let e = node.nodeType === 1 ? node : node.parentElement; e; e = e.parentElement) {
            const d = getComputedStyle(e).display;
            if (d === 'block' || d === 'list-item' || d === 'table-cell' || d === 'flex' || d === 'grid' || e === document.body) return e;
        }
        return document.body;
    }

    function selectorsFor(idx, range) {
        const start = positionOf(idx, range.startContainer, range.startOffset);
        const end = positionOf(idx, range.endContainer, range.endOffset);
        if (end <= start) return null;
        const exact = idx.text.slice(start, end);
        if (!exact.trim()) return null;
        // Context stays inside the passage's own block: the index runs text nodes together, and a
        // prefix that crosses into the previous paragraph glues two words into one no page contains.
        const first = blockOf(range.startContainer), last = blockOf(range.endContainer);
        const blockStart = positionOf(idx, first, 0);
        const blockEnd = positionOf(idx, last, last.childNodes.length);
        return {
            exact, start, end,
            prefix: idx.text.slice(Math.max(blockStart, start - CONTEXT), start),
            suffix: idx.text.slice(end, Math.min(blockEnd, end + CONTEXT)),
            startPath: xpath(range.startContainer), startOffset: range.startOffset,
            endPath: xpath(range.endContainer), endOffset: range.endOffset,
        };
    }

    function trimmedRange(idx, range) {
        // Drop leading/trailing whitespace from the selection so the quote starts on a letter.
        const s = positionOf(idx, range.startContainer, range.startOffset);
        const e = positionOf(idx, range.endContainer, range.endOffset);
        let a = s, b = e;
        while (a < b && /\s/.test(idx.text[a])) a++;
        while (b > a && /\s/.test(idx.text[b - 1])) b--;
        return a < b ? rangeFromPositions(idx, a, b) : null;
    }

    // Paragraph-ish blocks with their own text, numbered in document order.
    function blocks() {
        const out = [];
        const all = Array.from(document.querySelectorAll(BLOCK)).filter(visible);
        const set = new Set(all);
        for (const el of all) {
            const isContainer = /^(DIV|SECTION|ARTICLE)$/.test(el.tagName);
            if (isContainer) {
                // Only when the container holds text of its own and no block child does the job.
                const own = Array.from(el.childNodes).filter(n => n.nodeType === 3).map(n => n.nodeValue).join('').trim();
                if (own.length < 40) continue;
            } else if (Array.from(el.querySelectorAll(BLOCK)).some(c => set.has(c) && !/^(DIV|SECTION|ARTICLE)$/.test(c.tagName) && c.innerText.trim().length > 20)) {
                continue; // a list item or cell that is itself made of blocks
            }
            const text = (el.innerText || '').replace(/\s+/g, ' ').trim();
            if (text.length < 20) continue;
            out.push({ n: out.length + 1, text: text.slice(0, 600), path: xpath(el) });
        }
        return out;
    }

    function unsupported() {
        if (document.contentType === 'application/pdf') return "This is a PDF shown by WebKit's viewer; passages in it can't be highlighted";
        const body = document.body;
        if (!body) return 'The page has no body';
        const textLength = (body.innerText || '').trim().length;
        if (textLength < 200 && body.querySelector('canvas')) return 'The text on this page is drawn on a canvas and cannot be highlighted';
        return '';
    }

    // Re-anchoring ladder. Returns a Range or null.
    function anchor(idx, sel) {
        const text = idx.text;
        // 1. Exact quote, disambiguated by context and by distance from the recorded position.
        const hits = [];
        for (let i = text.indexOf(sel.exact); i !== -1 && hits.length < 50; i = text.indexOf(sel.exact, i + 1)) hits.push(i);
        if (hits.length) {
            const scored = hits.map(i => {
                let score = 0;
                if (sel.prefix && text.slice(Math.max(0, i - sel.prefix.length), i) === sel.prefix) score += 2;
                if (sel.suffix && text.slice(i + sel.exact.length, i + sel.exact.length + sel.suffix.length) === sel.suffix) score += 2;
                score -= Math.abs(i - (sel.start || 0)) / Math.max(1, text.length);
                return { i, score };
            }).sort((a, b) => b.score - a.score);
            return rangeFromPositions(idx, scored[0].i, scored[0].i + sel.exact.length);
        }
        // 2. The XPath range, if it still reads the same.
        if (sel.startPath && sel.endPath) {
            const a = resolveXPath(sel.startPath), b = resolveXPath(sel.endPath);
            if (a && b) {
                try {
                    const range = document.createRange();
                    range.setStart(a, Math.min(sel.startOffset, a.nodeValue ? a.nodeValue.length : a.childNodes.length));
                    range.setEnd(b, Math.min(sel.endOffset, b.nodeValue ? b.nodeValue.length : b.childNodes.length));
                    if (similarity(range.toString(), sel.exact) >= 0.8) return range;
                } catch {}
            }
        }
        // 3. Fuzzy: the best approximate match near the recorded position (or anywhere on a short page).
        return fuzzy(idx, sel);
    }

    function similarity(a, b) {
        if (a === b) return 1;
        if (!a.length || !b.length) return 0;
        const n = a.length, m = b.length;
        if (Math.abs(n - m) > Math.max(n, m) * 0.5) return 0;
        let prev = new Array(m + 1), cur = new Array(m + 1);
        for (let j = 0; j <= m; j++) prev[j] = j;
        for (let i = 1; i <= n; i++) {
            cur[0] = i;
            for (let j = 1; j <= m; j++) {
                cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
            }
            [prev, cur] = [cur, prev];
        }
        return 1 - prev[m] / Math.max(n, m);
    }

    function fuzzy(idx, sel) {
        const text = idx.text, exact = sel.exact;
        if (exact.length < 12) return null;
        const words = exact.split(/\s+/).filter(w => w.length > 3);
        if (!words.length) return null;
        // Candidate starts: occurrences of the quote's first distinctive words.
        const seeds = words.slice(0, 3);
        const candidates = new Set();
        for (const w of seeds) {
            for (let i = text.indexOf(w); i !== -1 && candidates.size < 400; i = text.indexOf(w, i + 1)) {
                candidates.add(Math.max(0, i - exact.indexOf(w)));
            }
        }
        const window = text.length > 20000 ? 4000 : text.length;
        let best = null;
        for (const start of candidates) {
            if (Math.abs(start - (sel.start || 0)) > window && text.length > 20000) continue;
            const slack = Math.round(exact.length * 0.2);
            for (const len of [exact.length, exact.length - slack, exact.length + slack]) {
                if (len <= 0) continue;
                const s = similarity(text.slice(start, start + len), exact);
                if (!best || s > best.s) best = { s, start, len };
            }
        }
        if (!best || best.s < 0.75) return null;
        return rangeFromPositions(idx, best.start, best.start + best.len);
    }

    // Painting.
    function registry() {
        if (!('highlights' in CSS)) return null;
        if (!window.__sixHighlight) {
            window.__sixHighlight = new Highlight();
            CSS.highlights.set(NAME, window.__sixHighlight);
            window.__sixRanges = new Map();
        }
        return window.__sixHighlight;
    }

    function ensureStyle() {
        if (document.getElementById('six-highlight-style')) return;
        const style = document.createElement('style');
        style.id = 'six-highlight-style';
        style.textContent = `::highlight(${NAME}) { background-color: rgba(255, 214, 10, 0.45); color: inherit; }
            mark.${NAME} { background-color: rgba(255, 214, 10, 0.45); color: inherit; }`;
        (document.head || document.documentElement).appendChild(style);
    }

    function paint(id, range) {
        ensureStyle();
        const reg = registry();
        if (reg) {
            const old = window.__sixRanges.get(id);
            if (old) reg.delete(old);
            reg.add(range);
            window.__sixRanges.set(id, range);
            return;
        }
        // Fallback: wrap each text node of the range in a <mark>. Changes the DOM; only where there is no choice.
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
            mark.className = NAME;
            mark.dataset.sixId = id;
            try { r.surroundContents(mark); } catch {}
        }
    }

    function unpaint(id) {
        const reg = registry();
        if (reg) {
            const r = window.__sixRanges && window.__sixRanges.get(id);
            if (r) { reg.delete(r); window.__sixRanges.delete(id); }
            return;
        }
        for (const mark of document.querySelectorAll(`mark.${NAME}[data-six-id="${id}"]`)) {
            const parent = mark.parentNode;
            while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
            parent.removeChild(mark);
        }
    }

    function applyAll(list) {
        const idx = index();
        const missing = [];
        for (const sel of list) {
            const range = anchor(idx, sel);
            if (range) paint(sel.id, range); else missing.push(sel);
        }
        return missing;
    }

    function scrollToRange(range) {
        const rect = range.getBoundingClientRect();
        window.scrollBy({ top: rect.top - window.innerHeight / 3, behavior: 'smooth' });
    }
    """#

    /// The page's blocks as `[{n, text, path}]`, for the model to choose among by number.
    static let blocks = library + "\nreturn { unsupported: unsupported(), blocks: blocks() };"

    /// Selectors for blocks by number (`numbers: [Int]`, the numbering `blocks` returned).
    static let blockSelectors = library + #"""

    const idx = index();
    const all = blocks();
    const out = [];
    for (const n of numbers) {
        const block = all.find(b => b.n === n);
        if (!block) continue;
        const el = resolveXPath(block.path);
        if (!el) continue;
        const range = document.createRange();
        range.selectNodeContents(el);
        const trimmed = trimmedRange(idx, range);
        const sel = trimmed ? selectorsFor(idx, trimmed) : null;
        if (sel) { sel.n = n; out.push(sel); }
    }
    return out;
    """#

    /// Selectors for the current selection, or null.
    static let selectionSelectors = library + #"""

    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
    const idx = index();
    const range = trimmedRange(idx, selection.getRangeAt(0));
    return range ? selectorsFor(idx, range) : null;
    """#

    /// Anchors and paints `list`. Returns `{anchored: [id], missing: [id], unsupported: String}` for the
    /// first pass; what is missing keeps being retried for a few seconds while the page is still
    /// filling in (a `MutationObserver`, then it stops). `status` reads the outcome afterwards.
    static let apply = library + #"""

    const why = unsupported();
    if (why) return { anchored: [], missing: list.map(s => s.id), unsupported: why };
    let missing = applyAll(list);
    const anchored = list.filter(s => !missing.includes(s)).map(s => s.id);
    if (missing.length && window.MutationObserver) {
        // A lazily hydrated article usually lands within a second or two; watch for that, then stop.
        let timer = null;
        const deadline = Date.now() + 5000;
        const observer = new MutationObserver(() => {
            if (timer) return;
            timer = setTimeout(() => {
                timer = null;
                missing = applyAll(missing);
                if (!missing.length || Date.now() > deadline) observer.disconnect();
            }, 300);
        });
        observer.observe(document.body || document.documentElement, { childList: true, subtree: true, characterData: true });
        setTimeout(() => observer.disconnect(), 5200);
    }
    return { anchored, missing: missing.map(s => s.id), unsupported: '' };
    """#

    /// Which of `ids` are painted now.
    static let status = library + #"""

    const painted = new Set();
    if (window.__sixRanges) for (const id of window.__sixRanges.keys()) painted.add(id);
    for (const mark of document.querySelectorAll(`mark.${NAME}`)) painted.add(mark.dataset.sixId);
    return { anchored: ids.filter(id => painted.has(id)), missing: ids.filter(id => !painted.has(id)) };
    """#

    /// Scrolls to a painted highlight by id.
    static let scrollTo = library + #"""

    const r = window.__sixRanges && window.__sixRanges.get(id);
    if (r) { scrollToRange(r); return true; }
    const mark = document.querySelector(`mark.${NAME}[data-six-id="${id}"]`);
    if (mark) { mark.scrollIntoView({ block: 'center', behavior: 'smooth' }); return true; }
    return false;
    """#

    static let remove = library + "\nunpaint(id); return true;"
}
