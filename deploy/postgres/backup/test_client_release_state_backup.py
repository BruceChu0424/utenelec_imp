"""Real Linux filesystem, Java lock interoperability, and paired cold restore."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

import client_release_state_backup as client
import paired_internal_backup as paired

ID = "12345678-1234-1234-1234-123456789abc"
OTHER = "22345678-1234-1234-1234-123456789abc"


class ClientRuntimeContractTest(unittest.TestCase):
    """Metadata-only cases run on Windows as well as the Linux backup host."""

    def release(self, **changes):
        value = {"platform": "windows", "architecture": "x64", "installMode": "windows_archive"}
        value.update(changes)
        return value

    def test_legacy_absent_null_and_explicit_flutter_are_not_rewritten(self):
        for fields in ({}, {"runtimeFamily": None}, {"runtimeFamily": "flutter"}):
            for kind in ({}, {"packageKind": None}, {"packageKind": "update"}):
                with self.subTest(fields=fields, kind=kind):
                    metadata = self.release(**fields, **kind)
                    before = json.dumps(metadata, sort_keys=True)
                    self.assertEqual(("flutter", "update"), client._validate_runtime_contract(metadata))
                    self.assertEqual(before, json.dumps(metadata, sort_keys=True))

    def test_valid_wpf_targets_and_matching_kinds(self):
        for architecture in ("x86", "x64"):
            for mode, kind in (("windows_wpf_setup", "installer"), ("windows_wpf_archive", "update")):
                with self.subTest(architecture=architecture, mode=mode):
                    value = self.release(runtimeFamily="wpf_legacy", architecture=architecture, installMode=mode,
                                         packageKind=kind, fileName="Uten-Win7-Setup.EXE")
                    self.assertEqual(("wpf_legacy", kind), client._validate_runtime_contract(value))
    def test_delivery_contract_is_optional_preserved_and_target_bound(self):
        for contract in (None, "paired_v1"):
            value = self.release(deliveryContract=contract)
            before = json.dumps(value, sort_keys=True)
            self.assertEqual(("flutter", "update"), client._validate_runtime_contract(value))
            self.assertEqual(before, json.dumps(value, sort_keys=True))
        android = {"platform": "android", "architecture": "arm64", "installMode": "android_package",
                   "runtimeFamily": "flutter", "deliveryContract": "audited_v1"}
        self.assertEqual(("flutter", "update"), client._validate_runtime_contract(android))
        for fields in ({"deliveryContract": "audited_v1"}, {"deliveryContract": "unknown"},
                       {"deliveryContract": False}, {"deliveryContract": []},
                       {"platform": "android", "architecture": "arm64", "installMode": "android_package", "deliveryContract": "paired_v1"}):
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                client._validate_runtime_contract(self.release(**fields))

    def test_malformed_family_mode_architecture_or_platform_is_rejected(self):
        for field, malformed in (("runtimeFamily", ["", "Flutter", "wpf", False, 1, [], {}]),
                                 ("architecture", [None, "", "X64", "x86_64", "riscv64", [], {}]),
                                 ("platform", [None, "", "win7", "web", [], {}]),
                                 ("installMode", [None, "", "windows_unknown", [], {}])):
            for value in malformed:
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    client._validate_runtime_contract(self.release(**{field: value}))

    def test_runtime_mode_and_target_mismatches_are_rejected(self):
        invalid = [
            {"runtimeFamily": "flutter", "installMode": "windows_wpf_archive"},
            {"runtimeFamily": None, "installMode": "windows_wpf_archive"},
            {"installMode": "windows_wpf_archive"},
            {"runtimeFamily": "flutter", "installMode": "windows_wpf_setup", "packageKind": "installer", "fileName": "x.exe"},
            {"runtimeFamily": "wpf_legacy", "installMode": "windows_archive"},
            {"runtimeFamily": "wpf_legacy", "installMode": "windows_setup", "packageKind": "installer", "fileName": "x.exe"},
            {"runtimeFamily": "wpf_legacy", "installMode": "windows_bundle", "packageKind": "installer"},
            {"runtimeFamily": "wpf_legacy", "installMode": "store"},
            {"runtimeFamily": "wpf_legacy", "installMode": "windows_wpf_archive", "architecture": "arm64"},
            {"runtimeFamily": "wpf_legacy", "installMode": "windows_wpf_archive", "architecture": "universal"},
            {"runtimeFamily": "wpf_legacy", "installMode": "windows_wpf_archive", "platform": "android"},
            {"runtimeFamily": "wpf_legacy", "installMode": "windows_wpf_archive", "packageKind": "installer"},
            {"runtimeFamily": "wpf_legacy", "installMode": "windows_wpf_setup", "packageKind": "update"},
        ]
        for fields in invalid:
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                client._validate_runtime_contract(self.release(**fields))

    def test_wpf_setup_executable_name_and_legacy_modes_keep_their_contracts(self):
        for filename in (None, "setup.zip", "../setup.exe", "setup.exe/", "setup\n.exe"):
            with self.subTest(filename=filename), self.assertRaisesRegex(ValueError, "executable filename"):
                client._validate_runtime_contract(self.release(runtimeFamily="wpf_legacy", installMode="windows_wpf_setup",
                    packageKind="installer", fileName=filename))
        for mode, kind in (("windows_setup", "installer"), ("windows_bundle", "installer"), ("windows_archive", "update")):
            self.assertEqual(("flutter", kind), client._validate_runtime_contract(
                self.release(installMode=mode, packageKind=kind, fileName="Setup.exe")))


@unittest.skipUnless(os.name == "posix", "the paired host uses Linux POSIX record locks")
class ClientReleaseStateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "catalog"
        self.source.mkdir()
        (self.source / ".catalog.lock").touch()
        self.destination = self.root / "export"
        self.target = self.root / "restored"

    def release(self, identifier=ID, *, state="PUBLISHED", mode="windows_archive", data=b"real package bytes", uploaded=True,
                kind=None, filename=None, runtime="absent", architecture="x64"):
        folder = self.source / identifier
        folder.mkdir(exist_ok=True)
        digest = hashlib.sha256(data).hexdigest() if mode != "store" else None
        value = {"id": identifier, "platform": "windows", "architecture": architecture, "version": "2.5.28",
                 "buildNumber": 2528, "state": state, "installMode": mode,
                 "expectedSha256": digest, "sha256": digest if uploaded else None,
                 "sizeBytes": len(data) if uploaded and mode != "store" else 0,
                 "releaseNotes": "Recover metadata and its exact package together"}
        if kind is not None:
            value["packageKind"] = kind
        if filename is not None:
            value["fileName"] = filename
        if runtime != "absent":
            value["runtimeFamily"] = runtime
        if uploaded and mode != "store":
            (folder / "package.bin").write_bytes(data)
        (folder / "release.json").write_text(json.dumps(value), encoding="utf-8")
        return value

    def test_mixed_runtime_pair_backup_preserves_metadata_and_each_binary_exactly(self):
        fixtures = (
            (ID, {}, b"legacy flutter update"),
            (OTHER, {"mode": "windows_setup", "kind": "installer", "filename": "Flutter-Setup.exe", "runtime": None}, b"flutter setup"),
            ("32345678-1234-1234-1234-123456789abc", {"mode": "windows_bundle", "kind": "installer", "runtime": "flutter"}, b"legacy flutter bundle"),
            ("42345678-1234-1234-1234-123456789abc", {"mode": "windows_wpf_setup", "kind": "installer", "filename": "WPF-Setup.exe", "runtime": "wpf_legacy", "architecture": "x86"}, b"wpf x86 setup"),
            ("52345678-1234-1234-1234-123456789abc", {"mode": "windows_wpf_archive", "kind": "update", "runtime": "wpf_legacy", "architecture": "x86"}, b"wpf x86 update"),
            ("62345678-1234-1234-1234-123456789abc", {"mode": "windows_wpf_setup", "kind": "installer", "filename": "WPF-x64-Setup.exe", "runtime": "wpf_legacy"}, b"wpf x64 setup"),
            ("72345678-1234-1234-1234-123456789abc", {"mode": "windows_wpf_archive", "kind": "update", "runtime": "wpf_legacy"}, b"wpf x64 update"),
        )
        originals = {}
        for identifier, options, data in fixtures:
            self.release(identifier, data=data, **options)
            metadata = self.source / identifier / "release.json"
            # Noncanonical whitespace and Unicode are audit bytes, not an invitation to normalize.
            metadata.write_bytes(json.dumps(json.loads(metadata.read_bytes()), ensure_ascii=False, indent=3).encode("utf-8") + b"\n")
            originals[identifier] = {"release.json": metadata.read_bytes(), "package.bin": data}
        work, summary = self.make_pair(seed=False)
        target = self.root / "mixed-runtime-media"
        target.mkdir()
        report = paired.restore_client_release_states(work, target)
        self.assertEqual((7, 14), (report["internal"]["releases"], report["internal"]["files"]))
        for identifier, files in originals.items():
            for name, original in files.items():
                self.assertEqual(original, (target / "client-releases" / identifier / name).read_bytes())
        self.assertEqual(summary, paired.verify_set(work))

    def test_withdrawn_wpf_tombstones_do_not_restore_leftover_binaries(self):
        originals = {}
        for identifier, mode, kind in ((ID, "windows_wpf_setup", "installer"), (OTHER, "windows_wpf_archive", "update")):
            self.release(identifier, mode=mode, kind=kind, filename="WPF-Setup.exe", runtime="wpf_legacy")
            metadata = self.source / identifier / "release.json"
            value = json.loads(metadata.read_bytes())
            value.update(state="WITHDRAWN", sha256=None, sizeBytes=0)
            metadata.write_bytes(json.dumps(value, indent=2).encode("utf-8"))
            originals[identifier] = metadata.read_bytes()
        summary = client.export_client_releases(self.source, self.destination)
        self.assertEqual((2, 2), (summary["releases"], summary["files"]))
        client.restore_client_releases(self.destination, self.target)
        for identifier, raw in originals.items():
            self.assertEqual(raw, (self.target / identifier / "release.json").read_bytes())
            self.assertFalse((self.target / identifier / "package.bin").exists())

    def test_invalid_runtime_metadata_never_publishes_a_backup(self):
        for fields in ({"runtimeFamily": []}, {"runtimeFamily": "wpf_legacy"},
                       {"runtimeFamily": "wpf_legacy", "installMode": "windows_wpf_archive", "architecture": "arm64"},
                       {"runtimeFamily": "flutter", "installMode": "windows_wpf_archive"}):
            with self.subTest(fields=fields):
                self.release(state="WITHDRAWN", uploaded=False)
                metadata = self.source / ID / "release.json"
                value = json.loads(metadata.read_bytes())
                value.update(fields)
                metadata.write_text(json.dumps(value), encoding="utf-8")
                with self.assertRaises(ValueError):
                    client.export_client_releases(self.source, self.destination)
                self.assertFalse(self.destination.exists())
                self.assertEqual([], list(self.root.glob(".market-state-*")))

    def test_self_consistent_manifest_cannot_hide_runtime_mismatch_on_restore(self):
        self.release(mode="windows_wpf_archive", kind="update", runtime="wpf_legacy")
        client.export_client_releases(self.source, self.destination)
        metadata = self.destination / ID / "release.json"
        value = json.loads(metadata.read_bytes())
        value["runtimeFamily"] = "flutter"
        raw = json.dumps(value).encode("utf-8")
        metadata.write_bytes(raw)
        manifest_path = self.destination / client.MANIFEST
        manifest = json.loads(manifest_path.read_bytes())
        record = next(row for row in manifest["records"] if row["path"] == ID + "/release.json")
        manifest["bytes"] += len(raw) - record["size"]
        record.update(size=len(raw), sha256=hashlib.sha256(raw).hexdigest())
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaises(ValueError):
            client.restore_client_releases(self.destination, self.target)
        self.assertFalse(self.target.exists())

    def test_committed_package_and_metadata_round_trip_and_ignore_upload_work(self):
        self.release()
        folder = self.source / ID
        (folder / ".upload-12345678-1234-1234-1234-123456789abc.tmp").write_bytes(b"incomplete upload")
        (folder / ".metadata-12345678-1234-1234-1234-123456789abc.tmp").write_bytes(b"not committed")
        raw = (folder / "release.json").read_bytes()
        summary = client.export_client_releases(self.source, self.destination)
        self.assertEqual((1, 2), (summary["releases"], summary["files"]))
        self.assertEqual(summary, client.verify_client_releases(self.destination))
        self.assertEqual(summary, client.restore_client_releases(self.destination, self.target))
        self.assertEqual(raw, (self.target / ID / "release.json").read_bytes())
        self.assertEqual(b"real package bytes", (self.target / ID / "package.bin").read_bytes())
        self.assertEqual({ID, ".catalog.lock"}, {p.name for p in self.target.iterdir()})
        self.assertEqual({"release.json", "package.bin"}, {p.name for p in (self.target / ID).iterdir()})
        self.assertEqual(0, (self.target / ".catalog.lock").stat().st_size)
        self.assertEqual(0o600, (self.target / ID / "release.json").stat().st_mode & 0o777)
        self.assertEqual(summary["files"], client.export_client_releases(self.target, self.root / "cold-reexport")["files"])

    def test_draft_and_store_and_withdrawn_records_keep_their_distinct_contracts(self):
        self.release(state="DRAFT", uploaded=False)
        self.release(OTHER, state="WITHDRAWN")
        store = "32345678-1234-1234-1234-123456789abc"
        self.release(store, mode="store")
        summary = client.export_client_releases(self.source, self.destination)
        self.assertEqual((3, 4), (summary["releases"], summary["files"]))
        client.restore_client_releases(self.destination, self.target)
        self.assertFalse((self.target / ID / "package.bin").exists())
        self.assertFalse((self.target / store / "package.bin").exists())
        self.assertEqual("WITHDRAWN", json.loads((self.target / OTHER / "release.json").read_text())["state"])

    def test_legacy_update_and_new_full_installer_share_a_lossless_cold_restore(self):
        self.release()  # Existing metadata has no packageKind field.
        self.release(OTHER, mode="windows_bundle", kind="installer", data=b"complete first-install fixture")
        originals = {identifier: (self.source / identifier / "release.json").read_bytes()
                     for identifier in (ID, OTHER)}
        work, summary = self.make_pair()
        target = self.root / "new-mixed-media"
        target.mkdir()
        report = paired.restore_client_release_states(work, target)
        self.assertEqual((2, 4), (report["internal"]["releases"], report["internal"]["files"]))
        for identifier in (ID, OTHER):
            self.assertEqual(originals[identifier], (target / "client-releases" / identifier / "release.json").read_bytes())
        self.assertEqual(b"complete first-install fixture", (target / "client-releases" / OTHER / "package.bin").read_bytes())
        self.assertEqual(summary, paired.verify_set(work))

    def test_setup_exe_legacy_bundle_and_update_keep_exact_bytes_through_cold_restore(self):
        setup = "42345678-1234-1234-1234-123456789abc"
        self.release()  # Legacy update without a packageKind field.
        self.release(OTHER, mode="windows_bundle", kind="installer", state="WITHDRAWN",
                     data=b"legacy complete ZIP catalog fixture")
        self.release(setup, mode="windows_setup", kind="installer", filename="Uten-Setup-2.5.32.EXE",
                     data=b"MZ synthetic Setup.exe fixture only; not a runnable client")
        originals = {identifier: {name: (self.source / identifier / name).read_bytes()
                                  for name in ("release.json", "package.bin")}
                     for identifier in (ID, OTHER, setup)}
        work, summary = self.make_pair()
        target = self.root / "new-setup-media"
        target.mkdir()
        report = paired.restore_client_release_states(work, target)
        self.assertEqual((3, 6), (report["internal"]["releases"], report["internal"]["files"]))
        for identifier, files in originals.items():
            for name, original in files.items():
                self.assertEqual(original, (target / "client-releases" / identifier / name).read_bytes())
        self.assertEqual(summary, paired.verify_set(work))

    def test_latest_windows_pair_restores_retired_receipts_without_resurrecting_old_packages(self):
        old_setup = ID
        old_update = OTHER
        latest_setup = "42345678-1234-1234-1234-123456789abc"
        latest_update = "52345678-1234-1234-1234-123456789abc"
        self.release(old_setup, mode="windows_setup", kind="installer", filename="UTEN-Old-Setup.exe",
                     data=b"old setup payload")
        self.release(old_update, kind="update", filename="UTEN-old-update.zip", data=b"old update payload")
        originals = {}
        for identifier in (old_setup, old_update):
            metadata = self.source / identifier / "release.json"
            value = json.loads(metadata.read_text())
            value.update(state="WITHDRAWN", sha256=None, sizeBytes=0,
                         publishedAt="2026-10-22T18:00:00Z")
            metadata.write_text(json.dumps(value), encoding="utf-8")
            originals[identifier] = metadata.read_bytes()
        # Simulate the retention order: metadata commits before unlinking bytes.
        # One interrupted unlink must not turn an old package into a restored pair.
        (self.source / old_setup / "package.bin").unlink()
        self.release(latest_setup, mode="windows_setup", kind="installer", filename="UTEN-Setup.exe",
                     data=b"latest setup payload")
        self.release(latest_update, kind="update", filename="UTEN-update.zip", data=b"latest update payload")
        for identifier in (latest_setup, latest_update):
            metadata = self.source / identifier / "release.json"
            value = json.loads(metadata.read_text())
            value.update(version="2.5.32", buildNumber=2532, publishedAt="2026-10-26T18:00:00Z")
            metadata.write_text(json.dumps(value), encoding="utf-8")
            originals[identifier] = metadata.read_bytes()

        work, summary = self.make_pair(seed=False)
        self.assertEqual((4, 6), (summary["client_release_state"]["internal"]["releases"],
                                 summary["client_release_state"]["internal"]["files"]))
        target = self.root / "latest-pair-media"
        target.mkdir()
        report = paired.restore_client_release_states(work, target)
        self.assertEqual(summary["client_release_state"]["internal"], report["internal"])
        restored = target / "client-releases"
        for identifier, raw in originals.items():
            self.assertEqual(raw, (restored / identifier / "release.json").read_bytes())
        for identifier in (old_setup, old_update):
            self.assertFalse((restored / identifier / "package.bin").exists())
            receipt = json.loads((restored / identifier / "release.json").read_text())
            self.assertEqual("WITHDRAWN", receipt["state"])
            self.assertIsNone(receipt["sha256"])
            self.assertEqual("2026-10-22T18:00:00Z", receipt["publishedAt"])
            self.assertEqual(64, len(receipt["expectedSha256"]))
        self.assertEqual(b"latest setup payload", (restored / latest_setup / "package.bin").read_bytes())
        self.assertEqual(b"latest update payload", (restored / latest_update / "package.bin").read_bytes())
        self.assertEqual(2, len(list(restored.glob("*/package.bin"))))
        self.assertEqual(summary, paired.verify_set(work))

    def test_retired_receipt_does_not_hide_corrupt_latest_pair_from_backup_verification(self):
        self.release(state="WITHDRAWN", uploaded=False)
        self.release(OTHER, kind="update", data=b"latest committed update")
        (self.source / OTHER / "package.bin").write_bytes(b"corrupt latest update")
        with self.assertRaisesRegex(ValueError, "integrity"):
            client.export_client_releases(self.source, self.destination)
        self.assertFalse(self.destination.exists())

    def test_windows_setup_requires_installer_kind_windows_platform_and_safe_exe_name(self):
        for kind, platform, filename in (("update", "windows", "Uten-Setup.exe"),
                                          ("installer", "android", "Uten-Setup.exe"),
                                          ("installer", "windows", "Uten-Setup.zip"),
                                          ("installer", "windows", "../Uten-Setup.exe"),
                                          ("installer", "windows", None)):
            with self.subTest(kind=kind, platform=platform, filename=filename):
                self.release(mode="windows_setup", kind=kind, filename=filename)
                metadata = self.source / ID / "release.json"
                value = json.loads(metadata.read_text())
                value["platform"] = platform
                metadata.write_text(json.dumps(value))
                with self.assertRaisesRegex(ValueError, "package kind/install mode|executable filename"):
                    client.export_client_releases(self.source, self.destination)
                self.assertFalse(self.destination.exists())

    def test_installer_kind_mode_or_platform_mismatch_is_not_a_valid_backup(self):
        for mode, kind, platform in (("windows_bundle", "update", "windows"),
                                      ("windows_archive", "installer", "windows"),
                                      ("windows_bundle", "installer", "android")):
            with self.subTest(mode=mode, kind=kind, platform=platform):
                self.release(mode=mode, kind=kind)
                metadata = self.source / ID / "release.json"
                value = json.loads(metadata.read_text())
                value["platform"] = platform
                metadata.write_text(json.dumps(value))
                with self.assertRaisesRegex(ValueError, "package kind/install mode"):
                    client.export_client_releases(self.source, self.destination)
                self.assertFalse(self.destination.exists())

    def test_legacy_explicit_null_kind_still_restores_its_exact_metadata(self):
        self.release()
        metadata = self.source / ID / "release.json"
        value = json.loads(metadata.read_text())
        value["packageKind"] = None
        raw = json.dumps(value).encode()
        metadata.write_bytes(raw)
        client.export_client_releases(self.source, self.destination)
        client.restore_client_releases(self.destination, self.target)
        self.assertEqual(raw, (self.target / ID / "release.json").read_bytes())

    def test_uncommitted_draft_binary_does_not_become_an_uploaded_restored_pair(self):
        self.release(state="DRAFT", uploaded=False)
        (self.source / ID / "package.bin").write_bytes(b"crash before metadata commit")
        self.assertEqual(1, client.export_client_releases(self.source, self.destination)["files"])
        client.restore_client_releases(self.destination, self.target)
        self.assertFalse((self.target / ID / "package.bin").exists())

    def test_published_missing_package_or_wrong_digest_fails_without_publishing_backup(self):
        self.release()
        package = self.source / ID / "package.bin"
        for data in [None, b"corrupt package bytes"]:
            with self.subTest(data=data):
                if data is None:package.unlink()
                else:package.write_bytes(data)
                with self.assertRaisesRegex(ValueError, "missing|integrity"):
                    client.export_client_releases(self.source, self.destination)
                self.assertFalse(self.destination.exists())
                self.assertEqual([], list(self.root.glob(".market-state-*")))

    def test_published_metadata_without_commit_hash_is_not_a_recoverable_release(self):
        self.release(uploaded=False)
        with self.assertRaisesRegex(ValueError, "no committed package"):
            client.export_client_releases(self.source, self.destination)

    def test_duplicate_json_identity_and_oversized_metadata_are_rejected(self):
        self.release()
        metadata = self.source / ID / "release.json"
        for payload in [b'{"id":"one","id":"two"}', b" " * (client.MAX_METADATA_BYTES + 1)]:
            with self.subTest(size=len(payload)):
                metadata.write_bytes(payload)
                with self.assertRaises(ValueError):client.export_client_releases(self.source, self.destination)

    def test_links_and_hardlinks_cannot_escape_the_catalog(self):
        self.release()
        package = self.source / ID / "package.bin"
        outside = self.root / "private-outside.bin"
        outside.write_bytes(package.read_bytes())
        for hard in [False, True]:
            with self.subTest(hard=hard):
                package.unlink()
                os.link(outside, package) if hard else package.symlink_to(outside)
                with self.assertRaises(ValueError):client.export_client_releases(self.source, self.destination)

    def test_missing_or_linked_writer_barrier_fails_closed(self):
        self.release()
        barrier = self.source / ".catalog.lock"
        barrier.unlink()
        with self.assertRaises(FileNotFoundError):client.export_client_releases(self.source, self.destination)
        other = self.root / "foreign-lock"
        other.touch()
        barrier.symlink_to(other)
        with self.assertRaises(ValueError):client.export_client_releases(self.source, self.destination)

    def test_budget_failure_keeps_previous_destination_and_cleans_private_stage(self):
        self.release()
        calls = []
        def exhausted(count):
            calls.append(count)
            if count:raise TimeoutError("isolated byte/time budget exhausted")
        with self.assertRaises(TimeoutError):client.export_client_releases(self.source, self.destination, copy_budget=exhausted)
        self.assertTrue(calls)
        self.assertFalse(self.destination.exists())
        self.assertEqual([], list(self.root.glob(".market-state-*")))

    def test_tamper_extra_inventory_and_traversal_never_verify(self):
        self.release()
        client.export_client_releases(self.source, self.destination)
        package = self.destination / ID / "package.bin"
        original = package.read_bytes()
        package.write_bytes(b"tampered")
        with self.assertRaises(ValueError):client.verify_client_releases(self.destination)
        package.write_bytes(original)
        extra = self.destination / ID / "unexpected.bin"
        extra.write_bytes(b"must not disappear from verification")
        with self.assertRaises(ValueError):client.verify_client_releases(self.destination)
        extra.unlink()
        empty = self.destination / OTHER
        empty.mkdir()
        with self.assertRaises(ValueError):client.verify_client_releases(self.destination)
        empty.rmdir()
        path = self.destination / client.MANIFEST
        manifest = json.loads(path.read_text())
        manifest["records"][0]["path"] = "../outside"
        path.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):client.verify_client_releases(self.destination)

    def test_restore_refuses_existing_data_and_preserves_it(self):
        self.release()
        client.export_client_releases(self.source, self.destination)
        self.target.mkdir()
        (self.target / "keep.bin").write_bytes(b"preserve")
        with self.assertRaises(FileExistsError):client.restore_client_releases(self.destination, self.target)
        self.assertEqual(b"preserve", (self.target / "keep.bin").read_bytes())

    @unittest.skipUnless(shutil.which("java"), "Java launcher required for cross-language lock proof")
    def test_java_filechannel_exclusive_lock_blocks_shared_backup_lock(self):
        self.release()
        source = self.root / "CatalogWriter.java"
        source.write_text('''import java.nio.channels.*; import java.nio.file.*;
class CatalogWriter { public static void main(String[] a) throws Exception {
try (var c=FileChannel.open(Path.of(a[0]),StandardOpenOption.WRITE); var l=c.lock()) {
Files.writeString(Path.of(a[1]),"ready");
while(!Files.exists(Path.of(a[2]))) Thread.sleep(20);
}}}''')
        ready, release = self.root / "java-ready", self.root / "java-release"
        writer = subprocess.Popen([shutil.which("java"), str(source), str(self.source / ".catalog.lock"), str(ready), str(release)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 20
            while not ready.exists():
                if writer.poll() is not None or time.monotonic() > deadline:
                    self.fail("Isolated Java writer did not acquire its FileChannel lock")
                time.sleep(.05)
            with self.assertRaises(BlockingIOError):
                with client.catalog_lock(self.source, timeout=.15):self.fail("Java lock was bypassed")
            release.touch()
            stdout, stderr = writer.communicate(timeout=10)
            self.assertEqual(0, writer.returncode, stderr.decode(errors="replace"))
            self.assertEqual(2, client.export_client_releases(self.source, self.destination)["files"])
        finally:
            if writer.poll() is None:writer.kill(); writer.communicate(timeout=5)

    def make_pair(self, *, configured=False, seed=True):
        if seed:self.release()
        media = self.root / "media"
        media.mkdir()
        if not configured:
            self.source.rename(media / "client-releases")
        work = self.root / "paired"
        work.mkdir()
        config = paired.Config(media_root=str(media), backup_root=str(self.root),
                               client_releases_root=str(self.source) if configured else None,
                               min_free_bytes=0, min_free_percent=0, bytes_per_second=10**9)
        scope = paired.export_client_release_states(config, work, paired.Budget(config, self.root))
        for name, raw in [("database.dump", b"isolated logical dump fixture"), ("objects.jsonl", b""), ("references.jsonl", b"")]:
            (work / name).write_bytes(raw)
        summary = {"format": "uten-paired-internal-v2", "client_release_state": scope,
                   "clean_objects": 0, "private_document_references": 0, "media_objects": 0, "stored_bytes": 0, "original_bytes": 0,
                   "database_dump_sha256": paired.digest_file(work / "database.dump"),
                   "objects_manifest_sha256": paired.digest_file(work / "objects.jsonl"),
                   "references_manifest_sha256": paired.digest_file(work / "references.jsonl")}
        (work / "manifest.json").write_text(json.dumps(summary))
        return work, summary

    def test_full_pair_verifies_and_cold_restores_bound_catalog_namespace(self):
        work, summary = self.make_pair()
        self.assertEqual(summary, paired.verify_set(work))
        target = self.root / "empty-new-media"
        target.mkdir()
        report = paired.restore_client_release_states(work, target)
        self.assertEqual(summary["client_release_state"]["internal"], report["internal"])
        self.assertEqual(b"real package bytes", (target / "client-releases" / ID / "package.bin").read_bytes())
        summary["client_release_state"]["internal"]["manifestSha256"] = "f" * 64
        (work / "manifest.json").write_text(json.dumps(summary))
        with self.assertRaisesRegex(ValueError, "manifest digest/count/bytes"):
            paired.verify_set(work)

    def test_custom_directory_requires_explicit_restore_target(self):
        work, _ = self.make_pair(configured=True)
        target = self.root / "new-media"
        target.mkdir()
        with self.assertRaisesRegex(ValueError, "explicit target"):
            paired.restore_client_release_states(work, target)
        restored = self.root / "configured-restored"
        paired.restore_client_release_states(work, target, client_releases_root=restored)
        self.assertTrue((restored / ID / "release.json").exists())

    def test_legacy_database_format_cannot_bypass_client_catalog_verification(self):
        work, summary = self.make_pair()
        (work / "media" / "final").mkdir(parents=True)
        summary["format"] = "uten-paired-internal-v1"
        (work / "manifest.json").write_text(json.dumps(summary))
        self.assertEqual("uten-paired-internal-v1", paired.verify_set(work)["format"])
        (work / "client-release-state" / "internal" / ID / "package.bin").write_bytes(b"corrupt legacy-labelled set")
        with self.assertRaisesRegex(ValueError, "integrity"):
            paired.verify_set(work)

    def test_old_paired_sets_remain_valid_but_unbound_client_bytes_are_rejected(self):
        paired.verify_client_release_states(self.root, {})
        (self.root / "client-release-state").mkdir()
        with self.assertRaisesRegex(ValueError, "Unbound"):
            paired.verify_client_release_states(self.root, {})


if __name__ == "__main__":unittest.main()
