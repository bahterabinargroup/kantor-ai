# Kantor AI — Serah-terima: memasang Rakazo di VPS (untuk Claude Code)

Baca dulu `kantor-ai/HANDOFF.md` (konteks sistem). Dokumen ini khusus tugas **memasang Rakazo di VPS Kantor AI**.
Pemilik: **Raka** (bukan programmer). Balas dalam **bahasa Indonesia sederhana, langkah demi langkah**; setiap istilah teknis diberi penjelasan satu kalimat.
Aturan tetap: cek connector & skill yang tersedia dulu; **jangan minta rahasia ditempel di chat** (kunci API, token, password); **tanya dulu sebelum mengubah server produksi**; jangan push `.env`/rahasia ke GitHub.

## 1. Tujuan
Menjalankan **Rakazo** (https://github.com/elie222/rakazo, Apache-2.0, ±9,9 rb bintang; "alternatif Grok Bot" open source: bot AI yang punya memori, rutinitas terjadwal, komputer + browser sendiri, subagen, integrasi Gmail/Slack/Notion/MCP) di **VPS yang sama dengan Kantor AI** sebagai uji coba "otak tambahan" untuk tugas tak tetap. Rakazo **tidak menggantikan** pipeline n8n/Evolution yang sudah stabil (IPAL, Admin Berdikari).

## 2. Keputusan Raka (jangan diubah tanpa tanya)
- Dipasang di **VPS Kantor AI (Sumopod Jakarta, `149.41.195.210`, user `ubuntu`)**, komputer bot berjalan di **Docker lokal** (`SANDBOX_PROVIDER=docker`, bawaan). Raka sudah diberi tahu risikonya dan memilih ini. Alternatif yang ditolak: E2B (cloud), VPS baru terpisah.
- Alamat: `https://rakazo.149-41-195-210.sslip.io` (sslip.io, tanpa beli domain; pola sama dengan `kantor.`/`n8n.`/`wa.`).
- Hanya email Raka yang boleh mendaftar (allowlist). Akun pertama = pemilik.
- Raka sendiri mengisi kunci model (OpenRouter dsb.) di layar onboarding Rakazo. Bukan lewat chat.

## 3. Status saat serah-terima (27 Nov 2026)
- Skrip pemasang sudah ditulis dan di-push: **`scripts/pasang-rakazo.sh`** (commit `a307d5a`, repo `bahterabinargroup/kantor-ai`, cabang `main`). Perubahan ikut: blok `{$RAKAZO_DOMAIN}` di `caddy/Caddyfile` (`reverse_proxy web:5173`) dan `RAKAZO_DOMAIN` (default `rakazo.localhost`) di environment Caddy pada `docker-compose.yml`.
- **Skrip BELUM pernah dijalankan dan BELUM teruji** (penulisnya tidak punya akses server/Docker). Anggap setiap langkah belum terbukti.
- Server menyalin repo ke `~/kantor-ai` otomatis tiap menit (`~/auto-update.sh`, log `~/kantor-ai-update.log`; folder itu BUKAN repo git; `.env`, `.git`, `data/` tidak ditimpa).

## 4. Fakta Rakazo yang sudah diverifikasi (dari docs/self-host.md & tutorial pihak ketiga)
- Pemasangan: folder kosong → `curl` `install-images.sh` dari `raw.githubusercontent.com/elie222/rakazo/main/infra/compose/` → `bash install-images.sh`. `--prepare-only` hanya menulis `.env` (rahasia acak) lalu berhenti; `.env` yang sudah ada tidak ditimpa. Syarat: Docker Engine 26+, plugin Compose, curl, OpenSSL.
- Isi stack: Postgres, API (3100), Graphile Worker, pengawas sandbox, web (Vite, 5173) + **satu kontainer "komputer" Linux grafis per bot**. Gambar `ghcr.io/elie222/rakazo/app` dan `.../computer` (besar).
- Web terikat **127.0.0.1:5173**, API **127.0.0.1:3100** (jangan diekspos), Postgres tidak dipublikasikan. Proxy HTTPS cukup meneruskan 5173 (`/api`, `/rpc` sudah di-proxy oleh web).
- `.env` penting: `BETTER_AUTH_URL`, `WEB_ORIGIN`, `API_URL` harus origin HTTPS yang sama; `RAKAZO_HOST` = hostname saja (kalau tetap `localhost` semua permintaan ditolak, "Blocked request"); `RAKAZO_IMAGE_TAG` (default `edge`); `SANDBOX_PROVIDER`; `ENCRYPTION_KEY` **jangan diganti** setelah dipakai.
- Pembatasan daftar (dari tutorial lumadock, **bukan** dari docs resmi — verifikasi di `docs/self-host-accounts.md` & `self-host-configuration.md`): `SIGNUPS_ENABLED=true` + `SIGNUP_ALLOWLIST=<email>`; `SIGNUPS_ENABLED` hanya dibaca saat API pertama start; **pengguna pertama menjadi owner** → allowlist harus terpasang SEBELUM start pertama.
- Sumber docs: https://raw.githubusercontent.com/elie222/rakazo/master/docs/self-host.md
- `docker compose down -v` di folder Rakazo **menghapus semua data Postgres**. Jangan pernah pakai `-v`.

## 5. Risiko yang harus selalu diingat
1. **Soket Docker:** pengawas sandbox me-mount `/var/run/docker.sock` → siapa pun yang menguasai pengawas/bot bisa menguasai host (WhatsApp/Evolution, `.env`, kunci Supabase). Server ini produksi (laporan IPAL, data bisnis nyata). Jangan pernah mempublikasikan 5173/3100/Postgres; hanya lewat Caddy HTTPS. Jangan beri bot akses ke akun penting (Supabase, bank, Google Raka) selama uji coba.
2. **Beban:** VPS 2 inti, RAM 7,4 GB (terpakai ±2,1 GB saat idle), disk 98 GB (17% terpakai). Dokumentasi Rakazo: 4 GB = batas minimum jika sandbox di VPS sendiri; tiap bot aktif menambah kontainer. Pantau di halaman **Kondisi VPS** (`/vps.html`). Jika RAM tersedia < ±1,5 GB atau n8n/Evolution melambat → hentikan Rakazo (`docker compose --env-file .env -f docker-compose.images.yml stop` di `~/rakazo`).
3. **Tag gambar `edge`** = versi terbaru yang belum tentu stabil. Setelah jalan, usulkan mengunci ke rilis tertentu (`RAKAZO_IMAGE_TAG=vX.Y.Z`, cek tag yang ada di GitHub Releases/ghcr).
4. **Jaringan Caddy ↔ Rakazo:** Caddy (kontainer Kantor AI) tidak bisa menjangkau 127.0.0.1 host. Skrip memakai `docker network connect <rakazo_default> <caddy>` agar `web:5173` terjangkau. Asumsi (belum diuji): koneksi ini bertahan saat reboot/restart kontainer tetapi **hilang bila kontainer Caddy dibuat ulang** (`docker compose up -d caddy` setelah perubahan konfigurasi) → ulangi `network connect`. Bila gagal permanen, pertimbangkan blok `networks:` eksternal di compose, tetapi hati-hati: bila jaringan eksternal tidak ada, Caddy gagal start dan SEMUA HTTPS (dashboard, n8n, WhatsApp webhook) mati.
5. Memuat ulang Caddy memutus HTTPS beberapa detik (dashboard, n8n, webhook WhatsApp).

## 6. Langkah kerja yang disarankan
1. Di server, pastikan perbaikan terbaru tersalin: `grep -c RAKAZO_DOMAIN ~/kantor-ai/caddy/Caddyfile ~/kantor-ai/docker-compose.yml` (harus ≥1 di keduanya) dan `tail -5 ~/kantor-ai-update.log`.
2. Cek kesiapan: `docker version --format '{{.Server.Version}}'` (≥26), `free -m`, `df -h ~`, dan `docker compose -f ~/kantor-ai/docker-compose.yml ps` (semua `Up`).
3. **Baca** `~/kantor-ai/scripts/pasang-rakazo.sh` sebelum menjalankan (skrip belum teruji). Perbaiki bila ada kesalahan (kirim perbaikan lewat commit ke GitHub; jangan edit langsung di `~/kantor-ai` karena ditimpa rsync).
4. Jalankan: `cd ~/kantor-ai && bash scripts/pasang-rakazo.sh`. Skrip: cek RAM/disk → cadangan (`~/backup-sebelum-rakazo-<ts>/`) → `--prepare-only` di `~/rakazo` → set URL/host/allowlist (menanyakan email Raka) → minta ketik `ya` → pasang & start → tunggu 127.0.0.1:5173 → set `RAKAZO_DOMAIN` di `~/kantor-ai/.env`, `docker compose up -d caddy`, `docker network connect` → tes `wget http://web:5173/` dari kontainer Caddy.
   - Karena skrip interaktif (email, ketik `ya`), jalankan di terminal yang ada pengguna; atau minta Raka mengetikkan dua jawaban itu.
5. Verifikasi: `https://rakazo.149-41-195-210.sslip.io` memuat halaman login dengan sertifikat valid (butuh ±1 menit pertama kali); `docker compose --env-file .env -f docker-compose.images.yml ps` di `~/rakazo` — Postgres, supervisor, API, worker, web **Up** (`computer` dan `data-init` boleh `exited`); Kantor AI tetap sehat: `cd ~/kantor-ai && docker compose ps`, dashboard `/vps.html`, dan WhatsApp masih `open` (bot membalas / status di dashboard).
6. Raka mendaftar dengan email allowlist, mengisi kunci model di onboarding, membuat satu bot uji, membuka **Agent computer** dan memastikan desktop Linux tampil.
7. Setelah stabil: usulkan pin versi gambar, cek pemakaian RAM beberapa hari, dan tanya apakah akan dihubungkan ke Kantor AI (mis. memanggil Rakazo lewat n8n/MCP). **Jangan** menyambungkan Rakazo ke Supabase produksi atau ke sesi WhatsApp Evolution tanpa persetujuan Raka.

## 7. Cadangan & jalan mundur
- Cadangan otomatis: `~/backup-sebelum-rakazo-<ts>/` (`kantor.env` mode 600, `Caddyfile`, `docker-compose.yml`).
- Pulihkan Caddy: `cd ~/kantor-ai && cp ~/backup-sebelum-rakazo-<ts>/kantor.env .env` (hati-hati: ini menimpa `.env`; cukup hapus baris `RAKAZO_DOMAIN` bila hanya itu yang berubah), lalu pastikan Caddyfile/compose kembali dari repo (revert commit `a307d5a` bila perlu), `docker compose up -d caddy`.
- Hentikan Rakazo tanpa menghapus data: `cd ~/rakazo && docker compose --env-file .env -f docker-compose.images.yml stop`. Copot sepenuhnya hanya bila Raka minta, dan **tanpa `-v`** kecuali Raka memang rela datanya hilang.

## 8. Konteks terbaru Kantor AI (sejak HANDOFF.md 17 Nov)
- Evolution API sudah **v2.3.7** (`EVOLUTION_VERSION` di `.env`; skrip `scripts/upgrade-evolution.sh`). Kegagalan dekripsi WhatsApp ("No SenderKeyRecord") masih terjadi sesekali; ada alarm pribadi `scripts/alarm-ipal.sh` (cron tiap menit) dan `ipal_reconcile` sebelum pengingat.
- Pengingat IPAL: sore **20:00** WIB (Sen–Jum) dan pagi 06:00 (Sel–Sab); teks sopan; menyebut hari+tanggal; selalu ada ucapan terima kasih bila semua dapur lapor. Kedungsari libur sampai 20 Nov (tabel `ipal_libur`).
- Halaman **Kondisi VPS** (`dashboard/vps.html`, pencatat `scripts/vps-stats.py` lewat cron, pemasang `scripts/pasang-vps-stats.sh`) sudah aktif; server sudah di-reboot 26 Nov (tidak lagi "System restart required").
- Login dashboard: basic auth Caddy (`DASHBOARD_USER`, `DASHBOARD_PASS_HASH` di `.env`); cara membuat ulang kata sandi: `docker run --rm -it caddy:2-alpine caddy hash-password`.
- Daftar rapikan nanti (belum): domain asli, ganti kunci `service_role` legacy dengan `sb_secret_`, pin versi image, Postgres 17, backup, `WA_ALLOWED_CHATS`.

## 9. Hal yang belum diketahui / perlu dicek
- Apakah variabel `SIGNUPS_ENABLED`/`SIGNUP_ALLOWLIST` benar menurut docs resmi saat ini.
- Apakah kontainer `web` Rakazo mendengarkan di semua antarmuka di dalam jaringan Docker (asumsi skrip: ya, nama layanan `web`, port 5173) dan nama jaringannya `rakazo_default`.
- Apakah `docker network connect` bertahan saat reboot.
- Kebutuhan RAM nyata per bot aktif; apakah Rakazo punya cara membatasi memori kontainer komputer.
- Apakah Rakazo punya integrasi WhatsApp (README tidak menyebutnya). Bila Raka ingin bot ini ikut grup WhatsApp, pilihan lain yang dibahas: **Hermes Agent** (Nous Research, mendukung WhatsApp) — jangan menyambung ke sesi Evolution yang sama.
