-- Aktifkan pencatatan GRUP PENGELUARAN (Meita → Balqis) untuk Admin Berdikari. Aman diulang.
-- Semua teks di grup ini diserahkan ke agen akuntan (config.all_text_chats); bot diam, hasil ke akun_pengeluaran_grup.
update public.agents
   set config = jsonb_set(
         jsonb_set(config, '{all_text_chats}', '["120363423195221113@g.us"]'::jsonb),
         '{chats}',
         (select to_jsonb(array(select distinct x from jsonb_array_elements_text(coalesce(config->'chats','[]'::jsonb) || '["120363423195221113@g.us"]'::jsonb) x))))
 where id = 'akuntan';
select id, config from public.agents where id = 'akuntan';
