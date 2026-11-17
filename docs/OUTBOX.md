# Antrean pesan WhatsApp keluar (outbox)

Cara mengirim pesan WhatsApp lewat bot tanpa membuat workflow baru: **tambah satu baris ke tabel `wa_outbox`**.
Workflow n8n `sys:outbox` berjalan tiap menit, mengambil pesan yang `pending`, mengirimnya lewat `lib-send-wa`, lalu menandainya `sent`.

## Mengirim pesan
```sql
insert into public.wa_outbox (chat_id, text, source)
values ('120363211510777251@g.us', E'Halo!\nIni pesan dari bot.', 'nama-sumber');
```
- `chat_id`: JID grup (`...@g.us`) atau nomor (`62812xxxx@s.whatsapp.net`). Daftar grup: `scripts/cari-grup-wa.sh`.
- `text`: isi pesan (baris baru dengan `E'...\n...'`).
- `source`: bebas, untuk melacak asal pesan.

## Aturan
- Sekali kirim, tanpa dobel: baris ditandai `sent` saat diambil. Kalau pengiriman gagal, pesan tidak otomatis diulang (error tercatat oleh `sys:error-handler`).
- Pesan yang menunggu lebih dari 1 hari tidak dikirim (ditandai `sent` tanpa dikirim).
- Maksimal 5 pesan per menit per putaran.
- Hanya `service_role` yang boleh memanggil `outbox_claim`; tabel dilindungi RLS.

## Berkas
- `supabase/outbox.sql`: tabel `wa_outbox` + fungsi `outbox_claim(p_limit)` (idempoten, jalankan manual di Supabase).
- `n8n/workflows/sys-outbox.json` (dibuat oleh `tools/gen_workflows.py`).
- Setelah deploy, workflow baru aktif setelah `docker compose restart n8n` di server.
