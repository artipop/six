# Sharing

Both directions of the system's Share menu: a page handed from six to other apps, and a page, some text or a file handed
from another app to six.

## Out: the share button

`ShareLink` over the page's own address (`BrowserTab.shareableURL`), in three places: beside the bookmark star in the
top bar (`ShareButton` in [`ContentView.swift`](../six/Views/ContentView.swift)), as **Share** and **Share Link** in the
page's context menu ([`PageContextMenu.swift`](../six/Views/PageContextMenu.swift)), and in the phone's `…` menu. A start
page, a `six://` page and a document have no address anybody else can open, so the button is greyed out there. It is
greyed out and not hidden, so the bar does not shift between a page and a start page.

It is deliberately not in the menu bar. A `Commands` body is built once (AGENTS.md, *a `.disabled` on a SwiftUI
`Commands` item*), so a File › Share item would go on sharing whatever page was in front when the menu was first
built.

## In: the share extension

`ShareExtension/` is a target of its own, `six-share` (`org.deffun.six.share`, `.dev.share` for Debug). The Mac target
depends on it and embeds it in `Contents/PlugIns`. It is macOS only.

```
another app's Share ▸ six ──▶ six-share.appex (sandboxed)
                                 │ reads   ~/Library/Application Support/<app id>/share-targets.json
                                 │ opens   six-share://open|private|bookmark?url=…|text=…&profile=…&workspace=…
                                 ▼         (to its own containing app, by path)
                              six.app ── onOpenURL ─▶ BrowserState.receive(_:)
```

An app extension on macOS has to be sandboxed, and a sandbox leaves exactly two ways to reach the app without a
developer team, an App Group or a provisioning profile. This machine signs ad hoc, so those two are the whole channel,
one for each direction:

- **App → sheet: a file.** `BrowserState.shareTargets` lists every non-private profile, its workspaces top to bottom,
  and the first three window titles of each, so an unnamed row can still be told apart. It is written as
  `share-targets.json` beside `state.json` by a second `StatePersistence`: debounced, off the main thread, and
  atomic. The extension reads that one file through a
  `temporary-exception.files.home-relative-path.read-only` entitlement. It gets the file and not the folder, and it
  reads from the real home directory (`getpwuid`), because inside the sandbox `NSHomeDirectory()` is the container.
- **Sheet → app: a URL.** `ShareRequest` ([`six/Share/ShareHandoff.swift`](../six/Share/ShareHandoff.swift), the one
  file both targets compile) goes out as `six-share://…`. The extension hands it to *its own* containing app with
  `NSWorkspace.open(_:withApplicationAt:)`. It does not use whichever app claims the scheme, because the installed
  six and a development build both carry a sheet. The schemes are build settings (`SIX_SHARE_SCHEME`: `six-share` /
  `six-dev-share`), and so is the Application Support folder the extension reads (`SIX_APP_IDENTIFIER`). Both reach
  the extension's `Info.plist` and its entitlements.

Profiles and workspaces travel **by id**, because the row can change between the sheet opening and the click. An id
that is gone falls back to the profile and row in front (`ShareInbox.swift`), and the shared page is never dropped.
The last row of every strip is the empty one `normalize` always keeps, and the sheet calls it **New Workspace**:
opening into it is how a page gets a row of its own.

### What the sheet takes

The activation rule is what the other browsers take, measured from their own `Info.plist`s. Firefox for iOS takes a
web page, a URL and text. Chrome for iOS offers open, open in incognito, add to bookmarks, reading list, and search for
text. The Mac's own Notes also takes a file. six takes:

| shared | offered | done |
|---|---|---|
| a web URL (Safari, any app with a link) | **Open**, **Add to Bookmarks**, private | a window on the chosen row; or `BookmarkStore.add(url:title:in:)`, which reads the page off screen with the profile's cookies |
| text that is one address | the same as a URL | |
| other text | **Search**, private | `URL.fromUserInput`, with the configured engine |
| one PDF, HTML, web archive, image or plain-text **file** | **Open**, private | a `file:` window |

Any other file (a zip, say) does not show six at all, because a sheet that only opens to say "can't" is worse than
none. The rule tests `public.file-url` first: a text file shared from Finder also registers `public.plain-text`, and
without that order it would turn into a search for its contents. **Add to Bookmarks** does not bring six forward
(`OpenConfiguration.activates = false`). The bookmark goes to the profile of the chosen workspace, because bookmarks
are kept per profile.

### The switch

macOS registers a newly installed share extension **disabled**, and the only switch for it is in
System Settings, several screens deep, in a list where six is one line among a dozen. There is no
`Info.plist` key that asks for it to be on, and no framework call either: `pluginkit` is the whole
interface, and it is what System Settings itself drives.

So `ShareExtensionSwitch` ([`six/Share/ShareExtensionSwitch.swift`](../six/Share/ShareExtensionSwitch.swift))
shells out to it — six is not sandboxed — and the app does exactly two things with it:

- **Switches it on once**, at the first launch that finds it off (`sixApp.init`). The record of having
  done it (`ConfigurationStore.hasOfferedShareExtension`) is written whatever the answer was, so a
  person who switches it back off is never overruled by the next launch.
- **Shows the same switch** in Configuration ▸ General ▸ Sharing, read from the system every time the
  page appears. Not cached in the database: System Settings can have changed it since, and a switch
  showing six's opinion rather than the system's is a lie the moment it does.

`pluginkit -m -i <id>` prints one line whose first character is the state (`+` on, a space off), and
`pluginkit -e use|ignore -i <id>` is the write. No line at all means macOS has no record of the
extension — the app has not been launched from where it is installed — and the row says so instead of
offering a switch that would do nothing.

### Two traps, both measured

- **An `NSHostingView` as the controller's `view` never appears at all.** A share sheet is a *remote*
  view: the app that shared owns the window, and what crosses the process boundary is a view
  controller. SwiftUI's own sizing goes through a hosting *controller*, so with a bare hosting view
  nothing ever gave the remote view a size — the note dimmed, nothing was drawn over it, and Esc was
  the only way out. None of `viewWillAppear`, `viewDidLayout` or `viewDidAppear` ever fired, which is
  the tell: a sheet that is merely empty still appears. An `NSHostingController` added as a child,
  with `preferredContentSize` set in points, comes up at 440×420 with every callback firing.
- **A share extension is registered by bundle id, and another build's copy answers for yours.**
  Another session's `six.app` in its own DerivedData carries the same `org.deffun.six.dev.share`, and
  LaunchServices resolved the id to *that* one — so a rebuild here changed nothing that ran, and three
  rounds of "the new code never runs" were one stale copy. `pluginkit -m -v -i <id>` prints the path
  that won, which is the only way to see it; `pluginkit -r <the other .appex>` and then
  `pluginkit -a <yours>` puts it back. `lsregister -f -R` on the app does *not* move it.

### Checking it without a screen

No clicks can be sent here (AGENTS.md), so each half is checked on its own:

- **Registration and the rule.** Run `pluginkit -m -p com.apple.share-services | grep six`. A leading `+` means the
  extension is enabled. A fresh build is registered **disabled**, and `pluginkit -e use -i org.deffun.six.dev.share`
  is what the Share menu's own switch does. After that, `NSSharingService.sharingServices(forItems:)` in a ten-line
  Swift script says which items get six: a URL, text, a PDF and a `.txt` did, and a `.zip` did not (measured).
- **The sheet.** `service.perform(withItems:)` from a script that owns an `NSApplication` puts the sheet up.
  `log show --predicate 'subsystem == "org.deffun.six.dev.share"'` then shows `sheet for …; row read`, which means
  the sandboxed process read `share-targets.json`.
- **The handoff.** `open "six-dev-share://open?url=…&profile=…&workspace=…"`, then read `share-targets.json` again: the
  window shows up on the named row. `bookmark` and `private` log `shared in: …` in `six.log`, and a saved bookmark
  logs `shared in and saved`.

What none of those can show is a person pressing the buttons in the sheet. That still wants a hand.

## Not built

- **iOS.** The phone shares out (the `…` menu) but takes nothing in. An iOS extension cannot open its containing app
  with a URL, and it has no temporary exceptions, so both halves of the channel above would need an App Group, and an
  App Group needs a team ([todo.md](todo.md#sharing-into-six-on-ios)).
- **Images and files by value.** Photos shares an image as data, not as a file. six would have to write it somewhere
  first, and the extension's container is not a place anything should outlive the sheet.
