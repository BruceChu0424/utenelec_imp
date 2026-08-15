import ast
import contextlib
import hashlib
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SETUP_DIR = Path(__file__).parent
LAUNCHER_PATH = SETUP_DIR / "launch-internal-test-reviewed-host-manifest-builder.py"
BUILDER_PATH = SETUP_DIR / "build-internal-test-reviewed-host-manifest.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


launcher = load_module("reviewed_host_manifest_launcher", LAUNCHER_PATH)
builder = load_module("reviewed_host_manifest_builder_tls", BUILDER_PATH)


class LauncherContractTest(unittest.TestCase):
    def test_source_executes_verified_memory_without_path_or_subprocess_dispatch(self):
        source = LAUNCHER_PATH.read_text(encoding="utf-8")
        tree = ast.parse(source)
        imported = {
            alias.name
            for node in ast.walk(tree)
            if isinstance(node, ast.Import)
            for alias in node.names
        }
        imported_from = {
            node.module
            for node in ast.walk(tree)
            if isinstance(node, ast.ImportFrom) and node.module is not None
        }
        self.assertNotIn("subprocess", imported)
        self.assertNotIn("runpy", imported)
        self.assertNotIn("importlib", imported)
        self.assertNotIn("runpy", imported_from)
        self.assertIn('compile(verified.payload, str(builder), "exec"', source)
        self.assertIn("exec(code, namespace, namespace)", source)

    def test_fixed_install_and_isolated_mode_are_mandatory(self):
        self.assertEqual(
            Path("/usr/local/sbin/uten-imp-reviewed-host-manifest-builder-launcher"),
            launcher.INSTALLED_LAUNCHER,
        )
        with mock.patch.object(launcher.os, "geteuid", return_value=1, create=True):
            with self.assertRaisesRegex(launcher.LauncherError, "root"):
                launcher.validate_runtime_trust()
        source = LAUNCHER_PATH.read_text(encoding="utf-8")
        self.assertIn("sys.flags.isolated", source)
        self.assertIn('exact_mode=0o500', source)

    def test_builder_digest_argument_cannot_be_overridden(self):
        verified = launcher.VerifiedBuilder(b"pass\n", "a" * 64, 1, 2, 5)
        for arguments in (
            ["--expected-builder-sha256", "b" * 64],
            ["--expected-builder-sha256=" + "b" * 64],
        ):
            with self.subTest(arguments=arguments):
                with self.assertRaisesRegex(launcher.LauncherError, "launcher-owned"):
                    launcher.execute_verified_builder(
                        verified,
                        Path("/reviewed/setup/") / launcher.BUILDER_BASENAME,
                        arguments,
                    )

    def test_only_captured_bytes_execute_even_if_path_now_contains_other_code(self):
        verified_payload = b"raise SystemExit(23)\n"
        replacement_payload = b"raise SystemExit(91)\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / launcher.BUILDER_BASENAME
            path.write_bytes(replacement_payload)
            verified = launcher.VerifiedBuilder(
                verified_payload,
                hashlib.sha256(verified_payload).hexdigest(),
                1,
                2,
                len(verified_payload),
            )
            original_argv = sys.argv
            with self.assertRaises(SystemExit) as raised:
                launcher.execute_verified_builder(verified, path, ["--help"])
            self.assertEqual(23, raised.exception.code)
            self.assertIs(original_argv, sys.argv)

    def test_launcher_injects_the_authenticated_digest_into_builder_argv(self):
        digest = "c" * 64
        path = Path("/reviewed/setup") / launcher.BUILDER_BASENAME
        payload = (
            "import sys\n"
            f"expected = {[str(path), '--expected-builder-sha256', digest, '--help']!r}\n"
            "raise SystemExit(0 if sys.argv == expected else 97)\n"
        ).encode("utf-8")
        verified = launcher.VerifiedBuilder(payload, digest, 7, 8, len(payload))
        with self.assertRaises(SystemExit) as raised:
            launcher.execute_verified_builder(verified, path, ["--help"])
        self.assertEqual(0, raised.exception.code)


@unittest.skipUnless(
    os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0,
    "real root-owned fd/inode tamper contracts run on Linux as root",
)
class RootOwnedLauncherTamperTest(unittest.TestCase):
    def fixture(self, directory: str, payload: bytes = b"raise SystemExit(0)\n"):
        setup = Path(directory) / "setup"
        setup.mkdir(mode=0o700)
        path = setup / launcher.BUILDER_BASENAME
        path.write_bytes(payload)
        path.chmod(0o600)
        return path, payload

    def test_exact_single_link_builder_is_accepted(self):
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, payload = self.fixture(directory)
            verified = launcher.read_verified_builder(
                path, hashlib.sha256(payload).hexdigest()
            )
        self.assertEqual(payload, verified.payload)
        self.assertEqual(len(payload), verified.size)

    def test_symlink_builder_is_rejected(self):
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            root = Path(directory)
            setup = root / "setup"
            setup.mkdir(mode=0o700)
            target = setup / "real-builder.py"
            target.write_bytes(b"pass\n")
            target.chmod(0o600)
            path = setup / launcher.BUILDER_BASENAME
            path.symlink_to(target.name)
            with self.assertRaisesRegex(launcher.LauncherError, "open.*safely"):
                launcher.read_verified_builder(
                    path, hashlib.sha256(target.read_bytes()).hexdigest()
                )

    def test_hardlink_builder_is_rejected(self):
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            root = Path(directory)
            setup = root / "setup"
            setup.mkdir(mode=0o700)
            original = setup / "original-builder.py"
            original.write_bytes(b"pass\n")
            original.chmod(0o600)
            path = setup / launcher.BUILDER_BASENAME
            os.link(original, path)
            with self.assertRaisesRegex(launcher.LauncherError, "single|immutable"):
                launcher.read_verified_builder(
                    path, hashlib.sha256(original.read_bytes()).hexdigest()
                )

    def test_digest_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, _payload = self.fixture(directory)
            with self.assertRaisesRegex(launcher.LauncherError, "SHA-256"):
                launcher.read_verified_builder(path, "f" * 64)

    def test_group_writable_builder_is_rejected(self):
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, payload = self.fixture(directory)
            path.chmod(0o620)
            with self.assertRaisesRegex(launcher.LauncherError, "immutable"):
                launcher.read_verified_builder(
                    path, hashlib.sha256(payload).hexdigest()
                )

    def test_inode_replacement_during_read_is_rejected(self):
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, payload = self.fixture(directory, b"x" * (1024 * 1024 + 1))
            replacement = path.with_name("replacement-builder.py")
            replacement.write_bytes(payload)
            replacement.chmod(0o600)
            real_read = os.read
            swapped = False

            def read_then_swap(descriptor: int, size: int) -> bytes:
                nonlocal swapped
                block = real_read(descriptor, size)
                if block and not swapped:
                    swapped = True
                    os.replace(replacement, path)
                return block

            with mock.patch.object(launcher.os, "read", side_effect=read_then_swap):
                with self.assertRaisesRegex(launcher.LauncherError, "changed"):
                    launcher.read_verified_builder(
                        path, hashlib.sha256(payload).hexdigest()
                    )
            self.assertTrue(swapped)


class BuilderTlsTrustTest(unittest.TestCase):
    DOMAIN = "erp.office.example.invalid"

    @staticmethod
    def completed(command, returncode=0, stdout=b"", stderr=b""):
        return subprocess.CompletedProcess(command, returncode, stdout, stderr)

    def runner(self, san_output: bytes, *, verify_returncode: int = 0):
        commands: list[list[str]] = []

        def run(command, **_kwargs):
            commands.append(command)
            if "subjectAltName" in command:
                return self.completed(command, stdout=san_output)
            if command[1:3] == ["x509", "-pubkey"]:
                return self.completed(command, stdout=b"PUBLIC KEY\n")
            if command[1:3] == ["pkey", "-pubout"]:
                return self.completed(command, stdout=b"PUBLIC KEY\n")
            if command[1] == "verify":
                return self.completed(command, returncode=verify_returncode)
            return self.completed(command)

        return commands, run

    def invoke(self, san_output: bytes, *, verify_returncode: int = 0):
        commands, run = self.runner(
            san_output, verify_returncode=verify_returncode
        )
        with mock.patch.object(builder.subprocess, "run", side_effect=run), mock.patch.object(
            builder, "_validate_root_parent_chain"
        ), mock.patch.object(
            builder,
            "sealed_memory_snapshot",
            return_value=contextlib.nullcontext(73),
        ):
            builder.validate_tls_snapshot(
                self.DOMAIN, b"CERTIFICATE SNAPSHOT", b"PRIVATE KEY SNAPSHOT"
            )
        return commands

    def test_exact_dns_san_and_strict_system_ca_chain_are_required(self):
        commands = self.invoke(
            b"X509v3 Subject Alternative Name:\n"
            b"    DNS:erp.office.example.invalid, DNS:other.example.invalid\n"
        )
        flattened = [argument for command in commands for argument in command]
        self.assertNotIn("-checkhost", flattened)
        verify = next(command for command in commands if command[1] == "verify")
        self.assertIn("-x509_strict", verify)
        self.assertIn("sslserver", verify)
        self.assertIn("-verify_hostname", verify)
        self.assertIn(self.DOMAIN, verify)
        self.assertEqual(
            str(builder.SYSTEM_CA_PATH), verify[verify.index("-CApath") + 1]
        )
        self.assertEqual(
            "/proc/self/fd/73", verify[verify.index("-untrusted") + 1]
        )
        self.assertEqual("/proc/self/fd/73", verify[-1])

    def test_cn_only_certificate_is_rejected_without_chain_dispatch(self):
        commands, run = self.runner(b"subject=CN = " + self.DOMAIN.encode("ascii"))
        with mock.patch.object(builder.subprocess, "run", side_effect=run):
            with self.assertRaisesRegex(RuntimeError, "exact reviewed DNS"):
                builder.validate_tls_snapshot(
                    self.DOMAIN, b"CERTIFICATE SNAPSHOT", b"PRIVATE KEY SNAPSHOT"
                )
        self.assertFalse(any(command[1] == "verify" for command in commands))

    def test_wildcard_san_does_not_satisfy_exact_dns_contract(self):
        commands, run = self.runner(
            b"X509v3 Subject Alternative Name:\n    DNS:*.office.example.invalid\n"
        )
        with mock.patch.object(builder.subprocess, "run", side_effect=run):
            with self.assertRaisesRegex(RuntimeError, "exact reviewed DNS"):
                builder.validate_tls_snapshot(
                    self.DOMAIN, b"CERTIFICATE SNAPSHOT", b"PRIVATE KEY SNAPSHOT"
                )
        self.assertFalse(any(command[1] == "verify" for command in commands))

    def test_untrusted_or_incomplete_chain_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "OpenSSL validation"):
            self.invoke(
                b"X509v3 Subject Alternative Name:\n"
                b"    DNS:erp.office.example.invalid\n",
                verify_returncode=2,
            )

    @unittest.skipUnless(
        os.name == "posix"
        and hasattr(os, "geteuid")
        and os.geteuid() == 0
        and Path("/usr/bin/openssl").is_file(),
        "real exact-SAN/CA-chain verification runs on Linux as root",
    )
    def test_real_openssl_verifies_complete_chain_from_sealed_snapshot(self):
        def openssl(*arguments: str) -> None:
            subprocess.run(
                ["/usr/bin/openssl", *arguments],
                check=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"},
            )

        with tempfile.TemporaryDirectory(dir="/root") as directory:
            root = Path(directory)
            root_key = root / "root.key"
            root_cert = root / "root.pem"
            intermediate_key = root / "intermediate.key"
            intermediate_csr = root / "intermediate.csr"
            intermediate_cert = root / "intermediate.pem"
            intermediate_ext = root / "intermediate.ext"
            leaf_key = root / "leaf.key"
            leaf_csr = root / "leaf.csr"
            leaf_cert = root / "leaf.pem"
            leaf_ext = root / "leaf.ext"
            ca_path = root / "ca-path"
            ca_path.mkdir(mode=0o700)
            intermediate_ext.write_text(
                "basicConstraints=critical,CA:TRUE,pathlen:0\n"
                "keyUsage=critical,keyCertSign,cRLSign\n"
                "subjectKeyIdentifier=hash\n"
                "authorityKeyIdentifier=keyid:always,issuer\n",
                encoding="ascii",
            )
            leaf_ext.write_text(
                "basicConstraints=critical,CA:FALSE\n"
                "keyUsage=critical,digitalSignature,keyEncipherment\n"
                "extendedKeyUsage=serverAuth\n"
                f"subjectAltName=DNS:{self.DOMAIN}\n"
                "subjectKeyIdentifier=hash\n"
                "authorityKeyIdentifier=keyid:always,issuer\n",
                encoding="ascii",
            )
            openssl(
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-sha256",
                "-days",
                "2",
                "-subj",
                "/CN=Uten Test Root",
                "-addext",
                "basicConstraints=critical,CA:TRUE,pathlen:1",
                "-addext",
                "keyUsage=critical,keyCertSign,cRLSign",
                "-keyout",
                str(root_key),
                "-out",
                str(root_cert),
            )
            openssl(
                "req",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-sha256",
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
                "-sha256",
                "-days",
                "2",
                "-in",
                str(intermediate_csr),
                "-CA",
                str(root_cert),
                "-CAkey",
                str(root_key),
                "-CAcreateserial",
                "-extfile",
                str(intermediate_ext),
                "-out",
                str(intermediate_cert),
            )
            openssl(
                "req",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-sha256",
                "-subj",
                "/CN=CN fallback must not be authoritative",
                "-keyout",
                str(leaf_key),
                "-out",
                str(leaf_csr),
            )
            openssl(
                "x509",
                "-req",
                "-sha256",
                "-days",
                "2",
                "-in",
                str(leaf_csr),
                "-CA",
                str(intermediate_cert),
                "-CAkey",
                str(intermediate_key),
                "-CAcreateserial",
                "-extfile",
                str(leaf_ext),
                "-out",
                str(leaf_cert),
            )
            trusted_root = ca_path / "uten-test-root.pem"
            trusted_root.write_bytes(root_cert.read_bytes())
            trusted_root.chmod(0o644)
            openssl("rehash", str(ca_path))
            certificate_chain = leaf_cert.read_bytes() + intermediate_cert.read_bytes()
            with mock.patch.object(builder, "SYSTEM_CA_PATH", ca_path):
                builder.validate_tls_snapshot(
                    self.DOMAIN, certificate_chain, leaf_key.read_bytes()
                )

    @unittest.skipUnless(
        os.name == "posix" and hasattr(os, "memfd_create"),
        "sealed memfd contract runs on Linux",
    )
    def test_tls_snapshot_memfd_is_write_sealed(self):
        with builder.sealed_memory_snapshot(b"captured certificate", "test") as descriptor:
            self.assertEqual(len(b"captured certificate"), os.fstat(descriptor).st_size)
            with self.assertRaises(OSError):
                os.write(descriptor, b"tamper")


if __name__ == "__main__":
    unittest.main()
