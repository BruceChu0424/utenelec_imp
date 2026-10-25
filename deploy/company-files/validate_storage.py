#!/usr/bin/python3
"""Read-only mount/permission gate for the shared internal document store.

Runs as the application user before Java starts. Never creates a directory or
opens an object, never reads server.env, and never substitutes a missing mount.
"""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys


def unescape_mount(value):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), value)


def parse_mounts(contents):
    mounts = []
    for line in contents.splitlines():
        left, separator, right = line.partition(" - ")
        if not separator:
            raise ValueError("Malformed mount information")
        fields, details = left.split(), right.split()
        if len(fields) < 6 or len(details) < 3:
            raise ValueError("Malformed mount information")
        mounts.append({"target": unescape_mount(fields[4]), "device": fields[2],
                       "root": unescape_mount(fields[3]), "fs": details[0],
                       "source": unescape_mount(details[1]),
                       "options": set(fields[5].split(",")) | set(details[2].split(","))})
    return mounts


def check_mounts(mounts, expected_mount, expected_source):
    roots = [m for m in mounts if m["target"] == "/"]
    media = [m for m in mounts if m["target"] == expected_mount]
    if not roots or len(media) != 1:
        raise ValueError("The dedicated media mount is missing or ambiguous")
    volume = media[0]
    if volume["device"] == roots[-1]["device"]:
        raise ValueError("The media volume must be independent of the system filesystem")
    if volume["source"] != expected_source or volume["root"] != "/":
        raise ValueError("The media mount does not match the reviewed source")
    if volume["fs"] != "ext4" or not {"rw", "nodev", "nosuid", "noexec"} <= volume["options"] or "ro" in volume["options"]:
        raise ValueError("The media filesystem or mount protections are invalid")
    return volume


def read_policy(path):
    meta = path.lstat()
    if not stat.S_ISREG(meta.st_mode) or path != path.resolve(strict=True) or meta.st_uid != 0 or meta.st_mode & 0o022:
        raise ValueError("Storage policy must be a real root-owned non-writable file")
    policy = json.loads(path.read_text(encoding="utf-8"))
    if set(policy) != {"mount", "source", "filesystem_uuid", "root", "min_free_bytes"}:
        raise ValueError("Invalid storage policy fields")
    if policy["mount"] != "/var/lib/uten-imp-media" or policy["root"] != "/var/lib/uten-imp-media/attachments":
        raise ValueError("Storage policy must target the reviewed internal media volume")
    if not isinstance(policy["source"], str) or not policy["source"].startswith("/dev/") or "REPLACE" in policy["source"]:
        raise ValueError("Storage policy requires the reviewed block-device source")
    if not isinstance(policy["filesystem_uuid"], str) or not re.fullmatch(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", policy["filesystem_uuid"]):
        raise ValueError("Storage policy requires the reviewed filesystem UUID")
    if type(policy["min_free_bytes"]) is not int or policy["min_free_bytes"] < 10 * 1024**3:
        raise ValueError("Storage policy must reserve at least 10 GiB")
    return policy


def uuid_from_udev(contents):
    values = [line.removeprefix("E:ID_FS_UUID=") for line in contents.splitlines() if line.startswith("E:ID_FS_UUID=")]
    if len(values) != 1:
        raise ValueError("Filesystem UUID evidence is missing or ambiguous")
    return values[0]


def validate(policy, environment):
    root = Path(policy["root"])
    if environment.get("UTEN_STORAGE_PROVIDER") != "internal" or environment.get("UTEN_INTERNAL_STORAGE_ROOT") != str(root):
        raise ValueError("Application storage does not match the reviewed internal root")
    configured_reserve = int(environment.get("UTEN_INTERNAL_STORAGE_MIN_FREE_BYTES", "0"))
    if configured_reserve < policy["min_free_bytes"]:
        raise ValueError("Application free-space reserve is below the reviewed minimum")
    if environment.get("UTEN_ATTACHMENT_SCANNER_PROVIDER") != "clamav":
        raise ValueError("Company documents require the ClamAV scanner")
    volume = check_mounts(parse_mounts(Path("/proc/self/mountinfo").read_text()), policy["mount"], policy["source"])
    # udev's block-device metadata remains readable with systemd PrivateDevices;
    # no /dev node access, blkid subprocess or root privileges are necessary.
    udev = Path("/run/udev/data") / ("b" + volume["device"])
    evidence = udev.lstat()
    if not stat.S_ISREG(evidence.st_mode) or evidence.st_uid != 0 or evidence.st_mode & 0o022 or udev != udev.resolve(strict=True):
        raise ValueError("Filesystem UUID evidence is not root-controlled")
    if uuid_from_udev(udev.read_text()) != policy["filesystem_uuid"]:
        raise ValueError("The mounted filesystem UUID does not match the reviewed volume")
    import pwd
    import grp
    expected_uid, expected_gid = pwd.getpwnam("uten-imp").pw_uid, grp.getgrnam("uten-imp").gr_gid
    if os.geteuid() != expected_uid or os.getegid() != expected_gid:
        raise ValueError("Storage preflight must run as the actual uten-imp service identity")
    # Missing namespaces fail closed. Initial creation belongs to the reviewed
    # deployment procedure, never this preflight or a fallback system directory.
    namespaces = [root, *(root / n for n in ("staging", "final", "scratch"))]
    preview = root / "preview"
    if preview.exists() or preview.is_symlink():
        namespaces.append(preview)
    for path in namespaces:
        meta = path.lstat()
        if path != path.resolve(strict=True) or not stat.S_ISDIR(meta.st_mode):
            raise ValueError("Internal storage directories must be real directories")
        if meta.st_uid != expected_uid or meta.st_gid != expected_gid or stat.S_IMODE(meta.st_mode) != 0o700:
            raise ValueError("Internal storage directories must belong to uten-imp with mode 0700")
        if os.major(meta.st_dev) != int(volume["device"].split(":")[0]) or os.minor(meta.st_dev) != int(volume["device"].split(":")[1]):
            raise ValueError("Internal storage namespaces must stay on the dedicated volume")
    stats = os.statvfs(root)
    available = stats.f_bavail * stats.f_frsize
    if available < configured_reserve:
        raise ValueError("Internal media volume has less than the reserved free space")
    socket = Path(environment.get("UTEN_CLAMAV_UNIX_SOCKET", "/run/clamav/clamd.ctl"))
    socket_meta = socket.lstat()
    if (not socket.is_absolute() or socket != socket.resolve(strict=True)
            or not stat.S_ISSOCK(socket_meta.st_mode) or socket_meta.st_gid != expected_gid
            or stat.S_IMODE(socket_meta.st_mode) != 0o660 or not os.access(socket, os.R_OK | os.W_OK)):
        raise ValueError("The application cannot access the configured scanner socket")
    return {"status": "PASS", "mount": policy["mount"], "root": str(root), "available_bytes": available,
            "reserved_bytes": configured_reserve, "scanner": "clamav"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        report = validate(read_policy(arguments.policy), os.environ)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"status": "FAIL", "reason": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
