#!/usr/bin/env python3
"""Focused P0 tests for updater transaction and local trust boundaries."""

from __future__ import annotations

import contextlib
import importlib.util
import inspect
import os
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "uten_imp_release_updater_state_lock_test", HERE / "release_updater.py"
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load release_updater.py")
updater = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = updater
SPEC.loader.exec_module(updater)


class ReleaseGuardStableLoaderTest(unittest.TestCase):
    def test_preverified_guard_is_reused_without_reopening_its_path(self):
        module_name = "uten_imp_release_updater_preverified_guard_test"
        spec = importlib.util.spec_from_file_location(
            module_name, HERE / "release_updater.py"
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        candidate = importlib.util.module_from_spec(spec)
        candidate._UTEN_PREVERIFIED_RELEASE_GUARD = updater.release_guard
        sys.modules[module_name] = candidate
        try:
            with mock.patch.object(
                os,
                "open",
                side_effect=AssertionError("preverified guard path was reopened"),
            ):
                spec.loader.exec_module(candidate)
            self.assertIs(candidate.release_guard, updater.release_guard)
        finally:
            sys.modules.pop(module_name, None)

    def test_preverified_guard_requires_the_fixed_path_and_complete_api(self):
        wrong_path = types.ModuleType("wrong_path_guard")
        wrong_path.__file__ = str(HERE / "elsewhere.py")
        with self.assertRaisesRegex(RuntimeError, "fixed source path"):
            updater._validate_release_guard_module(wrong_path, updater._GUARD_PATH)

        incomplete = types.ModuleType("incomplete_guard")
        incomplete.__file__ = str(updater._GUARD_PATH)
        with self.assertRaisesRegex(RuntimeError, "API contract"):
            updater._validate_release_guard_module(incomplete, updater._GUARD_PATH)

    def test_stable_loader_rejects_fd_metadata_drift_before_compile(self):
        actual_fstat = os.fstat
        observations = 0

        def drifting_fstat(descriptor: int):
            nonlocal observations
            observations += 1
            details = actual_fstat(descriptor)
            if observations == 1:
                return details
            return SimpleNamespace(
                st_dev=details.st_dev,
                st_ino=details.st_ino,
                st_mode=details.st_mode,
                st_nlink=details.st_nlink,
                st_uid=details.st_uid,
                st_gid=details.st_gid,
                st_size=details.st_size,
                st_mtime_ns=details.st_mtime_ns + 1,
                st_ctime_ns=details.st_ctime_ns,
            )

        with mock.patch.object(
            updater.os, "fstat", side_effect=drifting_fstat
        ), mock.patch("builtins.compile") as compile_source:
            with self.assertRaisesRegex(RuntimeError, "changed while it was captured"):
                updater._stable_release_guard_module(HERE / "release_guard.py")
        compile_source.assert_not_called()

    def test_stable_loader_rejects_digest_mismatch_before_compile_or_exec(self):
        with tempfile.TemporaryDirectory() as temporary:
            tampered = Path(temporary) / "release_guard.py"
            tampered.write_bytes((HERE / "release_guard.py").read_bytes() + b"\n# tampered\n")
            with mock.patch("builtins.compile") as compile_source, mock.patch(
                "builtins.exec"
            ) as execute_source:
                with self.assertRaisesRegex(RuntimeError, "digest.*leaf pin"):
                    updater._stable_release_guard_module(tampered)
            compile_source.assert_not_called()
            execute_source.assert_not_called()

    def test_stable_loader_rejects_path_replacement_before_compile_or_exec(self):
        with tempfile.TemporaryDirectory() as temporary:
            helper = Path(temporary) / "reviewed_helper.py"
            displaced = Path(temporary) / "reviewed_helper.displaced"
            reviewed = b"VALUE = 'reviewed'\n"
            helper.write_bytes(reviewed)
            actual_read = os.read
            replaced = False

            def replace_path_then_read(descriptor: int, maximum: int) -> bytes:
                nonlocal replaced
                if not replaced:
                    helper.rename(displaced)
                    helper.write_bytes(b"VALUE = 'attacker'\n")
                    replaced = True
                return actual_read(descriptor, maximum)

            with mock.patch.object(
                updater.os, "read", side_effect=replace_path_then_read
            ), mock.patch("builtins.compile") as compile_source, mock.patch(
                "builtins.exec"
            ) as execute_source:
                with self.assertRaisesRegex(RuntimeError, "changed while it was captured"):
                    updater._stable_pinned_python_module(
                        helper,
                        expected_sha256=updater.hashlib.sha256(reviewed).hexdigest(),
                        module_name="uten_imp_replaced_helper_test",
                        require_root_control=False,
                    )
            compile_source.assert_not_called()
            execute_source.assert_not_called()

    def test_stable_pinned_helper_executes_exactly_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            helper = Path(temporary) / "one_shot.py"
            payload = b"EXECUTIONS = globals().get('EXECUTIONS', 0) + 1\n"
            helper.write_bytes(payload)
            module = updater._stable_pinned_python_module(
                helper,
                expected_sha256=updater.hashlib.sha256(payload).hexdigest(),
                module_name="uten_imp_one_shot_helper_test",
                require_root_control=False,
            )
            try:
                self.assertEqual(1, module.EXECUTIONS)
            finally:
                sys.modules.pop("uten_imp_one_shot_helper_test", None)

    def test_top_level_guard_loader_has_no_path_import_after_capture(self):
        source = (HERE / "release_updater.py").read_text(encoding="utf-8")
        loader_source = source.split("LOG_TAG =", maxsplit=1)[0]
        self.assertIn("_UTEN_PREVERIFIED_RELEASE_GUARD", loader_source)
        self.assertIn("_GUARD_SHA256", loader_source)
        self.assertIn("hashlib.sha256(source)", loader_source)
        self.assertIn("compile(source", loader_source)
        self.assertNotIn("spec_from_file_location", loader_source)
        self.assertNotIn("exec_module", loader_source)

    def test_storage_observer_uses_the_same_pinned_stable_loader(self):
        source = inspect.getsource(updater.assert_storage_observer_contract)
        self.assertIn("_stable_pinned_python_module(", source)
        self.assertIn("expected_sha256=STORAGE_MOUNT_OBSERVER_SHA256", source)
        self.assertIn("Path(\"/usr/local/libexec/uten-imp-release\")", source)
        self.assertIn("exact_mode=0o644", source)
        self.assertNotIn("spec_from_file_location", source)
        self.assertNotIn("exec_module", source)


class CredentialHelperStableExecutionTest(unittest.TestCase):
    def test_credential_helper_leaf_pins_match_reviewed_source_bytes(self):
        self.assertEqual(
            updater.OSS_IO_SHA256,
            updater.hashlib.sha256((HERE / "oss_io.py").read_bytes()).hexdigest(),
        )
        self.assertEqual(
            updater.WHEELHOUSE_SUPPLY_CHAIN_SHA256,
            updater.hashlib.sha256(
                (HERE / "wheelhouse_supply_chain.py").read_bytes()
            ).hexdigest(),
        )

    def test_captured_helper_bytes_are_executed_without_reopening_replaced_path(self):
        reviewed = b"print('reviewed')\n"
        attacker = b"raise RuntimeError('attacker path executed')\n"
        with tempfile.TemporaryDirectory() as temporary:
            helper = Path(temporary) / "credential_helper.py"
            displaced = Path(temporary) / "credential_helper.reviewed.py"
            helper.write_bytes(reviewed)

            def capture(path: Path, **_kwargs) -> bytes:
                self.assertEqual(helper, path)
                path.rename(displaced)
                path.write_bytes(attacker)
                return reviewed

            completed = SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
            with mock.patch.object(
                updater, "read_root_controlled_bytes", side_effect=capture
            ), mock.patch.object(
                updater.subprocess, "run", return_value=completed
            ) as execute:
                result = updater.run_pinned_python_source(
                    helper,
                    expected_sha256=updater.hashlib.sha256(reviewed).hexdigest(),
                    arguments=["verify"],
                    executable="/usr/bin/python3",
                    environment={"PATH": "/usr/bin:/bin"},
                    capture=True,
                    check=True,
                    timeout=30,
                    label="test credential helper",
                )

        self.assertIs(completed, result)
        self.assertEqual(
            ["/usr/bin/python3", "-I", "-", "verify"],
            execute.call_args.args[0],
        )
        self.assertEqual(reviewed, execute.call_args.kwargs["input"])
        self.assertNotIn(str(helper), execute.call_args.args[0])

    def test_oss_digest_mismatch_never_dispatches_credential_environment(self):
        reviewed = b"print('reviewed')\n"
        tampered = b"print('tampered')\n"
        credential_environment = {
            "PATH": "/usr/bin:/bin",
            "OSS_ACCESS_KEY_ID": "sensitive-test-value",
        }
        with mock.patch.object(
            updater, "OSS_IO_SHA256", updater.hashlib.sha256(reviewed).hexdigest()
        ), mock.patch.object(
            updater, "read_root_controlled_bytes", return_value=tampered
        ), mock.patch.object(
            updater.os, "environ", credential_environment
        ), mock.patch.object(
            updater.subprocess, "run"
        ) as execute, self.assertRaisesRegex(
            updater.UpdaterError, "credential-bearing OSS helper.*leaf digest"
        ):
            updater.oss_stat("candidate/channel.json")
        execute.assert_not_called()

    def test_wheelhouse_contract_digest_mismatch_precedes_helper_dispatch(self):
        with mock.patch.object(
            updater, "run_pinned_python_source"
        ) as execute, self.assertRaisesRegex(
            updater.UpdaterError, "unpinned wheelhouse verifier"
        ):
            updater.updater_venv_inventory_sha256("0" * 64)
        execute.assert_not_called()

    def test_credential_helpers_have_no_python_child_path_argument(self):
        wheelhouse = inspect.getsource(updater.updater_venv_inventory_sha256)
        oss = inspect.getsource(updater.run_oss_helper)
        runner = inspect.getsource(updater.run_pinned_python_source)
        self.assertIn("run_pinned_python_source(", wheelhouse)
        self.assertIn("run_pinned_python_source(", oss)
        self.assertIn('executable="/proc/self/exe"', oss)
        self.assertIn('[executable, "-I", "-", *arguments]', runner)
        self.assertNotIn("str(verifier)", wheelhouse)
        self.assertNotIn("str(OSS_IO_HELPER)", oss)

    def test_post_verifier_venv_inventory_has_a_root_immutable_tree_basis(self):
        verifier = (HERE / "wheelhouse_supply_chain.py").read_text(encoding="utf-8")
        inventory = inspect.getsource(updater.updater_venv_inventory_sha256)
        self.assertIn("details.st_uid != 0 or details.st_gid != 0", verifier)
        self.assertIn("details.st_mode & 0o022", verifier)
        self.assertIn("details.st_nlink != 1", verifier)
        self.assertIn("verify-installed has just proven the entire venv tree", inventory)


class StateLockPersistentMarkerTest(unittest.TestCase):
    MARKERS = {
        "ACTIVATION_FAILURE_MARKER": "activation-failed.json",
        "ACTIVATION_IN_PROGRESS_MARKER": "activation-in-progress.json",
        "BOOT_ENABLEMENT_IN_PROGRESS_MARKER": "boot-enablement-in-progress.json",
        "RECOVERY_IN_PROGRESS_MARKER": "recovery-in-progress.json",
        "RECOVERY_INGRESS_PENDING": "recovery-ingress-pending.json",
        "RECOVERY_INGRESS_AUTHORIZATION": "recovery-ingress-authorization.json",
        "RECOVERY_INGRESS_FINALIZING": "recovery-ingress-finalizing.json",
        "INTERNAL_TEST_ONBOARDING_ADOPTION": (
            "internal-test-onboarding-adoption.json"
        ),
        "INTERNAL_TEST_ACTIVATION_REAUTHORIZATION": (
            "internal-test-activation-reauthorization.json"
        ),
    }

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.lock_path = self.root / "operation.lock"
        self.lock_path.write_bytes(b"")
        self.lock_path.chmod(0o660)
        self.worker_request = self.root / "worker-request.json"
        self.paths = {
            attribute: self.root / name for attribute, name in self.MARKERS.items()
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @contextlib.contextmanager
    def patched_lock_namespace(self):
        actual_fstat = os.fstat

        def root_lock_stat(descriptor: int):
            details = actual_fstat(descriptor)
            return SimpleNamespace(
                st_mode=stat.S_IFREG | 0o660,
                st_uid=0,
                st_gid=4242,
                st_nlink=1,
                st_dev=details.st_dev,
                st_ino=details.st_ino,
                st_size=details.st_size,
            )

        with contextlib.ExitStack() as stack:
            for attribute, path in self.paths.items():
                stack.enter_context(mock.patch.object(updater, attribute, path))
            stack.enter_context(
                mock.patch.object(
                    updater, "INTERNAL_TEST_DB_WORKER_REQUEST", self.worker_request
                )
            )
            stack.enter_context(mock.patch.object(updater, "require_real_directory"))
            root_file = stack.enter_context(
                mock.patch.object(updater, "require_root_controlled_file")
            )
            stack.enter_context(
                mock.patch.object(updater, "system_group_id", return_value=4242)
            )
            stack.enter_context(
                mock.patch.object(updater.os, "fstat", side_effect=root_lock_stat)
            )
            yield root_file

    def test_every_persistent_marker_blocks_an_ordinary_lock_without_mutation(self):
        for attribute, marker in self.paths.items():
            with self.subTest(marker=attribute), self.patched_lock_namespace() as root_file:
                marker.write_text('{"status":"pending"}\n', encoding="utf-8")
                original = marker.read_bytes()
                guard = updater.StateLock(self.lock_path)
                with self.assertRaisesRegex(
                    updater.UpdaterError,
                    "global release gate|fixed systemd finalizer",
                ):
                    guard.__enter__()
                self.assertIsNone(guard.descriptor)
                self.assertEqual(original, marker.read_bytes())
                root_file.assert_called_once_with(marker, secret=True)
                marker.unlink()

    def test_recovery_allows_only_its_fixed_non_ingress_lineage(self):
        with self.patched_lock_namespace():
            compatible = updater.recovery_state_lock_compatible_markers()
            expected = {
                self.paths["ACTIVATION_FAILURE_MARKER"],
                self.paths["ACTIVATION_IN_PROGRESS_MARKER"],
                self.paths["BOOT_ENABLEMENT_IN_PROGRESS_MARKER"],
                self.paths["RECOVERY_IN_PROGRESS_MARKER"],
                self.paths["INTERNAL_TEST_ONBOARDING_ADOPTION"],
                self.paths["INTERNAL_TEST_ACTIVATION_REAUTHORIZATION"],
            }
            self.assertEqual(expected, set(compatible))
            for marker in expected:
                with self.subTest(marker=marker.name):
                    marker.write_text("{}\n", encoding="utf-8")
                    guard = updater.StateLock(self.lock_path).allow_persistent_markers(
                        compatible
                    )
                    with guard:
                        self.assertIsNotNone(guard.descriptor)
                    self.assertIsNone(guard.descriptor)
                    marker.unlink()

            for attribute in (
                "RECOVERY_INGRESS_PENDING",
                "RECOVERY_INGRESS_AUTHORIZATION",
                "RECOVERY_INGRESS_FINALIZING",
            ):
                with self.subTest(forbidden=attribute), self.assertRaisesRegex(
                    updater.UpdaterError, "can never be shared"
                ):
                    updater.StateLock(self.lock_path).allow_persistent_markers(
                        {self.paths[attribute]}
                    )

    def test_entrypoints_take_marker_gate_before_their_first_write(self):
        stage = inspect.getsource(updater.stage_release)
        self.assertLess(stage.index("with StateLock("), stage.index("os.mkdir(candidates"))

        activate = inspect.getsource(updater.activate_release)
        self.assertIn("activation_compatible_markers", activate)
        self.assertIn(".allow_persistent_markers(", activate)
        self.assertLess(
            activate.index("with StateLock("), activate.index("snapshot_candidate(")
        )

        for recovery in (
            updater.recover_interrupted_assess,
            updater.recover_interrupted_apply,
            updater.recover_assess,
            updater.recover_apply,
        ):
            source = inspect.getsource(recovery)
            self.assertIn("recovery_state_lock_compatible_markers()", source)
            self.assertIn(".allow_persistent_markers(", source)


class InternalTestTlsTrustBoundaryTest(unittest.TestCase):
    CERTIFICATE_BYTES = b"reviewed certificate bytes\n"
    KEY_BYTES = b"reviewed private key bytes\n"
    DOMAIN = "erp.internal.example"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.tls_root = self.root / "tls"
        self.ca_path = self.root / "system-ca"
        self.tls_root.mkdir()
        self.ca_path.mkdir()
        self.certificate = self.tls_root / "fullchain.pem"
        self.key = self.tls_root / "privkey.pem"
        self.certificate.write_bytes(b"placeholder")
        self.key.write_bytes(b"placeholder")
        self.calls: list[list[str]] = []
        self.call_options: list[dict[str, object]] = []

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def contract(self) -> dict[str, str]:
        return {
            "internalDomain": self.DOMAIN,
            "tlsCertificatePath": str(self.certificate),
            "tlsKeyPath": str(self.key),
            "tlsCertificateSha256": updater.hashlib.sha256(
                self.CERTIFICATE_BYTES
            ).hexdigest(),
            "tlsKeySha256": updater.hashlib.sha256(self.KEY_BYTES).hexdigest(),
        }

    def validate_with_san(self, san_output: bytes, *, verify_returncode: int = 0):
        def read_reviewed_bytes(path: Path, **_kwargs):
            if path == self.certificate:
                return self.CERTIFICATE_BYTES
            if path == self.key:
                return self.KEY_BYTES
            raise AssertionError(f"unexpected TLS path: {path}")

        def openssl_run(command, **_kwargs):
            self.calls.append(command)
            self.call_options.append(_kwargs)
            arguments = command[1:]
            if arguments == ["x509", "-noout", "-checkend", "86400"]:
                return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
            if arguments == ["x509", "-noout", "-ext", "subjectAltName"]:
                return SimpleNamespace(returncode=0, stdout=san_output, stderr=b"")
            if arguments[:1] == ["verify"]:
                return SimpleNamespace(
                    returncode=verify_returncode,
                    stdout=b"/dev/stdin: OK\n" if verify_returncode == 0 else b"",
                    stderr=b"strict chain failure\n" if verify_returncode else b"",
                )
            if arguments == ["x509", "-pubkey", "-noout"]:
                return SimpleNamespace(returncode=0, stdout=b"PUBLIC KEY\n", stderr=b"")
            if arguments == ["pkey", "-pubout"]:
                return SimpleNamespace(returncode=0, stdout=b"PUBLIC KEY\n", stderr=b"")
            raise AssertionError(f"unexpected OpenSSL invocation: {command}")

        @contextlib.contextmanager
        def sealed_snapshot(payload: bytes, label: str):
            self.assertEqual(self.CERTIFICATE_BYTES, payload)
            self.assertEqual("internal-test-tls-fullchain", label)
            yield 73

        with mock.patch.object(
            updater, "INTERNAL_TEST_TLS_ROOT", self.tls_root
        ), mock.patch.object(
            updater, "SYSTEM_CA_PATH", self.ca_path
        ), mock.patch.object(
            updater, "read_root_controlled_bytes", side_effect=read_reviewed_bytes
        ), mock.patch.object(
            updater, "require_real_directory"
        ) as require_ca, mock.patch.object(
            updater.subprocess, "run", side_effect=openssl_run
        ), mock.patch.object(
            updater, "sealed_memory_snapshot", side_effect=sealed_snapshot
        ):
            updater.validate_internal_test_tls_contract(self.contract())
        return require_ca

    def test_exact_dns_san_and_strict_system_ca_chain_are_required(self):
        require_ca = self.validate_with_san(
            b"X509v3 Subject Alternative Name:\n"
            b"    DNS:*.internal.example, DNS:erp.internal.example\n"
        )
        require_ca.assert_called_once_with(self.ca_path, owner_uid=0)
        verify = next(call for call in self.calls if call[1] == "verify")
        self.assertEqual(
            [
                "/usr/bin/openssl",
                "verify",
                "-x509_strict",
                "-purpose",
                "sslserver",
                "-verify_hostname",
                self.DOMAIN,
                "-CApath",
                str(self.ca_path),
                "-untrusted",
                "/proc/self/fd/73",
                "/proc/self/fd/73",
            ],
            verify,
        )
        verify_index = self.calls.index(verify)
        self.assertEqual((73,), self.call_options[verify_index]["pass_fds"])
        self.assertNotIn("-checkhost", inspect.getsource(updater.validate_internal_test_tls_contract))

    def test_wildcard_only_san_cannot_satisfy_exact_internal_dns_name(self):
        with self.assertRaisesRegex(
            updater.UpdaterError, "lacks the exact DNS subjectAltName"
        ):
            self.validate_with_san(
                b"X509v3 Subject Alternative Name:\n    DNS:*.internal.example\n"
            )
        self.assertFalse(any(call[1] == "verify" for call in self.calls))

    def test_untrusted_chain_fails_before_key_acceptance(self):
        with self.assertRaisesRegex(
            updater.UpdaterError, "failed OpenSSL validation"
        ):
            self.validate_with_san(
                b"X509v3 Subject Alternative Name:\n    DNS:erp.internal.example\n",
                verify_returncode=2,
            )
        self.assertTrue(any(call[1] == "verify" for call in self.calls))
        self.assertFalse(any(call[1:3] == ["x509", "-pubkey"] for call in self.calls))

    def test_real_root_intermediate_leaf_fullchain_validates(self):
        root_key = self.root / "root.key"
        root_certificate = self.root / "root.pem"
        intermediate_key = self.root / "intermediate.key"
        intermediate_csr = self.root / "intermediate.csr"
        intermediate_certificate = self.root / "intermediate.pem"
        leaf_csr = self.root / "leaf.csr"
        intermediate_extensions = self.root / "intermediate.ext"
        leaf_extensions = self.root / "leaf.ext"

        intermediate_extensions.write_text(
            "basicConstraints=critical,CA:TRUE,pathlen:0\n"
            "keyUsage=critical,keyCertSign,cRLSign\n"
            "subjectKeyIdentifier=hash\n"
            "authorityKeyIdentifier=keyid,issuer\n",
            encoding="ascii",
        )
        leaf_extensions.write_text(
            "basicConstraints=critical,CA:FALSE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\n"
            f"subjectAltName=DNS:{self.DOMAIN}\n"
            "subjectKeyIdentifier=hash\n"
            "authorityKeyIdentifier=keyid,issuer\n",
            encoding="ascii",
        )

        def openssl(*arguments: str) -> None:
            subprocess.run(
                ["/usr/bin/openssl", *arguments],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
                timeout=30,
            )

        openssl(
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-subj",
            "/CN=Uten Test Root",
            "-days",
            "2",
            "-sha256",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
            "-addext",
            "subjectKeyIdentifier=hash",
            "-keyout",
            str(root_key),
            "-out",
            str(root_certificate),
        )
        openssl(
            "req",
            "-new",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-subj",
            "/CN=Uten Test Intermediate",
            "-keyout",
            str(intermediate_key),
            "-out",
            str(intermediate_csr),
        )
        openssl(
            "x509",
            "-req",
            "-in",
            str(intermediate_csr),
            "-CA",
            str(root_certificate),
            "-CAkey",
            str(root_key),
            "-CAcreateserial",
            "-days",
            "2",
            "-sha256",
            "-extfile",
            str(intermediate_extensions),
            "-out",
            str(intermediate_certificate),
        )
        openssl(
            "req",
            "-new",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-subj",
            f"/CN={self.DOMAIN}",
            "-keyout",
            str(self.key),
            "-out",
            str(leaf_csr),
        )
        openssl(
            "x509",
            "-req",
            "-in",
            str(leaf_csr),
            "-CA",
            str(intermediate_certificate),
            "-CAkey",
            str(intermediate_key),
            "-CAcreateserial",
            "-days",
            "2",
            "-sha256",
            "-extfile",
            str(leaf_extensions),
            "-out",
            str(self.certificate),
        )
        self.certificate.write_bytes(
            self.certificate.read_bytes() + intermediate_certificate.read_bytes()
        )
        (self.ca_path / "root.pem").write_bytes(root_certificate.read_bytes())
        openssl("rehash", str(self.ca_path))
        certificate_bytes = self.certificate.read_bytes()
        key_bytes = self.key.read_bytes()
        contract = {
            "internalDomain": self.DOMAIN,
            "tlsCertificatePath": str(self.certificate),
            "tlsKeyPath": str(self.key),
            "tlsCertificateSha256": updater.hashlib.sha256(
                certificate_bytes
            ).hexdigest(),
            "tlsKeySha256": updater.hashlib.sha256(key_bytes).hexdigest(),
        }

        with mock.patch.object(
            updater, "INTERNAL_TEST_TLS_ROOT", self.tls_root
        ), mock.patch.object(
            updater, "SYSTEM_CA_PATH", self.ca_path
        ), mock.patch.object(
            updater,
            "read_root_controlled_bytes",
            side_effect=lambda path, **_kwargs: path.read_bytes(),
        ), mock.patch.object(
            updater, "require_real_directory"
        ):
            updater.validate_internal_test_tls_contract(contract)


class DatabaseVerifierStableExecutionTest(unittest.TestCase):
    def test_path_replacement_after_capture_executes_only_captured_bytes(self):
        reviewed = b"print('{}')\n"
        attacker = b"raise RuntimeError('attacker path executed')\n"
        with tempfile.TemporaryDirectory() as temporary:
            verifier = Path(temporary) / "database_recovery_verifier.py"
            displaced = Path(temporary) / "database_recovery_verifier.reviewed.py"
            verifier.write_bytes(reviewed)

            def capture(path: Path, **_kwargs) -> bytes:
                self.assertEqual(verifier, path)
                path.rename(displaced)
                path.write_bytes(attacker)
                return reviewed

            completed = SimpleNamespace(
                returncode=0, stdout=b"{}\n", stderr=b""
            )
            with mock.patch.object(
                updater, "DATABASE_RECOVERY_VERIFIER", verifier
            ), mock.patch.object(
                updater,
                "DATABASE_RECOVERY_VERIFIER_SHA256",
                updater.hashlib.sha256(reviewed).hexdigest(),
            ), mock.patch.object(
                updater, "read_root_controlled_bytes", side_effect=capture
            ), mock.patch.object(
                updater.subprocess, "run", return_value=completed
            ) as execute:
                self.assertEqual({}, updater.observe_live_database())

        self.assertEqual(
            [
                "/usr/sbin/runuser",
                "-u",
                "postgres",
                "--",
                "/usr/bin/python3",
                "-I",
                "-",
            ],
            execute.call_args.args[0],
        )
        self.assertEqual(reviewed, execute.call_args.kwargs["input"])
        self.assertNotIn("stdin", execute.call_args.kwargs)

    def test_digest_mismatch_never_dispatches_the_verifier(self):
        reviewed = b"print('{}')\n"
        tampered = b"print('{\"tampered\":true}')\n"
        with mock.patch.object(
            updater,
            "DATABASE_RECOVERY_VERIFIER_SHA256",
            updater.hashlib.sha256(reviewed).hexdigest(),
        ), mock.patch.object(
            updater, "read_root_controlled_bytes", return_value=tampered
        ), mock.patch.object(
            updater.subprocess, "run"
        ) as execute, self.assertRaisesRegex(
            updater.UpdaterError, "differs from the reviewed digest"
        ):
            updater.observe_live_database()
        execute.assert_not_called()

    def test_database_verifier_has_no_child_path_reopen(self):
        source = inspect.getsource(updater.observe_live_database)
        self.assertIn("read_root_controlled_bytes(", source)
        self.assertIn("input=verifier_bytes", source)
        self.assertNotIn("str(DATABASE_RECOVERY_VERIFIER)", source)


if __name__ == "__main__":
    unittest.main()
