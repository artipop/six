# 26. A deep research saved as one file

Save a finished research run as a single self-contained `.html`.

## Why

A finished run is a document tab and the tabs of its sources, in a group of their own
([deep-research.md](../../deep-research.md)). Save As writes the document alone
(`Savoia/Documents/Export.swift`); the sources stay behind as addresses. A month later a page has changed or gone
and the citation leads nowhere, and there is nothing to send to someone but text with links.

## What to build

One more format in Save As for a research document: the document, and under it each cited source's readable copy
(`ReadablePage`, the text bookmarks already keep) with the highlighted passages marked, each citation in the
document linking to its passage inside the same file. No scripts and nothing fetched when it is opened — styles
inline, pictures left out or inlined under a size limit, decided by what a real run weighs.

A source whose tab has been closed has no page to read. Take its text from the bookmark if there is one, otherwise
say in the file that the source is a link only; do not load pages during a save.

## Done when

Save As offers the format on a research document, the file opens in Safari with its highlights visible and its
citations landing on them, and the size of one real run is written into deep-research.md. The label goes through
the String Catalog in English and Russian, and the guide's research page gets a line in both languages.
