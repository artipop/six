# Tabs and groups

A Savoia window is a tab bar along the top, the address field under it, and the
page below. Tabs gather into groups, two tabs can stand side by side, and `⌃Tab`
takes you back to the one you were just in.

## Groups

A group is a coloured label with a name in front of its tabs. A new group asks
for its name straight away; left empty, it is called "Group N".

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
half that has the keyboard is underlined at the top; a click on the other one
makes it current. **Stop Showing Side by Side** on either one takes them apart.

**Pinned tabs.** **Pin Tab** in a tab's menu turns it into an icon at the left
edge of the bar, before every group; each profile has its own. It has no close
button, stays in sight when a group is folded, and **Close Other Tabs**, **Close
Group** and groups by meaning leave it alone. **Unpin Tab** takes it back. A pin
stays after a relaunch.

A folded group stays folded after a relaunch.

### Groups by meaning

With **Configuration ▸ Tabs ▸ Group Tabs by Meaning** on, Savoia sorts tabs by what
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

### Old tabs

**Configuration ▸ Tabs ▸ Old Tabs ▸ Offer to Close** — how often Savoia looks for tabs
you have left behind: **Never** (the default), **Daily**, **Every 3 Days**, **Weekly**,
**Every 2 Weeks** or **Monthly**. The period is also the measure: once a week it looks
for tabs not opened for a week.

A tab left behind is one that has not been in front for the whole period, and whose
topic you have not come across in that time — neither in the other tabs you opened
nor in the history. The topics are compared by the same model that sorts tabs into
groups, on this Mac, with no network. If any tab of a group was opened, the rest of
the group is left alone too: a group is a topic. Pinned tabs are never offered.

The tabs found are shown as a list with checkboxes: untick what you want to keep and
click **Close N Tabs**, or **Keep All**. Savoia closes nothing by itself. If you read
next to nothing in the period — you were on holiday, say — nothing is offered: there
is nothing to judge by. It looks at the profile that is open, and never at a private
one.

**Look Now** runs the same search at once, without waiting for the period.

## Keys

| | |
|---|---|
| `⌃Tab` | fly between tabs by memory: pictures of every tab of every group, in the order you looked at them; let `⌃` go and you are there. *Control-Tab Switches* in the Windows settings can choose Tab Bar Order instead of Recently Used |
| `⌃⇧Tab` | the same, over the group you are in |
| `⌘⇧]` `⌘⇧[` | next / previous tab |
| `⌘1` … `⌘8` | that tab, `⌘9` the last one |
| `⌘T` `⌘W` `⌘⇧T` | new tab, close tab, reopen a closed one |

`⌘⇧]` `⌘⇧[` and `⌘1`…`⌘9` skip folded groups; `⌃Tab` does not. Every key is on
the [Keyboard shortcuts](/en/hotkeys) page.
