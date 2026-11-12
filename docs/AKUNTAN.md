> Nama tampilan agen: **Admin Berdikari**. ID teknisnya tetap `akuntan` (perintah `/akuntan`, workflow `agent:akuntan`).

# Agen Akuntan — Berdikari Koffee

Mencatat **pemasukan** (foto lembar harian) dan **pengeluaran** (teks "LAPORAN PENGELUARAN BERDIKARI KOFFEE" + foto nota) dari grup WhatsApp **BERDIKARI - LAPORAN HARIAN**. Tanpa kategori, tanpa rekap otomatis, WhatsApp saja.

## Cara kerja
- Foto lembar harian → dibaca model Claude → garis per menu × harga → dicek: QRIS tertulis vs hitungan, dan **cash akhir shift 2 = modal + penjualan tunai − belanja** (shift 2 melanjutkan cash akhir shift 1). Yang tidak cocok ditandai di balasan.
- Teks laporan pengeluaran + foto nota/barang dari pengirim yang sama (≤20 menit, urutan bebas) digabung jadi satu catatan.
- **Bukti bayar** (foto struk token listrik, transfer, wifi, dll.) tanpa teks laporan dicatat otomatis sebagai pengeluaran (tanggal dari bukti, tanpa kategori). Kalau laporan teks dengan nominal & tanggal sama masuk sebelum/sesudahnya, keduanya digabung, tidak dobel.
- Foto tidak terbaca → bot minta kirim ulang atau ketik manual.
- `/akuntan rekap`, `/akuntan rekap kemarin`, `/akuntan rekap 9 nov` → ringkasan satu hari (manual).
- Foto TIDAK disimpan di server (aslinya tetap di WhatsApp; `message_id` dicatat). Nominal tidak masuk log dashboard (`redact_events`).

## Arti istilah
- **Uang plastik** = uang "Pisah Modal" (kotak kanan di lembar, mis. 200k): kelebihan kas di atas modal ±90–110 ribu, dimasukkan ke plastik dan disimpan di kasir sampai diambil PIC. Pengeluaran bertuliskan "uang plastik" diambil dari simpanan ini, bukan dari laci (`pay_source = plastik`).
- **Uang berdi** = Cash Berdi (uang di luar plastik, kas laci).
- **Pisah Modal** dibaca dari tiap lembar ke kolom `pisah_modal` (tampil di view `akun_v_harian`). Pengambilan oleh PIC tidak dicatat.
- **Rokok Eceran** Rp2.500 per batang.

## Pasang (urut)
1. Deploy zip: `bash ~/Downloads/deploy.sh`
2. Isi `ANTHROPIC_API_KEY` di `.env` server (ketik sendiri di server, jangan ke chat), lalu `docker compose up -d n8n`.
3. Supabase → SQL Editor → jalankan `supabase/akuntan.sql`.
4. Cari JID grup: `bash scripts/cari-grup-wa.sh "BERDIKARI"`.
5. Buka `supabase/akuntan-aktifkan.sql`, ganti `GANTI_JID_GRUP_BERDIKARI` dengan JID tadi, jalankan di SQL Editor (ini juga mengunci IPAL ke grup IPAL dan menyalakan Akuntan).
6. Di `.env`: `WA_ALLOWED_CHATS` harus berisi JID IPAL **dan** JID Berdikari (pisah koma), lalu `docker compose up -d n8n`.
7. (Opsional) Impor riwayat Des 2025–Okt 2026 dari buku Balqis: jalankan file terpisah `riwayat-import.sql` di SQL Editor (pencairan QRIS BNI, Shopee/GoFood/Grab, mutasi bank), lalu hapus file-nya.
8. Uji dengan foto asli di grup. Semua harga menu sudah terisi dari lembar harga (Extra Shot Rp5.000, Air Mineral/Es Teh Rp3.000).

## Kecocokan dengan buku Balqis
| Di buku | Di Supabase |
|---|---|
| Penjualan Cash/hari = cash akhir − modal + belanja harian | `akun_sheets.cash_revenue` (selisih dengan hitungan garis tunai = `cash_variance`, setara "petty cash harian") |
| QRIS/hari: kertas dulu (sementara), diganti pencairan BNI saat dikirim berkala (tanggal real = hari sebelum tanggal masuk) | `akun_qris_settlements`; view `akun_v_harian` (`qris_status`), `akun_v_qris_belum_cair` |
| Online/hari: angka merchant (nyata) dipakai; kertas tetap dicatat → potongan = kertas − merchant | `akun_online_income`; `akun_sheets.online_sales`; view `potongan_online` |
| Event, catering, bulk order, belanja lewat bank | `akun_bank_tx` |
| Sheet HPP (harga jual, HPP, grup menu) | `akun_menu.price / hpp / menu_group` |
| Keterangan "Belanja @ toko", Detail, Sumber Payment, PIC | `akun_expenses.vendor / item / pay_source / reporter` (toko dibaca dari nota) |
| Sheet List (sub-kategori → baris laba-rugi) | `akun_category_map` (kategori belum dipakai; pengeluaran masih dicatat tanpa kategori) |
| Sheet LAPORAN HARIAN (+ kolom Crosscheck) | view `akun_v_harian` (`crosscheck_qris` = QRIS tertulis − pencairan bank) |

Tabel dan view ini tertutup untuk dashboard; hanya n8n (service_role) yang bisa membaca.

## Kirim pencairan QRIS & pendapatan merchant (grup "Akuntan Berdikari")

> Opsional & tidak dipakai saat ini: pencairan QRIS dan data merchant masuk lewat spreadsheet (nanti ditangani agen akuntan). Biarkan `AKUNTAN_ADMIN_CHATS` kosong; jalur ini otomatis diam.
Buat grup WhatsApp khusus pengurus (kamu + bot, boleh ditambah akuntan), terpisah dari grup staf. Cari ID-nya dengan `bash scripts/cari-grup-wa.sh "Akuntan"`, isi di `.env`: `AKUNTAN_ADMIN_CHATS=<id grup>`. ID itu juga harus ada di `WA_ALLOWED_CHATS`. Lalu `docker compose up -d n8n`. Dari chat lain (termasuk grup staf) data ini ditolak/diabaikan; kosong = ditolak semua.

- **Pencairan QRIS**: kirim tangkapan layar mutasi bank dengan caption `/akuntan qris`, atau ketik `/akuntan qris` lalu baris `11/11 203.000` (tanggal = tanggal uang masuk di bank; tanggal real QRIS otomatis sehari sebelumnya).
- **Pendapatan merchant**: tangkapan layar aplikasi dengan caption `/akuntan online`, atau ketik `/akuntan online` lalu baris `10/11 shopee 97.917`.
- Satu foto per pesan. Bot membalas: jumlah baris tercatat, cocok/selisih dengan kertas (QRIS), potongan (online), dan bagian yang ragu dibaca.


## Koreksi belanja lewat teks

Kalau bot salah baca daftar belanja di lembar, ketik di grup (satu pesan):

`koreksi 12/11: es 12k, fee Rafi 50k, telur tisu 20.5k, nasi 5k, fee Erico 50k, pinjam uang plastik 10k`

- Seluruh daftar belanja lembar tanggal itu **diganti** dengan daftar di pesan, lalu cash dan selisih dihitung ulang.
- Tanggal boleh dihilangkan (`koreksi: es 12k, ...`): dipakai lembar terakhir.
- Baris "pinjam / ambil uang plastik" (kembalian kasir) bukan belanja. Dicatat sebagai uang plastik yang masuk kasir
  (kolom `akun_sheets.plastik_in`) dan ikut dihitung di cash akhir.

## Barang eceran

Rokok Eceran, Rokok Signature, dan Air Mineral/Es Teh punya kategori `eceran`: tidak ikut "Menu terlaris",
tampil di kartu **Barang eceran** di halaman laporan.


## Karyawan, fee, dan bon (untuk potong gaji)

Daftar barista ada di tabel `akun_staff` (Zhafran, Rafi, Erico, Habib, Farhan; ejaan lain di kolom `aliases`).
Setiap baris belanja yang menulis `fee <nama>` atau `bon/kasbon <nama>` ditandai otomatis
(`akun_expenses.staff`, `staff_kind` = `fee_shift` | `bon` | `lain`), dari lembar maupun laporan teks.

Untuk agen pemotong gaji (hanya `service_role`):
- `akun_v_staff`: satu baris per catatan (tanggal, nama, jenis, nominal, item). `perlu_dicek = true` bila fee/bon tanpa nama yang dikenal.
- `akun_v_staff_bulanan`: total per bulan per karyawan (`fee_shift`, `bon`, `lain`, `total`).

Fee dan bon tetap ikut hitungan belanja lembar (uangnya memang keluar dari kasir). Agen gaji cukup membaca view di atas;
jangan menjumlah ulang dari belanja. Nama baru: tambah baris di `akun_staff`.
