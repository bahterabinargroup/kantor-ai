#!/usr/bin/env bash
# Sekali saja, di server:  bash ~/kantor-ai/scripts/pasang-auto-update.sh git@github.com:AKUN/kantor-ai.git
set -euo pipefail
URL="${1:?Pakai: bash pasang-auto-update.sh git@github.com:AKUN/NAMA-REPO.git}"
KEY="$HOME/.ssh/kantor_deploy"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "kantor-ai-server" >/dev/null
  echo; echo "KUNCI DEPLOY (salin SEMUA baris di bawah, tempel di GitHub → repo → Settings → Deploy keys → Add, JANGAN centang write):"
  echo; cat "$KEY.pub"; echo
  read -rp "Kalau sudah ditambahkan di GitHub, tekan Enter… " _
fi
grep -q 'Host github.com' ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config <<CFG
Host github.com
  IdentityFile $KEY
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
CFG
chmod 600 ~/.ssh/config
command -v rsync >/dev/null || sudo apt-get install -y -qq rsync
[ -d ~/kantor-ai-repo/.git ] || git clone -q "$URL" ~/kantor-ai-repo
chmod +x ~/kantor-ai/scripts/auto-update.sh 2>/dev/null || true
cp ~/kantor-ai-repo/scripts/auto-update.sh ~/auto-update.sh 2>/dev/null || cp ~/kantor-ai/scripts/auto-update.sh ~/auto-update.sh
chmod +x ~/auto-update.sh
( crontab -l 2>/dev/null | grep -v auto-update.sh; echo "* * * * * $HOME/auto-update.sh" ) | crontab -
echo "SELESAI. Mulai sekarang server memperbarui diri sendiri tiap menit dari GitHub."
