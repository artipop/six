/**
 * The cosmetic half of an advanced rule, as it runs inside a page.
 *
 * Plain element hiding (`site.com##.banner`) never reaches here — WebKit's own JSON has
 * `css-display-none` and the converter emits it. What is left are the two kinds it cannot
 * express: CSS *injection* (`#$#.ad { height: 0 !important; }`), and extended CSS, whose
 * selectors (`:has-text()`, `:contains()`, `:xpath()`, `:matches-css()`) no CSS engine knows —
 * they are matched by AdGuard's own library, which is the whole reason this file is 40 KB.
 *
 * six calls it from a content world of its own, so the page can neither see `sixCosmetic` nor
 * replace the DOM methods it uses.
 */
import { ExtendedCss } from '@adguard/extended-css';

/**
 * A rule arrives either as a selector or as a whole CSS rule; a bare selector means hide it.
 * This is AdGuard's own `toCSSRules`, kept identical on purpose.
 */
const toCSSRules = (rules) => rules
    .map((rule) => rule.trim())
    .filter((rule) => rule.length > 0)
    .map((rule) => (rule.at(-1) !== '}' ? `${rule} {display:none!important;}` : rule));

/**
 * Sites that dislike being filtered empty the style element they find. Putting the rules back
 * costs one observer, and the alternative is a page that un-hides its ads a second after load.
 */
const protectStyleElement = (element) => {
    const { MutationObserver } = window;
    if (!MutationObserver) return;
    const observer = new MutationObserver((mutations) => {
        for (const mutation of mutations) {
            if (element.getAttribute('mod') === 'inner') {
                element.removeAttribute('mod');
                break;
            }
            element.setAttribute('mod', 'inner');
            let restored = false;
            if (mutation.removedNodes.length > 0) {
                for (const node of mutation.removedNodes) {
                    restored = true;
                    element.appendChild(node);
                }
            } else if (mutation.oldValue) {
                restored = true;
                element.textContent = mutation.oldValue;
            }
            if (!restored) element.removeAttribute('mod');
        }
    });
    observer.observe(element, {
        childList: true, characterData: true, subtree: true, characterDataOldValue: true,
    });
};

const insertCss = (css) => {
    if (!css || css.length === 0) return;
    const element = document.createElement('style');
    element.setAttribute('type', 'text/css');
    (document.head || document.documentElement).appendChild(element);
    if (element.sheet) {
        for (const rule of toCSSRules(css)) {
            try {
                element.sheet.insertRule(rule);
            } catch (e) {
                // One malformed selector out of a filter list must not cost the other thousand.
            }
        }
    }
    protectStyleElement(element);
};

const insertExtendedCss = (extendedCss) => {
    if (!extendedCss || extendedCss.length === 0) return;
    new ExtendedCss({ cssRules: toCSSRules(extendedCss) }).apply();
};

/**
 * Applies both, and answers what it did so Swift can log a page that got rules but showed none.
 * Called at document start, before the page has a body: `insertRule` on a `<style>` in `<head>`
 * and ExtendedCss's own observer both handle an empty document and catch up as it fills.
 */
globalThis.sixCosmetic = (css, extendedCss) => {
    let applied = 0;
    try {
        insertCss(css);
        applied += css.length;
    } catch (e) {
        console.error('six: failed to insert CSS', e);
    }
    try {
        insertExtendedCss(extendedCss);
        applied += extendedCss.length;
    } catch (e) {
        console.error('six: failed to insert extended CSS', e);
    }
    return applied;
};
