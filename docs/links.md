# Links, the context menu and downloads

What happens when a link is clicked, right-clicked, ⌘-clicked or asked for as a file. One page, because in a SwiftUI
`WebPage` browser these are all the same problem: WebKit's own answer to them goes to a delegate this API has no seat
for, so six has to answer them itself.

## What the SwiftUI API gives, and what it doesn't

`WebPage` has a navigation decider (`WebPage.NavigationDeciding`), a dialog presenter and a device-sensor
authorization block. It has **no UI client** (`WKUIDelegate`) and **no download delegate** (`WKDownloadDelegate`).
Everything below follows from that.

| what the user does | where WebKit sends it | before |
|---|---|---|
| a `target=_blank` link, `window.open` | `decidePolicy(for:preferences:)`, `target == nil`, then the UI client | the policy call was answered `.allow` and the UI client never existed → nothing |
| ⌘-click | `decidePolicy(for:preferences:)` — `modifierFlags` carries the ⌘ | answered `.allow` → the page was simply replaced |
| middle click | `decidePolicy(for:preferences:)`, and nothing in the action tells it from a plain click | it replaces the page, and still does |
| ⇧-click, ⌘⇧-click | straight to the UI client, no policy call | nothing, and nothing six can do about it |
| **Open Link in New Window** (context menu) | straight to the UI client, no policy call | nothing |
| **Download Linked File** (context menu) | straight to a download delegate, no policy call | nothing |
| `<a download>`, ⌥-click | `decidePolicy(for:preferences:)`, `shouldPerformDownload` | answered `.allow` → the file was displayed, or nothing |
| a response no page can show (a zip, an attachment) | `decidePolicy(for response:)`, `canShowMimeType == false` | answered `.allow` → a blank window |

The two context-menu items and the shift-clicks cannot be caught in a decider at all: WebKit hands them to
the UI client and to a download delegate, and this API has a seat for neither. The middle click is a third kind of
loss: it *does* reach the decider, but nothing in the action says which button was pressed. `buttonNumber`,
despite the name, is 1 for every activation the mouse drove — left, middle, plain or modified — and 0 for
everything else, so a middle click and an ordinary one are the same event. Reading it as the middle button is
what once made every plain click open a window of its own. Everything else is a navigation
action, and `TabNavigationDecider` in [`BrowserTab.swift`](../six/Browser/BrowserTab.swift) cancels it and
hands the request back to `BrowserState`. The menu items six replaces; the shift-clicks it cannot.

`SIX_LINKS_TRACE=1` narrates every one of these decisions on stderr.

## The context menu is six's

Because the two items cannot be repaired in place, and `webViewContextMenu` — the one hook there is — **replaces**
WebKit's menu rather than adding to it, six builds the whole menu
([`PageContextMenu.swift`](../six/Views/PageContextMenu.swift)):

| on a link | always |
|---|---|
| Open Link | Back / Forward / Reload (Stop while loading) |
| Open Link in New Window | Cut / Copy / Paste / Select All |
| Open Link Behind | |
| Download Linked File | |
| Copy Link | |

The clipboard items go through the responder chain (`cut:`, `copy:`, `paste:`, `selectAll:`), which is how they reach
the page's own selection and its text fields — the same route the Edit menu takes.

What is lost with WebKit's menu is what `WebView.ActivatedElementInfo` does not describe: it carries a link URL and
nothing else, so there is no Save Image, no Copy Image, no Look Up and no spelling suggestions. That is the price of
the two link items working at all.

## A second window

⌘-click, Open Link in New Window and `target=_blank` all end at
`BrowserState.openInNewWindow(_:from:background:)` — a column inserted right of the one the link was in.

- ⌘-click puts it there **behind**: the strip grows to the right and the focus stays on the page
  being read, and the strip leans over for a moment to show what arrived (above). There is no modifier for "and
  take me there" — every shift-click is swallowed before six is asked — so the going-there version lives in the
  context menu, as Open Link in New Window next to Open Link Behind.
- A page that opened the window itself (`window.open`, a `_blank` link clicked plainly) comes **forward**, because it
  was opened to be looked at.
- A link that is not the web — `magnet:`, `mailto:`, `tel:`, a custom scheme — goes to the system, not into a
  column. `ExternalScheme` in [`ExternalOpen.swift`](../six/Browser/ExternalOpen.swift) holds the one rule, and all
  three routes ask it: the decider (a link clicked **in place** — WebKit does call the decider for `magnet:`, and a
  `.allow` there is a click that does nothing at all, silently), the column a `target=_blank` would have opened, and
  the address bar. It is an allowlist of what a window can show — http(s), file, about, data, blob, javascript,
  `six:`, the extension and MCP-app schemes — because the schemes to hand off are unbounded by definition.
  The address bar asks LaunchServices first: `magnet:?xt=…` is an address on a machine with a torrent client and a
  search query on one without, which is also what keeps «note: buy milk» a search. The tools do not ask — an agent
  that names a scheme six cannot show gets a search, not the power to launch whatever app registered it.

WebKit's own popup blocking still runs first: a `window.open` with no user gesture behind it never reaches the
decider, so an ad that opens itself does not get a column.

## Downloads

`WKDownload` needs a delegate the SwiftUI API has no seat for, so six does the transfer itself —
[`Downloads.swift`](../six/Browser/Downloads.swift), one `DownloadStore` for the app.

That costs one thing and buys another. The request has to be rebuilt: six carries over the profile's cookies (from
`WKWebsiteDataStore.httpCookieStore`, filtered by domain, path and `secure`, or a site that only serves a file to a
signed-in session serves the sign-in page instead), the page's address as `Referer`, and Safari's user agent. In
return a download is an ordinary object — the strip can show it, cancel it and reveal it.

Files land in the user's **Downloads** folder under the name the server suggested, never overwriting: a second
`report.pdf` is `report 2.pdf`. They are left readable (0644), not private to the process the way a URLSession
temporary file is.

The button appears in the top bar as soon as there is a download and not before — a ring around it while a transfer
is running, the profile's colour when one has finished and the list hasn't been opened. The list has the size, the
host, Stop while it runs, Resume when it has stopped, Show in Finder when it is done, and a context menu with Open,
Copy Address and Remove from List. Removing a row never touches the file.

### Picking one up again

`URLSession` hands back a small blob — 8 KB for a 40 MB file, and it holds the temporary file's path and the
validators the server gave, not the bytes — whenever a download stops with a chance of carrying on. six keeps it on
the row and starts the next task from it, which asks for the rest with a `Range` header rather than for the whole
file again.

It arrives by two routes and both are taken. A **Stop** goes through `cancel(byProducingResumeData:)`, which answers
on a background queue, so the row goes to *Stopped* at once and grows its resume data a moment later. A transfer that
**died on its own** — the case that actually matters — carries the same blob in the error's
`NSURLSessionDownloadTaskResumeData`, which is read in `didCompleteWithError`.

A server that will not honour a range request gives nothing back, and then there is no resuming: six keeps the
request as it was actually sent instead — cookies, referrer and all — and the button says **Try Again** rather than
**Resume**, because starting over is what it will do. Both are one click, and neither sends the user back to find
the page and the link a second time.

Measured against a local server that supports ranges: a 40 MB file stopped at 12 845 056 bytes produced 8 038 bytes
of resume data, the resumed task asked for `bytes=12845056-` and nothing before it, and the finished file matched
the original's SHA-256. The same held when the server was killed mid-transfer instead of the download being
cancelled. `didResumeAtOffset` sets the bar where the transfer left off, so a resumed download shows nine tenths of
a bar rather than an empty one that fills instantly; `totalBytesWritten` counts from zero including the resumed
bytes, so the rest of the row needs no arithmetic.

### After a relaunch

Resume data does not survive one, and cannot: it points at a partial file in a temporary directory the system is
entitled to empty, so a *Resume* restored from a file would be a button that fails. What survives is the row.

The unfinished downloads — running, stopped or failed, whichever they were when six was quit — are written into the
session snapshot and come back as **Interrupted**, saying what the file was called and how big it was, with a
**Try Again** that fetches it from the beginning. Finished ones are not kept: the file is in the Downloads folder
and nothing about it was lost.

What is *not* written down is the request. It carries the profile's session cookies, and cookies do not belong in a
JSON file next to the session; the address, the referrer and the profile id are enough to build the request again —
with the cookies that profile has *now*, which is the better request anyway. That is also why resuming goes through
`BrowserState.resumeDownload(_:)`: only the browser knows which `WKWebsiteDataStore` a row belongs to.

Progress ticks must not reach the snapshot. It is written under observation tracking, so reading `items` there would
mean the whole session file rewritten once a second for the length of every download; `DownloadStore.unfinished` is
a value of its own, recomputed when a row is added, removed or changes state — and once more when the response
arrives and the size is finally known.

A download belongs to the browser, not to the window that started it: closing the window does not stop the transfer.
The list is in memory only — it is not written to the snapshot, in any profile.

A window that was opened only to carry the link — a `target=_blank` that turned out to be a file, an Open Link in
New Window on the same — closes itself when the download starts (`BrowserState.closeIfOnlyCarriedALink`). Nothing
was committed in it, so there is no page in it and nothing to go back to: it would stand there blank next to the
download it became. A window that had already shown something is left alone, and so is the one the user is reading.

## Saying that it happened

Both of these happen *somewhere else*. A download lands in a list behind a button in the corner of a
bar nobody was looking at; a ⌘-click adds a column to the right of the one being read without moving
the focus, usually past the edge of the screen. Both are clicks that appear to do nothing. They get
different answers, because they are different problems.

**A download flies.** A short arc from the click to the button, and the button bounces when it catches
one — [`Flights.swift`](../six/Browser/Flights.swift) for the model,
[`FlightsOverlay.swift`](../six/Views/FlightsOverlay.swift) for the drawing. Two things it has to get
right: the origin is the *pointer*, read at the moment the download is decided (`NavigationAction`
carries no point, and by the time the first byte arrives the mouse has moved on), and the target is
read a beat later, because on the first download the button does not exist yet — it comes into being
with the row that flight is for. Nobody clicked — an agent asked, or the pointer was outside the
window — and there is no flight.

**A ⌘-click leans.** The strip tips to the right far enough to show the edge of what arrived and comes
back: `NiriLayout.peek`, riding `horizontalPreview`, the same rubber band a scroll gesture borrows. An
arc was tried here first and thrown away — it is a symbol standing in for the thing, when the thing
itself is one column away and can simply be shown. A second ⌘-click restarts the lean rather than
queueing, so a burst of them settles once, at the end.

## Not built

- A form with `target=_blank` opens the new column with a GET: `newTab(url:)` takes an address, not a body.
- Save Image / Copy Image, and the rest of what WebKit's menu knew about an element that is not a link.
- ⇧-click and ⌘⇧-click: WebKit never asks anyone about them, so there is nothing to answer.
