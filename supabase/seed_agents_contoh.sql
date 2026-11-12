-- CONTOH pendaftaran agen sesuai rancangan awal (4 modul). Belum dijalankan otomatis.
-- Ubah id/nama/kata kunci sesuai kebutuhan, lalu jalankan di SQL Editor saat agennya
-- sudah punya workflow n8n (lihat docs/TAMBAH-AGEN.md). enabled=false = terdaftar tapi
-- belum menerima pesan; ubah ke true setelah workflow aktif.

insert into public.agents (id, name, role, emoji, color, triggers, priority, enabled, desk, config) values
  ('ipal',    'Ipal',    'Pantau laporan IPAL dapur MBG',        '🧯', '#0ea5e9', array['ipal'],                    10, false, '{"x":-2,"z":0}', '{}'),
  ('akuntan', 'Akuntan', 'Rekap nota, omset & kas',              '🧾', '#f59e0b', array['nota','omset','kas'],      10, false, '{"x":0,"z":0}',  '{}'),
  ('editor',  'Editor',  'Auto-edit video promo',                '🎬', '#a855f7', array['edit video','editkan'],    10, false, '{"x":2,"z":0}',  '{}'),
  ('scraper', 'Scraper', 'Kerja di browser (login, scraping)',   '🕸️', '#ef4444', array['scrape','cek akun'],       10, false, '{"x":4,"z":0}',  '{}')
on conflict (id) do nothing;
