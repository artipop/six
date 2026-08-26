import Foundation
import WebKit

/// The page as something a person (or a model) can read: the main content as Markdown, plus the
/// metadata a bookmark keeps. Extracted in the page itself, Readability-style: `<article>` /
/// `<main>` when the page says where the content is, otherwise the element that holds the most
/// paragraph text; navigation, asides, footers, forms and hidden nodes are dropped; headings,
/// lists, quotes, code, links, tables and large images survive the conversion.
nonisolated struct ReadablePage: Decodable, Sendable {
    var title: String
    var byline: String
    var siteName: String
    var excerpt: String
    var image: String
    var language: String
    var markdown: String
    var text: String

    var imageURL: URL? { image.isEmpty ? nil : URL(string: image) }

    /// The page must be loaded; the caller waits for that.
    @MainActor
    static func extract(from page: WebPage) async throws -> ReadablePage {
        let value = try await page.callJavaScript(script)
        guard let object = value as? [String: Any], JSONSerialization.isValidJSONObject(object) else {
            throw ExtractionError.noContent
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        var readable = try JSONDecoder().decode(ReadablePage.self, from: data)
        readable.markdown = readable.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        readable.text = readable.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readable.text.isEmpty else { throw ExtractionError.noContent }
        return readable
    }

    enum ExtractionError: LocalizedError {
        case noContent
        var errorDescription: String? { "The page has no readable text" }
    }

    /// Runs as a function body in the page. Read-only: nothing in the DOM is touched.
    static let script = #"""
    const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','IFRAME','SVG','CANVAS','NAV','ASIDE','FOOTER','FORM','BUTTON','INPUT','SELECT','TEXTAREA','OBJECT','EMBED','VIDEO','AUDIO','DIALOG']);
    const BLOCK = new Set(['P','DIV','SECTION','ARTICLE','MAIN','HEADER','LI','UL','OL','BLOCKQUOTE','PRE','TABLE','TR','H1','H2','H3','H4','H5','H6','HR','FIGURE','FIGCAPTION','DL','DT','DD','DETAILS','SUMMARY']);
    const NOISE = /(^|[\s_-])(comment|share|social|sidebar|widget|promo|advert|banner|cookie|popup|modal|subscribe|newsletter|related|breadcrumb|menu|nav|editsection)([\s_-]|$)/i;
    const meta = (sel) => { const el = document.querySelector(sel); return el ? (el.getAttribute('content') || '').trim() : ''; };
    const abs = (href) => { try { return new URL(href, document.baseURI).href; } catch { return ''; } };
    const clean = (s) => s.replace(/\s+/g, ' ');

    function hidden(el) {
        if (!(el instanceof Element)) return false;
        if (el.hidden || el.getAttribute('aria-hidden') === 'true') return true;
        const style = getComputedStyle(el);
        return style.display === 'none' || style.visibility === 'hidden';
    }
    function noisy(el) {
        const label = ((el.id || '') + ' ' + (el.className && typeof el.className === 'string' ? el.className : '')).trim();
        return label && NOISE.test(label) && el.tagName !== 'ARTICLE' && el.tagName !== 'MAIN' && el.tagName !== 'BODY';
    }
    function textLength(el) { return clean(el.innerText || '').length; }

    // 1. Where is the content?
    function pickRoot() {
        for (const sel of ['article', 'main', '[role="main"]', '[itemprop="articleBody"]', '.post-content', '.entry-content', '#content']) {
            const el = document.querySelector(sel);
            if (el && !hidden(el) && textLength(el) >= 400) return el;
        }
        const scores = new Map();
        for (const p of document.querySelectorAll('p, pre, li, blockquote')) {
            if (hidden(p)) continue;
            const len = clean(p.innerText || '').length;
            if (len < 40) continue;
            let node = p.parentElement, weight = 1;
            for (let depth = 0; node && depth < 3; depth++, node = node.parentElement, weight /= 2) {
                if (SKIP.has(node.tagName) || noisy(node)) break;
                scores.set(node, (scores.get(node) || 0) + len * weight);
            }
        }
        let best = document.body, bestScore = 0;
        for (const [el, score] of scores) if (score > bestScore) { best = el; bestScore = score; }
        return best;
    }

    // 2. DOM → Markdown.
    let out = [];
    function push(s) { out.push(s); }
    function inline(node, listDepth) {
        if (node.nodeType === Node.TEXT_NODE) return clean(node.nodeValue);
        if (node.nodeType !== Node.ELEMENT_NODE) return '';
        const tag = node.tagName;
        if (SKIP.has(tag) || hidden(node) || noisy(node)) return '';
        if (tag === 'BR') return '\n';
        if (tag === 'IMG') {
            const src = abs(node.currentSrc || node.src || node.getAttribute('data-src') || '');
            const w = node.naturalWidth || node.width || 0, h = node.naturalHeight || node.height || 0;
            if (!src || (w && w < 120) || (h && h < 120)) return '';
            return `![${clean(node.alt || '')}](${src})`;
        }
        if (tag === 'A') {
            const inner = children(node, listDepth).trim();
            const href = abs(node.getAttribute('href') || '');
            if (!inner) return '';
            return href && /^https?:/.test(href) && !inner.startsWith('!') ? `[${inner}](${href})` : inner;
        }
        if (tag === 'CODE' && node.parentElement && node.parentElement.tagName !== 'PRE') {
            const t = clean(node.textContent); return t ? '`' + t + '`' : '';
        }
        if (tag === 'STRONG' || tag === 'B') { const t = children(node, listDepth).trim(); return t ? `**${t}**` : ''; }
        if (tag === 'EM' || tag === 'I') { const t = children(node, listDepth).trim(); return t ? `_${t}_` : ''; }
        if (BLOCK.has(tag)) { block(node, listDepth); return ''; }
        return children(node, listDepth);
    }
    function children(node, listDepth) { let s = ''; for (const c of node.childNodes) s += inline(c, listDepth); return s; }
    function paragraph(text) { const t = text.replace(/[ \t]+\n/g, '\n').replace(/\n{2,}/g, '\n').trim(); if (t) push(t + '\n\n'); }
    function block(el, listDepth) {
        const tag = el.tagName;
        if (SKIP.has(tag) || hidden(el) || noisy(el)) return;
        switch (tag) {
            case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': {
                const t = clean(children(el, listDepth)).trim();
                if (t) push('#'.repeat(+tag[1]) + ' ' + t + '\n\n');
                return;
            }
            case 'P': case 'FIGCAPTION': case 'DT': case 'DD': case 'SUMMARY': paragraph(children(el, listDepth)); return;
            case 'HR': push('---\n\n'); return;
            case 'PRE': { const t = el.innerText.replace(/\s+$/, ''); if (t) push('```\n' + t + '\n```\n\n'); return; }
            case 'BLOCKQUOTE': {
                const start = out.length; container(el, listDepth);
                const inner = out.splice(start).join('').trim();
                if (inner) push(inner.split('\n').map(l => '> ' + l).join('\n') + '\n\n');
                return;
            }
            case 'UL': case 'OL': {
                let i = 0;
                for (const li of el.children) {
                    if (li.tagName !== 'LI' || hidden(li)) continue;
                    i++;
                    const start = out.length; const text = children(li, listDepth + 1);
                    const nested = out.splice(start).join('');
                    const marker = tag === 'OL' ? `${i}. ` : '- ';
                    const line = clean(text).trim();
                    if (line || nested) push('  '.repeat(listDepth) + marker + line + '\n' + nested.replace(/\n\n$/, '\n'));
                }
                push('\n');
                return;
            }
            case 'TABLE': {
                const rows = [];
                for (const tr of el.querySelectorAll('tr')) {
                    if (hidden(tr)) continue;
                    const cells = [...tr.children].map(td => clean(td.innerText || '').trim().replace(/\|/g, '\\|'));
                    if (cells.some(c => c)) rows.push('| ' + cells.join(' | ') + ' |');
                }
                if (rows.length) { rows.splice(1, 0, '|' + ' --- |'.repeat(rows[0].split('|').length - 2)); push(rows.join('\n') + '\n\n'); }
                return;
            }
            default: container(el, listDepth);
        }
    }
    // A container: its own inline runs become paragraphs, its blocks recurse.
    function container(el, listDepth) {
        let run = '';
        for (const c of el.childNodes) {
            if (c.nodeType === Node.ELEMENT_NODE && BLOCK.has(c.tagName)) { paragraph(run); run = ''; block(c, listDepth); }
            else run += inline(c, listDepth);
        }
        paragraph(run);
    }

    const root = pickRoot();
    block(root, 0);
    let markdown = out.join('').replace(/\n{3,}/g, '\n\n').trim();
    const text = markdown
        .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
        .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
        .replace(/^```.*$/gm, '')
        .replace(/^#{1,6} /gm, '')
        .replace(/^> /gm, '')
        .replace(/^\s*(?:[-*]|\d+\.) /gm, '')
        .replace(/\*\*|__|`/g, '')
        .replace(/[ \t]+/g, ' ').trim();
    const title = meta('meta[property="og:title"]') || (document.querySelector('h1') && textLength(document.querySelector('h1')) < 200 ? clean(document.querySelector('h1').innerText).trim() : '') || document.title;
    let excerpt = meta('meta[name="description"]') || meta('meta[property="og:description"]');
    if (!excerpt) { const p = text.split('\n').find(l => l.length > 60); excerpt = p ? p.slice(0, 300) : text.slice(0, 300); }
    return {
        title: clean(title).trim().slice(0, 300),
        byline: meta('meta[name="author"]') || meta('meta[property="article:author"]'),
        siteName: meta('meta[property="og:site_name"]') || location.hostname.replace(/^www\./, ''),
        excerpt: clean(excerpt).trim().slice(0, 500),
        image: abs(meta('meta[property="og:image"]') || meta('meta[name="twitter:image"]') || ''),
        language: (document.documentElement.lang || '').trim().slice(0, 12),
        markdown: markdown.slice(0, 400000),
        text: text.slice(0, 400000),
    };
    """#
}
