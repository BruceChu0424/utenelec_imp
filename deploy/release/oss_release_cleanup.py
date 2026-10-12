#!/usr/bin/env python3
"""Remove superseded release object versions using the pinned oss2 SDK contract."""

import argparse
import os
import re
import sys


class CleanupError(ValueError):
    """Remote inventory cannot safely authorize cleanup."""


def version_inventory(bucket, prefix):
    """Read every version and delete marker before issuing any deletion."""
    entries = []
    cursor = ("", "")
    seen = {cursor}
    while True:
        page = bucket.list_object_versions(
            prefix=prefix, key_marker=cursor[0], versionid_marker=cursor[1], max_keys=200
        )
        # oss2 2.19.1 exposes `versions` and `delete_marker`, not the XML tag names.
        for entry in list(page.versions) + list(page.delete_marker):
            if not isinstance(entry.key, str) or not entry.key.startswith(prefix):
                raise CleanupError("OSS inventory contains a key outside the requested prefix")
            if not isinstance(entry.versionid, str) or not entry.versionid:
                raise CleanupError("OSS inventory is missing an explicit version ID")
            entries.append(entry)
        if not page.is_truncated:
            return entries
        cursor = (page.next_key_marker, page.next_versionid_marker)
        if not cursor[0] or cursor in seen:
            raise CleanupError("OSS pagination marker is missing or repeated; cleanup stopped")
        seen.add(cursor)


def require_current_pointer(bucket, version):
    if bucket.get_object("LATEST.txt").read().decode("utf-8").strip() != version:
        raise CleanupError("LATEST.txt no longer identifies this release; cleanup stopped")


def purge_old_versions(bucket, version):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise CleanupError("Release version must be canonical vMAJOR.MINOR.PATCH")
    require_current_pointer(bucket, version)
    keep = f"releases/{version}/"
    old_releases = [
        entry for entry in version_inventory(bucket, "releases/")
        if not entry.key.startswith(keep)
    ]
    old_pointers = [
        entry for entry in version_inventory(bucket, "LATEST.txt")
        if entry.key == "LATEST.txt" and not entry.is_latest
    ]
    # Inventory is read before deletes, and an older run cannot purge a newer release.
    require_current_pointer(bucket, version)
    for entry in old_releases + old_pointers:
        bucket.delete_object(entry.key, params={"versionId": entry.versionid})
    return len(old_releases), len(old_pointers)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    args = parser.parse_args(argv)
    import oss2

    auth = oss2.Auth(os.environ["OSS_ACCESS_KEY_ID"], os.environ["OSS_ACCESS_KEY_SECRET"])
    bucket = oss2.Bucket(
        auth, f"https://{os.environ['OSS_ENDPOINT']}", os.environ["OSS_BUCKET"],
        connect_timeout=60,
    )
    try:
        releases, pointers = purge_old_versions(bucket, args.version)
    except CleanupError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    except oss2.exceptions.OssError as exc:
        # SDK errors can include request metadata. Log the error type, never credentials.
        print(f"::error::OSS cleanup request failed ({type(exc).__name__}); cleanup stopped",
              file=sys.stderr)
        if isinstance(exc, oss2.exceptions.AccessDenied):
            print("::error::Check publisher RAM permissions: oss:GetObject for LATEST.txt, "
                  "oss:ListObjectVersions for the release bucket, and oss:DeleteObjectVersion "
                  "for releases/* and LATEST.txt. Plain oss:DeleteObject does not authorize "
                  "deleting a specified version. Published release artifacts remain available.",
                  file=sys.stderr)
        return 1
    print(f"已删除旧版本对象 {releases} 个（保留 releases/{args.version}/）")
    print(f"已清理 LATEST.txt 历史版本 {pointers} 个")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
