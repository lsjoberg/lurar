#!/usr/bin/env bash
# Build a DMG from build/export/Klang.app. Writes:
#   build/Klang.dmg           — stable name, what the landing page links to
#   build/Klang-$VERSION.dmg  — versioned, what Sparkle appcast enclosures point at
#
# Requires: brew install create-dmg
set -euo pipefail

cd "$(dirname "$0")/.."

APP=build/export/Klang.app
if [[ ! -d "$APP" ]]; then
    echo "Missing $APP. Run scripts/build-release.sh first." >&2
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg not found. Install with: brew install create-dmg" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

rm -f build/Klang.dmg "build/Klang-${VERSION}.dmg"

echo "==> creating DMG (version $VERSION)"
create-dmg \
    --volname "Klang $VERSION" \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "Klang.app" 140 180 \
    --app-drop-link 400 180 \
    --no-internet-enable \
    "build/Klang.dmg" \
    "$APP"

cp "build/Klang.dmg" "build/Klang-${VERSION}.dmg"

echo "==> wrote build/Klang.dmg and build/Klang-${VERSION}.dmg"
