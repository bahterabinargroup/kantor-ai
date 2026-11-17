// Ambil pesan dari payload agen dan bentuk parameter untuk dm_record; kenali perintah teks.
const p = $('Webhook agen').first().json.body;
const MAX_B64 = 11 * 1024 * 1024;
const mime = p.mimetype || '';
const isDoc = /^document/i.test(p.message_type || '') ||
  /(spreadsheet|excel|csv|pdf|msword|officedocument)/i.test(mime);
// Hanya file tabel (xlsx/xls/csv) yang diunggah ke folder "RC 0"; PDF dan lainnya hanya dicatat.
const isSheet = /(spreadsheet|excel|csv)/i.test(mime);
const b64 = isSheet ? (p.media_base64 || null) : null;
const tooBig = !!(b64 && b64.length > MAX_B64);
const ext = /csv/i.test(mime) ? 'csv' : (/spreadsheetml|openxml/i.test(mime) ? 'xlsx' : 'xls');
const wib = new Date(Date.now() + 7 * 3600 * 1000).toISOString().slice(0, 16).replace('T', ' ').replace(':', '');
const cap = String(p.raw_text ?? p.text ?? '').replace(/[^A-Za-z0-9 _.-]/g, '').trim().slice(0, 40);
const fileName = ('RC0 ' + (cap ? cap + ' ' : '') + wib + '.' + ext);
const t = String(p.raw_text ?? p.text ?? '').trim();
const tl = t.toLowerCase();
let cmd = 'catat', arg = '';
if (!isDoc) {
  if (/^(proses|cek harga|update harga|mulai)\b/.test(tl)) cmd = 'proses';
  else if (/^setuju\b/.test(tl)) { cmd = 'setuju'; arg = tl.replace(/^setuju\s*/, ''); }
  else if (/^(pdf|buat pdf|fase 2)\b/.test(tl)) { cmd = 'pdf'; arg = t.replace(/^(pdf|buat pdf|fase 2)\s*/i, ''); }
  else if (/^(minggu baru|rotasi)\b/.test(tl)) { cmd = 'rotasi'; arg = t.replace(/^(minggu baru|rotasi)\s*/i, ''); }
  else if (/^(tes google|tes koneksi)\b/.test(tl)) cmd = 'tes';
  else if (/^batal\b/.test(tl)) cmd = 'batal';
  else if (/^(bantuan|menu|help)\b/.test(tl)) cmd = 'bantuan';
}
return [{ json: {
  cmd, arg, task_id: p.task_id, chat_id: p.chat_id, too_big: tooBig,
  upload: !!b64 && !tooBig, b64: tooBig ? null : b64, file_name: fileName, mime,
  p: {
    message_id: p.message_id, chat_id: p.chat_id, sender: p.sender, push_name: p.push_name,
    text: p.raw_text ?? p.text ?? '', message_type: p.message_type, mimetype: p.mimetype,
  },
} }];
