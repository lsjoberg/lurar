#!/usr/bin/env bash
#
# Rasterize docs/branding/app-icon.svg into the ten PNGs that Xcode
# expects in AppIcon.appiconset, then let the next `./scripts/dev.sh`
# (or any Xcode build) compile them into Lurar.app/Contents/Resources/
# AppIcon.icns.
#
# Tries rasterizers in order of output quality:
#   1. rsvg-convert   (brew install librsvg)        — recommended
#   2. magick         (brew install imagemagick)
#   3. inkscape       (brew install --cask inkscape)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

SVG="${1:-docs/branding/app-icon.svg}"
OUT="${2:-Lurar/Resources/Assets.xcassets/AppIcon.appiconset}"

if [[ ! -f "$SVG" ]]; then
  echo "error: source SVG not found at $SVG" >&2
  exit 1
fi

if command -v rsvg-convert >/dev/null; then
  rasterize() { rsvg-convert -w "$1" -h "$1" "$SVG" -o "$2"; }
  TOOL="rsvg-convert"
elif command -v magick >/dev/null; then
  rasterize() { magick -background none -density 1024 "$SVG" -resize "${1}x${1}" "$2"; }
  TOOL="magick"
elif command -v convert >/dev/null; then
  rasterize() { convert -background none -density 1024 "$SVG" -resize "${1}x${1}" "$2"; }
  TOOL="convert"
elif command -v inkscape >/dev/null; then
  rasterize() { inkscape -w "$1" -h "$1" "$SVG" -o "$2" >/dev/null 2>&1; }
  TOOL="inkscape"
else
  cat >&2 <<'EOF'
error: no SVG rasterizer found. Install one of:
  brew install librsvg          (recommended — sharpest output)
  brew install imagemagick
  brew install --cask inkscape
EOF
  exit 1
fi

mkdir -p "$OUT"

# AppIcon.appiconset slots — every macOS size at @1x and @2x.
# Pixel sizes 32, 256, 512 each appear twice (16@2x ≡ 32@1x, etc.) and
# are exported twice on purpose: Xcode's asset compiler keys by filename.
SLOTS=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

echo "Rasterizing $SVG → $OUT  (via $TOOL)"
for slot in "${SLOTS[@]}"; do
  size="${slot%%:*}"
  file="${slot##*:}"
  rasterize "$size" "$OUT/$file"
  printf "  %-26s %4sx%-4s\n" "$file" "$size" "$size"
done

echo
echo "Done. Run ./scripts/dev.sh to build — the asset compiler will fold"
echo "these into AppIcon.icns and CFBundleIconName=AppIcon picks it up."
