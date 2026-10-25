import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("storage_gate", Path(__file__).with_name("validate_storage.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class StorageMountGateTest(unittest.TestCase):
    def mounts(self, media="/dev/mapper/ubuntu--vg-uten--media", device="253:1", flags="rw,nosuid,nodev,noexec"):
        return gate.parse_mounts("30 1 253:0 / / rw - ext4 /dev/root rw\n"
                                 f"40 30 {device} / /var/lib/uten-imp-media {flags} - ext4 {media} rw\n")

    def check(self, mounts):
        return gate.check_mounts(mounts, "/var/lib/uten-imp-media", "/dev/mapper/ubuntu--vg-uten--media")

    def test_real_dedicated_media_is_accepted(self):
        self.assertEqual("253:1", self.check(self.mounts())["device"])

    def test_missing_mount_does_not_fall_back_to_root(self):
        with self.assertRaisesRegex(ValueError, "missing"):
            self.check(self.mounts()[:1])

    def test_same_system_filesystem_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "independent"):
            self.check(self.mounts(device="253:0"))

    def test_changed_volume_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "reviewed source"):
            self.check(self.mounts(media="/dev/mapper/other"))

    def test_missing_protection_or_readonly_is_rejected(self):
        for flags in ("rw,nodev,nosuid", "ro,noexec,nodev,nosuid"):
            with self.subTest(flags=flags), self.assertRaisesRegex(ValueError, "protections"):
                self.check(self.mounts(flags=flags))

    def test_bind_subdirectory_is_rejected(self):
        mounts = self.mounts()
        mounts[1]["root"] = "/another-directory"
        with self.assertRaisesRegex(ValueError, "reviewed source"):
            self.check(mounts)

    def test_mount_escape_decode(self):
        self.assertEqual("/some path", gate.unescape_mount(r"/some\040path"))

    def test_malformed_mounts_fail_closed(self):
        with self.assertRaises(ValueError):
            gate.parse_mounts("not mount information")

    def test_uuid_evidence_is_exact_and_missing_or_ambiguous_fails_closed(self):
        self.assertEqual("volume-id", gate.uuid_from_udev("E:OTHER=value\nE:ID_FS_UUID=volume-id\n"))
        for contents in ("E:OTHER=value", "E:ID_FS_UUID=a\nE:ID_FS_UUID=b"):
            with self.subTest(contents=contents), self.assertRaises(ValueError):
                gate.uuid_from_udev(contents)


if __name__ == "__main__":
    unittest.main()
