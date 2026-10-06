# 11. The rest of the scripts in pages — one pass

Four small things about the JavaScript Savoia runs in pages, close enough to be done in one sitting. Read
[page-scripts.md](../../page-scripts.md) first; it is the inventory and says what is already done.

## 1. The calls that are still a user gesture

`BrowserTab.callWithoutGesture` exists and the automatic calls use it. What a person or an agent asks for still goes
through `page.savoia(…)`, which is `callJavaScript` and therefore a gesture each time: the readable copy for
bookmarks, export and Save As, the accessibility overlay, going to a highlight, the selection for ⌘E (read,
reselect, insert), `get_selection`, `get_page_links`, `list_page_blocks`, `highlight_page`.

Move them to the gesture-free call, or say for each why it must stay. Inserting an answer into a field
(`PageFocusScript.insert`, `execCommand('insertText')`) may need the gesture — measure it rather than assume.

Done when: [page-scripts.md](../../page-scripts.md) has no row that says "still a gesture" without a reason, and
`navigator.userActivation.isActive` is false after each of those tools is called through `Savoia --mcp`.

## 2. The description for tab groups

`TabSorter.pageFinished` runs a script on every load to read the meta description or the first paragraph. It is the
last script that runs on every page. See whether what the tab already knows is enough — the title and address it
has without asking, or the text `ReadablePage` extracts when the page is bookmarked or read — and drop the script if
grouping is no worse. Compare on the tabs Artem has open, not on a guess: `SAVOIA_TOPICS_SELFTEST`.

## 3. Why there is no `PaymentRequest` — fifteen minutes

A page in Savoia has no `PaymentRequest` and no `ApplePaySession` — both are `undefined`, so a shop's Apple Pay
button is absent or dead, and the six wpt files `permissions-policy/payment-*` and `reporting/payment-reporting`
differ from Safari for that reason. Measured in October 2026 on an https page, with and without the blocker's page
scripts (`AdvancedRules`), so those are not the cause.

What the cause is was not established, and the investigation was dropped rather than finished. It is not the
region of the Apple ID, where Apple Pay does not work at all: Safari 27.2 on the same Mac answers
`typeof PaymentRequest` with `"function"` (Artem, by hand). So it is something about Savoia as an app — a limit
WebKit puts on one that is not Safari, or the user scripts Savoia still installs. A twenty-five-line app with a
bare `WKWebView` and no user script tells those two apart.

The experiment: that app, an https page, `typeof PaymentRequest`. There → Savoia's user scripts hide it, and it can
come back for pages that get none. Not there → it is WebKit's limit on an app that is not Safari, and that is the
end of it. Write the answer into [todo.md](../../todo.md) and the guide either way; build nothing.

## 4. The blocker's page half is a setting, off by default

Decided by Artem on 7 October 2026: scriptlets and extended CSS (`AdvancedRules`) stay in the code and are **off
unless switched on**. Today that is the environment variable `SAVOIA_ADVANCED_RULES`; make it a switch in
Configuration ▸ Privacy ▸ Blocking, off for a new install and for an existing one, and drop the variable. The label
names the thing and the caption a consequence, in English and Russian (AGENTS.md: the interface never narrates
what Savoia does).

Then the words catch up: [blocking.md](../../blocking.md), AGENTS.md's list of what is built, and the guide
([guide/blocking.md](../../guide/blocking.md), both languages), which today describes scriptlets as if they ran
for everyone. Cosmetic rules inside frames ([blocking.md](../../blocking.md#not-built-cosmetic-rules-inside-a-frame))
stay not built.
