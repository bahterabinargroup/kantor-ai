#!/usr/bin/env bash
# Alarm pribadi untuk grup IPAL: kirim DM ke pemilik bila (1) WhatsApp gagal membuka pesan di grup IPAL
# ("failed to decrypt message") atau (2) bot terputus dari WhatsApp. Dijalankan cron tiap menit (lihat pasang-alarm-ipal.sh).
# Butuh di .env:  IPAL_ALERT_JID=628xxxxxxxxxx@s.whatsapp.net   (nomor WA pemilik, BUKAN rahasia)
set -uo pipefail
cd "$(dirname "$0")/.."

get() { grep -E "^$1=" .env | head -n1 | cut -d= -f2- | sed -e "s/^'//" -e "s/'\$//"; }
ALERT="$(get IPAL_ALERT_JID)"; GROUP="$(get IPAL_GROUP_JID)"; KEY="$(get EVOLUTION_API_KEY)"
INSTANCE="$(get EVOLUTION_INSTANCE)"; INSTANCE="${INSTANCE:-kantor-ai}"
SB_URL="$(get SUPABASE_URL)"; SB_KEY="$(get SUPABASE_SERVICE_KEY)"
[ -n "$ALERT" ] && [ -n "$GROUP" ] || exit 0
ST="$HOME/.alarm-ipal"; mkdir -p "$ST"; touch "$ST/seen" "$ST/cooldown"

kirim() { # kirim "teks" → DM lewat Evolution (jaringan Docker)
  TEXT="$1" docker compose exec -T -e TEXT n8n node -e "
fetch('http://evolution-api:8080/message/sendText/$INSTANCE',{method:'POST',
 headers:{apikey:'$KEY','Content-Type':'application/json'},
 body:JSON.stringify({number:'$ALERT',text:process.env.TEXT,delay:500})})
 .then(r=>console.log('HTTP '+r.status)).catch(e=>console.log('ERR '+e.message))" 2>/dev/null | tail -n1
}
dapur_dari() { # tebak nama dapur dari pengirim (riwayat laporan); kosong bila tidak ketemu
  [ -n "$SB_URL" ] && [ -n "$SB_KEY" ] || return 0
  curl -sS -m 10 -G "$SB_URL/rest/v1/ipal_reports" -H "apikey: $SB_KEY" -H "Authorization: Bearer $SB_KEY" \
    --data-urlencode "select=kitchen_id" --data-urlencode "sender=eq.$1" --data-urlencode "kitchen_id=not.is.null" \
    --data-urlencode "order=id.desc" --data-urlencode "limit=1" 2>/dev/null \
  | python3 -c "import sys,json
try:
  r=json.load(sys.stdin); print(r[0]['kitchen_id'] if r else '')
except Exception: print('')"
}

sudah_tercatat() { # sudah_tercatat PENGIRIM T0 T1 → "ya" bila ada laporan pengirim itu tercatat sekitar waktu pesan gagal
  [ -n "$SB_URL" ] && [ -n "$SB_KEY" ] || { echo tidak; return 0; }
  A="$(date -u -d "@$(( $2 - 180 ))" '+%Y-%m-%dT%H:%M:%SZ')"; B="$(date -u -d "@$(( $3 + 480 ))" '+%Y-%m-%dT%H:%M:%SZ')"
  curl -sS -m 10 -G "$SB_URL/rest/v1/ipal_reports" -H "apikey: $SB_KEY" -H "Authorization: Bearer $SB_KEY" \
    --data-urlencode "select=id" --data-urlencode "sender=eq.$1" --data-urlencode "kitchen_id=not.is.null" \
    --data-urlencode "reported_at=gte.$A" --data-urlencode "limit=1" -H "Range-Unit: items" 2>/dev/null \
  | python3 -c "import sys,json
try:
  print('ya' if json.load(sys.stdin) else 'tidak')
except Exception: print('tidak')" 
}

# ── 1) Pesan gagal dibuka di grup IPAL ──
LOGS="$(docker compose logs evolution-api --since 12m --no-log-prefix 2>&1)"
NOW="$(date +%s)"
echo "$LOGS" | python3 -c "
import sys, json
group, seenf, cdf, now = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
from datetime import datetime, timezone, timedelta
seen = set(open(seenf).read().split())
cd = {}
for l in open(cdf).read().splitlines():
    p = l.split()
    if len(p) == 2: cd[p[0]] = int(p[1])
out = {}
for line in sys.stdin:
    if 'failed to decrypt message' not in line: continue
    i = line.find('{')
    if i < 0: continue
    try: j = json.loads(line[i:])
    except Exception: continue
    k = j.get('key') or {}
    if k.get('remoteJid') != group or k.get('fromMe'): continue
    mid = k.get('id'); who = k.get('participant') or '?'
    if not mid or mid in seen: continue
    if now - j.get('time', 0) / 1000 < 240: continue   # tunggu 4 menit: beri waktu laporan (foto lain di album) tercatat
    if now - cd.get(who, 0) < 300: continue        # sudah diperingatkan <5 menit lalu; ikut di peringatan berikutnya
    t = datetime.fromtimestamp(j.get('time', 0) / 1000, timezone(timedelta(hours=7))).strftime('%H:%M')
    ts = int(j.get('time', 0) / 1000)
    o = out.setdefault(who, {'ids': [], 'jam': t, 't0': ts, 't1': ts}); o['ids'].append(mid)
    o['t0'] = min(o['t0'], ts); o['t1'] = max(o['t1'], ts)
for who, o in out.items():
    print(json.dumps({'who': who, 'n': len(o['ids']), 'jam': o['jam'], 'ids': o['ids'], 't0': o['t0'], 't1': o['t1']}))
" "$GROUP" "$ST/seen" "$ST/cooldown" "$NOW" > "$ST/baru.jsonl"

while IFS= read -r row; do
  [ -n "$row" ] || continue
  WHO="$(echo "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["who"])')"
  N="$(echo "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["n"])')"
  JAM="$(echo "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["jam"])')"
  IDS="$(echo "$row" | python3 -c 'import sys,json;print(" ".join(json.load(sys.stdin)["ids"]))')"
  T0="$(echo "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["t0"])')"
  T1="$(echo "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["t1"])')"
  if [ "$(sudah_tercatat "$WHO" "$T0" "$T1")" = "ya" ]; then
    echo $IDS | tr ' ' '\n' >> "$ST/seen"     # laporan tetap tercatat (foto lain di album masuk) → tidak perlu alarm
    continue
  fi
  DAPUR="$(dapur_dari "$WHO")"
  ORANG="${DAPUR:+dapur $DAPUR (}$WHO${DAPUR:+)}"
  MSG="⚠️ ALARM IPAL: $N pesan di grup IPAL GAGAL dibuka bot, dari $ORANG, sekitar jam $JAM WIB.
Laporan ini BELUM tercatat. Minta Claude mencatat manual (sebut dapur & jam), jangan minta dapur kirim ulang."
  R="$(kirim "$MSG")"
  if echo "$R" | grep -q "HTTP 2"; then
    echo $IDS | tr ' ' '\n' >> "$ST/seen"
    grep -v "^$WHO " "$ST/cooldown" > "$ST/cd.tmp" 2>/dev/null; echo "$WHO $NOW" >> "$ST/cd.tmp"; mv "$ST/cd.tmp" "$ST/cooldown"
  fi
done < "$ST/baru.jsonl"
tail -n 500 "$ST/seen" > "$ST/seen.tmp" && mv "$ST/seen.tmp" "$ST/seen"

# ── 2) Bot terputus dari WhatsApp (dua pengecekan berturut-turut) ──
S="$(docker compose exec -T n8n node -e "
fetch('http://evolution-api:8080/instance/connectionState/$INSTANCE',{headers:{apikey:'$KEY'}})
 .then(r=>r.json()).then(j=>console.log(j.instance&&j.instance.state||'?')).catch(e=>console.log('ERR'))" 2>/dev/null | tail -n1)"
if [ "$S" = "open" ]; then
  if [ -f "$ST/down-alerted" ]; then rm -f "$ST/down-alerted"; kirim "✅ Bot WhatsApp tersambung lagi. Pesan selama terputus tidak akan tercatat — cek grup IPAL dan minta Claude mencatat bila ada." >/dev/null; fi
  rm -f "$ST/down-count"
else
  C=$(( $(cat "$ST/down-count" 2>/dev/null || echo 0) + 1 )); echo "$C" > "$ST/down-count"
  if [ "$C" -ge 2 ] && [ ! -f "$ST/down-alerted" ]; then
    R="$(kirim "⚠️ ALARM: bot WhatsApp TERPUTUS (status: $S). Laporan dapur yang masuk sekarang tidak diterima bot.")"
    # bila WA terputus, DM juga gagal terkirim; tandai saja agar tidak berulang
    touch "$ST/down-alerted"
  fi
fi
