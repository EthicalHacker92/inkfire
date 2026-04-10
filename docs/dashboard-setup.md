# Dashboard Setup

## Prerequisites

- Node.js 20+
- Syncthing syncing your Kobo's KOReader folder to `~/.koreader_sync/`
  (run `scripts/setup-sync.sh` for guided setup)

## Running the Dashboard

```bash
# Backend
cd dashboard/server
npm install
node index.js        # http://localhost:3000

# Frontend (dev mode)
cd dashboard/client
npm install
npm run dev          # http://localhost:5173
```

## PWA Install (iPhone)

1. Open `http://<MAC_IP>:5173` in Safari
2. Tap **Share → Add to Home Screen**
3. Launch from home screen — runs fullscreen, offline-capable

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | `3000` | Express server port |
| `KOREADER_SYNC_PATH` | `~/.koreader_sync` | Path to synced KOReader folder |
