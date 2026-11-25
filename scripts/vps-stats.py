#!/usr/bin/env python3
"""Catat kondisi VPS (CPU, memori, disk, jaringan, kontainer) tiap menit → ~/kantor-ai/data/vps/ (dibaca halaman /vps.html).
Dijalankan cron (lihat pasang-vps-stats.sh). Hanya membaca; tidak mengubah apa pun di server."""
import json, os, platform, shutil, subprocess, time

OUT = os.path.expanduser("~/kantor-ai/data/vps")
LATEST, HIST, STATE = f"{OUT}/latest.json", f"{OUT}/history.jsonl", f"{OUT}/.state.json"
KEEP = 2880  # 48 jam @ 1 menit
os.makedirs(OUT, exist_ok=True)
now = int(time.time())

def rd(p, d=""):
    try:
        return open(p).read()
    except Exception:
        return d

def sh(cmd, t=20):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t).stdout
    except Exception:
        return ""

try:
    st = json.loads(rd(STATE, "{}"))
except Exception:
    st = {}

# ── CPU (selisih /proc/stat sejak pencatatan terakhir) ──
f = list(map(int, rd("/proc/stat").split("\n")[0].split()[1:]))
idle, total = f[3] + f[4], sum(f)
cpu = 0.0
if "cpu" in st and total > st["cpu"][1]:
    di, dt = idle - st["cpu"][0], total - st["cpu"][1]
    cpu = round(100.0 * (1 - di / dt), 1)

# ── Jaringan (byte/detik, semua antarmuka selain lo & docker) ──
rx = tx = 0
for line in rd("/proc/net/dev").split("\n")[2:]:
    if ":" not in line:
        continue
    name, data = line.split(":", 1)
    name = name.strip()
    if name == "lo" or name.startswith(("docker", "br-", "veth")):
        continue
    v = data.split()
    rx += int(v[0]); tx += int(v[8])
rxs = txs = 0.0
if "net" in st and now > st["t"]:
    dt = now - st["t"]
    rxs, txs = max(0, rx - st["net"][0]) / dt, max(0, tx - st["net"][1]) / dt

# ── Memori ──
mi = {}
for line in rd("/proc/meminfo").split("\n"):
    if ":" in line:
        k, v = line.split(":", 1)
        mi[k] = int(v.split()[0]) * 1024
mem_total, mem_avail = mi.get("MemTotal", 0), mi.get("MemAvailable", 0)
mem_used = mem_total - mem_avail
swap_total, swap_used = mi.get("SwapTotal", 0), mi.get("SwapTotal", 0) - mi.get("SwapFree", 0)

# ── Disk, beban, uptime ──
du = shutil.disk_usage("/")
load = os.getloadavg()
up = float(rd("/proc/uptime", "0 0").split()[0])

# ── Info dasar (jarang berubah) ──
cpuinfo = rd("/proc/cpuinfo")
model = next((l.split(":", 1)[1].strip() for l in cpuinfo.split("\n") if l.startswith("model name")), "?")
osname = next((l.split("=", 1)[1].strip().strip('"') for l in rd("/etc/os-release").split("\n") if l.startswith("PRETTY_NAME=")), "?")
if now - st.get("ip_t", 0) > 3600:
    ip = sh("curl -s -m 4 https://api.ipify.org", 6).strip()
    st["ip"] = ip if ip and len(ip) < 46 else st.get("ip", "")
    st["ip_t"] = now

# ── Kontainer Docker ──
cont = {}
for l in sh("docker ps -a --format '{{json .}}'").splitlines():
    try:
        j = json.loads(l)
        cont[j["Names"]] = {"name": j["Names"], "status": j.get("Status", ""), "state": j.get("State", ""), "image": j.get("Image", "")}
    except Exception:
        pass
for l in sh("docker stats --no-stream --format '{{json .}}'", 30).splitlines():
    try:
        j = json.loads(l)
        c = cont.setdefault(j["Name"], {"name": j["Name"]})
        c.update(cpu=j.get("CPUPerc", ""), mem=j.get("MemUsage", "").split("/")[0].strip(), memp=j.get("MemPerc", ""), net=j.get("NetIO", ""))
    except Exception:
        pass

# ── Proses teratas ──
def top(key):
    out = []
    for l in sh(f"ps -eo comm,pcpu,pmem,rss --sort=-{key} --no-headers | head -6").splitlines():
        p = l.split()
        if len(p) >= 4:
            out.append({"cmd": p[0], "cpu": float(p[1]), "mem": float(p[2]), "rss": int(p[3]) * 1024})
    return out

latest = {
    "t": now,
    "host": platform.node(), "os": osname, "kernel": platform.release(), "ip": st.get("ip", ""),
    "cpu_model": model, "cores": os.cpu_count(),
    "uptime_s": int(up), "boot": now - int(up),
    "reboot_needed": os.path.exists("/var/run/reboot-required"),
    "cpu": cpu, "load": [round(x, 2) for x in load],
    "mem_total": mem_total, "mem_used": mem_used, "swap_total": swap_total, "swap_used": swap_used,
    "disk_total": du.total, "disk_used": du.used,
    "rx_bps": round(rxs), "tx_bps": round(txs),
    "containers": sorted(cont.values(), key=lambda c: c["name"]),
    "top_cpu": top("pcpu"), "top_mem": top("rss"),
}
tmp = LATEST + ".tmp"
open(tmp, "w").write(json.dumps(latest))
os.chmod(tmp, 0o644)
os.replace(tmp, LATEST)

# ── Riwayat ──
row = {"t": now, "cpu": cpu, "mem": round(100 * mem_used / mem_total, 1) if mem_total else 0,
       "load": round(load[0], 2), "disk": round(100 * du.used / du.total, 1), "rx": round(rxs), "tx": round(txs)}
lines = rd(HIST).splitlines()[-(KEEP - 1):]
lines.append(json.dumps(row))
open(HIST + ".tmp", "w").write("\n".join(lines) + "\n")
os.chmod(HIST + ".tmp", 0o644)
os.replace(HIST + ".tmp", HIST)

st.update(t=now, cpu=[idle, total], net=[rx, tx])
open(STATE, "w").write(json.dumps(st))
