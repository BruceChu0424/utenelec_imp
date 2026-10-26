"""128 MiB synthetic download fixture, bound only to loopback port 53881.

Build tool/b1_stream_download_harness.dart explicitly, then serve that build:
  python tool/serve_b1_stream_harness.py --root <build-dir> --evidence-dir <dir>
No business API, credentials, PostgreSQL or business file is involved.
"""
from argparse import ArgumentParser
from datetime import datetime, timezone
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import BoundedSemaphore, Lock
from urllib.parse import unquote, urlsplit
import functools
import hashlib
import json
import socket
import time

PORT = 53881
FIXTURE_ID = "b1000000-0000-4000-8000-000000000001"
DOWNLOAD_PATH = f"/api/report-export-jobs/{FIXTURE_ID}/download"
BLOCK = bytes(range(256)) * 256
TOTAL_BYTES = 128 * 1024 * 1024
EXPECTED_SHA256 = "a626d17da2e502f5b4b8e3ebd23f0bf9daef6255688d8e0bb482b3ae3794a682"
MODES = frozenset({"ok", "503", "truncate", "disconnect", "corrupt"})
ORIGINS = frozenset({f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"})
EVIDENCE_KINDS = frozenset({
    "b1-report-export-synthetic-ui", "b1-party-read-synthetic-ui", "b1-master-inline-synthetic-ui", "b1-native-facet-synthetic-ui",
    "b1-shipping-synthetic-ui", "b1-stream-download-synthetic-ui",
})


def safe_evidence(value, depth=0, counter=None):
    """Bounded synthetic diagnostic structure; no credentials are accepted."""
    if counter is None:
        counter = [0]
    counter[0] += 1
    if depth > 20 or counter[0] > 20000:
        return False
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str) or len(key) > 100:
                return False
            lowered = key.lower()
            if any(secret in lowered for secret in ("password", "token", "secret", "authorization", "cookie")):
                return False
            if not safe_evidence(child, depth + 1, counter):
                return False
        return True
    if isinstance(value, list):
        return all(safe_evidence(child, depth + 1, counter) for child in value)
    if isinstance(value, str):
        return len(value) <= 50000 and not value.lower().startswith("bearer ")
    return value is None or isinstance(value, (bool, int, float))


def fixture_sha256():
    digest = hashlib.sha256()
    for _ in range(TOTAL_BYTES // len(BLOCK)):
        digest.update(BLOCK)
    return digest.hexdigest()


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 8


class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(30)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "
            "style-src 'self' 'unsafe-inline'; connect-src 'self'; "
            "img-src 'self' data: blob:; font-src 'self'; worker-src 'self' blob:; "
            "object-src 'none'; base-uri 'self'; frame-ancestors 'none'",
        )
        super().end_headers()

    def _json(self, status, message):
        data = json.dumps({"code": "SYNTHETIC_FIXTURE", "message": message}).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        self.wfile.write(data)

    def _local_request(self):
        host = self.headers.get("Host", "")
        origin = self.headers.get("Origin")
        return (
            host in {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}
            and (origin is None or origin in ORIGINS)
            and self.client_address[0] == "127.0.0.1"
        )

    def _rejected(self, reason):
        # Existence flags only. Never persist incoming credentials, header
        # values, request bodies, query strings, business IDs or peer addresses.
        record = {
            "recordedUtc": datetime.now(timezone.utc).isoformat(),
            "outcome": "rejected",
            "reason": reason,
            "hasAuthorization": bool(self.headers.get("Authorization")),
            "hasCookie": bool(self.headers.get("Cookie")),
        }
        with self.server.evidence_lock:
            with (self.server.evidence_dir / "stream-server-results.jsonl").open("a", encoding="utf-8") as output:
                output.write(json.dumps(record) + "\n")
            print(json.dumps(record), flush=True)

    def list_directory(self, path):
        self._json(403, "Directory listings are disabled")
        return None

    def do_GET(self):
        if not self._local_request() or urlsplit(self.path).path.startswith("/api"):
            self._json(404, "Only static harness assets and the exact fixture download are available")
            return
        resolved = Path(self.translate_path(unquote(urlsplit(self.path).path))).resolve()
        if not resolved.is_relative_to(self.server.asset_root):
            self._json(403, "Asset path is outside the fixture build")
            return
        super().do_GET()

    def do_HEAD(self):
        if not self._local_request() or urlsplit(self.path).path.startswith("/api"):
            self._json(404, "Unsupported fixture endpoint")
            return
        resolved = Path(self.translate_path(unquote(urlsplit(self.path).path))).resolve()
        if not resolved.is_relative_to(self.server.asset_root):
            self._json(403, "Asset path is outside the fixture build")
            return
        super().do_HEAD()

    def do_POST(self):
        if not self._local_request() or self.path not in {DOWNLOAD_PATH, "/b0-results"}:
            self._rejected("non-fixture-request")
            self._json(404, "Unsupported fixture endpoint")
            return
        # A dedicated synthetic origin must never accept real account material.
        if self.headers.get("Authorization") or self.headers.get("Cookie"):
            self._rejected("credentials-forbidden")
            self._json(403, "Credentials are forbidden in this synthetic fixture")
            return
        if self.path == "/b0-results":
            self._evidence()
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 1024 or self.headers.get("Transfer-Encoding"):
                self._json(413, "Fixture request must be bounded JSON")
                return
            body = json.loads(self.rfile.read(size))
            mode = body.get("fixtureMode") if isinstance(body, dict) else None
            if mode not in MODES:
                self._json(400, "Unknown fixture mode")
                return
        except (ValueError, TypeError, UnicodeError):
            self._json(400, "Invalid fixture request")
            return
        if not self.server.transfers.acquire(blocking=False):
            self._json(503, "Synthetic transfer concurrency limit reached")
            return
        started = time.monotonic()
        sent = 0
        outcome = "completed"
        try:
            if mode == "503":
                self._json(503, "Synthetic server failure; retry the same fixture")
                outcome = "503"
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(TOTAL_BYTES))
            self.send_header("Content-Disposition", 'attachment; filename="b1-stream-128MiB.bin"')
            self.send_header("X-Synthetic-SHA256", EXPECTED_SHA256)
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            stop_after = {"truncate": 8 * 1024 * 1024, "disconnect": 1024 * 1024}.get(mode, TOTAL_BYTES)
            while sent < stop_after:
                block = BLOCK
                if mode == "corrupt" and sent == 0:
                    block = bytes([BLOCK[0] ^ 1]) + BLOCK[1:]
                self.wfile.write(block)
                self.wfile.flush()
                sent += len(block)
                time.sleep(self.server.chunk_delay_ms / 1000)
            if mode == "disconnect":
                outcome = "deliberate-disconnect"
                self.connection.shutdown(socket.SHUT_RDWR)
            elif mode == "truncate":
                outcome = "deliberate-truncation"
                self.connection.shutdown(socket.SHUT_WR)
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError) as error:
            outcome = type(error).__name__
        finally:
            self.server.transfers.release()
            record = {
                "recordedUtc": datetime.now(timezone.utc).isoformat(),
                "mode": mode,
                "expectedBytes": TOTAL_BYTES,
                "declaredBytes": TOTAL_BYTES if mode != "503" else None,
                "sentBytes": sent,
                "writeChunkBytes": len(BLOCK),
                "chunkDelayMs": self.server.chunk_delay_ms,
                "elapsedMs": (time.monotonic() - started) * 1000,
                "outcome": outcome,
                "expectedSha256": EXPECTED_SHA256,
            }
            with self.server.evidence_lock:
                with (self.server.evidence_dir / "stream-server-results.jsonl").open("a", encoding="utf-8") as output:
                    output.write(json.dumps(record, ensure_ascii=False) + "\n")
                print(json.dumps(record, ensure_ascii=False), flush=True)

    def _evidence(self):
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 200000 or self.headers.get("Transfer-Encoding"):
                self._json(413, "Synthetic metrics exceed collector bounds")
                return
            value = json.loads(self.rfile.read(size), parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite")))
            if not isinstance(value, dict) or value.get("kind") not in EVIDENCE_KINDS or not safe_evidence(value):
                self._rejected("invalid-synthetic-evidence")
                self._json(400, "Only typed synthetic metrics without credentials are accepted")
                return
        except (ValueError, TypeError, UnicodeError):
            self._rejected("invalid-synthetic-evidence")
            self._json(400, "Invalid synthetic metrics")
            return
        value["recordedUtc"] = datetime.now(timezone.utc).isoformat()
        with self.server.evidence_lock:
            with (self.server.evidence_dir / "browser-results.jsonl").open("a", encoding="utf-8") as output:
                output.write(json.dumps(value, ensure_ascii=False) + "\n")
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def log_message(self, fmt, *values):
        # Evidence contains fixture metrics only, never incoming headers/body.
        pass


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="Explicit synthetic Flutter web build directory")
    parser.add_argument("--evidence-dir", required=True)
    parser.add_argument("--chunk-delay-ms", type=int, default=6, choices=range(1, 101))
    args = parser.parse_args()
    root = Path(args.root).resolve(strict=True)
    if not root.is_dir() or not (root / "index.html").is_file():
        parser.error("--root must contain the explicit harness web build index.html")
    evidence = Path(args.evidence_dir).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    server = FixtureServer(("127.0.0.1", PORT), functools.partial(Handler, directory=str(root)))
    server.asset_root = root
    server.evidence_dir = evidence
    server.evidence_lock = Lock()
    server.transfers = BoundedSemaphore(2)
    server.chunk_delay_ms = args.chunk_delay_ms
    print(f"Synthetic stream harness http://127.0.0.1:{PORT}; SHA-256 {EXPECTED_SHA256}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
