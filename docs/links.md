# Links, the context menu and downloads

What happens when a link is clicked, right-clicked, ⌘-clicked or asked for as a file. One page, because they all
arrive at one object: `PageDelegate` ([`PageDelegate.swift`](../Savoia/Browser/PageDelegate.swift)), the navigation
and UI delegate of a tab's `WKWebView`.

## Where WebKit sends each one

Until October 2026 a tab was SwiftUI's `WebPage`, which has a navigation decider and no UI client, and most of this
page was about what could not be answered. A tab's view is Savoia's own now, with both delegates.

| what the user does | where WebKit sends it | what Savoia answers |
|---|---|---|
| a `target=_blank` link, `window.open` | `decidePolicyFor`, `targetFrame == nil`, then `createWebView` | `.allow`, then a tab that keeps its opener (below) |
| ⌘-click | `decidePolicyFor` — `modifierFlags` carries the ⌘ | `.cancel`, and the link opens behind, by its address |
| middle click | `decidePolicyFor`, and nothing in the action tells it from a plain click | it replaces the page |
| ⇧-click, ⌘⇧-click | the UI client, with no policy call — not measured since the tab has one | whatever `createWebView` makes of it |
| the context menu | `_webView:getContextMenuFromProposedMenu:forElement:…`, SPI | Savoia's own menu (below) |
| `<a download>`, ⌥-click | `decidePolicyFor`, `shouldPerformDownload` | `.cancel`, and the request goes to `DownloadStore` |
| a response no page can show (a zip, an attachment) | `decidePolicyFor` a response, `canShowMIMEType == false` | `.cancel`, and the same |

The middle click reaches the delegate, but nothing in the action says which button was pressed. `buttonNumber`,
despite the name, is 1 for every activation the mouse drove — left, middle, plain or modified — and 0 for
everything else, so a middle click and an ordinary one are the same event. Reading it as the middle button is
what once made every plain click open a window of its own.

A navigation the delegate cancels reports nothing afterwards — no failure, no finish — so the delegate tells the tab
(`BrowserTab.navigationCancelled`), and a tool waiting for the load stops waiting.

`SAVOIA_LINKS_TRACE=1` narrates every one of these decisions in the log.

## The context menu is Savoia's

An `NSMenu` built by [`PageContextMenu.swift`](../Savoia/Views/PageContextMenu.swift) and handed to WebKit in place
of the one it proposed:

| on a link | always |
|---|---|
| Open Link | Back / Forward / Reload (Stop while loading), Save As…, Share |
| Open Link in New Tab | Cut / Copy / Paste / Select All |
| Open Link Behind | Picture in Picture |
| Open Link Beside | Move to Profile, Close Tab |
| Download Linked File | what the extensions added |
| Copy Link, Share Link | |

The clipboard items go through the responder chain (`cut:`, `copy:`, `paste:`, `selectAll:`), which is how they reach
the page's own selection and its text fields — the same route the Edit menu takes. A document's preview gets the
menu without the page commands.

The link under the pointer comes from SPI: the delegate method above is handed a `_WKContextMenuElementInfo`, and
its `hitTestResult.absoluteLinkURL` is the address — measured on a throwaway `WKWebView` with a synthetic right
click, not yet by hand in Savoia. Public API offers `willOpenMenu(_:with:)`, which hands over WebKit's menu and not
what was clicked. If the SPI goes, the method is never called and WebKit's own menu shows; its Open Link in New
Window then arrives at `createWebView` and makes a tab, and its Download Linked File goes nowhere, since Savoia has
no `WKDownloadDelegate`. The hit test also knows the image under the pointer, which the menu does not use yet: there
is still no Save Image, Copy Image, Look Up or spelling suggestions.

## A second window

⌘-click and the menu's Open Link in New Tab end at `BrowserState.openInNewWindow(_:from:background:)` — a tab
right of the one the link was in, loaded by its address.

- ⌘-click puts it there **behind**: the focus stays on the page being read. The going-there version lives in the
  context menu, as Open Link in New Tab next to Open Link Behind.
- **A window the page asks for is a tab that keeps its opener.** `window.open` — with a size or without, with an
  address or with one assigned afterwards — and a `_blank` link clicked plainly are answered by
  `createWebView`: `BrowserState.openPageWindow` puts a tab next to the opener, in **front**, because the page
  opened it to be looked at, and the tab builds its view on the configuration WebKit handed over
  (`BrowserTab.open(byPageWith:)`), with its own content controller in it. That configuration is the only way the
  new page gets a `window.opener` and the opener a `WindowProxy`, which is what a sign-in or payment popup reports
  back through. `window.close()` closes a tab a page opened, and no other.

  It is a tab like any other — history, permissions, downloads, translation, the ⌘E line — where it used to be a
  bare window (`ScriptedPopups`, gone) that had none of them, and where the rule of which call got a window and
  which a tab with no opener is gone with it. The size a page asks for is not honoured: Sign in with Google asks
  500×550 and gets a tab. Measured over `Savoia --mcp`: all three kinds of `window.open` return a window, the
  child's `postMessage` reaches the opener, the opener reads the child's title, and `window.close()` from the
  opener removes the tab. A sign-in through such a tab has not been walked by hand since.

  If the page budget takes the page of a tab a page opened, it is built again by its address and the two no longer
  have each other.
- A link that is not the web — `magnet:`, `mailto:`, `tel:`, a custom scheme — goes to the system, not into a
  column. `ExternalScheme` in [`ExternalScheme.swift`](../Savoia/Browser/ExternalScheme.swift) — holds the one rule, and all
  three routes ask it: the delegate (a link clicked **in place** — WebKit does ask the delegate for `magnet:`, and a
  `.allow` there is a click that does nothing at all, silently), the column a `target=_blank` would have opened, and
  the address bar. It is an allowlist of what a window can show — http(s), file, about, data, blob, javascript,
  `Savoia:`, the extension and MCP-app schemes — because the schemes to hand off are unbounded by definition.
  A page that navigates *itself* to a scheme nothing on the machine claims is dropped without a word: Telemost's
  join page tries `telemost://` to wake its desktop app and carries on in the browser, and handing that to the
  system put up macOS's "no application to open the URL" alert on every call. Only a clicked link (`linkActivated`)
  still gets that alert, where it is the answer to something the person did.
  The address bar asks LaunchServices first: `magnet:?xt=…` is an address on a machine with a torrent client and a
  search query on one without, which is also what keeps «note: buy milk» a search. The tools do not ask — an agent
  that names a scheme Savoia cannot show gets a search, not the power to launch whatever app registered it.

**Nothing blocks a window a page opens by itself.** `javaScriptCanOpenWindowsAutomatically` is on by default in a
`WKWebView` on macOS, and measured over `Savoia --mcp` a `window.open` with no user gesture behind it gets its tab —
as it did before the move, when the note here said otherwise. The preference is Savoia's to set now; it is left on
because there is nothing yet to let one site through with.

## Downloads

Savoia does the transfer itself rather than through `WKDownload` —
[`Downloads.swift`](../Savoia/Browser/Downloads.swift), one `DownloadStore` for the app.

That costs one thing and buys another. The request has to be rebuilt: Savoia carries over the profile's cookies (from
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
validators the server gave, not the bytes — whenever a download stops with a chance of carrying on. Savoia keeps it on
the row and starts the next task from it, which asks for the rest with a `Range` header rather than for the whole
file again.

It arrives by two routes and both are taken. A **Stop** goes through `cancel(byProducingResumeData:)`, which answers
on a background queue, so the row goes to *Stopped* at once and grows its resume data a moment later. A transfer that
**died on its own** — the case that actually matters — carries the same blob in the error's
`NSURLSessionDownloadTaskResumeData`, which is read in `didCompleteWithError`.

A server that will not honour a range request gives nothing back, and then there is no resuming: Savoia keeps the
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

The unfinished downloads — running, stopped or failed, whichever they were when Savoia was quit — are written into the
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
one — [`Flights.swift`](../Savoia/Browser/Flights.swift) for the model,
[`FlightsOverlay.swift`](../Savoia/Views/FlightsOverlay.swift) for the drawing. Two things it has to get
right: the origin is the *pointer*, read at the moment the download is decided (`NavigationAction`
carries no point, and by the time the first byte arrives the mouse has moved on), and the target is
read a beat later, because on the first download the button does not exist yet — it comes into being
with the row that flight is for. Nobody clicked — an agent asked, or the pointer was outside the
window — and there is no flight.

**A ⌘-click leans.** The strip tips to the right far enough to show the edge of what arrived and comes
back: `TilingLayout.peek`, riding `horizontalPreview`, the same rubber band a scroll gesture borrows. An
arc was tried here first and thrown away — it is a symbol standing in for the thing, when the thing
itself is one column away and can simply be shown. A second ⌘-click restarts the lean rather than
queueing, so a burst of them settles once, at the end.

## Not built

- A form with `target=_blank` opens the new column with a GET: `newTab(url:)` takes an address, not a body.
- Save Image / Copy Image, and the rest of what WebKit's menu knew about an element that is not a link.
- ⇧-click and ⌘⇧-click: WebKit never asks anyone about them, so there is nothing to answer.
