# TODO

What is planned but not built. Ordered by how much it is missed, not by effort. Whatever has a brief a session can
be handed is in [tasks/](tasks/README.md), and its section here is a pointer.

## Two switches in the same corner mean two different sizes of thing

Configuration has two panes that open with a switch, and the switch reaches a different distance in each. No rule
chosen — [tasks/design/21-open-design-questions.md](tasks/design/21-open-design-questions.md).

## Help inside the app

No Help menu content and no help book: the only account of what a setting does is the guide on the site. A Help
menu and a `?` on each pane that open the guide's page for what is in front are item 6 of
[tasks/browser/13-small-things.md](tasks/browser/13-small-things.md). Offline is the open question after that: a
help book bundled with the app, or the guide's built pages shipped as resources and opened in a window of Savoia's
own.

## The ring's arrows are three keys

`⌃⇧←` / `⌃⇧→`, because macOS owns the two-key ones. No better answer found —
[tasks/design/21-open-design-questions.md](tasks/design/21-open-design-questions.md).

## Popups: what the window still lacks

A window opened with `window.open` has its opener, the page's dialogs, an answer about the camera and the
microphone, and downloads ([links.md](links.md#a-second-window)). It has no history, translation or ⌘E line. And a
call that asks nothing of the window and names an address is a tab with no opener, where Safari's tab keeps it —
a `WebPage` tab cannot. Sign in with Google through the popup was walked through by hand on Reddit; the microphone
was only refused on the stand, never granted.

## Save As: web archives

Document windows, Save As and highlights are built ([deep-research.md](deep-research.md)). What Save As still
lacks is `.webarchive` for pages: `WebPage` has no `createWebArchiveData` today, so a page saves as `.html` (its
source), `.pdf` or `.txt`. Downloads are built without `WKDownload` at all — see [links.md](links.md).

## Bookmarks: images

Nothing in a bookmark's pictures is searchable. Three steps, OCR and labels first —
[tasks/bookmarks/16-images-in-bookmarks.md](tasks/bookmarks/16-images-in-bookmarks.md).

## Extensions: the tab a content script cannot see

Hosting is built ([extensions.md](extensions.md)); the per-tab half is fixed at the API level and not re-measured end
to end. The measurement is in [tasks/measure/12-one-sitting.md](tasks/measure/12-one-sitting.md); the WebKit bug to file and
extension pages inside Savoia's interface are in [tasks/extensions/20-extensions-next.md](tasks/extensions/20-extensions-next.md).

## Someday: Savoia's own WebKit build

Two separate walls in this document are the same wall — WebKit can do the thing, the macOS SDK does not expose it:

- `WKWebExtensionTab.webView(for:)` needs a tab's `WKWebView`, and `WebPage` keeps its own private — macOS now
  answers this through a view-tree walk instead of waiting on Apple, but the walk is still a workaround for a wall
  the SDK put there in the first place ([extensions.md](extensions.md));
- there is no public way to *open* Web Inspector on your own page — the whole word "Inspector" appears in exactly
  one public header, as `WKWebView.isInspectable` — so Savoia only lets Safari attach ([devtools.md](devtools.md)).
  **This wall has a door**: `WKWebView._inspector` opens it on a tab, measured in October 2026
  ([tasks/devtools/22-web-inspector-in-savoia.md](tasks/devtools/22-web-inspector-in-savoia.md)). What stays behind
  the wall is the inspector *protocol* for an agent.

Neither is a WebKit limitation. WebKit's inspector frontend is in the open-source tree, and the GTK port hands it to
applications as ordinary public API (`webkit_web_view_get_inspector`, `webkit_web_inspector_show`). Orion has
in-window developer tools on macOS, which means either SPI or a build of its own; Playwright ships a patched WebKit
precisely to reach the inspector protocol.

So the escape hatch, if the walls ever start costing more than they are worth: **build WebKit ourselves and embed
it.** What it would buy, in the order it matters — the inspector in Savoia's own window, the inspector protocol behind
the MCP devtools tools (real network with headers and bodies, a DOM snapshot, interactions), and whatever
`WebPage` refuses to hand over, including the backing view an extension tab needs.

What it costs, so this is not written down as if it were free: hours of build time and tens of gigabytes per
revision; the WebContent XPC services to embed, sign and sandbox; the size of the app; and — the real price —
**security updates become ours**. System WebKit is patched with the OS; a private copy is patched when we get
around to it, on a browser that runs other people's JavaScript. Every macOS release is also a chance for the build
to break.

Before that, two cheaper things should be tried, in order: **file the bugs** (nothing on bugs.webkit.org mentions
`WKWebExtension` with `WebPage`, and the inspector ask is a request for parity with a port that already has it),
and watch whether Safari's own MCP server (Safari 27 / STP 247) turns out to be reachable by other apps — it is the
same capability from the other end.

## The assistant: what the three surfaces still owe

Ghost text in the field itself, and a verb of one's own —
[tasks/assistant/18-ghost-text-and-own-verbs.md](tasks/assistant/18-ghost-text-and-own-verbs.md).

## Dictation: saying it instead of typing it

Built on the Mac: a microphone beside the ⌘E line (and the agent panel's composer, which has no way in now), FluidAudio's Parakeet TDT v3 with
Silero in front of it on the Neural Engine. What is left — Apple's `SpeechAnalyzer` as the engine that downloads
nothing, a Settings section with the model's Delete, a key, the phone — is at the end of [speech.md](speech.md).

## Developer tools: what Chrome's devtools MCP has and Savoia does not

Acting on a page is built ([agent-actions.md](agent-actions.md)). Missing against Chrome's server: `hover`, `drag`,
`upload_file`, `handle_dialog`; not reachable: request bodies, throttling, traces. The comparison and the plan —
[tasks/agents/15-agent-tools-to-chrome.md](tasks/agents/15-agent-tools-to-chrome.md).

## Geolocation and notifications: WebKit's C API, one header for both

Site permissions are built ([permissions.md](permissions.md)): the camera, the microphone and the motion sensors are
asked for per site, remembered per origin and profile, and takeable back, and screen sharing works through the picker
WebKit presents by itself ([permissions.md](permissions.md#screen-sharing-which-webkit-asks-for-by-itself)).
Geolocation and notifications are still missing, and missing the same way: WebKit asks the app for permission through
a delegate, then expects the app to *supply* the thing — a position, a banner — through C functions that
`WebKit.framework` exports and the SDK does not declare.

The direction chosen (Artem, 2026-09-15) is to declare them, in a bridging header copied from WebKit's open-source
`WKGeolocationManager.h`, `WKNotificationManager.h` and `WKNotificationProvider.h`. The alternative weighed was a
JavaScript stand-in for `Notification` installed at document start: public API only, but an imitation, and no answer
for service-worker notifications.

What the two share, built once:

- **The header.** Savoia has none today. The functions — `WKContextGetGeolocationManager`,
  `WKGeolocationManagerSetProvider`, `WKGeolocationManagerProviderDidChangePosition`, `WKGeolocationPositionCreate`;
  `WKContextGetNotificationManager`, `WKNotificationManagerSetProvider`, `WKNotificationManagerProviderDidShowNotification`,
  `…DidClickNotification`, `…DidCloseNotifications`, `WKNotificationCopyTitle`, `WKNotificationCopyBody`,
  `WKNotificationGetID` — are all in WebKit's exports on this macOS (`dyld_info -exports`). The provider structs are
  versioned (`WKGeolocationProviderV1`, `WKNotificationProviderV0`), and a layout that no longer matches is a crash
  rather than a compile error, so the header pins one version.
- **The `WKContextRef`.** Both managers hang off the process pool `WebPage` built: `configuration.processPool` of the
  `WKWebView` that `WebViewResponder` finds. How that object becomes a `WKContextRef` from Swift is the first unproven
  step.
- **The delegate proxy.** Both permission questions are `WKUIDelegate` methods, answered in front of `WebPage`'s own
  adapter by the forwarding proxy from `e64dd24`, with its two lessons: the selector built from its string, and the
  proxy retained somewhere, because `uiDelegate` is weak. Forwarding everything else was verified — `confirm()` and
  the microphone still reached the adapter.

**Geolocation.** The permission hook is public (`requestGeolocationPermissionFor:initiatedBy:`, macOS 27); the
provider is not. Savoia would run `CLLocationManager` itself — `NSLocationWhenInUseUsageDescription` is already in the
Info.plist — and hand WebKit positions. Without a provider "Allow" led to a page that waited forever
([permissions.md](permissions.md#what-a-webpage-browser-still-cannot-ask-for)). First step: a position arriving in a
page at all.

**Notifications.** Measured on 2026-09-15 in a throwaway app, not in Savoia:

- `Notification.requestPermission()` is refused inside WebCore, before anyone is asked, unless it runs in a user
  gesture and a secure context. A script run over `Savoia --mcp` is not a gesture, which is why an early check from Savoia
  read `denied` in 3 ms and proved nothing about the delegate.
- A non-persistent data store — what Savoia's private profiles use — is refused in `WebNotificationClient` before the
  delegate too (`sessionID().isEphemeral()`). Private profiles would stay without notifications, as in Safari.
- With a persistent store, made the way Savoia makes its other profiles, and a real click, the private delegate method
  `_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:` was called, answered yes, and the page got
  `granted`. `new Notification()` then reached the UI process (`showNotification called` in the log) and went no
  further: no provider, no banner, no `onshow`.
- `BuiltInNotificationsEnabled`, the feature flag that looks like WebKit showing them itself, sends both permission and
  display to `webpushd` through the network process: `requestPermission failed: no active connection to webpushd`,
  refused in 0 ms, with the data store's `webPushMachServiceName` set.

The provider would post through `UserNotifications` (a system prompt of its own, once for the app), report shows and
clicks back to WebKit, and answer `notificationPermissions` from `SitePermissions`. Service-worker notifications come
through the same provider marked persistent, but their clicks go to `WKWebsiteDataStore` SPI — later, not first.

**Web Push** is out of reach rather than undocumented: `webpushd` checks the private entitlement
`com.apple.private.webkit.webpush` before serving a client, and Apple does not hand it out.

Savoia is not sandboxed and not on the App Store, so undeclared API carries no review risk here — only the ordinary one,
that it changes in a macOS update.

## Apple Pay: not supported, and why is not known

A page in Savoia has no `PaymentRequest` and no `ApplePaySession` — both are `undefined`, so a shop's Apple Pay
button is absent or dead, and the six wpt files `permissions-policy/payment-*` and `reporting/payment-reporting`
differ from Safari for that reason. Measured in October 2026 on an https page, with and without the blocker's page
scripts (`AdvancedRules`), so those are not the cause.

What the cause is was not established, and the investigation was dropped rather than finished. It is not the
region of the Apple ID, where Apple Pay does not work at all: Safari 27.2 on the same Mac answers
`typeof PaymentRequest` with `"function"` (Artem, by hand). So it is something about Savoia as an app — a limit
WebKit puts on one that is not Safari, or the user scripts Savoia still installs. A twenty-five-line app with a
bare `WKWebView` and no user script tells those two apart.

## Blocking: cosmetic rules inside a frame

[Advanced blocking](blocking.md#the-advanced-rules-what-runs-inside-the-page) is main frame only, and the reason is
structural rather than lazy. A `WKUserScript`'s source is fixed when it is installed on the content controller,
which happens before the load starts; the rules that apply to a subframe are the ones for the *subframe's own*
address, and that is not known until the frame loads. Giving a third-party frame the top document's cosmetic rules
would hide things inside it for no reason, so it is given none. What blocks inside a frame today is the network
half, which is per-request and needs nobody's help — so what is missing is scriptlets and extended CSS in frames,
which is where a certain kind of ad iframe lives.

Three ways it could be closed, none of them free:

- **Ask, then apply.** Inject one small script into every frame (`forMainFrameOnly: false`) that posts its own URL
  to a `WKScriptMessageHandler`, and have Swift answer with that frame's rules. Cheap and correct for CSS — a frame's
  cosmetics can arrive a moment late and still work. Useless for **scriptlets**, which have to patch a global before
  the frame's own scripts run, and a round trip through the main actor is not before.
- **Ship the lookup to the page.** Inject the engine's answers for every domain the page might frame — which is the
  whole index — or the engine itself as JavaScript. AdGuard's own extension does the second, in a background script;
  Savoia would be paying 350 KB and a build of the index per frame.
- **A `WKURLSchemeHandler`-shaped proxy**, or the Web Inspector protocol, so the rules could be applied to a frame's
  document before it is parsed. Both are the [own-WebKit-build](#someday-savoias-own-webkit-build) conversation.

The first is the only cheap one and it buys the smaller half. Worth doing when a real page is found where the frames
are the problem; not worth guessing at before that.

## Picture-in-picture — the window half

Video PiP is built ([layout.md](layout.md#picture-in-picture)). Any tab as a small always-on-top window is not —
[tasks/browser/17-floating-window.md](tasks/browser/17-floating-window.md).

## Passkeys and passwords

Sign in with a passkey (or a saved password) on any site, through the system UI. WebAuthn inside a third-party
`WKWebView` is gated by Apple's browser entitlements, so this is as much a paperwork task as a coding one. The plan,
the fallbacks and what to verify first are in [passkeys.md](passkeys.md). **Next up.**

## Sync through CloudKit — history first

History on every Mac (and later everything else that is a plain record: profiles, highlights, documents). Private
database, `CKSyncEngine`, one record per visit — visits are immutable, so there is nothing to merge. Design, limits
and what CloudKit can and cannot carry (vectors included) in [sync.md](sync.md). The store is ready for it — see the sync
columns under Storage below.

## Storage: history pages and retrieval

SQLite is the system of record, built. Search over visited pages, not only saved ones, is not —
[tasks/storage/19-history-pages.md](tasks/storage/19-history-pages.md), which also carries the state of the store and what
was rejected.

## Tab groups by meaning: a classifier instead of cosines

`TabSorter` measures e5 cosines and asks for a lead, which leaves a tab whose title says little where it is and keeps
Russian titles out of English topics. The other shape is a classifier asked the question outright —
"which of these groups is this tab about, or none" — which is what jev / laya-browser are (a 322M "System 1" that
answers multiple-choice questions over `/v1/systemone`, tried for page actions on `origin/agent-actions`,
docs/agent-actions.md there). The options would be the group names plus "none"; the fit to try is whether its
confidence is calibrated enough to replace `joins` and `tie`, and what 0.35–1.3 s per tab on MPS costs when tabs
arrive in bursts. The same question asked of a local instruct model is built (**Sort By ▸ Local Model**,
docs/layout.md): Gemma 4 E2B places tabs better than the embeddings but at 5.6 s and 3.6 GB a tab on 8 GB, and
never answered "between". An ACP agent names groups through its own errand sessions (`AgentErrands`), but does not
place tabs yet.

## WebMCP: the nine wpt tests left

165 of 174 of wpt's `webmcp/` pass (`scripts/webmcp-wpt.py`, the baseline beside it). The nine left, and what each
would take — none of it is a polyfill's to do ([webmcp.md](webmcp.md#not-built)):

- **An opened window (2).** `window.open` returns a window now ([links.md](links.md#a-second-window)), in a
  `WKWebView` of its own. Not re-run since: whether the polyfill is installed in that view, and whether the broker
  knows it belongs to another frame tree, is the open part.
- **`document.domain` (4).** The draft refuses the API where `document.domain` is enabled, and WebKit has no
  origin-keyed agent clusters, so the rule read literally refuses everything. Waits for WebKit to ship
  `Origin-Agent-Cluster` by default, or for the draft to phrase the rule so it has meaning there.
- **`isTrusted` on `toolactivated` (1).** Only an event the engine dispatches is trusted. Native WebMCP in WebKit, or
  Savoia's own WebKit build ([Someday](#someday-savoias-own-webkit-build)).
- **An iframe's initial `about:blank` when the iframe has a `src` (1).** WebKit runs no user script there, and the
  page reaches the document before it navigates. The parent's polyfill could install one into a same-origin child it
  sees created; wpt's own comment says Chrome fails this one too, so it waits for the test to settle.
- **Styling by `:tool-form-active` (1).** WebKit's CSS parser drops a rule with a pseudo-class it does not know.
  Engine work again.

Re-run the suite when wpt moves (`--update`): the declarative section of the draft is still TODO, and its tests are
where the next changes will land.

## Smaller things

- A window whose address *is* a download re-downloads it on every launch. Nothing was committed in it, so the
  window comes back pointed at the attachment and asks for it again; `closeIfOnlyCarriedALink` only closes the
  window a link opened, not the one somebody typed the address into. Harmless until this session, easy to see now
  that an unfinished download survives a relaunch.
- Deep research without an agent: a native loop over the ⌘E model for machines with no Claude Code / Codex, and
  exporting a run as one HTML file with its sources inlined ([deep-research.md](deep-research.md)).
- A way back to the start page after navigating (a "home" affordance, or `⌘⇧H`).
- Forget one site: drop a single host's cookies and storage (`WKWebsiteDataStore.fetchDataRecords` →
  `remove(ofTypes:for:)`). Clearing a whole profile is the only option today, and it takes every login with it.
- Per-site user-agent overrides through `WebPage.customUserAgent`, for sites that sniff wrongly even at Safari's
  string.
- **The one warning left in `scripts/dmg.sh`.** `appintentsmetadataprocessor: Metadata extraction skipped, no
  AppIntents.framework dependency found` comes from Xcode's own build phase, once per build; the app has no App
  Intents, so it is harmless. It goes away if Savoia gets any (Shortcuts actions for open-tab and search would be the
  natural ones), and not before.
