# Unmeasured

Claims this repository makes, or nearly makes, that nobody has watched happen. Each one is a thing that would take
one sitting to settle; they live here rather than in the page they belong to, because a page that says "believed"
in six places is a page nobody trusts and nobody fixes.

A line leaves this file by being measured, in either direction, and by the page it came from being rewritten to say
what was seen. Say when it was measured and on what.

**Most of what waits for a hand has a page to do it on.** `./scripts/walk.sh` serves `scripts/walk/` on localhost
and opens it in the Debug Savoia: twelve stations, sixty-nine checks, each saying what to press and what should
happen, with the buttons, lists, video and file fields it needs on the page. Answers are kept in the browser, and
**Copy the report** on the first page gives them as text to paste back — which is how lines leave this file. The
stations follow the sections below; what has no station is what needs no hand (the wpt lines).

## uBOL: what was not pressed

**2026-10-08, macOS 27.2, dev build, throwaway homes.** The control runs, the per-tab half and the four calls
behind the verdict were measured and are in [extensions.md](extensions.md#ublock-origin-lite). What they left:

- **uBOL's popup.** Every mode change was the popup's own message, sent from the dashboard open in a tab. The
  slider was not moved, and the count was read from `action.getBadgeText`, not seen on the button.
- **Two readings of the hidden block that disagree with the rest.** A new tab opened after the mode went back
  from complete to optimal still hid the block, where the tab that was already open showed it; and once, in
  complete mode, a tab showed the block twelve seconds after a navigation. Neither was repeated or explained.
- **`testpages.adblockplus.org`** answers 301 to the home page of `abptestpages.org`, and its filters are a test
  subscription of Adblock Plus that uBOL does not carry. Element hiding was measured on a page of our own.
- **The 96 of 22 September** was 91 on every load of this day, in optimal and in complete mode.
- **"Open Options Page" in the Extensions list, and the toggle that lets an extension stand in for the start
  page.** The options page was opened by the extension itself and the override by a setting written between two
  launches; neither control was clicked.
- **The verdict in the install dialog** says `scripting` and content scripts work now. The dialog was not opened
  after the change.

## An agent's hover and drag, past the stand page

**2026-10-07, macOS, dev build.** `hover` and `drag` over `Savoia --mcp` passed seven steps on a page written for
them, with Savoia in the background and launched in front ([agent-actions.md](agent-actions.md#hover-and-drag-the-pointer)).
What that leaves:

- **A window known to be key.** `document.hasFocus()` answered false in every run, the ones in front too, and
  again on 8 October with Savoia started by `open`: the Release Savoia was the front app by then. The first fault
  found — a dragging session following the person's pointer — showed only with Savoia in front, so this is the
  case most likely to hide another. It takes a Mac nobody is working at.
- **What a person sees, in motion.** Drawn with `testdriver_window_image` on 8 October: the menu open under its
  button after `hover`, and nothing left on the page after a refused `drag`
  ([agent-actions.md](agent-actions.md#hover-and-drag-the-pointer)). A drawing is one frame; the walk's "An
  agent's hand" is for the eye.
- **A Trello-like board**, or any real site whose items do have a control in them. SortableJS's own page has
  none, and the agent cannot name an item there.
- **Hover in wpt** was run on 8 October 2026 and is a fault, not a question: 24 of 85 addresses below Safari's
  row ([tasks/devtools/34](tasks/devtools/34-hover-under-webdriver.md)). Not run: the thirteen hover files that
  also name a drag, and the permission baseline after the runner changed.
- **Drag-and-drop in wpt measures nothing yet.** A run of `html/editing/dnd` stopped at 50 files: 18 passed, 31
  timed out, every one the same as Safari's row. The runner sends down, move, up past `PageActions.drag`, so
  those are the raw path's timeouts and not the tool's. Before they mean anything the press has to be kept at the
  web view — down declines the session, a move after `dragstart` is the destination's `draggingUpdated`, up is the
  drop — with the tool and the runner both on it. **Do not run them on the raw path while Artem is at the Mac**:
  each starts a real dragging session and writes the system's drag pasteboard, and it got in the way of his work.
- **Whether WebKit's automation starts a dragging session too**, when `performInteractionSequence` presses and
  moves over a `draggable` element. Reasoned, not measured.
- **Chrome's and Firefox's rows for the same files** on wpt.fyi were not read, so it is not known how many of the
  31 a browser passes at all.

The instrument is a page with a CSS hover menu, a `mouseenter` tooltip, a list sorted on `mousemove`, a list of
`draggable` items, a drop target and an element that takes no drops, each with a button or a `draggable` element
inside so the snapshot gives it a ref, and a `state()` that returns the lists' order, the menu's `display`, the
tooltip's text and the event log. Seven tool calls — `hover` twice, `drag` four times, the last onto the refusing
element, then `click` — and `state()` read through `evaluate_javascript` after each.

## What the move to `WKWebView` left to eyes and hands

**2026-10-06 to 08, macOS, dev build, throwaway homes.** Every tab became a `WKWebView` of Savoia's own
([architecture.md](architecture.md#from-webpage-to-wkwebview)). The self-tests, the wpt runs and a set of scenarios
over `Savoia --mcp` came out the same as before the move or better, and these were watched happen: a download and
the tab opened only to carry it, a certificate failure and its page (read in a drawing of the window), a restored
tab that does not start its sound and plays on the next navigation, an extension's options page and its new-tab
override as tabs, `window.open` with a message back to the opener, element fullscreen entered by a real click and
left by navigating. What nobody has watched:

- **The context menu.** It is an `NSMenu` built from SPI (`PageContextMenu`, `PageDelegate`), and the SPI was
  exercised once, on a throwaway `WKWebView`, with a synthetic right click. In Savoia nobody has opened it: on a
  link, on a page, in a document's preview; its Share items; an extension's own items in it. Half of this needs
  no eyes — a test-driver tool that asks for the menu at a point and lists its items.
- **A ⌘-click.** The delegate cancels it and opens the link behind; no run has sent one. `testdriver_click` holds
  no modifiers, and a click sent through `Automation.performInteractionSequence` reached no page in the one
  attempt, plain or modified — most likely the command was put together wrongly.
- **A web archive opened again.** Save As answers `bplist00` bytes of a plausible size; the file was never written
  through the panel or loaded back into a tab.
- **Back and forward by swipe.** `allowsBackForwardNavigationGestures` is set; no gesture can be sent from here.
- **The picture in fullscreen, and picture-in-picture.** The state, the size and the way home are measured, on
  YouTube too ([permissions.md](permissions.md#compatibility-web-platform-tests)); whether anything is drawn is
  not, and a black screen was the fault the removed workaround was for. A drawing of the fullscreen window shows
  the page laid out at the screen's size and no video frame, which is what a drawing gives for video anywhere;
  and the page read `hidden` while in fullscreen, with Savoia behind another app.
- **A call.** The camera's question passes in wpt on a stand page; a real call, screen sharing with its picker and
  the mute buttons in the address field were not tried.
- **A sign-in through a window the site opens** — Sign in with Google, Telegram's widget. It is a tab now, and
  the size it asks for is not honoured; only the mechanics were measured, on a stand page.
- **An extension's popup.** WebKit's own popover, pointed at the toolbar button.
- **Translation.** `SAVOIA_TRANSLATE_SELFTEST` in a fresh home lands on the welcome page and finds no plan, so it
  said nothing before the move or after.
- **The lock in the address field on a failed https load.** The drawing of the certificate page shows it. Whether
  it was there before the move was not checked.
- **The key ring's self-test on the last build.** `SAVOIA_KEY_SELFTEST=1` read "no key window" in its last two
  runs, with the screen locked or another app in front; `=alert` was run by Artem on a free Mac and passed.

## Remote automation and the page's host, 7 October 2026

What [devtools.md](devtools.md#remote-automation) and [permissions.md](permissions.md#compatibility-web-platform-tests)
say after that day's work, and the part of it nobody watched.

- **A person's first click on an automation tab.** `AutomatedWebView` accepts the first mouse so that the
  protocol's click lands with Savoia behind another app. It follows that a person who clicks a Savoia window to
  bring it forward also clicks whatever in the page was under the pointer, on such a tab only. Reasoned, not tried.
- **A window an automation tab opens** is said to be an automation tab with the same view. That it is built as an
  `AutomatedWebView`, and that the protocol clicks in it from behind, was not run.
- **The rest of the protocol's mouse.** Measured: `Move`, `Down`, `Up` of the left button in a sequence, and
  `performMouseInteraction` `Down` and `Up`. Not run: the right and middle buttons, a double click, a drag, a wheel
  source, an `Element` origin. Why `SingleClick` sends two mouse-downs is not known.
- **The page that does not come home from fullscreen.** The host takes it back, and that was measured on the one
  wpt file that showed it. A page of the same shape made by hand came home by itself, so what sets the wpt file
  apart is not known. A real site came home on 8 October, entered by the test driver's click; a person has not
  entered and left one since (the walk's "Fullscreen and picture-in-picture").
- **The Continuity Camera and `enumerateDevices-per-origin-ids`.** Seen: with an iPhone in reach its camera's
  `deviceId` differs between a page and its same-origin frame, and the subtest fails. Inferred: that the baseline's
  pass was a run without the phone. One run with the iPhone out of reach settles it.
- **The full wpt run after the two fixes** gave Safari's 331 of 356 — on a Debug build that another session
  rebuilt while it ran, with geolocation half in. The numbers are of that tree, not of a commit.
- **`MediaStreamTrack-applyConstraints`** timed out once in that run at its second subtest and not alone
  afterwards. Not explained.
- **The window's frame** was measured in one window on the built-in display: not on a second display, not in a
  fullscreen window, not with two windows.
- **Whether the window commands hung before they were answered.** `maximizeWindowOfBrowsingContext`,
  `hideWindowOfBrowsingContext` and `setWindowFrameOfBrowsingContext` answer at once now; what they did on the
  build before was not run, so "they had nobody to ask" is the task's word and not a measurement.
- **The switch itself.** Turning automation off under a command was done through `testdriver_allow_automation`,
  which sets the same property as the toggle in Configuration; the toggle was not pressed.
- **The orange mark** was seen in a drawing of the window, dark appearance, Russian. Its help text on hover and the
  light appearance were not.
- **The guide** was edited in both languages and not built.
- **The names in [task 30](tasks/permissions/30-paste-menu-over-another-app.md)** — the three WebKit calls around
  the Paste menu — are from the binary; none was called.

## Geolocation and notifications, 8 October 2026

Both were built and measured under `SAVOIA_TESTDRIVER`, where neither system service is touched. What that leaves:

- **CoreLocation.** No position from the Mac has reached a page: the system's prompt for Savoia, a real fix, the
  `desiredAccuracy` switch, and what a page is told with Location Services off (`POSITION_UNAVAILABLE` is what the
  code sends) were not seen. One map and one press of "my location".
- **That the position repeating once a second is right outside the stand.** It was added for a stand-in position
  that never changes; whether CoreLocation on a still Mac leaves `getCurrentPosition` waiting the same way, and
  whether a real map minds a callback every second, were not watched.
- **A banner.** `UNUserNotificationCenter` was never called: the system's prompt, the banner's title, body and
  site, a click on it selecting the tab and the page hearing `click`, and a notification the system refused, are
  all untried. Mattermost, or any page with a button.
- **Two profiles that answered one site differently.** The rule — allowed anywhere is `granted` to WebKit, and the
  tab's own profile is asked again before anything is shown — was not run with two profiles.
- **A private profile** is said to be refused inside WebKit; that is from the throwaway app of September, not from
  Savoia.
- **A service worker's notification** outside wpt. Seen under the test driver: it arrives with no page and names
  its data store, and the profile is found from that. Not seen: the banner, a click, `clients.openWindow` opening
  a tab through the store's delegate — that method was never called — and a worker of a second profile.
- **The icon.** The download and the attachment were never run; nothing is posted under the test driver.
- **`instance.https.window.html` depends on what ran before it.** On a quiet stand, 8 October: three runs of
  `notifications` alone gave 221 of 369, this file's service-worker half timing out in "Service worker test setup"
  (18 of 34); one run of `permissions`, `geolocation` and `notifications` together gave 231, the file at 28 — as
  the two runs of 7 October had, and as it gives beside three neighbours. Not the store's delegate: the same with
  it off. Which file before it decides was not found. The baseline holds the 231 of the longer run. Its ten
  `notificationclose` subtests pass by a coincidence where they pass: the test's own `close()` is refused, and the
  event it waits for is the one a same-tagged notification from the next step causes.
- **Every run of 7 and 8 October reused one orphaned `wpt serve`** from an earlier session, and some overlapped
  another session's stand on the same ports. The numbers repeated across runs, so they are believed; the three
  runs above are the only ones known to be alone.
- **`MediaDevices-enumerateDevices-per-origin-ids`** gave 1/3 once and 2/3 on the next run of the same build; see
  the Continuity Camera line above.
- **The guide** was edited in both languages and not built.
- **A Release build** with the bridging header was not made.

## A page's dialogs, under a hand

**8 October 2026, dev build.** The sheets behind `alert`, `confirm`, `prompt` and the file chooser were rebuilt so
that an agent can answer them ([agent-actions.md](agent-actions.md#dialogs-and-files-the-delegates-door)).
`SAVOIA_DIALOGS_SELFTEST` presses their buttons and reads the result; these it cannot do.

- **Escape on a sheet, and any key in the prompt's field.** Posted with `NSApp.postEvent` they reach the key
  router, pass through, and the sheet does nothing: Escape on `confirm`, `prompt` and the open panel, and Return or
  a typed letter while the prompt's field has the keyboard. Return on `confirm` and `alert` does answer. Whether a
  real key does better is not known — it is the same `NSAlert` as before the change, but nobody pressed Escape on
  the old one either. One `confirm` and one `prompt` by hand settle it.
- **A file picked in the open panel by hand.** The panel's Cancel and an agent's file are measured; a person
  choosing a file and pressing Choose is not.
- **What the sheets look like.** Each step saw a sheet attached and gone afterwards, by class. Nobody saw one go up
  under an agent's click and come down on its answer, or whether that reads as a flicker.
- **A dialog in a tab that is not in front.** Its sheet takes the whole window until it is answered, as it always
  did; with an agent working in a background tab that now happens while a person reads another. Whether that is
  acceptable, or a tab under an agent should raise no sheet, is a decision and not a measurement.
- **A dialog with no window to hang a sheet on** runs `runModal`, and an agent's answer to it was not tried.


## Consent for a file

**8 October 2026, dev build, a throwaway home.** `upload_file` is asked about on every call, on the agent's card or
in the tab's bar ([agent-actions.md](agent-actions.md#who-asks-about-a-file)). `SAVOIA_UPLOAD_SELFTEST` and a bare
MCP client measured it with an agent that has no model in it; these they did not.

- **A real agent's card.** The stand's agent sends the call's arguments as the card's `rawInput` and then calls
  with the same ones, which is what lets the card's answer stand for the call. Whether Claude Code and Codex do —
  the same keys, a `window_id` they add or leave out, a path they rewrite — was not looked at. If they do not, the
  person is asked twice, on the card and then in the bar, and never less than once. One upload from the ⌘E line
  with `SAVOIA_ACP_TRACE=1` settles it.
- **Whether a real agent's card arrives with its "always" gone.** The filter drops it where the agent offers a way
  to allow once; the options a real adapter offers for an MCP tool were not read off the wire.
- **The bar under a hand.** Its buttons were pressed in code (`SitePermissions.answer`,
  `testdriver_answer_permission`) and it was drawn once to a PNG, in Russian. Nobody clicked Block or Allow.
- **A long path, and several files.** The bar was seen with one short path. Two lines truncated in the middle is
  what the code asks for; what a path of two hundred characters, or five files, looks like is not known.
- **The bar in a tab that is not in front, and with Savoia behind another app.** It waits there unseen, and the
  client's call waits with it; a client that gives up leaves the bar standing, and an Allow pressed later still
  hands the file over. Whether the tab should come forward, or the question should end with the caller, is a
  decision.
- **The selftest after the path stopped being shortened to `~`.** The app was rebuilt and the selftest was not run
  again; the change is in the bar's sentence alone.
- **The guide.** Both languages were edited and the VitePress build was not run.

## Switches set through the database, never pressed

- **The blocker's page half** (Configuration ▸ Privacy ▸ Blocking, 8 October 2026). The switch was drawn in a
  picture of the window, in Russian, in the on position; the setting itself was written between two launches. No
  one has clicked it, or looked at a page with it on and off.
- **Find on the page, the ⌘E line at a selection, the inspector's `⌥⌘I`** were each tried by Artem once on the day
  they were made and not since the move to `WKWebView`. The walk's "Switches nobody has pressed" has all three.
