#!/usr/bin/env python3
"""server.py — the transport behind `hzl web`, and nothing else.

This process parses no ledger, reads no state file and knows no rule. It runs
`hzl dashboard` for what to show and `hzl add` for what to write, and passes
their output through. That is deliberate and it is the whole design: the rest
of this program keeps one parse of the backlog, in `backlog_scan`, and a second
implementation of "what the queue says" written in Python would be the copy
that falls behind — the way `ledger_blocked`'s copy did, silently, until a
person noticed a tag in the morning report that the ledger no longer considered
part of the task.

What it does own is the boundary. A page that can write the backlog is reachable
from any site the browser happens to have open, so the mutating route is behind
four checks that a cross-site request cannot pass all of, and every response
carries the headers that keep the page from being framed, sniffed or cached.
"""
import ipaddress
import json
import os
import subprocess
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HZL = os.environ.get("HZL_BIN") or "hzl"
UI_DIR = os.environ.get("HZL_WEB_UI") or os.path.join(os.path.dirname(os.path.abspath(__file__)))
HOST = os.environ.get("HZL_WEB_HOST", "127.0.0.1")
PORT = int(os.environ.get("HZL_WEB_PORT", "3151"))
DAYS = os.environ.get("HZL_WEB_DAYS", "3")

# A command that hangs would hang the page with it, and a dashboard that never
# answers is worse than one that says it could not.
TIMEOUT = 30

CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
       "connect-src 'self'; img-src 'self' data:; object-src 'none'; "
       "base-uri 'none'; frame-ancestors 'none'")


def run_hzl(args, timeout=TIMEOUT):
    """Run `hzl` and return (rc, stdout, stderr). Never raises for exit codes.

    `hzl status` exits 10 when a session is live and `hzl report` exits 10 when
    something is blocked: those codes are answers, not failures, so the caller
    decides what a code means rather than this function guessing.
    """
    try:
        p = subprocess.run([HZL] + args, capture_output=True, timeout=timeout)
    except FileNotFoundError:
        return 127, "", f"{HZL}: not found"
    except subprocess.TimeoutExpired:
        return 124, "", f"{' '.join(args)}: no answer in {timeout}s"
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def host_allowed(headers):
    """Loopback only, and refuse a name that resolves somewhere else.

    The server binds 127.0.0.1, but a DNS name pointed at that address is still
    a way for a page on another origin to talk to it as though it were the same
    one. The Host header is checked rather than trusted.
    """
    raw = str(headers.get("Host") or "").strip()
    try:
        parsed = urllib.parse.urlparse("//" + raw)
        if (not raw or parsed.username or parsed.password or parsed.path
                or parsed.params or parsed.query or parsed.fragment):
            return False
        parsed.port  # noqa: B018 - validates an optional port, raises if malformed
        hostname = (parsed.hostname or "").rstrip(".").lower()
    except ValueError:
        return False
    if hostname == "localhost" or hostname.endswith(".localhost"):
        return True
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False


def write_allowed(headers):
    """The boundary the add-a-task route sits behind.

    Four checks, and a cross-site request cannot pass all of them:

      * `Host` names loopback, so a rebound DNS name is not this origin.
      * `Sec-Fetch-Site: cross-site` is refused outright, which browsers send
        and cannot be talked out of.
      * `Origin`, when the browser sends one, must be exactly this Host.
      * the body must be `application/json`, which a form post cannot claim
        without a preflight this server never approves.

    A client that sends no Origin at all — curl, a script — is allowed, because
    it is not a browser being used against its owner and it already has the
    shell this would be a longer way round to.
    """
    if not host_allowed(headers):
        return False
    if str(headers.get("Sec-Fetch-Site") or "").lower() == "cross-site":
        return False
    ctype = str(headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
    if ctype != "application/json":
        return False
    origin = headers.get("Origin")
    if not origin:
        return True
    host = str(headers.get("Host") or "").strip().lower()
    try:
        parsed = urllib.parse.urlparse(origin)
    except ValueError:
        return False
    return bool(host and parsed.scheme in ("http", "https")
                and parsed.netloc.lower() == host
                and not parsed.username and not parsed.password
                and parsed.path in ("", "/") and not parsed.query)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "hzl-web"
    sys_version = ""

    def log_message(self, fmt, *args):
        """Quiet. The terminal that started this is a terminal a person is using."""

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CSP)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _file(self, name, ctype):
        # Fixed names only. There is no path taken from the request here, so
        # there is nothing to traverse out of.
        try:
            with open(os.path.join(UI_DIR, name), "rb") as fh:
                self._send(200, fh.read(), ctype)
        except OSError:
            self._send(404, {"error": "not found"})

    def do_GET(self):  # noqa: N802
        if not host_allowed(self.headers):
            self._send(403, {"error": "this server answers on loopback only"})
            return
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            self._file("index.html", "text/html; charset=utf-8")
        elif path == "/app.js":
            self._file("app.js", "text/javascript; charset=utf-8")
        elif path == "/api/dashboard":
            started = time.time()
            rc, out, err = run_hzl(["dashboard", "--days", DAYS])
            if rc != 0 or not out.strip():
                # No stale document wearing a fresh face: when the collector
                # fails the page is told so and shows nothing rather than
                # something old. (smile-monitor's rule, and the right one.)
                self._send(503, {"error": err.strip() or f"hzl dashboard exited {rc}",
                                 "collected_ms": int((time.time() - started) * 1000)})
                return
            try:
                data = json.loads(out)
            except json.JSONDecodeError as exc:
                self._send(503, {"error": f"hzl dashboard did not return JSON: {exc}"})
                return
            data["collected_ms"] = int((time.time() - started) * 1000)
            self._send(200, data)
        else:
            self._send(404, {"error": "not found"})

    def do_HEAD(self):  # noqa: N802
        self.do_GET()

    def do_POST(self):  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        if path != "/api/task":
            self._send(404, {"error": "not found"})
            return
        if not write_allowed(self.headers):
            self._send(403, {"error": "refused: this route takes same-origin JSON on loopback only"})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._send(400, {"error": "bad Content-Length"})
            return
        if length <= 0 or length > 64 * 1024:
            self._send(400, {"error": "the body must be between 1 byte and 64KB"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            self._send(400, {"error": f"body is not JSON: {exc}"})
            return
        if not isinstance(payload, dict):
            self._send(400, {"error": "body must be a JSON object"})
            return

        text = str(payload.get("text") or "").strip()
        if not text:
            self._send(400, {"error": "text is required"})
            return
        args = ["add"]
        priority = payload.get("priority")
        if priority not in (None, ""):
            # Validated here as well as in `hzl add`, so that a bad value is a
            # 400 with a sentence rather than a non-zero exit to interpret.
            if not str(priority).isdigit() or not 1 <= int(priority) <= 99:
                self._send(400, {"error": "priority must be an integer in 1..99"})
                return
            args += ["--priority", str(int(priority))]
        workspace = str(payload.get("workspace") or "").strip()
        if workspace:
            args += ["--dir", workspace]
        # `--` and then the text: a task beginning with a dash is a task, not
        # an option, and a person writing one should not have to know that.
        args += ["--", text]

        rc, out, err = run_hzl(args)
        if rc == 0:
            self._send(200, {"ok": True, "said": out.strip()})
        elif rc == 4:
            self._send(409, {"error": "that task is already in the ledger, word for word"})
        else:
            self._send(400, {"error": err.strip() or f"hzl add exited {rc}"})


def main():
    try:
        srv = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError as exc:
        sys.stderr.write(f"hzl web: cannot listen on {HOST}:{PORT}: {exc}\n")
        return 1
    srv.daemon_threads = True
    sys.stderr.write(f"hzl web: http://{HOST}:{PORT}/  (ctrl-c to stop)\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\nhzl web: stopped\n")
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
