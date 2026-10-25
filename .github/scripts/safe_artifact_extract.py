"""Unpack Quality artifacts only after download-artifact's SHA-256 gate succeeds.

The pinned official action downloads raw ZIPs with skip-decompress=true. Its
Content-Disposition filename is not a stable API: even the fallback 'artifact'
has no extension. Multiple downloads use separate artifact-name directories;
the SDK puts a single match directly in the raw root. Accept both layouts while
keeping report ownership and the original merged shard layout explicit.
"""

import argparse
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[2]
DESTINATIONS = {
    "backend-test-plan": "target-ci-plan",
    "backend-test-results-*": "target-ci-reports",
    "backend-unfiltered-reference": "target-ci-reference",
}
MAX_ARCHIVE_BYTES = 3 * 1024**3
MAX_MEMBER_BYTES = 2 * 1024**3
MAX_TOTAL_BYTES = 8 * 1024**3
MAX_MEMBERS = 100_000
# The current reviewed workflow schedules eight partitions. Keep raw names and
# ZIP ownership in the same finite pool; the workflow-boundary test pins it.
SHARD_IDS = tuple(str(number) for number in range(8))
SHARD_DIRECTORIES = frozenset("shard-" + number for number in SHARD_IDS)
SHARD_NAME = re.compile(r"backend-test-results-(" + "|".join(SHARD_IDS) + r")\Z")
RESERVED = re.compile(r"(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?\Z", re.I)


def safe_parts(name):
    if not name or "\\" in name or ":" in name or name.startswith("/"):
        raise ValueError("unsafe artifact member path")
    parts = name.split("/")
    if any(not p or p in {".", ".."} or p.endswith((".", " "))
           or RESERVED.fullmatch(p) or any(ord(c) < 32 or ord(c) == 127 for c in p)
           for p in parts):
        raise ValueError("unsafe artifact member path")
    if PurePosixPath(name).is_absolute():
        raise ValueError("absolute artifact member path")
    return tuple(parts)


def plain_node(path, directory=False):
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)):
        raise ValueError("artifact path is a link or special node")


def contained_directory(path, boundary):
    boundary = boundary.resolve(strict=True)
    value = Path(os.path.abspath(path))
    try:
        relative = value.relative_to(boundary)
    except ValueError as error:
        raise ValueError("raw artifact staging is outside RUNNER_TEMP") from error
    if not relative.parts:
        raise ValueError("raw artifact staging must be a dedicated directory")
    current = boundary
    for part in relative.parts:
        current /= part
        plain_node(current, directory=True)
    return value


def raw_archives(raw, artifact):
    """Return (archive, expected shard) without assuming an archive basename."""
    children = sorted(raw.iterdir())
    if not children:
        raise ValueError("no authenticated raw artifact archives")
    if artifact != "backend-test-results-*":
        if len(children) != 1:
            raise ValueError("named artifact must contain one raw archive")
        plain_node(children[0])
        safe_parts(children[0].name)
        return [(children[0], None)]
    if len(children) == 1 and children[0].is_file() and not children[0].is_symlink():
        # The SDK elides the artifact-name directory for exactly one match.
        safe_parts(children[0].name)
        return [(children[0], None)]
    result = []
    for child in children:
        plain_node(child, directory=True)
        match = SHARD_NAME.fullmatch(child.name)
        if not match:
            raise ValueError("unexpected raw report artifact name")
        entries = list(child.iterdir())
        if len(entries) != 1:
            raise ValueError("report artifact must contain one raw archive")
        plain_node(entries[0])
        safe_parts(entries[0].name)
        result.append((entries[0], match[1]))
    return result


def extract_artifacts(raw, artifact, *, workspace=ROOT, runner_temp=None):
    if artifact not in DESTINATIONS:
        raise ValueError("unexpected Quality artifact selector")
    if runner_temp is None:
        runner_temp = os.environ.get("RUNNER_TEMP")
    if not runner_temp:
        raise ValueError("RUNNER_TEMP is required")
    raw = contained_directory(Path(raw), Path(runner_temp))
    workspace = Path(workspace).resolve(strict=True)
    server = workspace / "server"
    plain_node(server, directory=True)
    destination = server / DESTINATIONS[artifact]
    if destination.exists() or destination.is_symlink():
        plain_node(destination, directory=True)
        if any(destination.iterdir()):
            raise ValueError("artifact destination is already nonempty")
    archives = raw_archives(raw, artifact)
    known = {}
    members = []
    total = 0
    report_shards = set()
    # Validate every central-directory entry before creating an extraction tree.
    for archive_path, expected_shard in archives:
        if archive_path.stat().st_size > MAX_ARCHIVE_BYTES:
            raise ValueError("artifact archive exceeds the size limit")
        archive_shards = set()
        with zipfile.ZipFile(archive_path) as archive:
            infos = archive.infolist()
            if not infos:
                raise ValueError("empty artifact ZIP")
            for info in infos:
                if len(members) >= MAX_MEMBERS:
                    raise ValueError("artifact member count exceeds the limit")
                directory = info.is_dir()
                name = info.filename[:-1] if directory else info.filename
                if info.orig_filename != info.filename:
                    raise ValueError("artifact member name was truncated")
                parts = safe_parts(name)
                kind = stat.S_IFMT(info.external_attr >> 16)
                if kind not in {0, stat.S_IFREG, stat.S_IFDIR} or (
                    directory and kind == stat.S_IFREG
                ) or (not directory and kind == stat.S_IFDIR) or info.flag_bits & 1:
                    raise ValueError("artifact member is encrypted, a link or special node")
                if info.file_size > MAX_MEMBER_BYTES or directory and info.file_size:
                    raise ValueError("artifact member exceeds the size limit")
                total += info.file_size
                if total > MAX_TOTAL_BYTES:
                    raise ValueError("artifact expansion exceeds the size limit")
                key = "/".join(parts).casefold()
                if key in known:
                    raise ValueError("duplicate artifact member or merged overwrite")
                known[key] = directory
                if artifact == "backend-test-results-*":
                    if parts[0] not in SHARD_DIRECTORIES or (
                        len(parts) == 1 and not directory
                    ):
                        raise ValueError("unexpected report member ownership")
                    archive_shards.add(parts[0].removeprefix("shard-"))
                members.append((archive_path, info, parts, directory))
        if artifact == "backend-test-results-*":
            if len(archive_shards) != 1 or (
                expected_shard is not None and archive_shards != {expected_shard}
            ) or report_shards & archive_shards:
                raise ValueError("report archive belongs to another or duplicate shard")
            report_shards |= archive_shards
    for key in known:
        pieces = key.split("/")
        if any(known.get("/".join(pieces[:i])) is False for i in range(1, len(pieces))):
            raise ValueError("artifact file is used as a parent directory")
    required = {"backend-test-plan": "plan.json", "backend-unfiltered-reference": "baseline-plan.json"}
    if artifact in required and known.get(required[artifact]) is not False:
        raise ValueError("artifact is missing its required plan")
    # CRC/decompression failures only affect this new private tree. Publish after
    # every member has been read and checked; existing/source files are never used.
    with tempfile.TemporaryDirectory(prefix=".quality-artifact-", dir=server) as staging_name:
        staging = Path(staging_name)
        opened = {}
        try:
            for archive_path, info, parts, directory in members:
                target = staging.joinpath(*parts)
                if directory:
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                if archive_path not in opened:
                    opened[archive_path] = zipfile.ZipFile(archive_path)
                copied = 0
                with opened[archive_path].open(info) as reader, target.open("xb") as writer:
                    while chunk := reader.read(1024 * 1024):
                        copied += len(chunk)
                        if copied > info.file_size:
                            raise ValueError("artifact member expanded beyond its declared size")
                        writer.write(chunk)
                if copied != info.file_size:
                    raise ValueError("artifact member size differs")
            # Recheck before promotion, including a newly introduced symlink.
            plain_node(server, directory=True)
            if destination.exists() or destination.is_symlink():
                plain_node(destination, directory=True)
                destination.rmdir()  # Only an empty destination may be replaced.
            os.replace(staging, destination)
        finally:
            for archive in opened.values():
                archive.close()
    return {"archives": len(archives), "files": sum(not row[3] for row in members), "bytes": total}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", required=True)
    parser.add_argument("--artifact", required=True, choices=DESTINATIONS)
    args = parser.parse_args()
    try:
        result = extract_artifacts(args.raw, args.artifact)
    except (OSError, ValueError, zipfile.BadZipFile, NotImplementedError) as error:
        parser.exit(1, f"Authenticated artifact extraction failed: {error}\n")
    print(f"Safely extracted {result['archives']} authenticated archive(s), {result['files']} files")


if __name__ == "__main__":
    main()
