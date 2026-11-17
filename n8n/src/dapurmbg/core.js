// ── Inti perhitungan (dipakai node Code dan diuji lokal) ──────────────────────
const norm = x => String(x == null ? '' : x).replace(/\s+/g, ' ').trim().toLowerCase();
const SYN = [['saos', 'saus'], ['jintan', 'jinten'], ['fres ', 'fresh '], ['mozarella', 'mozzarella']];
const STOP = new Set(['merk', 'kg', 'pcs', 'gr', 'gram', '1kg', '1', 'l', 'ml', 'liter', 'botol', 'saset', 'sachet', 'cap', 'raw', 'material', 'dan', 'tanpa']);
const ALIAS = { 'jamur salju/snow': 'jamur salju' };
const TABS = ['SAYURAN', 'KARBOHIDRAT', 'PROTEIN', 'BUMBU', 'SEMBAKO', 'BUAH & SUSU', 'BAHAN TAMBAHAN'];
const UTARA = ['pringapus', 'bawen', 'ambarawa', 'banyubiru'];
const SELATAN = ['kranggan', 'kedungsari', 'grabag', 'pituruh'];

function key(x) {
  let s = String(x || '').toLowerCase();
  for (const [a, b] of SYN) s = s.split(a).join(b);
  s = s.replace(/[^a-z0-9 ]/g, ' ').replace(/(\d+)\s*(gr|g|gram)\b/g, '$1gr');
  return s.split(/\s+/).filter(t => t && !STOP.has(t)).sort().join(' ');
}
function dice(a, b) {
  a = key(a); b = key(b); if (a.length < 2 || b.length < 2) return 0;
  const bg = s => { const m = new Map(); for (let i = 0; i < s.length - 1; i++) { const g = s.slice(i, i + 2); m.set(g, (m.get(g) || 0) + 1); } return m; };
  const A = bg(a), B = bg(b); let inter = 0;
  for (const [g, c] of A) inter += Math.min(c, B.get(g) || 0);
  return 2 * inter / ((a.length - 1) + (b.length - 1));
}
function toGrid(j) {
  const out = {};
  for (const s of (j.sheets || [])) {
    const rows = (((s.data || [])[0] || {}).rowData || []).map(r => ((r && r.values) || []).map(v => {
      const e = v && v.effectiveValue; if (!e) return null;
      if ('numberValue' in e) return e.numberValue; if ('stringValue' in e) return e.stringValue;
      if ('boolValue' in e) return e.boolValue; return null;
    }));
    out[s.properties.title] = rows;
  }
  return out;
}
const rp = n => (n < 0 ? '-' : '') + String(Math.round(Math.abs(n))).replace(/\B(?=(\d{3})+(?!\d))/g, '.');

function masterItems(rows) {
  const out = [];
  (rows || []).forEach((r, i) => {
    if (i === 0) return; const nm = r[1], pr = r[2];
    if (nm && typeof pr === 'number') out.push({ row: i + 1, name: String(nm).trim(), k: norm(nm), price: pr, unit: norm(r[3]), note: norm(r[5]) });
  });
  return out;
}
function rcRows(rows) {
  let hi = -1, cols = [];
  for (let i = 0; i < Math.min(12, rows.length); i++) {
    const js = []; (rows[i] || []).forEach((c, j) => { if (norm(c) === 'rc 0' && j > 0) js.push(j); });
    if (js.length) { hi = i; cols = js; break; }
  }
  if (hi < 0) return [];
  const out = [];
  for (let i = hi + 1; i < rows.length; i++) {
    const r = rows[i] || [];
    for (const ci of cols) { const nm = r[ci - 1], v = r[ci]; if (nm && typeof v === 'number') out.push({ name: String(nm).trim(), v, row: i + 1, unit: norm(r[ci + 1]), note: norm(r[ci + 2]) }); }
  }
  return out;
}
const sigs = (name, unit, note) => {
  const t = norm(name + ' ' + unit + ' ' + note).replace(/(\d+)\s*(gr|g|gram)\b/g, '$1gr').replace(/(\d+)\s*(kg|kilo)\b/g, '$1kg').replace(/\bkilo\b/g, 'kg').replace(/\bgram\b/g, 'gr');
  return new Set(t.split(/[^a-z0-9]+/).filter(x => /^(\d+(gr|kg|ml|l|pcs)|kg|gr|pcs|pack|ikat|btl|botol|liter|ml|sachet|saset|dus|box)$/.test(x)));
};
const unitOf = u => norm(u).replace(/\bkilo\b/, 'kg').replace(/\bgram\b/, 'gr').replace(/^1\s*(kg|gr|l|liter)$/, '$1');
function pickBest(cands, rc) {
  if (cands.length <= 1) return cands[0] || null;
  const rs = sigs('', rc.unit || '', rc.note || '');
  const sc = cands.map(x => { const ms = sigs(x.name, x.unit, x.note); let n = 0; for (const t of rs) if (ms.has(t)) n++; return { x, n }; });
  sc.sort((a, b) => b.n - a.n);
  if (sc[0].n > sc[1].n) return sc[0].x;
  return null; // seri: tidak bisa dibedakan dari satuan/keterangan
}
function findMaster(items, rc, pred, suffix) {
  const nm0 = ALIAS[norm(rc.name)] || rc.name; const nm = nm0 + (suffix || '');
  const k = norm(nm); const cand = items.filter(pred);
  let m = cand.filter(x => x.k === k);
  if (m.length) { const b = pickBest(m, rc); return b ? { item: b, how: 'exact' } : { item: m[0], how: 'exact', ambiguous: true }; }
  const kk = key(nm); m = cand.filter(x => key(x.name) === kk);
  if (m.length) { const b = pickBest(m, rc); if (b) return { item: b, how: 'key' }; if (m.length > 1) return { item: m[0], how: 'key', ambiguous: true }; }
  const sc = cand.map(x => ({ x, s: dice(nm, x.name) })).filter(o => o.s >= 0.85);
  if (sc.length) { const b = pickBest(sc.map(o => o.x), rc) || (sc.length === 1 ? sc[0].x : null);
    if (b) return { item: b, how: 'mirip' }; return { item: sc[0].x, how: 'mirip', ambiguous: true }; }
  return null;
}
function ayamKind(n) {
  n = norm(n);
  if (/giling/.test(n)) return 'giling'; if (/dadu/.test(n)) return 'dadu'; if (/katsu/.test(n)) return 'katsu';
  if (/tanpa kulit/.test(n)) return 'tanpakulit'; if (/(filet|fillet).*(dada|paha)|(dada|paha).*(filet|fillet)/.test(n)) return 'filet';
  if (/potong/.test(n)) return 'potong'; return null;
}
const EXCLUDE = [[/^bihun/i, 'Bihun tidak diubah (aturan tetap)'], [/minyak goreng/i, 'Minyak goreng dilewati']];

function classify(gridsList) {
  let sepakat = null, sawangan = null;
  for (const f of gridsList) {
    const t = Object.keys(f.grid);
    const isSep = t.includes('PROTEIN') && t.includes('SAYURAN');
    if (isSep && !sepakat) sepakat = f; else if (!isSep && !sawangan) sawangan = f;
  }
  return { sepakat, sawangan };
}

function reasons(m, rc) {
  const r = [];
  if (m.ambiguous) r.push('ada beberapa baris serupa di master, satuan/keterangan tidak membedakan');
  if (m.how === 'mirip') r.push('nama mirip dengan "' + rc.name + '"');
  const ru = unitOf(rc.unit), mu = unitOf(m.item.unit);
  if (ru && mu && ru !== mu) r.push('satuan beda (RC 0: ' + ru + ', master: ' + mu + ')');
  return r;
}
function buildPlan(masterG, sep, saw) {
  const items = [], unsure = [], unmatched = [], skipped = [], targets = new Map();
  const add = (e, reasons) => {
    const tk = e.tab + '|' + e.row;
    if (targets.has(tk)) { if (targets.get(tk).new !== e.new) reasons.push('nama dobel di RC 0, nilainya beda'); else return; }
    else targets.set(tk, e);
    if (e.old > 0 && Math.abs(e.new - e.old) / e.old > 0.5) reasons.push('selisih >50%');
    if (reasons.length) { e.why = reasons.join('; '); unsure.push(e); } else items.push(e);
  };
  for (const tab of TABS) {
    const mi = masterItems(masterG[tab]);
    if (sep && sep.grid[tab]) {
      for (const rc of rcRows(sep.grid[tab])) {
        const ex = EXCLUDE.find(([re]) => re.test(rc.name)); if (ex) { skipped.push(rc.name + ' (' + ex[1] + ')'); continue; }
        if (/^ayam /i.test(rc.name)) continue;
        const pred = x => !/^[su] ?ayam/i.test(x.name) && !(tab === 'SAYURAN' && x.k.endsWith(' s'));
        const m = findMaster(mi, rc, pred);
        if (!m) { unmatched.push(rc.name); continue; }
        if (m.item.price === rc.v) continue;
        add({ tab, row: m.item.row, name: m.item.name, old: m.item.price, new: rc.v, src: 'sepakat', via: m.how === 'key' ? rc.name : null }, reasons(m, rc));
      }
    }
  }
  // Sawangan: item berakhiran " S" di blok sayur Sawangan
  if (saw) {
    const mi = masterItems(masterG['SAYURAN']);
    const rows = saw.grid[Object.keys(saw.grid)[0]];
    for (const rc of rcRows(rows)) {
      const ex = EXCLUDE.find(([re]) => re.test(rc.name)); if (ex) continue;
      const m = findMaster(mi, rc, x => x.k.endsWith(' s'), ' S');
      if (!m) { unmatched.push(rc.name + ' (Sawangan)'); continue; }
      if (m.item.price === rc.v) continue;
      add({ tab: 'SAYURAN', row: m.item.row, name: m.item.name, old: m.item.price, new: rc.v, src: 'sawangan', via: m.how === 'key' ? rc.name : null }, reasons(m, rc));
    }
  }
  // Ayam: harga tertinggi per area
  if (sep && sep.grid['PROTEIN']) {
    const rows = sep.grid['PROTEIN']; let hi = -1, cj = -1;
    for (let i = 0; i < Math.min(30, rows.length) && hi < 0; i++) {
      (rows[i] || []).forEach((c, j) => { if (hi < 0 && norm(c) === 'item' && norm((rows[i] || [])[j + 1]) === 'pringapus') { hi = i; cj = j; } });
    }
    if (hi >= 0) {
      const areas = []; for (let j = cj + 1; j < rows[hi].length && rows[hi][j]; j++) areas.push([j, norm(rows[hi][j])]);
      const best = {};
      for (let i = hi + 1; i < rows.length && (rows[i] || [])[cj]; i++) {
        const kind = ayamKind(rows[i][cj]); if (!kind) continue;
        const mx = names => Math.max(-1, ...areas.filter(a => names.includes(a[1])).map(a => rows[i][a[0]]).filter(v => typeof v === 'number'));
        best[kind] = { u: mx(UTARA), s: mx(SELATAN) };
      }
      const pm = masterItems(masterG['PROTEIN']);
      for (const x of pm) {
        const g = /^s ?ayam/i.test(x.name) ? 's' : (/^u ?ayam/i.test(x.name) ? 'u' : null); if (!g) continue;
        const kind = ayamKind(x.name); const b = best[kind]; if (!b || b[g] <= 0) continue;
        if (b[g] !== x.price) add({ tab: 'PROTEIN', row: x.row, name: x.name, old: x.price, new: b[g], src: (g === 's' ? 'Selatan' : 'Utara') + ', tertinggi' }, []);
      }
    }
  }
  const order = t => TABS.indexOf(t);
  const cmp = (a, b) => order(a.tab) - order(b.tab) || a.row - b.row;
  items.sort(cmp); unsure.sort(cmp);
  let n = 0; items.forEach(e => e.n = ++n); unsure.forEach(e => e.n = ++n);
  return { items, unsure, unmatched, skipped };
}

function weekInfo(masterName, sep) {
  const m = /Harga Supplier\s+(\S+)\s+Week\s*(\d+)/i.exec(masterName || '');
  let dates = null;
  if (sep) for (const t of Object.keys(sep.grid)) {
    for (const r of sep.grid[t].slice(0, 6)) for (const c of (r || [])) {
      const d = /(\d{1,2})\s*-\s*(\d{1,2})\s*(jan|feb|mar|apr|mei|jun|jul|agu|sep|okt|nov|des)/i.exec(String(c || ''));
      if (d && !dates) dates = d[1] + '-' + d[2];
    }
  }
  return { month: m ? m[1] : null, week: m ? m[2] : null, dates };
}

function formatPlan(plan) {
  const L = [];
  L.push('📋 *Rencana update harga RC 0*');
  L.push(plan.masterName + (plan.dates ? ' (' + plan.dates + ')' : ''));
  L.push('');
  const line = e => e.n + '. ' + e.tab + ' – ' + e.name + ': ' + rp(e.old) + ' → ' + rp(e.new) + ' (' + (e.new >= e.old ? '+' : '') + rp(e.new - e.old) + ')' + (e.src !== 'sepakat' ? ' [' + e.src + ']' : '') + (e.via ? ' (di RC 0: "' + e.via.trim() + '")' : '');
  L.push('*Akan diubah (' + plan.items.length + '):*');
  plan.items.forEach(e => L.push(line(e)));
  if (plan.unsure.length) {
    L.push(''); L.push('⚠️ *Perlu keputusan (TIDAK dimasukkan kecuali kamu setujui):*');
    plan.unsure.slice(0, 15).forEach(e => L.push(line(e) + ' — ' + e.why));
    if (plan.unsure.length > 15) L.push('…dan ' + (plan.unsure.length - 15) + ' lagi');
  }
  if (plan.skipped.length) { L.push(''); L.push('Dilewati sesuai aturan: ' + plan.skipped.slice(0, 6).join('; ')); }
  if (plan.unmatched.length) L.push('Tidak ada di master (dilewati): ' + plan.unmatched.length + ' item.');
  L.push('');
  L.push('Balas: *setuju* | *setuju kecuali 3,5* | *setuju + 31* (masukkan yang perlu keputusan) | *batal*');
  return L.join('\n');
}
