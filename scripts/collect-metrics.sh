#!/usr/bin/env bash
# Privacy-friendly popularity metrics for Lurar.
#
# Snapshots GitHub's own server-side aggregate counters — the download count
# of each release DMG — into CSV files so a trend accumulates over time.
#
# This collects NO user tracking of any kind: it reads only the totals GitHub
# already keeps for public release assets. Nothing runs on a user's machine and
# no personal data is touched. A "download" is the closest privacy-clean proxy
# for an install.
#
# Two assets ship per release and mean different things:
#   Lurar.dmg          (stable name, what the website button links to)  -> new installs
#   Lurar-X.Y.Z.dmg    (versioned, what the Sparkle appcast points at)  -> auto-updates
# (Pre-rename builds use Klang.dmg / Klang-X.Y.Z.dmg.)
#
# Env vars:
#   REPO     owner/name to read (default: lsjoberg/lurar)
#   OUT_DIR  directory to write/append the CSVs into (default: metrics)
#   GH_TOKEN consumed by the gh CLI for authentication
set -euo pipefail

REPO="${REPO:-lsjoberg/lurar}"
OUT_DIR="${OUT_DIR:-metrics}"
DATE="$(date -u +%Y-%m-%d)"

mkdir -p "$OUT_DIR"
DETAIL="$OUT_DIR/downloads.csv"
SUMMARY="$OUT_DIR/summary.csv"

# A stable (un-versioned) DMG name marks a "new install" download; anything
# else ending in .dmg is a versioned build that Sparkle pulls as an update.
STABLE='^(Lurar|Klang)\.dmg$'

# Pull every release plus its DMG assets in one paginated call.
releases="$(gh api --paginate "repos/$REPO/releases" \
    --jq '.[] | select(.draft | not) | {
            tag: .tag_name,
            prerelease: .prerelease,
            assets: [.assets[] | select(.name | endswith(".dmg"))
                     | {name: .name, downloads: .download_count}]
          }' | jq -s '.')"

# --- Detail: one row per asset per snapshot (the source of truth) ---
[[ -f "$DETAIL" ]] || echo 'snapshot_date,tag,asset,kind,downloads' > "$DETAIL"
jq -r --arg d "$DATE" --arg stable "$STABLE" '
    .[] | .tag as $t | .assets[] |
    [ $d, $t, .name,
      (if (.name | test($stable)) then "new_install" else "update" end),
      .downloads ] | @csv' <<<"$releases" >> "$DETAIL"

# --- Summary: one at-a-glance row per snapshot ---
read -r total new_installs updates < <(jq -r --arg stable "$STABLE" '
    [ .[].assets[] ] as $a
    | ([ $a[].downloads ] | add // 0) as $t
    | ([ $a[] | select(.name | test($stable)) | .downloads ] | add // 0) as $n
    | "\($t) \($n) \($t - $n)"' <<<"$releases")

latest_tag="$(jq -r 'first(.[] | select(.prerelease | not)) | .tag // "n/a"' <<<"$releases")"
latest_new_installs="$(jq -r --arg stable "$STABLE" '
    first(.[] | select(.prerelease | not))
    | [ .assets[]? | select(.name | test($stable)) | .downloads ] | add // 0' <<<"$releases")"

[[ -f "$SUMMARY" ]] || echo 'snapshot_date,total_downloads,new_install_downloads,update_downloads,latest_tag,latest_new_install_downloads' > "$SUMMARY"
echo "$DATE,$total,$new_installs,$updates,$latest_tag,$latest_new_installs" >> "$SUMMARY"

echo "==> $DATE: $total total downloads ($new_installs new installs, $updates updates); latest $latest_tag at $latest_new_installs"
