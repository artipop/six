#!/bin/bash
# Runs the Linux front inside the container, and puts its window somewhere it can be looked at.
#
# There is no display in a container, so the app draws into Xvfb and x11vnc/websockify publish that
# display as noVNC on 6080 — open http://localhost:6080/vnc_lite.html on the Mac. That is the whole
# reason this file exists: without it the third front can be built and never seen.
#
# Started for you by `scripts/six-linux.sh up`; it lives in the repository rather than inside the
# container because the earlier copies did not, and died with the container that held them.

set -u

cd /work/six/linux

# Build into a log and test the exit code. NEVER `swift build | grep -E "error:|Build complete"`:
# the grep succeeds, the pipeline exits 0, `set -e` never fires, and the loop below relaunches the
# *previous* binary — which is how one stale crash got reported as "it still crashes" three times.
echo "==> building"
if ! swift build -j 2 --scratch-path /tmp/g > /tmp/build.log 2>&1; then
    echo "=== BUILD FAILED ==="
    grep -E "error:" /tmp/build.log | head -20
    echo "=== (full log: /tmp/build.log; the container stays up so you can exec into it) ==="
    sleep infinity
fi
echo "==> built $(date +%T)"

export XDG_DATA_HOME=/data DISPLAY=:99 GDK_BACKEND=x11
# Already set in the image; repeated so this script also works in a plain toolchain container.
export WEBKIT_DISABLE_COMPOSITING_MODE=1 WEBKIT_DISABLE_DMABUF_RENDERER=1
export WEBKIT_FORCE_SANDBOX=0 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export SIX_URL="${SIX_URL:-https://webkitgtk.org/ https://swift.org/}"
export SIX_UI_DEBUG="${SIX_UI_DEBUG:-1}"

Xvfb :99 -screen 0 "${SIX_SCREEN:-1600x1000}"x24 & sleep 2
x11vnc -display :99 -forever -shared -nopw -quiet -rfbport 5900 >/dev/null 2>&1 & sleep 1
websockify --web=/usr/share/novnc 6080 localhost:5900 >/dev/null 2>&1 &

echo "==> six on http://localhost:6080/vnc_lite.html"

# Supervised on purpose. A front that has crashed and a front that is drawing nothing look
# identical over VNC — a black screen either way — and a restart at least says *when* it went.
while true; do
    "/tmp/g/debug/six-linux" > /tmp/six.log 2>&1 || true
    echo "--- exited $(date +%T), restarting in 3s (log: /tmp/six.log) ---"
    sleep 3
done
