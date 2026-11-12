#!/usr/bin/env bash
# Kirim versi terbaru Kantor AI ke server dan aktifkan, semuanya otomatis.
# Pakai (di Terminal Mac):   bash ~/Downloads/deploy.sh
set -euo pipefail

HOST="${1:-ubuntu@149.41.195.210}"
ZIP="$(ls -t "$HOME"/Downloads/kantor-ai*.zip 2>/dev/null | head -n1 || true)"
[ -n "$ZIP" ] || { echo "File kantor-ai.zip tidak ada di folder Downloads."; exit 1; }
echo "→ Memakai: $ZIP"

echo "→ [1/2] Mengirim ke server (kalau diminta password, itu password SSH server)…"
scp "$ZIP" "$HOST:~/kantor-ai.zip"

echo "→ [2/2] Memasang di server…"
ssh -n "$HOST" 'set -e
cp ~/kantor-ai/.env /tmp/env.bak
unzip -oq ~/kantor-ai.zip -d ~
cp /tmp/env.bak ~/kantor-ai/.env
cd ~/kantor-ai
bash scripts/import-workflows.sh
docker compose up -d --build dashboard
docker compose restart caddy
echo
echo "SELESAI. Semua sudah terpasang."'
