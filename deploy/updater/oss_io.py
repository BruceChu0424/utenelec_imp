#!/usr/bin/env python3
"""Minimal Aliyun OSS I/O helper; credentials are accepted only via environment."""

from __future__ import annotations

import json
import os
import re
import stat
import sys
import urllib.parse
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn


BUCKET_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$")
DEFAULT_MAX_DOWNLOAD_BYTES = 2 * 1024 * 1024 * 1024


class OssIoError(RuntimeError):
    """Raised for an invalid local request or unsafe OSS configuration."""


def fail(message: str) -> NoReturn:
    raise OssIoError(message)


def required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        fail(f"missing required environment variable: {name}")
    return value


def validated_endpoint(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        fail("OSS_ENDPOINT must be a plain HTTPS origin without credentials or a path")
    return value.rstrip("/")


def validated_key(value: str) -> str:
    if len(value.encode("utf-8")) > 1023:
        fail("OSS object key is too long")
    if not value or value.startswith("/") or "\\" in value:
        fail("OSS object key is not canonical")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        fail("OSS object key contains control characters")
    pure = PurePosixPath(value)
    if pure.is_absolute() or any(part in ("", ".", "..") for part in value.split("/")):
        fail("OSS object key contains an unsafe path segment")
    if pure.as_posix() != value:
        fail("OSS object key is not canonical")
    return value


def safe_source(value: str) -> Path:
    source = Path(value)
    details = source.lstat()
    if not stat.S_ISREG(details.st_mode) or source.is_symlink():
        fail(f"upload source is not a regular non-symlink file: {source}")
    return source


def max_download_bytes() -> int:
    raw = os.environ.get("OSS_MAX_DOWNLOAD_BYTES", str(DEFAULT_MAX_DOWNLOAD_BYTES))
    try:
        value = int(raw)
    except ValueError as exc:
        raise OssIoError("OSS_MAX_DOWNLOAD_BYTES must be an integer") from exc
    if value < 1 or value > DEFAULT_MAX_DOWNLOAD_BYTES:
        fail("OSS_MAX_DOWNLOAD_BYTES is outside the allowed range")
    return value


def metadata(result: Any) -> dict[str, Any]:
    length = getattr(result, "content_length", None)
    if not isinstance(length, int) or isinstance(length, bool) or length < 0:
        fail("OSS HEAD response did not contain a valid content length")
    last_modified = getattr(result, "last_modified", None)
    return {
        "contentLength": length,
        "etag": getattr(result, "etag", None),
        "lastModified": last_modified if isinstance(last_modified, int) else None,
        "versionId": getattr(result, "versionid", None),
    }


def _open_stable_directory(path: Path) -> tuple[int, os.stat_result]:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise OssIoError("download destination parent cannot be opened safely") from exc
    try:
        opened = os.fstat(descriptor)
        live = path.lstat()
        if (
            not stat.S_ISDIR(opened.st_mode)
            or not stat.S_ISDIR(live.st_mode)
            or stat.S_ISLNK(live.st_mode)
            or (opened.st_dev, opened.st_ino) != (live.st_dev, live.st_ino)
        ):
            fail("download destination parent is not a stable real directory")
        return descriptor, opened
    except Exception:
        os.close(descriptor)
        raise


def _path_absent(directory_descriptor: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return True
    return False


def _open_anonymous_download(directory_descriptor: int) -> tuple[int, os.stat_result]:
    temporary_flag = getattr(os, "O_TMPFILE", 0)
    if not temporary_flag:
        fail("download filesystem does not support anonymous temporary files")
    flags = os.O_RDWR | temporary_flag | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(".", flags, 0o640, dir_fd=directory_descriptor)
    except OSError as exc:
        raise OssIoError(
            "download filesystem cannot create a secure anonymous temporary file"
        ) from exc
    try:
        os.fchmod(descriptor, 0o640)
        opened = os.fstat(descriptor)
        get_euid = getattr(os, "geteuid", None)
        expected_uid = get_euid() if get_euid is not None else opened.st_uid
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 0
            or opened.st_size != 0
            or opened.st_uid != expected_uid
            or stat.S_IMODE(opened.st_mode) != 0o640
        ):
            fail("anonymous download inode does not meet the local safety contract")
        return descriptor, opened
    except Exception:
        os.close(descriptor)
        raise


def _write_download_stream(
    descriptor: int,
    opened: os.stat_result,
    stream: Any,
    expected: int,
    maximum: int,
) -> None:
    total = 0
    while total < expected:
        block = stream.read(min(1024 * 1024, expected - total))
        if not block:
            fail("OSS object ended before the authenticated content length")
        if not isinstance(block, (bytes, bytearray, memoryview)):
            fail("OSS object stream returned non-byte content")
        view = memoryview(block)
        total += len(view)
        if total > expected or total > maximum:
            fail("OSS object exceeded the authenticated content length")
        while view:
            written = os.write(descriptor, view)
            if written < 1:
                fail("local download write made no progress")
            view = view[written:]
    extra = stream.read(1)
    if not isinstance(extra, (bytes, bytearray, memoryview)):
        fail("OSS object stream returned non-byte content")
    if extra:
        fail("OSS object exceeded the authenticated content length")
    after = os.fstat(descriptor)
    if (
        (opened.st_dev, opened.st_ino) != (after.st_dev, after.st_ino)
        or not stat.S_ISREG(after.st_mode)
        or after.st_nlink != 0
        or after.st_size != expected
        or stat.S_IMODE(after.st_mode) != 0o640
    ):
        fail("anonymous download inode changed while being written")
    os.fsync(descriptor)


def _publish_download(
    descriptor: int,
    opened: os.stat_result,
    directory_descriptor: int,
    parent: Path,
    parent_opened: os.stat_result,
    destination_name: str,
    expected: int,
) -> None:
    if not _path_absent(directory_descriptor, destination_name):
        fail("download destination already exists")
    live_parent = parent.lstat()
    if (
        not stat.S_ISDIR(live_parent.st_mode)
        or stat.S_ISLNK(live_parent.st_mode)
        or (parent_opened.st_dev, parent_opened.st_ino)
        != (live_parent.st_dev, live_parent.st_ino)
    ):
        fail("download destination parent changed before publication")

    published = False
    try:
        # Linux documents /proc/self/fd + AT_SYMLINK_FOLLOW as the
        # capability-free way to link an O_TMPFILE inode into its directory.
        os.link(
            f"/proc/self/fd/{descriptor}",
            destination_name,
            dst_dir_fd=directory_descriptor,
            follow_symlinks=True,
        )
        linked = os.stat(
            destination_name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        opened_after = os.fstat(descriptor)
        live_parent_after = parent.lstat()
        if (
            (opened.st_dev, opened.st_ino)
            != (opened_after.st_dev, opened_after.st_ino)
            or (opened_after.st_dev, opened_after.st_ino)
            != (linked.st_dev, linked.st_ino)
            or not stat.S_ISREG(linked.st_mode)
            or linked.st_nlink != 1
            or opened_after.st_nlink != 1
            or linked.st_size != expected
            or opened_after.st_size != expected
            or stat.S_IMODE(linked.st_mode) != 0o640
            or not stat.S_ISDIR(live_parent_after.st_mode)
            or stat.S_ISLNK(live_parent_after.st_mode)
            or (parent_opened.st_dev, parent_opened.st_ino)
            != (live_parent_after.st_dev, live_parent_after.st_ino)
        ):
            fail("published download is not the verified anonymous inode")
        os.fsync(directory_descriptor)
        published = True
    except FileExistsError as exc:
        raise OssIoError("download destination appeared during publication") from exc
    except OSError as exc:
        raise OssIoError("verified download could not be published atomically") from exc
    finally:
        if not published:
            try:
                current = os.stat(
                    destination_name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
                if (current.st_dev, current.st_ino) == (opened.st_dev, opened.st_ino):
                    os.unlink(destination_name, dir_fd=directory_descriptor)
                    os.fsync(directory_descriptor)
            except FileNotFoundError:
                pass


def atomic_download(bucket: Any, key: str, destination: Path) -> None:
    parent = destination.parent
    destination_name = destination.name
    if destination_name in ("", ".", "..") or Path(destination_name).name != destination_name:
        fail("download destination name is not canonical")
    directory_descriptor, parent_opened = _open_stable_directory(parent)
    descriptor = -1
    try:
        if not _path_absent(directory_descriptor, destination_name):
            fail("download destination already exists")
        head = metadata(bucket.head_object(key))
        expected = head["contentLength"]
        maximum = max_download_bytes()
        if expected < 1 or expected > maximum:
            fail("OSS object is outside the allowed download size")

        descriptor, opened = _open_anonymous_download(directory_descriptor)
        stream = bucket.get_object(key)
        try:
            downloaded = metadata(stream)
            if downloaded["contentLength"] != expected:
                fail("OSS HEAD and GET content lengths differ")
            for field in ("etag", "versionId"):
                if head[field] is not None and downloaded[field] != head[field]:
                    fail(f"OSS HEAD and GET {field} values differ")
            _write_download_stream(descriptor, opened, stream, expected, maximum)
        finally:
            close = getattr(stream, "close", None)
            if callable(close):
                close()
        _publish_download(
            descriptor,
            opened,
            directory_descriptor,
            parent,
            parent_opened,
            destination_name,
            expected,
        )
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(directory_descriptor)


def build_bucket() -> Any:
    import oss2

    access_key_id = required_env("OSS_ACCESS_KEY_ID")
    access_key_secret = required_env("OSS_ACCESS_KEY_SECRET")
    bucket_name = required_env("OSS_BUCKET")
    endpoint = validated_endpoint(required_env("OSS_ENDPOINT"))
    if not BUCKET_RE.fullmatch(bucket_name):
        fail("OSS_BUCKET is not a valid bucket name")
    security_token = os.environ.get("OSS_SECURITY_TOKEN")
    if security_token:
        auth = oss2.StsAuth(access_key_id, access_key_secret, security_token)
    else:
        auth = oss2.Auth(access_key_id, access_key_secret)
    return oss2.Bucket(auth, endpoint, bucket_name)


def usage() -> int:
    print(
        "usage: oss_io.py stat KEY | get KEY DEST | put SRC KEY | "
        "put-immutable SRC KEY | exists KEY",
        file=sys.stderr,
    )
    return 2


def main() -> int:
    os.umask(0o027)
    if len(sys.argv) < 3:
        return usage()
    action = sys.argv[1]
    expected_arguments = {"stat": 3, "exists": 3, "get": 4, "put": 4, "put-immutable": 4}
    if action not in expected_arguments or len(sys.argv) != expected_arguments[action]:
        return usage()
    try:
        bucket = build_bucket()
        if action == "stat":
            print(json.dumps(metadata(bucket.head_object(validated_key(sys.argv[2]))), sort_keys=True))
            return 0
        if action == "exists":
            print("true" if bucket.object_exists(validated_key(sys.argv[2])) else "false")
            return 0
        if action == "get":
            atomic_download(bucket, validated_key(sys.argv[2]), Path(sys.argv[3]))
            return 0
        source = safe_source(sys.argv[2])
        key = validated_key(sys.argv[3])
        headers = {"x-oss-forbid-overwrite": "true"} if action == "put-immutable" else None
        bucket.put_object_from_file(key, str(source), headers=headers)
        return 0
    except OssIoError as exc:
        print(f"OSS I/O rejected: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        # Do not echo exception strings: SDK errors may contain request details.
        print(f"OSS I/O failed: {type(exc).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
