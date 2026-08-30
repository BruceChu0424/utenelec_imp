from __future__ import annotations

import base64
import hashlib
import importlib.util
import io
import json
import os
import contextlib
import ast
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "deploy" / "release"))
sys.path.insert(0, str(PROJECT_ROOT / "deploy" / "updater"))
sys.path.insert(0, str(PROJECT_ROOT / "deploy" / "postgres" / "backup"))

import oss_io  # noqa: E402
import pgbackrest_health  # noqa: E402
import release_guard  # noqa: E402
import release_tools  # noqa: E402
import wheelhouse_supply_chain  # noqa: E402


class ReleaseFixture(unittest.TestCase):
    version = "v2026.08.11-1"
    commit = "0123456789abcdef0123456789abcdef01234567"
    key_id = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    flyway_checksum = -1320745395

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.payload = self.root / "payload" / self.version
        for directory in ("server", "web", "sbom"):
            (self.payload / directory).mkdir(parents=True, exist_ok=True)
        (self.payload / "web/index.html").write_text(
            '<html><head><meta name="uten-release-version" '
            'content="__UTEN_RELEASE_VERSION__"></head>'
            '<script src="flutter_bootstrap.js"></script></html>\n',
            encoding="utf-8",
        )
        sbom = json.dumps({"bomFormat": "CycloneDX", "specVersion": "1.6"}) + "\n"
        (self.payload / "sbom/backend.cdx.json").write_text(sbom, encoding="utf-8")
        (self.payload / "sbom/flutter.cdx.json").write_text(sbom, encoding="utf-8")
        (self.payload / "web/version.json").write_bytes(
            release_tools.FLUTTER_WEB_PACKAGE_METADATA_BYTES
        )
        self.updater_supply = self.payload / "sbom/updater"
        self.updater_wheelhouse = self.updater_supply / "wheelhouse"
        self.updater_wheelhouse.mkdir(parents=True)
        (self.updater_supply / "build-evidence").mkdir()
        (self.updater_supply / "updater-requirements.in").write_text(
            "# Updater runtime root.\noss2==2.19.1\n", encoding="ascii"
        )
        (self.updater_supply / "build-evidence/source-requirements.lock").write_text(
            "aliyun-python-sdk-core==2.16.0 --hash=sha256:" + "1" * 64 + "\n"
            "crcmod==1.7 --hash=sha256:" + "2" * 64 + "\n"
            "oss2==2.19.1 --hash=sha256:" + "3" * 64 + "\n",
            encoding="ascii",
        )
        (self.updater_supply / "build-evidence/build-requirements.lock").write_text(
            "setuptools==80.9.0 --hash=sha256:" + "4" * 64 + "\n"
            "wheel==0.45.1 --hash=sha256:" + "5" * 64 + "\n",
            encoding="ascii",
        )
        self.updater_builder_script = self.root / "build-wheelhouse.sh"
        self.updater_builder_script.write_text(
            "#!/usr/bin/env bash\nset -Eeuo pipefail\n", encoding="ascii"
        )
        self.updater_verifier_source = self.root / "wheelhouse_supply_chain.py"
        self.updater_verifier_source.write_text(
            "# reviewed updater verifier fixture\n", encoding="ascii"
        )
        updater_runtime = {
            "aliyun-python-sdk-core": ("2.16.0", ("cryptography", "jmespath")),
            "aliyun-python-sdk-kms": ("2.16.5", ("aliyun-python-sdk-core",)),
            "certifi": ("2026.7.22", ()),
            "cffi": ("2.1.1", ("pycparser",)),
            "charset-normalizer": ("3.4.9", ()),
            "crcmod": ("1.7", ()),
            "cryptography": ("50.0.0", ("cffi",)),
            "idna": ("3.18", ()),
            "jmespath": ("0.10.0", ()),
            "oss2": (
                "2.19.1",
                (
                    "aliyun-python-sdk-core", "aliyun-python-sdk-kms", "crcmod",
                    "pycryptodome", "requests", "six",
                ),
            ),
            "pycparser": ("3.0", ()),
            "pycryptodome": ("3.23.0", ()),
            "requests": ("2.34.2", ("certifi", "charset-normalizer", "idna", "urllib3")),
            "six": ("1.17.0", ()),
            "urllib3": ("2.7.0", ()),
        }
        updater_tags = {
            "aliyun-python-sdk-kms": "py2.py3-none-any",
            "cffi": "cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64",
            "charset-normalizer": (
                "cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64."
                "manylinux_2_28_x86_64"
            ),
            "cryptography": "cp311-abi3-manylinux_2_34_x86_64",
            "jmespath": "py2.py3-none-any",
            "pycryptodome": "cp37-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64",
            "six": "py2.py3-none-any",
        }
        for name, (version, requirements) in updater_runtime.items():
            self._write_updater_wheel(
                name, version, requirements, tag=updater_tags.get(name, "py3-none-any")
            )
        lock_rows = []
        for wheel in sorted(self.updater_wheelhouse.glob("*.whl")):
            info = wheelhouse_supply_chain.inspect_wheel(wheel)
            lock_rows.append(f"{info.name}=={info.version} --hash=sha256:{info.sha256}\n")
        (self.updater_supply / "updater-requirements.lock").write_text(
            "".join(lock_rows), encoding="ascii"
        )
        wheelhouse_supply_chain.command_generate(
            SimpleNamespace(
                requirements_input=self.updater_supply / "updater-requirements.in",
                source_lock=self.updater_supply / "build-evidence/source-requirements.lock",
                build_lock=self.updater_supply / "build-evidence/build-requirements.lock",
                builder_script=self.updater_builder_script,
                verifier_source=self.updater_verifier_source,
                lock=self.updater_supply / "updater-requirements.lock",
                wheelhouse=self.updater_wheelhouse,
                sums=self.updater_supply / "updater-wheelhouse.SHA256SUMS",
                sbom=self.updater_supply / "updater-wheelhouse.cdx.json",
                attestation=self.updater_supply / "updater-wheelhouse.attestation.json",
                commit=self.commit,
                timestamp="2026-08-11T08:00:00Z",
                builder_image=(
                    "python:3.12.11-slim-bookworm@sha256:"
                    "519591d6871b7bc437060736b9f7456b8731f1499a57e22e6c285135ae657bf7"
                ),
            )
        )
        release_tools.stamp_web_release(
            SimpleNamespace(
                commit=self.commit,
                version=self.version,
                web_root=self.payload / "web",
            )
        )
        self.migrations = self.root / "migrations"
        self.migrations.mkdir()
        (self.migrations / "V1__initial_schema.sql").write_text(
            "create table fixture(id integer);\n", encoding="utf-8"
        )
        self.flyway_checksums = self.root / "flyway-checksums.tsv"
        self.flyway_checksums.write_text(
            f"{release_tools.FLYWAY_CHECKSUM_HEADER}\n"
            f"1\tV1__initial_schema.sql\t{self.flyway_checksum}\n",
            encoding="utf-8",
        )
        with zipfile.ZipFile(
            self.payload / "server/uten-imp-server.jar", "w", zipfile.ZIP_DEFLATED
        ) as jar:
            jar.write(
                self.migrations / "V1__initial_schema.sql",
                "BOOT-INF/classes/db/migration/V1__initial_schema.sql",
            )
        with zipfile.ZipFile(
            self.payload / "server/uten-imp-migrator.jar", "w", zipfile.ZIP_DEFLATED
        ) as jar:
            jar.writestr(
                "META-INF/MANIFEST.MF",
                "Manifest-Version: 1.0\r\n"
                "Main-Class: com.uten.imp.migration.UtenImpMigrator\r\n\r\n",
            )
            jar.write(
                self.migrations / "V1__initial_schema.sql",
                "db/migration/V1__initial_schema.sql",
            )
            for application_class in (
                "com/uten/imp/migration/UtenImpMigrator.class",
                "com/uten/imp/migration/UtenImpMigrator$1.class",
                "com/uten/imp/migration/UtenImpMigrator$MigrationActions.class",
                "com/uten/imp/migration/UtenImpMigrator$MigrationActionsFactory.class",
                "com/uten/imp/migration/AppliedMigrationCompatibilityCallback.class",
                "com/uten/imp/migration/AuditFreshStartGuardCallback.class",
            ):
                jar.writestr(application_class, b"fixture-bytecode")
        release_tools.write_checksums(self.payload, self.payload / "SHA256SUMS")
        self.artifact = self.root / f"uten-imp-{self.version}-{self.commit[:12]}.tar.gz"
        with tarfile.open(self.artifact, "w:gz") as bundle:
            bundle.add(self.payload, arcname=self.version, recursive=True)
        self.manifest_path = self.root / "manifest.json"
        release_tools.build_manifest(
            SimpleNamespace(
                artifact=self.artifact,
                artifact_object_key=f"releases/{self.version}/{self.artifact.name}",
                built_at="2026-08-11T08:00:00Z",
                commit=self.commit,
                flyway_dir=self.migrations,
                flyway_checksums=self.flyway_checksums,
                output=self.manifest_path,
                payload_root=self.payload,
                signing_key_id=self.key_id,
                source_ref=f"refs/tags/{self.version}",
                version=self.version,
            )
        )
        self.manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        self.info = release_guard.validate_manifest(self.manifest)

    def _write_updater_wheel(
        self,
        name: str,
        version: str,
        requirements: tuple[str, ...],
        *,
        tag: str,
    ) -> None:
        filename_name = name.replace("-", "_")
        dist_info = f"{filename_name}-{version}.dist-info"
        metadata = [
            "Metadata-Version: 2.1",
            f"Name: {name}",
            f"Version: {version}",
            *(f"Requires-Dist: {requirement}" for requirement in requirements),
            "",
            "",
        ]
        wheel = self.updater_wheelhouse / f"{filename_name}-{version}-{tag}.whl"
        with zipfile.ZipFile(wheel, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(f"{filename_name}/__init__.py", "")
            archive.writestr(f"{dist_info}/METADATA", "\n".join(metadata))
            python_tag, abi_tag, platform_tag = tag.split("-", 2)
            expanded_tags = (
                f"{python_value}-{abi_value}-{platform_value}"
                for python_value in python_tag.split(".")
                for abi_value in abi_tag.split(".")
                for platform_value in platform_tag.split(".")
            )
            root_is_pure = "true" if platform_tag == "any" and abi_tag == "none" else "false"
            archive.writestr(
                f"{dist_info}/WHEEL",
                "Wheel-Version: 1.0\nGenerator: fixture\n"
                f"Root-Is-Purelib: {root_is_pure}\n"
                + "".join(f"Tag: {expanded}\n" for expanded in expanded_tags),
            )
            archive.writestr(f"{dist_info}/RECORD", "")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_valid_bundle_extracts_and_tampering_is_detected(self) -> None:
        extracted = release_guard.safe_extract(self.artifact, self.root / "verified", self.info)
        self.assertEqual(extracted.name, self.version)
        release_guard.verify_payload(extracted, self.info)
        (extracted / "server/uten-imp-server.jar").write_bytes(b"tampered")
        with self.assertRaises(release_guard.ReleaseGuardError):
            release_guard.verify_payload(extracted, self.info)

    def test_backend_and_migrator_are_both_mandatory_and_signed(self) -> None:
        self.assertEqual(
            set(self.manifest["executables"]), {"backend", "migrator"}
        )
        for executable in self.manifest["executables"].values():
            self.assertEqual(
                executable["sha256"],
                release_tools.sha256_file(self.payload / executable["path"]),
            )
        (self.payload / "server/uten-imp-migrator.jar").unlink()
        with self.assertRaises(release_tools.ReleaseMetadataError):
            release_tools.write_checksums(self.payload, self.payload / "SHA256SUMS.new")

    def test_migrator_jar_rejects_business_and_web_runtime_classes(self) -> None:
        original = self.payload / "server/uten-imp-migrator.jar"
        for label, forbidden_class in (
            ("business", "com/uten/imp/service/OrderService.class"),
            ("spring", "org/springframework/context/ApplicationContext.class"),
            ("servlet", "jakarta/servlet/Servlet.class"),
            ("tomcat", "org/apache/tomcat/Server.class"),
            ("multi-release", "META-INF/versions/17/com/uten/imp/Backdoor.class"),
        ):
            with self.subTest(label=label):
                tampered = self.root / label / "uten-imp-migrator.jar"
                tampered.parent.mkdir()
                shutil.copyfile(original, tampered)
                with zipfile.ZipFile(tampered, "a", zipfile.ZIP_DEFLATED) as jar:
                    jar.writestr(forbidden_class, b"fixture-bytecode")
                with self.assertRaises(release_tools.ReleaseMetadataError):
                    release_tools.verify_jar_migrations(tampered, self.manifest["flyway"])
                with self.assertRaises(release_guard.ReleaseGuardError):
                    release_guard.verify_executable_jar(
                        tampered,
                        self.info,
                        migration_prefix="db/migration/",
                        migrator=True,
                    )

    def test_release_counter_is_canonical_and_anti_alias(self) -> None:
        with self.assertRaises(release_tools.ReleaseMetadataError):
            release_tools.validate_version("v2026.08.11-01")
        with self.assertRaises(release_guard.ReleaseGuardError):
            release_guard.version_sequence("v2026.08.11-01")

    def test_absolute_checksum_path_is_a_controlled_metadata_error(self) -> None:
        (self.payload / "SHA256SUMS").write_text(
            f"{'0' * 64}  /outside-release\n", encoding="utf-8"
        )
        with self.assertRaises(release_tools.ReleaseMetadataError):
            release_tools.read_checksums(self.payload)

    def test_archive_traversal_and_symlinks_are_rejected(self) -> None:
        for member_name, member_type in (
            (f"{self.version}/../escape", tarfile.REGTYPE),
            (f"{self.version}/server/link", tarfile.SYMTYPE),
        ):
            malicious = self.root / f"malicious-{member_type!s}.tar.gz"
            with tarfile.open(malicious, "w:gz") as bundle:
                member = tarfile.TarInfo(member_name)
                member.type = member_type
                if member_type == tarfile.SYMTYPE:
                    member.linkname = "/etc/passwd"
                    bundle.addfile(member)
                else:
                    data = b"escape"
                    member.size = len(data)
                    bundle.addfile(member, io.BytesIO(data))
            malicious_info = dict(self.info)
            malicious_info.update(
                artifactSha256=release_guard.sha256_file(malicious),
                artifactSizeBytes=malicious.stat().st_size,
            )
            with self.assertRaises(release_guard.ReleaseGuardError):
                release_guard.safe_extract(
                    malicious, self.root / f"reject-{member_type!s}", malicious_info
                )

    def test_manifest_requires_fail_closed_database_policy(self) -> None:
        self.assertEqual(
            self.manifest["flyway"]["migrations"][0]["flywayChecksum"],
            self.flyway_checksum,
        )
        changed = json.loads(json.dumps(self.manifest))
        changed["databaseChangePolicy"]["rollbackCompatible"] = True
        with self.assertRaises(release_guard.ReleaseGuardError):
            release_guard.validate_manifest(changed)

    def test_flyway_checksum_export_is_strict_canonical_tsv(self) -> None:
        malformed = self.root / "bad-flyway-checksums.tsv"
        malformed.write_text(
            f"{release_tools.FLYWAY_CHECKSUM_HEADER}\n"
            "01\tV1__initial_schema.sql\t123456789\n",
            encoding="utf-8",
        )
        with self.assertRaises(release_tools.ReleaseMetadataError):
            release_tools.read_flyway_checksums(malformed)
        malformed.write_text(
            f"{release_tools.FLYWAY_CHECKSUM_HEADER}\n"
            "2\tV2__second.sql\t2\n"
            "1\tV1__first.sql\t1\n",
            encoding="utf-8",
        )
        with self.assertRaises(release_tools.ReleaseMetadataError):
            release_tools.read_flyway_checksums(malformed)

    @unittest.skipIf(
        getattr(os, "geteuid", lambda: -1)() == 0,
        "temporary restore evidence fixture is intentionally unprivileged",
    )
    def test_restore_checksum_rows_come_from_a_verified_manifest(self) -> None:
        ssh_keygen = shutil.which("ssh-keygen")
        if not ssh_keygen:
            self.skipTest("OpenSSH ssh-keygen is not installed")
        key = self.root / "restore-release-key"
        subprocess.run(
            [ssh_keygen, "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        public_key = " ".join(
            key.with_suffix(".pub").read_text(encoding="ascii").split()[:2]
        )
        allowed = self.root / "restore-allowed-signers"
        allowed.write_text(
            f"{release_guard.SIGNING_IDENTITY} {public_key}\n", encoding="ascii"
        )
        signed = json.loads(json.dumps(self.manifest))
        signed["signingKeyId"] = next(
            iter(release_guard.allowed_signing_key_ids(allowed))
        )
        signed_manifest = self.root / "restore-manifest.json"
        release_tools.write_json(signed_manifest, signed)
        subprocess.run(
            [
                ssh_keygen,
                "-Y",
                "sign",
                "-f",
                str(key),
                "-n",
                release_guard.SIGNATURE_NAMESPACE,
                str(signed_manifest),
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        output = io.StringIO()
        argv = [
            "release_guard.py",
            "verified-flyway-checksums",
            "--manifest",
            str(signed_manifest),
            "--signature",
            str(signed_manifest.with_suffix(".json.sig")),
            "--allowed-signers",
            str(allowed),
            "--expected-version",
            self.version,
        ]
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(output):
            self.assertEqual(release_guard.main(), 0)
        self.assertEqual(
            output.getvalue(),
            f"1\tV1__initial_schema.sql\t{self.flyway_checksum}\n",
        )
        self.assertEqual(
            release_guard.INSTALLED_GUARD_PATH,
            Path("/usr/local/libexec/uten-imp-release/release_guard.py"),
        )
        self.assertEqual(
            release_guard.INSTALLED_RESTORE_ALLOWED_SIGNERS_PATH,
            Path("/etc/uten-imp-release-trust/release-allowed-signers"),
        )

    def test_static_entry_requires_exact_http_shape_and_flutter_marker(self) -> None:
        release_guard.validate_static_entry_response(
            200,
            "text/html; charset=utf-8",
            b'<meta name="uten-release-version" content="v2026.08.11-1">'
            b"<script src='flutter_bootstrap.js'></script>",
            self.version,
        )
        for status, content_type, body in (
            (302, "text/html", b"flutter_bootstrap.js"),
            (200, "application/json", b"flutter_bootstrap.js"),
            (200, "text/html", b"generic maintenance page"),
        ):
            with self.assertRaises(release_guard.ReleaseGuardError):
                release_guard.validate_static_entry_response(status, content_type, body)
        with self.assertRaises(release_guard.ReleaseGuardError):
            release_guard.validate_static_entry_response(
                200,
                "text/html",
                b"flutter_bootstrap.js",
                self.version,
            )

    def test_web_stamp_rejects_duplicate_or_noncanonical_token(self) -> None:
        web = self.root / "bad-web"
        web.mkdir()
        (web / "index.html").write_text(
            release_tools.INDEX_VERSION_META + release_tools.INDEX_VERSION_META,
            encoding="utf-8",
        )
        with self.assertRaises(release_tools.ReleaseMetadataError):
            release_tools.stamp_web_release(
                SimpleNamespace(web_root=web, version=self.version, commit=self.commit)
            )

    def test_signed_channel_is_bound_to_manifest_identity(self) -> None:
        channel_path = self.root / "channel.json"
        release_tools.build_channel(
            SimpleNamespace(
                channel="candidate",
                manifest=self.manifest_path,
                manifest_object_key=f"releases/{self.version}/manifest.json",
                manifest_signature_object_key=f"releases/{self.version}/manifest.sig",
                output=channel_path,
                published_at="2026-08-11T08:00:00Z",
            )
        )
        channel = json.loads(channel_path.read_text(encoding="utf-8"))
        channel_info = release_guard.validate_channel(channel, expected_channel="candidate")
        for key in ("commitSha", "releaseSequence", "signingKeyId", "version"):
            self.assertEqual(channel_info[key], self.info[key])

    def test_isolated_signer_anchors_manifest_and_both_jars_to_protected_source(self) -> None:
        publish_root = self.root / "publish-candidate"
        publish_root.mkdir()
        artifact_name = self.artifact.name
        shutil.copyfile(self.artifact, publish_root / artifact_name)
        (publish_root / f"{artifact_name}.sha256").write_text(
            f"{release_tools.sha256_file(self.artifact)}  {artifact_name}\n",
            encoding="ascii",
        )
        shutil.copyfile(
            self.payload / "sbom/backend.cdx.json",
            publish_root / "backend.cdx.json",
        )
        shutil.copyfile(
            self.payload / "sbom/flutter.cdx.json",
            publish_root / "flutter.cdx.json",
        )
        shutil.copyfile(self.manifest_path, publish_root / "manifest.template.json")
        shutil.copyfile(
            self.updater_supply / "updater-wheelhouse.attestation.json",
            publish_root / "updater-wheelhouse.attestation.json",
        )
        inventory_names = [
            artifact_name,
            f"{artifact_name}.sha256",
            "backend.cdx.json",
            "flutter.cdx.json",
            "manifest.template.json",
            "updater-wheelhouse.attestation.json",
        ]
        (publish_root / "PUBLISH_SHA256SUMS").write_text(
            "".join(
                f"{release_tools.sha256_file(publish_root / name)}  {name}\n"
                for name in inventory_names
            ),
            encoding="ascii",
        )
        candidate_tar = self.root / "publish-candidate.tar"
        with tarfile.open(candidate_tar, "w:") as candidate:
            for name in ["PUBLISH_SHA256SUMS", *inventory_names]:
                candidate.add(publish_root / name, arcname=name, recursive=False)

        inline_source = SignatureAndIoValidationTest.workflow_inline_python_after(
            "Re-verify candidate structure, digests, and unsigned manifest without project code"
        )
        migration_bytes = (self.migrations / "V1__initial_schema.sql").read_bytes()
        api_root = "https://api.github.test"
        repository = "example/uten-imp"
        class ApiResponse(io.BytesIO):
            status = 200

        def api_payloads(protected_bytes: bytes) -> dict[str, bytes]:
            files = {
                "server/src/main/resources/db/migration/V1__initial_schema.sql": protected_bytes,
                "deploy/updater/wheelhouse/requirements.in": (
                    self.updater_supply / "updater-requirements.in"
                ).read_bytes(),
                "deploy/updater/wheelhouse/requirements.lock": (
                    self.updater_supply / "updater-requirements.lock"
                ).read_bytes(),
                "deploy/updater/wheelhouse/source-requirements.lock": (
                    self.updater_supply / "build-evidence/source-requirements.lock"
                ).read_bytes(),
                "deploy/updater/wheelhouse/build-requirements.lock": (
                    self.updater_supply / "build-evidence/build-requirements.lock"
                ).read_bytes(),
                "deploy/updater/build-wheelhouse.sh": self.updater_builder_script.read_bytes(),
                "deploy/updater/wheelhouse_supply_chain.py": self.updater_verifier_source.read_bytes(),
            }
            source_tree: dict[str, object] = {}
            for path, content in files.items():
                cursor = source_tree
                segments = path.split("/")
                for segment in segments[:-1]:
                    cursor = cursor.setdefault(segment, {})  # type: ignore[assignment]
                cursor[segments[-1]] = content

            payloads: dict[str, object] = {}
            tree_counter = 1

            def emit_tree(tree: dict[str, object]) -> str:
                nonlocal tree_counter
                tree_sha = f"{tree_counter:040x}"
                tree_counter += 1
                entries = []
                for name in sorted(tree):
                    value = tree[name]
                    if isinstance(value, dict):
                        child_sha = emit_tree(value)
                        entries.append(
                            {"mode": "040000", "path": name, "sha": child_sha, "type": "tree"}
                        )
                    else:
                        self.assertIsInstance(value, bytes)
                        blob_object = b"blob " + str(len(value)).encode("ascii") + b"\0" + value
                        blob_sha = hashlib.sha1(blob_object).hexdigest()
                        entries.append(
                            {
                                "mode": "100644", "path": name, "sha": blob_sha,
                                "size": len(value), "type": "blob",
                            }
                        )
                        payloads[f"{api_root}/repos/{repository}/git/blobs/{blob_sha}"] = {
                            "content": base64.b64encode(value).decode("ascii"),
                            "encoding": "base64",
                            "sha": blob_sha,
                            "size": len(value),
                        }
                payloads[f"{api_root}/repos/{repository}/git/trees/{tree_sha}"] = {
                    "sha": tree_sha,
                    "truncated": False,
                    "tree": entries,
                }
                return tree_sha

            root_tree_sha = emit_tree(source_tree)
            payloads[f"{api_root}/repos/{repository}/git/commits/{self.commit}"] = {
                "sha": self.commit,
                "tree": {"sha": root_tree_sha},
            }
            return {
                url: json.dumps(value).encode("utf-8") for url, value in payloads.items()
            }

        def execute_verifier(protected_bytes: bytes, destination_name: str) -> None:
            payloads = api_payloads(protected_bytes)

            def urlopen(request, timeout):
                self.assertEqual(timeout, 30)
                try:
                    return ApiResponse(payloads[request.full_url])
                except KeyError as exc:
                    raise AssertionError(f"unexpected GitHub API request: {request.full_url}") from exc

            destination = self.root / destination_name
            destination.mkdir()
            environment = {
                "GH_TOKEN": "test-token",
                "GITHUB_API_URL": api_root,
                "GITHUB_REF_NAME": self.version,
                "GITHUB_REPOSITORY": repository,
                "GITHUB_SHA": self.commit,
                "PLACEHOLDER_KEY_ID": self.key_id,
            }
            with mock.patch.dict(os.environ, environment, clear=False), mock.patch.object(
                sys, "argv", ["inline", str(candidate_tar), str(destination)]
            ), mock.patch("urllib.request.urlopen", side_effect=urlopen), contextlib.redirect_stdout(
                io.StringIO()
            ):
                namespace: dict[str, object] = {}
                try:
                    exec(
                        compile(inline_source, "isolated-publish-verifier", "exec"),
                        namespace,
                    )
                finally:
                    for executable_copy in namespace.get("executable_copies", {}).values():
                        if not executable_copy.closed:
                            executable_copy.close()

        execute_verifier(migration_bytes, "verified-source")
        with self.assertRaisesRegex(SystemExit, "protected GitHub source blobs"):
            execute_verifier(
                b"create table protected_only(id integer);\n",
                "mismatched-source",
            )


@unittest.skipUnless(os.name == "posix", "release web stamping is Linux CI-only")
class FlutterWebVersionStampTest(unittest.TestCase):
    version = "v2026.08.14-1"
    commit = "89abcdef0123456789abcdef0123456789abcdef"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.web = self.root / "web"
        self.web.mkdir()
        self.index = self.web / "index.html"
        self.index.write_text(
            f"<html><head>{release_tools.INDEX_VERSION_META}</head>"
            "<script src=\"flutter_bootstrap.js\"></script></html>\n",
            encoding="utf-8",
        )
        self.version_file = self.web / "version.json"
        self.version_file.write_bytes(release_tools.FLUTTER_WEB_PACKAGE_METADATA_BYTES)
        self.transaction_file = self.web / release_tools.WEB_STAMP_TRANSACTION_FILE
        self.args = SimpleNamespace(
            web_root=self.web,
            version=self.version,
            commit=self.commit,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_flutter_3442_metadata_is_consumed_and_replaced_canonically(self) -> None:
        workflow = (PROJECT_ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            f"flutter-version: {release_tools.FLUTTER_WEB_GENERATOR_VERSION}",
            workflow,
        )
        self.assertEqual(
            json.dumps(
                release_tools.FLUTTER_WEB_PACKAGE_METADATA,
                separators=(",", ":"),
            ).encode("utf-8"),
            release_tools.FLUTTER_WEB_PACKAGE_METADATA_BYTES,
        )

        release_tools.stamp_web_release(self.args)

        self.assertEqual(
            json.loads(self.version_file.read_text(encoding="utf-8")),
            {
                "commitSha": self.commit,
                "product": release_tools.PRODUCT,
                "releaseSequence": 20260814001,
                "schemaVersion": 1,
                "version": self.version,
            },
        )
        self.assertEqual(stat.S_IMODE(self.version_file.stat().st_mode), 0o644)
        self.assertEqual(self.version_file.stat().st_nlink, 1)
        self.assertFalse(self.transaction_file.exists())
        index = self.index.read_text(encoding="utf-8")
        self.assertNotIn(release_tools.INDEX_VERSION_TOKEN, index)
        self.assertEqual(
            index.count(
                release_tools.INDEX_VERSION_META.replace(
                    release_tools.INDEX_VERSION_TOKEN, self.version
                )
            ),
            1,
        )

    def test_forged_replayed_or_old_flutter_metadata_is_rejected_without_mutation(self) -> None:
        original_index = self.index.read_bytes()
        cases = {
            "forged-package": (
                b'{"app_name":"uten_imp","version":"0.1.0","build_number":"1",'
                b'"package_name":"forged"}'
            ),
            "duplicate-field": (
                b'{"app_name":"uten_imp","version":"0.1.0","build_number":"1",'
                b'"package_name":"uten_imp","package_name":"uten_imp"}'
            ),
            "old-release-schema": release_tools.canonical_json_bytes(
                {
                    "commitSha": self.commit,
                    "product": release_tools.PRODUCT,
                    "releaseSequence": 20260814001,
                    "schemaVersion": 1,
                    "version": self.version,
                }
            ),
            "non-generator-encoding": (
                release_tools.FLUTTER_WEB_PACKAGE_METADATA_BYTES + b"\n"
            ),
        }
        for label, raw in cases.items():
            with self.subTest(label=label):
                self.version_file.write_bytes(raw)
                with self.assertRaisesRegex(
                    release_tools.ReleaseMetadataError,
                    "differs from the reviewed Flutter",
                ):
                    release_tools.stamp_web_release(self.args)
                self.assertEqual(self.index.read_bytes(), original_index)
                self.assertEqual(self.version_file.read_bytes(), raw)

    def test_flutter_version_symlink_is_rejected_without_touching_index(self) -> None:
        original_index = self.index.read_bytes()
        outside = self.root / "outside-version.json"
        outside.write_bytes(release_tools.FLUTTER_WEB_PACKAGE_METADATA_BYTES)
        self.version_file.unlink()
        self.version_file.symlink_to(outside)

        with self.assertRaises(release_tools.ReleaseMetadataError):
            release_tools.stamp_web_release(self.args)

        self.assertTrue(self.version_file.is_symlink())
        self.assertEqual(self.index.read_bytes(), original_index)
        self.assertEqual(outside.read_bytes(), release_tools.FLUTTER_WEB_PACKAGE_METADATA_BYTES)

    def test_flutter_version_hardlink_is_rejected_without_touching_index(self) -> None:
        original_index = self.index.read_bytes()
        alias = self.root / "version-alias.json"
        os.link(self.version_file, alias)

        with self.assertRaisesRegex(
            release_tools.ReleaseMetadataError, "stable single-link"
        ):
            release_tools.stamp_web_release(self.args)

        self.assertEqual(self.index.read_bytes(), original_index)
        self.assertEqual(self.version_file.stat().st_nlink, 2)
        self.assertEqual(alias.read_bytes(), release_tools.FLUTTER_WEB_PACKAGE_METADATA_BYTES)

    def test_same_bytes_path_replacement_is_rejected_before_stamping(self) -> None:
        original_index = self.index.read_bytes()
        replacement = self.web / ".replacement-version.json"
        replacement.write_bytes(release_tools.FLUTTER_WEB_PACKAGE_METADATA_BYTES)
        real_read = os.read
        reads = 0

        def swap_during_capture(descriptor: int, size: int) -> bytes:
            nonlocal reads
            chunk = real_read(descriptor, size)
            reads += 1
            if reads == 3:
                os.replace(replacement, self.version_file)
            return chunk

        with mock.patch.object(
            release_tools.os, "read", side_effect=swap_during_capture
        ), self.assertRaisesRegex(
            release_tools.ReleaseMetadataError,
            "changed while its bytes were being captured|path changed after its bytes were captured",
        ):
            release_tools.stamp_web_release(self.args)

        self.assertEqual(self.index.read_bytes(), original_index)
        self.assertEqual(
            self.version_file.read_bytes(),
            release_tools.FLUTTER_WEB_PACKAGE_METADATA_BYTES,
        )

    def test_interrupted_two_file_stamp_resumes_only_from_bound_transaction(self) -> None:
        real_replace = release_tools._atomic_replace_captured_web_file
        replacements = 0

        def interrupt_second_replace(
            directory_fd: int, name: str, **kwargs: object
        ) -> None:
            nonlocal replacements
            replacements += 1
            if replacements == 2:
                raise OSError("injected interruption before version replacement")
            real_replace(directory_fd, name, **kwargs)

        with mock.patch.object(
            release_tools,
            "_atomic_replace_captured_web_file",
            side_effect=interrupt_second_replace,
        ), self.assertRaisesRegex(OSError, "injected interruption"):
            release_tools.stamp_web_release(self.args)

        self.assertTrue(self.transaction_file.is_file())
        self.assertEqual(stat.S_IMODE(self.transaction_file.stat().st_mode), 0o600)
        self.assertEqual(self.transaction_file.stat().st_nlink, 1)
        self.assertNotIn(
            release_tools.INDEX_VERSION_TOKEN,
            self.index.read_text(encoding="utf-8"),
        )
        self.assertEqual(
            self.version_file.read_bytes(),
            release_tools.FLUTTER_WEB_PACKAGE_METADATA_BYTES,
        )

        release_tools.stamp_web_release(self.args)

        self.assertFalse(self.transaction_file.exists())
        self.assertEqual(
            json.loads(self.version_file.read_text(encoding="utf-8"))["version"],
            self.version,
        )

    def test_forged_resume_transaction_is_rejected_without_mutation(self) -> None:
        original_index = self.index.read_bytes()
        forged = release_tools._web_stamp_transaction_value(
            version=self.version,
            commit_sha=self.commit,
            sequence=20260814001,
            index_preimage=original_index,
            index_final=release_tools._stamped_index_from_preimage(
                original_index, self.version
            ),
            version_final=release_tools.canonical_json_bytes(
                {
                    "commitSha": self.commit,
                    "product": release_tools.PRODUCT,
                    "releaseSequence": 20260814001,
                    "schemaVersion": 1,
                    "version": self.version,
                }
            ),
        )
        forged["unexpected"] = "not-reviewed"
        self.transaction_file.write_bytes(release_tools.canonical_json_bytes(forged))
        self.transaction_file.chmod(0o600)

        with self.assertRaisesRegex(
            release_tools.ReleaseMetadataError, "transaction schema is not exact"
        ):
            release_tools.stamp_web_release(self.args)

        self.assertEqual(self.index.read_bytes(), original_index)
        self.assertEqual(
            self.version_file.read_bytes(),
            release_tools.FLUTTER_WEB_PACKAGE_METADATA_BYTES,
        )
        self.assertTrue(self.transaction_file.exists())

    def test_resume_transaction_rejects_bool_and_float_integer_fields(self) -> None:
        original_index = self.index.read_bytes()
        release_version = release_tools.canonical_json_bytes(
            {
                "commitSha": self.commit,
                "product": release_tools.PRODUCT,
                "releaseSequence": 20260814001,
                "schemaVersion": 1,
                "version": self.version,
            }
        )
        original_transaction = release_tools._web_stamp_transaction_value(
            version=self.version,
            commit_sha=self.commit,
            sequence=20260814001,
            index_preimage=original_index,
            index_final=release_tools._stamped_index_from_preimage(
                original_index, self.version
            ),
            version_final=release_version,
        )
        cases = {
            "boolean-schema": ("schemaVersion", True),
            "float-schema": ("schemaVersion", 1.0),
            "float-sequence": ("releaseSequence", 20260814001.0),
        }
        for label, (key, value) in cases.items():
            with self.subTest(label=label):
                transaction = dict(original_transaction)
                transaction[key] = value
                self.transaction_file.write_bytes(
                    release_tools.canonical_json_bytes(transaction)
                )
                self.transaction_file.chmod(0o600)
                with self.assertRaisesRegex(
                    release_tools.ReleaseMetadataError,
                    "transaction differs from the requested release",
                ):
                    release_tools.stamp_web_release(self.args)
                self.assertEqual(self.index.read_bytes(), original_index)
                self.assertEqual(
                    self.version_file.read_bytes(),
                    release_tools.FLUTTER_WEB_PACKAGE_METADATA_BYTES,
                )

    def test_post_replace_index_swap_is_caught_by_joint_terminal_verification(self) -> None:
        real_replace = release_tools._atomic_replace_captured_web_file
        swapped = False

        def replace_then_swap(
            directory_fd: int, name: str, **kwargs: object
        ) -> None:
            nonlocal swapped
            real_replace(directory_fd, name, **kwargs)
            if name == "index.html" and not swapped:
                replacement = self.web / ".post-replace-index"
                replacement.write_bytes(b"<html><head></head><body>forged</body></html>\n")
                replacement.chmod(0o644)
                os.replace(replacement, self.index)
                swapped = True

        with mock.patch.object(
            release_tools,
            "_atomic_replace_captured_web_file",
            side_effect=replace_then_swap,
        ), self.assertRaisesRegex(
            release_tools.ReleaseMetadataError,
            "terminal web index|release identity is not canonical",
        ):
            release_tools.stamp_web_release(self.args)

        self.assertTrue(swapped)
        self.assertTrue(self.transaction_file.exists())
        self.assertEqual(
            json.loads(self.version_file.read_text(encoding="utf-8"))["version"],
            self.version,
        )

    def test_joint_terminal_cross_check_rejects_same_bytes_inode_swap(self) -> None:
        real_read = release_tools._read_stable_web_file
        swapped = False

        def read_then_swap(
            directory_fd: int, name: str, **kwargs: object
        ) -> tuple[bytes, tuple[int, ...]]:
            nonlocal swapped
            captured = real_read(directory_fd, name, **kwargs)
            if kwargs.get("label") == "terminal web index.html" and not swapped:
                replacement = self.web / ".terminal-index-replacement"
                replacement.write_bytes(captured[0])
                replacement.chmod(0o644)
                os.replace(replacement, self.index)
                swapped = True
            return captured

        with mock.patch.object(
            release_tools,
            "_read_stable_web_file",
            side_effect=read_then_swap,
        ), self.assertRaisesRegex(
            release_tools.ReleaseMetadataError,
            "terminal web index.html changed during joint terminal verification",
        ):
            release_tools.stamp_web_release(self.args)

        self.assertTrue(swapped)
        self.assertTrue(self.transaction_file.exists())


class SignatureAndIoValidationTest(unittest.TestCase):
    def setUp(self) -> None:
        import release_updater

        profile = mock.patch.object(
            release_updater, "deployment_profile", return_value="prod"
        )
        profile.start()
        self.addCleanup(profile.stop)

    @staticmethod
    def systemd_exec_record(path: str, argv: str) -> str:
        return (
            f"{{ path={path} ; argv[]={argv} ; ignore_errors=no ; "
            "start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
        )

    @staticmethod
    def workflow_inline_python_after(marker: str) -> str:
        workflow = (PROJECT_ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        marker_offset = workflow.index(marker)
        start = workflow.index("<<'PY'\n", marker_offset) + len("<<'PY'\n")
        end = workflow.index("\n          PY", start)
        lines = workflow[start:end].splitlines()
        if not all(not line or line.startswith("          ") for line in lines):
            raise AssertionError("inline Python is not aligned with its YAML block")
        return "\n".join(line[10:] if line else "" for line in lines) + "\n"

    def test_release_workflow_keeps_protected_quality_and_signing_gates(self) -> None:
        workflow = (PROJECT_ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        build = workflow[
            workflow.index("  build-release-candidate:") : workflow.index(
                "  publish-release:"
            )
        ]
        publish = workflow[
            workflow.index("  publish-release:") : workflow.index(
                "  bootstrap-initial-candidate:"
            )
        ]
        bootstrap = workflow[workflow.index("  bootstrap-initial-candidate:") :]
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("CREATE_INITIAL_CANDIDATE_POINTER", workflow)
        self.assertIn("group: signed-production-release", workflow)
        self.assertNotIn("signed-release-${{ github.ref }}", workflow)
        self.assertNotIn("if: github.ref_type", workflow)
        self.assertIn("RELEASE_REF_PROTECTED", workflow)
        self.assertIn("environment: production-release-publisher", publish)
        self.assertIn("environment: production-release-bootstrap", bootstrap)
        self.assertNotIn("environment: production-release\n", workflow)
        self.assertNotIn("/environments/production-release", workflow)
        self.assertIn("clean verify", workflow)
        self.assertNotIn("skipTests", workflow)
        self.assertIn("-Dtest=FlywayChecksumManifestExporterTest", workflow)
        self.assertIn("node --test web/update_check.test.cjs", workflow)
        self.assertIn('-p "test*.py"', build)
        self.assertIn("deploy/verify-templates.ps1", build)
        self.assertIn("find deploy website/deploy", build)
        self.assertIn('bash -n "$script"', build)
        self.assertIn("ast.parse(path.read_text", build)
        self.assertIn("bash deploy/updater/build-wheelhouse.sh", build)
        self.assertIn("bash deploy/updater/test-wheelhouse-offline.sh", build)
        wheelhouse_offline_test = (
            PROJECT_ROOT / "deploy/updater/test-wheelhouse-offline.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("--user 0:0", wheelhouse_offline_test)
        self.assertIn("--user 10001:10001", wheelhouse_offline_test)
        self.assertIn(
            "/tmp:rw,nosuid,nodev,exec,uid=10001,gid=10001,mode=1777",
            wheelhouse_offline_test,
        )
        self.assertIn("type=volume,src=$runtime_volume,dst=/runtime", wheelhouse_offline_test)
        self.assertIn(
            "type=volume,src=$runtime_volume,dst=/runtime,readonly",
            wheelhouse_offline_test,
        )
        self.assertNotIn("--cap-add", wheelhouse_offline_test)
        self.assertNotIn("setpriv", wheelhouse_offline_test)
        self.assertLess(
            wheelhouse_offline_test.index("--user 0:0"),
            wheelhouse_offline_test.index("python3 -m venv /runtime/venv"),
        )
        self.assertLess(
            wheelhouse_offline_test.index("--venv /runtime/venv"),
            wheelhouse_offline_test.index("--user 10001:10001"),
        )
        wheelhouse_builder = (
            PROJECT_ROOT / "deploy/updater/build-wheelhouse.sh"
        ).read_text(encoding="utf-8")
        self.assertGreaterEqual(wheelhouse_builder.count("--read-only --cap-drop ALL"), 2)
        self.assertGreaterEqual(
            wheelhouse_builder.count("--security-opt no-new-privileges"), 2
        )
        self.assertIn("--network none", wheelhouse_builder)
        self.assertIn("must run as an unprivileged host user and group", wheelhouse_builder)
        self.assertIn("render-runtime-lock", wheelhouse_builder)
        self.assertIn(
            "reviewed runtime lock is not the canonical exact lock for the built wheelhouse",
            wheelhouse_builder,
        )
        self.assertIn('cp -a "$RUNNER_TEMP/updater-supply-chain/."', build)
        self.assertIn('MIGRATOR_JAR="server/target/uten-imp-migrator.jar"', build)
        self.assertIn('"$PAYLOAD/server/uten-imp-migrator.jar"', build)
        self.assertGreaterEqual(workflow.count("main moved or lost protection"), 3)
        self.assertNotIn("environment:", build)
        self.assertNotIn("${{ secrets.", build)
        self.assertNotIn("RELEASE_SIGNING_PRIVATE_KEY", build)
        self.assertIn(
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
            build,
        )
        self.assertNotIn("actions/checkout@", publish)
        for forbidden in (
            "flutter ",
            "mvn ",
            "pip install",
            "release_tools.py",
            "release_guard.py",
        ):
            self.assertNotIn(forbidden, publish)
        self.assertNotIn("python3 deploy/", publish)
        self.assertIn(
            "actions/runs/$GITHUB_RUN_ID/artifacts",
            publish,
        )
        self.assertIn("artifact_digest=", publish)
        self.assertIn(
            're.fullmatch(r"[0-9a-f]{64}", build_digest)',
            publish,
        )
        self.assertIn('digest.removeprefix("sha256:") != build_digest', publish)
        self.assertIn("sha256sum --check --status", publish)
        self.assertIn("GH_TOKEN: ${{ github.token }}", publish)
        self.assertIn(f'/repos/{{repository}}/git/commits/{{commit}}', publish)
        self.assertIn(f'/repos/{{repository}}/git/trees/{{tree_sha}}', publish)
        self.assertIn(f'/repos/{{repository}}/git/blobs/{{entry[\'sha\']}}', publish)
        self.assertIn("hashlib.sha1(git_object).hexdigest()", publish)
        self.assertIn("zlib.crc32", publish)
        self.assertIn("zipfile.ZipFile(jar_file)", publish)
        self.assertIn("manifest_source != protected_source", publish)
        self.assertIn("actual_migrations != expected_migration_bytes", publish)
        self.assertIn("deploy/updater/wheelhouse/requirements.lock", publish)
        self.assertIn("deploy/updater/build-wheelhouse.sh", publish)
        self.assertIn("deploy/updater/wheelhouse_supply_chain.py", publish)
        self.assertIn("updater runtime lock differs from the complete reviewed transitive set", publish)
        self.assertIn("https://cyclonedx.org/bom", publish)
        self.assertIn("uten-imp-updater-wheelhouse-v1", publish)
        self.assertIn("updater-wheelhouse.attestation.sig", publish)
        phase4 = (PROJECT_ROOT / "deploy/setup/phase4-updater-nginx.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "local wheelhouse verifier differs from the signed protected source", phase4
        )
        self.assertIn("PIP_NO_CACHE_DIR=1", phase4)
        self.assertIn("id-token: write", publish)
        self.assertIn("ALIYUN_RELEASE_PUBLISHER_ROLE_ARN", publish)
        self.assertNotIn("ALIYUN_RELEASE_BOOTSTRAP_ROLE_ARN", publish)
        self.assertIn('/tmp/token "$RUNNER_TEMP/token"', publish)
        self.assertIn(
            "aliyun/configure-aliyun-credentials-action@"
            "1e5248c8d5d93a8781ac344a68e19a43341e79e6",
            publish,
        )
        self.assertNotIn("steps.aliyun-oidc.outputs", publish)
        self.assertNotRegex(publish, r"(?m)^\s+HOME:")
        self.assertIn(
            'OSS_ACCESS_KEY_ID="${ALIBABA_CLOUD_ACCESS_KEY_ID:-}"', publish
        )
        self.assertIn(
            "3ae4d9fc85a7a6e9f5654d1599766f1a3a42a3692870887b5ae9338d582ef65a",
            publish,
        )
        self.assertNotIn("secrets.OSS_", workflow)
        self.assertNotRegex(
            workflow,
            r"\$\{\{\s*secrets\.(?:ALIBABA_CLOUD_|ALICLOUD_|ALIYUN_|OSS_)",
        )
        self.assertNotIn("pip install", workflow)
        self.assertIn("RELEASE_ALLOWED_SIGNERS: ${{ vars.RELEASE_ALLOWED_SIGNERS }}", publish)
        self.assertIn("get_existing_object", publish)
        self.assertIn("readback_exact", publish)
        self.assertGreaterEqual(publish.count("readback_exact "), 11)
        self.assertIn("existing channel claims an unauthorized signing key", publish)
        self.assertIn("refusing candidate pointer replay/downgrade", publish)
        self.assertIn("trap 'rm -rf -- \"$KEY_DIR\"' EXIT", workflow)
        self.assertIn("unset RELEASE_SIGNING_PRIVATE_KEY", workflow)
        self.assertIn('rm -f -- "$KEY_DIR/id_ed25519"', workflow)
        self.assertIn("id: upload-signed-candidate", publish)
        self.assertGreaterEqual(
            publish.count("if: github.event_name == 'push'"), 5
        )
        secret_start = publish.index("RELEASE_SIGNING_PRIVATE_KEY: ${{ secrets.")
        secret_unset = publish.index("unset RELEASE_SIGNING_PRIVATE_KEY", secret_start)
        secret_window = publish[secret_start:secret_unset]
        self.assertIn("printf '%s'", secret_window)
        self.assertNotIn("$(", secret_window)
        self.assertNotRegex(secret_window, r"\n\s+(python3|ssh-keygen|stat|awk|cat)\b")
        immutable_upload = publish.rindex("put_immutable ")
        mutable_pointer = publish.rindex("put_mutable_pointer ")
        pointer_advance_gate = publish.rindex("VERIFIED pointer advance")
        self.assertLess(pointer_advance_gate, immutable_upload)
        self.assertGreater(mutable_pointer, immutable_upload)
        self.assertIn("environment: production-release-bootstrap", bootstrap)
        self.assertIn("ALIYUN_RELEASE_BOOTSTRAP_ROLE_ARN", bootstrap)
        self.assertNotIn("ALIYUN_RELEASE_PUBLISHER_ROLE_ARN", bootstrap)
        self.assertIn('/tmp/token "$RUNNER_TEMP/token"', bootstrap)
        self.assertNotIn("actions/checkout@", bootstrap)
        self.assertNotIn("RELEASE_SIGNING_PRIVATE_KEY", bootstrap)
        self.assertNotIn("${{ secrets.", bootstrap)
        self.assertIn("put_create_only", bootstrap)
        bootstrap_channel = bootstrap.index(
            'put_create_only "$CANDIDATE/channel.sig"'
        )
        bootstrap_pointer = bootstrap.index(
            'put_initial_pointer "$CANDIDATE/LATEST.txt"'
        )
        self.assertLess(bootstrap_channel, bootstrap_pointer)
        self.assertIn("--forbid-overwrite true", bootstrap)
        self.assertIn("--cache-control no-store", bootstrap)
        self.assertIn('cmp --silent "$CANDIDATE/LATEST.txt"', bootstrap)
        self.assertIn('cmp --silent "$CANDIDATE/$ARTIFACT"', bootstrap)
        self.assertIn('cmp --silent "$CANDIDATE/backend.cdx.json"', bootstrap)
        self.assertNotIn("ALIYUN_RELEASE_ROLE_ARN", workflow)
        self.assertGreaterEqual(bootstrap.count("ssh-keygen -Y verify"), 6)
        self.assertIn("signed artifact service metadata differs", bootstrap)
        action_refs = re.findall(r"^\s*- uses: [^@\s]+@([^\s]+)", workflow, re.MULTILINE)
        self.assertTrue(action_refs)
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{40}", ref) for ref in action_refs))

    def test_release_workflow_inline_python_is_syntactically_valid(self) -> None:
        workflow = (PROJECT_ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        scripts = re.findall(
            r"<<'PY'\n(?P<body>.*?)(?=^          PY$)",
            workflow,
            re.MULTILINE | re.DOTALL,
        )
        self.assertGreaterEqual(len(scripts), 6)
        for index, script in enumerate(scripts, start=1):
            lines = script.splitlines()
            self.assertTrue(
                all(not line or line.startswith("          ") for line in lines),
                f"inline Python {index} is not aligned with its YAML block",
            )
            source = "\n".join(
                line[10:] if line else "" for line in lines
            ) + "\n"
            try:
                ast.parse(source)
            except SyntaxError as exc:
                self.fail(f"inline Python {index} is invalid: {exc}")

        shell_blocks = re.findall(
            r"(?m)^        run: \|\r?\n(?P<body>(?:(?:          [^\r\n]*)?\r?\n)+)",
            workflow,
        )
        self.assertGreaterEqual(len(shell_blocks), 20)
        for index, block in enumerate(shell_blocks, start=1):
            source = "\n".join(
                line[10:] if line.startswith("          ") else ""
                for line in block.splitlines()
            ) + "\n"
            source = re.sub(r"\$\{\{.*?\}\}", "GITHUB_EXPRESSION", source)
            completed = subprocess.run(
                ["bash", "-n"],
                input=source,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(
                0,
                completed.returncode,
                f"release shell block {index}: {completed.stderr}",
            )

    def test_phase4_inline_python_is_syntactically_valid(self) -> None:
        phase4 = (PROJECT_ROOT / "deploy/setup/phase4-updater-nginx.sh").read_text(
            encoding="utf-8"
        )
        scripts = re.findall(
            r"<<'PY'\n(?P<body>.*?)(?=^PY$)",
            phase4,
            re.MULTILINE | re.DOTALL,
        )
        self.assertGreaterEqual(len(scripts), 4)
        for index, source in enumerate(scripts, start=1):
            try:
                ast.parse(source)
            except SyntaxError as exc:
                self.fail(f"Phase 4 inline Python {index} is invalid: {exc}")

    def test_phase4_binds_executed_verifier_to_signed_sbom_digest(self) -> None:
        phase4 = (PROJECT_ROOT / "deploy/setup/phase4-updater-nginx.sh").read_text(
            encoding="utf-8"
        )
        marker = "attestation_path = Path(sys.argv[1])"
        marker_offset = phase4.index(marker)
        start = phase4.rindex("<<'PY'\n", 0, marker_offset) + len("<<'PY'\n")
        end = phase4.index("\nPY", marker_offset)
        source = phase4[start:end] + "\n"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            verifier = root / "wheelhouse_supply_chain.py"
            verifier.write_bytes(b"# reviewed verifier\n")
            digest = hashlib.sha256(verifier.read_bytes()).hexdigest()
            statement = {
                "predicate": {
                    "metadata": {
                        "properties": [
                            {
                                "name": "uten:builder:verifier-sha256",
                                "value": digest,
                            }
                        ]
                    }
                }
            }
            attestation = root / "attestation.json"
            attestation.write_bytes(
                (json.dumps(statement, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(
                    "utf-8"
                )
            )
            with mock.patch.object(
                sys, "argv", ["inline", str(attestation), str(verifier)]
            ):
                exec(compile(source, "phase4-verifier-binding", "exec"), {})
            verifier.write_bytes(b"# tampered verifier\n")
            with mock.patch.object(
                sys, "argv", ["inline", str(attestation), str(verifier)]
            ), self.assertRaisesRegex(SystemExit, "differs from the signed protected source"):
                exec(compile(source, "phase4-verifier-binding", "exec"), {})

    def test_artifact_service_digest_binds_bare_upload_action_digest(self) -> None:
        source = self.workflow_inline_python_after(
            "Locate the one current-run artifact and bind its service digest"
        )
        digest = "a" * 64
        commit = "b" * 40
        artifact_id = 1234
        metadata = {
            "artifacts": [
                {
                    "digest": f"sha256:{digest}",
                    "expired": False,
                    "id": artifact_id,
                    "name": f"uten-imp-unsigned-{commit}",
                    "size_in_bytes": 4096,
                    "workflow_run": {"head_sha": commit, "id": 9876},
                }
            ],
            "total_count": 1,
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            metadata_path = root / "artifacts.json"
            output_path = root / "output.txt"
            metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
            environment = {
                "BUILD_ARTIFACT_DIGEST": digest,
                "BUILD_ARTIFACT_ID": str(artifact_id),
                "GITHUB_RUN_ID": "9876",
                "GITHUB_SHA": commit,
            }
            with mock.patch.dict(os.environ, environment, clear=False), mock.patch.object(
                sys, "argv", ["inline", str(metadata_path), str(output_path)]
            ):
                exec(compile(source, "release-artifact-digest-gate", "exec"), {})
            output = output_path.read_text(encoding="utf-8")
            self.assertIn(f"artifact_digest={digest}\n", output)
            with mock.patch.dict(
                os.environ,
                {**environment, "BUILD_ARTIFACT_DIGEST": f"sha256:{digest}"},
                clear=False,
            ), mock.patch.object(
                sys, "argv", ["inline", str(metadata_path), str(output_path)]
            ), self.assertRaisesRegex(SystemExit, "bare SHA-256"):
                exec(compile(source, "release-artifact-digest-gate", "exec"), {})

    def test_bootstrap_artifact_is_bound_to_same_protected_workflow_run(self) -> None:
        source = self.workflow_inline_python_after(
            "Bind explicit bootstrap intent, source, and signed artifact"
        )
        digest = "c" * 64
        commit = "d" * 40
        artifact_id = 4321
        run_id = 8765
        metadata = {
            "artifacts": [
                {
                    "digest": f"sha256:{digest}",
                    "expired": False,
                    "id": artifact_id,
                    "name": f"uten-imp-signed-{commit}",
                    "size_in_bytes": 8192,
                    "workflow_run": {"head_sha": commit, "id": run_id},
                }
            ],
            "total_count": 1,
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            metadata_path = root / "signed-artifacts.json"
            output_path = root / "output.txt"
            metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
            environment = {
                "GITHUB_RUN_ID": str(run_id),
                "GITHUB_SHA": commit,
                "SIGNED_ARTIFACT_DIGEST": digest,
                "SIGNED_ARTIFACT_ID": str(artifact_id),
            }
            with mock.patch.dict(os.environ, environment, clear=False), mock.patch.object(
                sys, "argv", ["inline", str(metadata_path), str(output_path)]
            ):
                exec(compile(source, "bootstrap-artifact-binding", "exec"), {})
            self.assertIn(
                f"artifact_digest={digest}\n",
                output_path.read_text(encoding="utf-8"),
            )
            metadata["artifacts"][0]["workflow_run"]["head_sha"] = "e" * 40
            metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
            with mock.patch.dict(os.environ, environment, clear=False), mock.patch.object(
                sys, "argv", ["inline", str(metadata_path), str(output_path)]
            ), self.assertRaisesRegex(SystemExit, "source SHA"):
                exec(compile(source, "bootstrap-artifact-binding", "exec"), {})

    @unittest.skipUnless(os.name == "posix", "openat/O_NOFOLLOW regression runs on Linux CI")
    def test_root_snapshot_rejects_symlink_and_multilink_sources(self) -> None:
        import release_updater

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            destination = root / "destination"
            source.mkdir()
            destination.mkdir()
            (source / "real").write_bytes(b"fixture")
            (source / "link").symlink_to(source / "real")
            os.link(source / "real", source / "second-link")
            directory_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY)
            try:
                with self.assertRaises(release_updater.UpdaterError):
                    release_updater.copy_untrusted_regular_file(
                        directory_fd,
                        "link",
                        destination / "link-copy",
                        updater_uid=os.geteuid(),
                        maximum_bytes=1024,
                    )
                with self.assertRaises(release_updater.UpdaterError):
                    release_updater.copy_untrusted_regular_file(
                        directory_fd,
                        "real",
                        destination / "multilink-copy",
                        updater_uid=os.geteuid(),
                        maximum_bytes=1024,
                    )
            finally:
                os.close(directory_fd)

    @unittest.skipUnless(os.name == "posix", "snapshot mutation regression runs on Linux CI")
    def test_root_snapshot_rejects_in_place_mutation(self) -> None:
        import release_updater

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            destination = root / "destination"
            source.mkdir()
            destination.mkdir()
            source_file = source / "archive"
            source_file.write_bytes(b"A" * (2 * 1024 * 1024))
            directory_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY)
            original_read = release_updater.os.read
            mutated = False

            def mutate_after_first_read(descriptor: int, size: int) -> bytes:
                nonlocal mutated
                chunk = original_read(descriptor, size)
                if chunk and not mutated:
                    mutated = True
                    source_file.write_bytes(b"B" * (2 * 1024 * 1024))
                return chunk

            try:
                with mock.patch.object(
                    release_updater.os, "read", side_effect=mutate_after_first_read
                ), self.assertRaises(release_updater.UpdaterError):
                    release_updater.copy_untrusted_regular_file(
                        directory_fd,
                        "archive",
                        destination / "copy",
                        updater_uid=os.geteuid(),
                        maximum_bytes=3 * 1024 * 1024,
                    )
            finally:
                os.close(directory_fd)

    def test_updater_credentials_use_a_separate_traversable_directory(self) -> None:
        service = (PROJECT_ROOT / "deploy/updater/uten-imp-updater.service").read_text(
            encoding="utf-8"
        )
        updater_source = (PROJECT_ROOT / "deploy/updater/release_updater.py").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "EnvironmentFile=/etc/uten-imp-updater/oss-pull.env", service
        )
        unset = next(
            line for line in service.splitlines() if line.startswith("UnsetEnvironment=")
        ).removeprefix("UnsetEnvironment=").split()
        for forbidden in (
            "LD_PRELOAD",
            "LD_LIBRARY_PATH",
            "LD_AUDIT",
            "BASH_ENV",
            "ENV",
            "SHELLOPTS",
            "BASHOPTS",
            "PS4",
            "BASH_XTRACEFD",
            "PYTHONPATH",
            "PYTHONHOME",
            "JAVA_TOOL_OPTIONS",
            "JDK_JAVA_OPTIONS",
            "_JAVA_OPTIONS",
        ):
            self.assertIn(forbidden, unset)
        self.assertLess(
            service.index("UnsetEnvironment="), service.index("ExecStartPre=")
        )
        self.assertIn(
            'Path("/etc/uten-imp-updater/release-allowed-signers")', updater_source
        )
        self.assertNotIn("/etc/uten-imp/oss-pull.env", service)
        activation = (PROJECT_ROOT / "deploy/updater/uten-imp-activate.sh").read_text(
            encoding="utf-8"
        )
        staging = (PROJECT_ROOT / "deploy/updater/uten-imp-updater.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('readonly PYTHON=/usr/bin/python3', activation)
        self.assertIn('exec "$PYTHON" -I', activation)
        self.assertIn('verify_root_directory_chain "$UPDATER_DIR"', activation)
        self.assertIn('readonly UPDATER_DIR=/opt/uten-imp/updater', activation)
        self.assertIn('unset UTEN_UPDATER_HOME UTEN_UPDATER_STATE_DIR', activation)
        self.assertNotIn('venv/bin/python', activation)
        self.assertIn('readonly UPDATER_DIR=/opt/uten-imp/updater', staging)
        self.assertNotIn('${UTEN_UPDATER_HOME', staging)

    def test_privileged_activation_paths_are_constant(self) -> None:
        import release_updater

        source = (PROJECT_ROOT / "deploy/updater/release_updater.py").read_text(
            encoding="utf-8"
        )
        activation = source[source.index("def activate_release") : source.index("def parser")]
        self.assertIn("state_dir = DEFAULT_STATE_DIR", activation)
        self.assertIn("allowed_signers = DEFAULT_ALLOWED_SIGNERS", activation)
        self.assertIn("base = DEFAULT_RELEASE_BASE", activation)
        boot_gate = (
            "/usr/bin/test ! -e "
            "/var/lib/uten-imp-release/boot-enablement-in-progress.json"
        )
        self.assertTrue(
            any(
                boot_gate in line
                for line in release_updater.APPLICATION_EXECSTART_PRE_FRAGMENT_LINES
            )
        )
        self.assertIn(
            f"ExecStartPre={boot_gate}", release_updater.NGINX_DROPIN_LINES
        )
        self.assertIn(
            ("/usr/bin/test", boot_gate),
            release_updater.WATCHDOG_REQUIRED_GATE_COMMANDS,
        )
        self.assertIn("root_state = DEFAULT_ROOT_STATE_DIR", activation)
        self.assertIn("with StateLock(DEFAULT_LOCK_FILE)", activation)
        self.assertIn("os.path.lexists(ACTIVATION_FAILURE_MARKER)", activation)
        self.assertIn("os.path.lexists(active_state_path)", activation)
        self.assertLess(
            activation.index("run_migration_unit(migration_authorization_nonce)"),
            activation.index("start_application_authorized("),
        )
        self.assertLess(
            activation.index("atomic_current(base, target)"),
            activation.index("prepare_migration_authorization("),
        )
        self.assertLess(
            activation.index("prepare_migration_authorization("),
            activation.index("run_migration_unit(migration_authorization_nonce)"),
        )
        self.assertLess(
            activation.index("write_runtime_authority("),
            activation.index('start_unit("nginx.service")'),
        )
        self.assertIn("unit_enabled(MIGRATION_UNIT)", activation)
        migration_history_gate = activation.index(
            "require_append_only_flyway_transition(old_info, manifest_info)"
        )
        self.assertLess(
            migration_history_gate,
            activation.index("install_root_owned_release(candidate, releases, manifest_info)"),
        )
        self.assertLess(
            migration_history_gate,
            activation.index("begin_activation_transaction("),
        )
        self.assertLess(
            migration_history_gate,
            activation.index("atomic_current(base, target)"),
        )
        first_database_gate = activation.index(
            "require_initial_database_onboarding_acceptance("
        )
        online_database_gate = activation.index(
            "require_online_database_transition_acceptance("
        )
        live_onboarding_gate = activation.index(
            "live_onboarding_target = verify_live_signed_database("
        )
        self.assertLess(live_onboarding_gate, first_database_gate)
        for mutation in (
            "target = install_root_owned_release(candidate, releases, manifest_info)",
            "begin_activation_transaction(",
            "stop_unit(",
            "atomic_current(base, target)",
            "prepare_migration_authorization(",
            "run_migration_unit(migration_authorization_nonce)",
        ):
            mutation_index = activation.index(mutation)
            self.assertLess(first_database_gate, mutation_index)
            self.assertLess(online_database_gate, mutation_index)
        established_release_branch = activation.index(
            "        else:\n            if issue_reauthorization_only"
        )
        onboarding_branch = activation[
            activation.index("if old_info is None:\n            live_onboarding_target") :
            established_release_branch
        ]
        self.assertIn("database_changed = False", onboarding_branch)
        self.assertIn("database_migration_required = False", onboarding_branch)
        self.assertNotIn("prepare_migration_authorization", onboarding_branch)
        self.assertNotIn("run_migration_unit", onboarding_branch)
        signed_current_branch = activation[
            established_release_branch : activation.index(
                "target = install_root_owned_release(candidate, releases, manifest_info)"
            )
        ]
        self.assertIn(
            "if database_changed:\n                "
            "require_online_database_transition_acceptance(",
            signed_current_branch,
        )
        self.assertIn("elif args.approve_database_change:", signed_current_branch)
        self.assertNotIn("--database-onboarding-receipt", activation)
        guarded_migration = activation.index(
            "if database_migration_required:",
            activation.index("atomic_current(base, target)"),
        )
        self.assertLess(guarded_migration, activation.index("prepare_migration_authorization("))
        self.assertLess(guarded_migration, activation.index("run_migration_unit("))
        self.assertNotIn("args.state_dir", activation)
        self.assertNotIn("args.allowed_signers", activation)
        self.assertNotIn("args.release_base", activation)
        self.assertNotIn("args.root_state_dir", activation)
        self.assertNotIn("args.lock_file", activation)

    @unittest.skipUnless(os.name == "posix", "Flyway transition gate runs on Linux CI")
    def test_ordinary_activation_requires_an_exact_append_only_flyway_history(self) -> None:
        import release_updater

        def migration(version: int, *, sha256: str | None = None) -> dict[str, object]:
            return {
                "description": f"migration_{version}",
                "file": f"V{version}__migration_{version}.sql",
                "flywayChecksum": version * 100,
                "sha256": sha256 or f"{version:064x}",
                "version": str(version),
            }

        def inventory(*versions: int) -> dict[str, object]:
            return {
                "flywayHeadVersion": str(versions[-1]),
                "flywayMigrations": [migration(version) for version in versions],
            }

        current = inventory(1, 2)
        release_updater.require_append_only_flyway_transition(None, inventory(1, 2))
        release_updater.require_append_only_flyway_transition(current, inventory(1, 2))
        release_updater.require_append_only_flyway_transition(
            current, inventory(1, 2, 5)
        )

        with self.assertRaisesRegex(
            release_updater.UpdaterError, "head must not decrease"
        ):
            release_updater.require_append_only_flyway_transition(
                current, inventory(1)
            )

        with self.assertRaisesRegex(
            release_updater.UpdaterError, "must not remove"
        ):
            release_updater.require_append_only_flyway_transition(
                inventory(1, 2, 5), inventory(1, 5)
            )

        rewritten = inventory(1, 2, 5)
        rewritten["flywayMigrations"][0] = migration(1, sha256="f" * 64)
        with self.assertRaisesRegex(
            release_updater.UpdaterError, "exact append-only extension"
        ):
            release_updater.require_append_only_flyway_transition(current, rewritten)

        with self.assertRaisesRegex(
            release_updater.UpdaterError, "current signed Flyway inventory"
        ):
            release_updater.require_append_only_flyway_transition(
                {"flywayHeadVersion": "2"}, inventory(1, 2, 5)
            )

    @unittest.skipUnless(os.name == "posix", "database activation gates run on Linux CI")
    def test_first_and_legacy_onboarding_have_no_manual_receipt_escape_hatch(self) -> None:
        import release_updater

        target = {
            "flywayHeadVersion": "255",
            "flywayMigrationCount": 2,
            "flywayMigrationSetSha256": "a" * 64,
            "flywayMigrations": [
                {
                    "version": "238",
                    "file": "V238__authority.sql",
                    "flywayChecksum": 238,
                },
                {
                    "version": "255",
                    "file": "V255__target.sql",
                    "flywayChecksum": 255,
                },
            ],
        }
        projection = hashlib.sha256(
            release_updater.canonical_signed_flyway_projection(target)
        ).hexdigest()
        live = {
            "flyway": {
                "headVersion": 255,
                "successfulMigrationCount": 2,
                "signedProjectionSha256": projection,
            }
        }

        for legacy_retirement in (False, True):
            for approve_database_change in (False, True):
                with self.subTest(
                    legacy_retirement=legacy_retirement,
                    approve_database_change=approve_database_change,
                ), self.assertRaisesRegex(
                    release_updater.UpdaterError,
                    "database onboarding remains hard NO-GO",
                ):
                    release_updater.require_initial_database_onboarding_acceptance(
                        target_info=target,
                        target_manifest_sha256="f" * 64,
                        live_evidence=live,
                        legacy_retirement=legacy_retirement,
                        approve_database_change=approve_database_change,
                    )

        mismatched_live = {
            "flyway": {
                "headVersion": 238,
                "successfulMigrationCount": 1,
                "signedProjectionSha256": "b" * 64,
            }
        }
        with self.assertRaisesRegex(
            release_updater.UpdaterError, "is not the signed target"
        ):
            release_updater.require_initial_database_onboarding_acceptance(
                target_info=target,
                target_manifest_sha256="f" * 64,
                live_evidence=mismatched_live,
                legacy_retirement=False,
                approve_database_change=True,
            )

    @unittest.skipUnless(os.name == "posix", "internal-test adoption runs on Linux CI")
    def test_committed_internal_onboarding_adoption_is_idempotently_terminalized(self) -> None:
        import release_updater

        target = Path("/opt/uten-imp/releases/v2026.08.12-1")
        manifest = {
            "commitSha": "a" * 40,
            "flywayHeadVersion": "255",
            "flywayMigrationSetSha256": "b" * 64,
            "releaseSequence": 20260812001,
            "version": "v2026.08.12-1",
        }
        archive = release_updater.INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR / (
            "internal-test-db-20260812T120000Z-abcdef123456.json"
        )
        receipt_sha = "c" * 64
        contract_sha = "d" * 64
        adoption = {
            "archivePath": str(archive),
            "preparedAtUtc": "2026-08-12T12:00:00Z",
            "receiptSha256": receipt_sha,
            "runtimeContractId": "uten-imp-internal-test-runtime-v1",
            "runtimeContractSha256": contract_sha,
            "schemaVersion": 1,
            "sourcePath": str(release_updater.INTERNAL_TEST_ONBOARDING_RECEIPT),
            "status": "ADOPTION_PREPARED",
            "transactionId": "internal-test-db-20260812T120000Z-abcdef123456",
        }
        active = {
            "activatedAtUtc": "2026-08-12T12:05:00Z",
            "commitSha": manifest["commitSha"],
            "databaseChanged": False,
            "flywayHeadVersion": manifest["flywayHeadVersion"],
            "flywayMigrationSetSha256": manifest["flywayMigrationSetSha256"],
            "manifestSha256": "e" * 64,
            "onboardingArchivePath": str(archive),
            "onboardingReceiptSha256": receipt_sha,
            "releaseSequence": manifest["releaseSequence"],
            "runtimeContractId": adoption["runtimeContractId"],
            "runtimeContractSha256": contract_sha,
            "version": manifest["version"],
        }
        authority = {
            "runtimeContractId": adoption["runtimeContractId"],
            "runtimeContractSha256": contract_sha,
        }
        encoded = {
            release_updater.INTERNAL_TEST_ONBOARDING_ADOPTION: json.dumps(adoption).encode(),
            release_updater.DEFAULT_ROOT_STATE_DIR / "active.json": json.dumps(active).encode(),
            release_updater.RUNTIME_AUTHORITY: json.dumps(authority).encode(),
        }

        def evidence(path: Path, **_kwargs):
            return encoded[Path(path)]

        with mock.patch.object(
            release_updater, "deployment_profile", return_value="internal-test"
        ), mock.patch.object(
            release_updater.os.path, "lexists", return_value=True
        ), mock.patch.object(
            release_updater, "read_root_evidence_bytes", side_effect=evidence
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater, "validate_internal_test_onboarding_adoption"
        ), mock.patch.object(
            release_updater, "validate_active_release_state"
        ), mock.patch.object(
            release_updater, "validate_existing_runtime_authority"
        ) as runtime_gate, mock.patch.object(
            release_updater, "installed_manifest_sha256", return_value="e" * 64
        ), mock.patch.object(
            release_updater.release_guard, "sha256_file", return_value=receipt_sha
        ), mock.patch.object(
            release_updater, "durable_unlink"
        ) as unlink:
            release_updater.finalize_internal_test_onboarding_adoption_if_committed(
                target=target,
                manifest=manifest,
                live_evidence={"verified": True},
            )
        runtime_gate.assert_called_once()
        unlink.assert_called_once_with(release_updater.INTERNAL_TEST_ONBOARDING_ADOPTION)

        def archive_only_evidence(path: Path, **_kwargs):
            if Path(path) == release_updater.DEFAULT_ROOT_STATE_DIR / "active.json":
                raise release_updater.UpdaterError(
                    "committed active state is absent after archive"
                )
            return encoded[Path(path)]

        with mock.patch.object(
            release_updater, "deployment_profile", return_value="internal-test"
        ), mock.patch.object(
            release_updater.os.path, "lexists", return_value=True
        ), mock.patch.object(
            release_updater,
            "read_root_evidence_bytes",
            side_effect=archive_only_evidence,
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater, "validate_internal_test_onboarding_adoption"
        ), mock.patch.object(
            release_updater, "durable_unlink"
        ) as unlink, self.assertRaisesRegex(
            release_updater.UpdaterError, "active state is absent"
        ):
            release_updater.finalize_internal_test_onboarding_adoption_if_committed(
                target=target,
                manifest=manifest,
                live_evidence={"verified": True},
            )
        unlink.assert_not_called()

        authority["runtimeContractSha256"] = "f" * 64
        encoded[release_updater.RUNTIME_AUTHORITY] = json.dumps(authority).encode()
        with mock.patch.object(
            release_updater, "deployment_profile", return_value="internal-test"
        ), mock.patch.object(
            release_updater.os.path, "lexists", return_value=True
        ), mock.patch.object(
            release_updater, "read_root_evidence_bytes", side_effect=evidence
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater, "validate_internal_test_onboarding_adoption"
        ), mock.patch.object(
            release_updater, "validate_active_release_state"
        ), mock.patch.object(
            release_updater, "validate_existing_runtime_authority"
        ), mock.patch.object(
            release_updater, "installed_manifest_sha256", return_value="e" * 64
        ), mock.patch.object(
            release_updater.release_guard, "sha256_file", return_value=receipt_sha
        ), mock.patch.object(
            release_updater, "durable_unlink"
        ) as unlink, self.assertRaisesRegex(
            release_updater.UpdaterError, "runtime authority differs"
        ):
            release_updater.finalize_internal_test_onboarding_adoption_if_committed(
                target=target,
                manifest=manifest,
                live_evidence={"verified": True},
            )
        unlink.assert_not_called()

    @unittest.skipUnless(os.name == "posix", "internal-test restore runs on Linux CI")
    def test_previous_internal_restore_preserves_exact_onboarding_origin(self) -> None:
        import release_updater

        archive = release_updater.INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR / (
            "internal-test-db-20260812T120000Z-abcdef123456.json"
        )
        fields = {
            "onboardingArchivePath": str(archive),
            "onboardingReceiptSha256": "a" * 64,
            "runtimeContractId": "uten-imp-internal-test-runtime-v1",
            "runtimeContractSha256": "b" * 64,
        }
        state = {"active": {"fields": fields, "valid": True}}
        contract = {"contractId": fields["runtimeContractId"]}
        with mock.patch.object(
            release_updater, "deployment_profile", return_value="internal-test"
        ), mock.patch.object(
            release_updater,
            "internal_test_runtime_contract",
            return_value=(contract, fields["runtimeContractSha256"]),
        ), mock.patch.object(
            release_updater, "validate_active_release_state"
        ) as active_gate, mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater.release_guard,
            "sha256_file",
            return_value=fields["onboardingReceiptSha256"],
        ):
            self.assertEqual(
                release_updater.validated_internal_active_origin(state), fields
            )
        active_gate.assert_called_once_with(fields)

        state["active"]["fields"] = {**fields, "runtimeContractSha256": "c" * 64}
        with mock.patch.object(
            release_updater, "deployment_profile", return_value="internal-test"
        ), mock.patch.object(
            release_updater,
            "internal_test_runtime_contract",
            return_value=(contract, fields["runtimeContractSha256"]),
        ), mock.patch.object(
            release_updater, "validate_active_release_state"
        ), self.assertRaisesRegex(
            release_updater.UpdaterError, "another runtime contract"
        ):
            release_updater.validated_internal_active_origin(state)

        with mock.patch.object(
            release_updater, "deployment_profile", return_value="internal-test"
        ), mock.patch.object(
            release_updater,
            "internal_test_runtime_contract",
            return_value=(contract, fields["runtimeContractSha256"]),
        ), self.assertRaisesRegex(
            release_updater.UpdaterError, "lacks its validated active origin"
        ):
            release_updater.validated_internal_active_origin({"active": None})

    @unittest.skipUnless(os.name == "posix", "internal-test DB gates run on Linux CI")
    def test_internal_live_database_rejects_archive_and_role_acl_drift(self) -> None:
        import release_updater

        observed = next(iter(self.recovery_state_fixture(release_updater)["manifests"].values()))
        full = self.recovery_full_manifest_fixture(release_updater, observed)
        live = self.recovery_live_database_fixture(full)
        live["archiveMode"] = "off"
        live["archiveCommand"] = ""
        live["roleAclContract"] = release_updater.internal_test_role_acl_contract()
        release_updater.validate_live_database_against_signed_release(
            live,
            target_manifest=full,
            require_internal_role_acl=True,
        )

        for key, changed in (
            ("archiveMode", "on"),
            ("archiveCommand", "pgbackrest archive-push %p"),
        ):
            drifted = json.loads(json.dumps(live))
            drifted[key] = changed
            with self.subTest(key=key), self.assertRaisesRegex(
                release_updater.UpdaterError, "archive settings"
            ):
                release_updater.validate_live_database_against_signed_release(
                    drifted,
                    target_manifest=full,
                    require_internal_role_acl=True,
                )

        drifted = json.loads(json.dumps(live))
        drifted["roleAclContract"]["applicationMemberships"] = ["pg_read_all_data"]
        with self.assertRaisesRegex(
            release_updater.UpdaterError, "role/ownership/ACL"
        ):
            release_updater.validate_live_database_against_signed_release(
                drifted,
                target_manifest=full,
                require_internal_role_acl=True,
            )

        for key, value in (
            ("unexpectedNonBuiltinRoles", ["legacy_login"]),
            ("unexpectedPrivilegedRoles", ["legacy_superuser"]),
        ):
            drifted = json.loads(json.dumps(live))
            drifted["roleAclContract"][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(
                release_updater.UpdaterError, "role/ownership/ACL"
            ):
                release_updater.validate_live_database_against_signed_release(
                    drifted,
                    target_manifest=full,
                    require_internal_role_acl=True,
                )

    @unittest.skipUnless(os.name == "posix", "database activation gates run on Linux CI")
    def test_online_flyway_transition_rejects_boolean_approval(self) -> None:
        import release_updater

        current = {"flywayHeadVersion": "238"}
        target = {"flywayHeadVersion": "255"}
        for approve_database_change in (False, True):
            with self.subTest(
                approve_database_change=approve_database_change
            ), self.assertRaisesRegex(
                release_updater.UpdaterError, "online Flyway activation remains hard NO-GO"
            ):
                release_updater.require_online_database_transition_acceptance(
                    current_info=current,
                    target_info=target,
                    approve_database_change=approve_database_change,
                )

    @unittest.skipUnless(os.name == "posix", "watchdog gates run on Linux CI")
    def test_watchdog_services_require_both_persistent_reboot_gates(self) -> None:
        import release_updater

        unit = release_updater.WATCHDOG_SERVICES[0]
        gate_records = " ; ".join(
            self.systemd_exec_record(path, argv)
            for path, argv in release_updater.WATCHDOG_REQUIRED_GATE_COMMANDS
        )
        properties = {
            "User": "root",
            "ExecStart": "/usr/local/libexec/uten-imp/watchdog.sh",
            "ExecStartPre": gate_records,
        }
        with mock.patch.object(
            release_updater, "unit_exists", return_value=True
        ), mock.patch.object(
            release_updater,
            "systemd_property",
            side_effect=lambda _unit, name: properties[name],
        ):
            release_updater.assert_watchdog_service_gate_contract(unit)

        unsafe = dict(properties)
        unsafe["ExecStartPre"] = self.systemd_exec_record(
            *release_updater.WATCHDOG_REQUIRED_GATE_COMMANDS[0]
        )
        with mock.patch.object(
            release_updater, "unit_exists", return_value=True
        ), mock.patch.object(
            release_updater,
            "systemd_property",
            side_effect=lambda _unit, name: unsafe[name],
        ), self.assertRaisesRegex(
            release_updater.UpdaterError, "missing a required reboot-safety gate"
        ):
            release_updater.assert_watchdog_service_gate_contract(unit)

    @unittest.skipUnless(os.name == "posix", "entry watchdog unit gate runs on Linux CI")
    def test_entry_watchdog_loaded_unit_orders_after_but_never_pulls_nginx(self) -> None:
        import release_updater

        unit = release_updater.ENTRY_WATCHDOG_UNIT
        gate_records = " ; ".join(
            self.systemd_exec_record(path, argv)
            for path, argv in release_updater.WATCHDOG_REQUIRED_GATE_COMMANDS
        )
        properties = {
            "User": "root",
            "ExecStart": "/usr/local/libexec/uten-imp/uten-imp-entry-watchdog",
            "ExecStartPre": gate_records,
            "LoadState": "loaded",
            "FragmentPath": str(release_updater.ENTRY_WATCHDOG_UNIT_FILE),
            "DropInPaths": "",
            "After": (
                "basic.target network-online.target nginx.service "
                "uten-imp-recovery-commit-verifier.service"
            ),
            "Wants": "network-online.target",
            "Requires": "sysinit.target uten-imp-recovery-commit-verifier.service",
            "BindsTo": "",
            "Upholds": "",
        }
        repository = Path(__file__).resolve().parents[2]
        unit_raw = (
            repository / "deploy/systemd/uten-imp-entry-watchdog.service.example"
        ).read_bytes()
        script_raw = (
            repository / "deploy/watchdog/uten-imp-entry-watchdog.sh"
        ).read_bytes()

        def contract_bytes(path: Path, **_kwargs: object) -> bytes:
            if path == release_updater.ENTRY_WATCHDOG_UNIT_FILE:
                return unit_raw
            if path == release_updater.ENTRY_WATCHDOG_SCRIPT_FILE:
                return script_raw
            raise AssertionError(f"unexpected root contract path: {path}")

        def verify(candidate: dict[str, str]) -> None:
            with mock.patch.object(
                release_updater, "unit_exists", return_value=True
            ), mock.patch.object(
                release_updater,
                "read_root_controlled_bytes",
                side_effect=contract_bytes,
            ), mock.patch.object(
                release_updater,
                "systemd_property",
                side_effect=lambda _unit, name: candidate.get(name, ""),
            ):
                release_updater.assert_watchdog_service_gate_contract(unit)

        verify(properties)

        pulls_nginx = dict(properties)
        pulls_nginx["Wants"] = "network-online.target nginx.service"
        with self.assertRaisesRegex(
            release_updater.UpdaterError, "Wants must contain only"
        ):
            verify(pulls_nginx)

        dropin = dict(properties)
        dropin["DropInPaths"] = "/etc/systemd/system/entry.d/pull-nginx.conf"
        with self.assertRaisesRegex(release_updater.UpdaterError, "drop-ins"):
            verify(dropin)

    @unittest.skipUnless(os.name == "posix", "capacity gate runs with Linux updater module")
    def test_capacity_gate_keeps_absolute_and_proportional_reserve(self) -> None:
        import release_updater

        usage = SimpleNamespace(total=10_000, used=1_000, free=9_000)
        with mock.patch.object(
            release_updater.shutil, "disk_usage", return_value=usage
        ), mock.patch.object(
            release_updater, "MIN_FREE_BYTES", 2_000
        ), mock.patch.object(
            release_updater, "MIN_FREE_PERCENT", 15
        ):
            release_updater.require_capacity(Path("."), 7_000, "fixture")
            with self.assertRaises(release_updater.UpdaterError):
                release_updater.require_capacity(Path("."), 7_001, "fixture")

    @unittest.skipUnless(os.name == "posix", "capacity reporting runs with Linux updater module")
    def test_capacity_report_warns_without_deleting_any_release(self) -> None:
        import release_updater

        usage = SimpleNamespace(total=10_000, used=7_500, free=2_500)
        with mock.patch.object(
            release_updater.shutil, "disk_usage", return_value=usage
        ), mock.patch.object(release_updater, "MIN_FREE_BYTES", 1_000), mock.patch.object(
            release_updater, "log"
        ) as logger, mock.patch.object(
            release_updater.shutil, "rmtree", side_effect=AssertionError("must not delete")
        ):
            report = release_updater.report_capacity(Path("."), "fixture")
        self.assertEqual(report["freePercent"], 25)
        logger.assert_called_once()
        self.assertEqual(logger.call_args.args[1], "warning")

    @contextlib.contextmanager
    def root_install_fixture(self):
        import release_updater

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = root / "candidate"
            releases = root / "releases"
            candidate.mkdir()
            releases.mkdir()
            for name in (
                "channel.json",
                "channel.sig",
                "manifest.json",
                "manifest.sig",
                "STAGED.json",
            ):
                (candidate / name).write_text(f"fixture {name}\n", encoding="utf-8")
            manifest_info = {
                "artifactFileName": "release.tar.gz",
                "version": "v2026.08.11-1",
            }
            install_paths: dict[str, Path] = {}

            def safe_extract(
                _archive: Path,
                temporary_parent: Path,
                _manifest_info: dict[str, object],
            ) -> Path:
                extracted = temporary_parent / manifest_info["version"]
                extracted.mkdir()
                (extracted / "payload.txt").write_text("payload\n", encoding="utf-8")
                install_paths["temporary_parent"] = temporary_parent
                install_paths["extracted"] = extracted
                return extracted

            yield release_updater, candidate, releases, manifest_info, install_paths, safe_extract

    @unittest.skipUnless(os.name == "posix", "durability ordering runs on Linux CI")
    def test_candidate_is_durable_before_high_water_commit(self) -> None:
        import release_updater

        manager = mock.Mock()
        with mock.patch.object(release_updater, "fsync_tree") as fsync_tree, mock.patch.object(
            release_updater.os, "replace"
        ) as replace, mock.patch.object(
            release_updater, "fsync_directory"
        ) as fsync_directory, mock.patch.object(
            release_updater, "atomic_json"
        ) as atomic_json:
            manager.attach_mock(fsync_tree, "fsync_tree")
            manager.attach_mock(replace, "replace")
            manager.attach_mock(fsync_directory, "fsync_directory")
            manager.attach_mock(atomic_json, "atomic_json")
            release_updater.commit_staged_candidate(
                work=Path("/state/.incoming"),
                candidate=Path("/state/candidates/v2026.08.11-1"),
                state_dir=Path("/state"),
                candidates=Path("/state/candidates"),
                high_water_path=Path("/state/high-water.json"),
                high_water_value={"releaseSequence": 20260811001},
            )
        self.assertEqual(
            manager.mock_calls,
            [
                mock.call.fsync_tree(Path("/state/.incoming")),
                mock.call.replace(
                    Path("/state/.incoming"),
                    Path("/state/candidates/v2026.08.11-1"),
                ),
                mock.call.fsync_directory(Path("/state/candidates")),
                mock.call.fsync_directory(Path("/state")),
                mock.call.atomic_json(
                    Path("/state/high-water.json"),
                    {"releaseSequence": 20260811001},
                ),
            ],
        )
        source = (PROJECT_ROOT / "deploy/updater/release_updater.py").read_text(
            encoding="utf-8"
        )
        stage = source[source.index("def stage_release(") : source.index("\ndef inspect_release(")]
        self.assertLess(stage.index("high_water = load_high_water"), stage.index("if candidate.exists()"))
        self.assertIn("if high_water > sequence:", stage)
        self.assertIn("if high_water < sequence:", stage)
        self.assertIn("recovered staging high-water evidence", stage)

    @unittest.skipUnless(os.name == "posix", "durability ordering runs on Linux CI")
    def test_staging_destination_fsync_failure_blocks_high_water_commit(self) -> None:
        import release_updater

        with mock.patch.object(release_updater, "fsync_tree"), mock.patch.object(
            release_updater.os, "replace"
        ), mock.patch.object(
            release_updater, "fsync_directory", side_effect=OSError("injected fsync failure")
        ) as fsync_directory, mock.patch.object(
            release_updater, "atomic_json"
        ) as atomic_json, self.assertRaisesRegex(OSError, "injected fsync failure"):
            release_updater.commit_staged_candidate(
                work=Path("/state/.incoming"),
                candidate=Path("/state/candidates/v2026.08.11-1"),
                state_dir=Path("/state"),
                candidates=Path("/state/candidates"),
                high_water_path=Path("/state/high-water.json"),
                high_water_value={"releaseSequence": 20260811001},
            )
        fsync_directory.assert_called_once_with(Path("/state/candidates"))
        atomic_json.assert_not_called()

    @unittest.skipUnless(os.name == "posix", "root installation runs on Linux CI")
    def test_root_install_is_durable_and_reverified_before_return(self) -> None:
        with self.root_install_fixture() as fixture:
            (
                release_updater,
                candidate,
                releases,
                manifest_info,
                install_paths,
                safe_extract,
            ) = fixture
            target = releases / manifest_info["version"]
            real_replace = os.replace
            manager = mock.Mock()
            with mock.patch.object(
                release_updater, "require_real_directory"
            ), mock.patch.object(
                release_updater, "require_root_owned_tree"
            ) as require_root_owned_tree, mock.patch.object(
                release_updater.release_guard, "safe_extract", side_effect=safe_extract
            ), mock.patch.object(
                release_updater.release_guard, "verify_payload"
            ) as verify_payload, mock.patch.object(
                release_updater, "fsync_tree"
            ) as fsync_tree, mock.patch.object(
                release_updater.os, "replace", wraps=real_replace
            ) as replace, mock.patch.object(
                release_updater, "fsync_directory"
            ) as fsync_directory, mock.patch.object(
                release_updater.os, "chown"
            ):
                manager.attach_mock(require_root_owned_tree, "require_root_owned_tree")
                manager.attach_mock(verify_payload, "verify_payload")
                manager.attach_mock(fsync_tree, "fsync_tree")
                manager.attach_mock(replace, "replace")
                manager.attach_mock(fsync_directory, "fsync_directory")
                installed = release_updater.install_root_owned_release(
                    candidate, releases, manifest_info
                )

            extracted = install_paths["extracted"]
            temporary_parent = install_paths["temporary_parent"]
            self.assertEqual(installed, target)
            self.assertEqual(
                manager.mock_calls,
                [
                    mock.call.require_root_owned_tree(candidate),
                    mock.call.fsync_directory(releases),
                    mock.call.verify_payload(extracted, manifest_info),
                    mock.call.fsync_tree(extracted),
                    mock.call.replace(extracted, target),
                    mock.call.fsync_directory(releases),
                    mock.call.fsync_directory(temporary_parent),
                    mock.call.verify_payload(target, manifest_info),
                    mock.call.require_root_owned_tree(target),
                    mock.call.require_root_owned_tree(temporary_parent),
                    mock.call.fsync_directory(releases),
                ],
            )

            source = (PROJECT_ROOT / "deploy/updater/release_updater.py").read_text(
                encoding="utf-8"
            )
            activation = source[
                source.index("def activate_release(") : source.index("\ndef parser(")
            ]
            self.assertLess(
                activation.index("target = install_root_owned_release("),
                activation.index("atomic_current(base, target)"),
            )

    @unittest.skipUnless(os.name == "posix", "root installation runs on Linux CI")
    def test_root_install_destination_fsync_failure_never_reports_success(self) -> None:
        with self.root_install_fixture() as fixture:
            (
                release_updater,
                candidate,
                releases,
                manifest_info,
                install_paths,
                safe_extract,
            ) = fixture
            target = releases / manifest_info["version"]
            real_replace = os.replace
            destination_fsync_calls = 0

            def fail_second_destination_fsync(path: Path) -> None:
                nonlocal destination_fsync_calls
                self.assertEqual(path, releases)
                destination_fsync_calls += 1
                if destination_fsync_calls == 2:
                    raise OSError("injected destination fsync failure")

            with mock.patch.object(
                release_updater, "require_real_directory"
            ), mock.patch.object(
                release_updater, "require_root_owned_tree"
            ) as require_root_owned_tree, mock.patch.object(
                release_updater.release_guard, "safe_extract", side_effect=safe_extract
            ), mock.patch.object(
                release_updater.release_guard, "verify_payload"
            ) as verify_payload, mock.patch.object(
                release_updater, "fsync_tree"
            ), mock.patch.object(
                release_updater.os, "replace", wraps=real_replace
            ), mock.patch.object(
                release_updater,
                "fsync_directory",
                side_effect=fail_second_destination_fsync,
            ) as fsync_directory, mock.patch.object(
                release_updater.os, "chown"
            ), self.assertRaisesRegex(OSError, "injected destination fsync failure"):
                release_updater.install_root_owned_release(candidate, releases, manifest_info)

            self.assertEqual(
                fsync_directory.call_args_list,
                [mock.call(releases), mock.call(releases), mock.call(releases)],
            )
            self.assertEqual(
                verify_payload.call_args_list,
                [mock.call(install_paths["extracted"], manifest_info)],
            )
            self.assertEqual(
                require_root_owned_tree.call_args_list,
                [mock.call(candidate), mock.call(install_paths["temporary_parent"])],
            )
            self.assertTrue(target.is_dir())

    @unittest.skipUnless(os.name == "posix", "root installation runs on Linux CI")
    def test_root_install_target_reverification_failure_never_reports_success(self) -> None:
        with self.root_install_fixture() as fixture:
            (
                release_updater,
                candidate,
                releases,
                manifest_info,
                install_paths,
                safe_extract,
            ) = fixture
            target = releases / manifest_info["version"]
            real_replace = os.replace
            with mock.patch.object(
                release_updater, "require_real_directory"
            ), mock.patch.object(
                release_updater, "require_root_owned_tree"
            ) as require_root_owned_tree, mock.patch.object(
                release_updater.release_guard, "safe_extract", side_effect=safe_extract
            ), mock.patch.object(
                release_updater.release_guard,
                "verify_payload",
                side_effect=[
                    None,
                    release_updater.UpdaterError("injected target revalidation failure"),
                ],
            ) as verify_payload, mock.patch.object(
                release_updater, "fsync_tree"
            ), mock.patch.object(
                release_updater.os, "replace", wraps=real_replace
            ), mock.patch.object(
                release_updater, "fsync_directory"
            ) as fsync_directory, mock.patch.object(
                release_updater.os, "chown"
            ), self.assertRaisesRegex(
                release_updater.UpdaterError, "injected target revalidation failure"
            ):
                release_updater.install_root_owned_release(candidate, releases, manifest_info)

            self.assertEqual(
                fsync_directory.call_args_list,
                [
                    mock.call(releases),
                    mock.call(releases),
                    mock.call(install_paths["temporary_parent"]),
                    mock.call(releases),
                ],
            )
            self.assertEqual(
                verify_payload.call_args_list,
                [
                    mock.call(install_paths["extracted"], manifest_info),
                    mock.call(target, manifest_info),
                ],
            )
            self.assertEqual(
                require_root_owned_tree.call_args_list,
                [mock.call(candidate), mock.call(install_paths["temporary_parent"])],
            )
            self.assertTrue(target.is_dir())

    @unittest.skipUnless(os.name == "posix", "activation durability runs on Linux CI")
    def test_activation_transaction_disables_boot_before_gate_removal(self) -> None:
        import release_updater

        old_info = {"version": "v2026.08.10-1"}
        new_info = {
            "commitSha": "b" * 40,
            "releaseSequence": 20260811001,
            "version": "v2026.08.11-1",
        }
        enabled = {unit: True for unit in release_updater.BOOT_UNITS}
        manager = mock.Mock()
        with mock.patch.object(release_updater, "atomic_json") as atomic_json, mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater, "disable_boot_units_durable"
        ) as disable_boot, mock.patch.object(
            release_updater, "durable_unlink"
        ) as durable_unlink:
            manager.attach_mock(atomic_json, "atomic_json")
            manager.attach_mock(disable_boot, "disable_boot")
            manager.attach_mock(durable_unlink, "durable_unlink")
            release_updater.begin_activation_transaction(
                old_info=old_info,
                new_info=new_info,
                boot_enabled_before=enabled,
            )
        calls = manager.mock_calls
        failure_gate_index = next(
            index
            for index, call in enumerate(calls)
            if call.args and call.args[0] == release_updater.ACTIVATION_FAILURE_MARKER
        )
        in_progress_index = next(
            index
            for index, call in enumerate(calls)
            if call.args and call.args[0] == release_updater.ACTIVATION_IN_PROGRESS_MARKER
        )
        self.assertLess(failure_gate_index, calls.index(mock.call.disable_boot()))
        self.assertLess(calls.index(mock.call.disable_boot()), in_progress_index)
        self.assertEqual(
            calls[-1], mock.call.durable_unlink(release_updater.ACTIVATION_FAILURE_MARKER)
        )

    @unittest.skipUnless(os.name == "posix", "PostgreSQL boot contract runs on Linux CI")
    def test_database_boot_authority_is_never_part_of_release_containment(self) -> None:
        import release_updater

        self.assertEqual(
            release_updater.DATABASE_BOOT_UNITS,
            (release_updater.POSTGRES_META_UNIT, release_updater.POSTGRES_UNIT),
        )
        self.assertTrue(
            set(release_updater.DATABASE_BOOT_UNITS).isdisjoint(
                release_updater.BOOT_UNITS
            )
        )
        with mock.patch.object(release_updater, "run") as run, mock.patch.object(
            release_updater, "unit_enabled", return_value=False
        ), mock.patch.object(release_updater, "fsync_boot_enablement") as fsync:
            release_updater.disable_boot_units_durable()
        disabled = {call.args[0][-1] for call in run.call_args_list}
        self.assertEqual(disabled, set(release_updater.BOOT_UNITS))
        self.assertTrue(disabled.isdisjoint(release_updater.DATABASE_BOOT_UNITS))
        fsync.assert_called_once_with()

        with mock.patch.object(release_updater, "stop_unit") as stop, mock.patch.object(
            release_updater, "run"
        ) as disable, mock.patch.object(
            release_updater, "fsync_boot_enablement"
        ), mock.patch.object(
            release_updater, "observe_recovery_unit",
            return_value={
                "active": False,
                "enabled": False,
                "exists": True,
                "loadState": "loaded",
            },
        ):
            release_updater._stop_and_disable_for_interrupted_containment()
        for database_unit in release_updater.DATABASE_BOOT_UNITS:
            self.assertNotIn(mock.call(database_unit), stop.call_args_list)
            self.assertNotIn(
                mock.call(["systemctl", "disable", database_unit], check=False),
                disable.call_args_list,
            )

    @unittest.skipUnless(os.name == "posix", "database boot verifier runs on Linux CI")
    def test_database_boot_contract_requires_exact_auto_generator_and_two_active_units(self) -> None:
        import release_updater

        with tempfile.TemporaryDirectory() as temporary:
            fragment = Path(temporary) / "postgresql@.service"
            fragment.write_text("[Unit]\n", encoding="ascii")
            generator_link = mock.MagicMock()
            generator_link.lstat.return_value = SimpleNamespace(
                st_mode=stat.S_IFLNK | 0o777, st_uid=0
            )
            generator_link.resolve.return_value = fragment.resolve()
            properties = {
                (release_updater.POSTGRES_META_UNIT, "LoadState"): "loaded",
                (release_updater.POSTGRES_META_UNIT, "UnitFileState"): "enabled",
                (release_updater.POSTGRES_META_UNIT, "ActiveState"): "active",
                (release_updater.POSTGRES_META_UNIT, "Wants"):
                    release_updater.POSTGRES_UNIT,
                (release_updater.POSTGRES_UNIT, "LoadState"): "loaded",
                (release_updater.POSTGRES_UNIT, "UnitFileState"): "enabled",
                (release_updater.POSTGRES_UNIT, "ActiveState"): "active",
                (release_updater.POSTGRES_UNIT, "FragmentPath"): str(fragment),
            }

            def verify(overrides: dict[tuple[str, str], str] | None = None) -> None:
                observed = properties | (overrides or {})
                with mock.patch.object(
                    release_updater, "read_postgres_start_conf", return_value=b"auto\n"
                ), mock.patch.object(
                    release_updater,
                    "systemd_property",
                    side_effect=lambda unit, name: observed.get((unit, name), ""),
                ), mock.patch.object(
                    release_updater, "require_real_directory"
                ), mock.patch.object(
                    release_updater, "require_root_controlled_file"
                ), mock.patch.object(
                    release_updater, "POSTGRES_GENERATOR_LINK", generator_link
                ):
                    release_updater.assert_database_boot_contract()

            verify()
            for label, override in {
                "meta-inactive": {
                    (release_updater.POSTGRES_META_UNIT, "ActiveState"): "inactive"
                },
                "instance-disabled": {
                    (release_updater.POSTGRES_UNIT, "UnitFileState"): "disabled"
                },
                "missing-generator-want": {
                    (release_updater.POSTGRES_META_UNIT, "Wants"): ""
                },
            }.items():
                with self.subTest(label=label), self.assertRaises(
                    release_updater.UpdaterError
                ):
                    verify(override)

            with mock.patch.object(
                release_updater, "read_postgres_start_conf", return_value=b"manual\n"
            ), self.assertRaisesRegex(release_updater.UpdaterError, "exactly auto"):
                release_updater.assert_database_boot_contract()

    @unittest.skipUnless(os.name == "posix", "database lock verifier runs on Linux CI")
    def test_database_maintenance_lock_is_fixed_nonblocking_and_single_link(self) -> None:
        import release_updater

        directory = mock.MagicMock()
        directory.lstat.return_value = SimpleNamespace(
            st_mode=stat.S_IFDIR | 0o750, st_uid=0, st_gid=77
        )
        directory.is_symlink.return_value = False
        lock_path = mock.MagicMock()
        lock_path.lstat.return_value = SimpleNamespace(st_dev=9, st_ino=10)
        opened = SimpleNamespace(
            st_mode=stat.S_IFREG | 0o660,
            st_uid=0,
            st_gid=77,
            st_nlink=1,
            st_size=0,
            st_dev=9,
            st_ino=10,
        )
        with mock.patch.object(release_updater.os, "geteuid", return_value=0), mock.patch.object(
            release_updater, "system_group_id", return_value=77
        ), mock.patch.object(
            release_updater, "require_real_directory"
        ), mock.patch.object(
            release_updater, "DATABASE_MAINTENANCE_DIR", directory
        ), mock.patch.object(
            release_updater, "DATABASE_MAINTENANCE_LOCK", lock_path
        ), mock.patch.object(
            release_updater.os, "open", return_value=31
        ), mock.patch.object(
            release_updater.os, "fstat", return_value=opened
        ), mock.patch.object(
            release_updater.os, "close"
        ) as close, mock.patch.object(
            release_updater.fcntl, "flock"
        ) as flock:
            with release_updater.DatabaseMaintenanceLock():
                self.assertEqual(
                    flock.call_args_list,
                    [mock.call(31, release_updater.fcntl.LOCK_EX | release_updater.fcntl.LOCK_NB)],
                )
            self.assertEqual(
                flock.call_args_list[-1],
                mock.call(31, release_updater.fcntl.LOCK_UN),
            )
            close.assert_called_once_with(31)

        with mock.patch.object(release_updater.os, "geteuid", return_value=0), mock.patch.object(
            release_updater, "system_group_id", return_value=77
        ), mock.patch.object(
            release_updater, "require_real_directory"
        ), mock.patch.object(
            release_updater, "DATABASE_MAINTENANCE_DIR", directory
        ), mock.patch.object(
            release_updater, "DATABASE_MAINTENANCE_LOCK", lock_path
        ), mock.patch.object(
            release_updater.os, "open", return_value=31
        ), mock.patch.object(
            release_updater.os, "fstat", return_value=opened
        ), mock.patch.object(
            release_updater.os, "close"
        ), mock.patch.object(
            release_updater.fcntl, "flock", side_effect=BlockingIOError
        ), self.assertRaisesRegex(release_updater.UpdaterError, "already running"):
            release_updater.DatabaseMaintenanceLock().__enter__()

    @unittest.skipUnless(os.name == "posix", "activation durability runs on Linux CI")
    def test_activation_source_restores_boot_only_after_durable_active_state(self) -> None:
        source = (PROJECT_ROOT / "deploy/updater/release_updater.py").read_text(
            encoding="utf-8"
        )
        activation = source[
            source.index("def activate_release(") : source.index("\ndef parser(")
        ]
        begin = activation.index("begin_activation_transaction(")
        switch = activation.index("atomic_current(base, target)")
        active_state = activation.index("atomic_json(\n                active_state_path")
        commit_enablement = activation.index(
            "commit_boot_enablement(desired_boot_enablement, manifest_info)"
        )
        self.assertLess(begin, switch)
        self.assertLess(active_state, commit_enablement)

        commit_source = source[
            source.index("def commit_boot_enablement(") : source.index(
                "\ndef begin_activation_transaction("
            )
        ]
        boot_marker = commit_source.index(
            "atomic_json(\n        BOOT_ENABLEMENT_IN_PROGRESS_MARKER"
        )
        clear_activation = commit_source.index(
            "durable_unlink(ACTIVATION_IN_PROGRESS_MARKER)"
        )
        restore_enablement = commit_source.index(
            "restore_boot_enablement(boot_enabled)"
        )
        clear_boot_marker = commit_source.index(
            "durable_unlink(BOOT_ENABLEMENT_IN_PROGRESS_MARKER)"
        )
        self.assertLess(boot_marker, clear_activation)
        self.assertLess(clear_activation, restore_enablement)
        self.assertLess(restore_enablement, clear_boot_marker)

    def test_database_lock_order_spans_activation_and_evidence_recovery_terminal_paths(self) -> None:
        source = (PROJECT_ROOT / "deploy/updater/release_updater.py").read_text(
            encoding="utf-8"
        )
        tree = ast.parse(source)
        functions = {
            node.name: node
            for node in tree.body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        }

        def ordered_release_database_lock(node):
            if not isinstance(node, ast.With) or len(node.items) != 2:
                return False
            release_context = node.items[0].context_expr
            database_context = node.items[1].context_expr
            return (
                isinstance(release_context, ast.Call)
                and isinstance(release_context.func, ast.Attribute)
                and release_context.func.attr == "allow_persistent_markers"
                and isinstance(release_context.func.value, ast.Call)
                and isinstance(release_context.func.value.func, ast.Name)
                and release_context.func.value.func.id == "StateLock"
                and isinstance(database_context, ast.Call)
                and isinstance(database_context.func, ast.Name)
                and database_context.func.id == "DatabaseMaintenanceLock"
            )

        for function_name, terminal_calls in {
            "activate_release": {"recover_failed_activation", "commit_boot_enablement"},
            "recover_apply": {
                "remain_contained_recovery",
                "finish_activation_recovery",
                "restore_previous_recovery",
            },
        }.items():
            with self.subTest(function=function_name):
                function = functions[function_name]
                dual_lock = next(
                    node
                    for node in ast.walk(function)
                    if ordered_release_database_lock(node)
                )
                held_calls = {
                    node.func.id
                    for node in ast.walk(dual_lock)
                    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                }
                self.assertTrue(terminal_calls.issubset(held_calls))

        interrupted = functions["recover_interrupted_apply"]
        interrupted_calls = {
            node.func.id
            for node in ast.walk(interrupted)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
        }
        self.assertIn("StateLock", interrupted_calls)
        self.assertNotIn("DatabaseMaintenanceLock", interrupted_calls)

    def test_installers_persist_database_boot_recovery_before_mutation_and_preflight_phase4(self) -> None:
        phase3 = (PROJECT_ROOT / "deploy/setup/phase3-runtime.sh").read_text(
            encoding="utf-8"
        )
        marker_resume = phase3.index(
            'if [[ -e "$DATABASE_BOOT_IN_PROGRESS" || -L "$DATABASE_BOOT_IN_PROGRESS" ]]'
        )
        classification = phase3.index("echo '==> Classify the host")
        marker_publish = phase3.index("\n      publish_database_boot_marker\n")
        storage_confirmation = phase3.index(
            '[[ "$storage_authority_confirmation" == "$expected_storage_confirmation" ]]'
        )
        storage_authority_publish = phase3.index(
            'mv -T -- "$storage_authority_temp" "$STORAGE_AUTHORITY"'
        )
        marker_remove = phase3.index('  rm -f -- "$DATABASE_BOOT_IN_PROGRESS"')
        boot_verify = phase3.rindex(
            "  verify_database_boot_contract", 0, marker_remove
        )
        self.assertLess(marker_resume, classification)
        self.assertLess(storage_confirmation, marker_publish)
        self.assertLess(marker_publish, storage_authority_publish)
        self.assertLess(boot_verify, marker_remove)

        phase4 = (PROJECT_ROOT / "deploy/setup/phase4-updater-nginx.sh").read_text(
            encoding="utf-8"
        )
        stable_guard_check = phase4.index(
            "stable privileged release guard differs from the reviewed Phase 4 source"
        )
        lock_preflight = phase4.index(
            "\nverify_database_maintenance_lock\n", stable_guard_check
        )
        boot_preflight = phase4.index("\nverify_database_boot_contract\n", lock_preflight)
        first_stable_write = phase4.index(
            "install -d -m 0755 -o root -g root /usr/local/libexec/uten-imp-release",
            stable_guard_check,
        )
        self.assertLess(lock_preflight, first_stable_write)
        self.assertLess(boot_preflight, first_stable_write)

    def test_phase2_database_generator_commit_and_failure_containment_are_explicit(self) -> None:
        phase2 = (PROJECT_ROOT / "deploy/setup/phase2-postgres.sh").read_text(
            encoding="utf-8"
        )
        success = phase2[phase2.index("echo '==> Commit boot enablement") :]
        auto = success.index("set_cluster_start_conf auto")
        reload_manager = success.index("systemctl daemon-reload", auto)
        enable_database = success.index(
            'systemctl enable postgresql.service "postgresql@${PG_VERSION}-${PG_CLUSTER}.service"',
            reload_manager,
        )
        start_meta = success.index("systemctl start postgresql.service", enable_database)
        verify = success.index("verify_database_boot_contract", start_meta)
        self.assertLess(auto, reload_manager)
        self.assertLess(reload_manager, enable_database)
        self.assertLess(enable_database, start_meta)
        self.assertLess(start_meta, verify)
        self.assertNotIn("systemctl enable uten-pgbackup.timer", success)

        containment = phase2[
            phase2.index("fail_close_phase2()") : phase2.index(
                "trap fail_close_phase2 EXIT"
            )
        ]
        manual = containment.index("set_cluster_start_conf manual")
        containment_reload = containment.index("systemctl daemon-reload", manual)
        disable_database = containment.index("disable --now", containment_reload)
        generator_check = containment.index(
            "postgresql-generator-dependency-remains", disable_database
        )
        self.assertLess(manual, containment_reload)
        self.assertLess(containment_reload, disable_database)
        self.assertLess(disable_database, generator_check)

    def test_migration_template_has_ordering_only_database_and_data_dependencies(self) -> None:
        unit = (PROJECT_ROOT / "deploy/systemd/uten-imp-migrate.service.example").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "After=network-online.target data.mount postgresql@16-main.service", unit
        )
        self.assertIn("Wants=network-online.target", unit)
        for forbidden in (
            "Requires=postgresql@16-main.service",
            "Requisite=postgresql@16-main.service",
            "BindsTo=postgresql@16-main.service",
            "RequiresMountsFor=/data",
        ):
            self.assertNotIn(forbidden, unit)

    @unittest.skipUnless(os.name == "posix", "boot transaction runs on Linux CI")
    def test_boot_enablement_marker_survives_every_partial_enable_failure(self) -> None:
        import release_updater

        desired = {unit: True for unit in release_updater.BOOT_UNITS}
        release_info = {
            "commitSha": "b" * 40,
            "releaseSequence": 20260811001,
            "version": "v2026.08.11-1",
        }
        for fail_index in range(len(release_updater.BOOT_UNITS)):
            attempts: list[str] = []

            def fail_one_enable(unit: str) -> None:
                attempts.append(unit)
                if len(attempts) - 1 == fail_index:
                    raise release_updater.UpdaterError("injected enable failure")

            with self.subTest(fail_index=fail_index), mock.patch.object(
                release_updater, "atomic_json"
            ) as atomic_json, mock.patch.object(
                release_updater, "require_root_controlled_file"
            ), mock.patch.object(
                release_updater, "durable_unlink"
            ) as durable_unlink, mock.patch.object(
                release_updater, "enable_unit", side_effect=fail_one_enable
            ), mock.patch.object(
                release_updater, "fsync_boot_enablement"
            ), self.assertRaisesRegex(
                release_updater.UpdaterError, "injected enable failure"
            ):
                release_updater.commit_boot_enablement(desired, release_info)
            self.assertEqual(
                atomic_json.call_args.args[0],
                release_updater.BOOT_ENABLEMENT_IN_PROGRESS_MARKER,
            )
            durable_unlink.assert_called_once_with(
                release_updater.ACTIVATION_IN_PROGRESS_MARKER
            )

        with mock.patch.object(
            release_updater, "atomic_json"
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater, "durable_unlink"
        ) as durable_unlink, mock.patch.object(
            release_updater, "enable_unit"
        ), mock.patch.object(
            release_updater, "fsync_boot_enablement", side_effect=OSError("fsync")
        ), self.assertRaisesRegex(OSError, "fsync"):
            release_updater.commit_boot_enablement(desired, release_info)
        self.assertNotIn(
            mock.call(release_updater.BOOT_ENABLEMENT_IN_PROGRESS_MARKER),
            durable_unlink.call_args_list,
        )

        with mock.patch.object(
            release_updater, "atomic_json"
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater, "durable_unlink"
        ) as durable_unlink, mock.patch.object(
            release_updater, "enable_unit"
        ), mock.patch.object(
            release_updater, "fsync_boot_enablement"
        ):
            release_updater.commit_boot_enablement(desired, release_info)
        self.assertEqual(
            durable_unlink.call_args_list,
            [
                mock.call(release_updater.ACTIVATION_IN_PROGRESS_MARKER),
                mock.call(release_updater.BOOT_ENABLEMENT_IN_PROGRESS_MARKER),
            ],
        )

    @unittest.skipUnless(os.name == "posix", "legacy retirement runs on Linux CI")
    def test_legacy_current_retirement_is_one_time_quiescent_and_no_rollback(self) -> None:
        import release_updater

        with mock.patch.object(
            release_updater, "unit_exists", return_value=True
        ), mock.patch.object(
            release_updater, "unit_active", return_value=False
        ), mock.patch.object(
            release_updater, "unit_enabled", return_value=False
        ):
            release_updater.require_legacy_retirement_quiescence()

        for unsafe_property in ("unit_active", "unit_enabled"):
            with self.subTest(unsafe_property=unsafe_property), mock.patch.object(
                release_updater, "unit_exists", return_value=True
            ), mock.patch.object(
                release_updater,
                "unit_active",
                return_value=unsafe_property == "unit_active",
            ), mock.patch.object(
                release_updater,
                "unit_enabled",
                return_value=unsafe_property == "unit_enabled",
            ), self.assertRaises(release_updater.UpdaterError):
                release_updater.require_legacy_retirement_quiescence()

        failure_evidence = {
            "legacyCurrentLinkTarget": "releases/legacy-unsigned",
            "legacyResolvedPath": "/opt/uten-imp/releases/legacy-unsigned",
        }
        recovery_arguments = {
            "activation_error": RuntimeError("injected begin failure"),
            "base": Path("/opt/uten-imp"),
            "old_target": Path("/opt/uten-imp/releases/legacy-unsigned"),
            "old_info": None,
            "new_info": {"commitSha": "b" * 40, "version": "v2026.08.11-1"},
            "nginx_was_active": False,
            "active_timers": [],
            "boot_enabled_before": {
                unit: False for unit in release_updater.BOOT_UNITS
            },
            "schema_change_attempted": False,
            "activation_state_commit_started": False,
            "legacy_retirement": True,
            "legacy_current_evidence": failure_evidence,
        }
        for transaction_started in (False, True):
            with self.subTest(
                begin_failure_transaction_started=transaction_started
            ), mock.patch.object(
                release_updater, "persist_fail_closed_activation"
            ) as persist, mock.patch.object(
                release_updater, "restore_after_failure"
            ) as restore:
                release_updater.recover_failed_activation(
                    **recovery_arguments,
                    transaction_started=transaction_started,
                    legacy_retirement_committed=False,
                )
            restore.assert_not_called()
            self.assertEqual(
                persist.call_args.kwargs["reason"],
                "legacy-retirement-preparation-failed",
            )
            self.assertEqual(
                persist.call_args.kwargs["legacy_current_evidence"],
                failure_evidence,
            )

        with mock.patch.object(
            release_updater, "persist_fail_closed_activation"
        ) as persist, mock.patch.object(
            release_updater, "restore_after_failure"
        ) as restore:
            release_updater.recover_failed_activation(
                **recovery_arguments,
                transaction_started=True,
                legacy_retirement_committed=True,
            )
        persist.assert_not_called()
        self.assertIsNone(restore.call_args.kwargs["old_target"])

        committed_recovery_arguments = dict(recovery_arguments)
        committed_recovery_arguments["activation_state_commit_started"] = True
        with mock.patch.object(
            release_updater, "persist_fail_closed_activation"
        ) as persist, mock.patch.object(
            release_updater, "restore_after_failure"
        ) as restore:
            release_updater.recover_failed_activation(
                **committed_recovery_arguments,
                transaction_started=True,
                legacy_retirement_committed=True,
            )
        restore.assert_not_called()
        self.assertEqual(
            persist.call_args.kwargs["reason"], "activation-commit-failed"
        )

        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary) / "opt" / "uten-imp"
            legacy = base / "releases" / "legacy-unsigned"
            legacy.mkdir(parents=True)
            (base / "current").symlink_to(Path("releases") / legacy.name)
            marker = Path(temporary) / "state" / "legacy-current-retirement.json"
            marker.parent.mkdir()
            new_info = {
                "commitSha": "b" * 40,
                "version": "v2026.08.11-1",
            }
            expected_evidence = {
                "legacyCurrentLinkTarget": "releases/legacy-unsigned",
                "legacyResolvedPath": str(legacy.resolve()),
            }
            with mock.patch.object(
                release_updater, "LEGACY_RETIREMENT_MARKER", marker
            ), mock.patch.object(
                release_updater, "require_root_controlled_file"
            ):
                release_updater.record_and_remove_legacy_current(
                    base=base,
                    legacy_target=legacy.resolve(),
                    new_info=new_info,
                    expected_evidence=expected_evidence,
                )
                self.assertFalse(os.path.lexists(base / "current"))
                evidence = json.loads(marker.read_text(encoding="utf-8"))
                self.assertFalse(evidence["rollbackAllowed"])
                self.assertEqual(evidence["replacementVersion"], new_info["version"])
                (base / "current").symlink_to(Path("releases") / legacy.name)
                with self.assertRaisesRegex(
                    release_updater.UpdaterError, "already been recorded"
                ):
                    release_updater.record_and_remove_legacy_current(
                        base=base,
                        legacy_target=legacy.resolve(),
                        new_info=new_info,
                        expected_evidence=expected_evidence,
                    )

        parser = release_updater.parser()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(
                [
                    "activate",
                    "v2026.08.11-1",
                    "--accept-legacy-current",
                ]
            )
        source = (PROJECT_ROOT / "deploy/updater/release_updater.py").read_text(
            encoding="utf-8"
        )
        self.assertIn(release_updater.LEGACY_RETIREMENT_CONFIRMATION, source)
        self.assertIn(
            "old_target=None if legacy_retirement else old_target",
            source,
        )
        self.assertNotIn("--accept-legacy-current", source)

    @unittest.skipUnless(os.name == "posix", "systemd containment runs on Linux CI")
    def test_database_incompatible_recovery_persists_original_boot_state(self) -> None:
        import release_updater

        old_info = {
            "flywayMigrationSetSha256": "a" * 64,
            "flywayHeadVersion": "252",
            "version": "v2026.08.10-1",
        }
        new_info = {
            "commitSha": "b" * 40,
            "flywayMigrationSetSha256": "c" * 64,
            "flywayHeadVersion": "253",
            "version": "v2026.08.11-1",
        }
        enabled = {unit: True for unit in release_updater.BOOT_UNITS}
        with mock.patch.object(release_updater, "stop_unit"), mock.patch.object(
            release_updater, "atomic_current"
        ), mock.patch.object(
            release_updater, "persist_fail_closed_activation"
        ) as persist:
            release_updater.restore_after_failure(
                base=Path("/opt/uten-imp"),
                old_target=Path("/opt/uten-imp/releases/v2026.08.10-1"),
                old_info=old_info,
                new_info=new_info,
                nginx_was_active=True,
                active_timers=list(release_updater.WATCHDOG_TIMERS),
                boot_enabled_before=enabled,
            )
        persist.assert_called_once_with(
            old_info=old_info,
            new_info=new_info,
            boot_enabled_before=enabled,
            reason="database-incompatible",
            current_link_restored=True,
        )

    @unittest.skipUnless(os.name == "posix", "pre-migration recovery runs on Linux CI")
    def test_pre_migration_validation_failure_can_restore_old_release(self) -> None:
        import release_updater

        old_info = {
            "flywayMigrationSetSha256": "a" * 64,
            "flywayHeadVersion": "252",
            "version": "v2026.08.10-1",
        }
        new_info = {
            "commitSha": "b" * 40,
            "flywayMigrationSetSha256": "c" * 64,
            "flywayHeadVersion": "253",
            "version": "v2026.08.11-1",
        }
        enabled = {unit: True for unit in release_updater.BOOT_UNITS}
        with mock.patch.object(release_updater, "stop_unit"), mock.patch.object(
            release_updater, "atomic_current"
        ), mock.patch.object(release_updater, "validate_health"), mock.patch.object(
            release_updater, "run"
        ), mock.patch.object(
            release_updater, "verify_live_signed_database", return_value={"verified": True}
        ), mock.patch.object(
            release_updater, "validate_existing_runtime_authority"
        ), mock.patch.object(
            release_updater, "start_application_authorized"
        ) as app_start, mock.patch.object(
            release_updater, "unit_active", return_value=True
        ), mock.patch.object(release_updater, "start_unit") as start, mock.patch.object(
            release_updater, "commit_boot_enablement"
        ) as commit_enablement, mock.patch.object(
            release_updater, "persist_fail_closed_activation"
        ) as persist:
            release_updater.restore_after_failure(
                base=Path("/opt/uten-imp"),
                old_target=Path("/opt/uten-imp/releases/v2026.08.10-1"),
                old_info=old_info,
                new_info=new_info,
                nginx_was_active=True,
                active_timers=list(release_updater.WATCHDOG_TIMERS),
                boot_enabled_before=enabled,
                schema_change_attempted=False,
            )
        persist.assert_not_called()
        app_start.assert_called_once()
        commit_enablement.assert_called_once_with(enabled, old_info)
        self.assertEqual(
            start.call_args_list,
            [
                *(mock.call(timer) for timer in release_updater.WATCHDOG_TIMERS),
                mock.call("nginx.service"),
            ],
        )

    @unittest.skipUnless(os.name == "posix", "migration containment runs on Linux CI")
    def test_migration_process_failure_never_restarts_old_application(self) -> None:
        import release_updater

        old_info = {
            "flywayMigrationSetSha256": "a" * 64,
            "flywayHeadVersion": "253",
            "version": "v2026.08.10-1",
        }
        new_info = {
            "commitSha": "b" * 40,
            "flywayMigrationSetSha256": "a" * 64,
            "flywayHeadVersion": "253",
            "version": "v2026.08.11-1",
        }
        enabled = {unit: True for unit in release_updater.BOOT_UNITS}
        with mock.patch.object(release_updater, "stop_unit"), mock.patch.object(
            release_updater, "atomic_current"
        ), mock.patch.object(
            release_updater, "start_unit"
        ) as start, mock.patch.object(
            release_updater, "persist_fail_closed_activation"
        ) as persist:
            release_updater.restore_after_failure(
                base=Path("/opt/uten-imp"),
                old_target=Path("/opt/uten-imp/releases/v2026.08.10-1"),
                old_info=old_info,
                new_info=new_info,
                nginx_was_active=True,
                active_timers=list(release_updater.WATCHDOG_TIMERS),
                boot_enabled_before=enabled,
                force_persistent_reason="migration-process-failed",
            )
        start.assert_not_called()
        persist.assert_called_once_with(
            old_info=old_info,
            new_info=new_info,
            boot_enabled_before=enabled,
            reason="migration-process-failed",
            current_link_restored=True,
        )

    @unittest.skipUnless(os.name == "posix", "application unit validation runs on Linux CI")
    def test_application_unit_contract_rejects_privilege_or_command_drift(self) -> None:
        import release_updater

        exec_start = self.systemd_exec_record(
            "/usr/bin/java", release_updater.APPLICATION_EXECSTART_ARGV
        )
        exec_start_pre = " ; ".join(
            self.systemd_exec_record(path, argv)
            for path, argv in release_updater.APPLICATION_EXECSTART_PRE_COMMANDS
        )
        fragment = "[Service]\n" + "\n".join(
            (
                *release_updater.APPLICATION_EXECSTART_PRE_FRAGMENT_LINES,
                release_updater.APPLICATION_EXECSTART_FRAGMENT_LINE,
            )
        )
        properties = {
            "LoadState": "loaded",
            "Type": "simple",
            "Restart": "always",
            "RestartSteps": "5",
            "RestartMaxDelayUSec": "1min",
            "TimeoutStartUSec": "2min",
            "StartLimitIntervalUSec": "10min",
            "StartLimitBurst": "8",
            "StartLimitAction": "none",
            "User": "uten-imp",
            "Group": "uten-imp",
            "FragmentPath": "/etc/systemd/system/uten-imp.service",
            "EnvironmentFiles": "/etc/uten-imp/server.env (ignore_errors=no)",
            "ReadWritePaths": "/run/uten-imp-release",
            "DropInPaths": "",
            "After": (
                "network-online.target data.mount postgresql@16-main.service "
                "uten-imp-recovery-commit-verifier.service"
            ),
            "BindsTo": "data.mount postgresql@16-main.service",
            "PartOf": "postgresql@16-main.service",
            "Requires": (
                "postgresql@16-main.service data.mount "
                "uten-imp-recovery-commit-verifier.service"
            ),
            "ExecStart": exec_start,
            "ExecStartPre": exec_start_pre,
            "ExecCondition": "",
            "ExecStartPost": "",
            "ExecReload": "",
            "ExecStop": "",
            "ExecStopPost": "",
        }
        validator_result = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="\n".join(release_updater.APPLICATION_ENV_VALIDATION_OUTPUT) + "\n",
            stderr="",
        )
        with mock.patch.object(
            release_updater,
            "systemd_property",
            side_effect=lambda _unit, name: properties[name],
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ) as require_root, mock.patch.object(
            release_updater, "run", return_value=validator_result
        ) as run_validator, mock.patch.object(
            type(release_updater.APPLICATION_UNIT_FILE),
            "read_text",
            return_value=fragment,
        ):
            release_updater.assert_application_unit_contract()
        self.assertEqual(
            require_root.call_args_list,
            [
                mock.call(release_updater.APPLICATION_UNIT_FILE),
                mock.call(release_updater.APPLICATION_ENV_VALIDATOR),
            ],
        )
        run_validator.assert_called_once_with(
            [
                str(release_updater.APPLICATION_ENV_VALIDATOR),
                str(release_updater.APPLICATION_ENV_FILE),
            ],
            capture=True,
        )

        unsafe_cases = {
            "root-user": ({"User": "root"}, fragment),
            "drop-in": (
                {"DropInPaths": "/etc/systemd/system/uten-imp.service.d/override.conf"},
                fragment,
            ),
            "server-argument": (
                {
                    "ExecStart": exec_start.replace(
                        "uten-imp-server.jar ;", "uten-imp-server.jar --debug ;"
                    )
                },
                fragment,
            ),
            "extra-pre-command": (
                {
                    "ExecStartPre": exec_start_pre
                    + " ; "
                    + self.systemd_exec_record("/bin/sh", "/bin/sh -c true")
                },
                fragment,
            ),
            "extra-stop-command": (
                {"ExecStop": self.systemd_exec_record("/bin/sh", "/bin/sh -c true")},
                fragment,
            ),
            "marker-root-prefix-removed": (
                {},
                fragment.replace("ExecStartPre=+/usr/bin/test", "ExecStartPre=/usr/bin/test"),
            ),
            "root-java-prefix-added": (
                {},
                fragment.replace("ExecStart=/usr/bin/java", "ExecStart=+/usr/bin/java"),
            ),
            "missing-data-bind": ({"BindsTo": "postgresql@16-main.service"}, fragment),
            "missing-postgres-order": ({"After": "network-online.target data.mount"}, fragment),
        }
        for label, (override, unsafe_fragment) in unsafe_cases.items():
            with self.subTest(label=label):
                unsafe_properties = properties | override
                with mock.patch.object(
                    release_updater,
                    "systemd_property",
                    side_effect=lambda _unit, name: unsafe_properties[name],
                ), mock.patch.object(
                    release_updater, "require_root_controlled_file"
                ), mock.patch.object(
                    release_updater, "run", return_value=validator_result
                ), mock.patch.object(
                    type(release_updater.APPLICATION_UNIT_FILE),
                    "read_text",
                    return_value=unsafe_fragment,
                ), self.assertRaises(release_updater.UpdaterError):
                    release_updater.assert_application_unit_contract()

    def test_postgres_unit_requires_the_exact_pre_write_storage_gate(self) -> None:
        import release_updater

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dropin = root / "uten-imp-storage.conf"
            verifier = root / "storage_boot_verifier.py"
            dropin.write_text(
                "\n".join(release_updater.POSTGRES_STORAGE_DROPIN_LINES) + "\n",
                encoding="utf-8",
            )
            verifier.write_text("# fixed verifier\n", encoding="utf-8")
            safe_details = SimpleNamespace(
                st_gid=0, st_mode=stat.S_IFREG | 0o644, st_nlink=1
            )
            properties = {
                "LoadState": "loaded",
                "User": "postgres",
                "DropInPaths": str(dropin),
                "After": "network.target data.mount",
                "BindsTo": "data.mount",
                "ExecStartPre": self.systemd_exec_record(
                    "/usr/bin/python3",
                    "/usr/bin/python3 -I "
                    "/usr/local/libexec/uten-imp-release/storage_boot_verifier.py",
                ),
            }
            with mock.patch.object(
                release_updater, "POSTGRES_STORAGE_DROPIN_FILE", dropin
            ), mock.patch.object(
                release_updater, "STORAGE_BOOT_VERIFIER", verifier
            ), mock.patch.object(
                release_updater,
                "systemd_property",
                side_effect=lambda _unit, name: properties[name],
            ), mock.patch.object(
                release_updater, "require_root_controlled_file"
            ), mock.patch.object(
                type(verifier), "lstat", return_value=safe_details
            ), mock.patch.object(
                release_updater.release_guard,
                "sha256_file",
                return_value=release_updater.STORAGE_BOOT_VERIFIER_SHA256,
            ):
                release_updater.assert_postgres_storage_unit_contract()
                properties["DropInPaths"] = f"{dropin} /etc/systemd/system/rogue.conf"
                with self.assertRaisesRegex(
                    release_updater.UpdaterError, "unreviewed or missing"
                ):
                    release_updater.assert_postgres_storage_unit_contract()

    def test_storage_observer_requires_generation_specific_device_contract(self) -> None:
        import release_updater

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            authority_path = root / "storage-authority.json"
            helper_path = Path(__file__).with_name("storage_mount_observer.py")
            unit_path = root / "uten-imp-storage-observer.service"
            authority_value = {
                "dataFilesystem": "ext4",
                "dataSource": "/dev/md/uten-data",
                "dataUuid": "12345678-1234-1234-1234-123456789abc",
                "minimumFreeBytes": 2 * 1024**3,
                "minimumFreeInodes": 100_000,
                "mountPoint": "/data",
                "requiredOptions": ["nodev", "noexec", "nosuid", "rw"],
                "schemaVersion": 2,
            }
            authority_raw = (json.dumps(authority_value, sort_keys=True) + "\n").encode()
            authority_path.write_bytes(authority_raw)
            helper_spec = importlib.util.spec_from_file_location(
                "storage_observer_release_fixture", helper_path
            )
            self.assertIsNotNone(helper_spec)
            self.assertIsNotNone(helper_spec.loader)
            helper_module = importlib.util.module_from_spec(helper_spec)
            helper_spec.loader.exec_module(helper_module)
            unit_path.write_text(
                helper_module.render_observer_unit("/dev/md127"), encoding="utf-8"
            )
            properties = {
                "LoadState": "loaded",
                "FragmentPath": str(unit_path),
                "DropInPaths": "",
                "User": "root",
                "DevicePolicy": "closed",
                "PrivateDevices": "no",
                "PrivateNetwork": "yes",
                "ExecStart": f"/usr/bin/python3 -I {helper_path} observe",
            }

            def metadata(path: Path) -> SimpleNamespace:
                mode = 0o640 if Path(path) == authority_path else 0o644
                return SimpleNamespace(
                    st_gid=0, st_mode=stat.S_IFREG | mode, st_nlink=1
                )

            patches = (
                mock.patch.object(release_updater, "STORAGE_MOUNT_OBSERVER", helper_path),
                mock.patch.object(release_updater, "STORAGE_AUTHORITY", authority_path),
                mock.patch.object(release_updater, "STORAGE_OBSERVER_UNIT_FILE", unit_path),
                mock.patch.object(release_updater, "unit_exists", return_value=True),
                mock.patch.object(release_updater, "unit_enabled", return_value=False),
                mock.patch.object(release_updater, "require_root_controlled_file"),
                mock.patch.object(
                    type(helper_path), "lstat", autospec=True, side_effect=metadata
                ),
                mock.patch.object(
                    release_updater.release_guard,
                    "sha256_file",
                    return_value=release_updater.STORAGE_MOUNT_OBSERVER_SHA256,
                ),
                mock.patch.object(
                    release_updater,
                    "read_root_controlled_bytes",
                    side_effect=lambda *_args, **_kwargs: authority_raw,
                ),
                mock.patch.object(
                    release_updater.os.path, "realpath", return_value="/dev/md127"
                ),
                mock.patch.object(
                    release_updater.os,
                    "stat",
                    return_value=SimpleNamespace(st_mode=stat.S_IFBLK | 0o600),
                ),
                mock.patch.object(
                    release_updater,
                    "systemd_property",
                    side_effect=lambda _unit, name: properties[name],
                ),
            )
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], patches[8], patches[9], patches[10], patches[11]:
                release_updater.assert_storage_observer_contract()
                unit_path.write_text(
                    helper_module.render_observer_unit("/dev/md127")
                    + "DeviceAllow=/dev/md126 r\n",
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(
                    release_updater.UpdaterError, "authority-generation"
                ):
                    release_updater.assert_storage_observer_contract()

                authority_v3 = {
                    "approvalReference": "CHG-2026-0812-NVME",
                    "commissioningEvidenceSha256": "a" * 64,
                    "dataFilesystem": "ext4",
                    "dataSource": "/dev/mapper/ubuntu--vg-uten--data",
                    "dataUuid": "12345678-1234-1234-1234-123456789abc",
                    "lvm": {
                        "dmUuid": "LVM-" + "A" * 64,
                        "lvSizeBytes": 350 * 1024**3,
                        "lvUuid": "ABCDEF-abcd-1234-5678-9abc-def0-ABCDEF",
                        "pvCount": 1,
                        "pvUuid": "FEDCBA-abcd-1234-5678-9abc-def0-FEDCBA",
                        "segmentType": "linear",
                        "vgUuid": "AAAAAA-bbbb-2222-3333-4444-5555-CCCCCC",
                    },
                    "minimumFreeBytes": 2 * 1024**3,
                    "minimumFreeInodes": 100_000,
                    "mountPoint": "/data",
                    "nvme": {
                        "namespaceById": "/dev/disk/by-id/nvme-UTEN_NVME",
                        "partitionById": "/dev/disk/by-id/nvme-UTEN_NVME-part3",
                        "partitionNumber": 3,
                        "rotational": False,
                        "serialSha256": "b" * 64,
                        "transport": "nvme",
                    },
                    "requiredOptions": ["nodev", "noexec", "nosuid", "rw"],
                    "schemaVersion": 3,
                    "topology": "lvm-linear-nvme",
                }
                authority_raw = (json.dumps(authority_v3, sort_keys=True) + "\n").encode()
                unit_path.write_text(helper_module.render_observer_unit(None), encoding="utf-8")
                release_updater.assert_storage_observer_contract()
                unit_path.write_text(
                    helper_module.render_observer_unit(None) + "DeviceAllow=/dev/dm-1 r\n",
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(release_updater.UpdaterError, "authority-generation"):
                    release_updater.assert_storage_observer_contract()
                unit_path.write_text(
                    helper_module.render_observer_unit(None), encoding="utf-8"
                )
                properties["PrivateDevices"] = "yes"
                with self.assertRaisesRegex(
                    release_updater.UpdaterError, "sandbox contract"
                ):
                    release_updater.assert_storage_observer_contract()

    @unittest.skipUnless(os.name == "posix", "nginx unit validation runs on Linux CI")
    def test_nginx_unit_contract_rejects_fragment_or_dropin_drift(self) -> None:
        import release_updater

        exec_start = self.systemd_exec_record(
            "/usr/sbin/nginx", release_updater.NGINX_EXECSTART_ARGV
        )
        exec_start_pre = " ; ".join(
            self.systemd_exec_record(path, argv)
            for path, argv in release_updater.NGINX_EXECSTART_PRE_COMMANDS
        )
        dropin = "\n".join(release_updater.NGINX_DROPIN_LINES) + "\n"
        properties = {
            "LoadState": "loaded",
            "Type": "forking",
            "Restart": "no",
            "RestartSteps": "5",
            "RestartMaxDelayUSec": "30s",
            "StartLimitIntervalUSec": "10min",
            "StartLimitBurst": "8",
            "StartLimitAction": "none",
            "FragmentPath": "/usr/lib/systemd/system/nginx.service",
            "DropInPaths": "/etc/systemd/system/nginx.service.d/uten-imp.conf",
            "After": (
                "network-online.target uten-imp.service "
                "uten-imp-recovery-commit-verifier.service"
            ),
            "Requires": "uten-imp-recovery-commit-verifier.service",
            "BindsTo": "uten-imp.service",
            "PartOf": "uten-imp.service",
            "ExecStart": exec_start,
            "ExecStartPre": exec_start_pre,
            "ExecCondition": "",
            "ExecStartPost": " ; ".join(
                self.systemd_exec_record(path, argv)
                for path, argv in release_updater.NGINX_EXECSTART_POST_COMMANDS
            ),
            "ExecStopPost": "",
            "ExecReload": self.systemd_exec_record(
                "/usr/sbin/nginx", release_updater.NGINX_EXECRELOAD_ARGV
            ),
            "ExecStop": self.systemd_exec_record(
                "/sbin/start-stop-daemon",
                release_updater.NGINX_EXECSTOP_ARGV,
            ).replace("ignore_errors=no", "ignore_errors=yes"),
        }
        with mock.patch.object(
            release_updater,
            "systemd_property",
            side_effect=lambda _unit, name: properties[name],
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ) as require_root, mock.patch.object(
            type(release_updater.NGINX_DROPIN_FILE), "read_text", return_value=dropin
        ):
            release_updater.assert_nginx_unit_contract()
        self.assertEqual(
            require_root.call_args_list,
            [
                mock.call(release_updater.NGINX_FRAGMENT_FILE),
                mock.call(release_updater.NGINX_DROPIN_FILE),
                mock.call(release_updater.NGINX_READINESS_GATE),
            ],
        )

        unsafe_cases = {
            "different-fragment": ({"FragmentPath": "/tmp/nginx.service"}, dropin),
            "extra-dropin": (
                {
                    "DropInPaths": (
                        "/etc/systemd/system/nginx.service.d/uten-imp.conf "
                        "/etc/systemd/system/nginx.service.d/debug.conf"
                    )
                },
                dropin,
            ),
            "different-exec": (
                {
                    "ExecStart": self.systemd_exec_record(
                        "/bin/sh", "/bin/sh -c /usr/sbin/nginx"
                    )
                },
                dropin,
            ),
            "missing-marker": (
                {
                    "ExecStartPre": self.systemd_exec_record(
                        *release_updater.NGINX_EXECSTART_PRE_COMMANDS[0]
                    )
                },
                dropin,
            ),
            "extra-stop-post": (
                {
                    "ExecStopPost": self.systemd_exec_record(
                        "/bin/sh", "/bin/sh -c true"
                    )
                },
                dropin,
            ),
            "dropin-content": ({}, dropin.replace("Restart=no", "Restart=always")),
            "missing-app-bind": ({"BindsTo": ""}, dropin),
        }
        for label, (override, unsafe_dropin) in unsafe_cases.items():
            with self.subTest(label=label):
                unsafe_properties = properties | override
                with mock.patch.object(
                    release_updater,
                    "systemd_property",
                    side_effect=lambda _unit, name: unsafe_properties[name],
                ), mock.patch.object(
                    release_updater, "require_root_controlled_file"
                ), mock.patch.object(
                    type(release_updater.NGINX_DROPIN_FILE),
                    "read_text",
                    return_value=unsafe_dropin,
                ), self.assertRaises(release_updater.UpdaterError):
                    release_updater.assert_nginx_unit_contract()

    @unittest.skipUnless(os.name == "posix", "migration oneshot runs on Linux CI")
    def test_migration_oneshot_requires_exact_terminal_success(self) -> None:
        import release_updater

        success = {
            "Result": "success",
            "ExecMainStatus": "0",
            "ActiveState": "inactive",
            "SubState": "dead",
        }
        with mock.patch.object(
            release_updater, "unit_exists", return_value=True
        ), mock.patch.object(release_updater, "run") as run_systemd, mock.patch.object(
            release_updater,
            "systemd_property",
            side_effect=lambda _unit, name: success[name],
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater, "read_root_evidence_bytes", return_value=b"{}\n"
        ), mock.patch.object(
            release_updater, "strict_json_object", return_value={"nonce": "a" * 32}
        ), mock.patch.object(
            release_updater, "validate_migration_authorization"
        ), mock.patch.object(
            release_updater.os.path, "lexists", return_value=False
        ), mock.patch.object(
            release_updater,
            "require_consumed_migration_authorization",
            return_value=(Path("/run/consumed"), {"nonce": "a" * 32}),
        ), mock.patch.object(
            release_updater, "_persist_migration_authorization_terminal"
        ) as persist:
            release_updater.run_migration_unit("a" * 32)
        run_systemd.assert_called_once_with(
            ["systemctl", "start", release_updater.MIGRATION_UNIT]
        )
        persist.assert_called_once_with(
            kind="consumed",
            runtime_archive=Path("/run/consumed"),
            raw=b"{}\n",
            value={"nonce": "a" * 32},
            terminal_state=success,
            status="migration-succeeded",
        )
        with mock.patch.object(
            release_updater, "unit_exists", return_value=True
        ), mock.patch.object(release_updater, "run"), mock.patch.object(
            release_updater,
            "systemd_property",
            side_effect=lambda _unit, name: (
                "failed" if name == "Result" else success[name]
            ),
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater, "read_root_evidence_bytes", return_value=b"{}\n"
        ), mock.patch.object(
            release_updater, "strict_json_object", return_value={"nonce": "a" * 32}
        ), mock.patch.object(
            release_updater, "validate_migration_authorization"
        ), mock.patch.object(
            release_updater.os.path, "lexists", return_value=False
        ), mock.patch.object(
            release_updater,
            "require_consumed_migration_authorization",
            return_value=(Path("/run/consumed"), {"nonce": "a" * 32}),
        ), mock.patch.object(
            release_updater, "_persist_migration_authorization_terminal"
        ) as persist, self.assertRaises(release_updater.MigrationUnitError):
            release_updater.run_migration_unit("a" * 32)
        failed = dict(success)
        failed["Result"] = "failed"
        persist.assert_called_once_with(
            kind="consumed",
            runtime_archive=Path("/run/consumed"),
            raw=b"{}\n",
            value={"nonce": "a" * 32},
            terminal_state=failed,
            status="migration-failed",
        )

        with mock.patch.object(
            release_updater, "unit_exists", return_value=True
        ), mock.patch.object(release_updater, "run"), mock.patch.object(
            release_updater,
            "systemd_property",
            side_effect=lambda _unit, name: success[name],
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater, "read_root_evidence_bytes", return_value=b"{}\n"
        ), mock.patch.object(
            release_updater, "strict_json_object", return_value={"nonce": "a" * 32}
        ), mock.patch.object(
            release_updater, "validate_migration_authorization"
        ), mock.patch.object(
            release_updater.os.path, "lexists", return_value=True
        ), mock.patch.object(
            release_updater, "_persist_migration_authorization_terminal"
        ) as persist, self.assertRaisesRegex(
            release_updater.MigrationUnitError, "without consuming"
        ):
            release_updater.run_migration_unit("a" * 32)
        persist.assert_not_called()

    @unittest.skipUnless(os.name == "posix", "migration evidence durability runs on Linux CI")
    def test_migration_terminal_evidence_persists_exact_bytes_before_run_cleanup(self) -> None:
        import release_updater

        raw = b'{"nonce":"' + b"6" * 32 + b'"}\n'
        digest = hashlib.sha256(raw).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            transaction = root / "transaction"
            transaction.mkdir()
            issued = transaction / "authorization.issued.json"
            issued.write_bytes(raw)
            runtime = root / (
                f"migration-authorization.consumed-{'6' * 32}-{digest}.json"
            )
            runtime.write_bytes(raw)
            value = {"nonce": "6" * 32, "markerSha256": "7" * 64}

            def read_bytes(path: Path, **_kwargs: object) -> bytes:
                return Path(path).read_bytes()

            with mock.patch.object(
                release_updater,
                "_migration_authorization_runtime_path",
                return_value=runtime,
            ), mock.patch.object(
                release_updater,
                "_migration_authorization_transaction",
                return_value=(transaction, issued),
            ), mock.patch.object(
                release_updater, "read_root_evidence_bytes", side_effect=read_bytes
            ), mock.patch.object(
                release_updater, "require_root_controlled_file"
            ), mock.patch.object(
                release_updater, "fsync_directory"
            ) as fsync:
                release_updater._persist_migration_authorization_terminal(
                    kind="consumed",
                    runtime_archive=runtime,
                    raw=raw,
                    value=value,
                    terminal_state={
                        "ActiveState": "inactive",
                        "ExecMainStatus": "0",
                        "Result": "success",
                        "SubState": "dead",
                    },
                    status="migration-succeeded",
                )

            persisted = transaction / "authorization.consumed.json"
            self.assertEqual(persisted.read_bytes(), raw)
            self.assertFalse(issued.exists())
            self.assertFalse(runtime.exists())
            receipt = json.loads((transaction / "terminal.json").read_text(encoding="utf-8"))
            self.assertEqual(receipt["authorizationSha256"], digest)
            self.assertEqual(receipt["status"], "migration-succeeded")
            self.assertGreaterEqual(fsync.call_count, 2)

    def test_failed_activation_preserves_marker_for_outstanding_migration_grant(self) -> None:
        import release_updater

        with mock.patch.object(
            release_updater.os.path, "lexists", return_value=True
        ), mock.patch.object(
            release_updater,
            "_migration_authorization_entries",
            return_value=[Path("/run/uten-imp-migration-authorization/consumed.json")],
        ), mock.patch.object(
            release_updater, "_stop_and_disable_for_interrupted_containment"
        ) as contain, mock.patch.object(
            release_updater, "persist_fail_closed_activation"
        ) as persist, mock.patch.object(
            release_updater, "restore_after_failure"
        ) as restore:
            release_updater.recover_failed_activation(
                activation_error=RuntimeError("terminal fsync failed"),
                base=Path("/opt/uten-imp"),
                old_target=Path("/opt/uten-imp/releases/v2026.08.11-1"),
                old_info=None,
                new_info={},
                nginx_was_active=False,
                active_timers=[],
                boot_enabled_before={
                    unit: True for unit in release_updater.BOOT_UNITS
                },
                transaction_started=True,
                schema_change_attempted=True,
                activation_state_commit_started=False,
                legacy_retirement=False,
                legacy_retirement_committed=False,
                legacy_current_evidence=None,
            )
        contain.assert_called_once_with()
        persist.assert_not_called()
        restore.assert_not_called()

    def test_setup_phases_pin_migration_helper_before_installation(self) -> None:
        helper_bytes = (
            PROJECT_ROOT / "deploy/updater/migration_authorization.py"
        ).read_bytes()
        # Production bundles come from Linux CI and the reviewed pin is over
        # canonical LF bytes. Keep Windows discovery useful even when a local
        # Git checkout applies core.autocrlf; such a tree still cannot pass the
        # Phase 3/4 raw-byte production preflight.
        helper_digest = hashlib.sha256(helper_bytes.replace(b"\r\n", b"\n")).hexdigest()
        cases = (
            (
                PROJECT_ROOT / "deploy/setup/phase3-runtime.sh",
                "migration authorization helper differs from the fixed Phase 3 digest",
                '"$DEPLOY_ROOT/updater/migration_authorization.py"',
            ),
            (
                PROJECT_ROOT / "deploy/setup/phase4-updater-nginx.sh",
                "migration authorization helper differs from the fixed Phase 4 digest",
                '"$MIGRATION_AUTHORIZATION_HELPER_SOURCE"',
            ),
        )
        for path, preinstall_failure, install_command in cases:
            with self.subTest(path=path.name):
                source = path.read_text(encoding="utf-8")
                match = re.search(
                    r"^readonly MIGRATION_AUTHORIZATION_HELPER_SHA256='([0-9a-f]{64})'$",
                    source,
                    re.MULTILINE,
                )
                self.assertIsNotNone(match)
                self.assertEqual(match.group(1), helper_digest)
                digest_gate = source.index(preinstall_failure)
                self.assertLess(
                    digest_gate, source.index(install_command, digest_gate)
                )

    @unittest.skipUnless(os.name == "posix", "migration unit validation runs on Linux CI")
    def test_migration_unit_contract_rejects_runtime_override(self) -> None:
        import release_updater

        expected_exec_start = self.systemd_exec_record(
            "/usr/bin/java", release_updater.MIGRATION_EXECSTART_ARGV
        )
        expected_exec_start_pre = " ; ".join(
            self.systemd_exec_record(path, argv)
            for path, argv in release_updater.MIGRATION_EXECSTART_PRE_COMMANDS
        )
        expected_fragment = "[Service]\n" + "\n".join(
            (
                *release_updater.MIGRATION_EXECSTART_PRE_FRAGMENT_LINES,
                release_updater.MIGRATION_EXECSTART_FRAGMENT_LINE,
            )
        )
        properties = {
            "LoadState": "loaded",
            "Type": "oneshot",
            "RemainAfterExit": "no",
            "Restart": "no",
            "User": "uten-imp-migrate",
            "Group": "uten-imp-migrate",
            "FragmentPath": "/etc/systemd/system/uten-imp-migrate.service",
            "EnvironmentFiles": "/etc/uten-imp-migrator/migrator.env (ignore_errors=no)",
            "ReadWritePaths": "/run/uten-imp-migration-authorization",
            "DropInPaths": "",
            "After": "network-online.target data.mount postgresql@16-main.service",
            "Wants": "network-online.target",
            "Requires": "",
            "Requisite": "",
            "BindsTo": "",
            "PartOf": "",
            "Upholds": "",
            "RequiresMountsFor": "",
            "ExecStart": expected_exec_start,
            "ExecStartPre": expected_exec_start_pre,
            "ExecCondition": "",
            "ExecStartPost": "",
            "ExecReload": "",
            "ExecStop": "",
            "ExecStopPost": "",
        }
        validator_result = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=(
                "MIGRATOR_ENV_CONFIGURATION_OK\n"
                "The file is isolated from the application account and contains no database URL or role override.\n"
            ),
            stderr="",
        )
        with mock.patch.object(
            release_updater,
            "systemd_property",
            side_effect=lambda _unit, name: properties[name],
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ) as require_root, mock.patch.object(
            release_updater, "run", return_value=validator_result
        ) as run_validator, mock.patch.object(
            type(release_updater.MIGRATION_UNIT_FILE),
            "read_text",
            return_value=expected_fragment,
        ), mock.patch.object(
            release_updater, "require_migration_authorization_helper"
        ):
            release_updater.assert_migration_unit_contract()
        self.assertEqual(
            require_root.call_args_list,
            [
                mock.call(release_updater.MIGRATION_UNIT_FILE),
                mock.call(release_updater.MIGRATION_ENV_VALIDATOR),
            ],
        )
        run_validator.assert_not_called()
        with mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater, "run", return_value=validator_result
        ) as run_validator:
            release_updater.validate_migration_environment()
        run_validator.assert_called_once_with(
            [str(release_updater.MIGRATION_ENV_VALIDATOR), str(release_updater.MIGRATION_ENV_FILE)],
            capture=True,
        )

        unsafe_overrides = {
            "drop-in": (
                {
                    "DropInPaths": "/etc/systemd/system/uten-imp-migrate.service.d/override.conf"
                },
                expected_fragment,
            ),
            "root-user": ({"User": "root"}, expected_fragment),
            "extra-argument": (
                {
                    "ExecStart": expected_exec_start.replace(
                        "uten-imp-migrator.jar ;", "uten-imp-migrator.jar --repair ;"
                    )
                },
                expected_fragment,
            ),
            "different-jar": (
                {
                    "ExecStart": expected_exec_start.replace(
                        "uten-imp-migrator.jar", "uten-imp-server.jar"
                    )
                },
                expected_fragment,
            ),
            "extra-pre-command": (
                {
                    "ExecStartPre": expected_exec_start_pre
                    + " ; "
                    + self.systemd_exec_record("/bin/sh", "/bin/sh -c true")
                },
                expected_fragment,
            ),
            "extra-stop-command": (
                {"ExecStop": self.systemd_exec_record("/bin/sh", "/bin/sh -c true")},
                expected_fragment,
            ),
            "root-prefix-removed": (
                {},
                expected_fragment.replace("ExecStartPre=+/usr/bin/test", "ExecStartPre=/usr/bin/test"),
            ),
            "root-java-prefix-added": (
                {},
                expected_fragment.replace("ExecStart=/usr/bin/java", "ExecStart=+/usr/bin/java"),
            ),
            "pulls-postgresql": (
                {"Requires": release_updater.POSTGRES_UNIT},
                expected_fragment,
            ),
            "pulls-data-mount": (
                {"BindsTo": "data.mount"},
                expected_fragment,
            ),
            "requires-data-path": (
                {"RequiresMountsFor": "/data"},
                expected_fragment,
            ),
            "unreviewed-wants": (
                {"Wants": "network-online.target postgresql@16-main.service"},
                expected_fragment,
            ),
        }
        for label, (override, fragment) in unsafe_overrides.items():
            with self.subTest(label=label):
                unsafe = properties | override
                with mock.patch.object(
                    release_updater,
                    "systemd_property",
                    side_effect=lambda _unit, name: unsafe[name],
                ), mock.patch.object(
                    release_updater, "require_root_controlled_file"
                ), mock.patch.object(
                    release_updater, "run", return_value=validator_result
                ), mock.patch.object(
                    type(release_updater.MIGRATION_UNIT_FILE),
                    "read_text",
                    return_value=fragment,
                ), mock.patch.object(
                    release_updater, "require_migration_authorization_helper"
                ), self.assertRaises(release_updater.UpdaterError):
                    release_updater.assert_migration_unit_contract()

        source = (PROJECT_ROOT / "deploy/updater/release_updater.py").read_text(
            encoding="utf-8"
        )
        tree = ast.parse(source)
        privilege_assertion = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef)
            and node.name == "assert_privilege_separation"
        )
        delegated_contracts = {
            node.func.id
            for node in ast.walk(privilege_assertion)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
        }
        self.assertTrue(
            {
                "assert_application_unit_contract",
                "assert_database_boot_contract",
                "assert_migration_unit_contract",
                "assert_nginx_unit_contract",
            }.issubset(delegated_contracts)
        )

    @unittest.skipUnless(os.name == "posix", "systemd containment runs on Linux CI")
    def test_persistent_failure_gate_disables_restart_eligibility(self) -> None:
        import release_updater

        old_info = {
            "flywayMigrationSetSha256": "a" * 64,
            "flywayHeadVersion": "252",
            "version": "v2026.08.10-1",
        }
        new_info = {
            "commitSha": "b" * 40,
            "flywayMigrationSetSha256": "c" * 64,
            "flywayHeadVersion": "253",
            "version": "v2026.08.11-1",
        }
        enabled = {unit: True for unit in release_updater.BOOT_UNITS}
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "activation-failed.json"
            with mock.patch.object(
                release_updater, "ACTIVATION_FAILURE_MARKER", marker
            ), mock.patch.object(
                release_updater, "require_root_controlled_file"
            ), mock.patch.object(
                release_updater, "stop_unit"
            ) as stop, mock.patch.object(
                release_updater, "unit_exists", return_value=True
            ), mock.patch.object(
                release_updater, "unit_enabled", return_value=False
            ), mock.patch.object(
                release_updater, "unit_active", return_value=False
            ), mock.patch.object(
                release_updater, "run"
            ) as run_systemd, mock.patch.object(
                release_updater, "log"
            ):
                release_updater.persist_fail_closed_activation(
                    old_info=old_info,
                    new_info=new_info,
                    boot_enabled_before=enabled,
                    reason="database-incompatible",
                    current_link_restored=True,
                )
            evidence = json.loads(marker.read_text(encoding="utf-8"))
        self.assertEqual(evidence["originalBootEnablement"], enabled)
        self.assertEqual(evidence["reason"], "database-incompatible")
        self.assertTrue(evidence["recoveryRequired"])
        for unit in release_updater.BOOT_UNITS:
            run_systemd.assert_any_call(["systemctl", "disable", unit])
        self.assertGreaterEqual(stop.call_count, len(release_updater.BOOT_UNITS))

    def recovery_state_fixture(self, release_updater):
        version = "v2026.08.11-1"
        commit = "b" * 40
        migration_digest = "c" * 64
        manifest_digest = "d" * 64
        boot_map = {unit: True for unit in release_updater.BOOT_UNITS}
        marker_fields = {
            "currentLinkRestored": False,
            "failedAtUtc": "2026-08-11T08:00:00Z",
            "failedCommitSha": commit,
            "failedFlywayHeadVersion": "253",
            "failedFlywayMigrationSetSha256": migration_digest,
            "failedVersion": version,
            "originalBootEnablement": boot_map,
            "previousFlywayHeadVersion": "252",
            "previousFlywayMigrationSetSha256": "e" * 64,
            "previousVersion": "v2026.08.10-1",
            "reason": "activation-commit-failed",
            "recoveryRequired": True,
            "schemaVersion": 1,
        }
        target_path = release_updater.DEFAULT_RELEASE_BASE / "releases" / version
        manifest = {
            "commitSha": commit,
            "flywayHeadVersion": "253",
            "flywayMigrationCount": 2,
            "flywayMigrationSetSha256": migration_digest,
            "manifestSha256": manifest_digest,
            "path": str(target_path),
            "releaseSequence": 20260811001,
            "signingKeyId": "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "verified": True,
            "version": version,
        }
        active_fields = {
            "activatedAtUtc": "2026-08-11T08:05:00Z",
            "commitSha": commit,
            "databaseChanged": True,
            "flywayHeadVersion": "253",
            "flywayMigrationSetSha256": migration_digest,
            "manifestSha256": manifest_digest,
            "releaseSequence": 20260811001,
            "version": version,
        }
        controlled_units = tuple(
            dict.fromkeys(
                (
                    *release_updater.BOOT_UNITS,
                    *release_updater.WATCHDOG_SERVICES,
                    release_updater.MIGRATION_UNIT,
                )
            )
        )
        return {
            "activationFailure": {
                "fields": marker_fields,
                "path": str(release_updater.ACTIVATION_FAILURE_MARKER),
                "schemaKind": "activation-failure-v1",
                "sha256": "a" * 64,
                "sizeBytes": 1024,
            },
            "activationInProgress": None,
            "active": {
                "fields": active_fields,
                "path": str(release_updater.DEFAULT_ROOT_STATE_DIR / "active.json"),
                "present": True,
                "schemaKind": "active-release-v1",
                "sha256": "f" * 64,
                "sizeBytes": 512,
                "valid": True,
            },
            "bootEnablementInProgress": None,
            "current": {
                "linkPath": str(release_updater.DEFAULT_RELEASE_BASE / "current"),
                "targetPath": str(target_path),
            },
            "manifests": {version: manifest},
            "paths": {
                "allowedSigners": str(release_updater.DEFAULT_ALLOWED_SIGNERS),
                "databaseReceipts": str(
                    release_updater.RECOVERY_DATABASE_RECEIPTS_DIR
                ),
                "operationLock": str(release_updater.DEFAULT_LOCK_FILE),
                "releaseBase": str(release_updater.DEFAULT_RELEASE_BASE),
                "recoveryEvidence": str(release_updater.RECOVERY_EVIDENCE_DIR),
                "rootState": str(release_updater.DEFAULT_ROOT_STATE_DIR),
            },
            "recoveryInProgress": None,
            "recoveryStorage": {
                "databaseReceipts": {
                    "mode": "0700",
                    "path": str(release_updater.RECOVERY_DATABASE_RECEIPTS_DIR),
                    "safe": True,
                },
                "evidence": {
                    "mode": "0700",
                    "path": str(release_updater.RECOVERY_EVIDENCE_DIR),
                    "safe": True,
                },
            },
            "trust": {
                "allowedSignerKeyIds": [
                    "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                ],
                "allowedSignersSha256": "7" * 64,
            },
            "units": {
                unit: {"active": False, "enabled": False, "exists": True}
                for unit in controlled_units
            },
        }

    def recovery_full_manifest_fixture(self, release_updater, observed_manifest):
        migrations = [
            {
                "description": "refresh_audit_trigger_coverage",
                "file": "V252__refresh_audit_trigger_coverage.sql",
                "flywayChecksum": -1200,
                "sha256": "1" * 64,
                "version": "252",
            },
            {
                "description": "website_inquiries",
                "file": "V253__website_inquiries.sql",
                "flywayChecksum": 25300,
                "sha256": "2" * 64,
                "version": "253",
            },
        ]
        # release_guard.validate_manifest returns the signed fields and rows;
        # observe_installed_release adds these two derived observation fields.
        full_manifest = dict(observed_manifest)
        full_manifest.pop("flywayMigrationCount", None)
        full_manifest.pop("manifestSha256", None)
        full_manifest["flywayMigrations"] = migrations
        return full_manifest

    def recovery_previous_manifest_fixture(self, release_updater):
        version = "v2026.08.10-1"
        return {
            "commitSha": "e" * 40,
            "flywayHeadVersion": "252",
            "flywayMigrationCount": 1,
            "flywayMigrationSetSha256": "e" * 64,
            "manifestSha256": "6" * 64,
            "path": str(release_updater.DEFAULT_RELEASE_BASE / "releases" / version),
            "releaseSequence": 20260810001,
            "signingKeyId": "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "verified": True,
            "version": version,
        }

    def recovery_previous_full_manifest_fixture(self, release_updater, observed_manifest):
        full_manifest = dict(observed_manifest)
        full_manifest.pop("flywayMigrationCount", None)
        full_manifest.pop("manifestSha256", None)
        full_manifest["flywayMigrations"] = [
            {
                "description": "refresh_audit_trigger_coverage",
                "file": "V252__refresh_audit_trigger_coverage.sql",
                "flywayChecksum": -1200,
                "sha256": "1" * 64,
                "version": "252",
            }
        ]
        return full_manifest

    def recovery_live_database_fixture(self, full_manifest):
        return {
            "archiveCommand": "pgbackrest --stanza=uten-imp archive-push %p",
            "archiveMode": "on",
            "configFile": "/etc/postgresql/16/main/postgresql.conf",
            "dataDirectory": "/data/postgresql/16/main",
            "databaseName": "uten_imp",
            "flywayHistory": [
                {
                    "checksum": migration["flywayChecksum"],
                    "description": migration["description"],
                    "installedRank": index,
                    "script": migration["file"],
                    "success": True,
                    "type": "SQL",
                    "version": migration["version"],
                }
                for index, migration in enumerate(
                    full_manifest["flywayMigrations"], start=1
                )
            ],
            "hbaFile": "/etc/postgresql/16/main/pg_hba.conf",
            "inRecovery": False,
            "listenAddresses": "127.0.0.1,::1",
            "postmasterPid": 1234,
            "roleAclContract": {},
            "schemaName": "public",
            "schemaVersion": 1,
            "serverPort": 5432,
            "serverVersionNum": 160010,
            "systemdMainPid": 1234,
            "systemIdentifier": "7523456789012345678",
            "tcpListenerPid": 1234,
            "timeline": 1,
        }

    def recovery_detail_fixture(
        self, release_updater, observed_manifest, full_manifest, *, signature_sha="6" * 64
    ):
        live = self.recovery_live_database_fixture(full_manifest)
        flyway = release_updater.canonical_live_flyway_identity(
            live["flywayHistory"], full_manifest
        )
        checks = {
            name: {"status": "PASS", "evidenceReference": f"approved/{name}/evidence"}
            for name in release_updater.REQUIRED_DATABASE_BUSINESS_CHECKS
        }
        restore_points = [
            {
                "label": f"backup-{index}",
                "stopEpoch": 1_700_000_000 + index,
                "walStart": "000000010000000000000001",
                "walStop": "000000010000000000000002",
            }
            for index in range(7)
        ]
        restore_point_labels = [point["label"] for point in restore_points]
        latest_restore_point = restore_points[-1]
        return {
            "activeRepo2Preflight": {"status": "PASS"},
            "approvalReference": "CAB-2026-0811",
            "completedAtUtc": "2026-08-11T07:30:00Z",
            "continuousWal": {
                "archivedCount": 7,
                "currentWal": "000000010000000000000003",
                "failedCount": 0,
                "lastArchivedWal": "000000010000000000000002",
                "latestArchiveSuccessAgeSeconds": 10,
                "latestArchiveSuccessEpoch": 1_700_000_000,
                "nowEpoch": 1_700_000_010,
                "systemIdentifier": live["systemIdentifier"],
                "timeline": live["timeline"],
            },
            "databaseIdentity": {
                "flyway": flyway,
                "systemIdentifier": live["systemIdentifier"],
                "timeline": live["timeline"],
            },
            "externalAlertDeliveryVerifiedSeparately": True,
            "externalAlertEvidence": {
                "eventId": "backup-health-1",
                "eventSha256": "3" * 64,
                "providerMessageId": "provider-1",
                "receiptSha256": "4" * 64,
            },
            "flywayHeadVersion": observed_manifest["flywayHeadVersion"],
            "flywayMigrationCount": observed_manifest["flywayMigrationCount"],
            "flywayMigrationSetSha256": observed_manifest["flywayMigrationSetSha256"],
            "healthReportSha256": "5" * 64,
            "isolatedPitrEvidence": {
                "actualRpoSeconds": 30,
                "actualRtoSeconds": 120,
                "backupSet": "20260811-010101F",
                "businessAcceptanceSha256": "7" * 64,
                "checks": checks,
                "repository": 2,
                "restoreReceiptSha256": "8" * 64,
                "targetTimeUtc": "2026-08-11T07:00:00Z",
                "walStart": "000000010000000000000001",
                "walStop": "000000010000000000000002",
            },
            "isolatedRepo2PitrVerifiedSeparately": True,
            "receiptType": "backup-acceptance-detail",
            "remoteImmutabilityVerifiedSeparately": True,
            "repositories": [
                {
                    "databaseId": 1,
                    "latestArchivedWal": "000000010000000000000003",
                    "latestSuccessfulFullAgeSeconds": 10,
                    "latestSuccessfulFullLabel": latest_restore_point["label"],
                    "latestSuccessfulFullStopEpoch": latest_restore_point["stopEpoch"],
                    "latestSuccessfulFullWalStart": latest_restore_point["walStart"],
                    "latestSuccessfulFullWalStop": latest_restore_point["walStop"],
                    "repo": repo,
                    "restorePoints": restore_points,
                    "successfulFullRestorePointLabels": restore_point_labels,
                    "successfulFullRestorePoints": 7,
                }
                for repo in (1, 2)
            ],
            "schemaVersion": 1,
            "signedReleaseEvidence": {
                "flywayRowsSha256": flyway["signedProjectionSha256"],
                "manifestSha256": observed_manifest["manifestSha256"],
                "migrationSetSha256": observed_manifest["flywayMigrationSetSha256"],
                "signatureSha256": signature_sha,
            },
            "successful": True,
            "targetVersion": observed_manifest["version"],
            "wormEvidence": {"status": "VERIFIED"},
            "wormEvidenceSha256": "9" * 64,
        }

    @unittest.skipUnless(os.name == "posix", "recovery evidence runs on Linux CI")
    def test_recovery_marker_schema_and_strict_json_are_fail_closed(self) -> None:
        import release_updater

        state = self.recovery_state_fixture(release_updater)
        marker = state["activationFailure"]["fields"]
        self.assertEqual(
            release_updater.validate_activation_failure_marker(marker),
            "activation-failure-v1",
        )
        unknown = dict(marker)
        unknown["operatorCleared"] = True
        with self.assertRaisesRegex(release_updater.UpdaterError, "unknown schema"):
            release_updater.validate_activation_failure_marker(unknown)
        boolean_schema = dict(marker)
        boolean_schema["schemaVersion"] = True
        with self.assertRaisesRegex(release_updater.UpdaterError, "schema is unsupported"):
            release_updater.validate_activation_failure_marker(boolean_schema)
        with self.assertRaisesRegex(release_updater.UpdaterError, "duplicate JSON key"):
            release_updater.strict_json_object(
                b'{"schemaVersion":1,"schemaVersion":1}', "fixture marker"
            )

    @unittest.skipUnless(os.name == "posix", "systemd observations run on Linux CI")
    def test_recovery_unit_observation_never_maps_query_failure_to_safe(self) -> None:
        import release_updater

        with mock.patch.object(
            release_updater,
            "systemd_property",
            side_effect=["loaded", None, "disabled"],
        ):
            observation = release_updater.observe_recovery_unit("uten-imp.service")
        self.assertTrue(observation["exists"])
        self.assertIsNone(observation["active"])
        self.assertIsNone(observation["enabled"])
        self.assertIn("error", observation)

        state = self.recovery_state_fixture(release_updater)
        state["units"]["uten-imp.service"] = observation
        assessment = release_updater.finalize_recovery_assessment(state)
        finish = assessment["actions"]["finish-activation"]
        self.assertFalse(finish["allowed"])
        self.assertTrue(
            any("unit state is indeterminate" in reason for reason in finish["reasons"])
        )

    @unittest.skipUnless(os.name == "posix", "recovery plans run on Linux CI")
    def test_recovery_plan_is_deterministic_and_retry_is_explicit_no_go(self) -> None:
        import release_updater

        state = self.recovery_state_fixture(release_updater)
        first = release_updater.finalize_recovery_assessment(state)
        second = release_updater.finalize_recovery_assessment(
            json.loads(json.dumps(state))
        )
        self.assertEqual(first["planSha256"], second["planSha256"])
        self.assertTrue(first["actions"]["finish-activation"]["allowed"])
        self.assertFalse(first["actions"]["retry-activation"]["allowed"])
        self.assertIn(
            first["planSha256"],
            first["actions"]["finish-activation"]["requiredConfirmation"],
        )

        self.assertTrue(
            set(release_updater.DATABASE_BOOT_UNITS).isdisjoint(state["units"])
        )

        changed = json.loads(json.dumps(state))
        changed["active"]["fields"]["manifestSha256"] = "0" * 64
        changed_assessment = release_updater.finalize_recovery_assessment(changed)
        self.assertNotEqual(first["planSha256"], changed_assessment["planSha256"])
        self.assertFalse(changed_assessment["actions"]["finish-activation"]["allowed"])

    @unittest.skipUnless(os.name == "posix", "previous recovery plans run on Linux CI")
    def test_previous_restore_and_preparation_abandon_are_evidence_bound(self) -> None:
        import release_updater

        for reason in (
            "activation-preparation-failed",
            "activation-commit-failed",
            "current-restore-failed",
            "database-incompatible",
            "migration-process-failed",
            "previous-release-recovery-failed",
        ):
            with self.subTest(reason=reason):
                state = self.recovery_state_fixture(release_updater)
                previous = self.recovery_previous_manifest_fixture(release_updater)
                state["manifests"][previous["version"]] = previous
                state["activationFailure"]["fields"]["reason"] = reason
                assessment = release_updater.finalize_recovery_assessment(state)
                restore = assessment["actions"]["restore-previous"]
                self.assertTrue(restore["allowed"], restore["reasons"])
                self.assertEqual(restore["targetVersion"], previous["version"])
                self.assertIn(
                    assessment["planSha256"], restore["requiredConfirmation"]
                )

        state = self.recovery_state_fixture(release_updater)
        previous = self.recovery_previous_manifest_fixture(release_updater)
        state["manifests"][previous["version"]] = previous
        state["activationFailure"] = {
            **state["activationFailure"],
            "fields": {
                "failedAtUtc": "2026-08-11T08:00:00Z",
                "failedCommitSha": state["activationFailure"]["fields"][
                    "failedCommitSha"
                ],
                "failedVersion": state["activationFailure"]["fields"]["failedVersion"],
                "originalBootEnablement": state["activationFailure"]["fields"][
                    "originalBootEnablement"
                ],
                "previousVersion": previous["version"],
                "reason": "activation-preparing",
                "recoveryRequired": True,
                "schemaVersion": 1,
            },
            "schemaKind": "activation-preparing-v1",
        }
        state["current"]["targetPath"] = previous["path"]
        state["active"]["fields"] = {
            "activatedAtUtc": "2026-08-10T08:00:00Z",
            "commitSha": previous["commitSha"],
            "databaseChanged": False,
            "flywayHeadVersion": previous["flywayHeadVersion"],
            "flywayMigrationSetSha256": previous["flywayMigrationSetSha256"],
            "manifestSha256": previous["manifestSha256"],
            "releaseSequence": previous["releaseSequence"],
            "version": previous["version"],
        }
        assessment = release_updater.finalize_recovery_assessment(state)
        self.assertTrue(assessment["actions"]["abandon-candidate"]["allowed"])
        self.assertFalse(assessment["actions"]["restore-previous"]["allowed"])

        first_release = self.recovery_state_fixture(release_updater)
        first_fields = first_release["activationFailure"]["fields"]
        first_fields["previousVersion"] = None
        first_fields["previousFlywayHeadVersion"] = None
        first_fields["previousFlywayMigrationSetSha256"] = None
        first_fields["reason"] = "first-release-failed"
        first_release_assessment = release_updater.finalize_recovery_assessment(
            first_release
        )
        self.assertFalse(
            first_release_assessment["actions"]["restore-previous"]["allowed"]
        )
        self.assertTrue(
            first_release_assessment["actions"]["remain-contained"]["allowed"]
        )

    @unittest.skipUnless(os.name == "posix", "contained recovery plans run on Linux CI")
    def test_contained_interrupted_activation_can_restore_previous_but_not_guess(self) -> None:
        import release_updater

        state = self.recovery_state_fixture(release_updater)
        failed = state["activationFailure"]["fields"]
        previous = self.recovery_previous_manifest_fixture(release_updater)
        state["manifests"][previous["version"]] = previous
        activation_fields = {
            "commitSha": failed["failedCommitSha"],
            "originalBootEnablement": failed["originalBootEnablement"],
            "previousVersion": previous["version"],
            "releaseSequence": 20260811001,
            "schemaVersion": 1,
            "startedAtUtc": "2026-08-11T08:00:00Z",
            "version": failed["failedVersion"],
        }
        contained_marker = {
            "fields": {
                "containmentStartedAtUtc": "2026-08-11T08:10:00Z",
                "interruptedMarkerSha256": {"activation": "1" * 64},
                "planSha256": "2" * 64,
                "reason": "interrupted-transaction-containment",
                "recoveryRequired": True,
                "schemaVersion": 1,
                "startAuthorization": None,
                "stateKind": "activation",
                "transactionDirectory": str(
                    release_updater.RECOVERY_EVIDENCE_DIR / ("interrupted-" + "2" * 64)
                ),
            },
            "path": str(release_updater.ACTIVATION_FAILURE_MARKER),
            "schemaKind": "interrupted-containment-v1",
            "sha256": "3" * 64,
            "sizeBytes": 512,
        }
        interrupted = {
            "planSha256": "2" * 64,
            "state": {
                "markers": {
                    "activation": {
                        "fields": activation_fields,
                        "path": str(release_updater.ACTIVATION_IN_PROGRESS_MARKER),
                        "schemaKind": "activation-in-progress-v1",
                        "sha256": "1" * 64,
                        "sizeBytes": 512,
                    }
                },
                "receipt": {"sha256": "4" * 64},
                "stateKind": "activation",
                "transactionDirectory": contained_marker["fields"][
                    "transactionDirectory"
                ],
            },
        }
        state["activationFailure"] = contained_marker
        state["interruptedContainment"] = interrupted
        state["recoveryContext"] = release_updater.derive_recovery_context(
            contained_marker, interrupted
        )
        assessment = release_updater.finalize_recovery_assessment(state)
        self.assertTrue(assessment["actions"]["restore-previous"]["allowed"])
        self.assertFalse(assessment["actions"]["finish-activation"]["allowed"])

        interrupted["state"]["receipt"] = None
        state["recoveryContext"] = release_updater.derive_recovery_context(
            contained_marker, interrupted
        )
        no_receipt = release_updater.finalize_recovery_assessment(state)
        self.assertFalse(no_receipt["actions"]["restore-previous"]["allowed"])
        self.assertTrue(no_receipt["actions"]["remain-contained"]["allowed"])

    @unittest.skipUnless(os.name == "posix", "recovery assessment runs on Linux CI")
    def test_recovery_assess_is_fixed_path_locked_and_read_only(self) -> None:
        import release_updater

        assessment = release_updater.finalize_recovery_assessment(
            self.recovery_state_fixture(release_updater)
        )
        lock = mock.MagicMock()
        output = io.StringIO()
        with mock.patch.object(release_updater.os, "geteuid", return_value=0), mock.patch.object(
            release_updater, "require_real_directory"
        ), mock.patch.object(
            release_updater, "StateLock", return_value=lock
        ) as state_lock, mock.patch.object(
            release_updater, "build_recovery_assessment", return_value=assessment
        ), mock.patch.object(
            release_updater, "atomic_json", side_effect=AssertionError("assess must not write")
        ), contextlib.redirect_stdout(output):
            release_updater.recover_assess()
        state_lock.assert_called_once_with(release_updater.DEFAULT_LOCK_FILE)
        rendered = json.loads(output.getvalue())
        self.assertTrue(rendered["readOnly"])
        self.assertEqual(rendered["planSha256"], assessment["planSha256"])

    @unittest.skipUnless(os.name == "posix", "recovery archive runs on Linux CI")
    def test_recovery_archive_fsyncs_destination_before_source(self) -> None:
        import release_updater

        raw = b'{"schemaVersion":1}\n'
        digest = release_updater.hashlib.sha256(raw).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_parent = root / "state"
            destination_parent = root / "evidence"
            source_parent.mkdir(mode=0o700)
            destination_parent.mkdir(mode=0o700)
            source = source_parent / "activation-failed.json"
            destination = destination_parent / "activation-failed.original.json"
            manager = mock.Mock()
            with mock.patch.object(
                release_updater, "require_real_directory"
            ), mock.patch.object(
                release_updater, "read_root_evidence_bytes", side_effect=[raw, raw]
            ), mock.patch.object(
                release_updater.os, "replace"
            ) as replace, mock.patch.object(
                release_updater, "fsync_directory"
            ) as fsync_directory:
                manager.attach_mock(replace, "replace")
                manager.attach_mock(fsync_directory, "fsync_directory")
                archived = release_updater.archive_root_evidence(
                    source, destination, digest
                )
        self.assertEqual(archived, raw)
        self.assertEqual(
            manager.mock_calls,
            [
                mock.call.replace(source, destination),
                mock.call.fsync_directory(destination_parent),
                mock.call.fsync_directory(source_parent),
            ],
        )

    @unittest.skipUnless(os.name == "posix", "recovery receipts run on Linux CI")
    def test_database_recovery_receipt_is_hash_and_release_bound(self) -> None:
        import release_updater

        state = self.recovery_state_fixture(release_updater)
        manifest = next(iter(state["manifests"].values()))
        full_manifest = self.recovery_full_manifest_fixture(release_updater, manifest)
        detail = self.recovery_detail_fixture(
            release_updater, manifest, full_manifest
        )
        detail_raw = (json.dumps(detail, sort_keys=True) + "\n").encode("utf-8")
        detail_digest = release_updater.hashlib.sha256(detail_raw).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt_dir = root / "database-receipts"
            detail_dir = root / "acceptance-receipts"
            receipt_dir.mkdir(mode=0o700)
            detail_dir.mkdir(mode=0o700)
            receipt_path = receipt_dir / "backup-receipt.json"
            detail_path = detail_dir / "backup-detail.json"
            receipt = {
                "approvalReference": "CAB-2026-0811",
                "completedAtUtc": detail["completedAtUtc"],
                "evidenceReference": f"path={detail_path};sha256={detail_digest}",
                "flywayHeadVersion": manifest["flywayHeadVersion"],
                "flywayMigrationSetSha256": manifest["flywayMigrationSetSha256"],
                "receiptType": "backup",
                "schemaVersion": 1,
                "successful": True,
                "targetVersion": manifest["version"],
            }
            raw = (json.dumps(receipt, sort_keys=True) + "\n").encode("utf-8")
            digest = release_updater.hashlib.sha256(raw).hexdigest()
            reference_re = re.compile(
                rf"path=({re.escape(str(detail_dir))}/"
                r"[A-Za-z0-9][A-Za-z0-9._-]{2,127}\.json);sha256=([0-9a-f]{64})"
            )

            def evidence_bytes(path, **_kwargs):
                if path == receipt_path:
                    return raw
                if path == detail_path:
                    return detail_raw
                raise AssertionError(f"unexpected recovery evidence path: {path}")

            with mock.patch.object(
                release_updater, "RECOVERY_DATABASE_RECEIPTS_DIR", receipt_dir
            ), mock.patch.object(
                release_updater, "RECOVERY_DATABASE_DETAIL_DIR", detail_dir
            ), mock.patch.object(
                release_updater, "RECOVERY_DETAIL_REFERENCE_RE", reference_re
            ), mock.patch.object(
                release_updater, "require_real_directory"
            ), mock.patch.object(
                release_updater, "read_root_evidence_bytes", side_effect=evidence_bytes
            ):
                observed = release_updater.load_database_recovery_receipt(
                    path_text=str(receipt_path),
                    expected_sha256=digest,
                    approval_reference="CAB-2026-0811",
                    target_manifest=manifest,
                )
                self.assertEqual(observed["sha256"], digest)
                self.assertEqual(observed["detailSha256"], detail_digest)
                self.assertEqual(
                    observed["detailIdentity"]["systemIdentifier"],
                    detail["databaseIdentity"]["systemIdentifier"],
                )
                with self.assertRaisesRegex(
                    release_updater.UpdaterError, "approval reference differs"
                ):
                    release_updater.load_database_recovery_receipt(
                        path_text=str(receipt_path),
                        expected_sha256=digest,
                        approval_reference="CAB-2026-OTHER",
                        target_manifest=manifest,
                    )

    @unittest.skipUnless(os.name == "posix", "database recovery identity runs on Linux CI")
    def test_live_database_identity_and_exact_flyway_rows_are_fail_closed(self) -> None:
        import release_updater

        observed = next(iter(self.recovery_state_fixture(release_updater)["manifests"].values()))
        full = self.recovery_full_manifest_fixture(release_updater, observed)
        detail = self.recovery_detail_fixture(release_updater, observed, full)
        narrow = {
            "approvalReference": detail["approvalReference"],
            "completedAtUtc": detail["completedAtUtc"],
            "evidenceReference": "path=/var/lib/uten-imp-backup/acceptance-receipts/detail.json;sha256="
            + "a" * 64,
            "flywayHeadVersion": detail["flywayHeadVersion"],
            "flywayMigrationSetSha256": detail["flywayMigrationSetSha256"],
            "receiptType": "backup",
            "schemaVersion": 1,
            "successful": True,
            "targetVersion": detail["targetVersion"],
        }
        identity = release_updater.validate_database_recovery_detail(
            detail, narrow=narrow, target_manifest=observed
        )
        receipt = {"detailIdentity": identity}
        live = self.recovery_live_database_fixture(full)
        result = release_updater.validate_live_database_observation(
            live, database_receipt=receipt, target_manifest=full
        )
        self.assertEqual(
            result["flyway"],
            pgbackrest_health._flyway_identity(live["flywayHistory"]),
        )
        self.assertEqual(
            result["flyway"]["signedProjectionSha256"],
            hashlib.sha256(
                release_updater.canonical_signed_flyway_projection(full)
            ).hexdigest(),
        )
        self.assertEqual(result["flyway"]["successfulMigrationCount"], 2)
        self.assertEqual(
            result["flyway"]["canonicalHistorySha256"],
            identity["canonicalHistorySha256"],
        )

        failures = {}
        value = json.loads(json.dumps(live))
        value["flywayHistory"][0]["checksum"] = True
        failures["bool-as-int"] = value
        value = json.loads(json.dumps(live))
        value["flywayHistory"][1]["version"] = value["flywayHistory"][0]["version"]
        failures["duplicate-version"] = value
        value = json.loads(json.dumps(live))
        value["flywayHistory"].append(
            {
                "checksum": 25400,
                "description": "future",
                "installedRank": 3,
                "script": "V254__future.sql",
                "success": True,
                "type": "SQL",
                "version": "254",
            }
        )
        failures["future-row"] = value
        value = json.loads(json.dumps(live))
        value["flywayHistory"][0]["success"] = False
        failures["failed-row"] = value
        value = json.loads(json.dumps(live))
        value["flywayHistory"][0]["unexpected"] = "field"
        failures["row-field-drift"] = value
        value = json.loads(json.dumps(live))
        value["systemIdentifier"] = "7523456789012345679"
        failures["system-identifier-drift"] = value
        value = json.loads(json.dumps(live))
        value["timeline"] = 2
        failures["timeline-drift"] = value
        value = json.loads(json.dumps(live))
        value["flywayHistory"].pop()
        failures["count-drift"] = value
        for label, drifted in failures.items():
            with self.subTest(label=label), self.assertRaises(release_updater.UpdaterError):
                release_updater.validate_live_database_observation(
                    drifted, database_receipt=receipt, target_manifest=full
                )

        digest_drift = json.loads(json.dumps(receipt))
        digest_drift["detailIdentity"]["canonicalHistorySha256"] = "0" * 64
        with self.assertRaisesRegex(release_updater.UpdaterError, "canonicalHistorySha256"):
            release_updater.validate_live_database_observation(
                live, database_receipt=digest_drift, target_manifest=full
            )

        boolean_detail = json.loads(json.dumps(detail))
        boolean_detail["databaseIdentity"]["timeline"] = True
        with self.assertRaisesRegex(release_updater.UpdaterError, "canonical integer"):
            release_updater.validate_database_recovery_detail(
                boolean_detail, narrow=narrow, target_manifest=observed
            )
        schema_drift = json.loads(json.dumps(detail))
        schema_drift["repositories"][0]["unexpected"] = True
        with self.assertRaisesRegex(
            release_updater.release_guard.ReleaseGuardError,
            "keys differ from contract",
        ):
            release_updater.validate_database_recovery_detail(
                schema_drift, narrow=narrow, target_manifest=observed
            )

    @unittest.skipUnless(os.name == "posix", "database recovery evidence runs on Linux CI")
    def test_database_detail_reference_and_root_file_shapes_are_fail_closed(self) -> None:
        import release_updater

        receipt = {
            "approvalReference": "CAB-2026-0811",
            "completedAtUtc": "2026-08-11T07:30:00Z",
            "evidenceReference": "path=/tmp/escaped.json;sha256=" + "a" * 64,
            "flywayHeadVersion": "253",
            "flywayMigrationSetSha256": "b" * 64,
            "receiptType": "backup",
            "schemaVersion": 1,
            "successful": True,
            "targetVersion": "v2026.08.11-1",
        }
        with self.assertRaisesRegex(release_updater.UpdaterError, "fixed detailed receipt"):
            release_updater.validate_database_recovery_receipt(receipt)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            regular = root / "detail.json"
            regular.write_text("{}\n", encoding="utf-8")
            regular.chmod(0o600)
            symlink = root / "detail-link.json"
            symlink.symlink_to(regular)
            with self.assertRaises(release_updater.UpdaterError):
                release_updater.require_root_controlled_file(symlink, secret=True)

            hardlink = root / "detail-hard.json"
            os.link(regular, hardlink)
            actual = regular.stat()

            def evidence_shape(*, uid=0, mode=0o600, links=1):
                return SimpleNamespace(
                    st_dev=actual.st_dev,
                    st_ino=actual.st_ino,
                    st_mode=stat.S_IFREG | mode,
                    st_nlink=links,
                    st_size=actual.st_size,
                    st_uid=uid,
                )

            for label, path, shape in (
                ("owner", regular, evidence_shape(uid=65534)),
                ("hardlink", hardlink, evidence_shape(links=2)),
                ("mode", regular, evidence_shape(mode=0o640)),
            ):
                with self.subTest(label=label), mock.patch.object(
                    release_updater, "require_root_controlled_file"
                ), mock.patch.object(
                    release_updater.os, "fstat", return_value=shape
                ), self.assertRaisesRegex(
                    release_updater.UpdaterError,
                    "stable single-link root-only regular file",
                ):
                    release_updater.read_root_evidence_bytes(path)

    @unittest.skipUnless(os.name == "posix", "database recovery helper runs on Linux CI")
    def test_database_recovery_helper_digest_is_checked_before_execution(self) -> None:
        import release_updater

        helper = PROJECT_ROOT / "deploy/updater/database_recovery_verifier.py"
        self.assertEqual(
            hashlib.sha256(helper.read_bytes()).hexdigest(),
            release_updater.DATABASE_RECOVERY_VERIFIER_SHA256,
        )

        with mock.patch.object(
            release_updater, "read_root_controlled_bytes", return_value=b"tampered helper"
        ) as captured_helper, mock.patch.object(
            release_updater.subprocess, "run"
        ) as execute, self.assertRaisesRegex(
            release_updater.UpdaterError, "reviewed digest"
        ):
            release_updater.verify_live_recovery_database(
                database_receipt={}, target_manifest={}
            )
        captured_helper.assert_called_once_with(
            release_updater.DATABASE_RECOVERY_VERIFIER,
            exact_mode=0o644,
            maximum_bytes=4 * 1024 * 1024,
        )
        execute.assert_not_called()

        with mock.patch.object(
            release_updater,
            "read_root_controlled_bytes",
            side_effect=release_updater.UpdaterError(
                "installed helper is not a stable root-controlled file"
            ),
        ), mock.patch.object(
            release_updater.subprocess, "run"
        ) as execute, self.assertRaisesRegex(
            release_updater.UpdaterError, "stable root-controlled"
        ):
            release_updater.verify_live_recovery_database(
                database_receipt={}, target_manifest={}
            )
        execute.assert_not_called()

    @unittest.skipUnless(os.name == "posix", "database recovery helper runs on Linux CI")
    def test_database_recovery_helper_has_fixed_read_only_contract(self) -> None:
        import database_recovery_verifier

        observed = {
            "configFile": "/etc/postgresql/16/main/postgresql.conf",
            "dataDirectory": "/data/postgresql/16/main",
            "databaseName": "uten_imp",
            "flywayHistory": [],
            "hbaFile": "/etc/postgresql/16/main/pg_hba.conf",
            "inRecovery": False,
            "listenAddresses": "127.0.0.1,::1",
            "postmasterPid": 1234,
            "schemaName": "public",
            "schemaVersion": 1,
            "serverPort": 5432,
            "serverVersionNum": 160010,
            "systemIdentifier": "7523456789012345678",
            "timeline": 1,
        }
        psql_completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps(observed).encode("utf-8"), stderr=b""
        )
        systemd_completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=b"1234\n", stderr=b""
        )
        listener_completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=(
                b'LISTEN 0 244 127.0.0.1:5432 0.0.0.0:* '
                b'users:(("postgres",pid=1234,fd=5))\n'
            ),
            stderr=b"",
        )
        postgres = SimpleNamespace(pw_uid=1234)
        with mock.patch.object(
            database_recovery_verifier.pwd, "getpwnam", return_value=postgres
        ), mock.patch.object(
            database_recovery_verifier.os, "geteuid", return_value=1234
        ), mock.patch.object(
            database_recovery_verifier.subprocess,
            "run",
            side_effect=(psql_completed, systemd_completed, listener_completed),
        ) as execute:
            self.assertEqual(
                database_recovery_verifier.collect(),
                {**observed, "systemdMainPid": 1234, "tcpListenerPid": 1234},
            )
        self.assertEqual(execute.call_count, 3)
        command = execute.call_args_list[0].args[0]
        self.assertEqual(command[0], "/usr/bin/psql")
        self.assertIn("--no-password", command)
        self.assertIn("/var/run/postgresql", command)
        self.assertIn("uten_imp", command)
        self.assertIn("FROM public.flyway_schema_history", database_recovery_verifier.QUERY)
        self.assertIn("ORDER BY installed_rank", database_recovery_verifier.QUERY)
        self.assertNotIn("WHERE success", database_recovery_verifier.QUERY)
        self.assertIn("postmasterPid", database_recovery_verifier.QUERY)
        self.assertEqual(
            execute.call_args_list[1].args[0],
            [
                "/usr/bin/systemctl",
                "show",
                "--property=MainPID",
                "--value",
                "postgresql@16-main.service",
            ],
        )
        self.assertEqual(execute.call_args_list[2].args[0][0], "/usr/bin/ss")
        self.assertIn(
            "default_transaction_read_only=on",
            execute.call_args_list[0].kwargs["env"]["PGOPTIONS"],
        )
        self.assertFalse(execute.call_args_list[0].kwargs.get("shell", False))
        for secret_name in ("PGPASSWORD", "PGPASSFILE", "PGSERVICE"):
            self.assertNotIn(secret_name, execute.call_args_list[0].kwargs["env"])

    @unittest.skipUnless(os.name == "posix", "database recovery helper runs on Linux CI")
    def test_updater_invokes_only_the_pinned_live_database_helper(self) -> None:
        import release_updater

        observed = next(
            iter(self.recovery_state_fixture(release_updater)["manifests"].values())
        )
        full = self.recovery_full_manifest_fixture(release_updater, observed)
        detail = self.recovery_detail_fixture(release_updater, observed, full)
        database_receipt = {
            "detailIdentity": {
                **detail["databaseIdentity"]["flyway"],
                "systemIdentifier": detail["databaseIdentity"]["systemIdentifier"],
                "timeline": detail["databaseIdentity"]["timeline"],
            }
        }
        live = self.recovery_live_database_fixture(full)
        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps(live).encode("utf-8"), stderr=b""
        )
        helper_bytes = (
            PROJECT_ROOT / "deploy/updater/database_recovery_verifier.py"
        ).read_bytes()
        self.assertEqual(
            hashlib.sha256(helper_bytes).hexdigest(),
            release_updater.DATABASE_RECOVERY_VERIFIER_SHA256,
        )
        with mock.patch.object(
            release_updater, "read_root_controlled_bytes", return_value=helper_bytes
        ) as captured_helper, mock.patch.object(
            release_updater.subprocess, "run", return_value=completed
        ) as execute:
            evidence = release_updater.verify_live_recovery_database(
                database_receipt=database_receipt, target_manifest=full
            )

        captured_helper.assert_called_once_with(
            release_updater.DATABASE_RECOVERY_VERIFIER,
            exact_mode=0o644,
            maximum_bytes=4 * 1024 * 1024,
        )
        self.assertEqual(evidence["systemIdentifier"], live["systemIdentifier"])
        self.assertEqual(
            execute.call_args.args[0],
            [
                "/usr/sbin/runuser",
                "-u",
                "postgres",
                "--",
                "/usr/bin/python3",
                "-I",
                "-",
            ],
        )
        self.assertEqual(execute.call_args.kwargs["input"], helper_bytes)
        self.assertIs(execute.call_args.kwargs["stderr"], subprocess.DEVNULL)
        self.assertFalse(execute.call_args.kwargs.get("shell", False))
        self.assertEqual(
            execute.call_args.kwargs["env"],
            {
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            },
        )

    @unittest.skipUnless(os.name == "posix", "recovery apply runs on Linux CI")
    def test_recovery_apply_rejects_stale_plan_before_receipt_or_mutation(self) -> None:
        import release_updater

        assessment = release_updater.finalize_recovery_assessment(
            self.recovery_state_fixture(release_updater)
        )
        marker_sha = assessment["state"]["activationFailure"]["sha256"]
        args = SimpleNamespace(
            action="finish-activation",
            approval_reference="CAB-2026-0811",
            confirm="irrelevant",
            database_receipt=str(
                release_updater.RECOVERY_DATABASE_RECEIPTS_DIR / "receipt.json"
            ),
            expected_database_receipt_sha256="b" * 64,
            expected_marker_sha256=marker_sha,
            expected_plan_sha256="0" * 64,
            target_version=assessment["state"]["activationFailure"]["fields"][
                "failedVersion"
            ],
        )
        lock = mock.MagicMock()
        database_lock = mock.MagicMock()
        with mock.patch.object(release_updater.os, "geteuid", return_value=0), mock.patch.object(
            release_updater, "require_real_directory"
        ), mock.patch.object(release_updater, "StateLock", return_value=lock), mock.patch.object(
            release_updater, "DatabaseMaintenanceLock", return_value=database_lock
        ), mock.patch.object(
            release_updater, "build_recovery_assessment", return_value=assessment
        ), mock.patch.object(
            release_updater, "load_database_recovery_receipt"
        ) as load_receipt, mock.patch.object(
            release_updater, "finish_activation_recovery"
        ) as finish, self.assertRaisesRegex(
            release_updater.UpdaterError, "assessment changed"
        ):
            release_updater.recover_apply(args)
        load_receipt.assert_not_called()
        finish.assert_not_called()

    @unittest.skipUnless(os.name == "posix", "recovery apply runs on Linux CI")
    def test_retry_recovery_is_rejected_after_all_explicit_evidence_checks(self) -> None:
        import release_updater

        assessment = release_updater.finalize_recovery_assessment(
            self.recovery_state_fixture(release_updater)
        )
        version = assessment["state"]["activationFailure"]["fields"]["failedVersion"]
        plan_sha = assessment["planSha256"]
        args = SimpleNamespace(
            action="retry-activation",
            approval_reference="CAB-2026-0811",
            confirm=release_updater.recovery_confirmation(
                "retry-activation", version, plan_sha
            ),
            database_receipt=str(
                release_updater.RECOVERY_DATABASE_RECEIPTS_DIR / "receipt.json"
            ),
            expected_database_receipt_sha256="b" * 64,
            expected_marker_sha256=assessment["state"]["activationFailure"]["sha256"],
            expected_plan_sha256=plan_sha,
            target_version=version,
        )
        lock = mock.MagicMock()
        database_lock = mock.MagicMock()
        with mock.patch.object(release_updater.os, "geteuid", return_value=0), mock.patch.object(
            release_updater, "require_real_directory"
        ), mock.patch.object(release_updater, "StateLock", return_value=lock), mock.patch.object(
            release_updater, "DatabaseMaintenanceLock", return_value=database_lock
        ), mock.patch.object(
            release_updater, "build_recovery_assessment", return_value=assessment
        ), mock.patch.object(
            release_updater,
            "load_database_recovery_receipt",
            return_value={"path": "/receipt", "sha256": "b" * 64},
        ) as load_receipt, mock.patch.object(
            release_updater, "finish_activation_recovery"
        ) as finish, self.assertRaisesRegex(
            release_updater.UpdaterError, "intentionally unavailable"
        ):
            release_updater.recover_apply(args)
        load_receipt.assert_called_once()
        finish.assert_not_called()

    @unittest.skipUnless(os.name == "posix", "recovery finish runs on Linux CI")
    def test_finish_recovery_archives_evidence_and_removes_boot_gate_last(self) -> None:
        import release_updater

        state = self.recovery_state_fixture(release_updater)
        marker_raw = b"original activation marker bytes"
        state["activationFailure"]["sha256"] = release_updater.hashlib.sha256(
            marker_raw
        ).hexdigest()
        state["bootEnablementInProgress"] = {
            "fields": {
                "commitSha": state["activationFailure"]["fields"]["failedCommitSha"],
                "desiredBootEnablement": state["activationFailure"]["fields"][
                    "originalBootEnablement"
                ],
                "releaseSequence": 20260811001,
                "schemaVersion": 1,
                "startedAtUtc": "2026-08-11T08:06:00Z",
                "version": state["activationFailure"]["fields"]["failedVersion"],
            },
            "path": str(release_updater.BOOT_ENABLEMENT_IN_PROGRESS_MARKER),
            "schemaKind": "boot-enablement-in-progress-v1",
            "sha256": "9" * 64,
            "sizeBytes": 512,
        }
        assessment = release_updater.finalize_recovery_assessment(state)
        self.assertTrue(assessment["actions"]["finish-activation"]["allowed"])
        manifest = state["manifests"][state["activationFailure"]["fields"]["failedVersion"]]
        full_manifest = self.recovery_full_manifest_fixture(release_updater, manifest)
        transaction = Path("/var/lib/uten-imp-release/recovery-evidence/fixture")
        manager = mock.Mock()
        database_receipt = {
            "detailPath": "/var/lib/uten-imp-backup/acceptance-receipts/detail.json",
            "detailSha256": "7" * 64,
            "path": "/receipt",
            "sha256": "8" * 64,
        }

        def evidence_bytes(path: Path, **_kwargs):
            if path == release_updater.ACTIVATION_FAILURE_MARKER:
                return marker_raw
            if path == release_updater.RECOVERY_IN_PROGRESS_MARKER:
                return b"recovery progress"
            if path == release_updater.BOOT_ENABLEMENT_IN_PROGRESS_MARKER:
                return b"recovery boot gate"
            raise AssertionError(f"unexpected evidence read: {path}")

        with mock.patch.object(
            release_updater, "read_root_evidence_bytes", side_effect=evidence_bytes
        ), mock.patch.object(
            release_updater, "assert_privilege_separation"
        ), mock.patch.object(
            release_updater, "observe_installed_release", return_value=manifest
        ), mock.patch.object(
            release_updater, "load_installed_manifest", return_value=full_manifest
        ), mock.patch.object(
            release_updater, "validate_detail_against_signed_manifest"
        ) as detail_manifest, mock.patch.object(
            release_updater, "create_recovery_transaction", return_value=transaction
        ), mock.patch.object(
            release_updater, "atomic_json"
        ) as atomic_json, mock.patch.multiple(
            release_updater,
            arm_recovery_ingress_pending=mock.DEFAULT,
            commit_recovery_ingress_for_systemd_finalizer=mock.DEFAULT,
            read_systemd_finalized_recovery_receipt=mock.DEFAULT,
        ) as ingress_patches, mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater, "archive_root_evidence"
        ) as archive, mock.patch.object(
            release_updater,
            "verify_live_recovery_database",
            return_value={
                "flyway": {
                    "canonicalHistorySha256": "1" * 64,
                    "headVersion": 255,
                    "signedProjectionSha256": "2" * 64,
                    "successfulMigrationCount": 236,
                },
                "systemIdentifier": "7523456789012345678",
                "timeline": 4,
            },
        ) as live_database, mock.patch.multiple(
            release_updater,
            archive_interrupted_start_authorization=mock.DEFAULT,
            start_application_authorized=mock.DEFAULT,
            write_runtime_authority=mock.DEFAULT,
            installed_manifest_sha256=mock.DEFAULT,
        ) as runtime_patches, mock.patch.object(
            release_updater, "start_unit"
        ) as start, mock.patch.object(
            release_updater, "validate_health"
        ) as health, mock.patch.object(
            release_updater, "validate_static_entry"
        ) as static, mock.patch.object(
            release_updater, "run_oneshot_probe"
        ) as probe, mock.patch.object(
            release_updater, "restore_boot_enablement"
        ) as restore_boot, mock.patch.object(
            release_updater, "unit_active", return_value=True
        ), mock.patch.object(
            release_updater, "run"
        ) as run:
            runtime_patches["installed_manifest_sha256"].return_value = "3" * 64
            ingress_patches["read_systemd_finalized_recovery_receipt"].return_value = {
                "status": "completed"
            }
            authorized_start = runtime_patches["start_application_authorized"]
            for child, name in (
                (detail_manifest, "detail_manifest"),
                (atomic_json, "atomic_json"),
                (ingress_patches["arm_recovery_ingress_pending"], "arm_ingress"),
                (
                    ingress_patches["commit_recovery_ingress_for_systemd_finalizer"],
                    "commit_ingress",
                ),
                (
                    ingress_patches["read_systemd_finalized_recovery_receipt"],
                    "finalized_receipt",
                ),
                (archive, "archive"),
                (live_database, "live_database"),
                (authorized_start, "authorized_start"),
                (start, "start"),
                (health, "health"),
                (static, "static"),
                (probe, "probe"),
                (restore_boot, "restore_boot"),
                (run, "run"),
            ):
                manager.attach_mock(child, name)
            receipt = release_updater.finish_activation_recovery(
                assessment=assessment,
                approval_reference="CAB-2026-0811",
                database_receipt=database_receipt,
            )

        calls = manager.mock_calls
        activation_archive = next(
            index
            for index, call in enumerate(calls)
            if call == mock.call.archive(
                release_updater.ACTIVATION_FAILURE_MARKER,
                transaction / "activation-failed.original.json",
                state["activationFailure"]["sha256"],
            )
        )
        detail_manifest_gate = calls.index(
            mock.call.detail_manifest(database_receipt, full_manifest, mock.ANY)
        )
        live_database_gate = calls.index(
            mock.call.live_database(
                database_receipt=database_receipt,
                target_manifest=full_manifest,
                require_internal_role_acl=False,
                allow_local_recovery_archive=False,
            )
        )
        app_start = next(
            index for index, call in enumerate(calls) if call[0] == "authorized_start"
        )
        boot_restore = next(
            index for index, call in enumerate(calls) if call.args and call[0] == "restore_boot"
        )
        progress_archive = next(
            index
            for index, call in enumerate(calls)
            if call[0] == "archive"
            and call.args
            and call.args[0] == release_updater.RECOVERY_IN_PROGRESS_MARKER
        )
        final_boot_archive = next(
            index
            for index, call in enumerate(calls)
            if call[0] == "archive"
            and call.args
            and call.args[0] == release_updater.BOOT_ENABLEMENT_IN_PROGRESS_MARKER
            and call.args[1] == transaction / "boot-enablement.recovery.json"
        )
        durable_ingress_authority = calls.index(
            mock.call.commit_ingress(
                transaction=transaction,
                commit_path=transaction / "recovery-commit.json",
            )
        )
        nginx_start = calls.index(mock.call.start("nginx.service"))
        terminal_ingress_receipt = next(
            index
            for index, call in enumerate(calls)
            if call[0] == "finalized_receipt"
        )
        self.assertLess(activation_archive, app_start)
        self.assertLess(detail_manifest_gate, app_start)
        self.assertLess(live_database_gate, app_start)
        self.assertLess(app_start, boot_restore)
        self.assertLess(boot_restore, progress_archive)
        self.assertLess(progress_archive, final_boot_archive)
        self.assertLess(final_boot_archive, durable_ingress_authority)
        self.assertLess(durable_ingress_authority, nginx_start)
        self.assertLess(nginx_start, terminal_ingress_receipt)
        self.assertEqual(receipt["status"], "completed")

        source = (PROJECT_ROOT / "deploy/updater/release_updater.py").read_text(
            encoding="utf-8"
        )
        recovery_source = source[
            source.index("def finish_activation_recovery(") : source.index(
                "\ndef recover_assess("
            )
        ]
        self.assertNotIn("durable_unlink", recovery_source)

    @unittest.skipUnless(os.name == "posix", "recovery finish runs on Linux CI")
    def test_finish_recovery_failure_invokes_persistent_containment(self) -> None:
        import release_updater

        state = self.recovery_state_fixture(release_updater)
        marker_raw = b"original activation marker bytes"
        state["activationFailure"]["sha256"] = release_updater.hashlib.sha256(
            marker_raw
        ).hexdigest()
        assessment = release_updater.finalize_recovery_assessment(state)
        manifest = next(iter(state["manifests"].values()))
        full_manifest = self.recovery_full_manifest_fixture(release_updater, manifest)
        transaction = Path("/var/lib/uten-imp-release/recovery-evidence/fixture")
        database_receipt = {
            "detailPath": "/var/lib/uten-imp-backup/acceptance-receipts/detail.json",
            "detailSha256": "7" * 64,
            "path": "/receipt",
            "sha256": "8" * 64,
        }

        def evidence_bytes(path: Path, **_kwargs):
            if path == release_updater.ACTIVATION_FAILURE_MARKER:
                return marker_raw
            raise AssertionError(f"unexpected evidence read: {path}")

        with mock.patch.object(
            release_updater, "read_root_evidence_bytes", side_effect=evidence_bytes
        ), mock.patch.object(
            release_updater, "assert_privilege_separation"
        ), mock.patch.object(
            release_updater, "observe_installed_release", return_value=manifest
        ), mock.patch.object(
            release_updater, "load_installed_manifest", return_value=full_manifest
        ), mock.patch.object(
            release_updater, "validate_detail_against_signed_manifest"
        ), mock.patch.object(
            release_updater, "create_recovery_transaction", return_value=transaction
        ), mock.patch.object(
            release_updater, "atomic_json"
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater, "archive_root_evidence"
        ), mock.patch.object(
            release_updater,
            "verify_live_recovery_database",
            side_effect=release_updater.UpdaterError("injected live database mismatch"),
        ), mock.patch.object(
            release_updater, "start_unit"
        ) as start, mock.patch.object(
            release_updater, "validate_health"
        ), mock.patch.object(
            release_updater, "run"
        ), mock.patch.object(
            release_updater, "contain_recovery_failure"
        ) as contain, self.assertRaisesRegex(
            release_updater.UpdaterError, "injected live database mismatch"
        ):
            release_updater.finish_activation_recovery(
                assessment=assessment,
                approval_reference="CAB-2026-0811",
                database_receipt=database_receipt,
            )
        contain.assert_called_once()
        start.assert_not_called()

    @unittest.skipUnless(os.name == "posix", "previous recovery runs on Linux CI")
    def test_restore_previous_orders_signed_db_switch_commit_and_ingress(self) -> None:
        import release_updater

        state = self.recovery_state_fixture(release_updater)
        state["activationFailure"]["fields"]["reason"] = "database-incompatible"
        state["activationFailure"]["fields"]["currentLinkRestored"] = True
        previous = self.recovery_previous_manifest_fixture(release_updater)
        state["manifests"][previous["version"]] = previous
        marker_raw = b"restore previous activation marker bytes"
        state["activationFailure"]["sha256"] = hashlib.sha256(marker_raw).hexdigest()
        assessment = release_updater.finalize_recovery_assessment(state)
        self.assertTrue(
            assessment["actions"]["restore-previous"]["allowed"],
            assessment["actions"]["restore-previous"]["reasons"],
        )
        full_manifest = self.recovery_previous_full_manifest_fixture(
            release_updater, previous
        )
        transaction = Path("/var/lib/uten-imp-release/recovery-evidence/restore-fixture")
        database_receipt = {
            "detailPath": "/var/lib/uten-imp-backup/acceptance-receipts/detail.json",
            "detailSha256": "7" * 64,
            "path": str(release_updater.RECOVERY_DATABASE_RECEIPTS_DIR / "receipt.json"),
            "sha256": "8" * 64,
        }
        live = {
            "flyway": {
                "canonicalHistorySha256": "1" * 64,
                "headVersion": 252,
                "signedProjectionSha256": "2" * 64,
                "successfulMigrationCount": 1,
            },
            "systemIdentifier": "7523456789012345678",
            "timeline": 4,
        }
        manager = mock.Mock()

        def evidence_bytes(path: Path, **_kwargs):
            if path == release_updater.ACTIVATION_FAILURE_MARKER:
                return marker_raw
            if path == release_updater.RECOVERY_IN_PROGRESS_MARKER:
                return b"previous recovery progress"
            if path == release_updater.BOOT_ENABLEMENT_IN_PROGRESS_MARKER:
                return b"previous recovery boot gate"
            raise AssertionError(f"unexpected evidence read: {path}")

        with contextlib.ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "read_root_evidence_bytes",
                    side_effect=evidence_bytes,
                )
            )
            stack.enter_context(mock.patch.object(release_updater, "assert_privilege_separation"))
            stack.enter_context(
                mock.patch.object(
                    release_updater, "observe_installed_release", return_value=previous
                )
            )
            stack.enter_context(
                mock.patch.object(
                    release_updater, "load_installed_manifest", return_value=full_manifest
                )
            )
            detail_gate = stack.enter_context(
                mock.patch.object(release_updater, "validate_detail_against_signed_manifest")
            )
            stack.enter_context(
                mock.patch.object(
                    release_updater, "create_recovery_transaction", return_value=transaction
                )
            )
            atomic_json = stack.enter_context(
                mock.patch.object(release_updater, "atomic_json")
            )
            arm_ingress = stack.enter_context(
                mock.patch.object(release_updater, "arm_recovery_ingress_pending")
            )
            commit_ingress = stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "commit_recovery_ingress_for_systemd_finalizer",
                )
            )
            finalized_receipt = stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "read_systemd_finalized_recovery_receipt",
                    return_value={"status": "completed"},
                )
            )
            stack.enter_context(mock.patch.object(release_updater, "require_root_controlled_file"))
            close_all = stack.enter_context(
                mock.patch.object(
                    release_updater, "_stop_and_disable_for_interrupted_containment"
                )
            )
            archive = stack.enter_context(
                mock.patch.object(release_updater, "archive_root_evidence")
            )
            stack.enter_context(
                mock.patch.object(release_updater, "archive_interrupted_start_authorization")
            )
            switch_current = stack.enter_context(
                mock.patch.object(release_updater, "atomic_current")
            )
            live_database = stack.enter_context(
                mock.patch.object(
                    release_updater, "verify_live_recovery_database", return_value=live
                )
            )
            authorized_start = stack.enter_context(
                mock.patch.object(release_updater, "start_application_authorized")
            )
            health = stack.enter_context(mock.patch.object(release_updater, "validate_health"))
            stack.enter_context(
                mock.patch.object(
                    release_updater, "installed_manifest_sha256", return_value="5" * 64
                )
            )
            runtime_authority = stack.enter_context(
                mock.patch.object(release_updater, "write_runtime_authority")
            )
            restore_boot = stack.enter_context(
                mock.patch.object(release_updater, "restore_boot_enablement")
            )
            start = stack.enter_context(mock.patch.object(release_updater, "start_unit"))
            stack.enter_context(mock.patch.object(release_updater, "unit_active", return_value=True))
            static = stack.enter_context(
                mock.patch.object(release_updater, "validate_static_entry")
            )
            probe = stack.enter_context(
                mock.patch.object(release_updater, "run_oneshot_probe")
            )
            run = stack.enter_context(mock.patch.object(release_updater, "run"))
            for child, name in (
                (detail_gate, "detail"),
                (atomic_json, "atomic"),
                (arm_ingress, "arm_ingress"),
                (commit_ingress, "commit_ingress"),
                (finalized_receipt, "finalized_receipt"),
                (close_all, "close"),
                (archive, "archive"),
                (switch_current, "switch"),
                (live_database, "live"),
                (authorized_start, "authorized_start"),
                (health, "health"),
                (runtime_authority, "runtime"),
                (restore_boot, "restore_boot"),
                (start, "start"),
                (static, "static"),
                (probe, "probe"),
                (run, "run"),
            ):
                manager.attach_mock(child, name)
            receipt = release_updater.restore_previous_recovery(
                action="restore-previous",
                assessment=assessment,
                approval_reference="CAB-2026-0811",
                database_receipt=database_receipt,
            )

        calls = manager.mock_calls
        progress_gate = next(
            index
            for index, call in enumerate(calls)
            if call[0] == "atomic"
            and call.args[0] == release_updater.RECOVERY_IN_PROGRESS_MARKER
        )
        close_index = calls.index(mock.call.close())
        failure_archive = calls.index(
            mock.call.archive(
                release_updater.ACTIVATION_FAILURE_MARKER,
                transaction / "activation-failed.original.json",
                state["activationFailure"]["sha256"],
            )
        )
        switch_index = calls.index(
            mock.call.switch(
                release_updater.DEFAULT_RELEASE_BASE,
                release_updater.DEFAULT_RELEASE_BASE
                / "releases"
                / previous["version"],
            )
        )
        live_index = calls.index(
            mock.call.live(
                database_receipt=database_receipt,
                target_manifest=full_manifest,
                require_internal_role_acl=False,
                allow_local_recovery_archive=False,
            )
        )
        app_start = next(
            index for index, call in enumerate(calls) if call[0] == "authorized_start"
        )
        runtime_commit = next(
            index for index, call in enumerate(calls) if call[0] == "runtime"
        )
        progress_archive = next(
            index
            for index, call in enumerate(calls)
            if call[0] == "archive"
            and call.args[0] == release_updater.RECOVERY_IN_PROGRESS_MARKER
        )
        boot_archive = next(
            index
            for index, call in enumerate(calls)
            if call[0] == "archive"
            and call.args[0] == release_updater.BOOT_ENABLEMENT_IN_PROGRESS_MARKER
        )
        nginx_start = next(
            index
            for index, call in enumerate(calls)
            if call == mock.call.start("nginx.service")
        )
        durable_ingress_authority = calls.index(
            mock.call.commit_ingress(
                transaction=transaction,
                commit_path=transaction / "recovery-commit.json",
            )
        )
        terminal_ingress_receipt = next(
            index
            for index, call in enumerate(calls)
            if call[0] == "finalized_receipt"
        )
        self.assertLess(progress_gate, close_index)
        self.assertLess(close_index, failure_archive)
        self.assertLess(failure_archive, switch_index)
        self.assertLess(switch_index, live_index)
        self.assertLess(live_index, app_start)
        self.assertLess(app_start, runtime_commit)
        self.assertLess(runtime_commit, progress_archive)
        self.assertLess(progress_archive, boot_archive)
        self.assertLess(boot_archive, durable_ingress_authority)
        self.assertLess(durable_ingress_authority, nginx_start)
        self.assertLess(boot_archive, nginx_start)
        self.assertLess(nginx_start, terminal_ingress_receipt)
        self.assertEqual(receipt["status"], "completed")
        source = (PROJECT_ROOT / "deploy/updater/release_updater.py").read_text(
            encoding="utf-8"
        )
        restore_source = source[
            source.index("def restore_previous_recovery(") : source.index(
                "\ndef remain_contained_recovery("
            )
        ]
        self.assertNotIn("flyway repair", restore_source.lower())
        self.assertNotIn("run_migration_unit", restore_source)

    @unittest.skipUnless(os.name == "posix", "containment receipts run on Linux CI")
    def test_remain_contained_never_clears_marker_or_starts_runtime(self) -> None:
        import release_updater

        state = self.recovery_state_fixture(release_updater)
        marker_raw = b"remain contained marker"
        state["activationFailure"]["sha256"] = hashlib.sha256(marker_raw).hexdigest()
        assessment = release_updater.finalize_recovery_assessment(state)
        transaction = Path("/var/lib/uten-imp-release/recovery-evidence/remain")
        with mock.patch.object(
            release_updater, "read_root_evidence_bytes", return_value=marker_raw
        ), mock.patch.object(
            release_updater, "_stop_and_disable_for_interrupted_containment"
        ) as close_all, mock.patch.object(
            release_updater, "create_recovery_transaction", return_value=transaction
        ), mock.patch.object(
            release_updater, "atomic_json"
        ) as atomic_json, mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater.os.path, "lexists", return_value=True
        ), mock.patch.object(
            release_updater, "archive_root_evidence", side_effect=AssertionError("no archive")
        ), mock.patch.object(
            release_updater, "start_unit", side_effect=AssertionError("no start")
        ), mock.patch.object(
            release_updater, "verify_live_recovery_database", side_effect=AssertionError("no db")
        ):
            receipt = release_updater.remain_contained_recovery(
                assessment=assessment, approval_reference="CAB-2026-0811"
            )
        close_all.assert_called_once_with()
        atomic_json.assert_called_once_with(
            transaction / "remain-contained-receipt.json", mock.ANY, mode=0o600
        )
        self.assertEqual(receipt["status"], "contained-no-start-no-marker-clear")

    def test_openssh_ed25519_detached_signature(self) -> None:
        ssh_keygen = shutil.which("ssh-keygen")
        if not ssh_keygen:
            self.skipTest("OpenSSH ssh-keygen is not installed")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key = root / "release-key"
            subprocess.run(
                [ssh_keygen, "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            content = root / "manifest.json"
            content.write_text('{"fixture":true}\n', encoding="utf-8")
            subprocess.run(
                [
                    ssh_keygen,
                    "-Y",
                    "sign",
                    "-f",
                    str(key),
                    "-n",
                    release_guard.SIGNATURE_NAMESPACE,
                    str(content),
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            public_key = " ".join(
                key.with_suffix(".pub").read_text(encoding="ascii").split()[:2]
            )
            allowed_signers = root / "allowed_signers"
            allowed_signers.write_text(
                f"{release_guard.SIGNING_IDENTITY} {public_key}\n", encoding="ascii"
            )
            signed_key_id = next(iter(release_guard.allowed_signing_key_ids(allowed_signers)))
            release_guard.verify_ssh_signature(
                content,
                content.with_suffix(".json.sig"),
                allowed_signers,
                expected_key_id=signed_key_id,
            )
            self.assertEqual(len(release_guard.allowed_signing_key_ids(allowed_signers)), 1)

            second_key = root / "second-release-key"
            subprocess.run(
                [ssh_keygen, "-q", "-t", "ed25519", "-N", "", "-f", str(second_key)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            second_public = " ".join(
                second_key.with_suffix(".pub").read_text(encoding="ascii").split()[:2]
            )
            allowed_signers.write_text(
                f"{release_guard.SIGNING_IDENTITY} {public_key}\n"
                f"{release_guard.SIGNING_IDENTITY} {second_public}\n",
                encoding="ascii",
            )
            other_key_id = next(
                key_id
                for key_id in release_guard.allowed_signing_key_ids(allowed_signers)
                if key_id != signed_key_id
            )
            with self.assertRaises(release_guard.ReleaseGuardError):
                release_guard.verify_ssh_signature(
                    content,
                    content.with_suffix(".json.sig"),
                    allowed_signers,
                    expected_key_id=other_key_id,
                )

    def test_oss_inputs_reject_http_and_unsafe_keys(self) -> None:
        with self.assertRaises(oss_io.OssIoError):
            oss_io.validated_endpoint("http://oss.example.invalid")
        with self.assertRaises(oss_io.OssIoError):
            oss_io.validated_key("releases/../server.env")
        self.assertEqual(
            oss_io.validated_key("channels/candidate/LATEST.txt"),
            "channels/candidate/LATEST.txt",
        )


@unittest.skipUnless(os.name == "posix", "interrupted recovery runs on Linux CI")
class InterruptedContainmentTest(unittest.TestCase):
    version = "v2026.08.12-1"
    sequence = 20260812001
    commit = "a" * 40

    def setUp(self) -> None:
        import release_updater

        profile = mock.patch.object(
            release_updater, "deployment_profile", return_value="prod"
        )
        profile.start()
        self.addCleanup(profile.stop)

    @contextlib.contextmanager
    def interrupted_environment(self, release_updater):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / "recovery-evidence"
            evidence.mkdir(mode=0o700)
            paths = {
                "root": root,
                "evidence": evidence,
                "authorization_dir": root / "run",
                "authorization": root / "run" / "start-authorization.json",
                "migration_authorization_dir": root / "migration-run",
                "migration_authorization": root
                / "migration-run"
                / "migration-authorization.json",
                "activation_failure": root / "activation-failed.json",
                "activation": root / "activation-in-progress.json",
                "recovery": root / "recovery-in-progress.json",
                "boot": root / "boot-enablement-in-progress.json",
            }

            def evidence_bytes(path: Path, **_kwargs):
                return Path(path).read_bytes()

            real_lstat = Path.lstat

            def root_authorization_lstat(path: Path):
                details = real_lstat(path)
                if Path(path) in {
                    paths["authorization_dir"],
                    paths["migration_authorization_dir"],
                }:
                    return SimpleNamespace(
                        st_gid=0,
                        st_mode=stat.S_IFDIR | 0o700,
                    )
                if (
                    Path(path) == paths["migration_authorization"]
                    or (
                        Path(path).parent == paths["migration_authorization_dir"]
                        and release_updater.MIGRATION_AUTHORIZATION_ARCHIVE_RE.fullmatch(
                            Path(path).name
                        )
                    )
                ):
                    return SimpleNamespace(
                        st_gid=0,
                        st_mode=stat.S_IFREG | 0o600,
                    )
                return details

            with mock.patch.multiple(
                release_updater,
                DEFAULT_ROOT_STATE_DIR=root,
                DEFAULT_LOCK_FILE=root / "operation.lock",
                ACTIVATION_FAILURE_MARKER=paths["activation_failure"],
                ACTIVATION_IN_PROGRESS_MARKER=paths["activation"],
                RECOVERY_IN_PROGRESS_MARKER=paths["recovery"],
                BOOT_ENABLEMENT_IN_PROGRESS_MARKER=paths["boot"],
                RECOVERY_EVIDENCE_DIR=evidence,
                START_AUTHORIZATION_DIR=paths["authorization_dir"],
                START_AUTHORIZATION=paths["authorization"],
                MIGRATION_AUTHORIZATION_DIR=paths["migration_authorization_dir"],
                MIGRATION_AUTHORIZATION=paths["migration_authorization"],
            ), mock.patch.object(
                release_updater, "require_real_directory"
            ), mock.patch.object(
                release_updater,
                "read_root_evidence_bytes",
                side_effect=evidence_bytes,
            ), mock.patch.object(
                release_updater,
                "observe_recovery_unit",
                return_value={
                    "active": False,
                    "activeState": "inactive",
                    "enabled": False,
                    "exists": True,
                    "loadState": "loaded",
                    "unitFileState": "disabled",
                },
            ), mock.patch.object(
                Path, "lstat", root_authorization_lstat
            ):
                yield paths

    def write_json(self, path: Path, value: dict) -> bytes:
        raw = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")
        path.write_bytes(raw)
        return raw

    def activation_marker(self, release_updater) -> dict:
        return {
            "commitSha": self.commit,
            "originalBootEnablement": {
                unit: True for unit in release_updater.BOOT_UNITS
            },
            "previousVersion": "v2026.08.11-1",
            "releaseSequence": self.sequence,
            "schemaVersion": 1,
            "startedAtUtc": "2026-08-12T01:00:00Z",
            "version": self.version,
        }

    def boot_marker(self, release_updater) -> dict:
        return {
            "commitSha": self.commit,
            "desiredBootEnablement": {
                unit: False for unit in release_updater.BOOT_UNITS
            },
            "releaseSequence": self.sequence,
            "schemaVersion": 1,
            "startedAtUtc": "2026-08-12T01:05:00Z",
            "version": self.version,
        }

    def recovery_marker(self, release_updater) -> dict:
        return {
            "action": "finish-activation",
            "approvalReference": "CAB-2026-0812",
            "databaseReceiptPath": str(
                release_updater.RECOVERY_DATABASE_RECEIPTS_DIR / "receipt.json"
            ),
            "databaseReceiptSha256": "b" * 64,
            "desiredBootEnablement": {
                unit: True for unit in release_updater.BOOT_UNITS
            },
            "markerSha256": "c" * 64,
            "planSha256": "d" * 64,
            "schemaVersion": 1,
            "startedAtUtc": "2026-08-12T01:03:00Z",
            "targetVersion": self.version,
            "transactionDirectory": str(
                release_updater.RECOVERY_EVIDENCE_DIR / "prior-recovery"
            ),
        }

    def failed_activation_marker(self, release_updater) -> dict:
        return {
            "currentLinkRestored": False,
            "failedAtUtc": "2026-08-12T01:00:00Z",
            "failedCommitSha": self.commit,
            "failedFlywayHeadVersion": "255",
            "failedFlywayMigrationSetSha256": "1" * 64,
            "failedVersion": self.version,
            "originalBootEnablement": {
                unit: True for unit in release_updater.BOOT_UNITS
            },
            "previousFlywayHeadVersion": "254",
            "previousFlywayMigrationSetSha256": "2" * 64,
            "previousVersion": "v2026.08.11-1",
            "reason": "activation-commit-failed",
            "recoveryRequired": True,
            "schemaVersion": 1,
        }

    def recovery_marker_for_action(
        self,
        release_updater,
        *,
        action: str,
        marker_sha256: str,
        target_version: str,
        transaction: Path,
    ) -> dict:
        value = self.recovery_marker(release_updater)
        value.update(
            {
                "action": action,
                "markerSha256": marker_sha256,
                "targetVersion": target_version,
                "transactionDirectory": str(transaction),
            }
        )
        return value

    def start_authorization(self, release_updater, marker_sha256: str) -> dict:
        return {
            "authorizationId": "f" * 32,
            "bootId": "12345678-1234-1234-1234-123456789abc",
            "commitSha": self.commit,
            "createdAtUtc": "2026-08-12T01:04:00Z",
            "databaseIdentity": {
                "canonicalHistorySha256": "1" * 64,
                "headVersion": 255,
                "signedProjectionSha256": "2" * 64,
                "successfulMigrationCount": 236,
                "systemIdentifier": "7523456789012345678",
                "timeline": 4,
            },
            "issuerCommandLineSha256": "4" * 64,
            "issuerExecutablePath": "/usr/bin/python3.14",
            "issuerExecutableSha256": "5" * 64,
            "issuerPid": 4242,
            "issuerStartTimeTicks": 123456,
            "manifestSha256": "3" * 64,
            "markerPath": str(release_updater.ACTIVATION_IN_PROGRESS_MARKER),
            "markerSha256": marker_sha256,
            "mode": "activation",
            "releaseSequence": self.sequence,
            "schemaVersion": 1,
            "version": self.version,
        }

    def migration_authorization(self, release_updater, marker_sha256: str) -> dict:
        return {
            "bootId": "12345678-1234-1234-1234-123456789abc",
            "commitSha": self.commit,
            "expiresAtBoottimeNs": 123000000000
            + release_updater.MIGRATION_AUTHORIZATION_TTL_SECONDS * 1_000_000_000,
            "expiresAtUnix": 1786496760 + release_updater.MIGRATION_AUTHORIZATION_TTL_SECONDS,
            "flywayHeadVersion": "255",
            "flywayMigrationSetSha256": "4" * 64,
            "issuedAtUnix": 1786496760,
            "issuedAtBoottimeNs": 123000000000,
            "issuedAtUtc": "2026-08-12T01:06:00Z",
            "issuerPid": 4242,
            "issuerProcStartTime": "123456",
            "manifestSha256": "5" * 64,
            "markerPath": str(release_updater.ACTIVATION_IN_PROGRESS_MARKER),
            "markerSha256": marker_sha256,
            "nonce": "6" * 32,
            "releaseSequence": self.sequence,
            "schemaVersion": 1,
            "targetPath": f"/opt/uten-imp/releases/{self.version}",
            "transactionEvidencePath": str(
                release_updater.MIGRATION_AUTHORIZATION_EVIDENCE_DIR
                / f"activation-{marker_sha256}-{'6' * 32}"
            ),
            "version": self.version,
        }

    def marker_values(self, release_updater) -> dict[str, dict]:
        return {
            "activation": self.activation_marker(release_updater),
            "recovery": self.recovery_marker(release_updater),
            "boot": self.boot_marker(release_updater),
        }

    def test_interrupted_assessment_covers_all_reviewed_marker_states(self) -> None:
        import release_updater

        cases = (
            (("activation",), "activation"),
            (("recovery",), "recovery"),
            (("activation", "boot"), "activation+boot"),
            (("recovery", "boot"), "recovery+boot"),
            (("boot",), "boot"),
        )
        for names, expected_kind in cases:
            with self.subTest(state=expected_kind), self.interrupted_environment(
                release_updater
            ) as paths:
                values = self.marker_values(release_updater)
                for name in names:
                    self.write_json(paths[name], values[name])
                first = release_updater.build_interrupted_containment_assessment()
                second = release_updater.build_interrupted_containment_assessment()
                self.assertEqual(first["state"]["stateKind"], expected_kind)
                self.assertEqual(first["planSha256"], second["planSha256"])
                self.assertEqual(set(first["state"]["markers"]), set(names))
                self.assertTrue(first["actions"]["contain"]["allowed"])
                self.assertEqual(
                    first["actions"]["contain"]["requiredConfirmation"],
                    f"CONTAIN-INTERRUPTED:{expected_kind}:{first['planSha256']}",
                )

    def test_recovery_double_marker_sigkill_is_contained_and_reentrant(self) -> None:
        import release_updater

        for action, target_version in (
            ("finish-activation", self.version),
            ("restore-previous", "v2026.08.11-1"),
        ):
            with self.subTest(action=action), self.interrupted_environment(
                release_updater
            ) as paths:
                prior_transaction = paths["evidence"] / (
                    "d" * 16 + "-prior_recovery"
                )
                prior_transaction.mkdir(mode=0o700)
                failure_raw = self.write_json(
                    paths["activation_failure"],
                    self.failed_activation_marker(release_updater),
                )
                failure_sha = hashlib.sha256(failure_raw).hexdigest()
                self.write_json(
                    paths["recovery"],
                    self.recovery_marker_for_action(
                        release_updater,
                        action=action,
                        marker_sha256=failure_sha,
                        target_version=target_version,
                        transaction=prior_transaction,
                    ),
                )

                first = release_updater.build_interrupted_containment_assessment()
                self.assertEqual(first["state"]["stateKind"], "recovery")
                self.assertEqual(
                    first["state"]["preexistingFailure"]["sha256"], failure_sha
                )
                self.assertTrue(first["actions"]["contain"]["allowed"])

                with mock.patch.object(
                    release_updater,
                    "_stop_and_disable_for_interrupted_containment",
                ), mock.patch.object(release_updater.os, "chown"):
                    receipt = release_updater.contain_interrupted_transaction(first)

                original = prior_transaction / "activation-failed.original.json"
                self.assertEqual(original.read_bytes(), failure_raw)
                self.assertFalse(paths["recovery"].exists())
                normalized_gate = json.loads(
                    paths["activation_failure"].read_text(encoding="utf-8")
                )
                self.assertEqual(
                    normalized_gate["reason"], "interrupted-transaction-containment"
                )
                self.assertEqual(receipt["status"], "contained-no-start")

                resumed = release_updater.build_interrupted_containment_assessment()
                self.assertEqual(resumed["planSha256"], first["planSha256"])
                self.assertEqual(
                    resumed["state"]["preexistingFailure"]["sha256"], failure_sha
                )
                context = release_updater.derive_recovery_context(
                    resumed["state"]["containmentGate"], {"state": resumed["state"]}
                )
                self.assertEqual(context["failedVersion"], self.version)
                self.assertEqual(context["finishTargetVersion"], target_version)
                self.assertEqual(
                    context["failureReason"], f"interrupted-recovery:{action}"
                )

                with mock.patch.object(
                    release_updater,
                    "_stop_and_disable_for_interrupted_containment",
                ), mock.patch.object(release_updater.os, "chown"):
                    repeated = release_updater.contain_interrupted_transaction(resumed)
                self.assertEqual(repeated, receipt)

    def test_recovery_double_marker_rejects_unbound_failure_gate(self) -> None:
        import release_updater

        with self.interrupted_environment(release_updater) as paths:
            prior_transaction = paths["evidence"] / ("e" * 16 + "-prior_recovery")
            prior_transaction.mkdir(mode=0o700)
            self.write_json(
                paths["activation_failure"],
                self.failed_activation_marker(release_updater),
            )
            self.write_json(
                paths["recovery"],
                self.recovery_marker_for_action(
                    release_updater,
                    action="finish-activation",
                    marker_sha256="f" * 64,
                    target_version=self.version,
                    transaction=prior_transaction,
                ),
            )
            with self.assertRaisesRegex(
                release_updater.UpdaterError, "does not bind the preexisting failure"
            ):
                release_updater.build_interrupted_containment_assessment()

    def test_interrupted_assessment_rejects_conflict_and_identity_drift(self) -> None:
        import release_updater

        with self.interrupted_environment(release_updater) as paths:
            values = self.marker_values(release_updater)
            self.write_json(paths["activation"], values["activation"])
            self.write_json(paths["recovery"], values["recovery"])
            with self.assertRaisesRegex(
                release_updater.UpdaterError, "empty or conflicting"
            ):
                release_updater.build_interrupted_containment_assessment()

        with self.interrupted_environment(release_updater) as paths:
            values = self.marker_values(release_updater)
            values["boot"]["commitSha"] = "e" * 40
            self.write_json(paths["activation"], values["activation"])
            self.write_json(paths["boot"], values["boot"])
            with self.assertRaisesRegex(
                release_updater.UpdaterError, "identify different releases"
            ):
                release_updater.build_interrupted_containment_assessment()

    def test_partial_archive_after_sigkill_reconstructs_the_same_plan(self) -> None:
        import release_updater

        with self.interrupted_environment(release_updater) as paths:
            marker_raw = self.write_json(
                paths["activation"], self.activation_marker(release_updater)
            )
            first = release_updater.build_interrupted_containment_assessment()
            plan_sha = first["planSha256"]
            transaction = paths["evidence"] / f"interrupted-{plan_sha}"
            transaction.mkdir(mode=0o700)
            self.write_json(
                transaction / release_updater.INTERRUPTED_CONTAINMENT_PLAN,
                {
                    "kind": "uten-imp-interrupted-containment-plan",
                    "planBasis": first["planBasis"],
                    "planSha256": plan_sha,
                    "schemaVersion": 1,
                },
            )
            self.write_json(
                paths["activation_failure"],
                {
                    "containmentStartedAtUtc": "2026-08-12T01:10:00Z",
                    "interruptedMarkerSha256": {
                        "activation": hashlib.sha256(marker_raw).hexdigest()
                    },
                    "planSha256": plan_sha,
                    "reason": "interrupted-transaction-containment",
                    "recoveryRequired": True,
                    "schemaVersion": 1,
                    "startAuthorization": None,
                    "stateKind": "activation",
                    "transactionDirectory": str(transaction),
                },
            )
            archive = release_updater.interrupted_archive_path(
                transaction, paths["activation"]
            )
            paths["activation"].replace(archive)

            resumed = release_updater.build_interrupted_containment_assessment()
            self.assertEqual(resumed["planSha256"], plan_sha)
            self.assertEqual(
                resumed["state"]["containmentGate"]["schemaKind"],
                "interrupted-containment-v1",
            )
            self.assertEqual(
                resumed["state"]["markers"]["activation"]["sha256"],
                hashlib.sha256(marker_raw).hexdigest(),
            )
            self.assertIsNone(resumed["state"]["receipt"])

    def test_unconsumed_and_consumed_start_authorizations_are_plan_bound_archives(
        self,
    ) -> None:
        import release_updater

        authorization_names = (
            "start-authorization.json",
            "start-authorization.consumed-1234-0123456789abcdef.json",
        )
        for authorization_name in authorization_names:
            with self.subTest(name=authorization_name), self.interrupted_environment(
                release_updater
            ) as paths:
                marker_raw = self.write_json(
                    paths["activation"], self.activation_marker(release_updater)
                )
                paths["authorization_dir"].mkdir(mode=0o700)
                authorization_path = paths["authorization_dir"] / authorization_name
                authorization_raw = self.write_json(
                    authorization_path,
                    self.start_authorization(
                        release_updater, hashlib.sha256(marker_raw).hexdigest()
                    ),
                )
                assessment = release_updater.build_interrupted_containment_assessment()
                observed = assessment["state"]["startAuthorization"]
                self.assertEqual(observed["path"], str(authorization_path))
                self.assertEqual(
                    observed["sha256"], hashlib.sha256(authorization_raw).hexdigest()
                )
                self.assertEqual(
                    assessment["planBasis"]["startAuthorization"]["sha256"],
                    observed["sha256"],
                )

                transaction = paths["evidence"] / (
                    f"interrupted-{assessment['planSha256']}"
                )
                transaction.mkdir(mode=0o700)
                release_updater._ensure_start_authorization_snapshot(
                    transaction, observed
                )
                archived = release_updater.archive_plan_bound_start_authorization(
                    transaction, observed
                )
                self.assertIsNotNone(archived)
                self.assertEqual(archived["originalPath"], str(authorization_path))
                self.assertEqual(archived["sha256"], observed["sha256"])
                self.assertFalse(authorization_path.exists())
                self.assertEqual(
                    Path(archived["path"]).read_bytes(), authorization_raw
                )

    def test_sigkill_unconsumed_migration_grant_is_plan_bound_and_archived(self) -> None:
        import release_updater

        with self.interrupted_environment(release_updater) as paths:
            marker_raw = self.write_json(
                paths["activation"], self.activation_marker(release_updater)
            )
            paths["migration_authorization_dir"].mkdir(mode=0o700)
            authorization_raw = self.write_json(
                paths["migration_authorization"],
                self.migration_authorization(
                    release_updater, hashlib.sha256(marker_raw).hexdigest()
                ),
            )
            paths["migration_authorization"].chmod(0o600)
            with mock.patch.object(
                release_updater, "require_root_controlled_file"
            ):
                assessment = release_updater.build_interrupted_containment_assessment()
                observed = assessment["state"]["startAuthorization"]
                self.assertEqual(
                    observed["schemaKind"], "migration-authorization-v1"
                )
                self.assertEqual(
                    observed["sha256"], hashlib.sha256(authorization_raw).hexdigest()
                )
                transaction = paths["evidence"] / (
                    f"interrupted-{assessment['planSha256']}"
                )
                transaction.mkdir(mode=0o700)
                release_updater._ensure_start_authorization_snapshot(
                    transaction, observed
                )
                archived = release_updater.archive_plan_bound_start_authorization(
                    transaction, observed
                )
            self.assertEqual(
                archived["originalPath"], str(paths["migration_authorization"])
            )
            self.assertFalse(paths["migration_authorization"].exists())
            self.assertEqual(Path(archived["path"]).read_bytes(), authorization_raw)

    def test_sigkill_consumed_migration_grant_is_plan_bound_and_archived(self) -> None:
        import release_updater

        with self.interrupted_environment(release_updater) as paths:
            marker_raw = self.write_json(
                paths["activation"], self.activation_marker(release_updater)
            )
            paths["migration_authorization_dir"].mkdir(mode=0o700)
            value = self.migration_authorization(
                release_updater, hashlib.sha256(marker_raw).hexdigest()
            )
            authorization_raw = (
                json.dumps(value, sort_keys=True, indent=2) + "\n"
            ).encode("utf-8")
            digest = hashlib.sha256(authorization_raw).hexdigest()
            consumed = paths["migration_authorization_dir"] / (
                f"migration-authorization.consumed-{value['nonce']}-{digest}.json"
            )
            consumed.write_bytes(authorization_raw)
            consumed.chmod(0o600)
            with mock.patch.object(
                release_updater, "require_root_controlled_file"
            ):
                assessment = release_updater.build_interrupted_containment_assessment()
                observed = assessment["state"]["startAuthorization"]
                self.assertEqual(
                    observed["schemaKind"], "migration-authorization-v1"
                )
                self.assertEqual(observed["path"], str(consumed))
                self.assertEqual(observed["sha256"], digest)
                transaction = paths["evidence"] / (
                    f"interrupted-{assessment['planSha256']}"
                )
                transaction.mkdir(mode=0o700)
                release_updater._ensure_start_authorization_snapshot(
                    transaction, observed
                )
                archived = release_updater.archive_plan_bound_start_authorization(
                    transaction, observed
                )
            self.assertEqual(archived["originalPath"], str(consumed))
            self.assertFalse(consumed.exists())
            self.assertEqual(Path(archived["path"]).read_bytes(), authorization_raw)

    def test_power_loss_after_gate_recovers_volatile_authorization_from_snapshot(
        self,
    ) -> None:
        import release_updater

        with self.interrupted_environment(release_updater) as paths:
            marker_raw = self.write_json(
                paths["activation"], self.activation_marker(release_updater)
            )
            paths["authorization_dir"].mkdir(mode=0o700)
            authorization_raw = self.write_json(
                paths["authorization"],
                self.start_authorization(
                    release_updater, hashlib.sha256(marker_raw).hexdigest()
                ),
            )
            first = release_updater.build_interrupted_containment_assessment()
            plan_sha = first["planSha256"]
            transaction = paths["evidence"] / f"interrupted-{plan_sha}"
            transaction.mkdir(mode=0o700)
            self.write_json(
                transaction / release_updater.INTERRUPTED_CONTAINMENT_PLAN,
                {
                    "kind": "uten-imp-interrupted-containment-plan",
                    "planBasis": first["planBasis"],
                    "planSha256": plan_sha,
                    "schemaVersion": 1,
                },
            )
            release_updater._ensure_start_authorization_snapshot(
                transaction, first["state"]["startAuthorization"]
            )
            self.write_json(
                paths["activation_failure"],
                {
                    "containmentStartedAtUtc": "2026-08-12T01:10:00Z",
                    "interruptedMarkerSha256": {
                        "activation": hashlib.sha256(marker_raw).hexdigest()
                    },
                    "planSha256": plan_sha,
                    "reason": "interrupted-transaction-containment",
                    "recoveryRequired": True,
                    "schemaVersion": 1,
                    "startAuthorization": {
                        "path": str(paths["authorization"]),
                        "sha256": hashlib.sha256(authorization_raw).hexdigest(),
                    },
                    "stateKind": "activation",
                    "transactionDirectory": str(transaction),
                },
            )
            paths["activation"].replace(
                release_updater.interrupted_archive_path(
                    transaction, paths["activation"]
                )
            )
            paths["authorization"].unlink()
            paths["authorization_dir"].rmdir()

            resumed = release_updater.build_interrupted_containment_assessment()
            self.assertEqual(resumed["planSha256"], plan_sha)
            self.assertEqual(
                resumed["state"]["startAuthorization"]["sha256"],
                hashlib.sha256(authorization_raw).hexdigest(),
            )
            self.assertEqual(
                Path(resumed["state"]["startAuthorization"]["path"]),
                paths["authorization"],
            )

    def test_containment_orders_gate_stop_archive_receipt_and_never_starts(self) -> None:
        import release_updater

        with self.interrupted_environment(release_updater) as paths:
            self.write_json(
                paths["activation"], self.activation_marker(release_updater)
            )
            assessment = release_updater.build_interrupted_containment_assessment()
            transaction = paths["evidence"] / (
                f"interrupted-{assessment['planSha256']}"
            )
            archive = release_updater.interrupted_archive_path(
                transaction, paths["activation"]
            )
            stored: dict[Path, dict] = {}
            live = {paths["activation"]: True, archive: False}
            manager = mock.Mock()

            def lexists(path):
                candidate = Path(path)
                if candidate in live:
                    return live[candidate]
                return candidate in stored

            def persist(path: Path, value: dict, mode: int = 0o640):
                self.assertEqual(mode, 0o600)
                stored[Path(path)] = value

            def observe(path: Path, label: str, validator):
                value = stored[Path(path)]
                raw = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode(
                    "utf-8"
                )
                return (
                    {
                        "fields": value,
                        "path": str(path),
                        "schemaKind": validator(value),
                        "sha256": hashlib.sha256(raw).hexdigest(),
                        "sizeBytes": len(raw),
                    },
                    raw,
                )

            def archive_marker(source: Path, destination: Path, expected: str):
                self.assertEqual(source, paths["activation"])
                self.assertEqual(destination, archive)
                self.assertEqual(
                    expected,
                    assessment["state"]["markers"]["activation"]["sha256"],
                )
                live[source] = False
                live[destination] = True
                return b"archived"

            with mock.patch.object(
                release_updater,
                "create_interrupted_transaction",
                return_value=transaction,
            ), mock.patch.object(
                release_updater, "_ensure_interrupted_plan"
            ), mock.patch.object(
                release_updater.os.path, "lexists", side_effect=lexists
            ), mock.patch.object(
                release_updater, "atomic_json", side_effect=persist
            ) as atomic_json, mock.patch.object(
                release_updater, "root_json_observation", side_effect=observe
            ), mock.patch.object(
                release_updater, "_stop_and_disable_for_interrupted_containment"
            ) as close_all, mock.patch.object(
                release_updater,
                "archive_root_evidence",
                side_effect=archive_marker,
            ) as archive_evidence:
                manager.attach_mock(atomic_json, "atomic")
                manager.attach_mock(close_all, "close_all")
                manager.attach_mock(archive_evidence, "archive")
                receipt = release_updater.contain_interrupted_transaction(assessment)

            gate_index = next(
                index
                for index, call in enumerate(manager.mock_calls)
                if call[0] == "atomic"
                and call.args[0] == paths["activation_failure"]
            )
            close_index = manager.mock_calls.index(mock.call.close_all())
            archive_index = next(
                index
                for index, call in enumerate(manager.mock_calls)
                if call[0] == "archive"
            )
            receipt_index = next(
                index
                for index, call in enumerate(manager.mock_calls)
                if call[0] == "atomic"
                and call.args[0]
                == transaction / release_updater.INTERRUPTED_CONTAINMENT_RECEIPT
            )
            self.assertLess(gate_index, close_index)
            self.assertLess(close_index, archive_index)
            self.assertLess(archive_index, receipt_index)
            self.assertEqual(receipt["status"], "contained-no-start")
            self.assertIn(paths["activation_failure"], stored)
            self.assertFalse(live[paths["activation"]])

            source = (PROJECT_ROOT / "deploy/updater/release_updater.py").read_text(
                encoding="utf-8"
            )
            containment_source = source[
                source.index("def contain_interrupted_transaction(") : source.index(
                    "\ndef contain_recovery_failure("
                )
            ]
            for forbidden in (
                "start_unit(",
                "start_application_authorized(",
                "run_migration_unit(",
                "verify_live_recovery_database(",
                "durable_unlink(",
            ):
                self.assertNotIn(forbidden, containment_source)

    def test_close_all_attempts_every_unit_and_verifies_disabled_state(self) -> None:
        import release_updater

        with mock.patch.object(release_updater, "stop_unit") as stop, mock.patch.object(
            release_updater, "run"
        ) as run, mock.patch.object(
            release_updater, "fsync_boot_enablement"
        ) as fsync, mock.patch.object(
            release_updater,
            "observe_recovery_unit",
            return_value={
                "active": False,
                "enabled": False,
                "exists": True,
                "loadState": "loaded",
            },
        ) as observe:
            release_updater._stop_and_disable_for_interrupted_containment()

        controlled = tuple(
            dict.fromkeys(
                (
                    "nginx.service",
                    release_updater.APPLICATION_UNIT,
                    release_updater.MIGRATION_UNIT,
                    *release_updater.WATCHDOG_SERVICES,
                    *release_updater.WATCHDOG_TIMERS,
                )
            )
        )
        self.assertEqual([call.args[0] for call in stop.call_args_list], list(controlled))
        self.assertEqual(
            [call.args[0] for call in observe.call_args_list],
            list(controlled),
        )
        self.assertTrue(
            set(release_updater.DATABASE_BOOT_UNITS).isdisjoint(
                call.args[0] for call in observe.call_args_list
            )
        )
        self.assertEqual(
            run.call_args_list,
            [
                mock.call(["systemctl", "disable", unit], check=False)
                for unit in release_updater.BOOT_UNITS
            ],
        )
        fsync.assert_called_once_with()

    def test_interrupted_apply_requires_fresh_plan_and_exact_confirmation(self) -> None:
        import release_updater

        assessment = {
            "actions": {
                "contain": {
                    "allowed": True,
                    "reasons": [],
                    "requiredConfirmation": "CONTAIN-INTERRUPTED:boot:" + "a" * 64,
                }
            },
            "planSha256": "a" * 64,
        }
        args = SimpleNamespace(
            action="contain",
            confirm=assessment["actions"]["contain"]["requiredConfirmation"],
            expected_plan_sha256="b" * 64,
        )
        lock = mock.MagicMock()
        with mock.patch.object(
            release_updater.os, "geteuid", return_value=0
        ), mock.patch.object(
            release_updater, "require_real_directory"
        ), mock.patch.object(
            release_updater, "StateLock", return_value=lock
        ), mock.patch.object(
            release_updater,
            "build_interrupted_containment_assessment",
            return_value=assessment,
        ), mock.patch.object(
            release_updater, "contain_interrupted_transaction"
        ) as contain, self.assertRaisesRegex(
            release_updater.UpdaterError, "assessment changed"
        ):
            release_updater.recover_interrupted_apply(args)
        contain.assert_not_called()

        parsed = release_updater.parser().parse_args(
            [
                "recover",
                "interrupted-apply",
                "--action",
                "contain",
                "--expected-plan-sha256",
                "a" * 64,
                "--confirm",
                assessment["actions"]["contain"]["requiredConfirmation"],
            ]
        )
        self.assertEqual(parsed.recovery_command, "interrupted-apply")
        self.assertEqual(parsed.action, "contain")


if __name__ == "__main__":
    unittest.main()
