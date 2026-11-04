#!/usr/bin/env python3
"""
bot.py - Bot Telegram giám sát và điều khiển server.

Chỉ dùng thư viện chuẩn của Python 3 (không cần pip install).

Lệnh (chỉ chấp nhận từ TELEGRAM_CHAT_ID):
  /status          Trạng thái container + tài nguyên server
  /logs            20 dòng log gần nhất của container
  /restart         Khởi động lại container
  /deploy [tag]    Chạy deploy.sh (kết quả do deploy.sh tự thông báo)
  /help            Danh sách lệnh

Ngoài ra bot tự giám sát HEALTH_URL và báo khi app DOWN / UP trở lại.
"""
import fcntl
import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from html import escape

TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
CHAT_ID = str(os.environ.get("TELEGRAM_CHAT_ID", ""))
CONTAINER = os.environ.get("CONTAINER_NAME", "myapp")
APP_PORT = os.environ.get("APP_PORT", "8000")
HEALTH_URL = os.environ.get("HEALTH_URL", f"http://127.0.0.1:{APP_PORT}/")
MONITOR_INTERVAL = int(os.environ.get("MONITOR_INTERVAL", "60"))
FAIL_THRESHOLD = int(os.environ.get("FAIL_THRESHOLD", "2"))
LOCK_FILE = os.environ.get("LOCK_FILE", f"/tmp/{CONTAINER}-deploy.lock")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEPLOY_SCRIPT = os.path.join(BASE_DIR, "deploy.sh")
DEPLOY_LOG = os.path.join(BASE_DIR, "deploy.log")
API = f"https://api.telegram.org/bot{TOKEN}"


# ---------------------------------------------------------------- Telegram API
def api(method, params=None, timeout=40):
    data = urllib.parse.urlencode(params or {}).encode()
    req = urllib.request.Request(f"{API}/{method}", data=data)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def send(text, chat_id=None):
    try:
        api("sendMessage", {
            "chat_id": chat_id or CHAT_ID,
            "text": text[:4000],
            "parse_mode": "HTML",
            "disable_web_page_preview": "true",
        }, timeout=15)
    except Exception as exc:  # không để lỗi mạng làm sập bot
        print(f"[send] lỗi: {exc}", flush=True)


# ------------------------------------------------------------------ Tiện ích
def run(cmd, timeout=20):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (out.stdout + out.stderr).strip()
    except Exception as exc:
        return f"(lỗi chạy lệnh: {exc})"


def check_health():
    try:
        with urllib.request.urlopen(HEALTH_URL, timeout=5) as resp:
            return resp.status < 500
    except urllib.error.HTTPError as exc:
        return exc.code < 500
    except Exception:
        return False


def deploy_running():
    """True nếu deploy.sh đang giữ file lock."""
    try:
        with open(LOCK_FILE, "a+") as fh:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fh, fcntl.LOCK_UN)
                return False
            except BlockingIOError:
                return True
    except OSError:
        return False


def human_uptime():
    with open("/proc/uptime") as fh:
        secs = int(float(fh.read().split()[0]))
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    return f"{d}d {h}h {rem // 60}m"


def memory_usage():
    info = {}
    with open("/proc/meminfo") as fh:
        for line in fh:
            key, val = line.split(":")
            info[key] = int(val.split()[0])  # kB
    total, avail = info["MemTotal"], info["MemAvailable"]
    used = total - avail
    return f"{used // 1024}/{total // 1024} MB ({used * 100 // total}%)"


# --------------------------------------------------------------------- Lệnh
def cmd_help():
    return ("<b>Lệnh có sẵn</b>\n"
            "/status - trạng thái hệ thống\n"
            "/logs - log container\n"
            "/restart - khởi động lại container\n"
            "/deploy [tag] - triển khai phiên bản mới\n"
            "/help - trợ giúp")


def cmd_status():
    info = run(["docker", "inspect", "-f",
                "{{.State.Status}}|{{.State.StartedAt}}|{{.Config.Image}}", CONTAINER])
    if "|" in info:
        state, started, image = info.split("|", 2)
        icon = "🟢" if state == "running" else "🔴"
        container_txt = (f"{icon} <b>{escape(state)}</b>\n"
                         f"Image: <code>{escape(image)}</code>\n"
                         f"Khởi động: {escape(started[:19].replace('T', ' '))} UTC")
    else:
        container_txt = f"🔴 Không tìm thấy container <code>{escape(CONTAINER)}</code>"

    app_ok = check_health()
    disk = shutil.disk_usage("/")
    load1, load5, _ = os.getloadavg()

    return (f"📊 <b>Trạng thái server</b> <code>{os.uname().nodename}</code>\n\n"
            f"<b>Container</b>: {container_txt}\n"
            f"<b>Health check</b>: {'🟢 OK' if app_ok else '🔴 FAIL'}\n\n"
            f"Uptime: {human_uptime()}\n"
            f"Load: {load1:.2f} / {load5:.2f}\n"
            f"RAM: {memory_usage()}\n"
            f"Disk: {disk.used * 100 // disk.total}% "
            f"({disk.used // 2**30}/{disk.total // 2**30} GB)")


def cmd_logs():
    out = run(["docker", "logs", "--tail", "20", CONTAINER])
    return f"📜 <b>Log {escape(CONTAINER)}</b>\n<pre>{escape(out[-3000:]) or '(trống)'}</pre>"


def cmd_restart():
    out = run(["docker", "restart", CONTAINER], timeout=60)
    ok = out.strip() == CONTAINER
    return "🔄 Đã restart container." if ok else f"❌ Restart lỗi:\n<pre>{escape(out)}</pre>"


def cmd_deploy(args):
    tag = args[0] if args else ""
    if tag and not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", tag):
        return "❌ Tag không hợp lệ."
    if deploy_running():
        return "⚠️ Đang có một lần deploy chạy, thử lại sau."
    cmd = [DEPLOY_SCRIPT] + ([tag] if tag else [])
    with open(DEPLOY_LOG, "a") as log:
        subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True, cwd=BASE_DIR)
    return f"⏳ Đã kích hoạt deploy{' tag ' + tag if tag else ''}. Kết quả sẽ được báo sau."


def handle(message):
    chat_id = str(message["chat"]["id"])
    if chat_id != CHAT_ID:
        print(f"[auth] Bỏ qua chat không được phép: {chat_id}", flush=True)
        return

    parts = message.get("text", "").strip().split()
    if not parts or not parts[0].startswith("/"):
        return
    command = parts[0].split("@")[0].lower()
    args = parts[1:]

    handlers = {
        "/start": cmd_help, "/help": cmd_help,
        "/status": cmd_status, "/logs": cmd_logs, "/restart": cmd_restart,
    }
    if command == "/deploy":
        reply = cmd_deploy(args)
    elif command in handlers:
        reply = handlers[command]()
    else:
        reply = "Lệnh không hợp lệ. Gõ /help để xem danh sách."
    send(reply, chat_id)


# ------------------------------------------------------- Giám sát tự động
def monitor_loop():
    state_up = None   # None = chưa biết
    fails = 0
    while True:
        time.sleep(MONITOR_INTERVAL)
        if deploy_running():          # đang deploy thì không báo động giả
            fails = 0
            continue
        if check_health():
            fails = 0
            if state_up is False:
                send(f"🟢 <b>App đã hoạt động trở lại</b>\n<code>{escape(HEALTH_URL)}</code>")
            state_up = True
        else:
            fails += 1
            if fails >= FAIL_THRESHOLD and state_up is not False:
                send(f"🔴 <b>CẢNH BÁO: App không phản hồi</b>\n"
                     f"<code>{escape(HEALTH_URL)}</code>\n"
                     f"Gõ /status hoặc /logs để kiểm tra.")
                state_up = False


# ----------------------------------------------------------------------- Main
def main():
    if not TOKEN or not CHAT_ID:
        raise SystemExit("Thiếu TELEGRAM_BOT_TOKEN hoặc TELEGRAM_CHAT_ID")

    threading.Thread(target=monitor_loop, daemon=True).start()
    send("🤖 Bot đã khởi động. Gõ /help để xem lệnh.")
    print("Bot đang chạy...", flush=True)

    offset = None
    while True:
        try:
            params = {"timeout": 30, "allowed_updates": json.dumps(["message"])}
            if offset is not None:
                params["offset"] = offset
            data = api("getUpdates", params, timeout=40)
            for update in data.get("result", []):
                offset = update["update_id"] + 1
                if "message" in update:
                    try:
                        handle(update["message"])
                    except Exception as exc:
                        print(f"[handle] lỗi: {exc}", flush=True)
        except Exception as exc:
            print(f"[poll] lỗi: {exc}", flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
