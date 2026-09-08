# TODO

What is planned but not built. Ordered by how much it is missed, not by effort.

## Save As: web archives

Document windows, Save As and highlights are built ([deep-research.md](deep-research.md)). What Save As still
lacks is `.webarchive` for pages: `WebPage` has no `createWebArchiveData` today, so a page saves as `.html` (its
source), `.pdf` or `.txt`. Downloads are built without `WKDownload` at all — see [links.md](links.md).

## Bookmarks: images

Today a bookmark keeps images only as `![alt](src)` in the Markdown and `og:image` in the front matter; nothing in
a picture is searchable. The plan, in the order it should be built ([bookmarks.md](bookmarks.md#embeddings) has what
the SDK offers and doesn't):

1. **OCR + labels, locally (Vision)** — the base. When a page is bookmarked, download its large images (≥ 120 px, at
   most ~20 per page) into `Bookmarks/<slug>/images/`, run `RecognizeTextRequest` (multilingual OCR) and
   `ClassifyImageRequest` (~1300 labels) on each, and store the result as chunks of a new kind —
   `bookmark_chunks(kind: image, imageURL, text)` — embedded like any text. Screenshots, diagrams, infographics,
   menus, tables-as-pictures become findable by their words; a photo by its labels. Don't lean on `alt` or
   `<figcaption>` — they are usually empty or wrong; use them only as extra words when present.
2. **Descriptions from Foundation Models** (macOS 27: the on-device model takes `Attachment<ImageAttachmentContent>`
   — `CGImage`, `CIImage`, `CVPixelBuffer`, `imageURL:`; nothing else, no PDF). Ask for a one-line description per
   image, in the user's language, and store it as another image chunk. Seconds per image, needs Apple Intelligence
   assets — a budget of ~10 images per page, in the background after step 1. Decide after seeing step 1 on real pages.
3. **A multimodal embedder** (Voyage `voyage-multimodal-3`, Cohere Embed v4) as a second `Embedder` conformer:
   image chunks embedded as images, text as text, one space — real text→image search and cross-lingual text at the
   same time. Remote, keyed, images leave the Mac; a setting, off by default.

PDFs: the model doesn't take them; `PDFPage.string` for the text layer and page renders as images through step 1/2
when `ReadablePage` learns to read a PDF `WebPage`.

## Extensions: the tab a content script cannot see

Hosting is built ([extensions.md](extensions.md)): install from a folder or an archive, a controller per profile,
actions in the top bar, permission prompts, and a compatibility verdict shown before anything runs. What is left is
the one gap behind it — `WKWebExtensionTab.webView(for:)` needs the live `WKWebView` and `WebPage` does not hand its
own out — which costs messaging between a content script and its extension, `scripting.executeScript` and
`insertCSS`, and (as far as can be told) uBlock Origin Lite's per-tab logic.

Reflection into `WebPage`'s private storage would close it and is deliberately not used. The move that might
actually close it is upstream: nothing on bugs.webkit.org mentions `WKWebExtension` and `WebPage` together, so this
wants a bug (and a Feedback) asking for the backing view — or for a way to associate a `WebPage` with a tab — with
the measurements from [extensions.md](extensions.md) as the case. `WebPage.isInspectable` is the precedent: something
that lives on `WKWebView`, lifted into the new API.

Smaller things that follow once the boundary moves (or that are worth doing anyway): a workspace per extension
window rather than one window per profile strip, `commands` bound to real keys, `menus` in the page context menu,
and extension pages (options, new-tab override) as ordinary columns rather than plain windows.

## Someday: six's own WebKit build

Two separate walls in this document are the same wall — WebKit can do the thing, the macOS SDK does not expose it:

- `WKWebExtensionTab.webView(for:)` needs a tab's `WKWebView`, and `WebPage` keeps its own private, so an
  extension's content scripts run but cannot talk to it ([extensions.md](extensions.md));
- there is no public way to *open* Web Inspector on your own page — the whole word "Inspector" appears in exactly
  one public header, as `WKWebView.isInspectable` — so six can only let Safari attach ([devtools.md](devtools.md)).

Neither is a WebKit limitation. WebKit's inspector frontend is in the open-source tree, and the GTK port hands it to
applications as ordinary public API (`webkit_web_view_get_inspector`, `webkit_web_inspector_show`). Orion has
in-window developer tools on macOS, which means either SPI or a build of its own; Playwright ships a patched WebKit
precisely to reach the inspector protocol.

So the escape hatch, if the walls ever start costing more than they are worth: **build WebKit ourselves and embed
it.** What it would buy, in the order it matters — the inspector in six's own window, the inspector protocol behind
the MCP devtools tools (real network with headers and bodies, a DOM snapshot, interactions), and whatever
`WebPage` refuses to hand over, including the backing view an extension tab needs.

What it costs, so this is not written down as if it were free: hours of build time and tens of gigabytes per
revision; the WebContent XPC services to embed, sign and sandbox; the size of the app; and — the real price —
**security updates become ours**. System WebKit is patched with the OS; a private copy is patched when we get
around to it, on a browser that runs other people's JavaScript. Every macOS release is also a chance for the build
to break.

Before that, two cheaper things should be tried, in order: **file the bugs** (nothing on bugs.webkit.org mentions
`WKWebExtension` with `WebPage`, and the inspector ask is a request for parity with a port that already has it),
and watch whether Safari's own MCP server (Safari 27 / STP 247) turns out to be reachable by other apps — it is the
same capability from the other end.

## The assistant: what the three surfaces still owe

Built: the catalog of verbs, the bar at a selection, the caret in a field, and the one-answer ⌘K
line ([assistant.md](assistant.md)). What was deliberately left for later, in the order it is
missed:

1. **Ghost text in the field itself.** A rewrite arrives in the strip at the bottom of the window
   and goes into the page on Return; the thing to build is the answer shown *in place* — grey text
   after the caret, Tab to take it — which needs an overlay positioned on a caret rectangle that
   moves with every keystroke, inside a page whose scrolling six does not own. The strip is the
   honest version until that is measured.
2. **Verbs while an agent is chosen.** A verb is a prompt to a language model, so the bar keeps only
   "Ask…" while the line is set to Claude Code or Codex. Routing a verb to the agent instead would
   be a different session with a different memory answering the same button, and that wants a
   decision rather than a default.
3. **A verb of your own.** The catalog is a Swift array; the row that would make it a setting — a
   title, a prompt, where it applies — is the smallest useful next feature, and the reason the type
   is shaped the way it is.
4. **The phone.** `PageFocus` compiles on iOS and nothing reads it there: the Phone layout has no
   assistant surface at all yet, and a selection bar is a different gesture on a touch screen —
   iOS puts its own menu over a selection.

## Windows: a WebKit that is not Playwright's

The Windows front runs the WebKit that `playwright install webkit` puts on the machine, and takes whatever
revision the installed Playwright pins — `webkit-2359` at the time of writing. Two separate reasons to want a
different build, and they are worth keeping apart:

- **A newer one** was the original hope, and is now known to be pointless on its own: the cause is a patch
  Playwright applies to every build it ships ([windows.md](windows.md)).
- **An unpatched one, and this is now the whole reason** — the `../sixty` session guessed that Playwright's
  patching for headless automation might be causing the bug, and reading the patch confirmed it exactly.
  `browser_patches/webkit/patches/bootstrap.diff` deletes the `/ intrinsicDeviceScaleFactor` from
  `WebView::onSizeEvent`, which is precisely the division `RailWebView.installScaleShim` puts back from outside.
  So any non-Playwright build — CI or self-built — makes the shim, the divided creation rect and probably the
  compositing preference all unnecessary. A *newer Playwright* build never will; they all carry the patch.

**Neither is available right now**, and both routes have been checked rather than guessed at:

- Playwright's own newest is not newer. `webkit-2360` — one past the pinned `2359`, from
  `https://cdn.playwright.dev/dbazure/download/playwright/builds/webkit/<rev>/webkit-win64.zip` — behaves
  identically, and `2361`+ return 400. Re-probe that URL pattern rather than re-deriving it; revisions just
  increment.
- **build.webkit.org builds Windows fine. What it does not do is hand anyone a binary.** Worth stating carefully,
  because "the CI is dead" is the wrong summary and leads to the wrong next step. Checked directly against the
  buildbot API on 2026-09-08:

  | builder | id | latest runs |
  |---|---|---|
  | `Windows-64-bit-Debug-Build` | 1189 | running **today**, four times this morning — and red every time |
  | `Windows-64-bit-Release-Build` | 1192 | not failing: four green in a row, but the newest is 2026-05-22, ~109 days back. It stopped being scheduled, it did not break |
  | `WinCairo-64-bit-*-Build` | 731 / 729 | last ran 2024-09-13 |
  | `Apple-Win-10-*-Build` | 67 / 56 | last ran 2023-02-07 |

  So a green Windows Release build exists — `313706@main`, from May — and the problem is fetching it. The archive
  bucket is not public: `archives.webkit.org` returns 403 for both the object and a listing. The only way in is the
  presigned URL a build's own `generate-s3-url` step logs, and those expire about 30 minutes after they are
  generated, which rules out anything from May and makes a fresh one a watch-and-grab job. `../sixty` ran a cron
  watch for a green build and gave up.

  **The Debug builder is not a way around that**, which is the first thing anyone asks. Its pipeline stops dead:
  `compile-webkit` fails and the build ends there, so `archive-built-product`, `generate-s3-url` and
  `upload-file-to-s3` never run and no zip is ever produced — nothing to fetch, expired URL or not. Only the
  Release builder has ever reached those steps (its last green run uploaded `WebKitBuild/release.zip`). And it has
  been red a long time: 1600 consecutive failures, as far back as the API was paged, to 2026-08-03. Even green it
  would be the wrong artifact — a Debug WebKit links the debug CRT, which is not redistributable and wants Visual
  Studio present, on top of being assert-heavy and far larger and slower.

  So there is one thing to watch, not two: **the Release builder being scheduled again**. That is what produces a
  fresh build whose presigned URL is still live. The recipe is the second option in
  [dev.to: Running the latest Safari WebKit on Windows](https://dev.to/dustinbrett/running-the-latest-safari-webkit-on-windows-33pb),
  which is where Artem got it, with his warning that the CI links have moved since.
- A self-hosted build on a cloud VM is the remaining idea. Nobody has costed it.

Trying a build is otherwise cheap, since nothing here pins the engine: `six-windows.ps1 -WebKitDir <folder>` points
at any DLL set. The chore is `windows/vendor/WebKit2/WebKit2.lib` — see [windows.md](windows.md) for regenerating it.
`../sixty` already has `windows/scripts/update-playwright-webkit.ps1` on a daily scheduled task watching for a newer
Playwright; point at that rather than writing a second one.

The cross-checkout write-up lives at `../sixty/windows/WEBKIT_WINDOWS_NOTES.md` — toolchain traps, the CI detail
above, both fronts' DPI findings, and Artem's reference links:
[the survey](https://fujii.github.io/2019/07/05/webkit-on-windows/),
[running WebKit on Windows](https://schepp.dev/posts/running-webkit-on-windows/) and its
[HN thread](https://news.ycombinator.com/item?id=30280404), and
[qt-ultralight-browser](https://github.com/niutech/qt-ultralight-browser) for the QtWebKit route.

## Developer tools: the half Chrome's devtools MCP has and six does not

Web Inspector and capture are built ([devtools.md](devtools.md)): console, network, screenshots, over MCP. What an
agent still cannot do is *act* on a page except through `evaluate_javascript`, and cannot measure it:

- **A snapshot with stable ids** — Chrome's `take_snapshot` returns the accessibility tree with a uid per node, and
  every interaction tool takes one. six has `list_page_blocks` for reading; the same idea with uids, over the
  accessibility tree rather than paragraphs, is what `click`, `fill` and `hover` would address.
- **Interactions as tools** rather than hand-written JavaScript: click, type, hover, select, drag, upload, and
  `wait_for(text)`. All of it is expressible through the page world today, which is why it is not urgent — but a
  tool that returns "the button was not there" beats a script that throws.
- **Performance traces and emulation** (CPU/network throttling, a device viewport). WebKit exposes none of this to
  an app; it would need the Web Inspector protocol, which is not reachable from the app hosting the page. Worth
  saying so in the docs and stopping there.
- **Request bodies and headers**, and request interception. The page-world hooks see status and timing only; going
  further means either the inspector protocol or a `WKURLSchemeHandler`-shaped proxy, and neither is cheap.

## Geolocation, screen sharing and Web Push: one trade, not three

Site permissions are built ([permissions.md](permissions.md)): the camera, the microphone and the motion sensors are
asked for per site, remembered per origin and profile, and takeable back. Three things a browser is expected to do are
still missing, and they are the *same* missing thing — each needs a `WKWebView` and a delegate on it, which `WebPage`
does not hand out.

**Geolocation** is the one that stings, because it is not even SPI any more. macOS 27 added
`WKUIDelegate.webView(_:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)` — public,
`API_AVAILABLE(macos(27.0))`, and six already targets 27. But it is a `WKUIDelegate` method, and the SwiftUI-native
surface has no equivalent: `WebPage.DeviceSensorAuthorization.Permission` carries `mediaCapture` and
`deviceOrientationAndMotion` and nothing else. So `NSLocationWhenInUseUsageDescription` sits in the Info.plist wired to
nothing, and `navigator.geolocation` is dead on six's pages. Before writing any code, this wants a Feedback: the gap is
a hole in the new API rather than a missing capability, and it is the cheapest of the three to have closed upstream.
`WebPage.isInspectable` — a `WKWebView` property lifted into the new API — is the precedent to cite.

**Screen sharing** (`getDisplayMedia`) is SPI, but shallow SPI: `WKPreferences._screenCaptureEnabled` plus
`_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:` (macOS 13+),
where returning `ScreenPrompt` or `WindowPrompt` hands the picker back to WebKit — six would not have to draw one.

**Web Push** is SPI and deep: `_getPendingPushMessages` / `_processPushMessage` / `_processPersistentNotificationClick`
on `WKWebsiteDataStore`, a push partition, and a daemon. Worth its own decision, not this one.

The order to take them in follows the price: file the geolocation Feedback and wait a release; if it lands, geolocation
costs nothing. If it does not — or if screen sharing starts being missed — the move is to drop `BrowserTab` back onto
`WKWebView` + `NSViewRepresentable`, which is a real rewrite of the one file everything else talks to, and which the
extension gap wants anyway ([extensions.md](extensions.md)). Doing it once for all four reasons is a different
proposition from doing it for geolocation alone. six is not sandboxed and not on the App Store, so SPI carries no
review risk here — only the ordinary one, that it goes away in a macOS update; `respondsToSelector:` and a feature that
quietly disappears rather than a crash is the shape that takes.

## Blocking: cosmetic rules inside a frame

[Advanced blocking](blocking.md#the-advanced-rules-what-runs-inside-the-page) is main frame only, and the reason is
structural rather than lazy. A `WKUserScript`'s source is fixed when it is installed on the content controller,
which happens before the load starts; the rules that apply to a subframe are the ones for the *subframe's own*
address, and that is not known until the frame loads. Giving a third-party frame the top document's cosmetic rules
would hide things inside it for no reason, so it is given none. What blocks inside a frame today is the network
half, which is per-request and needs nobody's help — so what is missing is scriptlets and extended CSS in frames,
which is where a certain kind of ad iframe lives.

Three ways it could be closed, none of them free:

- **Ask, then apply.** Inject one small script into every frame (`forMainFrameOnly: false`) that posts its own URL
  to a `WKScriptMessageHandler`, and have Swift answer with that frame's rules. Cheap and correct for CSS — a frame's
  cosmetics can arrive a moment late and still work. Useless for **scriptlets**, which have to patch a global before
  the frame's own scripts run, and a round trip through the main actor is not before.
- **Ship the lookup to the page.** Inject the engine's answers for every domain the page might frame — which is the
  whole index — or the engine itself as JavaScript. AdGuard's own extension does the second, in a background script;
  six would be paying 350 KB and a build of the index per frame.
- **A `WKURLSchemeHandler`-shaped proxy**, or the Web Inspector protocol, so the rules could be applied to a frame's
  document before it is parsed. Both are the [own-WebKit-build](#someday-sixs-own-webkit-build) conversation.

The first is the only cheap one and it buys the smaller half. Worth doing when a real page is found where the frames
are the problem; not worth guessing at before that.

## Picture-in-picture — the window half

Two different features deserve the name, and the first of them is now built.

**Video PiP** — WebKit's own, for `<video>` — is done: `⌥⇧P`, a View menu item, and the button in WebKit's own media
controls. `WebPage.Configuration` turned out to have no field to allow it in, so it is SPI on the terms above, and the
floating player survives its window being scrolled off the rail, turned into a placeholder card and left behind for
another profile. What it took, and what was measured, is in [layout.md](layout.md#picture-in-picture).

**Window PiP** is not. Any six window as a small always-on-top panel: an `NSPanel` at `.floating` level hosting the
page, which leaves the strip while it floats and returns to its column when closed. This is niri's floating layer, and
the same mechanism would later serve a proper floating-window mode. Nothing about the video half helps here — that one
is a window WebKit owns and six only asks for.

## Passkeys and passwords

Sign in with a passkey (or a saved password) on any site, through the system UI. WebAuthn inside a third-party
`WKWebView` is gated by Apple's browser entitlements, so this is as much a paperwork task as a coding one. The plan,
the fallbacks and what to verify first are in [passkeys.md](passkeys.md). **Next up.**

## Sync through CloudKit — history first

History on every Mac (and later everything else that is a plain record: profiles, highlights, documents). Private
database, `CKSyncEngine`, one record per visit — visits are immutable, so there is nothing to merge. Design, limits
and what CloudKit can and cannot carry (vectors included) in [sync.md](sync.md). The store is ready for it — see the sync
columns under Storage below.

## Storage: history pages and retrieval

SQLite is the system of record — chosen and built: SQLiteData over GRDB for `visits`, `settings`, bookmarks and
their chunks and vectors (`six/Data/`, `six/Bookmarks/`, [architecture.md](architecture.md#persistence),
[bookmarks.md](bookmarks.md)). The app-state snapshot stays JSON — one small document, not a table. What is left:

- **History pages through the same store.** Bookmarks are the first RAG slice; history is the second: `pages(url,
  fetchedAt, text)` + FTS5 for visited pages, chunks and vectors like bookmarks, retrieval over what was *read*, not
  only what was saved. Decide when a visit is worth its text (dwell time, scroll, explicit "remember this").
- **`Retrieval` as a protocol.** The sqlite-vec KNN lives inside `BookmarkStore.vectorSearch` — one function to
  swap. Lift it behind a seam before a second index appears ([storage.md](storage.md)).
- **A bigger embedder when small isn't enough.** ~~One line in `MLXEmbedder.configuration`~~ — done, as a setting:
  `EmbeddingModelChoice` offers `multilingual-e5-small` and `multilingual-e5-base`, recommended by the Mac's memory
  and overridable ([bookmarks.md](bookmarks.md)). What is still open is a third rung — `multilingual-e5-large` or
  `bge-m3`, at 2 GB and up — and whether the ladder should be one the user climbs at all rather than one six climbs
  for them. An ANN index (USearch) only past ~100k chunks — `vec0` is brute force too, just in C.
- **Prototypes worth an afternoon**, both caches over SQLite, never systems of record:
  [Wax](https://github.com/christopherkarani/Wax) — one `.wax` file with FTS5 + Metal HNSW, hybrid search in one
  query, own embedder and an MCP server; Apple Silicon first, single writer, v0.2. VecturaKit — embed + index +
  BM25 hybrid in one Swift API over MLX; Apple-only, own files.
- **Linux build of the data layer.** ~~Verify early~~ — done, and it builds: GRDB, SQLiteData, sqlite-vec
  and the `@Table` macros all compile on Swift 6.3.3/aarch64, as do `AppDatabase`, `SettingsStore`, `History`
  and `Bookmark`. No fallback needed. What it costs is two pins: `swift-sharing` 2.10.0 and
  `combine-schedulers` 1.2.1 regressed on Linux, and `sqlite-data` 1.11.0 does not compile against
  `structured-queries` 0.38 on any platform. The package's `Package.resolved` is seeded from the app's,
  which answers all three — so `swift package update` is Linux-breaking. Measured in [storage.md](storage.md).
- `record_name` / `sync_state` columns for [sync](sync.md) when it comes; the schema already follows SQLiteData's
  CloudKit rules (UUID text keys with `ON CONFLICT REPLACE`, no other `UNIQUE`, no column drops, BLOBs in their own
  tables), so nothing migrates.

Rejected, so it isn't re-litigated: Core Data / SwiftData (Apple-only, no FTS or vectors), Realm (sync dropped, no
Linux Swift), LMDB/RocksDB (everything built on top), Couchbase Lite (its own sync), DuckDB (poor for many small
writes), libSQL / Turso (native vectors, but not the system `sqlite3`, young Swift SDK), ObjectBox (closed core, no
Linux), PGlite (WASM runtime, data unreachable from `six --mcp`), Qdrant / Milvus / Weaviate / Chroma (server
clients, nothing embedded).

## iOS: the data layer travels, the embedder is the question

What a port needs to know, so that nothing built now has to be undone ([sync.md](sync.md) has the phone-as-thin-client
flow this leans on).

**Goes as it is.** There is no custom SQLite: the iOS `libsqlite3` is used the way the macOS one is, and sqlite-vec is a
C file compiled into the app and entered per connection (`sqlite3_vec_init` from `prepareDatabase`) — the one way that
works when the system library has extension loading compiled out, which iOS has too. sqlite-vec-data declares
iOS 16 / tvOS / watchOS and builds the C with NEON on ARM; GRDB and SQLiteData are native there; the schema, the `vec0`
tables and a copied `six.sqlite` work unchanged. Statically compiled C is fine for the App Store — nothing is loaded
dynamically. `WebPage` exists on iOS 26, so `ReadablePage` and the refresh path port too; the hourly refresh becomes a
`BGProcessingTask` on Wi-Fi and power.

**Decide: which model, and for what.**

- The cheap path, and the one the architecture was built for: **the Mac indexes, the phone searches.** Chunks and
  vectors sync through CloudKit (one record per chunk, 384 float32 = 1.5 KB); the phone writes them into its own
  `vec0` and never embeds a page. It still has to embed the *query*, and that must be the **same model**
  (`multilingual-e5-small`) or the spaces don't line up — a query is a few milliseconds on an A17, so the model's only
  cost on the phone is its size.
- Size: `mlx-swift` runs on iOS 17+, but 470 MB of fp32 weights is a lot to ship or download to a phone. Take an
  fp16 (~235 MB) or 4-bit (~70 MB) conversion from `mlx-community`, or quantise once on the Mac; the model id in
  every vector means a quantised query model against fp32 passage vectors is a measurable choice, not a guess.
- `NLContextualEmbedding` (Apple, iOS 17+, no download) is the no-MLX fallback and stays per-script, i.e. not
  cross-lingual — already rejected on the Mac for that reason; on the phone it would only make sense if the Mac
  used it too.
- Embedding *pages* on the phone (a bookmark saved on the go) is the open question: run e5-small in an
  `NSExtension`/background task with a passage budget, or mark the bookmark *pending* and let the Mac embed it when
  it syncs. Start with the latter.

## Linux: what the third front still owes the first

Built and measured; see [linux.md](linux.md) for the whole picture. What is left, in the order it is missed:

- **Page scripting.** `PageScripts` and `PageControllers` are the two places six already abstracted WebKit, and both
  land on WebKitGTK without strain: `call_async_javascript_function` takes the same function body, arguments and
  isolated-world name as `callJavaScript(_:arguments:contentWorld:)`. Everything downstream waits on it — highlights,
  the readable copy, the DevTools capture the agent tools read. It should also be the first place the Linux build ends
  up *ahead*: WebKitGTK awaits a returned Promise, and the Apple API does not, which is why every page script on the
  Mac is written synchronously and polled from Swift.
- **Blocking.** `WebKitUserContentFilterStore` compiles the same content-blocker JSON as `WKContentRuleList`, so the
  SafariConverterLib output already in `FilterListStore` needs no changes. Wiring, not design ([blocking.md](blocking.md)).
- **The strip clamps at its ends.** `resolvedOffset` centres the focused column; the Mac places columns absolutely in
  a container that does not scroll, so the first and last centre like any other. On Linux the strip is a real
  `GtkScrolledWindow` and its adjustment clamps, so the outermost columns sit against the edge. Either the canvas
  grows half a viewport of slack at each end, or the front stops using the adjustment and places the canvas itself.
- **Downloads, dialogs and navigation policy.** `WebKitDownload`, `script-dialog`, `run-file-chooser` and
  `decide-policy` map one-to-one onto what `PageDialogQueue` and the navigation decider already do
  ([links.md](links.md)).
- **The assistant, ACP and MCP.** The most portable code in the repository — Foundation, child processes, JSON-RPC
  over stdio — with no front to talk to yet. `ModelChoice` collapses to ACP plus the vendored `ClaudeAPI`, because
  FoundationModels is Apple's.
- **Extensions**, when Igalia exposes `WebExtensionContext` and `WebExtensionController`. The install dialog and the
  compatibility verdict port today, because `WebKitWebExtension` already parses a manifest.
- **Favicons and find-in-page**, which WebKitGTK gives away (`WebKitFaviconDatabase`, `WebKitFindController`) and six
  has on no platform.

## Smaller things

- A readable maximum width for the default column on ultra-wide displays: 88 % of a 5K panel is a very long line.
- **WebKit's real back-forward list across a relaunch.** Six restores the trail as *addresses*
  ([architecture.md](architecture.md#persistence)), so ⌘[ after a restart loads the previous page rather than
  restoring the rendered one — no scroll position, no form state, no cached response. `WKWebView` has had
  `interactionState` since macOS 12 for exactly this, and `WebPage` exposes nothing equivalent: its
  `backForwardList` is read-only and its only way in is `load(_ item:)` on an item WebKit already has. This is the
  same hole as [geolocation](#geolocation-screen-sharing-and-web-push-one-trade-not-three) — a `WKWebView` property
  that did not make the crossing — and wants the same answer, a Feedback citing `WebPage.isInspectable` as the
  precedent.
- A window whose address *is* a download re-downloads it on every launch. Nothing was committed in it, so the
  window comes back pointed at the attachment and asks for it again; `closeIfOnlyCarriedALink` only closes the
  window a link opened, not the one somebody typed the address into. Harmless until this session, easy to see now
  that an unfinished row survives a relaunch.
- Restoring where a window was scrolled to. The offset is only read when a window leaves the screen
  (`rememberViewState`), so a window that stayed put all session would come back at the top anyway; doing it properly
  means reading `window.scrollY` for the visible windows as the snapshot is taken, which is a JavaScript call on the
  autosave path.
- Deep research without an agent: a native loop over the ⌘K model for machines with no Claude Code / Codex, and
  exporting a run as one HTML file with its sources inlined ([deep-research.md](deep-research.md)).
- A way back to the start page after navigating (a "home" affordance, or `⌘⇧H`).
- Forget one site: drop a single host's cookies and storage (`WKWebsiteDataStore.fetchDataRecords` →
  `remove(ofTypes:for:)`). Clearing a whole profile is the only option today, and it takes every login with it.
- Per-site user-agent overrides through `WebPage.customUserAgent`, for sites that sniff wrongly even at Safari's
  string.
