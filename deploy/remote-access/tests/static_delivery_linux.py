#!/usr/bin/env python3
"""Exercise the four current employee Nginx templates in isolated Docker.

No host ports, production credentials, external network, or business data.
"""
from __future__ import annotations

import gzip
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location(
    "nginx_fixture", ROOT / "deploy/client/nginx_client_updates_integration.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
PRIVATE = b"PRIVATE-FONT-RESPONSE" * 2048


class Backend(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "font/ttf")
        self.send_header("Content-Length", str(len(PRIVATE)))
        self.send_header("Cache-Control", "private, no-store")
        self.end_headers()
        self.wfile.write(PRIVATE)

    def log_message(self, *args):
        pass


def request(work, path, encoding="gzip"):
    context = ssl.create_default_context(cafile=str(work / "fixture.crt"))
    stream = context.wrap_socket(socket.create_connection(("127.0.0.1", 18443), timeout=5),
                                 server_hostname="erp.example.test")
    connection = http.client.HTTPConnection("erp.example.test", timeout=5)
    connection.sock = stream
    try:
        connection.request("GET", path, headers={"Accept-Encoding": encoding})
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        connection.close()


@unittest.skipUnless(Path("/.dockerenv").exists(), "Disposable Linux Docker only")
class StaticDeliveryTests(unittest.TestCase):
    def test_real_nginx_font_compression_routes_cache_and_security_headers(self):
        templates = [
            "deploy/nginx/uten-imp-http-lan.conf",
            "deploy/nginx/uten-imp.conf.example",
            "deploy/nginx/uten-imp-internal-test.conf.example",
            "deploy/remote-access/templates/company-nginx.conf.tmpl",
        ]
        backend = ThreadingHTTPServer(("127.0.0.1", 18082), Backend)
        threading.Thread(target=backend.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory(prefix="uten-static-delivery-") as temporary:
                base = Path(temporary)
                base.chmod(0o755)
                subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                                "-days", "1", "-subj", "/CN=erp.example.test", "-addext",
                                "subjectAltName=DNS:erp.example.test", "-keyout", str(base / "fixture.key"),
                                "-out", str(base / "fixture.crt")], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                for index, template in enumerate(templates):
                    with self.subTest(template=template):
                        work = base / str(index)
                        work.mkdir(mode=0o755)
                        for name in ("fixture.key", "fixture.crt"):
                            (work / name).write_bytes((base / name).read_bytes())
                        for name in ("tls", "web", "body", "proxy", "fastcgi", "uwsgi", "scgi", "public"):
                            (work / name).mkdir(mode=0o755)
                        for name in ("transport-server.crt", "cloud-client-ca.crt", "employee-fullchain.crt"):
                            (work / "tls" / name).write_bytes((base / "fixture.crt").read_bytes())
                        for name in ("transport-server.key", "employee.key"):
                            (work / "tls" / name).write_bytes((base / "fixture.key").read_bytes())
                        font = bytes(range(256)) * 256
                        (work / "web/assets").mkdir()
                        for name, body in {"assets/font.ttf": font, "assets/font.otf": font,
                                           "assets/font.0123456789abcdef.ttf": font,
                                           "main.dart.js": b"console.log(1);" * 512,
                                           "engine.wasm": b"\x00asm" * 2048,
                                           "index.html": b"APPLICATION"}.items():
                            (work / "web" / name).write_bytes(body)
                        remote = "remote-access" in template
                        rendered = fixture.render((ROOT / template).read_text(encoding="utf-8"), work, remote)
                        if not remote:
                            rendered = rendered.replace("http {\n", "http {\ninclude /etc/nginx/mime.types;\n", 1)
                        config = work / "nginx.conf"
                        config.write_text(rendered.replace("/var/lib/uten-imp-public", str(work / "public")))
                        checked = subprocess.run(["nginx", "-t", "-q", "-c", str(config)], capture_output=True, text=True)
                        self.assertEqual(0, checked.returncode, checked.stderr)
                        self.assertNotIn("[warn]", checked.stderr)
                        process = subprocess.Popen(["nginx", "-c", str(config), "-g", "daemon off;"],
                                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        try:
                            fixture.wait_listener()
                            for extension in ("ttf", "otf"):
                                path = "/assets/font." + extension
                                code, headers, compressed = request(work, path)
                                self.assertEqual(200, code)
                                self.assertEqual("font/" + extension, headers["Content-Type"])
                                self.assertEqual("gzip", headers.get("Content-Encoding"))
                                self.assertEqual(font, gzip.decompress(compressed))
                                self.assertLess(len(compressed), len(font) // 2)
                                self.assertIn("Accept-Encoding", headers["Vary"])
                                self.assertIn("no-cache", headers["Cache-Control"])
                                self.assertIn("Content-Security-Policy", headers)
                                self.assertEqual("nosniff", headers["X-Content-Type-Options"])
                                _, plain_headers, plain = request(work, path, "identity")
                                self.assertNotIn("Content-Encoding", plain_headers)
                                self.assertEqual(font, plain)
                            code, headers, _ = request(work, "/assets/font.0123456789abcdef.ttf")
                            self.assertEqual(200, code)
                            if template.endswith("uten-imp-http-lan.conf") or remote:
                                self.assertIn("immutable", headers["Cache-Control"])
                            self.assertEqual(404, request(work, "/assets/missing.ttf")[0])
                            for path, expected in (("/main.dart.js", "application/javascript"),
                                                   ("/engine.wasm", "application/wasm")):
                                code, headers, _ = request(work, path)
                                self.assertEqual(200, code)
                                self.assertEqual(expected, headers["Content-Type"])
                                self.assertNotIn("immutable", headers.get("Cache-Control", ""))
                            code, headers, body = request(work, "/api/attachment/font.ttf")
                            self.assertEqual(200, code)
                            if remote:
                                self.assertNotIn("Content-Encoding", headers)
                                self.assertIn("no-store", headers["Cache-Control"])
                            self.assertEqual(PRIVATE, gzip.decompress(body) if headers.get("Content-Encoding") == "gzip" else body)
                            self.assertEqual(404, request(work, "/.private.ttf")[0])
                        finally:
                            process.terminate()
                            process.wait(timeout=5)
        finally:
            backend.shutdown()
            backend.server_close()


if __name__ == "__main__":
    unittest.main()
