#!/usr/bin/env python3
"""Runs web-platform-tests' permission directories in the Debug Savoia and compares each file with Safari.

    ./scripts/permissions-wpt.py                               # every directory, against Safari and the baseline
    ./scripts/permissions-wpt.py --no-testdriver               # without the camera and the system clipboard
    ./scripts/permissions-wpt.py --screen                      # with the screen-sharing files, and a person to answer
    ./scripts/permissions-wpt.py permissions screen-capture    # only these directories
    ./scripts/permissions-wpt.py --only getusermedia           # files whose address contains this
    ./scripts/permissions-wpt.py --write-baseline              # after a change that should move the numbers
    ./scripts/permissions-wpt.py --newest-safari               # against Safari's newest run, and what moved in it

The stand is webmcp-wpt.py's — `wpt serve` with a CA of its own, Savoia driven through `Savoia --mcp` —
but under wpt's own names, web-platform.test and not-web-platform.test, which have to be in /etc/hosts
(`--hosts` prints the lines). Under *.localhost plain http is a secure context and every host is a site
of its own to WebKit, and the tests of non-secure contexts and same-site frames say nothing. Savoia itself is launched here, in a throwaway home (CFFIXED_USER_HOME) that is
given the CA, so no answer a site was given before reaches the run and the dev build's state is not
touched. The list of files and their variants is wpt's own manifest.

testdriver works the way wptrunner drives Safari: the page side is wptrunner's own testdriver-extra.js
and message queue, served as /resources/testdriver-vendor.js, and this script takes each action off
the queue, carries it out through tools Savoia offers only under SAVOIA_TESTDRIVER, and posts the
result back. An action Savoia has no tool for is answered "not implemented", as wptrunner does.

Safari's results are one run on wpt.fyi, the one the baseline names: Safari moves between its own
runs, and a comparison with the newest would move with it. `--newest-safari` takes the newest stable
run instead and prints what moved in Safari apart from what moved in Savoia. The files where Savoia
and Safari differ are printed subtest by subtest.
"""

import argparse
import gzip
import importlib.util
import json
import os
import plistlib
import re
import shutil
import socket
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
           "service-workers/service-worker/resources", "html/browsers/browsing-the-web/remote-context-helper",
           "websockets/handlers"]
RUNS = "https://wpt.fyi/api/runs?product=safari&label=stable&label=master&max-count=1"
RUN = "https://wpt.fyi/api/runs/%d"
STATUS = {"OK": "O", "Error": "E", "Timeout": "T", "Precondition Failed": "PF", "NO RESULT": "T"}

HOST = "web-platform.test"
# wpt's default names, on this stand's ports and with certificates of its own beside webmcp-wpt.py's.
CONFIG = dict(stand.CONFIG, browser_host=HOST, alternate_hosts={"alt": "not-" + HOST},
              ports=dict(stand.CONFIG["ports"], ws=[8666], wss=[8667]),
              ssl={"type": "openssl", "openssl": {"duration": 365, "force_regenerate": False, "base_path": "savoia-wpt-certs"}})
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

FOCUS = r"""
let root = document, element = null;
for (const selector of %s) {
    element = root.querySelector(selector);
    if (!element) return JSON.stringify({error: 'no element matches ' + selector});
    root = element.shadowRoot || element;
}
if (document.activeElement !== element) element.focus();
return JSON.stringify({});
"""

# WebDriver's code points for the keys that are not characters, as KeyboardEvent.key names them.
KEYS = {"\ue003": "Backspace", "\ue004": "Tab", "\ue006": "Enter", "\ue007": "Enter", "\ue008": "Shift",
        "\ue009": "Control", "\ue00a": "Alt", "\ue00c": "Escape", "\ue00d": " ", "\ue00e": "PageUp",
        "\ue00f": "PageDown", "\ue010": "End", "\ue011": "Home", "\ue012": "ArrowLeft", "\ue013": "ArrowUp",
        "\ue014": "ArrowRight", "\ue015": "ArrowDown", "\ue017": "Delete", "\ue03d": "Meta", "\ue050": "Shift",
        "\ue051": "Control", "\ue052": "Alt", "\ue053": "Meta"}
MODIFIERS = {"Shift", "Control", "Alt", "Meta"}

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
    os.makedirs(os.path.join(CACHE, "savoia-wpt-certs"), exist_ok=True)
    json.dump(CONFIG, open(os.path.join(CACHE, "savoia-wpt-config.json"), "w"), indent=1)
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
        named = urllib.request.urlopen("http://localhost:8000/common/get-host-info.sub.js", timeout=2).read()
        if b"__wptrunner_message_queue" not in served or HOST.encode() not in named:
            sys.exit("another wpt serve is already running on these ports; stop it first")
        return None
    except OSError:
        pass
    log = open(os.path.join(CACHE, "savoia-serve.log"), "w")
    process = subprocess.Popen(["./wpt", "serve", "--config", "savoia-wpt-config.json", "--alias_file", "savoia-aliases.txt"],
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


def address(url):
    path = urllib.parse.urlsplit(url).path
    if ".https." in path or ".serviceworker." in path:
        return f"https://{HOST}:8443" + url
    return f"http://{HOST}:8000" + url


def hosts():
    """The lines wpt wants in /etc/hosts, and whether they are there."""
    lines = subprocess.run(["./wpt", "make-hosts-file"], cwd=CACHE, capture_output=True, text=True).stdout
    try:
        present = all(socket.gethostbyname(name) == "127.0.0.1" for name in (HOST, "www1." + HOST, "not-" + HOST))
    except OSError:
        present = False
    return lines, present


def download(url):
    data = urllib.request.urlopen(url, timeout=120).read()
    return json.loads(gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data)


def safari(pinned=None):
    """One stable Safari run on wpt.fyi — the pinned one, or the newest: what it is, its summary, and
    where its per-file reports live."""
    run = download(RUN % pinned) if pinned else download(RUNS)[0]
    cached = os.path.join(CACHE, f"savoia-safari-{run['id']}.json")
    if not os.path.exists(cached):
        json.dump(download(run["results_url"]), open(cached, "w"))
    return run, json.load(open(cached)), run["results_url"].replace("-summary_v2.json.gz", "")


def named(run):
    return (f"Safari {run['browser_version']} on macOS {run['os_version']}, wpt {run['revision']}, "
            f"{run['time_start'][:10]} (wpt.fyi run {run['id']})")


def safari_moves(urls, before, after):
    """The files Safari itself answers differently in two of its runs."""
    def text(row):
        return "absent" if row is None else f"{row['s']} {row['c'][0]}/{row['c'][1]}"
    return [f"SAFARI     {url} — {text(before.get(url))} → {text(after.get(url))}"
            for url in urls if before.get(url) != after.get(url)]


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
        # A sleeping display hides every page, and a hidden page is refused fullscreen and focus.
        self.awake = subprocess.Popen(["caffeinate", "-d", "-u", "-w", str(os.getpid())])
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
        shutil.copy(os.path.join(CACHE, "savoia-wpt-certs", "cacert.pem"), os.path.join(support, "Certificates", "wpt-localhost.pem"))
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
        self.awake.terminate()
        self.quit()
        shutil.rmtree(self.home, ignore_errors=True)


def js(savoia, window, script):
    """Runs a function body in the page and reads back the JSON it returns."""
    return savoia.js(window, script)


def key(savoia, window, value, action, held):
    """One key going down or up, with the modifiers already down held."""
    name = KEYS.get(value, value)
    savoia.call("testdriver_key", window_id=window, key=name, action=action, modifiers="+".join(sorted(held)))
    if name in MODIFIERS:
        (held.add if action == "down" else held.discard)(name)


def act(savoia, window, action, origin, held):
    """Carries out one testdriver action and returns its result; raises when it cannot be done."""
    name, params = action["action"], action["params"]
    context = params.get("context")
    if isinstance(context, dict):
        raise NotImplementedError(f"{name} in another window")
    aimed = {"context": context} if context else {}

    def inside(script):
        """In the frame the action is aimed at, which wptrunner reaches by switching WebDriver to it."""
        if context:
            return json.loads(savoia.call("testdriver_in_context", window_id=window, context=context, script=script))
        return js(savoia, window, script)

    if name == "set_permission":
        wanted = params["permission_params"]
        target = inside("return JSON.stringify({origin: location.origin});")["origin"]
        savoia.call("testdriver_set_permission", window_id=window, origin=target, top=origin,
                    permission=wanted["descriptor"]["name"], state=wanted["state"])
    elif name == "click":
        point = inside(POINT % json.dumps(params["selectors"]))
        if "error" in point:
            raise RuntimeError(point["error"])
        savoia.call("testdriver_click", window_id=window, x=point["x"], y=point["y"], **aimed)
    elif name == "delete_all_cookies":
        savoia.call("testdriver_delete_all_cookies", window_id=window)
    elif name == "send_keys":
        focused = inside(FOCUS % json.dumps(params["selectors"]))
        if "error" in focused:
            raise RuntimeError(focused["error"])
        down = set()
        for value in params["keys"]:
            if value == "\ue000":
                for modifier in sorted(down):
                    key(savoia, window, modifier, "up", down)
            elif KEYS.get(value) in MODIFIERS:
                key(savoia, window, value, "down", down)
            else:
                key(savoia, window, value, "press", down)
        for modifier in sorted(down):
            key(savoia, window, modifier, "up", down)
    elif name == "action_sequence":
        # wptrunner releases what the sequence before this one left down.
        for modifier in sorted(held):
            key(savoia, window, modifier, "up", held)
        sources, pointers = params["actions"], {}
        for tick in range(max(len(source["actions"]) for source in sources)):
            pause = 0
            for source in sources:
                step = source["actions"][tick] if tick < len(source["actions"]) else {"type": "pause"}
                kind, at = step["type"], pointers.setdefault(source.get("id"), [0, 0])
                if kind == "pause":
                    pause = max(pause, step.get("duration") or 0)
                elif kind in ("keyDown", "keyUp"):
                    key(savoia, window, step["value"], "down" if kind == "keyDown" else "up", held)
                elif kind == "pointerMove":
                    start = step.get("origin", "viewport")
                    if isinstance(start, dict):
                        start = inside(POINT % json.dumps(start["selectors"]))
                        if "error" in start:
                            raise RuntimeError(start["error"])
                        start = [start["x"], start["y"]]
                    else:
                        start = at if start == "pointer" else [0, 0]
                    at[:] = [start[0] + step.get("x", 0), start[1] + step.get("y", 0)]
                    savoia.call("testdriver_click", window_id=window, x=at[0], y=at[1], action="move", **aimed)
                elif kind in ("pointerDown", "pointerUp") and step.get("button", 0) == 0:
                    savoia.call("testdriver_click", window_id=window, x=at[0], y=at[1],
                                action="down" if kind == "pointerDown" else "up", **aimed)
                else:
                    raise NotImplementedError(f"action_sequence with {kind}")
            time.sleep(pause / 1000)
    else:
        raise NotImplementedError(name)
    return None


def answer(savoia, window, action, origin, log, held):
    """What wptrunner's process_action does: act, then post testdriver-complete to the page."""
    try:
        message = {"status": "success", "message": json.dumps({"result": act(savoia, window, action, origin, held)})}
    except NotImplementedError as error:
        message = {"status": "error", "message": f"Action {error} not implemented"}
    except Exception as error:
        message = {"status": "error", "message": f"Action {action['action']} failed: {error}"}
    log.append(f"{action['action']}: {message['status']}" + ("" if message["status"] == "success" else f" — {message['message']}"))
    message.update(cmd_id=action["id"], type="testdriver-complete")
    js(savoia, window, f"window.postMessage({json.dumps(message)}, '*'); return '{{}}';")


def run_one(savoia, window, test, slack):
    timeout = (60 if test["long"] else 10) + slack
    savoia.call("testdriver_close_windows")
    savoia.call("navigate", window_id=window, url=address(test["url"]))
    state, started = None, time.time()
    actions, acted, held = [], False, set()
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
            answer(savoia, window, state["action"], state["origin"], actions, held)
            acted = True
            continue
        if state["done"] or (test["kind"] == "crashtest" and time.time() - started > 3):
            break
    for modifier in sorted(held):
        key(savoia, window, modifier, "up", held)
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
    parser.add_argument("--hosts", action="store_true", help="print the lines wpt needs in /etc/hosts, then stop")
    parser.add_argument("--actions", action="store_true", help="print every testdriver action and how it went")
    parser.add_argument("--update", action="store_true", help="pull the suite again first")
    parser.add_argument("--write-baseline", action="store_true", help="save this run as scripts/permissions-wpt-baseline.json")
    parser.add_argument("--newest-safari", action="store_true",
                        help="compare with Safari's newest stable run and not the one the baseline names")
    parser.add_argument("--safari-run", type=int, help="compare with this wpt.fyi run of Safari instead")
    parser.add_argument("--json", help="write every result to this file too")
    args = parser.parse_args()

    directories = args.directories or DIRECTORIES
    commit = fetch(args.update)
    lines, present = hosts()
    if args.hosts:
        return print(lines, end="")
    if not present:
        sys.exit(f"{HOST} does not resolve to this Mac. Add wpt's names to /etc/hosts:\n"
                 f"    ./scripts/permissions-wpt.py --hosts | sudo tee -a /etc/hosts")
    baseline = json.load(open(BASELINE)) if os.path.exists(BASELINE) else None
    pinned = baseline["safari"]["run"] if baseline else None
    run, summary, reports = safari(args.safari_run or (None if args.newest_safari else pinned))
    listed = tests(directories, args.only)
    runnable = [t for t in listed if not (args.no_testdriver and t["testdriver"]) and (args.screen or not t["picker"])]

    vendor()
    server = serve()
    browser = Browser(args.app)
    results = {}
    try:
        os.environ.update(CFFIXED_USER_HOME=browser.home, SAVOIA_MCP_SOCKET=browser.env["SAVOIA_MCP_SOCKET"])
        savoia = stand.Savoia(args.app)
        opened = savoia.call("open_window", url=f"http://{HOST}:8000/resources/blank.html")
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
    print(f"\nwpt {commit}; {named(run)}")
    if not run["browser_version"].startswith(system):
        print(f"NOTE: this Mac has Safari {system}, and the run compared against is {run['browser_version'].split()[0]} — "
              "a difference may be the WebKit version and not Savoia")

    if baseline and run["id"] != pinned:
        was, before, _ = safari(pinned)
        moved = safari_moves([t["url"] for t in listed], before, summary)
        print(f"in Safari, since {named(was)}:")
        print("\n".join(moved) if moved else "nothing moved")
    if baseline and not args.write_baseline:
        moved = stand.compare(results, baseline["results"])
        print(f"in Savoia, against the baseline (wpt {baseline['wpt']}):")
        print("\n".join(moved) if moved else "nothing moved")
    record = {"wpt": commit, "safari": {"version": run["browser_version"], "os": run["os_version"],
                                       "wpt": run["revision"], "run": run["id"]}, "results": results}
    if args.write_baseline:
        # Statuses only: the messages carry ports, stacks and timings, and would move on every run.
        slim = {url: dict(result, rows=[{"name": r["name"], "status": r["status"]} for r in result["rows"]])
                for url, result in results.items()}
        # A run of some directories replaces those and keeps the rest.
        if baseline and baseline["wpt"] == commit:
            slim = dict(baseline["results"], **slim)
        # One Safari run for every row, the kept ones too.
        slim = {url: dict(result, safari=summary.get(url)) for url, result in slim.items()}
        json.dump(dict(record, results=slim), open(BASELINE, "w"), indent=1, ensure_ascii=False, sort_keys=True)
        print(f"baseline written to {os.path.relpath(BASELINE)}")
    if args.json:
        json.dump(record, open(args.json, "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
