# Bookmarks and history

A bookmark in VI is three things at once: a row in a list, **a readable copy of
the page as a file on disk**, and a place in an index that finds it by what it
was about rather than by its title.

| | |
|---|---|
| `⌘D` | bookmark the focused page (again: remove it) |
| the star beside the address field | the same; filled when the page is saved |
| `⌘⌥B` | the list, and the search across it |

## What is saved

Not an address — the page. VI pulls the main content out of it (headings,
paragraphs, lists, quotes, code, links, tables, large images) and writes a
Markdown file beside the row, in `Profiles/<name>/Bookmarks/`. Navigation,
sidebars, footers, forms, cookie notices and anything calling itself comments or
a newsletter are dropped.

So what you saved is readable a year later, and without the site. The file starts
with the title, address, site, language, profile and date — enough to rebuild the
row if the database is ever lost. Removing the bookmark removes the file.

## Search by meaning

`⌘⌥B` searches not the letters of a title but what the page was about. Under each
hit is the passage that matched.

It works **across languages**: a Russian question finds an English page and the
other way round. The model behind it (~470 MB) is downloaded once on first use
and never leaves the machine afterwards; while it comes in, the bookmarks
window's footer says so. Search by title works from the first second, waiting for
nothing. Once the model is on the machine it is loaded as soon as the window
opens — while you are still typing the first question — so the first search of a
session is as quick as the rest. Opening a window never fetches it; only a search
does.

::: tip What is honest to say about the quality
Within one language the ranking is right. Across languages it is right for topics
and shaky for details: an English question about a number in a Russian paragraph
can lose to an unrelated English page.
:::

`↑` `↓` walk the rows straight from the search field, `↩` opens the selected one
in a new window, `⌘⌫` removes the bookmark and its file, `Esc` closes. The
context menu has **Show File in Finder**.

### Which model

VI picks one for your Mac and says which: **Settings ▸ General ▸ Bookmarks ▸ Model for
Search by Meaning**. Below 16 GB of memory the recommendation is **Compact — 465 MB**,
above it **Larger — 1.1 GB**; the recommended one is marked in the list. The other is
yours to take, at your own risk — larger ranks a little better between languages, but
downloads twice as much and keeps twice as much memory busy for as long as VI runs, and
on a small Mac it is the open pages that pay for that.

Changing the model re-indexes: every saved page is embedded again by the new one. Search
by meaning goes quiet while that happens — the pages themselves are not going anywhere —
and the footer of the bookmarks window says how far it has got.

## Without being asked

The same search runs where you are not searching for anything — under the
[start page's field](/en/start#the-personal-half). As you type, up to two of your
saved pages stand above the engine's completions, when they are about it. There
is nothing to switch on: with bookmarks the rows appear, without them nothing
does, and the model is not downloaded for it.

A private window has none of them.

## Pages change

Bookmarks are re-read on a schedule: **Bookmarks ▸ Re-read Saved Pages** — never
/ daily / **weekly** (the default) / monthly. It happens in the background, one
page at a time, with the profile's cookies — so a page behind a login is read as
you see it.

If the text has not changed, only the date is stamped. If it has, the file and
the index are rewritten. If the page will not load, the old copy stays and an
orange arrow appears on the row with the reason.

**Refresh Bookmark** and **Refresh `<profile>` Bookmarks** do the same on demand.

## On Windows and Linux

The star is there too, and the same index is behind it. **On Windows** it is to
the right of the address, and `Ctrl+D` does the same; **on Linux** it is the star
in the toolbar, with `Ctrl+D` beside it. Press to save, press again to forget. A
filled star takes the profile's colour: a bookmark belongs to a profile rather
than to the browser.

The model behind search by meaning is the same one — multilingual-e5-small — but
it arrives by a different road: not through Metal, which those machines do not
have, but through the page engine six already ships. There is one honest
difference: the model has to be downloaded, about 155 MB, once. That starts with
the first page you save rather than at launch.

Two things are missing on both: six saves the title, the description and the
address but does not read the page's text yet, so a bookmark is found by what it
is about rather than by a phrase from the middle of it. And there is no bookmarks
window there — the list and the search are still the Mac's.

## What the assistant and the agents see

**Bookmarks ▸ Assistant Searches: This Profile / All Profiles** is one setting
for all of it: it decides whose bookmarks the [⌘K assistant](/en/assistant) and
the [agents](/en/agents) look in when nothing says otherwise. They can list
bookmarks, search them by meaning, read a saved file whole, add, refresh and
remove one.

The agents' working directory is deliberately **not** the bookmarks folder: a
question about something saved should go through the search rather than through a
`grep` over the working directory.
