# Tabs, links and downloads

## Open, close, bring back

| | |
|---|---|
| `⌘T` | a new tab — at the end of the bar, outside every group |
| `⌘W` | close the tab |
| `⌘⇧T` | put the last closed tab back where it stood, showing what it showed |
| `⌘L` | the caret in the address field |
| `⌘⇧N` | a new document — Markdown in a tab ([more](/en/research#documents)) |

`⌘⇧T` remembers ten tabs, and only for this run. A private window is not on the
list, and neither is a tab that never showed anything.

The last tab can be closed too. The window then shows **New Tab** in the middle
with "or ⌘T" under it. Savoia does not put a start page nobody asked for where the
closed tab stood, and an empty window survives quitting.

## Links

| | |
|---|---|
| a plain click | as everywhere |
| `⌘` + click | a new tab **behind** — the focus stays on the page you are reading |
| right-click ▸ **Open Link in New Window** | a new tab, and take me there |
| right-click ▸ **Open Link Behind** | the same as `⌘`-click |
| right-click ▸ **Open Link Beside** | a new tab beside this one — both pages on screen |
| right-click ▸ **Download Linked File** | download it without opening |

::: warning `⇧`-click and the middle button do nothing
And that is not an omission. WebKit hands `⇧`- and `⌘⇧`-clicks somewhere Savoia
cannot answer from, and a middle click arrives indistinguishable from a plain
one. So "open it and take me there" lives in the context menu, next to "open
behind".
:::

A link that is not the web — `magnet:`, `mailto:`, `tel:`, a custom scheme —
goes to the system rather than becoming a tab, and it does so wherever it was
clicked: in place, in a new tab, or pasted into the address bar. The address
bar hands one over only when an app on this Mac claims the scheme; with nothing
to open it, what was typed is a search like anything else. A `target=_blank` link
opens a tab, and it comes forward: it was opened to be looked at.

A window a page opens by script (`window.open`) — signing in through another service,
a payment — is a window of its own and not a tab: the page's title, its address under
it, and a lock while the connection is secure. It stays connected to the page that
opened it, so it can hand a result back and close itself; ⌘W closes it while it is in
front. WebKit's own popup blocking runs before any of this, so an ad that opens
itself gets no window.

## The page's context menu

It is entirely Savoia's own, because two of its link items could not be repaired in
anybody else's:

| on a link | always |
|---|---|
| Open Link | Back / Forward / Reload |
| Open Link in New Window | Cut / Copy / Paste / Select All |
| Open Link Behind | This Window ▸ … |
| Open Link Beside | |
| Download Linked File | |
| Copy Link | Share ▸ … |
| Share Link ▸ … | |

The price is what WebKit's menu knew about an element that is not a link: Save
Image, Copy Image, Look Up and the spelling suggestions. It is a trade: without
its own menu, those two link items would not work at all.

## Downloads

Files land in your **Downloads** folder under the name the server suggested, and
never overwrite: a second `report.pdf` becomes `report 2.pdf`.

The download ring appears in the top bar once something has been downloaded, and
not before. Inside: what is coming in and how far, **Stop**, **Resume** for one
that has stopped, **Show in Finder** when it is done, and a context menu per row —
open, copy the address, remove from the list. Removing a row never touches the
file.

**Resume** picks a transfer up where it left off: Savoia asks the server for the
missing bytes rather than for the file again, so the ninety per cent that went
down with the network stays where it is. A download that died on its own behaves
the same as one you stopped. When the server will not do that, the button is
honestly called **Try Again**: it starts over, but it still saves you finding the
page and the link a second time.

A download **flies** from the click to that button, and the button bounces when
it catches one: otherwise a click that put a file in a folder at the other end of
the screen looks like a click that did nothing.

A download belongs to the browser, not to the window that started it: closing the
window does not stop the transfer.

Unfinished downloads survive a relaunch: the row is still there after Savoia is
quit, saying **Interrupted** with the file's name and size, and the button offers
to fetch it again. It cannot pick up from the middle across a restart — the bytes
already downloaded were in a temporary folder the system is entitled to empty, so
promising them would be dishonest. Finished downloads are not kept: the file is in
the folder, and there is nothing to lose.

A window opened only to carry a link that turned out to be a file closes itself
once the download starts: nothing was in it, and there is nothing to go back to.

## Saving a page

| | |
|---|---|
| `⌘S` | save — a document that already has a file goes back to it |
| `⌘⇧S` | save as… |

A page saves as `.html`, `.pdf` or `.txt`; a document as `.md`, `.html` or
`.pdf`. The folder is remembered. There is no `.webarchive`.

## Sharing

**Sending a page to another app.** The **Share** button sits to the right of the
bookmark star. It opens the system's share menu: Mail, Messages, AirDrop, Notes,
and any other app that takes links. The same is in the page's context menu
(**Share**, and **Share Link** over a link). A start
page or a document has nothing to share, so the button is greyed out there.

**Taking a page from another app.** Savoia is in every app's Share menu: Safari,
Mail, Finder. Pick it, and a sheet comes up over that app and asks where the page
goes:

- the profile, if there is more than one;
- the workspace: each row shows its first windows' titles, the one open now is
  marked **Current**, and the last one, **New Workspace**, gives the page a row of
  its own;
- **Open** opens the page as a new tab in that group and brings Savoia forward;
- **Add to Bookmarks** saves the page to that workspace's profile without opening
  anything or bringing Savoia forward;
- the hand button is **Open in Private Window**.

What can be sent besides a link:

| what | what Savoia offers |
|---|---|
| a link, a page from Safari | Open, Add to Bookmarks |
| text that is just an address | the same as a link |
| any other text | **Search**, with your search engine |
| a PDF, HTML, web archive, image or plain-text file | Open |

Savoia is not offered for any other kind of file.

macOS registers extensions like this switched off, so Savoia switches itself into the
Share menu — once, at the first launch that finds it off. Turning it back off, and
on again, is where everything else is: **Configuration ▸ General ▸ Sharing ▸ Show
Savoia in the Share Menu**. It is the same switch as the one in System Settings,
without the hunt for it; and if you switch it off yourself, Savoia leaves it off.

## What Savoia tells sites it is

Safari's own string — the Safari installed on this machine, version number and
all. It is not a disguise: the engine, the JavaScript and the quirks really are
that Safari's. Naming ourselves in the same string is exactly what makes
Aviasales and Yandex answer "your browser is out of date", so Savoia does not name
itself there. Nothing beyond the string is faked.
