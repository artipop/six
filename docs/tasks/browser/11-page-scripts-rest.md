# 11. The rest of the scripts in pages — one pass

Five things about the JavaScript Savoia runs in pages, close enough for one sitting. Rewritten on 8 October 2026,
after tabs moved to a `WKWebView` of Savoia's own: read the code, not the older text of
[page-scripts.md](../../page-scripts.md), which still speaks of `WebPage` in places — bringing it up to date is
part of this task.

Background in one paragraph: a script the app runs in a page is a **user gesture** to WebKit unless it is called
with `withUserGesture: false`. After a gesture the page may open windows, play sound and read the clipboard as if
a person had clicked. Savoia has the gesture-free call (`WKWebView.callWithoutGesture` in
`Savoia/Browser/PageScripts.swift`, SPI behind `responds(to:)`), and the calls that run by themselves use it.

## 1. One door, and it carries no gesture

There are three ways to run a script today, and they differ only in the gesture:

- `WKWebView.savoia(_:arguments:)` — Savoia's content world, **with** a gesture. About seventeen call sites:
  `BrowserTools` (selection, links, page blocks, highlights), `HighlightStore` (painting one, the selection's
  selectors, scrolling to one), `Export` (the page's source and type), `WebSearch`, `ReadablePage+WebView`,
  `PageFocus` (reading the selection for ⌘E), `AccessibilityOverlay`.
- `BrowserTab.callWithoutGesture` and `runScript` — without one. Translation, the acting tools, `TabSorter`, the
  highlights put back on a load, `evaluate_javascript`.
- `WKWebView.callJavaScript` — the page's world, with a gesture: WebMCP's page calls and the MCP app bridge.

When a tab was a `WebPage` the gesture-free call needed the tab, to find its view. It does not now: the method is
on the view. So **make `savoia(_:arguments:)` itself the gesture-free call**, and the seventeen sites change
without being touched. Then there is one name where there are three; remove the fallback in
`BrowserTab.callWithoutGesture` if nothing can reach it any more.

Check, do not assume, the few that might have relied on the gesture: putting an answer into a field
(`PageFocusScript.insert`, `execCommand('insertText')` — it already goes through `runScript`, so it probably does
not), scrolling to a highlight, and the off-screen page `WebSearch` keeps. For the page's world, decide per caller:
a WebMCP tool call is made on a person's or an agent's say-so and a page may expect activation from it — say what
was chosen and why.

Done when: `navigator.userActivation.isActive` is false after each of `get_selection`, `get_page_links`,
`list_page_blocks`, `highlight_page`, a bookmark being saved, Save As and ⌘E on a selection, checked through
`Savoia --mcp` in a throwaway home; and [page-scripts.md](../../page-scripts.md) has no row that says a call is a
gesture without a reason.

## 2. The description for tab groups

`TabSorter.pageFinished` runs a script on every load to read the meta description or the first paragraph. It is
the last script that runs on every page for every person. See whether what the tab already has is enough — the
title and address, which cost nothing — and drop the script if grouping is no worse. Compare on real tabs, not on
a guess: `SAVOIA_TOPICS_SELFTEST`. If the description earns its keep, it stays and the doc says by how much.

## 3. `MediaHold` as a setting of the view

A user script in every frame, installed for one load after a tab is rebuilt, pauses media nobody pressed play on
(`Savoia/Browser/MediaHold.swift`). It existed because `WebPage.Configuration` had no
`mediaTypesRequiringUserActionForPlayback` on macOS. `WKWebViewConfiguration` has it. Try it for a rebuilt tab —
the configuration is fixed when the view is made, so see whether "this load only" can still be had, or whether a
view made to hold media can be let go after the first gesture. If it cannot be had without the script, the script
stays and the doc says why.

## 4. Why there is no `PaymentRequest` — fifteen minutes

A page in Savoia has no `PaymentRequest` and no `ApplePaySession`; both are `undefined`, so a shop's Apple Pay
button is absent or dead, and six wpt files differ from Safari for it. Measured with and without the blocker's page
scripts, so those are not the cause. It is not the Apple ID's region either: Safari on the same Mac answers
`typeof PaymentRequest` with `"function"` (Artem, by hand).

One experiment is left: a twenty-five-line app with a bare `WKWebView`, no user script, an https page, and
`typeof PaymentRequest`. There → something Savoia does to its views hides it; find which (user scripts, the
content world, a preference) by adding Savoia's configuration back a piece at a time. Not there → it is what WebKit
gives an app that is not Safari, and that is the end of it. Write the answer into [todo.md](../../todo.md),
[api-watch.md](../../api-watch.md) and the guide's "not there yet" list in both languages. Build nothing.

## 5. The blocker's page half is a setting, off by default

Decided by Artem on 7 October 2026: scriptlets and extended CSS (`AdvancedRules`) stay in the code and are **off
unless switched on**. Today that is the environment variable `SAVOIA_ADVANCED_RULES`
(`AdvancedRules.isOn`). Make it a switch in Configuration ▸ Privacy ▸ Blocking, off for a new install and for an
existing one, and drop the variable. The label names the thing and a caption only a consequence, in English and
Russian (AGENTS.md: the interface never narrates what Savoia does).

Then the words catch up: [blocking.md](../../blocking.md), AGENTS.md's list of what is built, and the guide
([guide/blocking.md](../../guide/blocking.md), both languages), which describes scriptlets as if they ran for
everyone. Cosmetic rules inside frames stay not built.

## Order, and what each is

1 is the one that matters and is mostly a single edit plus checking. 5 is a small feature with strings. 4 is an
experiment that ends in a sentence. 2 and 3 may each end in "it stays, and here is why" — that is a result. Each
is its own commit; stop wherever the session ends.
