# WebMCP

A page can offer agents tools of its own, and six can call them. This follows
[agent-actions.md](agent-actions.md) and [accessibility.md](accessibility.md), where an agent looks at a page from
outside — its text, its accessibility tree, clicks. WebMCP is the page saying **itself** what it can do and handing
over the functions for it.

## What it is

[WebMCP](https://webmachinelearning.github.io/webmcp/) is a W3C Community Group draft (Web Machine Learning CG; Google
and Microsoft), last revised 10 September 2026. A page registers **tools** — a name, a description, a JSON Schema for
the input and a JavaScript function that runs them — and a browser agent calls those instead of clicking through the
interface. In shape it is an MCP server that lives inside the tab and works in the session the person is already
signed in to.

The interface as the draft has it now:

```webidl
[Exposed=Window, SecureContext]
interface ModelContext : EventTarget {
  Promise<undefined> registerTool(ModelContextTool tool, optional ModelContextRegisterToolOptions options = {});
  Promise<sequence<RegisteredTool>> getTools(optional ModelContextGetToolOptions options = {});
  Promise<DOMString> executeTool(RegisteredTool tool, optional any inputObject,
                                 optional ModelContextExecuteToolOptions options = {});
  attribute EventHandler ontoolchange;
};
```

- reached as `document.modelContext`, one per document;
- `ModelContextTool`: `name` (1–128 characters, `[A-Za-z0-9_.-]`), `description`, `inputSchema`,
  `execute(input, {signal})`, `annotations`;
- `annotations`: `readOnlyHint`, `untrustedContentHint`, `consequentialHint`, all `false` by default;
- `registerTool(tool, {signal, exposedTo})`: an `AbortSignal` unregisters; `exposedTo` lists other origins that may
  see the tool;
- `getTools` / `executeTool` are for agents living in the page (or an iframe), filtered by `fromOrigins`;
- secure contexts only; in an iframe through the `tools` permissions policy (`'self'` by default, cross-origin only
  with `allow="tools"`);
- a declarative form — attributes on `<form>` (`toolname`, `tooldescription`, `toolparamdescription`) from which the
  browser synthesises a tool. That section of the spec is still **TODO** and lives in a separate explainer.

## Where it stands

- **Chrome**: origin trial from 149 to 156. `navigator.modelContext` shipped in 146 and was deprecated in 150, when
  the 21 July 2026 revision moved the API to `document.modelContext`. First-trial sites call
  `navigator.modelContext.registerTool`, newer ones `document.modelContext`.
- **Edge**: behind a flag since 147.
- **WebKit is opposed** ([WebKit/standards-positions#670](https://github.com/WebKit/standards-positions/issues/670)):
  API design, duplication of the existing platform, privacy, security, unclear use cases. **Mozilla** is discussing
  it and has no implementation.
- **Polyfills**: `@mcp-b/global` and its neighbours (descendants of the MCP-B prototype) put `modelContext` on the
  page and carry it to an MCP client.
- **Who is trying it**: Google I/O 2026 named trial participants — Expedia, Booking.com, Shopify, Credit Karma,
  TurboTax, Redfin, Etsy, Instacart, Target. Who has actually shipped is unconfirmed.

The consequence for six: **there will be no native WebMCP in the engine** — not in WebKit on the Mac, WebKitGTK on
Linux or WebKit on Windows — while WebKit is opposed. What six offers is its own polyfill and its own agent side. In
return it is one implementation on every front, and it waits for nobody's release.

## Why six wants it

An agent in six has four ways to understand a page, and WebMCP is the best of them where it exists:

1. **The service's own MCP server**, connected in Apps (`<server>__<tool>`). Best of all, but only where a server
   exists and has been connected.
2. **The page's WebMCP tools.** The same session and cookies, no OAuth, and functions the site wrote for agents:
   `search_flights(from, to, date)` instead of twenty clicks through a calendar. They survive a redesign and answer
   with structure rather than pixels.
3. **The page's controls, read and acted on** ([agent-actions.md](agent-actions.md)) — every other site. Works
   anywhere, but it is still "press button 12".
4. `evaluate_javascript`, the last resort.

"Through the page's own API or DOM, not a model looking at pixels" is the rule agent-actions.md settled on, and WebMCP
is that rule taken literally: the page's own API, declared for the agent.

## How it is built

**Only three things are owed by a front** (`WebMCPPage.swift`): install `WebMCPScript.source` as a user script in the
page's world, route the channel's messages into `WebMCPHost.receive`, and run a function body in the page's world.
Everything else — whether WebMCP is on, settling the document after a navigation, the call, the gate, finding the
self-test's window — is shared.

- `six/WebMCP/`, in `SixCore` and so on every front: `WebMCPScript` (the polyfill and the call bodies),
  `WebMCPRegistry` (the channel's messages and the window → tools registry), `WebMCPHost` (calls in flight, the gate,
  the "an agent is calling" mark), `WebMCPPage`, `WebMCPSelfTest`.
- The bridges: `six/WebMCP/WebMCPStore.swift` (Apple), `windows/Sources/SixUI/StripWebMCP.swift` (Windows),
  `linux/Sources/SixWebKitCore/PageChannels.swift` with `linux/Sources/SixBrowser/WebMCP.swift` (Linux).
- Agents get `list_page_tools` and `call_page_tool` in the catalog, over MCP. The ⌘K assistant gets the focused
  window's `readOnlyHint` tools as tools of its own (`WebMCPModelTool`), with their JSON Schema translated into a
  `DynamicGenerationSchema`, and its session is rebuilt when that set changes.
- The mark: on the Mac, `PageToolsButton` — a wrench at the trailing end of the address field beside translation's
  button, its tooltip counting the tools, pulsing while a call runs, and the list behind it on a click. On Windows a
  badge with the count, lit while a call runs.

Off by default, behind `six://configuration` ▸ Develop ▸ WebMCP.

### The polyfill

A user script in the **page's** world at document start, main frame only. In the page's world rather than six's for
the reason console capture lives there ([devtools.md](devtools.md)): the page has to reach `document.modelContext`,
or there is nothing to declare. It is the second deliberate exception to "everything of six's in six's world".

- It defines `document.modelContext`, and `navigator.modelContext` as the same object for first-trial sites — only
  when neither exists yet, so a polyfill the page brought (`@mcp-b/global`) keeps its own.
- `registerTool` validates the name and schema as the draft does (`TypeError` / `InvalidStateError`), keeps `execute`
  and sends Swift **only the description**: `name`, `title`, `description`, `inputSchema`, `annotations`, `origin`.
  `register` answers with an object carrying `unregister()`, as the first trial did.
- An `AbortSignal` unregisters and says so; `toolchange` fires on the page as the spec says; `getTools` and
  `executeTool` work over the same registry for agents inside the page.

**The channel** is a `WKScriptMessageHandler` in the page's world with a name that is new on every launch, as console
capture's is. A page can post into it and forge a registration — of its **own** tool, which gains it nothing.

**The registry is not cleared when a navigation commits.** On the Mac that news arrives through an async sequence and
can land after the new document has already declared its tools. Every message carries its document's token instead,
and a navigation only asks the page for its current one (`settle`).

### Calls

Two stable tools in the catalog rather than one per page tool: `list_page_tools(window_id?)` and
`call_page_tool(window_id?, name, arguments)`. Expanding them as `page__search_flights` would change the catalog on
every navigation of every window, send `notifications/tools/list_changed` constantly, and fight the ⌘K assistant's
tool set, which is fixed per session.

A call takes two moves: the tool is started, and its answer comes back over the channel with the call's id, so
nothing depends on whether `WebPage.callJavaScript` waits on a promise (it does not take `await` at all). Around it:

- a timeout (30 s by default) and cancellation, through an `AbortController` whose `signal` reaches `execute`;
- a navigation mid-call is the error "the page went away", not a hang;
- the answer is capped like `get_page_content`'s, and fenced as the page's data, not instructions, whatever
  `untrustedContentHint` says.

### The gate

Two separate questions, both through the same queue and the same bar as the camera's (`SitePermissions`, which grew a
third kind of question rather than a second queue, so each front's permission bar draws it with no new UI):

- **The site, once.** The first call to a site asks "may agents use the tools this site offers them?". The answer is
  remembered per profile and origin, shown in `six://configuration` ▸ Privacy ▸ Site Permissions and taken back from
  there. It is asked at the first call, not when a page declares tools: a page whose tools nobody calls has asked for
  nothing.
- **The call, every time**, unless the page marked the tool `readOnlyHint` — and always for `consequentialHint`. The
  bar shows the tool's name and its **arguments**, never the page's description of them: the page writes the
  description, and this is the one line between it and the session the person signed in to.
- **Private windows** get no polyfill at all, on any front.
- **A front that wired no way to ask is refused**: no `WebMCPHost.ask` means no.

Annotations are the page's word about itself, so they lift the question about the *call* and never the one about the
site.

**Rolling back is not free.** `SitePermission` has a new kind, `pageTools`, and the permission list is decoded whole:
an older build reading a database with a `pageTools` row forgets **every** site answer — the same case as `location`
in [permissions.md](permissions.md).

## Not built

- **Declarative forms.** When the spec's section stops being TODO: walk `form[toolname]` in six's world, map
  `toolname` / `tooldescription` to a tool and named fields with `toolparamdescription` to its schema, and call by
  filling the fields and submitting with the agent mark (`SubmitEvent.agentInvoked`, `respondWith(promise)` in the
  explainer). Follow the spec, not the explainer — Lighthouse already checks the attributes, so sites will set them
  before the spec settles.
- **iframes and `exposedTo`.** Main frame only, `exposedTo` ignored, no `tools` permissions policy — so `fromOrigins`
  in `getTools` filters nothing useful.
- **Not native.** The IDL is followed as far as `idlharness` checks it, but the events six dispatches are the page's
  own and `isTrusted` is false. The page sees the polyfill and can replace it — with an engine that opposes WebMCP there
  is no other way.
- **Input is not checked against `inputSchema`** before a call.
- **`exposedTo` is validated and then ignored**: a non-trustworthy origin is a `SecurityError`, as the draft says,
  but nothing is ever exposed to another frame.
- **Windows a page opens itself** (Windows, `openPageWindow`) get no channel: WebKit configures them, not
  `WebEngine.makeView`.
- **Linux has no MCP server**, so its page tools are seen only by the self-test and `BrowserModel.pageToolCount`, and
  there is no mark in its bar.
- **The ⌘K assistant gets only some tools**: `readOnlyHint` ones whose schema translates (an object of strings,
  numbers, booleans, enums and arrays of those). The rest stay with ACP agents through `call_page_tool`.
- **Limits of six's own, not in the draft**: at most 100 tools a document, descriptions up to 4,000 characters,
  schemas up to 64 KB.
- **`navigator.modelContext`** stays for Chrome's first-trial sites; when the trial ends (156), see who still calls
  it and remove it.

What not to do: wait for WebKit, or turn six into a bridge for someone else's agent — MCP-B's page → extension →
external client path is not needed when six **is** the MCP server (`six --mcp`), and page tools leave through
`call_page_tool` with the rest of the catalog and its permissions, not around them.

## Compatibility: web-platform-tests

wpt has the suite Chromium moved its own tests into, [`webmcp/`](https://github.com/web-platform-tests/wpt/tree/master/webmcp),
and `scripts/webmcp-wpt.py` runs it in a running dev six over `six --mcp`, on wpt's own `wpt serve` — the stand is
described in [test-suites.md](test-suites.md#the-shared-stand): `six.localhost` and its subdomains with no hosts file,
a second and a cross-site origin, the LAN address as the non-secure one, and a CA of its own trusted by the dev build
only.

```sh
./scripts/webmcp-wpt.py --install-ca          # once, with the dev six quit
open -na <Debug six.app> --env SIX_WEBMCP=1
./scripts/webmcp-wpt.py                       # everything, and what moved against the baseline
./scripts/webmcp-wpt.py imperative/getTools   # only paths containing an argument
./scripts/webmcp-wpt.py --write-baseline      # after a change that should move the numbers
```

The baseline is `scripts/webmcp-wpt-baseline.json`. At wpt `a9871a2`: **89 of 166** — imperative 60 of 97,
`idlharness` 22 of 22, `tool-activated-event` 4 of 4, declarative 3 of 43. Every imperative test that fails involves a
frame — an iframe, a detached frame, a second origin, `window.open` — which six does not build (main frame only),
plus `isTrusted` on `toolactivated`, which no polyfill can pass. The declarative ones fail because declarative forms
are not built. What the suite taught the polyfill, and it now does: `getTools()` sorted by name and carrying
`window`; annotations absent when none were given, with `debugging`; `InvalidStateError` for a bad name;
`AbortError`/the signal's reason from `registerTool` when its signal aborts; `SecurityError` for `exposedTo`;
`executeTool` input through JSON and required to be an object, `UnknownError` for a missing tool or a failed call,
`NotSupportedError` for an opaque origin, a default `AbortSignal`, the caller's abort rejecting at once and reaching
the tool a task later; `toolactivated` on the window and the context (with `ontoolactivated`) and `toolcancel` on the
window; titles made well-formed; nothing at all on a non-secure page. And, for `idlharness`: `modelContext` a getter
on `Document.prototype`, `ModelContext` and `ToolActivatedEvent` as globals whose operations and attributes are
enumerable, have WebIDL's lengths and brand-check `this`. The polyfill takes `Promise`, `Map`, `URL` and the rest
from `window` before the page runs, so a page replacing one of them does not break it; a page patching their
prototypes still can.

## Frames: what WebKit allows, measured

Every frame test in the suite needs the polyfill in frames other than the main one, and a broker that can reach any
of them. Measured on 2026-09-27, macOS 27, dev build, with a throwaway probe (a user script in every frame of the
page's world, a `WKScriptMessageHandlerWithReply`, and `WKWebView.callAsyncJavaScript(_:in: WKFrameInfo, contentWorld:)`
through `WebViewResponder.webView(for:)`), on a stand page holding a same-origin iframe, two cross-origin ones
(`www1.six.localhost`, one with `allow="tools"`), a `srcdoc`, a static `about:blank` and one created from script:

- **A `forMainFrameOnly: false` user script reaches every one of them** — cross-origin frames included, `srcdoc`, the
  static `about:blank`, and an `about:blank` iframe created by `appendChild`, where it has already run when
  `appendChild` returns. The parent does not have to install anything into a same-origin child itself.
- **The reply handler answers in every frame.** `postMessage` returns a promise there, and each frame got its own
  answer; `message.frameInfo` names the frame's own origin (`about:blank` and `srcdoc` inherit the parent's), which
  is the origin six should trust rather than anything the page says.
- **Running code in one particular frame works**, cross-origin frames too, from the `WKFrameInfo` its message
  carried. A frame that has gone answers `WKErrorDomain` 12, "Target frame could not be found" — the navigated-away
  case, for free. `WebPage.callJavaScript(in:)` takes a `WebPage.FrameInfo`, which only navigation and dialog
  callbacks hand out, so the `WKWebView` is the way in; it exists once a pane has shown the window.
- **WebKit has no `document.featurePolicy` or `permissionsPolicy`.** The `tools` policy has to be six's own
  computation.
- **`window.open` hands the page no window.** Without a gesture WebKit's popup blocking answers `null`; with one six
  opens a new column that is not scripting-connected to its opener (docs/links.md). The two tests that script an
  opened window — `exposedTo-window-open` and `executeTool-across-trees` — cannot pass until that changes, and the
  same gap breaks any site whose sign-in popup answers through `window.opener`. That is a browser matter, not a
  WebMCP one.

### The shape this gives stage 3

- The polyfill runs in every frame, each with a random frame token beside its document token. Swift keeps the latest
  `WKFrameInfo` per window and frame token, and takes the frame's origin from it.
- The channel becomes a reply handler, so `getTools` and `executeTool` from any frame are one request to Swift and
  one answer. The broker is `WebMCPHost`, in `SixCore`: a registry per window, per frame, with `exposedTo` and
  `fromOrigins` applied there.
- A call into another frame goes to that frame through `callAsyncJavaScript(in:)`, and its answer comes back over
  the channel as calls do now. A stale frame is a navigation.
- The `tools` policy: a frame is allowed when it is same-origin with its parent, or when the parent's iframe element
  says `allow="tools"` (or `tools *`, or names the child's origin). The parent's polyfill reports its iframes'
  `allow` and hands each child, by `postMessage`, a random id for its element; the child passes it to Swift. A child
  that lies can only claim a sibling's policy, and only with an id it was never sent.
- A detached frame's `document.defaultView` is `null`: every operation there is `InvalidStateError`.
- `toolchange` is dispatched by Swift into every frame whose view of the tools changed.
- Agents see a subframe's tools with the subframe's origin, and the site question is asked about that origin — an
  ad frame does not inherit the answer given to the page.

## What has been checked

- **Mac.** Both schemes build. `SIX_WEBMCP_SELFTEST` against `Tests/WebMCP/webmcp.html`: 22 checks, `PASS`.
  `WebMCPTests` pass with the rest of `SixCore`'s tests. wpt as above.
- **Windows, real WebKit.** The same self-test, 22 checks, `PASS`; the badge seen in a `PrintWindow` capture. `file:`
  is a secure context in that WebKit, and `WKPageCallAsyncJavaScript` runs in the page's world.
- The self-test covers: a declaration with annotations and schema, `add(2,3)` → `5`,
  `document.modelContext === navigator.modelContext`, `getTools()` inside the page, the site asked about at the first
  call and not again, a changing call confirmed, a no stopping the call **before** the page runs it, a timeout through
  `AbortSignal`, unregistering through `abort()`, a new document with its own tools, the site's answer outliving a
  navigation, a navigation mid-call, an empty registry on `about:blank`. It forgets its own site answer first, so it
  can be run back to back.

### Not checked

- **Linux has never been built.** Its first container build has to answer whether `WebKitUserContentManager` and
  `JSCValue` import as `OpaquePointer`, whether `webkit_user_content_manager_register_script_message_handler` takes
  the world as its third argument, whether `script-message-received` is (`manager`, `JSCValue*`, `gpointer`), and
  whether `webkit_web_view_get_user_content_manager` gives each view its own manager.
- **The ⌘K schema translation (`WebMCPModelTool`)** has not been exercised with a model.
- A polyfill that arrived with the page (`@mcp-b/global`), on a live page: whether it and six's leave each other alone.

### How to check it

**Mac:**

1. `six://configuration` ▸ Develop ▸ WebMCP on;
2. open `file:///…/Tests/WebMCP/webmcp.html`: a wrench in the address field, its tooltip saying 4, a click listing
   them with the read-only and consequential marks;
3. `six --mcp` → `list_page_tools`, then `call_page_tool` with `name: add`, `arguments: {"a":2,"b":3}` — the bar asks
   about the site, and `5` comes back after the answer;
4. `call_page_tool` with `name: forget_slow` — a bar with the tool's name and arguments, on every call;
5. ⌘K: ask for something that needs `add` — the assistant has it as its own tool and does not have `slow`, which is
   not read-only;
6. the same in a private window: no tools at all;
7. `SIX_WEBMCP_SELFTEST=file:///…/webmcp.html` on launching the dev build — the report goes to
   `~/Library/Logs/org.deffun.six.dev/six.log`.

**Windows:**

```powershell
./scripts/six-windows.ps1 build      # stops every running six-windows, other sessions' included
$env:SIX_WEBMCP_SELFTEST = "file:///C:/Users/Artem/sources/six/Tests/WebMCP/webmcp.html"
.\windows\.build\x86_64-unknown-windows-msvc\debug\six-windows.exe
```

The report is in `%LOCALAPPDATA%\six\Logs\six.log`, the line `webmcp self-test`, ending in `PASS`. By hand:
`SIX_WEBMCP=1` instead, and the same page shows a 4 in the address bar.

**Linux** (in the container, [linux.md](linux.md)):

```sh
./scripts/six-linux.sh build
SIX_WEBMCP_SELFTEST=file:///work/Tests/WebMCP/webmcp.html ./scripts/six-linux.sh up
```

**wpt**: `./scripts/webmcp-wpt.py`, above.

**Unit tests**: `swift test --disable-automatic-resolution`. `WebMCPTests` covers message parsing, the registry,
calls, the gate and what the agent reads.

Sources: [the draft](https://webmachinelearning.github.io/webmcp/),
[repository and explainer](https://github.com/webmachinelearning/webmcp),
[WebKit's position](https://github.com/WebKit/standards-positions/issues/670),
[state of WebMCP, July 2026](https://www.spronta.com/blog/state-of-webmcp-july-2026/).
