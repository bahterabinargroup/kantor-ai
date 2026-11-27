#!/usr/bin/env bash
# Memasang Rakazo (asisten AI berkomputer, open source) di VPS Kantor AI, bertahap dan aman.
# Pakai (di server):  cd ~/kantor-ai && bash scripts/pasang-rakazo.sh
# Tidak ada kunci rahasia yang diketik atau dicetak: semuanya dibuat acak oleh installer resmi Rakazo.
# Aman diulang: .env Rakazo yang sudah ada tidak ditimpa.
set -uo pipefail
cd "$(dirname "$0")/.."
KANTOR="$PWD"
RDIR="$HOME/rakazo"
TS="$(date +%Y%m%d-%H%M%S)"
die() { echo; echo "BERHENTI: $*"; exit 1; }
get() { grep -E "^$1=" "$2" 2>/dev/null | head -n1 | cut -d= -f2- | sed -e "s/^'//" -e "s/'\$//"; }
set_var() { # set_var NAMA NILAI  (di .env Rakazo)
  if grep -qE "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}
RC() { docker compose --env-file .env -f docker-compose.images.yml "$@"; }

echo "══ 1/7 Cek kesiapan server ══"
command -v docker >/dev/null || die "Docker tidak ditemukan."
VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1)"
[ "${VER:-0}" -ge 26 ] || die "Docker versi 26+ dibutuhkan (sekarang: ${VER:-tidak diketahui})."
MEM="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
DISK="$(df -BG --output=avail "$HOME" | tail -n1 | tr -dc '0-9')"
echo "RAM tersedia: ${MEM} MB · Disk kosong: ${DISK} GB"
[ "$MEM" -ge 2500 ] || die "RAM kosong kurang dari 2,5 GB. Rakazo + komputer botnya butuh ruang. Jangan dipasang dulu."
[ "$DISK" -ge 15 ] || die "Disk kosong kurang dari 15 GB (gambar komputer bot besar)."
grep -q 'RAKAZO_DOMAIN' caddy/Caddyfile || die "Perbaikan terbaru belum tersalin ke server. Tunggu 2 menit lalu ulangi."
grep -q 'RAKAZO_DOMAIN' docker-compose.yml || die "Perbaikan terbaru belum tersalin ke server. Tunggu 2 menit lalu ulangi."
DASH="$(get DASHBOARD_DOMAIN .env)"
case "$DASH" in kantor.*) RHOST="rakazo.${DASH#kantor.}";; *) die "Domain dashboard tidak dikenali ($DASH).";; esac
echo "Alamat Rakazo nanti: https://$RHOST"

echo; echo "══ 2/7 Cadangan ══"
BK="$HOME/backup-sebelum-rakazo-$TS"; mkdir -p "$BK"
cp .env "$BK/kantor.env"; cp caddy/Caddyfile "$BK/Caddyfile"; cp docker-compose.yml "$BK/docker-compose.yml"
chmod 600 "$BK/kantor.env"
echo "Tersimpan di $BK"

echo; echo "══ 3/7 Siapkan Rakazo (belum dijalankan) ══"
mkdir -p "$RDIR" && cd "$RDIR"
if [ ! -f install-images.sh ]; then
  curl -fsSLO https://raw.githubusercontent.com/elie222/rakazo/main/infra/compose/install-images.sh || die "Gagal mengunduh installer."
fi
bash install-images.sh --prepare-only || die "Persiapan installer gagal."
[ -f .env ] || die ".env Rakazo tidak terbentuk."
chmod 600 .env

echo; echo "══ 4/7 Pengaturan alamat & pembatasan pendaftaran ══"
EMAIL="$(get SIGNUP_ALLOWLIST .env)"
if [ -z "$EMAIL" ]; then
  read -r -p "Email Anda untuk akun Rakazo (satu-satunya yang boleh mendaftar): " EMAIL
  case "$EMAIL" in *@*.*) ;; *) die "Email tidak valid.";; esac
fi
set_var BETTER_AUTH_URL "https://$RHOST"
set_var WEB_ORIGIN "https://$RHOST"
set_var API_URL "https://$RHOST"
set_var RAKAZO_HOST "$RHOST"
set_var SIGNUPS_ENABLED true
set_var SIGNUP_ALLOWLIST "$EMAIL"
echo "Terpasang: alamat https://$RHOST · hanya $EMAIL yang boleh mendaftar."
echo "Gambar yang dipakai: $(get RAKAZO_IMAGE_TAG .env | sed 's/^$/(bawaan installer)/')"
echo
read -r -p "Lanjut memasang & menjalankan Rakazo sekarang? Ini mengunduh beberapa GB. Ketik 'ya': " OK
[ "$OK" = "ya" ] || die "Dibatalkan. Tidak ada layanan yang dijalankan."

echo; echo "══ 5/7 Pasang & jalankan Rakazo ══"
bash install-images.sh || die "Installer gagal. Layanan Kantor AI tidak tersentuh."
echo "Menunggu Rakazo siap (maks 3 menit)…"
UP=0
for i in $(seq 1 36); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5173/ || true)"
  [ "$CODE" = "200" ] && { UP=1; break; }; sleep 5
done
RC ps
[ "$UP" = 1 ] || die "Rakazo belum menjawab di 127.0.0.1:5173. Cek: cd ~/rakazo && docker compose --env-file .env -f docker-compose.images.yml logs --tail 50 api web"

echo; echo "══ 6/7 Sambungkan ke HTTPS (Caddy) ══"
cd "$KANTOR"
if grep -qE '^RAKAZO_DOMAIN=' .env; then sed -i "s|^RAKAZO_DOMAIN=.*|RAKAZO_DOMAIN=$RHOST|" .env; else echo "RAKAZO_DOMAIN=$RHOST" >> .env; fi
docker compose up -d caddy || die "Caddy gagal dimuat ulang. Pulihkan dengan: cp $BK/kantor.env .env && cp $BK/Caddyfile caddy/Caddyfile"
RNET="$(docker network ls --format '{{.Name}}' | grep -E '^rakazo[_-]' | head -n1)"
[ -n "$RNET" ] || die "Jaringan Docker Rakazo tidak ditemukan."
CADDY="$(docker compose ps -q caddy)"
docker network connect "$RNET" "$CADDY" 2>/dev/null || true
sleep 3
docker exec "$CADDY" wget -qO- --timeout=5 http://web:5173/ >/dev/null 2>&1 && echo "Caddy bisa menjangkau Rakazo ✔" || echo "⚠ Caddy belum bisa menjangkau Rakazo (web:5173)."

echo; echo "══ 7/7 Hasil ══"
sleep 5
echo "Layanan Kantor AI:"; docker compose ps --format 'table {{.Service}}\t{{.Status}}'
echo
echo "Buka  https://$RHOST  (sertifikat HTTPS bisa butuh ±1 menit pertama kali)."
echo "Daftar dengan email $EMAIL — akun pertama menjadi pemilik."
echo "Jangan jalankan 'docker compose down -v' di folder ~/rakazo: itu menghapus semua data Rakazo."
