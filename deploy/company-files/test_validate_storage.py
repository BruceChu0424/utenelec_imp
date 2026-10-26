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

    def sandbox_mounts(self, flags="rw,nosuid,nodev,noexec", *, root="/attachments",
                       device="252:1", source="/dev/mapper/ubuntu--vg-uten--media", super_flags="rw"):
        # Actual strict-systemd namespace captured read-only on 2026-10-26 02:03:52Z:
        # the parent is deliberately ro while the exact attachment subtree is rw.
        return gate.parse_mounts(
            "402 91 252:0 / / ro,relatime - ext4 /dev/mapper/ubuntu--vg-ubuntu--lv rw\n"
            "461 402 252:1 / /var/lib/uten-imp-media ro,nosuid,nodev,noexec,relatime - ext4 /dev/mapper/ubuntu--vg-uten--media rw\n"
            f"411 461 {device} {root} /var/lib/uten-imp-media/attachments {flags} - ext4 {source} {super_flags}\n")

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

    def test_actual_strict_namespace_accepts_only_exact_writable_attachment_binding(self):
        self.assertEqual("252:1", self.check(self.sandbox_mounts())["device"])

    def test_per_mount_readonly_is_not_replaced_by_superblock_writable(self):
        mount = self.sandbox_mounts()[1]
        self.assertIn("ro", mount["options"])
        self.assertNotIn("rw", mount["options"])
        self.assertEqual({"rw"}, mount["super_options"])

    def test_strict_namespace_without_attachment_binding_stays_rejected(self):
        with self.assertRaisesRegex(ValueError, "protections"):
            self.check(self.sandbox_mounts()[:2])

    def test_attachment_binding_identity_drift_stays_rejected(self):
        for changes in ({"root": "/other"}, {"device": "252:2"}, {"source": "/dev/mapper/other"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.check(self.sandbox_mounts(**changes))

    def test_readonly_or_unprotected_attachment_binding_stays_rejected(self):
        for flags in ("ro,nosuid,nodev,noexec", "rw,nodev,noexec", "rw,nosuid,noexec",
                      "rw,nosuid,nodev", "ro,rw,nosuid,nodev,noexec"):
            with self.subTest(flags=flags), self.assertRaises(ValueError):
                self.check(self.sandbox_mounts(flags=flags))

    def test_readonly_superblock_stays_rejected_even_with_writable_binding(self):
        with self.assertRaises(ValueError):
            self.check(self.sandbox_mounts(super_flags="ro"))

    def test_superblock_protections_do_not_substitute_for_per_mount_protections(self):
        with self.assertRaises(ValueError):
            self.check(self.sandbox_mounts(flags="rw", super_flags="rw,nosuid,nodev,noexec"))

    def test_duplicate_attachment_bindings_are_rejected(self):
        mounts = self.sandbox_mounts()
        mounts.append(dict(mounts[-1]))
        with self.assertRaises(ValueError):
            self.check(mounts)

    def test_unreviewed_child_mount_cannot_replace_storage_namespace(self):
        for parent in (self.mounts(), self.sandbox_mounts()):
            mounts = parent + gate.parse_mounts(
                f"500 411 {parent[1]['device']} /other /var/lib/uten-imp-media/attachments/staging rw,nosuid,nodev,noexec - ext4 /dev/mapper/ubuntu--vg-uten--media rw\n")
            with self.subTest(parent=parent), self.assertRaises(ValueError):
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
