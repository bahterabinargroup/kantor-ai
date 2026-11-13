// Cek jawaban model penglihat: bisa dibaca sebagai JSON? Kalau tidak, alur mencoba ulang sendiri (tanpa melibatkan pengirim foto).
const r = $input.first().json || {};
const s = $('Siapkan').first().json;
const t = s.vision_provider === 'gemini'
  ? (r.candidates && r.candidates[0] && r.candidates[0].content && r.candidates[0].content.parts && r.candidates[0].content.parts.map(x => x.text || '').join(''))
  : (r.content && r.content[0] && r.content[0].text);
let ok = false;
if (t) {
  const a = t.indexOf('{'), b = t.lastIndexOf('}');
  if (a >= 0 && b > a) { try { const v = JSON.parse(t.slice(a, b + 1)); ok = !!(v && typeof v === 'object' && v.type); } catch (e) { ok = false; } }
}
return [{ json: Object.assign({}, r, { __ok: ok }) }];
