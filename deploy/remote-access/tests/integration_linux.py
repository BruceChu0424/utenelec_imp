#!/usr/bin/env python3
"""Real nested TLS / Nginx regression, entirely in a disposable Linux container.

No published ports, no production data. Test keys are temporary and never logged.
Run with NET_ADMIN only if --firewall is selected; never run on a company host.
"""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("unit_contract", ROOT / "test_remote_access.py")
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


def command(args, **kwargs):
    result = subprocess.run(args, capture_output=True, timeout=30, **kwargs)
    if result.returncode:
        detail = result.stderr.decode(errors="replace") if isinstance(result.stderr, bytes) else result.stderr
        raise AssertionError("isolated tool failed: " + args[0] + "\n" + detail[:2000])
    return result


def make_ca(directory, name):
    command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
             "-subj", "/CN=" + name, "-keyout", str(directory / (name + ".key")),
             "-out", str(directory / (name + ".crt"))])


def make_cert(directory, name, ca, dns, client=False):
    command(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=" + dns,
             "-keyout", str(directory / (name + ".key")), "-out", str(directory / (name + ".csr"))])
    ext = directory / (name + ".ext")
    ext.write_text(f"basicConstraints=CA:FALSE\nsubjectAltName=DNS:{dns}\nextendedKeyUsage={'clientAuth' if client else 'serverAuth'}\n")
    command(["openssl", "x509", "-req", "-in", str(directory / (name + ".csr")),
             "-CA", str(directory / (ca + ".crt")), "-CAkey", str(directory / (ca + ".key")),
             "-CAcreateserial", "-days", "2", "-extfile", str(ext), "-out", str(directory / (name + ".crt"))])


class Backend(BaseHTTPRequestHandler):
    posts = 0
    last_headers = {}

    def do_GET(self):
        type(self).last_headers = dict(self.headers)
        body = b'{"status":"UP"}' if self.path.startswith("/actuator/") else b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "public, max-age=86400")  # proxy must replace this
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        type(self).posts += 1
        # Simulate committed work followed by response loss. It must not be retried.
        self.connection.shutdown(socket.SHUT_RDWR)
        self.connection.close()

    def log_message(self, *args):
        pass


def employee_request(directory, path="/api/test", method="GET", body=None, headers=None, hostname="erp.example.test"):
    context = ssl.create_default_context(cafile=str(directory / "employee-ca.crt"))
    raw = socket.create_connection(("127.0.0.1", 18444), timeout=5)
    encrypted = context.wrap_socket(raw, server_hostname=hostname)
    connection = http.client.HTTPConnection("erp.example.test", timeout=5)
    connection.sock = encrypted
    try:
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        connection.close()


def wait_listener(port):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=.2):
                return
        except OSError:
            time.sleep(.05)
    raise AssertionError("isolated listener failed to start")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--firewall", action="store_true")
    args = parser.parse_args()
    if not Path("/.dockerenv").exists():
        raise SystemExit("This test must run in its disposable Docker container.")
    processes = []
    backend = ThreadingHTTPServer(("127.0.0.1", 18082), Backend)
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="uten-remote-test-") as temporary:
        directory = Path(temporary)
        directory.chmod(0o755)  # Nginx workers can read the deliberately public test web files.
        try:
            for ca in ("transport-server-ca", "cloud-client-ca", "employee-ca", "untrusted-ca"):
                make_ca(directory, ca)
            make_cert(directory, "transport-server", "transport-server-ca", "transport.uten.internal")
            make_cert(directory, "cloud-client", "cloud-client-ca", "cloud-client", client=True)
            make_cert(directory, "untrusted-client", "untrusted-ca", "untrusted-client", client=True)
            make_cert(directory, "employee", "employee-ca", "erp.example.test")
            (directory / "employee-fullchain.crt").write_bytes((directory / "employee.crt").read_bytes())
            web = directory / "web"
            web.mkdir()
            (web / "index.html").write_text("<!doctype html><title>isolated</title>")
            (web / "app.12345678.js").write_text("const test = 1;")
            (web / "flutter_bootstrap.js").write_text("const bootstrap = 1;")
            configs = contract.remote.files(contract.profile())
            for role in ("company", "cloud"):
                work = directory / role
                work.mkdir()
                for cache in ("body", "proxy", "fastcgi", "uwsgi", "scgi"):
                    (work / cache).mkdir()
                config = configs[f"{role}/nginx.conf"]
                # Only test socket/path substitution, not altered TLS or proxy policy.
                for old, new in (("/etc/uten-remote/tls", str(directory)), ("/var/log/uten-remote", str(work)),
                                 ("/var/cache/uten-remote", str(work)), ("/run/uten-remote", str(work)),
                                 ("/opt/uten-imp/current/web", str(web)), ("0.0.0.0:443", "127.0.0.1:18444"),
                                 ("10.77.0.2:8443", "127.0.0.1:18443"), ("allow 10.77.0.1;", "allow 127.0.0.1;"),
                                 ("127.0.0.1:9443", "127.0.0.1:19443"), ("127.0.0.1:8082", "127.0.0.1:18082")):
                    config = config.replace(old, new)
                path = work / "nginx.conf"
                path.write_text(config)
                command(["nginx", "-t", "-q", "-c", str(path)])
                processes.append(subprocess.Popen(["nginx", "-c", str(path), "-g", "daemon off;"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            wait_listener(18443)
            wait_listener(18444)
            status, headers, data = employee_request(directory, headers={"X-Forwarded-For": "127.0.0.99", "Forwarded": "for=evil", "X-Uten-Source": "local", "Authorization": "Bearer TEST_ONLY_SECRET"})
            assert status == 200 and data == b'{"ok":true}'
            assert headers["Cache-Control"] == "private, no-store"
            assert Backend.last_headers["X-Forwarded-For"] == "127.0.0.1"
            assert "Forwarded" not in Backend.last_headers and "X-Uten-Source" not in Backend.last_headers
            assert Backend.last_headers["Authorization"] == "Bearer TEST_ONLY_SECRET"
            assert employee_request(directory, "/actuator/health/readiness")[0] == 200
            for blocked in ("/actuator/env", "/actuator/health/secret", "/api/system-test/business-data/reset", "/api/visitor/auth/login", "/api/website-inquiries/ingest"):
                assert employee_request(directory, blocked)[0] == 404, blocked
            # The real website integration uses POST with a machine token. It must
            # remain unreachable even if such a token is supplied to this entry.
            before_ingest = Backend.posts
            assert employee_request(directory, "/api/website-inquiries/ingest", "POST", b"{}",
                                    {"Content-Type": "application/json", "X-Uten-Ingest-Token": "TEST_ONLY_MACHINE_TOKEN"})[0] == 404
            assert Backend.posts == before_ingest
            assert "immutable" in employee_request(directory, "/app.12345678.js")[1]["Cache-Control"]
            assert employee_request(directory, "/flutter_bootstrap.js")[1]["Cache-Control"] == "no-cache"
            assert employee_request(directory, "/missing.js")[0] == 404
            assert employee_request(directory, "/api/test", "POST", b"x" * (2 * 1024 * 1024 + 1))[0] == 413
            status = employee_request(directory, "/api/test", "POST", b"mutation")[0]
            assert status == 502 and Backend.posts == 1
            try:
                employee_request(directory, hostname="wrong.example.test")
                raise AssertionError("wrong inner TLS hostname accepted")
            except ssl.SSLCertVerificationError:
                pass
            # A tunnel peer without the cloud mTLS identity cannot reach employee TLS.
            for invalid_client in (None, "untrusted-client"):
                context = ssl.create_default_context(cafile=str(directory / "transport-server-ca.crt"))
                if invalid_client:
                    context.load_cert_chain(str(directory / (invalid_client + ".crt")), str(directory / (invalid_client + ".key")))
                denied = False
                try:
                    with context.wrap_socket(socket.create_connection(("127.0.0.1", 18443), timeout=3), server_hostname="transport.uten.internal") as stream:
                        stream.sendall(b"GET / HTTP/1.0\r\n\r\n")
                        denied = stream.recv(1024) == b""
                except (ssl.SSLError, OSError):
                    denied = True
                assert denied, "missing/untrusted cloud certificate accepted"
            # Browser-style verified TLS remains end-to-end even with five concurrent sessions.
            with ThreadPoolExecutor(max_workers=5) as pool:
                assert all(code == 200 for code in pool.map(lambda _: employee_request(directory)[0], range(10)))
            for log in directory.glob("*/*.log"):
                assert b"TEST_ONLY_SECRET" not in log.read_bytes()
            # Optional namespace-local actual egress isolation; container needs NET_ADMIN.
            if args.firewall:
                rule = directory / "firewall.nft"
                rule.write_text(configs["company/firewall.nft"])
                command(["nft", "--check", "-f", str(rule)])
                command(["nft", "-f", str(rule)])
                import pwd
                uid = pwd.getpwnam("uten-remote").pw_uid
                fake_db = socket.socket()
                fake_db.bind(("127.0.0.1", 5432))
                fake_db.listen()
                # Existing backend is on a test port, so an allowed-port listener is separate.
                permitted = socket.socket()
                permitted.bind(("127.0.0.1", 8082))
                permitted.listen()
                code = "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=1).close()"
                good = subprocess.run(["python3", "-c", code, "8082"], preexec_fn=lambda: os.setuid(uid), capture_output=True, timeout=3)
                bad = subprocess.run(["python3", "-c", code, "5432"], preexec_fn=lambda: os.setuid(uid), capture_output=True, timeout=3)
                assert good.returncode == 0 and bad.returncode != 0
                permitted.close()
                fake_db.close()
                command(["nft", "delete", "table", "inet", "uten_remote"])
            print(json.dumps({"result": "PASS", "nested_tls": True, "missing_client_certificate_rejected": True,
                              "untrusted_client_certificate_rejected": True,
                              "employee_hostname_verified": True, "forged_headers_removed": True,
                              "committed_post_not_retried": True, "cache_and_upload_contract": True,
                              "website_machine_ingest_blocked": True,
                              "process_database_egress_blocked": args.firewall}))
        finally:
            for process in processes:
                process.terminate()
            for process in processes:
                process.wait(timeout=5)
            backend.shutdown()


if __name__ == "__main__":
    main()
