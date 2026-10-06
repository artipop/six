# Extensions: what Savoia can host

Savoia hosts browser extensions on `WKWebExtension` (public API since macOS 15.4): a `WKWebExtensionController` goes
into each tab's `WKWebViewConfiguration.webExtensionController`, a `WKWebExtensionContext` per extension, and the app answers
for its tabs and windows through `WKWebExtensionTab` / `WKWebExtensionWindow`.

**`WKWebExtensionTab.webView(for:)` answers with the tab's own view.** A tab is a `WKWebView` Savoia creates
([architecture.md](architecture.md#from-webpage-to-wkwebview)), so the answer is `tab.livePage`, whether or not the
tab has been on screen. When a tab was SwiftUI's `WebPage`, which hands out no view, the method answered `nil`, and
then with a view found by searching the window; both are history.

**What that closes is not yet re-measured.** The table below is the state from when the method answered `nil`, and a fresh MV3 test
extension built to re-run it hit a wall one step short of the tables' own tests — `content_scripts` never fired in
this environment for a reason that looks environmental rather than about `webView(for:)` (content-script injection
is WebKit's own static match against a manifest and never calls this method at all), but it means the specific
"works now" claims below are a prediction from what `webView(for:)` returning correctly implies, not yet a
measurement with the same rigor as the rest of this page. Whoever re-runs it: confirm `runtime.sendMessage` /
`tabs.sendMessage` / `scripting.executeScript` / `scripting.insertCSS` and uBlock Origin Lite's per-tab logic again,
each on its own, before moving this out of "believed fixed." What each of those runs would have to show, and the
one reading that already disagrees with this page — uBOL scoring 96/100 on a request-counting test with Savoia's own
blocking switched off — are in [unmeasured.md](unmeasured.md).

**Install** from **Extensions › Manage Extensions…**: a folder, a `.zip`, a `.crx` or an `.xpi`. Before anything
runs, the dialog says what the extension is, what it will be granted, and — from its manifest alone — what will not
work in Savoia. The panel keeps that verdict on the row afterwards.

```
InstalledExtension   what is installed and what the user decided about it (+ the compatibility verdict)
ExtensionInstaller   folder / .zip / .crx / .xpi → an unpacked folder; the verdict, from the manifest
ExtensionStore       a controller per profile, a context per extension, actions, permission prompts
ExtensionAdapters    a column as WKWebExtensionTab, a profile's strip as WKWebExtensionWindow
```

`SAVOIA_EXTENSION=/path/to/unpacked` installs one at launch with no dialog, for development.
`SAVOIA_EXTENSION_TESTING=1` gives extensions WebKit's `browser.test` — [below](#compatibility-web-platform-tests).

## What works, measured

| surface | result |
|---|---|
| loading an unpacked extension (`WKWebExtension(resourceBaseURL:)`) | works; manifest, icons, permissions and capability flags all readable **before** loading |
| background (`service_worker` and a `scripts` module page) | starts, runs, `browser.*` namespace present |
| `storage.local` | works, from the background and from a content script |
| `alarms` | works (a 0.5 min alarm fired) |
| `tabs.query` | works — sees Savoia's columns with their URLs and titles, through the adapters |
| `tabs.onUpdated` | works, *once the app reports changes* — `didChangeTabProperties(.URL/.title/.loading)` from the navigation stream |
| `cookies` | present and answers |
| **content scripts declared in the manifest** | **run** — `document_start`, DOM touched, `browser.*` available inside them |
| **`scripting.registerContentScripts`** | **works** — dynamically registered scripts run in pages |
| **`declarativeNetRequest`** | **blocks** — subresources *and* main-frame navigations, static rulesets and dynamic rules alike, including rules conditioned on `initiatorDomains`, `excludedInitiatorDomains` and `requestDomains` |
| action popup | works — WebKit hands over its own `NSPopover` (and a live `WKWebView` on `webkit-extension://…/popup.html`), which Savoia points at the toolbar button that was clicked, through that button's own AppKit view |
| extension pages (options, dashboards, `tabs.create` of its own pages, the new-tab override) | **tabs** — see below |
| permissions | granted programmatically, or through `promptForPermissions` on the delegate |

### Extension pages are tabs

WebKit loads an extension's page as a main frame only into a web view whose configuration names that extension
(`requiredWebExtensionBaseURL`, checked in its `WebExtensionURLSchemeHandler`); anywhere else the load fails with
`NSURLErrorResourceUnavailable` (-1008), which is what uBlock Origin Lite's dashboard showed as "the page did not
open". The configuration that names it is `WKWebExtensionContext.webViewConfiguration`.

A tab asks for it: `ExtensionStore.pageConfiguration(for:profileID:)` answers for an address under an extension's
base, and `BrowserTab.materialize` builds the view on that configuration and leaves it as WebKit made it. A
configuration is fixed when a view is made, so `load()` into or out of an extension's page gives the tab another
view. `openOptionsPage`, "Open Options Page" in the Extensions list, `tabs.create` — which now answers with the tab —
and the new-tab override all end in `newTab(url:)`.

Two things a tab needs that a throwaway window did not:

- **The base address is the same on every launch.** WebKit's default is `webkit-extension://<a fresh UUID>`, so a
  restored tab pointed at nothing. Savoia sets `baseURL` to `webkit-extension://<the extension's id>`. An
  extension page's own storage keeps its origin across launches for the same reason.
- **A tab restored in front is built before its extension has loaded**, on a plain configuration, and fails with
  -1008. When the extension has loaded, `BrowserTab.extensionLoaded` builds such a tab again.

Seen with a throwaway extension in a throwaway home: the page its background opened with `tabs.create` is a tab,
loads, has `browser.runtime`, and loads again after the page budget took it and after a relaunch — behind, and in
front, where the log shows the first attempt's -1008 before the rebuild. The options page and the new-tab override
were not opened. When these pages were windows, uBOL Lite's dashboard loaded and its background answered
`getOptionsPageData`; that has not been repeated in a tab.

### Each profile's copy of an extension sees only its own tabs

Every profile has a controller of its own, and each loads its own copy of every extension. The delegate used to
work out a context's profile by looking the context up among the loaded ones and, failing that, taking the
selected profile. A context is filed only once `controller.load` returns, and WebKit asks for its windows *during*
`load` — so the second profile's copy was handed the first profile's window and tabs, and WebKit kept them. From
then on it logged `web view … returned by webViewForWebExtensionContext: is not configured with the same
WKWebExtensionController as extension context` in bursts, at every load and roughly every ten minutes after, when
uBOL walked its tabs.

The delegate now asks which runtime owns the `controller` it was called with, which is exact from the first call;
and `ExtensionTabAdapter.webView(for:)` hands WebKit a view only when its configuration carries the context's own
controller. Measured: under the same conditions that logged the bursts before (a web page restored and claimed
before the extensions load, two profiles), none. Two other WebKit messages remain and predate this: a
`WKWebExtension.Error` 6 (invalid manifest entry) at every launch, once per profile, and an occasional "array
returned by tabsForWebExtensionContext: does not contain the active tab". Savoia writes each extension's
`WKWebExtensionContext.errors` to its own log now (`[extensions] <name> reports …`), so which extension a recorded
error belongs to is no longer a guess.

## Compatibility: web-platform-tests

wpt's [`web-extensions/`](https://github.com/web-platform-tests/wpt/tree/master/web-extensions) is six test
extensions, 44 tests. `scripts/web-extensions-wpt.py` runs them unmodified and compares with
`scripts/web-extensions-wpt-baseline.json`; it needs no running Savoia and does not touch the dev build's state,
because each extension gets a launch of its own in a throwaway home (`CFFIXED_USER_HOME`).

| extension | Savoia | Safari 27.0 | Safari TP 253 | Chrome 157 | Firefox 159 |
|---|---|---|---|---|---|
| `runtime` | 4/6 | 4/6 | 4/6 | 6/6 | 4/6 |
| `storage` | 8/10 | 8/10 | 10/10 | 10/10 | 8/10 |
| `alarms` | 5/8 | 5/8 | 7/8 | 7/8 | 6/8 |
| `idle` | 2/5 | 2/5 | 2/5 | 5/5 | 5/5 |
| `bookmarks` | 1/7 | 1/7 | 1/7 | 7/7 | 6/7 |
| `browsingData` | 1/8 | 1/8 | 1/8 | 8/8 | 8/8 |
| | **21/44** | 21/44 | 25/44 | 43/44 | 37/44 |

Measured 2026-10-04 on macOS 27.2 against wpt `1d99362`; the other columns are wpt.fyi's runs of 2–3 October.
Savoia equals the Safari of the same system file by file, so every failure is inside WebKit's `browser.*` and none
is Savoia's to fix: `browser.idle`, `browser.bookmarks` and `browser.browsingData` do not exist (the one or two
tests that pass in each are the ones any exception satisfies), `runtime.onEnabled` and `runtime.onExtensionLoaded`
are missing, `storage.<area>.setAccessLevel` is missing, `alarms.clear()` resolves to nothing instead of `true`,
and `alarms.create()` neither takes an options-only call nor returns a promise. Technology Preview already passes
`setAccessLevel` and two more of `alarms`, so those arrive with a system update — a run that prints `NEW PASS` is
how it will be noticed ([api-watch.md](api-watch.md)).

`browser.test` exists only in WebKit's testing mode, which is SPI: `SAVOIA_EXTENSION_TESTING=1` sets
`_testingMode` on every controller and `ExtensionTesting.swift` answers the private delegate methods WebKit then
calls, writing each as `[extensions] test {…}` in the log. Without the variable nothing is set and nothing calls
them. On wpt.fyi the same tests reach Safari through `safaridriver`: the test page calls
`test_driver.install_web_extension`, which is WebDriver's `POST /session/{id}/webextension`, and listens to
`browser.test.onTestStarted` / `onTestFinished`. The script skips the page — an extension loaded in testing mode
starts its tests by itself.

Outside testing mode WebKit holds every alarm for at least 30 seconds: one created with `when: now + 1 s` fired at
30.0 s, where the same test passes in testing mode within a second or two.

## What does not work, and why it is all one thing

| surface | result |
|---|---|
| `runtime.sendMessage` **from a content script** | `Invalid call to runtime.sendMessage(). Tab not found.` |
| `tabs.sendMessage` **to a content script** | silently delivers nothing |
| `scripting.executeScript` | `Could not execute script on this tab.` |
| `scripting.insertCSS` | `Could not inject stylesheet on this tab.` |
| `declarativeNetRequest.onRuleMatchedDebug` | not implemented by WebKit at all — not Savoia's gap |

Every failure but the last is the same failure: **WebKit cannot map a frame back to a tab without the tab's web
view**. So content scripts run, but they are *deaf* — they cannot talk to their own background, and the background
cannot reach into them or inject anything new.

That is a sharper line than "content injection does not work". An extension whose content script is self-contained
(a stylesheet, a scriptlet carrying its own data, anything that acts on the DOM and reports to nobody) works. An
extension whose content script is a client of its background — which is most of them — does not.

## uBlock Origin Lite

The interesting case, since it is the MV3 ad blocker and it ships a **Safari** build meant for exactly this API.
Loaded into Savoia it starts, enables its rule sets (`ublock-filters`, `easylist`, `easyprivacy`, `rus-0`), reports
`hasBroadHostPermissions: true`, produces no context errors — **and blocks nothing.**

What was ruled out, one at a time: rule-set enablement (they are enabled), permissions (`<all_urls>` granted,
`permissions.getAll()` confirms), compile errors (`WKWebExtensionContext.errors` stays empty after the rule sets
load), WebKit's own DNR (a controlled extension blocks with every rule flavour uBOL uses), rule limits (WebKit
allows 50 enabled rule sets and 30 000 dynamic rules; uBOL enables four and adds none), and scale (disabling all its
static rule sets does not make a fresh dynamic rule work either).

What is left is uBOL's own per-tab logic: its filtering mode is decided per site and per tab, and its popup renders
empty in Savoia — the same symptom as everything else in the table above. Best read: **uBOL cannot see a tab, so it
filters nothing.**

So the answer to "can Savoia's ad blocking be an extension" is, today, *no* — which is why blocking is native
(see [blocking.md](blocking.md)) and does not depend on any of this. uBOL installs and shows its verdict like any
other extension; it simply does not block.

## How it is put together

- **A controller per profile.** A profile is an isolated `WKWebsiteDataStore`; its extensions get storage of their
  own the same way, through a persistent `WKWebExtensionController.Configuration(identifier:)` keyed by the
  profile's store id. The context's `uniqueIdentifier` is the installed extension's id, which is what makes an
  extension's storage survive a relaunch.
- **The context's `baseURL` is left to WebKit**, a new random `webkit-extension://` host on every launch. Fixing it
  was tried, because that host is inside the translated `declarativeNetRequest` rules whose hash decides whether the
  compiled list on disk is reused, and so it never is. It does not help: uBlock Origin Lite loads one rule set
  (104 MB compiled) and changes it to another (132 MB) a few seconds later, WebKit keeps one compiled file and one
  hash, and with a stable host the two loads overlap — every other launch ended on the smaller list and never built
  the larger, where a random host always ends on the larger. Two compilations per profile per launch are what
  correct costs until WebKit caches more than one list.
- **A profile's extensions load when the profile is first looked at**, not at launch: `start()` brings up the
  profile of the selected tab, and another one follows with its first page or when one of its tabs is selected. A
  rule-set extension costs tens of seconds of CPU per profile to load (WebKit translates and compiles its
  `declarativeNetRequest` rules again on every launch), and three profiles paid that at once. The price is that an
  extension's background content does not run in a profile nobody has opened since launch.
- **What nothing else deletes is swept at launch** (`ExtensionLeftovers`, off the main actor). WebKit keeps an
  extension's storage under `~/Library/WebKit/<bundle id>/WebExtensions/<profile's store id>/<extension id>` and
  never removes it: not when the profile is deleted, not when the extension is, and a rule list being compiled when
  Savoia quits stays behind as a `ContentRuleListXXXXXX` of 30–130 MB. The sweep removes the folders of store ids
  no profile has, of extension ids not installed, those unfinished files older than this launch, and unpacked
  extensions that are no longer installed. Two guards, because a failed read looks the same as nothing being there:
  it does nothing when no extension is installed, and leaves WebKit's folder alone unless at least one folder in it
  answers to a current profile. Uninstalling an extension removes its storage in every profile there and then, so
  the first guard does not strand the last extension's data.
- **A private profile runs no extensions at all** — private browsing is recorded nowhere, and an extension's
  storage is a record.
- **A tab is a column, a window is a profile's strip.** The adapters read the *window* — `tab.currentURL`,
  `tab.title` — never its page, because asking `BrowserTab` for a page builds one, and an extension listing tabs
  must not wake a hundred discarded windows. Workspaces are not separate windows; when something actually needs to
  move a tab between windows, that is the moment to map them onto workspaces.
- **The browser tells the extensions what happened.** WebKit does not watch the app's model: `didOpenTab`,
  `didCloseTab`, `didActivateTab` and `didChangeTabProperties` are called from `BrowserState` and from what the
  tab's navigation delegate reports — without the last one, `tabs.onUpdated` never fires.
- **Installing or enabling one rebuilds the live pages.** A page's configuration is fixed when the page is built,
  so a window opened before an extension arrived would never see it (`BrowserState.rebuildLivePages`, the same
  discard-and-build-again the memory budget uses).
- **Permissions** are granted at install, where the dialog listed them; anything asked for later goes through
  `promptForPermissions` and asks. Actions are buttons in the top bar, and the popup is WebKit's own `NSPopover`
  pointed at the button that was clicked.

## Commands: an extension's own shortcuts

`commands` in a manifest — Focus Mode's ⌘B — cannot be a static menu item the way Savoia's own `⌘` keys are
(`ViewCommands` and the rest): nobody knows the shortcut until the extension is installed. So it goes through
`KeyRouter` instead, the monitor that already sees a key before the focused page can, tried only once the `⌥`/`⌃`
table has declined it — which every `⌘` chord always does, since the table holds none.

`WKWebExtensionContext.performCommand(for:)` is tried first, and is not enough by itself: it answers by the
character the event carries, and a Russian layout's ⌘B reports «И» — the same bug `KeyBindings.Key.letter` exists
to answer for Savoia's own bindings ([hotkeys.md](hotkeys.md)), here on WebKit's side of the fence. When that method
declines, `ExtensionStore.performCommand(for:in:)` checks each of the extension's `commands` again itself, this
time by the event's physical key code against a small US-ANSI letter table — the same "code or character" shape,
independently arrived at for a type Savoia does not otherwise touch.

## To revisit

The whole "does not work" table was one missing method, and a tab answers it with its own view now — re-measure
before trusting the table below ([tasks/measure/12](tasks/measure/12-one-sitting.md)). A `WKWebView` per tab is what
every other WebKit browser with extension support does, and since October 2026 what Savoia does. A WebKit build of
Savoia's own stays ruled out: system WebKit, used as far as it goes.

## Installing from a file

`WKWebExtension` takes only `resourceBaseURL:` — an unpacked folder. So the install paths are a folder, a `.zip`, a
`.crx` (a zip behind a header) or an `.xpi` (a zip), unpacked into `Application Support/org.deffun.savoia/Extensions/<id>/`.
Extensions from the App Store cannot be adopted: those are app extensions belonging to their own host apps, and
`WKWebExtension(appExtensionBundle:)` is for an extension shipped *inside* Savoia. Nothing verifies a `.crx`
signature, which the install dialog should say in as many words.
