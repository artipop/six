# Tabs instead of the row

Out of the box six shows its window the way every other browser does: a tab
bar at the top, the address field under it, and one page below. The row is the
same windows laid out another way, and it is one switch away.

Switch it in **Configuration ▸ Windows ▸ Show Windows As**: **Row** or **Tabs**.
**View ▸ Show Tabs** does the same.

## Nothing is lost

It is not a different browser, only another way of looking at the same row.
Switch back and forth as often as you like:

| in the row | with tabs |
|---|---|
| a window | a tab |
| a workspace | a tab group named after the workspace |
| the focused window | the tab in front |
| two windows in one column | two tabs side by side |

Whatever you opened, closed, dragged or renamed with the tabs up is in the row
when you go back to it.

## Groups

A workspace with a name is a group: a coloured label with the name stands in front
of its tabs. A workspace without one is simply tabs, with no group. A new group
asks for its name straight away; left empty, it keeps the workspace's own name.

- **Click the label** to fold the group up to it, and again to open it. A folded
  group shows how many tabs it holds. If the tab in front is in the group, the
  tab next to it is shown first, or a new tab if there is no other.
- **The label's menu**: **New Tab in Group**, **Rename Group…**, **Collapse
  Group** / **Expand Group**, **Ungroup**, **Close Group**.
- **A tab's menu**: **New Tab to the Right**, **Add Tab to New Group**, **Move Tab
  to Group**, **Remove from Group**, **Close Other Tabs**.
- **Drag** a tab along the tab bar, onto another group's label, or onto the empty
  end of the bar to take it out of its group.
- **New Tab** (`⌘T`, or the + in the bar) opens at the very end, outside every group.
- The empty part of the tab bar moves the window, and a double-click on it zooms it.

**Several tabs at once.** `⌘`-click adds a tab to the picked ones or takes it out,
`⇧`-click picks every tab from the last one clicked to this one. The menu of any
picked tab is about all of them: **Add N Tabs to New Group**, **Move N Tabs to
Group**, **Close N Tabs** — which is how a group is made from several tabs in one
go. Not `⌃`: on a Mac a `⌃`-click is the secondary click and opens the menu.

**Two tabs side by side.** Pick two tabs and choose **Show Side by Side** from the
menu: both pages stand under the tab bar, and the two tabs get a split mark. The
half that has the keyboard is underlined at the top. **Stop Showing Side by Side**
on either one takes them apart. It is the same split as `⌥S` on the row.

**Pinned tabs.** **Pin Tab** in a tab's menu turns it into an icon at the front
of its group — each group has its own pinned tabs, and each profile its own. It
has no close button, **Close Other Tabs** leaves it alone, and a tab dragged in
front of the pinned ones lands right after them. **Unpin Tab** takes it back. A
pin stays after a relaunch.

A folded group stays folded after a relaunch.

### Groups by meaning

With **Configuration ▸ Windows ▸ Group Tabs by Meaning** on, six sorts tabs by what
the page is about — on this Mac, with no network and without the language model
features:

- A new tab, once its page has loaded, goes into the group it is about, and the
  focus goes with it. When it is not sure, the tab stays where it is.
- A tab about two groups at once goes into a group between them, coloured between
  their colours: orange between yellow and red. A tab almost about a group, but not
  surely, goes into a pale group right after it. Until such a group has a name of
  its own it is called after its neighbours ("Dinner · Sport", "≈ Dinner"). Tabs can
  be dragged in and out; the colour is the group's. Its menu has **Merge into …**
  and **Make Separate Group**; if a neighbouring group goes away, it stays next to
  the other.
- Three alike tabs with no group become a new group. At first it is named after
  the words their titles share; a moment later a name by meaning replaces it
  ("Cooking", "Football"). The assistant's model or agent gives it when language
  models are on, the **Local Model** on this Mac otherwise. A name you typed in the meantime
  stays.
- A tab you moved by hand stays where you put it until it goes to another site. A
  group you ungrouped is not made again.

**Sort By**: **Embeddings** — the model that searches bookmarks, fast and light on
memory — or **Local Model**, which reads the titles and picks the group itself. That
works best with **Gemma 4 E2B**, at 3.6 GB and a few seconds a tab.

**Local Model** — Gemma 3 1B (770 MB), Qwen 2.5 1.5B (870 MB) or Gemma 4 E2B
(3.6 GB). Downloaded the first time it is needed, and held in memory only while it
answers.

## Keys

With the tabs up the row's `⌥` keys are off: `⌥←` moves by word again, `⌥W`
types «∑». The keys about the page stay — `⌥⇧T`, `⌥⇧H`, `⌥⇧P`, `⌘⇧C` — and so do
all the `⌘` ones.

| | |
|---|---|
| `⌃Tab` | fly between tabs by memory — the same ring as on the row, over every tab of every group |
| `⌃⇧Tab` | the same, over the group you are in |
| `⌘⇧]` `⌘⇧[` | next / previous tab |
| `⌘1` … `⌘8` | that tab, `⌘9` the last one |
| `⌘T` `⌘W` `⌘⇧T` | new tab, close tab, reopen a closed one |

`⌘⇧]` `⌘⇧[` and `⌘1`…`⌘9` skip folded groups; `⌃Tab` does not.
