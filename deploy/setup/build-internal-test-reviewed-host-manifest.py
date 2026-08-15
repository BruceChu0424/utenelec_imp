#!/usr/bin/env python3
"""Emit one canonical, reviewable host-policy manifest without mutating the host.

Run this only from the root-owned commissioning source snapshot while all entry
units are closed.  Its stdout contains hashes and host-policy parameters, never
secret values.  A separate reviewer must inspect the bytes, record their
SHA-256 out of band, and install that exact document root:root 0600 before the
preparer may apply it.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import os
import re
import stat
import subprocess
import sys
import types
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


PREPARER = Path(__file__).with_name("prepare-existing-test-host-internal-runtime.py")
BUILDER = Path(__file__)
SHA256_RE = re.compile(r"[0-9a-f]{64}")
MAX_REVIEWED_SOURCE_BYTES = 16 * 1024 * 1024
SYSTEM_CA_PATH = Path("/etc/ssl/certs")


def fail(message: str) -> None:
    raise RuntimeError(message)


def timestamp(value: str, label: str) -> datetime:
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise RuntimeError(f"{label} is not canonical UTC") from exc
    return parsed


def _validate_root_parent_chain(path: Path, label: str) -> None:
    """Reject a replaceable directory component above an executable/input."""

    current = path.parent
    while True:
        details = current.lstat()
        if (
            not stat.S_ISDIR(details.st_mode)
            or current.is_symlink()
            or details.st_uid != 0
            or details.st_gid != 0
            or details.st_mode & 0o022
        ):
            fail(f"reviewed {label} parent chain is not root controlled")
        if current == current.parent:
            return
        current = current.parent


def stable_root_source(
    path: Path,
    label: str,
    *,
    expected_mode: int | None = None,
) -> tuple[bytes, str]:
    """Read exact immutable root bytes once, bound to their live pathname."""

    _validate_root_parent_chain(path, label)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise RuntimeError(f"cannot open reviewed {label} safely") from exc
    try:
        opened = os.fstat(descriptor)
        live = path.lstat()
        if (
            not stat.S_ISREG(opened.st_mode)
            or not stat.S_ISREG(live.st_mode)
            or stat.S_ISLNK(live.st_mode)
            or opened.st_uid != 0
            or opened.st_gid != 0
            or live.st_uid != 0
            or live.st_gid != 0
            or opened.st_nlink != 1
            or live.st_nlink != 1
            or opened.st_mode & 0o022
            or (
                expected_mode is not None
                and stat.S_IMODE(opened.st_mode) != expected_mode
            )
            or not 1 <= opened.st_size <= MAX_REVIEWED_SOURCE_BYTES
            or (opened.st_dev, opened.st_ino) != (live.st_dev, live.st_ino)
        ):
            fail(f"reviewed {label} is not an immutable root-owned regular file")
        digest = hashlib.sha256()
        payload = bytearray()
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            digest.update(block)
            payload.extend(block)
        after = os.fstat(descriptor)
        live_after = path.lstat()
        if (
            opened.st_size != after.st_size
            or opened.st_mtime_ns != after.st_mtime_ns
            or opened.st_ctime_ns != after.st_ctime_ns
            or (after.st_dev, after.st_ino)
            != (live_after.st_dev, live_after.st_ino)
            or after.st_size != live_after.st_size
            or after.st_mtime_ns != live_after.st_mtime_ns
            or after.st_ctime_ns != live_after.st_ctime_ns
            or live_after.st_uid != 0
            or live_after.st_gid != 0
            or live_after.st_nlink != 1
            or live_after.st_mode & 0o022
        ):
            fail(f"reviewed {label} changed while it was hashed")
        return bytes(payload), digest.hexdigest()
    finally:
        os.close(descriptor)


def root_source_digest(path: Path, label: str) -> str:
    """Compatibility wrapper for callers that only need the stable digest."""

    return stable_root_source(path, label)[1]


def load_preparer(verified_bytes: bytes) -> Any:
    """Execute only the bytes already authenticated through the stable fd."""

    name = "uten_internal_host_preparer"
    module = types.ModuleType(name)
    module.__file__ = str(PREPARER)
    module.__package__ = ""
    sys.modules[name] = module
    try:
        code = compile(verified_bytes, str(PREPARER), "exec", dont_inherit=True)
        exec(code, module.__dict__)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


def digest_or_absent(module: Any, path: Path) -> str | None:
    if not os.path.lexists(path):
        return None
    return stable_root_source(path, f"target preimage {path}")[1]


@contextlib.contextmanager
def sealed_memory_snapshot(payload: bytes, label: str):
    """Expose exact captured bytes to a child through a sealed Linux memfd."""

    try:
        import fcntl
    except ImportError as exc:
        raise RuntimeError("sealed TLS snapshot support is unavailable") from exc
    required = (
        "F_ADD_SEALS",
        "F_GET_SEALS",
        "F_SEAL_GROW",
        "F_SEAL_SEAL",
        "F_SEAL_SHRINK",
        "F_SEAL_WRITE",
    )
    if not hasattr(os, "memfd_create") or any(
        not hasattr(fcntl, name) for name in required
    ):
        fail("sealed TLS snapshot support is unavailable")
    flags = getattr(os, "MFD_CLOEXEC", 0) | getattr(os, "MFD_ALLOW_SEALING", 0)
    try:
        descriptor = os.memfd_create(f"uten-{label}", flags)
    except OSError as exc:
        raise RuntimeError("cannot create sealed TLS snapshot") from exc
    try:
        offset = 0
        while offset < len(payload):
            try:
                written = os.write(descriptor, payload[offset:])
            except OSError as exc:
                raise RuntimeError("cannot populate sealed TLS snapshot") from exc
            if written <= 0:
                fail("sealed TLS snapshot write made no progress")
            offset += written
        seals = (
            fcntl.F_SEAL_GROW
            | fcntl.F_SEAL_SEAL
            | fcntl.F_SEAL_SHRINK
            | fcntl.F_SEAL_WRITE
        )
        try:
            fcntl.fcntl(descriptor, fcntl.F_ADD_SEALS, seals)
            observed = fcntl.fcntl(descriptor, fcntl.F_GET_SEALS)
        except OSError as exc:
            raise RuntimeError("cannot seal TLS snapshot") from exc
        if observed & seals != seals or os.fstat(descriptor).st_size != len(payload):
            fail("TLS snapshot seal or size differs")
        yield descriptor
    finally:
        os.close(descriptor)


def validate_tls_snapshot(domain: str, certificate: bytes, key: bytes) -> None:
    """Validate exact SAN, system-CA chain, expiry, and key on captured bytes."""

    def openssl(
        arguments: list[str],
        payload: bytes | None = None,
        *,
        pass_fds: tuple[int, ...] = (),
    ) -> bytes:
        try:
            completed = subprocess.run(
                ["/usr/bin/openssl", *arguments],
                input=b"" if payload is None else payload,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                env={"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"},
                pass_fds=pass_fds,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RuntimeError("cannot execute the fixed OpenSSL verifier") from exc
        if (
            completed.returncode != 0
            or len(completed.stdout) > 1024 * 1024
            or len(completed.stderr) > 1024 * 1024
        ):
            fail("reviewed TLS snapshot failed OpenSSL validation")
        return completed.stdout

    openssl(["x509", "-noout", "-checkend", "86400"], certificate)
    san_output = openssl(
        ["x509", "-noout", "-ext", "subjectAltName"], certificate
    )
    try:
        san_text = san_output.decode("ascii", errors="strict")
    except UnicodeDecodeError as exc:
        raise RuntimeError("TLS subjectAltName output is not canonical ASCII") from exc
    dns_sans = {
        value.rstrip(".").lower()
        for value in re.findall(r"(?:^|[,\s])DNS:([^,\s]+)", san_text)
    }
    if domain not in dns_sans:
        fail("TLS certificate lacks the exact reviewed DNS subjectAltName")

    _validate_root_parent_chain(
        SYSTEM_CA_PATH / ".uten-imp-system-ca-authority",
        "system CA store",
    )
    with sealed_memory_snapshot(certificate, "reviewed-tls-certificate") as descriptor:
        openssl(
            [
                "verify",
                "-x509_strict",
                "-purpose",
                "sslserver",
                "-verify_hostname",
                domain,
                "-CApath",
                str(SYSTEM_CA_PATH),
                "-untrusted",
                f"/proc/self/fd/{descriptor}",
                f"/proc/self/fd/{descriptor}",
            ],
            pass_fds=(descriptor,),
        )
    certificate_key = openssl(["x509", "-pubkey", "-noout"], certificate)
    private_key = openssl(["pkey", "-pubout"], key)
    if not certificate_key or certificate_key != private_key:
        fail("reviewed TLS certificate and private key do not match")


def build(args: argparse.Namespace) -> bytes:
    if os.geteuid() != 0:
        fail("review manifest assessment must run as root")
    # These checks must precede import: both files are executable Python and
    # therefore cannot be allowed to validate its own metadata after loading.
    _builder_bytes, builder_digest = stable_root_source(
        BUILDER, "host manifest builder"
    )
    if builder_digest != args.expected_builder_sha256:
        fail("builder bytes differ from the independently reviewed digest")
    preparer_bytes, preparer_digest = stable_root_source(PREPARER, "host preparer")
    if preparer_digest != args.expected_preparer_sha256:
        fail("preparer bytes differ from the independently reviewed digest")
    module = load_preparer(preparer_bytes)
    module.entry_closed()
    module.validate_network_inputs(args.domain, args.office_cidr)
    if (
        args.tls_cert.parent.resolve(strict=True) != module.TLS_ROOT.resolve(strict=True)
        or args.tls_key.parent.resolve(strict=True) != module.TLS_ROOT.resolve(strict=True)
    ):
        fail("TLS material must be a direct child of the fixed private directory")
    certificate, certificate_digest = stable_root_source(
        args.tls_cert, "TLS certificate", expected_mode=0o644
    )
    private_key, private_key_digest = stable_root_source(
        args.tls_key, "TLS private key", expected_mode=0o600
    )
    validate_tls_snapshot(args.domain, certificate, private_key)
    nginx_template, nginx_template_digest = stable_root_source(
        module.NGINX_SOURCE, "Nginx template"
    )
    if (
        hashlib.sha256(
            module.prospective_nginx_expanded(
                args.domain,
                args.office_cidr,
                args.tls_cert,
                args.tls_key,
                nginx_template,
            )
        ).hexdigest()
        != args.expected_nginx_expanded_config_sha256
    ):
        fail("prospective Nginx graph differs from the independently reviewed digest")
    if not module.APPROVAL_RE.fullmatch(args.approval_reference):
        fail("review approval reference is malformed")
    for value, label in (
        (args.expected_preparer_sha256, "preparer"),
        (args.server_environment_preimage_sha256, "server environment preimage"),
        (args.server_environment_sha256, "server environment target"),
        (args.allowed_signers_sha256, "allowed signers"),
        (args.expected_nginx_expanded_config_sha256, "expanded Nginx configuration"),
        (args.updater_venv_inventory_sha256, "updater virtualenv inventory"),
    ):
        if SHA256_RE.fullmatch(value) is None:
            fail(f"{label} digest is malformed")
    created = timestamp(args.created_at_utc, "review creation time")
    expires = timestamp(args.expires_at_utc, "review expiry time")
    now = datetime.now(timezone.utc)
    if (
        expires <= created
        or expires - created > timedelta(days=7)
        or created > now
        or now > expires
    ):
        fail("review validity window is empty or exceeds seven days")

    source: dict[str, str] = {}
    trusted_installer_payloads: dict[str, bytes] = {}
    for key, path in module.SOURCES.items():
        payload, digest = stable_root_source(path, f"source {key}")
        source[key] = digest
        if key in module.TRUSTED_INSTALLER_SOURCE_KEYS:
            trusted_installer_payloads[key] = payload
    module.validate_trusted_installer_source_payloads(trusted_installer_payloads)
    source["manifestBuilderSha256"] = builder_digest
    source["nginxTemplateSha256"] = nginx_template_digest
    trusted_installer_preimage = module.trusted_installer_target_preimages()
    target: dict[str, str | None] = {}
    for key, path in module.TARGETS.items():
        if key in trusted_installer_preimage:
            target[key] = trusted_installer_preimage[key]
        else:
            target[key] = digest_or_absent(module, path)
    for key in module.TRUSTED_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEYS:
        target[key] = trusted_installer_preimage[key]
    target["nginxConfigSha256"] = digest_or_absent(module, module.NGINX_TARGET)
    target["legacyNginxConfigSha256"] = digest_or_absent(
        module, module.LEGACY_NGINX_TARGET
    )
    value = {
        "approvalReference": args.approval_reference,
        "builderSha256": builder_digest,
        "createdAtUtc": args.created_at_utc,
        "expiresAtUtc": args.expires_at_utc,
        "hostParameters": {
            "allowedSignersSha256": args.allowed_signers_sha256,
            "domain": args.domain,
            "expectedNginxExpandedConfigSha256": args.expected_nginx_expanded_config_sha256,
            "officeCidr": args.office_cidr,
            "serverEnvironmentPreimageSha256": args.server_environment_preimage_sha256,
            "serverEnvironmentSha256": args.server_environment_sha256,
            "tlsCertificateSha256": certificate_digest,
            "tlsKeySha256": private_key_digest,
            "updaterVenvInventorySha256": args.updater_venv_inventory_sha256,
        },
        "kind": "uten-imp-internal-test-reviewed-host-sources",
        "preparerSha256": args.expected_preparer_sha256,
        "schemaVersion": 1,
        "sourceSha256": source,
        "targetPreimageSha256": target,
    }
    return module.canonical(value)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    result.add_argument("--domain", required=True)
    result.add_argument("--office-cidr", required=True)
    result.add_argument("--tls-cert", required=True, type=Path)
    result.add_argument("--tls-key", required=True, type=Path)
    result.add_argument("--approval-reference", required=True)
    result.add_argument("--created-at-utc", required=True)
    result.add_argument("--expires-at-utc", required=True)
    result.add_argument("--expected-preparer-sha256", required=True)
    result.add_argument("--expected-builder-sha256", required=True)
    result.add_argument("--expected-nginx-expanded-config-sha256", required=True)
    result.add_argument("--server-environment-preimage-sha256", required=True)
    result.add_argument("--server-environment-sha256", required=True)
    result.add_argument("--allowed-signers-sha256", required=True)
    result.add_argument("--updater-venv-inventory-sha256", required=True)
    return result


def main() -> int:
    try:
        payload = build(parser().parse_args())
    except Exception as exc:
        print(f"INTERNAL_TEST_HOST_REVIEW_MANIFEST_NO_GO: {exc}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
