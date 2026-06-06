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

# --- Optional: active-install heartbeat from the Cloudflare appcast counter ---
# Reads the aggregate (day, country, hits) table in D1 via the Cloudflare API
# and folds the trailing-7-day update-check volume into the summary. Stays blank
# unless CF_API_TOKEN / CF_ACCOUNT_ID / CF_D1_DATABASE_ID are all set, so the
# download metrics keep working with no Cloudflare setup at all.
update_checks_7d=""
active_installs_est=""
if [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ACCOUNT_ID:-}" && -n "${CF_D1_DATABASE_ID:-}" ]]; then
    cf_sql="SELECT COALESCE(SUM(hits),0) AS hits FROM appcast_hits WHERE day >= date('now','-7 day')"
    cf_resp="$(curl -fsS \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database/${CF_D1_DATABASE_ID}/query" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$(jq -nc --arg sql "$cf_sql" '{sql: $sql}')" 2>/dev/null || true)"
    hits="$(jq -r '.result[0].results[0].hits // empty' <<<"${cf_resp:-}" 2>/dev/null || true)"
    if [[ "$hits" =~ ^[0-9]+$ ]]; then
        update_checks_7d="$hits"
        active_installs_est="$(( (hits + 3) / 7 ))" # rounded daily average
    else
        echo "==> Cloudflare heartbeat query returned no usable count; leaving it blank" >&2
    fi
fi

[[ -f "$SUMMARY" ]] || echo 'snapshot_date,total_downloads,new_install_downloads,update_downloads,latest_tag,latest_new_install_downloads,update_checks_7d,active_installs_est' > "$SUMMARY"
echo "$DATE,$total,$new_installs,$updates,$latest_tag,$latest_new_installs,$update_checks_7d,$active_installs_est" >> "$SUMMARY"

echo "==> $DATE: $total total downloads ($new_installs new installs, $updates updates); latest $latest_tag at $latest_new_installs; update checks (7d): ${update_checks_7d:-n/a}"
