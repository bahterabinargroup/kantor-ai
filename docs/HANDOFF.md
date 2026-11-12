# Kantor AI — Catatan serah-terima untuk sesi/chat lain

Baca ini dulu sebelum mengerjakan agen baru. Pemilik: **Raka** (bukan programmer).
Balas dalam **bahasa Indonesia sederhana, langkah demi langkah**. Selalu cek connector & skill yang tersedia dulu sebelum cara lain.
Jangan minta rahasia (kunci/token/password) ditempel di chat. `.env` hanya ada di server.

## 1. Gambaran
Sistem multi-agen "Kantor AI" di satu VPS (Sumopod Jakarta, `149.41.195.210`, user `ubuntu`, repo server di `~/kantor-ai`).
Docker Compose: postgres, redis, **evolution-api** (WhatsApp/Baileys), **n8n**, browserless, dashboard (nginx), caddy.
Domain (sslip.io): `n8n.` / `wa.` / `kantor.149-41-195-210.sslip.io`. Dashboard: https://kantor.149-41-195-210.sslip.io/ (basic auth, user `admin`).
Database agen ada di **Supabase cloud**, project `kantor-ai`, ref `kehrjbsflupwfzmkhdki`. Dashboard 3D (kantor isometrik) membaca Supabase realtime.

Agen yang sudah ada: `echo` (uji pipeline) dan **`ipal`** (laporan harian 9 dapur MBG di grup WA "LAPORAN BERSIH2 IPAL"; JANGAN diubah tanpa alasan, lihat `supabase/ipal.sql` dan `agent:ipal`).
Rencana agen berikutnya (masing-masing di chat sendiri): Akuntan Berdikari Koffee, Editor video, Scraper, analisis iklan TikTok.

## 2. Cara mengirim perubahan (SUDAH OTOMATIS, Raka tidak perlu download/upload/terminal)
Repo GitHub privat: **`bahterabinargroup/kantor-ai`** (cabang `main`). Server menjalankan cron tiap menit (`~/auto-update.sh`):
`git fetch` → kalau ada commit baru → rsync ke `~/kantor-ai` (tanpa `.env`) → `scripts/import-workflows.sh` → `docker compose up -d --build dashboard` → restart caddy. Log: `~/kantor-ai-update.log` di server.

Alur kerja untuk sesi Claude:
1. `add_repo` (owner `bahterabinargroup`, repo `kantor-ai`, access `push`), clone ke folder BARU (bukan folder kerja yang sudah ada), `git fetch` dan **rebase sebelum push** (ada beberapa chat bekerja bersamaan).
2. Ubah file, commit kecil dengan pesan jelas, `git push origin main`. Dalam ±1 menit server memasangnya.
3. **SQL Supabase TIDAK ikut otomatis.** Terapkan sendiri lewat built-in browser (lihat §5), dan simpan juga di `supabase/*.sql` di repo (idempoten: `create or replace`, `if not exists`).
4. Perubahan `.env` / rahasia baru: tidak lewat GitHub. Beri Raka langkah manual di server, jangan minta nilai rahasianya.

Jangan push file `.env`, kunci, token. Jangan ubah kunci deploy / cron.

## 3. Kontrak agen (ringkas; detail di `docs/TAMBAH-AGEN.md`)
- Satu agen = baris di tabel `agents` (id, name, emoji, color, role, triggers, enabled, status, ...) + workflow n8n `agent:<id>` dengan webhook `agent-<id>` (internal `http://n8n:5678/webhook/agent-<id>`).
- Routing WhatsApp: `00 · Core WA Router` → RPC `dispatch_message` mencocokkan `agents.triggers` (dan `/<id>`; trigger `@media` untuk foto/video tanpa caption di grup) → buat baris `tasks` → panggil webhook agen.
- Dalam workflow agen: `lib:set-status` (Kerja/Santai/Macet), `lib:send-wa` (kirim WhatsApp), RPC `finish_task` di akhir. Status lain: `sleeping` otomatis lewat `sys:housekeeping` (idle > 30 mnt; tugas > 15 mnt gagal).
- Agen bisa dimatikan Raka dari dashboard (`agents.enabled=false`); fungsi agen WAJIB diam kalau `enabled=false` (lihat pola di `ipal.sql`).
- Posisi meja di dashboard 3D otomatis (urut nama); `agents.desk` tidak dipakai. Nama/logo(emoji)/warna bisa diubah Raka dari dashboard (RPC `update_agent_profile`).
- Caddy memblokir akses luar ke `/webhook/agent-*`, `lib-*`, `ctl-*`, `wa-incoming*`. Dashboard→n8n hanya lewat `/api/agent-toggle` dan `/api/agent-profile`.

## 4. Aturan Supabase (penting)
- RLS: `anon` hanya `SELECT` di `agents` dan `agent_events`. Semua tulis lewat fungsi RPC; **setiap fungsi baru wajib** `revoke all ... from public, anon, authenticated` + `grant execute ... to service_role` (lihat loop grant di akhir `schema.sql` / `ipal.sql`). n8n memanggil RPC dengan kunci service (di `.env` server).
- Realtime aktif di `agents` dan `agent_events`.
- Tabel agen baru: awali dengan nama agen (mis. `ipal_*`), jangan beri akses anon.
- Zona waktu bisnis: Asia/Jakarta (WIB). Cron n8n memakai `settings.timezone`.

## 5. Menjalankan SQL di Supabase (tanpa Raka)
Pakai built-in browser: `request_access` ke supabase.com (scope once) → navigate `https://supabase.com/dashboard/project/kehrjbsflupwfzmkhdki/sql/new` → isi editor lewat `window.monaco.editor.getModels()[0].setValue(String.raw\`...\`)` (hati-hati karakter backtick dan `${`) → klik Run (kadang ada dialog "Run query" untuk UPDATE tanpa WHERE: konfirmasi bila memang disengaja). Raka harus sudah login Supabase di browser itu.

## 6. Pembuatan workflow
`tools/gen_workflows.py <folder-keluaran>` membuat workflow inti + IPAL (helper: `webhook`, `rpc`, `http`, `code`, `if_not_empty`, `workflow`). Id node acak tiap generate (aman, import per nama).
Untuk agen BARU, tambah file sendiri (`n8n/workflows/agent-<id>.json`, `supabase/<id>.sql`) supaya tidak bentrok dengan chat lain; hanya sentuh `gen_workflows.py` bila memang mengubah workflow inti/IPAL.
Kunci LLM / API pihak ketiga: simpan sebagai credential/env di n8n/server oleh Raka, bukan di repo.

## 7. Jebakan yang sudah dikenal
- WhatsApp grup E2EE: log Evolution "No SenderKeyRecord found for decryption" → pesan tidak sampai n8n sampai kunci pengirim tiba (kirim ulang / tambah ulang bot). Bukan bug kode.
- Album foto WA = banyak pesan terpisah, caption hanya di foto pertama.
- Bot membalas obrolan biasa → agen grup harus punya filter (lihat `IPAL_PREP`: abaikan teks yang me-mention/membalas/terlalu panjang).
- Nama bot di WhatsApp: "Bahtera Binar Pulse" (nomor yang tertaut ke Evolution). `WA_ALLOWED_CHATS` di `.env` server masih kosong (belum dibatasi).
- Repo lain `bahtera-binar-pulse` adalah aplikasi web Next.js yang BERBEDA, jangan dicampur.

## 8. Rapikan nanti (belum dikerjakan)
Domain asli pengganti sslip.io; ganti kunci service_role legacy dengan `sb_secret_` sebelum akhir 2026; pin versi image Docker; Postgres 17; backup; set `WA_ALLOWED_CHATS`; recreate instance WA (token pernah tertempel di chat); server "System restart required".
