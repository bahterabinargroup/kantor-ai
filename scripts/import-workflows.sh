#!/usr/bin/env bash
# Impor semua workflow di n8n/workflows/ ke n8n, lalu aktifkan satu per satu (per-ID).
# Prasyarat: akun owner n8n sudah dibuat lewat browser. Aman dijalankan ulang.
set -euo pipefail
cd "$(dirname "$0")/.."

# Lewati kalau isi workflow tidak berubah sejak impor terakhir (impor = restart n8n = ±1 menit tidak bisa
# menerima pesan WhatsApp). Paksa dengan: FORCE=1 ./scripts/import-workflows.sh
HASHFILE=".workflows.sha"
NEWHASH="$(cat n8n/workflows/*.json | sha256sum | cut -d' ' -f1)"
if [ "${FORCE:-}" != "1" ] && [ -f "$HASHFILE" ] && [ "$(cat "$HASHFILE")" = "$NEWHASH" ]; then
  echo "Workflow tidak berubah — impor & restart n8n dilewati."
  exit 0
fi

echo "── Impor workflow ──"
docker compose exec -T n8n n8n import:workflow --separate --input=/workflows

echo "── Aktifkan workflow ──"
# n8n 2.x: publish:workflow --id (update:workflow deprecated, tanpa --all).
# n8n 1.x: update:workflow --id --active=true.
FAILED=()
for f in n8n/workflows/*.json; do
  id="$(sed -n 's/^  "id": "\(.*\)",$/\1/p' "$f" | head -n1)"
  name="$(sed -n 's/^  "name": "\(.*\)",$/\1/p' "$f" | head -n1)"
  [ -n "$id" ] || continue
  [ "$id" = "kai_sys_error_handler" ] && continue   # dipanggil otomatis saat error, tak perlu aktif
  if docker compose exec -T n8n n8n publish:workflow --id="$id" >/dev/null 2>&1 \
     || docker compose exec -T n8n n8n update:workflow --id="$id" --active=true >/dev/null 2>&1; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name"; FAILED+=("$name")
  fi
done

echo "── Restart n8n agar webhook terdaftar ──"
docker compose restart n8n

[ "${#FAILED[@]}" -eq 0 ] && echo "$NEWHASH" > "$HASHFILE"

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo
  echo "⚠  Gagal diaktifkan lewat CLI: ${FAILED[*]}"
  echo "   Buka n8n → workflow itu → tombol Publish/Active di kanan atas."
fi
echo
echo "Selesai. Error handler sudah terpasang otomatis di semua workflow (tidak ada langkah manual)."
