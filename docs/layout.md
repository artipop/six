# Tabs and groups

The window is a tab bar along the top, a toolbar under it with the address field, and the page in front filling the
rest (`Savoia/Views/TabStripView.swift`, `TabPageView.swift`). Underneath is `TilingLayout`, the model the scrollable
row used to draw — the row itself lives on the `dev` branch now, and the names here are the model's:

| the model | the tab bar |
|---|---|
| a column | a tab, or two tabs side by side |
| a named workspace | a tab group, coloured, labelled with the workspace's name |
| an unnamed workspace | tabs with no group |
| the focused column | the tab in front |
| the spare empty workspace at the end | nothing — it is not a group |

## Model — `Savoia/Tiling/TilingLayout.swift`

```
TilingStrip     workspaces: [TilingWorkspace], focus: Int      // one per profile
TilingWorkspace name, columns: [TilingColumn], focus, collapsed, blend, color
TilingColumn    tabID, second?, pane, pinned                  // points at one BrowserTab, or two
```

Every mutation goes through `mutate { }`, which runs `normalize` afterwards, so the invariants hold by construction:
exactly one empty workspace is kept at the end, empty ones in between are dropped unless they are named, pinned
columns stand first in their workspace, a blend whose parent stopped being a group is re-pointed or dropped, and every
group has a colour. `visibleTabIDs` is the focused column's tabs — what `LivePageCache` pins and builds.

A tab moving between workspaces is un-animated (`TilingLayout.unanimated`): a `WebPage` allows exactly one `WebView`,
and an animated move builds the second before the first has let go, which traps in `makeViewProvider`.

## A named group that runs out of tabs

A named workspace is a tab group, and naming is not something only a person does: `workspaceIndex(named:createIfMissing:)`
is called by every deep-research run (named after the question) and by the MCP tools (`open_window(workspace: "notes")`),
so a browser that answers questions for a living would silt up with empty groups carrying last week's questions.

The rule is now the same for every named workspace, whoever the name came from, and the difference is a question:

- `askBeforeRemoving` runs wherever a column leaves a workspace — `removeColumn`, `moveColumn`, `placeTab`, `split` —
  and queues a `TilingWorkspaceRemoval` (workspace id, name, profile) when that workspace is left empty *and* named. An
  unnamed workspace is never queued: it disappears as it always has, silently, a dozen times a day.
- `workspaceToRemove` is the head of the queue and what `WorkspaceRemovalDialog` draws on `ContentView`. `removeWorkspace(_:)` is yes, `keepWorkspace(_:)` is no, and dismissing the
  dialog any other way is a no — never an unanswered question read as consent.
- A **queue** and not one at a time: closing a profile or clearing a workspace can empty several workspaces, and a question that
  overwrote another would delete a workspace nobody was asked about. `removeProfile` drops the questions belonging to
  a profile being deleted whole, and `prunePendingRemovals` (after every `mutate`) drops any whose workspace has been filled
  again or has gone — a question is only worth asking while it is still true.

Asking is deliberately a *transition* and not part of `normalize`: normalize cannot tell a workspace that has become empty
from one that was made a moment ago, and every caller of `workspaceIndex(named:createIfMissing:)` creates a named
empty workspace and fills it on the next line. "Close Group" clears the name before closing the tabs, because closing the
group *is* the answer to the question.

## The tab bar

A group is a *named* workspace (`TabGroup.isGroup`); an unnamed one is tabs with no group, so two unnamed workspaces
side by side read as one run of plain tabs. "Add Tab to New Group" opens the name field straight away, and a new
group closed with the field empty keeps "Workspace N" as its name, or it would stop being a group the moment it was
made; emptying a name that was there is "Ungroup". `⌘T` and the bar's + are `newTabAtEnd` — the last workspace when
that has no name, the spare one otherwise — and a tab dropped on the bare bar goes the same place (`moveTabToEnd`).
"Remove from Group" puts the tab at the front of the ungrouped workspace just after the group, or in a new one of its
own; the last tab of a group ungroups it instead, so no named workspace is left to ask about. The colour is kept on
the workspace, so a group does not change colour when the one before it is closed.

A **pinned** tab is its column's `TilingColumn.pinned` (optional, so older files read as unpinned). The column stays in
its workspace — `normalize` only keeps it first there — but the tab bar takes it out of that group (`TabGroup.tabIDs`
leaves it out) and draws every pinned tab of the profile as an icon at the bar's left edge, outside the scrolling part
(`BrowserState.pinnedTabIDs`, which `tabOrder` also puts first). Folding, "Close Group", "Close Other Tabs" and
`TabSorter` pass over them.

A group **folds** up to its label (`TilingWorkspace.collapsed`, optional so an older session file reads as every group
open). A group cannot fold over the tab in front: the neighbouring tab is shown first, and if every other tab is folded
away too a new tab is opened at the end — Chrome's answer to the same question. `⌘⇧[` `⌘⇧]` and `⌘1…⌘9` skip folded
groups; the ring does not.

**Picking several tabs** is Chrome's on a Mac: `⌘`-click adds or removes one, `⇧`-click takes the run from the last
tab clicked without `⇧` (`BrowserState.clickTab`, `pickedTabs`). The tab in front is always among them, and anything
that moves it without a click starts the pick again from there (`syncSelection`). The tab menu, opened on a picked
tab, acts on all of them: `moveTabsToNewGroup`, `moveTabs(_:toGroup:)`, `closeTabs`. `⌃` is not the modifier because a
`⌃`-click on a Mac is the secondary click.

Dragging carries one tab, and it is AppKit's (`TabDragSource`, in `TabBarMouse.swift`): the tab bar lies in the band
the hidden title bar still owns, and a drag there moved the whole window, so SwiftUI's `.draggable` never started. The
view takes the left button's click and drag and lets the right button, `⌃`-click, the scroll wheel and the tab's ×
fall through to SwiftUI. While the tab bar is on screen the window is not movable at all (`WindowMover`), and the
bar's bare background moves it by hand and zooms it on a double-click, honouring `AppleActionOnDoubleClick`.

The verbs are `TilingLayout.placeTab` — one tab to a column index in a workspace, by workspace id, the focus following
it — `placeTabInNewWorkspace` for "Add Tab to New Group", and `setCollapsed`. The File and View menus read the model
when they are about to be used; a focused value would change with every click and have SwiftUI fill the File menu in
again, after which ⌘W belonged to the system's Close and quit Savoia (AGENTS.md).

## Two tabs side by side

Two picked tabs are **shown side by side** — `showSideBySide`, which is `TilingLayout.split(tabID:with:in:)`: the
second tab joins the first's column from wherever it was, another group included — and taken apart with `separate`,
which puts the right half into a column of its own just after it. Two is the ceiling. `TabbedWindowView` draws the
column's halves in one `ForEach` keyed by tab, so a tab joining or leaving a pair keeps its view. The half that has
the keyboard is underlined; the other half is a target, not a page — the first click on it selects it
(`TabPageView`'s `ClickCatcher`, an AppKit view because `WKWebView` takes the click before any SwiftUI overlay).
Both halves are built by the live-page budget, and closing one leaves the other filling the column.

The width changes in one step (`BrowserState.plainLayoutChange`): WebKit lays a live page out again at every width an
animation passes through, and animated, two pages walked through eight widths in a tenth of a second with a
horizontal scrollbar at each.

**The keyboard follows the selection.** The selection and AppKit's first responder are two different things:
everything keyed off the selection — the address field, `⌘W`, the assistant — follows it, while the keys would go on
arriving in the `WKWebView` a click had last given them to. `WebViewResponder` closes it: each pane leaves a zero-size
AppKit view beside its own web view, which finds it by frame, and `ContentView` hands the keyboard to the selected
tab's. It never takes the keyboard off a text field.

## ⌃Tab — the order the tabs were looked at

The tab bar is where tabs *are*; `WindowSwitcher` is where they have *been*. `⌃Tab` opens the ring over every tab of
the profile, every group, folded ones included (`BrowserState.tabOrder`); `⌃⇧Tab` over the group in front
(`groupOrder`). Once it is open they are forward and back.

- Recency is taken in `BrowserState.syncSelection`, the one place every focus change ends. This run only, like the
  list `⌘⇧T` reopens from.
- The ring is fixed when the switch opens and does not reorder while it is held, and it wraps. Tabs never focused this
  run follow in tab-bar order. One tab opens a ring of one: the key has to answer.
- `WindowSwitcher` keeps two orders: `walk` is what ⌃Tab moves through, `ring` is what is drawn; the arrows
  (`walkCards`) move along the drawn order.
- **The open ring outranks the caret** (`KeyBinding.yieldsToCaret(in:)`), so `⌃→` over a ring opened from the address
  field moves the card, not the caret.
- Nothing is loaded while it is walked: the cards are the pictures `PageThumbnails` keeps. The flight happens once, on
  `⌃` coming up, through `selectTab`.

The keys come through `KeyRouter`: a first-responder `WKWebView` answers a key equivalent before the menu bar sees it,
and the ring is held open by a modifier, which only a `flagsChanged` says was let go of. Any key that is not the
ring's ends the pass and is passed on. The panel is `WindowSwitcherOverlay`, over the tab bar as well, and it answers
no mouse.

## Picture-in-picture

`⌥⇧P`, View ▸ Picture in Picture, the same item in the page's context menu, and the button in WebKit's media controls:
the video leaves the page for a small window floating above every other application, and the page it left goes on
being an ordinary tab. Switch tabs, fold the group, switch profiles — the player stays where it was put and keeps
playing. That is the whole point of it, and it is why it needs Savoia's help twice.

**Turning it on.** WebKit has the feature and hands the new API no switch for it. The preference is real —
`WKPreferencesSetAllowsPictureInPictureMediaPlayback` is exported by the framework on macOS — but the only public way
to set it is `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback`, which is declared for iOS alone, and
`WebPage.Configuration` has no field for it at all. Off is the default, and off is silent in exactly the way element
fullscreen was: no button in the media controls,
`video.webkitSupportsPresentationMode('picture-in-picture')` false, and `video.requestPictureInPicture()` rejecting
with `NotSupportedError — The video element does not support the Picture-in-Picture mode`. Measured on a plain
`<video>` through Savoia's own MCP server, the day after the fullscreen fix landed: `{"pip": false, "fs": true}`.

So it is SPI: `WKPreferences._setAllowsPictureInPictureMediaPlayback:` to turn it on, `WKWebView._togglePictureInPicture`
for the menu item and the key, `_isPictureInPictureActive` for the question below. All of it lives in
`Savoia/Browser/PagePictureInPicture.swift`, all of it behind `responds(to:)`, on the terms [todo.md](todo.md) already
set for SPI here: Savoia is not sandboxed and not on the App Store, so the only risk is a selector going away in a macOS
update, and the shape that takes is a feature that is quietly not there rather than a crash. The way to the
`WKWebView` behind a `WebPage`, which the new API does not hand out, is `WebViewResponder`'s — the same view-tree
lookup the keyboard, extensions and screen sharing use — so the preference is set when a pane first shows the page
rather than when the page is built. It used to be `Mirror` into the page's `lazy` storage: that worked, and was a
second way in whose failure the type checker never sees.

**Keeping it alive.** A tab that is not in front loses its `WebView`, and eventually its page (`LivePageCache`).
Losing the view does not matter: the floating player is a window of WebKit's, not a subview, and it goes on playing
while the tab that owns it is unmounted. Losing the *page* would take the video
off the screen the user is looking at, so `keepAliveReason` asks `isInPictureInPicture` before anything else. The
"playing media" guard that was already there does not cover it: a floating player paused for a moment is still a
window somebody put on their screen on purpose.

Whether a window is in picture-in-picture is read off WebKit every time rather than remembered, because Savoia is not
the only one who can put it there — the media controls' button, a site's own button and `⌥⇧P` all end in the same
place, and a flag Savoia kept would be right only for the third. Nothing observes it, so nothing has to be told: the
menu asks when it is opened, the budget asks when it is about to evict, and both are moments where the answer is used
at once. For the same reason the menu item is never greyed out — whether the page in front of you has a video to
float is a question only the page can answer, and it changes with every play and pause without telling anyone.

**Where the window sits, and why Savoia cannot move it.** The floating player is not Savoia's window and not WebKit's
either: `WebPage` → `PIPViewController` → `PIPPanel` all live in Savoia's process, but the thing on the screen is drawn by
`/System/Library/CoreServices/PIPAgent.app`, in a process of its own, on CoreGraphics layer 19 — above every ordinary
window, below the Dock. Savoia's `PIPPanel` sits at level 0 and never appears in the on-screen window list at all; it is
where the events go, and the agent is where the pixels are. Three things follow, each of them measured rather than
reasoned:

* **It cannot be tied to Savoia's window.** `addChildWindow` on the `PIPPanel` succeeds and the panel dutifully follows
  its parent around, and nothing on the screen moves — and worse, the player then survives leaving picture-in-picture,
  still visible six seconds later, because a child window is ordered back in by its parent after WebKit orders it out.
* **It cannot be placed.** The agent snaps the player to a corner of the **screen**, not of the window that owns the
  video, and remembers the choice for every application at once (`com.apple.PIPAgent`: `Corner`, and `Size` as a
  fraction of the screen). Measured with a host window 1100 points wide at (100, 120): the player landed in the corner
  of a 1440-point screen.
* **`PIPViewController._pipSetWindowContentRect:completion:` is the wrong direction.** It is how the agent tells Savoia
  where the player went; calling it moves Savoia's invisible `PIPPanel` and leaves the agent's window where it was.

This is what Safari gets, for the same reason — the whole path is WebKit's. Chrome and Firefox place and level their
mini-players because they draw them, and drawing one is not something a browser built on `WebPage` can do: there is no
way to take a `<video>` out of a page and into a window of one's own. So the two asks this produced — that the player
travel with the browser on ⌘Tab, and that it sit under the top bar rather than over it — are not bugs with a fix here.
The other feature of the same name is the answer if they matter enough: any tab as a floating always-on-top panel —
Savoia's own `NSPanel` and therefore Savoia's to parent and to place. It is not built; it is in [todo.md](todo.md).

## Groups by meaning

**Sorted by meaning** (`TabSorter`, `TabTopics`, `ConfigurationStore.sortsTabsByMeaning`, off by default and
outside the AI switch). A web tab that finishes loading is embedded — its title with the site's name taken off, plus
the first sentence of its meta description or first real paragraph, cut to 120 characters — by the bookmark index's
own e5, with `query:` on both sides. Only a tab opened since the sorter last looked, or one that has gone to another
site, is placed; a tab restored at launch is only noted. `TabTopics.classify` then asks how far the best group is
*ahead*: of the second group, of the tab's median similarity to every tab (`background`), and of its nearest
ungrouped tab (`loose`). Ahead by `joins` (0.035) it goes in, focus following (`placeTab`); two groups within `tie`
of each other and both `betweenLead` ahead of the rest put it in the workspace between them. Ahead of the other groups and
its `background` by `near` (0.035, the same as `joins`) and kept out only by a loose tab no more than `betweenLead`
nearer, it goes into a workspace right after the group (`.near`). Ungrouped tabs are clustered average-linkage over how much closer two are than
either usually is to *every* tab, and three or more become a group.

**Rows between groups** (`TilingWorkspace.blend`, `TilingBlend`). The near verdict exists because of `loose`: four
recipes joined «Ужин», the next four arrived together, each was nearer the others than the group, and they became a
second group, «Кулинария», beside it. `near` ignores a loose tab about as close as the group, so they now stand next
to «Ужин» instead. `near` is not lower because e5-small cannot tell a near miss from a stray: a curry recipe led
the other groups by 0.029, a weather forecast led them (football) by 0.028; at 0.02 both went next to a group. What
tells them apart is a loose tab about as near, which the recipes have and the strays do not.

`SAVOIA_TOPICS_SELFTEST=batch` (four recipes arriving together after a food group, two tabs about food and football,
two strays) and `=live` (the same with Wikipedia pages in a new profile, through `TabSorter` itself):

| | recipes | between | strays |
|---|---|---|---|
| e5-small, before `near` | 0/4, all loose | 0/2 | 2/2 kept |
| e5-small, `near` at 0.02 | 1 in, 3 next to it | 0/2 | 0/2 — both next to football |
| e5-small, `near` at 0.035 | 3 next to it, 1 loose | 0/2 | 2/2 kept |
| e5-base, `near` at 0.035 | 0/4 | 0/2 | 1 next to football |
| live, e5-small | Solyanka in; pilaf, curry, ramen next to it, named «Азиатская кухня» | 0/1 | 2/2 kept |
| Gemma 4 E2B as the chooser | 4/4 in | 0/2, both to football | 2/2 kept |
| Qwen 2.5 1.5B | 2/4 | 0/2 | 2/2 |
| Gemma 3 1B | 0/4, everything to football | — | 0/2 |

`=compare` with `near` at 0.035: held-out 8/12, strays 5/5, between 1/2 — as before it. A blend workspace is a group in the tab bar whether or not it is named: its title is its parents'
names («Ужин · Спорт», «≈ Ужин») until the namer answers, which it is asked once the workspace has two tabs. The blend
belongs to the workspace, not the tab, so a tab dragged in takes its colour and one dragged out loses it. Its menu merges
it into a parent or makes it a group of its own. In `normalize`, a blend whose parent stops being a group (ungrouped,
closed) stands next to the other parent; with neither left it is ungrouped tabs, or a group of its own if the person
named it. A session saved with the old per-column `lean` has it moved to the workspace.

**Colours** (`GroupColor`). OKLCH, mixed with lightness and chroma linear and the hue the short way round, then the
chroma cut back into sRGB: red and yellow give orange, blue and yellow green, where an RGB mix goes through grey.
The palette starts with blue, red and yellow so the first three groups' mixes are the secondaries. A group is given
the first palette entry no other group has, kept on the workspace (`TilingWorkspace.color`), so closing one does not
recolour the rest; a group next to one group is that colour faded towards a pale neutral by its weight.

**Names and the local model.** A new group is named at once by c-TF-IDF over its tabs' text (or the host), then
renamed in the background, unless the person has renamed it meanwhile. With the AI switch on, the assistant's own
choice answers: a language model through `AssistantSettings.namingSession`, or an ACP agent through `AgentErrands` —
a second connection to the same agent, a fresh session per question in `Agents/Errands` inside Savoia's folder, tools
refused, so nothing lands in the person's chat (Claude Code: 9 s for the first name, spawn included, 4 s after).
Otherwise, and when that fails, the **local model** (`LocalLanguageModel`, `LocalModelChoice`, Configuration ▸ Tabs):
Gemma 3 1B by default, Qwen 2.5 1.5B, or Gemma 4 E2B, through MLXLLM from the `mlx-swift-lm` package the embedder
already uses. It is loaded for the question and let go a minute after the last one. The answer has to be in the
interface's script (a title's own words excepted), or the c-TF-IDF name stays. The examples are earlier chat turns,
not text in the question: asked for Russian, the small models answered in English and once in Chinese; shown an
answer inside the question, they copied it onto every group.

**Sort By** (`TabSortingMethod`) picks what places a tab: the embeddings above (the default), or the local model
asked outright, "which of these numbered groups, 0 for none, two numbers for both" (`LocalLanguageModel.choose`).
New groups are always found by the embeddings.

Measured with `SAVOIA_TOPICS_SELFTEST` on this 8 GB M2 (`=compare` for placing, `SAVOIA_LOCAL_MODEL=<case>` for naming):

| | naming, 5 groups (ru UI) | placing: own topic / strays left / between | per tab |
|---|---|---|---|
| e5 embeddings | — | 8/12 · 5/5 · 1/2 | ~0 |
| Gemma 3 1B (770 MB) | 4/5 | 4/12 · 0/5 · 0/2 — nearly all to the last group | 2.3 s |
| Qwen 2.5 1.5B (870 MB) | 4/5 | 8/12 · 3/5 · 0/2 | 0.6 s |
| Gemma 4 E2B (3.6 GB) | 5/5 | 11/12 · 5/5 · 0/2, both into one of the two | 5.6 s |

Qwen 2.5 0.5B and Gemma 3 270M were tried and are not offered: the first answered «Конcurrency» and «Делимаки», the
second copied the example. Gemma 3 1B is the default for naming because it is the smallest that names well; for
placing, only Gemma 4 beat the embeddings, at a cost this Mac feels.

**What it costs.** e5 stays loaded once sorting has used it (~235 MB, the bookmark index's own); the local model is
loaded for an answer and let go after a minute. MLX keeps freed buffers for reuse, and with both models that cache
took Savoia's footprint to 2.9 GB on this 8 GB Mac — swap, which is what the machine felt like. The cache is capped at
64 MB and cleared after each embedding pass and each answer (`LocalLanguageModel.trimMemory`). Measured on the main
process over the same Wikipedia pages (vmmap physical footprint): with sorting on, 1.3 GB while Gemma 3 1B is loaded,
~600 MB once it is let go; CPU about twice sorting-off's while pages load (10 s against 5 s for four cold pages,
most of it loading the models once), and the same when idle. If a name comes back in the wrong script, the model
is asked once more in the interface's language before the c-TF-IDF name is kept.

Why a lead and not Firefox's absolute threshold: `SAVOIA_TOPICS_SELFTEST=1` (`grid` for the model and prefix
comparison) on e5-small puts every title cosine between 0.75 and 0.92, and "Купить билеты на поезд" scores 0.851
with football where a match report scores 0.834. `query:` separates same-topic from cross-topic pairs 0.91 of the
time against `passage:`'s 0.77, and e5-base did worse than small on titles (0.73). Two more things were measured in
the running app: a whole paragraph made a bread article nearer a tech site's blurb than any title did (long texts
are alike for being long, hence the 120 characters), and a background taken over the loose tabs alone never let
four recipes cluster, because half the loose tabs were the recipes. What it gets wrong: a Russian title on a mostly
English topic stays out (e5-small keeps languages apart on short text).

The person wins. The sorter remembers the workspace it last put or saw each tab in (in memory); a tab found anywhere else
was moved by hand and is left alone until it goes to another site, a split is never touched, and a group it made
that was ungrouped marks its tabs the same way.

What the tab bar does **not** have yet: tabs from several profiles side by side (it shows the profile on screen),
dragging a tab out into a group of its own (the tab menu's "Add Tab to New Group" does that), and group colours
chosen by hand.
