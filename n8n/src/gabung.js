// Tambahkan hasil analisis (bila ada) ke balasan. Gagal/kosong = balasan asli apa adanya.
const b = $('Susun balasan').first().json;
const r = $input.first().json || {};
let t = (r.candidates && r.candidates[0] && r.candidates[0].content && r.candidates[0].content.parts && r.candidates[0].content.parts.map(x => x.text || '').join('')) || '';
t = String(t).trim();
let reply = b.reply;
if (t && t.length > 5) reply += '\n💡 Analisis:\n' + t.slice(0, 700);
return [{ json: { chat_id: b.chat_id, task_id: b.task_id, reply, kind: b.kind, failed: b.failed, error: b.error } }];
