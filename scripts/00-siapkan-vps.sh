#!/usr/bin/env bash
# Menyiapkan VPS Ubuntu 24.04 yang masih kosong: Docker + Compose v2, firewall, swap.
# Jalankan SEKALI sebagai root:   sudo bash scripts/00-siapkan-vps.sh
# Aman diulang (tidak merusak kalau sudah terpasang).
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root: sudo bash $0"; exit 1; }
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || { echo "Skrip ini untuk Ubuntu (terdeteksi: ${ID:-?})."; exit 1; }

export DEBIAN_FRONTEND=noninteractive

echo "── 1/4 Update sistem ──"
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg ufw git unzip

echo "── 2/4 Pasang Docker (repo resmi) ──"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
# Beri user yang menjalankan sudo (mis. "ubuntu") hak memakai docker tanpa sudo.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  usermod -aG docker "${SUDO_USER}"
  echo "User ${SUDO_USER} ditambahkan ke grup docker (aktif setelah login SSH ulang)."
fi
docker --version
docker compose version

echo "── 3/4 Firewall: hanya SSH, HTTP, HTTPS ──"
# Port 5678 (n8n), 8080 (Evolution), 3000 (Browserless) SENGAJA tidak dibuka:
# semuanya hanya diakses lewat Caddy (80/443) atau jaringan internal Docker.
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose

echo "── 4/4 Swap 2 GB (jaring pengaman kalau RAM penuh) ──"
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  echo "Swap sudah ada, dilewati."
fi

echo
echo "Selesai."
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  echo "PENTING: ketik  exit  lalu masuk SSH lagi (supaya hak docker aktif), kemudian:"
  echo "  cd kantor-ai && bash setup.sh"
else
  echo "Berikutnya (di folder kantor-ai):  bash setup.sh"
fi
