import Foundation

/// The page-side half of `PageFocus`: what is selected, where the caret is, and how text gets put
/// back. It runs in six's own content world (`PageScripts.swift`), so the page cannot redefine
/// `getSelection` or an input's value getter and hand the model something the person never typed —
/// the same reason the readable-page extractor and the highlighter live there.
///
/// Two halves with different shapes. The **watcher** is a user script installed once per window; it
/// pushes over a message handler, because a selection is an event and polling for one would run
/// while nothing at all is happening. The **entry points** are function bodies called through
/// `WebPage.six(_:arguments:)` when six actually has something to write, and they are synchronous:
/// `callJavaScript` is not `callAsyncJavaScript` and an `await` in the body fails at parse time.
nonisolated enum PageFocusScript {
    static let handlerName = "sixFocus"

    /// Never read, never posted, never sent anywhere: a password, a one-time code, a card number.
    /// The cheapest place to drop a secret is before it is sent, which is here and not in Swift.
    private static let secrets = """
        const SECRET = /password|one-time-code|cc-(number|csc|exp)|credit|card/i;
        function secret(el) {
            if (!el) return false;
            const type = (el.type || '').toLowerCase();
            if (type === 'password') return true;
            if (el.autocomplete && SECRET.test(el.autocomplete)) return true;
            if (el.name && SECRET.test(el.name)) return true;
            if (el.id && SECRET.test(el.id)) return true;
            return false;
        }
        """

    /// Reading the page: what is focused, what is selected, and where on screen that is.
    private static let reader = secrets + """

        const LIMIT = 8000;

        function nameOf(el) {
            if (!el) return '';
            const aria = el.getAttribute && el.getAttribute('aria-label');
            if (aria) return aria.trim().slice(0, 120);
            if (el.labels && el.labels.length) return (el.labels[0].innerText || '').trim().slice(0, 120);
            if (el.placeholder) return el.placeholder.trim().slice(0, 120);
            const title = el.getAttribute && el.getAttribute('title');
            if (title) return title.trim().slice(0, 120);
            return '';
        }

        function boxOf(el) {
            const r = el.getBoundingClientRect();
            return [r.left, r.top, r.width, r.height];
        }

        function editableHost(node) {
            let el = node && node.nodeType === 1 ? node : (node ? node.parentElement : null);
            while (el && el.nodeType === 1) {
                if (el.isContentEditable) return el;
                el = el.parentElement;
            }
            return null;
        }

        // A field's own selection, which `window.getSelection()` does not report: inside an
        // `<input>` or a `<textarea>` WebKit keeps a selection of its own, reachable only through
        // `selectionStart`/`selectionEnd`.
        function describe() {
            const active = document.activeElement;
            const tag = active ? active.tagName : '';
            if (tag === 'INPUT' || tag === 'TEXTAREA') {
                if (secret(active)) return { kind: 'none' };
                if (tag === 'INPUT') {
                    const type = (active.type || 'text').toLowerCase();
                    if (['text','search','email','url','tel','number',''].indexOf(type) < 0) return { kind: 'none' };
                }
                const value = (active.value || '').slice(0, LIMIT);
                const start = active.selectionStart || 0;
                const end = active.selectionEnd || 0;
                return {
                    kind: end > start ? 'selection' : 'caret',
                    text: end > start ? value.slice(start, end) : '',
                    field: value,
                    start: start,
                    end: end,
                    editable: !active.readOnly && !active.disabled,
                    multiline: tag === 'TEXTAREA',
                    label: nameOf(active),
                    rect: boxOf(active)
                };
            }

            const sel = window.getSelection();
            if (sel && sel.rangeCount > 0 && !sel.isCollapsed) {
                const range = sel.getRangeAt(0);
                const host = editableHost(sel.anchorNode);
                if (host && secret(host)) return { kind: 'none' };
                const r = range.getBoundingClientRect();
                const text = sel.toString();
                if (!text.trim()) return { kind: 'none' };
                return {
                    kind: 'selection',
                    text: text.slice(0, LIMIT),
                    field: host ? (host.innerText || '').slice(0, LIMIT) : '',
                    start: 0,
                    end: 0,
                    editable: !!host,
                    multiline: true,
                    label: host ? nameOf(host) : '',
                    rect: [r.left, r.top, r.width, r.height]
                };
            }

            if (active && active.isContentEditable) {
                if (secret(active)) return { kind: 'none' };
                let rect = boxOf(active);
                // A caret has a rectangle of its own inside a rich editor, and it is the one worth
                // pointing at: the host element can be the whole page.
                if (sel && sel.rangeCount > 0) {
                    const caret = sel.getRangeAt(0).getBoundingClientRect();
                    if (caret.width || caret.height) rect = [caret.left, caret.top, caret.width, caret.height];
                }
                return {
                    kind: 'caret',
                    text: '',
                    field: (active.innerText || '').slice(0, LIMIT),
                    start: 0,
                    end: 0,
                    editable: true,
                    multiline: true,
                    label: nameOf(active),
                    rect: rect
                };
            }

            return { kind: 'none' };
        }
        """

    /// Installed once per window, at document end.
    static let source = """
        (function () {
            if (window.__sixFocusInstalled) return;
            window.__sixFocusInstalled = true;
        \(reader)

            let last = '';
            let timer = 0;

            function post(force) {
                const state = describe();
                const key = JSON.stringify(state);
                if (!force && key === last) return;
                last = key;
                try { window.webkit.messageHandlers.\(handlerName).postMessage(state); } catch (e) {}
            }

            function schedule(delay) {
                if (timer) clearTimeout(timer);
                timer = setTimeout(function () { timer = 0; post(false); }, delay);
            }

            document.addEventListener('selectionchange', function () { schedule(140); }, true);
            document.addEventListener('focusin', function () { schedule(60); }, true);
            document.addEventListener('mouseup', function () { schedule(60); }, true);
            document.addEventListener('keyup', function () { schedule(200); }, true);
            // The rectangle moves with the page even when what it points at has not changed, and a
            // bar left behind at the old place is worse than no bar.
            document.addEventListener('scroll', function () { schedule(80); }, true);
            window.addEventListener('resize', function () { schedule(120); });
            // A page's own focus leaving for six's chrome must not clear anything: pressing ⌘K
            // after selecting a paragraph is the ordinary case, and WebKit keeps the selection.
            schedule(200);
        })();
        """

    /// Called from Swift: read the focus now, without waiting for an event.
    static let read = reader + """

        return describe();
        """

    /// Called from Swift: put `text` where the selection is (or at the caret).
    ///
    /// `execCommand('insertText')` rather than a value assignment, deliberately: it fires the input
    /// events a framework-driven field listens for, and it lands in the page's own undo stack — so
    /// ⌘Z takes it back, which is what makes a wrong rewrite cheap.
    static let insert = secrets + """

        const active = document.activeElement;
        const tag = active ? active.tagName : '';
        if (secret(active)) return false;
        if (tag === 'INPUT' || tag === 'TEXTAREA') {
            active.focus();
            if (whole) active.setSelectionRange(0, (active.value || '').length);
            const ok = document.execCommand('insertText', false, text);
            if (!ok) {
                // A field that refuses the command — set the value through the native setter and
                // say so ourselves, which is what a framework's onChange is listening for.
                const proto = tag === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                const value = active.value || '';
                const start = whole ? 0 : (active.selectionStart || 0);
                const end = whole ? value.length : (active.selectionEnd || 0);
                setter.call(active, value.slice(0, start) + text + value.slice(end));
                active.dispatchEvent(new Event('input', { bubbles: true }));
                active.dispatchEvent(new Event('change', { bubbles: true }));
            }
            return true;
        }
        const sel = window.getSelection();
        let host = null;
        let node = sel && sel.anchorNode;
        while (node) {
            if (node.nodeType === 1 && node.isContentEditable) { host = node; break; }
            node = node.parentElement || node.parentNode;
        }
        if (!host) return false;
        host.focus();
        if (whole) {
            const range = document.createRange();
            range.selectNodeContents(host);
            sel.removeAllRanges();
            sel.addRange(range);
        }
        return document.execCommand('insertText', false, text);
        """
}
