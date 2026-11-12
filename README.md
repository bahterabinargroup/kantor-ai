# Kantor AI — Fondasi Sistem Multi-Agen

Fondasi yang siap dipasangi agen. Satu VPS (2–4 vCPU, 4–8 GB RAM), semua lewat Docker Compose.
**Agen belum ada** (kecuali `echo` untuk uji pipeline) — kamu tambahkan sendiri, lihat [`docs/TAMBAH-AGEN.md`](docs/TAMBAH-AGEN.md).

```
WhatsApp ──► Evolution API ──► n8n "00 · Core WA Router"
                                   │  Normalize → dispatch_message (SQL: anti-duplikat + routing + buat tugas)
                                   ▼
                         webhook  agent-<id>   (n8n, internal saja)
                                   │  pakai lib:set-status · lib:send-wa · Browserless · LLM
                                   ▼
                         Supabase (agents · tasks · agent_events) ──realtime──► Dashboard
```

## Isi

| Komponen | Peran | Catatan |
|---|---|---|
| `postgres` + `redis` | DB lokal untuk n8n & Evolution | internal |
| `evolution-api` | Gateway WhatsApp (Baileys) | `https://EVOLUTION_DOMAIN/manager` untuk scan QR |
| `n8n` | Orkestrator agen | workflow inti di `n8n/workflows/` |
| `browserless` | Chromium sandbox untuk agen peramban | internal: `ws://browserless:3000?token=…` |
| `dashboard` | Status agen real-time (Kerja/Santai/Macet/Tidur) | dilindungi login (basic auth) |
| `caddy` | HTTPS otomatis + penutup endpoint internal | satu-satunya yang membuka port 80/443 |
| **Supabase (cloud)** | Registry agen, tugas, log, realtime | `supabase/schema.sql` |

Workflow inti: `00 · Core WA Router`, `lib:set-status`, `lib:send-wa`, `agent:echo` (template), `sys:housekeeping`, `sys:error-handler`, `sys:wa-watchdog`.
`sys:wa-watchdog` (tiap 5 menit) memasang ulang webhook WhatsApp bila kosong — Evolution API dilaporkan kadang mengosongkannya setelah restart container ([issue #2694](https://github.com/evolution-foundation/evolution-api/issues/2694)).

## Setup

**1. Siapkan VPS & domain.** Di VPS Ubuntu 24.04 yang masih kosong, jalankan `sudo bash scripts/00-siapkan-vps.sh` (memasang Docker + Compose v2, firewall 22/80/443, swap 2 GB). Lalu arahkan tiga subdomain (n8n, wa, kantor) ke IP VPS.

**2. Supabase.** Buat project gratis di supabase.com → *SQL Editor* → tempel isi `supabase/schema.sql` → Run.
Dari *Project Settings → API* salin `Project URL`, kunci **publishable** (`sb_publishable_…`) dan kunci **secret** (`sb_secret_…`; buat di tab *API Keys* kalau belum ada).
Kunci lama `anon`/`service_role` masih jalan, tapi Supabase menghentikannya akhir 2026 — pakai yang baru.

**3. Jalankan setup.**
```bash
./setup.sh      # tanya domain, buat semua secret & password dashboard, isi .env
```
Pertama kali berhenti meminta tiga nilai Supabase: isi di `.env` lalu jalankan `./setup.sh` lagi.

**4. n8n.** Buka `https://N8N_DOMAIN` → buat akun owner. Lalu:
```bash
./scripts/import-workflows.sh     # impor + aktifkan workflow inti (per-ID, cocok n8n 1.x & 2.x)
```
Error handler sudah terpasang otomatis di semua workflow; tidak ada langkah manual.

**5. WhatsApp.**
```bash
./scripts/connect-wa.sh           # buat instance + pasang webhook
```
Buka `https://EVOLUTION_DOMAIN/manager`, scan QR (WhatsApp → Perangkat tertaut).

**6. Uji.** Dari nomor lain kirim `/echo halo` ke nomor yang tertaut. Echo membalas, dan kartu Echo di dashboard berubah *Kerja → Santai*.
`/help` menampilkan daftar agen.

## Cara kerja inti

- **Routing:** `/nama-agen isi` memanggil agen itu; tanpa perintah, agen dengan kata kunci (`agents.triggers`) yang cocok. Di grup, pesan tanpa kecocokan diabaikan; di chat pribadi dibalas daftar agen.
- **Status agen:** setiap agen memanggil `lib:set-status` (working → idle). Error otomatis → *Macet*. `sys:housekeeping` tiap 10 menit: tugas >15 menit dianggap gagal, agen santai >30 menit → *Tidur*.
- **Slot LLM-router:** kalau nanti routing perlu cerdas (Gemini Flash), sisipkan satu node antara `Normalize` dan `Dispatch` di `00 · Core WA Router`.
- **Slot render video:** blok `renderer` yang dikomentari di `docker-compose.yml`.

## Keamanan (sudah diterapkan)

- Endpoint `/webhook/agent-*`, `/webhook/lib-*`, `/webhook/wa-incoming*` ditolak (403) dari internet; hanya antar-container.
- Webhook WA diverifikasi dengan `WEBHOOK_SECRET`; `WA_ALLOWED_CHATS` membatasi grup/chat yang boleh memicu agen.
- Dashboard di balik login; anon key hanya bisa `SELECT` `agents` & `agent_events` (RLS). Tulis hanya lewat fungsi RPC yang dikunci ke `service_role` (n8n).
- Browserless tidak dibuka ke internet dan butuh token.
- **Jangan** menaruh nominal, isi nota, atau nomor HP di `agent_events` (terbaca dashboard).
- Baileys memakai WhatsApp tidak resmi: ada risiko nomor dibatasi. Pakai nomor khusus bot, bukan nomor utama.

## Belum diuji di lingkungan nyata

Dicek: sintaks compose/JSON/shell dan seluruh `schema.sql` (dijalankan di Postgres 16: routing, anti-duplikat, timeout, idempoten). **Belum** dijalankan: container, n8n, dan Evolution API sungguhan.
Titik yang paling mungkin perlu penyesuaian saat pertama jalan:
- `connect-wa.sh`: bentuk body webhook (datar: `enabled, url, webhookByEvents, webhookBase64, events`) cocok dengan dokumentasi dan laporan issue Evolution; skrip tetap punya cadangan bentuk lain. Versi dipin `v2.3.0`.
- `import-workflows.sh`: sudah sesuai dokumentasi n8n (`publish:workflow --id` di 2.x, `update:workflow --id` di 1.x); kalau satu workflow gagal aktif, skrip menyebut namanya — klik *Publish* di UI.
- Payload JID grup/kontak kadang berbentuk `@lid`; kalau `WA_ALLOWED_CHATS` tidak cocok, lihat JID asli di Executions → node `Normalize`.

## Perintah harian

```bash
docker compose ps                 # status
docker compose logs -f n8n        # log
docker compose pull && docker compose up -d   # update (pin versi di .env dulu)
```
Backup: volume `postgres_data`, `n8n_data`, `evolution_instances` + file `.env` (terutama `N8N_ENCRYPTION_KEY`). Supabase: backup bawaan project.
