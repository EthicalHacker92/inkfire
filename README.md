# inkfire

> A suite of KOReader plugins + local web dashboard that solves the biggest
> pain points for Kobo e-reader users — especially manga readers.

**Device:** Kobo Clara BW · KOReader (latest stable)  
**By:** [EthicalHacker92](https://github.com/EthicalHacker92) · Digital Firefighter

---

## Plugins

| Plugin | What it does |
|--------|-------------|
| **TransferBridge** | WiFi drag-and-drop file transfer. Open `http://device-ip:8765` in any browser, drop files, done. No Calibre needed. |
| **MangaFlow** | Auto-detects RTL manga (ComicInfo.xml → bookinfo cache → filename), remembers per-series settings, shows a page/series HUD, auto-handles double-page spreads. |
| **SeriesOS** | Groups your flat library into series shelves. "One Piece · Vol 1–47 · 12 unread." Throttled cover loading so it never freezes. Duplicate detector and auto-rename. |
| **ReadingVault** | Daily reading goals (default 30 min), streak tracking, session summary popup on close, today's stats in menu. |
| **PowerGuard** | Smart sleep profiles (Reading 5min / Manga 10min / Night 2min), time-of-day brightness schedule, low-battery mode at 15%. Clara BW-specific tuning. |
| **ClipSync** | Aggregates all highlights from `.sdr` sidecar files into a searchable SQLite DB. Export to Obsidian markdown or Readwise CSV. Daily random "memory" on wake. |

## Dashboard

Local web app that reads your reading stats via Syncthing.

```
http://localhost:3000
```

| View | What it shows |
|------|--------------|
| **Library** | Series grid with progress, status filter tabs (All / Unread / Reading / Done), search |
| **Stats** | GitHub-style reading heatmap, 52-week history, top series by time, pages/hour trend |
| **Goals** | Day streak ring, daily goal progress, yearly book target |
| **Highlights** | All highlights searchable and copyable, pulled from `.sdr` sidecars |
| **Transfer** | Drag-and-drop files to your device via SFTP |

**Design:** dark theme · Fraunces + DM Mono · ember `#ff5722`  
**PWA:** installable on iPhone home screen

---

## Install Plugins

### WiFi SFTP (recommended)

Enable SSH in KOReader: **Menu → Tools → SSH server → Start**

```bash
sftp root@<DEVICE_IP>
cd /mnt/onboard/.adds/koreader/plugins/
put -r transferbridge.koplugin
put -r mangaflow.koplugin
put -r seriosos.koplugin
put -r readingvault.koplugin
put -r powerguard.koplugin
put -r clipsync.koplugin
exit
```

Then restart KOReader. Plugins appear under **Menu → Tools → Plugin manager**.

### USB

Copy each `.koplugin` folder to `/mnt/onboard/.adds/koreader/plugins/` and restart.

---

## Run the Dashboard

### 1. Sync your device

```bash
bash scripts/setup-sync.sh
```

Syncthing auto-syncs your Kobo's KOReader folder to `~/.koreader_sync/` whenever on the same WiFi.

### 2. Start the server

```bash
cd dashboard/server
npm install
node index.js
```

### 3. Start the frontend (dev)

```bash
cd dashboard/client
npm install
npm run dev        # http://localhost:5173
```

### 4. Environment variables (optional)

| Variable | Default | Description |
|---|---|---|
| `KOREADER_SYNC_PATH` | `~/.koreader_sync` | Path to synced KOReader folder |
| `PORT` | `3000` | Server port |
| `DEVICE_IP` | _(none)_ | Kobo IP for SFTP transfer from dashboard |
| `DEVICE_SSH_PORT` | `22` | SSH port |
| `DAILY_GOAL_MINUTES` | `30` | Default daily goal |
| `YEARLY_GOAL_BOOKS` | `50` | Default yearly target |

### PWA Install (iPhone)

1. Open `http://<YOUR_MAC_IP>:5173` in Safari
2. **Share → Add to Home Screen**
3. Launch fullscreen, works offline

---

## Topics

`koreader-plugin` · `kobo` · `manga` · `ereader` · `koreader` · `self-hosted`

---

*inkfire — Digital Firefighter*
