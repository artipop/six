# 28. WebDriver over HTTP

A server of Savoia's own that speaks W3C WebDriver and turns each command into one of WebKit's automation
protocol, so that an ordinary WebDriver client — Selenium, WebdriverIO, wptrunner — drives Savoia. It is what
safaridriver does for Safari, and safaridriver does not attach to another browser.

**The client is wptrunner.** Artem's decision, 7 October 2026: the wpt stand is to move from Savoia's own runner
(`scripts/permissions-wpt.py` and its siblings) to wpt's, the way Safari is run, which is also what would put
Savoia's results on wpt.fyi and open the whole suite and not twelve directories of it. Not started.

It does not make `Savoia/Tools/TestDriver.swift` go away. The protocol cannot set a permission Savoia keeps
(`setSessionPermissions` refuses `geolocation`) and has no BiDi `permissions` or `emulation` domain; the server's
Set Permission and the rest are that file's code behind another door. Whether the protocol's own frame handles
(`resolveChildFrameHandle`) can stand in for `testdriver_in_context` was not tried ([devtools.md](../../devtools.md#who-speaks-to-it)).

## What is there

Read [devtools.md](../../devtools.md#remote-automation) first. Develop ▸ Allow Remote Automation, tabs opened under
a `_WKAutomationSession`, and `automation_send`, which passes one protocol command and answers with its reply
(`Savoia/DevTools/Automation.swift`). The session's delegate answers a new web view, a switch to one, the dialogs
and the window requests; the window's frame is read and not set. Keys and the mouse both reach the page, the mouse
with Savoia behind another app too. The three things in the protocol that drop a mouse state without an error are
written down there — a server has to get them right for Element Click and Perform Actions.

## To do

1. **Run wptrunner against Safari first**, on the permission directories, with safaridriver's log on: the commands
   it actually sends are the list to build, and its results are the answers to compare with.
2. **Search for a Swift WebDriver server or an HTTP library before writing one** (AGENTS.md: ask before a
   hand-written integration), and report what was found.
3. **The server**: sessions (`New Session`, `Delete Session`, one at a time), then the commands from step 1, in the
   order wptrunner sends them — not the whole specification. WebKit's `Source/WebDriver` is the reference for which
   protocol command each one becomes; Element Click and Send Keys are sequences built from element layout, not
   single commands.
4. **Where it listens**: loopback only, a port chosen at launch, and only while Allow Remote Automation is on.
5. **A wptrunner product for Savoia** — the small Python file that tells wptrunner how to start the browser and
   where its WebDriver is; Safari's is the model.
6. **What a test sees in an automation tab.** It has a store of its own, no extensions, and `navigator.webdriver`
   true; whether `SitePermissions` and the permission bar behave there as in an ordinary tab is not measured, and
   the permission directories are the ones that would show it.
7. **Compare and retire.** The same directories under both runners; where they agree, the old runner and its
   baseline go, and `TestDriver.swift` keeps what the server calls.

## Done when

wptrunner runs the permission directories against Savoia with the results `permissions-wpt.py` gives or better,
the commands it does not get are listed in devtools.md, test-suites.md describes the stand as it then is, and the
old runner is gone or its reason for staying is written down.

## Playwright is a different client, and a second question

Asked by Artem on 8 October 2026: could Playwright drive Savoia through this? **Not through this server as
described.** Playwright does not speak WebDriver over HTTP. For WebKit it ships a patched build with a protocol of
its own; what it speaks to browsers it does not patch is **WebDriver BiDi**, over a WebSocket — by 2026 its Firefox
runs that way, and its BiDi backend is reported as passing about nine tests in ten on browsers that implement the
protocol (read from coverage of it, not tried).

So Playwright needs a BiDi endpoint, and this task builds the classic one. What would have to be found out before
a line is written, in this order:

1. **Whether WebKit's automation session carries BiDi at all on macOS 27.** The classic commands go through
   `_WKAutomationSession`; WebKit has been adding BiDi beside them. Read `Source/WebKit/UIProcess/Automation/` on
   WebKit's `main` and the exports of the system's WebKit (`dyld_info -exports`), as
   [api-watch.md](../../api-watch.md) describes. Above it was noted that the protocol has no BiDi `permissions` or
   `emulation` domain; find out which domains it has.
2. **Which BiDi modules Playwright's backend cannot do without** — `session`, `browsingContext`, `script`,
   `network`, `input` at least — and which of them WebKit answers.
3. **Whether Playwright will connect to an endpoint it did not launch.** It expects to start the browser itself;
   an attach-over-WebSocket path may exist only for some browser types.

If 1 says no, Playwright is out of reach until WebKit carries BiDi, and that goes into
[todo.md](../../todo.md)'s "not planned" with the reason. If it says yes, this is a task of its own after the
classic server, not a part of it. Selenium and WebdriverIO, which do speak classic WebDriver, come with the server
as described.
