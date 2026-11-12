#!/usr/bin/env bash
# Membuat instance WhatsApp di Evolution API, memasang webhook ke n8n, dan menampilkan cara scan QR.
set -euo pipefail
cd "$(dirname "$0")/.."

get() { grep -E "^$1=" .env | head -n1 | cut -d= -f2- | sed -e "s/^'//" -e "s/'\$//"; }
KEY="$(get EVOLUTION_API_KEY)"
INSTANCE="$(get EVOLUTION_INSTANCE)"; INSTANCE="${INSTANCE:-kantor-ai}"
SECRET="$(get WEBHOOK_SECRET)"
BASE="https://$(get EVOLUTION_DOMAIN)"
# Evolution memanggil n8n lewat jaringan Docker (tidak lewat internet)
HOOK="http://n8n:5678/webhook/wa-incoming?secret=${SECRET}"

api() { # api METODE PATH [BODY] → cetak "kode_http" di baris terakhir
  curl -sS -k -X "$1" "$BASE$2" -H "apikey: $KEY" -H "Content-Type: application/json" \
    ${3:+-d "$3"} -w '\n%{http_code}'
}

echo "── Membuat instance '$INSTANCE' ──"
OUT="$(api POST /instance/create "{\"instanceName\":\"$INSTANCE\",\"qrcode\":true,\"integration\":\"WHATSAPP-BAILEYS\"}")" || true
echo "$OUT" | head -n -1 | head -c 300; echo
CODE="$(echo "$OUT" | tail -n1)"
case "$CODE" in 2*) ;; 403|409) echo "(instance sudah ada — lanjut)";; *) echo "Gagal membuat instance (HTTP $CODE)"; exit 1;; esac

echo "── Memasang webhook ke n8n ──"
EVENTS='["MESSAGES_UPSERT"]'
FLAT="{\"enabled\":true,\"url\":\"$HOOK\",\"webhookByEvents\":false,\"webhookBase64\":true,\"events\":$EVENTS}"
WRAP="{\"webhook\":{\"enabled\":true,\"url\":\"$HOOK\",\"byEvents\":false,\"base64\":true,\"events\":$EVENTS}}"
OUT="$(api POST "/webhook/set/$INSTANCE" "$FLAT")"; CODE="$(echo "$OUT" | tail -n1)"
if [[ "$CODE" != 2* ]]; then
  OUT="$(api POST "/webhook/set/$INSTANCE" "$WRAP")"; CODE="$(echo "$OUT" | tail -n1)"
fi
[[ "$CODE" == 2* ]] && echo "Webhook terpasang." || { echo "Gagal memasang webhook (HTTP $CODE):"; echo "$OUT" | head -n -1; exit 1; }

cat <<MSG

Scan QR:
  • Buka  $BASE/manager  → login dengan EVOLUTION_API_KEY → pilih instance '$INSTANCE' → Connect.
  • Di HP: WhatsApp → Perangkat tertaut → Tautkan perangkat → scan.

Setelah tertaut, kirim "/echo halo" dari chat lain ke nomor itu.
Untuk membatasi grup/chat yang boleh memicu agen, isi WA_ALLOWED_CHATS di .env
(JID chat terlihat di n8n → Executions → workflow "00 · Core WA Router" → node Normalize).
MSG
