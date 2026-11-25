#!/usr/bin/env bash
# Sekali saja, di server:  bash ~/kantor-ai/scripts/pasang-vps-stats.sh
# Memasang pencatat kondisi VPS (jalan tiap menit) untuk halaman /vps.html di dashboard.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v python3 >/dev/null || { echo "python3 tidak ada"; exit 1; }
# Folder data/ bisa dimiliki root (dibuat Docker), jadi pakai sudo bila perlu.
mkdir -p data/vps 2>/dev/null || sudo mkdir -p data/vps
sudo chown -R "$USER":"$USER" data/vps
sudo chmod 755 data data/vps
chmod +x scripts/vps-stats.py
( crontab -l 2>/dev/null | grep -v vps-stats.py || true; echo "* * * * * /usr/bin/python3 $HOME/kantor-ai/scripts/vps-stats.py >> $HOME/vps-stats.log 2>&1" ) | crontab -
echo "Menjalankan pencatatan pertama…"
python3 scripts/vps-stats.py && sleep 2 && python3 scripts/vps-stats.py
ls -l data/vps
echo "SELESAI. Buka halaman  /vps.html  di dashboard (data terisi penuh setelah beberapa menit)."
