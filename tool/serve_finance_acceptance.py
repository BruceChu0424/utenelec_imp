"""Loopback-only real application proxy and bounded UI-test evidence sink.

Business requests reach the actual disposable Spring/PG application. A one-shot
fault is injected only after the upstream has fully completed its response, so
unknown-result recovery tests cannot accidentally simulate an unwritten request.
No request bodies, cookies, authorization values or business responses are logged.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import http.client
import json
import threading
import urllib.parse
import argparse

ROOT = Path(__file__).resolve().parents[1]
arguments=argparse.ArgumentParser()
arguments.add_argument('--web-root',type=Path,default=ROOT/'build/web')
arguments.add_argument('--port',type=int,choices=(18090,18092),default=18090)
arguments.add_argument('--api-port',type=int,choices=(18089,18091),default=18089)
options=arguments.parse_args()
if (options.port,options.api_port) not in {(18090,18089),(18092,18091)}:
    raise ValueError('Acceptance listener/upstream pair must remain task-owned')
WEB=options.web_root.resolve()
allowed=(ROOT.resolve(),Path('D:/Projects/uten_imp_worktrees/finance-ui-20261105').resolve())
if not any(WEB.is_relative_to(folder) for folder in allowed) or not (WEB/'index.html').is_file():
    raise ValueError('Acceptance Web assets must be a built task-owned directory')
OUT = ROOT / "build/finance-closeout-20261104/actual-ui"
OUT.mkdir(parents=True, exist_ok=True)
LOCK = threading.Lock()
STATE = {"fault": None, "delay": None, "requests": 0, "droppedCommittedReplies": 0,
         "delayedReadReplies": 0}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def answer(self, status, data, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def do_PUT(self):
        self.dispatch()

    def do_DELETE(self):
        self.dispatch()

    def dispatch(self):
        path = urllib.parse.urlsplit(self.path).path
        length = int(self.headers.get("Content-Length", "0"))
        if length > 20 * 1024 * 1024:
            self.answer(413, b"{}")
            return
        body = self.rfile.read(length) if length else None
        if path.startswith("/__acceptance__/"):
            self.control(path, body)
            return
        if path.startswith("/api/"):
            upstream = http.client.HTTPConnection("127.0.0.1", options.api_port, timeout=180)
            try:
                headers = {key: value for key, value in self.headers.items()
                           if key.lower() not in {"connection", "content-length"}}
                upstream.request(self.command, self.path, body, headers)
                result = upstream.getresponse()
                data = result.read()
                drop = False
                delay = 0
                with LOCK:
                    STATE["requests"] += 1
                    fault = STATE["fault"]
                    if (fault and self.command == fault["method"] and path == fault["path"]
                            and 200 <= result.status < 300):
                        STATE["fault"] = None
                        STATE["droppedCommittedReplies"] += 1
                        drop = True
                    planned_delay = STATE["delay"]
                    if (planned_delay and self.command == "GET" and path == planned_delay["path"]):
                        delay = planned_delay["milliseconds"]
                        STATE["delay"] = None
                        STATE["delayedReadReplies"] += 1
                if drop:
                    self.close_connection = True
                    self.connection.shutdown(2)
                    self.connection.close()
                    return
                if delay:
                    import time
                    time.sleep(delay / 1000)
                self.send_response(result.status)
                for key, value in result.getheaders():
                    if key.lower() not in {"transfer-encoding", "connection", "content-length"}:
                        self.send_header(key, value)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (OSError, http.client.HTTPException):
                if not self.close_connection:
                    self.answer(502, b'{"code":"ACCEPTANCE_UPSTREAM_UNAVAILABLE"}')
            finally:
                upstream.close()
            return
        relative = urllib.parse.unquote(path).lstrip("/") or "index.html"
        target = (WEB / relative).resolve()
        if not target.is_relative_to(WEB.resolve()):
            self.answer(403, b"{}")
            return
        if not target.is_file():
            target = WEB / "index.html"
        if not target.is_file():
            self.answer(503, b"Web build is not ready", "text/plain")
            return
        import mimetypes
        self.answer(200, target.read_bytes(), mimetypes.guess_type(target)[0] or "application/octet-stream")

    def control(self, path, body):
        if path == "/__acceptance__/delay" and self.command == "POST":
            value = json.loads(body or b"{}")
            if (not str(value.get("path", "")).startswith("/api/finance/")
                    or not isinstance(value.get("milliseconds"), int)
                    or not 100 <= value["milliseconds"] <= 5000):
                self.answer(400, b"{}")
                return
            with LOCK:
                STATE["delay"] = {"path": value["path"], "milliseconds": value["milliseconds"]}
            self.answer(200, b'{"armed":true}')
            return
        if path == "/__acceptance__/state" and self.command == "GET":
            with LOCK:
                data = json.dumps(STATE).encode()
            self.answer(200, data)
            return
        if path == "/__acceptance__/fault" and self.command == "POST":
            value = json.loads(body or b"{}")
            if (value.get("method") not in {"POST", "PUT", "DELETE"}
                    or not str(value.get("path", "")).startswith("/api/finance/")):
                self.answer(400, b"{}")
                return
            with LOCK:
                STATE["fault"] = {"method": value["method"], "path": value["path"]}
            self.answer(200, b'{"armed":true}')
            return
        if path == "/__acceptance__/artifact" and self.command == "POST":
            name = self.headers.get("X-Acceptance-Name", "")
            import re
            if not re.fullmatch(r"[a-zA-Z0-9_-]{1,100}\.(png|json)", name):
                self.answer(400, b"{}")
                return
            (OUT / name).write_bytes(body or b"")
            self.answer(200, b'{"saved":true}')
            return
        self.answer(404, b"{}")


if __name__ == "__main__":
    print(f"Loopback acceptance proxy 127.0.0.1:{options.port} -> disposable API :{options.api_port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", options.port), Handler).serve_forever()
