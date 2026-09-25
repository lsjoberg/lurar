# Metrics

Privacy-friendly popularity tracking for Lurar. **No user tracking** — this
reads only GitHub's own server-side aggregate counters (how many times each
release DMG has been downloaded). Nothing runs on a user's machine and no
personal data is collected. A "download" is the closest privacy-clean proxy for
an install.

## How it works

`scripts/collect-metrics.sh` queries the GitHub API for every release and its
DMG download counts. The [`Metrics snapshot`](../.github/workflows/metrics.yml)
workflow runs it **weekly** (and on demand) and appends the numbers to CSV files
on a dedicated **`metrics` branch**.

The data lives on its own branch — not `main` — so it stays decoupled from the
release pipeline and never triggers CI, Pages, or release-please.

- **Summary (at a glance):** <https://github.com/lsjoberg/lurar/blob/metrics/summary.csv>
- **Full detail (per asset):** <https://github.com/lsjoberg/lurar/blob/metrics/downloads.csv>

## Reading the numbers

Each release ships two DMGs that mean different things:

| Asset | Linked from | Proxy for |
| --- | --- | --- |
| `Lurar.dmg` | the website download button | **new installs** |
| `Lurar-X.Y.Z.dmg` | the Sparkle appcast | **auto-updates** |

`summary.csv` columns:

| Column | Meaning |
| --- | --- |
| `snapshot_date` | UTC date the snapshot was taken |
| `total_downloads` | all DMG downloads, all releases (running total) |
| `new_install_downloads` | sum of the stable `Lurar.dmg` / `Klang.dmg` assets |
| `update_downloads` | sum of the versioned DMGs (Sparkle updates + direct grabs) |
| `latest_tag` | the current latest release |
| `latest_new_install_downloads` | new-install downloads of the latest release so far |
| `update_checks_7d` | appcast hits in the trailing 7 days (active-install heartbeat) |
| `active_installs_est` | `update_checks_7d / 7` — rough daily-active installs |

The last two columns are **optional** and come from the Cloudflare appcast
counter (see below). They stay blank until it's deployed and the secrets are
set — download metrics work fine without them.

GitHub stores only the cumulative total, so the **trend** is the week-over-week
*difference* between rows. Open either CSV in Sheets/Excel and chart
`new_install_downloads` over `snapshot_date` to see adoption over time. Because
the snapshot runs weekly, `update_checks_7d` is already a clean per-week
active-use figure — chart it directly.

## Folding in the active-install heartbeat (optional)

To populate `update_checks_7d` / `active_installs_est`, deploy the
[appcast counter](../cloudflare/appcast-counter/README.md), then add three repo
secrets (Settings → Secrets and variables → Actions) so the workflow can read
the aggregate counts from D1:

| Secret | Where it comes from |
| --- | --- |
| `CF_API_TOKEN` | A Cloudflare API token scoped to **Account › D1** for your account only. Use Read if the query endpoint accepts it; Cloudflare may require Edit since the D1 query API runs SQL. Revoke/rotate anytime. |
| `CF_ACCOUNT_ID` | `npx wrangler whoami`, or the Cloudflare dashboard URL. |
| `CF_D1_DATABASE_ID` | The `database_id` from `wrangler d1 create` (same value as in `wrangler.toml`). |

The query is a read-only `SELECT SUM(hits)` over the last 7 days — no per-user
data leaves Cloudflare, and if the call fails the columns just stay blank.

## Caveats

A download is not the same as an install or an active user: people download on
more than one Mac, crawlers and mirrors hit release URLs, and GitHub does not
deduplicate. Read the numbers as order-of-magnitude trends, not exact headcounts.

For an *active-install* signal (who kept the app and still runs it), see the
Cloudflare appcast heartbeat in [`cloudflare/appcast-counter/`](../cloudflare/appcast-counter/README.md).
Together they form a privacy-clean funnel: site visits → new installs (here) →
active installs (the heartbeat).

## Running it manually

Actions → **Metrics snapshot** → **Run workflow**. The first run creates the
`metrics` branch and the initial data point.

You can also run it locally (requires the [`gh`](https://cli.github.com) CLI,
authenticated):

```bash
OUT_DIR=metrics ./scripts/collect-metrics.sh
```
