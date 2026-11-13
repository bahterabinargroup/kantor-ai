// Gabungkan hasil bacaan foto (bila ada) dengan teks pesan → satu panggilan RPC akun_handle.
const s = $('Siapkan').first().json;
function extractJson(t) {
  const a = t.indexOf('{'), b = t.lastIndexOf('}');
  if (a < 0 || b <= a) return null;
  try { return JSON.parse(t.slice(a, b + 1)); } catch (e) { return null; }
}
let v = null;
let err = s.vision_error || null;
if (s.need_vision) {
  const r = $input.first().json || {};
  const t = s.vision_provider === 'gemini'
    ? (r.candidates && r.candidates[0] && r.candidates[0].content && r.candidates[0].content.parts && r.candidates[0].content.parts.map(x => x.text || '').join(''))
    : (r.content && r.content[0] && r.content[0].text);
  if (!t) {
    let m = (r.error && (r.error.message || r.error)) || r.message || 'jawaban kosong';
    err = String(typeof m === 'string' ? m : JSON.stringify(m)).slice(0, 160);
  } else {
    v = extractJson(t);
    if (!v) {
      const fr = r.candidates && r.candidates[0] && r.candidates[0].finishReason;
      err = 'jawaban model bukan JSON' + (fr ? ' (finish: ' + fr + ')' : '') + ' | ' + String(t).replace(/\s+/g, ' ').slice(0, 100);
    }
  }
}
const base = { message_id: s.message_id, chat_id: s.chat_id, sender: s.sender };
const isPhotoKind = v && (v.type === 'nota' || v.type === 'foto_barang' || v.type === 'bukti_bayar');
let rpc;
let localReply = s.local_reply || null;
if (s.grup_chat) {
  rpc = s.grup ? Object.assign({}, base, { kind: 'grup_pengeluaran', expense: s.grup }) : Object.assign({}, base, { kind: 'ignore' });
} else if (s.mode === 'qris' || s.mode === 'online') {
  const want = s.mode === 'qris' ? 'settlement' : 'online_income';
  const vr = v && v.type === want && Array.isArray(v.rows) ? v.rows : [];
  const rows = vr.concat(s.text_rows || []);
  if (rows.length) rpc = Object.assign({}, base, { kind: want, rows });
  else {
    rpc = Object.assign({}, base, { kind: 'ignore' });
    if (!err) localReply = s.mode === 'qris'
      ? 'Kirim tangkapan layar mutasi bank dengan caption "/akuntan qris", atau ketik baris: 11/11 203.000'
      : 'Kirim tangkapan layar aplikasi merchant dengan caption "/akuntan online", atau ketik baris: 10/11 shopee 97.917';
  }
} else if (s.koreksi && s.koreksi.items.length) {
  rpc = Object.assign({}, base, { kind: 'koreksi', date: s.koreksi.date, items: s.koreksi.items });
} else if (s.mode === 'ditolak') {
  rpc = Object.assign({}, base, { kind: 'ignore' });
} else if (v && v.type === 'lembar_harian') {
  rpc = Object.assign({}, base, { kind: 'sheet', sheet: v });
} else if (s.expense) {
  rpc = Object.assign({}, base, { kind: 'expense_text', expense: s.expense,
    photo: isPhotoKind ? { type: v.type, total: v.total === undefined ? null : v.total, vendor: v.vendor || null }
         : (s.media && !v ? { type: 'foto_barang' } : null) });
} else if (v && v.type === 'bukti_bayar') {
  rpc = Object.assign({}, base, { kind: 'bukti_bayar', proof: { amount: v.total, date: v.date || null, item: v.item || null, vendor: v.vendor || null } });
} else if (isPhotoKind) {
  rpc = Object.assign({}, base, { kind: 'photo', photo: { type: v.type, total: v.total === undefined ? null : v.total, vendor: v.vendor || null } });
} else if (s.rekap) {
  rpc = Object.assign({}, base, { kind: 'rekap', date: s.rekap_date });
} else {
  rpc = Object.assign({}, base, { kind: 'ignore' });
}
// foto gagal dibaca dan tidak ada teks laporan: tandai tugas gagal (tanpa isi pesan) supaya terlihat di dashboard
const failed = !!err && s.media && !s.expense && s.mode !== 'ditolak' && !s.local_reply;
// jawaban model tak terbaca → minta kirim ulang; gangguan teknis (API key, jaringan) → diam, tugas ditandai gagal
const unreadable = failed && /bukan JSON/.test(err);
const uncertain = (v && Array.isArray(v.uncertain) ? v.uncertain : []).filter(x => x && String(x).trim()).slice(0, 5).map(x => String(x).slice(0, 140));
return [{ json: { p: rpc, kind: rpc.kind, failed, unreadable, error: failed ? err : null, local_reply: localReply, uncertain: (s.mode === 'qris' || s.mode === 'online') ? uncertain : [] } }];
