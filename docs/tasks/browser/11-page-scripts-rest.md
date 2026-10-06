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

[todo.md](../../todo.md#apple-pay-not-supported-and-why-is-not-known). It is not the region: Safari on the same Mac
has `PaymentRequest`. Two candidates are left, and one experiment separates them: a twenty-five-line app with a
bare `WKWebView`, no user script, loading an https page, reading `typeof PaymentRequest`. There → Savoia's user
scripts hide it, and it can come back for pages that get none. Not there → it is WebKit's limit on an app that is
not Safari, and that is the end of it. Write the answer into todo.md and the guide either way; build nothing.

## 4. `AdvancedRules`: on, or gone

The blocker's scriptlets and extended CSS are off behind `SAVOIA_ADVANCED_RULES=1` while Artem uses the browser
without them. **Ask him how it went before touching anything.** Then either the switch goes and they are back, or
the code, the vendored payload (`Savoia/Blocking/Payload`, `scripts/blocking-payload.sh`) and the claims in
[blocking.md](../../blocking.md) and the guide go. Until then the guide ([guide/blocking.md](../../guide/blocking.md),
both languages) describes scriptlets that are not running — if a release is cut first, it has to say so.
