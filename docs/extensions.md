# Extensions: what a `WebPage` browser can host

six hosts browser extensions on `WKWebExtension` (public API since macOS 15.4): a `WKWebExtensionController` goes
into `WebPage.Configuration.webExtensionController`, a `WKWebExtensionContext` per extension, and the app answers
for its tabs and windows through `WKWebExtensionTab` / `WKWebExtensionWindow`.

**`WKWebExtensionTab.webView(for:)`, on macOS, answers now.** It wants the live `WKWebView` behind a tab, and
`WebPage` hands out none of its own — but `WebViewResponder` already had one on file per tab, for keyboard focus
(⌥→ moving the rail's selection without AppKit's first responder following it). Found by walking the rendered view
tree for `is WKWebView` and matched by frame containment, not by `Mirror`-ing into `WebPage`'s private storage — a
different and sturdier bet than the one this page used to reject outright, and confirmed on the wire: `webView(for:)`
is now called repeatedly by WebKit itself and answers with the right tab's `WKWebView`, at the right URL, where it
always answered `nil` before. The phone has no equivalent view-tree walk yet, so it still answers `nil` there.

**What that closes is not yet re-measured.** The table below is the state *before* this fix, and a fresh MV3 test
extension built to re-run it hit a wall one step short of the tables' own tests — `content_scripts` never fired in
this environment for a reason that looks environmental rather than about `webView(for:)` (content-script injection
is WebKit's own static match against a manifest and never calls this method at all), but it means the specific
"works now" claims below are a prediction from what `webView(for:)` returning correctly implies, not yet a
measurement with the same rigor as the rest of this page. Whoever re-runs it: confirm `runtime.sendMessage` /
`tabs.sendMessage` / `scripting.executeScript` / `scripting.insertCSS` and uBlock Origin Lite's per-tab logic again,
each on its own, before moving this out of "believed fixed."

**Install** from **Extensions › Manage Extensions…**: a folder, a `.zip`, a `.crx` or an `.xpi`. Before anything
runs, the dialog says what the extension is, what it will be granted, and — from its manifest alone — what will not
work in six. The panel keeps that verdict on the row afterwards.

```
InstalledExtension   what is installed and what the user decided about it (+ the compatibility verdict)
ExtensionInstaller   folder / .zip / .crx / .xpi → an unpacked folder; the verdict, from the manifest
ExtensionStore       a controller per profile, a context per extension, actions, permission prompts
ExtensionAdapters    a column as WKWebExtensionTab, a profile's strip as WKWebExtensionWindow
```

`SIX_EXTENSION=/path/to/unpacked` installs one at launch with no dialog, for development.

## What works, measured

| surface | result |
|---|---|
| loading an unpacked extension (`WKWebExtension(resourceBaseURL:)`) | works; manifest, icons, permissions and capability flags all readable **before** loading |
| background (`service_worker` and a `scripts` module page) | starts, runs, `browser.*` namespace present |
| `storage.local` | works, from the background and from a content script |
| `alarms` | works (a 0.5 min alarm fired) |
| `tabs.query` | works — sees six's columns with their URLs and titles, through the adapters |
| `tabs.onUpdated` | works, *once the app reports changes* — `didChangeTabProperties(.URL/.title/.loading)` from the navigation stream |
| `cookies` | present and answers |
| **content scripts declared in the manifest** | **run** — `document_start`, DOM touched, `browser.*` available inside them |
| **`scripting.registerContentScripts`** | **works** — dynamically registered scripts run in pages |
| **`declarativeNetRequest`** | **blocks** — subresources *and* main-frame navigations, static rulesets and dynamic rules alike, including rules conditioned on `initiatorDomains`, `excludedInitiatorDomains` and `requestDomains` |
| action popup | works — WebKit hands over its own `NSPopover` (and a live `WKWebView` on `webkit-extension://…/popup.html`), which six points at the toolbar button that was clicked |
| permissions | granted programmatically, or through `promptForPermissions` on the delegate |

## What does not work, and why it is all one thing

| surface | result |
|---|---|
| `runtime.sendMessage` **from a content script** | `Invalid call to runtime.sendMessage(). Tab not found.` |
| `tabs.sendMessage` **to a content script** | silently delivers nothing |
| `scripting.executeScript` | `Could not execute script on this tab.` |
| `scripting.insertCSS` | `Could not inject stylesheet on this tab.` |
| `declarativeNetRequest.onRuleMatchedDebug` | not implemented by WebKit at all — not six's gap |

Every failure but the last is the same failure: **WebKit cannot map a frame back to a tab without the tab's web
view**. So content scripts run, but they are *deaf* — they cannot talk to their own background, and the background
cannot reach into them or inject anything new.

That is a sharper line than "content injection does not work". An extension whose content script is self-contained
(a stylesheet, a scriptlet carrying its own data, anything that acts on the DOM and reports to nobody) works. An
extension whose content script is a client of its background — which is most of them — does not.

## uBlock Origin Lite

The interesting case, since it is the MV3 ad blocker and it ships a **Safari** build meant for exactly this API.
Loaded into six it starts, enables its rule sets (`ublock-filters`, `easylist`, `easyprivacy`, `rus-0`), reports
`hasBroadHostPermissions: true`, produces no context errors — **and blocks nothing.**

What was ruled out, one at a time: rule-set enablement (they are enabled), permissions (`<all_urls>` granted,
`permissions.getAll()` confirms), compile errors (`WKWebExtensionContext.errors` stays empty after the rule sets
load), WebKit's own DNR (a controlled extension blocks with every rule flavour uBOL uses), rule limits (WebKit
allows 50 enabled rule sets and 30 000 dynamic rules; uBOL enables four and adds none), and scale (disabling all its
static rule sets does not make a fresh dynamic rule work either).

What is left is uBOL's own per-tab logic: its filtering mode is decided per site and per tab, and its popup renders
empty in six — the same symptom as everything else in the table above. Best read: **uBOL cannot see a tab, so it
filters nothing.**

So the answer to "can six's ad blocking be an extension" is, today, *no* — which is why blocking is native
(see [blocking.md](blocking.md)) and does not depend on any of this. uBOL installs and shows its verdict like any
other extension; it simply does not block.

## How it is put together

- **A controller per profile.** A profile is an isolated `WKWebsiteDataStore`; its extensions get storage of their
  own the same way, through a persistent `WKWebExtensionController.Configuration(identifier:)` keyed by the
  profile's store id. The context's `uniqueIdentifier` is the installed extension's id, which is what makes an
  extension's storage survive a relaunch.
- **A private profile runs no extensions at all** — private browsing is recorded nowhere, and an extension's
  storage is a record.
- **A tab is a column, a window is a profile's strip.** The adapters read the *window* — `tab.currentURL`,
  `tab.title` — never its page, because asking `BrowserTab` for a page builds one, and an extension listing tabs
  must not wake a hundred discarded windows. Workspaces are not separate windows; when something actually needs to
  move a tab between windows, that is the moment to map them onto workspaces.
- **The browser tells the extensions what happened.** WebKit does not watch the app's model: `didOpenTab`,
  `didCloseTab`, `didActivateTab` and `didChangeTabProperties` are called from `BrowserState` and from the
  navigation stream — without the last one, `tabs.onUpdated` never fires.
- **Installing or enabling one rebuilds the live pages.** A page's configuration is fixed when the page is built,
  so a window opened before an extension arrived would never see it (`BrowserState.rebuildLivePages`, the same
  discard-and-build-again the memory budget uses).
- **Permissions** are granted at install, where the dialog listed them; anything asked for later goes through
  `promptForPermissions` and asks. Actions are buttons in the top bar, and the popup is WebKit's own `NSPopover`
  pointed at the button that was clicked.

## Commands: an extension's own shortcuts

`commands` in a manifest — Focus Mode's ⌘B — cannot be a static menu item the way six's own `⌘` keys are
(`ViewCommands` and the rest): nobody knows the shortcut until the extension is installed. So it goes through
`KeyRouter` instead, the monitor that already sees a key before the focused page can, tried only once the `⌥`/`⌃`
table has declined it — which every `⌘` chord always does, since the table holds none.

`WKWebExtensionContext.performCommand(for:)` is tried first, and is not enough by itself: it answers by the
character the event carries, and a Russian layout's ⌘B reports «И» — the same bug `KeyBindings.Key.letter` exists
to answer for six's own bindings ([hotkeys.md](hotkeys.md)), here on WebKit's side of the fence. When that method
declines, `ExtensionStore.performCommand(for:in:)` checks each of the extension's `commands` again itself, this
time by the event's physical key code against a small US-ANSI letter table — the same "code or character" shape,
independently arrived at for a type six does not otherwise touch.

## To revisit

The whole "does not work" table was one missing method, and macOS now answers it — see above, and re-measure before
trusting the table below. Two routes stayed out on purpose even so:

1. **Apple exposes the backing view** (or a way to associate a `WebPage` with a `WKWebExtensionTab`), which would
   make `WebViewResponder`'s workaround unnecessary rather than merely working. `WebPage` already exposes
   `isInspectable`, so there is precedent for lifting something that lives on `WKWebView` up to the new API. Nothing
   about this exists on bugs.webkit.org today — a search for `WKWebExtension` + `WebPage` finds nothing at all — so
   the useful move is to file it, with the measurements in this document as the case.
2. **`Mirror`-ing into `WebPage`'s private storage** — verified to work on this SDK, and still deliberately not
   used, unlike the view-tree walk above. The two are not the same bet: a property Apple renames or restructures
   next OS is invisible to the type checker and this fails silently, where the view-tree walk fails by finding
   nothing (a `nil` `webView(for:)`, the same answer as before the fix) rather than finding the wrong thing.
3. **A `WKWebView` per tab**, which is what every other WebKit browser with extension support does — and which is
   exactly the thing six exists not to do.
4. **A WebKit build of six's own**, which would also close the devtools wall and costs accordingly — the price is
   written down in [todo.md](todo.md#someday-sixs-own-webkit-build).

## Installing from a file

`WKWebExtension` takes only `resourceBaseURL:` — an unpacked folder. So the install paths are a folder, a `.zip`, a
`.crx` (a zip behind a header) or an `.xpi` (a zip), unpacked into `Application Support/org.deffun.six/Extensions/<id>/`.
Extensions from the App Store cannot be adopted: those are app extensions belonging to their own host apps, and
`WKWebExtension(appExtensionBundle:)` is for an extension shipped *inside* six. Nothing verifies a `.crx`
signature, which the install dialog should say in as many words.
