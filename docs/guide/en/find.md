# Finding text on a page

`⌘F` — or **View ▸ Find on Page…** — opens the find bar under the address field, in the tab you pressed it in. The
caret is already in the field: type.

| | |
|---|---|
| the **Find** field | matches are highlighted on the page as you type |
| "2 of 5" | the current match and how many there are; a red **No Results** when there are none |
| `↩` or the ˅ button | **Next Match (⏎)** |
| `⇧↩` or the ˄ button | **Previous Match (⇧⏎)** |
| `Esc` or the cross | **Close (⎋)**: the highlighting goes away |

After the last match the search wraps to the first, and the other way round.

## What is searched

- Case does not matter: `savoia` finds "Savoia".
- The visible text of the page is searched. Hidden elements, form fields, buttons, and text inside video, `canvas` and
  embedded frames (`iframe`) are skipped.
- Code inside `<pre>` and `<code>` blocks is found.

## Each tab has its own search

The bar belongs to the tab. Close it and the query stays: the next `⌘F` in that tab opens the bar with the same text.
In another tab the search starts with an empty field.

