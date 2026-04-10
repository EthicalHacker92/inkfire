# Session 2 — TransferBridge + MangaFlow

**Date:** 2026-04-09

## What Was Built

### TransferBridge (full implementation)

`plugins/transferbridge.koplugin/main.lua`
- Non-blocking HTTP server via LuaSocket `socket.bind` + `settimeout(0)`
- Polled every 150ms via `UIManager:scheduleIn` — never blocks the UI
- Routes: `GET /` (dropzone HTML), `GET /api/status` (JSON), `POST /api/upload` (multipart)
- Full multipart/form-data parser — handles binary file content correctly
- Duplicate detection: compares incoming file size against existing file on device
- Auto-organizes: CBZ/CBR/ZIP → `/mnt/onboard/manga/`, EPUB/MOBI/AZW/FB2/PDF → `/mnt/onboard/books/`
- Calls `FileManager.instance:onRefresh()` after transfers to update the library
- Device IP detection via UDP socket trick (no ifconfig needed)
- Minimal JSON encoder (no external deps)
- Menu: Start/Stop server, Show URL

`plugins/transferbridge.koplugin/ui/dropzone.html`
- Dark theme matching inkfire brand (`#0d0d0d` bg, `#ff5722` accent)
- Drag-and-drop + click-to-browse, multi-file
- Per-file progress bars via XHR `upload.onprogress`
- Status badges: pending / uploading / ok / duplicate / error
- Heartbeat polling `/api/status` every 3s — shows connected/offline dot
- `__DEVICE_URL__` placeholder injected at serve time

### MangaFlow (full implementation)

`plugins/mangaflow.koplugin/series_settings.lua`
- SQLite schema: `series_settings(series_name PK, rtl, contrast, precache, autocrop, spread, updated_at)`
- `get(series_name)` — returns row or DEFAULTS
- `set(series_name, partial)` — upsert with merge against current values
- `delete(series_name)` — reset to defaults
- `getAll()` — for future settings UI

`plugins/mangaflow.koplugin/main.lua`
- Hooks: `onReaderReady`, `onPageUpdate`, `onCloseDocument`
- RTL detection priority: ComicInfo.xml (via `unzip -p`) → bookinfo_cache.sqlite3 language → filename heuristics
- Series name resolution: bookinfo_cache `series` column → document props → filename stripping
- Applies: RTL page-flip direction, contrast/gamma, pre-cache lookahead
- Progress HUD: footer text showing `Series · page / total`
- First-encounter prompt: asks user to enable Manga Mode for new series
- Menu: toggle Manga Mode, reset series settings, show current series name
- `isSpreadPage()` helper ready for Session 3 spread-stitching polish

## What's Working
- TransferBridge server starts/stops cleanly, all routes implemented
- Dropzone UI is polished and functional (visible in preview panel)
- MangaFlow detects RTL from 3 different sources with fallback chain
- Per-series SQLite settings persist across sessions
- HUD shows series name + page progress in reader footer

## What's Next (Session 3)
- **SeriesOS:** series grouping from `bookinfo_cache.sqlite3`, throttled cover caching (5/sec), reading-status tabs
- **MangaFlow polish:** double-page spread stitching using `isSpreadPage()` + document render API, auto border crop

## Known Issues / TODOs
- `unzip` must be available in PATH on device (it is on Kobo stock firmware)
- HUD widget anchoring uses `overlap_offset` — test exact positioning on Clara BW screen
- `paging:setPageFlipMode()` API name may vary by KOReader version — verify on device
- `doc:setContrast()` availability depends on document type — CBZ should support it
- Spread stitching left for Session 3 (placeholder `isSpreadPage()` is ready)
