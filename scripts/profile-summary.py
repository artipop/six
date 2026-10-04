#!/usr/bin/env python3
"""Writes a text summary of a Time Profiler trace beside it: where the CPU went, by process and by function.

    ./scripts/profile-summary.py dist/profiles/savoia-<timestamp>.trace [pid]

A trace of every process exports its system frames as bare addresses. They are resolved here with
`atos -p`, against pid if it is given and still running, which only holds until the next reboot — so profile.sh runs this right after recording.
"""
import collections
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

TOP = 40
WEBKIT = "com.apple.WebKit."


def export(trace, schema, out):
    xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    with open(out, "wb") as f:
        subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xpath],
                       stdout=f, stderr=subprocess.DEVNULL, check=True)


class Samples:
    """The time-profile table, with xctrace's id/ref sharing undone."""

    def __init__(self, path):
        self.tables = collections.defaultdict(dict)
        self.stacks = []                              # index → tuple of frame names, leaf first
        self.weight = collections.Counter()           # (process, thread, stack index) → ms
        self.by_minute = collections.defaultdict(collections.Counter)
        self.duration = 0
        stack_index = {}
        root = None
        for event, el in ET.iterparse(path, events=("start", "end")):
            if event == "start":
                root = root if root is not None else el
                continue
            if el.tag != "row":
                continue
            time = self.get(el.find("sample-time"), lambda e: int(e.text))
            thread = self.get(el.find("thread"), self.thread)
            process = self.get(el.find("process"), lambda e: e.get("fmt"))
            weight = self.get(el.find("weight"), lambda e: int(e.text) / 1e6)
            stack = self.get(el.find("tagged-backtrace"), self.backtrace)
            root.clear()
            if None in (time, process, weight):
                continue
            stack = stack or ()
            index = stack_index.setdefault(stack, len(self.stacks))
            if index == len(self.stacks):
                self.stacks.append(stack)
            self.weight[(process, thread or "", index)] += weight
            self.by_minute[time // 60_000_000_000][group(process)] += weight
            self.duration = max(self.duration, time / 1e9)

    def get(self, el, make):
        if el is None:
            return None
        table = self.tables[el.tag]
        ref = el.get("ref")
        if ref is not None:
            return table.get(ref)
        value = table[el.get("id")] = make(el)
        return value

    def thread(self, el):
        self.get(el.find("process"), lambda e: e.get("fmt"))
        return el.get("fmt")

    def frame(self, el):
        binary = self.get(el.find("binary"), lambda e: e.get("name"))
        name = el.get("name")
        return name if binary is None or name.startswith("0x") else f"{name}  [{binary}]"

    def backtrace(self, el):
        return tuple(self.get(f, self.frame) for f in el.findall("frame"))


def name_of(process):
    return process.rsplit(" (", 1)[0]


def group(process):
    name = name_of(process)
    return "Savoia" if name == "Savoia" else "WebKit" if name.startswith(WEBKIT) else "other"


def resolve(addresses, pids):
    """Address → `symbol  [library]`. atos names only what the process it is pointed at has loaded,
    so each one is asked about what the ones before it left."""
    names = {}
    for pid in pids:
        left = sorted(addresses - names.keys())
        if not left:
            break
        with tempfile.NamedTemporaryFile("w", suffix=".txt") as f:
            f.write("\n".join(left))
            f.flush()
            result = subprocess.run(["atos", "-p", str(pid), "-f", f.name], capture_output=True, text=True)
        lines = result.stdout.splitlines()
        if len(lines) != len(left):
            continue
        for address, line in zip(left, lines):
            match = re.match(r"(.*) \(in (.*?)\)( \(.*\))?( \+ \d+)?$", line)
            if match:
                names[address] = f"{match.group(1)}  [{match.group(2)}]"
    return names


def pids_to_ask(given):
    """The profiled Savoia if it is still there, then Finder, which has WebKit loaded, then this process."""
    finder = subprocess.run(["pgrep", "-x", "Finder"], capture_output=True, text=True).stdout.split()
    return [int(p) for p in given + finder[:1]] + [os.getpid()]


def table(out, title, counter, total, limit=TOP):
    out.append(f"\n{title}")
    for key, ms in counter.most_common(limit):
        share = 100 * ms / total if total else 0
        out.append(f"  {ms / 1000:8.2f} s  {share:5.1f}%  {key[:200]}")


def functions(samples, names, keys):
    """Self and inclusive time per function over the samples under `keys`."""
    own, inclusive = collections.Counter(), collections.Counter()
    for key in keys:
        ms = samples.weight[key]
        stack = [names.get(f, f) for f in samples.stacks[key[2]]]
        if stack:
            own[stack[0]] += ms
        for frame in set(stack):
            inclusive[frame] += ms
    return own, inclusive


def hangs(trace, out):
    with tempfile.NamedTemporaryFile(suffix=".xml") as f:
        try:
            export(trace, "potential-hangs", f.name)
            rows = re.findall(r"<row>(.*?)</row>", open(f.name).read(), flags=re.S)
        except (subprocess.CalledProcessError, OSError):
            return
    out.append(f"\nHangs on a main thread: {len(rows)}")
    last = ""
    for row in rows[:50]:
        fields = re.findall(r'fmt="([^"]*)"', row)
        thread = next((f for f in fields if "pid:" in f), None)
        last = thread or last
        out.append(f"  {fields[0]}  {fields[1]:>10}  {last}")


def main():
    trace = sys.argv[1].rstrip("/")
    with tempfile.NamedTemporaryFile(suffix=".xml") as f:
        print("exporting samples…", file=sys.stderr)
        export(trace, "time-profile", f.name)
        print("reading them…", file=sys.stderr)
        samples = Samples(f.name)

    by_process = collections.Counter()
    for (process, _, _), ms in samples.weight.items():
        by_process[process if name_of(process) == "Savoia" else name_of(process)] += ms
    total = sum(by_process.values())
    savoia = max((p for p in by_process if name_of(p) == "Savoia"), key=by_process.get, default=None)

    ours = [k for k in samples.weight if k[0] == savoia or name_of(k[0]).startswith(WEBKIT)]
    raw = {f for k in ours for f in samples.stacks[k[2]] if f.startswith("0x")}
    print(f"naming {len(raw)} addresses…", file=sys.stderr)
    names = resolve(raw, pids_to_ask(sys.argv[2:3]))

    out = [f"{os.path.basename(trace)}: {samples.duration:.0f} s recorded, {total / 1000:.0f} s of CPU",
           f"{len(names)} of {len(raw)} bare addresses named with atos"]
    table(out, "CPU by process", by_process, total, 20)

    out.append("\nCPU per minute, s: Savoia / WebKit / everything else")
    for minute in sorted(samples.by_minute):
        m = samples.by_minute[minute]
        out.append(f"  {minute:3d}  {m['Savoia'] / 1000:7.1f} {m['WebKit'] / 1000:7.1f} {m['other'] / 1000:7.1f}")

    if savoia:
        main_thread = [k for k in ours if k[0] == savoia and k[1].startswith("Main Thread")]
        background = [k for k in ours if k[0] == savoia and not k[1].startswith("Main Thread")]
        for title, keys in (("main thread", main_thread), ("other threads", background)):
            spent = sum(samples.weight[k] for k in keys)
            own, inclusive = functions(samples, names, keys)
            table(out, f"{savoia}, {title}: {spent / 1000:.1f} s — where it was (self time)", own, spent)
            table(out, f"{savoia}, {title} — what it was doing (with callees)", inclusive, spent)

    pages = [k for k in ours if name_of(k[0]).startswith(WEBKIT)]
    spent = sum(samples.weight[k] for k in pages)
    own, inclusive = functions(samples, names, pages)
    table(out, f"WebKit processes: {spent / 1000:.1f} s — where it was (self time)", own, spent)
    table(out, "WebKit processes — what they were doing (with callees)", inclusive, spent)

    hangs(trace, out)

    summary = os.path.splitext(trace)[0] + ".txt"
    with open(summary, "w") as f:
        f.write("\n".join(out) + "\n")
    print(summary)


if __name__ == "__main__":
    main()
