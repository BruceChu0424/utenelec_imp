from __future__ import annotations

import base64
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


UPDATER_ROOT = Path(__file__).resolve().parent
if str(UPDATER_ROOT) not in sys.path:
    sys.path.insert(0, str(UPDATER_ROOT))

import oss_io  # noqa: E402
import release_guard  # noqa: E402


class StrictJsonConsumerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, name: str, payload: bytes) -> Path:
        path = self.root / name
        path.write_bytes(payload)
        return path

    def test_duplicate_keys_are_rejected_at_every_nesting_level(self) -> None:
        path = self.write(
            "state.json",
            b'{"outer":{"value":1,"value":2}}',
        )
        with self.assertRaisesRegex(release_guard.ReleaseGuardError, "duplicate JSON key"):
            release_guard.load_json(path, 1024)

    def test_non_finite_values_are_rejected(self) -> None:
        for constant in (b"NaN", b"Infinity", b"-Infinity"):
            with self.subTest(constant=constant):
                path = self.write("state.json", b'{"value":' + constant + b"}")
                with self.assertRaisesRegex(
                    release_guard.ReleaseGuardError,
                    "non-finite JSON value",
                ):
                    release_guard.load_json(path, 1024)

    def test_invalid_utf8_and_oversized_inputs_are_rejected(self) -> None:
        invalid = self.write("state.json", b'{"value":"\xff"}')
        with self.assertRaisesRegex(release_guard.ReleaseGuardError, "strict UTF-8 JSON"):
            release_guard.load_json(invalid, 1024)

        oversized = self.write("other.json", b'{"value":true}\n')
        with self.assertRaisesRegex(release_guard.ReleaseGuardError, "bounded"):
            release_guard.load_json(oversized, 4)

    def test_release_objects_require_exact_canonical_bytes(self) -> None:
        value = {"channel": "candidate", "schemaVersion": 1}
        canonical = release_guard._canonical_json_bytes(value)
        channel = self.write("channel.json", canonical)
        self.assertEqual(value, release_guard.load_json(channel, 1024))

        channel.write_bytes(json.dumps(value, sort_keys=True).encode("utf-8"))
        with self.assertRaisesRegex(release_guard.ReleaseGuardError, "not canonical"):
            release_guard.load_json(channel, 1024)

        generic = self.write("state.json", json.dumps(value).encode("utf-8"))
        self.assertEqual(value, release_guard.load_json(generic, 1024))

    def test_signature_verification_is_bound_to_the_loaded_canonical_bytes(self) -> None:
        channel = self.write(
            "channel.json",
            release_guard._canonical_json_bytes({"sequence": 1}),
        )
        release_guard.load_json(channel, 1024)
        channel.write_bytes(release_guard._canonical_json_bytes({"sequence": 2}))

        with self.assertRaisesRegex(
            release_guard.ReleaseGuardError,
            "changed after canonical JSON validation",
        ):
            release_guard.verify_ssh_signature(
                channel,
                self.root / "unused.sig",
                self.root / "unused-allowed-signers",
            )

    def test_unknown_channel_field_is_rejected_by_exact_schema(self) -> None:
        version = "v2026.08.14-1"
        channel = {
            "channel": "candidate",
            "commitSha": "a" * 40,
            "manifest": {
                "objectKey": f"releases/{version}/manifest.json",
                "sha256": "b" * 64,
                "signatureObjectKey": f"releases/{version}/manifest.sig",
            },
            "product": "uten-imp",
            "publishedAtUtc": "2026-08-14T00:00:00Z",
            "releaseSequence": 20260814001,
            "schemaVersion": 1,
            "signingKeyId": "SHA256:" + "A" * 43,
            "unexpected": True,
            "version": version,
        }
        with self.assertRaisesRegex(release_guard.ReleaseGuardError, "unexpected"):
            release_guard.validate_channel(channel, expected_channel="candidate")

    def test_symlink_and_hardlink_json_inputs_are_rejected(self) -> None:
        original = self.write("original.json", b'{"value":true}')
        hardlink = self.root / "hardlink.json"
        os.link(original, hardlink)
        with self.assertRaisesRegex(release_guard.ReleaseGuardError, "single-link"):
            release_guard.load_json(hardlink, 1024)

        symlink = self.root / "symlink.json"
        try:
            symlink.symlink_to(original)
        except (NotImplementedError, OSError):
            self.skipTest("symlinks are unavailable in this test environment")
        with self.assertRaises(release_guard.ReleaseGuardError):
            release_guard.load_json(symlink, 1024)


class AllowedSignersPolicyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def encoded_key(seed: int) -> str:
        blob = (
            b"\x00\x00\x00\x0bssh-ed25519"
            b"\x00\x00\x00\x20"
            + bytes([seed]) * 32
        )
        return base64.b64encode(blob).decode("ascii")

    def policy(self, body: str) -> Path:
        path = self.root / "allowed-signers"
        path.write_text(body, encoding="ascii", newline="\n")
        return path

    def test_distinct_keys_for_the_fixed_principal_remain_compatible(self) -> None:
        first = self.encoded_key(1)
        second = self.encoded_key(2)
        path = self.policy(
            f"uten-imp-release ssh-ed25519 {first}\n"
            f"uten-imp-release ssh-ed25519 {second}\n"
        )
        entries = release_guard.allowed_signer_entries(path)
        self.assertEqual(2, len(entries))
        self.assertEqual(
            {
                f"uten-imp-release ssh-ed25519 {first}",
                f"uten-imp-release ssh-ed25519 {second}",
            },
            set(entries.values()),
        )

    def test_trailing_comment_or_extra_field_is_rejected(self) -> None:
        path = self.policy(
            f"uten-imp-release ssh-ed25519 {self.encoded_key(3)} comment\n"
        )
        with self.assertRaisesRegex(release_guard.ReleaseGuardError, "exactly three"):
            release_guard.allowed_signer_entries(path)

    def test_duplicate_fingerprint_is_rejected(self) -> None:
        key = self.encoded_key(4)
        path = self.policy(
            f"uten-imp-release ssh-ed25519 {key}\n"
            f"uten-imp-release ssh-ed25519 {key}\n"
        )
        with self.assertRaisesRegex(release_guard.ReleaseGuardError, "duplicate key fingerprint"):
            release_guard.allowed_signer_entries(path)

    def test_duplicate_or_expanded_principal_is_rejected(self) -> None:
        key = self.encoded_key(5)
        duplicate = self.policy(
            f"uten-imp-release,uten-imp-release ssh-ed25519 {key}\n"
        )
        with self.assertRaisesRegex(release_guard.ReleaseGuardError, "duplicate principal"):
            release_guard.allowed_signer_entries(duplicate)

        expanded = self.policy(f"uten-imp-release,other ssh-ed25519 {key}\n")
        with self.assertRaisesRegex(release_guard.ReleaseGuardError, "fixed release identity"):
            release_guard.allowed_signer_entries(expanded)

    def test_policy_requires_ascii_single_lf_and_canonical_key_blob(self) -> None:
        key = self.encoded_key(6)
        missing_newline = self.policy(f"uten-imp-release ssh-ed25519 {key}")
        with self.assertRaisesRegex(release_guard.ReleaseGuardError, "canonical LF"):
            release_guard.allowed_signer_entries(missing_newline)

        malformed = self.policy(
            "uten-imp-release ssh-ed25519 "
            + base64.b64encode(b"not-an-openssh-key").decode("ascii")
            + "\n"
        )
        with self.assertRaisesRegex(release_guard.ReleaseGuardError, "Ed25519 public key"):
            release_guard.allowed_signer_entries(malformed)


class ObjectMetadata:
    def __init__(
        self,
        length: int,
        *,
        etag: str | None = "fixture-etag",
        version_id: str | None = "fixture-version",
    ) -> None:
        self.content_length = length
        self.etag = etag
        self.last_modified = 1
        self.versionid = version_id


class ObjectStream(ObjectMetadata):
    def __init__(
        self,
        payload: bytes,
        *,
        advertised_length: int | None = None,
        interrupt: bool = False,
    ) -> None:
        super().__init__(
            len(payload) if advertised_length is None else advertised_length
        )
        self._body = io.BytesIO(payload)
        self._interrupt = interrupt
        self.closed = False

    def read(self, size: int = -1) -> bytes:
        if self._interrupt:
            self._interrupt = False
            raise InterruptedError("fixture interruption")
        return self._body.read(size)

    def close(self) -> None:
        self.closed = True
        self._body.close()


class BucketFixture:
    def __init__(self, head: ObjectMetadata, stream: ObjectStream) -> None:
        self.head = head
        self.stream = stream

    def head_object(self, _key: str) -> ObjectMetadata:
        return self.head

    def get_object(self, _key: str) -> ObjectStream:
        return self.stream


@unittest.skipUnless(
    os.name == "posix" and bool(getattr(os, "O_TMPFILE", 0)),
    "fd-bound anonymous download publication requires Linux O_TMPFILE",
)
class AtomicDownloadTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.environment = mock.patch.dict(
            os.environ,
            {"OSS_MAX_DOWNLOAD_BYTES": str(4 * 1024 * 1024)},
        )
        self.environment.start()

    def tearDown(self) -> None:
        self.environment.stop()
        self.temporary.cleanup()

    def test_verified_inode_is_published_once_with_exact_metadata(self) -> None:
        payload = b"signed release bytes"
        stream = ObjectStream(payload)
        bucket = BucketFixture(ObjectMetadata(len(payload)), stream)
        destination = self.root / "manifest.json"

        oss_io.atomic_download(bucket, "releases/manifest.json", destination)

        details = destination.lstat()
        self.assertEqual(payload, destination.read_bytes())
        self.assertTrue(stat.S_ISREG(details.st_mode))
        self.assertEqual(1, details.st_nlink)
        self.assertEqual(0o640, stat.S_IMODE(details.st_mode))
        self.assertTrue(stream.closed)

    def test_head_get_metadata_drift_is_rejected_without_publication(self) -> None:
        stream = ObjectStream(b"four", advertised_length=4)
        bucket = BucketFixture(ObjectMetadata(3), stream)
        destination = self.root / "artifact.tar.gz"

        with self.assertRaisesRegex(oss_io.OssIoError, "content lengths differ"):
            oss_io.atomic_download(bucket, "releases/artifact.tar.gz", destination)

        self.assertFalse(os.path.lexists(destination))
        self.assertTrue(stream.closed)

    def test_short_body_and_interrupted_download_leave_no_path(self) -> None:
        short = ObjectStream(b"xy", advertised_length=3)
        destination = self.root / "short.bin"
        with self.assertRaisesRegex(oss_io.OssIoError, "ended before"):
            oss_io.atomic_download(
                BucketFixture(ObjectMetadata(3), short),
                "releases/short.bin",
                destination,
            )
        self.assertFalse(os.path.lexists(destination))

        interrupted = ObjectStream(b"xyz", interrupt=True)
        interrupted_destination = self.root / "interrupted.bin"
        with self.assertRaises(InterruptedError):
            oss_io.atomic_download(
                BucketFixture(ObjectMetadata(3), interrupted),
                "releases/interrupted.bin",
                interrupted_destination,
            )
        self.assertFalse(os.path.lexists(interrupted_destination))
        self.assertTrue(interrupted.closed)

    def test_existing_symlink_is_rejected_without_touching_its_target(self) -> None:
        target = self.root / "target"
        target.write_bytes(b"keep")
        destination = self.root / "candidate"
        destination.symlink_to(target)
        bucket = BucketFixture(ObjectMetadata(3), ObjectStream(b"new"))

        with self.assertRaisesRegex(oss_io.OssIoError, "already exists"):
            oss_io.atomic_download(bucket, "releases/candidate", destination)

        self.assertTrue(destination.is_symlink())
        self.assertEqual(b"keep", target.read_bytes())

    def test_symlink_swap_at_publication_fails_closed(self) -> None:
        target = self.root / "target"
        target.write_bytes(b"keep")
        destination = self.root / "candidate"
        payload = b"new"
        bucket = BucketFixture(ObjectMetadata(len(payload)), ObjectStream(payload))
        real_link = os.link

        def racing_link(source, destination_name, **kwargs):
            destination.symlink_to(target)
            return real_link(source, destination_name, **kwargs)

        with mock.patch.object(oss_io.os, "link", side_effect=racing_link):
            with self.assertRaisesRegex(oss_io.OssIoError, "appeared during publication"):
                oss_io.atomic_download(bucket, "releases/candidate", destination)

        self.assertTrue(destination.is_symlink())
        self.assertEqual(b"keep", target.read_bytes())


if __name__ == "__main__":
    unittest.main()
