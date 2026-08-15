from __future__ import annotations

import ast
import importlib.util
import json
import os
import stat
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


SOURCE = Path(__file__).resolve().with_name("migration_authorization.py")
SPEC = importlib.util.spec_from_file_location("migration_authorization_under_test", SOURCE)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load migration authorization helper")
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)


class MigrationAuthorizationTest(unittest.TestCase):
    def test_module_has_no_posix_only_top_level_import(self) -> None:
        tree = ast.parse(SOURCE.read_text(encoding="utf-8"))
        imported = {
            alias.name
            for node in tree.body
            if isinstance(node, ast.Import)
            for alias in node.names
        }
        imported.update(
            node.module
            for node in tree.body
            if isinstance(node, ast.ImportFrom) and node.module is not None
        )
        self.assertNotIn("grp", imported)

    def authorization(self) -> dict[str, object]:
        issued = int(time.time())
        issued_boot = 123_000_000_000
        marker_sha = "e" * 64
        nonce = "f" * 32
        return {
            "bootId": "01234567-89ab-cdef-0123-456789abcdef",
            "commitSha": "b" * 40,
            "expiresAtBoottimeNs": issued_boot
            + migration.AUTHORIZATION_TTL_SECONDS * 1_000_000_000,
            "expiresAtUnix": issued + migration.AUTHORIZATION_TTL_SECONDS,
            "flywayHeadVersion": "255",
            "flywayMigrationSetSha256": "c" * 64,
            "issuedAtUnix": issued,
            "issuedAtBoottimeNs": issued_boot,
            "issuedAtUtc": datetime.fromtimestamp(issued, timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z"),
            "issuerPid": 4242,
            "issuerProcStartTime": "123456",
            "manifestSha256": "d" * 64,
            "markerPath": str(migration.ACTIVATION_IN_PROGRESS_MARKER),
            "markerSha256": marker_sha,
            "nonce": nonce,
            "releaseSequence": 20260812001,
            "schemaVersion": 1,
            "targetPath": "/opt/uten-imp/releases/v2026.08.12-1",
            "transactionEvidencePath": (
                f"/var/lib/uten-imp-release/migration-evidence/"
                f"activation-{marker_sha}-{nonce}"
            ),
            "version": "v2026.08.12-1",
        }

    def manifest(self) -> dict[str, object]:
        return {
            "commitSha": "b" * 40,
            "flywayHeadVersion": "255",
            "flywayMigrationSetSha256": "c" * 64,
            "releaseSequence": 20260812001,
            "version": "v2026.08.12-1",
        }

    def test_valid_grant_binds_boot_marker_signed_current_and_live_issuer(self) -> None:
        authorization = self.authorization()
        target = Path(str(authorization["targetPath"]))
        with mock.patch.object(
            migration, "_boot_id", return_value=str(authorization["bootId"])
        ), mock.patch.object(
            migration, "_boottime_ns", return_value=123_500_000_000
        ), mock.patch.object(migration, "_validate_marker") as marker, mock.patch.object(
            migration, "_load_release_guard", return_value=object()
        ), mock.patch.object(
            migration,
            "_verified_current_release",
            return_value=(target, self.manifest(), str(authorization["manifestSha256"])),
        ), mock.patch.object(
            migration, "_current_release", return_value=target
        ), mock.patch.object(migration, "_validate_live_issuer") as issuer, mock.patch.object(
            migration,
            "_validate_freshness",
            wraps=migration._validate_freshness,
        ) as freshness:
            migration._validate_authorization(authorization)
        self.assertEqual(marker.call_args_list, [mock.call(authorization), mock.call(authorization)])
        issuer.assert_called_once_with(authorization)
        self.assertEqual(freshness.call_count, 2)

    def test_expiry_after_full_payload_and_issuer_verification_is_rejected(self) -> None:
        authorization = self.authorization()
        target = Path(str(authorization["targetPath"]))
        expiry = migration.MigrationAuthorizationError(
            "migration authorization is expired after verification"
        )
        with mock.patch.object(
            migration, "_boot_id", return_value=str(authorization["bootId"])
        ), mock.patch.object(
            migration, "_validate_freshness", side_effect=(None, expiry)
        ) as freshness, mock.patch.object(
            migration, "_validate_marker"
        ), mock.patch.object(
            migration, "_load_release_guard", return_value=object()
        ), mock.patch.object(
            migration,
            "_verified_current_release",
            return_value=(target, self.manifest(), str(authorization["manifestSha256"])),
        ), mock.patch.object(
            migration, "_current_release", return_value=target
        ), mock.patch.object(
            migration, "_validate_live_issuer"
        ) as issuer, self.assertRaisesRegex(
            migration.MigrationAuthorizationError, "expired after verification"
        ):
            migration._validate_authorization(authorization)
        issuer.assert_called_once_with(authorization)
        self.assertEqual(freshness.call_count, 2)

    def test_expired_cross_boot_wrong_current_and_marker_drift_are_rejected(self) -> None:
        cases: list[tuple[str, dict[str, object], str]] = []
        expired = self.authorization()
        expired["issuedAtUnix"] = 1
        expired["expiresAtUnix"] = 1 + migration.AUTHORIZATION_TTL_SECONDS
        cases.append(("expired", expired, "expired"))
        cross_boot = self.authorization()
        cross_boot["bootId"] = "11111111-1111-1111-1111-111111111111"
        cases.append(("cross-boot", cross_boot, "another boot"))
        for label, authorization, message in cases:
            with self.subTest(label=label), mock.patch.object(
                migration,
                "_boot_id",
                return_value="01234567-89ab-cdef-0123-456789abcdef",
            ), mock.patch.object(
                migration, "_boottime_ns", return_value=123_500_000_000
            ), self.assertRaisesRegex(migration.MigrationAuthorizationError, message):
                migration._validate_authorization(authorization)

        authorization = self.authorization()
        with mock.patch.object(
            migration, "_boot_id", return_value=str(authorization["bootId"])
        ), mock.patch.object(
            migration, "_boottime_ns", return_value=123_500_000_000
        ), mock.patch.object(
            migration,
            "_validate_marker",
            side_effect=migration.MigrationAuthorizationError("marker changed"),
        ), self.assertRaisesRegex(migration.MigrationAuthorizationError, "marker changed"):
            migration._validate_authorization(authorization)

        with mock.patch.object(
            migration, "_boot_id", return_value=str(authorization["bootId"])
        ), mock.patch.object(
            migration, "_boottime_ns", return_value=123_500_000_000
        ), mock.patch.object(migration, "_validate_marker"), mock.patch.object(
            migration, "_load_release_guard", return_value=object()
        ), mock.patch.object(
            migration,
            "_verified_current_release",
            return_value=(
                Path("/opt/uten-imp/releases/v2026.08.11-1"),
                self.manifest(),
                str(authorization["manifestSha256"]),
            ),
        ), self.assertRaisesRegex(
            migration.MigrationAuthorizationError, "signed current release"
        ):
            migration._validate_authorization(authorization)

    def test_clock_boottime_expiry_rejects_wall_clock_rollback(self) -> None:
        authorization = self.authorization()
        with mock.patch.object(
            migration, "_boottime_ns", return_value=999_000_000_000
        ), mock.patch.object(
            migration.time,
            "time",
            return_value=int(authorization["issuedAtUnix"]),
        ), self.assertRaisesRegex(
            migration.MigrationAuthorizationError, "expired"
        ):
            migration._validate_freshness(authorization)

    def test_exact_expiry_boundary_is_rejected(self) -> None:
        authorization = self.authorization()
        with mock.patch.object(
            migration.time,
            "time",
            return_value=int(authorization["expiresAtUnix"]),
        ), mock.patch.object(
            migration,
            "_boottime_ns",
            return_value=int(authorization["expiresAtBoottimeNs"]),
        ), self.assertRaisesRegex(
            migration.MigrationAuthorizationError, "expired"
        ):
            migration._validate_freshness(authorization)

    def test_manual_start_without_grant_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "authorization"
            directory.mkdir()
            source = directory / "migration-authorization.json"
            with mock.patch.object(migration, "AUTHORIZATION_DIR", directory), mock.patch.object(
                migration, "AUTHORIZATION", source
            ), mock.patch.object(migration.os, "geteuid", return_value=0), mock.patch.object(
                migration, "_require_root_directory"
            ), mock.patch.object(migration, "_require_root_file"):
                self.assertEqual(migration.main(["consume"]), 1)
            self.assertFalse(any(directory.iterdir()))

    def test_grant_without_activation_marker_is_rejected(self) -> None:
        authorization = self.authorization()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / "activation-in-progress.json"
            failure = root / "activation-failed.json"
            authorization["markerPath"] = str(marker)
            with mock.patch.object(
                migration, "ACTIVATION_IN_PROGRESS_MARKER", marker
            ), mock.patch.object(
                migration, "ACTIVATION_FAILURE_MARKER", failure
            ), mock.patch.object(
                migration, "_require_root_parent_chain"
            ), self.assertRaisesRegex(
                migration.MigrationAuthorizationError, "required file is missing"
            ):
                migration._validate_marker(authorization)

    def test_consume_is_atomic_and_replay_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "authorization"
            directory.mkdir()
            source = directory / "migration-authorization.json"
            raw = json.dumps(self.authorization()).encode("utf-8")
            source.write_bytes(raw)

            def read_bytes(path: Path, **_kwargs: object) -> bytes:
                return Path(path).read_bytes()

            patches = (
                mock.patch.object(migration, "AUTHORIZATION_DIR", directory),
                mock.patch.object(migration, "AUTHORIZATION", source),
                mock.patch.object(migration.os, "geteuid", return_value=0),
                mock.patch.object(migration, "_require_root_directory"),
                mock.patch.object(migration, "_require_root_file"),
                mock.patch.object(migration, "_fsync_directory"),
                mock.patch.object(migration, "_read_stable_bytes", side_effect=read_bytes),
                mock.patch.object(migration, "_validate_authorization"),
                mock.patch.object(migration, "_validate_transaction_evidence"),
                mock.patch.object(migration, "_validate_freshness"),
            )
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], patches[8], patches[9]:
                self.assertEqual(migration.consume(), "f" * 32)
                self.assertFalse(source.exists())
                archives = list(directory.glob("migration-authorization.consumed-*.json"))
                self.assertEqual(len(archives), 1)
                source.write_bytes(raw)
                self.assertEqual(migration.main(["consume"]), 1)
                self.assertFalse(source.exists())
                self.assertEqual(
                    list(directory.glob("migration-authorization.consumed-*.json")),
                    archives,
                )

    def test_sigkill_after_issue_is_archived_and_dead_issuer_cannot_migrate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "authorization"
            directory.mkdir()
            source = directory / "migration-authorization.json"
            source.write_text(json.dumps(self.authorization()), encoding="utf-8")

            def read_bytes(path: Path, **_kwargs: object) -> bytes:
                return Path(path).read_bytes()

            with mock.patch.object(migration, "AUTHORIZATION_DIR", directory), mock.patch.object(
                migration, "AUTHORIZATION", source
            ), mock.patch.object(migration.os, "geteuid", return_value=0), mock.patch.object(
                migration, "_require_root_directory"
            ), mock.patch.object(migration, "_require_root_file"), mock.patch.object(
                migration, "_fsync_directory"
            ), mock.patch.object(
                migration, "_read_stable_bytes", side_effect=read_bytes
            ), mock.patch.object(
                migration,
                "_validate_authorization",
                side_effect=migration.MigrationAuthorizationError(
                    "authorized updater process is not alive"
                ),
            ):
                self.assertEqual(migration.main(["consume"]), 1)
            self.assertFalse(source.exists())
            self.assertEqual(
                len(list(directory.glob("migration-authorization.consumed-*.json"))),
                1,
            )

    def test_dead_or_reused_issuer_pid_is_rejected(self) -> None:
        authorization = self.authorization()
        with mock.patch.object(
            migration,
            "_read_proc_start_time",
            side_effect=migration.MigrationAuthorizationError(
                "authorized updater process is not alive"
            ),
        ), self.assertRaisesRegex(
            migration.MigrationAuthorizationError, "not alive"
        ):
            migration._validate_live_issuer(authorization)

    @unittest.skipUnless(os.name == "posix", "operation lock inode test")
    def test_issuer_must_hold_the_exact_operation_lock_inode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / "operation.lock"
            lock.write_bytes(b"")
            descriptor_dir = root / "proc" / "4242" / "fd"
            descriptor_dir.mkdir(parents=True)
            (descriptor_dir / "7").symlink_to(lock)
            fake_group = SimpleNamespace(gr_gid=1234)
            fake_grp = SimpleNamespace(getgrnam=lambda _name: fake_group)
            with mock.patch.object(
                migration, "OPERATION_LOCK", lock
            ), mock.patch.object(
                migration, "PROC_ROOT", root / "proc"
            ), mock.patch.object(
                migration, "_require_root_file", return_value=lock.stat()
            ), mock.patch.dict(
                sys.modules, {"grp": fake_grp}
            ):
                migration._issuer_holds_operation_lock(4242)
                (descriptor_dir / "7").unlink()
                with self.assertRaisesRegex(
                    migration.MigrationAuthorizationError, "does not hold"
                ):
                    migration._issuer_holds_operation_lock(4242)

    @unittest.skipUnless(
        os.name == "posix" and getattr(os, "geteuid", lambda: -1)() == 0,
        "root metadata test",
    )
    def test_owner_mode_and_symlink_drift_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            file = root / "authorization.json"
            file.write_text("{}", encoding="utf-8")
            file.chmod(0o644)
            with mock.patch.object(migration, "_require_root_parent_chain"):
                with self.assertRaises(migration.MigrationAuthorizationError):
                    migration._require_root_file(file, mode=0o600)
            file.chmod(0o600)
            link = root / "link.json"
            link.symlink_to(file)
            with mock.patch.object(migration, "_require_root_parent_chain"):
                with self.assertRaises(migration.MigrationAuthorizationError):
                    migration._require_root_file(link, mode=0o600)


if __name__ == "__main__":
    unittest.main()
