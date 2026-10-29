"""Source policy/managed-PE checks; these do not certify any Windows machine."""

from pathlib import Path
import json
import struct
import tempfile
import unittest

from wpf_install_policy import (
    MIN_NET_RELEASE,
    decide_installation,
    inspect_managed_executable,
    render_pascal_policy,
    validate_app_configuration,
)


def managed_pe(architecture: str, flags: int | None = None) -> bytes:
    """Minimal structural fixture, deliberately not a runnable application."""
    data = bytearray(0x500)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    machine, magic, optional_size, directory_offset = {
        "x86": (0x14C, 0x10B, 224, 96),
        "x64": (0x8664, 0x20B, 240, 112),
    }[architecture]
    struct.pack_into("<HH", data, 0x84, machine, 1)
    struct.pack_into("<H", data, 0x94, optional_size)
    struct.pack_into("<H", data, 0x96, 2)
    optional = 0x98
    struct.pack_into("<H", data, optional, magic)
    struct.pack_into("<I", data, optional + directory_offset - 4, 16)
    struct.pack_into("<II", data, optional + directory_offset + 14 * 8, 0x2000, 72)
    section = optional + optional_size
    data[section:section + 8] = b".text\0\0\0"
    struct.pack_into("<IIII", data, section + 8, 0x100, 0x2000, 0x200, 0x300)
    struct.pack_into("<IHH", data, 0x300, 72, 2, 5)
    actual_flags = flags if flags is not None else (3 if architecture == "x86" else 1)
    struct.pack_into("<I", data, 0x310, actual_flags)
    return bytes(data)


class InstallationPolicyTests(unittest.TestCase):
    def test_only_reviewed_os_architectures_pass(self):
        accepted = {(6, 1, 1), (6, 1, 2), (6, 3, 0)}
        candidates = [(6, 0, 2), (6, 1, 0), (6, 1, 1), (6, 1, 2),
                      (6, 2, 0), (6, 3, 0), (10, 0, 0), (11, 0, 0), (7, 0, 0)]
        for version in candidates:
            for processor, expected in ((0, "x86"), (9, "x64"), (12, None), (65535, None)):
                with self.subTest(version=version, processor=processor):
                    result = decide_installation(*version, processor, 528049)
                    self.assertEqual(result.architecture, expected if version in accepted else None)
                    self.assertEqual(result.error is None, result.architecture is not None)

    def test_framework_boundary_and_os_specific_release_values(self):
        for release in (None, 0, 461814, MIN_NET_RELEASE - 1):
            with self.subTest(release=release):
                result = decide_installation(6, 1, 1, 9, release)
                self.assertIsNone(result.architecture)
                self.assertIn(".NET Framework 4.8", result.error)
        for release in (528040, 528049, 528372, 533320):
            with self.subTest(release=release):
                self.assertEqual(decide_installation(6, 3, 0, 9, release).architecture, "x64")

    def test_does_not_reclassify_server_versions_as_workstations(self):
        for product_type in (0, 2, 3):
            self.assertIsNone(decide_installation(6, 1, 1, 9, 528049, product_type).architecture)

    def test_missing_sp1_and_modern_windows_explain_the_actual_requirement(self):
        self.assertIn("Service Pack 1", decide_installation(6, 1, 0, 0, 0).error)
        self.assertIn("现有 Windows 10/11", decide_installation(10, 0, 0, 9, 0).error)

    def test_checked_in_pascal_uses_the_shared_policy(self):
        include = Path(__file__).with_name("wpf_install_policy.iss")
        self.assertEqual(include.read_text(encoding="utf-8"), render_pascal_policy())


class ManagedExecutableTests(unittest.TestCase):
    def inspect(self, data: bytes, architecture: str):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Uten.Legacy.Desktop.exe"
            path.write_bytes(data)
            return inspect_managed_executable(path, architecture)

    def test_accepts_explicit_x86_and_x64_managed_payloads(self):
        for architecture in ("x86", "x64"):
            self.assertEqual(self.inspect(managed_pe(architecture), architecture)["architecture"], architecture)

    def test_rejects_anycpu_mislabeled_as_x86(self):
        for flags in (1, 0x20001):
            with self.subTest(flags=flags), self.assertRaisesRegex(ValueError, "32BITREQUIRED"):
                self.inspect(managed_pe("x86", flags), "x86")

    def test_rejects_wrong_machine_and_corrupt_or_native_payloads(self):
        with self.assertRaisesRegex(ValueError, "target architecture"):
            self.inspect(managed_pe("x86"), "x64")
        for payload in (b"", b"MZ", managed_pe("x64")[:0x320]):
            with self.subTest(length=len(payload)), self.assertRaises(ValueError):
                self.inspect(payload, "x64")
        native = bytearray(managed_pe("x64"))
        struct.pack_into("<II", native, 0x98 + 112 + 14 * 8, 0, 0)
        with self.assertRaisesRegex(ValueError, "managed"):
            self.inspect(native, "x64")
        renamed_dll = bytearray(managed_pe("x64"))
        struct.pack_into("<H", renamed_dll, 0x96, 0x2002)
        with self.assertRaisesRegex(ValueError, "DLL"):
            self.inspect(renamed_dll, "x64")

    def test_rejects_clr_header_outside_the_image(self):
        payload = bytearray(managed_pe("x64"))
        struct.pack_into("<I", payload, 0x98 + 112 + 14 * 8, 0x9000)
        with self.assertRaisesRegex(ValueError, "PE section"):
            self.inspect(payload, "x64")


class ConfigurationTests(unittest.TestCase):
    def check_url(self, url: str):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "uten.client.json"
            path.write_text(json.dumps({
                "endpoints": [{"id": "company", "name": "公司内网", "apiBaseUrl": url}],
                "selectedEndpointId": "company",
            }), encoding="utf-8")
            return validate_app_configuration(path)

    def test_accepts_company_https_shape_without_calling_network(self):
        self.check_url("https://imp.utenelec/api")

    def test_rejects_localhost_insecure_and_credentialed_endpoints(self):
        urls = ("http://imp.utenelec/api", "https://localhost/api", "https://LOCALHOST./api",
                "https://127.0.0.1/api", "https://[::1]/api", "https://0.0.0.0/api",
                "https://[::ffff:127.0.0.1]/api",
                "https://2130706433/api", "https://127.1/api", "https://user:pass@example.com/api",
                "https://imp.utenelec/api?target=other", "https://imp.utenelec:bad/api")
        for url in urls:
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.check_url(url)


if __name__ == "__main__":
    unittest.main()
