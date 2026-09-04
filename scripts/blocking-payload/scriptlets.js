/**
 * AdGuard's scriptlet library — the ~200 named counter-measures a filter list asks for by name
 * (`example.com#%#//scriptlet('set-constant', 'adBlockDetected', 'false')`).
 *
 * This file never reaches a page. It is a *compiler*: `invoke({name, args})` returns the source
 * of one scriptlet, and six runs it in JavaScriptCore, in the app, once per distinct scriptlet.
 * What a page gets is the few kilobytes that came out — which is why six's pages do not carry
 * 350 KB of library each, and why the result can be a `WKUserScript` at document start, ahead of
 * the page's own scripts and out of reach of its Content-Security-Policy.
 */
import { scriptlets } from '@adguard/scriptlets';

globalThis.sixScriptlets = scriptlets;
