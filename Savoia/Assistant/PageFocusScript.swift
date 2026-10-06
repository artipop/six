import Foundation

/// The page-side half of `PageFocus`: what is selected, where the caret is, and how text gets put
/// back. It runs in Savoia's own content world (`PageScripts.swift`), so the page cannot redefine
/// `getSelection` or an input's value getter and hand the model something the person never typed —
/// the same reason the readable-page extractor and the highlighter live there.
///
/// Function bodies called through `WebPage.savoia(_:arguments:)`, and synchronous: `callJavaScript`
/// is not `callAsyncJavaScript` and an `await` in the body fails at parse time. Nothing here is
/// installed in a page ahead of time (docs/page-scripts.md).
nonisolated enum PageFocusScript {

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
    ///
    /// It also **remembers the last selection it saw**, in the page and in this world, because the
    /// selection does not survive the ⌘E line taking the keyboard: a field collapses its own to a
    /// caret and a selection in prose is dropped outright. Swift keeps the text of it, but only the
    /// page can keep the nodes, and putting an answer back needs the range and not the words.
    private static let reader = secrets + """

        const LIMIT = 8000;

        function remember(state) {
            const active = document.activeElement;
            const tag = active ? active.tagName : '';
            if (state.kind !== 'selection') return state;
            if (tag === 'INPUT' || tag === 'TEXTAREA') {
                window.__savoiaKeep = { field: active, start: state.start, end: state.end, range: null };
                return state;
            }
            const sel = window.getSelection();
            if (sel && sel.rangeCount > 0) {
                window.__savoiaKeep = { field: null, start: 0, end: 0, range: sel.getRangeAt(0).cloneRange() };
            }
            return state;
        }

        /// Put back the selection this world remembers, if it is still the one being asked about —
        /// the numbers for a field, the text for a range. A stale one is left alone: a caret that
        /// has moved on is not a selection that was lost.
        function reselect(text, start, end) {
            const keep = window.__savoiaKeep;
            if (!keep) return 'nothing kept';
            if (keep.field) {
                if (!document.contains(keep.field)) return 'the field is gone';
                if (keep.start !== start || keep.end !== end) return 'the field moved on';
                keep.field.setSelectionRange(keep.start, keep.end);
                return 'field ' + keep.start + '-' + keep.end;
            }
            if (!keep.range) return 'nothing kept';
            if (keep.range.toString() !== text) return 'the selection moved on';
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(keep.range);
            return 'range';
        }

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
                return remember({
                    kind: end > start ? 'selection' : 'caret',
                    text: end > start ? value.slice(start, end) : '',
                    field: value,
                    start: start,
                    end: end,
                    editable: !active.readOnly && !active.disabled,
                    multiline: tag === 'TEXTAREA',
                    label: nameOf(active),
                    rect: boxOf(active)
                });
            }

            const sel = window.getSelection();
            if (sel && sel.rangeCount > 0 && !sel.isCollapsed) {
                const range = sel.getRangeAt(0);
                const host = editableHost(sel.anchorNode);
                if (host && secret(host)) return { kind: 'none' };
                const r = range.getBoundingClientRect();
                const text = sel.toString();
                if (!text.trim()) return { kind: 'none' };
                return remember({
                    kind: 'selection',
                    text: text.slice(0, LIMIT),
                    field: host ? (host.innerText || '').slice(0, LIMIT) : '',
                    start: 0,
                    end: 0,
                    editable: !!host,
                    multiline: true,
                    label: host ? nameOf(host) : '',
                    rect: [r.left, r.top, r.width, r.height]
                });
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

    /// What is pointed at, now.
    static let read = reader + """

        return describe();
        """

    /// Called from Swift: put `text` where the selection is (or at the caret).
    ///
    /// `execCommand('insertText')` rather than a value assignment, deliberately: it fires the input
    /// events a framework-driven field listens for, and it lands in the page's own undo stack — so
    /// ⌘Z takes it back, which is what makes a wrong rewrite cheap.
    /// Called when the line comes up: the page is asked to hold on to what it was showing, so the
    /// person can still see what the question is about.
    static let reselect = reader + """

        return reselect(text, start, end);
        """

    /// Putting an answer back. `text` is the answer, `whole` replaces the field; `subject`,
    /// `start` and `end` are what the line was about, so the selection can be put back first — by
    /// the time this runs the page has collapsed it, and inserting over a caret is not replacing.
    static let insert = reader + """

        const keep = window.__savoiaKeep;
        let target = document.activeElement;
        const editable = target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA');
        if (!editable && keep && keep.field && document.contains(keep.field)) target = keep.field;
        if (secret(target)) return false;
        const tag = target ? target.tagName : '';
        if (tag === 'INPUT' || tag === 'TEXTAREA') {
            target.focus();
            if (whole) {
                target.setSelectionRange(0, (target.value || '').length);
            } else {
                reselect(subject, start, end);
            }
            const ok = document.execCommand('insertText', false, text);
            if (!ok) {
                // A field that refuses the command — set the value through the native setter and
                // say so ourselves, which is what a framework's onChange is listening for.
                const proto = tag === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                const value = target.value || '';
                const from = whole ? 0 : (target.selectionStart || 0);
                const to = whole ? value.length : (target.selectionEnd || 0);
                setter.call(target, value.slice(0, from) + text + value.slice(to));
                target.dispatchEvent(new Event('input', { bubbles: true }));
                target.dispatchEvent(new Event('change', { bubbles: true }));
            }
            return true;
        }
        if (!whole) reselect(subject, start, end);
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
