#!/usr/bin/env bash
# Cari ID (JID) grup WhatsApp berdasarkan sebagian nama. Contoh:
#   bash scripts/cari-grup-wa.sh "IPAL"
# Bot harus sudah masuk ke grup itu.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
CARI="${1:-}"
[ -n "$CARI" ] || { echo "Pakai: bash scripts/cari-grup-wa.sh \"IPAL\""; exit 1; }
curl -fsS -H "apikey: $EVOLUTION_API_KEY" \
  "https://${EVOLUTION_DOMAIN}/group/fetchAllGroups/${EVOLUTION_INSTANCE:-kantor-ai}?getParticipants=false" \
| CARI="$CARI" python3 -c '
import json,os,sys
c=os.environ["CARI"].lower(); hit=0
for g in json.load(sys.stdin):
    if c in (g.get("subject") or "").lower():
        print(g["id"], "  ", g["subject"]); hit+=1
if not hit: print("Tidak ada grup yang cocok. Pastikan bot sudah masuk grup.")
'
