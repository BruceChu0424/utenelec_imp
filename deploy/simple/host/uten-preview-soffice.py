#!/usr/bin/python3 -I
"""Bridge the JVM command to an isolated worker; never run a local converter.

Only current source bytes and fixed limits cross the Unix socket. No application
paths or credentials are sent. Partial or invalid PDFs are never published.
"""
from __future__ import annotations
import hashlib
import hmac
import json
import os
from pathlib import Path
import socket
import stat
import struct
import sys
import tempfile
import time
from urllib.parse import unquote, urlsplit

WORKER_SOCKET = "/run/uten-imp-preview.sock"
MAX_INPUT_BYTES = 25 * 1024 * 1024
MAX_OUTPUT_BYTES = 64 * 1024 * 1024
MAX_HEADER_BYTES = 4096
REQUEST_SECONDS = 65
EXTENSIONS = frozenset(("doc", "docx", "rtf", "odt", "xls", "xlsx", "ods",
                        "ppt", "pptx", "odp", "svg"))

class PreviewFailure(ValueError):
    pass

def private_work_directory() -> Path:
    directory = Path.cwd()
    descriptor = os.open(".", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        current, named = os.fstat(descriptor), directory.lstat()
        if (not stat.S_ISDIR(named.st_mode) or named.st_uid != os.geteuid()
                or named.st_mode & 0o077
                or (named.st_dev, named.st_ino) != (current.st_dev, current.st_ino)):
            raise PreviewFailure()
        if any(not stat.S_ISDIR(parent.lstat().st_mode) for parent in directory.parents):
            raise PreviewFailure()
    finally:
        os.close(descriptor)
    return directory

def command_source(directory: Path, arguments: list[str]) -> Path:
    if (len(arguments) != 10
            or arguments[:4] != ["--headless", "--norestore", "--nologo", "--nolockcheck"]
            or not arguments[4].startswith("-env:UserInstallation=")
            or arguments[5:8] != ["--convert-to", "pdf", "--outdir"]):
        raise PreviewFailure()
    profile = urlsplit(arguments[4].removeprefix("-env:UserInstallation="))
    if (profile.scheme != "file" or profile.netloc or profile.query or profile.fragment
            or Path(unquote(profile.path)) != directory / "profile"
            or Path(arguments[8]) != directory):
        raise PreviewFailure()
    source = Path(arguments[9])
    if (source.parent != directory or source.name != "source" + source.suffix
            or source.suffix.removeprefix(".") not in EXTENSIONS):
        raise PreviewFailure()
    return source

def remaining(deadline: float) -> float:
    value = deadline - time.monotonic()
    if value <= 0:
        raise PreviewFailure()
    return value

def receive_exact(connection: socket.socket, length: int, deadline: float) -> bytes:
    result = bytearray()
    while len(result) < length:
        connection.settimeout(remaining(deadline))
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise PreviewFailure()
        result.extend(chunk)
    return bytes(result)

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise PreviewFailure()
        result[key] = value
    return result

def convert(directory: Path, source: Path) -> None:
    descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    temporary = None
    try:
        with os.fdopen(descriptor, "rb") as original:
            metadata = os.fstat(original.fileno())
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                    or not 0 < metadata.st_size <= MAX_INPUT_BYTES):
                raise PreviewFailure()
            digest, read_bytes = hashlib.sha256(), 0
            while chunk := original.read(65536):
                read_bytes += len(chunk)
                if read_bytes > MAX_INPUT_BYTES:
                    raise PreviewFailure()
                digest.update(chunk)
            if read_bytes != metadata.st_size:
                raise PreviewFailure()
            original.seek(0)
            output = directory / "source.pdf"
            if output.exists() or output.is_symlink():
                raise PreviewFailure()
            header = json.dumps({"version": 1, "extension": source.suffix[1:],
                                 "sourceBytes": read_bytes, "sha256": digest.hexdigest(),
                                 "timeoutSeconds": 60, "maxOutputBytes": MAX_OUTPUT_BYTES},
                                separators=(",", ":")).encode("utf-8")
            deadline = time.monotonic() + REQUEST_SECONDS
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(min(3, remaining(deadline)))
                connection.connect(WORKER_SOCKET)
                connection.settimeout(remaining(deadline))
                connection.sendall(struct.pack("!I", len(header)) + header)
                sent = 0
                while chunk := original.read(65536):
                    sent += len(chunk)
                    if sent > read_bytes:
                        raise PreviewFailure()
                    connection.settimeout(remaining(deadline))
                    connection.sendall(chunk)
                if sent != read_bytes:
                    raise PreviewFailure()
                length = struct.unpack("!I", receive_exact(connection, 4, deadline))[0]
                if not 0 < length <= MAX_HEADER_BYTES:
                    raise PreviewFailure()
                response = json.loads(receive_exact(connection, length, deadline),
                                      object_pairs_hook=unique_object)
                if (not isinstance(response, dict)
                        or set(response) != {"version", "ok", "sizeBytes", "sha256"}
                        or type(response["version"]) is not int or response["version"] != 1
                        or response["ok"] is not True
                        or type(response["sizeBytes"]) is not int
                        or not 5 < response["sizeBytes"] <= MAX_OUTPUT_BYTES
                        or not isinstance(response["sha256"], str)
                        or len(response["sha256"]) != 64):
                    raise PreviewFailure()
                fd, name = tempfile.mkstemp(prefix=".preview-response-", dir=directory)
                temporary = Path(name)
                digest, left, first = hashlib.sha256(), response["sizeBytes"], True
                with os.fdopen(fd, "wb") as pdf:
                    while left:
                        chunk = receive_exact(connection, min(65536, left), deadline)
                        if first and not chunk.startswith(b"%PDF-"):
                            raise PreviewFailure()
                        first = False
                        digest.update(chunk)
                        pdf.write(chunk)
                        left -= len(chunk)
                if not hmac.compare_digest(digest.hexdigest(), response["sha256"]):
                    raise PreviewFailure()
                # Exclusive publication also refuses a pre-existing symlink.
                os.link(temporary, output, follow_symlinks=False)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)

def main() -> int:
    if not sys.flags.isolated:
        sys.stderr.write("UTEN_PREVIEW_ISOLATED_PYTHON_REQUIRED\n")
        return 78
    try:
        directory = private_work_directory()
        convert(directory, command_source(directory, sys.argv[1:]))
        return 0
    except (OSError, ValueError, UnicodeError, TypeError, KeyError, RecursionError):
        sys.stderr.write("UTEN_PREVIEW_ISOLATED_WORKER_UNAVAILABLE\n")
        return 69

if __name__ == "__main__":
    sys.exit(main())
