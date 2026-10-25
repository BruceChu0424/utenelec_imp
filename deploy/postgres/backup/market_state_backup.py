"""Stable, bounded market-state export/verification/restore; Python stdlib only.

The worker cooperates through .market-write.lock, byte range [0,1). Executable
environments and live leases are never portable data. A paired backup must bind
the returned manifestSha256 to its own independently trusted set manifest.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tempfile
import threading
import time

FORMAT = "uten-market-state-v1"
MANIFEST = "market-state-manifest.json"
MAX_BYTES = 8 * 1024**3
MAX_FILES = 200_000
MAX_MANIFEST_BYTES = 128 * 1024**2
MAX_JSON_BYTES = 64 * 1024**2
CHUNK = 1024 * 1024
_registry_guard = threading.Lock()
_locks: dict[Path, threading.RLock] = {}
_held = threading.local()
_HEX = re.compile(r"[0-9a-f]{64}\Z")
_SERIES = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
_EXCLUDED_DIRS = {"venv", ".venv", "runtime", "runtimes", ".runtime", "runtime-cache",
                  "wheelhouse", "__pycache__", "scripts", "bin"}


def _tick(callback, size=0):
    if callback is not None:
        callback(size)


def _private(info):
    return not (getattr(info, "st_file_attributes", 0) & 0x400) and not stat.S_ISLNK(info.st_mode)


def _absolute(path: Path) -> Path:
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("An absolute, non-traversing market path is required")
    return Path(os.path.abspath(path))


def _real_directory(path: Path) -> Path:
    path = _absolute(path)
    for part in reversed((path, *path.parents)):
        info = part.lstat()
        if not stat.S_ISDIR(info.st_mode) or not _private(info):
            raise ValueError("Market directory links are forbidden")
    if os.path.normcase(str(path.resolve(strict=True))) != os.path.normcase(str(path)):
        raise ValueError("Market directory alias is forbidden")
    return path


def _relative(value: str) -> Path:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 4096:
        raise ValueError("Invalid market-state relative path")
    parts = value.split("/")
    for part in parts:
        if (not part or part in {".", ".."} or "\\" in part or ":" in part
                or part.endswith((".", " ")) or len(part.encode("utf-8")) > 255
                or any(ord(c) < 32 or ord(c) == 127 for c in part)
                or re.fullmatch(r"(?i)(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?", part)):
            raise ValueError("Unsafe portable market-state path")
    if PurePosixPath(value).is_absolute():
        raise ValueError("Absolute market-state entry")
    return Path(*parts)


def _excluded(relative: Path) -> bool:
    parts = [part.casefold() for part in relative.parts]
    if any(part in _EXCLUDED_DIRS or part.startswith((".venv-", "venv-")) for part in parts[:-1]):
        return True
    name = parts[-1]
    return name.endswith((".lock", ".tmp", ".pid", ".pyc", ".pyo", ".exe", ".dll", ".pyd", ".so", ".whl"))


def _inventory(root: Path, *, source: bool):
    pending = [root]
    visited = 0
    while pending:
        folder = pending.pop()
        _real_directory(folder)
        with os.scandir(folder) as listing:
            entries = []
            for entry in listing:
                visited += 1
                if visited > MAX_FILES * 2 + 100:
                    raise ValueError("Market directory exceeds its traversal budget")
                entries.append(entry)
            entries.sort(key=lambda entry: entry.name)
        for entry in entries:
            path = Path(entry.path)
            relative = path.relative_to(root)
            if source and (entry.name.casefold() in _EXCLUDED_DIRS
                           or entry.name.casefold().startswith((".venv-", "venv-"))):
                continue
            # Live health is an independently replaced, volatile run receipt,
            # not recoverable market state. Skip it and transient temp files
            # before lstat: either can disappear after the directory listing.
            # Keep _excluded unchanged so signed historical v1 inventories
            # containing health still verify and restore with their old digest.
            if source and (_excluded(relative) or relative.as_posix().casefold() == "auto-feed-health.json"):
                continue
            # Windows DirEntry.stat may cache zero st_ino/st_nlink; lstat gives
            # the real identity required to reject hard links and reparse points.
            info = path.lstat()
            if not _private(info):
                raise ValueError("Market-state links are forbidden")
            if stat.S_ISDIR(info.st_mode):
                pending.append(path)
            elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                name = relative.as_posix()
                _relative(name)
                if name == MANIFEST:
                    if source:
                        raise ValueError("A live state directory cannot contain an export manifest")
                    continue
                yield name, info
            else:
                raise ValueError("Market state contains a non-private regular file")


@contextmanager
def _open(root: Path, relative: Path):
    current = root
    for part in relative.parts[:-1]:
        current = _real_directory(current / part)
    path = current / relative.name
    before = path.lstat()
    if not _private(before) or not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ValueError("Unsafe market-state file")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        after = os.fstat(stream.fileno())
        if not os.path.samestat(before, after) or after.st_nlink != 1:
            raise ValueError("Market-state file identity changed")
        yield stream, after


@contextmanager
def market_state_lock(source: Path, *, timeout=120, copy_budget=None, shared=False):
    """Cooperating writer/backup barrier; a process crash releases the OS lock."""
    source = _real_directory(source)
    with _registry_guard:
        thread_lock = _locks.setdefault(source, threading.RLock())
    if not thread_lock.acquire(timeout=timeout):
        raise BlockingIOError("Market state is busy")
    depths = getattr(_held, "depths", None)
    if depths is None:
        depths = _held.depths = {}
    fd = None
    locked = False
    nested = source in depths
    try:
        if nested:
            if depths[source] and not shared:
                raise BlockingIOError("Cannot upgrade a nested market snapshot lock")
            yield
            return
        lock = source / ".market-write.lock"
        if lock.exists() and not _private(lock.lstat()):
            raise ValueError("Market barrier links are forbidden")
        flags = os.O_RDWR | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            fd = os.open(lock, flags | os.O_CREAT | os.O_EXCL, 0o600)
            created = True
        except FileExistsError:
            fd = os.open(lock, (os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                         if shared and os.name == "posix" else flags)
            created = False
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not _private(info):
            raise ValueError("Market barrier must be a private regular file")
        if created and os.name == "posix":
            owner = source.stat()
            if (info.st_uid, info.st_gid) != (owner.st_uid, owner.st_gid):
                os.fchown(fd, owner.st_uid, owner.st_gid)
        if info.st_size == 0 and (created or not shared or os.name == "nt"):
            os.write(fd, b"0")
        deadline = time.monotonic() + timeout
        while True:
            _tick(copy_budget)
            try:
                os.lseek(fd, 0, os.SEEK_SET)
                if os.name == "nt":
                    import msvcrt
                    msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.lockf(fd, (fcntl.LOCK_SH if shared else fcntl.LOCK_EX)
                                | fcntl.LOCK_NB, 1, 0, os.SEEK_SET)
                locked = True
                break
            except OSError as error:
                if time.monotonic() >= deadline:
                    raise BlockingIOError("Market state is busy") from error
                time.sleep(.05)
        depths[source] = shared
        yield
    finally:
        if not nested:
            depths.pop(source, None)
        if fd is not None:
            try:
                if locked:
                    os.lseek(fd, 0, os.SEEK_SET)
                    if os.name == "nt":
                        msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
                    else:
                        fcntl.lockf(fd, fcntl.LOCK_UN, 1, 0, os.SEEK_SET)
            finally:
                os.close(fd)
        thread_lock.release()


def _unique_pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("Duplicate market-state JSON key")
        value[key] = item
    return value


def _json_bytes(root: Path, name: str, limit=MAX_JSON_BYTES):
    with _open(root, _relative(name)) as (stream, info):
        if info.st_size > limit:
            raise ValueError("Market-state JSON exceeds the safety limit")
        raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise ValueError("Market-state JSON exceeds the safety limit")
    return raw


def _decode(raw):
    return json.loads(raw, object_pairs_hook=_unique_pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Invalid JSON number")))


def _json(root: Path, name: str, limit=MAX_JSON_BYTES):
    return _decode(_json_bytes(root, name, limit))


def _digest(root: Path, name: str, *, limit=MAX_BYTES):
    digest, size = hashlib.sha256(), 0
    with _open(root, _relative(name)) as (stream, info):
        while chunk := stream.read(CHUNK):
            if size + len(chunk) > limit:
                raise ValueError("Market file exceeds the integrity budget")
            digest.update(chunk)
            size += len(chunk)
        if size != info.st_size:
            raise ValueError("Market-state file size changed")
    return size, digest.hexdigest()


def _references(root: Path, names: set[str]):
    """Reject dangling known cache pointers, rather than blessing a broken cache."""
    for name in sorted(names):
        if name.startswith(".auto-feed/daily/") and name.endswith(".json"):
            pointer = _json(root, name)
            if not isinstance(pointer, dict):
                raise ValueError("Invalid market source pointer")
            day, digest = pointer.get("date"), pointer.get("sha256")
            if not isinstance(day, str) or Path(name).name != day + ".json" or not isinstance(digest, str) or not _HEX.fullmatch(digest):
                raise ValueError("Invalid market source pointer")
            expected = f".auto-feed/raw/{day}/{digest}.json"
            _relative(expected)
            if expected not in names:
                raise ValueError("Market source pointer references a missing revision")
        if name.startswith(".auto-feed/raw/") and name.endswith(".json"):
            revision = _json(root, name)
            digest = Path(name).stem
            if not isinstance(revision, dict) or not _HEX.fullmatch(digest) or revision.get("sha256") != digest or not isinstance(revision.get("payload"), dict):
                raise ValueError("Invalid immutable market source revision")
            canonical = json.dumps(revision["payload"], ensure_ascii=False, sort_keys=True,
                                   separators=(",", ":"), allow_nan=False).encode("utf-8")
            if hashlib.sha256(canonical).hexdigest() != digest:
                raise ValueError("Immutable market source revision digest mismatch")
        if name == ".auto-feed/state.json":
            state = _json(root, name)
            if not isinstance(state, dict):
                raise ValueError("Invalid market model pointer state")
            models = state.get("models", {})
            if not isinstance(models, dict):
                raise ValueError("Invalid market model pointer state")
            for series in models:
                if not isinstance(series, str) or not _SERIES.fullmatch(series) or series + ".json" not in names:
                    raise ValueError("Market model pointer references a missing snapshot")


def _destination(path: Path):
    path = _absolute(path)
    parent = _real_directory(path.parent)
    previous = None
    if path.exists() or path.is_symlink():
        _real_directory(path)
        if next(path.iterdir(), None) is not None:
            raise FileExistsError("Market destination must be new or empty")
        previous = path.stat()
    return path, parent, previous


def _discard(stage: Path, parent: Path):
    # Delete only the private staging directory allocated by this invocation.
    if stage.parent != parent or not stage.name.startswith(".market-state-"):
        raise ValueError("Refusing unsafe market staging cleanup")
    if stage.exists():
        if not _private(stage.lstat()) or stage.resolve().parent != parent:
            raise ValueError("Market staging identity changed")
        shutil.rmtree(stage)


def _publish(stage: Path, target: Path, previous):
    if previous is not None:
        if not target.exists() or not os.path.samestat(previous, target.lstat()):
            raise FileExistsError("Market destination changed during export")
        target.rmdir()  # Never removes a nonempty directory or unrelated files.
    elif target.exists() or target.is_symlink():
        raise FileExistsError("Market destination appeared during export")
    os.rename(stage, target)


def _write_json(path: Path, value):
    raw = (json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
    with path.open("xb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    if os.name == "posix":
        path.chmod(0o600)
    return raw


def _copy(source: Path, name: str, target: Path, *, copy_budget=None):
    destination = target / _relative(name)
    destination.parent.mkdir(parents=True, exist_ok=True)
    digest, size = hashlib.sha256(), 0
    with _open(source, _relative(name)) as (input_stream, info), destination.open("xb") as output:
        while chunk := input_stream.read(CHUNK):
            if size + len(chunk) > info.st_size:
                raise ValueError("Market-state source grew during copy")
            _tick(copy_budget, len(chunk))
            output.write(chunk)
            digest.update(chunk)
            size += len(chunk)
        output.flush()
        os.fsync(output.fileno())
        if size != info.st_size or not os.path.samestat(info, os.fstat(input_stream.fileno())):
            raise ValueError("Market-state source changed during copy")
    if os.name == "posix":
        destination.chmod(0o600)
    return {"path": name, "size": size, "sha256": digest.hexdigest()}


def export_market_state(source: Path, destination: Path, *, max_bytes=MAX_BYTES,
                        max_files=MAX_FILES, copy_budget=None) -> dict:
    source = _real_directory(source)
    destination, parent, previous = _destination(destination)
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("Market export and live state must not overlap")
    if type(max_bytes) is not int or type(max_files) is not int or not 0 <= max_bytes <= MAX_BYTES or not 0 <= max_files <= MAX_FILES:
        raise ValueError("Invalid market export budget")
    stage = Path(tempfile.mkdtemp(prefix=".market-state-", dir=parent))
    try:
        with market_state_lock(source, copy_budget=copy_budget, shared=True):
            inventory = sorted(_inventory(source, source=True), key=lambda row: row[0])
            if len(inventory) > max_files or sum(info.st_size for _, info in inventory) > max_bytes:
                raise ValueError("Market state exceeds the export budget")
            names = [name for name, _ in inventory]
            if len({name.casefold() for name in names}) != len(names):
                raise ValueError("Market-state paths conflict on a portable host")
            records = [_copy(source, name, stage, copy_budget=copy_budget) for name in names]
            manifest = {"format": FORMAT, "capturedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                        "files": len(records), "bytes": sum(row["size"] for row in records), "records": records}
            raw = _write_json(stage / MANIFEST, manifest)
            summary = {"format": FORMAT, "files": manifest["files"], "bytes": manifest["bytes"],
                       "manifestSha256": hashlib.sha256(raw).hexdigest()}
        # The private copy is now stable. Validate all digests and semantic
        # references without keeping the live worker behind the copy barrier.
        verify_market_state(stage)
        _publish(stage, destination, previous)
        return summary
    finally:
        _discard(stage, parent)


def verify_market_state(directory: Path) -> dict:
    directory = _real_directory(directory)
    raw = _json_bytes(directory, MANIFEST, MAX_MANIFEST_BYTES)
    manifest, initial_digest = _decode(raw), hashlib.sha256(raw).hexdigest()
    if (not isinstance(manifest, dict) or set(manifest) != {"format", "capturedAt", "files", "bytes", "records"}
            or manifest["format"] != FORMAT or type(manifest["files"]) is not int
            or type(manifest["bytes"]) is not int or not 0 <= manifest["files"] <= MAX_FILES
            or not 0 <= manifest["bytes"] <= MAX_BYTES or not isinstance(manifest["records"], list)
            or len(manifest["records"]) != manifest["files"]):
        raise ValueError("Invalid market-state manifest")
    captured = manifest["capturedAt"]
    if not isinstance(captured, str) or not captured.endswith("Z"):
        raise ValueError("Invalid market-state capture timestamp")
    datetime.fromisoformat(captured.replace("Z", "+00:00"))
    expected, total = set(), 0
    portable = set()
    for record in manifest["records"]:
        if (not isinstance(record, dict) or set(record) != {"path", "size", "sha256"}
                or type(record["size"]) is not int or record["size"] < 0
                or not isinstance(record["sha256"], str) or not _HEX.fullmatch(record["sha256"])):
            raise ValueError("Invalid market-state file record")
        name = record["path"]
        relative = _relative(name)
        if name == MANIFEST or _excluded(relative) or name in expected or name.casefold() in portable:
            raise ValueError("Duplicate or excluded market-state entry")
        expected.add(name)
        portable.add(name.casefold())
        size, digest = _digest(directory, name, limit=record["size"])
        if size != record["size"] or digest != record["sha256"]:
            raise ValueError("Market-state file integrity failed")
        total += size
    if total != manifest["bytes"] or {name for name, _ in _inventory(directory, source=False)} != expected:
        raise ValueError("Market-state inventory is incomplete")
    _references(directory, expected)
    _, digest = _digest(directory, MANIFEST, limit=MAX_MANIFEST_BYTES)
    if digest != initial_digest:
        raise ValueError("Market manifest changed during verification")
    return {"format": FORMAT, "files": len(expected), "bytes": total, "manifestSha256": digest}


def restore_market_state(directory: Path, target: Path) -> dict:
    directory = _real_directory(directory)
    summary = verify_market_state(directory)
    target, parent, previous = _destination(target)
    if directory == target or directory in target.parents or target in directory.parents:
        raise ValueError("Market restore and backup must not overlap")
    raw = _json_bytes(directory, MANIFEST, MAX_MANIFEST_BYTES)
    manifest = _decode(raw)
    if hashlib.sha256(raw).hexdigest() != summary["manifestSha256"]:
        raise ValueError("Market backup manifest changed before restore")
    stage = Path(tempfile.mkdtemp(prefix=".market-state-", dir=parent))
    health_reset = False
    try:
        for row in manifest["records"]:
            copied = _copy(directory, row["path"], stage)
            if copied != row:
                raise ValueError("Market backup changed during restore")
        if _digest(directory, MANIFEST, limit=MAX_MANIFEST_BYTES)[1] != summary["manifestSha256"]:
            raise ValueError("Market backup manifest changed during restore")
        if (stage / "auto-feed-health.json").exists():
            health = _json(stage, "auto-feed-health.json")
            if not isinstance(health, dict) or not isinstance(health.get("series", []), list):
                raise ValueError("Invalid restored market health evidence")
            evidence = stage / "restore-evidence" / "auto-feed-health.json"
            if evidence.exists():
                evidence = stage / "restore-evidence" / summary["manifestSha256"] / "auto-feed-health.json"
            evidence.parent.mkdir(parents=True, exist_ok=True)
            with _open(stage, Path("auto-feed-health.json")) as (stream, _), evidence.open("xb") as output:
                shutil.copyfileobj(stream, output, CHUNK)
                output.flush(); os.fsync(output.fileno())
            health["autoUpdateEnabled"] = False
            for field in ("runId", "configRevision", "pid", "processId"):
                health.pop(field, None)
            for row in health.get("series", []):
                if not isinstance(row, dict):
                    raise ValueError("Invalid restored market health series")
                row["status"], row["nextSyncAt"] = "IDLE", None
            (stage / "auto-feed-health.json").unlink()
            _write_json(stage / "auto-feed-health.json", health)
            health_reset = True
        # Old leases/locks are never copied. A new, unlocked barrier is needed
        # even when the restored configuration leaves the worker disabled: a
        # read-only backup mount cannot create it on the next export.
        with (stage / ".market-write.lock").open("xb") as barrier:
            barrier.write(b"0")
            barrier.flush()
            os.fsync(barrier.fileno())
        owner = previous or parent.stat()
        if os.name == "posix":
            # Keep the staging root inaccessible until every child is prepared.
            for folder, directories, filenames in os.walk(stage):
                for name in [*directories, *filenames]:
                    item = Path(folder) / name
                    os.chown(item, owner.st_uid, owner.st_gid)
                    item.chmod(0o700 if item.is_dir() else 0o600)
        owned = stage.stat()
        _publish(stage, target, previous)
        if os.name == "posix":
            try:
                os.chown(target, owner.st_uid, owner.st_gid)
            except OSError:
                # The unpublished root is still private to this invocation.
                # Never remove a replacement or anything a different owner made.
                if os.path.samestat(owned, target.lstat()) and _private(target.lstat()):
                    shutil.rmtree(target)
                    if previous is not None:
                        target.mkdir(mode=stat.S_IMODE(previous.st_mode))
                        os.chown(target, previous.st_uid, previous.st_gid)
                raise
        return {**summary, "healthReset": health_reset}
    finally:
        _discard(stage, parent)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Stable portable market-state backup")
    actions = parser.add_subparsers(dest="action", required=True)
    export = actions.add_parser("export")
    export.add_argument("source", type=Path); export.add_argument("destination", type=Path)
    verify = actions.add_parser("verify"); verify.add_argument("directory", type=Path)
    restore = actions.add_parser("restore")
    restore.add_argument("directory", type=Path); restore.add_argument("target", type=Path)
    args = parser.parse_args(argv)
    result = (export_market_state(args.source, args.destination) if args.action == "export" else
              verify_market_state(args.directory) if args.action == "verify" else
              restore_market_state(args.directory, args.target))
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
