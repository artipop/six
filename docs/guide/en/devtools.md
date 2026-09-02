# Developer tools

The **Develop** menu; both switches are off by default.

## Web Inspector

**Develop ▸ Web Inspector** lets **Safari's inspector** attach to VI's pages.
There is no inspector window of VI's own and there cannot be one: WebKit lets an
application declare its pages inspectable, and no more. Safari's inspector,
though, is the real thing — elements, console, network, sources, breakpoints.

How to attach:

1. in Safari, turn on **Settings › Advanced › Show features for web
   developers** — without it Safari's own Develop menu is hidden and there is
   nowhere to attach from. This is the usual reason for "I turned it on and
   nothing happened";
2. in Safari's menu bar: **Develop › ‹the name of this Mac› › six › ‹the page's
   title›**.

An **Open Safari to Attach** button appears beside the switch, and its help tag
already has your machine's name in it.

The window has to be showing a **page**: a fresh window is the start page, which
is drawn natively rather than as web content, so there is nothing in it to
inspect. Nor is there in a window whose page has been discarded, until you come
back to it.

It is off by default because an inspectable page is one another process on the
machine can attach to.

## Capturing the console and the network

**Develop ▸ Capture Console and Network** is not for a person but for an
[agent](/en/agents): with it on, the agent can ask what a page logged and what it
requested — what Chrome's devtools MCP does, on WebKit.

| | |
|---|---|
| console | everything the page logged since it last navigated, uncaught errors included |
| requests | method, status, duration, size, kind; the failures can be asked for on their own |
| screenshot | a PNG of the **whole** page, not the visible part — works with capture off too |

Each window keeps 500 messages and 500 requests, and both are cleared when it
navigates: what was captured belonged to the page being left. **Clear Captured
Logs** does it at once.

Turning capture on reloads the open windows: the hook is installed at the start
of a load, or it does not see the load's beginning.

::: warning What this means for privacy
The console and `fetch` hooks live **in the page's own world** — anywhere else
they would wrap nothing. Everything else VI injects into pages lives in a world
of its own that the page cannot reach, and this is the one deliberate exception.

Which means: the page can see the hooks, can replace them, and can post to them
itself. What you read back is the page's account of itself, not the browser's
testimony. The channel's name is different on every launch, so a page cannot
count on finding it. Capture is off by default and is meant to be turned on while
you are looking into something, not left on.
:::

What is not here: a DOM snapshot with stable element ids, synthetic clicks and
typing, performance traces, request interception or throttling. Most of them need
the inspector protocol, which an application hosting the page cannot reach.
