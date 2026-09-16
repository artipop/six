# The accessibility tree as the agent's eyes

View ▸ Accessibility Overlay (`⌥⌘A`) draws WebKit's accessibility tree over the focused window's page, and
`get_accessibility_tree` hands the same read to an agent as numbered lines. Mac only.

**None of it can be used yet.** Measured on the Mac, the read deadlocks the browser the first time it is allowed to
happen — "What the Mac answered" below has the two stacks and what follows from them. The branch is kept for the
walk, the placing and the outline, which are all still right; what has to change is who asks for the tree.

The user-facing account is
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
client API's trust check — the tree can be walked without the permission, and the reader should move to that. It
does not: with the permission not yet granted the line read `trusted false; the web view's own children in process:
[]`, so the in-process side really does stop at the token and the client API really is the only way in. Read it in
the log:

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

## What the Mac answered

Built and run on the Mac (macOS 27, Debug, 16 September 2026). Three of the questions below are answered, and the
fourth answer stops the feature.

- **Both Apple schemes build**, with no warning from any of the new files, and `SixCore`'s 201 tests pass.
- **Without the permission the tool refuses politely** — "six is not allowed to use macOS accessibility… the user has
  to switch six on in System Settings ▸ Privacy & Security ▸ Accessibility" — and `AccessibilityOverlay.probe`
  answered `trusted false; the web view's own children in process: []` (above).
- **With the permission granted, the first read deadlocks the browser.** Reproduced twice: once by turning the
  overlay on with `⌥⌘A`, once by calling `get_accessibility_tree` over `six --mcp` with no window and no menu
  involved. The app stays alive at 0% CPU and answers nothing — no MCP, no clicks — and only a kill ends it.

`sample` says the same thing both times. The thread that serves accessibility questions *inside six* suspends
another thread of six to answer, and that thread is holding SwiftUI's update lock:

```
main thread   UpdateGroup.begin() → _MovableLockLock → _pthread_mutex_firstfit_lock_wait → __psynch_mutexwait
HIE: … thread SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION (in HIServices) → thread_suspend
```

So the lock is never given back and the main thread waits for it forever. Nothing in `PageAccessibilityReader` is
wrong in itself — the read is already off the main thread, with a 1.5 s messaging timeout — because the suspension
is done by the system, at a point of its choosing, in a process that is asking *itself*. That is the part that has
to change: the question has to come from outside six.

Until it does, **leave six switched off in Privacy & Security ▸ Accessibility**. Untrusted, the API answers
`kAXErrorAPIDisabled` at once and the feature is merely absent; trusted, the overlay and the tool are each one
keystroke away from taking the browser down.

### Asked from outside instead — measured, and it works

`~/sources/angels/axprobe` (outside this repo) is a small `.app` that asks *another* process for its tree, plus
`stand/ax-stand.html`, ten cases where the two readings can disagree, and `stand/domdump.js`, the same page read
the other way — roles from `role` and the tag, names from the obvious attributes, boxes from
`getBoundingClientRect()`. A `.app` rather than a bare binary because a command run from a shell is answered for
by the terminal, and the grant would land there.

**What the tree holds that a DOM walk cannot get**, on the stand in Safari (the same engine, six not involved):

| the case | the accessibility tree | the DOM walk in the page |
|---|---|---|
| a **closed** shadow root | its button and field are there | nothing: `shadowRoot` is `null` |
| light DOM slotted into a shadow tree | the button is named "Slotted label" | the button has no name |
| `aria-hidden`, `role=presentation`, `inert` | all three gone | all three present, unless the walk climbs every ancestor |
| semantics from `ElementInternals` | `AXCheckBox (AXSwitch) "Custom switch"` | an element with no role at all |
| `<canvas>` with fallback content | the button inside it | a canvas, and nothing in it |
| an iframe | a web area of its own, with its button | not entered: another document |
| `aria-labelledby`, `<label for>` | assembled by the engine | the same answer — this part JS can do |
| what an element answers to | `press`, `increment`, `pick`… per element | nothing: the DOM does not say |

So four of the ten cases are not "harder" from inside the page, they are unreachable. That is what the
permission buys.

**And the deadlock is specific to a process asking itself.** `axprobe` read the same page inside a running six
with this branch's build: 400 elements in 0.17–0.40 s, closed shadow root included, three times in a row, and
six answered over MCP immediately after each read and went on working. A Wikipedia article came back as
1 889 elements in 0.65 s. Nothing suspended, nothing hung.

Two things the probe learned that six will need if it goes this way:

- **"The first web area" is a lottery.** six's rail keeps off-screen columns as web areas too, so one run walked
  the neighbouring column's `example.com` instead of the page on screen. Take the widest web area that overlaps
  a screen.
- **A rebuild costs the grant.** The bundle is ad-hoc signed, so re-signing it makes macOS ask again — the same
  trap the Debug app has.

**Signing, since the probe lost its grant twice.** That is ad-hoc signing, not something helpers do: with no Team
ID, TCC has only the code directory hash to key the grant to, and every rebuild produces a new one. Signed with a
Developer ID identity, the grant is keyed to the designated requirement — team plus bundle id — and survives
updates. six is ad-hoc signed today, Debug *and* the Release in `/Applications`, so this is a thing to fix before
any of it ships, whichever way the read goes.

The other half is already right: **App Sandbox is off** (`six/six.entitlements` says why — the ACP layer spawns
the user's own toolchain), and it has to be, because a sandboxed process cannot be an accessibility client at all.

What this does not answer: how six would carry a helper — a login item, an XPC service, a binary inside the app
bundle launched on demand — and what it costs to keep one alive. Nor does it make the tree free: the read is
still a permission the user grants, and the fallback for the fronts that are not the Mac is still the DOM walk
above, with its four blind spots.

## Still not measured

- the boxes sitting on the elements: full width, a split, a window half off the rail, page zoom, after a scroll —
  all of it waits on a read six can actually perform;
- whether the overlay's own prompt and the legend's button reach the right Settings pane.

## Not built

- **Acting.** `AXUIElementPerformAction(AXPress)` and setting `AXValue` are the obvious hands for these eyes, and
  they press the way VoiceOver does — but acting is the next stage of [agent-actions.md](agent-actions.md), with the
  permission boundaries that plan puts first.
- **Other fronts.** WebKitGTK exposes the same tree over AT-SPI (D-Bus), so Linux could have this without a
  permission prompt. Windows' WebKit and iOS have no route.
- **Cross-origin iframes** in separate processes (site isolation) appear as remote frames inside the tree; not tested.
