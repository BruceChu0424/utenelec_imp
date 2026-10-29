"""Bounded, paired client catalog backup and isolated restore (stdlib only).

The live Java catalog uses FileChannel.lock(): Linux POSIX record locks, not
flock. Readers hold a shared lock on the same .catalog.lock through the copy.
Only committed release.json/package.bin pairs are portable; upload work is not.
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import stat
import tempfile
import threading
import time

FORMAT = "uten-client-release-state-v1"
MANIFEST = "client-release-state-manifest.json"
MAX_RELEASES = 2000
MAX_PACKAGE_BYTES = 512 * 1024**2
MAX_METADATA_BYTES = 65536
MAX_MANIFEST_BYTES = 4 * 1024**2
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
HEX = re.compile(r"[0-9a-f]{64}\Z")
TEMPORARY = re.compile(r"\.(?:upload|metadata)-[0-9a-f-]{36}\.tmp\Z")
_helpers = None
_registry = threading.Lock()
_locks: dict[Path, threading.Lock] = {}
_TARGET_ARCHITECTURES = {
    "windows": {"x86", "x64", "arm64"},
    "android": {"arm64", "armeabi-v7a", "x64", "universal"},
    "ios": {"arm64", "universal"},
    "macos": {"arm64", "x64", "universal"},
    "linux": {"arm64", "x64", "universal"},
}
_WINDOWS_INSTALLER_MODES = {"windows_bundle", "windows_setup", "windows_wpf_setup"}
_WINDOWS_MODES = _WINDOWS_INSTALLER_MODES | {"windows_archive", "windows_wpf_archive"}
_WPF_MODES = {"windows_wpf_setup", "windows_wpf_archive"}


def _validate_runtime_contract(release: dict) -> tuple[str, str]:
    """Validate a release partition without normalizing or rewriting its receipt.

    Legacy missing/null runtimeFamily means flutter only. A backup/restore keeps
    the original release.json bytes, including absent/null discriminators.
    """
    family = release.get("runtimeFamily")
    if family is None:
        family = "flutter"
    if not isinstance(family, str) or family not in {"flutter", "wpf_legacy"}:
        raise ValueError("Invalid client runtime family")
    platform, architecture, mode = (release.get(field) for field in ("platform", "architecture", "installMode"))
    if (not isinstance(platform, str) or platform not in _TARGET_ARCHITECTURES
            or not isinstance(architecture, str) or architecture not in _TARGET_ARCHITECTURES[platform]):
        raise ValueError("Invalid client runtime platform/architecture")
    if not isinstance(mode, str) or mode not in _WINDOWS_MODES | {"store", "android_package"}:
        raise ValueError("Invalid client runtime install mode")
    kind = release.get("packageKind")
    if kind is None:
        kind = "update"  # Legacy receipts predate the discriminator.
    if (not isinstance(kind, str) or kind not in {"update", "installer"}
            or (kind == "installer") != (mode in _WINDOWS_INSTALLER_MODES)
            or mode in _WINDOWS_MODES and platform != "windows"
            or mode == "android_package" and platform != "android"):
        raise ValueError("Invalid client package kind/install mode")
    if family == "wpf_legacy":
        if platform != "windows" or architecture not in {"x86", "x64"} or mode not in _WPF_MODES:
            raise ValueError("Invalid WPF runtime family/target/install mode")
    elif mode in _WPF_MODES:
        raise ValueError("Flutter runtime cannot contain a WPF install mode")
    if mode in {"windows_setup", "windows_wpf_setup"}:
        filename = release.get("fileName")
        if (not isinstance(filename, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._ -]{0,180}", filename)
                or not filename.lower().endswith(".exe")):
            raise ValueError("Windows setup requires an executable filename")
    return family, kind


def helpers():
    global _helpers
    if _helpers is None:
        path = Path(__file__).resolve().with_name("market_state_backup.py")
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or path.is_symlink() or info.st_size > 256 * 1024
                or os.name == "posix" and str(path).startswith("/usr/local/")
                and (info.st_uid != 0 or info.st_mode & 0o022)):
            raise ValueError("Client backup filesystem helper is missing or unsafe")
        spec = importlib.util.spec_from_file_location("uten_client_backup_filesystem", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _helpers = module
    return _helpers


@contextmanager
def catalog_lock(root: Path, *, timeout=120, copy_budget=None):
    """Shared POSIX range [0, EOF), compatible with the Java writer barrier."""
    import fcntl
    h = helpers()
    root = h._real_directory(root)
    with _registry:
        thread_lock = _locks.setdefault(root, threading.Lock())
    if not thread_lock.acquire(timeout=timeout):
        raise BlockingIOError("Client catalog is busy")
    fd, locked = None, False
    try:
        # Do not create a lock through the backup unit's read-only source view.
        # An existing catalog without its writer barrier needs repair/retry.
        path = root / ".catalog.lock"
        before = path.lstat()
        if not h._private(before) or not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError("Unsafe client catalog barrier")
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        info = os.fstat(fd)
        if not os.path.samestat(before, info):
            raise ValueError("Client catalog barrier changed")
        deadline = time.monotonic() + timeout
        while True:
            h._tick(copy_budget)
            try:
                fcntl.lockf(fd, fcntl.LOCK_SH | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
                locked = True
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise BlockingIOError("Client catalog is busy") from None
                time.sleep(.05)
        yield
    finally:
        if fd is not None:
            try:
                if locked:
                    fcntl.lockf(fd, fcntl.LOCK_UN, 0, 0, os.SEEK_SET)
            finally:
                os.close(fd)
        thread_lock.release()


def _entries(root: Path, limit: int):
    result = []
    for path in root.iterdir():
        if len(result) >= limit:
            raise ValueError("Client catalog exceeds its traversal budget")
        result.append(path)
    return sorted(result)


def _catalog_inventory(root: Path, *, source: bool, copy_budget=None) -> list[str]:
    h = helpers()
    names = []
    for folder in _entries(root, MAX_RELEASES + 2):
        h._tick(copy_budget)
        if folder.name == (".catalog.lock" if source else MANIFEST):
            continue
        if not UUID.fullmatch(folder.name):
            raise ValueError("Unexpected client catalog entry")
        h._real_directory(folder)
        files = _entries(folder, 100)
        stable = set()
        for path in files:
            if source and TEMPORARY.fullmatch(path.name):
                continue
            if path.name not in {"release.json", "package.bin"}:
                raise ValueError("Unexpected client release file")
            info = path.lstat()
            if not h._private(info) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise ValueError("Client release links and special files are forbidden")
            stable.add(path.name)
        if "release.json" not in stable:
            if stable or not source:
                raise ValueError("Client package has no bound metadata")
            continue
        relative = folder.name + "/release.json"
        release = h._json(root, relative, MAX_METADATA_BYTES)
        if (not isinstance(release, dict) or release.get("id") != folder.name
                or not isinstance(release.get("state"), str)
                or release.get("state") not in {"DRAFT", "PUBLISHED", "WITHDRAWN"}
                or type(release.get("sizeBytes")) is not int):
            raise ValueError("Invalid client release metadata identity/state")
        _validate_runtime_contract(release)
        size, digest = release["sizeBytes"], release.get("sha256")
        mode, state = release["installMode"], release["state"]
        names.append(relative)
        if mode == "store":
            if digest is not None or size != 0 or "package.bin" in stable:
                raise ValueError("Store release must not contain a package")
            continue
        if digest is None:
            if size != 0 or state == "PUBLISHED":
                raise ValueError("Published client release has no committed package")
            # A failed upload/cutover may leave an uncommitted binary; metadata
            # still says retry. Do not promote it to a restored, uploaded pair.
            if not source and "package.bin" in stable:
                raise ValueError("Unbound client package in backup")
            continue
        if (not isinstance(digest, str) or not HEX.fullmatch(digest)
                or release.get("expectedSha256") != digest or not 1 <= size <= MAX_PACKAGE_BYTES
                or "package.bin" not in stable):
            raise ValueError("Committed client release package is missing or invalid")
        binary = folder.name + "/package.bin"
        actual_size, actual_digest = h._digest(root, binary, limit=MAX_PACKAGE_BYTES)
        h._tick(copy_budget)
        if actual_size != size or actual_digest != digest:
            raise ValueError("Client release package integrity failed")
        names.append(binary)
    return sorted(names)


def verify_client_releases(directory: Path, *, copy_budget=None) -> dict:
    h = helpers()
    directory = h._real_directory(directory)
    raw = h._json_bytes(directory, MANIFEST, MAX_MANIFEST_BYTES)
    manifest = h._decode(raw)
    if (not isinstance(manifest, dict)
            or set(manifest) != {"format", "capturedAt", "releases", "files", "bytes", "records"}
            or manifest["format"] != FORMAT or type(manifest["releases"]) is not int
            or not 0 <= manifest["releases"] <= MAX_RELEASES
            or type(manifest["files"]) is not int or type(manifest["bytes"]) is not int
            or not isinstance(manifest["records"], list) or len(manifest["records"]) != manifest["files"]
            or not 0 <= manifest["files"] <= 2 * MAX_RELEASES
            or not 0 <= manifest["bytes"] <= MAX_RELEASES * (MAX_PACKAGE_BYTES + MAX_METADATA_BYTES)):
        raise ValueError("Invalid client release backup manifest")
    captured = manifest["capturedAt"]
    if not isinstance(captured, str) or not captured.endswith("Z"):
        raise ValueError("Invalid client release capture timestamp")
    datetime.fromisoformat(captured.replace("Z", "+00:00"))
    expected, total = set(), 0
    for record in manifest["records"]:
        h._tick(copy_budget)
        if (not isinstance(record, dict) or set(record) != {"path", "size", "sha256"}
                or type(record["size"]) is not int or record["size"] < 0
                or not isinstance(record["sha256"], str) or not HEX.fullmatch(record["sha256"])):
            raise ValueError("Invalid client release file record")
        name = record["path"]
        parts = name.split("/") if isinstance(name, str) else []
        if (len(parts) != 2 or not UUID.fullmatch(parts[0])
                or parts[1] not in {"release.json", "package.bin"} or name in expected):
            raise ValueError("Invalid or duplicate client release file path")
        expected.add(name)
        limit = MAX_METADATA_BYTES if name.endswith("/release.json") else MAX_PACKAGE_BYTES
        size, digest = h._digest(directory, name, limit=limit)
        if size != record["size"] or digest != record["sha256"]:
            raise ValueError("Client release backup file integrity failed")
        total += size
    names = set(_catalog_inventory(directory, source=False, copy_budget=copy_budget))
    if (names != expected or total != manifest["bytes"]
            or sum(name.endswith("/release.json") for name in names) != manifest["releases"]):
        raise ValueError("Client release backup inventory is incomplete")
    if h._digest(directory, MANIFEST, limit=MAX_MANIFEST_BYTES)[1] != hashlib.sha256(raw).hexdigest():
        raise ValueError("Client release manifest changed during verification")
    return {"format": FORMAT, "releases": manifest["releases"], "files": len(names),
            "bytes": total, "manifestSha256": hashlib.sha256(raw).hexdigest()}


def export_client_releases(source: Path, destination: Path, *, copy_budget=None) -> dict:
    h = helpers()
    source = h._real_directory(source)
    destination, parent, previous = h._destination(destination)
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("Client release export and live catalog must not overlap")
    stage = Path(tempfile.mkdtemp(prefix=".market-state-", dir=parent))
    try:
        with catalog_lock(source, copy_budget=copy_budget):
            names = _catalog_inventory(source, source=True, copy_budget=copy_budget)
            records = [h._copy(source, name, stage, copy_budget=copy_budget) for name in names]
            manifest = {"format": FORMAT, "capturedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                        "releases": sum(name.endswith("/release.json") for name in names),
                        "files": len(records), "bytes": sum(row["size"] for row in records), "records": records}
            h._write_json(stage / MANIFEST, manifest)
        summary = verify_client_releases(stage, copy_budget=copy_budget)
        h._publish(stage, destination, previous)
        return summary
    finally:
        h._discard(stage, parent)


def restore_client_releases(directory: Path, target: Path) -> dict:
    h = helpers()
    directory = h._real_directory(directory)
    summary = verify_client_releases(directory)
    target, parent, previous = h._destination(target)
    if directory == target or directory in target.parents or target in directory.parents:
        raise ValueError("Client release restore and backup must not overlap")
    manifest = h._json(directory, MANIFEST, MAX_MANIFEST_BYTES)
    stage = Path(tempfile.mkdtemp(prefix=".market-state-", dir=parent))
    try:
        for row in manifest["records"]:
            if h._copy(directory, row["path"], stage) != row:
                raise ValueError("Client release backup changed during restore")
        if h._digest(directory, MANIFEST, limit=MAX_MANIFEST_BYTES)[1] != summary["manifestSha256"]:
            raise ValueError("Client release manifest changed during restore")
        _catalog_inventory(stage, source=False)
        with (stage / ".catalog.lock").open("xb") as barrier:
            barrier.flush(); os.fsync(barrier.fileno())
        owner = previous or parent.stat()
        if os.name == "posix":
            for folder, directories, filenames in os.walk(stage):
                for name in [*directories, *filenames]:
                    path = Path(folder) / name
                    os.chown(path, owner.st_uid, owner.st_gid)
                    path.chmod(0o700 if path.is_dir() else 0o600)
        # Prepare ownership before publication. A nonempty target is never replaced.
        if os.name == "posix":
            os.chown(stage, owner.st_uid, owner.st_gid)
        h._publish(stage, target, previous)
        return summary
    finally:
        h._discard(stage, parent)
