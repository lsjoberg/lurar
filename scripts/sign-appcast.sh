#!/usr/bin/env bash
# Sign the DMG with the Sparkle EdDSA private key and regenerate
# docs/appcast.xml from docs/appcast.xml.template.
#
# Required env vars (signed mode):
#   SPARKLE_ED_PRIVATE_KEY  — base64 EdDSA private key from `generate_keys`
#
# Optional:
#   RELEASE_NOTES_URL       — HTML URL for the release notes; defaults to
#                             the GitHub release page for this version.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    echo "==> SPARKLE_ED_PRIVATE_KEY unset, skipping appcast signing (dry run)"
    exit 0
fi

APP=build/export/Klang.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$APP/Contents/Info.plist")
DMG="build/Klang-${VERSION}.dmg"

if [[ ! -f "$DMG" ]]; then
    echo "Missing $DMG. Run scripts/make-dmg.sh first." >&2
    exit 1
fi

# Locate sign_update from the resolved Sparkle SPM checkout. Xcode caches
# this under DerivedData; mirror its layout for both local and CI runs.
SIGN_UPDATE=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
    -type f 2>/dev/null | head -n 1)

if [[ -z "$SIGN_UPDATE" ]]; then
    # Fall back to searching the local build's DerivedData (CI uses
    # -derivedDataPath build/, so SourcePackages lives there).
    SIGN_UPDATE=$(find build -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
        -type f 2>/dev/null | head -n 1)
fi

if [[ -z "$SIGN_UPDATE" ]]; then
    echo "Could not locate Sparkle's sign_update binary. Build first so SPM resolves Sparkle." >&2
    exit 1
fi

echo "==> using $SIGN_UPDATE"

KEYFILE=$(mktemp)
trap 'rm -f "$KEYFILE"' EXIT
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$KEYFILE"
chmod 600 "$KEYFILE"

# sign_update prints: sparkle:edSignature="..." length="..."
SIG_OUTPUT=$("$SIGN_UPDATE" -f "$KEYFILE" "$DMG")
ED_SIG=$(echo "$SIG_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(echo "$SIG_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')

if [[ -z "$ED_SIG" || -z "$LENGTH" ]]; then
    echo "Failed to parse sign_update output: $SIG_OUTPUT" >&2
    exit 1
fi

REPO_SLUG="${GITHUB_REPOSITORY:-lsjoberg/klang}"
URL="https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/Klang-${VERSION}.dmg"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-https://github.com/${REPO_SLUG}/releases/tag/v${VERSION}}"
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

export VERSION BUILD MIN_OS URL RELEASE_NOTES_URL PUBDATE ED_SIG LENGTH

echo "==> rendering docs/appcast.xml for v${VERSION}"
envsubst < docs/appcast.xml.template > docs/appcast.xml

echo "==> wrote docs/appcast.xml"
