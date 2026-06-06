# Appcast counter (active-install heartbeat)

A tiny Cloudflare Worker on the `lurar.app/appcast.xml` route that counts how
many update checks happen per day. Every running copy of Lurar fetches the
appcast (~once a day, Sparkle's default), so this is a relative trend for how
many installs are **alive and still in use** — the retention signal that
GitHub's one-time download counts can't show.

## Privacy

- **No IPs, cookies, identifiers, or fingerprints** are ever stored.
- The only data recorded is an aggregate row of `(UTC date, 2-letter country, count)`.
- Requests are **deliberately not deduplicated per user** — that would require
  storing an identifier. Treat the numbers as a relative trend, not an exact
  headcount.
- Drop the `country` column entirely if you want only `(date, count)` — see
  `schema.sql` and `src/worker.js`.

## Reliability

The counter is **fail-open**. The appcast is always served unchanged from
origin (GitHub Pages); the tally runs out of band via `ctx.waitUntil` and is
wrapped so it can never throw into the response path. If the database is unbound
or a write fails, the update check still succeeds. Counting can never break
update delivery — which matters, because this URL must keep serving forever.

## Prerequisite

The `lurar.app` DNS record must be **proxied (orange cloud)**, not DNS-only, or
the route never runs. SSL/TLS mode should be **Full**.

## Deploy

```bash
cd cloudflare/appcast-counter
npm install                       # or: npm i -D wrangler@latest
npx wrangler login

# 1. Create the D1 database, then paste the printed id into wrangler.toml
npx wrangler d1 create lurar-metrics

# 2. Create the table
npm run db:init

# 3. Ship it
npm run deploy
```

Verify it's live and still serving the real appcast:

```bash
curl -s https://lurar.app/appcast.xml | head        # unchanged XML
npx wrangler tail                                    # watch live invocations
```

## Read the trend

```bash
npm run stats           # daily totals, last 30 days
npm run stats:country   # per-country breakdown
```

Or browse the table in the Cloudflare dashboard → Workers & Pages → D1 →
`lurar-metrics`. Export to CSV and chart `hits` over `day` for the active-use
trend.

To roll this into the weekly download CSVs automatically (an `update_checks_7d`
column in `summary.csv`), see
[`metrics/README.md`](../../metrics/README.md#folding-in-the-active-install-heartbeat-optional).

## How it fits the bigger picture

This completes a fully privacy-clean funnel, no user tracking anywhere:

- **visits** — Cloudflare zone analytics for `lurar.app`
- **new installs** — GitHub release download counts (`metrics/` + the weekly
  `Metrics snapshot` action)
- **active installs** — this Worker's `/appcast.xml` heartbeat
