# Menambah Agen Baru

Satu agen = **1 baris di tabel `agents`** + **1 workflow n8n** bernama `agent:<id>`. Tidak ada kode lain yang diubah.

## Kontrak

| | Aturan |
|---|---|
| `id` | huruf kecil/angka/`-`/`_`, mis. `akuntan` |
| Workflow | nama `agent:<id>`, pemicu **Webhook POST** dengan path `agent-<id>` |
| Input webhook (`$json.body`) | `task_id, agent_id, text, chat_id, is_group, sender, push_name, message_id, message_type, mimetype, media_base64, instance` |
| Awal | panggil `lib-set-status` → `working` (sertakan `task_id`, `detail` singkat) |
| Balas | panggil `lib-send-wa` → `{chat_id, text}` |
| Akhir | RPC `finish_task` (`done`/`failed`) → `lib-set-status` → `idle` |
| Error | Otomatis: duplikat `agent:echo` mewarisi *Error workflow* `sys:error-handler` (agen jadi *Macet*). Cek di Settings workflow bila membuat dari nol. |

`media_base64` besar dan tidak disimpan ke database; simpan hasil olahan (JSON terstruktur) saja.

## Langkah

1. **Daftarkan agen** (SQL Editor Supabase):
   ```sql
   insert into agents (id, name, role, emoji, triggers, priority)
   values ('akuntan', 'Akuntan', 'Rekap nota & kas', '🧾', array['nota','omset'], 10);
   ```
   `triggers` = kata kunci yang memicu agen tanpa perintah. Selain itu `/akuntan …` selalu memicunya.
   Contoh siap pakai untuk 4 modul awal: `supabase/seed_agents_contoh.sql`.
2. **Duplikat `agent:echo`** di n8n → ganti nama jadi `agent:akuntan`, path webhook jadi `agent-akuntan`, dan `echo` pada dua node status jadi `akuntan`.
3. **Ganti node `Kerjakan tugas`** dengan pekerjaan agen (HTTP ke Gemini/Claude, Browserless, dsb.). Hapus node `Jeda demo`.
4. **Aktifkan** workflow (tombol Publish/Active).
5. Uji: `/akuntan tes`. Lihat kartunya di dashboard.

Menonaktifkan sementara: `update agents set enabled=false where id='akuntan';`

## Bahan yang sudah tersedia untuk agen

- **LLM**: `$env.GEMINI_API_KEY`, `$env.ANTHROPIC_API_KEY` (isi di `.env`).
- **Browser**: Playwright/Puppeteer terhubung ke `ws://browserless:3000?token={{ $env.BROWSERLESS_TOKEN }}`.
- **Memori agen**: tabel `agent_memory` (key-value per agen) lewat REST Supabase dengan service key.
- **Log progres**: RPC `log_event` (`p_agent_id, p_event, p_message`) untuk langkah antara, mis. "OCR selesai".
- **Agen memanggil agen**: POST ke `http://n8n:5678/webhook/agent-<id>` dengan payload yang sama (buat baris di `tasks` lewat RPC bila perlu dilacak).
