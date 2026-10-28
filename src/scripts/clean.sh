#!/bin/bash
# Clears build leftovers, temp files and caches of the OverPass suite on this Mac.
#   clean.sh            what can always go: old test scratch folders, Wine's leftover temp links, packaging
#                       stages, older Wine tarballs, prototype build folders, old logs; trims ccache
#   clean.sh --deep     also the build trees (the next Wine, runtime and app builds start from scratch;
#                       ccache keeps them fast) and Homebrew's download cache
#   clean.sh --dry-run  only lists what would go
#   --after-build       for a build script calling this as it finishes (skips the "build running" check)
# Run by overpass-wine's build.sh and this repo's build-app.sh when they finish; safe to run any time
# while no build is running.
set -uo pipefail

DEEP=0 DRY=0 AFTER_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --deep) DEEP=1 ;;
        --dry-run) DRY=1 ;;
        --after-build) AFTER_BUILD=1 ;;
        *) echo "usage: clean.sh [--deep] [--dry-run] [--after-build]" >&2; exit 2 ;;
    esac
done

DEV="$HOME/Dev"
WINE_DIR="$DEV/OverPass-wine"
RUNTIME_DIR="$DEV/OverPass-runtime"
APP_DIR="$DEV/OverPass/src"
before=$(df -k "$HOME" | awk 'NR==2 {print $4}')

remove() {
    for path in "$@"; do
        [ -e "$path" ] || continue
        echo "  $(du -sh "$path" 2>/dev/null | cut -f1)	${path/#$HOME/~}"
        [ $DRY = 1 ] || rm -rf "$path"
    done
}

building() { pgrep -f "overpass/build.sh|build-app.sh|meson compile|ninja -C" >/dev/null; }
# A build matching the pattern other than the one that called this script (a build calling with --after-build is
# one of our ancestors). Another build still needs its own folders: build-app.sh finishing once removed a Wine
# build's stage while it was being packaged.
building_elsewhere() {
    local ancestors=" " pid=$$
    while [ "$pid" -gt 1 ]; do ancestors+="$pid "; pid=$(ps -o ppid= -p "$pid" | tr -d ' '); done
    for p in $(pgrep -f "$1"); do [[ "$ancestors" == *" $p "* ]] || return 0; done
    return 1
}
if [ $AFTER_BUILD = 0 ] && building && [ $DRY = 0 ]; then
    echo "clean.sh: a build is running; try again when it's done." >&2
    exit 1
fi

echo "Test scratch folders not touched for 12 hours:"
for dir in /private/tmp/claude-"$(id -u)"/*OverPass*/*/; do
    [ -d "$dir" ] && [ -z "$(find "$dir" -maxdepth 2 -mmin -720 -print -quit 2>/dev/null)" ] && remove "${dir%/}"
done

# Wine's loader links (CW Hack 22144) live in winetemp-* folders; Wine leaves them behind.
if ! pgrep -x wineserver >/dev/null; then
    echo "Wine temp folders (no Wine running):"
    remove "${TMPDIR:-/tmp}"/winetemp-*
fi

if building_elsewhere "overpass/build.sh|build-dxvk.sh|build-gstreamer.sh|build-deps.sh"; then
    echo "OverPass Wine: a build is running, left alone."
else
echo "OverPass Wine:"
# Prototypes from before build-deps.sh and build-gstreamer.sh took over.
remove "$WINE_DIR"/deps-test "$WINE_DIR"/gst-work "$WINE_DIR"/gst-prefix "$WINE_DIR"/inotify-work \
       "$WINE_DIR"/deps-test.log "$WINE_DIR"/dl/wine-11.0
# The packaged tarball holds everything the stage did.
remove "$WINE_DIR"/main/build-overpass/stage
# Only the newest tarball; released ones are on GitHub.
ls -t "$WINE_DIR"/main/overpass-wine-*-x86_64.tar.xz 2>/dev/null | tail -n +2 | while read -r f; do remove "$f"; done
ls -t "$WINE_DIR"/build-*.log 2>/dev/null | tail -n +3 | while read -r f; do remove "$f"; done
fi

echo "OverPass Runtime:"
remove "$RUNTIME_DIR"/install-debug
ls -t "$RUNTIME_DIR"/dist/*.tar.xz 2>/dev/null | tail -n +2 | while read -r f; do remove "$f" "$f.sha256"; done

if [ $DEEP = 1 ]; then
    echo "Build trees (--deep):"
    remove "$WINE_DIR"/main/build-overpass "$RUNTIME_DIR"/build "$APP_DIR"/.build "$APP_DIR"/build
    if command -v brew >/dev/null; then
        echo "  Homebrew cache"
        [ $DRY = 1 ] || brew cleanup -s >/dev/null 2>&1
    fi
fi

if command -v ccache >/dev/null && [ $DRY = 0 ]; then
    # Keeps what recent builds used, within ccache's size limit.
    ccache --evict-older-than 30d >/dev/null 2>&1
    ccache -c >/dev/null 2>&1
fi

after=$(df -k "$HOME" | awk 'NR==2 {print $4}')
[ $DRY = 1 ] || echo "Freed $(( (after - before) / 1024 )) MB; $(df -h "$HOME" | awk 'NR==2 {print $4}') free."
