#!/usr/bin/env python3
"""Runs web-platform-tests in the Debug Savoia with wpt's own runner, and compares each file with Safari.

    ./scripts/wpt.py                               # the permission directories, against Safari and the baseline
    ./scripts/wpt.py permissions screen-capture    # only these directories
    ./scripts/wpt.py --only getusermedia           # files whose address contains this
    ./scripts/wpt.py --screen                      # with the screen-sharing files, and a person to answer
    ./scripts/wpt.py --write-baseline              # after a change that should move the numbers
    ./scripts/wpt.py --newest-safari               # against Safari's newest run, and what moved in it
    ./scripts/wpt.py dom/events -- --log-mach -    # any directory, and what follows -- goes to `wpt run`

This is `./wpt run savoia`: wptrunner starts Savoia, speaks W3C WebDriver to the server Savoia has
while Allow Remote Automation is on (docs/devtools.md), and serves the suite under wpt's own names,
web-platform.test and not-web-platform.test, which have to be in /etc/hosts (`--hosts` prints the
lines). The product — how to start Savoia, in a throwaway home that has the switch on and trusts
wpt's CA — is scripts/wptrunner/savoia_wptrunner.py. The tests run in automation tabs.

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
import socket
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("stand", os.path.join(HERE, "webmcp-wpt.py"))
stand = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stand)

CACHE = stand.CACHE
BASELINE = os.path.join(HERE, "wpt-baseline.json")
PRODUCT = os.path.join(CACHE, "savoia-product")
DIRECTORIES = ["permissions", "permissions-request", "permissions-revoke", "permissions-policy",
               "mediacapture-streams", "screen-capture", "mediacapture-handle", "geolocation", "notifications",
               "clipboard-apis", "storage-access-api", "idle-detection"]
SUPPORT = ["resources", "common", "tools", "interfaces", "fonts", "docs", ".well-known", "cookies", "bluetooth",
           "reporting", "webrtc", "webauthn", "page-visibility", "feature-policy", "media", "images",
           "service-workers/service-worker/resources", "html/browsers/browsing-the-web/remote-context-helper",
           "websockets/handlers", "infrastructure"]
RUNS = "https://wpt.fyi/api/runs?product=safari&label=stable&label=master&max-count=1"
RUN = "https://wpt.fyi/api/runs/%d"
HOST = "web-platform.test"
# wptrunner's statuses in wpt.fyi's letters.
STATUS = {"OK": "O", "ERROR": "E", "TIMEOUT": "T", "CRASH": "C", "PRECONDITION_FAILED": "PF", "PASS": "P",
          "FAIL": "F", "SKIP": "S"}


def fetch(directories, update):
    """The suite, with `add` and not `set`: the cache is shared with the other runners."""
    if not os.path.isdir(os.path.join(CACHE, ".git")):
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", stand.WPT, CACHE], check=True)
    elif update:
        subprocess.run(["git", "-C", CACHE, "pull", "-q", "--depth", "1"], check=True)
    subprocess.run(["git", "-C", CACHE, "sparse-checkout", "add", *directories, *SUPPORT], check=True)
    subprocess.run(["./wpt", "manifest", "-p", "savoia-MANIFEST.json", "--no-download"], cwd=CACHE,
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return subprocess.run(["git", "-C", CACHE, "rev-parse", "--short", "HEAD"],
                          capture_output=True, text=True).stdout.strip()


def register():
    """wptrunner finds a product of somebody else's by an entry point, which is a file beside the module."""
    info = os.path.join(PRODUCT, "savoia_wptrunner-1.dist-info")
    os.makedirs(info, exist_ok=True)
    with open(os.path.join(info, "METADATA"), "w") as target:
        target.write("Metadata-Version: 2.1\nName: savoia-wptrunner\nVersion: 1\n")
    with open(os.path.join(info, "entry_points.txt"), "w") as target:
        target.write("[wptrunner.products]\nsavoia = savoia_wptrunner:product\n")
    return os.pathsep.join([PRODUCT, os.path.join(HERE, "wptrunner")])


def tests(directories, only):
    """Every test address wpt's manifest names under the directories, with what it says about each."""
    items = json.load(open(os.path.join(CACHE, "savoia-MANIFEST.json")))["items"]
    found = []

    def walk(node, path):
        for name, value in node.items():
            if isinstance(value, dict):
                walk(value, path + [name])
                continue
            source = "/".join(path + [name])
            text = open(os.path.join(CACHE, source), errors="replace").read()
            # The system's sharing picker: nobody but a person can answer it.
            picker = "getDisplayMedia" in text or source.startswith("screen-capture/")
            for url, _ in value[1:]:
                found.append({"url": "/" + (url or source), "testdriver": "testdriver" in text, "picker": picker})

    for kind in ("testharness", "crashtest"):
        walk(items.get(kind, {}), [])
    found = [t for t in found if any(t["url"].startswith("/" + d.strip("/") + "/") for d in directories)]
    return sorted((t for t in found if not only or any(o in t["url"] for o in only)), key=lambda t: t["url"])


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


def run(app, urls, python_path, extra):
    """`./wpt run savoia` over the addresses; returns wptrunner's report, a result per test."""
    with tempfile.TemporaryDirectory(prefix="savoia-wpt-run-") as scratch:
        listed, report = os.path.join(scratch, "tests.txt"), os.path.join(scratch, "report.json")
        with open(listed, "w") as target:
            target.write("\n".join(urls) + "\n")
        command = ["./wpt", "run", "--binary", os.path.join(app, "Contents/MacOS/Savoia"), "--manifest", "savoia-MANIFEST.json",
                   "--no-manifest-update", "--include-file", listed, "--log-wptreport", report, "--yes",
                   "--no-fail-on-unexpected", "--no-pause-after-test", "--no-restart-on-unexpected", *extra, "savoia"]
        environment = dict(os.environ, PYTHONPATH=python_path, PYTHONWARNINGS="ignore")
        with open(os.path.join(CACHE, "savoia-wptrunner.log"), "w") as log:
            status = subprocess.run(command, cwd=CACHE, env=environment, stdout=log if not extra else None,
                                    stderr=subprocess.STDOUT if not extra else None).returncode
        if not os.path.exists(report):
            sys.exit(f"wptrunner wrote no report (exit {status}); see {log.name}")
        return json.load(open(report))["results"]


def verdict(result):
    """A result in wpt.fyi's summary vocabulary: a status letter and [passed, total]."""
    rows = result["subtests"]
    return {"s": STATUS.get(result["status"], result["status"]), "c": [sum(r["status"] == "PASS" for r in rows), len(rows)]}


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
        other, message = safari_rows.get(row["name"]), (row.get("message") or "").split("\n")[0]
        if other is None:
            lines.append(f"only in Savoia   {row['status']:8} {row['name'][:90]} — {message[:120]}")
        elif (other["status"] == "PASS") != (row["status"] == "PASS"):
            lines.append(f"Savoia {row['status']}, Safari {other['status']}: {row['name'][:90]} — "
                         f"{(message if row['status'] != 'PASS' else other.get('message') or '')[:160]}")
    for name, other in safari_rows.items():
        if name not in seen:
            lines.append(f"only in Safari   {other['status']:8} {name[:90]}")
    if not lines and theirs.get("status") != "OK":
        lines.append(f"Safari's harness: {theirs.get('status')} — {(theirs.get('message') or '')[:160]}")
    return lines


def moved(results, baseline):
    """What moved against the baseline, one line per file or subtest that changed."""
    lines = []
    for url, now in results.items():
        was = baseline.get(url)
        if was is None:
            continue
        if was["savoia"]["s"] != now["savoia"]["s"]:
            lines.append(f"{'STATUS':10} {url} — {was['savoia']['s']} → {now['savoia']['s']}")
        before = {r["name"]: r["status"] for r in was["rows"]}
        for row in now["rows"]:
            old = before.get(row["name"])
            if old is not None and (old == "PASS") != (row["status"] == "PASS"):
                lines.append(f"{'NEW PASS' if row['status'] == 'PASS' else 'REGRESSION':10} {url} — {row['name'][:100]}")
    return lines


def main():
    arguments, extra = sys.argv[1:], []
    if "--" in arguments:
        arguments, extra = arguments[:arguments.index("--")], arguments[arguments.index("--") + 1:]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directories", nargs="*", help="wpt directories to run; the permission ones when none is named")
    parser.add_argument("--only", action="append", default=[], help="run the files whose address contains this")
    parser.add_argument("--app", default=stand.newest_app(), help="the Debug Savoia.app to launch")
    parser.add_argument("--no-testdriver", action="store_true",
                        help="leave out the files that call testdriver: they use the camera and the system clipboard")
    parser.add_argument("--screen", action="store_true",
                        help="run the files that call getDisplayMedia too; someone has to answer the system's picker")
    parser.add_argument("--hosts", action="store_true", help="print the lines wpt needs in /etc/hosts, then stop")
    parser.add_argument("--update", action="store_true", help="pull the suite again first")
    parser.add_argument("--write-baseline", action="store_true", help="save this run as scripts/wpt-baseline.json")
    parser.add_argument("--newest-safari", action="store_true",
                        help="compare with Safari's newest stable run and not the one the baseline names")
    parser.add_argument("--safari-run", type=int, help="compare with this wpt.fyi run of Safari instead")
    parser.add_argument("--json", help="write every result to this file too")
    args = parser.parse_args(arguments)

    directories = args.directories or DIRECTORIES
    commit = fetch(directories, args.update)
    lines, present = hosts()
    if args.hosts:
        return print(lines, end="")
    if not present:
        sys.exit(f"{HOST} does not resolve to this Mac. Add wpt's names to /etc/hosts:\n"
                 f"    ./scripts/wpt.py --hosts | sudo tee -a /etc/hosts")
    baseline = json.load(open(BASELINE)) if os.path.exists(BASELINE) else None
    pinned = baseline["safari"]["run"] if baseline else None
    safari_run, summary, reports = safari(args.safari_run or (None if args.newest_safari else pinned))
    listed = tests(directories, args.only)
    runnable = [t for t in listed if not (args.no_testdriver and t["testdriver"]) and (args.screen or not t["picker"])]
    if not runnable:
        sys.exit("no test is named by that")

    results = {}
    for result in sorted(run(args.app, [t["url"] for t in runnable], register(), extra), key=lambda r: r["test"]):
        url, mine, theirs = result["test"], verdict(result), summary.get(result["test"])
        same = theirs is not None and mine == {"s": theirs["s"], "c": theirs["c"]}
        mark = "  " if same else ("??" if theirs is None else "≠ ")
        safari_text = "not in Safari's run" if theirs is None else f"Safari {theirs['s']} {theirs['c'][0]}/{theirs['c'][1]}"
        print(f"{mark} {mine['s']:2} {mine['c'][0]:3}/{mine['c'][1]:<3} {url}" + ("" if same else f"  [{safari_text}]"), flush=True)
        if result["status"] not in ("OK", "PASS") and result.get("message"):
            print(f"         {result['message'].strip().splitlines()[-1][:200]}")
        for line in [] if same or theirs is None else subtest_differences(url, result["subtests"], reports):
            print(f"         {line}", flush=True)
        results[url] = {"harness": result["status"], "rows": result["subtests"], "savoia": mine, "safari": theirs}

    print(f"\n{'directory':24} {'files':>5} {'picker':>6} {'run':>4} {'same':>5} {'differ':>6} {'no Safari row':>13}")
    for directory in directories:
        inside = "/" + directory.strip("/") + "/"
        mine = [u for u in results if u.startswith(inside)]
        absent = [u for u in mine if results[u]["safari"] is None]
        same = [u for u in mine if results[u]["safari"] == results[u]["savoia"]]
        everything = [t for t in listed if t["url"].startswith(inside)]
        print(f"{directory:24} {len(everything):5} {sum(t['picker'] for t in everything):6} {len(mine):4} "
              f"{len(same):5} {len(mine) - len(same) - len(absent):6} {len(absent):13}")

    system = system_safari()
    print(f"\nwpt {commit}; {named(safari_run)}")
    if not safari_run["browser_version"].startswith(system):
        print(f"NOTE: this Mac has Safari {system}, and the run compared against is {safari_run['browser_version'].split()[0]} — "
              "a difference may be the WebKit version and not Savoia")
    if baseline and safari_run["id"] != pinned:
        was, before, _ = safari(pinned)
        changed = safari_moves([t["url"] for t in listed], before, summary)
        print(f"in Safari, since {named(was)}:")
        print("\n".join(changed) if changed else "nothing moved")
    if baseline and not args.write_baseline:
        changed = moved(results, baseline["results"])
        print(f"in Savoia, against the baseline (wpt {baseline['wpt']}):")
        print("\n".join(changed) if changed else "nothing moved")
    record = {"wpt": commit, "safari": {"version": safari_run["browser_version"], "os": safari_run["os_version"],
                                       "wpt": safari_run["revision"], "run": safari_run["id"]}, "results": results}
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
