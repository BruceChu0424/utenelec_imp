import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile


spec = importlib.util.spec_from_file_location("android_ndk_prepare", Path(__file__).with_name("prepare_android_ndk.py"))
ndk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ndk)


class FixedAndroidNdkTest(unittest.TestCase):
    def archive(self, directory, name):
        path = Path(directory) / "ndk.zip"
        with zipfile.ZipFile(path, "w") as stream:
            stream.writestr(name, "Pkg.Revision = " + ndk.VERSION + "\n")
        return path

    def test_expected_archive_passes_hash_and_crc(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.archive(directory, ndk.ARCHIVE_ROOT + "/source.properties")
            result = ndk.verify_archive(path, path.stat().st_size, ndk.file_digest(path, "sha1"))
            self.assertTrue(result["zipCrcVerified"])
            self.assertEqual(result["entries"], 1)

    def test_truncated_or_wrong_download_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.archive(directory, ndk.ARCHIVE_ROOT + "/source.properties")
            with self.assertRaisesRegex(ValueError, "size/checksum"):
                ndk.verify_archive(path, path.stat().st_size + 1, ndk.file_digest(path, "sha1"))
            with self.assertRaisesRegex(ValueError, "size/checksum"):
                ndk.verify_archive(path, path.stat().st_size, "0" * 40)

    def test_matching_response_bytes_still_need_to_be_a_valid_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ndk.zip"
            body = b"upstream error response"
            path.write_bytes(body)
            with self.assertRaises(zipfile.BadZipFile):
                ndk.verify_archive(path, len(body), hashlib.sha1(body).hexdigest())

    def test_archive_cannot_write_outside_the_fixed_vendor_root(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.archive(directory, "../outside")
            with self.assertRaisesRegex(ValueError, "member"):
                ndk.verify_archive(path, path.stat().st_size, ndk.file_digest(path, "sha1"))

    def test_existing_partial_or_other_version_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "source.properties").write_text("Pkg.Revision = 27.0.0\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "version"):
                ndk.verify_installation(path)
            (path / "source.properties").write_text("Pkg.Revision = " + ndk.VERSION + "\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing"):
                ndk.verify_installation(path)


if __name__ == "__main__":
    unittest.main()
