# The accessibility tree as the agent's eyes

View ▸ Accessibility Overlay (`⌥⌘A`) draws WebKit's accessibility tree over the focused window's page, and
`get_accessibility_tree` hands the same read to an agent as numbered lines. Mac only. The user-facing account is
[guide/accessibility.md](guide/accessibility.md); the plan for acting on what is seen is
[agent-actions.md](agent-actions.md).

| file | what it does |
|---|---|
| `six/Accessibility/PageAccessibilityReader.swift` | the walk: `AXUIElement` calls on a serial queue → `AXPageSnapshot`, plain values |
| `six/Accessibility/AccessibilityOverlay.swift` | the model (`AccessibilityOverlay.shared`), placing the snapshot over the web view, the outline for a model, and the SwiftUI layer |
| `six/Input/WebViewResponder.swift` | `webView(for:)` — the pane's `WKWebView`, which is the only way to know where on screen a `WebPage` is |
| `six/Views/NiriStripView.swift` | mounts `AccessibilityOverlayView` over the focused pane |
| `six/Views/MacCommands.swift` | the View menu toggle |
| `six/Tools/BrowserTools.swift` | `get_accessibility_tree` (`surfaces: .mcp`) |

## Why the accessibility tree and not the DOM

The DOM says what the markup says. The accessibility tree is what the engine *concluded* from it: ARIA roles and
names applied, `aria-hidden` subtrees gone, a label resolved from wherever it came from, a `div` with a click handler
turned into something that answers `AXPress` — plus, per element, the list of what it actually answers. That is the
vocabulary a person with a screen reader drives the page in, and the one a well-made site has already been tested
against. It is computed in the engine, out of the page's reach: a page cannot redefine a getter to show the agent a
button a person does not see. The DOM walk in [agent-actions.md](agent-actions.md#этап-2-снимок-и-действия-по-dom)
stays the fallback for everything this cannot do — no permission, and the fronts that are not the Mac.

## Why `AXUIElement`, and why that takes a permission

Checked in WebKit's source (`Source/WebKit/UIProcess/mac/WebViewImpl.mm`, September 2026), not reasoned:

- The tree lives in the **web content process**. In this process `WKWebView` reports itself as an `AXGroup` whose one
  child is `m_remoteAccessibilityChild` — an `NSAccessibilityRemoteUIElement` made with `initWithRemoteToken:` from a
  token the web process sent. Even `accessibilityHitTest:` returns that element, whatever the point.
- That remote element is resolved by the accessibility runtime on the **client's** side, by talking to the web
  process. So the NSAccessibility protocol asked in-process stops at a token, and the client API — `AXUIElement` —
  is the one that crosses. macOS allows a process that API only once Privacy & Security ▸ Accessibility lists it,
  **including when the process it asks is itself**: an untrusted call answers `kAXErrorAPIDisabled`.
- `WebPage` has no accessibility API at all. `WKWebView` has `_retrieveAccessibilityTreeData:` — but it is in
  `WKWebViewTestingMac.mm`, WebKit's test SPI, and it returns a dump for layout tests, without the geometry or the
  actions an overlay needs.
- The first accessibility question the web view is asked (anything but parent and position) runs
  `enableAccessibilityIfNecessary`, which sets `AccessibilityMode::MainThread` on web content processes. From then on
  WebKit keeps an accessibility tree up to date for the pages it serves — a cost the pages did not pay before the
  overlay was first turned on, and one worth measuring on the 8 GB Mac.

**The one thing still open is the second point**, and `AccessibilityOverlay.probe` exists to settle it: once per
launch it logs what the web view's in-process child answers for `AXRole` and `AXChildren`, through the old
`accessibilityAttributeValue:`. If the remote element does answer in-process — if AppKit forwards it without the
client API's trust check — the tree can be walked without the permission, and the reader should move to that. Read
it in the log:

```sh
grep "accessibility probe" ~/Library/Logs/org.deffun.six.dev/six.log
```

## The read

`PageAccessibilityReader.snapshot(at:visible:limit:)`, off the main thread — the path from the app's element down to
the web view is answered by this app's own main thread, and a main thread blocked waiting for its own answer times
out instead.

1. `AXUIElementCopyElementAtPosition` on `AXUIElementCreateApplication(getpid())` at the middle of the pane's visible
   part.
2. Up the `AXParent`s to the **outermost** `AXWebArea` — an iframe is a web area of its own. If there is none above
   (the hit test stopped at the web view's own group), a short breadth-first search down from where it stopped.
3. Depth-first from there, children pushed in reverse so the numbers come out in document order. Per element, one
   `AXUIElementCopyMultipleAttributeValues` for role, subrole, role description, title, description, value,
   placeholder, `AXDOMIdentifier`, position, size, enabled, focused and children; `AXUIElementCopyActionNames`; and,
   for the roles that can have one, whether `AXValue` is settable.
4. A subtree whose box has a size and misses the visible part (plus 40 pt) is not walked; a zero-size box is walked,
   because WebKit gives some containers none while their children are on screen. `AXStaticText` is not descended
   into. The walk stops at 2 500 elements.
5. An element with no title or description takes its name from the text inside it, the way a screen reader reads a
   link.

A messaging timeout of 1.5 s is set on the system-wide element, so a busy web process costs a missing subtree
instead of a frozen overlay. If the first read comes back with fewer than three elements, it is read once more
400 ms later: WebKit builds its tree when first asked.

**Kinds**, for colour and for the outline: *control* (buttons, links, checkboxes, pop-ups, sliders… and anything
answering `AXPress`/`AXIncrement`/`AXPick`/`AXConfirm`), *field* (text fields, text areas, combo boxes, search
fields, or a settable value), *landmark* (`AXLandmark*` subroles, dialogs, articles), *heading*, *image*, *text*,
*other*. `AXScrollToVisible` and `AXShowMenu` are not listed as verbs: WebKit gives them to every element.

## Placing it over the page

Accessibility counts from the top-left of the primary screen, y down; AppKit from its bottom-left, y up. Each box is
flipped into AppKit's screen space, taken into the window with `convertFromScreen`, into the web view with
`convert(_:from: nil)`, and flipped again if the view is not flipped. The result is in the web view's own points,
which are the overlay's, because the overlay is laid over exactly that view. The view's size at reading time is kept,
and the canvas scales by it if the pane has changed size since.

A snapshot is a picture of a moment. While the overlay is on, `follow` asks the page for `scrollX`, `scrollY`,
`innerWidth`, `innerHeight` and `readyState` every 500 ms (in six's world, from the live page only — the overlay must
never be what builds a page). When they change, the boxes fade to 20 %; once two polls agree, the tree is read
again. A still page is read again every 5 s, for DOM changes. The task belongs to the view: moving the focus or
turning the switch off cancels it.

The boxes and labels are one `Canvas` — a page has hundreds of elements. Labels are placed greedily, controls first,
and skipped where they would cover one already placed. The canvas is `accessibilityHidden`: otherwise the next hit
test lands on the overlay instead of the page under it. The legend is `HostedOverlay`, because SwiftUI drawn over a
`WKWebView` never sees the mouse.

## For a model

`get_accessibility_tree(window_id?, include_text?, max_nodes?)`:

```
[1] document "Example Domain" @0,0 1280×720
  [4] heading level 1 "Example Domain" @320,133 640×38
  [9] link "More information..." — press @320,261 150×18
```

Roles are ARIA's (`button`, `textbox`, `navigation`), not AppKit's and not the system's localized ones: a model knows
the first vocabulary. Groups that are only structure are left out and their children pulled up a level. The numbers
are valid until the next read — they are what the acting tools of [agent-actions.md](agent-actions.md) will take. A
read done for the tool lands in the overlay too, so with the overlay on, the person sees what the agent was just
given.

The window must be on screen: the tree is read from what is displayed, and the tool says `focus_window` rather than
reading a pane that is off the edge of the rail.

## Not verified

This was written on the Windows machine, with no Mac to build or run it on. Before it is believed, on the Mac:

- both Apple schemes build (everything new is inside `#if os(macOS)`; the tool's body has an `#else` for iOS);
- turning the overlay on puts up macOS's own Accessibility prompt; the legend's button opens the right pane;
- the probe line above — what the in-process child answers;
- the hit test reaches the web area (or the downward fallback does) — `get_accessibility_tree` over `six --mcp` on a
  plain page;
- the boxes sit on the elements: full width, a split, a window half off the rail, page zoom, after a scroll;
- time and element count on a long page (a Wikipedia article) — the legend prints both;
- a Debug build keeps its grant across rebuilds; a re-signed binary can lose it, and then the legend says so.

## Not built

- **Acting.** `AXUIElementPerformAction(AXPress)` and setting `AXValue` are the obvious hands for these eyes, and
  they press the way VoiceOver does — but acting is the next stage of [agent-actions.md](agent-actions.md), with the
  permission boundaries that plan puts first.
- **Other fronts.** WebKitGTK exposes the same tree over AT-SPI (D-Bus), so Linux could have this without a
  permission prompt. Windows' WebKit and iOS have no route.
- **Cross-origin iframes** in separate processes (site isolation) appear as remote frames inside the tree; not tested.
