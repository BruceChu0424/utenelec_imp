import base64
import hashlib
import io
import json
from pathlib import Path
import struct
import unittest
from unittest import mock

import package_windows as policy
from test_package_windows import fixture_executable


def with_certificate_table(data: bytes) -> bytes:
    """Structural PE signature mutation; does not claim a trusted signature."""
    image = bytearray(data)
    optional = struct.unpack_from("<I", image, 60)[0] + 24
    directory = 96 if struct.unpack_from("<H", image, optional)[0] == 0x10B else 112
    image.extend(b"\0" * (-len(image) % 8))
    certificate = len(image)
    blob = struct.pack("<IHH", 24, 0x200, 2) + b"certificate-data"
    image.extend(blob)
    struct.pack_into("<II", image, optional + directory + 32, certificate, len(blob))
    struct.pack_into("<I", image, optional + 64, 0xA55A1234)
    return bytes(image)


class EngineSafetyTest(unittest.TestCase):
    def test_cross_language_mapped_image_vectors(self):
        vectors = json.loads((policy.ENGINE_SAFETY_CONTRACT.parent / "vectors-v1.json").read_text())["vectors"]
        for vector in vectors:
            with self.subTest(name=vector["name"]):
                image = base64.b64decode(vector["peBase64"])
                if vector["rejected"]:
                    with self.assertRaises(ValueError):
                        policy.pe_image_sha256(io.BytesIO(image), len(image))
                else:
                    self.assertEqual(vector["peImageSha256"], policy.pe_image_sha256(io.BytesIO(image), len(image)))

    def test_signing_cannot_reidentify_a_known_failed_engine(self):
        original = fixture_executable()
        changed = with_certificate_table(original)
        self.assertNotEqual(hashlib.sha256(original).digest(), hashlib.sha256(changed).digest())
        identity = policy.pe_image_sha256(io.BytesIO(original), len(original))
        denied = {"peImageSha256": identity, "classification": "confirmed-crashing", "reason": "native regression"}
        with mock.patch.dict(policy._ENGINE_POLICY, {"engines": [denied]}):
            with self.assertRaisesRegex(ValueError, "Known crashing.*signature-independent"):
                policy.reject_known_unsafe_engine("FLUTTER_WINDOWS.DLL", hashlib.sha256(changed).hexdigest(),
                                                   stream=io.BytesIO(changed), size=len(changed), require_approved=True)

    def test_formal_unknown_engine_fails_even_when_not_on_deny_list(self):
        image = fixture_executable()
        with mock.patch.dict(policy.APPROVED_ENGINE_IMAGES, {}, clear=True):
            with self.assertRaisesRegex(ValueError, "Unreviewed"):
                policy.reject_known_unsafe_engine("flutter_windows.dll", hashlib.sha256(image).hexdigest(),
                                                   stream=io.BytesIO(image), size=len(image), require_approved=True)

    def test_reviewed_engine_stays_admitted_after_signing_but_content_edit_does_not(self):
        original = fixture_executable()
        signed = with_certificate_table(original)
        identity = policy.pe_image_sha256(io.BytesIO(original), len(original))
        with mock.patch.dict(policy.APPROVED_ENGINE_IMAGES, {identity: {"testFixture": True}}, clear=True):
            policy.reject_known_unsafe_engine("flutter_windows.dll", hashlib.sha256(signed).hexdigest(),
                                               stream=io.BytesIO(signed), size=len(signed), require_approved=True)
            changed = bytearray(signed)
            changed[600] ^= 1
            with self.assertRaisesRegex(ValueError, "Unreviewed"):
                policy.reject_known_unsafe_engine("flutter_windows.dll", hashlib.sha256(changed).hexdigest(),
                                                   stream=io.BytesIO(changed), size=len(changed), require_approved=True)


if __name__ == "__main__":
    unittest.main()
