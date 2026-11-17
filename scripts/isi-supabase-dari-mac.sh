#!/usr/bin/env bash
# Dijalankan DI MAC (bukan di server). Mengambil kunci API Supabase lewat Supabase CLI
# lalu menulisnya langsung ke ~/kantor-ai/.env di server lewat SSH.
# Kunci TIDAK ditampilkan di layar dan tidak lewat chat.
#
# Pemakaian:   bash scripts/isi-supabase-dari-mac.sh ubuntu@149.41.195.210 [project-ref]
# Syarat:      supabase CLI sudah login (supabase login), python3, ssh ke server tanpa password.
set -euo pipefail

TARGET="${1:?Pemakaian: bash $0 ubuntu@IP_SERVER [project-ref]}"
REF="${2:-kehrjbsflupwfzmkhdki}"

command -v supabase >/dev/null || { echo "Supabase CLI belum terpasang. Pasang: brew install supabase/tap/supabase"; exit 1; }
command -v python3  >/dev/null || { echo "python3 dibutuhkan."; exit 1; }

echo "Mengambil kunci dari Supabase (project $REF)…"
RAW="$(supabase projects api-keys --project-ref "$REF" -o json)" \
  || { echo "Gagal. Coba jalankan dulu:  supabase login"; exit 1; }

PAYLOAD="$(REF="$REF" RAW="$RAW" python3 - <<'PY'
import os, re, json, base64, sys

ref = os.environ["REF"]
data = json.loads(os.environ["RAW"])

vals = []
def walk(x):
    if isinstance(x, str): vals.append(x)
    elif isinstance(x, dict):
        for v in x.values(): walk(v)
    elif isinstance(x, list):
        for v in x: walk(v)
walk(data)

OK = re.compile(r'^[A-Za-z0-9_.\-]{20,}$')   # kunci utuh (bukan yang disamarkan •••)

def jwt_role(t):
    try:
        p = t.split(".")[1]; p += "=" * (-len(p) % 4)
        return json.loads(base64.urlsafe_b64decode(p)).get("role")
    except Exception:
        return None

pub = sec = anon = svc = None
for v in vals:
    if not OK.match(v): continue
    if v.startswith("sb_publishable_"): pub = pub or v
    elif v.startswith("sb_secret_"):    sec = sec or v
    elif v.count(".") == 2:
        r = jwt_role(v)
        if r == "anon":         anon = anon or v
        elif r == "service_role": svc = svc or v

anon_key = pub or anon
svc_key  = sec or svc
if not anon_key or not svc_key:
    sys.stderr.write("Kunci utuh tidak ditemukan (mungkin disamarkan). Isi manual lewat nano .env\n")
    sys.exit(2)
if not sec:
    sys.stderr.write("CATATAN: kunci secret baru tidak tersedia lewat CLI; memakai service_role lama "
                     "(masih jalan, tapi Supabase menghentikannya akhir 2026).\n")
print("SUPABASE_URL=https://%s.supabase.co" % ref)
print("SUPABASE_ANON_KEY=" + anon_key)
print("SUPABASE_SERVICE_KEY=" + svc_key)
PY
)" || exit 1

echo "Menulis ke .env di server…"
printf '%s\n' "$PAYLOAD" | ssh "$TARGET" 'python3 -c "
import sys, os
p = os.path.expanduser(\"~/kantor-ai/.env\")
new = dict(l.rstrip(chr(10)).split(\"=\", 1) for l in sys.stdin if \"=\" in l)
old = open(p).read().splitlines()
out = [l for l in old if l.split(\"=\", 1)[0] not in new]
out += [k + \"=\" + chr(39) + v + chr(39) for k, v in new.items()]
open(p, \"w\").write(chr(10).join(out) + chr(10))
print(\"OK:\", len(new), \"nilai Supabase tertulis (tidak ditampilkan).\")
"'
echo "Selesai. Di server, jalankan:  bash setup.sh"
