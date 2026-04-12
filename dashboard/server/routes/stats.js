const { Router } = require("express");
const { getDb, dbExists } = require("../db");

const router = Router();

// GET /api/stats — reading totals, heatmap, streak, top series
router.get("/", (req, res) => {
  if (!dbExists()) {
    return res.json({ synced: false });
  }
  try {
    const db = getDb();

    // Overall totals
    const totals = db.prepare(`
      SELECT
        SUM(total_read_time)  AS total_seconds,
        SUM(total_read_pages) AS total_pages,
        COUNT(*)              AS total_books,
        SUM(highlights)       AS total_highlights
      FROM book
    `).get();

    // Daily heatmap (seconds read per day, last 365 days)
    const heatmap = db.prepare(`
      SELECT
        date(start_time, 'unixepoch', 'localtime') AS day,
        SUM(duration)                               AS seconds
      FROM page_stat_data
      WHERE start_time > strftime('%s','now','-365 days')
      GROUP BY day
      ORDER BY day ASC
    `).all();

    // Reading streak: consecutive days with >= 1 minute of reading
    const streak = computeStreak(heatmap);

    // Top 5 series/titles by total read time
    const top_series = db.prepare(`
      SELECT
        COALESCE(NULLIF(series,''), title) AS name,
        SUM(total_read_time)               AS seconds,
        SUM(total_read_pages)              AS pages
      FROM book
      GROUP BY name
      ORDER BY seconds DESC
      LIMIT 5
    `).all();

    // Reading speed trend: pages-per-hour over last 12 weeks
    const speed_trend = db.prepare(`
      SELECT
        strftime('%Y-W%W', start_time, 'unixepoch', 'localtime') AS week,
        SUM(total_pages)    AS pages,
        SUM(duration)       AS seconds
      FROM page_stat_data
      WHERE start_time > strftime('%s','now','-84 days')
      GROUP BY week
      ORDER BY week ASC
    `).all().map(r => ({
      week:     r.week,
      pph:      r.seconds > 0 ? Math.round((r.pages / r.seconds) * 3600) : 0,
      pages:    r.pages,
      hours:    Math.round(r.seconds / 360) / 10,
    }));

    res.json({
      synced:      true,
      totals:      {
        hours:       Math.floor((totals.total_seconds || 0) / 3600),
        minutes:     Math.floor(((totals.total_seconds || 0) % 3600) / 60),
        total_pages: totals.total_pages || 0,
        total_books: totals.total_books || 0,
        highlights:  totals.total_highlights || 0,
      },
      heatmap,
      streak,
      top_series,
      speed_trend,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

function computeStreak(heatmap) {
  if (!heatmap.length) return { current: 0, longest: 0, last_read: null };

  const MIN_SECONDS = 60;
  const today = new Date().toISOString().slice(0, 10);

  // Build a Set of active days
  const active = new Set(
    heatmap.filter(r => r.seconds >= MIN_SECONDS).map(r => r.day)
  );

  // Walk backwards from today
  let current = 0;
  let d = new Date(today);
  while (true) {
    const key = d.toISOString().slice(0, 10);
    if (!active.has(key)) break;
    current++;
    d.setDate(d.getDate() - 1);
  }

  // Longest streak
  let longest = 0, run = 0;
  const days = [...active].sort();
  for (let i = 0; i < days.length; i++) {
    if (i === 0) { run = 1; continue; }
    const prev = new Date(days[i - 1]);
    prev.setDate(prev.getDate() + 1);
    if (prev.toISOString().slice(0, 10) === days[i]) {
      run++;
    } else {
      run = 1;
    }
    longest = Math.max(longest, run);
  }
  longest = Math.max(longest, run);

  const last_read = days[days.length - 1] || null;
  return { current, longest, last_read };
}

module.exports = router;
