#!/usr/bin/env bash
# Dijalankan cron tiap menit di server: tarik versi terbaru dari GitHub, pasang kalau ada perubahan.
# Memakai kunci deploy read-only (~/.ssh/kantor_deploy). Tidak menyentuh .env.
set -euo pipefail
APP="$HOME/kantor-ai"; REPO="$HOME/kantor-ai-repo"; LOG="$HOME/kantor-ai-update.log"
exec 9>/tmp/kantor-update.lock; flock -n 9 || exit 0
cd "$REPO"
git fetch -q origin main
LOCAL=$(git rev-parse HEAD); REMOTE=$(git rev-parse origin/main)
[ "$LOCAL" = "$REMOTE" ] && exit 0
{
  echo "=== $(date '+%F %T') $LOCAL -> $REMOTE"
  git reset -q --hard origin/main
  rsync -a --delete --exclude '.env' --exclude '.git' --exclude 'data/' "$REPO"/ "$APP"/
  cd "$APP"
  bash scripts/import-workflows.sh
  docker compose up -d --build dashboard
  docker compose restart caddy
  echo "=== selesai"
} >>"$LOG" 2>&1
