#!/usr/bin/env python3
"""Provision one root-only website lock without following a final symlink."""

from __future__ import annotations

import os
from pathlib import Path
import re
import stat
import sys


RUNTIME_ROOT = Path("/run/uten-website-release")
NAME_RE = re.compile(r"[a-z][a-z0-9-]{0,63}\.lock")


class LockError(RuntimeError):
    pass


def open_checked_lock(
    path: Path,
    runtime_root: Path = RUNTIME_ROOT,
    *,
    expected_uid: int = 0,
    expected_gid: int = 0,
) -> None:
    root_info = runtime_root.lstat()
    if (
        runtime_root.is_symlink()
        or not stat.S_ISDIR(root_info.st_mode)
        or root_info.st_uid != expected_uid
        or root_info.st_gid != expected_gid
        or stat.S_IMODE(root_info.st_mode) != 0o700
    ):
        raise LockError("runtime control directory must be root:root 0700 and not a symlink")
    if path.parent != runtime_root or not NAME_RE.fullmatch(path.name):
        raise LockError("lock path leaves the fixed runtime control directory")
    flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as exc:
        raise LockError(f"cannot safely open lock: {exc}") from exc
    try:
        info = os.fstat(descriptor)
        path_info = path.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != expected_uid
            or info.st_gid != expected_gid
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
            or (info.st_dev, info.st_ino) != (path_info.st_dev, path_info.st_ino)
        ):
            raise LockError("lock must be one root-owned 0600 regular file")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def main() -> int:
    try:
        if len(sys.argv) != 2:
            raise LockError("usage: open_root_lock.py /run/uten-website-release/NAME.lock")
        open_checked_lock(Path(sys.argv[1]))
        return 0
    except (LockError, OSError) as exc:
        print(f"WEBSITE_ROOT_LOCK_REFUSED: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
