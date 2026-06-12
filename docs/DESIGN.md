# InkFire v3 — "Hearth" Design

**Target:** Kobo Clara BW (1072×1448, 300 dpi, grayscale e-ink, MTK SoC, warm+cool frontlight)
**Goal:** The most welcoming home experience on an e-reader. Make the time between books so pleasant that you keep coming back. Books and manga are equal citizens.

## Research inputs

1. **Community (r/koreader):** The most-loved UI mod is *Project: Title* — its philosophy is "blend in with the very best commercial eReaders, make the time between books as pleasant as possible." It polishes rather than replaces, and that's why it survives KOReader updates. *SimpleUI* proves a full desktop replacement is possible but pays in fragility (monkey-patching breaks on updates). Stock-KOReader complaints cluster on: overwhelming nested menus, file-manager-as-library coldness, no first-run warmth.
2. **Verified API surface (KOReader master):** `FrameContainer` supports `radius` (rounded cards). `ScrollableContainer` exists. Covers live in `bookinfo_cache.sqlite3` as zstd-compressed raw BlitBuffers (`cover_bb_type/stride/data`); decode via `zstd_uncompress_ctx` + `Blitbuffer.new` + `setAllocated(1)`. Real icons ship in `resources/icons/mdlight/` (no emoji — they render as blobs on e-ink). Full-screen widgets set `covers_fullscreen = true`; open with `flashui`, page with `partial`, close with `flashpartial`. `ReadHistory` + `DocSettings` sidecars are the robust source for "what was I reading and how far am I" (the same path coverbrowser uses).
3. **The owner's library (Calibre):** Chainsaw Man (manga, multiple volumes), Project Hail Mary, Dungeon Crawler Carl, and a shelf of cybersecurity books. Small library (~16), several with Anna's-Archive-style junk filenames. Implications: title cleaning is load-bearing; manga series continuation is a first-class flow; design for "what do I read tonight," not for 1,000-book management.

## Principles

1. **One screen, one feeling.** Open the Kobo → a warm, quiet page that says good evening and offers your book. No tabs, no dock, no dashboard clutter.
2. **Polish, don't replace.** No monkey-patching. Hearth is a `covers_fullscreen` widget over FileManager. Swipe down and stock KOReader is right there. Updates can't brick the device.
3. **E-ink is the medium, not a constraint.** High contrast, generous whitespace, rounded cards, real SVG icons, one deliberate flash on entry, partial refresh after. No animation, no spinners — e-ink rewards stillness.
4. **The next page is always one tap.** Hero card → resume reading. Manga volume finished? The hero becomes "Next volume."
5. **Habit, quietly.** A streak flame and today's minutes in one small line. Tap it for the full card. It never nags, never blocks.

## The screens

### Hearth (home)
```
 Good evening.                       ⚙  ✕
 Thursday, June 11

 CONTINUE
 ╭──────────────────────────────────────╮
 │ ┌──────┐  Project Hail Mary          │
 │ │cover │  Andy Weir                  │
 │ │      │  ▂▂▂▂▂▂▂▂▂▂░░░░░  64%       │
 │ └──────┘  about 2h 14m left          │
 ╰──────────────────────────────────────╯

 UP NEXT
 ┌────┐  ┌────┐  ┌────┐
 │cov │  │cov │  │cov │
 └────┘  └────┘  └────┘
 Chainsaw  Dungeon  Cuckoo's
 Man 14    Crawler  Egg

 ⚑ 12-day streak · 23 min today

 ╭───────────────╮  ╭───────────────╮
 │   ⌂ Library   │  │  ⇄ Transfer   │
 ╰───────────────╯  ╰───────────────╯
```
- Greeting is time-aware (morning/afternoon/evening). Date below in small caps.
- Hero = rounded card, real cover (decoded from bookinfo cache; typographic fallback), cleaned title, author, progress bar, time-left estimate from reading speed.
- Up Next = 3 covers: next unread volume of your current manga series first, then most-recent unfinished, then newest arrivals.
- Stats line: tap → stats card (streak, minutes vs goal, week total, books finished, set-goal button).
- Gestures: swipe down = close to FileManager; swipe up = Library. Settings icon → small menu (auto-open toggle, daily goal, about).

### Library
- Full-screen paged 3×3 cover grid. Lanes across the top: **All · Books · Manga** (text buttons, active underlined).
- Each cell: cover or typographic placeholder, 1-line cleaned title, thin progress underbar, small trophy on finished.
- Swipe west/east or chevrons to page. Tap cover = read. Footer: "page 1 of 2".

### Transfer
- One rounded modal: big URL (`http://192.168.x.x:8765`), "drop files from any browser on your WiFi," Stop button. Server is the proven non-blocking LuaSocket HTTP server with multipart upload, auto-sorting cbz/cbr→`manga/`, epub/pdf→`books/`.

## Architecture

```
inkfire.koplugin/
├── _meta.lua        plugin metadata
├── main.lua         shell: lifecycle, dispatcher, menu, gestures, settings, session toast
├── style.lua        design tokens: spacing scale, radius, fonts, icons, bars
├── data.lua         all reads: ReadHistory+DocSettings continue logic, bookinfo covers
│                    (zstd decode + LRU), shelf/lane grouping, title cleaner, stats
├── home.lua         Hearth screen + stats card overlay
├── library.lua      paged cover grid with lanes
└── transfer.lua     WiFi drop server (logic + status; main.lua schedules polling)
```

- `style.lua` and `data.lua` have **no UIManager calls**; widgets consume them.
- Every DB/file/IO path is pcall-wrapped; every widget has an empty state; a failed widget renders a quiet placeholder, never a crash.
- Settings under `G_reader_settings` namespace `inkfire_*`. Master escape hatch: `inkfire_auto_home` off → stock KOReader untouched.

## Performance budget

- Open Hearth: ≤ 1 full flash; data snapshot ≤ 150 ms (≤ 5 sidecar reads, ≤ 4 cover decodes, all cached).
- Library page: 9 covers max per paint, LRU 24 decoded covers, partial refresh per page.
- No timers while idle except the transfer poll (only while server runs).

## What v3 deliberately drops (from v2)

PowerGuard, ClipSync, separate SeriesOS browser, MangaFlow HUD, per-series RTL DB. KOReader already does RTL-per-book well; menus full of toggles were the opposite of welcoming. Their best ideas (next-volume logic, progress, series grouping) are absorbed into Hearth and Library. The dashboard (`dashboard/`) stays as a desktop companion.
