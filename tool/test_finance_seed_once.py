"""Anonymous real HTTP adapter tests; no company account, documents or database."""
from contextlib import contextmanager
from copy import deepcopy
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
import uuid
import zipfile

spec = importlib.util.spec_from_file_location("finance_seed_once", Path(__file__).with_name("finance_seed_once.py"))
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)
PYTHON = sys.executable if Path(sys.executable).is_file() else str(Path(sys.executable) / "bin/python.exe")
if not Path(PYTHON).is_file():
    PYTHON = shutil.which("python")


class World:
    def __init__(self):
        self.actor, self.dataset = str(uuid.uuid4()), str(uuid.uuid4())
        self.posts, self.gets, self.resources, self.nonces, self.originals = [], [], {}, {}, {}
        self.loss, self.gate, self.reached = None, None, threading.Event()
        self.mapping = "mapping-original"
        self.redirect, self.status = None, None

    def preview(self, query, path, body):
        if "multipart" in self.content_type:
            file = body.split(b"\r\n\r\n", 1)[1].rsplit(b"\r\n--", 1)[0]
        else:
            file = body
        identity = seed.sha(file)
        nonce = query.get("requestId")
        if nonce and nonce in self.nonces:
            return self.resources[self.nonces[nonce]]
        key = (path, identity, tuple(sorted((k, v) for k, v in query.items() if k != "requestId")))
        if key in self.originals:
            return self.resources[self.originals[key]]
        rid = str(uuid.uuid4())
        value = {"importId": rid, "sha256": identity, "rows": [{}] * 177, "issues": [],
                 "applied": False, "directoryApplied": False, "currencyMappingFingerprint": self.mapping,
                 "privateNumber": "123456789.123456789012345678901234"}
        if "accounting" in path:
            value.update(kind=query["kind"], sourceSystem=query["sourceSystem"], status="PREVIEW")
        elif "auxiliary" in path:
            value.update(receivable=query["side"] == "receivable", **{k: query[k] for k in
                         ("sourceSystem", "currencyId", "dateFrom", "dateTo")})
        elif "template" in path:
            value.update(**{k: query[k] for k in ("template", "period", "sourceSheet")})
        value["_file"] = file
        self.resources[rid], self.originals[key] = value, rid
        if nonce:
            self.nonces[nonce] = rid
        return value


@contextmanager
def http_world():
    world = World()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send_value(self, value, code=200, raw=False):
            data = value if raw else json.dumps({k: v for k, v in value.items() if k != "_file"}).encode()
            try:
                self.send_response(code)
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            path = urllib.parse.urlsplit(self.path).path
            world.gets.append(path)
            if world.redirect:
                self.send_response(307)
                self.send_header("Location", world.redirect)
                self.end_headers()
            elif world.status:
                self.send_value({"code": "VALIDATION_FAILED", "message": "secret-private-value"}, world.status)
            elif path.endswith("/auth/me"):
                self.send_value({"id": world.actor, "businessDatasetId": world.dataset,
                                 "businessResetGeneration": 0, "permissions": list(seed.REQUIRED_PERMISSIONS)})
            elif "/operations/" in path:
                nonce = path.rsplit("/", 1)[1]
                if nonce not in world.nonces:
                    self.send_value({"code": "NOT_FOUND"}, 404)
                else:
                    self.send_value({"requestId": nonce, "preview": {k: v for k, v in
                                    world.resources[world.nonces[nonce]].items() if k != "_file"}})
            elif path.endswith("/compare"):
                self.send_value({"issues": []})
            else:
                rid = path.split("/")[-2] if path.endswith("/file") else path.rsplit("/", 1)[1]
                if rid not in world.resources:
                    self.send_value({"code": "NOT_FOUND"}, 404)
                else:
                    value = world.resources[rid]
                    self.send_value(value["_file"] if path.endswith("/file") else value,
                                    raw=path.endswith("/file"))

        def do_POST(self):
            path = urllib.parse.urlsplit(self.path).path
            query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query))
            body = self.rfile.read(int(self.headers["Content-Length"]))
            world.content_type = self.headers.get("Content-Type", "")
            world.posts.append({"path": path, "query": query, "body": body,
                                "contentType": world.content_type})
            if path.endswith("import-apply") or path.endswith("directory-apply"):
                rid = json.loads(body)["importId"]
                flag = "applied" if path.endswith("import-apply") else "directoryApplied"
                world.resources[rid][flag] = True
                value = {"importId": rid, "status": "APPLIED"}
            else:
                value = world.preview(query, path, body)
            if world.loss == path:
                world.loss = None
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            if world.gate is not None:
                world.reached.set()
                world.gate.wait(15)
            self.send_value(value)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield world, f"http://127.0.0.1:{server.server_port}/api"
    finally:
        if world.gate:
            world.gate.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


class SeedOnceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state, self.sources = self.root / "state", self.root / "sources"
        self.sources.mkdir()
        for i, name in enumerate(seed.SOURCE_PATHS):
            path = self.sources / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"anonymous-original-{i}".encode())
        z = self.sources / "september/2026年9月份报表.zip"
        with zipfile.ZipFile(z, "w") as archive:
            for name in seed.REPORT_NAMES:
                archive.writestr("2026年9月份报表/" + name, (self.sources / seed.REPORT_DIR / name).read_bytes())
        self.contract = Path(__file__).resolve().parents[1] / "server/src/main/resources/finance/template-contract-v1.json"

    def tearDown(self):
        self.temp.cleanup()

    def plan(self, world, server):
        return seed.create_plan(self.state, self.sources, server, world.actor, "anonymous-book",
                                str(uuid.uuid4()), "2026-09", self.contract)

    def runner(self, server, plan):
        return seed.Runner(self.state, seed.Api(server, "anonymous-access-token"), seed.load_plan(self.state))

    def test_complete_second_apply_and_verify_have_zero_posts_and_no_payload_or_token_on_disk(self):
        with http_world() as (world, server):
            plan = self.plan(world, server)
            first = self.runner(server, plan).run()
            self.assertEqual(first["remaining"], 0)
            writes = len(world.posts)
            self.runner(server, plan).run()
            self.runner(server, plan).run(verify_only=True)
            self.assertEqual(len(world.posts), writes)
            state = (self.state / "journal.json").read_text(encoding="utf-8")
            self.assertNotIn("anonymous-access-token", state)
            self.assertNotIn("123456789.123456789", state)
            self.assertNotIn("privateNumber", state)
            self.assertTrue(all("submit" not in p["path"] and "approve" not in p["path"] for p in world.posts))
            self.assertEqual(len(list((self.state / "source-archive").rglob("*.*"))), len(seed.SOURCE_PATHS))

    def test_lost_aux_response_finds_original_nonce_after_mapping_changes_without_post(self):
        with http_world() as (world, server):
            plan = self.plan(world, server)
            world.loss = "/api/finance/auxiliary-imports/preview"
            with self.assertRaises(seed.SeedError):
                self.runner(server, plan).run()
            writes = len(world.posts)
            world.mapping = "changed-mapping-must-not-reparse"
            self.runner(server, plan).run()
            # Two auxiliary sources, only one preview POST each; recovered first source via original operation.
            aux = [p for p in world.posts if p["path"].endswith("auxiliary-imports/preview")]
            self.assertEqual(len(aux), 2)
            self.assertEqual(len(world.nonces), 2)
            self.assertTrue(any("/operations/" in p for p in world.gets))
            rid = world.nonces[aux[0]["query"]["requestId"]]
            self.assertEqual(world.resources[rid]["currencyMappingFingerprint"], "mapping-original")
            self.assertGreater(len(world.posts), writes)  # remaining distinct planned steps proceed

    def test_missing_nonce_receipt_after_unknown_retries_same_exact_bytes_and_nonce(self):
        with http_world() as (world, server):
            plan = self.plan(world, server)
            step = next(s for s in plan["steps"] if s["kind"] == "auxiliary-preview")
            runner = self.runner(server, plan)
            entry = runner.journal["steps"].setdefault(step["id"], {"state": "pending"})
            world.loss = "/api/finance/auxiliary-imports/preview"
            with self.assertRaises(seed.SeedError):
                runner.execute(step, entry)
            previous = deepcopy(world.posts[-1])
            world.nonces.clear()  # 404 cannot prove no old POST: same original request still used.
            runner.execute(step, entry)
            self.assertEqual(world.posts[-1], previous)
            self.assertEqual(len(world.resources), 1)

    def test_lost_chart_response_safely_dedups_same_actor_and_sha(self):
        with http_world() as (world, server):
            plan = self.plan(world, server)
            world.loss = "/api/finance/chart/import-preview"
            with self.assertRaises(seed.SeedError):
                self.runner(server, plan).run()
            first = deepcopy(world.posts[0])
            self.runner(server, plan).run()
            self.assertEqual(world.posts[1], first)
            chart_sources = [r for r in world.resources.values() if r["applied"]]
            self.assertEqual(len(chart_sources), 1)

    def test_completed_resource_missing_never_posts_replacement(self):
        with http_world() as (world, server):
            plan = self.plan(world, server)
            self.runner(server, plan).run()
            writes = len(world.posts)
            world.resources.clear()
            with self.assertRaises(seed.HttpFailure):
                self.runner(server, plan).run()
            self.assertEqual(len(world.posts), writes)

    def test_actor_server_and_dataset_fences(self):
        with http_world() as (world, server):
            plan = self.plan(world, server)
            self.runner(server, plan).run()
            writes = len(world.posts)
            actor = world.actor
            world.actor = str(uuid.uuid4())
            with self.assertRaises(seed.SeedError): self.runner(server, plan)
            world.actor = actor
            world.dataset = str(uuid.uuid4())
            with self.assertRaises(seed.SeedError): self.runner(server, plan)
            reads = len(world.gets)
            with self.assertRaises(seed.SeedError): seed.Runner(self.state, seed.Api(server + "x", "token"), plan)
            self.assertEqual(len(world.gets), reads)
            self.assertEqual(len(world.posts), writes)

    def test_plan_file_or_archive_tampering_rejected_before_network(self):
        with http_world() as (world, server):
            plan = self.plan(world, server)
            archived = self.state / "source-archive" / seed.SOURCE_PATHS[0]
            archived.write_bytes(b"changed")
            with self.assertRaises(seed.SeedError): seed.load_plan(self.state)
            archived.write_bytes((self.sources / seed.SOURCE_PATHS[0]).read_bytes())
            plan["period"] = "2026-10"
            seed.atomic_json(self.state / "plan.json", plan)
            with self.assertRaises(seed.SeedError): seed.load_plan(self.state)
            self.assertEqual(world.gets + world.posts, [])

    def test_lock_survives_competitor_and_releases_after_owner_exit(self):
        script = Path(seed.__file__)
        code = "import sys; sys.path.insert(0,sys.argv[1]); import finance_seed_once as s; from pathlib import Path\nwith s.state_lock(Path(sys.argv[2])): print('acquired')"
        with seed.state_lock(self.state):
            result = subprocess.run([PYTHON, "-c", code, str(script.parent), str(self.state)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
        result = subprocess.run([PYTHON, "-c", code, str(script.parent), str(self.state)], capture_output=True)
        self.assertEqual(result.returncode, 0)

    def test_killed_process_keeps_unknown_durable_request_then_same_input_recovery(self):
        with http_world() as (world, server):
            plan = self.plan(world, server)
            world.gate = threading.Event()
            env = dict(os.environ, UTEN_FINANCE_SEED_TOKEN="anonymous-access-token")
            process = subprocess.Popen([PYTHON, seed.__file__, "apply", "--state-dir", str(self.state),
                "--server", server, "--actor", world.actor, "--allow-http-loopback"], env=env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.assertTrue(world.reached.wait(8))
                process.kill()
                process.communicate(timeout=8)
                journal = seed.read_json(self.state / "journal.json")
                self.assertEqual(next(iter(journal["steps"].values()))["state"], "unknown")
            finally:
                if process.poll() is None: process.kill(); process.communicate(timeout=8)
                world.gate.set()
                world.gate = None
            original = deepcopy(world.posts[0])
            self.runner(server, plan).run()
            self.assertEqual(world.posts[1], original)

    def test_cross_origin_redirect_and_error_body_never_leak_credentials_or_payload(self):
        with http_world() as (world, server), http_world() as (other, other_server):
            world.redirect = other_server + "/auth/me"
            with self.assertRaises(seed.SeedError) as error:
                seed.Api(server, "secret-token").request("GET", "/auth/me")
            self.assertEqual(other.gets, [])
            self.assertNotIn("secret-token", str(error.exception))
            world.redirect, world.status = None, 400
            with self.assertRaises(seed.HttpFailure) as error:
                seed.Api(server, "secret-token").request("GET", "/auth/me")
            self.assertNotIn("secret-private-value", str(error.exception))

    def test_decimal_json_and_exact_raw_workbook_bytes(self):
        with http_world() as (world, server):
            plan = self.plan(world, server)
            before = {name: seed.sha((self.sources / name).read_bytes()) for name in seed.SOURCE_PATHS}
            self.runner(server, plan).run()
            self.assertEqual(before, {name: seed.sha((self.sources / name).read_bytes()) for name in seed.SOURCE_PATHS})
            self.assertEqual(json.loads('1.123456789012345678901234', parse_float=Decimal), Decimal('1.123456789012345678901234'))
            self.assertTrue(all(item["sourceSystem"] == "anonymous-book" for item in plan["files"]))

    def test_zip_traversal_duplicate_symlink_bomb_and_encryption_are_rejected(self):
        for names in (("../outside",), ("same", "SAME"), ("C:/outside",)):
            path = self.root / "bad.zip"
            with zipfile.ZipFile(path, "w") as z:
                for name in names: z.writestr(name, b"x")
            with self.assertRaises(seed.SeedError): seed.zip_members(path)
        path = self.root / "bomb.zip"
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
            z.writestr("bomb", b"0" * 2_000_000)
        with self.assertRaises(seed.SeedError): seed.zip_members(path)
        path = self.root / "link.zip"
        with zipfile.ZipFile(path, "w") as z:
            item = zipfile.ZipInfo("link")
            item.create_system, item.external_attr = 3, (0o120777 << 16)
            z.writestr(item, "outside")
        with self.assertRaises(seed.SeedError): seed.zip_members(path)
        path = self.root / "encrypted.zip"
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("encrypted", b"x")
        data = bytearray(path.read_bytes())
        data[6] |= 1
        data[data.index(b"PK\x01\x02") + 8] |= 1
        path.write_bytes(data)
        with self.assertRaises(seed.SeedError): seed.zip_members(path)

    def test_asset_profile_allows_original_above_15mb_without_relaxing_other_uploads(self):
        asset = self.sources / seed.REPORT_DIR / "2026年9月固定资产明细表.xlsx"
        ordinary = self.sources / "2026年9月份科目余额表代码.xls"
        with open(asset, "wb") as stream:
            stream.truncate(seed.MAX_FILE + 1)
        with open(ordinary, "wb") as stream:
            stream.truncate(seed.MAX_FILE + 1)
        self.assertEqual(seed.checked_file(self.sources, seed.REPORT_DIR + asset.name), asset)
        with self.assertRaises(seed.SeedError): seed.checked_file(self.sources, ordinary.name)


if __name__ == "__main__":
    unittest.main()
