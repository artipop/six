# Finding text on a page

`⌘F` — or **View ▸ Find on Page…** — opens the find bar under the address field, in the tab you pressed it in. The
caret is already in the field: type.

| | |
|---|---|
| the **Find** field | the page goes to a match and selects it as you type |
| **No Results** | shown in red when there is no match |
| `↩` or the ˅ button | **Next Match (⏎)** |
| `⇧↩` or the ˄ button | **Previous Match (⇧⏎)** |
| `Esc` or the cross | **Close (⎋)** |

After the last match the search wraps to the first, and the other way round.

## What is searched

- Case does not matter: `savoia` finds "Savoia".
- WebKit itself does the searching, as in Safari: the visible text of the page, embedded frames (`iframe`) included.

## Each tab has its own search

The bar belongs to the tab. Close it and the query stays: the next `⌘F` in that tab opens the bar with the same text.
In another tab the search starts with an empty field.

