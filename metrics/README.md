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

GitHub stores only the cumulative total, so the **trend** is the week-over-week
*difference* between rows. Open either CSV in Sheets/Excel and chart
`new_install_downloads` over `snapshot_date` to see adoption over time.

## Caveats

A download is not the same as an install or an active user: people download on
more than one Mac, crawlers and mirrors hit release URLs, and GitHub does not
deduplicate. Read the numbers as order-of-magnitude trends, not exact headcounts.

## Running it manually

Actions → **Metrics snapshot** → **Run workflow**. The first run creates the
`metrics` branch and the initial data point.

You can also run it locally (requires the [`gh`](https://cli.github.com) CLI,
authenticated):

```bash
OUT_DIR=metrics ./scripts/collect-metrics.sh
```
