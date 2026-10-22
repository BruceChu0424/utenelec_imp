#!/usr/bin/env python3
"""Exercise the actual update routes in disposable Linux Nginx, with no host ports.

Example from the repository root:
docker run --rm -v "${PWD}:/workspace:ro" uten-remote-contract:20261017 \
    python3 /workspace/deploy/client/nginx_client_updates_integration.py

The fixture backend only checks proxy behavior. Real account/publishing policy is
covered by the Spring tests, not by the deliberately fake test bearer below.
"""
from __future__ import annotations

import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import socket
import ssl
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
RELEASE_ID = "6a4dc49d-7aad-4d31-94df-fdcf81bdde35"
UPLOAD = f"/api/admin/client-releases/{RELEASE_ID}/package"
DOWNLOAD = f"/api/client-updates/{RELEASE_ID}/download"
TOKEN = "Bearer ISOLATED_PROXY_FIXTURE"


class Backend(BaseHTTPRequestHandler):
    requests = []
    withdrawn = False

    def reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Cache-Control", "private, no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):
        type(self).requests.append((self.path, dict(self.headers)))
        if self.headers.get("Authorization") != TOKEN:
            self.reply(401, b"unauthorized")
            return
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.reply(200, json.dumps({"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}).encode())

    def do_GET(self):
        type(self).requests.append((self.path, dict(self.headers)))
        if self.headers.get("Authorization") != TOKEN:
            self.reply(401, b"unauthorized")
        else:
            self.reply(404 if self.withdrawn else 200, b"withdrawn" if self.withdrawn else b"client-package")

    def log_message(self, *args):
        pass


def request(directory, path, method="GET", body=None, *, declared_size=None, authorized=True):
    context = ssl.create_default_context(cafile=str(directory / "fixture.crt"))
    stream = context.wrap_socket(socket.create_connection(("127.0.0.1", 18443), timeout=10),
                                 server_hostname="erp.example.test")
    connection = http.client.HTTPConnection("erp.example.test", timeout=10)
    connection.sock = stream
    try:
        connection.putrequest(method, path)
        if authorized:
            connection.putheader("Authorization", TOKEN)
        connection.putheader("X-Forwarded-For", "203.0.113.77")
        if body is not None or declared_size is not None:
            connection.putheader("Content-Type", "application/octet-stream")
            connection.putheader("Content-Length", str(declared_size if declared_size is not None else len(body)))
        connection.endheaders()
        if body is not None:
            connection.send(body)
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        connection.close()


def render(source, directory, remote):
    config = source
    replacements = {
        "__LOCAL_DOMAIN__": "erp.example.test", "__INTERNAL_DOMAIN__": "erp.example.test",
        "__CLOUD_DOMAIN__": "erp.example.test", "__OFFICE_CIDR__": "127.0.0.0/8",
        "__EXACT_OFFICE_CIDR__": "127.0.0.0/8", "__VPN_CIDR__": "192.0.2.0/24",
        "__TLS_CERT_PATH__": str(directory / "fixture.crt"),
        "__INTERNAL_TLS_CERT_PATH__": str(directory / "fixture.crt"),
        "__TLS_KEY_PATH__": str(directory / "fixture.key"),
        "__INTERNAL_TLS_KEY_PATH__": str(directory / "fixture.key"),
        "__OSS_PUBLIC_HOST__": "objects.example.test",
        "@@COMPANY_WIREGUARD_IPV4@@": "127.0.0.1", "@@CLOUD_WIREGUARD_IPV4@@": "127.0.0.1",
        "@@PUBLIC_DOMAIN@@": "erp.example.test", "@@REMOTE_BACKEND_PORT@@": "18082",
        "/etc/ssl/certs/uten-imp-lan.crt": str(directory / "fixture.crt"),
        "/etc/ssl/private/uten-imp-lan.key": str(directory / "fixture.key"),
        "/etc/uten-remote/tls": str(directory / "tls"),
        "/var/log/uten-remote": str(directory), "/var/cache/uten-remote": str(directory),
        "/run/uten-remote": str(directory), "/opt/uten-imp/current/web": str(directory / "web"),
        "127.0.0.1:8080": "127.0.0.1:18082", "127.0.0.1:8081": "127.0.0.1:18081",
        "127.0.0.1:9443": "127.0.0.1:18443", "127.0.0.1:8443": "127.0.0.1:18843",
    }
    for old, new in replacements.items():
        config = config.replace(old, new)
    if re.search(r"__[A-Z0-9_]+__|@@[A-Z0-9_]+@@", config):
        raise AssertionError("unrendered template token")
    if remote:
        return config
    config = re.sub(r"listen 443(?=\s)", "listen 18443", config)
    config = re.sub(r"listen 80(?=[;\s])", "listen 18080", config)
    return f"pid {directory}/nginx.pid;\nerror_log {directory}/error.log;\nevents {{}}\nhttp {{\n" + config + "\n}\n"


def wait_listener():
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", 18443), timeout=.2):
                return
        except OSError:
            time.sleep(.05)
    raise AssertionError("isolated Nginx did not start")


def main():
    if not Path("/.dockerenv").exists():
        raise SystemExit("Run only in a disposable Linux Docker container; never on an ERP host.")
    templates = [
        "deploy/nginx/uten-imp-http-lan.conf", "deploy/nginx/uten-imp.conf.example",
        "deploy/nginx/uten-imp-internal-test.conf.example", "deploy/cloud/nginx-cloud.conf.example",
        "deploy/remote-access/templates/company-nginx.conf.tmpl",
    ]
    backend = ThreadingHTTPServer(("127.0.0.1", 18082), Backend)
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    outcomes = []
    try:
        with tempfile.TemporaryDirectory(prefix="uten-client-nginx-") as temporary:
            base = Path(temporary)
            base.chmod(0o755)
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                            "-subj", "/CN=erp.example.test", "-addext", "subjectAltName=DNS:erp.example.test",
                            "-keyout", str(base / "fixture.key"), "-out", str(base / "fixture.crt")],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for index, template in enumerate(templates):
                work = base / str(index)
                work.mkdir(mode=0o755)
                (work / "fixture.crt").write_bytes((base / "fixture.crt").read_bytes())
                (work / "fixture.key").write_bytes((base / "fixture.key").read_bytes())
                (work / "tls").mkdir()
                for name in ("transport-server.crt", "cloud-client-ca.crt", "employee-fullchain.crt"):
                    (work / "tls" / name).write_bytes((base / "fixture.crt").read_bytes())
                for name in ("transport-server.key", "employee.key"):
                    (work / "tls" / name).write_bytes((base / "fixture.key").read_bytes())
                for name in ("web", "body", "proxy", "fastcgi", "uwsgi", "scgi"):
                    (work / name).mkdir(mode=0o755)
                config = work / "nginx.conf"
                config.write_text(render((ROOT / template).read_text(encoding="utf-8"), work, "remote-access" in template))
                checked = subprocess.run(["nginx", "-t", "-q", "-c", str(config)], capture_output=True, text=True)
                assert checked.returncode == 0, template + "\n" + checked.stderr
                process = subprocess.Popen(["nginx", "-c", str(config), "-g", "daemon off;"],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    wait_listener()
                    Backend.withdrawn = False
                    data = b"fixture" * (3 * 1024 * 1024 // 7 + 1)
                    status, headers, body = request(work, UPLOAD, "PUT", data)
                    assert status == 200, (template, status, body[:200])
                    assert json.loads(body) == {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                    forwarded = Backend.requests[-1][1]
                    assert forwarded["X-Forwarded-For"] == "127.0.0.1"
                    assert forwarded["Authorization"] == TOKEN and forwarded["X-Request-Id"]
                    assert headers["X-Content-Type-Options"] == "nosniff"
                    assert request(work, "/api/admin/client-releases", "PUT", declared_size=3 * 1024 * 1024)[0] == 413
                    assert request(work, UPLOAD, "PUT", declared_size=512 * 1024 * 1024 + 1)[0] == 413
                    assert request(work, UPLOAD, "PUT", b"", authorized=False)[0] == 401
                    assert request(work, UPLOAD)[0] == 405
                    assert request(work, DOWNLOAD, "PUT", b"")[0] == 405
                    status, headers, body = request(work, DOWNLOAD)
                    assert status == 200 and body == b"client-package"
                    assert "no-store" in headers["Cache-Control"]
                    Backend.withdrawn = True
                    assert request(work, DOWNLOAD)[0] == 404
                    assert request(work, DOWNLOAD, authorized=False)[0] == 401
                    outcomes.append({"template": template, "result": "PASS"})
                finally:
                    process.terminate()
                    process.wait(timeout=5)
    finally:
        backend.shutdown()
    print(json.dumps({"templates": outcomes, "upload_over_2m": True, "oversize_rejected": True,
                      "ordinary_json_stays_2m": True, "authorization_forwarded": True,
                      "withdrawal_not_cached": True, "security_headers_preserved": True}))


if __name__ == "__main__":
    main()
