const { Router } = require("express");
const { getDb } = require("../db");

const router = Router();

// GET /api/library — all books with metadata, covers, and progress
router.get("/", (req, res) => {
  try {
    const db = getDb();
    const books = db.prepare(`
      SELECT
        id, title, authors, series, language,
        pages, total_read_pages, total_read_time,
        last_open, highlights, notes, md5
      FROM book
      ORDER BY last_open DESC
    `).all();
    res.json(books);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

module.exports = router;
