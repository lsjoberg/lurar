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

APP=build/export/Lurar.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$APP/Contents/Info.plist")
DMG="build/Lurar-${VERSION}.dmg"

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

REPO_SLUG="${GITHUB_REPOSITORY:-lsjoberg/lurar}"
URL="https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/Lurar-${VERSION}.dmg"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-https://github.com/${REPO_SLUG}/releases/tag/v${VERSION}}"
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

# Pull this version's section out of CHANGELOG.md and render it to HTML so
# Sparkle can show it inline in the update dialog. Previously the appcast
# pointed Sparkle at the GitHub release page via <sparkle:releaseNotesLink>
# and the dialog rendered the entire GitHub UI chrome inside itself.
NOTES_MD=""
if [[ -f CHANGELOG.md ]]; then
    NOTES_MD=$(awk -v ver="$VERSION" '
        /^## \[/ {
            if (started) exit
            if (index($0, "## [" ver "]") == 1) { started = 1; next }
        }
        started { print }
    ' CHANGELOG.md)
fi

if [[ -n "$NOTES_MD" ]] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo "==> rendering CHANGELOG section for v${VERSION} via gh api /markdown"
    NOTES_BODY=$(gh api /markdown \
        --method POST \
        --raw-field "text=${NOTES_MD}" \
        --raw-field "mode=gfm" \
        --raw-field "context=${REPO_SLUG}")
elif [[ -n "$NOTES_MD" ]]; then
    echo "==> gh not available, falling back to <pre> rendering"
    NOTES_BODY="<pre>$(printf '%s' "$NOTES_MD" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>"
else
    echo "==> no CHANGELOG entry for v${VERSION}, linking out to GitHub"
    NOTES_BODY="<p>See the <a href=\"${RELEASE_NOTES_URL}\">release on GitHub</a> for details.</p>"
fi

NOTES_HTML="${NOTES_BODY}<p style=\"margin-top:1.5em;font-size:0.9em\"><a href=\"${RELEASE_NOTES_URL}\">View full release on GitHub →</a></p>"

export VERSION BUILD MIN_OS URL PUBDATE ED_SIG LENGTH NOTES_HTML

echo "==> rendering docs/appcast.xml for v${VERSION}"
envsubst '${VERSION} ${BUILD} ${MIN_OS} ${URL} ${PUBDATE} ${ED_SIG} ${LENGTH} ${NOTES_HTML}' \
    < docs/appcast.xml.template > docs/appcast.xml

echo "==> wrote docs/appcast.xml"
