const { Router } = require("express");
const { getDb, dbExists } = require("../db");
const { computeStreak } = require("../utils/streak");

const router = Router();

const DAILY_GOAL_SECONDS = parseInt(process.env.DAILY_GOAL_MINUTES || "30") * 60;
const YEARLY_GOAL_BOOKS  = parseInt(process.env.YEARLY_GOAL_BOOKS  || "50");

// GET /api/goals — streak, daily goal progress, yearly target
router.get("/", (req, res) => {
  if (!dbExists()) {
    return res.json({ synced: false });
  }
  try {
    const db    = getDb();
    const today = new Date().toISOString().slice(0, 10);

    const today_seconds = db.prepare(`
      SELECT COALESCE(SUM(duration), 0) AS seconds
      FROM page_stat_data
      WHERE date(start_time, 'unixepoch', 'localtime') = ?
    `).get(today)?.seconds || 0;

    const yearly_complete = db.prepare(`
      SELECT COUNT(*) AS n FROM book
      WHERE total_read_pages >= pages * 0.9
        AND pages > 0
        AND date(last_open, 'unixepoch', 'localtime') LIKE ?
    `).get(`${new Date().getFullYear()}%`)?.n || 0;

    const heatmap = db.prepare(`
      SELECT date(start_time, 'unixepoch', 'localtime') AS day, SUM(duration) AS seconds
      FROM page_stat_data
      WHERE start_time > strftime('%s','now','-365 days')
      GROUP BY day ORDER BY day ASC
    `).all();

    const { current: streak } = computeStreak(heatmap);

    res.json({
      synced:             true,
      daily_goal_seconds: DAILY_GOAL_SECONDS,
      today_seconds,
      today_pct:          Math.min(100, Math.round((today_seconds / DAILY_GOAL_SECONDS) * 100)),
      streak,
      yearly_goal:        YEARLY_GOAL_BOOKS,
      yearly_complete,
      yearly_pct:         Math.min(100, Math.round((yearly_complete / YEARLY_GOAL_BOOKS) * 100)),
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

module.exports = router;
