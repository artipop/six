#!/usr/bin/env python3
"""Runs web-platform-tests' permission directories in the Debug Savoia and compares each file with Safari.

    ./scripts/permissions-wpt.py                               # every directory, against Safari and the baseline
    ./scripts/permissions-wpt.py --no-testdriver               # without the camera and the system clipboard
    ./scripts/permissions-wpt.py --screen                      # with the screen-sharing files, and a person to answer
    ./scripts/permissions-wpt.py permissions screen-capture    # only these directories
    ./scripts/permissions-wpt.py --only getusermedia           # files whose address contains this
    ./scripts/permissions-wpt.py --write-baseline              # after a change that should move the numbers

The stand is webmcp-wpt.py's: `wpt serve` under savoia.localhost with a CA of its own, Savoia driven
through `Savoia --mcp`. Savoia itself is launched here, in a throwaway home (CFFIXED_USER_HOME) that is
given the CA, so no answer a site was given before reaches the run and the dev build's state is not
touched. The list of files and their variants is wpt's own manifest.

testdriver works the way wptrunner drives Safari: the page side is wptrunner's own testdriver-extra.js
and message queue, served as /resources/testdriver-vendor.js, and this script takes each action off
the queue, carries it out through tools Savoia offers only under SAVOIA_TESTDRIVER, and posts the
result back. An action Savoia has no tool for is answered "not implemented", as wptrunner does.

Safari's results are the newest stable run on wpt.fyi; the files where Savoia and Safari differ are
printed subtest by subtest.
"""

import argparse
import gzip
import importlib.util
import json
import os
import plistlib
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("stand", os.path.join(HERE, "webmcp-wpt.py"))
stand = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stand)

CACHE = stand.CACHE
BASELINE = os.path.join(HERE, "permissions-wpt-baseline.json")
DIRECTORIES = ["permissions", "permissions-request", "permissions-revoke", "permissions-policy",
               "mediacapture-streams", "screen-capture", "mediacapture-handle", "geolocation", "notifications",
               "clipboard-apis", "storage-access-api", "idle-detection"]
SUPPORT = ["resources", "common", "tools", "interfaces", "fonts", "docs", ".well-known", "cookies", "bluetooth",
           "reporting", "webrtc", "webauthn", "page-visibility", "feature-policy", "media", "images",
           "service-workers/service-worker/resources", "html/browsers/browsing-the-web/remote-context-helper"]
RUNS = "https://wpt.fyi/api/runs?product=safari&label=stable&label=master&max-count=1"
STATUS = {"OK": "O", "Error": "E", "Timeout": "T", "Precondition Failed": "PF", "NO RESULT": "T"}

VENDOR = os.path.join(CACHE, "savoia-testdriver")

# What wptrunner's executor does with execute_async_script: take one message off the page's queue.
TAKE = r"""
let action = null;
if (window.__wptrunner_message_queue && window.__wptrunner_process_next_event) {
    window.__wptrunner_testdriver_callback = message => { action = message[2]; };
    window.__wptrunner_process_next_event();
    window.__wptrunner_testdriver_callback = null;
}
"""

POINT = r"""
let root = document, element = null;
for (const selector of %s) {
    element = root.querySelector(selector);
    if (!element) return JSON.stringify({error: 'no element matches ' + selector});
    root = element.shadowRoot || element;
}
element.scrollIntoView({block: 'center', inline: 'center'});
const box = element.getBoundingClientRect();
return JSON.stringify({x: Math.round(box.left + box.width / 2), y: Math.round(box.top + box.height / 2), origin: location.origin});
"""

READ = TAKE + r"""
const summary = document.querySelector('#summary');
const rows = [...document.querySelectorAll('#results > tbody > tr')].map(r => {
    const cells = [...r.cells].map(c => {
        const copy = c.cloneNode(true);
        copy.querySelectorAll('details').forEach(d => d.remove());
        return copy.textContent.trim();
    });
    return {status: cells[0], name: cells[1] || '', message: (cells[2] || '').split('\n')[0].slice(0, 200)};
});
const harness = summary ? (summary.textContent.match(/Harness status: (OK|Error|Timeout|Precondition Failed)/) || [])[1] || '' : '';
return JSON.stringify({done: !!summary, harness, rows, url: location.href, origin: location.origin, action});
"""


def fetch(update):
    """The suite, with `add` and not `set`: the cache is shared with the other runners."""
    if not os.path.isdir(os.path.join(CACHE, ".git")):
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", stand.WPT, CACHE], check=True)
    elif update:
        subprocess.run(["git", "-C", CACHE, "pull", "-q", "--depth", "1"], check=True)
    subprocess.run(["git", "-C", CACHE, "sparse-checkout", "add", *DIRECTORIES, *SUPPORT], check=True)
    os.makedirs(os.path.join(CACHE, "savoia-certs"), exist_ok=True)
    json.dump(stand.CONFIG, open(os.path.join(CACHE, "savoia-config.json"), "w"), indent=1)
    subprocess.run(["./wpt", "manifest", "-p", "savoia-MANIFEST.json", "--no-download"], cwd=CACHE,
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return subprocess.run(["git", "-C", CACHE, "rev-parse", "--short", "HEAD"],
                          capture_output=True, text=True).stdout.strip()


def vendor():
    """wptrunner's page side of testdriver, unmodified, as the vendor file the stand serves."""
    runner = os.path.join(CACHE, "tools", "wptrunner", "wptrunner")
    queue = open(os.path.join(runner, "executors", "message-queue.js")).read()
    queue = queue[:queue.index("})();") + len("})();")]
    # wptrunner's testharnessreport.js says this; the stand serves wpt's own, which does not.
    context = "window.__wptrunner_is_test_context = !!document.querySelector('script[src*=\"testharnessreport.js\"]');"
    os.makedirs(VENDOR, exist_ok=True)
    with open(os.path.join(VENDOR, "testdriver-vendor.js"), "w") as target:
        target.write("\n".join([queue, context, open(os.path.join(runner, "testdriver-extra.js")).read()]))
    with open(os.path.join(CACHE, "savoia-aliases.txt"), "w") as target:
        target.write(f"/resources/testdriver-vendor.js, {VENDOR}\n")


def serve():
    """`wpt serve` with the vendor file in place; returns the process, or None when one already answers."""
    probe = "http://localhost:8000/resources/testdriver-vendor.js"
    try:
        served = urllib.request.urlopen(probe, timeout=2).read()
        if b"__wptrunner_message_queue" not in served:
            sys.exit("a wpt serve without the testdriver vendor file is already running; stop it first")
        return None
    except OSError:
        pass
    log = open(os.path.join(CACHE, "savoia-serve.log"), "w")
    process = subprocess.Popen(["./wpt", "serve", "--config", "savoia-config.json", "--alias_file", "savoia-aliases.txt"],
                               cwd=CACHE, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(240):
        if stand.answering(probe):
            return process
        time.sleep(0.5)
    sys.exit(f"wpt serve did not come up; see {log.name}")


def tests(directories, only):
    """Every test address wpt's manifest names under the directories, with what it says about each."""
    items = json.load(open(os.path.join(CACHE, "savoia-MANIFEST.json")))["items"]
    found = []

    def walk(node, path, kind):
        for name, value in node.items():
            if isinstance(value, dict):
                walk(value, path + [name], kind)
                continue
            source = "/".join(path + [name])
            # The manifest's own flag misses a .js test that names testdriver in its META lines.
            text = open(os.path.join(CACHE, source), errors="replace").read()
            testdriver = "testdriver" in text
            # The system's sharing picker: nobody but a person can answer it.
            picker = "getDisplayMedia" in text or source.startswith("screen-capture/")
            for url, extras in value[1:]:
                found.append({"url": "/" + (url or source), "kind": kind, "testdriver": testdriver, "picker": picker,
                              "long": extras.get("timeout") == "long"})

    for kind in ("testharness", "crashtest"):
        walk(items.get(kind, {}), [], kind)
    found = [t for t in found if t["url"].split("/")[1] in directories]
    return sorted((t for t in found if not only or any(o in t["url"] for o in only)), key=lambda t: t["url"])


def lan_address():
    """This Mac's address on a real interface. The default route may be a VPN's tunnel, which does not loop back."""
    for interface in ("en0", "en1", "en2", "en3"):
        found = subprocess.run(["ipconfig", "getifaddr", interface], capture_output=True, text=True).stdout.strip()
        if found:
            return found
    return stand.lan_address()


def address(url):
    path = urllib.parse.urlsplit(url).path
    # http://*.localhost is a secure context; a test of a non-secure one needs a host that is not.
    if "non-secure" in path or "insecure" in path or ".http." in path:
        return f"http://{lan_address()}:8000" + url
    if ".https." in path or ".serviceworker." in path:
        return "https://savoia.localhost:8443" + url
    return "http://savoia.localhost:8000" + url


def download(url):
    data = urllib.request.urlopen(url, timeout=120).read()
    return json.loads(gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data)


def safari():
    """The newest stable Safari run on wpt.fyi: what it is, its summary, and where its per-file reports live."""
    run = download(RUNS)[0]
    cached = os.path.join(CACHE, f"savoia-safari-{run['id']}.json")
    if not os.path.exists(cached):
        json.dump(download(run["results_url"]), open(cached, "w"))
    return run, json.load(open(cached)), run["results_url"].replace("-summary_v2.json.gz", "")


def system_safari():
    try:
        return plistlib.load(open("/Applications/Safari.app/Contents/Info.plist", "rb"))["CFBundleShortVersionString"]
    except Exception:
        return "unknown"


class Browser:
    """A Debug Savoia in a home of its own that trusts the stand's CA."""

    def __init__(self, app):
        self.app = app
        self.home = tempfile.mkdtemp(prefix="savoia-wpt-", dir="/tmp")
        self.env = dict(os.environ, CFFIXED_USER_HOME=self.home, SAVOIA_MCP_SOCKET=os.path.join(self.home, "mcp.sock"),
                        SAVOIA_TESTDRIVER="1")
        self.process = None
        # The settings table exists only after a first launch, and the trust list is read at launch.
        self.launch(lambda: self.database() and self.has_settings())
        self.quit()
        self.trust()
        self.launch(lambda: os.path.exists(self.env["SAVOIA_MCP_SOCKET"]))

    def database(self):
        import glob
        found = glob.glob(os.path.join(self.home, "Library/Application Support/*/savoia.sqlite"))
        return found[0] if found else None

    def has_settings(self):
        try:
            return bool(sqlite3.connect(self.database()).execute(
                "select 1 from sqlite_master where name = 'settings'").fetchone())
        except sqlite3.Error:
            return False

    def launch(self, ready):
        self.process = subprocess.Popen([self.app + "/Contents/MacOS/Savoia"], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(120):
            if self.process.poll() is not None:
                sys.exit("Savoia quit while starting; run this from a shell that is not sandboxed")
            if ready():
                return time.sleep(1)
            time.sleep(0.5)
        sys.exit("Savoia did not come up")

    def trust(self):
        support = os.path.dirname(self.database())
        os.makedirs(os.path.join(support, "Certificates"), exist_ok=True)
        shutil.copy(os.path.join(CACHE, "savoia-certs", "cacert.pem"), os.path.join(support, "Certificates", "wpt-localhost.pem"))
        db = sqlite3.connect(self.database())
        db.execute("insert or replace into settings (key, value) values ('trust.certificates', ?)",
                   (json.dumps(["file:wpt-localhost.pem"]),))
        db.commit()
        db.close()

    def quit(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(10)
            except subprocess.TimeoutExpired:
                self.process.kill()

    def close(self):
        self.quit()
        shutil.rmtree(self.home, ignore_errors=True)


def js(savoia, window, script):
    """Runs a function body in the page and reads back the JSON it returns."""
    return savoia.js(window, script)


def act(savoia, window, action, origin):
    """Carries out one testdriver action and returns its result; raises when it cannot be done."""
    name, params = action["action"], action["params"]
    if params.get("context") is not None:
        raise NotImplementedError(f"{name} in another window or frame")
    if name == "set_permission":
        wanted = params["permission_params"]
        savoia.call("testdriver_set_permission", window_id=window, origin=origin,
                    permission=wanted["descriptor"]["name"], state=wanted["state"])
    elif name == "click":
        point = js(savoia, window, POINT % json.dumps(params["selectors"]))
        if "error" in point:
            raise RuntimeError(point["error"])
        savoia.call("testdriver_click", window_id=window, x=point["x"], y=point["y"])
    elif name == "delete_all_cookies":
        savoia.call("testdriver_delete_all_cookies", window_id=window)
    else:
        raise NotImplementedError(name)
    return None


def answer(savoia, window, action, origin, log):
    """What wptrunner's process_action does: act, then post testdriver-complete to the page."""
    try:
        message = {"status": "success", "message": json.dumps({"result": act(savoia, window, action, origin)})}
    except NotImplementedError as error:
        message = {"status": "error", "message": f"Action {error} not implemented"}
    except Exception as error:
        message = {"status": "error", "message": f"Action {action['action']} failed: {error}"}
    log.append(f"{action['action']}: {message['status']}" + ("" if message["status"] == "success" else f" — {message['message']}"))
    message.update(cmd_id=action["id"], type="testdriver-complete")
    js(savoia, window, f"window.postMessage({json.dumps(message)}, '*'); return '{{}}';")


def run_one(savoia, window, test, slack):
    timeout = (60 if test["long"] else 10) + slack
    savoia.call("navigate", window_id=window, url=address(test["url"]))
    state, started = None, time.time()
    actions, acted = [], False
    while time.time() - started < timeout:
        # No pause after an action: a user activation the page was just given lasts about a second.
        if not acted:
            time.sleep(0.1 if actions else 0.5)
        acted = False
        try:
            state = js(savoia, window, READ)
        except Exception:
            state = None
            continue
        if not state["url"].endswith(test["url"]):
            state = None
            continue
        if state["action"]:
            answer(savoia, window, state["action"], state["origin"], actions)
            acted = True
            continue
        if state["done"] or (test["kind"] == "crashtest" and time.time() - started > 3):
            break
    if test["kind"] == "crashtest":
        return ("OK" if state else "CRASH"), [], actions
    if state and state["done"]:
        return state["harness"], state["rows"], actions
    return "NO RESULT", (state or {}).get("rows", []), actions


def verdict(test, harness, rows):
    """A result in wpt.fyi's summary vocabulary: a status letter and [passed, total]."""
    if test["kind"] == "crashtest":
        return {"s": "P" if harness == "OK" else "C", "c": [0, 0]}
    return {"s": STATUS.get(harness, harness), "c": [sum(1 for r in rows if r["status"] == "Pass"), len(rows)]}


def subtest_differences(url, rows, reports):
    """Which subtests of one file Savoia and Safari answer differently."""
    try:
        theirs = download(reports + urllib.parse.quote(url))
    except Exception as error:
        return [f"Safari's report for the file could not be read: {error}"]
    safari_rows = {s["name"]: s for s in theirs.get("subtests", [])}
    lines, seen = [], set()
    for row in rows:
        seen.add(row["name"])
        other = safari_rows.get(row["name"])
        mine = row["status"].upper().replace("NOT RUN", "NOTRUN")
        if other is None:
            lines.append(f"only in Savoia   {mine:8} {row['name'][:90]} — {row['message'][:120]}")
        elif (other["status"] == "PASS") != (mine == "PASS"):
            lines.append(f"Savoia {mine}, Safari {other['status']}: {row['name'][:90]} — "
                         f"{(row['message'] if mine != 'PASS' else other.get('message') or '')[:160]}")
    for name, other in safari_rows.items():
        if name not in seen:
            lines.append(f"only in Safari   {other['status']:8} {name[:90]}")
    if not lines and theirs.get("status") != "OK":
        lines.append(f"Safari's harness: {theirs.get('status')} — {(theirs.get('message') or '')[:160]}")
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directories", nargs="*", help="wpt directories to run; all of them when none is named")
    parser.add_argument("--only", action="append", default=[], help="run the files whose address contains this")
    parser.add_argument("--app", default=stand.newest_app(), help="the Debug Savoia.app to launch")
    parser.add_argument("--slack", type=float, default=5, help="seconds past testharness's own timeout to wait")
    parser.add_argument("--no-testdriver", action="store_true",
                        help="leave out the files that call testdriver: they use the camera and the system clipboard")
    parser.add_argument("--screen", action="store_true",
                        help="run the files that call getDisplayMedia too; someone has to answer the system's picker")
    parser.add_argument("--actions", action="store_true", help="print every testdriver action and how it went")
    parser.add_argument("--update", action="store_true", help="pull the suite again first")
    parser.add_argument("--write-baseline", action="store_true", help="save this run as scripts/permissions-wpt-baseline.json")
    parser.add_argument("--json", help="write every result to this file too")
    args = parser.parse_args()

    directories = args.directories or DIRECTORIES
    commit = fetch(args.update)
    run, summary, reports = safari()
    listed = tests(directories, args.only)
    runnable = [t for t in listed if not (args.no_testdriver and t["testdriver"]) and (args.screen or not t["picker"])]

    vendor()
    server = serve()
    browser = Browser(args.app)
    results = {}
    try:
        os.environ.update(CFFIXED_USER_HOME=browser.home, SAVOIA_MCP_SOCKET=browser.env["SAVOIA_MCP_SOCKET"])
        savoia = stand.Savoia(args.app)
        opened = savoia.call("open_window", url="http://savoia.localhost:8000/resources/blank.html")
        window = re.search(r"window ([0-9A-Fa-f-]{36})", opened).group(1)
        for test in runnable:
            harness, rows, actions = run_one(savoia, window, test, args.slack)
            mine, theirs = verdict(test, harness, rows), summary.get(test["url"])
            same = theirs is not None and mine["s"] == theirs["s"] and mine["c"] == theirs["c"]
            mark = "  " if same else ("??" if theirs is None else "≠ ")
            safari_text = "not in Safari's run" if theirs is None else f"Safari {theirs['s']} {theirs['c'][0]}/{theirs['c'][1]}"
            print(f"{mark} {mine['s']:2} {mine['c'][0]:3}/{mine['c'][1]:<3} {test['url']}" + ("" if same else f"  [{safari_text}]"), flush=True)
            differences = [] if same or theirs is None else subtest_differences(test["url"], rows, reports)
            for line in differences:
                print(f"         {line}", flush=True)
            if args.actions:
                for line in dict.fromkeys(actions):
                    print(f"         testdriver {actions.count(line)}× {line}", flush=True)
            results[test["url"]] = {"harness": harness, "rows": rows, "savoia": mine, "safari": theirs}
    finally:
        browser.close()
        if server:
            os.killpg(server.pid, 15)

    print(f"\n{'directory':24} {'files':>5} {'testdriver':>10} {'picker':>6} {'run':>4} {'same':>5} {'differ':>6} {'no Safari row':>13}")
    for directory in directories:
        mine = [u for u in results if u.split("/")[1] == directory]
        absent = [u for u in mine if results[u]["safari"] is None]
        same = [u for u in mine if results[u]["safari"] == results[u]["savoia"]]
        everything = [t for t in listed if t["url"].split("/")[1] == directory]
        print(f"{directory:24} {len(everything):5} {sum(t['testdriver'] for t in everything):10} "
              f"{sum(t['picker'] for t in everything):6} {len(mine):4} "
              f"{len(same):5} {len(mine) - len(same) - len(absent):6} {len(absent):13}")

    system = system_safari()
    print(f"\nwpt {commit}; Safari {run['browser_version']} on macOS {run['os_version']}, wpt {run['revision']}, "
          f"{run['time_start'][:10]} (wpt.fyi run {run['id']})")
    if not run["browser_version"].startswith(system):
        print(f"NOTE: this Mac has Safari {system}, and the run compared against is {run['browser_version'].split()[0]} — "
              "a difference may be the WebKit version and not Savoia")

    if os.path.exists(BASELINE) and not args.write_baseline:
        baseline = json.load(open(BASELINE))
        moved = stand.compare(results, baseline["results"])
        print(f"against the baseline (wpt {baseline['wpt']}):")
        print("\n".join(moved) if moved else "nothing moved")
    record = {"wpt": commit, "safari": {"version": run["browser_version"], "os": run["os_version"],
                                       "wpt": run["revision"], "run": run["id"]}, "results": results}
    if args.write_baseline:
        # Statuses only: the messages carry ports, stacks and timings, and would move on every run.
        slim = {url: dict(result, rows=[{"name": r["name"], "status": r["status"]} for r in result["rows"]])
                for url, result in results.items()}
        json.dump(dict(record, results=slim), open(BASELINE, "w"), indent=1, ensure_ascii=False, sort_keys=True)
        print(f"baseline written to {os.path.relpath(BASELINE)}")
    if args.json:
        json.dump(record, open(args.json, "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
