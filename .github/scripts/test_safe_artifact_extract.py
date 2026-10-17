"""Offline hostile ZIP fixtures and the actual authenticated workflow boundary."""

from pathlib import Path
import json
import os
import re
import stat
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import safe_artifact_extract as unpack
import backend_test_shards as runner
import test_backend_test_shards as fixtures


class ArtifactExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / "checkout"
        self.server = self.workspace / "server"
        self.server.mkdir(parents=True)
        self.runner_temp = self.root / "runner-temp"
        self.raw = self.runner_temp / "raw"
        self.raw.mkdir(parents=True)
        self.sentinel = self.server / "application-prod.yml"
        self.sentinel.write_text("untouched-source", encoding="utf-8")

    def archive(self, entries, name="artifact", folder=None):
        parent = self.raw if folder is None else self.raw / folder
        parent.mkdir(exist_ok=True)
        path = parent / name
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
            for entry, content in entries:
                if isinstance(entry, str):
                    # Windows ZipInfo normalizes backslashes on construction;
                    # preserve the actual hostile central-directory bytes.
                    original = entry
                    entry = zipfile.ZipInfo(original)
                    entry.filename = entry.orig_filename = original
                archive.writestr(entry, content)
        return path

    def extract(self, artifact="backend-test-plan"):
        return unpack.extract_artifacts(self.raw, artifact, workspace=self.workspace,
                                        runner_temp=self.runner_temp)

    def assert_rejected(self, artifact="backend-test-plan", error=ValueError):
        with self.assertRaises(error):
            self.extract(artifact)
        self.assertEqual("untouched-source", self.sentinel.read_text(encoding="utf-8"))
        self.assertFalse((self.server / unpack.DESTINATIONS[artifact]).exists())
        self.assertEqual([], list(self.server.glob(".quality-artifact-*")))

    def test_named_raw_archive_uses_server_filename_without_assuming_zip_extension(self):
        self.archive([("plan.json", '{"source":"fixture"}'), ("inventory.json", "[]")], name="计划原件")
        result = self.extract()
        self.assertEqual({"archives": 1, "files": 2, "bytes": 22}, result)
        self.assertEqual([], list((self.server / "target-ci-plan").glob("*.zip")))
        self.assertEqual({"source": "fixture"}, json.loads((self.server / "target-ci-plan/plan.json").read_text()))

    def test_four_raw_archives_merge_original_shard_paths_and_preserve_full_report_gate(self):
        manifest = fixtures.plan([fixtures.test_class("example." + c + "Test") for c in "ABCD"], shards=4)
        for shard in manifest["shards"]:
            number = shard["id"]
            source = self.root / f"producer-{number}"
            cases = [fixtures.testcase(classname=name) for name in shard["classes"]]
            fixtures.save_report(source, manifest, number, cases)
            entries = [(f"shard-{number}/" + file.relative_to(source).as_posix(), file.read_bytes())
                       for file in source.rglob("*") if file.is_file()]
            # Same fallback filename in every SDK artifact directory must not overwrite.
            self.archive(entries, folder=f"backend-test-results-{number}")
        result = self.extract("backend-test-results-*")
        self.assertEqual(4, result["archives"])
        destination = self.server / "target-ci-reports"
        self.assertEqual({f"shard-{i}" for i in range(4)}, {p.name for p in destination.iterdir()})
        verified = runner.verify_reports(manifest, destination)
        self.assertTrue(verified["complete"], verified["errors"])
        self.assertEqual(4, sum(sum(shard["method_counts"].values()) for shard in verified["shards"]))

    def test_sdk_single_pattern_match_is_in_raw_root_and_remains_one_shard(self):
        self.archive([("shard-2/report.json", "{}"), ("shard-2/surefire-reports/TEST-example.xml", "<testsuite/>")])
        self.extract("backend-test-results-*")
        target = self.server / "target-ci-reports"
        self.assertTrue((target / "shard-2/report.json").is_file())
        self.assertEqual(["shard-2"], [p.name for p in target.iterdir()])

    def test_optional_reference_preserves_baseline_plan_and_shard_directory(self):
        self.archive([("baseline-plan.json", "{}"), ("shard-0/report.json", "{}")], name="reference.zip")
        self.extract("backend-unfiltered-reference")
        self.assertTrue((self.server / "target-ci-reference/baseline-plan.json").is_file())
        self.assertTrue((self.server / "target-ci-reference/shard-0/report.json").is_file())

    def test_empty_existing_destination_is_safe_to_replace(self):
        (self.server / "target-ci-plan").mkdir()
        self.archive([("plan.json", "{}")])
        self.extract()
        self.assertEqual("{}", (self.server / "target-ci-plan/plan.json").read_text())

    def test_nonempty_destination_is_not_overwritten(self):
        destination = self.server / "target-ci-plan"
        destination.mkdir()
        (destination / "plan.json").write_text("existing")
        self.archive([("plan.json", "replacement")])
        with self.assertRaisesRegex(ValueError, "already nonempty"):
            self.extract()
        self.assertEqual("existing", (destination / "plan.json").read_text())

    def test_unexpected_selector_and_missing_runner_boundary_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "selector"):
            self.extract("source")
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, "RUNNER_TEMP"):
            unpack.extract_artifacts(self.raw, "backend-test-plan", workspace=self.workspace)
        with self.assertRaisesRegex(ValueError, "outside"):
            unpack.extract_artifacts(self.raw, "backend-test-plan", workspace=self.workspace,
                                     runner_temp=self.workspace)

    def test_missing_plan_and_empty_zip_are_rejected(self):
        path = self.archive([])
        self.assert_rejected()
        path.unlink()
        self.archive([("other.json", "{}")])
        self.assert_rejected()

    def test_path_traversal_absolute_windows_aliases_and_control_names_are_rejected(self):
        for name in ("../outside", "/absolute", "C:/drive", "a\\escape", "./dot", "a//b", "a/../b",
                     "a:stream", "NUL.txt", "trailing.", "trailing ", "a/\x01control"):
            with self.subTest(member=name):
                path = self.archive([("plan.json", "{}"), (name, "payload")])
                self.assert_rejected()
                path.unlink()

    def test_nul_truncated_member_is_rejected_before_extraction(self):
        path = self.archive([("plan.json", "{}"), ("nulname", "payload")])
        path.write_bytes(path.read_bytes().replace(b"nulname", b"nul\x00ame"))
        self.assert_rejected()

    def test_duplicate_case_alias_and_file_parent_paths_are_rejected(self):
        for names in (("plan.json", "plan.json"), ("plan.json", "PLAN.json"),
                      ("a", "a/child"), ("a/child", "a")):
            with self.subTest(names=names):
                if names[0] == names[1]:
                    with self.assertWarns(UserWarning):
                        path = self.archive([(name, "{}") for name in names])
                else:
                    path = self.archive([("plan.json", "{}")] + [(name, "{}") for name in names if name != "plan.json"])
                self.assert_rejected()
                path.unlink()

    def test_zip_symlink_special_node_and_conflicting_directory_mode_are_rejected(self):
        for kind, name in ((stat.S_IFLNK, "link"), (stat.S_IFIFO, "fifo"), (stat.S_IFCHR, "char"),
                           (stat.S_IFBLK, "block"), (stat.S_IFSOCK, "socket"), (stat.S_IFDIR, "not-a-dir"),
                           (stat.S_IFREG, "not-a-file/")):
            with self.subTest(kind=kind):
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (kind | 0o600) << 16
                path = self.archive([("plan.json", "{}"), (info, "")])
                self.assert_rejected()
                path.unlink()

    def test_encrypted_zip_is_rejected_without_password_attempts(self):
        path = self.archive([("plan.json", "{}")])
        data = bytearray(path.read_bytes())
        for signature, offset in ((b"PK\x03\x04", 6), (b"PK\x01\x02", 8)):
            position = data.index(signature) + offset
            struct.pack_into("<H", data, position, struct.unpack_from("<H", data, position)[0] | 1)
        path.write_bytes(data)
        self.assert_rejected()

    def test_corrupt_crc_never_publishes_a_partial_destination(self):
        path = self.archive([("plan.json", "{}"), ("report.log", "unique-CRC-payload")])
        path.write_bytes(path.read_bytes().replace(b"unique-CRC-payload", b"broken-CRC-payload"))
        self.assert_rejected(error=zipfile.BadZipFile)

    def test_truncated_archive_is_rejected(self):
        path = self.archive([("plan.json", "{}")])
        path.write_bytes(path.read_bytes()[:30])
        self.assert_rejected(error=zipfile.BadZipFile)

    def test_resource_limits_reject_before_publish(self):
        self.archive([("plan.json", "{}"), ("log", "12345")])
        for field, limit in (("MAX_ARCHIVE_BYTES", 1), ("MAX_MEMBER_BYTES", 4),
                             ("MAX_TOTAL_BYTES", 6), ("MAX_MEMBERS", 1)):
            with self.subTest(limit=field), patch.object(unpack, field, limit):
                self.assert_rejected()

    def test_report_artifact_names_and_zip_shard_ownership_must_agree(self):
        for folder, members in (("unrelated", [("shard-0/a", "x")]),
                                ("backend-test-results-4", [("shard-0/a", "x")]),
                                ("backend-test-results-0", [("shard-1/a", "x")]),
                                ("backend-test-results-0", [("shard-0/a", "x"), ("shard-1/b", "x")]),
                                ("backend-test-results-0", [("application-prod.yml", "x")])):
            with self.subTest(folder=folder, members=members):
                path = self.archive(members, folder=folder)
                self.assert_rejected("backend-test-results-*")
                path.unlink()
                path.parent.rmdir()

    def symlink(self, target, link, directory=False):
        try:
            link.symlink_to(target, target_is_directory=directory)
        except OSError as error:
            self.skipTest(f"symlinks unavailable on this host: {error}")

    def test_raw_archive_symlink_is_never_followed(self):
        outside = self.root / "outside.zip"
        with zipfile.ZipFile(outside, "w") as archive:
            archive.writestr("plan.json", "{}")
        self.symlink(outside, self.raw / "artifact")
        self.assert_rejected()

    def test_raw_artifact_directory_symlink_is_never_followed(self):
        outside = self.root / "outside"
        outside.mkdir()
        self.symlink(outside, self.raw / "backend-test-results-0", directory=True)
        self.assert_rejected("backend-test-results-*")

    def test_output_symlink_cannot_target_source(self):
        self.archive([("plan.json", "{}")])
        self.symlink(self.workspace, self.server / "target-ci-plan", directory=True)
        with self.assertRaisesRegex(ValueError, "link"):
            self.extract()
        self.assertFalse((self.workspace / "plan.json").exists())

    def test_symlink_in_raw_staging_ancestry_is_rejected(self):
        alternate = self.runner_temp / "alternate"
        self.symlink(self.raw, alternate, directory=True)
        with self.assertRaisesRegex(ValueError, "link"):
            unpack.extract_artifacts(alternate, "backend-test-plan", workspace=self.workspace,
                                     runner_temp=self.runner_temp)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "POSIX special nodes")
    def test_raw_special_node_is_rejected(self):
        os.mkfifo(self.raw / "artifact")
        self.assert_rejected()


class AuthenticatedWorkflowBoundaryTests(unittest.TestCase):
    def test_all_quality_downloads_keep_official_runtime_scope_and_hard_digest_gate(self):
        source = (unpack.ROOT / ".github/workflows/quality.yml").read_text(encoding="utf-8")
        steps = re.findall(r"^      - (.*?)(?=^      - |\Z)", source, re.M | re.S)
        downloads = [(i, step) for i, step in enumerate(steps) if "actions/download-artifact@" in step]
        self.assertEqual(5, len(downloads))
        for number, step in downloads:
            with self.subTest(download=step):
                self.assertIn("actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333", step)
                self.assertIn("skip-decompress: true", step)
                self.assertIn("digest-mismatch: error", step)
                self.assertIn("path: ${{ runner.temp }}/quality-raw-", step)
                self.assertNotIn("github-token:", step)
                self.assertNotIn("run-id:", step)
                self.assertNotIn("continue-on-error:", step)
                self.assertIn('run: mkdir -m 0700 -- "$RUNNER_TEMP/quality-raw-', steps[number - 1])
                following = steps[number + 1]
                self.assertIn("python3 .github/scripts/safe_artifact_extract.py", following)
                self.assertNotIn("always()", following)
                self.assertNotIn("continue-on-error:", following)
                conditions = lambda text: re.findall(r"^        if: (.*)$", text, re.M)
                self.assertEqual(conditions(step), conditions(following))
                selector = re.search(r"^          (?:name|pattern): (.*)$", step, re.M).group(1)
                self.assertIn("--artifact " + ("'" + selector + "'" if "*" in selector else selector), following)
                if "pattern:" in step:
                    self.assertIn("merge-multiple: false", step)
        self.assertEqual({"backend-test-plan": "target-ci-plan", "backend-test-results-*": "target-ci-reports",
                          "backend-unfiltered-reference": "target-ci-reference"}, unpack.DESTINATIONS)
        self.assertIn("-p 'test_safe_artifact_extract.py' -v", source)


if __name__ == "__main__":
    unittest.main()
