const { Router } = require("express");
const { getDb, dbExists, SYNC_PATH } = require("../db");
const path = require("path");
const fs   = require("fs");

const router = Router();

// GET /api/highlights?q=search&book_id=123
router.get("/", (req, res) => {
  const { q, book_id } = req.query;

  try {
    const annotations = readSdrHighlights(SYNC_PATH, q, book_id ? parseInt(book_id) : null);
    res.json({ highlights: annotations, synced: true });
  } catch (err) {
    res.status(500).json({ error: err.message, highlights: [] });
  }
});

/**
 * Reads all .sdr sidecar directories under sync_path and parses
 * their metadata.lua files for highlight annotations.
 * KOReader stores highlights in:
 *   <book>.sdr/metadata.epub.lua  (or .cbz.lua, etc.)
 */
function readSdrHighlights(sync_path, query, book_id_filter) {
  const highlights = [];
  if (!fs.existsSync(sync_path)) return highlights;

  walkDir(sync_path, (entry, dir) => {
    if (!entry.endsWith(".sdr")) return;
    const sdr_path = path.join(dir, entry);
    if (!fs.statSync(sdr_path).isDirectory()) return;

    // Find the metadata.*.lua file inside
    let meta_file = null;
    try {
      const files = fs.readdirSync(sdr_path);
      meta_file = files.find(f => f.startsWith("metadata.") && f.endsWith(".lua"));
    } catch { return; }

    if (!meta_file) return;

    const book_name = entry.replace(/\.sdr$/, "");
    const meta_path = path.join(sdr_path, meta_file);

    try {
      const raw = fs.readFileSync(meta_path, "utf8");
      const parsed = parseLuaHighlights(raw);
      for (const h of parsed) {
        if (!h.text || h.text.trim() === "") continue;
        if (query && !h.text.toLowerCase().includes(query.toLowerCase())) continue;
        highlights.push({
          book:    book_name,
          page:    h.page,
          text:    h.text,
          note:    h.note || null,
          chapter: h.chapter || null,
          time:    h.datetime || null,
        });
      }
    } catch { /* skip unreadable metadata */ }
  });

  // Sort by time desc
  highlights.sort((a, b) => (b.time || "").localeCompare(a.time || ""));
  return highlights;
}

/**
 * Minimal Lua table parser for KOReader's metadata.*.lua highlight format.
 * KOReader stores highlights as:
 *   ["highlight"] = { [1] = { ["text"] = "...", ["pos0"] = ..., ["datetime"] = "..." }, ... }
 */
function parseLuaHighlights(lua_src) {
  const highlights = [];

  // Extract the highlight block
  const block_match = lua_src.match(/\["highlight"\]\s*=\s*\{([\s\S]*?)\},?\s*\[/);
  if (!block_match) return highlights;

  const block = block_match[1];

  // Extract each entry: { ["key"] = "value", ... }
  const entry_re = /\{([^}]+)\}/g;
  let m;
  while ((m = entry_re.exec(block)) !== null) {
    const entry = m[1];
    const text    = extractLuaString(entry, "text");
    const note    = extractLuaString(entry, "note");
    const chapter = extractLuaString(entry, "chapter");
    const dt      = extractLuaString(entry, "datetime");
    const page_m  = entry.match(/\["pageno"\]\s*=\s*(\d+)/);

    if (text) {
      highlights.push({
        text:     text,
        note:     note,
        chapter:  chapter,
        datetime: dt,
        page:     page_m ? parseInt(page_m[1]) : null,
      });
    }
  }
  return highlights;
}

function extractLuaString(src, key) {
  const m = src.match(new RegExp(`\\["${key}"\\]\\s*=\\s*"((?:[^"\\\\]|\\\\.)*)"`));
  if (!m) return null;
  return m[1].replace(/\\n/g, "\n").replace(/\\"/g, '"').replace(/\\\\/g, "\\");
}

function walkDir(dir, fn, depth = 0, seen = new Set()) {
  if (depth > 10) return;
  try {
    const real = fs.realpathSync(dir);
    if (seen.has(real)) return;
    seen.add(real);
    const entries = fs.readdirSync(dir);
    for (const e of entries) {
      fn(e, dir);
      const full = path.join(dir, e);
      try {
        if (fs.statSync(full).isDirectory()) walkDir(full, fn, depth + 1, seen);
      } catch { /* skip */ }
    }
  } catch { /* skip unreadable dirs */ }
}

module.exports = router;
