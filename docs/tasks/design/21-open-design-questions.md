# 21. Two questions with no answer chosen

Not work for a session alone: each needs Artem to pick, and the session's part is to make the options concrete —
build each cheaply behind a switch, or draw them — so the picking takes minutes.

## Two switches in the same corner mean two different sizes of thing

`savoia://configuration` has two panes that open with a switch, and the switch means something
different in each. Privacy puts **Block Ads and Trackers** in the pane's own header row, top right
beside the segmented picker (`ConfigurationPageView.PrivacyConfiguration`) — and it governs one of
the three segments, leaving Site Permissions and Certificates working. Assistant puts **Use Language
Models and Agents** in the first row of its Form (`AssistantPane`) — and it governs far more than
the pane: the ⌘E line, the agent path, the MCP server, the reading of a page's selection. So the switch that sits in the chrome, where it reads as the master of everything under it, is
the narrow one; the switch that sits in the list, where it reads as one setting among many, is the
broadest in the application.

Neither placement is wrong on its own, and the scopes are real — what is missing is a rule that
makes the difference visible before it is discovered. Options, none chosen: one place for a pane's
master switch and a sentence under it saying what it reaches; or the header row reserved for
switches that reach the whole pane, with the ad-blocking one moving down into Blocking's own list
where its scope is; or the broad one keeping its own shape, since turning off every model in the
browser is not the same kind of act as turning off a filter list.

Acceptance: a person who has used one of the two panes can predict, without trying it, how far the
other's switch reaches.

## The ring's arrows are three keys

`⌃⇧←` / `⌃⇧→` walk the cards while the ring is held open. The `⇧` is a tax, not a design: macOS
owns plain `⌃←` and `⌃→` for Mission Control's *Move left/right a space* (symbolic hotkeys 79 and 80,
enabled by default), and the WindowServer takes them before any application's event monitor — so the
two keys a person would reach for cannot be had at all on a default Mac. The binding matches any
modifiers, so one extra key is enough to get the event delivered, and `⇧` is the one already under the
hand from `⌃⇧Tab`.

Three keys to page a carousel is a bad answer wherever it is written down, and
another one has not been found yet: the ring is held open *by* `⌃`, so every key it can answer is a
`⌃` chord, and the arrows are the only pair that says "the card over there" without being learned.
