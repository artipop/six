# Picture in Picture

The video leaves the page for a small window above every other app and keeps playing. The page stays an ordinary tab.

| | |
|---|---|
| `⌥⇧P` | the tab's video into the floating window, and back |
| **View ▸ Picture in Picture** | the same thing |
| **Picture in Picture** in the [page's context menu](windows.md#the-page-s-context-menu) | the same thing |
| the button in the video's own controls | the same thing |

While the window is on screen you can switch tabs, fold the group or change profile: the player stays where it was and
keeps playing. A tab with such a video is not unloaded from memory, however many others are open.

## What to expect

- The menu item is never greyed out: only the page knows whether it has a video. Where there is none, nothing happens.
- If a site has taken `⌥⇧P` for itself, the shortcut stays with the site; in a text field it types its own character
  ([keys](hotkeys.md)).
- The system remembers the window's position and size, the same for every app. It cannot be tied to the Savoia window:
  the system draws the player.
