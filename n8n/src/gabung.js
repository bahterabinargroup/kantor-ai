// Tambahkan satu baris analisis (bila ada) ke balasan. Gagal/kosong/"-" = balasan asli apa adanya.
const b = $('Susun balasan').first().json;
const r = $input.first().json || {};
let t = (r.candidates && r.candidates[0] && r.candidates[0].content && r.candidates[0].content.parts && r.candidates[0].content.parts.map(x => x.text || '').join('')) || '';
t = String(t).trim().split(/\r?\n/).filter(x => x.trim())[0] || '';
t = t.replace(/^[•\-*\s]+/, '').trim();
let reply = b.reply;
if (t.length > 8 && t !== '-') reply += '\n💡 ' + t.slice(0, 160);
return [{ json: { chat_id: b.chat_id, task_id: b.task_id, reply, kind: b.kind, failed: b.failed, error: b.error } }];
