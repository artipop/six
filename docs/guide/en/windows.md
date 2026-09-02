# Windows, links and downloads

## Open, close, bring back

| | |
|---|---|
| `⌘T` | a new window right of the focused one |
| `⌘W` | close the focused one |
| `⌘⇧T` | put the last closed window back where it stood, showing what it showed |
| `⌘L` | the caret in the address field |
| `⌘⇧N` | a new document — a Markdown column beside the pages ([more](/en/research#documents)) |

`⌘⇧T` remembers ten windows, and only for this run. A private window is not on
the list, and neither is one that never showed anything.

The `×` sits on the window's own top right corner. It is mostly over the gap, so
the page keeps its clicks, and it is invisible until the pointer is on it: a
rail of a dozen windows should not be a row of a dozen crosses.

## Links

| | |
|---|---|
| a plain click | as everywhere |
| `⌘` + click | a new window to the right, **behind** — the focus stays on the page you are reading, and the rail leans right for a moment to show what arrived |
| right-click ▸ **Open Link in New Window** | the same, and take me there |
| right-click ▸ **Open Link Behind** | the same as `⌘`-click |
| right-click ▸ **Download Linked File** | download it without opening |

::: warning `⇧`-click and the middle button do nothing
And that is not an omission. WebKit hands `⇧`- and `⌘⇧`-clicks somewhere VI
cannot answer from, and a middle click arrives indistinguishable from a plain
one. So "open it and take me there" lives in the context menu, next to "open
behind".
:::

A link that is not the web — `mailto:`, `tel:`, a custom scheme — goes to the
system rather than becoming a window. A page that opened a window itself
(`window.open`, a `target=_blank` link) comes forward: it was opened to be looked
at. WebKit's own popup blocking runs before any of this, so an ad that opens
itself gets no column.

## The page's context menu

It is entirely VI's own, because two of its link items could not be repaired in
anybody else's:

| on a link | always |
|---|---|
| Open Link | Back / Forward / Reload |
| Open Link in New Window | Cut / Copy / Paste / Select All |
| Open Link Behind | This Window ▸ … |
| Download Linked File | |
| Copy Link | |

The price is what WebKit's menu knew about an element that is not a link: Save
Image, Copy Image, Look Up and the spelling suggestions. It is a trade: without
its own menu, those two link items would not work at all.

## Downloads

Files land in your **Downloads** folder under the name the server suggested, and
never overwrite: a second `report.pdf` becomes `report 2.pdf`.

The download ring appears in the top bar once something has been downloaded, and
not before. Inside: what is coming in and how far, **Stop**, **Show in Finder**
when it is done, and a context menu per row — open, copy the address, remove from
the list. Removing a row never touches the file.

A download **flies** from the click to that button, and the button bounces when
it catches one: otherwise a click that put a file in a folder at the other end of
the screen looks like a click that did nothing.

A download belongs to the browser, not to the window that started it: closing the
window does not stop the transfer. The list is in memory only and is not written
to the session snapshot, in any profile. An interrupted download cannot be
resumed.

A window opened only to carry a link that turned out to be a file closes itself
once the download starts: nothing was in it, and there is nothing to go back to.

## Saving a page

| | |
|---|---|
| `⌘S` | save — a document that already has a file goes back to it |
| `⌘⇧S` | save as… |

A page saves as `.html`, `.pdf` or `.txt`; a document as `.md`, `.html` or
`.pdf`. The folder is remembered. There is no `.webarchive`.

## The "This Window" menu

A right-click on the page opens it too: close, full width, move left/right,
move to the workspace above or below. It used to hang off the
window's title bar; there are no title bars any more — the page runs edge to edge
— so it hangs off the page.

## What VI tells sites it is

Safari's own string — the Safari installed on this machine, version number and
all. It is not a disguise: the engine, the JavaScript and the quirks really are
that Safari's. Naming ourselves in the same string is exactly what makes
Aviasales and Yandex answer "your browser is out of date", so VI does not name
itself there. Nothing beyond the string is faked.
