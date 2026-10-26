#!/usr/bin/python3 -I
"""One systemd socket connection, one isolated LibreOffice conversion.

The framing contract accepts bytes and a fixed extension, never application paths,
commands or credentials. OS isolation is supplied by uten-imp-preview@.service.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time


SOFFICE_EXECUTABLE = "/usr/bin/soffice"
PROFILE_TEMPLATE = Path("/usr/lib/uten-imp-preview/attachment-preview-safe-profile.xcu")
WORK_ROOT = Path("/work")
MAX_HEADER_BYTES = 4096
MAX_SOURCE_BYTES = 25 * 1024 * 1024
MAX_OUTPUT_BYTES = 64 * 1024 * 1024
MAX_CONVERSION_SECONDS = 60
IO_SECONDS = 15
CHUNK_BYTES = 1024 * 1024
EXTENSIONS = frozenset({"doc", "docx", "rtf", "odt", "xls", "xlsx", "ods", "ppt", "pptx", "odp", "svg"})
ERROR_CODES = frozenset({"INVALID_REQUEST", "INPUT_TOO_LARGE", "INCOMPLETE_INPUT", "INTEGRITY_MISMATCH",
                         "CONVERSION_TIMEOUT", "CONVERSION_FAILED", "INVALID_OUTPUT", "OUTPUT_TOO_LARGE",
                         "UNAVAILABLE", "CLIENT_DISCONNECTED", "INTERNAL_ERROR"})


class WorkerError(Exception):
    def __init__(self, code: str):
        self.code = code if code in ERROR_CODES else "INTERNAL_ERROR"
        super().__init__(self.code)


def _remaining(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise WorkerError("INCOMPLETE_INPUT")
    return remaining


def _read_exact(connection: socket.socket, size: int, deadline: float) -> bytes:
    data = bytearray()
    while len(data) < size:
        connection.settimeout(_remaining(deadline))
        try:
            chunk = connection.recv(min(CHUNK_BYTES, size - len(data)))
        except (TimeoutError, OSError) as failure:
            raise WorkerError("INCOMPLETE_INPUT") from failure
        if not chunk:
            raise WorkerError("INCOMPLETE_INPUT")
        data.extend(chunk)
    return bytes(data)


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def _read_request(connection: socket.socket) -> dict[str, object]:
    deadline = time.monotonic() + IO_SECONDS
    length = struct.unpack("!I", _read_exact(connection, 4, deadline))[0]
    if not 0 < length <= MAX_HEADER_BYTES:
        raise WorkerError("INVALID_REQUEST")
    try:
        request = json.loads(_read_exact(connection, length, deadline).decode("utf-8"),
                             object_pairs_hook=_unique_object,
                             parse_constant=lambda _: (_ for _ in ()).throw(ValueError("non-finite")))
    except (ValueError, UnicodeError, RecursionError) as failure:
        raise WorkerError("INVALID_REQUEST") from failure
    if not isinstance(request, dict) or set(request) != {
            "version", "extension", "sourceBytes", "sha256", "timeoutSeconds", "maxOutputBytes"}:
        raise WorkerError("INVALID_REQUEST")
    if type(request["version"]) is not int or request["version"] != 1:
        raise WorkerError("INVALID_REQUEST")
    if not isinstance(request["extension"], str) or request["extension"] not in EXTENSIONS:
        raise WorkerError("INVALID_REQUEST")
    if type(request["sourceBytes"]) is not int or request["sourceBytes"] <= 0:
        raise WorkerError("INVALID_REQUEST")
    if request["sourceBytes"] > MAX_SOURCE_BYTES:
        raise WorkerError("INPUT_TOO_LARGE")
    if type(request["timeoutSeconds"]) is not int or not 1 <= request["timeoutSeconds"] <= MAX_CONVERSION_SECONDS:
        raise WorkerError("INVALID_REQUEST")
    if type(request["maxOutputBytes"]) is not int or not 1 <= request["maxOutputBytes"] <= MAX_OUTPUT_BYTES:
        raise WorkerError("INVALID_REQUEST")
    if not isinstance(request["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", request["sha256"]):
        raise WorkerError("INVALID_REQUEST")
    return request


def _write_header(connection: socket.socket, response: dict[str, object]) -> None:
    payload = json.dumps(response, separators=(",", ":"), ensure_ascii=True).encode("ascii")
    connection.settimeout(IO_SECONDS)
    connection.sendall(struct.pack("!I", len(payload)) + payload)


def _profile(directory: Path, template: Path) -> Path:
    try:
        descriptor = os.open(template, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as failure:
        raise WorkerError("UNAVAILABLE") from failure
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022 or not 0 < metadata.st_size <= 65536:
            raise WorkerError("UNAVAILABLE")
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            configuration = source.read(65537)
    finally:
        os.close(descriptor)
    profile = directory / "profile"
    user = profile / "user"
    user.mkdir(parents=True, mode=0o700)
    (user / "registrymodifications.xcu").write_bytes(configuration)
    return profile


def _kill_group(process: subprocess.Popen) -> None:
    # The leader may have exited while a spawned child still holds files or pipes.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def _convert(connection: socket.socket, directory: Path, source: Path,
             request: dict[str, object], converter: str, template: Path) -> Path:
    profile = _profile(directory, template)
    output = directory / "output"
    output.mkdir(mode=0o700)
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
                   "HOME": str(directory), "TMPDIR": str(directory), "TMP": str(directory),
                   "TEMP": str(directory), "SAL_USE_VCLPLUGIN": "svp"}
    command = [converter, f"-env:UserInstallation={profile.as_uri()}", "--headless", "--nologo",
               "--nodefault", "--norestore", "--nolockcheck", "--convert-to", "pdf",
               "--outdir", str(output), str(source)]
    try:
        process = subprocess.Popen(command, cwd=directory, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as failure:
        raise WorkerError("UNAVAILABLE") from failure
    try:
        deadline = time.monotonic() + request["timeoutSeconds"]
        while process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise WorkerError("CONVERSION_TIMEOUT")
            readable, _, _ = select.select([connection], [], [], min(0.1, remaining))
            if readable:
                # A request has exactly one body. Extra bytes cannot become a second command.
                if connection.recv(1, socket.MSG_PEEK):
                    raise WorkerError("INVALID_REQUEST")
                raise WorkerError("CLIENT_DISCONNECTED")
        if process.returncode != 0:
            raise WorkerError("CONVERSION_FAILED")
    finally:
        _kill_group(process)
    return output / "source.pdf"


def _send_pdf(connection: socket.socket, output: Path, max_bytes: int) -> None:
    try:
        descriptor = os.open(output, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as failure:
        raise WorkerError("INVALID_OUTPUT") from failure
    with os.fdopen(descriptor, "rb") as content:
        metadata = os.fstat(content.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_uid != os.geteuid() or metadata.st_size < 5:
            raise WorkerError("INVALID_OUTPUT")
        if metadata.st_size > max_bytes:
            raise WorkerError("OUTPUT_TOO_LARGE")
        if content.read(5) != b"%PDF-":
            raise WorkerError("INVALID_OUTPUT")
        content.seek(0)
        digest = hashlib.file_digest(content, "sha256").hexdigest()
        content.seek(0)
        _write_header(connection, {"version": 1, "ok": True, "sizeBytes": metadata.st_size, "sha256": digest})
        deadline = time.monotonic() + IO_SECONDS
        while chunk := content.read(CHUNK_BYTES):
            connection.settimeout(_remaining(deadline))
            connection.sendall(chunk)


def serve(connection: socket.socket, *, converter: str = SOFFICE_EXECUTABLE,
          template: Path = PROFILE_TEMPLATE, work_root: Path = WORK_ROOT) -> bool:
    """Internal dependency parameters support tests; protocol input cannot override them."""
    try:
        request = _read_request(connection)
        with tempfile.TemporaryDirectory(prefix="request-", dir=work_root) as temporary:
            directory = Path(temporary)
            source = directory / ("source." + request["extension"])
            digest = hashlib.sha256()
            remaining = request["sourceBytes"]
            deadline = time.monotonic() + IO_SECONDS
            with source.open("xb") as target:
                while remaining:
                    chunk = _read_exact(connection, min(CHUNK_BYTES, remaining), deadline)
                    digest.update(chunk)
                    target.write(chunk)
                    remaining -= len(chunk)
            if not hmac.compare_digest(digest.hexdigest(), request["sha256"]):
                raise WorkerError("INTEGRITY_MISMATCH")
            output = _convert(connection, directory, source, request, converter, template)
            _send_pdf(connection, output, request["maxOutputBytes"])
        return True
    except WorkerError as failure:
        code = failure.code
    except (OSError, ValueError, subprocess.SubprocessError):
        code = "INTERNAL_ERROR"
    try:
        _write_header(connection, {"version": 1, "ok": False, "error": code})
    except OSError:
        pass
    # Only a fixed code is logged; no file name, original path, content or subprocess output.
    sys.stderr.write("UTEN_PREVIEW_" + code + "\n")
    return False


def _interrupted(_number: int, _frame: object) -> None:
    raise WorkerError("CLIENT_DISCONNECTED")


def main() -> int:
    if not sys.flags.isolated or len(sys.argv) != 1:
        sys.stderr.write("UTEN_PREVIEW_ISOLATED_PYTHON_REQUIRED\n")
        return 78
    os.umask(0o077)
    signal.signal(signal.SIGTERM, _interrupted)
    signal.signal(signal.SIGINT, _interrupted)
    try:
        with socket.socket(fileno=os.dup(0)) as connection:
            if connection.family != socket.AF_UNIX or connection.type != socket.SOCK_STREAM:
                return 78
            return 0 if serve(connection) else 1
    except OSError:
        sys.stderr.write("UTEN_PREVIEW_SOCKET_REQUIRED\n")
        return 78


if __name__ == "__main__":
    sys.exit(main())
