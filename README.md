# inkfire

> A suite of KOReader plugins + local web dashboard solving the biggest pain points
> for Kobo e-reader users — especially manga readers.

**Target device:** Kobo Clara BW · KOReader (latest stable)  
**Brand:** [Digital Firefighter](https://github.com/EthicalHacker92)

---

## Plugins

| Plugin | Status | Description |
|--------|--------|-------------|
| **TransferBridge** | 🔨 Session 2 | WiFi drag-and-drop file transfer. QR code + browser drop zone. |
| **MangaFlow** | 🔨 Session 2 | Auto RTL, per-series settings, double-page spreads, progress HUD. |
| **SeriesOS** | 🔨 Session 3 | Series grouping, throttled cover caching, reading-status tabs. |
| **ReadingVault** | 🔨 Session 5 | Goals, streaks, session summaries, stats JSON endpoint. |
| **PowerGuard** | 🔨 Session 5 | Smart sleep profiles, brightness schedule, Clara BW tuning. |
| **ClipSync** | 🔨 Session 5 | Unified highlight DB, cross-library search, Notion/Obsidian export. |

## Dashboard

Local web app (Node + React) that reads your KOReader stats via Syncthing.

- **Library** — series grid with cover art and progress
- **Stats** — GitHub-style heatmap, reading time charts
- **Goals** — streak ring, daily goal, yearly target
- **Highlights** — search and export all highlights
- **Transfer** — drag-and-drop files to your device

**Design:** dark theme · Fraunces + DM Mono · ember accent `#ff5722`  
**PWA:** installable on iPhone home screen

## Quick Start

```bash
# 1. Install plugins on device (WiFi SFTP)
sftp root@<DEVICE_IP>
cd /mnt/onboard/.adds/koreader/plugins/
put -r plugins/transferbridge.koplugin
# ... (see docs/install-plugins.md)

# 2. Run dashboard
cd dashboard/server && npm install && node index.js
cd dashboard/client && npm install && npm run dev
```

See **[INSTALL.md](INSTALL.md)** for full setup instructions.

## Topics

`koreader-plugin` · `kobo` · `manga` · `ereader` · `koreader`

---

*Built by Eddie · Digital Firefighter*
