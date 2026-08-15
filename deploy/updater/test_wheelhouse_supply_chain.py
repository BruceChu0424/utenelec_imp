from __future__ import annotations

import base64
import csv
import hashlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import wheelhouse_supply_chain as supply_chain


class WheelhouseSupplyChainTest(unittest.TestCase):
    commit = "0123456789abcdef0123456789abcdef01234567"
    timestamp = "2026-08-12T08:00:00Z"
    builder = "python:3.12.11-slim-bookworm@sha256:" + "a" * 64

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.wheelhouse = self.root / "wheelhouse"
        self.wheelhouse.mkdir()
        self.requirements_input = self.root / "requirements.in"
        self.requirements_input.write_text("oss2==2.19.1\n", encoding="ascii")
        self.source_lock = self.root / "sources.lock"
        self.source_lock.write_text(
            "aliyun-python-sdk-core==2.16.0 --hash=sha256:" + "1" * 64 + "\n"
            "crcmod==1.7 --hash=sha256:" + "2" * 64 + "\n"
            "oss2==2.19.1 --hash=sha256:" + "3" * 64 + "\n",
            encoding="ascii",
        )
        self.build_lock = self.root / "build.lock"
        self.build_lock.write_text(
            "setuptools==80.9.0 --hash=sha256:" + "4" * 64 + "\n"
            "wheel==0.45.1 --hash=sha256:" + "5" * 64 + "\n",
            encoding="ascii",
        )
        self.builder_script = self.root / "build-wheelhouse.sh"
        self.builder_script.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="ascii")
        self.verifier_source = self.root / "wheelhouse_supply_chain.py"
        self.verifier_source.write_text("# reviewed verifier fixture\n", encoding="ascii")
        self._write_wheel("oss2", "2.19.1", ("dependency>=1",))
        self._write_wheel("dependency", "1.0", ())
        self.lock = self.root / "requirements.lock"
        self._write_lock()
        self.sums = self.root / "wheelhouse.SHA256SUMS"
        self.sbom = self.root / "wheelhouse.cdx.json"
        self.attestation = self.root / "wheelhouse.attestation.json"
        self._generate()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_wheel(
        self,
        name: str,
        version: str,
        requirements: tuple[str, ...],
        *,
        tag: str = "py3-none-any",
        add_pth: bool = False,
        embedded_tags: tuple[str, ...] | None = None,
        dist_info_suffix: str = "",
    ) -> Path:
        filename_name = name.replace("-", "_")
        path = self.wheelhouse / f"{filename_name}-{version}-{tag}.whl"
        dist_info = f"{filename_name}-{version}{dist_info_suffix}.dist-info"
        metadata = [
            "Metadata-Version: 2.1",
            f"Name: {name}",
            f"Version: {version}",
        ]
        metadata.extend(f"Requires-Dist: {requirement}" for requirement in requirements)
        metadata.append("")
        metadata.append("")
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(f"{name.replace('-', '_')}/__init__.py", "")
            archive.writestr(f"{dist_info}/METADATA", "\n".join(metadata))
            python_tag, abi_tag, platform_tag = tag.split("-", 2)
            if embedded_tags is None:
                embedded_tags = tuple(
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
                + "".join(f"Tag: {wheel_tag}\n" for wheel_tag in embedded_tags),
            )
            archive.writestr(f"{dist_info}/RECORD", "")
            if add_pth:
                archive.writestr("execute-me.pth", "import os\n")
        return path

    def _write_lock(self) -> None:
        rows = []
        for wheel in sorted(self.wheelhouse.glob("*.whl")):
            info = supply_chain.inspect_wheel(wheel)
            rows.append(
                f"{info.name}=={info.version} --hash=sha256:{info.sha256}\n"
            )
        self.lock.write_text("".join(rows), encoding="ascii")

    def _generate(self) -> None:
        supply_chain.command_generate(
            SimpleNamespace(
                requirements_input=self.requirements_input,
                source_lock=self.source_lock,
                build_lock=self.build_lock,
                builder_script=self.builder_script,
                verifier_source=self.verifier_source,
                lock=self.lock,
                wheelhouse=self.wheelhouse,
                sums=self.sums,
                sbom=self.sbom,
                attestation=self.attestation,
                commit=self.commit,
                timestamp=self.timestamp,
                builder_image=self.builder,
            )
        )

    def _verify(self) -> None:
        supply_chain.verify_bundle(
            self.wheelhouse,
            self.lock,
            self.sums,
            self.sbom,
            self.attestation,
        )

    def test_valid_lock_wheels_sbom_and_attestation_are_bound(self) -> None:
        lock, wheels = supply_chain.verify_bundle(
            self.wheelhouse,
            self.lock,
            self.sums,
            self.sbom,
            self.attestation,
        )
        self.assertEqual(set(lock), {"dependency", "oss2"})
        self.assertEqual(set(wheels), set(lock))
        statement = json.loads(self.attestation.read_text(encoding="utf-8"))
        self.assertEqual(statement["predicateType"], "https://cyclonedx.org/bom")
        properties = {
            item["name"]: item["value"]
            for item in statement["predicate"]["metadata"]["properties"]
        }
        self.assertEqual(
            properties["uten:builder:script-sha256"],
            supply_chain.sha256_file(self.builder_script),
        )
        self.assertEqual(
            properties["uten:builder:verifier-sha256"],
            supply_chain.sha256_file(self.verifier_source),
        )

    def test_runtime_lock_is_reproducibly_rendered_from_exact_wheels(self) -> None:
        rendered = self.root / "rendered.lock"
        supply_chain.command_render_runtime_lock(
            SimpleNamespace(wheelhouse=self.wheelhouse, output=rendered)
        )
        self.assertEqual(
            supply_chain.parse_requirements_lock(rendered),
            supply_chain.parse_requirements_lock(self.lock),
        )
        self.assertTrue(rendered.read_bytes().startswith(supply_chain.RUNTIME_LOCK_HEADER.encode("ascii")))

    def test_missing_dependency_wheel_is_rejected(self) -> None:
        (self.wheelhouse / "dependency-1.0-py3-none-any.whl").unlink()
        with self.assertRaises(supply_chain.WheelhouseError):
            self._verify()

    def test_extra_or_duplicate_wheel_is_rejected(self) -> None:
        self._write_wheel("unlocked", "1.0", ())
        with self.assertRaises(supply_chain.WheelhouseError):
            self._verify()

    def test_changed_wheel_is_rejected(self) -> None:
        wheel = self.wheelhouse / "oss2-2.19.1-py3-none-any.whl"
        with zipfile.ZipFile(wheel, "a", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("oss2/tampered.py", "tampered = True\n")
        with self.assertRaises(supply_chain.WheelhouseError):
            self._verify()

    def test_fake_sbom_or_attestation_is_rejected(self) -> None:
        original_sbom = self.sbom.read_bytes()
        original_attestation = self.attestation.read_bytes()
        sbom = json.loads(self.sbom.read_text(encoding="utf-8"))
        sbom["components"][0]["hashes"][0]["content"] = "0" * 64
        self.sbom.write_bytes(supply_chain.canonical_json_bytes(sbom))
        with self.assertRaises(supply_chain.WheelhouseError):
            self._verify()
        self.sbom.write_bytes(original_sbom)
        attestation = json.loads(original_attestation.decode("utf-8"))
        attestation["predicateType"] = "https://example.invalid/fake"
        self.attestation.write_bytes(supply_chain.canonical_json_bytes(attestation))
        with self.assertRaises(supply_chain.WheelhouseError):
            self._verify()

    def test_attestation_signature_namespace_and_tamper_are_enforced(self) -> None:
        ssh_keygen = shutil.which("ssh-keygen")
        if not ssh_keygen:
            self.skipTest("OpenSSH ssh-keygen is not installed")
        key = self.root / "wheelhouse-signing-key"
        subprocess.run(
            [ssh_keygen, "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        public_key = key.with_suffix(".pub").read_text(encoding="ascii").strip()
        allowed = self.root / "allowed-signers"
        allowed.write_text(f"uten-imp-release {public_key}\n", encoding="ascii")
        subprocess.run(
            [
                ssh_keygen,
                "-Y",
                "sign",
                "-f",
                str(key),
                "-n",
                "uten-imp-updater-wheelhouse-v1",
                str(self.attestation),
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        signature = Path(f"{self.attestation}.sig")

        def verify(content: bytes, namespace: str) -> subprocess.CompletedProcess[bytes]:
            return subprocess.run(
                [
                    ssh_keygen,
                    "-Y",
                    "verify",
                    "-f",
                    str(allowed),
                    "-I",
                    "uten-imp-release",
                    "-n",
                    namespace,
                    "-s",
                    str(signature),
                ],
                input=content,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        original = self.attestation.read_bytes()
        self.assertEqual(verify(original, "uten-imp-updater-wheelhouse-v1").returncode, 0)
        self.assertNotEqual(verify(original + b"tampered\n", "uten-imp-updater-wheelhouse-v1").returncode, 0)
        self.assertNotEqual(verify(original, "uten-imp-release-v1").returncode, 0)

    def test_unhashed_lock_is_rejected(self) -> None:
        self.lock.write_text("oss2==2.19.1\n", encoding="ascii")
        with self.assertRaises(supply_chain.WheelhouseError):
            self._verify()

    def test_sdist_or_pth_is_rejected(self) -> None:
        (self.wheelhouse / "crcmod-1.7.tar.gz").write_bytes(b"not-a-wheel")
        with self.assertRaises(supply_chain.WheelhouseError):
            supply_chain.load_wheelhouse(self.wheelhouse)
        (self.wheelhouse / "crcmod-1.7.tar.gz").unlink()
        self._write_wheel("unsafe", "1.0", (), add_pth=True)
        with self.assertRaises(supply_chain.WheelhouseError):
            supply_chain.load_wheelhouse(self.wheelhouse)

    def test_wheel_filename_and_embedded_tags_must_match(self) -> None:
        mismatched = self._write_wheel(
            "mismatched", "1.0", (), embedded_tags=("py2-none-any",)
        )
        with self.assertRaises(supply_chain.WheelhouseError):
            supply_chain.inspect_wheel(mismatched)
        forged_dist_info = self._write_wheel(
            "forged", "1.0", (), dist_info_suffix="evil"
        )
        with self.assertRaises(supply_chain.WheelhouseError):
            supply_chain.inspect_wheel(forged_dist_info)

    @staticmethod
    def _record_hash(content: bytes) -> str:
        return base64.urlsafe_b64encode(hashlib.sha256(content).digest()).decode("ascii").rstrip("=")

    class _RootOwnedStat:
        def __init__(self, details):
            self._details = details
            self.st_uid = 0
            self.st_gid = 0

        def __getattr__(self, name):
            return getattr(self._details, name)

    def _verify_installed_root_fixture(
        self, venv: Path, lock: dict[str, supply_chain.LockedRequirement]
    ) -> None:
        """Exercise the production root-owned contract on an unprivileged CI runner."""
        real_lstat = Path.lstat

        def root_owned_lstat(path: Path, *args, **kwargs):
            details = real_lstat(path, *args, **kwargs)
            try:
                path.relative_to(venv)
            except ValueError:
                return details
            return self._RootOwnedStat(details)

        with mock.patch.object(
            Path,
            "lstat",
            autospec=True,
            side_effect=root_owned_lstat,
        ):
            supply_chain.verify_installed(venv, lock)

    def _make_installed_venv(self) -> Path:
        venv = self.root / "venv"
        site = venv / "lib/python3.12/site-packages"
        site.mkdir(parents=True)
        lock = supply_chain.parse_requirements_lock(self.lock)
        for name, requirement in lock.items():
            module_path = site / f"{name.replace('-', '_')}.py"
            metadata_path = site / f"{name.replace('-', '_')}-{requirement.version}.dist-info/METADATA"
            record_path = metadata_path.parent / "RECORD"
            metadata_path.parent.mkdir()
            module_content = f"VERSION = {requirement.version!r}\n".encode("utf-8")
            metadata_content = (
                f"Metadata-Version: 2.1\nName: {name}\nVersion: {requirement.version}\n\n"
            ).encode("utf-8")
            module_path.write_bytes(module_content)
            metadata_path.write_bytes(metadata_content)
            rows = [
                [
                    module_path.relative_to(site).as_posix(),
                    f"sha256={self._record_hash(module_content)}",
                    str(len(module_content)),
                ],
                [
                    metadata_path.relative_to(site).as_posix(),
                    f"sha256={self._record_hash(metadata_content)}",
                    str(len(metadata_content)),
                ],
                [record_path.relative_to(site).as_posix(), "", ""],
            ]
            output = io.StringIO(newline="")
            csv.writer(output, lineterminator="\n").writerows(rows)
            record_path.write_text(output.getvalue(), encoding="utf-8", newline="")
        return venv

    def test_installed_dist_info_record_and_package_set_are_exact(self) -> None:
        venv = self._make_installed_venv()
        lock = supply_chain.parse_requirements_lock(self.lock)
        self._verify_installed_root_fixture(venv, lock)
        (venv / "lib/python3.12/site-packages/extra.pth").write_text(
            "import os\n", encoding="utf-8"
        )
        with self.assertRaises(supply_chain.WheelhouseError):
            self._verify_installed_root_fixture(venv, lock)

    def test_installed_recorded_venv_script_is_allowed_but_escape_or_extra_is_rejected(self) -> None:
        venv = self._make_installed_venv()
        lock = supply_chain.parse_requirements_lock(self.lock)
        script = venv / "bin/cffi-gen-src"
        script.parent.mkdir()
        script_content = b"#!/usr/bin/python3\n"
        script.write_bytes(script_content)
        record = venv / "lib/python3.12/site-packages/dependency-1.0.dist-info/RECORD"
        with record.open("a", encoding="utf-8", newline="") as handle:
            csv.writer(handle, lineterminator="\n").writerow(
                [
                    "../../../bin/cffi-gen-src",
                    f"sha256={self._record_hash(script_content)}",
                    str(len(script_content)),
                ]
            )
        self._verify_installed_root_fixture(venv, lock)

        extra = venv / "bin/unrecorded"
        extra.write_bytes(b"unexpected\n")
        with self.assertRaises(supply_chain.WheelhouseError):
            self._verify_installed_root_fixture(venv, lock)
        extra.unlink()

        outside = self.root / "outside"
        outside_content = b"outside\n"
        outside.write_bytes(outside_content)
        with record.open("a", encoding="utf-8", newline="") as handle:
            csv.writer(handle, lineterminator="\n").writerow(
                [
                    "../../../../../../outside",
                    f"sha256={self._record_hash(outside_content)}",
                    str(len(outside_content)),
                ]
            )
        with self.assertRaises(supply_chain.WheelhouseError):
            self._verify_installed_root_fixture(venv, lock)

    def test_installed_hardlink_is_rejected(self) -> None:
        venv = self._make_installed_venv()
        lock = supply_chain.parse_requirements_lock(self.lock)
        site = venv / "lib/python3.12/site-packages"
        os.link(site / "oss2.py", site / "oss2-alias.py")
        with self.assertRaises(supply_chain.WheelhouseError):
            self._verify_installed_root_fixture(venv, lock)

    def test_installed_file_tampering_and_extra_dist_info_are_rejected(self) -> None:
        venv = self._make_installed_venv()
        lock = supply_chain.parse_requirements_lock(self.lock)
        module = venv / "lib/python3.12/site-packages/oss2.py"
        module.write_text("tampered = True\n", encoding="utf-8")
        with self.assertRaises(supply_chain.WheelhouseError):
            self._verify_installed_root_fixture(venv, lock)
        shutil.rmtree(venv)
        venv = self._make_installed_venv()
        extra = venv / "lib/python3.12/site-packages/extra-1.0.dist-info"
        extra.mkdir()
        (extra / "METADATA").write_text(
            "Metadata-Version: 2.1\nName: extra\nVersion: 1.0\n\n",
            encoding="utf-8",
        )
        (extra / "RECORD").write_text("extra-1.0.dist-info/RECORD,,\n", encoding="utf-8")
        with self.assertRaises(supply_chain.WheelhouseError):
            self._verify_installed_root_fixture(venv, lock)


if __name__ == "__main__":
    unittest.main()
