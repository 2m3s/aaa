#!/usr/bin/env python3
"""Web panel for the Minecraft server: live console, file manager, restart, backups.

Runs in its own container with the repo folder mounted at PANEL_ROOT. Talks to the
server over RCON and reads its log file; it never touches Docker itself. Restarting
works by sending "stop": the container's restart policy brings the server back up,
and the start script re-reads server.env, so edited settings apply.
"""
import base64
import hmac
import http.server
import json
import os
import re
import secrets
import shutil
import socket
import struct
import sys
import tarfile
import tempfile
import threading
import time
import urllib.parse

ROOT = os.path.realpath(os.environ.get("PANEL_ROOT", "/aaa"))
ENV_FILE = os.path.join(ROOT, "server.env")
ENV_EXAMPLE = os.path.join(ROOT, "server.env.example")
LOG_FILE = os.path.join(ROOT, "data", "logs", "latest.log")
BACKUP_DIR = os.path.join(ROOT, "backups")
INDEX_HTML = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")
RCON_HOST = os.environ.get("RCON_HOST", "mc")
RCON_PORT = int(os.environ.get("RCON_PORT", "25575"))
LISTEN_PORT = int(os.environ.get("PANEL_LISTEN_PORT", "8080"))
HIDDEN = {".git"}
MAX_EDIT_BYTES = 2 * 1024 * 1024
LOG_TAIL_BYTES = 64 * 1024
LOG_CHUNK_BYTES = 256 * 1024
COLOR_CODES = re.compile("§[0-9a-fk-orx]", re.I)


# ── server.env ────────────────────────────────────────────────

def read_env():
    env = {}
    try:
        with open(ENV_FILE, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\r\n")
                if not line or line.lstrip().startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                    val = val[1:-1]
                env[key.strip()] = val
    except FileNotFoundError:
        pass
    return env


def set_env(key, value):
    with open(ENV_FILE, encoding="utf-8") as f:
        lines = f.read().splitlines()
    for i, line in enumerate(lines):
        if line.startswith(key + "="):
            lines[i] = f"{key}={value}"
            break
    else:
        lines += ["", f"{key}={value}"]
    write_file(ENV_FILE, ("\n".join(lines) + "\n").encode())


def ensure_env():
    """Create server.env from the example and give the panel a password if it has none."""
    if not os.path.exists(ENV_FILE) and os.path.exists(ENV_EXAMPLE):
        with open(ENV_EXAMPLE, "rb") as f:
            write_file(ENV_FILE, f.read())
        print("Created server.env from server.env.example", flush=True)
    if os.path.exists(ENV_FILE) and not read_env().get("PANEL_PASSWORD"):
        set_env("PANEL_PASSWORD", secrets.token_urlsafe(12))
        print("Generated a panel password (see PANEL_PASSWORD in server.env)", flush=True)
    env = read_env()
    print(f"Panel login  user: {env.get('PANEL_USER') or 'admin'}  "
          f"password: {env.get('PANEL_PASSWORD', '')}", flush=True)


# ── files ─────────────────────────────────────────────────────

def owner_of(path):
    """uid/gid that a new or rewritten file at path should get (existing file, else its folder)."""
    st = os.stat(path if os.path.exists(path) else os.path.dirname(path))
    return st.st_uid, st.st_gid


def fix_owner(path, uid_gid):
    # The panel runs as root; hand files back to whoever owns the folder so the
    # Minecraft server (uid 1000) can still read and write them.
    if os.geteuid() == 0:
        try:
            os.chown(path, *uid_gid)
        except OSError:
            pass


def write_file(path, data_or_stream, length=None):
    """Atomically write bytes (or `length` bytes from a stream) to path, keeping owner and mode."""
    uid_gid = owner_of(path)
    mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".upload-")
    try:
        with os.fdopen(fd, "wb") as out:
            if isinstance(data_or_stream, bytes):
                out.write(data_or_stream)
            else:
                remaining = length
                while remaining > 0:
                    chunk = data_or_stream.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        raise ConnectionError("upload cut off")
                    out.write(chunk)
                    remaining -= len(chunk)
        os.chmod(tmp, mode)
        fix_owner(tmp, uid_gid)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def safe_path(rel):
    """Resolve a panel path inside ROOT, or raise ValueError."""
    rel = (rel or "").replace("\\", "/").strip("/")
    path = os.path.realpath(os.path.join(ROOT, rel))
    if path != ROOT and not path.startswith(ROOT + os.sep):
        raise ValueError("path outside the server folder")
    if any(part in HIDDEN for part in os.path.relpath(path, ROOT).split(os.sep)):
        raise ValueError("that folder is hidden")
    return path


def rel_of(path):
    rel = os.path.relpath(path, ROOT)
    return "" if rel == "." else rel.replace(os.sep, "/")


# ── RCON ──────────────────────────────────────────────────────

class RconError(Exception):
    pass


class Rcon:
    """One RCON connection, kept open and shared. Minecraft logs every new RCON
    connection, so reconnecting for each status check would flood the console."""

    MAX_CHUNK = 4096  # Minecraft splits longer replies into packets of this many bytes

    def __init__(self):
        self.lock = threading.Lock()
        self.sock = None
        self.password = None
        self.next_id = 0

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def send(self, kind, body):
        self.next_id = self.next_id % 2_000_000_000 + 1
        payload = struct.pack("<ii", self.next_id, kind) + body.encode("utf-8") + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(payload)) + payload)
        return self.next_id

    def recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("Server closed the connection")
            buf += chunk
        return buf

    def recv(self):
        (length,) = struct.unpack("<i", self.recv_exact(4))
        data = self.recv_exact(length)
        req_id, _ = struct.unpack("<ii", data[:8])
        return req_id, data[8:-2]

    def connect(self, password, timeout):
        self.sock = socket.create_connection((RCON_HOST, RCON_PORT), timeout=timeout)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        self.send(3, password)
        if self.recv()[0] == -1:
            self.close()
            raise RconError("Wrong RCON_PASSWORD. If you just changed it, restart the server.")
        self.password = password

    def run(self, command, timeout):
        self.sock.settimeout(timeout)
        req_id = self.send(2, command)
        if command.strip().lower() == "stop":
            self.close()  # the server shuts down; reconnect after it's back
            return "Stopping..."
        body = b""
        while True:
            try:
                got_id, chunk = self.recv()
            except socket.timeout:
                if not body:
                    raise
                self.close()  # don't reuse a connection that may hold half a packet
                break
            if got_id != req_id:
                continue  # leftover reply to an earlier command
            body += chunk
            if len(chunk) < self.MAX_CHUNK:
                break
            self.sock.settimeout(0.5)  # a full-size packet may be followed by more
        return COLOR_CODES.sub("", body.decode("utf-8", "replace"))

    def command(self, command, timeout=5):
        password = read_env().get("RCON_PASSWORD", "")
        if not self.lock.acquire(timeout=timeout):
            raise RconError("Server is busy, try again in a moment.")
        try:
            for attempt in (1, 2):
                try:
                    if self.sock is None or self.password != password:
                        self.close()
                        self.connect(password, timeout)
                    return self.run(command, timeout)
                except socket.timeout:
                    self.close()
                    raise RconError("The server didn't answer in time.")
                except (OSError, struct.error):
                    # Stale connection (e.g. the server restarted): reconnect once.
                    self.close()
                    if attempt == 2:
                        raise RconError("Server is offline or still starting.")
        finally:
            self.lock.release()


_rcon = Rcon()


def rcon(command, timeout=5):
    return _rcon.command(command, timeout)


# ── backups ───────────────────────────────────────────────────

backup_state = {"running": False, "last": None, "error": None}


def run_backup():
    try:
        try:
            rcon("save-off")
            rcon("save-all flush", timeout=60)
            saved = True
        except RconError:
            saved = False
        try:
            os.makedirs(BACKUP_DIR, exist_ok=True)
            name = time.strftime("mc-%Y%m%d-%H%M%S.tar.gz")
            tmp = os.path.join(BACKUP_DIR, "." + name)
            with tarfile.open(tmp, "w:gz") as tar:
                tar.add(os.path.join(ROOT, "data"), arcname="data")
            os.replace(tmp, os.path.join(BACKUP_DIR, name))
            backup_state["last"] = "backups/" + name
            backup_state["error"] = None
        finally:
            if saved:
                rcon("save-on")
    except Exception as e:  # report anything to the page instead of dying silently
        backup_state["error"] = str(e)
    finally:
        backup_state["running"] = False


# ── HTTP ──────────────────────────────────────────────────────

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "mc-panel"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # keep the container log for login info and errors

    # helpers
    def reply(self, code, body=b"", ctype="application/json", headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def error(self, code, msg):
        self.reply(code, {"error": msg})

    def authorized(self):
        env = read_env()
        password = env.get("PANEL_PASSWORD", "")
        if not password:
            self.reply(503, "Set PANEL_PASSWORD in server.env, then restart the panel.", "text/plain")
            return False
        expected = f"{env.get('PANEL_USER') or 'admin'}:{password}".encode()
        header = self.headers.get("Authorization", "")
        if header.startswith("Basic "):
            try:
                given = base64.b64decode(header[6:], validate=True)
            except ValueError:
                given = b""
            if hmac.compare_digest(given, expected):
                return True
            time.sleep(1)  # slow down password guessing
        self.reply(401, "Login required", "text/plain",
                   {"WWW-Authenticate": 'Basic realm="Minecraft panel", charset="UTF-8"'})
        return False

    def json_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}") if length else {}

    def query(self):
        return {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).items()}

    def route(self):
        return urllib.parse.urlsplit(self.path).path

    # verbs
    def do_GET(self):
        if not self.authorized():
            return
        try:
            self.handle_get(self.route(), self.query())
        except ValueError as e:
            self.error(400, str(e))
        except FileNotFoundError:
            self.error(404, "Not found")

    def do_POST(self):
        self.handle_write(self.handle_post)

    def do_PUT(self):
        self.handle_write(self.handle_put)

    def handle_write(self, fn):
        if not self.authorized():
            return
        # Browsers can't add this header to a cross-site form post, so other sites
        # can't make a logged-in browser change anything here.
        if self.headers.get("X-Requested-By") != "panel":
            self.error(403, "Missing X-Requested-By header")
            return
        try:
            fn(self.route(), self.query())
        except ValueError as e:
            self.error(400, str(e))
        except FileNotFoundError:
            self.error(404, "Not found")
        except OSError as e:
            self.error(500, str(e))

    def handle_get(self, route, q):
        if route == "/":
            with open(INDEX_HTML, "rb") as f:
                self.reply(200, f.read(), "text/html; charset=utf-8")
        elif route == "/api/status":
            env = read_env()
            info = {"type": env.get("TYPE", ""), "version": env.get("VERSION", ""),
                    "memory": env.get("MEMORY", "")}
            try:
                info["players"] = rcon("list", timeout=2)
                info["online"] = True
            except RconError as e:
                info["online"] = False
                info["players"] = str(e)
            self.reply(200, info)
        elif route == "/api/log":
            self.send_log(int(q.get("offset", "-1")))
        elif route == "/api/files":
            path = safe_path(q.get("path"))
            entries = []
            with os.scandir(path) as it:
                for e in it:
                    if e.name in HIDDEN or e.name.startswith(".upload-"):
                        continue
                    st = e.stat()
                    entries.append({"name": e.name, "dir": e.is_dir(), "size": st.st_size,
                                    "mtime": int(st.st_mtime)})
            entries.sort(key=lambda e: (not e["dir"], e["name"].lower()))
            self.reply(200, {"path": rel_of(path), "entries": entries})
        elif route == "/api/file":
            path = safe_path(q.get("path"))
            if os.path.getsize(path) > MAX_EDIT_BYTES:
                return self.error(415, "Too big to edit here. Download it instead.")
            with open(path, "rb") as f:
                data = f.read()
            if b"\x00" in data:
                return self.error(415, "That's not a text file. Download it instead.")
            self.reply(200, {"path": rel_of(path), "text": data.decode("utf-8", "replace")})
        elif route == "/api/download":
            path = safe_path(q.get("path"))
            if not os.path.isfile(path):
                return self.error(400, "Only files can be downloaded")
            size = os.path.getsize(path)
            name = urllib.parse.quote(os.path.basename(path))
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition", f"attachment; filename*=UTF-8''{name}")
            self.end_headers()
            with open(path, "rb") as f:
                shutil.copyfileobj(f, self.wfile)
        elif route == "/api/backup":
            self.reply(200, backup_state)
        else:
            self.error(404, "Not found")

    def send_log(self, offset):
        try:
            size = os.path.getsize(LOG_FILE)
        except FileNotFoundError:
            return self.reply(200, {"offset": 0, "text": "", "reset": offset > 0})
        reset = False
        if offset < 0 or offset > size:  # first load, or the log was rotated on restart
            reset = offset > size
            offset = max(0, size - LOG_TAIL_BYTES) if offset < 0 else 0
        with open(LOG_FILE, "rb") as f:
            f.seek(offset)
            data = f.read(LOG_CHUNK_BYTES)
        self.reply(200, {"offset": offset + len(data), "reset": reset,
                         "text": data.decode("utf-8", "replace")})

    def handle_put(self, route, q):
        if route != "/api/file":
            return self.error(404, "Not found")
        path = safe_path(q.get("path"))
        if path == ROOT or os.path.isdir(path):
            raise ValueError("That's a folder")
        if not os.path.isdir(os.path.dirname(path)):
            raise ValueError("Folder doesn't exist")
        length = int(self.headers.get("Content-Length") or 0)
        write_file(path, self.rfile, length)
        self.reply(200, {"ok": True})

    def handle_post(self, route, q):
        body = self.json_body()
        if route == "/api/cmd":
            cmd = str(body.get("cmd", "")).strip().lstrip("/")
            if not cmd:
                raise ValueError("Type a command")
            try:
                self.reply(200, {"output": rcon(cmd)})
            except RconError as e:
                self.error(503, str(e))
        elif route == "/api/restart":
            try:
                rcon("stop")
                self.reply(200, {"output": "Saving and restarting. Back in a minute or two."})
            except RconError as e:
                self.error(503, f"{e} If it's stuck, run ./mc restart on the server.")
        elif route == "/api/backup":
            if backup_state["running"]:
                return self.error(409, "A backup is already running")
            backup_state["running"] = True
            threading.Thread(target=run_backup, daemon=True).start()
            self.reply(200, backup_state)
        elif route == "/api/mkdir":
            path = safe_path(body.get("path"))
            uid_gid = owner_of(path)
            os.mkdir(path)
            fix_owner(path, uid_gid)
            self.reply(200, {"ok": True})
        elif route == "/api/delete":
            path = safe_path(body.get("path"))
            if path == ROOT:
                raise ValueError("Can't delete the whole server folder")
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path)
            else:
                os.unlink(path)
            self.reply(200, {"ok": True})
        elif route == "/api/rename":
            src, dst = safe_path(body.get("path")), safe_path(body.get("to"))
            if src == ROOT:
                raise ValueError("Can't rename the server folder")
            if os.path.exists(dst):
                raise ValueError("Something with that name already exists")
            os.rename(src, dst)
            self.reply(200, {"ok": True})
        else:
            self.error(404, "Not found")


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # Port scanners and closed browser tabs drop connections all the time.
        if isinstance(sys.exc_info()[1], ConnectionError):
            return
        super().handle_error(request, client_address)


if __name__ == "__main__":
    ensure_env()
    print(f"Panel listening on port {LISTEN_PORT}", flush=True)
    Server(("", LISTEN_PORT), Handler).serve_forever()
