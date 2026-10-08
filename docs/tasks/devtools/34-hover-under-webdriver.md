# 34. A pointer move under WebDriver that hovers nothing

Measured on 8 October 2026, macOS 27.2, dev build, wpt `1d99362`, `scripts/wpt.py` under wptrunner: the files of
`pointerevents`, `uievents` and `css/selectors` that use testdriver and name `mouseover`, `mouseenter`, `:hover` or
their pointer twins, less the thirteen that also name a drag. 58 files, 85 addresses with their variants.

**60 came out as Safari's row, 25 did not: 24 below it and one above.** Eleven of the 24 timed out.
`css/selectors` has six of its seven below Safari, and the messages are plain: after a bare `pointerMove` onto an
element, `:hover` does not match it ("#a should be hovered before the gesture expected true got false"), and a
test that waits for `mouseover` waits out its time. Where a button is down the events arrive, in another order
than the test wants.

The move is WebKit's own: `POST /session/{id}/actions` becomes `performInteractionSequence` with
`mouseInteraction: "Move"` (`WebDriverInput.sequence`, `WebDriverServer`), the command `safaridriver` sends. So
the difference is in what receives it, not in what is sent.

## Where to look

1. **Whether the window was key.** The run was made with a terminal in front. Before 7 October the runner's move
   was a `mouseMoved` the view never saw in a window that was not key, and `PageActions.hover` sends a dragged
   event for that reason ([agent-actions.md](../../agent-actions.md#hover-and-drag-the-pointer)). One file —
   `/css/selectors/hover-002.html` — with Savoia in front and then behind settles whether this is the same fault.
2. **What `AutomatedWebView` does with a move.** It takes the first mouse so that a click lands from behind
   (`Savoia/DevTools/Automation.swift`); a move has no such door. Safari's automation window is key while a
   session runs.
3. **The one file above Safari**, `pointermove_after_pointerover_target_removed.tentative.html` at 4/4 against
   3/4: Safari's row is 27.0 and this Mac is 27.2, so it may be WebKit's and not Savoia's.

The thirteen files that name a drag were left out and still are: a press and a move over a `draggable` element may
start a real dragging session ([unmeasured.md](../../unmeasured.md#an-agents-hover-and-drag-past-the-stand-page)).
The permission baseline was not rerun.

To run them again:

```sh
cd ~/Library/Caches/savoia-wpt
grep -rlE "testdriver" pointerevents uievents css/selectors | xargs grep -lE "mouseover|mouseenter|:hover|pointerover|pointerenter" \
  | grep -v "/resources/\|/support/" | xargs grep -LiE "drag|dnd"
# then, from the repository, each as an --only:
./scripts/wpt.py pointerevents uievents css/selectors --only /css/selectors/hover-002.html …
```

## Done when

`:hover` matches after a `pointerMove` with Savoia behind another app, or [devtools.md](../../devtools.md) says
why it cannot; and the 25 files are run again and their rows written down.
