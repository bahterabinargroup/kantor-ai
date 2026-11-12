// Susun balasan dari hasil akun_handle. Diam kalau tidak ada yang perlu dikabarkan.
const p = $('Webhook agen').first().json.body;
const o = $('Olah hasil').first().json;
const r = $input.first().json || {};
let reply = o.unreadable ? 'Foto belum terbaca jelas. Mohon kirim ulang dengan foto lebih terang dan lurus, atau ketik manual.' : (o.failed ? '' : (o.local_reply || r.reply || ''));
if (reply && o.uncertain && o.uncertain.length) reply += '\n❓ Mohon dicek:\n' + o.uncertain.map(x => '• ' + x).join('\n');
return [{ json: { chat_id: p.chat_id, task_id: p.task_id, reply, kind: o.kind, failed: !!o.failed, error: o.error || null } }];
