import Foundation

extension WebMCPScript {
    /// Declarative tools: a `<form toolname tooldescription>` is a tool. Spliced into `source`, whose
    /// closure it shares. The schema and the filling follow Chromium's `form_mcp_schema.cc`
    /// (BSD-licensed), which is the spec for as long as the draft's section says TODO; the
    /// submission follows wpt's `webmcp/declarative` tests.
    nonisolated static let declarative = #"""
            (function () {
                // A sandboxed frame without scripts gets no tools, as the page's own scripts get nothing.
                try {
                    const frame = window.frameElement;
                    if (frame && frame.hasAttribute('sandbox') && !frame.sandbox.contains('allow-scripts')) { return; }
                } catch (e) {}

                const { HTMLFormElement, HTMLInputElement, HTMLSelectElement, HTMLTextAreaElement, HTMLButtonElement,
                        HTMLFieldSetElement, HTMLOptionElement, Element, SubmitEvent, MutationObserver, RegExp } = window;
                const nativeMatches = Element.prototype.matches;
                const nativeRequestSubmit = HTMLFormElement.prototype.requestSubmit;
                const nativeSubmit = HTMLFormElement.prototype.submit;
                const nativeQuery = Document.prototype.querySelectorAll;
                const property = (proto, key) => Object.getOwnPropertyDescriptor(proto, key);
                const inputValue = property(HTMLInputElement.prototype, 'value');
                const textareaValue = property(HTMLTextAreaElement.prototype, 'value');
                const inputChecked = property(HTMLInputElement.prototype, 'checked');
                const optionSelected = property(HTMLOptionElement.prototype, 'selected');

                const FORM_ATTRIBUTES = ['toolname', 'tooldescription', 'tooltitle', 'toolautosubmit'];
                const CONTROL_ATTRIBUTES = ['name', 'type', 'required', 'toolparamdescription', 'multiple', 'min', 'max',
                    'step', 'pattern', 'disabled', 'readonly', 'form', 'for', 'aria-description', 'value', 'label'];
                const TEXT = new Set(['text', 'email', 'search', 'tel', 'url', 'password']);
                const TYPED = new Set(['date', 'datetime-local', 'month', 'week', 'time', 'number', 'range', 'checkbox',
                    'radio', 'color']);
                const LABELABLE = new Set(['BUTTON', 'INPUT', 'METER', 'OUTPUT', 'PROGRESS', 'SELECT', 'TEXTAREA']);

                const entries = new Map();        // form -> entry
                const activeForms = new WeakSet();
                const activeSubmits = new WeakSet();
                const pending = new Map();        // form -> the agent's submission in progress
                const agentEvents = new WeakMap();

                // MARK: The schema

                const kindOf = (el) => {
                    if (el instanceof HTMLTextAreaElement) { return 'text'; }
                    if (el instanceof HTMLSelectElement) { return 'select'; }
                    if (!(el instanceof HTMLInputElement)) { return null; }
                    const type = el.type;
                    if (TEXT.has(type)) { return 'text'; }
                    if (type === 'hidden') { return el.getAttribute('toolparamdescription') ? 'text' : null; }
                    return TYPED.has(type) ? type : null;
                };

                const groupKind = (controls) => {
                    if (controls.length === 1) { return kindOf(controls[0]); }
                    if (controls.every((el) => kindOf(el) === 'checkbox')) { return 'checkbox'; }
                    if (controls.every((el) => kindOf(el) === 'radio')) { return 'radio'; }
                    return null;
                };

                const labelText = (el) => {
                    const labels = el.labels;
                    if (!labels || !labels.length) { return ''; }
                    const parts = [];
                    for (const label of labels) {
                        let text = '';
                        const walk = (node) => {
                            for (const child of node.childNodes) {
                                if (child.nodeType === 3) { text += child.data; }
                                else if (child.nodeType === 1 && !LABELABLE.has(child.tagName)) { walk(child); }
                            }
                        };
                        walk(label);
                        parts.push(text.trim());
                    }
                    return parts.join('; ');
                };

                const describeControls = (controls, form) => {
                    if (controls.length === 1) {
                        const el = controls[0];
                        return el.getAttribute('toolparamdescription') || labelText(el) || el.getAttribute('aria-description') || '';
                    }
                    let common = controls[0];
                    for (const el of controls.slice(1)) {
                        while (common && !common.contains(el)) { common = common.parentNode; }
                    }
                    for (let node = common; node && node !== form; node = node.parentNode) {
                        if (node instanceof HTMLFieldSetElement) { return node.getAttribute('toolparamdescription') || ''; }
                    }
                    return '';
                };

                const described = (schema, controls, form, extra) => {
                    let description = describeControls(controls, form);
                    if (extra) { description = description ? description + ' (' + extra + ')' : extra; }
                    if (description) { schema.description = description; }
                    return schema;
                };

                const addPattern = (el, schema) => {
                    if (!(el instanceof HTMLInputElement) || !el.hasAttribute('pattern')) { return; }
                    const raw = el.getAttribute('pattern');
                    try { new RegExp(raw, 'v'); } catch (e) { return; }
                    schema.pattern = raw;
                };

                const FLOAT = /^-?(\d+(\.\d+)?|\.\d+)([eE][-+]?\d+)?$/;
                const number = (text) => (text !== null && FLOAT.test(text) ? Number(text) : null);
                const isMultiple = (base, step) => Math.abs(base / step - Math.round(base / step)) < 1e-9;

                // `step` in the input's own unit; `null` when it is "any" and `any` is not the default.
                const stepOf = (el, fallback, anyIsDefault) => {
                    const raw = el.getAttribute('step');
                    if (raw === null) { return fallback; }
                    if (raw.trim().toLowerCase() === 'any') { return anyIsDefault ? fallback : null; }
                    const step = number(raw.trim());
                    return step !== null && step > 0 ? step : fallback;
                };

                const clock = (el, withDate) => {
                    const ms = stepOf(el, 60, true) * 1000;
                    const date = withDate ? '[0-9]{4}-(0[1-9]|1[0-2])-[0-9]{2}T' : '';
                    const tail = ms < 1000 ? '(:[0-5][0-9](\\.[0-9]{1,3})?)?' : ms < 60000 ? '(:[0-5][0-9])?' : '';
                    return '^' + date + '([01][0-9]|2[0-3]):[0-5][0-9]' + tail + '$';
                };

                const choices = (controls) => {
                    const anyOf = [];
                    const values = [];
                    let required = false;
                    for (const el of controls) {
                        const choice = { type: 'string', const: el.value };
                        const title = labelText(el);
                        if (title) { choice.title = title; }
                        anyOf.push(choice);
                        values.push(el.value);
                        required = required || el.required;
                    }
                    return { anyOf, values, required };
                };

                // [schema, required], or null for a name Savoia cannot describe.
                const parameter = (controls, form) => {
                    const kind = groupKind(controls);
                    const el = controls[0];
                    switch (kind) {
                    case 'text': {
                        const schema = { type: 'string' };
                        addPattern(el, schema);
                        return [described(schema, controls, form), el.required];
                    }
                    case 'date':
                        return [described({ type: 'string', format: 'date' }, controls, form,
                            "Dates MUST be provided in 'YYYY-MM-DD' format."), el.required];
                    case 'datetime-local':
                        return [described({ type: 'string', format: clock(el, true) }, controls, form), el.required];
                    case 'time':
                        return [described({ type: 'string', format: clock(el, false) }, controls, form), el.required];
                    case 'month':
                        return [described({ type: 'string', format: '^[0-9]{4}-(0[1-9]|1[0-2])$' }, controls, form), el.required];
                    case 'week':
                        return [described({ type: 'string', format: '^[0-9]{4}-W(0[1-9]|[1-4][0-9]|5[0-3])$' }, controls, form),
                            el.required];
                    case 'color':
                        return [described({ type: 'string', format: '^#[0-9a-zA-Z]{6}$' }, controls, form), el.required];
                    case 'number': {
                        const schema = { type: 'number' };
                        const min = number(el.getAttribute('min'));
                        const max = number(el.getAttribute('max'));
                        if (min !== null) { schema.minimum = min; }
                        if (max !== null) { schema.maximum = max; }
                        const step = stepOf(el, 1, false);
                        const base = min !== null ? min : (number(el.getAttribute('value')) ?? 0);
                        if (step !== null && isMultiple(base, step)) { schema.multipleOf = step; }
                        addPattern(el, schema);
                        return [described(schema, controls, form), el.required];
                    }
                    case 'range': {
                        const min = number(el.getAttribute('min')) ?? 0;
                        const max = Math.max(min, number(el.getAttribute('max')) ?? 100);
                        const schema = { type: 'number', minimum: min, maximum: max };
                        const step = stepOf(el, 1, true);
                        if (isMultiple(min, step)) { schema.multipleOf = step; }
                        return [described(schema, controls, form), el.required];
                    }
                    case 'select': {
                        const options = Array.from(el.options);
                        const anyOf = options.map((o) => ({ type: 'string', const: o.value, title: o.textContent }));
                        const values = options.map((o) => o.value);
                        const schema = el.multiple
                            ? { type: 'array', items: { type: 'string', anyOf, enum: values }, uniqueItems: true }
                            : { type: 'string', anyOf, enum: values };
                        return [described(schema, controls, form), el.required];
                    }
                    case 'checkbox': {
                        if (controls.length === 1) { return [described({ type: 'boolean' }, controls, form), el.required]; }
                        const { anyOf, values, required } = choices(controls);
                        const schema = { type: 'array', items: { type: 'string', anyOf, enum: values }, uniqueItems: true };
                        return [described(schema, controls, form), required];
                    }
                    case 'radio': {
                        const { anyOf, values, required } = choices(controls);
                        return [described({ type: 'string', anyOf, enum: values }, controls, form), required];
                    }
                    default:
                        return null;
                    }
                };

                const isSubmit = (el) => (el instanceof HTMLButtonElement && el.type === 'submit')
                    || (el instanceof HTMLInputElement && (el.type === 'submit' || el.type === 'image'));

                const collect = (form) => {
                    const names = [];
                    const byName = new Map();
                    let submit = null;
                    for (const el of Array.from(form.elements)) {
                        if (nativeMatches.call(el, ':disabled')) { continue; }
                        if ((el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) && el.hasAttribute('readonly')) { continue; }
                        const name = el.getAttribute('name') || '';
                        if (!byName.has(name)) { byName.set(name, []); names.push(name); }
                        byName.get(name).push(el);
                        if (!submit && isSubmit(el)) { submit = el; }
                    }
                    return { names, byName, submit };
                };

                const schemaOf = (form) => {
                    const { names, byName } = collect(form);
                    const properties = {};
                    const required = [];
                    for (const name of names) {
                        if (!name) { continue; }
                        const result = parameter(byName.get(name), form);
                        if (!result) { continue; }
                        properties[name] = result[0];
                        if (result[1]) { required.push(name); }
                    }
                    return { type: 'object', properties, required };
                };

                // MARK: Filling

                const asString = (v) => typeof v === 'string' ? v
                    : typeof v === 'number' ? (Number.isFinite(v) ? String(v) : null)
                    : typeof v === 'boolean' ? (v ? 'true' : 'false') : null;
                const asBoolean = (v) => {
                    if (typeof v === 'boolean') { return v; }
                    if (typeof v === 'number' && Number.isInteger(v)) { return v !== 0; }
                    if (typeof v === 'string') {
                        const lower = v.toLowerCase();
                        if (lower === 'true' || v === '1') { return true; }
                        if (lower === 'false' || v === '0') { return false; }
                    }
                    return null;
                };
                // What the input's own value sanitisation makes of a string: empty means refused.
                const sanitizes = (el, text) => {
                    if (!(el instanceof HTMLInputElement)) { return true; }
                    const probe = document.createElement('input');
                    probe.type = el.type;
                    inputValue.set.call(probe, text);
                    return inputValue.get.call(probe) !== '';
                };
                const uniqueFrom = (value, allowed) => {
                    if (!Array.isArray(value)) { return false; }
                    const left = new Set(allowed);
                    for (const item of value) {
                        const text = asString(item);
                        if (text === null || !left.has(text)) { return false; }
                        left.delete(text);
                    }
                    return true;
                };

                const valid = (controls, kind, value) => {
                    const el = controls[0];
                    switch (kind) {
                    case 'text': case 'date': case 'datetime-local': case 'month': case 'week': case 'time': case 'color': {
                        const text = asString(value);
                        return text !== null && (text === '' || sanitizes(el, text));
                    }
                    case 'number': case 'range': {
                        const text = asString(value);
                        return text !== null && text !== '' && sanitizes(el, text);
                    }
                    case 'checkbox':
                        return controls.length === 1 ? asBoolean(value) !== null : uniqueFrom(value, controls.map((c) => c.value));
                    case 'radio': {
                        const text = asString(value);
                        return text !== null && controls.some((c) => c.value === text);
                    }
                    case 'select': {
                        const values = Array.from(el.options, (o) => o.value);
                        if (el.multiple) { return uniqueFrom(value, values); }
                        const text = asString(value);
                        return text !== null && values.includes(text);
                    }
                    default:
                        return false;
                    }
                };

                const fire = (el, type) => el.dispatchEvent(new Event(type, { bubbles: true }));
                const check = (el, on) => {
                    const was = inputChecked.get.call(el);
                    inputChecked.set.call(el, on);
                    if (was !== on) { fire(el, 'input'); }
                    fire(el, 'change');
                };

                const fill = (controls, kind, value) => {
                    const el = controls[0];
                    switch (kind) {
                    case 'checkbox':
                        if (controls.length === 1) { return check(el, asBoolean(value)); }
                        for (const control of controls) { check(control, value.map(asString).includes(control.value)); }
                        return;
                    case 'radio':
                        for (const control of controls) { if (control.value === asString(value)) { check(control, true); } }
                        return;
                    case 'select': {
                        const wanted = el.multiple ? new Set(value.map(asString)) : new Set([asString(value)]);
                        let changed = false;
                        for (const option of Array.from(el.options)) {
                            const on = wanted.has(option.value);
                            if (!el.multiple && !on) { continue; }
                            if (optionSelected.get.call(option) !== on) { optionSelected.set.call(option, on); changed = true; }
                        }
                        if (changed) { fire(el, 'input'); fire(el, 'change'); }
                        return;
                    }
                    default: {
                        const text = asString(value);
                        const accessor = el instanceof HTMLTextAreaElement ? textareaValue : inputValue;
                        const before = accessor.get.call(el);
                        accessor.set.call(el, text);
                        if (accessor.get.call(el) !== before) { fire(el, 'input'); fire(el, 'change'); }
                    }
                    }
                };

                // MARK: Running a form

                const fail = (message) => new DOMException(message, 'UnknownError');

                const settle = (state) => {
                    const event = state.event;
                    if (!event) { return state.done(false, fail('the form was not submitted')); }
                    const agent = agentEvents.get(event);
                    if (agent) { agent.dispatching = false; }
                    if (!event.defaultPrevented) { return state.done(true, NOTHING); }
                    if (agent && agent.response) {
                        return agent.response.then((value) => state.done(true, value), (error) => state.done(false, fail(say(error))));
                    }
                    if (state.programmatic) { return state.done(true, NOTHING); }
                    state.done(false, fail('the submit event was cancelled without respondWith()'));
                };

                const runner = (form, entry) => (input, options) => new Promise((resolve, reject) => {
                    const { byName, submit } = collect(form);
                    const names = Object.keys(input || {});
                    for (const name of names) {
                        const controls = name ? byName.get(name) : undefined;
                        if (!controls) {
                            return reject(fail('Input contains a parameter "' + name + '" but there is no such parameter for the tool'));
                        }
                        const kind = groupKind(controls);
                        if (!kind || !valid(controls, kind, input[name])) { return reject(fail('Invalid value for parameter ' + name)); }
                    }
                    for (const name of names) { const controls = byName.get(name); fill(controls, groupKind(controls), input[name]); }
                    if (!document.defaultView || !form.isConnected) { return reject(fail('the form went away while it was filled')); }
                    const autosubmit = form.hasAttribute('toolautosubmit');
                    if (!autosubmit && !submit) { return reject(fail('the form has no submit button to focus')); }
                    if (autosubmit && !form.checkValidity()) { return reject(fail('the form does not validate')); }

                    let finished = false;
                    const state = { form, button: submit, autosubmit, event: null, dispatching: false, programmatic: false };
                    state.done = (ok, value) => {
                        if (finished) { return; }
                        finished = true;
                        activeForms.delete(form);
                        if (submit) { activeSubmits.delete(submit); }
                        if (pending.get(form) === state) { pending.delete(form); }
                        (ok ? resolve : reject)(value);
                    };
                    pending.set(form, state);
                    activeForms.add(form);
                    if (submit) { activeSubmits.add(submit); }
                    const signal = options && options.signal;
                    if (signal) { signal.addEventListener('abort', () => state.done(false, signal.reason), { once: true }); }
                    announceCall('toolactivated', entry.name);
                    if (!autosubmit) {
                        try { submit.focus(); } catch (e) {}
                        return;
                    }
                    state.dispatching = true;
                    try {
                        nativeRequestSubmit.call(form, submit || undefined);
                    } catch (error) {
                        return state.done(false, fail(say(error)));
                    } finally {
                        state.dispatching = false;
                    }
                    settle(state);
                });

                window.addEventListener('submit', (event) => {
                    const state = pending.get(event.target);
                    if (!state || state.event) { return; }
                    if (state.autosubmit ? !state.dispatching : event.submitter !== state.button) { return; }
                    state.event = event;
                    agentEvents.set(event, { dispatching: true, response: null });
                    if (!state.autosubmit) { setTimeout(() => settle(state), 0); }
                }, true);

                window.addEventListener('reset', (event) => {
                    const state = pending.get(event.target);
                    if (state && !state.event) { state.done(false, fail('the form was reset')); }
                }, true);

                const agentInvoked = property({ get agentInvoked() { return agentEvents.has(this); } }, 'agentInvoked').get;
                Object.defineProperty(SubmitEvent.prototype, 'agentInvoked', { get: agentInvoked, configurable: true, enumerable: true });
                Object.defineProperty(SubmitEvent.prototype, 'respondWith', {
                    value: function respondWith(response) {
                        const agent = agentEvents.get(this);
                        if (!agent || !agent.dispatching || !this.defaultPrevented) {
                            throw new DOMException('respondWith() answers an agent-invoked submission, during its dispatch, '
                                + 'after preventDefault()', 'InvalidStateError');
                        }
                        agent.response = Promise.resolve(response);
                    },
                    configurable: true, writable: true, enumerable: true
                });
                Object.defineProperty(HTMLFormElement.prototype, 'submit', {
                    value: function submit() {
                        const state = pending.get(this);
                        const agent = state && state.event && agentEvents.get(state.event);
                        if (agent && agent.dispatching) { state.programmatic = true; }
                        return nativeSubmit.call(this);
                    },
                    configurable: true, writable: true, enumerable: true
                });

                // MARK: :tool-form-active and :tool-submit-active, for matches() and closest()

                const PSEUDO = /:tool-(form|submit)-active/;
                const selectorList = (text) => {
                    const parts = [];
                    let depth = 0;
                    let start = 0;
                    for (let i = 0; i < text.length; i++) {
                        const c = text[i];
                        if (c === '(' || c === '[') { depth++; } else if (c === ')' || c === ']') { depth--; }
                        else if (c === ',' && depth === 0) { parts.push(text.slice(start, i)); start = i + 1; }
                    }
                    parts.push(text.slice(start));
                    return parts.map((p) => p.trim());
                };
                const matchesWithPseudo = (el, text) => {
                    for (const part of selectorList(text)) {
                        if (!PSEUDO.test(part)) {
                            if (nativeMatches.call(el, part)) { return true; }
                            continue;
                        }
                        const found = /^(.*?):tool-(form|submit)-active$/.exec(part);
                        if (!found || PSEUDO.test(found[1]) || /[\s>+~]$/.test(found[1])) {
                            throw new DOMException("'" + text + "' is not a valid selector.", 'SyntaxError');
                        }
                        const active = found[2] === 'form' ? activeForms : activeSubmits;
                        if (active.has(el) && (found[1] === '' || nativeMatches.call(el, found[1]))) { return true; }
                    }
                    return false;
                };
                const matches = function matches(selectors) {
                    const text = String(selectors);
                    return PSEUDO.test(text) ? matchesWithPseudo(this, text) : nativeMatches.call(this, selectors);
                };
                const nativeClosest = Element.prototype.closest;
                const closest = function closest(selectors) {
                    const text = String(selectors);
                    if (!PSEUDO.test(text)) { return nativeClosest.call(this, selectors); }
                    for (let el = this; el; el = el.parentElement) { if (matchesWithPseudo(el, text)) { return el; } }
                    return null;
                };
                for (const [key, value] of [['matches', matches], ['webkitMatchesSelector', matches], ['closest', closest]]) {
                    Object.defineProperty(Element.prototype, key, { value, configurable: true, writable: true, enumerable: true });
                }

                // MARK: Keeping the tools in step with the forms

                const describeForm = (form) => {
                    const name = form.getAttribute('toolname');
                    const description = form.getAttribute('tooldescription');
                    if (!name || !NAME.test(name) || !description) { return null; }
                    const meta = { name, description, title: form.getAttribute('tooltitle') || '',
                                   autosubmit: form.hasAttribute('toolautosubmit'), schema: schemaOf(form) };
                    meta.key = stringify([meta.name, meta.description, meta.title, meta.autosubmit, meta.schema]);
                    return meta;
                };

                const apply = (entry, meta) => {
                    Object.assign(entry, { name: meta.name, title: meta.title, description: meta.description,
                                           inputSchema: meta.schema, pageSchema: meta.schema, key: meta.key });
                };

                const sync = () => {
                    if (!document.defaultView) { return; }
                    let moved = false;
                    for (const [form, entry] of Array.from(entries)) {
                        const meta = form.isConnected && form.ownerDocument === document ? describeForm(form) : null;
                        if (!meta || meta.name !== entry.name) {
                            if (tools.get(entry.name) === entry) {
                                tools.delete(entry.name);
                                post({ kind: 'unregister', name: entry.name });
                                moved = true;
                            }
                            entries.delete(form);
                            continue;
                        }
                        if (meta.key !== entry.key) { apply(entry, meta); announce(entry); moved = true; }
                    }
                    for (const form of Array.from(nativeQuery.call(document, 'form[toolname]'))) {
                        if (entries.has(form)) { continue; }
                        const meta = describeForm(form);
                        if (!meta || tools.has(meta.name)) { continue; }
                        const entry = {
                            tool: null, form, declaredAnnotations: false, debugging: false, provided: false, exposedTo: [],
                            annotations: { readOnlyHint: false, untrustedContentHint: false, consequentialHint: false }
                        };
                        apply(entry, meta);
                        entry.execute = runner(form, entry);
                        tools.set(entry.name, entry);
                        entries.set(form, entry);
                        announce(entry);
                        moved = true;
                    }
                    for (const [form, state] of Array.from(pending)) {
                        if (!form.isConnected && !state.event) { state.done(false, fail('the form was removed')); }
                    }
                    if (moved) { changed(context); }
                };

                const observer = new MutationObserver(sync);
                observer.observe(document, {
                    subtree: true, childList: true, attributes: true,
                    attributeFilter: FORM_ATTRIBUTES.concat(CONTROL_ATTRIBUTES)
                });
                flushForms = () => { if (observer.takeRecords().length) { sync(); } };
                document.addEventListener('DOMContentLoaded', sync);
                queueMicrotask(sync);
            })();
    """#
}
