# 10. What activates a page at load

Find why `navigator.userActivation.hasBeenActive` is `true` on a page that has just loaded and nobody has clicked.

## Measured

`isActive` is `false`. Every call Savoia makes at load was moved to `BrowserTab.callWithoutGesture`, and the flag
is still `true`, on three different origins in a row from an empty window
([page-scripts.md](../../page-scripts.md)).

## Suspects, none checked

- The `page.savoia(…)` calls that were not moved: highlights, `hasUserInput`, translation.
- The navigation itself, started with `page.load` by the `navigate` tool.
- User scripts.

## Method

A minimal app with a `WebPage` and a `load` and nothing else: is the flag there? Then switch Savoia's sources on
one at a time. Read the flag with `evaluate_javascript` over `Savoia --mcp`, which carries no gesture.

## Done when

The source is named and shown by "with it `true`, without it `false`" — or it is shown to be what WebKit does for a
load the application started.
