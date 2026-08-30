#!/bin/sh
# Fetches sqlite-vec's prebuilt loadable extension for this machine, so `SqliteVecTest` can run.
#
# Not committed and not downloaded by the build: a test that reaches the network on its own is a test
# that fails for reasons that have nothing to do with the code. Run this once; the test skips itself
# until you do.
#
#   android/tools/sqlite-vec/fetch.sh
set -eu
version=${1:-0.1.9}
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../../core/build/sqlite-vec"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=macos-aarch64 ;;
  Darwin-x86_64) platform=macos-x86_64 ;;
  Linux-aarch64) platform=linux-aarch64 ;;
  Linux-x86_64) platform=linux-x86_64 ;;
  *) echo "no prebuilt for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$out"
url="https://github.com/asg017/sqlite-vec/releases/download/v$version/sqlite-vec-$version-loadable-$platform.tar.gz"
echo "fetching $url"
curl -sL --fail "$url" | tar xz -C "$out"
ls -l "$out"
