#!/usr/bin/env bash
# Submit build/Klang-$VERSION.dmg to Apple's notary service, wait for the
# verdict, and staple the ticket. Skips with exit 0 if APPLE_ID is unset
# (dry-run mode).
#
# Required env vars (signed mode):
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${APPLE_ID:-}" ]]; then
    echo "==> APPLE_ID unset, skipping notarization (dry run)"
    exit 0
fi

: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required when APPLE_ID is set}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required when APPLE_ID is set}"

APP=build/export/Klang.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Klang-${VERSION}.dmg"

if [[ ! -f "$DMG" ]]; then
    echo "Missing $DMG. Run scripts/make-dmg.sh first." >&2
    exit 1
fi

echo "==> notarytool submit $DMG"
xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait \
    --timeout 30m

echo "==> stapling ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# Re-copy the stapled DMG over the stable-named one so the landing-page
# download is also notarization-ratified.
cp "$DMG" build/Klang.dmg

echo "==> notarized + stapled $DMG"
