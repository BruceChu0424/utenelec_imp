import base64
import io
import json
from pathlib import Path
import tempfile
import unittest

import windows_payload_binding as binding


class WindowsPayloadBindingTest(unittest.TestCase):
    def test_shared_cross_language_envelopes(self):
        path = Path(__file__).resolve().parents[2] / "contracts/windows-payload-binding/vectors.json"
        vectors = json.loads(path.read_text(encoding="utf-8"))["vectors"]
        for vector in vectors:
            with self.subTest(vector=vector["name"]):
                image = base64.b64decode(vector["mainBase64"])
                if vector["accept"]:
                    result = binding.verify(io.BytesIO(image), len(image), metadata=vector["metadata"], records=vector["records"])
                    self.assertTrue(result["verified"])
                else:
                    with self.assertRaises(ValueError):
                        binding.verify(io.BytesIO(image), len(image), metadata=vector["metadata"], records=vector["records"])

    def test_staging_reseal_is_deterministic_and_preserves_mapped_executable(self):
        from test_package_windows import fixture_executable
        image = fixture_executable(2544, version=(2, 5, 44))
        metadata = {"runtimeFamily": "flutter", "version": "2.5.44", "buildNumber": 2544,
                    "architecture": "x64", "executable": "uten_imp.exe"}
        value = binding.inventory(metadata, [{"path": "data/app.so", "size": 0, "sha256": "a" * 64}])
        with tempfile.TemporaryDirectory(prefix="uten-binding-stage-") as directory:
            path = Path(directory) / "uten_imp.exe"
            path.write_bytes(image)
            binding.write(path, value)
            first = path.read_bytes()
            self.assertEqual(first[:len(image)], image)
            binding.write(path, value)
            self.assertEqual(path.read_bytes(), first)
            with path.open("rb") as stream:
                self.assertEqual(binding.read(stream, path.stat().st_size, require_signed=False), value)
            with path.open("rb") as stream, self.assertRaises(ValueError):
                binding.read(stream, path.stat().st_size)

    def test_unknown_overlay_cannot_be_silently_signed_as_a_payload_inventory(self):
        from test_package_windows import fixture_executable
        metadata = {"runtimeFamily": "flutter", "version": "2.5.44", "buildNumber": 2544,
                    "architecture": "x64", "executable": "uten_imp.exe"}
        value = binding.inventory(metadata, [{"path": "data/app.so", "size": 0, "sha256": "a" * 64}])
        with tempfile.TemporaryDirectory(prefix="uten-binding-unknown-") as directory:
            path = Path(directory) / "uten_imp.exe"
            original = fixture_executable() + b"unreviewed overlay"
            path.write_bytes(original)
            with self.assertRaises(ValueError):
                binding.write(path, value)
            self.assertEqual(path.read_bytes(), original)

    def test_oversized_certificate_table_is_rejected_before_traversal(self):
        import struct
        vector = json.loads((Path(__file__).resolve().parents[2] /
            "contracts/windows-payload-binding/vectors.json").read_text(encoding="utf-8"))["vectors"][0]
        image = bytearray(base64.b64decode(vector["mainBase64"]))
        certificate, _ = struct.unpack_from("<II", image, 296)
        oversized = binding.MAX_CERTIFICATE_BYTES + 8
        struct.pack_into("<II", image, 296, certificate, oversized)
        with tempfile.TemporaryFile() as stream:
            stream.write(image)
            stream.truncate(certificate + oversized)
            with self.assertRaisesRegex(ValueError, "terminal aligned PE certificate table"):
                binding.read(stream, certificate + oversized)


if __name__ == "__main__":
    unittest.main()
