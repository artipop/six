"""An ACP agent with no model in it, for SAVOIA_UPLOAD_SELFTEST: it uploads the files it is told to
through the `Savoia --mcp` it was handed, asking permission first or not.

The prompt is a mode on the first line — `card` asks `session/request_permission` before every
upload, `nocard` asks nothing — and one absolute path per line after it."""
import json, re, subprocess, sys, threading

out_lock = threading.Lock()
waiting = {}
next_id = [0]
servers = []

def send(message):
    with out_lock:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()

def request(method, params):
    next_id[0] += 1
    slot = {"event": threading.Event()}
    waiting[next_id[0]] = slot
    send({"jsonrpc": "2.0", "id": next_id[0], "method": method, "params": params})
    slot["event"].wait()
    return slot.get("result") or {}

def say(session, text):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": session,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text + "\n"}}}})

class Browser:
    def __init__(self, server):
        self.p = subprocess.Popen([server["command"]] + server.get("args", []),
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "consent-stand", "version": "0"}})

    def rpc(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        while True:
            line = self.p.stdout.readline()
            if not line:
                return {"isError": True, "content": [{"text": "Savoia --mcp closed"}]}
            message = json.loads(line)
            if message.get("id") == self.n:
                return message.get("result") or {"isError": True, "content": [{"text": json.dumps(message.get("error"))}]}

    def call(self, name, **arguments):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments})
        text = "\n".join(part.get("text", "") for part in result.get("content", []))
        return not result.get("isError"), text

def turn(request_id, params):
    session = params["sessionId"]
    lines = [line.strip() for block in params["prompt"] for line in block.get("text", "").splitlines() if line.strip()]
    mode, paths = lines[0], lines[1:]
    browser = Browser(servers[0])
    for number, path in enumerate(paths):
        _, snapshot = browser.call("page_snapshot")
        found = re.search(r"\[([^\]]+)\][^\n]*type=file", snapshot)
        if not found:
            say(session, f"{path}: no file input in the snapshot")
            continue
        arguments = {"path": path, "ref": found.group(1)}
        if mode == "card":
            answer = request("session/request_permission", {
                "sessionId": session,
                "toolCall": {"toolCallId": f"upload-{number}", "title": "mcp__savoia__upload_file", "rawInput": arguments},
                "options": [{"optionId": "always", "name": "Always Allow", "kind": "allow_always"},
                            {"optionId": "once", "name": "Allow", "kind": "allow_once"},
                            {"optionId": "reject", "name": "Reject", "kind": "reject_once"}]})
            chosen = answer.get("outcome", {}).get("optionId")
            if chosen not in ("always", "once"):
                say(session, f"{path}: the card said {chosen}")
                continue
        ok, text = browser.call("upload_file", **arguments)
        say(session, f"{path}: {'uploaded' if ok else text.splitlines()[0]}")
    browser.p.stdin.close()
    send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": "end_turn"}})

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method is None:
        slot = waiting.pop(message.get("id"), None)
        if slot:
            slot["result"] = message.get("result")
            slot["event"].set()
    elif method == "initialize":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {
            "protocolVersion": 1, "agentCapabilities": {}, "agentInfo": {"name": "consent-stand", "version": "0"}}})
    elif method == "session/new":
        servers[:] = message["params"].get("mcpServers", [])
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"sessionId": "consent-stand"}})
    elif method == "session/prompt":
        threading.Thread(target=turn, args=(message["id"], message["params"]), daemon=True).start()
    elif "id" in message:
        send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": method}})
