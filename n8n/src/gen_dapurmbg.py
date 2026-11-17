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

def if_node(name, pos, left, op):
    return node(name, "n8n-nodes-base.if", 2.2, pos, {
        "conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose"},
            "conditions": [{"id": nid(name + "-c"), "leftValue": left, "rightValue": "",
                            "operator": {"type": "string", "operation": op, "singleValue": True}}],
            "combinator": "and"}, "options": {}})

SIAPKAN = r"""// Ambil pesan dari payload agen dan bentuk parameter untuk dm_record.
// Isi file (base64) hanya dibawa untuk dokumen dan dibatasi ukurannya (8 MB sebelum base64).
const p = $('Webhook agen').first().json.body;
const MAX_B64 = 11 * 1024 * 1024;
const isDoc = /^document/i.test(p.message_type || '') ||
  /(spreadsheet|excel|csv|pdf|msword|officedocument)/i.test(p.mimetype || '');
let b64 = isDoc ? (p.media_base64 || null) : null;
let tooBig = false;
if (b64 && b64.length > MAX_B64) { b64 = null; tooBig = true; }
return [{ json: {
  task_id: p.task_id, chat_id: p.chat_id, too_big: tooBig,
  p: {
    message_id: p.message_id, chat_id: p.chat_id, sender: p.sender, push_name: p.push_name,
    text: p.raw_text ?? p.text ?? '', message_type: p.message_type, mimetype: p.mimetype,
    media_base64: b64,
  },
} }];
"""

BALASAN = r"""// Susun balasan singkat dari hasil dm_record. Diam kalau tidak ada balasan.
const s = $('Siapkan').first().json;
const r = Array.isArray($input.first().json) ? $input.first().json[0] : $input.first().json;
const res = (r && typeof r === 'object' && 'reply' in r) ? r : (r?.dm_record || r || {});
let reply = res.reply || null;
if (s.too_big) reply = '⚠️ File terlalu besar untuk dicatat (maks sekitar 8 MB). Coba kirim ulang yang lebih kecil.';
return [{ json: { chat_id: s.chat_id, task_id: s.task_id, reply, kind: res.kind || 'text' } }];
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
 code("Susun balasan", [960, 0], BALASAN),
 if_node("Ada balasan?", [1200, 0], "={{ $json.reply }}", "notEmpty"),
 http("Balas ke grup", [1440, -80], "http://n8n:5678/webhook/lib-send-wa",
      "={{ JSON.stringify({ chat_id: $json.chat_id, text: $json.reply }) }}"),
 http("Tutup tugas", [1680, 0], "={{ $env.SUPABASE_URL }}/rest/v1/rpc/finish_task",
      "={{ JSON.stringify({ p_task_id: $('Susun balasan').first().json.task_id, p_status: 'done', p_result: { kind: $('Susun balasan').first().json.kind } }) }}",
      supabase=True),
 status("Status: santai", [1920, 0], "idle", "Selesai", False),
]

def c(a, *outs):
    return {a: {"main": [[{"node": t, "type": "main", "index": 0}] for t in outs]}}
conn = {}
conn.update(c("Webhook agen", "Status: kerja"))
conn.update(c("Status: kerja", "Siapkan"))
conn.update(c("Siapkan", "Catat (RPC dm_record)"))
conn.update(c("Catat (RPC dm_record)", "Susun balasan"))
conn.update(c("Susun balasan", "Ada balasan?"))
conn["Ada balasan?"] = {"main": [[{"node": "Balas ke grup", "type": "main", "index": 0}], [{"node": "Tutup tugas", "type": "main", "index": 0}]]}
conn.update(c("Balas ke grup", "Tutup tugas"))
conn.update(c("Tutup tugas", "Status: santai"))

wf = {"id": "kai_agent_dapurmbg", "name": "agent:" + AGENT, "nodes": nodes, "connections": conn,
      "active": False, "settings": {"executionOrder": "v1", "errorWorkflow": "kai_sys_error_handler"}, "pinData": {}}
out.write_text(json.dumps(wf, indent=2, ensure_ascii=False) + "\n")
print("ditulis", out)
