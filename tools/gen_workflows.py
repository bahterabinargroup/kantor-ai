#!/usr/bin/env python3
"""Menghasilkan workflow n8n inti ke n8n/workflows/*.json"""
import json, sys, uuid, pathlib

OUT = pathlib.Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)

SUPA = "={{ $env.SUPABASE_URL }}/rest/v1/rpc/"
# Kunci baru Supabase (sb_secret_...) bukan JWT: cukup header apikey.
# Kunci lama (service_role, diawali eyJ) tetap butuh Authorization: Bearer.
SUPA_JSON_HEADERS = (
    "={{ JSON.stringify($env.SUPABASE_SERVICE_KEY.startsWith('eyJ') "
    "? { apikey: $env.SUPABASE_SERVICE_KEY, Authorization: 'Bearer ' + $env.SUPABASE_SERVICE_KEY } "
    ": { apikey: $env.SUPABASE_SERVICE_KEY }) }}"
)
ERR_ID = "kai_sys_error_handler"
N8N = "http://n8n:5678/webhook/"


def nid():
    return str(uuid.uuid4())


def webhook(name, path, pos, response="onReceived"):
    return {"id": nid(), "name": name, "type": "n8n-nodes-base.webhook", "typeVersion": 2,
            "position": pos, "webhookId": nid(),
            "parameters": {"httpMethod": "POST", "path": path, "responseMode": response, "options": {}}}


def http(name, url, body_expr, pos, headers=None, error_output=False):
    params = {"method": "POST", "url": url, "sendBody": True, "specifyBody": "json",
              "jsonBody": body_expr, "options": {}}
    if headers:
        params["sendHeaders"] = True
        params["headerParameters"] = headers
    n = {"id": nid(), "name": name, "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
         "position": pos, "parameters": params,
         # webhook/RPC kadang belum siap beberapa detik setelah n8n restart → coba ulang, jangan langsung gagal
         "retryOnFail": True, "maxTries": 5, "waitBetweenTries": 8000}
    if error_output:
        n["onError"] = "continueErrorOutput"
    return n


def rpc(name, fn, body_expr, pos):
    n = http(name, SUPA + fn, body_expr, pos)
    n["parameters"]["sendHeaders"] = True
    n["parameters"]["specifyHeaders"] = "json"
    n["parameters"]["jsonHeaders"] = SUPA_JSON_HEADERS
    return n


def code(name, js, pos):
    return {"id": nid(), "name": name, "type": "n8n-nodes-base.code", "typeVersion": 2,
            "position": pos, "parameters": {"mode": "runOnceForAllItems", "jsCode": js}}


def if_not_empty(name, expr, pos):
    return {"id": nid(), "name": name, "type": "n8n-nodes-base.if", "typeVersion": 2.2, "position": pos,
            "parameters": {"conditions": {
                "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose"},
                "conditions": [{"id": nid(), "leftValue": expr, "rightValue": "",
                                "operator": {"type": "string", "operation": "notEmpty", "singleValue": True}}],
                "combinator": "and"}, "options": {}}}


def note(text, pos, w=420, h=160, color=4):
    return {"id": nid(), "name": "Catatan " + str(pos[0]), "type": "n8n-nodes-base.stickyNote", "typeVersion": 1,
            "position": pos, "parameters": {"content": text, "width": w, "height": h, "color": color}}


def link(frm, to, out=0):
    return (frm, to, out)


def workflow(fname, name, nodes, links):
    conns = {}
    for frm, to, out in links:
        slot = conns.setdefault(frm, {"main": []})["main"]
        while len(slot) <= out:
            slot.append([])
        slot[out].append({"node": to, "type": "main", "index": 0})
    # ID tetap → skrip bisa mengaktifkan per-ID (n8n 2.x tidak punya --all) dan
    # semua workflow otomatis memakai sys:error-handler (tanpa langkah manual).
    wid = "kai_" + fname[:-5].replace("-", "_")
    # id node/webhook deterministik → file hanya berubah kalau isinya benar-benar berubah
    # (deploy otomatis lalu tidak perlu restart n8n bila workflow tidak berubah)
    for nd in nodes:
        nd["id"] = str(uuid.uuid5(uuid.NAMESPACE_URL, "kantor-ai/" + fname + "/" + nd["name"]))
        def _norm(o, path):
            if isinstance(o, dict):
                for k, v in o.items():
                    if k == "id" and isinstance(v, str) and len(v) == 36:
                        o[k] = str(uuid.uuid5(uuid.NAMESPACE_URL, "kantor-ai/in/" + fname + "/" + nd["name"] + "/" + path))
                    else:
                        _norm(v, path + "." + k)
            elif isinstance(o, list):
                for i, v in enumerate(o):
                    _norm(v, path + "[" + str(i) + "]")
        _norm(nd.get("parameters", {}), "p")
        if "webhookId" in nd:
            nd["webhookId"] = str(uuid.uuid5(uuid.NAMESPACE_URL, "kantor-ai/wh/" + fname + "/" + nd["name"]))
    settings = {"executionOrder": "v1"}
    if wid != ERR_ID:
        settings["errorWorkflow"] = ERR_ID
    wf = {"id": wid, "name": name, "nodes": nodes, "connections": conns, "active": False,
          "settings": settings, "pinData": {}}
    (OUT / fname).write_text(json.dumps(wf, indent=2, ensure_ascii=False) + "\n")


# ───────────────────────── lib:set-status ─────────────────────────
workflow("lib-set-status.json", "lib:set-status", [
    note("**Library: ubah status agen**\nPOST http://n8n:5678/webhook/lib-set-status\n"
         "`{agent_id, status: working|idle|blocked|sleeping, detail?, task_id?}`\n"
         "Menunggu sampai database terupdate sebelum membalas.", [0, -200], 460, 130),
    webhook("Webhook", "lib-set-status", [0, 0], "lastNode"),
    rpc("Set status (RPC)", "set_agent_status",
        "={{ JSON.stringify({ p_agent_id: $json.body.agent_id, p_status: $json.body.status, "
        "p_detail: $json.body.detail || null, p_task_id: $json.body.task_id || null }) }}", [260, 0]),
], [link("Webhook", "Set status (RPC)")])

# ───────────────────────── lib:send-wa ─────────────────────────
workflow("lib-send-wa.json", "lib:send-wa", [
    note("**Library: kirim teks WhatsApp**\nPOST http://n8n:5678/webhook/lib-send-wa\n"
         "`{chat_id, text}` — chat_id = JID (628xx@s.whatsapp.net atau xxx@g.us).\n"
         "Nanti bisa ditambah kirim gambar/video (sendMedia) di sini, satu tempat.", [0, -200], 480, 130),
    webhook("Webhook", "lib-send-wa", [0, 0], "lastNode"),
    http("Kirim via Evolution API",
         "={{ 'http://evolution-api:8080/message/sendText/' + ($json.body.instance || $env.EVOLUTION_INSTANCE) }}",
         "={{ JSON.stringify({ number: $json.body.chat_id, text: $json.body.text, delay: 800 }) }}",
         [260, 0], {"parameters": [{"name": "apikey", "value": "={{ $env.EVOLUTION_API_KEY }}"}]}),
], [link("Webhook", "Kirim via Evolution API")])

# ───────────────────────── 00 · Core WA Router ─────────────────────────
NORMALIZE = r"""// Menyaring & menormalkan webhook Evolution API (messages.upsert)
const item = $input.first().json;

// 1) keamanan: secret di URL webhook
const secret = $env.WEBHOOK_SECRET || '';
if (secret && item.query?.secret !== secret) return [];

// 2) hanya pesan masuk
const body = item.body || {};
const event = String(body.event || '').toLowerCase().replace(/_/g, '.');
if (event !== 'messages.upsert') return [];
const d = body.data || {};
const key = d.key || {};
if (key.fromMe || !key.id) return [];

const chatId = key.remoteJid || '';
if (!chatId || chatId === 'status@broadcast') return [];

// 3) batasi chat/grup yang diizinkan (kosong = semua)
const allowed = ($env.WA_ALLOWED_CHATS || '').split(',').map(s => s.trim()).filter(Boolean);
if (allowed.length && !allowed.includes(chatId)) return [];

const m = d.message || {};
const text = m.conversation || m.extendedTextMessage?.text || m.imageMessage?.caption
          || m.videoMessage?.caption || m.documentMessage?.caption || '';
const media = m.imageMessage || m.videoMessage || m.documentMessage || m.audioMessage || null;

return [{ json: {
  message_id: key.id,
  chat_id: chatId,
  is_group: chatId.endsWith('@g.us'),
  sender: key.participant || d.participant || chatId,
  push_name: d.pushName || '',
  text,
  message_type: d.messageType || Object.keys(m)[0] || 'unknown',
  mimetype: media?.mimetype || null,
  has_mention: ((m.extendedTextMessage?.contextInfo || m.imageMessage?.contextInfo || {}).mentionedJid || []).length > 0,
  is_reply: !!((m.extendedTextMessage?.contextInfo || m.imageMessage?.contextInfo || {}).quotedMessage),
  media_base64: m.base64 || d.base64 || null,   // besar — tidak disimpan ke database
  instance: body.instance || $env.EVOLUTION_INSTANCE || '',
  timestamp: d.messageTimestamp || null,
} }];
"""

BUILD_PAYLOAD = r"""// Gabungkan pesan asli + hasil dispatch menjadi payload untuk agen
const n = $('Normalize').first().json;
const d = $input.first().json;
return [{ json: { ...n, raw_text: n.text, text: d.text, task_id: d.task_id, agent_id: d.agent_id } }];
"""

core_nodes = [
    note("**Pintu masuk semua pesan WhatsApp**\n"
         "Webhook ← Evolution API → Normalize (cek secret, filter chat) → `dispatch_message` "
         "(anti-duplikat + routing + buat tugas, semua di SQL) → panggil webhook agen `agent-<id>`.\n"
         "Tidak ada agen cocok: chat pribadi dapat daftar agen, grup diam.\n"
         "Slot LLM-router (Gemini) bisa dipasang di antara Normalize dan Dispatch nanti.",
         [0, -260], 640, 170),
    webhook("Webhook WA", "wa-incoming", [0, 0]),
    code("Normalize", NORMALIZE, [240, 0]),
    rpc("Dispatch (RPC)", "dispatch_message",
        "={{ JSON.stringify({ p_message_id: $json.message_id, p_chat_id: $json.chat_id, p_is_group: $json.is_group, "
        "p_text: $json.text, p_meta: { sender: $json.sender, push_name: $json.push_name, "
        "message_type: $json.message_type, mimetype: $json.mimetype } }) }}", [480, 0]),
    if_not_empty("Ada tugas?", "={{ $json.task_id }}", [720, 0]),
    code("Build payload agen", BUILD_PAYLOAD, [960, -100]),
    http("Panggil agen", "={{ '" + N8N + "agent-' + $json.agent_id }}", "={{ JSON.stringify($json) }}",
         [1200, -100], error_output=True),
    rpc("Tandai tugas gagal", "finish_task",
        "={{ JSON.stringify({ p_task_id: $('Build payload agen').first().json.task_id, p_status: 'failed', "
        "p_error: 'workflow agen tidak merespons (belum aktif?)' }) }}", [1440, 40]),
    if_not_empty("Chat pribadi?", "={{ $('Normalize').first().json.is_group ? '' : 'x' }}", [1680, 40]),
    http("Beri tahu gagal", N8N + "lib-send-wa",
         "={{ JSON.stringify({ chat_id: $('Normalize').first().json.chat_id, "
         "text: '⚠️ Agen ' + $('Build payload agen').first().json.agent_id + ' belum aktif. Hubungi admin.' }) }}",
         [1920, 20]),
    if_not_empty("Ada balasan?", "={{ $json.reply }}", [960, 120]),
    http("Kirim balasan", N8N + "lib-send-wa",
         "={{ JSON.stringify({ chat_id: $('Normalize').first().json.chat_id, text: $json.reply }) }}",
         [1200, 100]),
]
core_links = [
    link("Webhook WA", "Normalize"), link("Normalize", "Dispatch (RPC)"),
    link("Dispatch (RPC)", "Ada tugas?"),
    link("Ada tugas?", "Build payload agen", 0), link("Ada tugas?", "Ada balasan?", 1),
    link("Build payload agen", "Panggil agen"),
    link("Panggil agen", "Tandai tugas gagal", 1), link("Tandai tugas gagal", "Chat pribadi?"), link("Chat pribadi?", "Beri tahu gagal", 0),
    link("Ada balasan?", "Kirim balasan", 0),
]
workflow("00-core-wa-router.json", "00 · Core WA Router", core_nodes, core_links)

# ───────────────────────── agent:echo (TEMPLATE AGEN) ─────────────────────────
ECHO_WORK = r"""// ← GANTI blok ini dengan pekerjaan agen yang sebenarnya.
// Input: $json.text, $json.chat_id, $json.media_base64, $json.message_type, $json.task_id, ...
const p = $('Webhook agen').first().json.body;
return [{ json: { chat_id: p.chat_id, task_id: p.task_id, reply: '🦜 Echo: ' + (p.text || '(kosong)') } }];
"""
AGENT_ID = "echo"
SET = N8N + "lib-set-status"
echo_nodes = [
    note("**TEMPLATE AGEN** — duplikat workflow ini untuk membuat agen baru.\n"
         "1. Ganti path webhook jadi `agent-<id>`, nama workflow jadi `agent:<id>`\n"
         "2. Ganti `echo` pada node status\n"
         "3. Isi pekerjaan di node 'Kerjakan tugas'\n"
         "4. Daftarkan agen di tabel `agents` (lihat docs/TAMBAH-AGEN.md)\n"
         "Pola tetap: working → kerja → balas → finish_task → idle.",
         [0, -300], 560, 190),
    webhook("Webhook agen", "agent-" + AGENT_ID, [0, 0]),
    http("Status: kerja", SET,
         "={{ JSON.stringify({ agent_id: '" + AGENT_ID + "', status: 'working', "
         "detail: 'Membalas: ' + String($json.body.text || '').slice(0, 60), task_id: $json.body.task_id }) }}",
         [240, 0]),
    {"id": nid(), "name": "Jeda demo 2 dtk", "type": "n8n-nodes-base.wait", "typeVersion": 1.1,
     "position": [480, 0], "parameters": {"amount": 2, "unit": "seconds"}, "webhookId": nid()},
    code("Kerjakan tugas", ECHO_WORK, [720, 0]),
    http("Balas ke WhatsApp", N8N + "lib-send-wa",
         "={{ JSON.stringify({ chat_id: $json.chat_id, text: $json.reply }) }}", [960, 0]),
    rpc("Tutup tugas", "finish_task",
        "={{ JSON.stringify({ p_task_id: $('Kerjakan tugas').first().json.task_id, p_status: 'done', "
        "p_result: { reply: $('Kerjakan tugas').first().json.reply } }) }}", [1200, 0]),
    http("Status: santai", SET,
         "={{ JSON.stringify({ agent_id: '" + AGENT_ID + "', status: 'idle', detail: 'Selesai' }) }}", [1440, 0]),
]
echo_links = [
    link("Webhook agen", "Status: kerja"), link("Status: kerja", "Jeda demo 2 dtk"),
    link("Jeda demo 2 dtk", "Kerjakan tugas"), link("Kerjakan tugas", "Balas ke WhatsApp"),
    link("Balas ke WhatsApp", "Tutup tugas"), link("Tutup tugas", "Status: santai"),
]
workflow("agent-echo.json", "agent:echo", echo_nodes, echo_links)

# ───────────────────────── sys:housekeeping ─────────────────────────
workflow("sys-housekeeping.json", "sys:housekeeping", [
    note("Tiap 10 menit: tugas macet → gagal & agen jadi Macet; agen santai >30 mnt → Tidur; "
         "bersih-bersih data lama.", [0, -180], 440, 100),
    {"id": nid(), "name": "Tiap 10 menit", "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.2,
     "position": [0, 0], "parameters": {"rule": {"interval": [{"field": "minutes", "minutesInterval": 10}]}}},
    rpc("Housekeeping (RPC)", "housekeeping", "={{ JSON.stringify({}) }}", [260, 0]),
], [link("Tiap 10 menit", "Housekeeping (RPC)")])

# ───────────────────────── sys:error-handler ─────────────────────────
ERR = r"""// Nama workflow agen harus berbentuk  agent:<id>  agar error bisa dipetakan ke agennya.
const e = $input.first().json;
const name = e.workflow?.name || '';
const m = name.match(/^agent:([a-z0-9_-]+)/i);
if (!m) return [];   // bukan workflow agen → abaikan (lihat saja di Executions)
const msg = `${e.execution?.lastNodeExecuted || 'node?'}: ${e.execution?.error?.message || 'error'}`;
return [{ json: { agent_id: m[1].toLowerCase(), detail: ('Error — ' + msg).slice(0, 280) } }];
"""
workflow("sys-error-handler.json", "sys:error-handler", [
    note("Pasang di tiap workflow agen: Settings → Error workflow → `sys:error-handler`.\n"
         "Agen yang error otomatis tampil **Macet** (merah) di dashboard.", [0, -180], 460, 100),
    {"id": nid(), "name": "Error Trigger", "type": "n8n-nodes-base.errorTrigger", "typeVersion": 1,
     "position": [0, 0], "parameters": {}},
    code("Petakan ke agen", ERR, [240, 0]),
    http("Status: macet", N8N + "lib-set-status",
         "={{ JSON.stringify({ agent_id: $json.agent_id, status: 'blocked', detail: $json.detail }) }}", [480, 0]),
], [link("Error Trigger", "Petakan ke agen"), link("Petakan ke agen", "Status: macet")])

# ───────────────────────── sys:wa-watchdog ─────────────────────────
# Evolution API dilaporkan kadang mengosongkan konfigurasi webhook setelah container restart
# (github.com/evolution-foundation/evolution-api/issues/2694). Tanpa penjaga, bot diam tanpa error.
EVO = "http://evolution-api:8080/webhook/"
get_hook = {"id": nid(), "name": "Cek webhook", "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
            "position": [260, 0], "alwaysOutputData": True, "onError": "continueRegularOutput",
            "parameters": {"method": "GET", "url": "={{ '" + EVO + "find/' + $env.EVOLUTION_INSTANCE }}",
                           "sendHeaders": True,
                           "headerParameters": {"parameters": [{"name": "apikey", "value": "={{ $env.EVOLUTION_API_KEY }}"}]},
                           "options": {}}}
workflow("sys-wa-watchdog.json", "sys:wa-watchdog", [
    note("Tiap 5 menit: cek webhook Evolution. Kalau URL-nya kosong (bug setelah restart), pasang ulang.",
         [0, -180], 460, 90),
    {"id": nid(), "name": "Tiap 5 menit", "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.2,
     "position": [0, 0], "parameters": {"rule": {"interval": [{"field": "minutes", "minutesInterval": 5}]}}},
    get_hook,
    if_not_empty("Webhook terpasang?", "={{ $json.url }}", [520, 0]),
    http("Pasang ulang webhook", "={{ '" + EVO + "set/' + $env.EVOLUTION_INSTANCE }}",
         "={{ JSON.stringify({ enabled: true, url: 'http://n8n:5678/webhook/wa-incoming?secret=' + $env.WEBHOOK_SECRET, "
         "webhookByEvents: false, webhookBase64: true, events: ['MESSAGES_UPSERT'] }) }}",
         [780, 100], {"parameters": [{"name": "apikey", "value": "={{ $env.EVOLUTION_API_KEY }}"}]}),
], [link("Tiap 5 menit", "Cek webhook"), link("Cek webhook", "Webhook terpasang?"),
    link("Webhook terpasang?", "Pasang ulang webhook", 1)])


# ───────────────────────── agent:ipal ─────────────────────────
IPAL_REPLY = r"""// Susun balasan dari hasil ipal_record_report. Diam kalau bukan laporan (obrolan biasa / foto tanpa caption).
const p = $('Webhook agen').first().json.body;
const r = $input.first().json || {};
const rawText = String(p.raw_text || '').trim();
const payloadMedia = !!(p.mimetype && /^(image|video)\//.test(p.mimetype)) || /^(image|video)Message$/.test(p.message_type || '');
const hasMedia = (r.has_media !== undefined) ? !!r.has_media : payloadMedia;
let reply = '';
if (r.pending_media) reply = '';   // foto tanpa caption: tunggu teks nama dapur (maks 20 menit), jangan ganggu grup
else if (r.matched && r.duplicate) reply = '';
else if (r.matched && !hasMedia) reply = '';   // teks saja: tunggu foto 20 menit; sys:ipal-incomplete yang mengumumkan kalau tak datang
else if (r.matched) reply = '';   // konfirmasi ✅ dikirim sys:ipal-ack setelah pengirim diam 2 menit (foto/video lanjutan)
else if (r.ambiguous && payloadMedia && rawText) reply = '❓ Caption menyebut lebih dari satu dapur. Mohon kirim ulang dengan satu nama dapur saja.';
else if (payloadMedia && rawText) reply = '❓ Nama dapur tidak terbaca di caption. Mohon tulis nama dapur, mis. "IPAL Grabag".';
return [{ json: { chat_id: p.chat_id, task_id: p.task_id, reply, matched: !!r.matched } }];
"""
IPAL_PREP = r"""// Obrolan biasa bukan laporan: teks tanpa foto yang me-mention/membalas orang atau lebih dari 40 kata diabaikan.
const p = $('Webhook agen').first().json.body;
const media = !!(p.mimetype && /^(image|video)\//.test(p.mimetype)) || /^(image|video)Message$/.test(p.message_type || '');
const raw = String(p.raw_text || '').trim();
const words = raw.split(/\s+/).filter(Boolean).length;
const reminder = /pengingat|belum\s+(lapor|report|kirim|setor)|tolong\s+(lapor|kirim)/i.test(raw);   // pesan pengingat/sosialisasi dari admin bukan laporan
const chatter = !media && (p.has_mention || p.is_reply || words > 40 || reminder);
return [{ json: { p_message_id: p.message_id, p_chat_id: p.chat_id, p_text: chatter ? '' : raw,
                  p_has_media: media, p_sender: p.sender } }];
"""
IP = "ipal"
ipal_nodes = [
    note("**Agen IPAL** — dipicu pesan grup yang memuat nama dapur/kecamatan atau kata 'ipal'.\n"
         "Foto + caption → `ipal_record_report` (cocokkan nama, catat SUDAH hari ini, WIB) → balas singkat.\n"
         "Teks dan foto dari pengirim yang sama (≤20 mnt, urutan bebas) digabung. Foto tanpa caption: ditahan diam-diam.", [0, -300], 560, 150),
    webhook("Webhook agen", "agent-" + IP, [0, 0]),
    http("Status: kerja", SET,
         "={{ JSON.stringify({ agent_id: '" + IP + "', status: 'working', detail: 'Mencatat laporan dapur', "
         "task_id: $json.body.task_id }) }}", [240, 0]),
    code("Siapkan data", IPAL_PREP, [480, 0]),
    rpc("Catat laporan (RPC)", "ipal_record_report", "={{ JSON.stringify($json) }}", [720, 0]),
    code("Susun balasan", IPAL_REPLY, [960, 0]),
    if_not_empty("Ada balasan?", "={{ $json.reply }}", [1200, 0]),
    http("Balas ke grup", N8N + "lib-send-wa",
         "={{ JSON.stringify({ chat_id: $json.chat_id, text: $json.reply }) }}", [1440, -80]),
    rpc("Tutup tugas", "finish_task",
        "={{ JSON.stringify({ p_task_id: $('Susun balasan').first().json.task_id, p_status: 'done', "
        "p_result: { matched: $('Susun balasan').first().json.matched } }) }}", [1680, 0]),
    http("Status: santai", SET,
         "={{ JSON.stringify({ agent_id: '" + IP + "', status: 'idle', detail: 'Selesai' }) }}", [1920, 0]),
]
ipal_links = [
    link("Webhook agen", "Status: kerja"), link("Status: kerja", "Siapkan data"), link("Siapkan data", "Catat laporan (RPC)"),
    link("Catat laporan (RPC)", "Susun balasan"), link("Susun balasan", "Ada balasan?"),
    link("Ada balasan?", "Balas ke grup", 0), link("Ada balasan?", "Tutup tugas", 1),
    link("Balas ke grup", "Tutup tugas"), link("Tutup tugas", "Status: santai"),
]
workflow("agent-ipal.json", "agent:ipal", ipal_nodes, ipal_links)

# ───────────────────────── sys:ipal-reminder ─────────────────────────
workflow("sys-ipal-reminder.json", "sys:ipal-reminder", [
    note("Dua pengingat ke grup (IPAL_GROUP_JID di .env):\n"
         "• 17:00 WIB (Senin–Jumat): dapur yang BELUM lapor hari ini.\n"
         "• 06:00 WIB (Selasa–Sabtu): dapur yang KEMARIN tidak lapor sama sekali.\n"
         "Semua sudah lapor → tidak kirim apa-apa.", [0, -220], 460, 130),
    {"id": nid(), "name": "17:00 WIB", "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.2,
     "position": [0, 0], "parameters": {"rule": {"interval": [{"field": "cronExpression", "expression": "0 17 * * 1-5"}]}}},
    {"id": nid(), "name": "06:00 WIB", "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.2,
     "position": [0, 220], "parameters": {"rule": {"interval": [{"field": "cronExpression", "expression": "0 6 * * 2-6"}]}}},
    rpc("Belum lapor hari ini (RPC)", "ipal_pending_today", "={{ JSON.stringify({}) }}", [260, 0]),
    rpc("Belum lapor kemarin (RPC)", "ipal_pending_yesterday", "={{ JSON.stringify({}) }}", [260, 220]),
    if_not_empty("Ada yang belum?", "={{ $json.reply }}", [540, 100]),
    http("Kirim pengingat", N8N + "lib-send-wa",
         "={{ JSON.stringify({ chat_id: $env.IPAL_GROUP_JID, text: $json.reply }) }}", [800, 40]),
], [link("17:00 WIB", "Belum lapor hari ini (RPC)"), link("06:00 WIB", "Belum lapor kemarin (RPC)"),
    link("Belum lapor hari ini (RPC)", "Ada yang belum?"), link("Belum lapor kemarin (RPC)", "Ada yang belum?"),
    link("Ada yang belum?", "Kirim pengingat", 0)])
_p = OUT / "sys-ipal-reminder.json"
_w = json.loads(_p.read_text()); _w["settings"]["timezone"] = "Asia/Jakarta"
_p.write_text(json.dumps(_w, indent=2, ensure_ascii=False) + "\n")


# ───────────────────────── sys:ipal-incomplete ─────────────────────────
workflow("sys-ipal-incomplete.json", "sys:ipal-incomplete", [
    note("Tiap 5 menit: teks nama dapur tanpa foto (atau foto tanpa nama dapur) yang tidak berpasangan "
         "setelah 20 menit → satu pengumuman 'laporan tidak lengkap' ke grup. Sekali saja per laporan.",
         [0, -180], 480, 100),
    {"id": nid(), "name": "Tiap 5 menit", "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.2,
     "position": [0, 0], "parameters": {"rule": {"interval": [{"field": "minutes", "minutesInterval": 5}]}}},
    rpc("Cek tidak lengkap (RPC)", "ipal_incomplete_notices", "={{ JSON.stringify({ p_minutes: 20 }) }}", [260, 0]),
    if_not_empty("Ada yang tidak lengkap?", "={{ $json.reply }}", [520, 0]),
    http("Umumkan", N8N + "lib-send-wa",
         "={{ JSON.stringify({ chat_id: $env.IPAL_GROUP_JID, text: $json.reply }) }}", [780, -60]),
], [link("Tiap 5 menit", "Cek tidak lengkap (RPC)"), link("Cek tidak lengkap (RPC)", "Ada yang tidak lengkap?"),
    link("Ada yang tidak lengkap?", "Umumkan", 0)])


# ───────────────────────── sys:ipal-ack ─────────────────────────
workflow("sys-ipal-ack.json", "sys:ipal-ack", [
    note("Tiap menit: konfirmasi ✅ laporan IPAL dikirim SETELAH pengirim diam 2 menit "
         "(supaya foto/video lanjutan yang masih dikirim tidak terpotong). Satu pesan per dapur.",
         [0, -180], 480, 100),
    {"id": nid(), "name": "Tiap menit", "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.2,
     "position": [0, 0], "parameters": {"rule": {"interval": [{"field": "minutes", "minutesInterval": 1}]}}},
    rpc("Cek konfirmasi (RPC)", "ipal_pending_acks", "={{ JSON.stringify({ p_quiet_minutes: 2 }) }}", [260, 0]),
    if_not_empty("Ada konfirmasi?", "={{ $json.reply }}", [520, 0]),
    http("Kirim konfirmasi", N8N + "lib-send-wa",
         "={{ JSON.stringify({ chat_id: $env.IPAL_GROUP_JID, text: $json.reply }) }}", [780, -60]),
], [link("Tiap menit", "Cek konfirmasi (RPC)"), link("Cek konfirmasi (RPC)", "Ada konfirmasi?"),
    link("Ada konfirmasi?", "Kirim konfirmasi", 0)])


# ───────────────────────── sys:outbox ─────────────────────────
workflow("sys-outbox.json", "sys:outbox", [
    note("Tiap menit: kirim pesan yang antre di tabel wa_outbox ke WhatsApp lewat bot. "
         "Untuk mengirim pesan dari mana pun: INSERT (chat_id, text) ke wa_outbox.",
         [0, -180], 480, 100),
    {"id": nid(), "name": "Tiap menit", "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.2,
     "position": [0, 0], "parameters": {"rule": {"interval": [{"field": "minutes", "minutesInterval": 1}]}}},
    rpc("Ambil pesan antre (RPC)", "outbox_claim", "={{ JSON.stringify({ p_limit: 5 }) }}", [260, 0]),
    if_not_empty("Ada pesan?", "={{ $json.chat_id }}", [520, 0]),
    http("Kirim pesan", N8N + "lib-send-wa",
         "={{ JSON.stringify({ chat_id: $json.chat_id, text: $json.text }) }}", [780, -60]),
], [link("Tiap menit", "Ambil pesan antre (RPC)"), link("Ambil pesan antre (RPC)", "Ada pesan?"),
    link("Ada pesan?", "Kirim pesan", 0)])


# ───────────────────────── ctl:agent-toggle (tombol dashboard) ─────────────────────────
workflow("ctl-agent-toggle.json", "ctl:agent-toggle", [
    note("Dipanggil tombol Nyala/Mati di dashboard (POST /api/agent-toggle → Caddy → webhook ini).\n"
         "Hanya bisa dicapai lewat dashboard (basic_auth); diblokir dari domain n8n publik.\n"
         "Body: {agent_id, enabled}", [0, -200], 480, 110),
    webhook("Webhook", "ctl-agent-toggle", [0, 0], "lastNode"),
    rpc("Nyalakan/matikan (RPC)", "set_agent_enabled",
        "={{ JSON.stringify({ p_agent_id: String($json.body.agent_id || ''), p_enabled: $json.body.enabled === true }) }}",
        [260, 0]),
], [link("Webhook", "Nyalakan/matikan (RPC)")])

# ───────────────────────── ctl:agent-profile (ubah nama/logo/warna dari dashboard) ─────────────────────────
workflow("ctl-agent-profile.json", "ctl:agent-profile", [
    note("Dipanggil form 'Ubah' di dashboard (POST /api/agent-profile → Caddy → webhook ini).\n"
         "Body: {agent_id, name, emoji, color}. Hanya lewat dashboard (basic_auth).", [0, -200], 480, 100),
    webhook("Webhook", "ctl-agent-profile", [0, 0], "lastNode"),
    rpc("Ubah profil (RPC)", "update_agent_profile",
        "={{ JSON.stringify({ p_agent_id: String($json.body.agent_id || ''), p_name: $json.body.name || null, "
        "p_emoji: $json.body.emoji || null, p_color: $json.body.color || null }) }}", [260, 0]),
], [link("Webhook", "Ubah profil (RPC)")])

print("OK:", ", ".join(sorted(p.name for p in OUT.glob("*.json"))))
