#!/usr/bin/env python3
"""Prepare only the private client catalog and its Java-compatible lock file.

The parent media directory must already exist on the approved mounted volume.
No source file is moved, no release is published, and no network is used.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat


MIN_FREE_BYTES = 10 * 1024**3
PROFILES = {
    "internal": (Path("/var/lib/uten-imp-media/attachments"), Path("/var/lib/uten-imp-media")),
    "internal-test": (Path("/data/uten-imp/attachments"), Path("/data")),
}


def prepare(media_root: Path, uid: int, gid: int, min_free_bytes=MIN_FREE_BYTES) -> dict:
    """Do not follow catalog links, replace files, or chmod a directory tree."""
    import fcntl

    media_root = Path(media_root)
    if not media_root.is_absolute() or media_root.resolve(strict=True) != media_root:
        raise ValueError("Media root must be an existing canonical private directory")
    if type(min_free_bytes) is not int or min_free_bytes < 0:
        raise ValueError("Invalid free-space reserve")
    # A root preparer must not mistake its own access for the service account's.
    # Do not repair ancestor permissions or ownership as a side effect.
    if uid != 0:
        for ancestor in (*reversed(media_root.parents), media_root):
            info = ancestor.stat()
            execute = 0o100 if info.st_uid == uid else 0o010 if info.st_gid == gid else 0o001
            if not info.st_mode & execute:
                raise ValueError("Media parent chain is not traversable by the service account")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    parent = os.open(media_root, flags)
    directory = barrier = None
    created = False
    try:
        parent_info = os.fstat(parent)
        if parent_info.st_uid not in {0, uid} or parent_info.st_mode & 0o022:
            raise ValueError("Media root owner or write permissions are unsafe")
        volume = os.fstatvfs(parent)
        if volume.f_bavail * volume.f_frsize < min_free_bytes:
            raise ValueError("Private media volume has less than the required free-space reserve")
        try:
            os.mkdir("client-releases", 0o700, dir_fd=parent)
            created = True
        except FileExistsError:
            pass
        directory = os.open("client-releases", flags, dir_fd=parent)
        info = os.fstat(directory)
        if not created and (info.st_uid != uid or info.st_mode & 0o022):
            raise ValueError("Existing client catalog has an unexpected owner or write permissions")
        if created:
            os.fchown(directory, uid, gid)
        os.fchmod(directory, 0o700)
        try:
            barrier = os.open(".catalog.lock", os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                              0o600, dir_fd=directory)
            os.fchown(barrier, uid, gid)
        except FileExistsError:
            barrier = os.open(".catalog.lock", os.O_RDWR | os.O_NOFOLLOW, dir_fd=directory)
        lock_info = os.fstat(barrier)
        if (not stat.S_ISREG(lock_info.st_mode) or lock_info.st_nlink != 1
                or lock_info.st_uid != uid or lock_info.st_size != 0):
            raise ValueError("Existing client catalog barrier is unsafe")
        # The same record-lock mechanism as FileChannel.lock(), never flock().
        fcntl.lockf(barrier, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.fchmod(barrier, 0o600)
        os.fsync(barrier)
        os.fsync(directory)
        os.fsync(parent)
        return {"catalog": str(media_root / "client-releases"), "created": created,
                "uid": uid, "gid": gid, "minimumFreeBytes": min_free_bytes}
    finally:
        for descriptor in (barrier, directory, parent):
            if descriptor is not None:
                os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=PROFILES, default="internal")
    args = parser.parse_args()
    if os.name != "posix" or os.geteuid() != 0:
        parser.error("Run the reviewed preparer as root on the Linux ERP host")
    import pwd

    media, mount = PROFILES[args.profile]
    if not os.path.ismount(mount):
        parser.error("The approved private media filesystem is not mounted")
    account = pwd.getpwnam("uten-imp")
    print(json.dumps(prepare(media, account.pw_uid, account.pw_gid)))


if __name__ == "__main__":
    main()
