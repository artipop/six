# 33. Playwright, which needs WebDriver BiDi

Asked by Artem on 8 October 2026: could Playwright drive Savoia through its WebDriver server
([devtools.md](../../devtools.md#webdriver-over-http))? **Not through that server.** Playwright does not speak WebDriver over HTTP. For WebKit it ships a patched build with a protocol of
its own; what it speaks to browsers it does not patch is **WebDriver BiDi**, over a WebSocket — by 2026 its Firefox
runs that way, and its BiDi backend is reported as passing about nine tests in ten on browsers that implement the
protocol (read from coverage of it, not tried).

So Playwright needs a BiDi endpoint, and the server is the classic one. What would have to be found out before
a line is written, in this order:

1. **Whether WebKit's automation session carries BiDi at all on macOS 27.** The classic commands go through
   `_WKAutomationSession`; WebKit has been adding BiDi beside them, and the session's `processBidiMessage` answers
   that the `permissions` and `emulation` domains were not found — which domains it does have is the question. Read `Source/WebKit/UIProcess/Automation/` on
   WebKit's `main` and the exports of the system's WebKit (`dyld_info -exports`), as
   [api-watch.md](../../api-watch.md) describes.
2. **Which BiDi modules Playwright's backend cannot do without** — `session`, `browsingContext`, `script`,
   `network`, `input` at least — and which of them WebKit answers.
3. **Whether Playwright will connect to an endpoint it did not launch.** It expects to start the browser itself;
   an attach-over-WebSocket path may exist only for some browser types.

If 1 says no, Playwright is out of reach until WebKit carries BiDi, and that goes into
[todo.md](../../todo.md)'s "not planned" with the reason. If it says yes, the endpoint is a WebSocket beside the
HTTP listener (`Savoia/DevTools/WebDriverServer.swift`), relaying to `processBidiMessage`. Selenium and
WebdriverIO, which speak classic WebDriver, have the server as it is.

## Done when

The three questions are answered in devtools.md, and either Playwright runs one test against Savoia or todo.md
says why it cannot.
