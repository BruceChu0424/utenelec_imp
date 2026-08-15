#!/usr/bin/env python3
"""Consume and verify one volatile authorization before the Flyway JVM starts."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import sys
import time
import types
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NoReturn


RELEASE_BASE = Path("/opt/uten-imp")
RELEASES_DIR = RELEASE_BASE / "releases"
CURRENT_LINK = RELEASE_BASE / "current"
ROOT_STATE_DIR = Path("/var/lib/uten-imp-release")
ACTIVATION_FAILURE_MARKER = ROOT_STATE_DIR / "activation-failed.json"
ACTIVATION_IN_PROGRESS_MARKER = ROOT_STATE_DIR / "activation-in-progress.json"
OPERATION_LOCK = ROOT_STATE_DIR / "operation.lock"
MIGRATION_EVIDENCE_DIR = ROOT_STATE_DIR / "migration-evidence"
AUTHORIZATION_DIR = Path("/run/uten-imp-migration-authorization")
AUTHORIZATION = AUTHORIZATION_DIR / "migration-authorization.json"
BOOT_ID_PATH = Path("/proc/sys/kernel/random/boot_id")
PROC_ROOT = Path("/proc")
STABLE_RELEASE_GUARD = Path(
    "/usr/local/libexec/uten-imp-release/release_guard.py"
)
STABLE_ALLOWED_SIGNERS = Path(
    "/etc/uten-imp-release-trust/release-allowed-signers"
)
UPDATER_SCRIPT = Path("/opt/uten-imp/updater/release_updater.py")
UPDATER_GROUP = "uten-imp-updater"
RELEASE_GUARD_SHA256 = (
    "2f3553f2fe3757b923a535925212877ce9b411c6743986d0c458ee07a2506833"
)
MAX_JSON_BYTES = 4 * 1024 * 1024
AUTHORIZATION_TTL_SECONDS = 120
FUTURE_CLOCK_TOLERANCE_SECONDS = 5
SHA256_RE = re.compile(r"[0-9a-f]{64}")
NONCE_RE = re.compile(r"[0-9a-f]{32}")
VERSION_RE = re.compile(r"v\d{4}\.\d{2}\.\d{2}-[1-9]\d{0,2}")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
BOOT_ID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
)
PYTHON_EXE_RE = re.compile(r"/usr/bin/python3(?:\.[0-9]+)?")
EVIDENCE_TRANSACTION_RE = re.compile(
    r"activation-[0-9a-f]{64}-[0-9a-f]{32}"
)


class MigrationAuthorizationError(RuntimeError):
    """A one-use migration authorization is absent, stale, or inconsistent."""


def fail(message: str) -> NoReturn:
    raise MigrationAuthorizationError(message)


def _lexists(path: Path) -> bool:
    return os.path.lexists(path)


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _require_root_directory(path: Path, *, mode: int | None = None) -> os.stat_result:
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise MigrationAuthorizationError(f"required directory is missing: {path}") from exc
    if (
        not stat.S_ISDIR(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_gid != 0
        or details.st_mode & 0o022
        or (mode is not None and stat.S_IMODE(details.st_mode) != mode)
    ):
        fail(f"root-controlled directory is unsafe: {path}")
    return details


def _stat_fingerprint(details: os.stat_result) -> tuple[int, ...]:
    return (
        details.st_dev,
        details.st_ino,
        details.st_mode,
        details.st_uid,
        details.st_gid,
        details.st_nlink,
        details.st_size,
        details.st_mtime_ns,
        details.st_ctime_ns,
    )


def _require_root_parent_chain(
    path: Path,
) -> tuple[tuple[str, tuple[int, ...]], ...]:
    captured: list[tuple[str, tuple[int, ...]]] = []
    current = path.parent
    while True:
        try:
            details = current.lstat()
        except OSError as exc:
            raise MigrationAuthorizationError(
                f"root-controlled parent is missing: {current}"
            ) from exc
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or details.st_mode & 0o022
        ):
            fail(f"root-controlled parent directory is unsafe: {current}")
        captured.append((str(current), _stat_fingerprint(details)))
        if current == current.parent:
            return tuple(captured)
        current = current.parent


def _require_root_file(
    path: Path,
    *,
    mode: int,
    maximum_bytes: int = MAX_JSON_BYTES,
    minimum_bytes: int = 1,
    owner_gid: int = 0,
) -> os.stat_result:
    _require_root_parent_chain(path)
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise MigrationAuthorizationError(f"required file is missing: {path}") from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_gid != owner_gid
        or details.st_nlink != 1
        or stat.S_IMODE(details.st_mode) != mode
        or not minimum_bytes <= details.st_size <= maximum_bytes
    ):
        fail(f"root-controlled file is unsafe: {path}")
    return details


def _read_stable_bytes(path: Path, *, mode: int, maximum_bytes: int) -> bytes:
    parent_before = _require_root_parent_chain(path)
    expected = _require_root_file(path, mode=mode, maximum_bytes=maximum_bytes)
    if not hasattr(os, "O_NOFOLLOW"):
        fail("platform lacks no-follow evidence reads")
    try:
        descriptor = os.open(
            path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        )
    except OSError as exc:
        raise MigrationAuthorizationError(
            f"cannot open root-controlled file safely: {path}"
        ) from exc
    try:
        observed = os.fstat(descriptor)
        if (
            not stat.S_ISREG(observed.st_mode)
            or _stat_fingerprint(observed) != _stat_fingerprint(expected)
            or observed.st_nlink != 1
            or observed.st_uid != 0
            or observed.st_gid != 0
            or stat.S_IMODE(observed.st_mode) != mode
        ):
            fail(f"root-controlled file changed during open: {path}")
        chunks: list[bytes] = []
        remaining = maximum_bytes + 1
        while remaining:
            block = os.read(descriptor, min(64 * 1024, remaining))
            if not block:
                break
            chunks.append(block)
            remaining -= len(block)
        raw = b"".join(chunks)
        after = os.fstat(descriptor)
        try:
            live_after = path.lstat()
        except OSError as exc:
            raise MigrationAuthorizationError(
                f"root-controlled file pathname changed during read: {path}"
            ) from exc
        if (
            len(raw) != observed.st_size
            or len(raw) > maximum_bytes
            or _stat_fingerprint(after) != _stat_fingerprint(observed)
            or _stat_fingerprint(live_after) != _stat_fingerprint(observed)
            or _require_root_parent_chain(path) != parent_before
        ):
            fail(f"root-controlled file changed during read: {path}")
        return raw
    finally:
        os.close(descriptor)


def _strict_json(raw: bytes, label: str) -> dict[str, Any]:
    if not 1 <= len(raw) <= MAX_JSON_BYTES or b"\0" in raw:
        fail(f"{label} size is outside the trusted range")

    def pairs(values: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in values:
            if key in result:
                fail(f"{label} contains a duplicate key")
            result[key] = value
        return result

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=pairs,
            parse_constant=lambda constant: fail(
                f"{label} contains a non-finite number: {constant}"
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MigrationAuthorizationError(f"{label} is not strict UTF-8 JSON") from exc
    if not isinstance(value, dict):
        fail(f"{label} root must be an object")
    return value


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        fail(f"{label} schema is unsupported")


def _string(value: Any, label: str, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str) or not value or (pattern and not pattern.fullmatch(value)):
        fail(f"{label} is malformed")
    return value


def _integer(value: Any, label: str, *, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        fail(f"{label} is malformed")
    return value


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _boot_id() -> str:
    try:
        value = BOOT_ID_PATH.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise MigrationAuthorizationError("kernel boot ID cannot be read") from exc
    return _string(value, "kernel boot ID", BOOT_ID_RE)


def _boottime_ns() -> int:
    clock = getattr(time, "CLOCK_BOOTTIME", None)
    if clock is None or not hasattr(time, "clock_gettime_ns"):
        fail("kernel CLOCK_BOOTTIME is unavailable")
    try:
        value = time.clock_gettime_ns(clock)
    except OSError as exc:
        raise MigrationAuthorizationError("kernel CLOCK_BOOTTIME cannot be read") from exc
    if not isinstance(value, int) or value < 1:
        fail("kernel CLOCK_BOOTTIME is malformed")
    return value


def _validate_freshness(authorization: dict[str, Any]) -> None:
    issued = _integer(authorization.get("issuedAtUnix"), "authorization issue time", minimum=1)
    expires = _integer(
        authorization.get("expiresAtUnix"), "authorization expiry time", minimum=1
    )
    issued_boot = _integer(
        authorization.get("issuedAtBoottimeNs"),
        "authorization boot-time issue tick",
        minimum=1,
    )
    expires_boot = _integer(
        authorization.get("expiresAtBoottimeNs"),
        "authorization boot-time expiry tick",
        minimum=1,
    )
    if (
        expires - issued != AUTHORIZATION_TTL_SECONDS
        or expires_boot - issued_boot != AUTHORIZATION_TTL_SECONDS * 1_000_000_000
    ):
        fail("migration authorization TTL differs from the fixed policy")
    now = int(time.time())
    now_boot = _boottime_ns()
    if (
        issued > now + FUTURE_CLOCK_TOLERANCE_SECONDS
        or now >= expires
        or issued_boot > now_boot
        or now_boot >= expires_boot
    ):
        fail("migration authorization is expired or from the future")
    issued_utc = _string(
        authorization.get("issuedAtUtc"), "authorization UTC issue time"
    )
    if not issued_utc.endswith("Z"):
        fail("authorization UTC issue time is not canonical UTC")
    try:
        issued_datetime = datetime.fromisoformat(issued_utc[:-1] + "+00:00")
    except ValueError as exc:
        raise MigrationAuthorizationError(
            "authorization UTC issue time is malformed"
        ) from exc
    if (
        issued_datetime.tzinfo != timezone.utc
        or abs(int(issued_datetime.timestamp()) - issued) > 1
    ):
        fail("authorization UTC and epoch issue times disagree")


def _proc_start_time(raw: str) -> str:
    closing = raw.rfind(")")
    if closing < 2 or not re.fullmatch(r"[1-9][0-9]* \([\s\S]*\)", raw[: closing + 1]):
        fail("issuer process stat is malformed")
    fields = raw[closing + 1 :].strip().split()
    # fields begins with Linux proc stat field 3; starttime is field 22.
    if len(fields) < 20 or not fields[19].isdigit() or int(fields[19]) < 1:
        fail("issuer process start time is malformed")
    return fields[19]


def _read_proc_start_time(pid: int) -> str:
    try:
        raw = (PROC_ROOT / str(pid) / "stat").read_text(encoding="ascii")
    except (OSError, UnicodeDecodeError) as exc:
        raise MigrationAuthorizationError("authorized updater process is not alive") from exc
    return _proc_start_time(raw)


def _issuer_holds_operation_lock(pid: int) -> None:
    try:
        import grp

        expected_gid = grp.getgrnam(UPDATER_GROUP).gr_gid
    except KeyError as exc:
        raise MigrationAuthorizationError("updater coordination group is missing") from exc
    lock = _require_root_file(
        OPERATION_LOCK,
        mode=0o660,
        maximum_bytes=4096,
        minimum_bytes=0,
        owner_gid=expected_gid,
    )
    descriptor_dir = PROC_ROOT / str(pid) / "fd"
    try:
        entries = list(descriptor_dir.iterdir())
    except OSError as exc:
        raise MigrationAuthorizationError("cannot inspect authorized updater descriptors") from exc
    for entry in entries:
        try:
            observed = entry.stat()
        except OSError:
            continue
        if (observed.st_dev, observed.st_ino) == (lock.st_dev, lock.st_ino):
            return
    fail("authorized updater does not hold the fixed operation lock")


def _validate_live_issuer(authorization: dict[str, Any]) -> None:
    pid = _integer(authorization.get("issuerPid"), "issuer PID", minimum=2)
    if pid == os.getpid():
        fail("migration helper cannot authorize itself")
    expected_start = _string(
        authorization.get("issuerProcStartTime"), "issuer process start time"
    )
    if not expected_start.isdigit() or int(expected_start) < 1:
        fail("issuer process start time is malformed")
    first_start = _read_proc_start_time(pid)
    process_dir = PROC_ROOT / str(pid)
    try:
        status = (process_dir / "status").read_text(encoding="ascii")
        cmdline = (process_dir / "cmdline").read_bytes().split(b"\0")
        executable = Path(os.readlink(process_dir / "exe")).resolve(strict=True)
        os.kill(pid, 0)
    except (OSError, UnicodeDecodeError) as exc:
        raise MigrationAuthorizationError("authorized updater process is not alive") from exc
    uid_lines = [line for line in status.splitlines() if line.startswith("Uid:")]
    if len(uid_lines) != 1 or uid_lines[0].split()[1:] != ["0", "0", "0", "0"]:
        fail("authorized updater process is not fully root-owned")
    if not PYTHON_EXE_RE.fullmatch(str(executable)):
        fail("authorized updater interpreter is outside the fixed system Python path")
    argv = [part.decode("utf-8", errors="strict") for part in cmdline if part]
    if len(argv) < 4 or argv[1:4] != ["-I", str(UPDATER_SCRIPT), "activate"]:
        fail("authorized updater command line is not the fixed activation entrypoint")
    _require_root_file(UPDATER_SCRIPT, mode=0o644, maximum_bytes=2 * 1024 * 1024)
    _issuer_holds_operation_lock(pid)
    second_start = _read_proc_start_time(pid)
    if first_start != expected_start or second_start != expected_start:
        fail("authorized updater PID was reused or changed after authorization")


def _load_release_guard() -> Any:
    raw = _read_stable_bytes(
        STABLE_RELEASE_GUARD,
        mode=0o644,
        maximum_bytes=2 * 1024 * 1024,
    )
    if _sha256_bytes(raw) != RELEASE_GUARD_SHA256:
        fail("stable release guard differs from the reviewed digest")
    try:
        code = compile(
            raw,
            str(STABLE_RELEASE_GUARD),
            "exec",
            dont_inherit=True,
        )
    except (SyntaxError, ValueError) as exc:
        raise MigrationAuthorizationError(
            "verified stable release guard could not be compiled"
        ) from exc
    module = types.ModuleType("uten_imp_migration_release_guard")
    module.__file__ = str(STABLE_RELEASE_GUARD)
    module.__package__ = ""
    module.__cached__ = None
    module.__spec__ = None
    exec(code, module.__dict__, module.__dict__)
    return module


def _current_release() -> Path:
    _require_root_directory(RELEASE_BASE)
    releases = RELEASES_DIR.resolve(strict=True)
    _require_root_directory(releases)
    try:
        link = CURRENT_LINK.lstat()
    except FileNotFoundError as exc:
        raise MigrationAuthorizationError("current release link is missing") from exc
    if not stat.S_ISLNK(link.st_mode) or link.st_uid != 0 or link.st_gid != 0:
        fail("current release is not a root-owned symbolic link")
    try:
        target = CURRENT_LINK.resolve(strict=True)
        target.relative_to(releases)
    except (OSError, ValueError) as exc:
        raise MigrationAuthorizationError("current release escaped the fixed release directory") from exc
    if target.parent != releases or not VERSION_RE.fullmatch(target.name):
        fail("current release target is not one canonical direct child")
    _require_root_directory(target)
    return target


def _verify_release_permissions(root: Path) -> None:
    for path in (root, *root.rglob("*")):
        details = path.lstat()
        if path.is_symlink() or not (
            stat.S_ISDIR(details.st_mode) or stat.S_ISREG(details.st_mode)
        ):
            fail(f"installed release contains an unsafe path: {path}")
        if details.st_uid != 0 or details.st_gid != 0 or details.st_mode & 0o022:
            fail(f"installed release permissions are unsafe: {path}")
        if stat.S_ISREG(details.st_mode) and details.st_nlink != 1:
            fail(f"installed release file has multiple hard links: {path}")


def _verified_current_release(guard: Any) -> tuple[Path, dict[str, Any], str]:
    target = _current_release()
    evidence = target / ".release"
    _require_root_directory(evidence, mode=0o755)
    manifest_path = evidence / "manifest.json"
    signature_path = evidence / "manifest.sig"
    manifest_raw = _read_stable_bytes(
        manifest_path, mode=0o644, maximum_bytes=MAX_JSON_BYTES
    )
    _require_root_file(signature_path, mode=0o644, maximum_bytes=64 * 1024)
    _require_root_file(STABLE_ALLOWED_SIGNERS, mode=0o640, maximum_bytes=64 * 1024)
    manifest = guard.load_json(manifest_path, MAX_JSON_BYTES)
    key_id = guard.require_string(
        manifest.get("signingKeyId"), "manifest signingKeyId", guard.KEY_ID_RE
    )
    guard.verify_ssh_signature(
        manifest_path,
        signature_path,
        STABLE_ALLOWED_SIGNERS,
        expected_key_id=key_id,
    )
    info = guard.validate_manifest(manifest, expected_version=target.name)
    guard.verify_payload(target, info)
    _verify_release_permissions(target)
    return target, info, _sha256_bytes(manifest_raw)


def _validate_marker(authorization: dict[str, Any]) -> None:
    if _lexists(ACTIVATION_FAILURE_MARKER):
        _require_root_file(ACTIVATION_FAILURE_MARKER, mode=0o600)
        fail("persistent activation failure gate is present")
    if authorization.get("markerPath") != str(ACTIVATION_IN_PROGRESS_MARKER):
        fail("migration authorization references another transaction marker")
    marker_raw = _read_stable_bytes(
        ACTIVATION_IN_PROGRESS_MARKER, mode=0o600, maximum_bytes=MAX_JSON_BYTES
    )
    if authorization.get("markerSha256") != _sha256_bytes(marker_raw):
        fail("activation marker changed after migration authorization")
    marker = _strict_json(marker_raw, "activation-in-progress marker")
    _exact_keys(
        marker,
        {
            "commitSha",
            "originalBootEnablement",
            "previousVersion",
            "releaseSequence",
            "schemaVersion",
            "startedAtUtc",
            "version",
        },
        "activation-in-progress marker",
    )
    if marker.get("schemaVersion") != 1 or isinstance(marker.get("schemaVersion"), bool):
        fail("activation-in-progress marker schema is unsupported")
    for key in ("commitSha", "releaseSequence", "version"):
        if marker.get(key) != authorization.get(key):
            fail("activation marker differs from the migration authorization")


def _validate_authorization(authorization: dict[str, Any]) -> None:
    _exact_keys(
        authorization,
        {
            "bootId",
            "commitSha",
            "expiresAtBoottimeNs",
            "expiresAtUnix",
            "flywayHeadVersion",
            "flywayMigrationSetSha256",
            "issuedAtUnix",
            "issuedAtBoottimeNs",
            "issuedAtUtc",
            "issuerPid",
            "issuerProcStartTime",
            "manifestSha256",
            "markerPath",
            "markerSha256",
            "nonce",
            "releaseSequence",
            "schemaVersion",
            "targetPath",
            "transactionEvidencePath",
            "version",
        },
        "migration authorization",
    )
    if authorization.get("schemaVersion") != 1 or isinstance(
        authorization.get("schemaVersion"), bool
    ):
        fail("migration authorization schema is unsupported")
    _string(authorization.get("nonce"), "migration authorization nonce", NONCE_RE)
    if authorization.get("bootId") != _boot_id():
        fail("migration authorization belongs to another boot")
    _validate_freshness(authorization)
    _string(authorization.get("commitSha"), "release commit", COMMIT_RE)
    _string(authorization.get("manifestSha256"), "manifest digest", SHA256_RE)
    _string(authorization.get("markerSha256"), "activation marker digest", SHA256_RE)
    _string(
        authorization.get("flywayMigrationSetSha256"),
        "Flyway migration-set digest",
        SHA256_RE,
    )
    version = _string(authorization.get("version"), "release version", VERSION_RE)
    if authorization.get("targetPath") != str(RELEASES_DIR / version):
        fail("migration authorization target path is not canonical")
    expected_transaction = MIGRATION_EVIDENCE_DIR / (
        f"activation-{authorization['markerSha256']}-{authorization['nonce']}"
    )
    if (
        not EVIDENCE_TRANSACTION_RE.fullmatch(expected_transaction.name)
        or authorization.get("transactionEvidencePath") != str(expected_transaction)
    ):
        fail("migration authorization transaction evidence path is not canonical")
    head = _string(authorization.get("flywayHeadVersion"), "Flyway head")
    if not head.isdigit() or int(head) < 1:
        fail("Flyway head is malformed")
    _integer(authorization.get("releaseSequence"), "release sequence", minimum=1)

    # Consume first, then check every mutable fact. Any validation failure leaves
    # only the non-replayable archived evidence behind.
    _validate_marker(authorization)
    guard = _load_release_guard()
    target, manifest, manifest_sha = _verified_current_release(guard)
    expected = {
        "commitSha": manifest["commitSha"],
        "flywayHeadVersion": manifest["flywayHeadVersion"],
        "flywayMigrationSetSha256": manifest["flywayMigrationSetSha256"],
        "manifestSha256": manifest_sha,
        "releaseSequence": manifest["releaseSequence"],
        "targetPath": str(target),
        "version": manifest["version"],
    }
    if any(authorization.get(key) != value for key, value in expected.items()):
        fail("migration authorization differs from the signed current release")
    _validate_live_issuer(authorization)
    _validate_marker(authorization)
    if _current_release() != target:
        fail("signed current release changed during migration authorization")
    _validate_freshness(authorization)


def _validate_transaction_evidence(
    authorization: dict[str, Any], authorization_raw: bytes
) -> None:
    _require_root_directory(MIGRATION_EVIDENCE_DIR, mode=0o700)
    transaction = Path(
        _string(
            authorization.get("transactionEvidencePath"),
            "migration transaction evidence path",
        )
    )
    if transaction.parent != MIGRATION_EVIDENCE_DIR or not EVIDENCE_TRANSACTION_RE.fullmatch(
        transaction.name
    ):
        fail("migration transaction evidence escaped the fixed directory")
    _require_root_directory(transaction, mode=0o700)
    issued = transaction / "authorization.issued.json"
    issued_raw = _read_stable_bytes(
        issued, mode=0o600, maximum_bytes=MAX_JSON_BYTES
    )
    if issued_raw != authorization_raw:
        fail("persistent migration authorization differs from the consumed bytes")


def _consume_authorization() -> tuple[dict[str, Any], Path, bytes, bool]:
    _require_root_directory(AUTHORIZATION_DIR, mode=0o700)
    raw = _read_stable_bytes(
        AUTHORIZATION, mode=0o600, maximum_bytes=MAX_JSON_BYTES
    )
    authorization = _strict_json(raw, "migration authorization pending consumption")
    digest = _sha256_bytes(raw)
    candidate_nonce = authorization.get("nonce")
    nonce = candidate_nonce if isinstance(candidate_nonce, str) and NONCE_RE.fullmatch(
        candidate_nonce
    ) else digest[:32]
    archive = AUTHORIZATION_DIR / (
        f"migration-authorization.consumed-{nonce}-{digest}.json"
    )
    if _lexists(archive):
        existing = _read_stable_bytes(
            archive, mode=0o600, maximum_bytes=MAX_JSON_BYTES
        )
        if existing != raw:
            fail("deterministic migration authorization archive digest collision")
        AUTHORIZATION.unlink()
        _fsync_directory(AUTHORIZATION_DIR)
        return authorization, archive, raw, True
    os.rename(AUTHORIZATION, archive)
    _fsync_directory(AUTHORIZATION_DIR)
    if _read_stable_bytes(archive, mode=0o600, maximum_bytes=MAX_JSON_BYTES) != raw:
        fail("consumed migration authorization archive bytes changed")
    return authorization, archive, raw, False


def consume() -> str:
    if os.geteuid() != 0:
        fail("migration authorization must be consumed as root")
    authorization, _archive, raw, replayed = _consume_authorization()
    if replayed:
        fail("migration authorization replay was atomically rejected")
    _validate_authorization(authorization)
    _validate_transaction_evidence(authorization, raw)
    _validate_freshness(authorization)
    return _string(authorization.get("nonce"), "migration authorization nonce", NONCE_RE)


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    try:
        if arguments != ["consume"]:
            fail("the only supported operation is: consume")
        nonce = consume()
    except Exception as exc:
        print(f"ERP_MIGRATION_AUTHORIZATION_NO_GO: {exc}", file=sys.stderr)
        return 1
    print(f"ERP_MIGRATION_AUTHORIZATION_OK nonce={nonce}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
