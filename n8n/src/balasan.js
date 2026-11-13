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
    'Kamu admin keuangan kafe Berdikari yang teliti. Lembar harian baru dicatat dan ada selisih. Pikirkan dalam hati, lalu tulis SATU kalimat pendek (maksimal 140 karakter, bahasa Indonesia sederhana, tanpa tanda "•", tanpa daftar): dugaan penyebab selisih yang paling masuk akal. Jangan mengarang angka, jangan menyebut tulisan/karakter aneh, jangan mengulang balasan. Kalau tidak ada dugaan yang masuk akal, tulis persis: -',
    'ATURAN KAFE: 1 blok garis = 4 tegak + 1 coretan = 5. Cash yang seharusnya ada = modal + penjualan cash + uang plastik masuk laci - belanja dari laci (fee karyawan ikut mengurangi). Belanja yang lupa ditulis membuat cash akhir lebih kecil dari hitungan. Cash akhir lebih besar biasanya penjualan cash tidak digaris. Selisih QRIS biasanya garis terlewat atau QRIS ditulis kotor vs bersih.',
    '',
    'BALASAN SISTEM:', reply, '',
    'DATA LEMBAR:', JSON.stringify({ shifts: sheet.shifts, expenses: sheet.expenses, pisah_modal: sheet.pisah_modal }).slice(0, 2500)
  ].join('\n');
  analisis_body = { contents: [{ role: 'user', parts: [{ text: prompt }] }], generationConfig: { temperature: 0.2, maxOutputTokens: 1024 } };
}
return [{ json: { chat_id: p.chat_id, task_id: p.task_id, reply, kind: o.kind, failed: !!o.failed, error: o.error || null, analisis_body, analisis_model: ($env.AKUNTAN_GEMINI_MODEL || 'gemini-3.8-flash') } }];

