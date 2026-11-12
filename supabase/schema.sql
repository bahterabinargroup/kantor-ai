-- ═══════════════════════════════════════════════════════════════════
-- Kantor AI — skema inti (jalankan di Supabase → SQL Editor, aman diulang)
-- ═══════════════════════════════════════════════════════════════════
-- Prinsip:
--   • Dashboard (anon key)  : hanya boleh MEMBACA agents & agent_events
--   • n8n (service_role key): satu-satunya yang menulis, lewat fungsi RPC di bawah
--   • JANGAN menaruh data sensitif (nominal, isi nota, nomor HP) di agent_events
--     karena tabel itu terbaca oleh dashboard.

-- ── Tabel ───────────────────────────────────────────────────────────
create table if not exists public.agents (
  id              text primary key check (id ~ '^[a-z0-9][a-z0-9_-]*$'),
  name            text not null,
  role            text not null default '',
  emoji           text not null default '🤖',
  color           text not null default '#6366f1',
  triggers        text[] not null default '{}',   -- kata kunci pemicu (huruf kecil/besar bebas)
  priority        int  not null default 0,        -- kalau >1 agen cocok, prioritas tertinggi menang
  enabled         boolean not null default true,
  status          text not null default 'sleeping'
                  check (status in ('working','idle','blocked','sleeping')),  -- Kerja/Santai/Macet/Tidur
  status_detail   text,
  current_task_id uuid,
  last_active_at  timestamptz not null default now(),
  desk            jsonb not null default '{}'::jsonb,  -- posisi meja untuk dashboard 3D nanti
  config          jsonb not null default '{}'::jsonb,  -- pengaturan khusus agen
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table if not exists public.tasks (
  id           uuid primary key default gen_random_uuid(),
  agent_id     text not null references public.agents(id) on update cascade,
  source       text not null default 'whatsapp',      -- whatsapp | web | cron | agent
  source_ref   text,                                  -- id pesan WA, dst.
  chat_id      text,
  payload      jsonb not null default '{}'::jsonb,
  status       text not null default 'queued'
               check (status in ('queued','running','done','failed')),
  result       jsonb,
  error        text,
  created_at   timestamptz not null default now(),
  started_at   timestamptz,
  finished_at  timestamptz
);
create index if not exists tasks_agent_created_idx on public.tasks (agent_id, created_at desc);
create index if not exists tasks_open_idx on public.tasks (status) where status in ('queued','running');

create table if not exists public.agent_events (
  id        bigint generated always as identity primary key,
  agent_id  text references public.agents(id) on update cascade on delete cascade,
  task_id   uuid,
  level     text not null default 'info' check (level in ('info','warn','error')),
  event     text not null,
  message   text,
  meta      jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists agent_events_created_idx on public.agent_events (created_at desc);

-- Memori jangka panjang per agen (key-value). Tidak terbaca dashboard.
create table if not exists public.agent_memory (
  agent_id   text not null references public.agents(id) on update cascade on delete cascade,
  key        text not null,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (agent_id, key)
);

-- Anti-duplikat: WhatsApp kadang mengirim webhook yang sama dua kali.
create table if not exists public.processed_messages (
  message_id  text primary key,
  received_at timestamptz not null default now()
);

-- ── updated_at otomatis ─────────────────────────────────────────────
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;

drop trigger if exists agents_touch on public.agents;
create trigger agents_touch before update on public.agents
  for each row execute function public.touch_updated_at();

-- ── Fungsi RPC (dipanggil n8n dengan service_role) ─────────────────

-- Ubah status agen + catat event. Dipakai lib:set-status.
create or replace function public.set_agent_status(
  p_agent_id text, p_status text, p_detail text default null, p_task_id uuid default null
) returns jsonb language plpgsql as $$
begin
  update public.agents
     set status = p_status,
         status_detail = p_detail,
         current_task_id = case when p_status = 'working' then p_task_id else null end,
         last_active_at = now()
   where id = p_agent_id;
  if not found then
    raise exception 'agen % tidak ditemukan', p_agent_id;
  end if;

  if p_status = 'working' and p_task_id is not null then
    update public.tasks set status = 'running', started_at = coalesce(started_at, now())
     where id = p_task_id and status = 'queued';
  end if;

  insert into public.agent_events (agent_id, task_id, level, event, message)
  values (p_agent_id, p_task_id,
          case when p_status = 'blocked' then 'error' else 'info' end,
          'status:' || p_status, left(p_detail, 300));

  return jsonb_build_object('ok', true, 'agent_id', p_agent_id, 'status', p_status);
end $$;

-- Catat event bebas (progres, peringatan, dll).
create or replace function public.log_event(
  p_agent_id text, p_event text, p_message text default null,
  p_level text default 'info', p_task_id uuid default null, p_meta jsonb default '{}'
) returns jsonb language plpgsql as $$
begin
  insert into public.agent_events (agent_id, task_id, level, event, message, meta)
  values (p_agent_id, p_task_id, p_level, p_event, left(p_message, 300), coalesce(p_meta, '{}'));
  return jsonb_build_object('ok', true);
end $$;

-- Tutup tugas.
create or replace function public.finish_task(
  p_task_id uuid, p_status text default 'done', p_result jsonb default null, p_error text default null
) returns jsonb language plpgsql as $$
begin
  if p_status not in ('done','failed') then
    raise exception 'status akhir harus done atau failed';
  end if;
  update public.tasks
     set status = p_status, result = p_result, error = left(p_error, 500), finished_at = now(),
         started_at = coalesce(started_at, now())
   where id = p_task_id;
  return jsonb_build_object('ok', found, 'task_id', p_task_id, 'status', p_status);
end $$;

-- Daftar agen untuk balasan /help.
create or replace function public.agents_help() returns text
language sql stable as $$
  select coalesce(
    'Agen tersedia:' || E'\n' ||
    string_agg('• /' || id || ' — ' || name || case when role <> '' then ' (' || role || ')' else '' end,
               E'\n' order by id),
    'Belum ada agen yang aktif.')
  from public.agents where enabled;
$$;

-- Pintu masuk semua pesan WhatsApp: anti-duplikat → routing → buat tugas.
--   /nama-agen isi pesan   → agen itu
--   tanpa perintah         → agen pertama yang kata kuncinya (agents.triggers) cocok
--   /help                  → daftar agen
create or replace function public.dispatch_message(
  p_message_id text, p_chat_id text, p_is_group boolean, p_text text, p_meta jsonb default '{}'
) returns jsonb language plpgsql as $$
declare
  v_text  text := btrim(coalesce(p_text, ''));
  v_clean text := btrim(coalesce(p_text, ''));
  v_cmd   text;
  v_agent public.agents%rowtype;
  v_rows  int;
  v_task  uuid;
begin
  insert into public.processed_messages (message_id) values (p_message_id)
  on conflict do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    return jsonb_build_object('duplicate', true);
  end if;

  if v_text ~ '^/[A-Za-z0-9_-]+' then
    v_cmd   := lower(substring(v_text from '^/([A-Za-z0-9_-]+)'));
    v_clean := btrim(regexp_replace(v_text, '^/[A-Za-z0-9_-]+\s*', ''));
    if v_cmd in ('help', 'agents', 'bantuan') then
      return jsonb_build_object('reply', public.agents_help());
    end if;
    select * into v_agent from public.agents where id = v_cmd and enabled;
    if v_agent.id is null then
      return jsonb_build_object('reply',
        'Agen "/' || v_cmd || E'" tidak ditemukan.\n' || public.agents_help());
    end if;
  else
    select a.* into v_agent
      from public.agents a
     where a.enabled
       and exists (select 1 from unnest(a.triggers) t
                    where btrim(t) <> '' and position(lower(t) in lower(v_text)) > 0)
     order by a.priority desc, a.id
     limit 1;
  end if;

  -- foto/video tanpa caption di grup → agen yang memasang pemicu '@media' (mis. IPAL, menunggu teks nama dapur)
  if v_agent.id is null and p_is_group and v_text = ''
     and coalesce(p_meta->>'message_type', '') in ('imageMessage', 'videoMessage') then
    select a.* into v_agent from public.agents a
     where a.enabled and '@media' = any(a.triggers)
     order by a.priority desc, a.id limit 1;
  end if;

  if v_agent.id is null then
    if not p_is_group and v_text <> '' then
      return jsonb_build_object('reply', public.agents_help());   -- chat pribadi: beri petunjuk
    end if;
    return jsonb_build_object('matched', false);                  -- grup: diam
  end if;

  insert into public.tasks (agent_id, source, source_ref, chat_id, payload)
  values (v_agent.id, 'whatsapp', p_message_id, p_chat_id,
          jsonb_build_object('text', v_clean) || coalesce(p_meta, '{}'))
  returning id into v_task;

  insert into public.agent_events (agent_id, task_id, event, message)
  values (v_agent.id, v_task, 'task:queued', left(v_clean, 120));

  return jsonb_build_object('matched', true, 'task_id', v_task, 'agent_id', v_agent.id, 'text', v_clean);
end $$;

-- Nyalakan/matikan agen (dipanggil tombol di dashboard lewat n8n). Agen nonaktif tidak menerima pesan.
create or replace function public.set_agent_enabled(p_agent_id text, p_enabled boolean)
returns jsonb language plpgsql as $$
begin
  update public.agents
     set enabled = p_enabled,
         status = case when p_enabled then 'idle' else 'sleeping' end,
         status_detail = case when p_enabled then 'Diaktifkan' else 'Dimatikan' end,
         current_task_id = null,
         last_active_at = now()
   where id = p_agent_id;
  if not found then
    raise exception 'agen % tidak ditemukan', p_agent_id;
  end if;
  insert into public.agent_events (agent_id, level, event, message)
  values (p_agent_id, 'warn', case when p_enabled then 'agent:enabled' else 'agent:disabled' end,
          case when p_enabled then 'diaktifkan dari dashboard' else 'dimatikan dari dashboard' end);
  return jsonb_build_object('ok', true, 'agent_id', p_agent_id, 'enabled', p_enabled);
end $$;

-- Ubah nama / logo (emoji) / warna agen dari dashboard. NULL = tidak diubah.
create or replace function public.update_agent_profile(
  p_agent_id text, p_name text default null, p_emoji text default null, p_color text default null
) returns jsonb language plpgsql as $$
declare
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_emoji text := nullif(btrim(coalesce(p_emoji, '')), '');
  v_color text := nullif(btrim(coalesce(p_color, '')), '');
begin
  if v_name is not null and char_length(v_name) > 30 then raise exception 'nama maksimal 30 karakter'; end if;
  if v_emoji is not null and char_length(v_emoji) > 8 then raise exception 'logo harus 1 emoji'; end if;
  if v_color is not null and v_color !~ '^#[0-9a-fA-F]{6}$' then raise exception 'warna harus format #rrggbb'; end if;
  update public.agents
     set name = coalesce(v_name, name), emoji = coalesce(v_emoji, emoji), color = coalesce(v_color, color)
   where id = p_agent_id;
  if not found then raise exception 'agen % tidak ditemukan', p_agent_id; end if;
  insert into public.agent_events (agent_id, level, event, message)
  values (p_agent_id, 'info', 'agent:profile', 'nama/logo diubah dari dashboard');
  return jsonb_build_object('ok', true, 'agent_id', p_agent_id);
end $$;

-- Perawatan berkala (dipanggil workflow sys:housekeeping tiap 10 menit).
create or replace function public.housekeeping(
  p_sleep_after_minutes int default 30, p_task_timeout_minutes int default 15
) returns jsonb language plpgsql as $$
declare v_sleep int; v_tasks int;
begin
  -- tugas macet → gagal, agennya ditandai Macet
  with stuck as (
    update public.tasks
       set status = 'failed', error = 'timeout: tidak selesai dalam ' || p_task_timeout_minutes || ' menit',
           finished_at = now()
     where status in ('queued','running')
       and created_at < now() - make_interval(mins => p_task_timeout_minutes)
    returning id, agent_id
  ), blocked as (
    update public.agents a
       set status = 'blocked', status_detail = 'Tugas timeout', current_task_id = null
      from stuck s
     where a.id = s.agent_id and a.status = 'working'
    returning a.id
  )
  select count(*) into v_tasks from stuck;

  -- agen santai terlalu lama → tidur
  update public.agents
     set status = 'sleeping', status_detail = null
   where status = 'idle'
     and last_active_at < now() - make_interval(mins => p_sleep_after_minutes);
  get diagnostics v_sleep = row_count;

  delete from public.processed_messages where received_at < now() - interval '7 days';
  delete from public.agent_events       where created_at  < now() - interval '30 days';

  return jsonb_build_object('tasks_timed_out', v_tasks, 'agents_slept', v_sleep);
end $$;

-- ── Keamanan ───────────────────────────────────────────────────────
alter table public.agents             enable row level security;
alter table public.tasks              enable row level security;
alter table public.agent_events       enable row level security;
alter table public.agent_memory       enable row level security;
alter table public.processed_messages enable row level security;

-- Dashboard (anon) hanya boleh membaca dua tabel ini. Tabel lain: tanpa policy = tertutup.
drop policy if exists "dashboard read agents" on public.agents;
create policy "dashboard read agents" on public.agents
  for select to anon, authenticated using (true);

drop policy if exists "dashboard read events" on public.agent_events;
create policy "dashboard read events" on public.agent_events
  for select to anon, authenticated using (true);

-- Hak akses tabel untuk Data API. Wajib bila project dibuat dengan opsi
-- "Automatically expose new tables" MATI (disarankan Supabase): tanpa ini n8n kena
-- "permission denied" dan dashboard tidak bisa membaca. RLS tetap membatasi anon.
grant usage on schema public to anon, authenticated, service_role;
grant select on public.agents, public.agent_events to anon, authenticated;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

-- Fungsi RPC hanya untuk service_role (n8n).
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('set_agent_status','set_agent_enabled','update_agent_profile','log_event','finish_task','agents_help','dispatch_message','housekeeping')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;

-- ── Realtime untuk dashboard ───────────────────────────────────────
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.agents;       exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.agent_events; exception when duplicate_object then null; end;
  end if;
end $$;

-- ── Seed: satu agen uji ─────────────────────────────────────────────
insert into public.agents (id, name, role, emoji, color, desk)
values ('echo', 'Echo', 'Agen uji pipeline', '🦜', '#22c55e', '{"x":0,"z":0}')
on conflict (id) do nothing;
