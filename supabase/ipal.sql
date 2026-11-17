-- ═══════════════════════════════════════════════════════════════════
-- Agen IPAL — laporan harian 9 dapur MBG (jalankan SETELAH schema.sql, aman diulang)
-- ═══════════════════════════════════════════════════════════════════
-- Alur: foto + caption masuk grup WA → ipal_record_report() mencocokkan nama dapur
--       → dicatat SUDAH untuk hari itu (WIB). Cron memanggil ipal_pending_today()
--       untuk daftar dapur yang masih BELUM.
-- Privasi: yang disimpan hanya "dapur X lapor jam sekian" (tanpa foto, tanpa isi caption
--          selain potongan pendek). Tabel TIDAK terbuka untuk dashboard (anon).

create schema if not exists extensions;
create extension if not exists fuzzystrmatch with schema extensions;

-- ── Tabel ───────────────────────────────────────────────────────────
create table if not exists public.ipal_kitchens (
  id        text primary key check (id ~ '^[a-z0-9_]+$'),
  name      text not null,                      -- nama baku untuk ditampilkan
  aliases   text[] not null default '{}',       -- kata penanda (huruf kecil, satu kata per entri)
  position  int  not null default 0,            -- urutan tampil
  enabled   boolean not null default true
);

create table if not exists public.ipal_reports (
  id          bigint generated always as identity primary key,
  kitchen_id  text references public.ipal_kitchens(id) on update cascade,   -- null = foto tanpa caption, menunggu teks nama dapur
  report_date date not null default ((now() at time zone 'Asia/Jakarta')::date),
  reported_at timestamptz not null default now(),
  message_id  text,
  chat_id     text,
  sender      text,
  has_media   boolean not null default false,
  match_method text,
  snippet     text                               -- potongan caption (maks 80 huruf)
);
create unique index if not exists ipal_reports_msg_uidx on public.ipal_reports (message_id) where message_id is not null;
create index if not exists ipal_reports_day_idx on public.ipal_reports (report_date, kitchen_id);

alter table public.ipal_reports alter column kitchen_id drop not null;   -- untuk database yang sudah terpasang versi lama
alter table public.ipal_reports add column if not exists notified_at timestamptz;   -- sudah diumumkan 'tidak lengkap'
alter table public.ipal_kitchens enable row level security;
alter table public.ipal_reports  enable row level security;   -- tanpa policy = tertutup untuk anon

-- ── Daftar 9 dapur ──────────────────────────────────────────────────
insert into public.ipal_kitchens (id, name, aliases, position) values
  ('pringsari',   'Pringsari, Pringapus',  array['pringsari','pringapus'], 1),
  ('doplang',     'Doplang, Bawen',        array['doplang','bawen'],       2),
  ('lodoyong',    'Lodoyong, Ambarawa',    array['lodoyong','ambarawa'],   3),
  ('ngrapah',     'Ngrapah, Banyubiru',    array['ngrapah','banyubiru'],   4),
  ('badran',      'Badran, Kranggan',      array['badran','kranggan'],     5),
  ('sawangan',    'Sawangan',              array['sawangan'],              6),
  ('kedungsari',  'Kedungsari',            array['kedungsari'],            7),
  ('grabag',      'Grabag',                array['grabag'],                8),
  ('tersidilor',  'Tersidilor, Pituruh',   array['tersidilor','pituruh'],  9)
on conflict (id) do update
  set name = excluded.name, aliases = excluded.aliases, position = excluded.position;

-- ── Pencocokan nama dapur dari caption ─────────────────────────────
-- Urutan: (1) kata utuh  (2) kata disambung tanpa spasi ("kedung sari")  (3) salah ketik ringan.
-- Hasil jsonb: {kitchen_id, method} | {ambiguous:true, candidates:[…]} | {kitchen_id:null}
create or replace function public.ipal_match(p_text text) returns jsonb
language plpgsql stable
set search_path = public, extensions
as $$
declare
  t   text := ' ' || btrim(regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', ' ', 'g')) || ' ';
  tj  text := replace(t, ' ', '');
  ids text[];
begin
  -- 1) kata utuh
  select array_agg(distinct k.id) into ids
    from public.ipal_kitchens k, unnest(k.aliases) a
   where k.enabled and position(' ' || a || ' ' in t) > 0;
  if cardinality(ids) = 1 then return jsonb_build_object('kitchen_id', ids[1], 'method', 'exact'); end if;
  if cardinality(ids) > 1 then return jsonb_build_object('kitchen_id', null, 'ambiguous', true, 'candidates', to_jsonb(ids)); end if;

  -- 2) disambung ("kedung sari" → "kedungsari"); hanya untuk nama ≥ 6 huruf agar tidak salah tangkap
  select array_agg(distinct k.id) into ids
    from public.ipal_kitchens k, unnest(k.aliases) a
   where k.enabled and length(a) >= 6 and position(a in tj) > 0;
  if cardinality(ids) = 1 then return jsonb_build_object('kitchen_id', ids[1], 'method', 'joined'); end if;
  if cardinality(ids) > 1 then return jsonb_build_object('kitchen_id', null, 'ambiguous', true, 'candidates', to_jsonb(ids)); end if;

  -- 3) salah ketik ringan: selisih 1 huruf (nama 6–7 huruf) atau 2 huruf (nama ≥ 8 huruf)
  select array_agg(distinct k.id) into ids
    from public.ipal_kitchens k, unnest(k.aliases) a,
         regexp_split_to_table(btrim(t), ' ') tok
   where k.enabled and length(a) >= 6 and length(tok) >= 6
     and abs(length(tok) - length(a)) <= 1
     and levenshtein(tok, a) <= case when length(a) >= 8 then 2 else 1 end;
  if cardinality(ids) = 1 then return jsonb_build_object('kitchen_id', ids[1], 'method', 'fuzzy'); end if;
  if cardinality(ids) > 1 then return jsonb_build_object('kitchen_id', null, 'ambiguous', true, 'candidates', to_jsonb(ids)); end if;

  return jsonb_build_object('kitchen_id', null);
end $$;

-- ── Catat laporan ───────────────────────────────────────────────────
-- Teks nama dapur + foto boleh datang terpisah (urutan apa pun) selama pengirimnya sama
-- dan jedanya ≤ 20 menit: keduanya digabung menjadi satu laporan SUDAH.
create or replace function public.ipal_record_report(
  p_message_id text, p_chat_id text, p_text text,
  p_has_media boolean default false, p_sender text default null
) returns jsonb
language plpgsql
set search_path = public, extensions
as $$
declare
  m jsonb := public.ipal_match(p_text);
  v_id text := m->>'kitchen_id';
  v_method text := m->>'method';
  v_has_text boolean := btrim(coalesce(p_text, '')) <> '';
  v_media boolean := coalesce(p_has_media, false);
  v_name text;
  v_before int;
  v_rows int;
  v_pend bigint;
begin
  if v_id is null then
    if v_media and not coalesce((m->>'ambiguous')::boolean, false) then
      -- foto tanpa caption ATAU caption tanpa nama dapur (mis. "Bak IPAL setelah dibersihkan") → pakai nama dapur dari teks pengirim yang sama (≤20 menit, belum dipasangkan foto)
      select r.kitchen_id into v_id
        from public.ipal_reports r
       where r.sender = p_sender and r.chat_id = p_chat_id and r.kitchen_id is not null
         and not r.has_media and r.reported_at > now() - interval '20 minutes'
         and not exists (select 1 from public.ipal_reports r2
                          where r2.sender = r.sender and r2.chat_id = r.chat_id
                            and r2.kitchen_id = r.kitchen_id and r2.has_media
                            and r2.reported_at >= r.reported_at)
       order by r.reported_at desc limit 1;
      if v_id is null then
        -- album: foto lanjutan dari pengirim yang sama ≤5 menit setelah laporan berfoto → ikut dapur itu (diam)
        select r.kitchen_id into v_id
          from public.ipal_reports r
         where r.sender = p_sender and r.chat_id = p_chat_id and r.kitchen_id is not null and r.has_media
           and r.reported_at > now() - interval '5 minutes'
         order by r.reported_at desc limit 1;
        if v_id is not null then
          insert into public.ipal_reports (kitchen_id, message_id, chat_id, sender, has_media, match_method)
          values (v_id, p_message_id, p_chat_id, p_sender, true, 'album')
          on conflict (message_id) where message_id is not null do nothing;
          return jsonb_build_object('matched', false, 'pending_media', true, 'album', true);
        end if;
      end if;
      if v_id is null then
        -- simpan dulu, menunggu teks nama dapur
        insert into public.ipal_reports (kitchen_id, message_id, chat_id, sender, has_media, match_method)
        values (null, p_message_id, p_chat_id, p_sender, true, 'pending_media')
        on conflict (message_id) where message_id is not null do nothing;
        return jsonb_build_object('matched', false, 'pending_media', true);
      end if;
      v_method := 'text_then_photo';
    else
      return jsonb_build_object('matched', false, 'ambiguous', coalesce((m->>'ambiguous')::boolean, false),
                                'candidates', coalesce(m->'candidates', '[]'::jsonb));
    end if;
  end if;

  select name into v_name from public.ipal_kitchens where id = v_id;

  select count(*) into v_before from public.ipal_reports
   where kitchen_id = v_id and report_date = (now() at time zone 'Asia/Jakarta')::date and has_media;

  -- teks saja → gabungkan dengan foto tanpa caption dari pengirim yang sama (≤20 menit)
  if not v_media and p_sender is not null then
    select r.id into v_pend from public.ipal_reports r
     where r.sender = p_sender and r.chat_id = p_chat_id and r.kitchen_id is null and r.has_media
       and r.reported_at > now() - interval '20 minutes'
     order by r.reported_at desc limit 1;
    if v_pend is not null then
      update public.ipal_reports
         set kitchen_id = v_id, match_method = 'photo_then_text', snippet = left(btrim(coalesce(p_text, '')), 80)
       where id = v_pend;
      return jsonb_build_object('matched', true, 'attached', true, 'kitchen_id', v_id, 'kitchen_name', v_name,
                                'method', 'photo_then_text', 'has_media', true,
                                'already_reported_today', v_before > 0);
    end if;
  end if;

  insert into public.ipal_reports (kitchen_id, message_id, chat_id, sender, has_media, match_method, snippet)
  values (v_id, p_message_id, p_chat_id, p_sender, v_media, v_method, left(btrim(coalesce(p_text, '')), 80))
  on conflict (message_id) where message_id is not null do nothing;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    return jsonb_build_object('matched', true, 'duplicate', true, 'kitchen_id', v_id, 'kitchen_name', v_name);
  end if;

  -- foto bercaption → foto album yang masuk lebih dulu tanpa caption (≤5 menit) ikut dapur ini
  if v_media and v_has_text and p_sender is not null then
    update public.ipal_reports
       set kitchen_id = v_id, match_method = 'album'
     where sender = p_sender and chat_id = p_chat_id and kitchen_id is null and has_media
       and reported_at > now() - interval '5 minutes';
  end if;

  return jsonb_build_object('matched', true, 'kitchen_id', v_id, 'kitchen_name', v_name,
                            'method', v_method, 'has_media', v_media,
                            'already_reported_today', v_before > 0);
end $$;

-- ── Status hari ini ─────────────────────────────────────────────────
-- p_require_media = true → hanya laporan yang ada foto/medianya yang dihitung SUDAH.
create or replace function public.ipal_status_day(p_day date, p_require_media boolean default true)
returns table (kitchen_id text, name text, sudah boolean, reports int, first_report_at timestamptz)
language sql stable as $$
  select k.id, k.name,
         count(r.id) > 0,
         count(r.id)::int,
         min(r.reported_at)
    from public.ipal_kitchens k
    left join public.ipal_reports r
           on r.kitchen_id = k.id
          and r.report_date = p_day
          and (r.has_media or not p_require_media)
   where k.enabled
   group by k.id, k.name, k.position
   order by k.position;
$$;

create or replace function public.ipal_status_today(p_require_media boolean default true)
returns table (kitchen_id text, name text, sudah boolean, reports int, first_report_at timestamptz)
language sql stable as $$
  select * from public.ipal_status_day((now() at time zone 'Asia/Jakarta')::date, p_require_media);
$$;

-- Teks pengingat siap kirim. Kalau semua sudah lapor: reply = null (jangan kirim apa-apa).
-- Tanggal berbahasa Indonesia, mis. "Selasa, 17 November 2026"
create or replace function public.ipal_tgl_id(p_day date)
returns text
language sql immutable as $$
  select (array['Minggu','Senin','Selasa','Rabu','Kamis','Jumat','Sabtu'])[extract(dow from p_day)::int + 1]
         || ', ' || extract(day from p_day)::int || ' '
         || (array['Januari','Februari','Maret','April','Mei','Juni','Juli','Agustus','September','Oktober','November','Desember'])[extract(month from p_day)::int]
         || ' ' || extract(year from p_day)::int;
$$;

create or replace function public.ipal_pending_today_core(p_require_media boolean default true)
returns jsonb
language sql stable as $$
  with s as (select * from public.ipal_status_today(p_require_media))
  select jsonb_build_object(
    'belum',   coalesce((select jsonb_agg(name order by name) from s where not sudah), '[]'::jsonb),
    'sudah_n', (select count(*) from s where sudah),
    'total_n', (select count(*) from s),
    'reply',   case when exists (select 1 from s where not sudah)
                     and coalesce((select enabled from public.agents where id = 'ipal'), false) then
                 '⏰ Pengingat sore. Mohon maaf mengganggu, dapur berikut BELUM melaporkan kebersihan IPAL hari ' || public.ipal_tgl_id((now() at time zone 'Asia/Jakarta')::date) || ':' || E'\n' ||
                 (select string_agg('• ' || name, E'\n' order by name) from s where not sudah) || E'\n\n' ||
                 'Tolong kirimkan foto + nama dapur di grup ini ya. Terima kasih banyak atas kerjasamanya 🙏'
                 when coalesce((select enabled from public.agents where id = 'ipal'), false) then
                 '✅ Semua dapur (' || (select count(*) from s) || ' dapur) sudah melaporkan kebersihan IPAL hari ' ||
                 public.ipal_tgl_id((now() at time zone 'Asia/Jakarta')::date) || E'.\n\n' ||
                 'Terima kasih atas kerjasamanya 🙏'
               end
  );
$$;

-- Pengingat pagi (06:00 WIB): dapur yang KEMARIN tidak melapor sama sekali (laporan sampai 23:59 dihitung).
create or replace function public.ipal_pending_yesterday_core(p_require_media boolean default true)
returns jsonb
language sql stable as $$
  with d as (select ((now() at time zone 'Asia/Jakarta')::date - 1) as day),
       s as (select * from public.ipal_status_day((select day from d), p_require_media))
  select jsonb_build_object(
    'belum',   coalesce((select jsonb_agg(name order by name) from s where not sudah), '[]'::jsonb),
    'sudah_n', (select count(*) from s where sudah),
    'total_n', (select count(*) from s),
    'reply',   case when exists (select 1 from s where not sudah)
                     and coalesce((select enabled from public.agents where id = 'ipal'), false) then
                 '🌅 Pengingat pagi. Mohon maaf mengganggu, dapur berikut BELUM melaporkan kebersihan IPAL hari ' ||
                 public.ipal_tgl_id((select day from d)) || ':' || E'\n' ||
                 (select string_agg('• ' || name, E'\n' order by name) from s where not sudah) || E'\n\n' ||
                 'Tolong segera kirimkan laporannya (foto + nama dapur) ya. Terima kasih banyak atas kerjasamanya 🙏'
                 when coalesce((select enabled from public.agents where id = 'ipal'), false) then
                 '✅ Semua dapur (' || (select count(*) from s) || ' dapur) sudah melaporkan kebersihan IPAL hari ' ||
                 public.ipal_tgl_id((select day from d)) || E'.\n\n' ||
                 'Terima kasih atas kerjasamanya 🙏'
               end
  );
$$;

-- ── Cek silang sebelum pengingat ────────────────────────────────────
-- Pesan yang SUDAH diterima bot (ada tugasnya di tabel tasks) tapi tugasnya gagal/macet, mis. n8n sedang
-- restart, diputar ulang lewat ipal_record_report. Hasil: baris "✅ Laporan IPAL <nama> tercatat." untuk dapur yang
-- BARU tercatat karenanya (null kalau tidak ada). Pesan yang tidak pernah sampai ke bot tidak bisa dipulihkan di sini.
create or replace function public.ipal_reconcile(p_day date)
returns text[]
language plpgsql
set search_path = public, extensions
as $$
declare
  t record;
  v_text text; v_media boolean; v_words int;
  v_ids text[] := '{}';
  v_before text[]; v_after text[];
  v_lines text[];
begin
  if not coalesce((select enabled from public.agents where id = 'ipal'), false) then return null; end if;
  select coalesce(array_agg(s.kitchen_id), '{}') into v_before from public.ipal_status_day(p_day, true) s where s.sudah;
  for t in
    select * from public.tasks
     where agent_id = 'ipal' and source = 'whatsapp'
       and status in ('queued', 'running', 'failed')
       and created_at < now() - interval '3 minutes'
       and (created_at at time zone 'Asia/Jakarta')::date = p_day
     order by created_at
  loop
    if t.source_ref is not null
       and not exists (select 1 from public.ipal_reports r where r.message_id = t.source_ref) then
      v_media := coalesce(t.payload->>'mimetype', '') ~ '^(image|video)/'
              or coalesce(t.payload->>'message_type', '') in ('imageMessage', 'videoMessage');
      v_text := btrim(coalesce(t.payload->>'text', ''));
      v_words := coalesce(array_length(regexp_split_to_array(v_text, '\s+'), 1), 0);
      -- sama seperti penyaring obrolan di agen: teks panjang / pesan pengingat bukan laporan
      if not v_media and (v_words > 40 or v_text ~* 'pengingat|belum\s+(lapor|report|kirim|setor)|tolong\s+(lapor|kirim)') then
        v_text := '';
      end if;
      perform public.ipal_record_report(t.source_ref, t.chat_id, v_text, v_media, t.payload->>'sender');
      v_ids := v_ids || t.source_ref;
    end if;
    update public.tasks set status = 'done', finished_at = now(),
           result = jsonb_build_object('reconciled', true)
     where id = t.id;
  end loop;
  -- jam & hari laporan dikembalikan ke waktu pesan aslinya; sudah dikonfirmasi lewat teks pengingat ini
  update public.ipal_reports r
     set reported_at = t2.created_at,
         report_date = (t2.created_at at time zone 'Asia/Jakarta')::date,
         acked_at = coalesce(r.acked_at, now())
    from public.tasks t2
   where t2.agent_id = 'ipal' and t2.source_ref = r.message_id and r.message_id = any(v_ids);
  select coalesce(array_agg(s.kitchen_id), '{}') into v_after from public.ipal_status_day(p_day, true) s where s.sudah;
  select array_agg('✅ Laporan IPAL ' || k.name || ' tercatat.' order by k.position)
    into v_lines
    from public.ipal_kitchens k
   where k.id = any(v_after) and not (k.id = any(v_before));
  return v_lines;
end $$;

-- Tempelkan konfirmasi "tercatat" di depan teks pengingat (satu pesan, konfirmasi dulu).
create or replace function public.ipal_prepend_confirmations(p_core jsonb, p_lines text[])
returns jsonb
language sql immutable as $$
  select case when p_lines is null then p_core
              else jsonb_set(p_core, '{reply}',
                     to_jsonb(array_to_string(p_lines, E'\n') ||
                              case when p_core->>'reply' is not null then E'\n\n' || (p_core->>'reply') else '' end))
         end;
$$;

create or replace function public.ipal_pending_today(p_require_media boolean default true)
returns jsonb
language plpgsql
set search_path = public, extensions
as $$
declare v_lines text[];
begin
  begin
    v_lines := public.ipal_reconcile((now() at time zone 'Asia/Jakarta')::date);
  exception when others then v_lines := null;   -- cek silang tidak boleh menggagalkan pengingat
  end;
  return public.ipal_prepend_confirmations(public.ipal_pending_today_core(p_require_media), v_lines);
end $$;

create or replace function public.ipal_pending_yesterday(p_require_media boolean default true)
returns jsonb
language plpgsql
set search_path = public, extensions
as $$
declare v_lines text[];
begin
  begin
    v_lines := public.ipal_reconcile((now() at time zone 'Asia/Jakarta')::date - 1);
  exception when others then v_lines := null;
  end;
  return public.ipal_prepend_confirmations(public.ipal_pending_yesterday_core(p_require_media), v_lines);
end $$;


-- ── Laporan tidak lengkap ───────────────────────────────────────────
-- Dipanggil tiap 5 menit. Teks nama dapur tanpa foto, atau foto tanpa nama dapur, yang tetap
-- tidak berpasangan setelah p_minutes menit → satu pengumuman ke grup (sekali saja per laporan).
create or replace function public.ipal_incomplete_notices(p_minutes int default 20)
returns jsonb
language plpgsql
set search_path = public, extensions
as $$
declare
  v_kitchens text;
  v_photos   int;
  v_times    text;
  v_lines    text[] := '{}';
begin
  -- agen IPAL dimatikan → tidak ada pengumuman apa pun
  if not coalesce((select enabled from public.agents where id = 'ipal'), false) then
    return jsonb_build_object('reply', null);
  end if;
  with t as (
    update public.ipal_reports r
       set notified_at = now()
     where r.notified_at is null
       and r.report_date = (now() at time zone 'Asia/Jakarta')::date
       and r.reported_at < now() - make_interval(mins => p_minutes)
       and (
            (r.kitchen_id is null and r.has_media)
         or (r.kitchen_id is not null and not r.has_media
             and not exists (select 1 from public.ipal_reports x
                              where x.kitchen_id = r.kitchen_id and x.has_media
                                and x.report_date = r.report_date))
       )
    returning r.kitchen_id, r.has_media, r.reported_at
  )
  select
    (select string_agg(distinct k.name, ', ') from t join public.ipal_kitchens k on k.id = t.kitchen_id where not t.has_media),
    (select count(*) from t where t.kitchen_id is null),
    (select string_agg(to_char(t.reported_at at time zone 'Asia/Jakarta', 'HH24:MI'), ', ' order by t.reported_at)
       from t where t.kitchen_id is null)
  into v_kitchens, v_photos, v_times;

  if v_kitchens is not null then
    v_lines := v_lines || ('• ' || v_kitchens || ': sudah ada tulisan nama dapur, tapi belum ada foto');
  end if;
  if v_photos > 0 then
    v_lines := v_lines || ('• ' || v_photos || ' foto (jam ' || v_times || ' WIB) belum ada nama dapur');
  end if;

  return jsonb_build_object('reply', case when cardinality(v_lines) > 0 then
    '⚠️ Belum dihitung, laporan tidak lengkap:' || E'\n' || array_to_string(v_lines, E'\n') || E'\n\n' ||
    'Mohon lengkapi: foto + nama dapur (contoh: "IPAL Grabag").' end);
end $$;

-- ── Agen IPAL di daftar agen ────────────────────────────────────────
-- Pemicu: nama dapur/kecamatan + kata "ipal" muncul di pesan grup tanpa perintah.
insert into public.agents (id, name, role, emoji, color, triggers, priority, enabled, desk)
values ('ipal', 'IPAL', 'Laporan harian 9 dapur MBG', '💧', '#0ea5e9',
        array['@media','ipal','pringsari','pringapus','doplang','bawen','lodoyong','ambarawa','ngrapah',
              'banyubiru','badran','kranggan','sawangan','kedungsari','grabag','tersidilor','pituruh'],
        5, true, '{"x":2,"z":0}')
on conflict (id) do update
  set name = excluded.name, role = excluded.role, emoji = excluded.emoji, color = excluded.color,
      triggers = excluded.triggers, priority = excluded.priority, desk = excluded.desk;

-- ── Hak akses: hanya service_role (n8n) ─────────────────────────────
grant all on public.ipal_kitchens, public.ipal_reports to service_role;
grant usage, select on all sequences in schema public to service_role;
-- ── Konfirmasi tertunda ─────────────────────────────────────────────
-- Balasan ✅ tidak langsung: tunggu pengirim diam p_quiet_minutes menit (foto/video lanjutan masih datang).
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='ipal_reports' and column_name='acked_at') then
    alter table public.ipal_reports add column acked_at timestamptz;
    update public.ipal_reports set acked_at = reported_at;   -- laporan lama sudah dibalas langsung dulu
  end if;
end $$;

create or replace function public.ipal_pending_acks(p_quiet_minutes int default 2)
returns jsonb
language plpgsql
set search_path = public, extensions
as $$
declare
  v_lines text[];
begin
  if not coalesce((select enabled from public.agents where id = 'ipal'), false) then
    return jsonb_build_object('reply', null);
  end if;
  -- laporan yang sudah lewat 30 menit tidak pernah dikonfirmasi lagi (mis. dibetulkan manual belakangan)
  update public.ipal_reports set acked_at = now()
   where acked_at is null and reported_at < now() - interval '30 minutes';
  with ready as (
    select r.kitchen_id, r.sender
      from public.ipal_reports r
     where r.acked_at is null and r.kitchen_id is not null and r.has_media
       and r.report_date = (now() at time zone 'Asia/Jakarta')::date
     group by r.kitchen_id, r.sender
    having not exists (select 1 from public.ipal_reports x
                        where x.sender is not distinct from r.sender
                          and x.reported_at > now() - make_interval(mins => p_quiet_minutes))
  ), prev as (
    select distinct kitchen_id from public.ipal_reports
     where acked_at is not null and report_date = (now() at time zone 'Asia/Jakarta')::date
  ), upd as (
    update public.ipal_reports r set acked_at = now()
      from ready
     where r.acked_at is null and r.kitchen_id = ready.kitchen_id
       and r.sender is not distinct from ready.sender and r.has_media
       and r.report_date = (now() at time zone 'Asia/Jakarta')::date
    returning r.kitchen_id
  ), agg as (
    select kitchen_id, count(*) as n from upd group by kitchen_id
  )
  select array_agg(
           case when p.kitchen_id is not null
                then 'ℹ️ ' || k.name || ' sudah lapor hari ini. Foto/video tambahan dicatat.'
                else '✅ Laporan IPAL ' || k.name || ' tercatat.' end
           order by k.position)
    into v_lines
    from agg a join public.ipal_kitchens k on k.id = a.kitchen_id
    left join prev p on p.kitchen_id = a.kitchen_id;
  if v_lines is null then return jsonb_build_object('reply', null); end if;
  return jsonb_build_object('reply', array_to_string(v_lines, E'\n'));
end $$;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('ipal_match','ipal_record_report','ipal_status_day','ipal_status_today','ipal_pending_today','ipal_pending_yesterday','ipal_tgl_id','ipal_pending_today_core','ipal_pending_yesterday_core','ipal_reconcile','ipal_prepend_confirmations','ipal_incomplete_notices','ipal_pending_acks')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;
