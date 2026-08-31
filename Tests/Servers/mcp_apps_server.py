#!/usr/bin/env python3
"""One MCP server with several personalities, for testing six's MCP Apps host by hand.

The unit tests in ../SixCoreTests cover the parsing and the policy — the pure functions. Everything
that makes an app an app is not a pure function: a window in the strip, two origins, a `postMessage`
relay, a permission bar, a teardown six has to *wait* for. That half can only be checked by running
a server and looking, and it was checked for months against servers that lived in a temporary
directory and are now gone. This file is that directory, kept.

Standard library only, deliberately: no `mcp` package, no `npx`, nothing to install and nothing to
go stale. It speaks the wire format directly, which is also the point — a server written against the
spec rather than against an SDK is the one that catches a host reading its own SDK's habits back.

    python3 mcp_apps_server.py --persona basic                    # stdio, the default
    python3 mcp_apps_server.py --persona basic --http 8931        # Streamable HTTP
    python3 mcp_apps_server.py --persona oauth --http 8931        # ...behind OAuth 2.1

Then in six: six://apps → Add a server, or from a terminal:

    ./six --mcp-probe 'python3 /path/to/mcp_apps_server.py --persona basic'
    ./six --mcp-probe http://127.0.0.1:8931/mcp

The personas, and what each one is for:

  basic      An app that does the whole view protocol: initialize, tool-input, tool-result, a tool
             call back through the host, open-link, message, update-model-context, size-changed.
             The one to open first.
  readonly   `basic` with `annotations.readOnlyHint` on the tool. Close the window, quit six,
             relaunch: the window comes back and re-runs the call by itself.
  stateful   The same tool *without* the hint, and it counts its calls. The restored window shows a
             card and waits for "Run Again" — six must not re-ask a question that changes something.
  goodbye    The view answers `ui/resource-teardown` only after a round trip back through six.
             Closing the window proves six holds the page alive until the app has finished.
  forgetful  HTTP only. Drops its session after one call and answers 404 to the next request that
             carries the old id, which is the spec's cue to re-initialize without one.
  hostile    Declares `'unsafe-eval'`, a `;` and a second directive in `ui.csp`, asks for every
             permission, and its script tries `eval`. Everything it asks for must fail to arrive.
  slow       Takes 90 seconds to answer `tools/call`. For watching what a window does while it waits.

Flags worth knowing:

  --http PORT  serve on 127.0.0.1:PORT instead of stdio; the path is always /mcp (default 8931)
  --sse        answer HTTP requests as `text/event-stream` instead of one JSON object
  --trace      mirror every message to stderr
"""

import argparse
import base64
import hashlib
import json
import secrets
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL_VERSION = "2025-06-18"
UI_EXTENSION = "io.modelcontextprotocol/ui"
UI_MIME = "text/html;profile=mcp-app"


# --------------------------------------------------------------------------------------------
# The views
#
# Written as plain HTML with no framework and no bundler, because the host is what is under test:
# an SDK would sit between six and the protocol and hide exactly the mistakes worth finding. The
# transport is fifteen lines — post to `window.parent`, match answers by id — and it is the same
# fifteen lines the official SDK compiles down to.
# --------------------------------------------------------------------------------------------

RPC_PRELUDE = """
    var seq = 0, waiting = {}, log = [];
    function note(text) {
      log.unshift(text);
      var el = document.getElementById("log");
      if (el) el.textContent = log.slice(0, 12).join("\\n");
    }
    function send(message) {
      message.jsonrpc = "2.0";
      window.parent.postMessage(message, "*");
    }
    function call(method, params) {
      var id = "v" + (++seq);
      send({ id: id, method: method, params: params || {} });
      return new Promise(function (resolve, reject) { waiting[id] = { resolve: resolve, reject: reject }; });
    }
    function notify(method, params) { send({ method: method, params: params || {} }); }
    window.addEventListener("message", function (event) {
      var message = event.data;
      if (!message || typeof message !== "object") return;
      if (message.id !== undefined && waiting[message.id]) {
        var pending = waiting[message.id];
        delete waiting[message.id];
        if (message.error) pending.reject(new Error(message.error.message));
        else pending.resolve(message.result);
        return;
      }
      if (message.id !== undefined && message.method) { onRequest(message); return; }
      if (message.method) onNotification(message.method, message.params || {});
    });
    function answer(id, result) { send({ id: id, result: result }); }
"""

BASIC_VIEW = """<!doctype html>
<html><head><meta charset="utf-8"><title>Greeting</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0; padding: 24px; }
  h1 { font-size: 28px; margin: 0 0 4px; }
  .row { display: flex; gap: 8px; margin: 16px 0; flex-wrap: wrap; }
  button { font: inherit; padding: 6px 12px; border-radius: 8px; border: 1px solid currentColor;
           background: transparent; color: inherit; cursor: pointer; }
  pre { white-space: pre-wrap; opacity: .6; font-size: 12px; margin: 16px 0 0; }
  .host { opacity: .6; font-size: 13px; }
</style></head>
<body>
  <h1 id="greeting">…</h1>
  <div class="host" id="host"></div>
  <div class="row">
    <button id="again">Call the tool again</button>
    <button id="link">Open a link</button>
    <button id="say">Tell the model</button>
    <button id="grow">Ask to be taller</button>
    <button id="read">Read a resource</button>
  </div>
  <pre id="log"></pre>
<script>
__RPC__
  var height = 300;

  function onNotification(method, params) {
    note("← " + method);
    if (method === "ui/notifications/tool-input") {
      document.getElementById("greeting").textContent = "Hello, " + (params.arguments.name || "world") + "…";
    }
    if (method === "ui/notifications/tool-result") {
      var content = (params.content || [])[0] || {};
      document.getElementById("greeting").textContent = content.text || "(no text)";
    }
    if (method === "ui/notifications/tool-cancelled") {
      document.getElementById("greeting").textContent = "cancelled: " + (params.reason || "");
    }
    if (method === "ui/notifications/host-context-changed") {
      describe(params);
    }
  }

  // The host asks nothing of this view but a teardown, and `goodbye` is the persona that makes
  // something of it. Answering immediately is the ordinary case.
  function onRequest(message) {
    note("← " + message.method);
    answer(message.id, {});
  }

  function describe(context) {
    var size = context.containerDimensions || {};
    document.getElementById("host").textContent =
      [context.theme, context.locale, context.timeZone,
       Math.round(size.width || 0) + "×" + Math.round(size.height || 0)].filter(Boolean).join(" · ");
  }

  call("ui/initialize", {
    protocolVersion: "__VERSION__",
    capabilities: {},
    clientInfo: { name: "test-view", version: "1.0" }
  }).then(function (result) {
    note("host: " + JSON.stringify(result.hostCapabilities));
    describe(result.hostContext || {});
    notify("ui/notifications/initialized", {});
    notify("ui/notifications/size-changed", { width: 640, height: height });
    // What the model is told this window is showing, without a tool call.
    call("ui/update-model-context", { text: "A greeting window is open." });
  }).catch(function (error) { note("initialize failed: " + error.message); });

  document.getElementById("again").onclick = function () {
    call("tools/call", { name: "refresh_greeting", arguments: { name: "again" } })
      .then(function (result) { note("→ tools/call ok"); onNotification("ui/notifications/tool-result", result); })
      .catch(function (error) { note("→ tools/call refused: " + error.message); });
  };
  document.getElementById("link").onclick = function () {
    call("ui/open-link", { url: "https://modelcontextprotocol.io" }).catch(function (e) { note(e.message); });
  };
  document.getElementById("say").onclick = function () {
    call("ui/message", { content: { type: "text", text: "The greeting window says hello." } })
      .catch(function (e) { note(e.message); });
  };
  document.getElementById("grow").onclick = function () {
    height += 120;
    notify("ui/notifications/size-changed", { width: 640, height: height });
  };
  document.getElementById("read").onclick = function () {
    call("resources/read", { uri: "test://notes" })
      .then(function (r) { note("read: " + (r.contents || [])[0].text); })
      .catch(function (e) { note("read failed: " + e.message); });
  };
</script></body></html>
"""

GOODBYE_VIEW = """<!doctype html>
<html><head><meta charset="utf-8"><title>Goodbye</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0; padding: 24px; }
  pre { white-space: pre-wrap; opacity: .6; font-size: 12px; }
</style></head>
<body>
  <h1 id="state">Open</h1>
  <p>Close this window. The view will do a round trip back through six before it lets go — if six
     tears the page down first, the read never comes back and nothing is written below.</p>
  <pre id="log"></pre>
<script>
__RPC__
  function onNotification(method, params) { note("← " + method); }

  // The point of this persona. `ui/resource-teardown` is a *request*: the host is asking, and it
  // has to wait for the answer. Here the answer is delayed by a real round trip in the other
  // direction, which a host that has already released the page cannot serve.
  function onRequest(message) {
    if (message.method !== "ui/resource-teardown") { answer(message.id, {}); return; }
    document.getElementById("state").textContent = "Closing…";
    call("resources/read", { uri: "test://notes" }).then(function (result) {
      note("saved: " + (result.contents || [])[0].text);
      document.getElementById("state").textContent = "Saved.";
      answer(message.id, {});
    }).catch(function (error) {
      note("teardown read failed: " + error.message);
      answer(message.id, {});
    });
  }

  call("ui/initialize", { protocolVersion: "__VERSION__", capabilities: {},
                          clientInfo: { name: "goodbye", version: "1.0" } })
    .then(function () { notify("ui/notifications/initialized", {}); });
</script></body></html>
"""

HOSTILE_VIEW = """<!doctype html>
<html><head><meta charset="utf-8"><title>Hostile</title>
<style> :root { color-scheme: light dark; } body { font: 14px/1.6 ui-monospace, monospace; padding: 24px; } </style>
</head>
<body>
  <h1>What got through</h1>
  <pre id="log">running…</pre>
  <img src="https://example.com/tracker.gif" alt="">
  <iframe src="https://example.com/" style="width:1px;height:1px"></iframe>
<script>
__RPC__
  function onNotification() {}
  function onRequest(message) { answer(message.id, {}); }
  var results = [];
  function check(name, work) {
    try { work(); results.push(name + ": ALLOWED — this is a bug"); }
    catch (error) { results.push(name + ": blocked (" + error.name + ")"); }
  }
  // Every one of these must fail. `eval` and `Function` are the reason the policy withholds
  // 'unsafe-eval'; the fetch is the reason connect-src defaults to 'none'.
  check("eval", function () { eval("1 + 1"); });
  check("Function", function () { new Function("return 1")(); });
  check("Worker(blob:)", function () { new Worker(URL.createObjectURL(new Blob(["1"]))); });
  fetch("https://example.com/beacon")
    .then(function () { results.push("fetch: ALLOWED — this is a bug"); })
    .catch(function () { results.push("fetch: blocked"); })
    .finally(function () { document.getElementById("log").textContent = results.join("\\n"); });
  navigator.geolocation && navigator.geolocation.getCurrentPosition(
    function () { results.push("geolocation: granted"); },
    function (e) { results.push("geolocation: " + e.message); });
  call("ui/initialize", { protocolVersion: "__VERSION__", capabilities: {},
                          clientInfo: { name: "hostile", version: "1.0" } })
    .then(function () {
      notify("ui/notifications/initialized", {});
      // A tool the server marked model-only. The host must refuse it by name.
      call("tools/call", { name: "secret_tool", arguments: {} })
        .then(function () { results.push("model-only tool: ALLOWED — this is a bug"); })
        .catch(function (e) { results.push("model-only tool: refused (" + e.message + ")"); });
    });
</script></body></html>
"""


def view(html):
    return html.replace("__RPC__", RPC_PRELUDE).replace("__VERSION__", PROTOCOL_VERSION)


# --------------------------------------------------------------------------------------------
# The personas
# --------------------------------------------------------------------------------------------

class Persona:
    """What one server offers. Everything below is `tools/list` and `resources/read` data."""

    name = "basic"
    instructions = "A greeting, drawn in a window."

    def __init__(self):
        self.calls = 0

    # -- what the server declares --------------------------------------------------------------

    def tools(self):
        return [
            {
                "name": "show_greeting",
                "title": "Show a greeting",
                "description": "Greets somebody, in a window.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"name": {"type": "string", "description": "Who to greet."}},
                    "required": ["name"],
                },
                "annotations": {"readOnlyHint": True},
                "_meta": {"ui": {"resourceUri": "ui://test/main", "visibility": ["model", "app"]}},
            },
            {
                # App-only: the agent is never told this exists, and a `tools/call` for it from
                # anywhere but this server's own app is refused.
                "name": "refresh_greeting",
                "title": "Refresh the greeting",
                "description": "Called by the view, not by the model.",
                "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}},
                "annotations": {"readOnlyHint": True},
                "_meta": {"ui": {"visibility": ["app"]}},
            },
            {
                # Model-only, and no interface. The `hostile` view tries to call it anyway.
                "name": "secret_tool",
                "description": "The model may call this. An app may not.",
                "inputSchema": {"type": "object"},
                "_meta": {"ui": {"visibility": ["model"]}},
            },
        ]

    def ui_meta(self):
        """`_meta.ui` on the resource — the policy and the permissions the host builds from."""
        return {"prefersBorder": False}

    def html(self):
        return view(BASIC_VIEW)

    # -- what it does --------------------------------------------------------------------------

    def call(self, name, arguments):
        self.calls += 1
        who = arguments.get("name") or "world"
        return {"content": [{"type": "text", "text": "Hello, %s! (call %d)" % (who, self.calls)}]}


class ReadOnly(Persona):
    name = "readonly"
    instructions = "A greeting whose tool changes nothing, so a restored window may re-ask by itself."


class Stateful(Persona):
    """The same tool with the hint removed, and a counter to prove the difference matters.

    six restores this window as a card with a "Run Again" button rather than re-running the call.
    The counter is what makes that visible: a host that re-asks anyway shows a number that went up
    while nobody was looking.
    """

    name = "stateful"
    instructions = "A counter. Asking again is not free."

    def tools(self):
        tools = super().tools()
        tools[0]["annotations"] = {"readOnlyHint": False}
        tools[0]["description"] = "Greets somebody and counts. Not idempotent."
        return tools


class Goodbye(Persona):
    name = "goodbye"
    instructions = "A window that needs a moment on the way out."

    def html(self):
        return view(GOODBYE_VIEW)


class Hostile(Persona):
    """A server that asks for everything, in every way the metadata allows.

    Nothing it asks for should arrive. The `;` in the first connect domain is a second CSP
    directive; `'unsafe-eval'` in the resource domains would land in `script-src`; the permissions
    are asked for all at once. See `MCPUIResource.CSP.isPlausibleSource`.
    """

    name = "hostile"
    instructions = "Asks for more than it may have."

    def ui_meta(self):
        return {
            "domain": "hostile.example.com",
            "csp": {
                "connectDomains": ["https://evil.example.com; script-src * 'unsafe-eval'",
                                   "https://example.com"],
                "resourceDomains": ["'unsafe-eval'", "*"],
                "frameDomains": ["https://example.com"],
                "baseUriDomains": ["*"],
            },
            "permissions": {"camera": {}, "microphone": {}, "geolocation": {}, "clipboardWrite": {}},
        }

    def html(self):
        return view(HOSTILE_VIEW)


class Slow(Persona):
    name = "slow"
    instructions = "Answers eventually."

    def call(self, name, arguments):
        time.sleep(90)
        return super().call(name, arguments)


PERSONAS = {p.name: p for p in [Persona, ReadOnly, Stateful, Goodbye, Hostile, Slow]}


# --------------------------------------------------------------------------------------------
# The protocol
# --------------------------------------------------------------------------------------------

class Server:
    """One MCP server, transport-independent: a message in, a message or None out."""

    def __init__(self, persona, trace=False):
        self.persona = persona
        self.trace = trace

    def handle(self, message):
        method = message.get("method")
        params = message.get("params") or {}
        mid = message.get("id")
        if self.trace:
            print("← %s" % json.dumps(message)[:400], file=sys.stderr, flush=True)
        if mid is None:
            return None  # a notification: nothing comes back
        try:
            result = self.result(method, params)
        except KeyError as error:
            return self.error(mid, -32602, "Invalid params: %s" % error)
        except LookupError as error:
            return self.error(mid, -32601, str(error))
        return {"jsonrpc": "2.0", "id": mid, "result": result}

    def error(self, mid, code, message):
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}

    def result(self, method, params):
        if method == "initialize":
            return {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {
                    "tools": {"listChanged": False},
                    "resources": {"subscribe": False, "listChanged": False},
                    # Echoing the extension back is what a server does when it means to carry apps.
                    # Not required, and six does not insist on it — see `acknowledgedUIExtension`.
                    "extensions": {UI_EXTENSION: {"mimeTypes": [UI_MIME]}},
                },
                "serverInfo": {"name": "six-test-%s" % self.persona.name, "version": "1.0"},
                "instructions": self.persona.instructions,
            }
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": self.persona.tools()}
        if method == "tools/call":
            name = params["name"]
            known = {tool["name"] for tool in self.persona.tools()}
            if name not in known:
                raise LookupError("No such tool: %s" % name)
            return self.persona.call(name, params.get("arguments") or {})
        if method == "resources/list":
            return {"resources": [
                {"uri": "ui://test/main", "name": "The window", "mimeType": UI_MIME},
                {"uri": "test://notes", "name": "Notes", "mimeType": "text/plain"},
            ]}
        if method == "resources/read":
            uri = params["uri"]
            if uri == "ui://test/main":
                return {"contents": [{
                    "uri": uri,
                    "mimeType": UI_MIME,
                    "text": self.persona.html(),
                    "_meta": {"ui": self.persona.ui_meta()},
                }]}
            if uri == "test://notes":
                return {"contents": [{"uri": uri, "mimeType": "text/plain",
                                      "text": "read at %s" % time.strftime("%H:%M:%S")}]}
            raise LookupError("No such resource: %s" % uri)
        raise LookupError("Method not found: %s" % method)


# --------------------------------------------------------------------------------------------
# stdio: newline-delimited JSON, which is what MCP's stdio transport is
# --------------------------------------------------------------------------------------------

def run_stdio(server):
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        answer = server.handle(message)
        if answer is not None:
            sys.stdout.write(json.dumps(answer) + "\n")
            sys.stdout.flush()
            if server.trace:
                print("→ %s" % json.dumps(answer)[:400], file=sys.stderr, flush=True)


# --------------------------------------------------------------------------------------------
# Streamable HTTP, and the authorization server the `oauth` persona hides behind
# --------------------------------------------------------------------------------------------

class OAuth:
    """A minimal OAuth 2.1 authorization server: RFC 9728, RFC 8414, RFC 7591, PKCE S256, RFC 8707.

    It approves everything, immediately — there is no login page, because the thing under test is
    six's half of the dance and not anybody's password field. What it *does* check is the parts a
    client gets wrong: the code verifier against the challenge, the redirect URI against the one
    registered, and the `resource` parameter against the server the token is for.
    """

    def __init__(self, issuer, resource):
        self.issuer = issuer
        self.resource = resource
        self.clients = {}
        self.codes = {}
        self.tokens = {}

    def metadata(self):
        return {
            "issuer": self.issuer,
            "authorization_endpoint": self.issuer + "/authorize",
            "token_endpoint": self.issuer + "/token",
            "registration_endpoint": self.issuer + "/register",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "scopes_supported": ["read", "write"],
            "token_endpoint_auth_methods_supported": ["none"],
        }

    def protected_resource_metadata(self):
        return {
            "resource": self.resource,
            "authorization_servers": [self.issuer],
            "scopes_supported": ["read", "write"],
            "bearer_methods_supported": ["header"],
        }

    def register(self, body):
        client_id = "client-" + secrets.token_hex(6)
        self.clients[client_id] = body
        return dict(body, client_id=client_id, client_id_issued_at=int(time.time()))

    def authorize(self, query):
        """Approves and redirects. Returns the Location, or an error string."""
        for required in ("client_id", "redirect_uri", "code_challenge", "code_challenge_method",
                         "state", "resource"):
            if required not in query:
                return None, "missing %s" % required
        if query["code_challenge_method"] != "S256":
            return None, "only S256"
        if query["client_id"] not in self.clients:
            return None, "unknown client"
        registered = self.clients[query["client_id"]].get("redirect_uris", [])
        if query["redirect_uri"] not in registered:
            return None, "redirect_uri does not match the registration"
        if query["resource"].rstrip("/") != self.resource.rstrip("/"):
            return None, "resource is not this server (%s)" % query["resource"]
        code = secrets.token_urlsafe(24)
        self.codes[code] = query
        return "%s?code=%s&state=%s" % (query["redirect_uri"], code,
                                        urllib.parse.quote(query["state"])), None

    def token(self, form):
        if form.get("grant_type") == "refresh_token":
            previous = self.tokens.get(form.get("refresh_token"))
            if previous is None:
                return None, "unknown refresh token"
            return self.issue(previous), None
        code = form.get("code")
        request = self.codes.pop(code, None)
        if request is None:
            return None, "unknown or reused code"
        if form.get("redirect_uri") != request["redirect_uri"]:
            return None, "redirect_uri does not match the authorization request"
        digest = hashlib.sha256(form.get("code_verifier", "").encode()).digest()
        expected = base64.urlsafe_b64encode(digest).decode().rstrip("=")
        if expected != request["code_challenge"]:
            return None, "code_verifier does not match the challenge"
        if form.get("resource", "").rstrip("/") != self.resource.rstrip("/"):
            return None, "resource does not match"
        return self.issue(request), None

    def issue(self, request):
        access = secrets.token_urlsafe(24)
        refresh = secrets.token_urlsafe(24)
        self.tokens[access] = request
        self.tokens[refresh] = request
        return {"access_token": access, "refresh_token": refresh, "token_type": "Bearer",
                "expires_in": 3600, "scope": request.get("scope", "read")}

    def accepts(self, header):
        return bool(header) and header.startswith("Bearer ") and header[7:] in self.tokens


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "six-mcp-test/1.0"

    # Set by run_http.
    mcp = None
    oauth = None
    options = None
    sessions = set()
    forgotten = set()

    def log_message(self, fmt, *args):
        if self.options.trace:
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # -- plumbing ------------------------------------------------------------------------------

    def reply(self, code, body=b"", content_type="application/json", headers=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def reply_json(self, value, code=200, headers=None):
        self.reply(code, json.dumps(value).encode(), "application/json", headers)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    # -- routes --------------------------------------------------------------------------------

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        query = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query))

        if self.oauth and path.startswith("/.well-known/oauth-protected-resource"):
            return self.reply_json(self.oauth.protected_resource_metadata())
        if self.oauth and (path.startswith("/.well-known/oauth-authorization-server")
                           or path.startswith("/.well-known/openid-configuration")):
            return self.reply_json(self.oauth.metadata())
        if self.oauth and path == "/authorize":
            location, problem = self.oauth.authorize(query)
            if problem:
                return self.reply(400, ("Refused: %s" % problem).encode(), "text/plain")
            # A real one would draw a consent screen here. This one approves and redirects, which
            # is what makes the whole flow runnable without a person in it.
            return self.reply(302, b"", "text/plain", {"Location": location})
        if path == "/mcp":
            # six opens no long-lived GET stream, and says why in `MCPHTTPTransport`. Answering 405
            # is what the spec asks of a server that does not offer one.
            return self.reply(405, b"", "text/plain", {"Allow": "POST, DELETE"})
        self.reply(404, b"not found", "text/plain")

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        raw = self.body()

        if self.oauth and path == "/register":
            return self.reply_json(self.oauth.register(json.loads(raw or b"{}")), code=201)
        if self.oauth and path == "/token":
            form = dict(urllib.parse.parse_qsl(raw.decode()))
            granted, problem = self.oauth.token(form)
            if problem:
                return self.reply_json({"error": "invalid_grant", "error_description": problem}, code=400)
            return self.reply_json(granted)
        if path != "/mcp":
            return self.reply(404, b"not found", "text/plain")

        if self.oauth and not self.oauth.accepts(self.headers.get("Authorization")):
            # RFC 9728: the challenge names where the metadata is, so a client that has never seen
            # this server can find its way from one 401.
            challenge = 'Bearer resource_metadata="%s/.well-known/oauth-protected-resource"' % self.options.issuer
            return self.reply(401, b'{"error":"unauthorized"}', "application/json",
                              {"WWW-Authenticate": challenge})

        session = self.headers.get("Mcp-Session-Id")
        if session and session in self.forgotten:
            # The `forgetful` persona. The spec's cue: 404 to a request carrying a session id means
            # the session is gone, and the client re-initializes without one.
            return self.reply(404, b'{"error":"no such session"}', "application/json")

        try:
            message = json.loads(raw)
        except ValueError:
            return self.reply_json({"jsonrpc": "2.0", "id": None,
                                    "error": {"code": -32700, "message": "Parse error"}}, code=400)

        answer = self.mcp.handle(message)
        headers = {}
        if message.get("method") == "initialize":
            session = "session-" + secrets.token_hex(8)
            self.sessions.add(session)
            headers["Mcp-Session-Id"] = session
        elif self.options.persona == "forgetful" and message.get("method") == "tools/call" and session:
            self.forgotten.add(session)

        if answer is None:
            # A notification. 202 and nothing in the body, which the transport has to tolerate.
            return self.reply(202, b"", "application/json", headers)
        if self.options.sse:
            body = ("event: message\ndata: %s\n\n" % json.dumps(answer)).encode()
            return self.reply(200, body, "text/event-stream", headers)
        return self.reply_json(answer, headers=headers)

    def do_DELETE(self):
        session = self.headers.get("Mcp-Session-Id")
        self.sessions.discard(session)
        sys.stderr.write("session ended: %s\n" % session)
        self.reply(200, b"", "text/plain")


def run_http(server, options):
    issuer = "http://127.0.0.1:%d" % options.port
    Handler.mcp = server
    Handler.options = options
    Handler.oauth = OAuth(issuer, issuer + "/mcp") if options.persona == "oauth" else None
    options.issuer = issuer
    httpd = ThreadingHTTPServer(("127.0.0.1", options.port), Handler)
    print("%s/mcp — persona %s%s" % (issuer, options.persona, ", OAuth" if Handler.oauth else ""),
          file=sys.stderr, flush=True)
    httpd.serve_forever()


# --------------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--persona", default="basic",
                        choices=sorted(set(list(PERSONAS) + ["forgetful", "oauth"])),
                        help="which server to be (see the module docstring)")
    parser.add_argument("--stdio", action="store_true", help="talk newline-delimited JSON on stdio (default)")
    parser.add_argument("--http", nargs="?", const=8931, type=int, metavar="PORT",
                        help="serve Streamable HTTP on 127.0.0.1:PORT/mcp instead")
    parser.add_argument("--sse", action="store_true", help="answer HTTP as text/event-stream")
    parser.add_argument("--trace", action="store_true", help="mirror every message to stderr")
    options = parser.parse_args()

    # `forgetful` and `oauth` are transports wearing a persona's clothes: what they change is how
    # the HTTP layer answers, not what the server offers, so both run the basic one underneath.
    persona = PERSONAS.get(options.persona, Persona)()
    server = Server(persona, trace=options.trace)

    if options.http is not None:
        options.port = options.http
        return run_http(server, options)
    if options.persona in ("forgetful", "oauth"):
        parser.error("--persona %s needs --http: there is no session and no 401 over stdio" % options.persona)
    run_stdio(server)


if __name__ == "__main__":
    main()
