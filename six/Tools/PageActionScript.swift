import Foundation

/// The page-side half of the acting tools (`page_snapshot`, `click`, `fill`, `select_option`,
/// `press_key`, `scroll_page`), run through `WebPage.six` — six's own content world, so a page cannot
/// redefine `querySelectorAll` or a getter to show the agent a button a person does not see, and
/// cannot reach the registry below to aim a click somewhere else.
///
/// The registry is the point of the design, and it is borrowed from browser-use's jev-ultrafast: a
/// `WeakMap` gives every element the snapshot saw a code-owned number, and a `Map` keeps the live
/// node behind that number. A model answers with a number, never with a selector, coordinates or
/// script, so nothing it says is ever executed — it can only pick one of the elements it was shown.
/// The same node keeps its number across snapshots, which lets a model say `e12` twice and mean the
/// same field; a node the page replaced gets a new one, and an old number then fails loudly
/// ("take a new snapshot") instead of landing on whatever took its place.
///
/// Why the DOM and not WebKit's accessibility tree (`ax-overlay`, docs/accessibility.md): that read
/// needs Privacy & Security ▸ Accessibility, exists on the Mac only, and deadlocks a process that asks
/// itself. What it sees and this does not was measured there and is narrow — closed shadow roots and
/// `ElementInternals` semantics. Open shadow roots are walked here.
///
/// Events are synthetic (`isTrusted: false`), which almost every form accepts; typing goes through
/// `execCommand('insertText')`, which WebKit runs as real editing — `beforeinput` and `input` arrive
/// the way they do from a keyboard, so React-style controlled inputs see the value. Canvas apps
/// (Sheets, Figma) are what this cannot drive; that is stage 3 of docs/agent-actions.md.
nonisolated enum PageActionScript {
    static let library = #"""
    const S = globalThis.__sixAct || (globalThis.__sixAct = { ids: new WeakMap(), nodes: new Map(), next: 1, mutations: 0 });
    if (!S.observer && document.documentElement) {
        // DOM changes are seen from every world; this is what "the page has settled" is measured by.
        S.observer = new MutationObserver(list => { S.mutations += list.length; });
        S.observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
    }
    const identity = e => {
        if (!S.ids.has(e)) S.ids.set(e, S.next++);
        const id = S.ids.get(e);
        S.nodes.set(id, e);
        return id;
    };
    const parentOf = e => e.parentElement || (e.getRootNode && e.getRootNode().host) || null;
    const hiddenByAncestor = e => {
        for (let a = e; a; a = parentOf(a)) {
            if (a.getAttribute && (a.getAttribute('aria-hidden') === 'true' || a.hasAttribute('inert'))) return true;
        }
        return false;
    };
    const visible = e => {
        if (!e || !e.isConnected) return false;
        if (e.checkVisibility && !e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
        const r = e.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) return false;
        return !hiddenByAncestor(e);
    };
    const byId = (e, id) => {
        const root = e.getRootNode();
        return (root.getElementById ? root.getElementById(id) : null) || document.getElementById(id);
    };
    const squash = s => (s || '').replace(/\s+/g, ' ').trim();
    // A label's text without the controls inside it: `<label>Cabin <select>…</select></label>` names
    // the dropdown "Cabin", not "Cabin Economy Business First".
    const ownText = l => {
        let out = '';
        const walk = n => {
            for (const c of n.childNodes) {
                if (c.nodeType === 3) out += c.textContent;
                else if (c.nodeType === 1 && !['SELECT', 'TEXTAREA', 'INPUT', 'BUTTON', 'SCRIPT', 'STYLE'].includes(c.tagName)
                    && c.getAttribute('aria-hidden') !== 'true') walk(c);
                out += ' ';
            }
        };
        walk(l);
        return squash(out);
    };
    const nameOf = (e, seen) => {
        seen = seen || new Set();
        if (!e || seen.has(e)) return '';
        seen.add(e);
        const referenced = (e.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean)
            .map(id => nameOf(byId(e, id), seen)).filter(Boolean).join(' ');
        if (referenced) return squash(referenced);
        const aria = e.getAttribute('aria-label');
        if (aria && aria.trim()) return squash(aria);
        const labels = [...(e.labels || [])].map(l => ownText(l)).filter(Boolean).join(' ');
        if (labels) return labels;
        if (e.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes(e.type)) return squash(e.value) || e.type;
        const alt = e.getAttribute('alt');
        if (alt) return squash(alt);
        if (!['INPUT', 'TEXTAREA', 'SELECT'].includes(e.tagName)) {
            const text = squash(e.innerText);
            if (text) return text.slice(0, 160);
            const img = e.querySelector('img[alt],svg[aria-label],[aria-label]');
            if (img) return squash(img.getAttribute('alt') || img.getAttribute('aria-label'));
        }
        return squash(e.getAttribute('title') || e.getAttribute('placeholder') || e.getAttribute('aria-placeholder') || '');
    };
    const ROLES = ['button', 'link', 'checkbox', 'radio', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio',
        'option', 'gridcell', 'combobox', 'textbox', 'searchbox', 'spinbutton', 'slider', 'listbox', 'treeitem'];
    const SELECTOR = 'a[href],button,input,textarea,select,summary,[contenteditable=""],[contenteditable="true"],[onclick],' +
        '[tabindex]:not([tabindex="-1"]),' + ROLES.map(r => '[role="' + r + '"]').join(',');
    const roleOf = e => {
        const explicit = (e.getAttribute('role') || '').split(/\s+/)[0];
        if (ROLES.includes(explicit)) return explicit;
        const tag = e.tagName;
        if (tag === 'BUTTON' || tag === 'SUMMARY') return 'button';
        if (tag === 'A') return e.hasAttribute('href') ? 'link' : null;
        if (tag === 'SELECT') return e.multiple ? 'listbox' : 'select';
        if (tag === 'TEXTAREA' || e.isContentEditable) return 'textbox';
        if (tag === 'INPUT') {
            const t = e.type;
            if (t === 'hidden' || t === 'file') return null;
            if (t === 'checkbox' || t === 'radio') return t;
            if (['button', 'submit', 'reset', 'image'].includes(t)) return 'button';
            if (t === 'search') return 'searchbox';
            if (t === 'number') return 'spinbutton';
            if (t === 'range') return 'slider';
            if (e.hasAttribute('list')) return 'combobox';
            return 'textbox';
        }
        if (e.hasAttribute('onclick') || e.hasAttribute('tabindex')) return 'button';
        return null;
    };
    const editable = e => {
        if (e.isContentEditable) return true;
        if (e.tagName === 'TEXTAREA') return !e.readOnly;
        if (e.tagName !== 'INPUT' || e.readOnly) return false;
        return !['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'range', 'color', 'file', 'hidden'].includes(e.type);
    };
    const disabled = e => {
        if (e.matches(':disabled')) return true;
        for (let a = e; a; a = parentOf(a)) if (a.getAttribute && a.getAttribute('aria-disabled') === 'true') return true;
        return false;
    };
    // Every root to search: the document and every open shadow root under it, however deep.
    const roots = () => {
        const out = [document];
        for (let i = 0; i < out.length; i++) {
            for (const e of out[i].querySelectorAll('*')) if (e.shadowRoot) out.push(e.shadowRoot);
        }
        return out;
    };
    const describe = e => {
        if (!e || !e.tagName) return 'something';
        const n = nameOf(e);
        return '<' + e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + '>' + (n ? ' "' + n.slice(0, 60) + '"' : '');
    };
    const center = e => {
        const r = e.getBoundingClientRect();
        return { x: r.left + r.width / 2, y: r.top + r.height / 2, r };
    };
    const inViewport = r => r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
    // What would receive a real click at the element's centre: the element itself, something inside
    // it, or its label — anything else is a cover (a cookie banner, a modal's backdrop).
    const hitOK = e => {
        const { x, y } = center(e);
        if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) return { ok: false, cover: 'outside the viewport' };
        let hit = document.elementFromPoint(x, y);
        while (hit && hit.shadowRoot) {
            const inner = hit.shadowRoot.elementFromPoint(x, y);
            if (!inner || inner === hit) break;
            hit = inner;
        }
        for (let a = hit; a; a = parentOf(a)) if (a === e) return { ok: true };
        if (hit && e.contains && e.contains(hit)) return { ok: true };
        if (hit && hit.tagName === 'LABEL' && hit.control === e) return { ok: true };
        if (hit && e.labels && [...e.labels].some(l => l.contains(hit))) return { ok: true };
        return { ok: false, cover: describe(hit) };
    };
    const node = ref => {
        const id = typeof ref === 'number' ? ref : parseInt(String(ref).replace(/^\D+/, ''), 10);
        const e = S.nodes.get(id);
        if (!e || !e.isConnected) return null;
        return e;
    };
    const record = (e, r) => {
        const role = roleOf(e);
        const item = { ref: 'e' + identity(e), role, name: nameOf(e) };
        const tag = e.tagName;
        if (tag === 'INPUT' && !['checkbox', 'radio', 'button', 'submit', 'reset', 'image'].includes(e.type)) {
            item.type = e.type;
            if (e.type === 'password') item.value = e.value ? '••••' : '';
            else item.value = e.value;
        } else if (tag === 'TEXTAREA') item.value = e.value.slice(0, 300);
        else if (e.isContentEditable) item.value = squash(e.innerText).slice(0, 300);
        else if (role === 'combobox' && e.getAttribute('aria-activedescendant') == null) {
            const v = e.getAttribute('aria-valuetext') || '';
            if (v) item.value = v;
        }
        if (tag === 'SELECT') {
            item.value = [...e.selectedOptions].map(o => squash(o.label)).join(', ');
            item.options = [...e.options].filter(o => !o.disabled).slice(0, 40).map(o => squash(o.label) || o.value);
            if (e.options.length > 40) item.moreOptions = e.options.length - 40;
        }
        if (e.type === 'checkbox' || e.type === 'radio') item.checked = e.checked;
        for (const key of ['checked', 'selected', 'expanded', 'pressed']) {
            const v = e.getAttribute('aria-' + key);
            if (v !== null && item[key] === undefined) item[key] = v === 'true' ? true : v === 'false' ? false : v;
        }
        const placeholder = e.getAttribute('placeholder');
        if (placeholder && placeholder !== item.name) item.placeholder = squash(placeholder);
        if (e.required || e.getAttribute('aria-required') === 'true') item.required = true;
        if (e.getAttribute('aria-invalid') === 'true' || (e.validity && e.willValidate && !e.validity.valid && e.value)) item.invalid = true;
        if (disabled(e)) item.disabled = true;
        if (role === 'link') {
            const href = e.getAttribute('href') || '';
            if (href && !href.startsWith('javascript:')) item.href = e.href;
        }
        item.actions = tag === 'SELECT' ? ['select'] : editable(e) ? ['fill', 'click'] : ['click'];
        item.box = [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)];
        item.where = inViewport(r) ? 'visible' : r.top >= innerHeight ? 'below' : r.bottom <= 0 ? 'above' : 'aside';
        return item;
    };
    const snapshot = (maxElements, textLimit) => {
        for (const [id, e] of S.nodes) if (!e.isConnected) S.nodes.delete(id);
        const seen = new Set(), items = [];
        let omitted = 0;
        for (const root of roots()) {
            for (const e of root.querySelectorAll(SELECTOR)) {
                if (seen.has(e)) continue;
                seen.add(e);
                if (!roleOf(e) || !visible(e)) continue;
                // A cell that wraps a button is one target, not two; a custom listbox is its options.
                if (e.getAttribute('role') === 'gridcell' && e.querySelector('button,[role="button"]')) continue;
                if (e.getAttribute('role') === 'listbox' && e.querySelector('[role="option"]')) continue;
                // A tabindex'd wrapper around a real control is noise.
                if (!e.matches('a[href],button,input,textarea,select,summary,[role]') && e.querySelector('a[href],button,input,select,textarea')) continue;
                const r = e.getBoundingClientRect();
                if (items.length >= maxElements) { omitted++; continue; }
                items.push(record(e, r));
            }
        }
        // The shadow walk appends out of document order; put the list back in reading order.
        items.sort((a, b) => (a.box[1] - b.box[1]) || (a.box[0] - b.box[0]));
        // Five buttons called "Select" are one button to a model. Each gets the text of the row it
        // stands in — the flight, the product, the message it belongs to.
        const counts = {};
        for (const item of items) counts[item.role + '|' + item.name] = (counts[item.role + '|' + item.name] || 0) + 1;
        for (const item of items) {
            if (counts[item.role + '|' + item.name] < 2) continue;
            const e = S.nodes.get(+item.ref.slice(1));
            for (let a = e && parentOf(e); a && a !== document.body; a = parentOf(a)) {
                const text = squash(a.innerText || '');
                if (text.length > item.name.length + 2) {
                    item.context = text.replace(item.name, '').trim().slice(0, 120);
                    break;
                }
            }
        }
        let text = '';
        if (textLimit > 0 && document.body) {
            const words = [], walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), range = document.createRange();
            let n, length = 0;
            while ((n = walker.nextNode()) && length < textLimit) {
                const value = n.textContent.replace(/\s+/g, ' ').trim(), parent = n.parentElement;
                if (!value || !parent || parent.closest('script,style,noscript,template') || !visible(parent)) continue;
                range.selectNodeContents(n);
                if (!inViewport(range.getBoundingClientRect())) continue;
                words.push(value);
                length += value.length + 1;
            }
            text = words.join('\n').slice(0, textLimit);
        }
        const dialog = [...document.querySelectorAll('dialog[open],[role="dialog"],[role="alertdialog"],[aria-modal="true"]')].find(visible);
        return {
            url: location.href, title: document.title, readyState: document.readyState,
            viewport: [innerWidth, innerHeight], scroll: [Math.round(scrollX), Math.round(scrollY)],
            pageHeight: document.documentElement.scrollHeight,
            focused: document.activeElement && S.ids.has(document.activeElement) ? 'e' + S.ids.get(document.activeElement) : null,
            dialog: dialog ? nameOf(dialog) || 'untitled' : null,
            elements: items, omitted, text,
        };
    };
    const ensureInView = e => {
        const r = e.getBoundingClientRect();
        if (r.top < 0 || r.left < 0 || r.bottom > innerHeight || r.right > innerWidth) {
            e.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        }
    };
    const mouse = (e, type, x, y, extra) => {
        const init = Object.assign({ bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, button: 0, buttons: type.endsWith('down') ? 1 : 0, detail: 1 }, extra || {});
        const Ctor = type.startsWith('pointer') && typeof PointerEvent === 'function' ? PointerEvent : MouseEvent;
        if (Ctor === PointerEvent) Object.assign(init, { pointerId: 1, pointerType: 'mouse', isPrimary: true });
        return e.dispatchEvent(new Ctor(type, init));
    };
    const click = (e, force) => {
        ensureInView(e);
        const hit = hitOK(e);
        if (!hit.ok && !force) return { error: 'covered', detail: describe(e) + ' is covered by ' + hit.cover + '; close what covers it, or scroll' };
        const { x, y } = center(e);
        mouse(e, 'pointerover', x, y); mouse(e, 'mouseover', x, y);
        mouse(e, 'pointerdown', x, y);
        const proceed = mouse(e, 'mousedown', x, y);
        if (proceed && e.focus) e.focus({ preventScroll: true });
        mouse(e, 'pointerup', x, y);
        mouse(e, 'mouseup', x, y);
        // click() runs activation behaviour: a link follows, a checkbox toggles, a submit button submits.
        e.click();
        return { ok: true };
    };
    const setNative = (e, value) => {
        const proto = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
        setter.call(e, value);
        e.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: value }));
    };
    const key = (e, name) => {
        const codes = { Enter: 13, Escape: 27, Tab: 9, ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39, Backspace: 8, Delete: 46, Space: 32, ' ': 32, Home: 36, End: 35, PageDown: 34, PageUp: 33 };
        const keyName = name === 'Space' ? ' ' : name;
        const code = name === 'Space' || name === ' ' ? 'Space' : name.length === 1 ? 'Key' + name.toUpperCase() : name;
        const init = { key: keyName, code, keyCode: codes[name] || (name.length === 1 ? name.toUpperCase().charCodeAt(0) : 0), which: codes[name] || 0, bubbles: true, cancelable: true, composed: true };
        const proceed = e.dispatchEvent(new KeyboardEvent('keydown', init));
        if (proceed && (name === 'Enter' || name.length === 1)) e.dispatchEvent(new KeyboardEvent('keypress', init));
        // The default actions an untrusted key does not get, done by hand where they are unambiguous.
        if (proceed && name === 'Enter') {
            if (e.form && e.tagName === 'INPUT') e.form.requestSubmit();
            else if (e.tagName === 'A' || e.tagName === 'BUTTON' || e.getAttribute('role') === 'button' || e.getAttribute('role') === 'option' || e.getAttribute('role') === 'link') e.click();
        }
        if (proceed && (name === 'Space' || name === ' ') && (e.tagName === 'BUTTON' || e.type === 'checkbox' || e.getAttribute('role') === 'checkbox' || e.getAttribute('role') === 'button')) e.click();
        if (proceed && name === 'Tab') {
            const all = [...document.querySelectorAll('a[href],button,input,select,textarea,[tabindex]:not([tabindex="-1"])')].filter(x => visible(x) && !disabled(x));
            const i = all.indexOf(e);
            const next = all[i + 1];
            if (next) next.focus();
        }
        e.dispatchEvent(new KeyboardEvent('keyup', init));
        return proceed;
    };
    """#

    /// Arguments: `maxElements`, `textLimit`.
    static let snapshot = library + "\nreturn snapshot(maxElements, textLimit);"

    /// Arguments: `ref`, `force`.
    static let click = library + #"""
    const e = node(ref);
    if (!e) return { error: 'stale', detail: 'ref ' + ref + ' is gone from the page' };
    if (disabled(e)) return { error: 'disabled', detail: describe(e) + ' is disabled' };
    if (!visible(e)) return { error: 'hidden', detail: describe(e) + ' is not visible' };
    const result = click(e, force);
    return Object.assign(result, { target: describe(e) });
    """#

    /// Arguments: `ref`, `text`, `submit`.
    static let fill = library + #"""
    const e = node(ref);
    if (!e) return { error: 'stale', detail: 'ref ' + ref + ' is gone from the page' };
    if (!editable(e)) return { error: 'not_editable', detail: describe(e) + ' is not a text field; use click or select_option' };
    if (disabled(e)) return { error: 'disabled', detail: describe(e) + ' is disabled' };
    ensureInView(e);
    e.focus({ preventScroll: true });
    let how = 'insertText';
    if (e.isContentEditable) {
        const range = document.createRange();
        range.selectNodeContents(e);
        const selection = getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        if (!(text ? document.execCommand('insertText', false, text) : document.execCommand('delete'))) { e.innerText = text; how = 'innerText'; }
    } else {
        e.select && e.select();
        const done = text ? document.execCommand('insertText', false, text) : document.execCommand('delete');
        // Some fields refuse editing commands (a date input, a masked field): the native setter, then input.
        if (!done || e.value !== text) { setNative(e, text); how = 'setter'; }
    }
    e.dispatchEvent(new Event('change', { bubbles: true }));
    let submitted = false;
    if (submit) submitted = key(e, 'Enter');
    const value = e.isContentEditable ? squash(e.innerText) : e.value;
    return { ok: true, target: describe(e), value: e.type === 'password' ? '••••' : value, how, submitted };
    """#

    /// Arguments: `ref`, `option` (a label or a value).
    static let select = library + #"""
    const e = node(ref);
    if (!e) return { error: 'stale', detail: 'ref ' + ref + ' is gone from the page' };
    if (e.tagName !== 'SELECT') return { error: 'not_select', detail: describe(e) + ' is not a native dropdown; click it, then click the option in the next snapshot' };
    if (disabled(e)) return { error: 'disabled', detail: describe(e) + ' is disabled' };
    const wanted = squash(String(option)).toLowerCase();
    const options = [...e.options].filter(o => !o.disabled);
    const match = options.find(o => squash(o.label).toLowerCase() === wanted) || options.find(o => o.value.toLowerCase() === wanted)
        || options.find(o => squash(o.label).toLowerCase().includes(wanted));
    if (!match) return { error: 'no_option', detail: 'no option "' + option + '" in ' + describe(e) + '; options: ' + options.map(o => squash(o.label)).slice(0, 40).join(' | ') };
    e.focus({ preventScroll: true });
    e.value = match.value;
    match.selected = true;
    e.dispatchEvent(new Event('input', { bubbles: true }));
    e.dispatchEvent(new Event('change', { bubbles: true }));
    return { ok: true, target: describe(e), value: squash(match.label) };
    """#

    /// Arguments: `ref` (optional; the focused element otherwise), `key`.
    static let press = library + #"""
    const e = ref ? node(ref) : (document.activeElement || document.body);
    if (!e) return { error: 'stale', detail: 'ref ' + ref + ' is gone from the page' };
    if (ref && e.focus) e.focus({ preventScroll: true });
    const proceed = key(e, keyName);
    return { ok: true, target: describe(e), defaultPrevented: !proceed };
    """#

    /// Arguments: `ref` (optional: scroll that element into view, or scroll inside it), `direction`.
    static let scroll = library + #"""
    const e = ref ? node(ref) : null;
    if (ref && !e) return { error: 'stale', detail: 'ref ' + ref + ' is gone from the page' };
    const scrollable = e && e.scrollHeight > e.clientHeight + 4 && /(auto|scroll)/.test(getComputedStyle(e).overflowY);
    if (e && !scrollable) {
        e.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        return { ok: true, target: describe(e), scroll: [scrollX, scrollY] };
    }
    const box = scrollable ? e : document.scrollingElement || document.documentElement;
    const page = scrollable ? e.clientHeight : innerHeight;
    const by = { down: page * 0.8, up: -page * 0.8, top: -box.scrollHeight, bottom: box.scrollHeight }[direction] ?? page * 0.8;
    box.scrollBy({ top: by, behavior: 'instant' });
    return { ok: true, target: scrollable ? describe(e) : 'page', scroll: [Math.round(box.scrollLeft), Math.round(box.scrollTop)], height: box.scrollHeight };
    """#

    /// How much the DOM has moved: a mutation counter and the document's identity, polled from Swift
    /// until two reads agree (`callJavaScript` cannot `await` — CLAUDE.md).
    static let settle = library + "\nreturn [S.mutations, document.readyState, location.href];"

    /// Arguments: `text`. Whether the text is on the page (rendered, not in the source).
    static let hasText = #"return !!document.body && document.body.innerText.toLowerCase().includes(String(text).toLowerCase());"#
}
