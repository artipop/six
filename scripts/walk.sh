#!/bin/sh
# Serves scripts/walk on localhost and opens it in the Debug Savoia — the hand-checks of docs/unmeasured.md.
# localhost is a secure context, so location, notifications, the camera and the clipboard all work there.
cd "$(dirname "$0")/walk" || exit 1
PORT=${1:-8765}
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/Savoia-*/Build/Products/Debug/Savoia.app 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "no Debug Savoia in DerivedData; build it first"; exit 1; }
curl -s -o /dev/null "http://localhost:$PORT/index.html" || { python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 & sleep 1; }
# By path, never by bundle id: the Release Savoia must not be the one that answers.
open -a "$APP" "http://localhost:$PORT/index.html"
echo "the walk is at http://localhost:$PORT/ in $APP"
