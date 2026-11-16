-- Antrean pesan WhatsApp keluar (outbox).
-- Siapa pun (agen, skrip, sesi Claude) cukup INSERT baris ke wa_outbox;
-- workflow n8n `sys:outbox` mengambilnya tiap menit dan mengirim lewat bot (lib-send-wa).
-- Idempotent: aman dijalankan ulang.

create table if not exists public.wa_outbox (
  id         bigint generated always as identity primary key,
  chat_id    text not null,                 -- JID grup/nomor, mis. 120363211510777251@g.us
  text       text not null,
  source     text,                          -- asal pesan (bebas): 'manual', 'akuntan', ...
  status     text not null default 'pending' check (status in ('pending','sent')),
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
create index if not exists wa_outbox_pending_idx on public.wa_outbox (id) where status = 'pending';
alter table public.wa_outbox enable row level security;
grant select, insert, update on public.wa_outbox to service_role;

-- Ambil pesan yang menunggu dan tandai terkirim (sekali kirim, tanpa dobel).
-- Pesan yang sudah menunggu lebih dari 1 hari dibuang (tidak dikirim telat).
create or replace function public.outbox_claim(p_limit int default 5)
returns jsonb
language plpgsql
set search_path = public, extensions
as $$
declare
  v jsonb;
begin
  update public.wa_outbox set status = 'sent', sent_at = now()
   where status = 'pending' and created_at < now() - interval '1 day';
  with c as (
    select id from public.wa_outbox
     where status = 'pending'
     order by id
     limit greatest(p_limit, 1)
     for update skip locked
  ), u as (
    update public.wa_outbox o set status = 'sent', sent_at = now()
      from c where o.id = c.id
    returning o.id, o.chat_id, o.text
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'chat_id', u.chat_id, 'text', u.text) order by u.id), '[]'::jsonb)
    into v from u;
  return v;
end $$;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'outbox_claim'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;
