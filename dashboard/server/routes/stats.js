const { Router } = require("express");
const { getDb } = require("../db");

const router = Router();

// GET /api/stats — reading time, pages, streaks, heatmap data
router.get("/", (req, res) => {
  try {
    const db = getDb();

    const totals = db.prepare(`
      SELECT
        SUM(total_read_time) AS total_seconds,
        SUM(total_read_pages) AS total_pages,
        COUNT(*) AS total_books
      FROM book
    `).get();

    // Daily heatmap: seconds read per calendar day (unix → date)
    const heatmap = db.prepare(`
      SELECT
        date(start_time, 'unixepoch', 'localtime') AS day,
        SUM(duration) AS seconds
      FROM page_stat_data
      GROUP BY day
      ORDER BY day ASC
    `).all();

    res.json({ totals, heatmap });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

module.exports = router;
