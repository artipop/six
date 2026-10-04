#!/bin/sh
# Records an Instruments trace into dist/profiles while the Release Savoia is running.
#
#   ./scripts/profile.sh [--attach | --launch] [seconds] [template]     # 30, "Time Profiler" — `xcrun xctrace list templates`
#
# Every process is recorded, because pages run in WebKit's own processes and those cannot be attached to.
# --attach records Savoia alone, which is what the per-process templates (Allocations, Leaks) need.
# --launch starts Savoia once the recording is running, so the trace has the launch in it; quit Savoia first.
# The build needs nothing extra: what dmg.sh makes is signed with get-task-allow and has its dSYM
# in dist/DerivedData. See docs/build.md.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
app=${SAVOIA_APP:-/Applications/Savoia.app}
mode=${1:-}
case "$mode" in --attach | --launch) shift ;; *) mode= ;; esac
seconds=${1:-30}
template=${2:-Time Profiler}

# The browser itself, not a `Savoia --mcp` bridge.
pid=$(pgrep -f "^$app/Contents/MacOS/Savoia\$" | head -1 || true)
target=--all-processes
case "$mode" in
--launch)
    [ -z "$pid" ] || { echo "$app is running; quit it first" >&2; exit 1; } ;;
*)
    [ -n "$pid" ] || { echo "$app is not running" >&2; exit 1; } ;;
esac
if [ "$mode" = --attach ]; then
    codesign -d --entitlements - "$app" 2>/dev/null | grep -q get-task-allow \
        || { echo "$app is signed without get-task-allow; Instruments cannot attach to it" >&2; exit 1; }
    target="--attach $pid"
fi

out="$root/dist/profiles"
mkdir -p "$out"
trace="$out/savoia-$(date +%Y%m%d-%H%M%S).trace"

if [ "$mode" = --launch ]; then
    # xctrace's own --launch cannot tell this Savoia.app from the other copies on the disk.
    started="org.deffun.savoia.profile.$$"
    (notifyutil -1 "$started" >/dev/null && open -na "$app") &
    set -- --notify-tracing-started "$started"
else
    set --
fi
# Ctrl-C ends the recording early and still saves it.
trap : INT
xcrun xctrace record --template "$template" $target --time-limit "${seconds}s" --no-prompt --output "$trace" "$@" || true

echo
echo "$trace"
echo "    open \"$trace\""
