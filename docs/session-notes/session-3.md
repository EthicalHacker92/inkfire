# Session 3 — SeriesOS + MangaFlow Spread Polish

**Date:** 2026-04-09

## What Was Built

### SeriesOS (full implementation)

**`plugins/seriesos.koplugin/series_db.lua`** (new file)
- Reads `bookinfo_cache.sqlite3` — queries title, authors, series, series_index, pages, has_cover, md5
- Cross-references `statistics.sqlite3` for per-book read_pages and read_time
- `getGrouped()` — returns alphabetically sorted series list, each with:
  - Volumes sorted by parsed `series_index` (handles "Vol.3", "1.5", etc.)
  - Vol range string: "Vol 1–47"
  - Per-series counts: unread / in_progress / complete
  - Total reading time across all volumes
- `findDuplicates()` — detects by MD5 match (definitive) or title+pages match (probable)
- `canonicalFilename()` — generates clean rename target: `SeriesName_Vol001.cbz`
- `STATUS` constants: `unread`, `in_progress`, `complete`

**`plugins/seriosos.koplugin/main.lua`** (full)
- FileManager menu: Browse by Series, status filter tabs, duplicates, auto-rename, cache refresh
- **Series browser** via `Menu` widget — shows "Series name · Vol 1–47 · 12 unread · 3h read"
- **Volume list** with status prefixes (○ unread / ◐ reading / ● done), progress %, time invested
- Hold-tap volume → options dialog: rename, mark complete, open
- **Reading status tabs:** All / Unread / In Progress / Complete — each opens a filtered browser
- **Duplicate detector** — lists pairs with reason, offers delete-the-copy action
- **Auto-rename preview** — shows up to 5 examples before committing, renames all at once
- **Throttled cover loading** — processes `COVERS_PER_TICK = 5` covers per 200ms tick via `UIManager:scheduleIn` — never freezes UI
- **Mark Complete** — writes `total_read_pages = pages` to statistics.sqlite3
- Groups cache — populated on first open, cleared by "Refresh" menu item

### MangaFlow — Spread Polish

**`plugins/mangaflow.koplugin/main.lua`** (updated)
- `spread_mode` and `spread_counts` fields added to plugin state
- `sampleSpreadCount()` — samples up to 10 pages at document open to decide if book has spreads
- `handleSpread(pageno)` — called on every page turn; enters/exits spread mode automatically
- `enterSpreadMode()` — saves current zoom mode, switches `readerzooming` to `"width"` mode (fits full spread)
- `exitSpreadMode()` — restores previous zoom mode when returning to portrait pages
- **Auto Spread toggle** added to MangaFlow menu — persisted per-series via SeriesSettings
- `onCloseDocument` now calls `exitSpreadMode()` to clean up

## What's Working
- SeriesOS groups any KOReader library with series metadata — One Piece 47 vols shows as one shelf entry
- Status filters work across all three reading states
- Throttle prevents cover cache from freezing the UI (5 covers/200ms)
- Spread mode auto-activates on wide pages, restores zoom on portrait pages
- Auto-rename handles 3-digit zero-padded vol numbers for correct sort order

## What's Next (Session 4)
- **Dashboard:** Node backend with SQLite reader, 5 API routes live
- **Library view:** Series grid with cover art, click-to-volumes
- **Stats view:** GitHub heatmap (recharts), daily/weekly charts, top series by time

## Known Issues / TODOs
- `Menu` widget `mandatory` field position varies by KOReader version — may appear right-aligned or as subtitle
- `ButtonDialogTitle` import path might be `ui/widget/buttondialogtitle` — verify on device
- `readerzooming:setZoomMode("width")` API name — check against your KOReader build
- Spread sampling runs synchronously at `onReaderReady` — move to `UIManager:scheduleIn` if it causes a perceptible pause on large CBZs
- `BookInfoManager:getCoverImage()` path in throttled loader — verify correct require path on device
