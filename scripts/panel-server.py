#!/usr/bin/env python3
"""
panel-server.py: serve the ApkScope control panel on 127.0.0.1.

GET  serves only the panel, status.json, and the three policy files.
POST /api/save writes one of those three policy files, and only those three.

Any web page you have open can send requests to localhost, so saves are
refused unless the request:
  - carries an Origin of this exact server (a cross-site page can't forge it), and
  - is application/json (a cross-site JSON POST needs a CORS preflight, which
    this server never approves).
Whatever you save still has to pass scripts/validate.sh before anything runs.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765

READABLE = {
    "/apkscope-control-panel.html": "text/html; charset=utf-8",
    "/status.json": "application/json",
    "/ai-proxy/filter": "text/plain; charset=utf-8",
    "/tools.txt": "text/plain; charset=utf-8",
    "/llm.env": "text/plain; charset=utf-8",
}
WRITABLE = {"ai-proxy/filter", "tools.txt", "llm.env"}
MAX_BYTES = 64 * 1024
ORIGINS = {f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            path = "/apkscope-control-panel.html"
        if path == "/api/ping":
            return self._send(200, json.dumps({"server": "apkscope"}))
        if path not in READABLE:
            return self._send(404, '{"error":"not found"}')
        try:
            with open(os.path.join(ROOT, path.lstrip("/")), "rb") as f:
                return self._send(200, f.read(), READABLE[path])
        except FileNotFoundError:
            return self._send(404, '{"error":"not found"}')

    def do_POST(self):
        if self.path != "/api/save":
            return self._send(404, '{"error":"not found"}')
        if self.headers.get("Origin") not in ORIGINS:
            return self._send(403, '{"error":"bad origin"}')
        if not self.headers.get("Content-Type", "").startswith("application/json"):
            return self._send(415, '{"error":"json only"}')
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BYTES:
            return self._send(413, '{"error":"too large"}')
        try:
            req = json.loads(self.rfile.read(length))
            rel, content = req["path"], req["content"]
        except (ValueError, KeyError, TypeError):
            return self._send(400, '{"error":"bad request"}')
        if rel not in WRITABLE or not isinstance(content, str):
            return self._send(403, '{"error":"not a policy file"}')
        target = os.path.join(ROOT, rel)
        tmp = target + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        os.replace(tmp, target)
        print(f"saved {rel} ({len(content)} bytes)")
        return self._send(200, json.dumps({"saved": rel}))

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"ApkScope panel: http://127.0.0.1:{PORT}/   (Ctrl+C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
