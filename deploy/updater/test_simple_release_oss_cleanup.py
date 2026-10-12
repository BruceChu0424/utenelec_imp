"""Versioned OSS cleanup regression: actual oss2 2.19.1 response field names."""

import importlib.util
import contextlib
import io
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "uten_oss_release_cleanup", ROOT / "deploy/release/oss_release_cleanup.py"
)
cleanup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cleanup)


def entry(key, versionid, latest=False):
    return SimpleNamespace(key=key, versionid=versionid, is_latest=latest)


def page(versions=(), markers=(), next_cursor=None):
    # These are the real ListObjectVersionsResult properties from oss2 2.19.1.
    return SimpleNamespace(
        versions=list(versions), delete_marker=list(markers),
        is_truncated=next_cursor is not None,
        next_key_marker=next_cursor[0] if next_cursor else "",
        next_versionid_marker=next_cursor[1] if next_cursor else "",
    )


class BucketFixture:
    def __init__(self, pages=None, pointers=(b"v2.5.12\n", b"v2.5.12\n")):
        self.pages = pages or {("releases/", "", ""): page(), ("LATEST.txt", "", ""): page()}
        self.pointers = iter(pointers)
        self.listed = []
        self.deleted = []

    def list_object_versions(self, *, prefix, key_marker, versionid_marker, max_keys):
        self.listed.append((prefix, key_marker, versionid_marker, max_keys))
        return self.pages[(prefix, key_marker, versionid_marker)]

    def get_object(self, key):
        if key != "LATEST.txt":
            raise AssertionError(key)
        return io.BytesIO(next(self.pointers))

    def delete_object(self, key, *, params):
        self.deleted.append((key, params))


class SimpleReleaseOssCleanupTest(unittest.TestCase):
    def test_real_sdk_properties_remove_all_old_versions_and_delete_markers(self):
        bucket = BucketFixture({
            ("releases/", "", ""): page(
                [entry("releases/v2.5.11/server/app.jar", "old-a", True),
                 entry("releases/v2.5.12/server/app.jar", "current", True),
                 entry("releases/v2.5.12/server/app.jar", "current-history")],
                [entry("releases/v2.5.11/web/old.js", "old-marker", True),
                 entry("releases/v2.5.12/web/old.js", "current-marker", True)],
                ("releases/v2.5.11/server/app.jar", "old-a")),
            ("releases/", "releases/v2.5.11/server/app.jar", "old-a"): page(
                [entry("releases/v2.5.11/server/app.jar", "old-b")]),
            ("LATEST.txt", "", ""): page(
                [entry("LATEST.txt", "pointer-current", True), entry("LATEST.txt", "pointer-old")],
                [entry("LATEST.txt", "pointer-marker")]),
        })
        self.assertEqual((3, 2), cleanup.purge_old_versions(bucket, "v2.5.12"))
        self.assertEqual([
            ("releases/v2.5.11/server/app.jar", {"versionId": "old-a"}),
            ("releases/v2.5.11/web/old.js", {"versionId": "old-marker"}),
            ("releases/v2.5.11/server/app.jar", {"versionId": "old-b"}),
            ("LATEST.txt", {"versionId": "pointer-old"}),
            ("LATEST.txt", {"versionId": "pointer-marker"}),
        ], bucket.deleted)

    def test_latest_history_uses_both_markers_and_exact_object_key(self):
        bucket = BucketFixture({
            ("releases/", "", ""): page(),
            ("LATEST.txt", "", ""): page(
                [entry("LATEST.txt", "current", True), entry("LATEST.txt", "old-a")],
                next_cursor=("LATEST.txt", "old-a")),
            ("LATEST.txt", "LATEST.txt", "old-a"): page(
                [entry("LATEST.txt", "old-b")], next_cursor=("LATEST.txt", "old-b")),
            ("LATEST.txt", "LATEST.txt", "old-b"): page(
                [entry("LATEST.txt.backup", "unrelated"), entry("LATEST.txt", "old-c")]),
        })
        self.assertEqual((0, 3), cleanup.purge_old_versions(bucket, "v2.5.12"))
        self.assertEqual([("LATEST.txt", {"versionId": value}) for value in ("old-a", "old-b", "old-c")],
                         bucket.deleted)

    def test_bad_pagination_in_either_inventory_causes_zero_deletes(self):
        for prefix in ("releases/", "LATEST.txt"):
            for marker in (("", "missing-key"), ("repeated-key", "repeated-id")):
                with self.subTest(prefix=prefix, marker=marker):
                    pages = {
                        ("releases/", "", ""): page([entry("releases/v2.5.11/x", "old")]),
                        ("LATEST.txt", "", ""): page(),
                    }
                    pages[(prefix, "", "")] = page(next_cursor=marker)
                    pages[(prefix, *marker)] = page(next_cursor=marker)
                    bucket = BucketFixture(pages)
                    with self.assertRaises(cleanup.CleanupError):
                        cleanup.purge_old_versions(bucket, "v2.5.12")
                    self.assertEqual([], bucket.deleted)

    def test_newer_pointer_before_or_after_inventory_prevents_deletion(self):
        for pointers in ((b"v2.5.13",), (b"v2.5.12", b"v2.5.13")):
            with self.subTest(pointers=pointers):
                bucket = BucketFixture(pointers=pointers)
                with self.assertRaises(cleanup.CleanupError):
                    cleanup.purge_old_versions(bucket, "v2.5.12")
                self.assertEqual([], bucket.deleted)

    def test_invalid_version_and_missing_version_id_fail_before_deletion(self):
        bucket = BucketFixture()
        with self.assertRaises(cleanup.CleanupError):
            cleanup.purge_old_versions(bucket, "v2.05.12")
        self.assertEqual([], bucket.listed)
        for key, versionid in (("unrelated-object", "old"), ("releases/v2.5.11/x", "")):
            bucket = BucketFixture({("releases/", "", ""): page([entry(key, versionid)])})
            with self.assertRaises(cleanup.CleanupError):
                cleanup.purge_old_versions(bucket, "v2.5.12")
            self.assertEqual([], bucket.deleted)

    def test_cli_reports_sdk_failure_without_secret_request_metadata(self):
        class AccessDenied(Exception):
            pass

        bucket = BucketFixture()
        bucket.list_object_versions = mock.Mock(side_effect=AccessDenied("fixture-private-request-header"))
        sdk = SimpleNamespace(Auth=mock.Mock(), Bucket=mock.Mock(return_value=bucket),
                              exceptions=SimpleNamespace(OssError=AccessDenied, AccessDenied=AccessDenied))
        environment = dict(OSS_ACCESS_KEY_ID="fixture-id", OSS_ACCESS_KEY_SECRET="fixture-secret",
                           OSS_ENDPOINT="oss-cn-example.aliyuncs.com", OSS_BUCKET="fixture-bucket")
        error = io.StringIO()
        with mock.patch.dict(sys.modules, oss2=sdk), mock.patch.dict(os.environ, environment), contextlib.redirect_stderr(error):
            self.assertEqual(1, cleanup.main(["v2.5.12"]))
        self.assertIn("AccessDenied", error.getvalue())
        self.assertIn("oss:ListObjectVersions", error.getvalue())
        self.assertIn("oss:DeleteObjectVersion", error.getvalue())
        self.assertIn("releases/* and LATEST.txt", error.getvalue())
        self.assertNotIn("fixture-private-request-header", error.getvalue())
        self.assertNotIn("fixture-secret", error.getvalue())
        self.assertEqual([], bucket.deleted)

    def test_workflow_runs_the_exercised_helper_and_does_not_hide_cleanup_failure(self):
        workflow = (ROOT / ".github/workflows/simple-release.yml").read_text(encoding="utf-8")
        step = workflow.split("      - name: Purge old releases from OSS", 1)[1].split("      - name: Summary", 1)[0]
        self.assertIn('python3 deploy/release/oss_release_cleanup.py "$VERSION"', step)
        self.assertNotIn("continue-on-error: true", step)
        self.assertNotIn("object_version_list", step)


if __name__ == "__main__":
    unittest.main()
