from __future__ import annotations

import base64
import copy
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("offsite_plan", HERE / "offsite_plan.py")
PLAN = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(PLAN)
NOW = datetime(2026, 10, 13, 12, 0, tzinfo=timezone.utc)


def utc(age_seconds: int) -> str:
    return (NOW - timedelta(seconds=age_seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def configured() -> dict:
    value = json.loads((HERE / "offsite-internal-server.example.json").read_text(encoding="utf-8"))
    value["source"].update(machineId="1" * 32, host="erp.internal", addresses=["192.168.10.10"],
                            systemIdentifier="7511111111111111111", timeline=1,
                            privateOriginalRoot="/var/lib/uten-private-originals")
    value["receiver"].update(machineId="2" * 32, addresses=["192.168.20.20"],
                              repositoryRoot="/srv/offsite-uten/history")
    value["ssh"].update(identityFile="/etc/uten-offsite/source_ed25519",
                       knownHostsFile="/etc/uten-offsite/known_hosts",
                       hostKeySha256="SHA256:" + base64.b64encode(b"x" * 32).decode().rstrip("="))
    return value


def receipt(config: dict) -> dict:
    wal_segments = [{"name": name, "sha256": "a" * 64} for name in (
        "0000000100000000000000FE", "0000000100000000000000FF", "000000010000000100000000")]
    return {
        "schemaVersion": 1, "status": "COMPLETED", "configCanonicalSha256": PLAN.canonical_digest(config),
        "observedAtUtc": utc(30), "sourceMachineId": "1" * 32, "receiverMachineId": "2" * 32,
        "database": {"systemIdentifier": config["source"]["systemIdentifier"], "timeline": 1,
            "repositoryNumber": 2, "baseBackupLabel": "20261012-021700F", "baseBackupManifestSha256": "b" * 64,
            "baseBackupStartedAtUtc": utc(86400), "baseBackupCompletedAtUtc": utc(82800),
            "baseBackupWalStart": wal_segments[0]["name"], "baseBackupWalStop": wal_segments[1]["name"],
            "walStart": wal_segments[0]["name"], "walStop": wal_segments[-1]["name"], "walSegmentBytes": 16777216,
            "walSegments": wal_segments, "walInventorySha256": PLAN.canonical_digest(wal_segments),
            "confirmedThroughUtc": utc(120)},
        "originals": {"mode": "CONTINUOUS_IMMUTABLE_JOURNAL", "scopes": ["attachments", "private-originals"],
            "objectManifestSha256": "c" * 64, "recoveryReferenceManifestSha256": "d" * 64,
            "immutabilityReceiptSha256": "e" * 64, "journalReceiptSha256": "f" * 64,
            "referenceCoverageFromUtc": utc(35 * 86400), "confirmedThroughUtc": utc(180)},
        "paired": {"setId": "20261013T034000Z-abcdef123456", "manifestSha256": "b" * 64,
            "databaseSha256": "c" * 64, "startedAtUtc": utc(8 * 3600 + 20 * 60), "completedAtUtc": utc(8 * 3600)},
        "durability": {"fsyncVerified": True, "immutableSnapshotId": "snapshot-20261013-115930",
                       "accessReviewSha256": "a" * 64}}


class ConfigurationTests(unittest.TestCase):
    def test_unresolved_example_is_explicitly_disabled_without_secret_values(self):
        value = json.loads((HERE / "offsite-internal-server.example.json").read_text(encoding="utf-8"))
        result = PLAN.make_plan(value)
        self.assertEqual("DISABLED_UNRESOLVED", result["status"])
        self.assertFalse(result["liveReadinessVerified"])
        self.assertFalse(result["connectionsAttempted"])
        self.assertFalse(result["writesPerformed"])
        self.assertEqual(900, result["rpoBudgetSeconds"])
        self.assertIn("UNRESOLVED:source.host", result["blockers"])
        self.assertIn("NO_INDEPENDENT_RECEIVER_DURABILITY_RECEIPT", result["blockers"])

    def test_filled_candidate_cannot_claim_ready_from_config_assertions(self):
        result = PLAN.make_plan(configured())
        self.assertEqual("CANDIDATE_NOT_CONNECTED", result["status"])
        self.assertIn("UNVERIFIED:isolation.siteFailureDomain", result["blockers"])
        self.assertIn("TRANSPORT_NOT_IMPLEMENTED", result["blockers"])
        self.assertFalse(result["rtoVerified"])

    def test_unsafe_configuration_is_rejected(self):
        cases = [("enabled", True), ("direction", "SOURCE_PUSH")]
        for field, value in cases:
            config = configured()
            config[field] = value
            with self.subTest(field=field), self.assertRaises(PLAN.ContractError):
                PLAN.validate_config(config)
        nested_cases = [("ssh", "strictHostKeyChecking", False), ("ssh", "passwordAuthentication", True),
            ("ssh", "agentForwarding", True), ("ssh", "portForwarding", True),
            ("ssh", "sourceCommand", "/bin/sh"), ("ssh", "sourceReadAccount", "root"),
            ("isolation", "sourceCanDeleteReceiverHistory", True),
            ("isolation", "receiveAccountCanDeleteHistory", True),
            ("isolation", "sourceReadAccountCanMutateSource", True),
            ("isolation", "physicalFailureDomain", "VERIFIED"), ("isolation", "siteFailureDomain", "VERIFIED"),
            ("isolation", "immutabilityVerification", "VERIFIED"),
            ("retention", "referenceClosureRequired", False), ("retention", "cleanupAuthority", "SOURCE"),
            ("retention", "pitrDays", 3), ("retention", "immutableDays", 30),
            ("recovery", "rpoSeconds", True), ("recovery", "rtoSeconds", 14401),
            ("recovery", "pullIntervalSeconds", 301), ("ssh", "port", True)]
        for section, field, value in nested_cases:
            config = configured()
            config[section][field] = value
            with self.subTest(section=section, field=field), self.assertRaises(PLAN.ContractError):
                PLAN.validate_config(config)

    def test_same_machine_ip_or_root_rejected(self):
        for field, value in (("machineId", "1" * 32), ("addresses", ["192.168.10.10"]),
                             ("repositoryRoot", "/srv/uten-backup/pgbackrest"),
                             ("repositoryRoot", "/srv/uten-backup/pgbackrest/replica"),
                             ("repositoryRoot", "/var/lib")):
            config = configured()
            config["receiver"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(PLAN.ContractError):
                PLAN.validate_config(config)

    def test_path_traversal_shell_and_placeholders_are_rejected(self):
        for path in ("/", "/srv//archive", "/srv/../archive", "/srv/archive/", "/srv/archive;whoami", "C:/backup"):
            config = configured()
            config["receiver"]["repositoryRoot"] = path
            with self.subTest(path=path), self.assertRaises(PLAN.ContractError):
                PLAN.validate_config(config)
        for host in ("localhost", "host.invalid", "REPLACE_HOST", "host;whoami", "10.0.0.20"):
            config = configured()
            config["source"]["host"] = host
            with self.subTest(host=host), self.assertRaises(PLAN.ContractError):
                PLAN.validate_config(config)

    def test_literal_addresses_must_be_safe_and_unique(self):
        for addresses in (["127.0.0.1"], ["::1"], ["0.0.0.0"], ["169.254.1.10"], ["224.0.0.1"],
                          ["erp.internal"], ["192.168.10.10"] * 2, [{}]):
            config = configured()
            config["source"]["addresses"] = addresses
            with self.subTest(addresses=addresses), self.assertRaises(PLAN.ContractError):
                PLAN.validate_config(config)

    def test_credential_values_cannot_be_added_to_schema(self):
        config = configured()
        config["ssh"]["privateKey"] = "VERY_PRIVATE_SECRET"
        with self.assertRaises(PLAN.ContractError):
            PLAN.validate_config(config)

    def test_dedicated_accounts_and_pin_files_must_be_separate(self):
        config = configured()
        config["receiver"]["retentionAccount"] = config["receiver"]["receiveAccount"]
        with self.assertRaises(PLAN.ContractError):
            PLAN.validate_config(config)
        config = configured()
        config["ssh"]["knownHostsFile"] = config["ssh"]["identityFile"]
        with self.assertRaises(PLAN.ContractError):
            PLAN.validate_config(config)


class RecoveryWatermarkTests(unittest.TestCase):
    def setUp(self):
        self.config = configured()
        self.receipt = receipt(self.config)

    def test_contiguous_wal_log_rollover_and_slower_originals_define_common_point(self):
        result = PLAN.make_plan(self.config, self.receipt, NOW)
        evidence = result["suppliedRecoveryEvidence"]
        self.assertEqual(180, evidence["observedRpoSeconds"])
        self.assertTrue(evidence["rpoWithinTargetFromSuppliedReceipt"])
        self.assertFalse(evidence["liveReadinessVerified"])
        self.assertFalse(result["liveReadinessVerified"])
        self.assertFalse(evidence["rtoVerified"])

    def test_fresh_database_and_twice_daily_paired_originals_fail_rpo(self):
        self.receipt["originals"].update(mode="PAIRED_SNAPSHOT", journalReceiptSha256=None,
                                         confirmedThroughUtc=self.receipt["paired"]["startedAtUtc"])
        result = PLAN.evaluate_receipt(self.config, self.receipt, NOW)
        self.assertFalse(result["rpoWithinTargetFromSuppliedReceipt"])
        self.assertGreater(result["observedRpoSeconds"], 8 * 3600)
        self.assertEqual(self.receipt["originals"]["confirmedThroughUtc"], result["commonRecoveryWatermarkUtc"])

    def test_paired_completion_cannot_be_used_as_snapshot_watermark(self):
        self.receipt["originals"].update(mode="PAIRED_SNAPSHOT", journalReceiptSha256=None,
                                         confirmedThroughUtc=self.receipt["paired"]["completedAtUtc"])
        with self.assertRaisesRegex(PLAN.ContractError, "paired-only"):
            PLAN.evaluate_receipt(self.config, self.receipt, NOW)

    def test_missing_duplicated_reordered_and_corrupt_wal_fail(self):
        original = self.receipt["database"]["walSegments"]
        for segments in (original[:-1], [original[0], original[0], original[2]], list(reversed(original))):
            value = copy.deepcopy(self.receipt)
            value["database"]["walSegments"] = segments
            value["database"]["walInventorySha256"] = PLAN.canonical_digest(segments)
            with self.subTest(segments=segments), self.assertRaises(PLAN.ContractError):
                PLAN.evaluate_receipt(self.config, value, NOW)
        self.receipt["database"]["walInventorySha256"] = "0" * 64
        with self.assertRaisesRegex(PLAN.ContractError, "digest"):
            PLAN.evaluate_receipt(self.config, self.receipt, NOW)

    def test_wrong_timeline_system_machine_and_policy_fail(self):
        for section, field, value in (("database", "systemIdentifier", "7512222222222222222"),
                                     ("database", "timeline", 2), ("database", "repositoryNumber", 1),
                                     ("database", "timeline", True)):
            document = copy.deepcopy(self.receipt)
            document[section][field] = value
            with self.subTest(field=field), self.assertRaises(PLAN.ContractError):
                PLAN.evaluate_receipt(self.config, document, NOW)
        for key in ("sourceMachineId", "receiverMachineId", "configCanonicalSha256"):
            document = copy.deepcopy(self.receipt)
            document[key] = "0" * len(document[key])
            with self.subTest(key=key), self.assertRaises(PLAN.ContractError):
                PLAN.evaluate_receipt(self.config, document, NOW)

    def test_wal_timeline_jump_and_missing_base_coverage_fail(self):
        for field, value in (("walStart", "0000000100000000000000FF"),
                             ("walStop", "000000020000000100000000"),
                             ("walSegmentBytes", 10000000),
                             ("baseBackupLabel", "20261012-021700F_20261013-021700D")):
            document = copy.deepcopy(self.receipt)
            document["database"][field] = value
            with self.subTest(field=field), self.assertRaises(PLAN.ContractError):
                PLAN.evaluate_receipt(self.config, document, NOW)

    def test_future_and_stale_receipts_or_watermarks_fail(self):
        for timestamp in (utc(-1), utc(901)):
            self.receipt["observedAtUtc"] = timestamp
            with self.subTest(timestamp=timestamp), self.assertRaises(PLAN.ContractError):
                PLAN.evaluate_receipt(self.config, self.receipt, NOW)
        self.receipt = receipt(self.config)
        self.receipt["originals"]["confirmedThroughUtc"] = utc(29)
        with self.assertRaises(PLAN.ContractError):
            PLAN.evaluate_receipt(self.config, self.receipt, NOW)

    def test_receiver_durability_missing_original_scope_or_journal_fail(self):
        for section, key, value in (("durability", "fsyncVerified", False),
                                    ("originals", "scopes", ["attachments"]),
                                    ("originals", "journalReceiptSha256", None),
                                    ("originals", "referenceCoverageFromUtc", utc(82799))):
            document = copy.deepcopy(self.receipt)
            document[section][key] = value
            with self.subTest(key=key), self.assertRaises(PLAN.ContractError):
                PLAN.evaluate_receipt(self.config, document, NOW)

    def test_selected_base_cannot_restore_earlier_common_point(self):
        self.receipt["originals"]["confirmedThroughUtc"] = utc(82801)
        with self.assertRaisesRegex(PLAN.ContractError, "common recovery point"):
            PLAN.evaluate_receipt(self.config, self.receipt, NOW)

    def test_unverified_example_receipt_cannot_be_promoted(self):
        document = json.loads((HERE / "offsite-receiver-receipt.example.json").read_text(encoding="utf-8"))
        with self.assertRaisesRegex(PLAN.ContractError, "completed"):
            PLAN.evaluate_receipt(self.config, document, NOW)


class CommandLineTests(unittest.TestCase):
    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        # LibreOffice's embedded Python reports a directory as sys.executable.
        executable = sys.executable if Path(sys.executable).is_file() else shutil.which("python")
        self.assertIsNotNone(executable)
        return subprocess.run([executable, "-I", str(HERE / "offsite_plan.py"), *args],
                              capture_output=True, text=True, timeout=10)

    def test_cli_readonly_plan_preserves_input_and_creates_no_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "candidate.json"
            raw = json.dumps(configured()).encode()
            path.write_bytes(raw)
            result = self.run_cli("plan", "--config", str(path))
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(raw, path.read_bytes())
            self.assertEqual([path], list(root.iterdir()))
            self.assertFalse(json.loads(result.stdout)["writesPerformed"])

    def test_cli_rejects_duplicate_keys_and_never_echoes_secret_values(self):
        for raw in ('{"schemaVersion":1,"schemaVersion":1,"secret":"VERY_PRIVATE_SECRET"}',
                    json.dumps({**configured(), "secret": "VERY_PRIVATE_SECRET"})):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "candidate.json"
                path.write_text(raw, encoding="utf-8")
                result = self.run_cli("validate", "--config", str(path))
                self.assertEqual(78, result.returncode)
                self.assertNotIn("VERY_PRIVATE_SECRET", result.stdout + result.stderr)
                self.assertEqual("INVALID_INPUT", json.loads(result.stdout)["status"])

    def test_receipt_requires_independent_digest_and_rejects_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_path, receipt_path = root / "config.json", root / "receipt.json"
            config_path.write_text(json.dumps(configured()), encoding="utf-8")
            receipt_path.write_text(json.dumps(receipt(configured())), encoding="utf-8")
            for args in (("--receipt", str(receipt_path)),
                         ("--receipt-sha256", "a" * 64),
                         ("--receipt", str(receipt_path), "--receipt-sha256", "a" * 64)):
                result = self.run_cli("plan", "--config", str(config_path), *args)
                self.assertEqual(78, result.returncode)

    def test_nonfinite_boolean_version_and_bom_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            values = [b'{"value":NaN}', b'\xef\xbb\xbf{}',
                      json.dumps({**configured(), "schemaVersion": True}).encode()]
            for value in values:
                path.write_bytes(value)
                result = self.run_cli("plan", "--config", str(path))
                self.assertEqual(78, result.returncode)

    @unittest.skipUnless(os.name == "posix", "receiver permission checks require Linux/POSIX")
    def test_real_receiver_files_refuse_broad_permissions_and_bad_host_pin(self):
        import pwd
        user = pwd.getpwuid(os.geteuid())
        # The receiver is deliberately non-root. /root is commonly 0700, so it
        # cannot be an ancestor of a valid root-run receiver fixture. /var/lib
        # has root-owned traversable ancestors and no world-writable /tmp path.
        receiver_fixture_parent = "/var/lib" if os.geteuid() == 0 else user.pw_dir
        with tempfile.TemporaryDirectory(prefix="offsite-plan-", dir=receiver_fixture_parent) as directory:
            root = Path(directory)
            key, pins, machine = root / "identity", root / "known_hosts", root / "machine-id"
            key.write_bytes(b"PRIVATE_KEY_IS_NOT_OPENED")
            public_key = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20" + b"x" * 32
            pins.write_text("erp.internal ssh-ed25519 " + base64.b64encode(public_key).decode() + "\n", encoding="ascii")
            machine.write_text("2" * 32, encoding="ascii")
            key.chmod(0o600)
            pins.chmod(0o600)
            receiving_uid = os.geteuid() if os.geteuid() != 0 else 65534
            if os.geteuid() == 0:
                os.chown(root, receiving_uid, -1)
                os.chown(key, receiving_uid, -1)
                os.chown(pins, receiving_uid, -1)
            config = configured()
            config["ssh"].update(identityFile=str(key), knownHostsFile=str(pins),
                hostKeySha256="SHA256:" + base64.b64encode(hashlib.sha256(public_key).digest()).decode().rstrip("="))
            with mock.patch("pwd.getpwnam", return_value=SimpleNamespace(pw_uid=receiving_uid, pw_gid=receiving_uid)), \
                    mock.patch("os.getgrouplist", return_value=[receiving_uid]):
                original_open = Path.open

                def refusing_private_key_open(path, *args, **kwargs):
                    if path == key:
                        raise AssertionError("private key content must never be opened")
                    return original_open(path, *args, **kwargs)

                with mock.patch.object(Path, "open", refusing_private_key_open):
                    result = PLAN.validate_receiver_files(config, machine)
                self.assertFalse(result["privateKeyContentRead"])
                key.chmod(0o640)
                with self.assertRaisesRegex(PLAN.ContractError, "private regular file"):
                    PLAN.validate_receiver_files(config, machine)
                key.chmod(0o600)
                config["ssh"]["hostKeySha256"] = configured()["ssh"]["hostKeySha256"]
                with self.assertRaisesRegex(PLAN.ContractError, "fingerprint"):
                    PLAN.validate_receiver_files(config, machine)

                config["ssh"]["hostKeySha256"] = "SHA256:" + base64.b64encode(hashlib.sha256(public_key).digest()).decode().rstrip("=")
                root.chmod(0o600)
                with self.assertRaisesRegex(PLAN.ContractError, "cannot traverse"):
                    PLAN.validate_receiver_files(config, machine)
                root.chmod(0o700)

            with mock.patch("pwd.getpwnam", return_value=SimpleNamespace(pw_uid=0)):
                with self.assertRaisesRegex(PLAN.ContractError, "root UID alias"):
                    PLAN.validate_receiver_files(config, machine)


@unittest.skipUnless(os.name == "posix", "pin descriptor checks require Linux/POSIX")
class ReceiverPinDescriptorTests(unittest.TestCase):
    def test_oversized_pin_is_rejected_before_any_file_read(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "known_hosts"
            with path.open("wb") as handle:
                handle.truncate(PLAN.MAX_HOST_PIN_BYTES + 1)
            with mock.patch("os.read", side_effect=AssertionError("oversized file must never be read")):
                with self.assertRaisesRegex(PLAN.ContractError, "exceeds 64 KiB"):
                    PLAN._read_checked_host_pin(path, path.lstat())

    def test_pin_replaced_after_lstat_by_symlink_is_never_opened(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path, other = root / "known_hosts", root / "private-other-file"
            path.write_bytes(b"original pin")
            other.write_bytes(b"sensitive target must not be read")
            expected = path.lstat()
            path.unlink()
            path.symlink_to(other)
            with mock.patch("os.read", side_effect=AssertionError("replacement link target must never be read")):
                with self.assertRaises(OSError):
                    PLAN._read_checked_host_pin(path, expected)

    def test_replacement_regular_file_and_changed_mode_fail_before_read(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path, replacement = root / "known_hosts", root / "replacement"
            path.write_bytes(b"original")
            replacement.write_bytes(b"replacement")
            expected = path.lstat()
            replacement.replace(path)
            with mock.patch("os.read", side_effect=AssertionError("replaced file must never be read")):
                with self.assertRaisesRegex(PLAN.ContractError, "identity or permissions changed"):
                    PLAN._read_checked_host_pin(path, expected)
            expected = path.lstat()
            path.chmod(0o640)
            with self.assertRaisesRegex(PLAN.ContractError, "identity or permissions changed"):
                PLAN._read_checked_host_pin(path, expected)

    def test_hardlinks_are_rejected_and_growing_file_read_remains_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "known_hosts"
            path.write_bytes(b"pin")
            os.link(path, root / "alias")
            with self.assertRaisesRegex(PLAN.ContractError, "identity or permissions changed"):
                PLAN._read_checked_host_pin(path, path.lstat())
            (root / "alias").unlink()
            read_sizes = []

            def growing_read(fd, count):
                read_sizes.append(count)
                return b"x" * count

            with mock.patch("os.read", growing_read):
                with self.assertRaisesRegex(PLAN.ContractError, "exceeds 64 KiB"):
                    PLAN._read_checked_host_pin(path, path.lstat())
            self.assertEqual([PLAN.MAX_HOST_PIN_BYTES + 1], read_sizes)


if __name__ == "__main__":
    unittest.main()
