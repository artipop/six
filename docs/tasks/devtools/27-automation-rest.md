# 27. Remote automation: the rest

Finish what [devtools.md](../../devtools.md#remote-automation) says remote automation does not do yet, and decide
who is meant to speak to it.

## What is there

Develop ▸ Allow Remote Automation, tabs opened under it apart from the rest, and two MCP tools:
`automation_open_window` and `automation_send`, which passes one command of WebKit's automation protocol to a
`_WKAutomationSession` and answers with its reply (`Savoia/DevTools/Automation.swift`). The session's delegate
answers a request for a new web view, a switch to one, and the seven dialog requests. All SPI behind
`responds(to:)`. Read that section first: it has what was measured and the two things that cost time.

## To do, smallest first

1. **Three paths nobody has run.** The switch turned off while an automation tab is open (`Automation.end`: the
   tabs close, the session goes, a command in flight is answered); a file chosen under automation
   (`Automation.setFilesToSelectForFileUpload`, then a click on the input — WebKit's own business, so
   `PageDelegate.runOpenPanelWith` may never be asked); and the orange mark in the address field, which wants
   Artem's eyes.
2. **The window's geometry.** `Automation.getBrowsingContexts` reads `windowSize` 0×0 and `windowOrigin` off
   screen, and `setWindowFrameOfBrowsingContext`, `maximizeWindowOfBrowsingContext` and
   `hideWindowOfBrowsingContext` have nobody to ask. Find out which door WebKit knocks on — the session
   delegate's `requestMaximizeWindowOfWebView…` / `requestHideWindowOfWebView…` / `requestRestoreWindowOfWebView…`,
   and for the frame probably the UI delegate's private `_webView:getWindowFrameWithCompletionHandler:` and
   `_webView:setWindowFrame:completionHandler:`; these names are from memory of WebKit's source, so check them
   against the binary (`responds(to:)`, `class_copyMethodList`) before writing a line. An automation tab is a tab
   in the one window, so the honest answers are the window's own frame, and a refusal to hide or resize what the
   person is using.
3. **Who speaks to it — a decision before any code.** Today only an MCP client does, one protocol command at a
   time. Two larger things were named and not started:
   - **The wpt stand on WebKit's automation** in place of its own testdriver
     ([test-suites.md](../../test-suites.md)). Measure before deciding: run `./scripts/permissions-wpt.py --actions`
     and count the actions answered "not implemented", then see which of them the protocol has
     (`performInteractionSequence`, `setSessionPermissions`, `setStorageAccessPermissionState`,
     virtual authenticators). If the count is small, write that down and stop.
   - **WebDriver over HTTP**, so that an ordinary WebDriver client drives Savoia. safaridriver cannot attach to
     another browser, so this is a server of Savoia's own that turns W3C WebDriver commands into the protocol's —
     what safaridriver itself does. It is the largest piece here and has no client waiting for it. Ask Artem
     whether anything is meant to use it before starting.

## Not this task

An agent's own tools — `click`, `fill`, `hover`, `drag`, `handle_dialog`, `upload_file` — work on every tab through
Savoia's page actions and are done ([agent-actions.md](../../agent-actions.md#against-chromes-server)). What the Web
Inspector protocol alone gives — request bodies, throttling, traces — is out of reach for an app's own pages.

## Done when

The three paths in step 1 are run and devtools.md says what happened; `windowSize` is the window's, or it is
written down why not; and step 3 has an answer in devtools.md — built, or measured and declined with the numbers.
