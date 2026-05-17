#!/usr/bin/env bash
# Regenerate the Xcode project, build Lurar with ad-hoc signing, kill any
# running instance, and launch the fresh build. No Xcode UI required.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> xcodegen generate"
xcodegen generate

echo "==> killing any running Lurar"
pkill -x Lurar 2>/dev/null || true

echo "==> xcodebuild (Debug, ad-hoc signed)"
xcodebuild \
    -project Lurar.xcodeproj \
    -scheme Lurar \
    -configuration Debug \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    -quiet \
    build

APP=build/Build/Products/Debug/Lurar.app
if [[ ! -d "$APP" ]]; then
    echo "Build succeeded but $APP not found" >&2
    exit 1
fi

echo "==> launching $APP"
open "$APP"
echo "==> done"
