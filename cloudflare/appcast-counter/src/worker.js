// Lurar appcast hit counter — a privacy-friendly active-install heartbeat.
//
// This Worker sits on the lurar.app/appcast.xml route. Every running copy of
// Lurar fetches that URL to check for updates (~once a day, Sparkle's default),
// so the request volume is a relative trend for how many installs are alive and
// still in use — the one signal GitHub's download counts can't show.
//
// Privacy: NO IPs, cookies, identifiers, or fingerprints are stored. The only
// thing recorded is an aggregate row of (UTC date, 2-letter country, count).
// Requests are deliberately NOT deduplicated per user — that would require
// storing an identifier. Read the numbers as a relative trend, not exact
// install counts.
//
// Reliability: the counter is best-effort and FAIL-OPEN. The appcast response
// is always served unchanged from origin; if the database is unbound or the
// write fails, the update check still succeeds. Counting can never break
// update delivery.

export default {
  async fetch(request, env, ctx) {
    // A subrequest to this Worker's own route goes to origin (GitHub Pages),
    // not back through the Worker — so this serves the real appcast.
    const response = await fetch(request);

    // Tally out of band: never block the response, never throw.
    ctx.waitUntil(recordHit(env, request).catch(() => {}));

    return response;
  },
};

async function recordHit(env, request) {
  if (!env.DB) return; // not configured -> serve appcast, record nothing

  const day = new Date().toISOString().slice(0, 10); // UTC YYYY-MM-DD
  const country = request.cf?.country ?? "XX"; // coarse geo, aggregate-only

  await env.DB.prepare(
    `INSERT INTO appcast_hits (day, country, hits) VALUES (?1, ?2, 1)
       ON CONFLICT(day, country) DO UPDATE SET hits = hits + 1`,
  )
    .bind(day, country)
    .run();
}
