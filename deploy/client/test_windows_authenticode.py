"""The Windows trust boundary is tested separately from synthetic PE layouts.

Real-system tests read/copy existing files only; no certificates, trust stores,
security policies, installed applications or real signing keys are changed.
"""
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest import mock
import zipfile

import windows_authenticode as signatures


class AuthenticodePolicyTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uten-signature-policy-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.file = self.root / "uten_imp.exe"
        self.file.write_bytes(b"non-executable synthetic policy fixture")
        self.environment = mock.patch.dict(os.environ, {signatures.PIN_ENV: "a" * 64, signatures.REQUIRE_ENV: "true"})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def record(self, **changes):
        return {"path": str(self.file.resolve()), "status": "Valid", "signatureType": "Authenticode",
                "codeSigning": True, "signerSha256": "a" * 64, "timestamped": True, **changes}

    def verify(self, record=None, **options):
        with mock.patch.object(signatures, "_metadata", return_value=[record or self.record()]), \
             mock.patch.object(signatures, "_signtool") as native:
            result = signatures.verify_files([("uten_imp.exe", self.file)], **options)
        return result, native

    def test_company_identity_is_pinned_and_all_signatures_use_authenticode_policy(self):
        result, native = self.verify()
        self.assertTrue(result["verified"])
        self.assertTrue(result["files"][0]["companyPublisher"])
        self.assertEqual(native.call_args.args[0][:6], ["verify", "/pa", "/all", "/tw", "/q", str(self.file.resolve())])

    def test_missing_public_company_pins_block_the_actual_gate(self):
        with mock.patch.dict(os.environ, {signatures.PIN_ENV: ""}), self.assertRaisesRegex(ValueError, "publisher is not configured"):
            signatures.verify_files([("uten_imp.exe", self.file)])

    def test_publisher_rotation_pin_limit_matches_the_server(self):
        with mock.patch.dict(os.environ, {signatures.PIN_ENV: ",".join(f"{value:064x}" for value in range(5))}), \
             self.assertRaisesRegex(ValueError, "1..4"):
            signatures.publisher_pins()

    def test_timestamp_endpoint_rejects_sensitive_url_components_without_echoing_them(self):
        for url in ("https://timestamp.example/?token=secret-value", "https://timestamp.example/#secret-value",
                    "https://user:secret-value@timestamp.example/"):
            with self.subTest(url=url), mock.patch.dict(os.environ, {signatures.TIMESTAMP_ENV: url}):
                with self.assertRaises(ValueError) as error:
                    signatures.timestamp_url()
                self.assertNotIn("secret-value", str(error.exception))
        with mock.patch.dict(os.environ, {signatures.TIMESTAMP_ENV: "https://timestamp.example/tsa"}):
            self.assertEqual(signatures.timestamp_url(), "https://timestamp.example/tsa")

    def test_bad_pin_timestamp_eku_and_catalog_cannot_claim_company_trust(self):
        for changes in ({"signerSha256": "b" * 64}, {"timestamped": False}, {"codeSigning": False},
                        {"signatureType": "Catalog"}, {"status": "HashMismatch"}, {"path": "different-file"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify(self.record(**changes))

    def test_trusted_vendor_identity_may_differ_from_company(self):
        result, _ = self.verify(self.record(signerSha256="b" * 64), company_files=set())
        self.assertFalse(result["files"][0]["companyPublisher"])

    def test_native_chain_error_cannot_be_replaced_by_metadata_or_manifest(self):
        with mock.patch.object(signatures, "_metadata", return_value=[self.record()]), \
             mock.patch.object(signatures, "_signtool", side_effect=ValueError("revoked")), \
             self.assertRaisesRegex(ValueError, "revoked"):
            signatures.verify_files([("uten_imp.exe", self.file)])

    def test_file_change_between_trust_and_publication_is_rejected(self):
        def change(*args, **options):
            self.file.write_bytes(b"changed while verifying")
        with mock.patch.object(signatures, "_metadata", return_value=[self.record()]), \
             mock.patch.object(signatures, "_signtool", side_effect=change), \
             self.assertRaisesRegex(ValueError, "changed during"):
            signatures.verify_files([("uten_imp.exe", self.file)])

    def test_whole_package_deadline_and_signable_file_count_are_bounded(self):
        with self.assertRaisesRegex(ValueError, "deadline"):
            signatures._remaining(time.monotonic() - 1)
        with self.assertRaisesRegex(ValueError, "1..128"):
            signatures.verify_files([("uten_imp.exe", self.file)] * 129)

    def test_missing_signing_tool_is_an_explicit_readiness_failure(self):
        with mock.patch.dict(os.environ, {signatures.TOOL_ENV: str(self.root / "signtool.exe")}), \
             self.assertRaisesRegex(ValueError, "SignTool.exe is unavailable"):
            signatures.check_configuration()

    def test_signature_warning_and_timeout_both_fail_closed(self):
        with mock.patch.object(signatures, "signing_tool", return_value=self.file), \
             mock.patch.object(signatures.subprocess, "run", return_value=subprocess.CompletedProcess([], 2, "timestamp warning", "")), \
             self.assertRaisesRegex(ValueError, "timestamp warning"):
            signatures._signtool(["verify"])
        with mock.patch.object(signatures, "signing_tool", return_value=self.file), \
             mock.patch.object(signatures.subprocess, "run", side_effect=subprocess.TimeoutExpired([], 30)), \
             self.assertRaisesRegex(ValueError, "timed out"):
            signatures._signtool(["verify"])

    def test_runtime_enumeration_covers_pe_disguised_as_other_extension(self):
        (self.root / "native.payload").write_bytes(b"MZ" + b"read-only fake PE")
        (self.root / "data.bin").write_bytes(b"ordinary data")
        self.assertEqual({name for name, _ in signatures.runtime_files(self.root)}, {"uten_imp.exe", "native.payload"})

    def test_archive_checks_the_finished_bytes_and_preserves_company_path(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("client_updater/client_updater.ps1", b"safe synthetic script")
            archive.writestr("data/native.so", b"MZfake")
        with zipfile.ZipFile(io.BytesIO(buffer.getvalue())) as archive, \
             mock.patch.object(signatures, "verify_files", return_value={"verified": True}) as verify:
            signatures.verify_archive(archive)
            files = verify.call_args.args[0]
            self.assertEqual([name for name, _ in files], ["client_updater/client_updater.ps1", "data/native.so"])
            # The private extraction directory is intentionally already removed.
        self.assertFalse(files[0][1].exists())

    def test_signer_uses_sha256_rfc3161_and_private_key_selector_only(self):
        ready = {"timestampService": "https://timestamp.example", "store": "CurrentUser\\My"}
        with mock.patch.dict(os.environ, {signatures.KEY_ENV: "c" * 40}), \
             mock.patch.object(signatures, "_metadata", return_value=[self.record(status="NotSigned")]), \
             mock.patch.object(signatures, "check_configuration", return_value=ready), \
             mock.patch.object(signatures, "_signtool") as native, \
             mock.patch.object(signatures, "verify_files", return_value={"verified": True}):
            signatures.sign_files([("uten_imp.exe", self.file)])
        arguments = native.call_args.args[0]
        self.assertEqual(arguments[:7], ["sign", "/fd", "SHA256", "/tr", "https://timestamp.example", "/td", "SHA256"])
        self.assertIn("/sha1", arguments)
        self.assertNotIn("/p", arguments)

    def test_modified_vendor_signature_never_invokes_the_company_signer(self):
        for status in ("HashMismatch", "NotTrusted", "NotSigned"):
            with self.subTest(status=status), \
                 mock.patch.object(signatures, "_metadata", return_value=[self.record(status=status)]), \
                 mock.patch.object(signatures, "check_configuration") as readiness, \
                 mock.patch.object(signatures, "_signtool") as signer, \
                 self.assertRaisesRegex(ValueError, "refusing to replace|re-signing is forbidden"):
                signatures.sign_files([("BouncyCastle.Cryptography.dll", self.file)])
            readiness.assert_not_called()
            signer.assert_not_called()

    def test_vendor_chain_failure_is_not_repaired_by_resigning_it(self):
        with mock.patch.object(signatures, "_metadata", return_value=[self.record(signerSha256="b" * 64)]), \
             mock.patch.object(signatures, "check_configuration") as readiness, \
             mock.patch.object(signatures, "verify_files", side_effect=ValueError("revoked vendor chain")), \
             self.assertRaisesRegex(ValueError, "revoked vendor chain"):
            signatures.sign_files([("BouncyCastle.Cryptography.dll", self.file)])
        readiness.assert_not_called()

    def test_formal_payload_cannot_skip_signatures_with_the_local_test_allow_flag(self):
        from test_verify_windows_release import formal_bundle
        from test_package_windows import generated_runtime_profile
        import package_windows
        bundle = formal_bundle(self.root / "runtime", version=(2, 5, 44), build=2544)
        (bundle / "data/uten-runtime-profile.json").write_text(
            json.dumps(generated_runtime_profile("formal")), encoding="utf-8")
        # Profile marker is part of the actual PE identity, so stamp the same
        # generated formal resources instead of merely labelling the JSON.
        from test_package_windows import fixture_executable
        profile = generated_runtime_profile("formal")
        from test_verify_windows_release import with_pe_characteristics, IDENTITY
        (bundle / "uten_imp.exe").write_bytes(with_pe_characteristics(fixture_executable(
            2544, version=(2, 5, 44), strings={**IDENTITY, "UtenBuildProfile": "formal",
            "UtenApplicationId": profile["applicationId"]}), 0x0002))
        output = self.root / "formal.zip"
        with mock.patch.object(signatures, "verify_files", side_effect=ValueError("actual signature required")), \
             self.assertRaisesRegex(ValueError, "actual signature required"):
            package_windows.package_release(bundle, output, build_number=2544, architecture="x64", version="2.5.44",
                                            kind="installer", allow_local_test=True)
        self.assertFalse(output.exists())
        import windows_payload_binding
        with mock.patch.object(signatures, "verify_files"), mock.patch.object(signatures, "verify_archive"), \
             mock.patch.object(windows_payload_binding, "verify_sources"), mock.patch.object(windows_payload_binding, "verify_archive"):
            package_windows.package_release(bundle, output, build_number=2544, architecture="x64", version="2.5.44",
                                            kind="installer", allow_local_test=True)
        with mock.patch.object(signatures, "verify_archive", side_effect=ValueError("archived signature required")), \
             self.assertRaisesRegex(ValueError, "archived signature required"):
            package_windows.validate_package(output, build_number=2544, architecture="x64", version="2.5.44",
                                             kind="installer", allow_local_test=True)


class OptionalAuthenticodePolicyTest(unittest.TestCase):
    def setUp(self):
        environment = mock.patch.dict(os.environ, {key: "" for key in
            (signatures.PIN_ENV, signatures.KEY_ENV, signatures.TIMESTAMP_ENV,
             signatures.TOOL_ENV, signatures.REQUIRE_ENV)})
        environment.start()
        self.addCleanup(environment.stop)
        temporary = tempfile.TemporaryDirectory(prefix="uten-optional-signature-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_unconfigured_default_reports_unverified_without_touching_keys_or_bytes(self):
        file = self.root / "application.exe"
        file.write_bytes(b"synthetic unchanged unsigned input")
        before = file.read_bytes()
        with mock.patch.object(signatures, "_provider") as native, mock.patch.object(signatures, "_signtool") as tool:
            readiness = signatures.check_configuration()
            evidence = signatures.sign_files([("application.exe", file)])
            verified = signatures.verify_files([("application.exe", file)])
        self.assertFalse(readiness["ready"])
        self.assertFalse(readiness["signingEnabled"])
        self.assertFalse(evidence["verified"])
        self.assertEqual("not-verified-not-required", verified["status"])
        self.assertEqual(before, file.read_bytes())
        native.assert_not_called()
        tool.assert_not_called()

    def test_explicit_require_and_partial_signing_configuration_still_fail_closed(self):
        file = self.root / "application.exe"
        file.write_bytes(b"synthetic")
        with mock.patch.dict(os.environ, {signatures.REQUIRE_ENV: "true"}):
            with self.assertRaises(ValueError):
                signatures.check_configuration()
            with self.assertRaisesRegex(ValueError, "publisher is not configured"):
                signatures.verify_files([("application.exe", file)])
        with mock.patch.dict(os.environ, {signatures.PIN_ENV: "invalid"}):
            self.assertTrue(signatures.signing_enabled())
            with self.assertRaisesRegex(ValueError, "publisher is not configured"):
                signatures.verify_files([("application.exe", file)])
        with mock.patch.dict(os.environ, {signatures.REQUIRE_ENV: "invalid"}):
            with self.assertRaisesRegex(ValueError, "boolean"):
                signatures.signature_required()

    def test_unsigned_formal_archive_still_requires_exact_payload_binding_and_approved_engine(self):
        from test_verify_windows_release import formal_bundle, IDENTITY
        from test_package_windows import generated_runtime_profile, fixture_executable
        import package_windows
        import windows_payload_binding as binding
        profile = generated_runtime_profile("formal")
        bundle = formal_bundle(self.root / "runtime", version=(2, 5, 45), build=2545,
            exe_identity={**IDENTITY, "UtenBuildProfile": "formal", "UtenApplicationId": profile["applicationId"]})
        (bundle / "data/uten-runtime-profile.json").write_text(json.dumps(profile), encoding="utf-8")
        sources, _, _ = package_windows.collect_runtime_sources(bundle, architecture="x64", kind="update")
        metadata = {"runtimeFamily": "flutter", "version": "2.5.45", "buildNumber": 2545,
                    "architecture": "x64", "executable": "uten_imp.exe"}
        binding.write(bundle / "uten_imp.exe", binding.inventory(metadata, binding.file_records(sources)))
        output = self.root / "unsigned-update.zip"
        package_windows.package_release(bundle, output, build_number=2545, architecture="x64",
            version="2.5.45", installer_sha256="a" * 64)
        package_windows.validate_package(output, build_number=2545, architecture="x64", version="2.5.45")
        (bundle / "data/app.so").write_bytes((bundle / "data/app.so").read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "payload binding differs"):
            package_windows.package_release(bundle, self.root / "tampered.zip", build_number=2545,
                architecture="x64", version="2.5.45", installer_sha256="a" * 64)
        (bundle / "flutter_windows.dll").write_bytes(fixture_executable(2545, strings={"unknownEngine": "true"}))
        with self.assertRaisesRegex(ValueError, "Unreviewed"):
            package_windows.package_release(bundle, self.root / "unknown-engine.zip", build_number=2545,
                architecture="x64", version="2.5.45", installer_sha256="a" * 64)

    def test_inno_signing_is_enabled_only_for_configured_or_required_company_signing(self):
        import build_windows_installer as setup
        options = dict(version="2.5.45", build_number=2545, architecture="x64")
        unsigned = setup.compiler_command(None, self.root, self.root, "Setup", **options)
        self.assertNotIn("/DUtenSign=1", unsigned)
        self.assertFalse(any(argument.startswith("/Suten=") for argument in unsigned))
        with mock.patch.dict(os.environ, {signatures.PIN_ENV: "a" * 64}):
            signed = setup.compiler_command(None, self.root, self.root, "Setup", **options)
        self.assertIn("/DUtenSign=1", signed)
        self.assertTrue(any(argument.startswith("/Suten=") for argument in signed))

    @unittest.skipUnless(os.environ.get("UTEN_TEST_ISCC"), "Explicit approved Inno compiler is required")
    def test_real_inno_builds_an_unsigned_pair_without_signing_or_relabelling_the_runtime(self):
        from test_verify_windows_release import formal_bundle, IDENTITY, ENDPOINTS
        from test_package_windows import generated_runtime_profile
        import build_windows_installer as setup
        from verify_windows_release import verify_pair
        profile = generated_runtime_profile("formal")
        bundle = formal_bundle(self.root / "runtime", version=(2, 5, 45), build=2545,
            exe_identity={**IDENTITY, "UtenBuildProfile": "formal", "UtenApplicationId": profile["applicationId"]})
        (bundle / "data/uten-runtime-profile.json").write_text(json.dumps(profile), encoding="utf-8")
        original = (bundle / "uten_imp.exe").read_bytes()
        installer, update = self.root / "Setup.exe", self.root / "update.zip"
        result = setup.build_windows_setup(bundle, installer, version="2.5.45", build_number=2545,
            architecture="x64", compiler=Path(os.environ["UTEN_TEST_ISCC"]), compile=True, update_output=update)
        self.assertFalse(result["windowsSigning"]["signatureVerified"])
        self.assertEqual(original, (bundle / "uten_imp.exe").read_bytes())
        self.assertEqual("NotSigned", signatures._metadata([installer.resolve()])[0]["status"])
        self.assertTrue(verify_pair(installer, update, version="2.5.45", build_number=2545,
            architecture="x64", required_endpoints=ENDPOINTS)["ok"])


@unittest.skipUnless(os.name == "nt", "Windows native trust integration")
class RealWindowsTrustTest(unittest.TestCase):
    def test_real_unsigned_application_is_rejected_by_windows(self):
        with tempfile.TemporaryDirectory(prefix="uten-unsigned-native-") as directory:
            path = Path(directory) / "unsigned.exe"
            from test_package_windows import fixture_executable
            path.write_bytes(fixture_executable())
            self.assertEqual(signatures._metadata([path])[0]["status"], "NotSigned")
            self.assertNotEqual(signatures._wintrust(path), 0)

    def test_real_embedded_signature_accepts_original_and_rejects_modified_copy(self):
        edge = Path("C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe")
        if not edge.is_file():
            self.skipTest("Read-only installed Edge embedded-signature fixture is absent")
        metadata = signatures._metadata([edge])[0]
        self.assertEqual(metadata["status"], "Valid")
        self.assertEqual(metadata["signatureType"], "Authenticode")
        self.assertTrue(metadata["codeSigning"])
        self.assertTrue(metadata["timestamped"])
        self.assertEqual(signatures._wintrust(edge), 0)
        with tempfile.TemporaryDirectory(prefix="uten-tampered-native-") as directory:
            copy = Path(directory) / "changed.exe"
            shutil.copyfile(edge, copy)
            with copy.open("r+b") as stream:
                stream.seek(1024)
                value = stream.read(1)
                stream.seek(1024)
                stream.write(bytes([value[0] ^ 1]))
            self.assertNotEqual(signatures._wintrust(copy), 0)
            self.assertEqual(signatures._metadata([copy])[0]["status"], "HashMismatch")


if __name__ == "__main__":
    unittest.main()
