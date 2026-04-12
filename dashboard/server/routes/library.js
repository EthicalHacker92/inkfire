const { Router } = require("express");
const { getDb, dbExists } = require("../db");

const router = Router();

// GET /api/library — all books grouped by series with progress
router.get("/", (req, res) => {
  if (!dbExists()) {
    return res.json({ books: [], synced: false });
  }
  try {
    const db = getDb();

    const books = db.prepare(`
      SELECT
        id, title, authors, series, language,
        pages,
        total_read_pages,
        total_read_time,
        last_open,
        highlights,
        notes,
        md5
      FROM book
      ORDER BY
        CASE WHEN series IS NOT NULL AND series != '' THEN series ELSE title END,
        last_open DESC
    `).all();

    // Group into series
    const groups = {};
    const order  = [];

    for (const book of books) {
      const key = book.series || "__NONE__";
      if (!groups[key]) {
        groups[key] = { series: book.series || null, volumes: [] };
        order.push(key);
      }
      groups[key].volumes.push({
        id:              book.id,
        title:           book.title,
        authors:         book.authors,
        series:          book.series,
        pages:           book.pages || 0,
        total_read_pages: book.total_read_pages || 0,
        total_read_time:  book.total_read_time  || 0,
        last_open:       book.last_open,
        highlights:      book.highlights || 0,
        md5:             book.md5,
        pct: book.pages > 0
          ? Math.round((book.total_read_pages / book.pages) * 100)
          : 0,
        status: !book.total_read_pages || book.total_read_pages === 0
          ? "unread"
          : book.pages > 0 && book.total_read_pages >= book.pages * 0.9
            ? "complete"
            : "in_progress",
      });
    }

    const result = order.map(key => ({
      series:      groups[key].series,
      volumes:     groups[key].volumes,
      total:       groups[key].volumes.length,
      total_time:  groups[key].volumes.reduce((s, v) => s + v.total_read_time, 0),
      unread:      groups[key].volumes.filter(v => v.status === "unread").length,
      in_progress: groups[key].volumes.filter(v => v.status === "in_progress").length,
      complete:    groups[key].volumes.filter(v => v.status === "complete").length,
    }));

    // Sort: series groups first (alpha), then unsorted
    result.sort((a, b) => {
      if (!a.series && !b.series) return 0;
      if (!a.series) return 1;
      if (!b.series) return -1;
      return a.series.localeCompare(b.series);
    });

    res.json({ groups: result, synced: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

module.exports = router;
