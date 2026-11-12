#!/usr/bin/env bash
# Setup pertama: membuat .env (secret otomatis), password dashboard, lalu menjalankan stack.
set -euo pipefail
cd "$(dirname "$0")"

command -v docker >/dev/null || { echo "Docker belum terpasang."; exit 1; }
docker compose version >/dev/null || { echo "Docker Compose v2 belum terpasang."; exit 1; }
command -v openssl >/dev/null || { echo "openssl dibutuhkan untuk membuat secret."; exit 1; }

[ -f .env ] || cp .env.example .env

get() { grep -E "^$1=" .env | head -n1 | cut -d= -f2- | sed -e "s/^'//" -e "s/'\$//"; }
set_var() { # set_var KEY VALUE  (nilai disimpan dengan petik tunggal agar '$' aman)
  local tmp; tmp="$(mktemp)"
  grep -vE "^$1=" .env > "$tmp" || true
  printf "%s='%s'\n" "$1" "$2" >> "$tmp"
  cat "$tmp" > .env; rm -f "$tmp"
}
ask() { # ask KEY "Pertanyaan" [default]
  local cur; cur="$(get "$1")"
  if [ -z "$cur" ] || [[ "$cur" == *contoh.com ]]; then
    local ans; read -r -p "$2 [${3:-}]: " ans
    set_var "$1" "${ans:-${3:-}}"
  fi
}
gen() { [ -n "$(get "$1")" ] || set_var "$1" "$(openssl rand -hex "${2:-24}")"; }

echo "── Domain ──"
ask N8N_DOMAIN       "Domain n8n"        "n8n.localhost"
ask EVOLUTION_DOMAIN "Domain WhatsApp API" "wa.localhost"
ask DASHBOARD_DOMAIN "Domain dashboard"   "kantor.localhost"

echo "── Membuat secret ──"
gen POSTGRES_PASSWORD
gen N8N_ENCRYPTION_KEY 32
gen EVOLUTION_API_KEY 32
gen BROWSERLESS_TOKEN 24
gen WEBHOOK_SECRET 24

if [ -z "$(get DASHBOARD_PASS_HASH)" ]; then
  read -r -s -p "Password login dashboard: " DPASS; echo
  [ -n "$DPASS" ] || { echo "Password tidak boleh kosong."; exit 1; }
  HASH="$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$DPASS")"
  set_var DASHBOARD_PASS_HASH "$HASH"
fi

for k in SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_KEY; do
  if [ -z "$(get $k)" ]; then
    echo
    echo "⚠  $k masih kosong. Buat project Supabase, jalankan supabase/schema.sql,"
    echo "   lalu isi SUPABASE_URL, SUPABASE_ANON_KEY (kunci publishable sb_publishable_…)"
    echo "   dan SUPABASE_SERVICE_KEY (kunci secret sb_secret_…) di .env"
    echo "   dan jalankan ulang ./setup.sh. (Panduan: README.md, langkah 2)"
    exit 1
  fi
done

echo "── Menjalankan stack ──"
docker compose up -d --build

cat <<MSG

✅ Stack berjalan.

Langkah berikutnya:
  1. Buka  https://$(get N8N_DOMAIN)  → buat akun owner n8n.
  2. Jalankan  ./scripts/import-workflows.sh   (impor & aktifkan workflow inti)
  3. Jalankan  ./scripts/connect-wa.sh          (hubungkan WhatsApp, scan QR)
  4. Kirim "/echo halo" ke nomor WA itu → agen Echo menjawab,
     dan dashboard di https://$(get DASHBOARD_DOMAIN) ikut berubah status.
MSG
