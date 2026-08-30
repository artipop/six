# Android

*The fourth front end: `android/`, Kotlin and Compose over the system WebView. The browser is built
and runs; the AI layer is not. This page is the contract it meets and the reasoning behind each
choice — the parts still ahead say so where they are.
Related: [platforms.md](platforms.md), [storage.md](storage.md), [layout.md](layout.md),
[sync.md](sync.md).*

```sh
cd android && ./gradlew :core:test          # the whole contract, no device needed
cd android && ./gradlew :app:installDebug   # onto a running emulator or phone
```

`:core` is a plain JVM module — no Android plugin, no Compose, nothing from the SDK — so everything
that has to agree with the Mac is tested without a device: the strip's geometry against a table
compiled out of `NiriLayout.swift`, `state.json` against a file the Mac wrote, the schema against
`grdb_migrations`, and the extraction script against the Swift literal it was copied from.

Four decisions, taken before any code:

| | |
|---|---|
| language | **Kotlin**, UI in **Compose** — no Swift on the device |
| engine | **the system WebView** through `androidx.webkit` — not GeckoView |
| what is shared | **the contract**, not the code: `state.json`, the SQLite schema, `NiriLayout` |
| out of scope | **blocking and extensions** — [why, and what it would take](#later-deliberately) |

## Why not Swift, when there is now an official SDK

There is one — the Swift SDK for Android shipped with 6.3 in March 2026, owned and versioned by the
Swift project, and the Linux build here already runs 6.3.3. So the option is real. It is just not
worth what it costs, and the reason is a measurement rather than a preference.

`six/` without `Vendor/` is 17 575 lines. Split by what a file imports:

| | lines | |
|---|---|---|
| no Apple API at all (Foundation / Observation / SQLiteData) | 4 565 | |
| `NiriLayout` (691) and `FilterListStore` (133) — nominally SwiftUI/CryptoKit, in fact neither | 5 389 | |
| less what a phone does not get anyway (ACP client, MCP, `ResearchCoordinator`) | **≈ 4 000** | **23 %** |
| WebKit / SwiftUI / AppKit | **13 010** | **77 %** |

Inside those 4 000, half is mechanical: `HighlightScript` (432) is JavaScript in string literals,
`Markdown` (360) and `TextDocument` (242) are parsers with no platform in them. What carries real
design is `NiriLayout` (691, with 167 lines of geometry tests) and the persistence layer.

So a Swift core on Android would save two or three thousand lines, half of it a geometry model that
ports in a day, and would not touch the 77 % — which is rewritten against WebView and Compose in any
language. Against that: a JNI seam through the middle of a browser, where every navigation, every
`didFinishLoad`, every scroll tick crosses it many times a second; and an unmeasured question about
whether SQLiteData and GRDB build against the Android SDK at all.

And the logic that would *grow* is the wrong shape to share. Foundation Models, MLX, CloudKit,
`WKContentRuleList`, `WKWebExtension` — each is a different implementation on Android, not a
different front end over the same one. Sharing pays in proportion to how much stays common, and here
that fraction shrinks as the app grows rather than rising.

(Skip.tools, which transpiles SwiftUI to Compose, is not a candidate for the same reason twice over:
six's SwiftUI is deep in AppKit and `NSEvent`, and it does not do WebKit at all.)

## Why the system WebView, and what it costs

GeckoView is the better *browser* engine — it is what Firefox for Android is built on, it has
tracking protection in the box, real WebExtensions, and a content process per tab, which is the model
`LivePageCache` already assumes. It is also 70 MB per ABI and a seat on Mozilla's release train.

The system WebView is Chromium, updated by the system rather than by us, and it costs nothing in the
package. Its multi-profile API maps onto six's profiles almost exactly. What it does not have, and
will not:

- **Extensions.** There is no host API. [extensions.md](extensions.md) has no Android section.
- **A compiled rule list.** Nothing answers to `WKContentRuleList`; blocking would be a matcher we
  run ourselves, per request, on the WebView's own background thread.
- **A process per page.** Discarding a column is destroying a `WebView` and keeping its state, not
  releasing a content process.

The first two are **out of scope** — see [Later, deliberately](#later-deliberately) — which is what
makes this choice cheap rather than merely defensible. They are exactly and only what GeckoView was
buying, so with them set aside the two engines differ by 70 MB per ABI and a release train, and the
argument stops being close.

`androidx.webkit` gates most of what matters behind runtime feature checks
(`WebViewFeature.isFeatureSupported`), because the WebView on the device is not the WebView we built
against. Every capability below is feature-detected, and the honest answer to "does it work" is per
device.

## The WebKit surface, mapped

| six, on WebKit | on Android |
|---|---|
| `WebPage` / SwiftUI `WebView` | `android.webkit.WebView` inside a Compose `AndroidView`, one per column |
| `WKWebsiteDataStore(forIdentifier:)` per profile | `androidx.webkit.Profile` / `ProfileStore`, `WebViewCompat.setProfile` |
| `WKUserScript(.atDocumentStart)` — highlights, instrumentation | `WebViewCompat.addDocumentStartJavaScript` |
| `WebPage.callJavaScript` | `WebView.evaluateJavascript` — and it takes a completion callback, so the "page scripts must be synchronous" constraint the Mac lives under simply is not there |
| `WKContentRuleList` compiled from filter lists | *out of scope.* Nothing equivalent — it would be `WebViewClient.shouldInterceptRequest` plus our own matcher, cosmetic rules as CSS injected at document start |
| `WKWebExtension` | *out of scope.* No host API at all |
| content process per page; discard and rebuild | `WebView.destroy()` with `saveState` / `restoreState` into a `Bundle` — history and scroll offset survive, which is what the column actually needs |
| page thumbnail | draw the `WebView` into a `Bitmap` |
| `WKDownload` | `DownloadListener` → `DownloadManager` |
| `isInspectable`, Safari's Develop menu | `WebView.setWebContentsDebuggingEnabled` → `chrome://inspect` |
| console capture | `WebChromeClient.onConsoleMessage` |
| network capture | only what `shouldInterceptRequest` sees — not the full request list the Mac's tools answer with |
| camera / mic prompts (`SitePermissions`) | `WebChromeClient.onPermissionRequest`, with the Android runtime permission behind it |
| passkeys ([passkeys.md](passkeys.md)) | unverified; feature-detect before promising anything |
| `LanguageModelSession` | nothing equivalent — the seam moves up a level; Claude over the API first, Gemini Nano after ([the AI layer](#the-ai-layer--phase-two)) |
| `MLXEmbedder` on MLX | the same `multilingual-e5-small` under ONNX Runtime, same 384 dimensions, same `modelID` |
| `sqlite-vec` through `#if canImport` | `BundledSQLiteDriver.addExtension` — proven to work, blocked on packaging ([measured](#the-index-what-was-measured)) |

`minSdk` is **34**. The multi-profile API arrived there, and profiles are not an optional part of
six — a build that cannot keep two profiles apart is a different app.

## What is actually shared

Three artefacts, all of which already exist:

1. **`state.json`** — `AppStateSnapshot`, versioned. Kotlin reads and writes the same shape through
   `kotlinx.serialization`.
2. **The SQLite schema** — visits, settings, bookmarks, chunks, vectors. Written by GRDB, opened on
   Android by `androidx.sqlite` directly. Same tables, same column names, same migrations.
3. **`NiriLayout` and its test vectors.** Port the 167 lines of `NiriLayoutGeometryTests` **first**,
   then make them pass. It is a pure model with no Android in it, so it runs as a JVM unit test, and
   it is the only guarantee that four front ends lay the strip out identically.

`SitePermissions` is the template for everything else that crosses: the decision, the queue and the
suspension are the same everywhere, and only the type the request arrives as differs. On the Mac that
boundary is `#if canImport(WebKit)`. On Android it is a different file with the same shape.

Strings are not shared either — Android is `strings.xml` with its own plural rules — but the two
languages and the line drawn in [localization.md](localization.md) are: what a person reads is
translated, what a model reads stays English.

## The layout, on a phone that is not Apple's

[platforms.md](platforms.md) already settled the axis, and the rule carries over unchanged: the strip
runs along the viewport's *long* edge, decided by `height > width` and nothing else. The Android
reflex here is `sw600dp` resource qualifiers, which would make the same mistake iOS size classes
would — a tablet is "large" whichever way it is held. Measure the window, in Compose, with
`BoxWithConstraints`; re-measure on rotation and on fold state.

The phone gesture model is already designed for this and happens to solve Android's hardest problem
for free. A `WebView` inside a horizontally scrollable container fights over every touch; six never
asks it to, because the strip is driven from the handle above each window and never from the page.
Along the handle pans the strip, across it changes workspace, both feeding `NiriLayout`'s
`horizontalPreview` / `verticalPreview`. Inside the page every gesture is the page's.

## The AI layer — phase two

Not deferred in the sense blocking is. `Embedder` is already a protocol, `storage.md` already names its
non-Apple adapter as "llama.cpp / ONNX embedder — *same model and version*", and Android is simply
that adapter written in Kotlin. The work here is almost entirely about exactness, not volume.

### The embedder, and why "the same model" is a stronger claim than it looks

`bookmark_vectors(chunkID, profileID, model, embedding BLOB)` stores the model id beside every
vector, and the whole design rests on what that column promises: two rows carrying the same id are
comparable. If Android writes `multilingual-e5-small` and produces vectors from a *slightly*
different pipeline, nothing errors — search just quietly gets worse, on the device that did not
compute the query. That is the worst failure mode available here, so four things have to match, and
each is a place the Kotlin side can drift on its own:

1. **The role prefixes.** `query: ` and `passage: ` on every text. E5 is asymmetric and
   `EmbeddingRole` exists for exactly this.
2. **Mean pooling, then L2.** `MLXEmbedder` says this explicitly, in a comment, because the pooling
   config does not reach the factory and the container falls back to CLS — which puts every sentence
   within a few percent of every other. Android has no container to default anything: pooling is
   ours to write, and therefore ours to get wrong.
3. **The tokenizer.** E5 is XLM-RoBERTa sentencepiece; Swift gets it from `Tokenizers` over the Hub
   snapshot. Kotlin needs *identical token ids* — either ONNX Runtime Extensions with tokenisation
   baked into the graph, which makes the graph itself the contract, or a sentencepiece binding. This
   is where it will actually break.
4. **No quantisation.** An int8 e5-small is a quarter of the download and a **different model**: its
   vectors do not live in the Mac's space. Quantising here is not an optimisation, it is a change of
   `modelID`, and it happens on both sides at once with a re-index or not at all.

The test that holds this together is golden vectors: a few dozen fixed strings, both roles, Latin and
Cyrillic, embedded on the Mac and committed; Android asserts cosine ≥ 0.999 against them. Token ids
first, vectors second — a token mismatch explains a vector mismatch, and not the other way round.

Chunking is part of the same contract, not a detail below it: passages of ~900 characters with chunk
0 = title + excerpt. Different boundaries mean different passages mean different vectors for the same
bookmark. `ReadablePage`'s extraction is JavaScript running in the page, so it ports as text, the way
`HighlightScript` does.

Weights are ~230 MB, fetched on first use into app storage with the same status narration the Mac
shows — not shipped in the package.

### The index: what was measured

The `vec0` tables are an index over the vectors, never the record, and they are not in the migration
history on either platform — `BookmarkStore` creates one per dimension, lazily. That is what makes
this a decision Android can take on its own: attaching an index or not touches neither the shared
schema nor `grdb_migrations`.

Three things were established by running them rather than reading about them, and they split the
question cleanly in two.

**The SQLite half works.** `androidx.sqlite`'s bundled build has extension loading compiled in, and
`BundledSQLiteDriver.addExtension(path, "sqlite3_vec_init")` reaches it. Loaded that way, sqlite-vec
answers `vec_version()`, creates a `vec0(embedding float[384])` table, takes vectors and returns a
correct nearest-neighbour ordering — exact match at distance zero. `SqliteVecTest` is that, run on
the JVM against the same library and the same compile options that ship in the app.

The entry point has to be named explicitly: SQLite derives one from the file name otherwise, and the
file is `vec0.so`.

**Vectors go in as a float32 blob, not as JSON.** That is what the Mac writes anyway, so it costs
nothing — but it is not optional here. With this pairing, the bundled SQLite 3.50.1 against a
sqlite-vec built nine months later, every JSON text form is rejected with a parsing error, including
one produced by SQLite's own `json_array()`. The blob path is unaffected. Anyone who reaches for the
documented `'[0.1,0.2]'` syntax first will conclude the extension is broken; it is not.

**The Android half is packaging, and it is blocked today.** sqlite-vec publishes prebuilt loadables
for all four ABIs, so no NDK is needed to *get* one — but the ELF program headers are 4 KB aligned
(`PT_LOAD align = 0x1000`), and Android 15's 16 KB-page devices refuse to load those. The emulator
this was checked against is one (`sdk_gphone16k_arm64`). Getting past it means rebuilding sqlite-vec
with `-Wl,-z,max-page-size=16384`, which does need the NDK.

Two smaller things wait behind that. The file has to be named `lib*.so` to be packaged and extracted
as a JNI library at all, and `android:extractNativeLibs` has to be **true**, because `addExtension`
takes a filesystem path and the default packaging leaves the library compressed inside the APK where
there is no path to give it.

So: brute-force cosine over the chunks remains the first answer, and the extension is a known
quantity waiting on one rebuild rather than an unknown.

### The assistant inverts

`LanguageModelSession` is Foundation Models and there is nothing behind it on Android, so the seam
moves up: not "swap the model" but an interface with ask, stream, cancel, reset and tool calls — the
shape `AssistantStore` already has. What the platform offers:

- **Gemini Nano through ML Kit GenAI**, over AICore — the recommended route in 2026, but its APIs are
  task-shaped (summarise, rewrite, proofread) rather than free-form, and AICore reaches a narrow set
  of devices. Enough to answer `summarize_page`; not enough to be the ⌘K line.
- **LiteRT-LM** for running a Gemma-class model ourselves. MediaPipe's LLM Inference task is
  maintenance-only now and its successor is the LiteRT-LM Kotlin API. Broad device support, another
  large download, and tool calling that is not worth the name.
- **Claude, over the API.** Here the platforms invert: iOS *cannot* have Claude, because the vendored
  `ClaudeForFoundationModels` needs the Command Line Tools SDK's Foundation Models SPI
  ([platforms.md](platforms.md)). Android is not in that argument at all — it is HTTPS and the key
  field that already exists in the settings. Android gets the model the phone cannot have.

So Android's first assistant is Claude and on-device comes after — the reverse of the Mac's default,
because that is the order this platform actually supports.

`ModelChoice` gains a third column, with neither Private Cloud Compute nor ACP in it, and the
"a setting saved on one and read on the other falls back to `.onDevice`" rule now has to answer for
three platforms rather than two — where `.onDevice` may itself be unavailable.

The tools travel with the assistant. `BrowserToolCatalog` describes each tool once; `BrowserModelTool`
wraps it for Foundation Models and MCP serves the same catalog to agents. On Android that catalog is
a Kotlin declaration wrapped as Anthropic tool-use schemas — and its text stays English, because it
is a prompt and not an interface ([localization.md](localization.md)).

## What Android does not have

The iOS exclusion list, inherited whole and for the same reasons — no child processes, no toolchain:
`ACP/` beyond the wire types, `MCP/`, `ResearchCoordinator`, the agent panel.

## Later, deliberately

**Blocking and extensions are out of scope**, and not as an oversight to be tidied up later: they are
the two subsystems where Android is not a second front end over the same design but a second design.
Leaving them out is what keeps the first version a port rather than a rewrite.

- **Blocking** ([blocking.md](blocking.md)). `FilterList` and `FilterListStore` — fetch, hash, cache,
  enable — would port; `RuleConversion` would not, because it converts to WebKit's JSON. What Android
  needs instead is an ABP matcher fast enough to live on `shouldInterceptRequest`'s thread, and that
  budget has to be measured before any UI is built around it. Until then there is no shield in the
  address field and no per-site allowlist, and the Privacy settings the Mac writes are read and left
  alone rather than acted on.
- **Extensions** ([extensions.md](extensions.md)). Not deferred but absent: the system WebView has no
  host API. If this ever comes back it is not a feature but an engine decision — it means GeckoView,
  and it means revisiting this document from the top.

Both are also the reason to keep `ContentBlocker` behind a seam on the Kotlin side from the start
rather than inlining "no blocking" into the page setup: the shape has to survive being filled in.

## Android is what decides the sync backend

[sync.md](sync.md) is written on `CKSyncEngine`, and says plainly that CloudKit Web Services is not a
client SDK. There is no CloudKit on Android. On the Mac and the phone a shared file can be a
meeting point; between a Mac and an Android device only a server is.

So committing to Android is the same act as committing to a non-Apple backend behind the `SyncEngine`
protocol. Better to know that now, before the CloudKit implementation is written, than to write it
twice.

## Where state that belongs to one device lives

Not in the database, and this is a rule rather than a preference.

`SQLiteData`'s sync is **opt-in per table**: `SyncEngine(for:tables:privateTables:)` takes the tables
by name, and anything not named is never synchronised. There is no filter below that — the only
method on `SyncEngineDelegate` is `accountChanged`, so "sync this table but not that row" is not
something the library can be asked for.

So a row holding state that belongs to one device is safe exactly as long as nobody adds its table to
that list, and unsafe the moment somebody does — silently, and in the direction that matters least
until it matters most. [sync.md](sync.md) already says the live strip must not travel: which windows
are open on this device is like Safari's iCloud Tabs, a list rather than a layout.

The clean answer is a table of its own that is never named. Android cannot write that one: the
schema's migrations are matched by identifier against `grdb_migrations`, so a table added here and
not on the Mac makes the Mac replay its own version of the same history and fail. A `device_state`
table is a Mac-side change, and until it exists this platform keeps `state.json`.

Which costs nothing, because the file is not a workaround here. `AppStateSnapshot` and
`FileSnapshotStore` are already written and tested, and the snapshot carries the `agent`, `research`
and `window` branches through untouched — a property no row in `settings` would have.

**The Linux front does it the other way**, in `settings["strip.state"]`, and says why: a front with no
snapshot machinery yet gets durability for free from the database that is already open and already
migrated. That reasoning is sound where it is written and does not reach Android, which has the
machinery. It is worth revisiting there the day `settings` joins the sync list.

## What is built

Phase one, the browser. Everything below has been run on a device, not only compiled.

- **The strip**, in Compose over `NiriLayout`: columns placed from `columnFrames`, the axis decided
  by the viewport's shape, both neighbouring workspaces drawn so the across-drag has something to
  move, a workspace indicator, and the overview's rescale.
- **Windows**: the handle as title, address field and drag surface; a `×` that backs out of the field
  before it closes anything; the profile's colour on the border and the loading dot.
- **Pages**: one `WebView` per live column, the back gesture belonging to the page before the app,
  and load failures reaching the browser rather than only the engine's error page.
- **Discarding**: only the columns `visibleTabIds` names keep a page, the rest are cards carrying the
  last picture of themselves, and memory pressure narrows that to the window being read.
- **Profiles**, including a private one that leaves nothing behind — and, because this platform has
  no ephemeral profile, deletes its store by hand and sweeps at launch for the times it could not.
- **Persistence**: `state.json` and `six.sqlite`, both in the Mac's format, with history and settings.
- **Bookmarks** without the index: the row, the passages and the readable Markdown file.
- **Site permissions** and the four dialogs a page can put up.
- **Both languages**, through `strings.xml`.

Not built, and named rather than implied: the assistant, the embedder and any search by meaning;
blocking and extensions, which are out of scope outright; an overview grid behind the rescale; moving
a window between workspaces, which the iPhone does not have either.

## The steps

Two phases. Phase one is a browser; phase two is what makes it six.

Following the shape the GTK port took — a spike that answers a small number of questions, then the
layer, then the thing.

### Phase one — the browser · done

0. `android/` beside `linux/`. Gradle, Kotlin, Compose.
1. The spike. Overtaken: the emulator arrived late, so the questions were answered by building the
   thing and then running it. What that cost is written down under [what running found](#what-running-found).
2. `NiriLayout` in Kotlin — tests first, model second, no Android dependencies.
3. Persistence — the snapshot and the database, against the real schema.
4. The strip — a column per page, the handle, the drag along and across, the address field.
5. Chrome and profiles — `ProfileStore`, the toolbar, history, the start page.

### Phase two — the AI layer · ahead

6. **The embedder.** ONNX Runtime with `multilingual-e5-small`, weights fetched on first use. Golden
   token ids before golden vectors, and neither is a formality: they are the only thing standing
   between a shared vector space and a silently worse search.
7. **Search by meaning.** The bookmarks already have their passages, so an embedder can run over what
   is saved rather than fetching every page again. Brute-force cosine first; `sqlite-vec` when the
   numbers ask and its packaging is solved.
8. **The assistant** — Claude over the API, `BrowserToolCatalog` re-declared in Kotlin as tool-use
   schemas. Gemini Nano behind the same seam afterwards, starting with `summarize_page`, which is the
   one tool ML Kit's task-shaped APIs actually fit.

## What running found

Three things a green build and a hundred and thirty tests did not.

**The app could not start.** The manifest named `.MainActivity` against the namespace
`org.deffun.six`, and the class is in `org.deffun.six.app`.

**One SQLite connection, several coroutines.** A page committing a visit, the snapshot being written
and a bookmark being saved are three writers on the IO dispatcher, and two transactions interleaving
gets `cannot start a transaction within a transaction` — a crash, not a lost write. GRDB gives the
Mac that guarantee by owning a writer queue; here it is a reentrant lock, and the connection is no
longer handed out as a property so the shape cannot be written again. Every test until then used one
database from one thread, the single arrangement in which this cannot happen.

**Nothing reported a failed load.** The engine drew its own error page and the browser knew nothing —
which is also how the emulator's missing DNS looked like a bug in the address bar.

The lesson is the ordering rather than the bugs: none of the three is subtle, and none of them is
findable by reading. Getting onto a device earlier would have been worth more than any amount of
further care.

## Still to measure

The device has been used now, but only for the things a first launch exercises. These are the claims
still standing on reasoning alone.

- Whether `saveState` / `restoreState` really brings a discarded column back where it was. The whole
  live-pages design rests on it and it is the claim most likely to be half-true — the documentation
  promises the back/forward list and says nothing about the scroll offset.
- How many live `WebView`s a device carries before the system starts killing the app. The Mac's
  budget is a memory-pressure band; Android's is `onTrimMemory`, and the numbers will not be the
  Mac's.
- The gestures. Written and read carefully, never yet driven by a finger: the drag along and across
  the handle, and what a real hand does at the boundary between them.
- Passkeys: whether the WebView on a current device authenticates at all.
- Multi-profile: present on every WebView version that ships with API 34+, or feature-detected with a
  real fallback that has actually been seen.
- Whether a page's thumbnail comes back with the parts the engine composited on the GPU, or with
  holes where a video was.

And before phase two starts, not during it:

- Whether Kotlin can be made to produce E5 token ids identical to `Tokenizers`'. If it cannot, the
  shared vector space is not available and the whole phase is shaped differently — a remote embedder
  behind the same protocol, rather than a local one.
- Brute-force cosine over a realistic number of chunks on a real device, which decides whether
  sqlite-vec is worth its packaging problem at all.
