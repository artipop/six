#!/usr/bin/env python3
"""Runs web-platform-tests' web-extensions/ test extensions in the Debug Savoia, unmodified.

    ./scripts/web-extensions-wpt.py                    # all six, against the baseline
    ./scripts/web-extensions-wpt.py alarms storage     # only these
    ./scripts/web-extensions-wpt.py --write-baseline   # after a WebKit update moved the numbers

Each extension gets a launch of its own in a throwaway home (CFFIXED_USER_HOME), so the dev build's
state is not touched and no running Savoia is needed. SAVOIA_EXTENSION installs it,
SAVOIA_EXTENSION_TESTING turns on WebKit's own `browser.test`, and the verdicts are read from
Savoia's log. The wpt page and testdriver are not involved: the extension starts its tests by itself.
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import tempfile
import time

CACHE = os.path.expanduser("~/Library/Caches/savoia-wpt")
WPT = "https://github.com/web-platform-tests/wpt.git"
BASELINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web-extensions-wpt-baseline.json")


def fetch(update):
    if not os.path.isdir(os.path.join(CACHE, ".git")):
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", WPT, CACHE], check=True)
    elif update:
        subprocess.run(["git", "-C", CACHE, "pull", "-q", "--depth", "1"], check=True)
    subprocess.run(["git", "-C", CACHE, "sparse-checkout", "add", "web-extensions"], check=True)
    return subprocess.run(["git", "-C", CACHE, "rev-parse", "--short", "HEAD"],
                          capture_output=True, text=True).stdout.strip()


def newest_app():
    apps = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/Savoia-*/Build/Products/Debug/Savoia.app"))
    return max(apps, key=os.path.getmtime) if apps else None


def events(home):
    found = []
    for log in glob.glob(os.path.join(home, "Library/Logs/*/savoia.log")):
        for line in open(log, errors="replace"):
            match = re.search(r"\[extensions\] test (\{.*\})", line)
            if match:
                found.append(json.loads(match.group(1)))
    return found


def run_one(app, name, timeout):
    home = tempfile.mkdtemp(prefix="savoia-webext-")
    env = dict(os.environ, CFFIXED_USER_HOME=home, SAVOIA_EXTENSION_TESTING="1",
               SAVOIA_EXTENSION=os.path.join(CACHE, "web-extensions", "resources", name))
    savoia = subprocess.Popen([app + "/Contents/MacOS/Savoia"], env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        started, added, finished = time.time(), [], {}
        while time.time() - started < timeout and savoia.poll() is None:
            time.sleep(1)
            seen = events(home)
            added = [e["name"] for e in seen if e["kind"] == "added"]
            finished = {e["name"]: e for e in seen if e["kind"] == "finished"}
            if added and len(finished) >= len(added):
                break
    finally:
        savoia.terminate()
        try:
            savoia.wait(10)
        except subprocess.TimeoutExpired:
            savoia.kill()
        shutil.rmtree(home, ignore_errors=True)
    rows = []
    for test in added:
        end = finished.get(test)
        status = "No result" if end is None else ("Pass" if end["result"] else "Fail")
        message = "" if end is None or end["result"] else " ".join(end["message"].split())
        rows.append({"name": test, "status": status, "message": message})
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("only", nargs="*", help="the extensions to run, by folder name")
    parser.add_argument("--app", default=newest_app(), help="the Debug Savoia.app to launch")
    parser.add_argument("--timeout", type=float, default=90, help="seconds to wait for one extension")
    parser.add_argument("--update", action="store_true", help="pull the suite again first")
    parser.add_argument("--write-baseline", action="store_true", help="save this run as the baseline")
    args = parser.parse_args()

    commit = fetch(args.update)
    names = sorted(os.listdir(os.path.join(CACHE, "web-extensions", "resources")))
    results, passed, total = {}, 0, 0
    for name in [n for n in names if not args.only or n in args.only]:
        rows = run_one(args.app, name, args.timeout)
        ok = sum(1 for r in rows if r["status"] == "Pass")
        passed, total = passed + ok, total + len(rows)
        print(f"{ok:3}/{len(rows):<3} {name}" + ("" if rows else "  [the extension never started its tests]"), flush=True)
        for r in rows:
            if r["status"] != "Pass":
                print(f"        {r['status']}: {r['name']} — {r['message'][:160]}", flush=True)
        results[name] = rows

    print(f"\n{passed}/{total} passed, wpt {commit}")
    if args.write_baseline:
        json.dump({"wpt": commit, "passed": passed, "total": total, "results": results},
                  open(BASELINE, "w"), indent=1, ensure_ascii=False)
        print(f"baseline written to {os.path.relpath(BASELINE)}")
    elif os.path.exists(BASELINE):
        baseline = json.load(open(BASELINE))
        moved = []
        for name, rows in results.items():
            before = {r["name"]: r["status"] for r in baseline["results"].get(name, [])}
            for r in rows:
                was = before.get(r["name"])
                if was is not None and (was == "Pass") != (r["status"] == "Pass"):
                    moved.append(f"{'NEW PASS' if r['status'] == 'Pass' else 'REGRESSION':10} {name} — {r['name']}")
        print(f"against the baseline (wpt {baseline['wpt']}, {baseline['passed']}/{baseline['total']}):")
        print("\n".join(moved) if moved else "nothing moved")


if __name__ == "__main__":
    main()
