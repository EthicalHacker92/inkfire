#!/usr/bin/env bash
# Deploys inkfire.koplugin to a mounted Kobo at /Volumes/KOBOeReader,
# cleans macOS junk files, and ejects safely.
set -euo pipefail

KOBO="/Volumes/KOBOeReader"
SRC="$(cd "$(dirname "$0")/.." && pwd)/inkfire.koplugin"
DST="$KOBO/.adds/koreader/plugins/inkfire.koplugin"

if [ ! -d "$KOBO" ]; then
    echo "error: $KOBO not mounted. Plug in the Kobo and tap Connect." >&2
    exit 1
fi

echo "→ Syncing inkfire.koplugin"
rsync -a --delete --exclude='._*' --exclude='.DS_Store' "$SRC/" "$DST/"
find "$DST" \( -name '._*' -o -name '.DS_Store' \) -delete

echo "→ Ejecting"
diskutil eject "$KOBO"
echo "Done. Restart KOReader on the device."
