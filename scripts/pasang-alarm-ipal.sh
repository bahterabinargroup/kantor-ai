#!/usr/bin/env bash
# Sekali saja, di server:  bash ~/kantor-ai/scripts/pasang-alarm-ipal.sh 628123456789
# (angka = nomor WhatsApp PEMILIK, format 62…, tanpa + dan tanpa 0 di depan). Alarm dikirim sebagai DM ke nomor itu.
set -euo pipefail
cd "$(dirname "$0")/.."
NOMOR="${1:?Pakai: bash scripts/pasang-alarm-ipal.sh 628123456789   (nomor WA Anda, format 62…)}"
case "$NOMOR" in *[!0-9]*|0*) echo "Nomor harus angka saja, diawali 62 (bukan 0, tanpa +)."; exit 1;; esac
JID="$NOMOR@s.whatsapp.net"
if grep -qE '^IPAL_ALERT_JID=' .env; then sed -i "s/^IPAL_ALERT_JID=.*/IPAL_ALERT_JID=$JID/" .env; else echo "IPAL_ALERT_JID=$JID" >> .env; fi
chmod +x scripts/alarm-ipal.sh
( crontab -l 2>/dev/null | grep -v alarm-ipal.sh || true; echo "* * * * * $HOME/kantor-ai/scripts/alarm-ipal.sh >> $HOME/alarm-ipal.log 2>&1" ) | crontab -
echo "Alarm terpasang. Mengirim pesan tes ke $NOMOR…"
rm -rf "$HOME/.alarm-ipal"
bash -c 'cd ~/kantor-ai && source /dev/null; set -a; . ./.env 2>/dev/null; set +a;
  docker compose exec -T -e TEXT="✅ Alarm IPAL aktif. Bila WhatsApp gagal membuka pesan di grup IPAL atau bot terputus, peringatan dikirim ke sini." n8n node -e "
fetch(\"http://evolution-api:8080/message/sendText/\"+(process.env.EVOLUTION_INSTANCE||\"kantor-ai\"),{method:\"POST\",headers:{apikey:process.env.EVOLUTION_API_KEY,\"Content-Type\":\"application/json\"},body:JSON.stringify({number:\"'"$JID"'\",text:process.env.TEXT})}).then(r=>console.log(\"HTTP \"+r.status)).catch(e=>console.log(\"ERR \"+e.message))"'
