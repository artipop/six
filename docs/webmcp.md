# WebMCP

A page can offer agents tools of its own, and Savoia can call them. This follows
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

The consequence for Savoia: **there will be no native WebMCP in the engine** — not in WebKit on the Mac, WebKitGTK on
Linux or WebKit on Windows — while WebKit is opposed. What Savoia offers is its own polyfill and its own agent side. In
return it is one implementation on every front, and it waits for nobody's release.

## Why Savoia wants it

An agent in Savoia has four ways to understand a page, and WebMCP is the best of them where it exists:

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
self-test's window — is shared. That is the main frame alone. A front that also injects into every frame, answers
the channel (`WebMCPHost.request`) and can run code in one given frame (`WebMCPFrame`) gets the frames: the Mac does,
Windows and Linux do not yet, and the polyfill tells the two apart by whether `postMessage` answers.

- `Savoia/WebMCP/`, in `SavoiaCore` and so on every front: `WebMCPScript` (the polyfill and the call bodies),
  `WebMCPRegistry` (the channel's messages and the window → tools registry agents read), `WebMCPHost` (calls in
  flight, the gate, the "an agent is calling" mark), `WebMCPBroker` (every frame's documents, who sees what, the
  `tools` policy, calls between frames), `WebMCPPage`, `WebMCPSelfTest`.
- The bridges: `Savoia/WebMCP/WebMCPStore.swift` (Apple), `windows/Sources/SavoiaUI/StripWebMCP.swift` (Windows),
  `linux/Sources/SavoiaWebKitCore/PageChannels.swift` with `linux/Sources/SavoiaBrowser/WebMCP.swift` (Linux).
- Agents get `list_page_tools` and `call_page_tool` in the catalog, over MCP. The ⌘K assistant gets the focused
  window's `readOnlyHint` tools as tools of its own (`WebMCPModelTool`), with their JSON Schema translated into a
  `DynamicGenerationSchema`, and its session is rebuilt when that set changes.
- The mark: on the Mac, `PageToolsButton` — a wrench at the trailing end of the address field beside translation's
  button, its tooltip counting the tools, pulsing while a call runs, and the list behind it on a click. On Windows a
  badge with the count, lit while a call runs.

Off by default, behind `savoia://configuration` ▸ Develop ▸ WebMCP.

### The polyfill

A user script in the **page's** world at document start, main frame only. In the page's world rather than Savoia's for
the reason console capture lives there ([devtools.md](devtools.md)): the page has to reach `document.modelContext`,
or there is nothing to declare. It is the second deliberate exception to "everything of Savoia's in Savoia's world".

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
  remembered per profile and origin, shown in `savoia://configuration` ▸ Privacy ▸ Site Permissions and taken back from
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

- **Styling by `:tool-form-active` and `:tool-submit-active`.** `matches()` and `closest()` know them; a style sheet
  does not, because WebKit's CSS parser drops a rule with a pseudo-class it has never heard of, and nothing a page
  script can do brings it back.
- **File inputs** in declarative forms: Chromium keeps them behind a flag pending a privacy review, and so does Savoia —
  there is no flag.
- **Frames on Windows and Linux.** Their bridges inject into the main frame and do not answer the channel, so there the
  polyfill keeps to its own document, as it did before frames were built.
- **`document.domain`.** The draft refuses the API where `document.domain` is enabled; WebKit has no origin-keyed
  agent clusters (`window.originAgentCluster` does not exist), so there `document.domain` is always enabled and the
  rule would refuse everything. Savoia does not apply it.
- **An opened window.** `window.open` hands the page no window in Savoia ([Frames](#frames-what-webkit-allows-measured)),
  so nothing about tools across an opener boundary can be tested, or needs to be.
- **The initial `about:blank` of an iframe with a `src`** gets no polyfill: WebKit does not run user scripts in it,
  and the page reaches it before it navigates. The wpt test for it says Chrome gets it wrong too.
- **Not native.** The IDL is followed as far as `idlharness` checks it, but the events Savoia dispatches are the page's
  own and `isTrusted` is false. The page sees the polyfill and can replace it — with an engine that opposes WebMCP there
  is no other way.
- **Input is not checked against `inputSchema`** before a call.
- **Windows a page opens itself** (Windows, `openPageWindow`) get no channel: WebKit configures them, not
  `WebEngine.makeView`.
- **Linux has no MCP server**, so its page tools are seen only by the self-test and `BrowserModel.pageToolCount`, and
  there is no mark in its bar.
- **The ⌘K assistant gets only some tools**: `readOnlyHint` ones whose schema translates (an object of strings,
  numbers, booleans, enums and arrays of those). The rest stay with ACP agents through `call_page_tool`.
- **Limits of Savoia's own, not in the draft**: at most 100 tools a document, descriptions up to 4,000 characters,
  schemas up to 64 KB.
- **`navigator.modelContext`** stays for Chrome's first-trial sites; when the trial ends (156), see who still calls
  it and remove it.

What not to do: wait for WebKit, or turn Savoia into a bridge for someone else's agent — MCP-B's page → extension →
external client path is not needed when Savoia **is** the MCP server (`Savoia --mcp`), and page tools leave through
`call_page_tool` with the rest of the catalog and its permissions, not around them.

## Declarative forms

`<form toolname tooldescription>` is a tool (`WebMCPForms.swift`, spliced into the polyfill). The draft's section is
still TODO, so the behaviour is Chromium's: the schema and the filling follow `form_mcp_schema.cc` (BSD) line for
line, and the submission follows wpt's `webmcp/declarative`.

- **The schema.** One property per control name, in the order the names first appear among the form's controls;
  disabled and read-only controls are left out. Text-like inputs and `<textarea>` are strings (with `pattern`),
  `number` and `range` numbers (`minimum`, `maximum`, `multipleOf` when the step base is a multiple of the step),
  dates and times strings with a format, a lone checkbox a boolean, a checkbox group an array of its values, a radio
  group and a `<select>` a string with `anyOf` and `enum` (`<select multiple>` an array). A description is
  `toolparamdescription`, else the label's text, else `aria-description`; a group's is its `<fieldset>`'s.
  `required` lists the required names, and is there even when empty.
- **A call** checks every argument before it touches anything — a name the form does not have, a value the control
  would refuse — then fills the fields with the native setters and fires `input` and `change` where a value changed,
  then `toolactivated`. With `toolautosubmit` Savoia submits: the `submit` event carries `agentInvoked`, a handler that
  cancels it answers with `respondWith(promise)`, one that does not lets the form navigate and the call answers
  `null`. Without it Savoia focuses the submit button and waits for the person to press it — which is what makes a form
  without `toolautosubmit` safe to offer. A reset, the form's removal before it was submitted, or the caller's abort
  ends the call.
- **Keeping up.** A `MutationObserver` on the document re-reads the forms when a tool attribute or a control changes,
  and registers, updates or drops the tool; `toolchange` fires only when what an agent would read changed.
  `getTools()` applies pending mutations first, so a page that edits a form and asks at once reads the edit.
- The first form with a name wins; an imperative tool of the same name keeps it. Forms of a document with no window
  (`DOMParser`, `createHTMLDocument`) and of a sandboxed frame without scripts are not tools.
- To an agent a form tool is like any other: not read-only, so every call is confirmed in the bar.

## Compatibility: web-platform-tests

wpt has the suite Chromium moved its own tests into, [`webmcp/`](https://github.com/web-platform-tests/wpt/tree/master/webmcp),
and `scripts/webmcp-wpt.py` runs it in a running dev Savoia over `Savoia --mcp`, on wpt's own `wpt serve` — the stand is
described in [test-suites.md](test-suites.md#the-shared-stand): `savoia.localhost` and its subdomains with no hosts file,
a second and a cross-site origin, the LAN address as the non-secure one, and a CA of its own trusted by the dev build
only.

```sh
./scripts/webmcp-wpt.py --install-ca          # once, with the dev Savoia quit
open -na <Debug Savoia.app> --env SAVOIA_WEBMCP=1
./scripts/webmcp-wpt.py                       # everything, and what moved against the baseline
./scripts/webmcp-wpt.py imperative/getTools   # only paths containing an argument
./scripts/webmcp-wpt.py --write-baseline      # after a change that should move the numbers
```

The baseline is `scripts/webmcp-wpt-baseline.json`. At wpt `a9871a2`: **165 of 174** — imperative 98 of 105,
declarative 41 of 43, `idlharness` 22 of 22, `tool-activated-event` 4 of 4. The nine left are the ones
[Not built](#not-built) explains: an opened window (2), `document.domain` (4), `isTrusted` (1), the initial
`about:blank` of an iframe with a `src` (1), and styling by `:tool-form-active` (1). What the suite taught the polyfill, and it now does: `getTools()` sorted by name and carrying
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
(`www1.savoia.localhost`, one with `allow="tools"`), a `srcdoc`, a static `about:blank` and one created from script:

- **A `forMainFrameOnly: false` user script reaches every one of them** — cross-origin frames included, `srcdoc`, the
  static `about:blank`, and an `about:blank` iframe created by `appendChild`, where it has already run when
  `appendChild` returns. The parent does not have to install anything into a same-origin child itself.
- **The reply handler answers in every frame.** `postMessage` returns a promise there, and each frame got its own
  answer; `message.frameInfo` names the frame's own origin (`about:blank` and `srcdoc` inherit the parent's), which
  is the origin Savoia should trust rather than anything the page says.
- **Running code in one particular frame works**, cross-origin frames too, from the `WKFrameInfo` its message
  carried. A frame that has gone answers `WKErrorDomain` 12, "Target frame could not be found" — the navigated-away
  case, for free. `WebPage.callJavaScript(in:)` takes a `WebPage.FrameInfo`, which only navigation and dialog
  callbacks hand out, so the `WKWebView` is the way in; it exists once a pane has shown the window.
- **WebKit has no `document.featurePolicy` or `permissionsPolicy`.** The `tools` policy has to be Savoia's own
  computation.
- **`window.open` hands the page no window.** Without a gesture WebKit's popup blocking answers `null`; with one Savoia
  opens a new column that is not scripting-connected to its opener (docs/links.md). The two tests that script an
  opened window — `exposedTo-window-open` and `executeTool-across-trees` — cannot pass until that changes, and the
  same gap breaks any site whose sign-in popup answers through `window.opener`. That is a browser matter, not a
  WebMCP one.

### Frames, as built

- The polyfill runs in every frame. Each document has a random token and knows its place in the frame tree — indices
  into `frames` from the top, worked out at document start, before any script of that document has run. Every
  message answers with the frame's `WKFrameInfo` (`WebMCPFrameHandle`), and the origin Savoia uses is the frame's own
  from there, never the page's word.
- The channel is a reply handler, so `getTools` and `executeTool` from any frame are one request to Swift and one
  answer. `WebMCPBroker`, in `SavoiaCore`, keeps every document of a window by token and place: a new document at a
  place replaces whatever was there and everything below it, and `pagehide` says a document is going.
- Who sees what: a document sees every tool of its own origin, in any frame, and every tool whose `exposedTo` names
  its origin; `getTools({fromOrigins})` keeps the first kind always and the second kind only from the origins
  asked for. `toolchange` goes to every other document that could see the tool, once its policy is known to allow it.
- A call into another frame goes to that frame through `callAsyncJavaScript(in:)`, and its answer comes back over the
  channel as a `result`, which the broker hands to the caller's pending reply. The caller's abort rejects at once and
  is passed on to the tool's signal; a caller or a target that goes away ends the call on the other side.
- The `tools` policy: the top document may; a subframe may when its parent may and the parent's container for it
  allows the child's origin — `'self'` (the parent's origin) with no `tools` directive, else what the directive
  lists: nothing for the `src` origin, `*`, `'self'`, `'src'`, `'none'`, origins. The container is read in Savoia's
  own world (`WebMCPBroker.allowQuery`), matched to the child by `contentWindow === frames[i]`, so the page cannot
  answer for it. A frame that may not gets `NotAllowedError` from all three operations.
- A detached frame's `document.defaultView` is `null`, and a tool whose `window` is closed is gone: every operation
  there is `InvalidStateError`.
- A tool's schema and annotations cross to other frames as the page's own JSON text, so a page reads back its keys in
  the order it wrote them, and nothing it did not give.
- **Agents see frames' tools too**, those of every frame the tools policy lets in, after the page's own
  (`WebMCPHost.tools(in:)`, `WebMCPBroker.frameTools`). Each carries its frame's origin: `list_page_tools` shows it,
  the wrench's list names it under the tool, and `call_page_tool` takes `origin` when a frame declares a name the page
  also declares. A call to a frame's tool runs in that frame, and the site question is asked about the frame's origin
  — an embedded frame does not inherit the answer given to the page. The frame going away ends the call.

## What has been checked

- **Mac.** Both schemes build. `SAVOIA_WEBMCP_SELFTEST` against `Tests/WebMCP/webmcp.html`: 22 checks, `PASS`.
  `WebMCPTests` pass with the rest of `SavoiaCore`'s tests. wpt as above.
- **Windows, real WebKit.** The same self-test, 22 checks, `PASS`; the badge seen in a `PrintWindow` capture. `file:`
  is a secure context in that WebKit, and `WKPageCallAsyncJavaScript` runs in the page's world.
- The self-test covers: a declaration with annotations and schema, `add(2,3)` → `5`,
  `document.modelContext === navigator.modelContext`, `getTools()` inside the page, the site asked about at the first
  call and not again, a changing call confirmed, a no stopping the call **before** the page runs it, a timeout through
  `AbortSignal`, unregistering through `abort()`, a new document with its own tools, the site's answer outliving a
  navigation, a navigation mid-call, an empty registry on `about:blank`. It forgets its own site answer first, so it
  can be run back to back.

- **Live pages** (2026-09-27, dev build): all fourteen of Chrome Labs' demos
  (`googlechromelabs.github.io/webmcp-tools/demos/`) declare their tools in Savoia — 41 between them, imperative and
  declarative, React, Angular and plain pages — and `list_page_tools` lists what the page's own `getTools()` returns.
  Called from inside the page: the pizza maker's `set_pizza_size` answered, the doors' and order tracking's forms
  submitted and answered `null`, and an argument outside a form's `enum` was refused before anything was filled.
- **`@mcp-b/global` 5.1.0** on a stand page: it takes Savoia's `document.modelContext` for a native one and wraps it, as
  its README says, and a tool registered through the wrapper reaches Savoia and is listed to agents.

### Not checked

- **Linux has never been built.** Its first container build has to answer whether `WebKitUserContentManager` and
  `JSCValue` import as `OpaquePointer`, whether `webkit_user_content_manager_register_script_message_handler` takes
  the world as its third argument, whether `script-message-received` is (`manager`, `JSCValue*`, `gpointer`), and
  whether `webkit_web_view_get_user_content_manager` gives each view its own manager.
- **The ⌘K schema translation (`WebMCPModelTool`)** has not been exercised with a model.

### How to check it

**Mac:**

1. `savoia://configuration` ▸ Develop ▸ WebMCP on;
2. open `file:///…/Tests/WebMCP/webmcp.html`: a wrench in the address field, its tooltip saying 4, a click listing
   them with the read-only and consequential marks;
3. `Savoia --mcp` → `list_page_tools`, then `call_page_tool` with `name: add`, `arguments: {"a":2,"b":3}` — the bar asks
   about the site, and `5` comes back after the answer;
4. `call_page_tool` with `name: forget_slow` — a bar with the tool's name and arguments, on every call;
5. ⌘K: ask for something that needs `add` — the assistant has it as its own tool and does not have `slow`, which is
   not read-only;
6. the same in a private window: no tools at all;
7. `SAVOIA_WEBMCP_SELFTEST=file:///…/webmcp.html` on launching the dev build — the report goes to
   `~/Library/Logs/org.deffun.savoia.dev/savoia.log`.

**Windows:**

```powershell
./scripts/savoia-windows.ps1 build      # stops every running savoia-windows, other sessions' included
$env:SAVOIA_WEBMCP_SELFTEST = "file:///C:/Users/Artem/sources/Savoia/Tests/WebMCP/webmcp.html"
.\windows\.build\x86_64-unknown-windows-msvc\debug\savoia-windows.exe
```

The report is in `%LOCALAPPDATA%\savoia\Logs\savoia.log`, the line `webmcp self-test`, ending in `PASS`. By hand:
`SAVOIA_WEBMCP=1` instead, and the same page shows a 4 in the address bar.

**Linux** (in the container, [linux.md](linux.md)):

```sh
./scripts/savoia-linux.sh build
SAVOIA_WEBMCP_SELFTEST=file:///work/Tests/WebMCP/webmcp.html ./scripts/savoia-linux.sh up
```

**wpt**: `./scripts/webmcp-wpt.py`, above.

**Unit tests**: `swift test --disable-automatic-resolution`. `WebMCPTests` covers message parsing, the registry,
calls, the gate and what the agent reads.

Sources: [the draft](https://webmachinelearning.github.io/webmcp/),
[repository and explainer](https://github.com/webmachinelearning/webmcp),
[WebKit's position](https://github.com/WebKit/standards-positions/issues/670),
[state of WebMCP, July 2026](https://www.spronta.com/blog/state-of-webmcp-july-2026/).
