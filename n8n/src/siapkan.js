// Menyiapkan pesan: laporan pengeluaran (teks), perintah rekap, atau foto yang perlu dibaca model penglihat.
const p = $('Webhook agen').first().json.body;
const text = String(p.text || '').trim();          // sudah tanpa "/akuntan"
const raw = String(p.raw_text || '').trim();
const media = (!!p.mimetype && /^image\//.test(p.mimetype)) || p.message_type === 'imageMessage';

const MON = { jan: 1, feb: 2, mar: 3, apr: 4, mei: 5, jun: 6, jul: 7, agu: 8, agt: 8, ags: 8, sep: 9, okt: 10, nov: 11, des: 12 };
function wibToday() {
  const s = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  return s; // YYYY-MM-DD
}
function iso(y, m, d) {
  if (!(m >= 1 && m <= 12 && d >= 1 && d <= 31)) return null;
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (dt.getUTCMonth() !== m - 1) return null;
  return dt.toISOString().slice(0, 10);
}
function parseDate(str) {
  if (!str) return null;
  const s = String(str).toLowerCase();
  const m = s.match(/(\d{1,2})\s*[\/\-\.\s]\s*([a-z]{3,9}|\d{1,2})(?:\s*[\/\-\.\s]\s*(\d{2,4}))?/);
  if (!m) return null;
  const d = parseInt(m[1], 10);
  let mo = /^\d+$/.test(m[2]) ? parseInt(m[2], 10) : MON[m[2].slice(0, 3)];
  if (!mo) return null;
  const today = wibToday();
  let y = m[3] ? parseInt(m[3], 10) : parseInt(today.slice(0, 4), 10);
  if (y < 100) y += 2000;
  let out = iso(y, mo, d);
  // tanpa tahun dan hasilnya lebih dari 2 hari ke depan → pasti tahun lalu ("28 des" ditulis di Januari)
  if (out && !m[3] && out > new Date(Date.parse(today) + 2 * 86400000).toISOString().slice(0, 10)) out = iso(y - 1, mo, d);
  return out;
}
function parseAmount(str) {
  if (str === null || str === undefined) return null;
  const s = String(str).toLowerCase().replace(/rp\.?/g, '').trim();
  const m = s.match(/(\d+(?:[.,]\d+)*)\s*(jt|juta|k|rb|ribu)?/);
  if (!m) return null;
  const unit = m[2] || '';
  if (unit) {
    const v = parseFloat(m[1].replace(/\.(?=\d{3}(\D|$))/g, '').replace(',', '.'));
    if (!isFinite(v)) return null;
    return Math.round(v * (/^(jt|juta)$/.test(unit) ? 1e6 : 1e3));
  }
  const digits = m[1].replace(/[.,](?=\d{3}(\D|$))/g, '').replace(/[.,]/g, '');
  const n = parseInt(digits, 10);
  return n >= 1000 ? n : null;                      // angka kecil tanpa satuan: terlalu ambigu, minta ditulis ulang
}
function parseExpense(t) {
  if (!/laporan\s+pengeluaran|nominal\s+pengeluaran/i.test(t)) return null;
  const e = { reporter: '', date: null, item: '', amount: null, source_raw: '' };
  const rest = [];
  for (const line of t.split(/\r?\n/)) {
    const l = line.trim();
    if (!l) continue;
    if (/laporan\s+pengeluaran/i.test(l) && !/[:：]/.test(l)) continue;     // judul
    const m = l.match(/^([^:：]{2,40}?)\s*[:：]\s*(.*)$/);
    if (!m) { rest.push(l); continue; }
    const k = m[1].toLowerCase().replace(/\s+/g, ' ').trim();
    const v = m[2].trim();
    if (k === 'nama') e.reporter = v;
    else if (k.startsWith('nominal')) e.amount = parseAmount(v);
    else if (k.startsWith('hari') || k === 'tanggal') e.date = parseDate(v);
    else if (k === 'pengeluaran' || k === 'barang' || k === 'keterangan') e.item = v;
    else rest.push(l);
  }
  e.source_raw = (rest.join(' ') || '').replace(/\bplatik\b/gi, 'plastik').toLowerCase().slice(0, 40);
  return e;
}

// "koreksi 12/11: es 12k, fee Rafi 50k, telur tisu 20.5k" → mengganti seluruh daftar belanja lembar tanggal itu
function parseKoreksi(t) {
  const m = String(t).match(/^\s*(?:koreksi|revisi)\b\s*(?:belanja|lembar)?\s*([\s\S]*)$/i);
  if (!m) return null;
  let rest = m[1];
  let date = null;
  const colon = rest.search(/[:：\n]/);
  const head = colon >= 0 ? rest.slice(0, colon) : '';
  if (head && /\d/.test(head)) { date = parseDate(head); rest = rest.slice(colon + 1); }
  else if (colon >= 0 && !/\d/.test(head)) { rest = rest.slice(colon + 1); }
  const items = [];
  for (const part of rest.split(/(?<!\d),|,(?!\d)|;|\n/)) {
    const l = part.trim();
    if (!l) continue;
    const mm = l.match(/^(.*?)[\s:=\-]*(?:rp\.?\s*)?(\d[\d.,]*\s*(?:jt|juta|k|rb|ribu)?)\s*$/i);
    if (!mm) continue;
    const item = mm[1].replace(/[\s:=\-]+$/, '').trim();
    const amount = parseAmount(mm[2]);
    if (item && amount) items.push({ item: item.slice(0, 120), amount });
  }
  return { date, items };
}

const MERCH = [['shopee', /shopee/i], ['gofood', /go\s*-?food|gojek/i], ['grab', /grab/i]];
function merchantOf(t) { for (const [k, re] of MERCH) if (re.test(t)) return k; return null; }
const DATE_RE = /\d{4}-\d{2}-\d{2}|\d{1,2}\s*[\/\-.]\s*\d{1,2}(?:\s*[\/\-.]\s*\d{2,4})?|\d{1,2}\s+(?:jan|feb|mar|apr|mei|jun|jul|agu|agt|ags|sep|okt|nov|des)[a-z]*(?:\s+\d{4})?/i;
// Baris tempelan: "<tanggal> [merchant] <nominal>" → {date, merchant, amount}
function parseLines(t, defMerchant) {
  const rows = [];
  for (const line of String(t).split(/\r?\n/)) {
    const l = line.trim();
    const dm = l.match(DATE_RE);
    if (!dm) continue;
    const d = /^\d{4}-/.test(dm[0]) ? dm[0] : parseDate(dm[0]);
    if (!d) continue;
    const nums = l.replace(dm[0], ' ').match(/\d{1,3}(?:[.,]\d{3})+|\d{4,}/g);
    if (!nums) continue;
    const amount = parseAmount(nums[nums.length - 1]);
    if (!amount) continue;
    rows.push({ date: d, merchant: merchantOf(l) || defMerchant || 'lain', amount });
  }
  return rows;
}

const out = { message_id: p.message_id, chat_id: p.chat_id, sender: p.sender, task_id: p.task_id,
              media, need_vision: false, expense: null, rekap: false, rekap_date: null, vision_error: null };

out.mode = null; out.text_rows = []; out.local_reply = null;
out.koreksi = media ? null : parseKoreksi(raw || text);
if (out.koreksi && out.koreksi.items.length === 0) {
  out.local_reply = 'Format koreksi belanja: koreksi 12/11: es 12k, fee Rafi 50k, telur tisu 20.5k, nasi 5k';
}
const modeM = text.match(/^(qris|online)\b\s*([\s\S]*)$/i);
out.expense = (modeM || out.koreksi) ? null : parseExpense(raw || text);
if (modeM) {
  out.mode = modeM[1].toLowerCase();
  const admins = String($env.AKUNTAN_ADMIN_CHATS || '').split(',').map(x => x.trim()).filter(Boolean);
  if (admins.length === 0 || !admins.includes(p.chat_id)) {   // jalur QRIS/online lewat chat dimatikan bila AKUNTAN_ADMIN_CHATS kosong (data masuk lewat spreadsheet)
    out.local_reply = null; out.mode = 'ditolak';          // diam: bukan chat pengurus (mis. grup staf)
  }
  if (out.mode === 'qris' || out.mode === 'online') {
    const rest = modeM[2] || '';
    const defM = out.mode === 'online' ? merchantOf(rest.split(/\r?\n/)[0]) : null;
    const tr = parseLines(rest, defM);
    out.text_rows = out.mode === 'qris' ? tr.map(r => ({ settle_date: r.date, amount: r.amount })) : tr;
  }
}
if (out.local_reply || out.mode === 'ditolak') { out.media = false; }
if (!out.expense && !out.mode && /^rekap\b/i.test(text)) {
  out.rekap = true;
  const rest = text.replace(/^rekap\s*/i, '').trim().toLowerCase();
  if (/^kemarin/.test(rest)) out.rekap_date = new Date(Date.parse(wibToday()) - 86400000).toISOString().slice(0, 10);
  else out.rekap_date = parseDate(rest);
}

if (media && out.mode === 'ditolak') {
  // diam
} else if (media && out.local_reply) {
  // ditolak dengan balasan
} else if (media) {
  const b64 = String(p.media_base64 || '').replace(/^data:[^;]+;base64,/, '');
  if (!b64) {
    out.vision_error = 'foto tidak ikut terkirim ke n8n (media_base64 kosong)';
  } else {
    const allowed = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];
    const mt = allowed.includes(p.mimetype) ? p.mimetype : 'image/jpeg';
    const prompt = out.mode === 'qris' ? [
      'Ini tangkapan layar mutasi rekening bank atau daftar pencairan QRIS kafe. Ambil HANYA baris uang masuk dari pencairan QRIS/merchant (abaikan transfer lain). Balas HANYA satu objek JSON valid (tanpa teks lain, tanpa tanda kutip kode):',
      '{"type":"settlement","rows":[{"settle_date":"YYYY-MM-DD tanggal uang masuk di bank","real_date":"YYYY-MM-DD tanggal transaksi QRIS bila tertulis, kalau tidak ada null","amount":angka rupiah penuh}],"uncertain":["catatan singkat untuk angka atau tanggal yang kamu ragu"]}',
      'Rupiah penuh tanpa titik. Tahun kalau tidak tertulis: ' + wibToday().slice(0, 4) + '. Jangan menebak; ragu = tulis di "uncertain".'
    ].join('\n') : out.mode === 'online' ? [
      'Ini tangkapan layar pendapatan dari aplikasi merchant (ShopeeFood, GoFood, atau GrabFood). Ambil pendapatan per hari. Pakai angka yang benar-benar diterima merchant (bersih setelah komisi) bila ada beberapa angka. Balas HANYA satu objek JSON valid (tanpa teks lain, tanpa tanda kutip kode):',
      '{"type":"online_income","rows":[{"date":"YYYY-MM-DD","merchant":"shopee|gofood|grab","amount":angka rupiah penuh}],"uncertain":["catatan singkat untuk angka, tanggal, atau jenis angka (kotor/bersih) yang kamu ragu"]}',
      'Rupiah penuh tanpa titik. Tahun kalau tidak tertulis: ' + wibToday().slice(0, 4) + '. Jangan menebak; ragu = tulis di "uncertain".'
    ].join('\n') : [
      'Kamu membantu mencatat laporan kafe Berdikari Koffee dari foto di grup WhatsApp. Lihat foto, tentukan jenisnya, lalu balas HANYA dengan satu objek JSON valid (tanpa teks lain, tanpa tanda kutip kode).',
      '',
      'Jenis foto ("type"):',
      '- "lembar_harian": lembar rekap harian kafe. Ciri: tabel Shift 1 / Shift 2 (nama barista, Uang Modal, Cash Akhir, QRIS, Total Discount), daftar menu dengan garis tally di kolom Cash / QRIS / Online, dan kotak "Pengeluaran belanja".',
      '- "nota": nota atau struk belanja.',
      '- "bukti_bayar": bukti pembayaran atau transfer (struk token listrik, tagihan wifi/gas, bukti transfer bank atau e-wallet, tangkapan layar pembayaran).',
      '- "foto_barang": foto barang atau bahan yang dibeli.',
      '- "lain": selain itu.',
      '',
      'Kalau "nota": {"type":"nota","total":<total nota dalam rupiah penuh, atau null>,"vendor":"<nama toko persis seperti di kop nota, atau null>"}',
      'Kalau "bukti_bayar": {"type":"bukti_bayar","total":<jumlah yang dibayar dalam rupiah penuh>,"date":"YYYY-MM-DD tanggal transaksi atau null","item":"apa yang dibayar, singkat (mis. Token listrik)","vendor":"penerima atau penyedia (mis. PLN) atau null"}',
      'Kalau "foto_barang" atau "lain": {"type":"..."}',
      '',
      'Kalau "lembar_harian", isi persis bentuk ini:',
      '{"type":"lembar_harian","date":"YYYY-MM-DD atau null","date_confident":true,',
      ' "shifts":[{"shift":1,"barista":"nama","ink":"blue|red|black|green|other","modal":angka|null,"cash_akhir":angka|null,"qris":angka|null,"discount":angka|null}],',
      ' "sales":[{"item":"nama menu persis seperti tercetak","channel":"cash|qris|online","qty":angka,"ink":"warna garis"}],',
      ' "pisah_modal":angka|null,',
      ' "expenses":[{"item":"...","amount":angka}],',
      ' "uncertain":["catatan singkat untuk setiap angka atau tulisan yang kamu ragu"]}',
      '',
      'Aturan lembar_harian:',
      '- Semua uang dalam rupiah penuh tanpa titik (120.000 jadi 120000; "58k" jadi 58000). "date" dari kolom Hari, Tanggal.',
      '- Nama barista (kolom "Nama Barista") hampir pasti salah satu dari: Zhafran, Rafi, Erico, Habib, Farhan. Tulisan tangan sering kurang jelas: pilih nama yang paling mirip dari daftar itu. Nama di luar daftar baru ditulis apa adanya bila jelas berbeda.',
      '- Tiap shift biasanya ditulis dengan warna tinta berbeda. Isi "ink" pada shifts dengan warna tulisan shift itu, dan "ink" pada tiap baris sales dengan warna garis tally itu. Kalau semuanya satu warna, isi apa adanya.',
      '- sales: satu elemen per menu per kolom (cash/qris/online) per warna tinta. Satu garis tegak = 1; empat garis dengan coretan miring = 5. Garis yang dicoret atau dihapus TIDAK dihitung. Menu tanpa tanda jangan dimasukkan.',
      '- Baris "Rokok Eceran" dan item tulisan tangan di bagian "LAINNYA" juga masuk sales; untuk item LAINNYA sertakan "unit_price" bila harganya tertulis.',
      '- Baris "Rokok Signature" berbeda: angka yang ditulis di kolomnya adalah RUPIAH (mis. 17.500), bukan jumlah batang. Isi "qty" dengan angka rupiah itu (17500).',
      '- pisah_modal: angka di kotak "Pisah Modal" (kanan atas, mis. 200k jadi 200000). Null bila kosong.',
      '- expenses: setiap barang di kotak "Pengeluaran belanja" beserta nominalnya ("12k" jadi 12000).',
      '- Jangan menebak. Kalau tulisan angka kurang jelas, isi nilai terbaikmu dan tulis keraguannya di "uncertain" (contoh: "cash akhir shift 2 terbaca 58400, mungkin 98000"). Kalau benar-benar tidak terbaca, isi null.'
    ].join('\n');
    out.need_vision = true;
    if (($env.AKUNTAN_VISION || 'anthropic') === 'gemini') {
      out.vision_provider = 'gemini';
      out.vision_body = {
        contents: [{ role: 'user', parts: [
          { inline_data: { mime_type: mt, data: b64 } },
          { text: prompt }
        ] }],
        generationConfig: { temperature: 0, maxOutputTokens: 4096, responseMimeType: 'application/json' }
      };
    } else {
      out.vision_provider = 'anthropic';
      out.vision_body = {
        model: $env.AKUNTAN_MODEL || 'claude-sonnet-5-5',
        max_tokens: 4096,
        messages: [{ role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: mt, data: b64 } },
          { type: 'text', text: prompt }
        ] }]
      };
    }
  }
}
return [{ json: out }];
