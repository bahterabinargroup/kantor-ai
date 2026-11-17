#!/usr/bin/env bash
# Upgrade Evolution API (WhatsApp) ke versi baru dengan cadangan + pengecekan + jalan mundur otomatis.
# Pakai (di server):  cd ~/kantor-ai && bash scripts/upgrade-evolution.sh v2.3.7
# Sesi WhatsApp (QR) tersimpan di database 'evolution', jadi TIDAK perlu scan ulang. Putus sekitar 1–2 menit.
set -uo pipefail
cd "$(dirname "$0")/.."

NEW="${1:-v2.3.7}"
IMG="evoapicloud/evolution-api"
get() { grep -E "^$1=" .env | head -n1 | cut -d= -f2- | sed -e "s/^'//" -e "s/'\$//"; }
KEY="$(get EVOLUTION_API_KEY)"; INSTANCE="$(get EVOLUTION_INSTANCE)"; INSTANCE="${INSTANCE:-kantor-ai}"
OLD="$(get EVOLUTION_VERSION)"; OLD="${OLD:-v2.3.0}"
TS="$(date +%Y%m%d-%H%M%S)"
BK="$HOME/backup-evolution-$TS"

state() { # status koneksi instance dari dalam jaringan Docker
  docker compose exec -T n8n node -e "
fetch('http://evolution-api:8080/instance/connectionState/$INSTANCE',{headers:{apikey:'$KEY'}})
 .then(r=>r.json()).then(j=>console.log(j.instance&&j.instance.state||JSON.stringify(j))).catch(e=>console.log('ERR '+e.message))" 2>/dev/null | tail -n1
}
set_version() { # ubah/isi EVOLUTION_VERSION di .env
  if grep -qE '^EVOLUTION_VERSION=' .env; then sed -i "s/^EVOLUTION_VERSION=.*/EVOLUTION_VERSION=$1/" .env; else echo "EVOLUTION_VERSION=$1" >> .env; fi
}

echo "══ 1/5 Cek status sekarang ══"
S0="$(state)"; echo "Koneksi WhatsApp: $S0 (versi sekarang $OLD → tujuan $NEW)"
[ "$S0" = "open" ] || { echo "WhatsApp sedang tidak tersambung — selesaikan itu dulu. Dibatalkan."; exit 1; }

echo "══ 2/5 Unduh versi baru (bot belum disentuh) ══"
docker pull "$IMG:$NEW" || { echo "Versi $NEW tidak ditemukan. Dibatalkan, tidak ada yang berubah."; exit 1; }

echo "══ 3/5 Cadangkan database Evolution ══"
mkdir -p "$BK"
docker compose exec -T postgres pg_dump -U postgres -Fc evolution > "$BK/evolution.dump" || { echo "Cadangan gagal. Dibatalkan."; exit 1; }
cp .env "$BK/env.bak"
ls -lh "$BK"; [ -s "$BK/evolution.dump" ] || { echo "Cadangan kosong. Dibatalkan."; exit 1; }

echo "══ 4/5 Pasang versi baru ══"
set_version "$NEW"
docker compose up -d evolution-api
for i in $(seq 1 30); do sleep 5; S="$(state)"; echo "  [$i] $S"; [ "$S" = "open" ] && break; done

echo "══ 5/5 Hasil ══"
if [ "$S" = "open" ]; then
  echo "BERHASIL: Evolution $NEW tersambung. Cadangan di $BK"
  echo "Tes: kirim /echo di grup uji / DM ke bot dan pastikan membalas."
  docker compose logs --tail 15 evolution-api
else
  echo "GAGAL tersambung — kembali ke $OLD otomatis…"
  set_version "$OLD"
  docker compose up -d evolution-api
  for i in $(seq 1 24); do sleep 5; S="$(state)"; echo "  [$i] $S"; [ "$S" = "open" ] && break; done
  echo "Status setelah kembali: $S  (cadangan di $BK)"
  docker compose logs --tail 40 evolution-api
  exit 1
fi
