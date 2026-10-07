# Developer tools

## Web Inspector

**View ▸ Web Inspector** (`⌥⌘I`) opens the inspector on the tab in front of you,
and the same keys close it. It is the inspector Safari has: elements, console,
sources and breakpoints, network, timelines, storage. Nothing has to be turned
on for it.

The inspector appears under the page. When two tabs stand side by side, half a
window is too narrow for it and it opens in a window of its own; `⌘W` there
closes that window and not the tab.

The tab has to be showing a **page**: the start page and Savoia's own pages —
configuration, bookmarks, chats — have nothing to inspect. While the inspector
is open the page is not discarded from memory, even when you are on another tab.

Savoia's pages can no longer be attached to from Safari's Develop menu: there is
no switch for it in the configuration.

## Capturing the console and the network

**Configuration ▸ Assistant ▸ Access to Page Console and Network** is not for a
person but for an [agent](/en/agents): a person has the web inspector for the same
thing, told more exactly. With it on, the agent gets two more tools and can ask what a page logged and what it
requested — what Chrome's devtools MCP does, on WebKit.

| | |
|---|---|
| console | everything the page logged since it last navigated, uncaught errors included |
| requests | method, status, duration, size, kind; the failures can be asked for on their own |
| screenshot | a PNG of the visible part of the page — works with capture off too |

What is captured stays in memory — nothing is written to disk, so there is no
file for it. Each window keeps 500 messages and 500 requests, and both are cleared when it
navigates: what was captured belonged to the page being left.

Turning capture on reloads the open windows: the hook is installed at the start
of a load, or it does not see the load's beginning.

::: warning What this means for privacy
The console and `fetch` hooks live **in the page's own world** — anywhere else
they would wrap nothing. Everything else Savoia injects into pages lives in a world
of its own that the page cannot reach, and this is the one deliberate exception.

Which means: the page can see the hooks, can replace them, and can post to them
itself. What you read back is the page's account of itself, not the browser's
testimony. The channel's name is different on every launch, so a page cannot
count on finding it. Capture is off by default and is meant to be turned on while
you are looking into something, not left on.
:::

## Remote automation

**Configuration ▸ Develop ▸ Allow Remote Automation** is what Allow Remote
Automation is in Safari's Develop menu: a program may open a tab and drive it
through WebKit's automation protocol, the one WebDriver runs on. It is for tests
and for an [agent](/en/agents), not for a person.

A tab opened for automation carries an orange **Automation** mark in the address
field. It stands apart from everything else:

- it has a store of its own: none of your cookies or sign-ins, and it leaves none;
- it is not in the history, and does not come back after a relaunch or with ⌘⇧T;
- extensions do not run in it;
- its page can tell it is being driven: `navigator.webdriver` is `true` there. In
  an ordinary tab it is `false`, whether the switch is on or not.

Turning the switch off closes such tabs. Only what talks to Savoia over
[MCP](/en/agents) drives them: `safaridriver` does not attach to Savoia.

## WebMCP

**Configuration ▸ Develop ▸ WebMCP ▸ Let Pages Offer Tools to Agents** is an
experimental switch, off by default.
[WebMCP](https://webmachinelearning.github.io/webmcp/) is a W3C draft by which a
page tells an [agent](/en/agents) what it can do: not "click button number 12"
but `search_flights(from, to, date)`. The function runs in the page itself, in
the session you are already signed in to.

When the open page has declared tools, a wrench appears at the end of the
address field, beside the translation button; its tooltip gives their number, and
it pulses while an agent is calling one. Clicking it lists them: name, description,
and the **read-only** and **consequential** marks — what the page said about
itself. The agent sees the same tools and can call them.

Tools declared by a frame inside the page — an embedded widget, say — are listed
too, each under its frame's address, and the question about a site is asked about
the frame's own site.

A page can also turn an ordinary form into a tool by marking it up. The agent then
fills the form in; if the page allows it, the agent submits it too, and otherwise
the submit button is focused and the form waits for you to press it.

The switch reaches pages loaded after it: turning it on reloads the open windows.

**What you will be asked.** The first call to a site raises a bar under the
window's title: may agents use the tools this site offers them? The answer is
remembered and sits with the camera's — **Configuration ▸ Privacy ▸ Site
Permissions** — and can be taken back there. After that, every call to a tool
the page did not mark read-only is confirmed on its own, and the bar shows the
tool's name and the arguments it is being called with. A private window offers
no tools at all.

::: warning Why this is in Develop for now
A page's tool does whatever the site wrote it to do — on your behalf, in your
session. The question about the site and the confirmation of each call limit
that, but they lean on marks the page puts on itself, so keep WebMCP off unless
you are testing it on purpose. Like console capture,
it lives in the page's own world: the page can see it and can post to its
channel itself — but only about its own tools.
:::

## The log

The capture above belongs to a window and is gone when the window navigates.
Separately from it, Savoia keeps a log of **its own** — what it did: settings that
did not save, a site that did not open, an extension refused without asking.

It goes to `~/Library/Logs/org.deffun.savoia/savoia.log` and, in the same words, to
macOS's system log. **Configuration ▸ Develop ▸ Log** names the path, reveals the file
in Finder and opens Console.

The file is appended to across launches and rotates at four megabytes, keeping
one previous generation. It contains addresses — the one that did not open is the
point of the line — and it sits beside the history and the state snapshot, which
hold far more of them. Delete it like any other file.

What is not here: a DOM snapshot with stable element ids, synthetic clicks and
typing, performance traces, request interception or throttling. Most of them need
the inspector protocol, which an application hosting the page cannot reach.
