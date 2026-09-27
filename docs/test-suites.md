# External test suites

Suites written by other people that six can be run against, and which part of six each one would measure. One of
them is scripted today (WebMCP, [webmcp.md](webmcp.md#compatibility-web-platform-tests)); the rest are the list to
work through. A suite earns its place by exercising code six owns. Most of the web platform is WebKit's, and a
failure there says nothing about six — so each row below names the six code it would put under test.

## The shared stand

`scripts/webmcp-wpt.py` already carries the parts every suite here needs, and the next runner should be cut from it
rather than written again:

- **wpt, served locally without a hosts file.** A sparse clone in `~/Library/Caches/six-wpt`, `wpt serve` with
  `browser_host` set to `six.localhost`: `*.localhost` resolves to loopback by itself, so `www1.six.localhost` and
  `six-alt.localhost` are the second and cross-site origins, and the Mac's LAN address is a non-secure one. Plain
  `localhost` does not work — `get-host-info.sub.js` then takes `127.0.0.1` as the remote host, and no certificate
  names an IP.
- **Its own CA, trusted by the dev build only.** `wpt serve` generates a CA name-constrained to those hosts;
  `--install-ca` copies it into the dev build's `Certificates/` and switches it on (with the dev six quit, since the
  trust list is held in memory and written back). Leaf certificates stay at 365 days: macOS refuses a TLS server
  certificate valid for more than 825 days even under a private anchor.
- **Driving six.** `six --mcp` from the Debug app: `open_window` once, then `navigate` and `evaluate_javascript`
  per file. testharness's report is read off the page (`#results > tbody > tr`), crash tests pass by leaving the
  page alive, and each run is compared with a committed baseline so the output is what moved.

### What unlocks most of the rest: testdriver

Many wpt tests need an action a page cannot take on itself — a click that counts as a user gesture, granting a
permission, pressing a key, installing an extension. wpt routes those through `resources/testdriver.js`, which a
browser vendor backs with `testdriver-vendor.js`. A six vendor file that sends each action over a channel to six,
which carries it out for real, would open most of the rows below at once. The pieces already exist:

| testdriver call | what six already has |
|---|---|
| `click`, `bless`, `send_keys`, `action_sequence` | `NSApp.postEvent` into the app's own queue (`KeySelfTest`); page-level clicks from agent-actions |
| `set_permission` | `SitePermissions`, per profile and origin |
| `install_web_extension` / `uninstall_web_extension` | `ExtensionInstaller` |
| `set_spc_transaction_mode`, `get_named_cookie`, `delete_all_cookies` | the profile's data store |

`postEvent` goes past the WindowServer, so a key the system owns tests green and does nothing in the hand
(AGENTS.md); a gesture WebKit checks through the OS may need a real click instead.

## Browser extensions (MV3)

`six/Extensions` hosts `WKWebExtension`; what matters is how much of the WebExtensions API a controller per profile
actually answers, and whether the compatibility verdict tells the truth.

| suite | what it measures in six | how to drive it | needs |
|---|---|---|---|
| wpt [`web-extensions/`](https://github.com/web-platform-tests/wpt/tree/master/web-extensions) | `runtime`, `storage`, `alarms`, `idle`, `bookmarks`, `browsingData` through six's extension controller — six test extensions, ~630 lines of `browser.test.runTests` | the page calls `runTestsWithWebExtension(path)`, which installs the extension through testdriver and listens for `browser.test` results | testdriver's `install_web_extension`; a `browser.test` shim prepended to each background script, since WKWebExtension exposes `browser.test` only in WebKit's testing mode |
| WebKit's own `TestWebKitAPI/Tests/WebKitCocoa/WKWebExtensionAPI*.mm` | the same layer from Apple's side: what `WKWebExtension` is meant to do, per namespace | lift the JavaScript out of the Objective-C and run it through the same shim | the shim above |
| [chrome-extensions-samples](https://github.com/GoogleChrome/chrome-extensions-samples) (MV3) and [mdn/webextensions-examples](https://github.com/mdn/webextensions-examples) | installing, the compatibility verdict, and the obvious behaviour of each sample | install every sample, record the verdict and the errors `[extensions]` logs, then check one visible effect each | a list of expected effects, by hand once |
| a corpus of real extensions — uBlock Origin Lite, Bitwarden, 1Password, Dark Reader, Grammarly, SponsorBlock, Violentmonkey | whether the verdict matches what works; uBOL is already measured in [unmeasured.md](unmeasured.md) | install, use, write down; semi-manual | Artem for anything with an account |
| MDN [browser-compat-data](https://github.com/mdn/browser-compat-data) `webextensions/` | not a test: the Safari column is the ceiling of what WKWebExtension can offer, and the checklist to read failures against | read, not run | — |

## Content blocking

`six/Blocking`: `WKContentRuleList` per profile, the rule conversion, and AdGuard's scriptlets and extended CSS as a
vendored payload in the page.

| suite | what it measures in six | how to drive it | needs |
|---|---|---|---|
| [AdGuard TestCases](https://github.com/AdguardTeam/TestCases) ([testcases.agrd.dev](https://testcases.agrd.dev/)) | 38 kinds of filter rule — element hiding, CSS, extended CSS, scriptlets, redirects, `$csp`, `$removeparam`, `$removeheader`, cookie and header rules — each page shipping its rules and its expected result | subscribe the test's rules in a throwaway profile, open the page, read what it reports | a way to add a filter list by URL without the UI |
| [AdGuard Scriptlets](https://github.com/AdguardTeam/Scriptlets) and [ExtendedCss](https://github.com/AdguardTeam/ExtendedCss) test suites | the vendored payload in six's setting — the page's world at document start, main frame only — rather than in AdGuard's extension | their QUnit pages, served from the stand | a build of their test bundles |
| [adblock-tester.com](https://adblock-tester.com/) | the whole thing, coarsely | one page, one score | — (measured once for uBOL) |
| wpt `content-security-policy`, `mixed-content`, `upgrade-insecure-requests` | only where six adds headers or rules of its own (`$csp`); otherwise WebKit's | a subset, chosen after the TestCases run | — |

## Privacy and profiles

Profiles are isolated `WKWebsiteDataStore`s; history, permissions and certificates are six's own.

| suite | what it measures in six | how to drive it | needs |
|---|---|---|---|
| [PrivacyTests.org](https://github.com/privacytests/privacytests.org) (MIT) | state partitioning and leaks between sites, fingerprinting surfaces, tracking-parameter stripping, HTTPS upgrades, private windows — the columns browsers are compared on publicly | its runner drives a browser per test and reads results off a page; it needs an adapter that drives six over `six --mcp` instead | the adapter |
| wpt `storage`, `storage-access-api`, `cookies`, `cookiestore`, `clear-site-data` | profile isolation and clearing, where six chose the data store | the stand, some tests with testdriver | testdriver for the storage-access prompts |
| wpt `private-click-measurement`, `nav-tracking-mitigations`, `gpc` | whether six turns on what WebKit leaves to the app | the stand | — |

## Where six answers, not WebKit (wpt)

WebKit asks the application — through a delegate, a `WebPage` callback or a UI six draws — and the result depends on
six's answer. These are the wpt directories worth running; everything else in wpt is the engine's.

| wpt directory | the six code under test |
|---|---|
| `permissions`, `permissions-policy`, `permissions-request`, `permissions-revoke` | `SitePermissions`: the per-site answers and the permission bar |
| `mediacapture-streams`, `screen-capture`, `mediacapture-handle` | camera, microphone and screen: the bar, the capture indicator, `stopCapture` ([permissions.md](permissions.md)) |
| `geolocation`, `notifications`, `push-api` | not built ([todo.md](todo.md)); these say exactly what is missing |
| `html/browsers/windows`, `html/browsers/the-window-object` (`window.open`, `noopener`, popups) | where a new window lands in the row, and who owns it |
| `html/webappapis/user-prompts`, `html/browsers/browsing-the-web/unloading-documents` (`beforeunload`) | the page's own dialogs, which six draws ([permissions.md](permissions.md)) |
| `html/browsers/history`, `navigation-api` | back and forward as six wires them, including the `⌘[` menu items |
| `fullscreen`, `picture-in-picture`, `document-picture-in-picture` | the view six swaps in for fullscreen (SwiftUI's `WebView` draws black there) and six's PiP |
| `clipboard-apis`, `web-share` | the clipboard permission and the Share menu ([sharing.md](sharing.md)) |
| `html/semantics/forms/the-input-element` (file inputs), `entries-api`, `file-system-access` | the open panel six presents |
| `download` attribute tests under `html/semantics/links`, `fetch` downloads | Downloads, without `WKDownload` ([links.md](links.md)) |
| `webauthn`, `credential-management`, `fedcm`, `digital-credentials` | passkeys and autofill, planned in [passkeys.md](passkeys.md) |
| `ai/` (Translator, LanguageDetector, Summarizer, Prompt API) | not exposed to pages today; six has on-device translation and Foundation Models, so these are the spec to follow if it ever is |
| `print` | printing, which six starts |
| `webmcp` | scripted — [webmcp.md](webmcp.md) |

## Protocols six speaks

| suite | what it measures in six | how to drive it | needs |
|---|---|---|---|
| [MCP conformance](https://github.com/modelcontextprotocol/conformance) | `six --mcp` as a server (`npx @modelcontextprotocol/conformance server --url …`, or a stdio wrapper), and six as an MCP *client* in Apps — OAuth, SEP-1865 — through its client scenarios | the framework starts its own server per scenario and records the exchange | a way to point six's Apps at a given server URL headlessly; the framework calls itself unstable |
| MCP Inspector | a manual pass over `six --mcp`'s tool list and schemas | by hand | — |

## Certificates and error pages

| suite | what it measures in six | how to drive it |
|---|---|---|
| [badssl.com](https://badssl.com/) | `CertificateStore`'s order of judgement ([certificates.md](certificates.md)) and the failure page: expired, self-signed, wrong host, untrusted root, revoked, pinning, weak protocols, mixed content | a list of hosts; read what the window ended up showing and what `[load]` logged |

## Order

Scripts are to be written in roughly this order, each one a sibling of `scripts/webmcp-wpt.py` sharing its stand:
AdGuard TestCases and badssl first (no testdriver, and they measure code six wrote from scratch); then the testdriver
vendor file; then wpt `web-extensions/` with the `browser.test` shim, and the permission and dialog directories;
then PrivacyTests.org's adapter and MCP conformance.
