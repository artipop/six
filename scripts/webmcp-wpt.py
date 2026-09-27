#!/usr/bin/env python3
"""Runs web-platform-tests' webmcp/ suite in a running dev six, through `six --mcp`.

    open -na <Debug six.app> --env SIX_WEBMCP=1      # or Develop ▸ WebMCP on
    ./scripts/webmcp-wpt.py                          # the whole suite
    ./scripts/webmcp-wpt.py imperative/getTools      # files whose path contains any argument

The suite is fetched once (a sparse clone of wpt's webmcp/, resources/ and common/) into
~/Library/Caches/six-wpt and served from 127.0.0.1, which is a secure context. What that server
cannot give is written down in docs/webmcp.md: a second origin, `.sub.` substitution and a
non-secure page, so the cross-origin, document.domain and non-secure tests fail here whatever
six does.
"""

import argparse
import functools
import glob
import http.server
import json
import os
import re
import subprocess
import sys
import threading
import time

CACHE = os.path.expanduser("~/Library/Caches/six-wpt")
WPT = "https://github.com/web-platform-tests/wpt.git"


def fetch(update):
    if not os.path.isdir(os.path.join(CACHE, ".git")):
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", WPT, CACHE], check=True)
        subprocess.run(["git", "-C", CACHE, "sparse-checkout", "set", "webmcp", "resources", "common"], check=True)
    elif update:
        subprocess.run(["git", "-C", CACHE, "pull", "-q", "--depth", "1"], check=True)
    return subprocess.run(["git", "-C", CACHE, "rev-parse", "--short", "HEAD"],
                          capture_output=True, text=True).stdout.strip()


class Handler(http.server.SimpleHTTPRequestHandler):
    """Serves wpt's `<file>.headers` beside the file, which the opaque-origin tests need."""

    def log_message(self, *args):
        pass

    def end_headers(self):
        path = self.translate_path(self.path.split("?")[0]) + ".headers"
        if os.path.isfile(path):
            for line in open(path):
                name, _, value = line.partition(":")
                if value.strip():
                    self.send_header(name.strip(), value.strip())
        super().end_headers()


def serve(port):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Handler, directory=CACHE))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class Six:
    def __init__(self, app):
        self.p = subprocess.Popen([app + "/Contents/MacOS/six", "--mcp"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, bufsize=1)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "webmcp-wpt", "version": "0"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")

    def rpc(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("six --mcp closed; is a dev six running?")
            message = json.loads(line)
            if message.get("id") == self.n:
                if "error" in message:
                    raise RuntimeError(message["error"])
                return message["result"]

    def call(self, name, **args):
        result = self.rpc("tools/call", {"name": name, "arguments": args})
        text = "\n".join(c.get("text", "") for c in result.get("content", []))
        if result.get("isError"):
            raise RuntimeError(f"{name}: {text}")
        return text

    def js(self, window, script):
        text = self.call("evaluate_javascript", window_id=window, script=script)
        return json.loads(text[text.index("{"):text.rindex("}") + 1])


READ = r"""
const summary = document.querySelector('#summary');
const rows = [...document.querySelectorAll('#results > tbody > tr')].map(r => {
    const cells = [...r.cells].map(c => c.textContent.trim());
    return {status: cells[0], name: cells[1] || '', message: (cells[2] || '').split('\n')[0]};
});
const harness = summary ? (summary.textContent.match(/Harness status: (OK|Error|Timeout|Precondition Failed)/) || [])[1] || '' : '';
return JSON.stringify({done: !!summary, harness, rows, modelContext: typeof document.modelContext});
"""


def newest_app():
    apps = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/six-*/Build/Products/Debug/six.app"))
    return max(apps, key=os.path.getmtime) if apps else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("only", nargs="*", help="run the files whose path contains any of these")
    parser.add_argument("--app", default=newest_app(), help="the six.app whose --mcp relay to use")
    parser.add_argument("--port", type=int, default=8777)
    parser.add_argument("--timeout", type=float, default=15, help="seconds to wait for one file")
    parser.add_argument("--update", action="store_true", help="pull the suite again first")
    parser.add_argument("--json", help="write every result to this file too")
    args = parser.parse_args()

    commit = fetch(args.update)
    files = sorted(f for f in glob.glob(os.path.join(CACHE, "webmcp/**/*.html"), recursive=True)
                   if "/resources/" not in f)
    if args.only:
        files = [f for f in files if any(o in f for o in args.only)]
    serve(args.port)
    six = Six(args.app)

    base = f"http://127.0.0.1:{args.port}/"
    opened = six.call("open_window", url=base + "webmcp/")
    window = re.search(r"window ([0-9A-Fa-f-]{36})", opened).group(1)

    results, passed, total = {}, 0, 0
    for path in files:
        rel = os.path.relpath(path, CACHE)
        crashtest = "testharness.js" not in open(path, encoding="utf-8").read()
        six.call("navigate", window_id=window, url=base + rel)
        state, deadline = None, time.time() + args.timeout
        while time.time() < deadline:
            time.sleep(0.5)
            try:
                state = six.js(window, READ)
            except Exception:
                continue
            if state["modelContext"] == "undefined" and not rel.endswith("non-secure.html"):
                sys.exit("document.modelContext is undefined: launch six with SIX_WEBMCP=1, or turn on Develop ▸ WebMCP")
            if state["done"] or (crashtest and time.time() > deadline - args.timeout + 3):
                break
        if crashtest:
            # A crash test passes by leaving the page alive.
            rows = [{"status": "Pass" if state else "Fail", "name": "the page survives", "message": ""}]
            harness = "OK" if state else "CRASH"
        elif state and state["done"]:
            rows, harness = state["rows"], state["harness"]
        else:
            rows, harness = [], "NO RESULT"
        ok = sum(1 for r in rows if r["status"] == "Pass")
        passed, total = passed + ok, total + max(len(rows), 1)
        print(f"{ok:3}/{len(rows):<3} {rel}" + ("" if harness == "OK" else f"  [{harness}]"))
        for r in rows:
            if r["status"] != "Pass":
                print(f"        {r['status']}: {r['name'][:100]} — {r['message'][:140]}")
        results[rel] = {"harness": harness, "rows": rows}

    print(f"\n{passed}/{total} passed, wpt {commit}")
    if args.json:
        json.dump({"wpt": commit, "results": results}, open(args.json, "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
