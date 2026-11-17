-- ═══════════════════════════════════════════════════════════════════
-- Agen "Admin Catering" (id teknis: dapurmbg) — pekerjaan mingguan DAPUR MBG.
-- Grup: "Makan Makan Sehat" (Raka + bot). Raka kirim file RC 0 dan PAGU jadi di grup itu.
--
-- Versi 1: agen MENCATAT semua file/teks yang masuk di grup, membalas pendek ("diterima"),
-- dan menyimpan isinya di dm_inbox supaya sesi Claude bisa memprosesnya (update harga RC 0, PDF PAGU).
-- Pekerjaan Google (master harga, PDF) dijalankan lewat sesi Claude, bukan di server.
--
-- Aman diulang (idempoten). Jalankan di SQL Editor Supabase.
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.dm_inbox (
  id          bigint generated always as identity primary key,
  message_id  text unique not null,
  chat_id     text not null,
  kind        text not null check (kind in ('file', 'media', 'text')),
  sender      text,
  push_name   text,
  body        text not null default '',       -- teks pesan / caption
  message_type text,
  mimetype    text,
  size_bytes  int,
  content_b64 text,                           -- isi file (base64), hanya untuk kind='file'
  handled     boolean not null default false, -- sudah diproses sesi Claude
  received_at timestamptz not null default now()
);
create index if not exists dm_inbox_received_idx on public.dm_inbox (received_at desc);

alter table public.dm_inbox enable row level security;
revoke all on public.dm_inbox from public, anon, authenticated;
grant all on public.dm_inbox to service_role;

-- Awal minggu (Senin 00:00 WIB) sebagai timestamptz.
create or replace function public.dm_week_start() returns timestamptz
language sql stable as $$
  select date_trunc('week', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta'
$$;

-- Catat satu pesan dari grup. p = {message_id, chat_id, sender, push_name, text, message_type, mimetype, media_base64}
-- Mengembalikan {kind, files_week, reply}. Balasan hanya untuk file dan kata "status".
create or replace function public.dm_record(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_type  text := coalesce(p->>'message_type', '');
  v_mime  text := coalesce(p->>'mimetype', '');
  v_text  text := btrim(coalesce(p->>'text', ''));
  v_b64   text := nullif(p->>'media_base64', '');
  v_kind  text;
  v_files int;
  v_open  int;
  v_reply text;
begin
  if v_type ilike 'document%' or v_mime ~* '(spreadsheet|excel|csv|pdf|msword|officedocument)' then
    v_kind := 'file';
  elsif v_type in ('imageMessage', 'videoMessage', 'audioMessage') or v_mime ~* '^(image|video|audio)/' then
    v_kind := 'media';
  else
    v_kind := 'text';
  end if;

  insert into public.dm_inbox (message_id, chat_id, kind, sender, push_name, body, message_type, mimetype,
                               size_bytes, content_b64)
  values (p->>'message_id', p->>'chat_id', v_kind, p->>'sender', p->>'push_name', v_text, v_type, nullif(v_mime, ''),
          case when v_b64 is not null then (length(v_b64) * 3 / 4) end,
          case when v_kind = 'file' then v_b64 end)
  on conflict (message_id) do nothing;

  select count(*) into v_files from public.dm_inbox
   where kind = 'file' and received_at >= public.dm_week_start();
  select count(*) into v_open from public.dm_inbox
   where kind = 'file' and not handled and received_at >= public.dm_week_start();

  if v_kind = 'file' then
    v_reply := '✅ File diterima. Minggu ini ' || v_files || ' file (' || v_open || ' belum diproses).';
  elsif v_kind = 'text' and lower(v_text) in ('status', 'cek', 'cek status') then
    v_reply := 'Minggu ini ' || v_files || ' file masuk, ' || v_open || ' belum diproses.';
  end if;

  return jsonb_build_object('kind', v_kind, 'files_week', v_files, 'reply', v_reply);
end $$;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('dm_record', 'dm_week_start')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;

-- ── Daftarkan agen, dibatasi ke grup "Makan Makan Sehat" ─────────────
-- all_text_chats: semua pesan dari grup ini (teks, file) diserahkan ke agen ini.
-- chats: agen ini hanya menerima dari grup ini. redact_events: isi pesan tidak muncul di log dashboard.
-- Tidak menimpa config bila baris sudah ada.
insert into public.agents (id, name, role, emoji, color, triggers, priority, enabled, desk, config)
values ('dapurmbg', 'Admin Catering', 'Admin catering: harga RC 0 mingguan & PDF PAGU DAPUR', '🍱', '#10b981',
        array[]::text[], 8, true, '{}',
        '{"chats": ["120363431545322912@g.us"], "all_text_chats": ["120363431545322912@g.us"], "redact_events": true}')
on conflict (id) do update
  set name = excluded.name, role = excluded.role, emoji = excluded.emoji, color = excluded.color;

select id, name, enabled, config from public.agents where id = 'dapurmbg';
