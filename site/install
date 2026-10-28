#!/bin/bash
# Installs the newest OverPass into /Applications and opens it.
#   curl -fsSL https://overpass.arctim.no/install | bash
# Downloaded this way the app isn't quarantined, so macOS opens it without the "can't be verified" prompt.
set -euo pipefail

ZIP_URL=""
for REPO in McKack/overpass McKack/overpass-releases; do
    ZIP_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | grep -o '"browser_download_url": *"[^"]*/[Oo]ver[Pp]ass-[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/') || true
    [ -n "$ZIP_URL" ] && break
done
[ -n "$ZIP_URL" ] || { echo "No OverPass release found." >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading $ZIP_URL"
curl -fL --progress-bar "$ZIP_URL" -o "$TMP/OverPass.zip"
ditto -x -k "$TMP/OverPass.zip" "$TMP"
[ -d "$TMP/OverPass.app" ] || { echo "The download doesn't contain OverPass.app." >&2; exit 1; }

osascript -e 'tell application "OverPass" to quit' >/dev/null 2>&1 || true
rm -rf /Applications/OverPass.app
ditto "$TMP/OverPass.app" /Applications/OverPass.app
echo "Installed /Applications/OverPass.app"
open /Applications/OverPass.app
