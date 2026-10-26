"""Real POSIX socket/client probes; no system converter or production socket is used."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

LAUNCHER = Path(__file__).resolve().parents[1] / "simple/host/uten-preview-soffice.py"

@unittest.skipUnless(os.name == "posix", "Linux/POSIX socket and private-directory probes")
class PosixLauncherTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="upc-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.work = self.root / "private conversion work"
        self.work.mkdir(mode=0o700)
        self.original = b"synthetic private document\n" * 100
        self.source = self.work / "source.docx"
        self.source.write_bytes(self.original)
        self.socket_path = str(self.root / "worker.sock")
        self.recorded = {}
        self.errors = []
        self.harness = '''import importlib.util,sys
spec=importlib.util.spec_from_file_location("launcher",sys.argv[1])
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.WORKER_SOCKET=sys.argv[2]
module.REQUEST_SECONDS=float(sys.argv[3])
sys.argv=[sys.argv[1],*sys.argv[4:]]
raise SystemExit(module.main())
'''

    def args(self):
        return ["--headless", "--norestore", "--nologo", "--nolockcheck",
                "-env:UserInstallation=" + (self.work / "profile").as_uri() + "/",
                "--convert-to", "pdf", "--outdir", str(self.work), str(self.source)]

    def run_launcher(self, args=None, isolated=True, seconds=3):
        command = [sys.executable, *(["-I"] if isolated else []), "-c", self.harness,
                   str(LAUNCHER), self.socket_path, str(seconds), *(self.args() if args is None else args)]
        return subprocess.run(command, cwd=self.work,
                              env=dict(os.environ, UTEN_DB_PASSWORD="synthetic-never-send-secret"),
                              capture_output=True, text=True, timeout=10)

    @staticmethod
    def read_exact(connection, length):
        data = bytearray()
        while len(data) < length:
            chunk = connection.recv(length - len(data))
            if not chunk:
                raise ValueError("fixture unexpected EOF")
            data.extend(chunk)
        return bytes(data)

    def serve(self, responder):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.socket_path)
        listener.listen(1)
        listener.settimeout(5)
        def run():
            try:
                with listener, listener.accept()[0] as connection:
                    connection.settimeout(5)
                    length = struct.unpack("!I", self.read_exact(connection, 4))[0]
                    self.recorded["header"] = json.loads(self.read_exact(connection, length))
                    self.recorded["body"] = self.read_exact(connection, self.recorded["header"]["sourceBytes"])
                    responder(connection)
            except Exception as error:
                self.errors.append(error)
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 6)
        return thread

    @staticmethod
    def response(connection, pdf=b"%PDF-1.7\nsynthetic regression PDF\n%%EOF\n", **changes):
        header = {"version": 1, "ok": True, "sizeBytes": len(pdf),
                  "sha256": hashlib.sha256(pdf).hexdigest()}
        header.update(changes)
        encoded = json.dumps(header).encode()
        connection.sendall(struct.pack("!I", len(encoded)) + encoded + pdf)

    def assert_refused(self, result):
        self.assertEqual(69, result.returncode, result.stderr)
        self.assertEqual("", result.stdout)
        self.assertEqual("UTEN_PREVIEW_ISOLATED_WORKER_UNAVAILABLE\n", result.stderr)
        self.assertFalse((self.work / "source.pdf").exists())
        self.assertEqual([], list(self.work.glob(".preview-response-*")))

    def test_real_socket_transfers_only_source_and_fixed_contract_then_publishes_exact_pdf(self):
        pdf = b"%PDF-1.7\nsynthetic verified output\n%%EOF\n"
        thread = self.serve(lambda connection: self.response(connection, pdf))
        result = self.run_launcher()
        thread.join(5)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.errors)
        self.assertEqual(self.original, self.recorded["body"])
        self.assertEqual({"version": 1, "extension": "docx", "sourceBytes": len(self.original),
                          "sha256": hashlib.sha256(self.original).hexdigest(), "timeoutSeconds": 60,
                          "maxOutputBytes": 64 * 1024 * 1024}, self.recorded["header"])
        self.assertNotIn(str(self.work), json.dumps(self.recorded["header"]))
        self.assertNotIn("synthetic-never-send-secret", repr(self.recorded))
        self.assertEqual(pdf, (self.work / "source.pdf").read_bytes())
        self.assertEqual(0o600, (self.work / "source.pdf").stat().st_mode & 0o777)

    def test_hash_signature_size_and_version_failures_never_publish_partial_output(self):
        cases = [(b"%PDF-1.7\nwrong hash", {"sha256": "a" * 64}),
                 (b"not-a-pdf", {}), (b"%PDF-1.7\ntruncated", {"sizeBytes": 999}),
                 (b"", {"sizeBytes": 64 * 1024 * 1024 + 1}),
                 (b"%PDF-1.7\nwrong version", {"version": True})]
        for pdf, changes in cases:
            with self.subTest(changes=changes):
                Path(self.socket_path).unlink(missing_ok=True)
                thread = self.serve(lambda connection, p=pdf, c=changes: self.response(connection, p, **c))
                self.assert_refused(self.run_launcher())
                thread.join(5)

    def test_duplicate_or_oversized_headers_are_rejected_before_output_creation(self):
        for encoded in (b'{"version":1,"version":1,"ok":true}', b'x' * 4097):
            with self.subTest(size=len(encoded)):
                Path(self.socket_path).unlink(missing_ok=True)
                thread = self.serve(lambda connection, data=encoded:
                                    connection.sendall(struct.pack("!I", len(data)) + data))
                self.assert_refused(self.run_launcher())
                thread.join(5)

    def test_one_deadline_covers_waiting_for_a_slow_worker(self):
        thread = self.serve(lambda connection: time.sleep(0.5))
        start = time.monotonic()
        self.assert_refused(self.run_launcher(seconds=0.1))
        self.assertLess(time.monotonic() - start, 2)
        thread.join(5)

    def test_missing_worker_does_not_fall_back_to_a_local_converter(self):
        self.assert_refused(self.run_launcher())

    def test_unexpected_arguments_and_paths_are_refused(self):
        for index, value in ((0, "--accept=socket"), (6, "html"), (8, str(self.root)),
                             (9, str(self.root / "source.docx")), (9, str(self.work / "source.exe")),
                             (4, "-env:UserInstallation=file:///etc/uten-imp")):
            with self.subTest(index=index, value=value):
                args = self.args()
                args[index] = value
                self.assert_refused(self.run_launcher(args))

    def test_source_symlink_is_not_followed(self):
        outside = self.root / "private outside input"
        outside.write_bytes(b"outside")
        self.source.unlink()
        self.source.symlink_to(outside)
        self.assert_refused(self.run_launcher())

    def test_nonprivate_work_directory_is_refused(self):
        for mode in (0o755, 0o750, 0o770, 0o777):
            with self.subTest(mode=mode):
                self.work.chmod(mode)
                self.assert_refused(self.run_launcher())
        self.work.chmod(0o700)

    def test_existing_output_symlink_is_never_replaced(self):
        outside = self.root / "do-not-overwrite"
        outside.write_bytes(b"preserve")
        (self.work / "source.pdf").symlink_to(outside)
        result = self.run_launcher()
        self.assertEqual(69, result.returncode)
        self.assertEqual(b"preserve", outside.read_bytes())
        self.assertTrue((self.work / "source.pdf").is_symlink())

    def test_nonisolated_python_is_refused_without_echoing_arguments(self):
        result = self.run_launcher(["PRIVATE_ARG_SENTINEL"], isolated=False)
        self.assertEqual(78, result.returncode)
        self.assertEqual("", result.stdout)
        self.assertEqual("UTEN_PREVIEW_ISOLATED_PYTHON_REQUIRED\n", result.stderr)

if __name__ == "__main__":
    unittest.main()
