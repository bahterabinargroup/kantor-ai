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

SIAPKAN = r"""// Ambil pesan dari payload agen dan bentuk parameter untuk dm_record.
// Isi file (base64) tidak disimpan di database; hanya file tabel diunggah ke Drive (maks sekitar 8 MB).
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
// Nama file tidak dibawa WhatsApp ke sini: pakai keterangan (caption) + waktu WIB.
const wib = new Date(Date.now() + 7 * 3600 * 1000).toISOString().slice(0, 16).replace('T', ' ').replace(':', '');
const cap = String(p.raw_text ?? p.text ?? '').replace(/[^A-Za-z0-9 _.-]/g, '').trim().slice(0, 40);
const fileName = ('RC0 ' + (cap ? cap + ' ' : '') + wib + '.' + ext);
return [{ json: {
  task_id: p.task_id, chat_id: p.chat_id, too_big: tooBig,
  upload: !!b64 && !tooBig, b64: tooBig ? null : b64, file_name: fileName, mime,
  p: {
    message_id: p.message_id, chat_id: p.chat_id, sender: p.sender, push_name: p.push_name,
    text: p.raw_text ?? p.text ?? '', message_type: p.message_type, mimetype: p.mimetype,
  },
} }];
"""

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
  if (d && d.id && !d.error) reply = '✅ File tersimpan di Drive (folder RC 0): ' + s.file_name + '
' + (res.reply || '');
  else reply = '⚠️ File diterima tapi gagal disimpan ke Drive. Saya catat dulu, mohon kabari Claude.
' + (res.reply || '');
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
   "Pekerjaan Google (master harga, PDF PAGU) dijalankan lewat sesi Claude dengan skill DAPUR MBG, "
   "hasilnya dikirim kembali ke grup lewat `wa_outbox`.\n"
   "Nama tampil bisa diubah dari dashboard; id teknis tetap `dapurmbg`.",
   "width": 620, "height": 190, "color": 4}),
 node("Webhook agen", "n8n-nodes-base.webhook", 2, [0, 0],
   {"httpMethod": "POST", "path": "agent-" + AGENT, "responseMode": "onReceived", "options": {}},
   webhookId=nid("webhook")),
 status("Status: kerja", [240, 0], "working", "Mencatat pesan grup", True),
 code("Siapkan", [480, 0], SIAPKAN),
 http("Catat (RPC dm_record)", [720, 0], "={{ $env.SUPABASE_URL }}/rest/v1/rpc/dm_record",
      "={{ JSON.stringify({ p: $json.p }) }}", supabase=True),
 if_node("Ada file untuk Drive?", [960, 0], "={{ $json.upload }}", "true", "boolean"),
 code("Siapkan biner", [1200, -120], BIN),
 node("Unggah ke Drive", "n8n-nodes-base.googleDrive", 3, [1440, -120], {
   "authentication": "serviceAccount", "resource": "file", "operation": "upload",
   "inputDataFieldName": "data", "name": "={{ $json.file_name }}",
   "driveId": {"__rl": True, "mode": "list", "value": "My Drive"},
   "folderId": {"__rl": True, "mode": "id", "value": "1WEVt0170RsXi3aB-OCrH-DnGExw-LH6T"},
   "options": {}},
   credentials={"googleApi": {"id": "aobybr8432rdzXGw", "name": "Google Drive - Kantor AI"}},
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

def c(a, *outs):
    return {a: {"main": [[{"node": t, "type": "main", "index": 0}] for t in outs]}}
conn = {}
conn.update(c("Webhook agen", "Status: kerja"))
conn.update(c("Status: kerja", "Siapkan"))
conn.update(c("Siapkan", "Catat (RPC dm_record)"))
conn.update(c("Catat (RPC dm_record)", "Ada file untuk Drive?"))
conn["Ada file untuk Drive?"] = {"main": [[{"node": "Siapkan biner", "type": "main", "index": 0}], [{"node": "Susun balasan", "type": "main", "index": 0}]]}
conn.update(c("Siapkan biner", "Unggah ke Drive"))
conn.update(c("Unggah ke Drive", "Susun balasan"))
conn.update(c("Susun balasan", "Ada balasan?"))
conn["Ada balasan?"] = {"main": [[{"node": "Balas ke grup", "type": "main", "index": 0}], [{"node": "Tutup tugas", "type": "main", "index": 0}]]}
conn.update(c("Balas ke grup", "Tutup tugas"))
conn.update(c("Tutup tugas", "Status: santai"))

wf = {"id": "kai_agent_dapurmbg", "name": "agent:" + AGENT, "nodes": nodes, "connections": conn,
      "active": False, "settings": {"executionOrder": "v1", "errorWorkflow": "kai_sys_error_handler"}, "pinData": {}}
out.write_text(json.dumps(wf, indent=2, ensure_ascii=False) + "\n")
print("ditulis", out)
