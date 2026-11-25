#!/usr/bin/env python3
"""Membuat n8n/workflows/agent-dapurmbg.json (agen "Admin Catering").
Jalankan dari akar proyek:  python3 n8n/src/gen_dapurmbg.py
"""
import json, uuid, pathlib

root = pathlib.Path(__file__).resolve().parents[2]
out = root / "n8n" / "workflows" / "agent-dapurmbg.json"
ns = uuid.UUID("6f1c2a54-9d3e-4b7a-8c10-a1b2c3d4e5f6")
def nid(name): return str(uuid.uuid5(ns, "dapurmbg:" + name))

AGENT = "dapurmbg"
HDR = "={{ JSON.stringify($env.SUPABASE_SERVICE_KEY.startsWith('eyJ') ? { apikey: $env.SUPABASE_SERVICE_KEY, Authorization: 'Bearer ' + $env.SUPABASE_SERVICE_KEY } : { apikey: $env.SUPABASE_SERVICE_KEY }) }}"

def node(name, typ, ver, pos, params, **extra):
    n = {"id": nid(name), "name": name, "type": typ, "typeVersion": ver, "position": pos, "parameters": params}
    n.update(extra); return n

def http(name, pos, url, body, supabase=False, **extra):
    p = {"method": "POST", "url": url, "sendBody": True, "specifyBody": "json", "jsonBody": body, "options": {}}
    if supabase:
        p.update({"sendHeaders": True, "specifyHeaders": "json", "jsonHeaders": HDR})
    return node(name, "n8n-nodes-base.httpRequest", 4.2, pos, p, **extra)

def status(name, pos, st, detail, with_task):
    t = ", task_id: $json.body.task_id" if with_task else ""
    return http(name, pos, "http://n8n:5678/webhook/lib-set-status",
                "={{ JSON.stringify({ agent_id: '%s', status: '%s', detail: '%s'%s }) }}" % (AGENT, st, detail, t))

def code(name, pos, js): return node(name, "n8n-nodes-base.code", 2, pos, {"jsCode": js})

def if_node(name, pos, left, op, typ="string"):
    return node(name, "n8n-nodes-base.if", 2.2, pos, {
        "conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose"},
            "conditions": [{"id": nid(name + "-c"), "leftValue": left, "rightValue": "",
                            "operator": {"type": typ, "operation": op, "singleValue": True}}],
            "combinator": "and"}, "options": {}})

SIAPKAN = (pathlib.Path(__file__).parent / "dapurmbg" / "siapkan.js").read_text()
CORE = (pathlib.Path(__file__).parent / "dapurmbg" / "core.js").read_text()

BALASAN = r"""// Susun balasan singkat dari hasil dm_record dan hasil unggah ke Drive. Diam kalau tidak ada balasan.
const s = $('Siapkan').first().json;
const r = $('Catat (RPC dm_record)').first().json;
const res = Array.isArray(r) ? (r[0] || {}) : ((r && 'reply' in r) ? r : (r?.dm_record || r || {}));
let reply = res.reply || null;
if (s.too_big) {
  reply = '⚠️ File terlalu besar untuk disimpan (maks sekitar 8 MB). Coba kirim ulang yang lebih kecil.';
} else if (s.upload) {
  let d = null;
  try { d = $('Unggah ke Drive').first().json; } catch (e) {}
  if (d && d.id && !d.error) reply = '✅ File tersimpan di Drive (folder RC 0): ' + s.file_name + ' | ' + (res.reply || '');
  else reply = '⚠️ File diterima tapi gagal disimpan ke Drive. Saya catat dulu, mohon kabari Claude. ' + (res.reply || '');
}
return [{ json: { chat_id: s.chat_id, task_id: s.task_id, reply, kind: res.kind || 'text' } }];
"""

BIN = r"""// Ubah base64 dari WhatsApp menjadi file biner untuk node Google Drive.
const s = $('Siapkan').first().json;
const buf = Buffer.from(s.b64, 'base64');
const bin = await this.helpers.prepareBinaryData(buf, s.file_name, s.mime);
return [{ json: { file_name: s.file_name }, binary: { data: bin } }];
"""

nodes = [
 node("Catatan 0", "n8n-nodes-base.stickyNote", 1, [0, -320], {"content":
   "**Agen Admin Catering** (id `dapurmbg`) — grup WhatsApp \"Makan Makan Sehat\".\n"
   "Mencatat file (RC 0, PAGU jadi) dan teks di `dm_inbox`, membalas pendek \"File diterima\". "
   "Perintah teks (proses, setuju, pdf, minggu baru) menjalankan update harga RC 0 dan PDF PAGU DAPUR "
   "langsung dari grup lewat Google Sheets/Drive API.\n"
   "Nama tampil bisa diubah dari dashboard; id teknis tetap `dapurmbg`.",
   "width": 620, "height": 190, "color": 4}),
 node("Webhook agen", "n8n-nodes-base.webhook", 2, [0, 0],
   {"httpMethod": "POST", "path": "agent-" + AGENT, "responseMode": "onReceived", "options": {}},
   webhookId=nid("webhook")),
 status("Status: kerja", [240, 0], "working", "Mencatat pesan grup", True),
 code("Siapkan", [480, 0], SIAPKAN),
 http("Catat (RPC dm_record)", [720, 0], "={{ $env.SUPABASE_URL }}/rest/v1/rpc/dm_record",
      "={{ JSON.stringify({ p: $json.p }) }}", supabase=True),
 if_node("Ada file untuk Drive?", [960, 0], "={{ $('Siapkan').first().json.upload }}", "true", "boolean"),
 code("Siapkan biner", [1200, -120], BIN),
 node("Unggah ke Drive", "n8n-nodes-base.googleDrive", 3, [1440, -120], {
   "authentication": "oAuth2", "resource": "file", "operation": "upload",
   "inputDataFieldName": "data", "name": "={{ $json.file_name }}",
   "driveId": {"__rl": True, "mode": "list", "value": "My Drive"},
   "folderId": {"__rl": True, "mode": "id", "value": "1WEVt0170RsXi3aB-OCrH-DnGExw-LH6T"},
   "options": {}},
   credentials={"googleDriveOAuth2Api": {"id": "Doo76uHkmH0qmaiU", "name": "Google Drive OAuth - Kantor AI"}},
   onError="continueRegularOutput"),
 code("Susun balasan", [1680, 0], BALASAN),
 if_node("Ada balasan?", [1920, 0], "={{ $json.reply }}", "notEmpty"),
 http("Balas ke grup", [2160, -80], "http://n8n:5678/webhook/lib-send-wa",
      "={{ JSON.stringify({ chat_id: $json.chat_id, text: $json.reply }) }}"),
 http("Tutup tugas", [2400, 0], "={{ $env.SUPABASE_URL }}/rest/v1/rpc/finish_task",
      "={{ JSON.stringify({ p_task_id: $('Susun balasan').first().json.task_id, p_status: 'done', p_result: { kind: $('Susun balasan').first().json.kind } }) }}",
      supabase=True),
 status("Status: santai", [2640, 0], "idle", "Selesai", False),
]

# ═══════════ Alur perintah dari WhatsApp ═══════════
GCRED = {"googleDriveOAuth2Api": {"id": "Doo76uHkmH0qmaiU", "name": "Google Drive OAuth - Kantor AI"}}
RC0_FOLDER = "1WEVt0170RsXi3aB-OCrH-DnGExw-LH6T"
PAGU_ID = "1e1swdU2BkjI7zT5j7UrdoE02_hlsd7D0x_c9fI8jFNQ"
PAGU_FOLDER = "17pWW6G5SpE9SjyJmzo_Z4BD3QezDILtG"
SHEETS = "https://sheets.googleapis.com/v4/spreadsheets/"
DRIVE = "https://www.googleapis.com/drive/v3/files"
GRID_FIELDS = "sheets(properties(title),data(rowData(values(effectiveValue))))"

def g(name, pos, method, url, body=None, file=False, err=True):
    p = {"method": method, "url": url, "authentication": "predefinedCredentialType",
         "nodeCredentialType": "googleDriveOAuth2Api", "options": {}}
    if body is not None:
        p.update({"sendBody": True, "specifyBody": "json", "jsonBody": body})
    if file:
        p["options"] = {"response": {"response": {"responseFormat": "file"}}}
    return node(name, "n8n-nodes-base.httpRequest", 4.2, pos, p, credentials=GCRED,
                onError=("continueErrorOutput" if err else "continueRegularOutput"))

def wa(name, pos, text_expr):
    return http(name, pos, "http://n8n:5678/webhook/lib-send-wa",
                "={{ JSON.stringify({ chat_id: $('Siapkan').first().json.chat_id, text: %s }) }}" % text_expr)

def if_ok(name, pos):
    return if_node(name, pos, "={{ $json.ok }}", "true", "boolean")

def sw(name, pos, outs):
    rules = [{"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
              "conditions": [{"id": nid(name + o), "leftValue": "={{ $json.cmd }}", "rightValue": o,
                              "operator": {"type": "string", "operation": "equals"}}], "combinator": "and"},
              "renameOutput": True, "outputKey": o} for o in outs]
    return node(name, "n8n-nodes-base.switch", 3.2, pos, {"rules": {"values": rules}, "options": {"fallbackOutput": "extra"}})

def state_get(name, pos):
    return http(name, pos, "={{ $env.SUPABASE_URL }}/rest/v1/rpc/dm_state_get", "={{ JSON.stringify({ p_key: 'plan' }) }}", supabase=True)
def state_set(name, pos, val_expr):
    return http(name, pos, "={{ $env.SUPABASE_URL }}/rest/v1/rpc/dm_state_set",
                "={{ JSON.stringify({ p_key: 'plan', p_val: %s }) }}" % val_expr, supabase=True)

MASTER_FIND = "($json.files || []).find(f => f.name.startsWith('[MASTER] Harga Supplier')) || {}"
def drive_list(name, pos, q, fields="files(id,name,parents,createdTime,modifiedTime)", order="modifiedTime desc", size=50):
    return g(name, pos, "GET", "=%s?q={{ encodeURIComponent(\"%s\") }}&orderBy={{ encodeURIComponent('%s') }}&pageSize=%d&fields={{ encodeURIComponent('%s') }}" % (DRIVE, q, order, size, fields))

RELAY = "return [{ json: { reply: $('%s').first().json.reply } }];"
GAGAL = r"""const e = $input.first().json;
const er = e.error || e;
const msg = [er.message, er.description].filter(Boolean).join(' – ') || JSON.stringify(e).slice(0, 300);
return [{ json: { reply: '⚠️ Gagal: ' + String(msg).slice(0, 450) + '\nMohon kabari Claude.' } }];"""

flow_nodes, flow_conn = [], {}
def link(a, b, port=0):
    flow_conn.setdefault(a, {"main": []})
    m = flow_conn[a]["main"]
    while len(m) <= port: m.append([])
    m[port].append({"node": b, "type": "main", "index": 0})
def chain(*names):
    for a, b in zip(names, names[1:]): link(a, b)
def add(*ns):
    flow_nodes.extend(ns)

X = 0; Y0 = 520
def y(k): return Y0 + k * 340
def xs(i): return 1200 + i * 240

# ── tail bersama
add(code("Lapor gagal", [xs(14), y(9)], GAGAL),
    wa("Balas alur", [xs(15), y(9)], "$json.reply"),
    http("Tutup alur", [xs(16), y(9)], "={{ $env.SUPABASE_URL }}/rest/v1/rpc/finish_task",
         "={{ JSON.stringify({ p_task_id: $('Siapkan').first().json.task_id, p_status: 'done', p_result: { kind: 'perintah' } }) }}", supabase=True))
chain("Lapor gagal", "Balas alur"); chain("Balas alur", "Tutup alur"); link("Tutup alur", "Status: santai")

def fail_to_lapor(*names):
    for n in names: link(n, "Lapor gagal", 1)

# ── bantuan & batal
BANTUAN = ("🍱 *Admin Catering – perintah*\n"
 "• Kirim 2 file RC 0 (sepakat + Sawangan) → otomatis tersimpan di Drive\n"
 "• *proses* → baca RC 0, bandingkan dengan master, kirim daftar perubahan\n"
 "• *setuju* / *setuju kecuali 3,5* / *setuju + 31* → tulis harga ke master\n"
 "• *pdf* → buat 3 PDF PAGU DAPUR (U, S, SAWANGAN) dan kirim link\n"
 "• *minggu baru* → arsipkan master minggu ini, siapkan master minggu depan\n"
 "• *batal* → hapus rencana yang menunggu\n• *tes google* → cek koneksi Google")
add(code("Bantuan", [xs(0), y(0)], "return [{ json: { reply: %s } }];" % json.dumps(BANTUAN, ensure_ascii=False)))
chain("Bantuan", "Balas alur")
add(state_set("Batal: hapus", [xs(0), y(1)], "null"),
    code("Batal: balasan", [xs(1), y(1)], "return [{ json: { reply: '🗑️ Rencana dibatalkan. Ketik *proses* untuk mulai lagi.' } }];"))
chain("Batal: hapus", "Batal: balasan", "Balas alur")

# ── tes google
add(drive_list("Tes: cari master", [xs(0), y(2)], "name contains 'Harga Supplier' and mimeType='application/vnd.google-apps.spreadsheet' and trashed=false"),
    g("Tes: baca Sheets", [xs(1), y(2)], "GET", "=%s{{ (%s).id }}?fields=properties.title,sheets.properties.title" % (SHEETS, MASTER_FIND)),
    code("Tes: balasan", [xs(2), y(2)], "const j = $json; return [{ json: { reply: '✅ Google OK. Master: ' + j.properties.title + ' (' + (j.sheets || []).length + ' tab)' } }];"))
chain("Tes: cari master", "Tes: baca Sheets", "Tes: balasan", "Balas alur")
fail_to_lapor("Tes: cari master", "Tes: baca Sheets")

# ── proses
P = "Proses: "
add(wa(P + "kabar", [xs(0), y(3)], "'⏳ Membaca file RC 0 dan master…'"),
    drive_list(P + "daftar file", [xs(1), y(3)], "'%s' in parents and trashed=false and (mimeType='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' or mimeType='application/vnd.ms-excel')" % RC0_FOLDER, "files(id,name,createdTime)", "createdTime desc", 20),
    drive_list(P + "cari master", [xs(2), y(3)], "name contains 'Harga Supplier' and mimeType='application/vnd.google-apps.spreadsheet' and trashed=false"),
    g(P + "baca master", [xs(3), y(3)], "GET", "=%s{{ ($('%scari master').first().json.files || []).find(f => f.name.startsWith('[MASTER] Harga Supplier')).id }}?includeGridData=true&fields={{ encodeURIComponent('%s') }}" % (SHEETS, P, GRID_FIELDS)),
    code(P + "pilih", [xs(4), y(3)], r"""const list = $('Proses: daftar file').first().json.files || [];
const mf = ($('Proses: cari master').first().json.files || []).find(f => f.name.startsWith('[MASTER] Harga Supplier'));
if (!mf) return [{ json: { ok: false, reply: '⚠️ Master "[MASTER] Harga Supplier ..." tidak ditemukan di Drive.' } }];
const cutoff = Date.now() - 21 * 864e5;
const c = list.filter(f => new Date(f.createdTime).getTime() > cutoff).slice(0, 4);
if (!c.length) return [{ json: { ok: false, reply: '⚠️ Belum ada file RC 0 dalam 3 minggu terakhir. Kirim dulu file RC 0 ke grup ini.' } }];
return c.map((f, i) => ({ json: { ok: true, fileId: f.id, fname: f.name, created: f.createdTime, idx: i } }));"""),
    if_ok(P + "ada file?", [xs(5), y(3)]),
    g(P + "konversi RC0", [xs(6), y(3)], "POST", "=%s/{{ $json.fileId }}/copy" % DRIVE,
      "={{ JSON.stringify({ name: 'tmp-rc0-' + Date.now() + '-' + $json.idx, mimeType: 'application/vnd.google-apps.spreadsheet', parents: ['%s'] }) }}" % RC0_FOLDER),
    g(P + "baca RC0", [xs(7), y(3)], "GET", "=%s{{ $json.id }}?includeGridData=true&fields={{ encodeURIComponent('%s') }}" % (SHEETS, GRID_FIELDS)),
    g(P + "hapus sementara", [xs(8), y(3) - 140], "DELETE", "=%s/{{ $('%skonversi RC0').item.json.id }}" % (DRIVE, P), err=False),
    code(P + "rencana", [xs(9), y(3)], CORE + r"""
const masterG = toGrid($('Proses: baca master').first().json);
const metas = $('Proses: pilih').all().map(i => i.json);
const reads = $('Proses: baca RC0').all().map(i => i.json);
const files = reads.map((j, i) => ({ name: metas[i].fname, id: metas[i].fileId, grid: toGrid(j) }));
const { sepakat, sawangan } = classify(files);
if (!sepakat) return [{ json: { reply: '⚠️ File RC 0 sepakat belum ketemu (yang berisi tab SAYURAN dan PROTEIN). Kirim ke grup lalu ketik *proses* lagi.' } }];
const mf = ($('Proses: cari master').first().json.files || []).find(f => f.name.startsWith('[MASTER] Harga Supplier'));
const pl = buildPlan(masterG, sepakat, sawangan);
const wk = weekInfo(mf.name, sepakat);
const plan = { status: 'pending', masterId: mf.id, masterName: mf.name, month: wk.month, week: wk.week, dates: wk.dates,
  files: { sepakat: sepakat.name, sawangan: sawangan ? sawangan.name : null }, items: pl.items, unsure: pl.unsure,
  skipped: pl.skipped, unmatched: pl.unmatched, createdAt: new Date().toISOString() };
let reply = formatPlan(plan);
reply += '\n\nFile dipakai: ' + sepakat.name + (sawangan ? ' + ' + sawangan.name : ' (file Sawangan BELUM ada, harga Sawangan tidak ikut)');
return [{ json: { reply, plan } }];"""),
    state_set(P + "simpan", [xs(10), y(3)], "$json.plan"),
    code(P + "balasan", [xs(11), y(3)], RELAY % (P + "rencana")))
chain(P + "kabar", P + "daftar file", P + "cari master", P + "baca master", P + "pilih", P + "ada file?")
link(P + "ada file?", P + "konversi RC0", 0); link(P + "ada file?", "Balas alur", 1)
chain(P + "konversi RC0", P + "baca RC0")
link(P + "baca RC0", P + "hapus sementara"); link(P + "baca RC0", P + "rencana")
chain(P + "rencana", P + "simpan", P + "balasan", "Balas alur")
fail_to_lapor(P + "daftar file", P + "cari master", P + "baca master", P + "konversi RC0", P + "baca RC0")

# ── setuju
S = "Setuju: "
add(state_get(S + "ambil rencana", [xs(0), y(4)]),
    code(S + "susun", [xs(1), y(4)], r"""const plan = $json.val;
if (!plan || !plan.items) return [{ json: { ok: false, reply: 'Belum ada rencana yang menunggu. Ketik *proses* dulu.' } }];
if (plan.status === 'applied') return [{ json: { ok: false, reply: 'Rencana ini sudah ditulis ke master. Ketik *pdf* untuk lanjut, atau *proses* untuk rencana baru.' } }];
const a = String($('Siapkan').first().json.arg || '');
const nums = s => (s ? (s.match(/\d+/g) || []).map(Number) : []);
const ex = nums((/kecuali\s*([\d,\s]+)/.exec(a) || [])[1]);
const inc = nums((/(?:\+|masukkan|tambah)\s*([\d,\s]+)/.exec(a) || [])[1]);
const chosen = plan.items.filter(e => !ex.includes(e.n)).concat(plan.unsure.filter(e => inc.includes(e.n)));
if (!chosen.length) return [{ json: { ok: false, reply: 'Tidak ada harga yang dipilih untuk ditulis.' } }];
const ranges = chosen.map(e => "'" + e.tab + "'!C" + e.row);
return [{ json: { ok: true, plan, chosen, ranges, excluded: ex, included: inc,
  url: 'https://sheets.googleapis.com/v4/spreadsheets/' + plan.masterId + '/values:batchGet?valueRenderOption=UNFORMATTED_VALUE&ranges=' + ranges.map(encodeURIComponent).join('&ranges=') } }];"""),
    if_ok(S + "ada rencana?", [xs(2), y(4)]),
    g(S + "baca lama", [xs(3), y(4)], "GET", "={{ $json.url }}"),
    code(S + "cek lama", [xs(4), y(4)], r"""const d = $('Setuju: susun').first().json;
const vr = $json.valueRanges || [];
const writes = [], blocked = [];
d.chosen.forEach((e, i) => {
  const cur = (((vr[i] || {}).values || [])[0] || [])[0];
  if (Number(cur) === Number(e.old)) writes.push(e); else blocked.push(e.n + '. ' + e.name + ' (sekarang ' + cur + ', rencana mengira ' + e.old + ')');
});
const body = { valueInputOption: 'RAW', data: writes.map(e => ({ range: "'" + e.tab + "'!C" + e.row, values: [[e.new]] })) };
return [{ json: { ok: writes.length > 0, writes, blocked, body, plan: d.plan, reply: 'Tidak ada yang bisa ditulis: nilai di master sudah beda dari rencana. ' + blocked.join('; ') } }];"""),
    if_ok(S + "ada tulisan?", [xs(5), y(4)]),
    g(S + "tulis", [xs(6), y(4)], "POST", "=%s{{ $('Setuju: cek lama').first().json.plan.masterId }}/values:batchUpdate" % SHEETS,
      "={{ JSON.stringify($('Setuju: cek lama').first().json.body) }}"),
    g(S + "baca baru", [xs(7), y(4)], "GET", "={{ $('Setuju: susun').first().json.url }}"),
    code(S + "verifikasi", [xs(8), y(4)], r"""const d = $('Setuju: cek lama').first().json;
const all = $('Setuju: susun').first().json.chosen;
const vr = $json.valueRanges || [];
let ok = 0; const bad = [];
all.forEach((e, i) => {
  const want = d.writes.find(w => w.n === e.n); if (!want) return;
  const cur = (((vr[i] || {}).values || [])[0] || [])[0];
  if (Number(cur) === Number(e.new)) ok++; else bad.push(e.n + '. ' + e.name + ' (hasil ' + cur + ', seharusnya ' + e.new + ')');
});
const plan = d.plan; plan.status = bad.length ? 'pending' : 'applied'; plan.appliedAt = new Date().toISOString();
let reply = (bad.length ? '⚠️ ' : '✅ ') + ok + ' dari ' + d.writes.length + ' harga tertulis dan terverifikasi di ' + plan.masterName + '.';
if (d.blocked.length) reply += '\nDilewati karena nilai di master sudah berubah: ' + d.blocked.join('; ');
if (bad.length) reply += '\nBELUM cocok: ' + bad.join('; ') + '\nMohon kabari Claude.';
else reply += '\nLanjut: ketik *pdf* untuk membuat 3 PDF PAGU DAPUR.';
return [{ json: { reply, plan } }];"""),
    state_set(S + "simpan", [xs(9), y(4)], "$json.plan"),
    code(S + "balasan", [xs(10), y(4)], RELAY % (S + "verifikasi")))
chain(S + "ambil rencana", S + "susun", S + "ada rencana?")
link(S + "ada rencana?", S + "baca lama", 0); link(S + "ada rencana?", "Balas alur", 1)
chain(S + "baca lama", S + "cek lama", S + "ada tulisan?")
link(S + "ada tulisan?", S + "tulis", 0); link(S + "ada tulisan?", "Balas alur", 1)
chain(S + "tulis", S + "baca baru", S + "verifikasi", S + "simpan", S + "balasan", "Balas alur")
fail_to_lapor(S + "ambil rencana", S + "baca lama", S + "tulis", S + "baca baru")

# ── pdf
D = "PDF: "
add(state_get(D + "ambil rencana", [xs(0), y(5)]),
    code(D + "nama", [xs(1), y(5)], r"""const plan = $json.val || {};
const arg = String($('Siapkan').first().json.arg || '').replace(/[()]/g, ' ');
const MON = ['januari','februari','maret','april','mei','juni','juli','agustus','september','oktober','november','desember'];
const mi = s => { s = String(s || '').toLowerCase(); return s.length < 3 ? -1 : MON.findIndex(m => m.startsWith(s.slice(0, 3))); };
const cap = i => MON[i].charAt(0).toUpperCase() + MON[i].slice(1);
let month = plan.month, week = plan.week, dates = plan.dates, sm = -1, em = -1;
const a = /([a-z]+)\s+week\s*(\d+)\s+(\d{1,2})\s*([a-z]*)\s*-\s*(\d{1,2})\s*([a-z]*)/i.exec(arg);
if (a) { month = a[1]; week = a[2]; dates = a[3] + '-' + a[5]; sm = mi(a[4]); em = mi(a[6]); }
if (!month || !week || !dates) return [{ json: { ok: false, reply: 'Saya belum tahu minggu dan tanggalnya. Ketik *proses* dulu, atau tulis: *pdf November Week 4 22-26* (lintas bulan: *pdf Desember Week 1 29nov-3des*)' } }];
const mm = mi(month);
if (mm < 0) return [{ json: { ok: false, reply: 'Nama bulan "' + month + '" tidak saya kenali. Contoh: *pdf Desember Week 1 29-3*' } }];
const d = String(dates).split('-').map(Number);
if (em < 0) em = mm;
if (sm < 0) sm = d[0] > d[1] ? (em + 11) % 12 : em;
const range = sm === em ? d[0] + '-' + d[1] + cap(em) : d[0] + cap(sm) + '-' + d[1] + cap(em);
const base = ' PAGU DAPUR - ' + cap(mm) + ' Week ' + week + '(' + range + ').pdf';
return [{ json: { ok: true, label: cap(mm) + ' Week ' + week + ' (' + range + ')', names: { U: 'U' + base, S: 'S' + base, W: 'SAWANGAN' + base } } }];"""),
    if_ok(D + "nama ok?", [xs(2), y(5)]),
    wa(D + "kabar", [xs(3), y(5)], "'⏳ Membuat 3 PDF PAGU DAPUR (' + $('PDF: nama').first().json.label + ')…'"),
    g(D + "baca PAGU", [xs(4), y(5)], "GET", "=%s%s?includeGridData=true&ranges={{ encodeURIComponent(\"'BAHAN BAKU ALL'!A1:G600\") }}&fields={{ encodeURIComponent('sheets(properties(title,sheetId),data(rowData(values(effectiveValue)),rowMetadata(hiddenByUser)))') }}" % (SHEETS, PAGU_ID)),
    code(D + "hitung baris", [xs(5), y(5)], CORE + r"""
const sh = $json.sheets[0]; const sheetId = sh.properties.sheetId;
const rows = toGrid({ sheets: [sh] })[sh.properties.title];
const meta = (sh.data[0].rowMetadata || []).map(m => !!(m && m.hiddenByUser));
let last = 0; rows.forEach((r, i) => { if (r && r[1]) last = i; });
const isS = n => /\sS$/.test(String(n || '').trim());
const set = { S: [], uA: [], sA: [], reg: [], oil: [] };
rows.forEach((r, i) => {
  if (i === 0 || !r || !r[1]) return; const n = String(r[1]).trim();
  if (isS(n)) set.S.push(i); else if (String(r[6] || '').toLowerCase() === 'sayuran') set.reg.push(i);
  if (/^s ?ayam/i.test(n)) set.sA.push(i); if (/^u ?ayam/i.test(n)) set.uA.push(i);
  if (/sunco|fortune/i.test(n)) set.oil.push(i);
});
if (!set.S.length || !set.sA.length || !set.uA.length || !set.reg.length)
  return [{ json: { ok: false, reply: '⚠️ Struktur PAGU DAPUR tidak seperti biasa (sayur Sawangan ' + set.S.length + ', sAyam ' + set.sA.length + ', u Ayam ' + set.uA.length + ', sayur biasa ' + set.reg.length + '). Saya berhenti, tidak mengubah apa pun.' } }];
const mk = hid => {
  const H = new Set(hid); const req = []; let i = 1;
  while (i <= last) { const v = H.has(i); let j = i; while (j + 1 <= last && H.has(j + 1) === v) j++;
    req.push({ updateDimensionProperties: { range: { sheetId, dimension: 'ROWS', startIndex: i, endIndex: j + 1 }, properties: { hiddenByUser: v }, fields: 'hiddenByUser' } }); i = j + 1; }
  return req;
};
const init = []; meta.forEach((h, i) => { if (h && i >= 1 && i <= last) init.push(i); });
const n = $('PDF: nama').first().json;
return [{ json: { ok: true, sheetId, last, initHidden: init, names: n.names, label: n.label,
  counts: { S: set.S.length, sA: set.sA.length, uA: set.uA.length, reg: set.reg.length, oil: set.oil.length },
  reqU: mk([...set.S, ...set.sA, ...set.oil]), reqS: mk([...set.S, ...set.uA, ...set.oil]),
  reqW: mk([...set.reg, ...set.uA, ...set.oil]), reqInit: mk(init) } }];"""),
    if_ok(D + "baris ok?", [xs(6), y(5)]))
chain(D + "ambil rencana", D + "nama", D + "nama ok?")
link(D + "nama ok?", D + "kabar", 0); link(D + "nama ok?", "Balas alur", 1)
chain(D + "kabar", D + "baca PAGU", D + "hitung baris", D + "baris ok?")
link(D + "baris ok?", D + "atur U", 0); link(D + "baris ok?", "Balas alur", 1)

emerg = D + "pulihkan darurat"
prev = None
for k, (v, req) in enumerate([("U", "reqU"), ("S", "reqS"), ("W", "reqW")]):
    base_x = 7 + k * 3
    add(g(D + "atur " + v, [xs(base_x), y(5)], "POST", "=%s%s:batchUpdate" % (SHEETS, PAGU_ID),
          "={{ JSON.stringify({ requests: $('PDF: hitung baris').first().json.%s }) }}" % req),
        g(D + "ekspor " + v, [xs(base_x + 1), y(5)], "GET", "=%s/%s/export?mimeType=application%%2Fpdf" % (DRIVE, PAGU_ID), file=True),
        node(D + "simpan " + v, "n8n-nodes-base.googleDrive", 3, [xs(base_x + 2), y(5)], {
            "authentication": "oAuth2", "resource": "file", "operation": "upload", "inputDataFieldName": "data",
            "name": "={{ $('PDF: hitung baris').first().json.names.%s }}" % v,
            "driveId": {"__rl": True, "mode": "list", "value": "My Drive"},
            "folderId": {"__rl": True, "mode": "id", "value": PAGU_FOLDER}, "options": {}},
            credentials=GCRED, onError="continueErrorOutput"))
    chain(D + "atur " + v, D + "ekspor " + v, D + "simpan " + v)
    link(D + "simpan " + v, D + "atur " + {"U": "S", "S": "W"}[v], 0) if v != "W" else link(D + "simpan W", D + "pulihkan", 0)
    for nn in ("atur ", "ekspor ", "simpan "): link(D + nn + v, emerg, 1)
add(g(D + "pulihkan", [xs(16), y(5)], "POST", "=%s%s:batchUpdate" % (SHEETS, PAGU_ID),
      "={{ JSON.stringify({ requests: $('PDF: hitung baris').first().json.reqInit }) }}"),
    g(D + "cek pulih", [xs(17), y(5)], "GET", "=%s%s?includeGridData=true&ranges={{ encodeURIComponent(\"'BAHAN BAKU ALL'!A1:G600\") }}&fields={{ encodeURIComponent('sheets(data(rowMetadata(hiddenByUser)))') }}" % (SHEETS, PAGU_ID)),
    code(D + "balasan", [xs(18), y(5)], r"""const h = $('PDF: hitung baris').first().json;
const meta = ($json.sheets[0].data[0].rowMetadata || []).map(m => !!(m && m.hiddenByUser));
const now = []; meta.forEach((v, i) => { if (v && i >= 1 && i <= h.last) now.push(i); });
const same = JSON.stringify(now) === JSON.stringify(h.initHidden);
const L = id => 'https://drive.google.com/file/d/' + id + '/view';
let reply = '✅ 3 PDF PAGU DAPUR ' + h.label + ' selesai:\n' +
  'U: ' + L($('PDF: simpan U').first().json.id) + '\n' +
  'S: ' + L($('PDF: simpan S').first().json.id) + '\n' +
  'SAWANGAN: ' + L($('PDF: simpan W').first().json.id);
reply += same ? '\nSheet PAGU DAPUR sudah dikembalikan ke keadaan awal.' : '\n⚠️ Sheet PAGU DAPUR belum kembali persis ke keadaan awal, mohon kabari Claude.';
return [{ json: { reply } }];"""),
    code(emerg, [xs(10), y(7)], "return [{ json: { x: 1 } }];"))
# pulihkan darurat: kembalikan sheet lalu lapor
flow_nodes[-1] = g(emerg, [xs(10), y(7)], "POST", "=%s%s:batchUpdate" % (SHEETS, PAGU_ID),
                   "={{ JSON.stringify({ requests: $('PDF: hitung baris').first().json.reqInit }) }}", err=False)
chain(D + "pulihkan", D + "cek pulih", D + "balasan", "Balas alur")
link(D + "pulihkan", "Lapor gagal", 1); link(D + "cek pulih", "Lapor gagal", 1)
link(emerg, "Lapor gagal", 0)
fail_to_lapor(D + "ambil rencana", D + "baca PAGU")

# ── rotasi (minggu baru)
R = "Rotasi: "
add(drive_list(R + "cari", [xs(0), y(6)], "name contains 'Harga Supplier' and mimeType='application/vnd.google-apps.spreadsheet' and trashed=false"),
    code(R + "hitung", [xs(1), y(6)], r"""const list = $json.files || [];
const cur = list.find(f => f.name.startsWith('[MASTER] Harga Supplier'));
if (!cur) return [{ json: { ok: false, reply: '⚠️ Master "[MASTER] Harga Supplier ..." tidak ditemukan.' } }];
const m = /Harga Supplier\s+(\S+)\s+Week\s*(\d+)/i.exec(cur.name);
if (!m) return [{ json: { ok: false, reply: '⚠️ Nama master tidak bisa dibaca: ' + cur.name } }];
const arg = String($('Siapkan').first().json.arg || '');
let month = m[1], wk = parseInt(m[2], 10) + 1;
const a = /(\S+)\s+week\s*(\d+)/i.exec(arg);
if (a) { month = a[1]; wk = parseInt(a[2], 10); }
else if (wk > 4) return [{ json: { ok: false, reply: 'Setelah ' + m[1] + ' Week ' + m[2] + ' bulannya mungkin ganti. Tulis lengkap, mis: *minggu baru Desember Week 1*' } }];
month = month.charAt(0).toUpperCase() + month.slice(1).toLowerCase();
const arch = 'Harga Supplier ' + m[1] + ' Week ' + m[2];
if (list.some(f => f.name === arch)) return [{ json: { ok: false, reply: 'Arsip "' + arch + '" sudah ada, sepertinya rotasi sudah dilakukan. Master sekarang: ' + cur.name } }];
const newName = '[MASTER] Harga Supplier ' + month + ' Week ' + wk;
return [{ json: { ok: true, id: cur.id, parents: cur.parents || [], arch, newName, oldName: cur.name } }];"""),
    if_ok(R + "ok?", [xs(2), y(6)]),
    g(R + "salin", [xs(3), y(6)], "POST", "=%s/{{ $json.id }}/copy" % DRIVE,
      "={{ JSON.stringify({ name: $json.arch, parents: $json.parents }) }}"),
    g(R + "ganti nama", [xs(4), y(6)], "PATCH", "=%s/{{ $('Rotasi: hitung').first().json.id }}" % DRIVE,
      "={{ JSON.stringify({ name: $('Rotasi: hitung').first().json.newName }) }}"),
    code(R + "balasan", [xs(5), y(6)], r"""const d = $('Rotasi: hitung').first().json;
return [{ json: { reply: '✅ Minggu baru siap.\nArsip: ' + d.arch + '\nMaster aktif: ' + d.newName + '\nLanjut: kirim 2 file RC 0 minggu ini, lalu ketik *proses*.' } }];"""))
chain(R + "cari", R + "hitung", R + "ok?")
link(R + "ok?", R + "salin", 0); link(R + "ok?", "Balas alur", 1)
chain(R + "salin", R + "ganti nama", R + "balasan", "Balas alur")
fail_to_lapor(R + "cari", R + "salin", R + "ganti nama")

add(sw("Perintah", [600, 260], ["proses", "setuju", "pdf", "rotasi", "tes", "batal", "bantuan"]))

def c(a, *outs):
    return {a: {"main": [[{"node": t, "type": "main", "index": 0}] for t in outs]}}
conn = {}
conn.update(c("Webhook agen", "Status: kerja"))
conn.update(c("Status: kerja", "Siapkan"))
conn.update(c("Siapkan", "Perintah"))
conn["Perintah"] = {"main": [[{"node": t, "type": "main", "index": 0}] for t in
    ["Proses: kabar", "Setuju: ambil rencana", "PDF: ambil rencana", "Rotasi: cari", "Tes: cari master", "Batal: hapus", "Bantuan", "Catat (RPC dm_record)"]]}
conn.update(flow_conn)
conn.update(c("Catat (RPC dm_record)", "Ada file untuk Drive?"))
conn["Ada file untuk Drive?"] = {"main": [[{"node": "Siapkan biner", "type": "main", "index": 0}], [{"node": "Susun balasan", "type": "main", "index": 0}]]}
conn.update(c("Siapkan biner", "Unggah ke Drive"))
conn.update(c("Unggah ke Drive", "Susun balasan"))
conn.update(c("Susun balasan", "Ada balasan?"))
conn["Ada balasan?"] = {"main": [[{"node": "Balas ke grup", "type": "main", "index": 0}], [{"node": "Tutup tugas", "type": "main", "index": 0}]]}
conn.update(c("Balas ke grup", "Tutup tugas"))
conn.update(c("Tutup tugas", "Status: santai"))

wf = {"id": "kai_agent_dapurmbg", "name": "agent:" + AGENT, "nodes": nodes + flow_nodes, "connections": conn,
      "active": False, "settings": {"executionOrder": "v1", "errorWorkflow": "kai_sys_error_handler"}, "pinData": {}}
out.write_text(json.dumps(wf, indent=2, ensure_ascii=False) + "\n")
print("ditulis", out)
