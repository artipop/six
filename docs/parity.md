# Parity: what the Windows front owes the Mac, and what Linux can take along

A working list, not a reference: the order the Windows front is being brought up to the Mac, one block at a time,
with what the Linux front gets from the same work. Written on 2026-09-12 against `9a98dd9` from the docs
([windows.md](windows.md), [linux.md](linux.md), [todo.md](todo.md)) and from the fronts' own sources — each
"has / has not" below was checked in code, not only read in a doc. It lives in the repository because the first
version of it lived in a conversation and was lost with it.

**The rule for Linux.** Anything that lands in `SixCore`, or is a callback the engine already has, is nearly free
on Linux — WebKitGTK has a direct counterpart for every C API the Windows front uses. So a block is written
shared-first: the model in `SixCore`, proved on Windows, and the Linux wiring written beside it and built in a
session that is about Linux (the container is on the Mac; CLAUDE.md says why that is not a habit).

Sizes are rough: **S** an afternoon, **M** a day or two, **L** a week, **XL** more.

## 0. The engine — postponed

A WebKit that is not Playwright's, and the DPI shim that goes away with it. Playwright deletes the
`/ intrinsicDeviceScaleFactor` from `WebView::onSizeEvent`, so `RailWebView.installScaleShim` divides `WM_SIZE` by
the scale; its WebCore has MediaStream compiled out, so no page can ask for the camera or the microphone however
finished six's side of that is; and GPU compositing is off. build.webkit.org builds Windows green and hands nobody a
binary ([todo.md](todo.md#windows-a-webkit-that-is-not-playwrights)). Everything below works on the current engine.

## Built already, on Windows

The rail and workspaces with the key table, `Alt`+wheel, the overview (looking, not rearranging); live pages,
discarding and pictures; the rail across a relaunch; profiles with isolated site data and a private one; history
with its list window; bookmarks with vectors, the page's whole text and the Markdown copy; translation (Bergamot);
site permissions (wired, engine-blocked — see 0).

## The list

### 1. The page's basics — M, both fronts

What makes it a browser rather than a rail of pages: **downloads** (the Mac's `DownloadsView`, resume, the row that
survives a relaunch — [links.md](links.md)); **the page's own dialogs** — `alert`, `confirm`, `prompt`, the file
picker; **a second window** — `target=_blank`, `window.open`, `⌘`/middle-click opening a column beside; **the
context menu on a link** (open beside, copy address — six took the Mac's over for exactly this); **a failed load**
as a page that says so (`PageFailureView`) rather than a blank card; **the load line** (`LoadingLine`).

- **Windows:** **the dialogs are done** (2026-09-12): alert, confirm, prompt and the file picker, measured end to
  end ([windows.md](windows.md#the-pages-own-dialogs)); a folder upload is still refused. They had been silently
  answered no, which the guide's "work as everywhere" had not noticed. **The second window is done** (2026-09-13):
  `window.open` and `target=_blank` as real related pages (`window.opener` works, unlike the Mac), `window.close()`,
  and a middle or `Ctrl`-click opening a link behind ([windows.md](windows.md#a-second-window)). **Downloads are
  done** (2026-09-13): WebKit's own transfer, the Downloads folder, the button and its list, `Ctrl+J`, the carrier
  column closing itself ([windows.md](windows.md#downloads)) — without resume, Try Again or rows across a relaunch,
  which the C API has nowhere to hand a stopped transfer back to. **A failed load and the loading line
  are done** (2026-09-13): the Mac's "This page didn't open" as an alternate page with Try Again, and the Mac's
  `LoadingLine` under the address and across the other cards ([windows.md](windows.md#a-failed-load-and-the-loading-line)).
  **The link's context menu is done** (2026-09-13): WebKit's own, alive here where the Mac's was dead, with Open Link
  Behind added and Download Linked File handed to the downloads ([windows.md](windows.md#the-context-menu)); Open Link
  Beside and This Window wait for the split and the column commands. **Links to other apps are done** (2026-09-13): `ExternalScheme` moved into `SixCore` (with
  `MCPAppScheme`'s two names split out of its WebKit file), and on Windows every route to such an address asks
  first, names the app, and refuses a page that tries it without a click
  ([windows.md](windows.md#links-to-other-apps)). The Mac and iOS builds of that move are unbuilt here. And
  **Stop** in place of Reload while a page loads ([windows.md](windows.md#a-failed-load-and-the-loading-line)).
  **Item 1 is closed on Windows**; its Linux half is still to be written.
- **Linux:** the same list: `WebKitDownload`, `script-dialog`, `run-file-chooser`, `decide-policy`,
  `context-menu` — [todo.md](todo.md#linux-what-the-third-front-still-owes-the-first) calls them one-to-one onto
  `PageDialogQueue` and the navigation decider.
- **Shared:** the download rows and their persistence are not Apple (`six/Browser/Downloads` carries the model);
  the "open beside" decision is `NiriLayout`'s already.

### 2. Blocking — L, both fronts

Filter lists compiled to content-blocker JSON, a rule list per profile, the scriptlets and extended CSS that run in
the page, the shield and its per-site allowlist ([blocking.md](blocking.md)).

- **Windows:** `WKUserContentExtensionStoreRef` is in the headers — the C spelling of `WKContentRuleListStore`.
- **Linux:** `WebKitUserContentFilterStore`, which takes the same JSON.
- **Shared:** `FilterListStore`, `RuleConversion` and `AdvancedRules` would move into `SixCore`. **The risk is the
  graph, not the code:** SafariConverterLib would join the root manifest and so the Linux and Windows resolved
  files — read "Three fronts, one dependency graph" in CLAUDE.md before touching a manifest for this.

### 3. The layout's remaining keys — M, both fronts

`NiriLayout` has all of it and both fronts return `nil` for the rows: **two windows in one column** (`⌥S`,
[layout.md](layout.md#two-windows-in-one-column) — Windows already *restores* a split and cannot make one),
**the `⌃Tab` ring** (`WindowSwitcherOverlay`), **copy address** (`⌃⇧C`, already spelled for off-Apple),
**picture-in-picture** where the engine allows it.

### 4. The bookmarks library — S–M

- **Windows:** no window at all; `searchBookmarks` is in the model and nothing shows it. `RailListPanel` (history's
  window) is the shape.
- **Linux:** `BookmarksSheet` exists and searches title and address only — its own comment still says the readable
  copy and the embeddings are out of scope, which stopped being true. Give it the vector search the model has.
- **Both:** the hourly **refresh** (re-read a saved page from its site) needs an off-screen page with the profile's
  cookies; `PageSandbox` today is deliberately cookie-less.

### 5. Start page and settings — M–L

The Mac's start page — the field, your own pages first (`PersonalSuggestions`: history and bookmarks), suggestions
([start-page.md](start-page.md)) — and `SettingsPageView`: search engine, translation target, embedding model,
bookmark refresh, blocking lists. Both fronts start on DuckDuckGo and have no settings surface; the values are
already in `SettingsStore`, which is `SixCore`'s.

### 6. Highlights and the selection verbs — M

`HighlightScript` is Foundation-only JavaScript, the same case `ReadablePage` was: into `SixCore`, through
`PageScriptRunner`. Then the selection bar (`PageFocusBar`) for **highlight** and **translate selection** — both are
key-table rows the fronts drop today. The highlights table is the Mac's ([deep-research.md](deep-research.md)).

### 7. What the engine gives away — S each

**Find in page** (`WKPageFindClient` / `WebKitFindController`), **favicons** (`WKIconDatabase` /
`WebKitFaviconDatabase`), **page zoom**, **fullscreen video**. Find and favicons are on no platform yet, the Mac
included — new everywhere rather than parity.

### 8. Profiles, whole — S–M

- **Windows:** create and switch; no rename, recolour or delete, and no "move this window to another profile"
  (`MoveToProfileMenu`). A rename has to move `Profiles/<name>` as the Mac's does — site data *and* the bookmarks'
  Markdown copies are in it now.
- **Linux:** one profile plus private ones. Profiles proper first.

### 9. The overview's hands — M

Carrying a window to another row, renaming a workspace, the removal dialog (`WorkspaceRemovalDialog`) —
[layout.md](layout.md#carrying-a-window). Both fronts look and go.

### 10. Localization — M, both fronts

Both are English only. Worth trying before gettext: `SixCore` reading `Localizable.xcstrings` (it is JSON) at run
time, so all three fronts share one catalogue and the Russian the Mac already has.

### 11. The AI layer — XL

The `⌘K` assistant and the verbs at a selection ([assistant.md](assistant.md)), the ACP agent panel
([agents.md](agents.md)), `six --mcp` and `BrowserTools` ([mcp.md](mcp.md)), MCP apps, deep research. The most
portable code in the repository — Foundation, child processes, JSON-RPC — minus Foundation Models, which is
Apple's: the model choice collapses to ACP, the vendored `ClaudeAPI` and OpenAI-compatible. Linux has `Process`
natively; so does Foundation on Windows.

### 12. DevTools — M, after 11

Web Inspector for a page, and the console and network capture the agent tools read ([devtools.md](devtools.md)).
The capture is the half that matters, and it matters once 11 exists.

### 13. Certificates — M, unscoped

Extra certificate authorities ([certificates.md](certificates.md)): on the Mac a trust evaluation per challenge.
Where each engine lets six decide server trust has not been looked at yet.

## Blocked, not owed

- **Extensions** — Linux waits for Igalia to expose `WebExtensionContext`/`WebExtensionController`; Windows has no
  extension API in the C headers it builds against.
- **Camera and microphone on Windows** — item 0.
- **Geolocation, screen sharing, web push** — blocked on the Mac too ([todo.md](todo.md)).

## Linux's own

- **Everything bookmarks-and-vectors is written and unrun** there, today's readable text and Markdown copy
  included: the first Linux session should run `SIX_EMBED_SELFTEST=1` and star a page.
- **The strip clamps at its ends** — the outermost columns sit against the edge instead of centring
  ([linux.md](linux.md#where-it-is-behind-the-mac)).
