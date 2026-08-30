"""Turns the generator's JSON into the flat table the Kotlin test reads.

Flat on purpose: `:core` has no JSON library on its test classpath and should not grow one to read
seven cases, and a line-oriented file makes a drift show up as a one-line diff.
"""

import json
import sys

HEADER = """# Golden strip geometry, produced by the Mac and committed here.
#
# Regenerate with android/tools/golden/generate.sh, which compiles six/Niri/NiriLayout.swift
# on its own and prints this table. Do not hand-edit: a number that changes here is either
# a deliberate change to the layout on both sides, or the bug this file exists to catch.
#
# Columns in every `case` are widthIndex 0..3; `frames` are x,y,w,h for widths [0,2,3,1]."""


def main(src, dst):
    cases = json.load(open(src))
    out = [HEADER]
    for c in cases:
        out.append("")
        out.append("case %s %.6f %.6f" % (c["name"], c["viewport"][0], c["viewport"][1]))
        out.append("gap %.6f" % c["gap"])
        out.append("columnHeight %.6f" % c["columnHeight"])
        out.append("widths " + " ".join("%.6f" % w for w in c["widths"]))
        out.append("frames " + " ".join(c["frames"]))
        out.append("contentWidth %.6f" % c["contentWidth"])
    open(dst, "w").write("\n".join(out) + "\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
