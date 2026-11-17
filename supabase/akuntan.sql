-- ═══════════════════════════════════════════════════════════════════
-- Agen Akuntan — Berdikari Koffee (jalankan SETELAH schema.sql & ipal.sql, aman diulang)
-- ═══════════════════════════════════════════════════════════════════
-- Dua jenis laporan di grup "BERDIKARI - LAPORAN HARIAN":
--   1) Foto lembar penjualan harian (garis per menu, Cash/QRIS/Online, 2 shift, kotak belanja)
--   2) Laporan pengeluaran (teks berformat "LAPORAN PENGELUARAN BERDIKARI KOFFEE" + foto nota/barang)
-- Semua dicatat apa adanya, tanpa kategori. Pintu masuk tunggal: akun_handle(jsonb).
-- Disesuaikan dengan buku Balqis (sheet "PIC: BALQIS | LAPORAN BERDIKARI KOFFEE"):
--   Penjualan Cash/hari = cash akhir − modal + belanja harian        (bukan dari garis)
--   Penjualan QRIS/hari = kertas dulu (sementara); setelah pencairan bank BNI masuk (berkala), angka bank yang dipakai
--     (tanggal real QRIS = hari sebelum tanggal masuk; di buku Balqis kolom QRIS = BNI, cocok 327/327 hari)
--   Penjualan Online/hari = Σ Shopee + GoFood + Grab dari aplikasi merchant (paling nyata); kertas tetap dicatat → potongan = kertas − merchant
--   Event/Catering = uang masuk di mutasi bank
-- Cek otomatis (hanya memberi tanda, tidak menolak):
--   QRIS   = Σ garis QRIS × harga menu            vs QRIS tertulis
--   Cash   = modal + Σ garis Cash × harga − belanja   vs Cash Akhir shift terakhir
--
-- Privasi: SEMUA tabel akun_* tertutup untuk dashboard (tanpa policy). Nominal tidak boleh masuk
-- agent_events — agen ini diberi config.redact_events agar log "pesan masuk" tidak memuat isi pesan.

-- ── Tabel ───────────────────────────────────────────────────────────
create table if not exists public.akun_menu (
  id        text primary key check (id ~ '^[a-z0-9_]+$'),
  name      text not null,                 -- nama seperti tertulis di lembar
  category  text not null default 'lain',  -- coffee | non_coffee | makanan | lain | eceran (barang eceran: rokok, air mineral — bukan menu)
  price     int,                           -- Rupiah penuh. NULL = harga belum diisi
  aliases   text[] not null default '{}',
  position  int not null default 0,
  enabled   boolean not null default true
);

create table if not exists public.akun_sheets (
  id          bigint generated always as identity primary key,
  sheet_date  date not null unique,        -- satu lembar per tanggal; kirim ulang = menggantikan
  message_id  text,
  chat_id     text,
  sender      text,
  reported_at timestamptz not null default now(),
  flags       jsonb not null default '[]'::jsonb,
  raw         jsonb                        -- hasil bacaan foto (tanpa gambar)
);

create table if not exists public.akun_shifts (
  sheet_id   bigint not null references public.akun_sheets(id) on delete cascade,
  shift      int not null check (shift between 1 and 3),
  barista    text,
  ink        text,
  modal      int,
  cash_akhir int,
  qris       int,
  discount   int,
  primary key (sheet_id, shift)
);

create table if not exists public.akun_sales (
  id         bigint generated always as identity primary key,
  sheet_id   bigint not null references public.akun_sheets(id) on delete cascade,
  shift      int,                          -- NULL = tidak bisa ditentukan dari warna tinta
  menu_id    text references public.akun_menu(id) on update cascade,
  item_name  text not null,
  channel    text not null check (channel in ('cash','qris','online')),
  qty        int not null check (qty > 0),
  unit_price int,                          -- harga saat dicatat (NULL = belum ada harga)
  ink        text
);
create index if not exists akun_sales_sheet_idx on public.akun_sales (sheet_id);

create table if not exists public.akun_expenses (
  id            bigint generated always as identity primary key,
  expense_date  date not null,
  item          text not null,
  amount        int not null check (amount >= 0),
  source_raw    text,                      -- sumber uang apa adanya: "uang plastik", "uang berdi"
  reporter      text,
  origin        text not null check (origin in ('laporan','lembar')),
  sheet_id      bigint references public.akun_sheets(id) on delete cascade,
  message_id    text,
  chat_id       text,
  sender        text,
  has_media     boolean not null default false,
  receipt_total int,                       -- total di nota (dibaca dari foto) bila ada
  flags         jsonb not null default '[]'::jsonb,
  created_at    timestamptz not null default now()
);
create unique index if not exists akun_expenses_msg_uidx
  on public.akun_expenses (message_id) where message_id is not null and origin = 'laporan';
create index if not exists akun_expenses_day_idx on public.akun_expenses (expense_date);

-- Foto nota/barang yang datang SEBELUM teks laporan (menunggu pasangan, maks 20 menit)
create table if not exists public.akun_pending_media (
  message_id    text primary key,
  chat_id       text,
  sender        text,
  receipt_total int,
  created_at    timestamptz not null default now()
);

-- ── Penyesuaian ke buku Balqis (kolom tambahan; aman diulang) ───────
alter table public.akun_menu    add column if not exists menu_group text;   -- grup di sheet HPP: COFFEE N' MILK, MANUAL BREW, …
alter table public.akun_menu    add column if not exists hpp int;           -- HPP per porsi (varian Ice bila ada Ice/Hot)
alter table public.akun_sheets  add column if not exists cash_sales    int;  -- Σ garis Cash × harga
alter table public.akun_sheets  add column if not exists qris_sales    int;  -- Σ garis QRIS × harga
alter table public.akun_sheets  add column if not exists online_sales  int;  -- Σ garis Online × harga (kotor)
alter table public.akun_sheets  add column if not exists belanja       int;  -- Σ kotak "Pengeluaran belanja" (= Belanja Harian)
alter table public.akun_sheets  add column if not exists qris_written  int;  -- QRIS yang ditulis barista (Σ shift)
alter table public.akun_sheets  add column if not exists cash_expected int;  -- modal + garis tunai − belanja
alter table public.akun_sheets  add column if not exists cash_revenue  int;  -- cash akhir − modal + belanja  → "Penjualan Cash" di laba-rugi
alter table public.akun_sheets  add column if not exists plastik_in    int not null default 0;  -- uang plastik yang dipinjam ke kasir untuk kembalian (bukan belanja)
alter table public.akun_sheets  add column if not exists cash_variance int;  -- cash akhir − cash_expected (= "petty cash harian" di arus kas)
alter table public.akun_expenses add column if not exists vendor       text; -- nama toko (dari nota), mis. "Mbak Ning"
alter table public.akun_expenses add column if not exists pay_source   text; -- cash_berdi | plastik | raka | NULL
alter table public.akun_expenses add column if not exists sub_category text; -- diisi belakangan (peta: akun_category_map)
alter table public.akun_pending_media add column if not exists vendor text;

-- Nama toko dari nota ↔ nama di buku (mis. "TOKO BU NING" = "Mbak Ning")
create table if not exists public.akun_vendors (
  name    text primary key,
  aliases text[] not null default '{}'
);

-- Sub-kategori buku → kelompok laporan laba-rugi (sheet "List"). Dipakai bila pengeluaran nanti dikategorikan.
create table if not exists public.akun_category_map (
  sub_category text primary key,
  pl_group     text not null
);

-- Pencairan QRIS di mutasi BNI. Masuk di bank T+1: tanggal real QRIS = hari sebelum tanggal masuk.
create table if not exists public.akun_qris_settlements (
  id          bigint generated always as identity primary key,
  settle_date date not null,               -- "Tanggal Masuk" di bank
  real_date   date not null,               -- "Tanggal Real QRIS" (hari penjualan)
  amount      int  not null,
  unique (settle_date, real_date)
);
create index if not exists akun_qris_real_idx on public.akun_qris_settlements (real_date);

-- Pendapatan per aplikasi merchant per hari (dari aplikasi Shopee/GoFood/Grab)
create table if not exists public.akun_online_income (
  id          bigint generated always as identity primary key,
  income_date date not null,
  merchant    text not null check (merchant in ('shopee','gofood','grab','lain')),
  amount      int  not null,
  unique (income_date, merchant)
);

-- Mutasi rekening bank (uang masuk: event/catering/bulk order; uang keluar: belanja lewat bank, listrik, dll.)
create table if not exists public.akun_bank_tx (
  id           bigint generated always as identity primary key,
  tx_date      date not null,
  description  text not null,
  direction    text not null check (direction in ('masuk','keluar')),
  amount       int  not null check (amount >= 0),
  sub_category text,
  dedupe_key   text unique,                -- agar impor ulang tidak menggandakan
  created_at   timestamptz not null default now()
);
create index if not exists akun_bank_tx_date_idx on public.akun_bank_tx (tx_date);

alter table public.akun_menu          enable row level security;
alter table public.akun_sheets        enable row level security;
alter table public.akun_shifts        enable row level security;
alter table public.akun_sales         enable row level security;
alter table public.akun_expenses      enable row level security;
alter table public.akun_pending_media enable row level security;   -- tanpa policy = tertutup untuk anon
alter table public.akun_vendors          enable row level security;
alter table public.akun_category_map     enable row level security;
alter table public.akun_qris_settlements enable row level security;
alter table public.akun_online_income    enable row level security;
alter table public.akun_bank_tx          enable row level security;

-- ── Daftar menu & harga (dari menu cetak). Harga NULL = belum diisi ─
-- Mengulang file ini TIDAK menimpa harga yang sudah kamu ubah.
insert into public.akun_menu (id, name, category, price, aliases, position, menu_group, hpp) values
  ('berdikopi','Berdikopi','coffee',18000,'{}',1,'COFFEE N'' MILK',5135),
  ('karibia','Karibia','coffee',18000,'{}',2,'COFFEE N'' MILK',5455),
  ('black_mongoose','Black Mongoose','coffee',13000,'{}',3,'COFFEE N'' MILK',4378),
  ('cafe_latte','Cafe Latte','coffee',18000,'{}',4,'COFFEE N'' MILK',4150),
  ('americano','Americano','coffee',13000,'{}',5,'MANUAL BREW',2625),
  ('eskobar','Eskobar','coffee',18000,'{}',6,'BERDI''S SPECIAL',5724),
  ('berdikomint','Berdikomint','coffee',20000,'{}',7,'COFFEE N'' MILK',6177),
  ('butterscotch_coffee','Butterscotch Coffee','coffee',23000,'{}',8,'COFFEE N'' MILK',6831),
  ('caramel_macchiato','Caramel Macchiato','coffee',23000,'{}',9,'COFFEE N'' MILK',7695),
  ('v60','V60','coffee',20000,'{}',10,'MANUAL BREW',3505),
  ('bierama','Bierama','coffee',18000,'{}',11,'BERDI''S SPECIAL',5100),
  ('baileys_coffee','Baileys Coffee','coffee',23000,'{}',12,'COFFEE N'' MILK',7567),
  ('cafe_et_roselle','Cafe et Roselle','coffee',18000,'{}',13,'BERDI''S SPECIAL',2903),
  ('nirada','Nirada','coffee',18000,'{}',14,'BERDI''S SPECIAL',6432),
  ('tubruk','Tubruk','coffee',13000,'{}',15,'MANUAL BREW',971),
  ('vietnam_drip','Vietnam Drip','coffee',18000,'{}',16,'MANUAL BREW',2621),
  ('extra_shot','Extra Shot Espresso','coffee',5000,'{}',17,'COFFEE N'' MILK',null),
  ('berdisusu','Berdisusu','non_coffee',15000,'{}',20,'SWEET TOOTH CLUB!',7276),
  ('matcha_latte','Matcha Latte','non_coffee',18000,'{}',21,'SWEET TOOTH CLUB!',6203),
  ('yakuza','Yakuza','non_coffee',18000,'{}',22,'SWEET TOOTH CLUB!',7675),
  ('teh_limint','Teh Limint','non_coffee',15000,'{}',23,'TEA SELECTION',3889),
  ('barito_choco','Barito Choco','non_coffee',18000,'{}',24,'SWEET TOOTH CLUB!',6803),
  ('red_volver','Red Volver','non_coffee',18000,'{}',25,'SWEET TOOTH CLUB!',6122),
  ('lychee_tea','Lychee Tea','non_coffee',18000,'{}',26,'TEA SELECTION',6398),
  ('roseberry_cream','Roseberry Cream','non_coffee',18000,'{}',27,'SWEET TOOTH CLUB!',4055),
  ('teh_tarik','Teh Tarik','non_coffee',18000,'{}',28,'TEA SELECTION',6634),
  ('carmia','Carmia','non_coffee',18000,'{}',29,'TEA SELECTION',6858),
  ('chocoberry','Chocoberry','non_coffee',23000,'{"Choco Berry"}',30,'SWEET TOOTH CLUB!',4506),
  ('kembang_gula','Kembang Gula','non_coffee',18000,'{}',31,'SWEET TOOTH CLUB!',5835),
  ('red_regal','Red Regal','non_coffee',20000,'{}',32,'SWEET TOOTH CLUB!',8239),
  ('rosela_tea','Rosela Tea','non_coffee',13000,'{"Rosella Tea"}',33,'TEA SELECTION',2026),
  ('rosela_mint','Rosela Mint','non_coffee',18000,'{"Rosella Mint"}',34,'TEA SELECTION',3108),
  ('barito_ricebowl','Barito Rice bowl','makanan',15000,'{"Barito Rice Bowl"}',40,'FOODIES!',4774),
  ('black_panther','Black Panther','makanan',13000,'{}',41,'FOODIES!',5939),
  ('kentang_kashmir','Kentang Kashmir','makanan',18000,'{}',42,'PLATTER & SNACK',7063),
  ('lite_platter','Lite Platter','makanan',18000,'{}',43,'PLATTER & SNACK',5353),
  ('mix_platter','Mix Platter','makanan',23000,'{}',44,'PLATTER & SNACK',8103),
  ('nasi_kashmir','Nasi Kashmir','makanan',13000,'{}',45,'FOODIES!',4568),
  ('red_panda','Red Panda','makanan',13000,'{}',46,'FOODIES!',5004),
  ('snack','Snack','makanan',10000,'{"Otak-Otak","Pisang Cokelat","Snack","Snack (10K)","Tahu Walik"}',47,'PLATTER & SNACK',null),
  ('rokok_eceran','Rokok Eceran','eceran',2500,'{"Rokok","Rokok Eceran (2.5k)"}',51,'ROKOK',null),
  ('telur_ceplok','Telur Ceplok','makanan',5000,'{"TELUR CEPLOK"}',60,'FOODIES!',null),
  ('berdikopi_500ml','Berdikopi 500ml','lain',38000,'{}',61,'LAINNYA',null),
  ('banofee_500ml','Banofee 500ml','lain',46000,'{}',62,'LAINNYA',null),
  ('karibia_500ml','Karibia 500ml','lain',38000,'{}',63,'LAINNYA',null),
  ('berdikopi_250ml','Berdikopi 250ml','lain',20000,'{}',64,'LAINNYA',null),
  ('air_mineral','Air Mineral/Es Teh','eceran',3000,'{"Air Mineral","Es Teh","Teh"}',65,'LAINNYA',null),
  ('jamur_kerupuk','Jamur, Kerupuk','lain',3000,'{"Jamur","Jamur Kerupuk","Kerupuk"}',66,'LAINNYA',null),
  ('rokok_signature','Rokok Signature','eceran',1,'{"Rokok Signature (Rp)"}',67,'ROKOK',null),
  ('kopi_susu_regal','Kopi Susu Regal','coffee',20000,'{}',68,'SWEET TOOTH CLUB!',7118),
  ('choconana','Choconana','coffee',23000,'{}',69,'SWEET TOOTH CLUB!',null),
  ('japanese_v60','Japanese V60','coffee',20000,'{}',70,'MANUAL BREW',3530)
on conflict (id) do update
  set name = excluded.name, category = excluded.category, aliases = excluded.aliases, position = excluded.position,
      menu_group = excluded.menu_group,
      price = coalesce(public.akun_menu.price, excluded.price),   -- harga yang sudah kamu ubah tidak ditimpa
      hpp   = coalesce(public.akun_menu.hpp, excluded.hpp);
-- "Teh" tanpa harga digabung ke "Air Mineral/Es Teh" (Rp3.000 di sheet garis)
update public.akun_sales set menu_id = 'air_mineral' where menu_id = 'teh';
delete from public.akun_menu where id = 'teh';
-- Rokok Signature: angka di kolom garis = RUPIAH (bukan jumlah batang), jadi harga satuan = 1.

-- ── Referensi dari buku Balqis: toko langganan & peta sub-kategori → laba-rugi ──
insert into public.akun_vendors (name, aliases) values
  ('Aroma','{}'),
  ('Christna','{}'),
  ('Cleo Galon','{}'),
  ('Es Batu','{}'),
  ('Frozen Hedar','{"Hedar"}'),
  ('GAS','{}'),
  ('HS Frozen','{"HS Frozen"}'),
  ('Indah Offset','{"Indah Offset"}'),
  ('Indomaret','{}'),
  ('Mbah Uti','{}'),
  ('Mbak Ning','{"Bu Ning","Toko Bu Ning"}'),
  ('Pagoda','{"Pagoda Jaya"}'),
  ('Perdana','{}'),
  ('Prima','{}'),
  ('Shopee','{}'),
  ('Superindo','{"Super Indo"}'),
  ('Warung kaca','{"Warung kaca"}'),
  ('Warung sayur','{}'),
  ('Repvblik','{}'),
  ('Rintik Kopi','{}'),
  ('Borobudur Roastery','{}'),
  ('Alfamart','{}')
on conflict (name) do nothing;

insert into public.akun_category_map (sub_category, pl_group) values
  ('Alat Tulis','Peralatan'),
  ('Bayar Sampah','Lain-lain'),
  ('Belanja @ Alfamart','Belanja Bahan'),
  ('Belanja @ Aroma','Belanja Bahan'),
  ('Belanja @ Christna','Belanja Bahan'),
  ('Belanja @ Indomaret','Belanja Bahan'),
  ('Belanja @ Mbak Ning','Belanja Bahan'),
  ('Belanja @ Pagoda','Belanja Bahan'),
  ('Belanja @ Perdana','Belanja Bahan'),
  ('Belanja @ Prima','Belanja Bahan'),
  ('Belanja @ Repvblik','Belanja Bahan'),
  ('Belanja @ Shopee','Belanja Bahan'),
  ('Belanja @ Superindo','Belanja Bahan'),
  ('Belanja @ Warung kaca','Belanja Bahan'),
  ('Belanja @ Warung sayur','Belanja Bahan'),
  ('Belanja @ tokobarito','Belanja Bahan'),
  ('Belanja @ ud bagas','Belanja Bahan'),
  ('Belanja Frozen','Belanja Bahan'),
  ('Belanja Harian','Belanja Bahan'),
  ('Bensin','Lain-lain'),
  ('Cash Berdi','Penjualan Cash'),
  ('Cash Income','Penjualan Cash'),
  ('Dekorasi','Peralatan'),
  ('Es batu','Belanja Bahan'),
  ('Event','Pemasukan Event'),
  ('Galon','Wifi/Gas/Galon/Listrik'),
  ('Gas','Wifi/Gas/Galon/Listrik'),
  ('Kentang','Belanja Bahan'),
  ('Kopi','Belanja Bahan'),
  ('Listrik','Wifi/Gas/Galon/Listrik'),
  ('Nasi','Belanja Bahan'),
  ('Online','Penjualan Online'),
  ('Parkir','Lain-lain'),
  ('Payroll / Fee','Payroll / Fee'),
  ('Pengeluaran Pribadi','Pengeluaran Pribadi'),
  ('Peralatan','Peralatan'),
  ('Percetakan','Percetakan'),
  ('QRIS','Penjualan QRIS'),
  ('Rokok','Belanja Bahan'),
  ('Spotify','Lain-lain'),
  ('Susu UHT','Belanja Bahan'),
  ('Telur','Belanja Bahan'),
  ('Transfer Account','Lain-lain'),
  ('Tukang','Payroll / Fee'),
  ('Unconfirmed','Lain-lain'),
  ('Wifi','Wifi/Gas/Galon/Listrik'),
  ('Yakult','Belanja Bahan'),
  ('Jasa','Payroll / Fee'),
  ('Tobii','Lain-lain'),
  ('Komisi Online / Admin','Komisi Online / Admin'),
  ('Ads Meta','Ads Meta')
on conflict (sub_category) do nothing;

-- ── Fungsi bantu ────────────────────────────────────────────────────
create or replace function public.akun_norm(p text) returns text
language sql immutable as $$ select regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]', '', 'g') $$;

-- jsonb (angka atau teks "75.000") → int; tidak terbaca → NULL
create or replace function public.akun_int(v jsonb) returns int
language sql immutable as $$
  select case jsonb_typeof(v)
           when 'number' then round((v #>> '{}')::numeric)::int
           when 'string' then nullif(regexp_replace(v #>> '{}', '[^0-9]', '', 'g'), '')::int
         end
$$;

-- "uang berdi" → cash_berdi (kas laci); "uang plastik" → plastik; "uang raka" → raka. Lainnya NULL.
create or replace function public.akun_pay_source(p text) returns text
language sql immutable as $$
  select case when public.akun_norm(p) like '%berdi%' then 'cash_berdi'
              when public.akun_norm(p) like '%plastik%' or public.akun_norm(p) like '%platik%' then 'plastik'
              when public.akun_norm(p) like '%raka%' then 'raka'
         end
$$;

-- Nama toko di nota → nama toko di buku (kecocokan sebagian, mis. "TOKO BU NING" → "Mbak Ning"); tak cocok = apa adanya
create or replace function public.akun_match_vendor(p text) returns text
language sql stable as $$
  select coalesce(
    (select v.name from public.akun_vendors v
      where nullif(btrim(p), '') is not null
        and (case when length(public.akun_norm(v.name)) < 4 then public.akun_norm(p) = public.akun_norm(v.name)
                  else public.akun_norm(p) like '%' || public.akun_norm(v.name) || '%' end
             or exists (select 1 from unnest(v.aliases) a
                         where length(public.akun_norm(a)) >= 4 and public.akun_norm(p) like '%' || public.akun_norm(a) || '%'))
      order by length(v.name) desc limit 1),
    nullif(left(btrim(p), 60), ''))
$$;

create or replace function public.akun_rp(n numeric) returns text
language sql immutable as $$
  select case when n is null then '-' else
    (case when n < 0 then '-' else '' end) || 'Rp' ||
    regexp_replace(abs(round(n))::bigint::text, '(\d)(?=(\d{3})+$)', '\1.', 'g') end
$$;

create or replace function public.akun_tgl(d date) returns text
language sql immutable as $$
  select extract(day from d)::int || ' ' ||
         (array['Jan','Feb','Mar','Apr','Mei','Jun','Jul','Agu','Sep','Okt','Nov','Des'])[extract(month from d)::int]
         || ' ' || extract(year from d)::int
$$;

create or replace function public.akun_match_menu(p text) returns text
language sql stable as $$
  select m.id from public.akun_menu m
   where m.enabled and p is not null and btrim(p) <> ''
     and (public.akun_norm(m.name) = public.akun_norm(p)
          or exists (select 1 from unnest(m.aliases) a where public.akun_norm(a) = public.akun_norm(p)))
   order by m.position limit 1
$$;


-- ── Anti-dobel: belanja yang sama muncul di lembar harian DAN di laporan teks (nota) ──
-- Pasangkan 1:1 per tanggal: nominal sama (+ nama mirip didahulukan). Baris lembar yang cocok diberi dup_of = id laporan,
-- sehingga di total pengeluaran hanya dihitung sekali (laporan teks dianggap utama: ada pelapor, toko, foto nota).
-- Hitungan kas harian tetap memakai SEMUA belanja di lembar (itu uang yang keluar dari laci).
alter table public.akun_expenses add column if not exists dup_of bigint;
-- Apakah nominal p_amt disebut di teks sumber uang laporan? ("uang berdi 2.5k uang plastik 150k", "10.000", "10000")
create or replace function public.akun_amt_in(p_src text, p_amt int) returns boolean
language sql immutable as $$
  select p_amt > 0 and coalesce(p_src, '') <> '' and (
    lower(p_src) ~ ('(^|[^0-9.,])' || replace(trim_scale(p_amt / 1000.0)::text, '.', '[.,]') || '\s*(k|rb|ribu)')
    or regexp_replace(regexp_replace(p_src, '([0-9])[.,]([0-9]{3})', '\1\2', 'g'), '([0-9])[.,]([0-9]{3})', '\1\2', 'g')
       ~ ('(^|[^0-9])' || p_amt::text || '([^0-9]|$)'));
$$;

-- Satu pengeluaran bisa muncul dua kali (laporan teks/nota dan lembar harian). Ditandai lewat dup_of pada baris lembar
-- (baris lembar tidak dihitung; laporan dihitung sekali). Tiga putaran:
--   1) nominal sama persis (nama barang dipakai untuk memilih bila ada beberapa kandidat)
--   2) baris lembar yang hanya SEBAGIAN dari satu laporan (mis. "Galon 10.000" dari galon 132k), nama barang beririsan
--   3) beberapa baris lembar yang JUMLAHNYA persis sama dengan satu laporan dan nominalnya disebut di sumber uang laporan
--      (mis. "uang beli Frozen 2.500" + "uang plastik Frozen 150.000" = laporan "kentang & otak" 152.500)
create or replace function public.akun_dedupe(p_date date) returns int
language plpgsql as $$
declare l record; t record; r record; v_best bigint; v_score int; v_s int; v_n int := 0; tok text;
        v_sum bigint; v_ids bigint[];
begin
  update public.akun_expenses set dup_of = null where origin = 'lembar' and expense_date = p_date and dup_of is not null;
  for l in select id, item, amount from public.akun_expenses
            where origin = 'lembar' and expense_date = p_date and amount > 0 order by id loop
    v_best := null; v_score := -1;
    for t in select e.id, e.item from public.akun_expenses e
              where e.origin = 'laporan' and e.expense_date = p_date and e.amount = l.amount
                and not exists (select 1 from public.akun_expenses x where x.dup_of = e.id)
              order by e.id loop
      v_s := 0;
      for tok in select w from regexp_split_to_table(lower(l.item), '[^a-z0-9]+') w where length(w) >= 3 loop
        if position(tok in lower(t.item)) > 0 then v_s := v_s + 1; end if;
      end loop;
      if v_s > v_score then v_score := v_s; v_best := t.id; end if;
    end loop;
    if v_best is not null then
      update public.akun_expenses set dup_of = v_best where id = l.id;
      v_n := v_n + 1;
    end if;
  end loop;
  for l in select id, item, amount from public.akun_expenses
            where origin = 'lembar' and expense_date = p_date and amount > 0 and dup_of is null order by id loop
    v_best := null; v_score := 0;
    for t in select e.id, e.item from public.akun_expenses e
              where e.origin = 'laporan' and e.expense_date = p_date and e.amount > l.amount
                and public.akun_amt_in(e.source_raw, l.amount)
                and e.amount >= l.amount + coalesce((select sum(x.amount) from public.akun_expenses x where x.dup_of = e.id), 0)
              order by e.id loop
      v_s := 0;
      for tok in select w from regexp_split_to_table(lower(l.item), '[^a-z0-9]+') w where length(w) >= 3 loop
        if position(tok in lower(t.item)) > 0 then v_s := v_s + 1; end if;
      end loop;
      if v_s > v_score then v_score := v_s; v_best := t.id; end if;
    end loop;
    if v_best is not null then
      update public.akun_expenses set dup_of = v_best where id = l.id;
      v_n := v_n + 1;
    end if;
  end loop;
  for r in select e.id, e.amount, e.source_raw from public.akun_expenses e
            where e.origin = 'laporan' and e.expense_date = p_date and coalesce(e.source_raw, '') <> ''
              and not exists (select 1 from public.akun_expenses x where x.dup_of = e.id)
            order by e.id loop
    select coalesce(sum(x.amount), 0), array_agg(x.id) into v_sum, v_ids
      from public.akun_expenses x
     where x.origin = 'lembar' and x.expense_date = p_date and x.amount > 0 and x.dup_of is null
       and public.akun_amt_in(r.source_raw, x.amount);
    if v_ids is not null and v_sum = r.amount then
      update public.akun_expenses set dup_of = r.id where id = any(v_ids);
      v_n := v_n + array_length(v_ids, 1);
    end if;
  end loop;
  return v_n;
end $$;

-- ── Rekap satu hari (juga untuk perintah "/akuntan rekap") ──────────
create or replace function public.akun_day_summary(p_date date) returns text
language plpgsql stable as $$
declare
  s record; v_cash numeric; v_qris numeric; v_online numeric; v_missing text;
  v_belanja_lembar numeric; v_belanja_lap numeric; v_last_cash int; v_lines text := '';
  r record;
begin
  select * into s from public.akun_sheets where sheet_date = p_date;
  select coalesce(sum(e.amount),0) into v_belanja_lap from public.akun_expenses e
   where e.expense_date = p_date and e.origin = 'laporan';
  if s.id is null then
    return '📒 ' || public.akun_tgl(p_date) || E'\nBelum ada lembar penjualan untuk tanggal ini.'
      || case when v_belanja_lap > 0 then E'\nPengeluaran per laporan: ' || public.akun_rp(v_belanja_lap) else '' end;
  end if;
  select coalesce(sum(qty*unit_price) filter (where channel='cash'),0),
         coalesce(sum(qty*unit_price) filter (where channel='qris'),0),
         coalesce(sum(qty*unit_price) filter (where channel='online'),0),
         string_agg(distinct item_name, ', ') filter (where unit_price is null)
    into v_cash, v_qris, v_online, v_missing
    from public.akun_sales where sheet_id = s.id;
  select coalesce(sum(amount),0) into v_belanja_lembar from public.akun_expenses where sheet_id = s.id;
  select cash_akhir into v_last_cash from public.akun_shifts
   where sheet_id = s.id and cash_akhir is not null order by shift desc limit 1;
  for r in select item, amount, source_raw from public.akun_expenses
            where expense_date = p_date and origin = 'laporan' order by id loop
    v_lines := v_lines || E'\n• ' || r.item || ' ' || public.akun_rp(r.amount)
               || coalesce(' (' || nullif(r.source_raw,'') || ')', '');
  end loop;
  return '📒 Rekap ' || public.akun_tgl(p_date) || E'\n' ||
    'Penjualan: Cash ' || public.akun_rp(v_cash) || ' · QRIS ' || public.akun_rp(v_qris) ||
    ' · Online ' || public.akun_rp(v_online) || ' · Total ' || public.akun_rp(v_cash+v_qris+v_online) || E'\n' ||
    'Belanja di lembar: ' || public.akun_rp(v_belanja_lembar) || E'\n' ||
    'Cash akhir tertulis: ' || public.akun_rp(v_last_cash) ||
    case when v_missing is not null then E'\n⚠️ Harga belum ada: ' || v_missing || ' (belum dihitung)' else '' end ||
    case when v_lines <> '' then E'\nPengeluaran per laporan: ' || public.akun_rp(v_belanja_lap) || v_lines else '' end;
end $$;

-- ── Pintu masuk tunggal ─────────────────────────────────────────────
-- p = {kind, message_id, chat_id, sender, ...}
--   kind 'sheet'        : p.sheet  = hasil bacaan lembar harian (JSON dari model penglihat)
--   kind 'expense_text' : p.expense = {date, reporter, item, amount, source_raw}; p.photo opsional {type,total}
--   kind 'photo'        : p.photo = {type: nota|foto_barang, total, vendor}
--   kind 'rekap'        : p.date (opsional, YYYY-MM-DD)
--   kind 'bukti_bayar'  : p.proof = {amount, date?, item?, vendor?}   (foto bukti transfer/token listrik; dicatat otomatis)
--   kind 'settlement'   : p.rows = [{settle_date, real_date?, amount}]   (pencairan QRIS bank, berkala)
--   kind 'online_income': p.rows = [{date, merchant, amount}]            (pendapatan Shopee/GoFood/Grab dari aplikasi)
-- Hasil: {reply: teks|null, ...}
create or replace function public.akun_handle(p jsonb) returns jsonb
language plpgsql
as $$
declare
  v_kind    text := p->>'kind';
  v_today   date := (now() at time zone 'Asia/Jakarta')::date;
  v_msg     text := p->>'message_id';
  v_chat    text := p->>'chat_id';
  v_sender  text := p->>'sender';
  -- lembar
  s jsonb; v_date date; v_sheet bigint; v_replaced boolean := false; v_datenote text := '';
  sh jsonb; sl jsonb; ex jsonb; v_shift int; v_menu text; v_price int; v_chan text; v_qty int; v_ink text;
  v_cash numeric; v_qris numeric; v_online numeric; v_missing_all text; v_missing_cash text; v_missing_qris text;
  v_belanja numeric; v_modal int; v_last_cash int; v_qris_written int; v_exp numeric;
  v_flags jsonb := '[]'::jsonb; v_unc text; v_unknown text; v_disc int; v_reply text;
  v_check text[] := '{}'; v_dupn int := 0; v_dupnote text := ''; v_out numeric; v_warn text;
  v_plastik int := 0; v_res jsonb; v_stf text; v_stf_bad text;
  -- pengeluaran
  e jsonb; v_amount int; v_item text; v_edate date; v_total int; v_rows int; v_id bigint; v_has_media boolean := false;
  v_pend record; v_photo jsonb := p->'photo'; v_vendor text; v_pay text;
  rw jsonb; rc record; v_n int; v_ok int; v_sd date; v_rd date; v_amt int; v_diff text; v_nolembar text; v_tot_k numeric; v_tot_m numeric; v_mer text;
begin
  -- bersihkan foto yatim (> 2 hari)
  delete from public.akun_pending_media where created_at < now() - interval '2 days';

  -- ═══ REKAP ═══
  if v_kind = 'rekap' then
    begin v_date := coalesce((p->>'date')::date, v_today); exception when others then v_date := v_today; end;
    return jsonb_build_object('reply', public.akun_day_summary(v_date));
  end if;

  -- ═══ PENCAIRAN QRIS (kiriman berkala, mis. seminggu sekali) ═══
  -- p.rows = [{settle_date, real_date?, amount}] ; real_date kosong = settle_date − 1 hari.
  -- QRIS dari kertas dipakai dulu; setelah pencairan masuk, angka bank menggantikan dan selisihnya dilaporkan.
  if v_kind = 'settlement' then
    v_n := 0; v_ok := 0; v_diff := ''; v_nolembar := '';
    for rw in select * from jsonb_array_elements(coalesce(p->'rows', '[]'::jsonb)) loop
      begin
        v_sd := (rw->>'settle_date')::date;
        v_rd := coalesce((rw->>'real_date')::date, v_sd - 1);
      exception when others then continue; end;
      v_amt := public.akun_int(rw->'amount');
      continue when v_amt is null or v_sd is null;
      insert into public.akun_qris_settlements (settle_date, real_date, amount) values (v_sd, v_rd, v_amt)
      on conflict (settle_date, real_date) do update set amount = excluded.amount;
      v_n := v_n + 1;
      select qris_written into v_amt from public.akun_sheets where sheet_date = v_rd;
      if not found then
        v_nolembar := v_nolembar || ' ' || public.akun_tgl(v_rd);
      elsif v_amt is not null then
        select coalesce(sum(amount),0) into v_tot_m from public.akun_qris_settlements where real_date = v_rd;
        if v_amt = v_tot_m then v_ok := v_ok + 1;
        else v_diff := v_diff || E'\n• ' || public.akun_tgl(v_rd) || ': kertas ' || public.akun_rp(v_amt) || ', bank ' || public.akun_rp(v_tot_m); end if;
      end if;
    end loop;
    return jsonb_build_object('reply',
      '✅ ' || v_n || ' pencairan QRIS tercatat. Cocok dengan kertas: ' || v_ok || ' hari.' ||
      case when v_diff <> '' then E'\n⚠️ Selisih (angka bank dipakai):' || v_diff else '' end ||
      case when v_nolembar <> '' then E'\nBelum ada lembar kertas untuk:' || v_nolembar else '' end);
  end if;

  -- ═══ PENDAPATAN MERCHANT ONLINE (data nyata dari aplikasi; kertas tetap dicatat untuk melihat potongan) ═══
  -- p.rows = [{date, merchant, amount}] ; merchant: shopee | gofood | grab (nama lain → 'lain')
  if v_kind = 'online_income' then
    v_n := 0; v_diff := ''; v_tot_k := 0; v_tot_m := 0;
    for rw in select * from jsonb_array_elements(coalesce(p->'rows', '[]'::jsonb)) loop
      begin v_sd := (rw->>'date')::date; exception when others then continue; end;
      v_amt := public.akun_int(rw->'amount');
      continue when v_amt is null or v_sd is null;
      v_mer := case when public.akun_norm(rw->>'merchant') like '%shopee%' then 'shopee'
                    when public.akun_norm(rw->>'merchant') like '%gofood%' or public.akun_norm(rw->>'merchant') like '%gojek%' then 'gofood'
                    when public.akun_norm(rw->>'merchant') like '%grab%' then 'grab' else 'lain' end;
      insert into public.akun_online_income (income_date, merchant, amount) values (v_sd, v_mer, v_amt)
      on conflict (income_date, merchant) do update set amount = excluded.amount;
      v_n := v_n + 1;
    end loop;
    -- potongan = garis online di kertas (kotor) − pendapatan merchant, hanya untuk hari yang punya keduanya
    select coalesce(sum(s2.online_sales),0), coalesce(sum(o.tot),0) into v_tot_k, v_tot_m
      from public.akun_sheets s2
      join (select income_date, sum(amount) tot from public.akun_online_income group by 1) o on o.income_date = s2.sheet_date
     where s2.online_sales is not null
       and s2.sheet_date in (select (x->>'date')::date from jsonb_array_elements(coalesce(p->'rows','[]'::jsonb)) x where x->>'date' ~ '^\d{4}-\d{2}-\d{2}$');
    return jsonb_build_object('reply',
      '✅ ' || v_n || ' baris pendapatan merchant tercatat.' ||
      case when v_tot_k > 0 then E'\nHari yang ada kertasnya: kertas ' || public.akun_rp(v_tot_k) || ', merchant ' || public.akun_rp(v_tot_m) ||
           ', potongan ' || public.akun_rp(v_tot_k - v_tot_m) else '' end);
  end if;

  -- ═══ GRUP PENGELUARAN: satu pengeluaran per pesan, dicatat ke tabel terpisah, tanpa balasan ═══
  if v_kind = 'grup_pengeluaran' then
    e := p->'expense';
    v_amount := public.akun_int(e->'amount');
    if v_amount is null or v_amount <= 0 then return jsonb_build_object('reply', null); end if;
    begin v_edate := (e->>'date')::date; exception when others then v_edate := null; end;
    if v_edate is null then return jsonb_build_object('reply', null); end if;
    insert into public.akun_pengeluaran_grup (tanggal, item, amount, metode, pribadi, reporter, message_id, chat_id, sender, raw)
    values (v_edate, coalesce(nullif(left(btrim(coalesce(e->>'item','')), 120), ''), 'Pengeluaran'), v_amount,
            nullif(left(btrim(coalesce(e->>'metode','')), 20), ''), coalesce((e->>'pribadi')::boolean, false),
            nullif(initcap(left(btrim(coalesce(e->>'reporter','')), 40)), ''), v_msg, v_chat, v_sender,
            left(coalesce(e->>'raw',''), 300))
    on conflict (message_id) where message_id is not null do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then return jsonb_build_object('reply', null, 'duplicate', true); end if;
    return jsonb_build_object('reply', 'Pengeluaran sudah aku catat kakak Meita 🙏');
  end if;

  -- ═══ KOREKSI BELANJA LEMBAR ═══
  -- p.date (boleh kosong = lembar terakhir), p.items = [{item, amount}] → menggantikan seluruh daftar belanja lembar itu,
  -- lalu lembar diproses ulang (cash, selisih, dsb. dihitung ulang).
  if v_kind = 'koreksi' then
    begin v_date := (p->>'date')::date; exception when others then v_date := null; end;
    if v_date is null then
      select sheet_date into v_date from public.akun_sheets order by sheet_date desc limit 1;
    end if;
    select raw into s from public.akun_sheets where sheet_date = v_date;
    if s is null then
      return jsonb_build_object('reply', 'Lembar ' || coalesce(public.akun_tgl(v_date), 'itu') || ' belum tercatat, jadi belum bisa dikoreksi. Kirim foto lembarnya dulu.');
    end if;
    s := (s - 'uncertain') || jsonb_build_object('date', v_date::text, 'date_confident', true,
                                                 'expenses', coalesce(p->'items', '[]'::jsonb));
    v_res := public.akun_handle(p || jsonb_build_object('kind', 'sheet', 'sheet', s));
    return jsonb_set(v_res, '{reply}', to_jsonb(
      replace(replace(coalesce(v_res->>'reply', ''), '✅ Lembar ', '✏️ Koreksi belanja lembar '), ' (menggantikan kiriman sebelumnya)', '')));
  end if;

  -- ═══ LEMBAR HARIAN ═══
  if v_kind = 'sheet' then
    s := p->'sheet';
    begin v_date := coalesce((s->>'date')::date, v_today); exception when others then v_date := v_today; end;
    if coalesce((s->>'date_confident')::boolean, true) = false or s->>'date' is null then
      v_flags := v_flags || to_jsonb('tanggal lembar kurang jelas, dipakai ' || v_date::text);
    end if;
    -- tanggal tak masuk akal (salah baca tahun/hari, mis. 2024): lembar dikirim pada hari yang sama atau 1-10 hari sesudahnya.
    -- Coba tahun ini/tahun lalu dengan hari-bulan yang sama; kalau masih di luar rentang, pakai hari ini.
    if v_date > v_today + 1 or v_date < v_today - 10 then
      declare v_orig date := v_date; v_try date; v_y int;
      begin
        v_date := null;
        foreach v_y in array array[extract(year from v_today)::int, extract(year from v_today)::int - 1] loop
          begin v_try := make_date(v_y, extract(month from v_orig)::int, extract(day from v_orig)::int);
          exception when others then v_try := null; end;
          if v_try is not null and v_try <= v_today + 1 and v_try >= v_today - 10 then v_date := v_try; exit; end if;
        end loop;
        if v_date is null then v_date := v_today; end if;
        v_flags := v_flags || to_jsonb('tanggal di lembar terbaca ' || v_orig::text || ', dipakai ' || v_date::text);
      end;
    end if;
    -- kirim ulang tanggal yang sama = menggantikan
    delete from public.akun_sheets where sheet_date = v_date;
    v_replaced := found;
    insert into public.akun_sheets (sheet_date, message_id, chat_id, sender, raw)
    values (v_date, v_msg, v_chat, v_sender, s) returning id into v_sheet;

    for sh in select * from jsonb_array_elements(coalesce(s->'shifts', '[]'::jsonb)) loop
      v_shift := public.akun_int(sh->'shift');
      continue when v_shift is null or v_shift not between 1 and 3;
      insert into public.akun_shifts (sheet_id, shift, barista, ink, modal, cash_akhir, qris, discount)
      values (v_sheet, v_shift, coalesce(public.akun_staff_name(sh->>'barista'), nullif(initcap(btrim(sh->>'barista')),'')), lower(nullif(btrim(sh->>'ink'),'')),
              public.akun_int(sh->'modal'), public.akun_int(sh->'cash_akhir'),
              public.akun_int(sh->'qris'), public.akun_int(sh->'discount'))
      on conflict do nothing;
    end loop;

    for sl in select * from jsonb_array_elements(coalesce(s->'sales', '[]'::jsonb)) loop
      v_qty  := public.akun_int(sl->'qty');
      v_chan := lower(coalesce(sl->>'channel', ''));
      continue when v_qty is null or v_qty <= 0 or v_chan not in ('cash','qris','online');
      v_ink  := lower(nullif(btrim(sl->>'ink'), ''));
      v_shift := public.akun_int(sl->'shift');
      if v_shift is null and v_ink is not null then
        select sh2.shift into v_shift from public.akun_shifts sh2
         where sh2.sheet_id = v_sheet and sh2.ink = v_ink
           and (select count(*) from public.akun_shifts x where x.sheet_id = v_sheet and x.ink = v_ink) = 1;
      end if;
      v_menu := public.akun_match_menu(sl->>'item');
      select price into v_price from public.akun_menu where id = v_menu;
      if v_menu is null then
        v_price := public.akun_int(sl->'unit_price');   -- baris "Lainnya" yang menulis harga sendiri
      end if;
      insert into public.akun_sales (sheet_id, shift, menu_id, item_name, channel, qty, unit_price, ink)
      values (v_sheet, v_shift, v_menu, left(coalesce(nullif(btrim(sl->>'item'),''), '?'), 80), v_chan, v_qty, v_price, v_ink);
    end loop;

    for ex in select * from jsonb_array_elements(coalesce(s->'expenses', '[]'::jsonb)) loop
      v_amount := public.akun_int(ex->'amount');
      continue when v_amount is null or btrim(coalesce(ex->>'item','')) = '';
      -- "pinjam/ambil uang plastik (buat kembalian)" = uang pindah dari plastik ke kasir, BUKAN belanja
      if public.akun_norm(ex->>'item') ~ 'plas?tik' and public.akun_norm(ex->>'item') ~ '(pinj|ambil|kembali)' then
        v_plastik := v_plastik + v_amount;
        continue;
      end if;
      insert into public.akun_expenses (expense_date, item, amount, origin, sheet_id, message_id, chat_id, sender)
      values (v_date, left(btrim(ex->>'item'), 120), v_amount, 'lembar', v_sheet, v_msg, v_chat, v_sender);
      -- "uang plastik <barang>" = belanja dibayar dari plastik, bukan dari laci: tetap belanja, tapi kas laci tidak berkurang
      if public.akun_norm(ex->>'item') ~ 'plas?tik' then
        v_plastik := v_plastik + v_amount;
      end if;
    end loop;

    -- fee / bon karyawan (untuk potong gaji)
    select string_agg(coalesce(st.name, '?') || ' ' || case x.staff_kind when 'fee_shift' then 'fee' when 'bon' then 'bon' else 'lain' end
                      || ' ' || public.akun_rp(x.amount), ' · ' order by x.id)
      into v_stf
      from public.akun_expenses x left join public.akun_staff st on st.id = x.staff
     where x.sheet_id = v_sheet and x.staff_kind is not null and x.staff is not null;
    select string_agg(x.item || ' ' || public.akun_rp(x.amount), ', ' order by x.id)
      into v_stf_bad
      from public.akun_expenses x
     where x.sheet_id = v_sheet and x.staff_kind in ('fee_shift','bon') and x.staff is null;

    -- totals
    select coalesce(sum(qty*unit_price) filter (where channel='cash'),0),
           coalesce(sum(qty*unit_price) filter (where channel='qris'),0),
           coalesce(sum(qty*unit_price) filter (where channel='online'),0),
           string_agg(distinct item_name, ', ') filter (where unit_price is null),
           string_agg(distinct item_name, ', ') filter (where unit_price is null and channel='cash'),
           string_agg(distinct item_name, ', ') filter (where unit_price is null and channel='qris'),
           string_agg(distinct item_name, ', ') filter (where menu_id is null)
      into v_cash, v_qris, v_online, v_missing_all, v_missing_cash, v_missing_qris, v_unknown
      from public.akun_sales where sheet_id = v_sheet;
    select coalesce(sum(amount),0) into v_belanja from public.akun_expenses where sheet_id = v_sheet;
    select modal into v_modal from public.akun_shifts where sheet_id = v_sheet and modal is not null order by shift limit 1;
    select cash_akhir into v_last_cash from public.akun_shifts where sheet_id = v_sheet and cash_akhir is not null order by shift desc limit 1;
    select sum(qris), sum(discount) into v_qris_written, v_disc from public.akun_shifts where sheet_id = v_sheet;

    -- cek QRIS
    if v_qris_written is null then
      null;
    elsif v_missing_qris is not null then
      v_check := array_append(v_check, (('QRIS belum bisa dicek (harga ' || v_missing_qris || ' belum ada)'))::text);
    elsif round(v_qris) = v_qris_written then
      v_check := array_append(v_check, ('QRIS cocok ✓')::text);
    else
      v_check := array_append(v_check, (('⚠️ QRIS tertulis ' || public.akun_rp(v_qris_written) || ', hitungan dari garis di lembar ' || public.akun_rp(v_qris)))::text);
      v_flags := v_flags || to_jsonb('selisih QRIS ' || public.akun_rp(v_qris_written - v_qris));
    end if;
    -- cek Cash: modal + penjualan tunai − belanja = cash akhir shift terakhir
    if v_modal is null or v_last_cash is null then
      null;
    elsif v_missing_cash is not null then
      v_check := array_append(v_check, (('Cash belum bisa dicek (harga ' || v_missing_cash || ' belum ada)'))::text);
    else
      v_exp := v_modal + v_cash + v_plastik - v_belanja;
      if round(v_exp) = v_last_cash then
        v_check := array_append(v_check, ('Cash akhir cocok ✓')::text);
      else
        v_check := array_append(v_check, (('⚠️ Cash akhir tertulis ' || public.akun_rp(v_last_cash) || ', hitungan ' || public.akun_rp(v_exp)
                               || ' (selisih ' || public.akun_rp(abs(v_last_cash - round(v_exp))) || ')'))::text);
        v_flags := v_flags || to_jsonb('selisih cash akhir ' || public.akun_rp(v_last_cash - v_exp));
      end if;
    end if;
    if coalesce(v_disc, 0) > 0 then
      v_check := array_append(v_check, (('ada diskon ' || public.akun_rp(v_disc) || ' (tidak ikut dihitung)'))::text);
    end if;
    if v_unknown is not null then
      v_flags := v_flags || to_jsonb('menu tidak dikenal: ' || v_unknown);
    end if;

    update public.akun_sheets set
        flags = v_flags,
        cash_sales = round(v_cash), qris_sales = round(v_qris), online_sales = round(v_online),
        belanja = round(v_belanja), qris_written = v_qris_written,
        cash_expected = case when v_modal is not null and v_missing_cash is null then round(v_modal + v_cash + v_plastik - v_belanja)::int end,
        plastik_in = v_plastik,
        cash_revenue  = case when v_modal is not null and v_last_cash is not null then v_last_cash - v_modal - v_plastik + round(v_belanja)::int end,
        cash_variance = case when v_modal is not null and v_last_cash is not null and v_missing_cash is null
                             then v_last_cash - round(v_modal + v_cash + v_plastik - v_belanja)::int end
      where id = v_sheet;

    v_dupn := public.akun_dedupe(v_date);
    if v_dupn > 0 then
      v_dupnote := E'\n🔗 ' || v_dupn || ' belanja sama dengan laporan teks, dihitung sekali.';
    end if;
    -- Balasan ringkas: kesimpulan saja (pemasukan, pengeluaran, peringatan selisih). Rincian ada di dashboard.
    select coalesce(sum(amount), 0) into v_out from public.akun_expenses
     where expense_date = v_date and (origin = 'laporan' or (origin = 'lembar' and dup_of is null));
    v_reply := '✅ Lembar ' || public.akun_tgl(v_date) || ' tercatat' ||
               case when v_replaced then ' (menggantikan kiriman sebelumnya)' else '' end || E'.\n' ||
               'Pemasukan: ' || public.akun_rp(v_cash + v_qris + v_online) ||
               ' (Cash ' || public.akun_rp(v_cash) || ' · QRIS ' || public.akun_rp(v_qris) || ' · Online ' || public.akun_rp(v_online) || E')\n' ||
               'Pengeluaran: ' || public.akun_rp(v_out);
    select string_agg(c, E'\n') into v_warn from unnest(v_check) c where c like '⚠️%';
    if v_warn is not null then v_reply := v_reply || E'\n' || v_warn; end if;
    -- keraguan baca (uncertain) TIDAK ditampilkan di grup supaya balasan singkat; tetap tersimpan di akun_sheets.raw
    return jsonb_build_object('reply', v_reply, 'sheet_id', v_sheet, 'flags', v_flags);
  end if;

  -- ═══ PENGELUARAN (teks laporan, boleh bersama foto) ═══
  if v_kind = 'expense_text' then
    e := p->'expense';
    v_amount := public.akun_int(e->'amount');
    v_item := left(btrim(coalesce(e->>'item', '')), 120);
    if v_amount is null or v_item = '' then
      return jsonb_build_object('reply',
        '❓ Laporan pengeluaran belum terbaca (nama barang atau nominal kosong). Contoh:' || E'\n' ||
        'Pengeluaran : robusta' || E'\n' || 'Nominal pengeluaran : 150k');
    end if;
    begin v_edate := coalesce((e->>'date')::date, v_today); exception when others then v_edate := v_today; end;
    v_has_media := v_photo is not null and coalesce(v_photo->>'type','') in ('nota','foto_barang','bukti_bayar');
    v_total := public.akun_int(v_photo->'total');
    v_vendor := nullif(btrim(coalesce(v_photo->>'vendor','')), '');

    -- foto yang datang lebih dulu dari pengirim yang sama (≤20 menit)
    if not v_has_media then
      select * into v_pend from public.akun_pending_media
       where sender = v_sender and chat_id = v_chat and created_at > now() - interval '20 minutes'
       order by created_at desc limit 1;
      if v_pend.message_id is not null then
        v_has_media := true; v_total := v_pend.receipt_total; v_vendor := coalesce(v_vendor, v_pend.vendor);
        delete from public.akun_pending_media where message_id = v_pend.message_id;
      end if;
    end if;

    v_vendor := public.akun_match_vendor(v_vendor);
    v_pay := public.akun_pay_source(e->>'source_raw');

    -- bukti bayar yang sudah tercatat otomatis (nominal & tanggal sama) → digabung, bukan dicatat dua kali
    select id into v_id from public.akun_expenses
     where origin = 'laporan' and flags @> '["bukti bayar"]'::jsonb and amount = v_amount and expense_date = v_edate
       and chat_id = v_chat and created_at > now() - interval '2 days'
     order by id desc limit 1;
    if v_id is not null then
      update public.akun_expenses set
          item = v_item, message_id = v_msg, has_media = true, flags = flags - 'bukti bayar',
          reporter = nullif(initcap(left(btrim(coalesce(e->>'reporter','')), 40)), ''),
          source_raw = nullif(left(btrim(coalesce(e->>'source_raw','')), 40), ''), pay_source = v_pay,
          vendor = coalesce(v_vendor, vendor)
        where id = v_id;
      perform public.akun_dedupe(v_edate);
      return jsonb_build_object('reply', '✅ Pengeluaran tercatat: ' || v_item || ' ' || public.akun_rp(v_amount) ||
             coalesce(' (' || nullif(left(btrim(coalesce(e->>'source_raw','')), 40), '') || ')', '') ||
             ' · ' || public.akun_tgl(v_edate) || E'\n(digabung dengan bukti bayar yang sudah masuk)');
    end if;

    insert into public.akun_expenses (expense_date, item, amount, source_raw, reporter, origin, message_id, chat_id,
                                      sender, has_media, receipt_total, vendor, pay_source)
    values (v_edate, v_item, v_amount, nullif(left(btrim(coalesce(e->>'source_raw','')), 40), ''),
            nullif(initcap(left(btrim(coalesce(e->>'reporter','')), 40)), ''), 'laporan', v_msg, v_chat,
            v_sender, v_has_media, v_total, v_vendor, v_pay)
    on conflict (message_id) where message_id is not null and origin = 'laporan' do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then return jsonb_build_object('reply', null, 'duplicate', true); end if;
    perform public.akun_dedupe(v_edate);

    v_reply := '✅ Pengeluaran tercatat: ' || v_item || ' ' || public.akun_rp(v_amount) ||
               coalesce(' (' || nullif(left(btrim(coalesce(e->>'source_raw','')), 40), '') || ')', '') ||
               ' · ' || public.akun_tgl(v_edate) || coalesce(' · ' || v_vendor, '');
    if not v_has_media then v_reply := v_reply || E'\n📷 Belum ada foto nota/barang.'; end if;
    if v_total is not null and v_total <> v_amount then
      v_reply := v_reply || E'\n⚠️ Total di nota ' || public.akun_rp(v_total) || ', tertulis ' || public.akun_rp(v_amount) || '. Mohon dicek.';
      update public.akun_expenses set flags = flags || to_jsonb('total nota ' || public.akun_rp(v_total))
       where message_id = v_msg and origin = 'laporan';
    end if;
    return jsonb_build_object('reply', v_reply);
  end if;

  -- ═══ BUKTI BAYAR (transfer, token listrik, wifi, dll.): dicatat otomatis sebagai pengeluaran ═══
  -- p.proof = {amount, date?, item?, vendor?}. Kalau laporan teks dengan nominal & tanggal sama sudah ada, hanya dilampirkan.
  if v_kind = 'bukti_bayar' then
    e := p->'proof';
    v_amount := public.akun_int(e->'amount');
    if v_amount is null or v_amount <= 0 then return jsonb_build_object('reply', null); end if;
    begin v_edate := coalesce((e->>'date')::date, v_today); exception when others then v_edate := v_today; end;
    v_item := coalesce(nullif(left(btrim(coalesce(e->>'item', '')), 120), ''), 'Bukti bayar');
    v_vendor := public.akun_match_vendor(e->>'vendor');
    select id into v_id from public.akun_expenses
     where origin = 'laporan' and amount = v_amount and expense_date = v_edate and chat_id = v_chat
       and not has_media and not (flags @> '["bukti bayar"]'::jsonb) and created_at > now() - interval '2 days'
     order by id desc limit 1;
    if v_id is not null then
      update public.akun_expenses set has_media = true, receipt_total = v_amount, vendor = coalesce(vendor, v_vendor) where id = v_id;
      return jsonb_build_object('reply', null, 'attached', true);
    end if;
    insert into public.akun_expenses (expense_date, item, amount, origin, message_id, chat_id, sender, has_media, receipt_total, vendor, flags)
    values (v_edate, v_item, v_amount, 'laporan', v_msg, v_chat, v_sender, true, v_amount, v_vendor, '["bukti bayar"]'::jsonb)
    on conflict (message_id) where message_id is not null and origin = 'laporan' do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then return jsonb_build_object('reply', null, 'duplicate', true); end if;
    perform public.akun_dedupe(v_edate);
    return jsonb_build_object('reply', '✅ Bukti bayar tercatat: ' || v_item || ' ' || public.akun_rp(v_amount) ||
           ' · ' || public.akun_tgl(v_edate) || coalesce(' · ' || v_vendor, ''));
  end if;

  -- ═══ FOTO NOTA / BARANG SAJA ═══
  if v_kind = 'photo' then
    if coalesce(v_photo->>'type','') not in ('nota','foto_barang') then
      return jsonb_build_object('reply', null);
    end if;
    v_total := public.akun_int(v_photo->'total');
    v_vendor := public.akun_match_vendor(v_photo->>'vendor');
    -- pasangkan ke laporan teks terakhir dari pengirim yang sama (≤20 menit) yang belum punya foto
    select id, amount, item into v_id, v_amount, v_item from public.akun_expenses
     where origin = 'laporan' and sender = v_sender and chat_id = v_chat and not has_media
       and created_at > now() - interval '20 minutes'
     order by created_at desc limit 1;
    if v_id is not null then
      update public.akun_expenses set has_media = true, receipt_total = v_total, vendor = coalesce(vendor, v_vendor) where id = v_id;
      if v_total is not null and v_total <> v_amount then
        update public.akun_expenses set flags = flags || to_jsonb('total nota ' || public.akun_rp(v_total)) where id = v_id;
        return jsonb_build_object('reply',
          '⚠️ ' || v_item || ': total di nota ' || public.akun_rp(v_total) || ', tertulis ' || public.akun_rp(v_amount) || '. Mohon dicek.');
      end if;
      return jsonb_build_object('reply', null, 'attached', true);
    end if;
    insert into public.akun_pending_media (message_id, chat_id, sender, receipt_total, vendor)
    values (v_msg, v_chat, v_sender, v_total, v_vendor) on conflict do nothing;
    return jsonb_build_object('reply', null, 'pending_media', true);
  end if;

  return jsonb_build_object('reply', null);
end $$;

-- ── Grup PENGELUARAN (Meita → Balqis): pencatatan terpisah, TIDAK ikut hitungan kas/laporan kafe ──
-- Format pesan: "1 september / peralatan tentrem / 177.000 / cash" (urutan baris bebas). Bot membalas singkat setelah tercatat.
create table if not exists public.akun_pengeluaran_grup (
  id          bigint generated always as identity primary key,
  tanggal     date not null,
  item        text not null,
  amount      int  not null check (amount >= 0),
  metode      text,                        -- cash | transfer | qris | debit | NULL
  pribadi     boolean not null default false,
  reporter    text,
  message_id  text,
  chat_id     text,
  sender      text,
  raw         text,
  created_at  timestamptz not null default now()
);
create unique index if not exists akun_pgrup_msg_uidx on public.akun_pengeluaran_grup (message_id) where message_id is not null;
create index if not exists akun_pgrup_tgl_idx on public.akun_pengeluaran_grup (tanggal);
alter table public.akun_pengeluaran_grup enable row level security;
revoke all on public.akun_pengeluaran_grup from public, anon, authenticated;
grant all on public.akun_pengeluaran_grup to service_role;

-- ── Routing per grup (perubahan kecil pada dispatch_message) ────────
-- agents.config.chats = ["xxx@g.us", …] → agen HANYA menerima pesan dari chat itu, dan didahulukan
--   daripada agen tanpa batas chat. Tanpa config.chats → perilaku lama (menerima dari mana saja).
-- agents.config.redact_events = true → log "pesan masuk" tidak memuat isi pesan (anti-bocor nominal).
-- '@media' pada agen yang dibatasi chat juga menangkap foto BERCAPTION dari chat itu.
create or replace function public.agent_chat_ok(p_config jsonb, p_chat text) returns boolean
language sql immutable as $$
  select case when jsonb_typeof(p_config->'chats') = 'array' and jsonb_array_length(p_config->'chats') > 0
              then jsonb_exists(p_config->'chats', p_chat) else true end
$$;

create or replace function public.agent_chat_scoped(p_config jsonb, p_chat text) returns boolean
language sql immutable as $$
  select jsonb_typeof(p_config->'chats') = 'array' and jsonb_exists(p_config->'chats', p_chat)
$$;

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
    -- grup yang SEMUA teksnya diserahkan ke satu agen (config.all_text_chats), mis. grup pengeluaran
    select a.* into v_agent from public.agents a
     where a.enabled and jsonb_typeof(a.config->'all_text_chats') = 'array'
       and jsonb_exists(a.config->'all_text_chats', p_chat_id)
     order by a.priority desc, a.id limit 1;
    if v_agent.id is null then
    select a.* into v_agent
      from public.agents a
     where a.enabled
       and public.agent_chat_ok(a.config, p_chat_id)
       and exists (select 1 from unnest(a.triggers) t
                    where btrim(t) <> '' and left(t, 1) <> '@'
                      and position(lower(t) in lower(v_text)) > 0)
     order by public.agent_chat_scoped(a.config, p_chat_id) desc, a.priority desc, a.id
     limit 1;
    end if;
  end if;

  -- foto/video di grup → agen yang memasang pemicu '@media'.
  --   tanpa caption : agen mana pun yang boleh menerima dari chat ini (mis. IPAL menunggu teks nama dapur)
  --   dengan caption: hanya agen yang dibatasi ke chat ini (mis. Akuntan)
  if v_agent.id is null and p_is_group
     and coalesce(p_meta->>'message_type', '') in ('imageMessage', 'videoMessage') then
    select a.* into v_agent from public.agents a
     where a.enabled and '@media' = any(a.triggers)
       and public.agent_chat_ok(a.config, p_chat_id)
       and (v_text = '' or public.agent_chat_scoped(a.config, p_chat_id))
     order by public.agent_chat_scoped(a.config, p_chat_id) desc, a.priority desc, a.id limit 1;
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
  values (v_agent.id, v_task, 'task:queued',
          case when coalesce(v_agent.config->>'redact_events', '') = 'true'
               then '(isi pesan disembunyikan)' else left(v_clean, 120) end);

  return jsonb_build_object('matched', true, 'task_id', v_task, 'agent_id', v_agent.id, 'text', v_clean);
end $$;

-- ── Agen Akuntan di daftar agen (MATI sampai dibatasi ke grupnya — lihat akuntan-aktifkan.sql) ──
-- Tidak menimpa config/enabled bila baris sudah ada.
insert into public.agents (id, name, role, emoji, color, triggers, priority, enabled, desk, config)
values ('akuntan', 'Admin Berdikari', 'Admin kafe: lembar harian, belanja, fee & bon karyawan', '🧾', '#f59e0b',
        array['@media', 'laporan pengeluaran', 'nominal pengeluaran', 'koreksi'],
        8, false, '{"x":-2,"z":0}', '{"redact_events": true}')
on conflict (id) do update
  set name = excluded.name, role = excluded.role, emoji = excluded.emoji, color = excluded.color,
      triggers = excluded.triggers, priority = excluded.priority;

-- "Pisah Modal" = kelebihan kas di atas modal yang dimasukkan ke plastik (uang plastik), dibaca dari kotak kanan lembar
alter table public.akun_sheets  add column if not exists pisah_modal int generated always as (public.akun_int(raw->'pisah_modal')) stored;

-- ── Laporan harian seperti sheet "LAPORAN HARIAN" (hanya service_role; tertutup untuk dashboard) ──
-- SATU METODE (sama dengan balasan bot): pemasukan = garis di lembar × harga menu. Cash selalu garis; selisih dengan uang di laci hanya jadi peringatan.
-- qris  : pencairan bank bila sudah ada (qris_status='final'), kalau belum garis lembar ('sementara'). qris_kertas = angka tulisan barista (pembanding).
-- online: pendapatan merchant bila sudah ada ('final'), kalau belum angka garis kertas ('sementara').
-- crosscheck_qris = QRIS kertas − bank (0 = cocok). potongan_online = garis kertas (kotor) − merchant.
drop view if exists public.akun_v_harian;   -- nama kolom berubah (kolom cash lama diganti cash_garis), view tidak bisa diganti di tempat
create view public.akun_v_harian with (security_invoker = true) as
with d as (
  select sheet_date as tgl from public.akun_sheets
  union select real_date from public.akun_qris_settlements
  union select income_date from public.akun_online_income
), sh as (
  select s.id,
         (select cash_akhir from public.akun_shifts x where x.sheet_id = s.id and x.cash_akhir is not null order by x.shift desc limit 1) as cash_akhir,
         (select modal      from public.akun_shifts x where x.sheet_id = s.id and x.modal is not null      order by x.shift      limit 1) as modal,
         (select string_agg(x.barista, ', ' order by x.shift) from public.akun_shifts x where x.sheet_id = s.id and x.barista is not null) as pic
    from public.akun_sheets s
), q as (select real_date as tgl, sum(amount)::int as bank from public.akun_qris_settlements group by 1),
   o as (select income_date as tgl, sum(amount)::int as merchant from public.akun_online_income group by 1)
select d.tgl as tanggal,
       sh.cash_akhir, sh.modal, sh.pic,
       s.belanja as belanja_harian, s.cash_revenue, s.cash_sales as cash_garis, s.cash_variance,
       coalesce(q.bank, s.qris_sales)                        as qris,
       case when q.bank is not null then 'final' when s.qris_sales is not null then 'sementara' end as qris_status,
       s.qris_written                                        as qris_kertas,
       q.bank                                                as qris_bank,
       case when q.bank is not null and s.qris_written is not null then s.qris_written - q.bank end as crosscheck_qris,
       coalesce(o.merchant, s.online_sales)                  as online,
       case when o.merchant is not null then 'final' when s.online_sales is not null then 'sementara' end as online_status,
       s.online_sales                                        as online_kertas,
       o.merchant                                            as online_merchant,
       case when o.merchant is not null and s.online_sales is not null then s.online_sales - o.merchant end as potongan_online,
       s.pisah_modal
  from d
  left join public.akun_sheets s on s.sheet_date = d.tgl
  left join sh on sh.id = s.id
  left join q on q.tgl = d.tgl
  left join o on o.tgl = d.tgl
 order by d.tgl;
revoke all on public.akun_v_harian from public, anon, authenticated;
grant select on public.akun_v_harian to service_role;

-- Hari yang QRIS-nya masih dari kertas (belum ada pencairan bank): untuk ditagih saat kirim pencairan berikutnya
create or replace view public.akun_v_qris_belum_cair with (security_invoker = true) as
select s.sheet_date as tanggal, s.qris_written as qris_kertas
  from public.akun_sheets s
 where coalesce(s.qris_written, 0) > 0
   and not exists (select 1 from public.akun_qris_settlements q where q.real_date = s.sheet_date)
 order by s.sheet_date;
revoke all on public.akun_v_qris_belum_cair from public, anon, authenticated;
grant select on public.akun_v_qris_belum_cair to service_role;


-- ── Karyawan & potongan gaji (fee shift, bon) ────────────────────────
-- Daftar barista. Setiap baris belanja yang menyebut "fee ..." atau "bon/kasbon ..." ditandai otomatis (staff, staff_kind)
-- supaya agen lain bisa memotong gaji bulanan lewat view akun_v_staff / akun_v_staff_bulanan.
create table if not exists public.akun_staff (
  id       text primary key check (id ~ '^[a-z0-9_]+$'),
  name     text not null,
  aliases  text[] not null default '{}',      -- ejaan lain (huruf kecil)
  position int not null default 0,
  enabled  boolean not null default true
);
alter table public.akun_staff enable row level security;
insert into public.akun_staff (id, name, aliases, position) values
  ('zhafran', 'Zhafran', '{"zafran","jafran","zhafran"}', 1),
  ('rafi',    'Rafi',    '{"rapi","rafy","raffi","kafi","koa","kari"}', 2),   -- koa/kafi/kari = tulisan tangannya sering terbaca begitu
  ('erico',   'Erico',   '{"eriko","erico"}', 3),
  ('habib',   'Habib',   '{"abib"}', 4),
  ('farhan',  'Farhan',  '{"farhan"}', 5)
on conflict (id) do update set name = excluded.name, aliases = excluded.aliases, position = excluded.position;

alter table public.akun_expenses add column if not exists staff      text references public.akun_staff(id);
alter table public.akun_expenses add column if not exists staff_kind text;   -- fee_shift | bon | lain

-- id karyawan yang disebut di teks (kata utuh), NULL bila tidak ada
create or replace function public.akun_staff_of(p text) returns text
language sql stable as $$
  with t as (select ' ' || btrim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', ' ', 'g')) || ' ' as s)
  select st.id
    from t, public.akun_staff st
   where st.enabled
     and exists (select 1 from unnest(array[lower(st.name)] || st.aliases) a where position(' ' || lower(a) || ' ' in t.s) > 0)
   order by st.position limit 1
$$;

-- nama resmi barista dari tulisan di lembar (NULL bila tidak dikenal)
create or replace function public.akun_staff_name(p text) returns text
language sql stable as $$ select st.name from public.akun_staff st where st.id = public.akun_staff_of(p) $$;

create or replace function public.akun_tag_staff() returns trigger
language plpgsql as $$
declare
  t text := ' ' || btrim(regexp_replace(lower(coalesce(new.item, '')), '[^a-z0-9]+', ' ', 'g')) || ' ';
  v_staff text := public.akun_staff_of(new.item);
  v_kind text;
begin
  if position(' fee ' in t) > 0 then v_kind := 'fee_shift';
  elsif t ~ ' (kasbon|ngebon|utang|hutang) ' or (position(' bon ' in t) > 0 and v_staff is not null) then v_kind := 'bon';
  elsif v_staff is not null then v_kind := 'lain';
  end if;
  new.staff := v_staff;
  new.staff_kind := v_kind;
  if v_kind in ('fee_shift', 'bon') and v_staff is null
     and not (coalesce(new.flags, '[]'::jsonb) ? 'karyawan tidak dikenal') then
    new.flags := coalesce(new.flags, '[]'::jsonb) || '"karyawan tidak dikenal"'::jsonb;
  end if;
  return new;
end $$;
drop trigger if exists akun_tag_staff_trg on public.akun_expenses;
create trigger akun_tag_staff_trg before insert or update of item on public.akun_expenses
  for each row execute function public.akun_tag_staff();

-- tandai baris yang sudah ada
update public.akun_expenses set item = item;

-- Buku fee/bon per karyawan (untuk agen pemotong gaji). perlu_dicek = fee/bon tanpa nama karyawan yang dikenal.
create or replace view public.akun_v_staff with (security_invoker = true) as
select e.id as expense_id, e.expense_date as tanggal, e.staff as staff_id, st.name as nama,
       e.staff_kind as jenis, e.amount, e.item, e.origin, e.sheet_id, (e.staff is null) as perlu_dicek
  from public.akun_expenses e
  left join public.akun_staff st on st.id = e.staff
 where e.staff_kind is not null
 order by e.expense_date, e.id;
revoke all on public.akun_v_staff from public, anon, authenticated;
grant select on public.akun_v_staff to service_role;

create or replace view public.akun_v_staff_bulanan with (security_invoker = true) as
select date_trunc('month', tanggal)::date as bulan, staff_id, nama,
       coalesce(sum(amount) filter (where jenis = 'fee_shift'), 0)::int as fee_shift,
       coalesce(sum(amount) filter (where jenis = 'bon'), 0)::int       as bon,
       coalesce(sum(amount) filter (where jenis = 'lain'), 0)::int      as lain,
       sum(amount)::int as total
  from public.akun_v_staff
 where staff_id is not null
 group by 1, 2, 3
 order by 1, 3;
revoke all on public.akun_v_staff_bulanan from public, anon, authenticated;
grant select on public.akun_v_staff_bulanan to service_role;

-- ── Hak akses: hanya service_role (n8n) ─────────────────────────────
grant all on public.akun_menu, public.akun_sheets, public.akun_shifts, public.akun_sales,
             public.akun_expenses, public.akun_pengeluaran_grup, public.akun_pending_media,
             public.akun_vendors, public.akun_category_map, public.akun_qris_settlements,
             public.akun_online_income, public.akun_bank_tx, public.akun_staff to service_role;
grant usage, select on all sequences in schema public to service_role;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('akun_dedupe','akun_amt_in','akun_handle','akun_day_summary','dispatch_message','akun_pay_source','akun_match_vendor',
                       'agent_chat_ok','agent_chat_scoped','akun_staff_of','akun_staff_name','akun_tag_staff')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;

-- isi ulang pasangan dobel untuk semua tanggal yang punya lembar dan laporan
select public.akun_dedupe(d) from (select distinct expense_date d from public.akun_expenses where origin = 'lembar') q;
