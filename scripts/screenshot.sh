#!/usr/bin/env bash
# Capture screenshots for the docs landing page with the right flags for
# transparent rounded corners (no shadow bleed, no wallpaper leak).
#
# Usage:
#   scripts/screenshot.sh <name>                       # window capture (default)
#   scripts/screenshot.sh <name> window                # same as above
#   scripts/screenshot.sh <name> region                # rectangular region capture
#   scripts/screenshot.sh <name> bar                   # menu bar strip (interactive region)
#   scripts/screenshot.sh <name> <mode> --delay <sec>  # wait N s before capture starts
#   scripts/screenshot.sh prep                         # one-time prep (dock, wallpaper hints)
#   scripts/screenshot.sh list                         # show suggested shot names + status
#
# Use --delay for focus-fragile UI (NSPopover-style surfaces like the menu bar
# popover or the auto-detect banner). Without it, switching focus to Terminal
# to run this script dismisses the popover, and running it first means the
# camera cursor eats the click you'd use to open the popover. With e.g.
# `--delay 5`, you get 5 s to open the popover; window-pick activates after.
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
# Lurar window you want to capture and click. For popovers (menu bar
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

ensure_lurar_running() {
  if ! pgrep -x Lurar >/dev/null; then
    echo "warning: Lurar doesn't seem to be running. Launch it first:"
    echo "  ./scripts/dev.sh"
    echo
  fi
}

DELAY=0

# screencapture's own -T flag is ignored when combined with -w/-i (interactive
# modes), so we implement the delay ourselves with a countdown sleep before
# kicking off the interactive capture.
wait_for_delay() {
  local label="$1"
  if (( DELAY <= 0 )); then return; fi
  echo "$label"
  local i
  for (( i = DELAY; i > 0; i-- )); do
    printf '  %ds...\r' "$i"
    sleep 1
  done
  printf '  go!     \n'
}

capture_window() {
  local out="$1"
  wait_for_delay "Capture in ${DELAY}s — open the popover/window now."
  if (( DELAY <= 0 )); then
    echo "Click the Lurar window or popover you want to capture..."
  fi
  screencapture -o -w "$out"
}

capture_region() {
  local out="$1"
  wait_for_delay "Capture in ${DELAY}s — get the screen ready, then drag a rectangle."
  if (( DELAY <= 0 )); then
    echo "Drag a rectangle to capture..."
  fi
  screencapture -o -i "$out"
}

capture_bar() {
  local out="$1"
  wait_for_delay "Capture in ${DELAY}s — then drag across the menu bar area."
  if (( DELAY <= 0 )); then
    echo "Drag a rectangle across the menu bar area..."
  fi
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

  2. Turn on Reduce Transparency so vibrancy surfaces (menu bar popover,
     Settings panes, sidebars) render as opaque solid colors instead of
     leaking the wallpaper tint through. Without this, light-mode popovers
     captured over a gray desktop come out looking muddy/dimmed.
       defaults write com.apple.universalaccess reduceTransparency -bool true
     Or via UI: System Settings → Accessibility → Display → Reduce transparency.
     Restore later with:
       defaults write com.apple.universalaccess reduceTransparency -bool false

  3. Set Desktop to a solid color so any future viewer that ignores alpha
     gets a clean fringe:
       System Settings → Wallpaper → Color → pick a neutral.
     Dark wallpaper for dark shots, light for light. The CSS handles
     shadows, so you don't need the desktop in the shot.

  4. Auto-hide the Dock for the duration of a capture session:
       defaults write com.apple.dock autohide -bool true && killall Dock
     Restore later with:
       defaults write com.apple.dock autohide -bool false && killall Dock

  5. Hide noisy menu bar extras (Wi-Fi, Battery, Bluetooth, Control Center)
     via System Settings → Control Center, so the menu bar shot is just
     Lurar and the system clock.

  6. Capture on a Retina display — `screencapture` records the native 2x
     pixel buffer automatically. Don't downscale before committing.

  7. Re-run a capture you don't like — `screencapture` overwrites without
     prompting.

  8. For dark-mode variants: switch the system to dark via
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

  local name="$1"; shift
  local mode="window"
  if [[ $# -gt 0 && "$1" != --* ]]; then
    mode="$1"; shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delay)
        [[ $# -ge 2 ]] || { echo "--delay requires a number of seconds" >&2; exit 2; }
        DELAY="$2"; shift 2
        ;;
      --delay=*)
        DELAY="${1#*=}"; shift
        ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
  done

  if ! [[ "$DELAY" =~ ^[0-9]+$ ]]; then
    echo "--delay must be a non-negative integer, got '$DELAY'" >&2
    exit 2
  fi

  if [[ "$name" =~ [^A-Za-z0-9._-] ]]; then
    echo "screenshot.sh: name must be alphanumeric (plus . _ -), got '$name'" >&2
    exit 2
  fi

  mkdir -p "$OUT_DIR"
  local out="$OUT_DIR/$name.png"

  ensure_lurar_running

  case "$mode" in
    window) capture_window "$out" ;;
    region) capture_region "$out" ;;
    bar)    capture_bar    "$out" ;;
    *)      echo "unknown mode: $mode (use window | region | bar)" >&2; exit 2 ;;
  esac

  print_result "$out"
}

main "$@"
