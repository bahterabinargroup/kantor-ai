#!/usr/bin/env python3
"""Membuat n8n/workflows/agent-akuntan.json dari kode di n8n/src/*.js.
Jalankan dari akar proyek:  python3 n8n/src/gen_akuntan.py
"""
import json, uuid, pathlib

root = pathlib.Path(__file__).resolve().parents[2]
src = root / "n8n" / "src"
out = root / "n8n" / "workflows" / "agent-akuntan.json"
ns = uuid.UUID("6f1c2a54-9d3e-4b7a-8c10-a1b2c3d4e5f6")
def nid(name): return str(uuid.uuid5(ns, name))

HDR = "={{ JSON.stringify($env.SUPABASE_SERVICE_KEY.startsWith('eyJ') ? { apikey: $env.SUPABASE_SERVICE_KEY, Authorization: 'Bearer ' + $env.SUPABASE_SERVICE_KEY } : { apikey: $env.SUPABASE_SERVICE_KEY }) }}"
def js(f): return (src / f).read_text()

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
                "={{ JSON.stringify({ agent_id: 'akuntan', status: '%s', detail: '%s'%s }) }}" % (st, detail, t))

def code(name, pos, f): return node(name, "n8n-nodes-base.code", 2, pos, {"jsCode": js(f)})

def if_node(name, pos, left, op):
    return node(name, "n8n-nodes-base.if", 2.2, pos, {
        "conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose"},
            "conditions": [{"id": nid(name + "-c"), "leftValue": left, "rightValue": "",
                            "operator": {"type": "string", "operation": op, "singleValue": True}}],
            "combinator": "and"}, "options": {}})

nodes = [
 node("Catatan 0", "n8n-nodes-base.stickyNote", 1, [0, -320], {"content":
   "**Agen Akuntan** — mencatat pemasukan (foto lembar harian) dan pengeluaran (teks laporan + foto nota) kafe Berdikari.\n"
   "Foto dibaca model penglihat Claude (`ANTHROPIC_API_KEY`, model `AKUNTAN_MODEL`) → `akun_handle` (RPC) → balasan singkat ke grup.\n"
   "Foto TIDAK disimpan di server. Nominal tidak masuk log dashboard (`redact_events`). `/akuntan rekap [kemarin|9 nov]` = rekap manual.",
   "width": 620, "height": 170, "color": 5}),
 node("Webhook agen", "n8n-nodes-base.webhook", 2, [0, 0],
   {"httpMethod": "POST", "path": "agent-akuntan", "responseMode": "onReceived", "options": {}},
   webhookId=nid("webhook-akuntan")),
 status("Status: kerja", [240, 0], "working", "Mencatat laporan kafe", True),
 code("Siapkan", [480, 0], "siapkan.js"),
 node("Perlu baca foto?", "n8n-nodes-base.if", 2.2, [720, 0], {
   "conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose"},
     "conditions": [{"id": nid("pbf-c"), "leftValue": "={{ $json.need_vision }}", "rightValue": "",
       "operator": {"type": "boolean", "operation": "true", "singleValue": True}}], "combinator": "and"}, "options": {}}),
 node("Baca foto (Claude)", "n8n-nodes-base.httpRequest", 4.2, [960, -80], {
   "method": "POST", "url": "={{ ($env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com').replace(/\\/+$/, '') + '/v1/messages' }}",
   "sendHeaders": True, "specifyHeaders": "json",
   "jsonHeaders": "={{ JSON.stringify({ 'x-api-key': $env.ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' }) }}",
   "sendBody": True, "specifyBody": "json", "jsonBody": "={{ JSON.stringify($json.vision_body) }}",
   "options": {"timeout": 120000}}, onError="continueRegularOutput"),
 code("Olah hasil", [1200, 0], "olah.js"),
 http("Catat (RPC akun_handle)", [1440, 0], "={{ $env.SUPABASE_URL }}/rest/v1/rpc/akun_handle", "={{ JSON.stringify({ p: $json.p }) }}", supabase=True),
 code("Susun balasan", [1680, 0], "balasan.js"),
 if_node("Ada balasan?", [1920, 0], "={{ $json.reply }}", "notEmpty"),
 http("Balas ke grup", [2160, -80], "http://n8n:5678/webhook/lib-send-wa",
      "={{ JSON.stringify({ chat_id: $json.chat_id, text: $json.reply }) }}"),
 http("Tutup tugas", [2400, 0], "={{ $env.SUPABASE_URL }}/rest/v1/rpc/finish_task",
      "={{ JSON.stringify({ p_task_id: $('Susun balasan').first().json.task_id, p_status: $('Susun balasan').first().json.failed ? 'failed' : 'done', p_result: { kind: $('Susun balasan').first().json.kind }, p_error: $('Susun balasan').first().json.error }) }}",
      supabase=True),
 status("Status: santai", [2640, 0], "idle", "Selesai", False),
]

def c(a, *outs):
    return {a: {"main": [[{"node": t, "type": "main", "index": 0}] for t in outs]}}
conn = {}
conn.update(c("Webhook agen", "Status: kerja"))
conn.update(c("Status: kerja", "Siapkan"))
conn.update(c("Siapkan", "Perlu baca foto?"))
conn["Perlu baca foto?"] = {"main": [[{"node": "Baca foto (Claude)", "type": "main", "index": 0}], [{"node": "Olah hasil", "type": "main", "index": 0}]]}
conn.update(c("Baca foto (Claude)", "Olah hasil"))
conn.update(c("Olah hasil", "Catat (RPC akun_handle)"))
conn.update(c("Catat (RPC akun_handle)", "Susun balasan"))
conn.update(c("Susun balasan", "Ada balasan?"))
conn["Ada balasan?"] = {"main": [[{"node": "Balas ke grup", "type": "main", "index": 0}], [{"node": "Tutup tugas", "type": "main", "index": 0}]]}
conn.update(c("Balas ke grup", "Tutup tugas"))
conn.update(c("Tutup tugas", "Status: santai"))

wf = {"id": "kai_agent_akuntan", "name": "agent:akuntan", "nodes": nodes, "connections": conn,
      "active": False, "settings": {"executionOrder": "v1", "errorWorkflow": "kai_sys_error_handler"}, "pinData": {}}
out.write_text(json.dumps(wf, indent=2, ensure_ascii=False) + "\n")
print("ditulis", out)
