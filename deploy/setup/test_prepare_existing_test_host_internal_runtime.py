import contextlib
import hashlib
import importlib.util
import json
import os
import pwd
import stat
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name(
    "prepare-existing-test-host-internal-runtime.py"
)
SPEC = importlib.util.spec_from_file_location(
    "prepare_existing_test_host_internal_runtime", MODULE_PATH
)
assert SPEC is not None and SPEC.loader is not None
preparer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = preparer
SPEC.loader.exec_module(preparer)


DOMAIN = "erp.office.example.invalid"
OFFICE_CIDR = "10.23.44.0/24"
APPROVAL = "CHG-INTERNAL-TEST-0001"
PREPARER_SHA256 = "a" * 64
SERVER_ENV_SHA256 = "b" * 64
STORAGE_AUTHORITY_SHA256 = "c" * 64
SERVER_ENV_PREIMAGE_SHA256 = "d" * 64
ALLOWED_SIGNERS_SHA256 = "e" * 64
UPDATER_VENV_INVENTORY_SHA256 = "f" * 64


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def utc_text(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def completed(command: list[str], stdout: bytes = b""):
    return subprocess.CompletedProcess(command, 0, stdout, b"")


class StatProxy:
    """Override selected ownership/device fields while retaining a real stat."""

    def __init__(self, original, **overrides):
        self._original = original
        self._overrides = overrides

    def __getattr__(self, name):
        if name in self._overrides:
            return self._overrides[name]
        return getattr(self._original, name)


class StrictJsonDocumentTest(unittest.TestCase):
    def test_duplicate_keys_are_rejected_at_every_depth(self):
        documents = (
            b'{"schemaVersion":1,"schemaVersion":1}',
            b'{"hostParameters":{"domain":"a","domain":"b"}}',
        )
        for raw in documents:
            with self.subTest(raw=raw):
                with self.assertRaisesRegex(
                    preparer.PreparationError, "duplicate key"
                ):
                    preparer.strict_json_document(raw, "reviewed source manifest")

    def test_non_finite_numbers_are_rejected(self):
        for token in (b"NaN", b"Infinity", b"-Infinity"):
            with self.subTest(token=token):
                raw = b'{"schemaVersion":' + token + b"}"
                with self.assertRaisesRegex(
                    preparer.PreparationError, "non-finite"
                ):
                    preparer.strict_json_document(
                        raw, "reviewed source manifest"
                    )

    def test_non_object_root_is_rejected(self):
        with self.assertRaisesRegex(preparer.PreparationError, "root"):
            preparer.strict_json_document(b"[]", "reviewed source manifest")

    def test_atomic_write_retries_partial_writes_before_publish(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "evidence.json"
            real_write = os.write
            writes: list[int] = []

            def short_write(descriptor: int, payload: bytes) -> int:
                chunk = payload[: max(1, len(payload) // 3)]
                written = real_write(descriptor, chunk)
                writes.append(written)
                return written

            with patch.object(preparer, "root_directory"), patch.object(
                preparer, "fsync_directory"
            ), patch.object(preparer.os, "chown"), patch.object(
                preparer.os, "write", side_effect=short_write
            ):
                preparer.atomic(target, b"x" * 4096, 0o600)
            self.assertEqual(b"x" * 4096, target.read_bytes())
            self.assertGreater(len(writes), 1)


class ReviewedSourceManifestTest(unittest.TestCase):
    def fixture(self, directory: str):
        root = Path(directory)
        source = root / "source.py"
        builder = root / "builder.py"
        nginx = root / "nginx.conf.example"
        server_env = root / "server.env"
        cert = root / "server.crt"
        key = root / "server.key"
        target = root / "installed.py"
        source.write_bytes(b"source-v1\n")
        builder.write_bytes(b"builder-v1\n")
        nginx.write_bytes(b"nginx-v1\n")
        server_env.write_bytes(b"environment-v1\n")
        cert.write_bytes(b"certificate-v1\n")
        key.write_bytes(b"key-v1\n")
        now = datetime.now(timezone.utc).replace(microsecond=0)
        value = {
            "approvalReference": APPROVAL,
            "builderSha256": sha256_bytes(builder.read_bytes()),
            "createdAtUtc": utc_text(now - timedelta(minutes=5)),
            "expiresAtUtc": utc_text(now + timedelta(minutes=30)),
            "hostParameters": {
                "allowedSignersSha256": ALLOWED_SIGNERS_SHA256,
                "domain": DOMAIN,
                "expectedNginxExpandedConfigSha256": "4" * 64,
                "officeCidr": OFFICE_CIDR,
                "serverEnvironmentPreimageSha256": SERVER_ENV_PREIMAGE_SHA256,
                "serverEnvironmentSha256": sha256_bytes(
                    server_env.read_bytes()
                ),
                "tlsCertificateSha256": sha256_bytes(cert.read_bytes()),
                "tlsKeySha256": sha256_bytes(key.read_bytes()),
                "updaterVenvInventorySha256": UPDATER_VENV_INVENTORY_SHA256,
            },
            "kind": "uten-imp-internal-test-reviewed-host-sources",
            "preparerSha256": PREPARER_SHA256,
            "schemaVersion": 1,
            "sourceSha256": {
                "sourceSha256": sha256_bytes(source.read_bytes()),
                "manifestBuilderSha256": sha256_bytes(builder.read_bytes()),
                "nginxTemplateSha256": sha256_bytes(nginx.read_bytes()),
            },
            "targetPreimageSha256": {
                "legacyNginxConfigSha256": None,
                "sourceSha256": None,
                "nginxConfigSha256": None,
            },
        }
        manifest = root / "reviewed.json"
        manifest.write_bytes(preparer.canonical(value))
        args = SimpleNamespace(
            approval_reference=APPROVAL,
            domain=DOMAIN,
            office_cidr=OFFICE_CIDR,
            tls_cert=cert,
            tls_key=key,
            expected_preparer_sha256=PREPARER_SHA256,
            expected_server_environment_sha256=sha256_bytes(
                server_env.read_bytes()
            ),
            expected_server_environment_preimage_sha256=SERVER_ENV_PREIMAGE_SHA256,
            expected_allowed_signers_sha256=ALLOWED_SIGNERS_SHA256,
            expected_updater_venv_inventory_sha256=UPDATER_VENV_INVENTORY_SHA256,
            source_manifest=manifest,
            expected_source_manifest_sha256=sha256_bytes(
                manifest.read_bytes()
            ),
        )
        constants = (
            patch.object(preparer, "SOURCES", {"sourceSha256": source}),
            patch.object(preparer, "TARGETS", {"sourceSha256": target}),
            patch.object(
                preparer,
                "TRUSTED_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEYS",
                frozenset(),
            ),
            patch.object(preparer, "MANIFEST_BUILDER", builder),
            patch.object(preparer, "NGINX_SOURCE", nginx),
            patch.object(preparer, "SERVER_ENV", server_env),
            patch.object(preparer, "root_file"),
            patch.object(
                preparer,
                "stable_root_digest",
                side_effect=lambda path, **_kwargs: sha256_bytes(Path(path).read_bytes()),
            ),
        )
        return value, manifest, args, constants

    def invoke(self, manifest: Path, args, constants):
        args.expected_source_manifest_sha256 = sha256_bytes(
            manifest.read_bytes()
        )
        with contextlib.ExitStack() as stack:
            for item in constants:
                stack.enter_context(item)
            return preparer.reviewed_source_manifest(args)

    def test_exact_fresh_manifest_and_host_parameters_are_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            value, manifest, args, constants = self.fixture(directory)
            reviewed, digest = self.invoke(manifest, args, constants)
        self.assertEqual(value, reviewed)
        self.assertEqual(sha256_bytes(preparer.canonical(value)), digest)

    def test_expired_or_excessively_long_authorization_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            value, manifest, args, constants = self.fixture(directory)
            now = datetime.now(timezone.utc).replace(microsecond=0)
            cases = (
                (
                    utc_text(now - timedelta(hours=2)),
                    utc_text(now - timedelta(hours=1)),
                ),
                (
                    utc_text(now - timedelta(minutes=1)),
                    utc_text(now + timedelta(days=8)),
                ),
            )
            for created, expires in cases:
                with self.subTest(created=created, expires=expires):
                    value["createdAtUtc"] = created
                    value["expiresAtUtc"] = expires
                    manifest.write_bytes(preparer.canonical(value))
                    with self.assertRaisesRegex(
                        preparer.PreparationError,
                        "expired|chronology|expiry|fresh",
                    ):
                        self.invoke(manifest, args, constants)

    def test_each_runtime_host_parameter_is_semantically_bound(self):
        replacements = {
            "allowedSignersSha256": "1" * 64,
            "domain": "other.office.example.invalid",
            "officeCidr": "10.23.45.0/24",
            "serverEnvironmentPreimageSha256": "2" * 64,
            "serverEnvironmentSha256": "d" * 64,
            "tlsCertificateSha256": "e" * 64,
            "tlsKeySha256": "f" * 64,
            "updaterVenvInventorySha256": "3" * 64,
        }
        for key, replacement in replacements.items():
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                value, manifest, args, constants = self.fixture(directory)
                value["hostParameters"][key] = replacement
                manifest.write_bytes(preparer.canonical(value))
                with self.assertRaisesRegex(
                    preparer.PreparationError, "host|parameter|authorize|differs"
                ):
                    self.invoke(manifest, args, constants)

    def test_duplicate_and_non_finite_manifest_tokens_are_rejected(self):
        invalid_documents = (
            b'{"schemaVersion":1,"schemaVersion":1}',
            b'{"schemaVersion":NaN}',
        )
        for raw in invalid_documents:
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as directory:
                _value, manifest, args, constants = self.fixture(directory)
                manifest.write_bytes(raw)
                with self.assertRaises(preparer.PreparationError):
                    self.invoke(manifest, args, constants)


class NginxUniquenessTest(unittest.TestCase):
    def test_prospective_graph_rejects_a_rogue_include_before_nginx_or_live_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            confd = root / "conf.d"
            enabled = root / "sites-enabled"
            confd.mkdir()
            enabled.mkdir()
            rogue = confd / "rogue.conf"
            rogue.write_text("server { listen 9443 ssl; }\n", encoding="utf-8")
            legacy = confd / "uten-imp.conf"
            link = enabled / "uten-imp-internal-test.conf"
            main = (
                b"http {\n"
                b"  include /etc/nginx/conf.d/*.conf;\n"
                b"  include /etc/nginx/sites-enabled/*;\n"
                b"}\n"
            )
            real_path = preparer.Path

            def mapped_path(value):
                path = real_path(value)
                mapping = {
                    real_path("/etc/nginx/nginx.conf"): root / "nginx.conf",
                    real_path("/etc/nginx/conf.d"): confd,
                    real_path("/etc/nginx/sites-enabled"): enabled,
                }
                return mapping.get(path, path)

            real_temporary_directory = tempfile.TemporaryDirectory

            def preview_directory(*, prefix, dir):
                self.assertEqual("/run", dir)
                return real_temporary_directory(prefix=prefix, dir=directory)

            with patch.object(preparer, "Path", side_effect=mapped_path), patch.object(
                preparer, "NGINX_LINK", link
            ), patch.object(
                preparer, "LEGACY_NGINX_TARGET", legacy
            ), patch.object(
                preparer, "stable_root_bytes", return_value=main
            ), patch.object(
                preparer, "root_directory"
            ), patch.object(
                preparer.os, "chown"
            ), patch.object(
                preparer.tempfile,
                "TemporaryDirectory",
                side_effect=preview_directory,
            ), patch.object(preparer, "run") as runner:
                with self.assertRaisesRegex(
                    preparer.PreparationError, "unreviewed Nginx include"
                ):
                    preparer.prospective_nginx_expanded(
                        DOMAIN,
                        OFFICE_CIDR,
                        Path("/etc/uten-imp/tls/internal-fullchain.pem"),
                        Path("/etc/uten-imp/tls/internal-privkey.pem"),
                        b"server { listen 443 ssl; }\n",
                    )
            runner.assert_not_called()
            self.assertEqual(
                "server { listen 9443 ssl; }\n",
                rogue.read_text(encoding="utf-8"),
            )

    def test_direct_loopback_backend_alias_in_another_include_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            confd = root / "conf.d"
            enabled = root / "sites-enabled"
            available = root / "sites-available"
            confd.mkdir()
            enabled.mkdir()
            available.mkdir()
            target = available / "uten-imp-internal-test.conf"
            target.write_text(
                "upstream uten_imp_internal_test_backend {\n"
                "    server 127.0.0.1:8080;\n}\n"
                "server { listen 127.0.0.1:8081; }\n",
                encoding="utf-8",
            )
            link = enabled / "uten-imp-internal-test.conf"
            link.symlink_to(target)
            bypass = confd / "innocent-name.conf"
            bypass.write_text(
                "server { listen 0.0.0.0:8099; proxy_pass http://127.0.0.1:8080; }\n",
                encoding="utf-8",
            )
            real_path = preparer.Path
            real_lstat = type(target).lstat

            def root_owned_lstat(path):
                details = real_lstat(path)
                return SimpleNamespace(
                    st_mode=details.st_mode,
                    st_uid=0,
                    st_gid=0,
                    st_nlink=details.st_nlink,
                    st_dev=details.st_dev,
                    st_ino=details.st_ino,
                    st_size=details.st_size,
                    st_mtime_ns=details.st_mtime_ns,
                    st_ctime_ns=details.st_ctime_ns,
                )

            def mapped_path(value):
                path = real_path(value)
                if path == real_path("/etc/nginx/conf.d"):
                    return confd
                if path == real_path("/etc/nginx/sites-enabled"):
                    return enabled
                return path

            with patch.object(preparer, "NGINX_TARGET", target), patch.object(
                preparer, "NGINX_LINK", link
            ), patch.object(preparer, "Path", side_effect=mapped_path), patch.object(
                preparer, "root_file"
            ), patch.object(
                type(target), "lstat", root_owned_lstat
            ):
                with self.assertRaisesRegex(
                    preparer.PreparationError, "unreviewed Nginx include|forwarding boundary"
                ):
                    preparer.unique_nginx_include()


class SystemdProspectiveContractTest(unittest.TestCase):
    def test_complete_reviewed_graph_is_accepted_by_the_local_systemd_parser(self):
        if not Path("/usr/bin/systemd-analyze").is_file():
            self.skipTest("systemd-analyze is unavailable on this platform")
        keys = set(preparer.SYSTEMD_UNIT_SOURCE_KEYS) | set(
            preparer.SYSTEMD_DROPIN_SOURCE_KEYS
        )
        source_hashes = {
            key: sha256_bytes(preparer.SOURCES[key].read_bytes()) for key in keys
        }
        real_temporary_directory = tempfile.TemporaryDirectory

        def preview_directory(*, prefix, dir):
            self.assertEqual("/run", dir)
            return real_temporary_directory(prefix=prefix, dir="/tmp")

        with patch.object(
            preparer,
            "stable_root_bytes",
            side_effect=lambda path, **_kwargs: path.read_bytes(),
        ), patch.object(
            preparer.tempfile,
            "TemporaryDirectory",
            side_effect=preview_directory,
        ), patch.object(
            preparer.os, "chown"
        ):
            preparer.prospective_systemd_verify({"sourceSha256": source_hashes})

    def test_target_systemd_parses_the_exact_reviewed_unit_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "candidate.service.example"
            source.write_bytes(b"[Unit]\nDescription=Candidate\n[Service]\nType=oneshot\nExecStart=/bin/true\n")
            digest = sha256_bytes(source.read_bytes())
            real_temporary_directory = tempfile.TemporaryDirectory

            def preview_directory(*, prefix, dir):
                self.assertEqual("/run", dir)
                return real_temporary_directory(prefix=prefix, dir=directory)

            with patch.object(
                preparer, "SYSTEMD_UNIT_SOURCE_KEYS", {"unitSha256": "candidate.service"}
            ), patch.object(
                preparer, "SYSTEMD_DROPIN_SOURCE_KEYS", {}
            ), patch.object(
                preparer, "SOURCES", {"unitSha256": source}
            ), patch.object(
                preparer,
                "stable_root_bytes",
                return_value=source.read_bytes(),
            ), patch.object(
                preparer.tempfile,
                "TemporaryDirectory",
                side_effect=preview_directory,
            ), patch.object(preparer.os, "chown"), patch.object(
                preparer, "run"
            ) as runner:
                preparer.prospective_systemd_verify(
                    {"sourceSha256": {"unitSha256": digest}}
                )
            command = runner.call_args.args[0]
            self.assertEqual("/usr/bin/systemd-analyze", command[0])
            self.assertRegex(command[1], r"^--root=.+uten-imp-systemd-preview-")
            self.assertEqual("verify", command[2])
            self.assertEqual("candidate.service", Path(command[3]).name)

    def test_loaded_graph_rejects_an_unreviewed_dropin(self):
        target = Path("/etc/systemd/system/candidate.service")
        dropin = Path("/etc/systemd/system/nginx.service.d/uten-imp.conf")

        def systemd_value(unit: str, property_name: str) -> str:
            values = {
                ("candidate.service", "LoadState"): "loaded",
                ("candidate.service", "FragmentPath"): str(target),
                ("candidate.service", "DropInPaths"): "",
                ("nginx.service", "DropInPaths"): (
                    str(dropin) + " /etc/systemd/system/nginx.service.d/rogue.conf"
                ),
            }
            return values[(unit, property_name)]

        with patch.object(
            preparer,
            "SYSTEMD_UNIT_SOURCE_KEYS",
            {"unitSha256": "candidate.service"},
        ), patch.object(
            preparer,
            "SYSTEMD_DROPIN_SOURCE_KEYS",
            {"dropinSha256": "nginx.service"},
        ), patch.object(
            preparer,
            "TARGETS",
            {"unitSha256": target, "dropinSha256": dropin},
        ), patch.object(preparer, "_systemd_value", side_effect=systemd_value):
            with self.assertRaisesRegex(preparer.PreparationError, "drop-in graph"):
                preparer.validate_loaded_systemd_contract()


class InputBoundaryTest(unittest.TestCase):
    def validate(self, cidr: str):
        with patch.object(preparer, "validate_tls_material"):
            preparer.validate_inputs(
                DOMAIN, cidr, Path("/reviewed/server.crt"), Path("/reviewed/server.key")
            )

    def test_canonical_strict_rfc1918_subnets_are_accepted(self):
        for cidr in (
            "10.23.44.0/24",
            "172.20.16.0/20",
            "192.168.25.0/24",
        ):
            with self.subTest(cidr=cidr):
                self.validate(cidr)

    def test_host_bits_parent_networks_and_non_rfc1918_space_are_rejected(self):
        values = (
            "10.23.44.9/24",
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "127.0.0.0/9",
            "169.254.10.0/24",
            "100.64.0.0/16",
            "192.0.2.0/24",
            "fc00::/64",
        )
        for cidr in values:
            with self.subTest(cidr=cidr):
                with self.assertRaises(preparer.PreparationError):
                    self.validate(cidr)

    def test_domain_must_be_canonical_and_not_a_path_or_command_fragment(self):
        values = (
            "ERP.office.example.invalid",
            "erp.office.example.invalid.",
            "localhost",
            "erp.office.example.invalid/path",
            "erp.office.example.invalid;include",
        )
        with patch.object(preparer, "validate_tls_material"):
            for domain in values:
                with self.subTest(domain=domain):
                    with self.assertRaises(preparer.PreparationError):
                        preparer.validate_inputs(
                            domain,
                            OFFICE_CIDR,
                            Path("/reviewed/server.crt"),
                            Path("/reviewed/server.key"),
                        )


class TlsMaterialTest(unittest.TestCase):
    def files(self, directory: str):
        tls_root = Path(directory) / "tls"
        tls_root.mkdir(mode=0o700)
        cert = tls_root / "internal-fullchain.pem"
        key = tls_root / "internal-privkey.pem"
        cert.write_bytes(b"test certificate")
        key.write_bytes(b"test key")
        cert.chmod(0o644)
        key.chmod(0o600)
        return tls_root, cert, key

    @staticmethod
    def root_metadata(path: Path, *, mode: int | None = None):
        details = path.lstat()
        if path.is_symlink() or not stat.S_ISREG(details.st_mode):
            raise preparer.PreparationError("unsafe TLS material")
        if mode is not None and stat.S_IMODE(details.st_mode) != mode:
            raise preparer.PreparationError("unsafe TLS material mode")
        return StatProxy(details, st_uid=0, st_gid=0, st_nlink=1)

    @staticmethod
    def openssl_success(command: list[str], **_kwargs):
        if "subjectAltName" in command:
            return completed(
                command,
                (
                    "X509v3 Subject Alternative Name:\n"
                    f"    DNS:{DOMAIN}\n"
                ).encode("ascii"),
            )
        if "-pubkey" in command or "-pubout" in command:
            return completed(command, b"same-public-key\n")
        return completed(command)

    def test_fixed_direct_children_valid_san_and_matching_key_are_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            tls_root, cert, key = self.files(directory)
            with patch.object(preparer, "TLS_ROOT", tls_root), patch.object(
                preparer, "root_file", side_effect=self.root_metadata
            ), patch.object(
                preparer, "root_directory"
            ), patch.object(preparer, "run", side_effect=self.openssl_success):
                result = preparer.validate_tls_material(DOMAIN, cert, key)
        self.assertIsNot(result, False)

    def test_paths_must_be_safe_direct_children_of_fixed_tls_root(self):
        with tempfile.TemporaryDirectory() as directory:
            tls_root, cert, key = self.files(directory)
            nested = tls_root / "nested"
            nested.mkdir()
            nested_cert = nested / "server.crt"
            nested_cert.write_bytes(cert.read_bytes())
            outside = Path(directory) / "outside.key"
            outside.write_bytes(key.read_bytes())
            unsafe_name = tls_root / "bad;name.crt"
            unsafe_name.write_bytes(cert.read_bytes())
            cases = ((nested_cert, key), (cert, outside), (unsafe_name, key))
            with patch.object(preparer, "TLS_ROOT", tls_root), patch.object(
                preparer, "root_file", side_effect=self.root_metadata
            ), patch.object(
                preparer, "root_directory"
            ), patch.object(preparer, "run", side_effect=self.openssl_success):
                for candidate_cert, candidate_key in cases:
                    with self.subTest(cert=candidate_cert, key=candidate_key):
                        with self.assertRaises(preparer.PreparationError):
                            preparer.validate_tls_material(
                                DOMAIN, candidate_cert, candidate_key
                            )

    def test_symlink_or_wrong_private_key_mode_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            tls_root, cert, key = self.files(directory)
            link = tls_root / "linked-key.pem"
            link.symlink_to(key)
            with patch.object(preparer, "TLS_ROOT", tls_root), patch.object(
                preparer, "root_file", side_effect=self.root_metadata
            ), patch.object(
                preparer, "root_directory"
            ), patch.object(preparer, "run", side_effect=self.openssl_success):
                with self.assertRaises(preparer.PreparationError):
                    preparer.validate_tls_material(DOMAIN, cert, link)
                key.chmod(0o644)
                with self.assertRaises(preparer.PreparationError):
                    preparer.validate_tls_material(DOMAIN, cert, key)

    def test_san_mismatch_and_public_key_mismatch_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            tls_root, cert, key = self.files(directory)

            def san_mismatch(command: list[str], **kwargs):
                if "subjectAltName" in command:
                    return completed(
                        command,
                        b"X509v3 Subject Alternative Name:\n    DNS:other.example.invalid\n",
                    )
                return self.openssl_success(command, **kwargs)

            def key_mismatch(command: list[str], **_kwargs):
                if "-pubkey" in command:
                    return completed(command, b"certificate-public-key\n")
                if "-pubout" in command:
                    return completed(command, b"private-public-key\n")
                return completed(command)

            def chain_mismatch(command: list[str], **kwargs):
                if len(command) > 1 and command[1] == "verify":
                    raise preparer.PreparationError("certificate chain mismatch")
                return self.openssl_success(command, **kwargs)

            for runner in (san_mismatch, chain_mismatch, key_mismatch):
                with self.subTest(runner=runner.__name__), patch.object(
                    preparer, "TLS_ROOT", tls_root
                ), patch.object(
                    preparer, "root_file", side_effect=self.root_metadata
                ), patch.object(
                    preparer, "root_directory"
                ), patch.object(preparer, "run", side_effect=runner):
                    with self.assertRaises(preparer.PreparationError):
                        preparer.validate_tls_material(DOMAIN, cert, key)


class ServerEnvironmentBindingTest(unittest.TestCase):
    @staticmethod
    def environment(
        *,
        profile: str = "internal-test",
        cidrs: str = f"127.0.0.0/8,{OFFICE_CIDR}",
        cors: str = f"https://{DOMAIN}",
    ) -> bytes:
        return (
            "# root-managed canonical data\n"
            f"UTEN_PROFILE={profile}\n"
            "UTEN_DEPLOYMENT_SITE=local\n"
            f"UTEN_LOCAL_ALLOWED_CIDRS={cidrs}\n"
            f"UTEN_CORS_ORIGINS={cors}\n"
            "SERVER_ADDRESS=127.0.0.1\n"
        ).encode("utf-8")

    def invoke(self, path: Path, expected_sha: str):
        with patch.object(preparer, "SERVER_ENV", path), patch.object(
            preparer, "root_file"
        ):
            return preparer.validate_server_environment(
                DOMAIN, OFFICE_CIDR, expected_sha
            )

    def test_profile_exact_cidr_pair_and_exact_https_origin_are_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "server.env"
            raw = self.environment()
            path.write_bytes(raw)
            result = self.invoke(path, sha256_bytes(raw))
        self.assertIsNot(result, False)

    def test_out_of_band_environment_digest_is_mandatory(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "server.env"
            path.write_bytes(self.environment())
            with self.assertRaisesRegex(
                preparer.PreparationError, "digest|sha|differs"
            ):
                self.invoke(path, "0" * 64)

    def test_profile_cidr_and_cors_cannot_drift_from_reviewed_host(self):
        cases = (
            self.environment(profile="prod"),
            self.environment(cidrs=OFFICE_CIDR),
            self.environment(cidrs=f"{OFFICE_CIDR},127.0.0.0/8"),
            self.environment(
                cidrs=f"127.0.0.0/8,{OFFICE_CIDR},::1/128"
            ),
            self.environment(cors="https://other.office.example.invalid"),
            self.environment(cors=f"https://{DOMAIN}/path"),
            self.environment(cors=f"https://{DOMAIN},https://other.invalid"),
        )
        for raw in cases:
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "server.env"
                path.write_bytes(raw)
                with self.assertRaises(preparer.PreparationError):
                    self.invoke(path, sha256_bytes(raw))

    def test_duplicate_bound_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "server.env"
            raw = self.environment() + b"UTEN_PROFILE=internal-test\n"
            path.write_bytes(raw)
            with self.assertRaises(preparer.PreparationError):
                self.invoke(path, sha256_bytes(raw))


class SourceSnapshotTest(unittest.TestCase):
    def fixture(self, directory: str):
        root = Path(directory)
        transaction = root / "transaction"
        transaction.mkdir(mode=0o700)
        source = root / "source.py"
        builder = root / "builder.py"
        nginx = root / "nginx.conf"
        source.write_bytes(b"reviewed source\n")
        builder.write_bytes(b"reviewed builder\n")
        nginx.write_bytes(b"reviewed nginx\n")
        reviewed = {
            "sourceSha256": {
                "sourceSha256": sha256_bytes(source.read_bytes()),
                "manifestBuilderSha256": sha256_bytes(builder.read_bytes()),
                "nginxTemplateSha256": sha256_bytes(nginx.read_bytes()),
            }
        }
        return root, transaction, source, builder, nginx, reviewed

    @staticmethod
    def root_owned_fstat(real_fstat):
        def invoke(descriptor):
            details = real_fstat(descriptor)
            return StatProxy(details, st_uid=0, st_gid=0, st_nlink=1)

        return invoke

    def common_patches(self, source: Path, builder: Path, nginx: Path):
        return (
            patch.object(preparer, "SOURCES", {"sourceSha256": source}),
            patch.object(preparer, "MANIFEST_BUILDER", builder),
            patch.object(preparer, "NGINX_SOURCE", nginx),
            patch.object(preparer, "root_directory"),
            patch.object(preparer, "root_file"),
            patch.object(preparer, "fsync_directory"),
            patch.object(preparer.os, "chown"),
        )

    def test_source_is_opened_with_no_follow_and_snapshotted_by_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            _root, transaction, source, builder, nginx, reviewed = self.fixture(directory)
            real_open = os.open
            real_fstat = os.fstat
            observed_source_flags: list[int] = []

            def recording_open(path, flags, *args, **kwargs):
                if Path(path) in {source, builder, nginx}:
                    observed_source_flags.append(flags)
                return real_open(path, flags, *args, **kwargs)

            with contextlib.ExitStack() as stack:
                for item in self.common_patches(source, builder, nginx):
                    stack.enter_context(item)
                stack.enter_context(
                    patch.object(preparer.os, "open", side_effect=recording_open)
                )
                stack.enter_context(
                    patch.object(
                        preparer.os,
                        "fstat",
                        side_effect=self.root_owned_fstat(real_fstat),
                    )
                )
                result = preparer.snapshot_sources(transaction, reviewed)

            self.assertEqual(
                source.read_bytes(), result["sourceSha256"].read_bytes()
            )
            self.assertEqual(
                builder.read_bytes(), result["manifestBuilderSha256"].read_bytes()
            )
            self.assertEqual(
                nginx.read_bytes(), result["nginxTemplateSha256"].read_bytes()
            )
            self.assertEqual(3, len(observed_source_flags))
            self.assertTrue(
                all(flags & os.O_NOFOLLOW for flags in observed_source_flags)
            )

    def test_symlink_source_is_refused_without_creating_a_snapshot_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root, transaction, source, builder, nginx, reviewed = self.fixture(directory)
            real = root / "real-source.py"
            real.write_bytes(source.read_bytes())
            source.unlink()
            source.symlink_to(real)
            with contextlib.ExitStack() as stack:
                for item in self.common_patches(source, builder, nginx):
                    stack.enter_context(item)
                with self.assertRaises(preparer.PreparationError):
                    preparer.snapshot_sources(transaction, reviewed)
            self.assertFalse(
                (transaction / "source-snapshot" / "sourceSha256").exists()
            )

    def test_metadata_drift_between_open_and_publish_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            _root, transaction, source, builder, nginx, reviewed = self.fixture(directory)
            real_fstat = os.fstat
            calls: dict[int, int] = {}

            def drifting_fstat(descriptor):
                details = real_fstat(descriptor)
                calls[descriptor] = calls.get(descriptor, 0) + 1
                ctime = details.st_ctime_ns
                if calls[descriptor] == 2:
                    ctime += 1
                return StatProxy(
                    details,
                    st_uid=0,
                    st_gid=0,
                    st_nlink=1,
                    st_ctime_ns=ctime,
                )

            with contextlib.ExitStack() as stack:
                for item in self.common_patches(source, builder, nginx):
                    stack.enter_context(item)
                stack.enter_context(
                    patch.object(preparer.os, "fstat", side_effect=drifting_fstat)
                )
                with self.assertRaisesRegex(
                    preparer.PreparationError, "changed|drift|stable"
                ):
                    preparer.snapshot_sources(transaction, reviewed)
            self.assertFalse(
                (transaction / "source-snapshot" / "sourceSha256").exists()
            )


class AttachmentLayoutTest(unittest.TestCase):
    APP_UID = 1201
    APP_GID = 1202

    def fixture(self, directory: str):
        root = Path(directory)
        data = root / "data"
        application = data / "uten-imp"
        attachments = application / "attachments"
        transaction = root / "transaction"
        data.mkdir(mode=0o755)
        transaction.mkdir(mode=0o700)
        authority = root / "storage-authority.json"
        authority.write_bytes(b"fixed authority\n")
        authority.chmod(0o640)
        return root, data, application, attachments, transaction, authority

    def metadata_patch(self, data: Path, attachments: Path, *, other_dev=None):
        real_lstat = os.lstat
        real_stat = os.stat
        application = attachments.parent
        transaction_parent = data.parent

        def ownership(path: Path):
            if path in {attachments / "staging", attachments / "final"}:
                return self.APP_UID, self.APP_GID
            if path == attachments:
                return 0, self.APP_GID
            return 0, 0

        def overrides(path, details):
            candidate = Path(path)
            uid, gid = ownership(candidate)
            device = details.st_dev
            if other_dev is not None and candidate == other_dev:
                device += 1
            return StatProxy(
                details, st_uid=uid, st_gid=gid, st_nlink=1, st_dev=device
            )

        def fake_lstat(path, *args, **kwargs):
            return overrides(path, real_lstat(path, *args, **kwargs))

        def fake_stat(path, *args, **kwargs):
            return overrides(path, real_stat(path, *args, **kwargs))

        return patch.object(preparer.os, "lstat", side_effect=fake_lstat), patch.object(
            preparer.os, "stat", side_effect=fake_stat
        )

    def runtime_patches(
        self,
        data: Path,
        attachments: Path,
        authority: Path,
        *,
        other_dev=None,
    ):
        patches = [
            patch.object(preparer, "ATTACHMENT_ROOT", attachments),
            patch.object(preparer, "STORAGE_AUTHORITY", authority),
            patch.object(preparer, "root_file"),
            patch.object(preparer.os, "chown"),
            patch.object(preparer, "fsync_directory"),
            patch.object(
                preparer.grp,
                "getgrnam",
                return_value=SimpleNamespace(gr_gid=self.APP_GID),
            ),
            patch.object(
                preparer,
                "run",
                return_value=completed(
                    [str(preparer.STORAGE_BOOT_VERIFIER)], b'{"status":"PASS"}\n'
                ),
            ),
            patch.object(
                pwd,
                "getpwnam",
                return_value=SimpleNamespace(
                    pw_uid=self.APP_UID, pw_gid=self.APP_GID
                ),
            ),
        ]
        if hasattr(preparer, "DATA_ROOT"):
            patches.append(
                patch.object(preparer, "DATA_ROOT", data)
            )
        else:
            real_path = Path
            patches.append(
                patch.object(
                    preparer,
                    "Path",
                    side_effect=lambda value: data
                    if value == "/data"
                    else real_path(value),
                )
            )
        patches.extend(self.metadata_patch(data, attachments, other_dev=other_dev))
        return patches

    def test_empty_or_exact_preexisting_layout_can_be_adopted_once(self):
        with tempfile.TemporaryDirectory() as directory:
            _root, data, _application, attachments, transaction, authority = (
                self.fixture(directory)
            )
            authority_sha = sha256_bytes(authority.read_bytes())
            with contextlib.ExitStack() as stack:
                for item in self.runtime_patches(data, attachments, authority):
                    stack.enter_context(item)
                receipt = preparer.ensure_attachment_layout(
                    transaction, authority_sha
                )
                resumed = preparer.ensure_attachment_layout(
                    transaction, authority_sha
                )
            self.assertEqual(receipt, resumed)
            self.assertEqual(authority_sha, receipt["storageAuthoritySha256"])
            self.assertRegex(receipt["layoutSha256"], r"^[0-9a-f]{64}$")
            receipt_path = Path(receipt["receiptPath"])
            self.assertTrue(receipt_path.is_file())
            self.assertEqual(
                sha256_bytes(receipt_path.read_bytes()), receipt["receiptSha256"]
            )

    def test_wrong_existing_preimage_is_refused_without_repairing_it(self):
        with tempfile.TemporaryDirectory() as directory:
            _root, data, application, attachments, transaction, authority = (
                self.fixture(directory)
            )
            application.mkdir(mode=0o700)
            marker = application / "retain-me"
            marker.write_text("preexisting", encoding="ascii")
            with contextlib.ExitStack() as stack:
                for item in self.runtime_patches(data, attachments, authority):
                    stack.enter_context(item)
                with self.assertRaises(preparer.PreparationError):
                    preparer.ensure_attachment_layout(
                        transaction, sha256_bytes(authority.read_bytes())
                    )
            self.assertEqual(0o700, stat.S_IMODE(application.lstat().st_mode))
            self.assertEqual("preexisting", marker.read_text(encoding="ascii"))
            self.assertFalse(attachments.exists())

    def test_unknown_attachment_content_is_rejected_before_creating_children(self):
        with tempfile.TemporaryDirectory() as directory:
            _root, data, application, attachments, transaction, authority = (
                self.fixture(directory)
            )
            application.mkdir(mode=0o755)
            attachments.mkdir(mode=0o750)
            marker = attachments / "unreviewed-object"
            marker.write_text("retain exactly", encoding="ascii")
            with contextlib.ExitStack() as stack:
                for item in self.runtime_patches(data, attachments, authority):
                    stack.enter_context(item)
                with self.assertRaisesRegex(
                    preparer.PreparationError, "content|preimage|unapproved"
                ):
                    preparer.ensure_attachment_layout(
                        transaction, sha256_bytes(authority.read_bytes())
                    )
            self.assertEqual("retain exactly", marker.read_text(encoding="ascii"))
            self.assertFalse((attachments / "staging").exists())
            self.assertFalse((attachments / "final").exists())
            self.assertFalse((transaction / "attachment-layout.json").exists())

    def test_storage_authority_digest_mismatch_precedes_layout_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            _root, data, application, attachments, transaction, authority = (
                self.fixture(directory)
            )
            with contextlib.ExitStack() as stack:
                for item in self.runtime_patches(data, attachments, authority):
                    stack.enter_context(item)
                with self.assertRaisesRegex(
                    preparer.PreparationError, "authority|storage"
                ):
                    preparer.ensure_attachment_layout(transaction, "0" * 64)
            self.assertFalse(application.exists())
            self.assertFalse(attachments.exists())

    def test_symlink_is_refused_and_its_target_is_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root, data, application, attachments, transaction, authority = (
                self.fixture(directory)
            )
            application.mkdir(mode=0o755)
            outside = root / "outside"
            outside.mkdir()
            marker = outside / "retain-me"
            marker.write_text("outside", encoding="ascii")
            attachments.symlink_to(outside, target_is_directory=True)
            with contextlib.ExitStack() as stack:
                for item in self.runtime_patches(data, attachments, authority):
                    stack.enter_context(item)
                with self.assertRaises(preparer.PreparationError):
                    preparer.ensure_attachment_layout(
                        transaction, sha256_bytes(authority.read_bytes())
                    )
            self.assertTrue(attachments.is_symlink())
            self.assertEqual("outside", marker.read_text(encoding="ascii"))

    def test_cross_device_child_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            _root, data, application, attachments, transaction, authority = (
                self.fixture(directory)
            )
            application.mkdir(mode=0o755)
            attachments.mkdir(mode=0o750)
            staging = attachments / "staging"
            final = attachments / "final"
            staging.mkdir(mode=0o750)
            final.mkdir(mode=0o750)
            with contextlib.ExitStack() as stack:
                for item in self.runtime_patches(
                    data, attachments, authority, other_dev=final
                ):
                    stack.enter_context(item)
                with self.assertRaises(preparer.PreparationError):
                    preparer.ensure_attachment_layout(
                        transaction, sha256_bytes(authority.read_bytes())
                    )


class PreparationLockTest(unittest.TestCase):
    def test_apply_completes_two_read_only_preflights_before_mutation(self):
        args = SimpleNamespace()
        receipt = {"status": "COMMITTED_ENTRY_CLOSED"}
        with patch.object(preparer, "read_only_preflight") as preflight, patch.object(
            preparer, "operation_lock", return_value=contextlib.nullcontext()
        ), patch.object(
            preparer, "_apply_locked", return_value=receipt
        ) as apply_locked, patch.object(
            preparer,
            "preparation_lock",
            side_effect=AssertionError("obsolete creating lock must not be used"),
        ):
            self.assertEqual(receipt, preparer.apply(args))
        self.assertEqual([((args,), {}), ((args,), {})], preflight.call_args_list)
        apply_locked.assert_called_once_with(args)

    def test_lock_is_global_nonblocking_and_reacquirable_after_release(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "preparation.lock"
            lock.write_bytes(b"")
            lock.chmod(0o600)
            real_fstat = os.fstat

            def root_owned_fstat(descriptor):
                details = real_fstat(descriptor)
                return StatProxy(
                    details, st_uid=0, st_gid=0, st_nlink=1
                )

            with patch.object(preparer, "LOCK_FILE", lock), patch.object(
                preparer.os, "fchown"
            ), patch.object(preparer, "root_directory"), patch.object(
                preparer.os, "fstat", side_effect=root_owned_fstat
            ):
                with preparer.preparation_lock():
                    with self.assertRaisesRegex(
                        preparer.PreparationError, "lock|running|active|concurrent"
                    ):
                        with preparer.preparation_lock():
                            self.fail("a second preparer acquired the global lock")
                with preparer.preparation_lock():
                    self.assertTrue(lock.is_file())

    def test_lock_path_symlink_is_never_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text("retain", encoding="ascii")
            lock = root / "preparation.lock"
            lock.symlink_to(target)
            with patch.object(preparer, "LOCK_FILE", lock), patch.object(
                preparer.os, "chown"
            ), patch.object(preparer, "root_directory"):
                with self.assertRaises(preparer.PreparationError):
                    with preparer.preparation_lock():
                        self.fail("a symlink was accepted as the global lock")
            self.assertEqual("retain", target.read_text(encoding="ascii"))


class MutationAuthorityDurabilityTest(unittest.TestCase):
    def fixture(self, directory: str):
        evidence = Path(directory) / "evidence"
        transaction = evidence / "prepare-internal-runtime-0123456789abcdef"
        transaction.mkdir(parents=True, mode=0o700)
        plan = transaction / "plan.json"
        plan.write_bytes(b"reviewed-plan\n")
        reviewed = transaction / "reviewed-source-manifest.json"
        reviewed.write_bytes(
            preparer.canonical(
                {
                    "approvalReference": "CHG-2026-0812-INTERNAL",
                    "builderSha256": "d" * 64,
                    "createdAtUtc": "2026-08-12T11:00:00Z",
                    "expiresAtUtc": "2026-08-13T11:00:00Z",
                    "hostParameters": {},
                    "kind": "uten-imp-internal-test-reviewed-host-sources",
                    "preparerSha256": "c" * 64,
                    "schemaVersion": 1,
                    "sourceSha256": {"manifestBuilderSha256": "d" * 64},
                    "targetPreimageSha256": {},
                }
            )
        )
        reviewed_sha = sha256_bytes(reviewed.read_bytes())
        active = evidence / "mutation-active.json"
        value = {
            "authorizedAtUtc": "2026-08-12T12:00:00Z",
            "kind": "uten-imp-internal-test-host-mutation-authority",
            "planPath": str(plan),
            "planSha256": sha256_bytes(plan.read_bytes()),
            "reviewedSourceManifestSha256": reviewed_sha,
            "schemaVersion": 1,
            "snapshotInventorySha256": "b" * 64,
            "status": "MUTATION_AUTHORIZED_ENTRY_CLOSED",
            "transactionId": transaction.name,
        }
        active.write_bytes(preparer.canonical(value))
        return evidence, transaction, active, value, reviewed_sha

    def test_commit_is_one_same_filesystem_rename_and_preserves_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, transaction, active, value, reviewed_sha = self.fixture(directory)
            before = active.read_bytes()
            with patch.object(preparer, "EVIDENCE", evidence), patch.object(
                preparer, "MUTATION_ACTIVE", active
            ), patch.object(preparer, "root_file"), patch.object(
                preparer, "fsync_directory"
            ) as fsync:
                result = preparer.commit_host_mutation_authority(
                    transaction, reviewed_sha
                )
                # Repeating after a crash at either directory fsync boundary
                # adopts the fixed committed pathname without rewriting it.
                repeated = preparer.commit_host_mutation_authority(
                    transaction, reviewed_sha
                )
            committed = transaction / "mutation-authorized.committed.json"
            self.assertFalse(active.exists())
            self.assertEqual(before, committed.read_bytes())
            self.assertEqual(value, result)
            self.assertEqual(value, repeated)
            self.assertEqual(
                "MUTATION_AUTHORIZED_ENTRY_CLOSED",
                json.loads(committed.read_bytes())["status"],
            )
            self.assertGreaterEqual(fsync.call_count, 2)

    def test_live_and_committed_names_coexisting_are_refused_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, transaction, active, _value, reviewed_sha = self.fixture(directory)
            committed = transaction / "mutation-authorized.committed.json"
            committed.write_bytes(active.read_bytes())
            live_before = active.read_bytes()
            committed_before = committed.read_bytes()
            with patch.object(preparer, "EVIDENCE", evidence), patch.object(
                preparer, "MUTATION_ACTIVE", active
            ):
                with self.assertRaisesRegex(
                    preparer.PreparationError, "coexist"
                ):
                    preparer.read_mutation_authority(transaction.name, reviewed_sha)
            self.assertEqual(live_before, active.read_bytes())
            self.assertEqual(committed_before, committed.read_bytes())


class CommonUpdaterSubstrateTest(unittest.TestCase):
    def fixture(self, directory: str):
        root = Path(directory)
        updater = root / "updater"
        (updater / "venv/bin").mkdir(parents=True)
        python = updater / "venv/bin/python"
        python.symlink_to("/usr/bin/python3")
        allowed = root / "updater-allowed-signers"
        stable = root / "stable-allowed-signers"
        signer = b"uten-imp-release ssh-ed25519 AAAA\n"
        allowed.write_bytes(signer)
        stable.write_bytes(signer)
        oss_env = root / "oss-pull.env"
        oss_env.write_bytes(b"UTEN_OSS_ENDPOINT=https://example.invalid\n")
        state = root / "state"
        state.mkdir()
        operation_lock = root / "operation.lock"
        operation_lock.write_bytes(b"")
        return updater, python, allowed, stable, oss_env, state, operation_lock

    def test_trust_and_virtualenv_prerequisites_are_bound_before_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            updater, python, allowed, stable, oss_env, state, operation_lock = (
                self.fixture(directory)
            )
            real_lstat = Path.lstat

            def root_python_lstat(path: Path):
                details = real_lstat(path)
                if path == python:
                    return StatProxy(details, st_uid=0)
                return details

            with patch.object(preparer, "UPDATER_ROOT", updater), patch.object(
                preparer, "UPDATER_VENV_PYTHON", python
            ), patch.object(
                preparer, "UPDATER_ALLOWED_SIGNERS", allowed
            ), patch.object(
                preparer, "STABLE_ALLOWED_SIGNERS", stable
            ), patch.object(
                preparer, "UPDATER_OSS_ENV", oss_env
            ), patch.object(
                preparer, "UPDATER_STATE", state
            ), patch.object(
                preparer, "OPERATION_LOCK", operation_lock
            ), patch.object(
                preparer, "_updater_identity", return_value=(1201, 1202)
            ), patch.object(preparer, "root_directory"), patch.object(
                preparer, "root_file"
            ), patch.object(preparer, "_exact_owned_path"), patch.object(
                preparer.os, "access", return_value=True
            ), patch.object(
                Path, "lstat", side_effect=root_python_lstat, autospec=True
            ), patch.object(
                preparer, "run", return_value=completed([])
            ):
                observed = preparer.validate_common_updater_prerequisites()
                stable.write_bytes(b"uten-imp-release ssh-ed25519 BBBB\n")
                with self.assertRaisesRegex(
                    preparer.PreparationError, "trust|key|signer"
                ):
                    preparer.validate_common_updater_prerequisites()
        self.assertEqual(sha256_bytes(b"uten-imp-release ssh-ed25519 AAAA\n"), observed["allowedSignersSha256"])
        self.assertRegex(observed["resolvedVenvPython"], r"^/usr/bin/python3")

    def test_terminal_substrate_requires_loaded_static_service_and_disabled_timer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transaction = root / "prepare-internal-runtime-0123456789abcdef"
            transaction.mkdir()
            keys = {
                "updaterEnvironmentValidatorSha256",
                "updaterServiceUnitSha256",
                "updaterTimerUnitSha256",
            }
            targets = {}
            sources = {}
            for key in keys:
                target = root / key
                target.write_bytes(key.encode("ascii"))
                targets[key] = target
                sources[key] = target
            prerequisite = {
                "allowedSignersSha256": "a" * 64,
                "ossEnvironmentSha256": "b" * 64,
                "resolvedVenvPython": "/usr/bin/python3.12",
                "updaterVenvInventorySha256": "c" * 64,
                "updaterGid": 1202,
                "updaterUid": 1201,
            }
            properties = {
                (preparer.UPDATER_SERVICE, "LoadState"): "loaded",
                (preparer.UPDATER_SERVICE, "FragmentPath"): str(
                    targets["updaterServiceUnitSha256"]
                ),
                (preparer.UPDATER_SERVICE, "DropInPaths"): "",
                (preparer.UPDATER_SERVICE, "ActiveState"): "inactive",
                (preparer.UPDATER_SERVICE, "User"): "uten-imp-updater",
                (preparer.UPDATER_SERVICE, "Group"): "uten-imp-updater",
                (preparer.UPDATER_SERVICE, "SupplementaryGroups"): "",
                (preparer.UPDATER_SERVICE, "UnitFileState"): "static",
                (preparer.UPDATER_TIMER, "LoadState"): "loaded",
                (preparer.UPDATER_TIMER, "FragmentPath"): str(
                    targets["updaterTimerUnitSha256"]
                ),
                (preparer.UPDATER_TIMER, "DropInPaths"): "",
                (preparer.UPDATER_TIMER, "ActiveState"): "inactive",
                (preparer.UPDATER_TIMER, "UnitFileState"): "disabled",
            }

            def atomic_write(path, payload, _mode, **_kwargs):
                path.write_bytes(payload)

            with patch.object(preparer, "SOURCES", sources), patch.object(
                preparer, "TARGETS", targets
            ), patch.object(
                preparer,
                "validate_common_updater_prerequisites",
                return_value=prerequisite,
            ), patch.object(
                preparer,
                "_systemd_value",
                side_effect=lambda unit, name: properties[(unit, name)],
            ), patch.object(preparer, "run", return_value=completed([])), patch.object(
                preparer, "atomic", side_effect=atomic_write
            ):
                receipt = preparer.validate_common_updater_substrate(
                    transaction, prerequisite
                )
                properties[(preparer.UPDATER_TIMER, "UnitFileState")] = "enabled"
                with self.assertRaisesRegex(
                    preparer.PreparationError, "enablement|privilege"
                ):
                    preparer.validate_common_updater_substrate(
                        transaction, prerequisite
                    )
                self.assertTrue(Path(receipt["path"]).is_file())
        self.assertEqual(
            "COMMITTED_ENTRY_CLOSED_STAGING_MANUAL_ONLY", receipt["status"]
        )

    def test_reviewed_inventory_covers_profile_neutral_stage_and_activation_files(self):
        required = {
            "activationEntrypointSha256",
            "recoveryEntrypointSha256",
            "updaterEntrypointSha256",
            "updaterEnvironmentValidatorSha256",
            "updaterOssIoSha256",
            "updaterServiceUnitSha256",
            "updaterTimerUnitSha256",
        }
        self.assertTrue(required.issubset(preparer.SOURCES))
        self.assertTrue(required.issubset(preparer.TARGETS))
        runbook = MODULE_PATH.with_name(
            "EXISTING_TEST_HOST_INTERNAL_TEST_ONBOARDING.zh-CN.md"
        ).read_text(encoding="utf-8")
        self.assertLess(
            runbook.index("主机运行时 prepare / resume"),
            runbook.index("标准签名候选 stage / inspect"),
        )


if __name__ == "__main__":
    unittest.main()
