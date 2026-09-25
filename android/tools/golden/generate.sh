#!/bin/sh
# Regenerates core/src/test/resources/tiling-golden.txt from the Mac's own TilingLayout.
#
# It compiles six/Tiling/TilingLayout.swift on its own — no Xcode project, no SwiftPM, nothing else from
# the app — and prints the geometry it computes. That file is the source of truth for the numbers;
# this is only the way to read them out. macOS only, which is the point: the golden values have to
# come from the platform they are the contract with.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
out="$repo/android/core/src/test/resources/tiling-golden.txt"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

swiftc -O -o "$tmp/golden" "$here/main.swift" "$repo/six/Tiling/TilingLayout.swift" 2>/dev/null
"$tmp/golden" > "$tmp/golden.json"
python3 "$here/format.py" "$tmp/golden.json" "$out"
echo "wrote $out"
