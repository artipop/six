"""Runs the stand's page tasks through a running six and prints one row per task.

    python3 scripts/agent-stand/serve.py 8765 &
    python3 scripts/agent-stand/tasks.py --label "jev"

What a row says is the whole question a fast decider has to answer: did the task end
correctly, how long it took, how many times the language model was called and how much
prompt it was given, and how often six kept the fast decider's own step. A decider that
is never kept saves nothing, however quick it is.

The verdict is what the stand's server received (`submitted.jsonl`), never the run's own
account of itself. Point six at one endpoint or another by launching it with
SIX_PAGETASK_ENDPOINT / SIX_PAGETASK_KEY / SIX_PAGETASK_MODEL / SIX_PAGETASK_THRESHOLD,
and run this with a --label saying which.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sixmcp import Six  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SUBMITTED = os.path.join(HERE, "submitted.jsonl")

TASKS = [
    {
        "name": "flights",
        "url": "flights.html",
        "goal": "Search one-way flights from Zurich to London Heathrow on 16 October 2026 for 2 adults "
                "in business class, nonstop only. Accept the cookie banner first. Stop when the results are shown.",
        "expect": {"task": "flights", "from": "ZRH", "to": "LHR", "d": "2026-10-16",
                   "adults": "2", "cabin": "Business", "nonstop": "true", "trip": "oneway"},
    },
    {
        "name": "contact",
        "url": "contact.html",
        "goal": "Send a support message as Jane Doe, jane@example.com, no phone. Topic: billing. Prefer contact "
                "by email. Message: I was charged twice for my September invoice, please refund one charge. "
                "Accept the privacy policy and send it.",
        "expect": {"task": "contact", "name": "Jane Doe", "email": "jane@example.com", "phone": "",
                   "topic": "billing", "pref": "email", "consent": "on"},
    },
    {
        "name": "results",
        "url": "results.html?from=ZRH&to=LHR&d=2026-10-16&adults=1&cabin=Economy",
        # Nothing to do: the goal is already satisfied. A decider that cannot see that presses
        # something, and on a real site that is the booking path.
        "goal": "Check that flight results from Zurich to London are shown for 16 October 2026. "
                "Do not select or book anything.",
        "expect": None,
    },
]

SUMMARY = re.compile(r"(\d+) steps in ([\d.]+) s")
CALLS = re.compile(r"language model called (\d+) × on (\d+) chars of prompt \((\d+) in all\)")
AGREED = re.compile(r"overruled (\d+) and confirmed (\d+)")
TOKENS = re.compile(r"fast decider (\d+) input tokens")


def submissions():
    if not os.path.exists(SUBMITTED):
        return []
    with open(SUBMITTED) as file:
        return [json.loads(line) for line in file if line.strip()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", default="run", help="what decided the steps, for the table")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--only", help="run one task by name")
    parser.add_argument("--out", help="write the rows to this JSON file as well")
    arguments = parser.parse_args()

    base = f"http://127.0.0.1:{arguments.port}/"
    try:
        urllib.request.urlopen(base + "flights.html", timeout=3)
    except OSError:
        sys.exit(f"The stand is not serving on {base} — start serve.py first")

    six = Six()
    rows = []
    for task in TASKS:
        if arguments.only and task["name"] != arguments.only:
            continue
        open(SUBMITTED, "w").close()
        six.call("open_window", url=base + task["url"])
        started = time.perf_counter()
        try:
            trace, _ = six.call("run_page_task", goal=task["goal"])
        except RuntimeError as error:
            rows.append({"task": task["name"], "ok": False, "why": str(error)[:120]})
            continue
        seconds = round(time.perf_counter() - started, 1)
        sent = submissions()
        if task["expect"] is None:
            ok = not sent
            why = "" if ok else f"submitted {sent}"
        elif not sent:
            ok, why = False, "nothing reached the server"
        else:
            missing = {k: (v, sent[-1].get(k)) for k, v in task["expect"].items() if sent[-1].get(k) != v}
            ok, why = not missing, "" if not missing else f"wrong: {missing}"
        summary = SUMMARY.search(trace)
        calls = CALLS.search(trace)
        agreed = AGREED.search(trace)
        tokens = TOKENS.search(trace)
        rows.append({
            "task": task["name"], "ok": ok, "why": why,
            "steps": int(summary.group(1)) if summary else None,
            "seconds": seconds,
            "llm_calls": int(calls.group(1)) if calls else 0,
            "llm_chars": int(calls.group(3)) if calls else 0,
            "kept": int(agreed.group(2)) if agreed else 0,
            "overruled": int(agreed.group(1)) if agreed else 0,
            "fast_tokens": int(tokens.group(1)) if tokens else 0,
            "trace": trace,
        })
        print(f"[{arguments.label}] {task['name']}: {'ok' if ok else 'FAILED ' + why} — {rows[-1]['steps']} steps, "
              f"{seconds} s, LLM {rows[-1]['llm_calls']} × ({rows[-1]['llm_chars']} chars), "
              f"fast decider kept {rows[-1]['kept']} / overruled {rows[-1]['overruled']}", flush=True)

    print()
    print(f"| task | {arguments.label} | steps | s | LLM calls | LLM chars | kept | overruled |")
    print("|---|---|---:|---:|---:|---:|---:|---:|")
    for row in rows:
        print(f"| {row['task']} | {'ok' if row.get('ok') else 'failed'} | {row.get('steps')} | {row.get('seconds')} "
              f"| {row.get('llm_calls')} | {row.get('llm_chars')} | {row.get('kept')} | {row.get('overruled')} |")
    if arguments.out:
        with open(arguments.out, "w") as file:
            json.dump({"label": arguments.label, "rows": rows}, file, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
