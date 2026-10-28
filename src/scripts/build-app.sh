#!/bin/bash
# Builds OverPass.app into build/ (release, ad-hoc signed) and installs it in /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=build/OverPass.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/OverPass" "$APP/Contents/MacOS/OverPass"
# SwiftPM resource bundle (profiles); Bundle.module looks for it in Contents/Resources.
cp -R "$BIN/OverPass_OverPass.bundle" "$APP/Contents/Resources/"
# The Credits window shows the repository's CREDITS.md.
cp ../CREDITS.md "$APP/Contents/Resources/CREDITS.md"
# Signed with the project's own certificate ("OverPass", self-signed, in the login keychain) when it's there:
# macOS ties privacy permissions (Screen Recording, Desktop and Documents) to that certificate, so they last
# across builds and updates. Without it the build is signed ad hoc and loses them on every build.
IDENTITY="${OVERPASS_SIGNING_IDENTITY:-OverPass}"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --deep -s "$IDENTITY" "$APP"
else
    echo "build-app.sh: no \"$IDENTITY\" signing certificate, signing ad hoc" >&2
    codesign --force --deep -s - "$APP"
fi
echo "Built $APP"

# Install the build in /Applications (OVERPASS_NO_INSTALL=1 skips it); quits a running copy first.
if [ -z "${OVERPASS_NO_INSTALL:-}" ]; then
    osascript -e 'tell application id "'"$(defaults read "$PWD/$APP/Contents/Info" CFBundleIdentifier)"'" to quit' 2>/dev/null || true
    rm -rf /Applications/OverPass.app
    ditto "$APP" /Applications/OverPass.app
    echo "Installed /Applications/OverPass.app"
fi

# Old test scratch folders, Wine temp links and other leftovers (OVERPASS_NO_CLEAN=1 skips it).
if [ -z "${OVERPASS_NO_CLEAN:-}" ]; then scripts/clean.sh --after-build >/dev/null || true; fi
