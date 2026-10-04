# External test suites

Suites written by other people that Savoia can be run against, and which part of Savoia each one would measure. Two of
them are scripted today (WebMCP, [webmcp.md](webmcp.md#compatibility-web-platform-tests), and wpt's
`web-extensions/`, [extensions.md](extensions.md#compatibility-web-platform-tests)); the rest are the list to work
through. A suite earns its place by exercising code Savoia owns. Most of the web platform is WebKit's, and a
failure there says nothing about Savoia — so each row below names the Savoia code it would put under test.

## The shared stand

`scripts/webmcp-wpt.py` already carries the parts every suite here needs, and the next runner should be cut from it
rather than written again:

- **wpt, served locally without a hosts file.** A sparse clone in `~/Library/Caches/savoia-wpt`, `wpt serve` with
  `browser_host` set to `savoia.localhost`: `*.localhost` resolves to loopback by itself, so `www1.savoia.localhost` and
  `savoia-alt.localhost` are the second and cross-site origins, and the Mac's LAN address is a non-secure one. Plain
  `localhost` does not work — `get-host-info.sub.js` then takes `127.0.0.1` as the remote host, and no certificate
  names an IP.
- **Its own CA, trusted by the dev build only.** `wpt serve` generates a CA name-constrained to those hosts;
  `--install-ca` copies it into the dev build's `Certificates/` and switches it on (with the dev Savoia quit, since the
  trust list is held in memory and written back). Leaf certificates stay at 365 days: macOS refuses a TLS server
  certificate valid for more than 825 days even under a private anchor.
- **Driving Savoia.** `Savoia --mcp` from the Debug app: `open_window` once, then `navigate` and `evaluate_javascript`
  per file. testharness's report is read off the page (`#results > tbody > tr`), crash tests pass by leaving the
  page alive, and each run is compared with a committed baseline so the output is what moved.

### What unlocks most of the rest: testdriver

Many wpt tests need an action a page cannot take on itself — a click that counts as a user gesture, granting a
permission, pressing a key, installing an extension. wpt routes those through `resources/testdriver.js`, which a
browser vendor backs with `testdriver-vendor.js`. A Savoia vendor file that sends each action over a channel to Savoia,
which carries it out for real, would open most of the rows below at once. The pieces already exist:

| testdriver call | what Savoia already has |
|---|---|
| `click`, `bless`, `send_keys`, `action_sequence` | `NSApp.postEvent` into the app's own queue (`KeySelfTest`); page-level clicks from agent-actions |
| `set_permission` | `SitePermissions`, per profile and origin |
| `install_web_extension` / `uninstall_web_extension` | `ExtensionInstaller` |
| `set_spc_transaction_mode`, `get_named_cookie`, `delete_all_cookies` | the profile's data store |

`postEvent` goes past the WindowServer, so a key the system owns tests green and does nothing in the hand
(AGENTS.md); a gesture WebKit checks through the OS may need a real click instead.

## Browser extensions (MV3)

`Savoia/Extensions` hosts `WKWebExtension`; what matters is how much of the WebExtensions API a controller per profile
actually answers, and whether the compatibility verdict tells the truth.

| suite | what it measures in Savoia | how to drive it | needs |
|---|---|---|---|
| wpt [`web-extensions/`](https://github.com/web-platform-tests/wpt/tree/master/web-extensions) | `runtime`, `storage`, `alarms`, `idle`, `bookmarks`, `browsingData` through Savoia's extension controller — six test extensions, 44 tests of `browser.test.runTests` | **scripted**: `scripts/web-extensions-wpt.py` installs each extension unmodified with `SAVOIA_EXTENSION`, in a launch and a throwaway home of its own, and reads WebKit's own `browser.test` verdicts from the log — [extensions.md](extensions.md#compatibility-web-platform-tests) | nothing more; the wpt page and testdriver's `install_web_extension` are bypassed, since the extension starts its tests by itself |
| WebKit's own `TestWebKitAPI/Tests/WebKitCocoa/WKWebExtensionAPI*.mm` | the same layer from Apple's side: what `WKWebExtension` is meant to do, per namespace | lift the JavaScript out of the Objective-C into an extension folder and run it the same way | the lifting |
| [chrome-extensions-samples](https://github.com/GoogleChrome/chrome-extensions-samples) (MV3) and [mdn/webextensions-examples](https://github.com/mdn/webextensions-examples) | installing, the compatibility verdict, and the obvious behaviour of each sample | install every sample, record the verdict and the errors `[extensions]` logs, then check one visible effect each | a list of expected effects, by hand once |
| a corpus of real extensions — uBlock Origin Lite, Bitwarden, 1Password, Dark Reader, Grammarly, SponsorBlock, Violentmonkey | whether the verdict matches what works; uBOL is already measured in [unmeasured.md](unmeasured.md) | install, use, write down; semi-manual | Artem for anything with an account |
| MDN [browser-compat-data](https://github.com/mdn/browser-compat-data) `webextensions/` | not a test: the Safari column is the ceiling of what WKWebExtension can offer, and the checklist to read failures against | read, not run | — |

## Content blocking

`Savoia/Blocking`: `WKContentRuleList` per profile, the rule conversion, and AdGuard's scriptlets and extended CSS as a
vendored payload in the page.

| suite | what it measures in Savoia | how to drive it | needs |
|---|---|---|---|
| [AdGuard TestCases](https://github.com/AdguardTeam/TestCases) ([testcases.agrd.dev](https://testcases.agrd.dev/)) | 38 kinds of filter rule — element hiding, CSS, extended CSS, scriptlets, redirects, `$csp`, `$removeparam`, `$removeheader`, cookie and header rules — each page shipping its rules and its expected result | subscribe the test's rules in a throwaway profile, open the page, read what it reports | a way to add a filter list by URL without the UI |
| [AdGuard Scriptlets](https://github.com/AdguardTeam/Scriptlets) and [ExtendedCss](https://github.com/AdguardTeam/ExtendedCss) test suites | the vendored payload in Savoia's setting — the page's world at document start, main frame only — rather than in AdGuard's extension | their QUnit pages, served from the stand | a build of their test bundles |
| [adblock-tester.com](https://adblock-tester.com/) | the whole thing, coarsely | one page, one score | — (measured once for uBOL) |
| wpt `content-security-policy`, `mixed-content`, `upgrade-insecure-requests` | only where Savoia adds headers or rules of its own (`$csp`); otherwise WebKit's | a subset, chosen after the TestCases run | — |

## Privacy and profiles

Profiles are isolated `WKWebsiteDataStore`s; history, permissions and certificates are Savoia's own.

| suite | what it measures in Savoia | how to drive it | needs |
|---|---|---|---|
| [PrivacyTests.org](https://github.com/privacytests/privacytests.org) (MIT) | state partitioning and leaks between sites, fingerprinting surfaces, tracking-parameter stripping, HTTPS upgrades, private windows — the columns browsers are compared on publicly | its runner drives a browser per test and reads results off a page; it needs an adapter that drives Savoia over `Savoia --mcp` instead | the adapter |
| wpt `storage`, `storage-access-api`, `cookies`, `cookiestore`, `clear-site-data` | profile isolation and clearing, where Savoia chose the data store | the stand, some tests with testdriver | testdriver for the storage-access prompts |
| wpt `private-click-measurement`, `nav-tracking-mitigations`, `gpc` | whether Savoia turns on what WebKit leaves to the app | the stand | — |

## Where Savoia answers, not WebKit (wpt)

WebKit asks the application — through a delegate, a `WebPage` callback or a UI Savoia draws — and the result depends on
Savoia's answer. These are the wpt directories worth running; everything else in wpt is the engine's.

| wpt directory | the Savoia code under test |
|---|---|
| `permissions`, `permissions-policy`, `permissions-request`, `permissions-revoke` | `SitePermissions`: the per-site answers and the permission bar |
| `mediacapture-streams`, `screen-capture`, `mediacapture-handle` | camera, microphone and screen: the bar, the capture indicator, `stopCapture` ([permissions.md](permissions.md)) |
| `geolocation`, `notifications`, `push-api` | not built ([todo.md](todo.md)); these say exactly what is missing |
| `html/browsers/windows`, `html/browsers/the-window-object` (`window.open`, `noopener`, popups) | where a new window lands in the row, and who owns it |
| `html/webappapis/user-prompts`, `html/browsers/browsing-the-web/unloading-documents` (`beforeunload`) | the page's own dialogs, which Savoia draws ([permissions.md](permissions.md)) |
| `html/browsers/history`, `navigation-api` | back and forward as Savoia wires them, including the `⌘[` menu items |
| `fullscreen`, `picture-in-picture`, `document-picture-in-picture` | the view Savoia swaps in for fullscreen (SwiftUI's `WebView` draws black there) and Savoia's PiP |
| `clipboard-apis`, `web-share` | the clipboard permission and the Share menu ([sharing.md](sharing.md)) |
| `html/semantics/forms/the-input-element` (file inputs), `entries-api`, `file-system-access` | the open panel Savoia presents |
| `download` attribute tests under `html/semantics/links`, `fetch` downloads | Downloads, without `WKDownload` ([links.md](links.md)) |
| `webauthn`, `credential-management`, `fedcm`, `digital-credentials` | passkeys and autofill, planned in [passkeys.md](passkeys.md) |
| `ai/` (Translator, LanguageDetector, Summarizer, Prompt API) | not exposed to pages today; Savoia has on-device translation and Foundation Models, so these are the spec to follow if it ever is |
| `print` | printing, which Savoia starts |
| `webmcp` | scripted — [webmcp.md](webmcp.md) |

### Permissions: what to run next, and against what

Not run yet. The bar is the one `web-extensions/` set: **the same result as the Safari of the same system, file by
file** — a failure Safari shares is WebKit's, a failure only Savoia has is Savoia's. Counted on wpt `1d99362`; the
Safari column is 27.0 on wpt.fyi, 2 October 2026 (Technology Preview 253 scores the same in every row but
`clipboard-apis`).

| wpt directory | test files | without testdriver | Safari 27.0, subtests | testdriver calls the rest make |
|---|---|---|---|---|
| `permissions` | 14 | 7 | 150/206 | `set_permission` |
| `permissions-request`, `permissions-revoke` | 2 | 2 | 8/14 each | — |
| `permissions-policy` | 111 | 83 | 66/620, 30 files timing out | `bless`, `send_keys`, `click` |
| `mediacapture-streams` | 57 | 12 | 366/482 | `bless`, `click`, `set_permission` through its helper |
| `screen-capture` | 15 | 4 | 25/186 | `bless`, `click`, `set_permission` |
| `mediacapture-handle` | 1 | 1 | 0/5 | — |
| `geolocation` | 22 | 5 | 94/131, 16 files in error | `set_permission`, WebDriver BiDi emulation |
| `notifications` | 24 | 8 | 187/345, 14 files in error | `set_permission` |
| `clipboard-apis` | 58 | 7 | 181/245 | `click`, `set_permission` |
| `storage-access-api` | 40 | 2 | 117/149 | `delete_all_cookies`, `set_permission` |
| `idle-detection` | 12 | 1 | 1/63 | `set_permission` |

In that order of work:

1. **The files without testdriver** — about 130 — run on the stand as it is: a sibling of `scripts/webmcp-wpt.py`
   taking the directories as arguments, which also fetches Safari's run from wpt.fyi
   (`/api/runs?product=safari&label=stable` → `results_url`, a map from test path to `[passed, total]`) and prints
   the files where Savoia and Safari differ. The cache already holds these directories.
2. **`set_permission`, `bless` and `click`** through a `testdriver-vendor.js` for Savoia (above). Safari gets these
   from `safaridriver`, so until the vendor file exists every test that calls one fails in Savoia for a reason that
   says nothing about `SitePermissions`.
3. **By hand, as a cross-check**: [permission.site](https://permission.site/), one button per prompt.

A page API that wants a person is refused over `Savoia --mcp` without reaching Savoia's code (AGENTS.md), so a
`denied` in step 1 is read against Safari's row before it is believed.

## Protocols Savoia speaks

| suite | what it measures in Savoia | how to drive it | needs |
|---|---|---|---|
| [MCP conformance](https://github.com/modelcontextprotocol/conformance) | `Savoia --mcp` as a server (`npx @modelcontextprotocol/conformance server --url …`, or a stdio wrapper), and Savoia as an MCP *client* in Apps — OAuth, SEP-1865 — through its client scenarios | the framework starts its own server per scenario and records the exchange | a way to point Savoia's Apps at a given server URL headlessly; the framework calls itself unstable |
| MCP Inspector | a manual pass over `Savoia --mcp`'s tool list and schemas | by hand | — |

## Certificates and error pages

| suite | what it measures in Savoia | how to drive it |
|---|---|---|
| [badssl.com](https://badssl.com/) | `CertificateStore`'s order of judgement ([certificates.md](certificates.md)) and the failure page: expired, self-signed, wrong host, untrusted root, revoked, pinning, weak protocols, mixed content | a list of hosts; read what the window ended up showing and what `[load]` logged |

## Order

Scripts are to be written in roughly this order, each one a sibling of `scripts/webmcp-wpt.py` sharing its stand:
AdGuard TestCases and badssl first (no testdriver, and they measure code Savoia wrote from scratch); then the testdriver
vendor file; then the permission and dialog directories (wpt `web-extensions/` is done, and needed neither testdriver nor a shim);
then PrivacyTests.org's adapter and MCP conformance.
