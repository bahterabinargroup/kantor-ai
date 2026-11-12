-- ═══════════════════════════════════════════════════════════════════
-- Aktifkan agen Akuntan: batasi ke grup Berdikari, batasi IPAL ke grup IPAL, lalu nyalakan.
-- Jalankan SEKALI setelah akuntan.sql dan setelah JID grup Berdikari diketahui:
--   bash scripts/cari-grup-wa.sh "BERDIKARI"      (bot harus sudah masuk grup)
-- Ganti GANTI_JID_GRUP_BERDIKARI di bawah dengan hasilnya (bentuk: 1203xxxxxxxxxxxx@g.us).
--
-- KENAPA WAJIB: foto tanpa caption sama-sama dibaca IPAL dan Akuntan. Tanpa batas grup,
-- agen berprioritas lebih tinggi akan mengambil foto dari grup yang salah.
-- ═══════════════════════════════════════════════════════════════════
do $$
declare
  v_berdikari text := 'GANTI_JID_GRUP_BERDIKARI';
  v_ipal      text := '120363412210248647@g.us';   -- LAPORAN BERSIH2 IPAL
begin
  if v_berdikari !~ '^[0-9]+(-[0-9]+)?@g\.us$' then
    raise exception 'Isi dulu JID grup Berdikari (sekarang: %)', v_berdikari;
  end if;
  update public.agents
     set config = jsonb_set(config, '{chats}', to_jsonb(array[v_ipal]))
   where id = 'ipal';
  update public.agents
     set config = jsonb_set(jsonb_set(config, '{chats}', to_jsonb(array[v_berdikari])), '{redact_events}', 'true'),
         enabled = true, status = 'idle', status_detail = 'Diaktifkan'
   where id = 'akuntan';
end $$;
