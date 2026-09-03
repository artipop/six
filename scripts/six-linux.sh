#!/bin/sh
# Drives the Linux front from the Mac: the image, the container, and the window in a browser.
#
# The third front is built and run in a container and nowhere else — `swift build --package-path
# linux` cannot work here, because `CWebKitGTK` has no `webkitgtk-6.0` on macOS to resolve against
# (docs/linux.md says why at length). Apple's `container` runs it natively on Apple Silicon.
#
# The recipe used to live in scripts written into a container's own filesystem, so it died whenever
# the container did and was reconstructed from memory each time. It lives here now.
#
#   ./scripts/six-linux.sh image     build six-gnome:26.04 from linux/Containerfile
#   ./scripts/six-linux.sh up        start six-live, then watch http://localhost:6080/vnc_lite.html
#   ./scripts/six-linux.sh build     rebuild the front inside the running container
#   ./scripts/six-linux.sh test      SixCore's tests, on Linux
#   ./scripts/six-linux.sh core      SixCore alone in a plain toolchain image (no GTK, no container kept)
#   ./scripts/six-linux.sh shot [f]  one still picture, without VNC
#   ./scripts/six-linux.sh logs      the app's stderr
#   ./scripts/six-linux.sh sh [cmd]  a shell (or one command) in the container
#   ./scripts/six-linux.sh down      remove the container
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
image=${SIX_IMAGE:-six-gnome:26.04}
name=${SIX_CONTAINER:-six-live}
port=${SIX_PORT:-6080}
# The scratch paths the build.db rule in CLAUDE.md is about: the front's, and the root package's.
scratch=/tmp/g
core_scratch=/tmp/gcore

PATH=/opt/homebrew/bin:$PATH
export PATH

have_system() {
    container system status >/dev/null 2>&1
}

need_system() {
    have_system && return 0
    echo "==> starting the container system"
    container system start >/dev/null 2>&1 || true
    have_system || { echo "container system is not running; try: container system start" >&2; exit 1; }
}

running() {
    container ls -q 2>/dev/null | grep -qx "$name"
}

need_running() {
    running || { echo "$name is not running — start it with: $0 up" >&2; exit 1; }
}

cmd=${1:-help}
[ $# -gt 0 ] && shift

case "$cmd" in

image)
    need_system
    echo "==> building $image (tracks GNOME 50; see linux/Containerfile)"
    container build --tag "$image" "$root/linux"
    ;;

up)
    need_system
    container rm -f "$name" >/dev/null 2>&1 || true
    echo "==> starting $name"
    # 2 CPUs and 4 GB: the default 1024 MB stalls the build near 120/453 with no error and no
    # output, and this Mac has 8 GB to share with Xcode and the browser you are actually using.
    container run -d --name "$name" --cpus 2 --memory 4g \
        -v "$root:/work/six" -p "$port:6080" \
        "$image" bash /work/six/scripts/linux-run.sh >/dev/null
    echo "==> waiting for noVNC (the first build in a fresh container takes minutes)"
    i=0
    while [ "$i" -lt 60 ]; do
        if curl -s -o /dev/null --max-time 4 "http://localhost:$port/vnc_lite.html"; then
            echo
            echo "    http://localhost:$port/vnc_lite.html"
            exit 0
        fi
        running || { echo; echo "$name exited; last output:" >&2; container logs "$name" 2>&1 | tail -20 >&2; exit 1; }
        i=$((i + 1))
        printf .
        sleep 10
    done
    echo
    echo "no noVNC after ten minutes — look at: $0 sh 'tail -40 /tmp/build.log'" >&2
    exit 1
    ;;

build)
    need_running
    fresh=${1:-}
    # llbuild caches the whole build description keyed on the manifest it was planned from, and a
    # path-dependency edit does not bump that key: the build "succeeds" in 0.1s having compiled
    # nothing new. After touching a Package.swift, pass `fresh`.
    if [ "$fresh" = "fresh" ]; then
        echo "==> dropping the cached build plan"
        container exec "$name" bash -lc "rm -f $scratch/build.db $core_scratch/build.db"
    fi
    container exec "$name" bash -lc "cd /work/six/linux && swift build -j 2 --scratch-path $scratch"
    ;;

test)
    need_running
    # The flag on every swift invocation, inside the container as much as outside — this is the
    # platform whose pins the resolved file is written for.
    container exec "$name" bash -lc \
        "cd /work/six && swift test --scratch-path $core_scratch --disable-automatic-resolution ${*:-}"
    ;;

core)
    # Proves SixCore still builds on Linux without building the GTK front at all — the only check
    # that catches Linux-only breakage, and the one to run before moving any dependency version.
    need_system
    echo "==> SixCore on Linux, in a plain toolchain image"
    container run --rm --memory 4g -v "$root:/work" -w /work docker.io/library/swift:6.3.3-noble \
        bash -c 'apt-get update -qq \
            && apt-get install -y -qq --no-install-recommends libsqlite3-dev >/dev/null \
            && swift build --disable-automatic-resolution --scratch-path /tmp/linuxbuild -j 2'
    ;;

shot)
    need_running
    out=${1:-linux.png}
    # A second display, so the live one on :99 is left alone. ImageMagick is in the image for this.
    echo "==> a picture on :98 (the app gets 16s to draw)"
    container exec "$name" bash -lc '
        set -u
        export XDG_DATA_HOME=/data-shot DISPLAY=:98 GDK_BACKEND=x11
        export SIX_URL="${SIX_URL:-https://example.com/ https://gnome.org/ https://gtk.org/}"
        rm -rf /data-shot
        pkill -f "Xvfb :98" 2>/dev/null || true
        sleep 1
        Xvfb :98 -screen 0 1400x880x24 & sleep 2
        /tmp/g/debug/six-linux > /tmp/shot.log 2>&1 & app=$!
        sleep 16
        import -window root /tmp/shot.png
        kill $app 2>/dev/null || true
        pkill -f "Xvfb :98" 2>/dev/null || true'
    container cp "$name:/tmp/shot.png" "$out"
    echo "    $out"
    ;;

logs)
    need_running
    container exec "$name" bash -lc 'tail -n ${SIX_TAIL:-40} /tmp/six.log'
    ;;

sh)
    need_running
    if [ $# -gt 0 ]; then
        container exec "$name" bash -lc "$*"
    else
        container exec -i -t "$name" bash -l
    fi
    ;;

down)
    container rm -f "$name" >/dev/null 2>&1 || true
    echo "removed $name"
    ;;

help | -h | --help)
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
    ;;

*)
    echo "unknown command: $cmd (try: $0 help)" >&2
    exit 1
    ;;

esac
