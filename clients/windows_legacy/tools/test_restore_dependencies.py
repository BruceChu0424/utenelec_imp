import base64
import hashlib
import io
import unittest
import zipfile

import restore_dependencies as dependencies


class PinnedDependencyTest(unittest.TestCase):
    def fixture(self, extra=None, files=None):
        contents = {"lib/net461/BouncyCastle.Cryptography.dll": b"fixture managed assembly", "LICENSE.md": b"fixture MIT notice"}
        contents.update(extra or {})
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            for name, content in contents.items():
                info = zipfile.ZipInfo()
                # ZipInfo(name) normalizes Windows separators on the test host;
                # hostile archives can contain the raw name, so preserve it.
                info.filename = name
                archive.writestr(info, content)
        raw = output.getvalue()
        selected = files or ["lib/net461/BouncyCastle.Cryptography.dll", "LICENSE.md"]
        lock = {"packageSha512Base64": base64.b64encode(hashlib.sha512(raw).digest()).decode(),
                "files": {name: hashlib.sha256(contents[name]).hexdigest() for name in selected}}
        return raw, lock

    def test_extracts_only_exact_framework_and_preserves_license(self):
        raw, lock = self.fixture({"lib/net6.0/BouncyCastle.Cryptography.dll": b"wrong target"})
        self.assertEqual(set(lock["files"]), set(dependencies.checked_contents(raw, lock)))

    def test_rejects_package_tampering_before_reading_zip(self):
        raw, lock = self.fixture()
        with self.assertRaisesRegex(ValueError, "SHA-512"):
            dependencies.checked_contents(raw + b"tampered", lock)

    def test_rejects_file_tampering_despite_accepted_package_hash(self):
        raw, lock = self.fixture()
        lock["files"]["LICENSE.md"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            dependencies.checked_contents(raw, lock)

    def test_rejects_archive_escape_and_windows_alias_paths(self):
        for name in ("../escape.dll", "/root.dll", "C:/escape.dll", "lib\\escape.dll"):
            with self.subTest(name=name):
                raw, lock = self.fixture({name: b"unexpected"})
                with self.assertRaisesRegex(ValueError, "Unsafe"):
                    dependencies.checked_contents(raw, lock)

    def test_rejects_wrong_framework_in_selected_files(self):
        raw, lock = self.fixture({"lib/net6.0/other.dll": b"wrong"}, ["lib/net6.0/other.dll"])
        with self.assertRaisesRegex(ValueError, "approved net461"):
            dependencies.checked_contents(raw, lock)


if __name__ == "__main__":
    unittest.main()
