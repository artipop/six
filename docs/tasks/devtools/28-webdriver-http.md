# 28. WebDriver over HTTP

A server of Savoia's own that speaks W3C WebDriver and turns each command into one of WebKit's automation
protocol, so that an ordinary WebDriver client — Selenium, WebdriverIO, wptrunner — drives Savoia. It is what
safaridriver does for Safari, and safaridriver does not attach to another browser.

**Not to be started without a client.** Nothing Savoia does needs it: agents act through MCP, and the wpt stand
would gain one action of 749 from the protocol ([devtools.md](../../devtools.md#who-speaks-to-it)). Take it up when
something is named that can only speak WebDriver, or when Savoia's results are wanted on wpt.fyi, which wptrunner
would produce.

## What is there

Read [devtools.md](../../devtools.md#remote-automation) first. Develop ▸ Allow Remote Automation, tabs opened under
a `_WKAutomationSession`, and `automation_send`, which passes one protocol command and answers with its reply
(`Savoia/DevTools/Automation.swift`). The session's delegate answers a new web view, a switch to one, the dialogs
and the window requests; the window's frame is read and not set. Keys and the mouse both reach the page, the mouse
with Savoia behind another app too. The three things in the protocol that drop a mouse state without an error are
written down there — a server has to get them right for Element Click and Perform Actions.

## To do

1. **Ask Artem which client**, and run that client against Safari with safaridriver first, to have the answers to
   compare with.
2. **Search for a Swift WebDriver server or an HTTP library before writing one** (AGENTS.md: ask before a
   hand-written integration), and report what was found.
3. **The server**: sessions (`New Session`, `Delete Session`, one at a time), then the commands the named client
   sends, in the order it sends them — not the whole specification. WebKit's `Source/WebDriver` is the reference
   for which protocol command each one becomes; Element Click and Send Keys are sequences built from element
   layout, not single commands.
4. **Where it listens**: loopback only, a port chosen at launch, and only while Allow Remote Automation is on.

## Done when

The named client runs its own smoke test against Savoia, the commands it does not get are listed in devtools.md,
and the guide says how to point a client at Savoia, in both languages.
