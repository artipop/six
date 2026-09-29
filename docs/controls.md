# Controls

Every mouse control, and the keyboard in short.

## Mouse

| | |
|---|---|
| click a tab | brings it to the front. `⌘`-click adds it to the picked tabs or takes it out, `⇧`-click picks the run from the last tab clicked; the tab menu then acts on every picked tab |
| drag a tab | along the bar, onto another group's label, or onto the empty end of the bar to take it out of its group (`TabDragSource`, AppKit's, because the bar lies in the hidden title bar's band) |
| click a group's label | fold the group up to it, and again to open it |
| right-click a group's label | New Tab in Group, Rename Group…, Collapse / Expand Group, Ungroup, Close Group; for a group between two, Merge into … and Make Separate Group |
| right-click a tab | New Tab to the Right, Add Tab to New Group, Move Tab to Group, Remove from Group, Pin / Unpin Tab, Show Side by Side (two picked), Stop Showing Side by Side, Close Other Tabs |
| the empty part of the tab bar | moves the window; a double-click zooms it, honouring `AppleActionOnDoubleClick` |
| the other half of a pair | the first click selects it; the second reaches the page |
| ⌘-click a link | opens it in a new tab **behind** — the focus stays on the page you are reading. To go there instead, the context menu's Open Link in New Tab: WebKit swallows every shift-click before Savoia sees it, and a middle click cannot be told from a plain one ([links.md](links.md)) |
| right-click a page | Savoia's own menu: on a link, Open Link / in New Tab / Behind / Beside / Download Linked File / Copy Link; always Back, Forward, Reload, the clipboard, Picture in Picture, Move to Profile ([what that rebuilds](architecture.md#moving-a-tab-to-another-profile)) and Close Tab. WebKit's menu could not be repaired in place — [links.md](links.md) has why |
| the download ring (toolbar) | there once something has been downloaded: what is coming in, Stop, and Show in Finder when it is done. A download flies there from the click ([links.md](links.md)) |
| the address field (toolbar) | one field, for the tab in front, with back/forward/reload beside it, and the lock, the shield, the camera light and the highlighter with it. `⌘L` puts the caret in it |
| the bookmark star (toolbar) | against the right edge of the address field: save the page — filled when it is saved; again to remove. `⌘⌥B` lists and searches them, and what is saved comes back as rows under the start page's field ([start-page.md](start-page.md)) |
| the lock / globe in the address field | once a site has been answered about the camera, the microphone or the motion sensors: flip an answer, forget the site, or open the whole list ([permissions.md](permissions.md)) |
| the red camera / mic / screen in the address field | one per device, only while the page is actually using it — click to mute that device, click again to bring it back |
| the engine chip on the start page | the search engine — for queries and for the suggestions; also under Configuration ▸ General ▸ Search Engine |
| the profile button (toolbar, right) | which profile you are in, by name. It opens onto the list: click one to switch, or unfold a row to rename it, pick its colour and delete it. New Profile at the bottom, and Private Window when there isn't one |

A named group that runs out of tabs asks first — *Delete the group "X"?* — and stands if you keep it; an unnamed one
goes without asking ([layout.md](layout.md#a-named-group-that-runs-out-of-tabs)).

## Keyboard

Every binding is in [hotkeys.md](hotkeys.md). In short: `⌘T` `⌘W` `⌘⇧T` `⌘⇧]` `⌘⇧[` `⌘1`…`⌘9` for tabs, `⌃Tab` held
flies to a tab by how recently it was used rather than by where it stands, `⌥⇧T` `⌥⇧H` `⌥⇧P` are about the page, and
`⌘L` `⌘E` `⌘D` `⌘⌥B` `⌘Y` `⌘,` are the browser's.
