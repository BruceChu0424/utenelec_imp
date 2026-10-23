import io
import json
from pathlib import Path
import tempfile
import unittest
from datetime import timedelta
from unittest.mock import patch

import continuous_backup as backup
import snapshot_chunks


class CiphertextReceiverTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="uten-dr-transfer-test-")
        self.base = Path(self.temp.name)
        self.base.chmod(0o700)
        self.storage = self.base / "storage"
        self.storage.mkdir(mode=0o700)
        self.config = {"storage_root": str(self.storage), "status_file": str(self.base / "status.json"),
            "recipient_fingerprint": "A" * 40, "max_archive_bytes": 1024 * 1024,
            "max_storage_bytes": 10 * 1024 * 1024, "min_free_bytes": 0,
            "hourly_retention_days": 7, "daily_retention_days": 30, "minimum_complete_sets": 3}
        self.ciphertext = b"SYNTHETIC OPAQUE ENCRYPTED BYTES" * 100
        self.index = 0
        patcher = patch.object(backup, "chunks_module", return_value=snapshot_chunks)
        patcher.start(); self.addCleanup(patcher.stop)

    def tearDown(self):
        self.temp.cleanup()

    def header(self, age_days=0):
        self.index += 1
        moment = backup.now() - timedelta(days=age_days)
        stamp = moment.strftime("%Y%m%dT%H%M%SZ")
        receipt = {"format": "uten-sealed-paired-v1", "exportId": f"sealed-{stamp}-{self.index:012x}",
            "state": "CIPHERTEXT_CREATED", "sourceSetId": f"{stamp}-{self.index:012x}",
            "sourceManifestSha256": "b" * 64, "recipientFingerprint": "A" * 40,
            "ciphertextFile": "archive.gpg", "ciphertextBytes": len(self.ciphertext),
            "ciphertextSha256": backup.hashlib.sha256(self.ciphertext).hexdigest(),
            "cryptoRecoveryIncluded": True, "completedAt": moment.isoformat(),
            "targetCopyVerified": False, "restoreVerified": False,
            "marketStateIncluded": False, "clientReleaseStateIncluded": False}
        return {"format": backup.FORMAT, "operation": "submit", "sourceReceipt": receipt,
                "sourceSnapshotAt": moment.isoformat()}

    def send(self, header, payload=None):
        incoming = io.BytesIO((json.dumps(header) + "\n").encode() +
                              (self.ciphertext if payload is None else payload))
        outgoing = io.BytesIO()
        backup.receive(self.config, incoming, outgoing)
        return json.loads(outgoing.getvalue())

    def assert_no_point(self):
        self.assertFalse(any(backup.EXPORT.fullmatch(p.name) for p in self.storage.iterdir()))
        self.assertFalse(any(p.name.startswith(".incoming-") for p in self.storage.iterdir()))

    def test_commits_only_complete_ciphertext_and_binds_target_receipt(self):
        header = self.header()
        receipt = self.send(header)
        self.assertEqual("TARGET_BYTES_VERIFIED", receipt["state"])
        self.assertEqual(header["sourceReceipt"]["ciphertextSha256"], receipt["ciphertextSha256"])
        self.assertEqual(self.ciphertext, (self.storage / receipt["exportId"] / "archive.gpg").read_bytes())
        status = backup.build_status(self.config)
        self.assertEqual(1, status["completedSets"])
        self.assertFalse(status["rpo15MinutesSatisfied"])
        self.assertFalse(status["restoreVerified"])
        self.assertFalse(status["recoveryPoints"][0]["verified"])

    def test_corrupt_short_or_extra_stream_never_publishes_a_point(self):
        for payload in [b"short", b"x" * len(self.ciphertext), self.ciphertext + b"extra"]:
            with self.subTest(size=len(payload)), self.assertRaises(ValueError):
                self.send(self.header(), payload)
            self.assert_no_point()

    def test_sender_cannot_supply_delete_shell_or_extra_secret_fields(self):
        for operation in ["delete", "restore", "shell", "retain"]:
            header = self.header()
            header["operation"] = operation
            with self.assertRaises(ValueError):
                self.send(header)
        header = self.header()
        header["sourceReceipt"]["secret"] = "MUST_NOT_BE_STORED"
        with self.assertRaises(ValueError):
            self.send(header)
        self.assert_no_point()

    def test_paths_wrong_recipient_or_claimed_restore_are_rejected(self):
        for field, value in [("exportId", "../../etc/shadow"),
                             ("recipientFingerprint", "0" * 40), ("restoreVerified", True),
                             ("ciphertextBytes", -1), ("ciphertextBytes", True)]:
            header = self.header()
            header["sourceReceipt"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.send(header)
            self.assert_no_point()

    def test_capacity_refusal_preserves_successful_history_and_status(self):
        self.send(self.header())
        previous = (self.base / "status.json").read_bytes()
        self.config["max_storage_bytes"] = len(self.ciphertext)
        with self.assertRaises(OSError):
            self.send(self.header())
        self.assertEqual(previous, (self.base / "status.json").read_bytes())
        self.assertEqual(1, backup.build_status(self.config)["completedSets"])

    def test_idempotent_retry_does_not_overwrite_history_and_collision_fails(self):
        header = self.header()
        first = self.send(header)
        self.assertEqual(first, self.send(header))
        header["sourceReceipt"]["sourceManifestSha256"] = "c" * 64
        with self.assertRaises(ValueError):
            self.send(header)
        self.assertEqual(1, len(backup.completed(self.config)))

    def test_remote_command_is_refused_even_if_forced_command_was_invoked(self):
        with patch.dict(backup.os.environ, {"SSH_ORIGINAL_COMMAND": "id"}):
            with self.assertRaises(ValueError):
                self.send(self.header())
        self.assert_no_point()

    def test_status_rpc_cannot_invoke_retention_and_has_no_secret_payload(self):
        self.send(self.header())
        output = io.BytesIO()
        backup.receive(self.config, io.BytesIO((json.dumps({"format": backup.FORMAT,
            "operation": "status"}) + "\n").encode()), output)
        self.assertEqual(1, json.loads(output.getvalue())["completedSets"])
        self.assertNotIn(self.ciphertext, output.getvalue())

    def test_independent_retention_preserves_daily_points_and_minimum_floor(self):
        for age in [50, 49, 48, 20, 20, 1]:
            header = self.header(age)
            target = self.send(header)
            path = self.storage / target["exportId"] / "target-receipt.json"
            target["receivedAt"] = (backup.now() - timedelta(days=age)).isoformat()
            backup.atomic_json(path, target)
        status = backup.retain(self.config)
        self.assertEqual(3, status["completedSets"])
        self.assertEqual(3, status["lastRetention"]["deletedSets"])

    def test_duplicate_json_keys_are_refused(self):
        with self.assertRaises(ValueError):
            backup.receive(self.config, io.BytesIO(b'{"format":"x","format":"uten-dr-ciphertext-transfer-v1","operation":"status"}\n'), io.BytesIO())


if __name__ == "__main__":
    unittest.main()
