-- Admin Catering: penyimpanan keadaan alur WhatsApp (rencana harga yang menunggu "setuju").
-- Aman diulang. Jalankan di SQL Editor Supabase.
create table if not exists public.dm_state (
  key        text primary key,
  val        jsonb,
  updated_at timestamptz not null default now()
);
alter table public.dm_state enable row level security;
revoke all on public.dm_state from public, anon, authenticated;
grant all on public.dm_state to service_role;

create or replace function public.dm_state_get(p_key text) returns jsonb
language sql stable as $$
  select jsonb_build_object('val', (select val from public.dm_state where key = p_key))
$$;

create or replace function public.dm_state_set(p_key text, p_val jsonb) returns jsonb
language sql as $$
  insert into public.dm_state (key, val) values (p_key, p_val)
  on conflict (key) do update set val = excluded.val, updated_at = now()
  returning jsonb_build_object('ok', true)
$$;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('dm_state_get', 'dm_state_set')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;

select public.dm_state_set('ping', '{"a":1}'::jsonb), public.dm_state_get('ping');
