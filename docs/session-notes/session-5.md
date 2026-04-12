# Session 5 — ReadingVault + PowerGuard + ClipSync

**Date:** 2026-04-09

## ReadingVault

`plugins/readingvault.koplugin/main.lua`

- **Session tracking:** `onReaderReady` records start time; `onPageUpdate` counts pages; `onCloseDocument` computes duration and fires summary
- **Session summary popup:** shows minutes read, progress vs daily goal, current streak + flame emoji
- **`readingvault.sqlite3`:** `goals` key-value table (daily goal seconds, yearly book target) + `sessions` log
- **Today's seconds:** queries `statistics.sqlite3 page_stat_data` — same DB KOReader writes to
- **Streak:** walks backwards from today through `page_stat_data` grouped by day
- **Menu:** editable daily goal (InputDialog), editable yearly goal, "Today's Stats" quick popup
- **Ignores sessions under 30 seconds** to avoid accidental opens polluting the data

## PowerGuard

`plugins/powerguard.koplugin/main.lua`

- **4 sleep profiles:** Reading (5 min), Manga (10 min), Night (2 min), Never — sets `auto_standby_timeout` via G_reader_settings and `Device.powerd`
- **Manga profile:** disables warmth LED (Clara BW has no warmth but guarded with `hasNaturalLight()`)
- **Brightness schedule:** polls every 60s via `UIManager:scheduleIn`; maps hour → brightness %
- **Low battery mode:** auto-triggers at ≤15% — dims to 20%, sleep to 1 min
- **Clara BW detection:** checks `Device.model == "spaBWTPV"` with fallback substring match
- **Battery status menu item** shows live % + low-battery mode state

## ClipSync

`plugins/clipsync.koplugin/main.lua`

- **`clipsync.sqlite3`:** `highlights` table (book_path, book_title, chapter, page, text, note, datetime) + `sync_state`
- **Sidecar sync:** walks all `.sdr` dirs under `/mnt/onboard`, reads `metadata.*.lua`, deduplicates by book_path+text
- **Line-by-line Lua parser:** no external deps — extracts text, note, chapter, pageno, datetime from KOReader's sidecar format
- **On-device search:** InputDialog → filters highlights by text (case-insensitive), shows results in Menu widget
- **Daily memory:** on init, picks a random highlight from DB and shows it (once per day via `sync_state` table)
- **Obsidian export:** writes `highlights_export.md` to `/mnt/onboard/` — grouped by book, blockquote format
- **Readwise CSV export:** RFC-compliant CSV to `/mnt/onboard/readwise_export.csv`

## README

- Rewrote README with clean table-based plugin/view summaries
- Removed all placeholder session references
- Added environment variable reference table
- Added PWA install instructions

## What's Complete

All 6 plugins fully implemented. Full dashboard. All 5 bug fixes applied. Ready to ship.
