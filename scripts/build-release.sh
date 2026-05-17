#!/usr/bin/env bash
# Generate the Xcode project and produce a Release build of Klang.app at
# build/export/Klang.app. Runs in two modes:
#
#   SIGNED   : DEVELOPMENT_TEAM env var set, certificate present in the
#              login keychain. Archives + exports a Developer ID signed app.
#   DRY RUN  : DEVELOPMENT_TEAM unset. Archives with an ad-hoc identity and
#              copies the app out of the archive. Output is not Gatekeeper-
#              acceptable; useful for landing-page + DMG-layout testing only.
set -euo pipefail

cd "$(dirname "$0")/.."

: "${SPARKLE_PUBLIC_ED_KEY:=}"

echo "==> xcodegen generate"
xcodegen generate

rm -rf build/Klang.xcarchive build/export

ARCHIVE_PATH="build/Klang.xcarchive"

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "==> archiving (Developer ID, team $DEVELOPMENT_TEAM)"
    BUILD_NUMBER="${CURRENT_PROJECT_VERSION:-$(date +%s)}"

    xcodebuild \
        -project Klang.xcodeproj \
        -scheme Klang \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -archivePath "$ARCHIVE_PATH" \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
        archive

    echo "==> exporting Developer ID app"
    cp ExportOptions.plist build/ExportOptions.plist
    /usr/libexec/PlistBuddy -c "Set :teamID $DEVELOPMENT_TEAM" build/ExportOptions.plist

    xcodebuild \
        -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist build/ExportOptions.plist \
        -exportPath build/export
else
    echo "==> archiving (ad-hoc, DRY RUN — output is not signed)"
    BUILD_NUMBER="${CURRENT_PROJECT_VERSION:-$(date +%s)}"

    xcodebuild \
        -project Klang.xcodeproj \
        -scheme Klang \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=YES \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
        archive

    mkdir -p build/export
    cp -R "$ARCHIVE_PATH/Products/Applications/Klang.app" build/export/Klang.app
fi

APP=build/export/Klang.app
if [[ ! -d "$APP" ]]; then
    echo "Build succeeded but $APP not found" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "==> built $APP (version $VERSION)"
