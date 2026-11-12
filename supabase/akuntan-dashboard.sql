-- Data untuk halaman "Laporan Keuangan" di dashboard (jalankan SETELAH akuntan.sql; aman diulang).
-- Hanya service_role (n8n) yang boleh memanggil; dashboard TIDAK membaca tabel akun_* langsung.
create or replace function public.akun_dashboard(p_from date, p_to date) returns jsonb
language sql stable as $$
with h as (
  select * from public.akun_v_harian where tanggal between p_from and p_to
), ex as (
  select expense_date, sum(amount)::int as jml
    from public.akun_expenses where origin = 'laporan' and expense_date between p_from and p_to group by 1
), days as (
  select tanggal as tgl from h union select expense_date from ex
), harian as (
  select d.tgl,
         coalesce(h.cash_revenue, 0)  as cash,
         coalesce(h.qris, 0)          as qris,
         coalesce(h.online, 0)        as online,
         coalesce(h.belanja_harian, 0) as belanja_lembar,
         coalesce(ex.jml, 0)          as laporan,
         h.pisah_modal, h.qris_status, h.online_status
    from days d left join h on h.tanggal = d.tgl left join ex on ex.expense_date = d.tgl
)
select jsonb_build_object(
  'from', p_from, 'to', p_to,
  'harian', coalesce((select jsonb_agg(jsonb_build_object(
      'tanggal', tgl, 'cash', cash, 'qris', qris, 'online', online, 'pemasukan', cash + qris + online,
      'belanja_lembar', belanja_lembar, 'laporan', laporan, 'pengeluaran', belanja_lembar + laporan,
      'pisah_modal', pisah_modal, 'qris_status', qris_status, 'online_status', online_status) order by tgl) from harian), '[]'::jsonb),
  'total', (select jsonb_build_object(
      'cash', coalesce(sum(cash),0), 'qris', coalesce(sum(qris),0), 'online', coalesce(sum(online),0),
      'pemasukan', coalesce(sum(cash + qris + online),0),
      'belanja_lembar', coalesce(sum(belanja_lembar),0), 'laporan', coalesce(sum(laporan),0),
      'pengeluaran', coalesce(sum(belanja_lembar + laporan),0),
      'hari', count(*) filter (where cash + qris + online > 0)) from harian),
  'menu', coalesce((select jsonb_agg(m order by (m->>'qty')::int desc) from (
      select jsonb_build_object('nama', coalesce(mm.name, s.item_name), 'qty', sum(s.qty)::int,
                                'omzet', sum(s.qty * coalesce(s.unit_price, 0))::int) as m
        from public.akun_sales s
        join public.akun_sheets sh on sh.id = s.sheet_id
        left join public.akun_menu mm on mm.id = s.menu_id
       where sh.sheet_date between p_from and p_to and coalesce(s.menu_id, '') <> 'rokok_signature'
       group by coalesce(mm.name, s.item_name)
       order by sum(s.qty) desc limit 10) q), '[]'::jsonb),
  'toko', coalesce((select jsonb_agg(t order by (t->>'total')::int desc) from (
      select jsonb_build_object('nama', coalesce(vendor, '(tanpa nama toko)'), 'total', sum(amount)::int) as t
        from public.akun_expenses
       where origin = 'laporan' and expense_date between p_from and p_to
       group by coalesce(vendor, '(tanpa nama toko)') order by sum(amount) desc limit 8) q), '[]'::jsonb),
  'perhatian', jsonb_build_object(
      'tanpa_foto', (select count(*) from public.akun_expenses where origin = 'laporan' and not has_media and expense_date between p_from and p_to),
      'qris_belum_cair', (select count(*) from public.akun_v_qris_belum_cair where tanggal between p_from and p_to),
      'potongan_online', coalesce((select sum(potongan_online) from h), 0),
      'pisah_modal', coalesce((select sum(pisah_modal) from h), 0))
)
$$;
revoke all on function public.akun_dashboard(date, date) from public, anon, authenticated;
grant execute on function public.akun_dashboard(date, date) to service_role;
