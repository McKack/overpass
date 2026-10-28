#!/bin/bash
# Builds OverPass, zips it and publishes it as a GitHub release, which the app's update check finds.
#   release.sh <version> [notes file]
# Publishes to McKack/overpass as overpass-<version>.zip. The lowercase name matters: OverPass 0.3.0 and older
# look for "OverPass…zip" and can't take the new bundle ID, so they skip this repo and update to 0.3.2 in
# McKack/overpass-releases instead (see AppUpdate.swift). Set OVERPASS_RELEASE_REPO to publish elsewhere.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$1
NOTES=${2:-}
REPO=${OVERPASS_RELEASE_REPO:-McKack/overpass}
BUILD=$(git rev-list --count HEAD)

[ -z "$(git status --porcelain -- .)" ] || { echo "Commit your changes first." >&2; exit 1; }
[ -z "$NOTES" ] || [ -f "$NOTES" ] || { echo "No notes file at $NOTES" >&2; exit 1; }

# A run that stopped after tagging (say, at the upload) picks up from the upload.
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && [ -f "build/overpass-$VERSION.zip" ]; then
    RESUME=1
fi

if [ -z "${RESUME:-}" ]; then
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Support/Info.plist
scripts/build-app.sh

ZIP=build/overpass-$VERSION.zip
rm -f "$ZIP"
ditto -c -k --keepParent build/OverPass.app "$ZIP"

if [ -n "$(git status --porcelain -- Support/Info.plist)" ]; then
    git commit -q -m "OverPass $VERSION" -- Support/Info.plist
fi
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
fi
ZIP=build/overpass-$VERSION.zip

ARGS=(--repo "$REPO" --title "OverPass $VERSION")
if [ -n "$NOTES" ]; then ARGS+=(--notes-file "$NOTES"); else ARGS+=(--notes "OverPass $VERSION"); fi
gh release create "v$VERSION" "$ZIP" "${ARGS[@]}"
echo "Released OverPass $VERSION (build $BUILD) to $REPO"
