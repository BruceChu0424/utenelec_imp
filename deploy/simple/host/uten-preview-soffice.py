#!/usr/bin/python3 -I
"""Launch the system converter with no application/agent/loader credentials.

Installed root-owned and executable; the JVM supplies the original argument list
and its private per-conversion cwd. This remains the application OS user: an
independent worker is still required for filesystem/process/network isolation.
"""
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys


SOFFICE_EXECUTABLE = "/usr/bin/soffice"
FIXED_PATH = "/usr/bin:/bin"
LOCALE_NAMES = ("LANG", "LC_ALL", "TZ")


class UnsafeWorkingDirectory(ValueError):
    pass


def private_work_directory() -> str:
    """Require owner-only directory permissions; inspect no credentials or input files."""
    directory = Path.cwd()
    descriptor = os.open(".", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        current = os.fstat(descriptor)
        named = directory.lstat()
        if (not stat.S_ISDIR(named.st_mode) or named.st_uid != os.geteuid()
                or named.st_mode & 0o077
                or (named.st_dev, named.st_ino) != (current.st_dev, current.st_ino)):
            raise UnsafeWorkingDirectory()
        for parent in directory.parents:
            if not stat.S_ISDIR(parent.lstat().st_mode):
                raise UnsafeWorkingDirectory()
    finally:
        os.close(descriptor)
    return str(directory)


def converter_environment(directory: str) -> dict[str, str]:
    environment = {"PATH": FIXED_PATH}
    for name in LOCALE_NAMES:
        value = os.environ.get(name)
        if value:
            environment[name] = value
    for name in ("HOME", "TMPDIR", "TMP", "TEMP"):
        environment[name] = directory
    return environment


def main() -> int:
    if not sys.flags.isolated:
        sys.stderr.write("UTEN_PREVIEW_ISOLATED_PYTHON_REQUIRED\n")
        return 78
    try:
        directory = private_work_directory()
    except (OSError, UnsafeWorkingDirectory):
        sys.stderr.write("UTEN_PREVIEW_PRIVATE_DIRECTORY_REQUIRED\n")
        return 78
    try:
        os.execve(SOFFICE_EXECUTABLE, [SOFFICE_EXECUTABLE, *sys.argv[1:]],
                  converter_environment(directory))
    except OSError:
        sys.stderr.write("UTEN_PREVIEW_SYSTEM_CONVERTER_UNAVAILABLE\n")
        return 127
    return 127


if __name__ == "__main__":
    sys.exit(main())
