# 🔥 InkFire

**A warm home for your reading life — a KOReader plugin for Kobo.**

InkFire replaces the cold file-manager landing of stock KOReader with **Hearth**:
a quiet, welcoming home screen that greets you, hands you your current book,
queues your next manga volume, and keeps a gentle streak going — all one tap
from reading.

Built for and tested on the **Kobo Clara BW** (1072×1448, 300 dpi e-ink).
Designed for people who read **books and manga** and want the device to pull
them back in, not get in the way.

## What it looks like

```
 Good evening.                        ⚙  ✕
 Thursday, June 11

 CONTINUE
 ╭──────────────────────────────────────╮
 │ [cover]  Project Hail Mary           │
 │          Andy Weir                   │
 │          ▂▂▂▂▂▂▂▂▂░░░░  64%          │
 │          about 2h 14m left           │
 ╰──────────────────────────────────────╯

 UP NEXT
 [Chainsaw Man 14] [Dungeon Crawler] [Cuckoo's Egg]

 ⚑ 12-day streak · 23 min today

 ╭───── Library ─────╮ ╭──── Transfer ────╮
```

## Features

- **Hearth home screen** — time-aware greeting, hero "Continue" card with real
  cover art, progress, and an honest time-left estimate from your own reading
  speed. Tap → you're reading.
- **Smart Up Next** — if you just finished *Chainsaw Man Vol. 13*, Vol. 14 is
  the first thing offered. Then your other in-progress reads, then fresh arrivals.
- **Library lanes** — full-screen cover grid with **All · Books · Manga** tabs,
  finished-book badges, swipe paging sized to the screen.
- **Quiet habit layer** — a one-line streak + minutes-today. Tap for the full
  card (week total, books finished, daily goal). It never nags.
- **WiFi drop transfer** — start it, open the URL on any device on your network,
  drag files in. Manga (`.cbz/.cbr`) auto-sorts into `manga/`, everything else
  into `books/`.
- **Title cleanup** — Anna's-Archive-style filename junk
  (`-- Publisher -- ISBN -- …`) never reaches your screen.

## Design stance

- **Polish, don't replace.** No monkey-patching of KOReader internals — Hearth
  is a full-screen widget *over* the stock UI. Swipe down and vanilla KOReader
  is right there. KOReader updates can't brick the device.
- **E-ink first.** One deliberate flash on entry, partial refresh after. Real
  SVG icons (KOReader's own set — never emoji). Rounded cards, generous
  whitespace, strong type hierarchy. Stillness over chrome.
- **Crash-proof by habit.** Every DB read, file read, and cover decode is
  pcall-guarded with a designed empty state. A failure renders as a quiet
  placeholder, not a crash.

Full design doc: [docs/DESIGN.md](docs/DESIGN.md)

## Install

1. Have [KOReader](https://github.com/koreader/koreader) installed on the Kobo
   (via [OCP-KFMon](https://www.mobileread.com/forums/showthread.php?t=314220)
   or NickelMenu).
2. Copy `inkfire.koplugin/` into `.adds/koreader/plugins/` on the device
   — or, on macOS with the Kobo plugged in:
   ```sh
   ./scripts/deploy-to-kobo.sh
   ```
3. Restart KOReader. Hearth greets you.

Covers come from KOReader's own book-info cache: browse your library once with
cover view (or just open books) and art fills in automatically.

### Controls

| Where | Gesture / tap | Action |
|---|---|---|
| Hearth | tap hero / Up Next cover | open that book |
| Hearth | swipe **up** | Library |
| Hearth | swipe **down** or ✕ | back to stock KOReader |
| Hearth | tap streak line | stats card + daily goal |
| Library | swipe **west / east** | page through covers |
| Anywhere | gesture → *InkFire: open Hearth* | bind via KOReader gestures |

Settings (⚙ on Hearth): show-on-startup toggle, daily goal.

## Repo layout

```
inkfire.koplugin/   the plugin (7 files, ~1900 lines of Lua)
dashboard/          optional desktop companion (Express + React)
scripts/            deploy helper
docs/DESIGN.md      the design document
```

## Versions

- **v3 “Hearth”** — ground-up rebuild: one welcoming home, library lanes,
  smart manga continuation, quiet stats, WiFi drop.
- v2 (archived in git history) — six-plugin suite, menu-driven.

---

*Part of the [Digital Firefighter](https://github.com/EthicalHacker92) project.*
