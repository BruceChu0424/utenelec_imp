"""Local-only client catalog deployment, permissions and reserved-space checks."""
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "client_release_storage", Path(__file__).with_name("prepare_client_release_storage.py"))
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)


def environment(path):
    return dict(line.split("=", 1) for line in path.read_text(encoding="utf-8-sig").splitlines()
                if line and not line.startswith("#"))


class DeploymentCatalogContractTest(unittest.TestCase):
    def test_environment_examples_keep_the_existing_backup_namespace_and_reserve(self):
        for relative, key in (("deploy/setup/server.env.internal-storage.example", "UTEN_INTERNAL_STORAGE_ROOT"),
                              ("deploy/setup/server.env.internal-test.example", "UTEN_STORAGE_LOCAL_DIR")):
            values = environment(ROOT / relative)
            with self.subTest(template=relative):
                self.assertEqual(values[key] + "/client-releases", values["UTEN_CLIENT_RELEASES_DIR"])
                self.assertEqual(storage.MIN_FREE_BYTES, int(values["UTEN_CLIENT_UPDATE_MIN_FREE_BYTES"]))

    def test_every_supported_service_keeps_catalog_inside_its_existing_write_boundary(self):
        for relative in ("deploy/simple/units/uten-imp.service", "deploy/systemd/uten-imp.service.example",
                         "deploy/systemd/uten-imp-internal-test.service.example",
                         "deploy/systemd/uten-imp-internal-storage.conf.example"):
            source = (ROOT / relative).read_text(encoding="utf-8-sig")
            values = dict(line[len("Environment="):].split("=", 1) for line in source.splitlines()
                          if line.startswith("Environment="))
            catalog = Path(values["UTEN_CLIENT_RELEASES_DIR"])
            grants = [Path(path.lstrip("-")) for line in source.splitlines() if line.startswith("ReadWritePaths=")
                      for path in line.split("=", 1)[1].split()]
            with self.subTest(unit=relative):
                self.assertTrue(any(catalog == path or path in catalog.parents for path in grants))
                self.assertEqual("client-releases", catalog.name)
                self.assertNotIn("current", catalog.parts)
                self.assertNotIn("releases", catalog.parts)
                self.assertNotIn("web", catalog.parts)
                self.assertEqual(storage.MIN_FREE_BYTES, int(values["UTEN_CLIENT_UPDATE_MIN_FREE_BYTES"]))

    def test_fresh_phase3_configuration_does_not_revert_to_the_low_application_fallback(self):
        source = (ROOT / "deploy/setup/phase3-runtime.sh").read_text(encoding="utf-8-sig")
        self.assertIn("\nUTEN_CLIENT_RELEASES_DIR=/var/lib/uten-imp-media/attachments/client-releases\n", source)
        self.assertIn("\nUTEN_CLIENT_UPDATE_MIN_FREE_BYTES=10737418240\n", source)

    @unittest.skipUnless(os.name == "posix", "actual Bash parser runs on Linux")
    def test_closed_internal_test_parser_accepts_only_the_reviewed_catalog_variables(self):
        source = (ROOT / "deploy/setup/validate-internal-test-server-env.sh").read_text(encoding="utf-8-sig")
        start = source.index("validate_supported_environment_keys() {")
        function = source[start:source.index("\n}\n", start) + 3]
        with tempfile.TemporaryDirectory() as directory:
            env = Path(directory) / "synthetic.env"
            script = Path(directory) / "check.sh"
            script.write_text('set -euo pipefail\nENV_FILE="$1"\ndie() { exit 7; }\n' +
                              function + '\nvalidate_supported_environment_keys\n')
            for key, expected in (("UTEN_CLIENT_RELEASES_DIR", 0),
                                  ("UTEN_CLIENT_UPDATE_MIN_FREE_BYTES", 0),
                                  ("UTEN_CLIENT_RELEASES_DIR_EVIL", 7)):
                env.write_text(key + "=fixture-unused\n")
                result = subprocess.run(["bash", str(script), str(env)], capture_output=True, text=True, timeout=10)
                self.assertEqual(expected, result.returncode, key)

    @unittest.skipUnless(os.name == "posix", "actual Bash policy runs on Linux")
    def test_internal_test_catalog_policy_keeps_old_envs_but_rejects_escape_and_low_reserve(self):
        source = (ROOT / "deploy/setup/validate-internal-test-server-env.sh").read_text(encoding="utf-8-sig")
        helpers = source[source.index("\ndie() {"):source.index("\nrequire_value() {")]
        start = source.index("# Client package storage remains")
        policy = source[start:source.index("expect_exact UTEN_ATTACHMENT_UPLOADS_ENABLED", start)]
        cases = (({}, True),
                 ({"UTEN_CLIENT_RELEASES_DIR": "/data/uten-imp/attachments/client-releases",
                   "UTEN_CLIENT_UPDATE_MIN_FREE_BYTES": str(storage.MIN_FREE_BYTES)}, True),
                 ({"UTEN_CLIENT_RELEASES_DIR": "/opt/uten-imp/current/web/downloads"}, False),
                 ({"UTEN_CLIENT_UPDATE_MIN_FREE_BYTES": "1073741824"}, False),
                 ({"UTEN_CLIENT_UPDATE_MIN_FREE_BYTES": "-1"}, False))
        with tempfile.TemporaryDirectory() as directory:
            env = Path(directory) / "synthetic.env"
            script = Path(directory) / "check.sh"
            script.write_text('set -euo pipefail\nENV_FILE="$1"\n' + helpers + policy)
            for values, accepted in cases:
                with self.subTest(values=values):
                    env.write_text("".join(key + "=" + value + "\n" for key, value in values.items()))
                    result = subprocess.run(["bash", str(script), str(env)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(accepted, result.returncode == 0, result.stderr)


@unittest.skipUnless(os.name == "posix", "private ERP host catalog uses Linux directory/record locks")
class PrivateCatalogPreparationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.media = self.root / "private-media"
        self.media.mkdir(mode=0o700)

    def prepare(self):
        return storage.prepare(self.media, os.geteuid(), os.getegid(), min_free_bytes=0)

    def test_fresh_private_catalog_and_lock_are_idempotent_and_preserve_all_history(self):
        result = self.prepare()
        catalog = self.media / "client-releases"
        self.assertTrue(result["created"])
        self.assertEqual(0o700, stat.S_IMODE(catalog.stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE((catalog / ".catalog.lock").stat().st_mode))
        receipt = catalog / "existing-history"
        receipt.write_bytes(b"retain every installer, update and withdrawn receipt")
        receipt.chmod(0o640)
        self.assertFalse(self.prepare()["created"])
        self.assertEqual(b"retain every installer, update and withdrawn receipt", receipt.read_bytes())
        self.assertEqual(0o640, stat.S_IMODE(receipt.stat().st_mode))

    def test_reserve_failure_precedes_catalog_creation_and_does_not_consume_business_space(self):
        volume = types.SimpleNamespace(f_bavail=storage.MIN_FREE_BYTES - 1, f_frsize=1)
        with patch.object(storage.os, "fstatvfs", return_value=volume):
            with self.assertRaisesRegex(ValueError, "free-space reserve"):
                storage.prepare(self.media, os.geteuid(), os.getegid())
        self.assertEqual([], list(self.media.iterdir()))

    def test_symlinked_media_or_catalog_cannot_redirect_preparation(self):
        alias = self.root / "alias"
        alias.symlink_to(self.media, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "canonical"):
            storage.prepare(alias, os.geteuid(), os.getegid(), 0)
        outside = self.root / "outside"
        outside.mkdir()
        (self.media / "client-releases").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError):
            self.prepare()
        self.assertEqual([], list(outside.iterdir()))

    def test_foreign_writable_catalog_is_rejected_without_chmod_or_file_changes(self):
        catalog = self.media / "client-releases"
        catalog.mkdir()
        catalog.chmod(0o777)
        with self.assertRaisesRegex(ValueError, "unexpected owner or write"):
            self.prepare()
        self.assertEqual(0o777, stat.S_IMODE(catalog.stat().st_mode))
        self.assertEqual([], list(catalog.iterdir()))

    def test_linked_lock_cannot_change_an_outside_file(self):
        catalog = self.media / "client-releases"
        catalog.mkdir(mode=0o700)
        outside = self.root / "outside-lock"
        outside.write_bytes(b"do not truncate or chmod")
        before = outside.stat()
        barrier = catalog / ".catalog.lock"
        for hard in (False, True):
            with self.subTest(hard=hard):
                if hard:
                    os.link(outside, barrier)
                else:
                    barrier.symlink_to(outside)
                with self.assertRaises((OSError, ValueError)):
                    self.prepare()
                self.assertEqual(b"do not truncate or chmod", outside.read_bytes())
                self.assertEqual(stat.S_IMODE(before.st_mode), stat.S_IMODE(outside.stat().st_mode))
                barrier.unlink()

    def test_running_catalog_writer_blocks_preparation_without_replacing_the_barrier(self):
        self.prepare()
        barrier = self.media / "client-releases" / ".catalog.lock"
        inode = barrier.stat().st_ino
        code = ("import fcntl,sys; f=open(sys.argv[1],'r+b'); "
                "fcntl.lockf(f,fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.read(1)")
        process = subprocess.Popen([sys.executable, "-I", "-c", code, str(barrier)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(b"ready\n", process.stdout.readline())
            with self.assertRaises(BlockingIOError):
                self.prepare()
            self.assertEqual(inode, barrier.stat().st_ino)
            self.assertEqual(b"", barrier.read_bytes())
        finally:
            process.communicate(input=b"x", timeout=10)
        self.assertEqual(0, process.returncode)

    @unittest.skipUnless(hasattr(os, "geteuid") and os.geteuid() == 0, "owner assignment requires root")
    def test_prepared_catalog_is_owned_by_the_service_account_not_the_nginx_account(self):
        self.root.chmod(0o755)
        self.media.chmod(0o750)
        os.chown(self.media, 0, 65534)
        result = storage.prepare(self.media, 65534, 65534, 0)
        catalog = Path(result["catalog"])
        self.assertEqual(65534, catalog.stat().st_uid)
        self.assertEqual(65534, (catalog / ".catalog.lock").stat().st_uid)
        self.assertEqual(0, stat.S_IMODE(catalog.stat().st_mode) & 0o077)

    @unittest.skipUnless(hasattr(os, "geteuid") and os.geteuid() == 0, "owner assignment requires root")
    def test_root_preparer_cannot_hide_an_inaccessible_service_parent(self):
        with self.assertRaisesRegex(ValueError, "not traversable"):
            storage.prepare(self.media, 65534, 65534, 0)
        self.assertFalse((self.media / "client-releases").exists())


if __name__ == "__main__":
    unittest.main()
