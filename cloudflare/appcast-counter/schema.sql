-- Aggregate appcast hit counts. No per-user data: one row per (UTC day,
-- country), with a running total. See README.md for the privacy rationale.
CREATE TABLE IF NOT EXISTS appcast_hits (
  day     TEXT    NOT NULL,            -- UTC date, YYYY-MM-DD
  country TEXT    NOT NULL DEFAULT 'XX', -- 2-letter country (coarse, aggregate)
  hits    INTEGER NOT NULL DEFAULT 0,  -- request count for that day + country
  PRIMARY KEY (day, country)
);
