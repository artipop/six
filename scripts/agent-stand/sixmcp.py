"""Minimal MCP stdio client for `six --mcp`."""
import json, subprocess, sys, glob, os, time

APP = sorted(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/six-*/Build/Products/Debug/six.app")), key=os.path.getmtime)[-1]

class Six:
    def __init__(self):
        self.p = subprocess.Popen([APP + "/Contents/MacOS/six", "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.n = 0
        self.info = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe", "version": "0"}})
        self.notify("notifications/initialized")
    def notify(self, method, params=None):
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method, **({"params": params} if params else {})}) + "\n")
    def rpc(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        while True:
            line = self.p.stdout.readline()
            if not line: raise RuntimeError("six --mcp closed")
            m = json.loads(line)
            if m.get("id") == self.n:
                if "error" in m: raise RuntimeError(m["error"])
                return m["result"]
    def call(self, name, **args):
        t = time.perf_counter()
        r = self.rpc("tools/call", {"name": name, "arguments": args})
        text = "\n".join(c.get("text", "") for c in r.get("content", []))
        ms = (time.perf_counter() - t) * 1000
        if r.get("isError"): raise RuntimeError(f"{name}: {text}")
        return text, ms

if __name__ == "__main__":
    s = Six()
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        name, _, rest = line.partition(" ")
        args = json.loads(rest) if rest else {}
        try:
            text, ms = s.call(name, **args)
            print(f"### {name} {json.dumps(args, ensure_ascii=False)}  ({ms:.0f} ms)\n{text}\n", flush=True)
        except Exception as e:
            print(f"### {name} FAILED: {e}\n", flush=True)
