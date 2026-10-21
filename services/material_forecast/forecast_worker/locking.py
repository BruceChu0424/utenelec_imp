"""Crash-released first-byte locks, interoperable with Java FileChannel locks."""

from contextlib import contextmanager
import os
from pathlib import Path
import stat
import threading
import time

_roots: dict[Path, threading.RLock] = {}
_registry_lock = threading.Lock()


@contextmanager
def os_file_lock(path: Path, timeout: float = 0):
    if path.is_symlink():
        raise ValueError("lock links are forbidden")
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    locked = False
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("lock must be a private regular file")
        if info.st_size == 0:
            os.write(descriptor, b"0")
        deadline = time.monotonic() + timeout
        while True:
            try:
                os.lseek(descriptor, 0, os.SEEK_SET)
                if os.name == "nt":
                    import msvcrt
                    msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB, 1, 0, os.SEEK_SET)
                locked = True
                break
            except OSError as exc:
                if time.monotonic() >= deadline:
                    raise BlockingIOError("collector or state writer is busy") from exc
                time.sleep(.05)
        yield
    finally:
        if locked:
            os.lseek(descriptor, 0, os.SEEK_SET)
            if os.name == "nt":
                msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)
            else:
                fcntl.lockf(descriptor, fcntl.LOCK_UN, 1, 0, os.SEEK_SET)
        os.close(descriptor)


def register_write_barrier(root: Path) -> None:
    with _registry_lock:
        _roots.setdefault(root.resolve(), threading.RLock())


@contextmanager
def write_barrier(path: Path):
    parent = path.parent.resolve()
    with _registry_lock:
        matches = [root for root in _roots if root == parent or root in parent.parents]
        root = max(matches, key=lambda item: len(item.parts)) if matches else None
        thread_lock = _roots.get(root)
    if root is None:
        yield
        return
    with thread_lock:
        with os_file_lock(root / ".market-write.lock", timeout=120):
            yield
