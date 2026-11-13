// Susun balasan dari hasil akun_handle. Diam kalau tidak ada yang perlu dikabarkan.
const p = $('Webhook agen').first().json.body;
const o = $('Olah hasil').first().json;
const r = $input.first().json || {};
// Kegagalan sistem (foto tak terbaca, API error) TIDAK pernah dikabarkan ke grup: sistem yang mencoba ulang sendiri, lalu mencatat di dashboard.
let reply = o.failed ? '' : (o.local_reply || r.reply || '');
if (reply && o.uncertain && o.uncertain.length) reply += '\n❓ Mohon dicek:\n' + o.uncertain.map(x => '• ' + x).join('\n');
// Langkah berpikir: bila lembar tercatat dengan selisih/peringatan, minta AI menalar penyebabnya (hanya saran, tidak mengubah data).
let analisis_body = null;
const sv = $('Siapkan').first().json;
if (reply && o.kind === 'sheet' && /⚠️/.test(reply) && sv.vision_provider === 'gemini') {
  const sheet = (o.p && o.p.sheet) ? o.p.sheet : {};
  const prompt = [
    'Kamu admin keuangan kafe Berdikari Koffee yang teliti dan berpikir jernih. Lembar harian baru dicatat dan sistem menemukan selisih. Pikirkan langkah demi langkah dalam hati, lalu tulis hasilnya.',
    'Tulis maksimal 4 poin pendek berbahasa Indonesia sederhana (awali tiap poin dengan "• "): penyebab paling masuk akal tiap selisih, dan apa yang perlu dicek pengurus. Jangan mengarang angka; pakai hanya angka dari data. Jangan mengulang seluruh balasan. Kalau tidak ada yang mencurigakan, tulis satu poin: "Tidak ada yang janggal."',
    'ATURAN KAFE:',
    '- Cara menulis garis: 1 blok = 4 garis tegak + 1 coretan miring/mendatar = 5. Itu normal.',
    '- Cash yang seharusnya ada di laci = modal + penjualan cash + uang plastik yang dipindah ke laci - belanja yang diambil dari laci. Fee karyawan dan belanja yang diambil dari laci mengurangi kas.',
    '- "Uang plastik" = sisa pisah modal di kantong plastik; "pinjam uang plastik" untuk kembalian BUKAN belanja.',
    '- QRIS tertulis = angka yang ditulis barista; hitungan garis = dari garis di kolom QRIS. Selisih biasanya karena garis terlewat/terhitung salah atau QRIS ditulis kotor vs bersih.',
    '- Belanja yang lupa ditulis di lembar membuat cash akhir lebih kecil dari hitungan. Cash akhir lebih besar dari hitungan biasanya berarti ada penjualan cash yang tidak digaris atau modal salah tulis.',
    '',
    'BALASAN SISTEM:', reply, '',
    'DATA LEMBAR (hasil baca):', JSON.stringify({ shifts: sheet.shifts, expenses: sheet.expenses, pisah_modal: sheet.pisah_modal, uncertain: sheet.uncertain }).slice(0, 3000)
  ].join('\n');
  analisis_body = { contents: [{ role: 'user', parts: [{ text: prompt }] }], generationConfig: { temperature: 0.2, maxOutputTokens: 2048 } };
}
return [{ json: { chat_id: p.chat_id, task_id: p.task_id, reply, kind: o.kind, failed: !!o.failed, error: o.error || null, analisis_body, analisis_model: ($env.AKUNTAN_GEMINI_MODEL || 'gemini-3.8-flash') } }];

