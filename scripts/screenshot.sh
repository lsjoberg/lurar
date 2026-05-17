#!/usr/bin/env bash
# Capture screenshots for the docs landing page with the right flags for
# transparent rounded corners (no shadow bleed, no wallpaper leak).
#
# Usage:
#   scripts/screenshot.sh <name>            # window capture (default)
#   scripts/screenshot.sh <name> window     # same as above
#   scripts/screenshot.sh <name> region     # rectangular region capture
#   scripts/screenshot.sh <name> bar        # menu bar strip (interactive region)
#   scripts/screenshot.sh prep              # one-time prep (dock, wallpaper hints)
#   scripts/screenshot.sh list              # show suggested shot names + status
#
# Output: docs/screenshots/<name>.png
#
# Why these flags
# ---------------
# `-o` strips the system drop shadow. Without `-o`, macOS bakes a soft
# shadow into the PNG AND into the alpha around the window's rounded
# corners — that's where wallpaper bleed comes from when the page
# background doesn't match the desktop. With `-o`, the corners are
# clean transparent alpha that the page can composite cleanly onto any
# background. The CSS in docs/style.css adds the shadow back via
# `filter: drop-shadow(...)`, which respects the alpha channel.
#
# `-w` enters interactive window-pick mode. Move the cursor over the
# Klang window you want to capture and click. For popovers (menu bar
# preset picker, etc.), click directly on the popover surface.
#
# `-i` (interactive region) is used by `region` and `bar` modes — drag
# a rectangle.
#
# Naming convention
# -----------------
# Names below match the <img src="screenshots/..."> paths in
# docs/index.html. Capture both light and dark variants for the big
# four; dark gets a `-dark` suffix (e.g. menu-bar-dark.png).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/docs/screenshots"

# Suggested shots referenced from docs/index.html. Add light/dark variants
# (e.g. menu-bar + menu-bar-dark) for the four primary ones.
SHOTS=(
  "menu-bar               # hero — menu bar popover, engine ON, preset loaded"
  "editor                 # EQ editor with curve, bands, spectrum, clip meter"
  "preset-library         # AutoEq catalog browser, search populated"
  "ab-blind               # A/B compare in blind mode with trial counter"
  "ab-sighted             # A/B compare in sighted mode, both curves overlaid"
  "auto-detect            # auto-detect banner suggesting a matching preset"
  "crossfeed-loudness     # crossfeed + loudness sliders zoomed"
  "excluded-apps          # Settings → Excluded Apps with 3–4 entries"
  "sync                   # Settings → Sync with iCloud toggle on"
  "onboarding             # first-run TCC permission window"
  "bypass                 # editor showing bypass active"
  "og                     # 1200×630 social card (use 'region' mode)"
)

usage() {
  sed -n '2,/^set -euo/{/^set -euo/!p;}' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

ensure_macos() {
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "screenshot.sh: this script only works on macOS." >&2
    exit 1
  fi
}

ensure_klang_running() {
  if ! pgrep -x Klang >/dev/null; then
    echo "warning: Klang doesn't seem to be running. Launch it first:"
    echo "  ./scripts/dev.sh"
    echo
  fi
}

capture_window() {
  local out="$1"
  echo "Click the Klang window or popover you want to capture..."
  screencapture -o -w "$out"
}

capture_region() {
  local out="$1"
  echo "Drag a rectangle to capture..."
  screencapture -o -i "$out"
}

capture_bar() {
  local out="$1"
  echo "Drag a rectangle across the menu bar area..."
  # `-i` is interactive region; for the menu bar strip you draw the rect
  # yourself. -o is still applied even though there's no window shadow,
  # which is harmless.
  screencapture -o -i "$out"
}

print_result() {
  local out="$1"
  if [[ ! -f "$out" ]]; then
    echo "Cancelled — no file written." >&2
    return 1
  fi
  local size dims
  size=$(stat -f '%z' "$out" 2>/dev/null || stat -c '%s' "$out")
  if command -v sips >/dev/null; then
    dims=$(sips -g pixelWidth -g pixelHeight "$out" 2>/dev/null \
           | awk '/pixelWidth/  {w=$2} /pixelHeight/ {h=$2} END {print w"×"h}')
  else
    dims="?"
  fi
  echo
  echo "  Saved: ${out#$REPO_ROOT/}"
  echo "  Size:  $((size / 1024)) KB"
  echo "  Dims:  $dims"
  echo
  echo "Drop this into docs/index.html by swapping the corresponding"
  echo "placeholder.svg <img src> reference."
}

cmd_prep() {
  cat <<'TIPS'
One-time setup tips (do these once, then capture freely):

  1. Quit unnecessary apps. Close any browser tabs that might flash through.

  2. Set Desktop to a solid color so any future viewer that ignores alpha
     gets a clean fringe:
       System Settings → Wallpaper → Color → pick a neutral.
     Dark wallpaper for dark shots, light for light. The CSS handles
     shadows, so you don't need the desktop in the shot.

  3. Auto-hide the Dock for the duration of a capture session:
       defaults write com.apple.dock autohide -bool true && killall Dock
     Restore later with:
       defaults write com.apple.dock autohide -bool false && killall Dock

  4. Hide noisy menu bar extras (Wi-Fi, Battery, Bluetooth, Control Center)
     via System Settings → Control Center, so the menu bar shot is just
     Klang and the system clock.

  5. Capture on a Retina display — `screencapture` records the native 2x
     pixel buffer automatically. Don't downscale before committing.

  6. Re-run a capture you don't like — `screencapture` overwrites without
     prompting.

  7. For dark-mode variants: switch the system to dark via
        osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to true'
     ...capture...then flip back.
TIPS
}

cmd_list() {
  echo "Suggested shots (referenced from docs/index.html):"
  echo
  for entry in "${SHOTS[@]}"; do
    local name="${entry%% *}"
    local desc="${entry#*#}"
    local path="$OUT_DIR/$name.png"
    if [[ -f "$path" ]]; then
      printf "  ✓ %-22s%s\n" "$name" "$desc"
    else
      printf "    %-22s%s\n" "$name" "$desc"
    fi
  done
  echo
  echo "Capture with: scripts/screenshot.sh <name>"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    ""|-h|--help|help) usage 0 ;;
    prep)              cmd_prep; exit 0 ;;
    list)              cmd_list; exit 0 ;;
  esac

  ensure_macos

  local name="$1"
  local mode="${2:-window}"

  if [[ "$name" =~ [^A-Za-z0-9._-] ]]; then
    echo "screenshot.sh: name must be alphanumeric (plus . _ -), got '$name'" >&2
    exit 2
  fi

  mkdir -p "$OUT_DIR"
  local out="$OUT_DIR/$name.png"

  ensure_klang_running

  case "$mode" in
    window) capture_window "$out" ;;
    region) capture_region "$out" ;;
    bar)    capture_bar    "$out" ;;
    *)      echo "unknown mode: $mode (use window | region | bar)" >&2; exit 2 ;;
  esac

  print_result "$out"
}

main "$@"
