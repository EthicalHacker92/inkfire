#!/bin/bash
# setup-sync.sh — configure Syncthing to sync KOReader data from Kobo to Mac
# Run once after installing Syncthing on both devices.

set -euo pipefail

SYNC_DIR="$HOME/.koreader_sync"

echo "=== Digital Firefighter — Syncthing Setup ==="
echo ""

# Create local sync directory
mkdir -p "$SYNC_DIR"
echo "[+] Created sync directory: $SYNC_DIR"

# Check Syncthing is installed
if ! command -v syncthing &>/dev/null; then
  echo "[!] Syncthing not found. Install with: brew install syncthing"
  exit 1
fi

echo ""
echo "Next steps:"
echo "  1. Open Syncthing UI: http://127.0.0.1:8384"
echo "  2. Add your Kobo as a remote device"
echo "  3. Share the folder: /mnt/onboard/.adds/koreader/"
echo "     → sync to: $SYNC_DIR"
echo "  4. On Kobo, accept the share in KOReader's Syncthing integration"
echo ""
echo "Once synced, statistics.sqlite3 will appear in $SYNC_DIR"
echo "Set KOREADER_SYNC_PATH=$SYNC_DIR in your .env or shell profile."
