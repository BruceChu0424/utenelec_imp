import base64
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from zip_directory import require_bounded_directory


class ZipDirectoryTest(unittest.TestCase):
    def test_shared_cross_language_vectors_before_zip_library_allocation(self):
        contract = Path(__file__).resolve().parents[2] / "contracts/windows-zip-directory/vectors-v1.json"
        vectors = json.loads(contract.read_text(encoding="utf-8"))["vectors"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.zip"
            for vector in vectors:
                with self.subTest(name=vector["name"]):
                    path.write_bytes(base64.b64decode(vector["zipBase64"]))
                    limits = {"max_entries": vector["maxEntries"], "max_central_bytes": vector["maxCentralBytes"]}
                    if vector["valid"]:
                        result = require_bounded_directory(path, **limits)
                        self.assertEqual({key: vector[key] for key in ("entries", "centralBytes", "centralOffset")}, result)
                        with zipfile.ZipFile(path) as archive:
                            self.assertEqual(vector["entries"], len(archive.infolist()))
                            self.assertIsNone(archive.testzip())
                    else:
                        with self.assertRaises(ValueError):
                            require_bounded_directory(path, **limits)

    def test_actual_python_producer_remains_within_declared_limits(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.zip"
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for index in range(2001):
                    archive.writestr(f"assets/entry-{index}.bin", b"fixed synthetic data")
            result = require_bounded_directory(path, max_entries=2001, max_central_bytes=1024 * 1024)
            self.assertEqual(2001, result["entries"])
            with self.assertRaises(ValueError):
                require_bounded_directory(path, max_entries=2000, max_central_bytes=1024 * 1024)

    def test_invalid_limits_are_rejected_before_opening_a_file(self):
        for entries, central in ((0, 32), (65535, 32), (1, 0), (True, 32)):
            with self.subTest(entries=entries, central=central), self.assertRaises(ValueError):
                require_bounded_directory(Path("does-not-exist.zip"), max_entries=entries, max_central_bytes=central)


if __name__ == "__main__":
    unittest.main()
