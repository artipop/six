#!/usr/bin/env python3
"""Runs web-platform-tests' webmcp/ suite in a running dev Savoia, through `Savoia --mcp`.

    ./scripts/webmcp-wpt.py --install-ca             # once, with the dev Savoia quit
    open -na <Debug Savoia.app> --env SAVOIA_WEBMCP=1      # or Develop ▸ WebMCP on
    ./scripts/webmcp-wpt.py                          # the whole suite, against the baseline
    ./scripts/webmcp-wpt.py imperative/getTools      # files whose path contains any argument
    ./scripts/webmcp-wpt.py --write-baseline         # after a change that should move the numbers

The suite is a sparse clone of wpt in ~/Library/Caches/savoia-wpt, served by wpt's own `wpt serve`
under .localhost rather than web-platform.test, so no hosts file is needed: *.localhost resolves
to loopback by itself. savoia.localhost is the test page, www1.savoia.localhost and savoia-alt.localhost
are the other origins, and the machine's LAN address is the one non-secure origin. Not plain
localhost: get-host-info then takes 127.0.0.1 as the remote host, which no certificate here
names. The certificates come from a CA name-constrained to those hosts, which `--install-ca`
puts into the dev build's trust list.
"""

import argparse
import glob
import json
import os
import re
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.request

CACHE = os.path.expanduser("~/Library/Caches/savoia-wpt")
WPT = "https://github.com/web-platform-tests/wpt.git"
SPARSE = ["webmcp", "resources", "common", "tools", "interfaces", "fonts", "docs", ".well-known"]
BASELINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "webmcp-wpt-baseline.json")
DEV = os.path.expanduser("~/Library/Application Support/org.deffun.savoia.dev")
CONFIG = {
    "browser_host": "savoia.localhost",
    "alternate_hosts": {"alt": "savoia-alt.localhost"},
    "server_host": "localhost",
    "bind_address": False,
    "check_subdomains": False,
    "ports": {"http": [8000, 8001], "https": [8443, 8444], "ws": [], "wss": [], "h2": [], "webtransport-h3": []},
    "ssl": {"type": "openssl", "openssl": {"duration": 365, "force_regenerate": False, "base_path": "savoia-certs"}},
}


def fetch(update):
    if not os.path.isdir(os.path.join(CACHE, ".git")):
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", WPT, CACHE], check=True)
    elif update:
        subprocess.run(["git", "-C", CACHE, "pull", "-q", "--depth", "1"], check=True)
    subprocess.run(["git", "-C", CACHE, "sparse-checkout", "set", *SPARSE], check=True)
    os.makedirs(os.path.join(CACHE, "savoia-certs"), exist_ok=True)
    json.dump(CONFIG, open(os.path.join(CACHE, "savoia-config.json"), "w"), indent=1)
    return subprocess.run(["git", "-C", CACHE, "rev-parse", "--short", "HEAD"],
                          capture_output=True, text=True).stdout.strip()


def answering(url):
    try:
        urllib.request.urlopen(url, timeout=2)
        return True
    except Exception:
        return False


def serve():
    """Starts `wpt serve` unless one is already answering, and returns the process it started."""
    if answering("http://localhost:8000/resources/testharness.js"):
        return None
    log = open(os.path.join(CACHE, "savoia-serve.log"), "w")
    process = subprocess.Popen(["./wpt", "serve", "--config", "savoia-config.json"], cwd=CACHE,
                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(240):
        if answering("http://localhost:8000/resources/testharness.js"):
            return process
        time.sleep(0.5)
    sys.exit(f"wpt serve did not come up; see {log.name}")


def install_ca():
    """Adds the stand's CA to the dev build's trust list. The dev Savoia must not be running."""
    if subprocess.run(["pgrep", "-f", "Debug/Savoia.app/Contents/MacOS/Savoia"], capture_output=True).stdout:
        sys.exit("quit the dev Savoia first: it keeps the trust list in memory and would write it back")
    ca = os.path.join(CACHE, "savoia-certs", "cacert.pem")
    if not os.path.exists(ca):
        process = serve()
        if process:
            os.killpg(process.pid, 15)
    os.makedirs(os.path.join(DEV, "Certificates"), exist_ok=True)
    name = "wpt-localhost.pem"
    with open(ca, "rb") as source, open(os.path.join(DEV, "Certificates", name), "wb") as target:
        target.write(source.read())
    db = sqlite3.connect(os.path.join(DEV, "savoia.sqlite"))
    row = db.execute("select value from settings where key = 'trust.certificates'").fetchone()
    enabled = set(json.loads(row[0])) if row else set()
    enabled.add("file:" + name)
    db.execute("insert or replace into settings (key, value) values ('trust.certificates', ?)", (json.dumps(sorted(enabled)),))
    db.commit()
    print(f"trusted {name} in the dev build ({', '.join(sorted(enabled))})")


def lan_address():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.connect(("192.0.2.1", 9))
        return probe.getsockname()[0]


def address(rel):
    """The URL wpt serve answers a test file on: .window.js becomes .window.html, https by name."""
    rel = re.sub(r"\.(window|any)\.js$", r".\1.html", rel)
    if rel.endswith("non-secure.html"):
        return f"http://{lan_address()}:8000/{rel}"
    if ".https." in rel:
        return f"https://savoia.localhost:8443/{rel}"
    return f"http://savoia.localhost:8000/{rel}"


class Savoia:
    def __init__(self, app):
        self.p = subprocess.Popen([app + "/Contents/MacOS/Savoia", "--mcp"], stdin=subprocess.PIPE,
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
                raise RuntimeError("Savoia --mcp closed; is a dev Savoia running?")
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
return JSON.stringify({done: !!summary, harness, rows, modelContext: typeof document.modelContext, url: location.href});
"""


def newest_app():
    apps = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/Savoia-*/Build/Products/Debug/Savoia.app"))
    return max(apps, key=os.path.getmtime) if apps else None


def test_files(only):
    files = []
    for pattern in ("webmcp/**/*.html", "webmcp/**/*.window.js", "webmcp/**/*.any.js"):
        files += glob.glob(os.path.join(CACHE, pattern), recursive=True)
    files = sorted(os.path.relpath(f, CACHE) for f in files if "/resources/" not in f)
    return [f for f in files if not only or any(o in f for o in only)]


def run_one(savoia, window, rel, timeout):
    source = open(os.path.join(CACHE, rel), encoding="utf-8").read()
    crashtest = rel.endswith(".html") and "testharness.js" not in source
    savoia.call("navigate", window_id=window, url=address(rel))
    state, started = None, time.time()
    while time.time() - started < timeout:
        time.sleep(0.5)
        try:
            state = savoia.js(window, READ)
        except Exception:
            continue
        if state["modelContext"] == "undefined" and ".https." in rel:
            sys.exit("document.modelContext is undefined on a secure page: launch Savoia with SAVOIA_WEBMCP=1, "
                     "or turn on Develop ▸ WebMCP — or the page did not load (--install-ca?)")
        if state["done"] or (crashtest and time.time() - started > 3):
            break
    if crashtest:
        # A crash test passes by leaving the page alive.
        return ("OK" if state else "CRASH"), [{"status": "Pass" if state else "Fail", "name": "the page survives", "message": ""}]
    if state and state["done"]:
        return state["harness"], state["rows"]
    return "NO RESULT", []


def compare(results, baseline):
    """What moved against the baseline, one line per subtest that changed."""
    lines = []
    for rel, now in results.items():
        before = {r["name"]: r["status"] for r in baseline.get(rel, {}).get("rows", [])}
        for row in now["rows"]:
            was = before.get(row["name"])
            if was is not None and (was == "Pass") != (row["status"] == "Pass"):
                mark = "NEW PASS" if row["status"] == "Pass" else "REGRESSION"
                lines.append(f"{mark:10} {rel} — {row['name'][:100]}")
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("only", nargs="*", help="run the files whose path contains any of these")
    parser.add_argument("--app", default=newest_app(), help="the Savoia.app whose --mcp relay to use")
    parser.add_argument("--timeout", type=float, default=45, help="seconds to wait for one file")
    parser.add_argument("--update", action="store_true", help="pull the suite again first")
    parser.add_argument("--install-ca", action="store_true", help="trust the stand's CA in the dev build, then stop")
    parser.add_argument("--write-baseline", action="store_true", help="save this run as scripts/webmcp-wpt-baseline.json")
    parser.add_argument("--json", help="write every result to this file too")
    args = parser.parse_args()

    commit = fetch(args.update)
    if args.install_ca:
        return install_ca()
    server = serve()
    try:
        savoia = Savoia(args.app)
        opened = savoia.call("open_window", url="http://savoia.localhost:8000/webmcp/")
        window = re.search(r"window ([0-9A-Fa-f-]{36})", opened).group(1)
        results, passed, total = {}, 0, 0
        for rel in test_files(args.only):
            harness, rows = run_one(savoia, window, rel, args.timeout)
            ok = sum(1 for r in rows if r["status"] == "Pass")
            passed, total = passed + ok, total + max(len(rows), 1)
            print(f"{ok:3}/{len(rows):<3} {rel}" + ("" if harness == "OK" else f"  [{harness}]"), flush=True)
            for r in rows:
                if r["status"] != "Pass":
                    print(f"        {r['status']}: {r['name'][:100]} — {r['message'][:140]}", flush=True)
            results[rel] = {"harness": harness, "rows": rows}
    finally:
        if server:
            os.killpg(server.pid, 15)

    print(f"\n{passed}/{total} passed, wpt {commit}")
    if os.path.exists(BASELINE) and not args.write_baseline:
        baseline = json.load(open(BASELINE))
        moved = compare(results, baseline["results"])
        print(f"against the baseline (wpt {baseline['wpt']}, {baseline['passed']}/{baseline['total']}):")
        print("\n".join(moved) if moved else "nothing moved")
    record = {"wpt": commit, "passed": passed, "total": total, "results": results}
    if args.write_baseline:
        json.dump(record, open(BASELINE, "w"), indent=1, ensure_ascii=False)
        print(f"baseline written to {os.path.relpath(BASELINE)}")
    if args.json:
        json.dump(record, open(args.json, "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
