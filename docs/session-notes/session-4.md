# Session 4 — Dashboard + Bug Fixes

**Date:** 2026-04-09

## Bug Fixes Applied

| Bug | File | Fix |
|-----|------|-----|
| `require("ui/lighterror")` crashes HUD render | `mangaflow/main.lua` | Replaced with `Blitbuffer.COLOR_BLACK/WHITE`; added `Blitbuffer` require |
| `SeriesSettings.get()` always truthy — first-encounter prompt never fired | `mangaflow/main.lua` + `series_settings.lua` | Added `SeriesSettings.exists()` helper; fixed condition to use it |
| `components.css` never imported — all component styles silently missing | `App.jsx` | Added `import "./components/components.css"` |
| `db.js` crashes if `statistics.sqlite3` doesn't exist | `dashboard/server/db.js` | Added `fs.existsSync` guard + `dbExists()` export |
| Multipart boundary parser failed on quoted boundaries from Chrome/Safari | `transferbridge/main.lua` | Added `boundary="..."` pattern before unquoted fallback |

## Dashboard Server

- `routes/library.js` — full series grouping, per-volume status (unread/in_progress/complete), % read
- `routes/stats.js` — totals, 365-day heatmap, streak computation, top-5 series, 12-week speed trend
- `routes/highlights.js` — walks `.sdr` sidecar dirs, parses `metadata.*.lua` files, supports `?q=` search
- `routes/transfer.js` — multer file upload, SFTP push via `ssh2`, auto-routes CBZ→manga/EPUB→books
- `routes/goals.js` — today's seconds, daily goal %, streak, yearly book count
- `server/index.js` — added `/api/goals`, `/api/health` routes; startup warning if DB not synced
- `server/package.json` — added `multer`, `ssh2` dependencies

## Dashboard Client

- **Library.jsx** — filter tabs (All/Unread/Reading/Done), search, series grid
- **Stats.jsx** — 4 stat cards, heatmap, top series list, speed bar chart
- **Goals.jsx** — daily ring + yearly SVG ring + streak card
- **Highlights.jsx** — search form, highlight cards with copy button, copy-all
- **Transfer.jsx** — device status check, config warning if no DEVICE_IP
- **SeriesCard.jsx** — cover initial, progress bar, expandable volume list with status dots
- **HeatmapChart.jsx** — pure SVG 52-week calendar heatmap, 5-level ember color scale, month labels
- **DropZone.jsx** — full drag-drop, file queue with badges, per-file SFTP upload
- **components.css** — complete design system: grid, stat cards, badges, dropzone, highlights, goals, buttons

## What's Next (Session 5)
ReadingVault + PowerGuard + ClipSync plugins (all implemented in same session).
