"""POSIX socket/process tests with a fake converter; no LibreOffice claims are made."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("preview_worker", HERE / "preview_worker.py")
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)
PROFILE = HERE.parents[1] / "server/src/main/resources/attachment-preview-safe-profile.xcu"


@unittest.skipUnless(os.name == "posix", "requires POSIX Unix sockets and process groups")
class PreviewWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.work = self.directory / "work"
        self.work.mkdir()
        self.profile = self.directory / "safe-profile.xcu"
        self.profile.write_bytes(PROFILE.read_bytes())
        self.profile.chmod(0o644)
        self.pids = self.directory / "pids.json"
        self.converter = self.directory / "fake-converter"
        self.converter.write_text(f"#!{sys.executable}\n" + """
import json, os, pathlib, sys, time
source=pathlib.Path(sys.argv[-1]); output=pathlib.Path(sys.argv[sys.argv.index('--outdir')+1])/'source.pdf'
mode=source.read_bytes()
if mode==b'EXIT': sys.exit(2)
if mode==b'MISSING': sys.exit(0)
if mode in (b'SLEEP',b'FORK'):
    child=os.fork() if mode==b'FORK' else 0
    if child or mode==b'SLEEP':
        pathlib.Path(PID_PATH).write_text(json.dumps([os.getpid(),child]))
    time.sleep(120)
if mode==b'BADPDF': output.write_bytes(b'<script>not a PDF</script>')
elif mode==b'OVERSIZE': output.write_bytes(b'%PDF-'+b'x'*4096)
elif mode==b'SYMLINK': output.symlink_to(source)
else:
    profile=pathlib.Path(next(v.split('=',1)[1][7:] for v in sys.argv if v.startswith('-env:UserInstallation=')))
    settings=(profile/'user/registrymodifications.xcu').read_text()
    output.write_bytes(b'%PDF-1.7\\n'+json.dumps({'environment':dict(os.environ),'settings':settings,'cwd':os.getcwd()}).encode())
""".replace("PID_PATH", repr(str(self.pids))), encoding="utf-8")
        self.converter.chmod(0o755)
        self.clients = []
        self.threads = []

    def tearDown(self):
        for client in self.clients:
            client.close()
        for thread in self.threads:
            thread.join(5)
            self.assertFalse(thread.is_alive())
        self.temporary.cleanup()

    def start(self):
        server, client = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        self.clients.append(client)
        def run():
            with server:
                worker.serve(server, converter=str(self.converter), template=self.profile, work_root=self.work)
        thread = threading.Thread(target=run, daemon=True)
        self.threads.append(thread)
        thread.start()
        return client, thread

    def request(self, content=b"OK", **changes):
        header = {"version": 1, "extension": "docx", "sourceBytes": len(content),
                  "sha256": hashlib.sha256(content).hexdigest(), "timeoutSeconds": 3,
                  "maxOutputBytes": worker.MAX_OUTPUT_BYTES}
        header.update(changes)
        client, thread = self.start()
        encoded = json.dumps(header).encode()
        client.sendall(struct.pack("!I", len(encoded)) + encoded + content)
        return client, thread

    def exact(self, client, length):
        result = b""
        while len(result) < length:
            chunk = client.recv(length - len(result))
            self.assertTrue(chunk)
            result += chunk
        return result

    def response(self, client):
        length = struct.unpack("!I", self.exact(client, 4))[0]
        self.assertLessEqual(length, worker.MAX_HEADER_BYTES)
        header = json.loads(self.exact(client, length))
        body = self.exact(client, header["sizeBytes"]) if header["ok"] else b""
        if body:
            self.assertEqual(hashlib.sha256(body).hexdigest(), header["sha256"])
        return header, body

    def test_success_has_exact_digest_safe_profile_clean_environment_and_cleanup(self):
        os.environ["UTEN_WORKER_TEST_SECRET"] = "never-inherit-this-secret"
        try:
            client, thread = self.request()
            header, body = self.response(client)
            self.assertTrue(header["ok"])
            observed = json.loads(body.split(b"\n", 1)[1])
            self.assertNotIn("UTEN_WORKER_TEST_SECRET", observed["environment"])
            self.assertIn("MacroSecurityLevel", observed["settings"])
            self.assertIn("DisableMacrosExecution", observed["settings"])
            self.assertEqual(observed["environment"]["HOME"], observed["cwd"])
            thread.join(3)
            self.assertFalse(list(self.work.iterdir()))
        finally:
            del os.environ["UTEN_WORKER_TEST_SECRET"]

    def test_rejects_unknown_version_path_command_oversize_invalid_types_and_digest(self):
        for changes, expected in [({"version": 2}, "INVALID_REQUEST"),
                ({"extension": "../../etc/passwd"}, "INVALID_REQUEST"),
                ({"command": "/bin/sh"}, "INVALID_REQUEST"),
                ({"sourceBytes": worker.MAX_SOURCE_BYTES + 1}, "INPUT_TOO_LARGE"),
                ({"sourceBytes": True}, "INVALID_REQUEST"),
                ({"timeoutSeconds": 61}, "INVALID_REQUEST"),
                ({"maxOutputBytes": worker.MAX_OUTPUT_BYTES + 1}, "INVALID_REQUEST"),
                ({"sha256": "0" * 64}, "INTEGRITY_MISMATCH")]:
            with self.subTest(changes=changes):
                client, thread = self.request(**changes)
                self.assertEqual(self.response(client)[0]["error"], expected)
                thread.join(2)
                self.assertFalse(list(self.work.iterdir()))

    def test_rejects_truncated_headers_body_duplicate_keys_and_oversize_header(self):
        for payload, expected in [(struct.pack("!I", 4097), "INVALID_REQUEST"),
                (struct.pack("!I", 26) + b'{"version":1,"version":1}', "INCOMPLETE_INPUT")]:
            client, thread = self.start()
            client.sendall(payload)
            client.shutdown(socket.SHUT_WR)
            self.assertEqual(self.response(client)[0]["error"], expected)
        duplicate = b'{"version":1,"version":1}'
        client, thread = self.start()
        client.sendall(struct.pack("!I", len(duplicate)) + duplicate)
        self.assertEqual(self.response(client)[0]["error"], "INVALID_REQUEST")
        nested = b"[" * 1500 + b"]" * 1500
        client, thread = self.start()
        client.sendall(struct.pack("!I", len(nested)) + nested)
        self.assertEqual(self.response(client)[0]["error"], "INVALID_REQUEST")
        client, thread = self.request(sourceBytes=3)
        client.shutdown(socket.SHUT_WR)
        self.assertEqual(self.response(client)[0]["error"], "INCOMPLETE_INPUT")

    def test_rejects_bad_missing_oversize_and_symlink_outputs(self):
        for mode, changes, expected in [(b"EXIT", {}, "CONVERSION_FAILED"),
                (b"MISSING", {}, "INVALID_OUTPUT"),
                (b"BADPDF", {}, "INVALID_OUTPUT"), (b"SYMLINK", {}, "INVALID_OUTPUT"),
                (b"OVERSIZE", {"maxOutputBytes": 100}, "OUTPUT_TOO_LARGE")]:
            with self.subTest(mode=mode):
                client, thread = self.request(mode, **changes)
                self.assertEqual(self.response(client)[0]["error"], expected)
                thread.join(2)
                self.assertFalse(list(self.work.iterdir()))

    def dead(self, pid):
        if not pid:
            return True
        try:
            os.kill(pid, 0)
            state = Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()[0]
            return state == "Z"
        except (ProcessLookupError, FileNotFoundError):
            return True

    def test_timeout_kills_converter_group_and_cleans_work(self):
        client, thread = self.request(b"FORK", timeoutSeconds=1)
        self.assertEqual(self.response(client)[0]["error"], "CONVERSION_TIMEOUT")
        thread.join(3)
        self.assertTrue(all(self.dead(pid) for pid in json.loads(self.pids.read_text())))
        self.assertFalse(list(self.work.iterdir()))

    def test_disconnect_kills_converter_group_and_cleans_work(self):
        client, thread = self.request(b"FORK", timeoutSeconds=10)
        deadline = time.monotonic() + 3
        while not self.pids.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(self.pids.exists())
        client.close()
        thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertTrue(all(self.dead(pid) for pid in json.loads(self.pids.read_text())))
        self.assertFalse(list(self.work.iterdir()))

    def test_service_contract_hides_credentials_media_and_host_run_and_limits_workers(self):
        service = (HERE / "uten-imp-preview@.service").read_text()
        activation = (HERE / "uten-imp-preview.socket").read_text()
        for setting in ("CollectMode=inactive-or-failed", "DynamicUser=yes", "PrivateNetwork=yes", "RestrictAddressFamilies=AF_UNIX",
                        "ProtectSystem=strict", "ProtectHome=yes", "ProtectProc=invisible",
                        "NoNewPrivileges=yes", "TemporaryFileSystem=/run:", "KillMode=control-group",
                        "RuntimeMaxSec=90", "MemoryMax=768M", "LimitCORE=0", "/etc/uten-imp", "/var/lib/uten-imp-media", "/opt/uten-imp"):
            self.assertIn(setting, service)
        for setting in ("Accept=yes", "MaxConnections=2", "SocketGroup=uten-imp", "SocketMode=0660", "RemoveOnStop=yes"):
            self.assertIn(setting, activation)


if __name__ == "__main__":
    unittest.main()
