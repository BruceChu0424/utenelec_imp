"""Install Flutter's fixed Linux NDK after checking Google's archive size/hash and ZIP CRC.

Gradle's implicit installer did not retain enough evidence after an invalid ZIP.
This step records HTTP/file diagnostics before extraction and never replaces an
existing NDK directory or changes the requested version.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile


VERSION = "28.2.13676358"
ARCHIVE_ROOT = "android-ndk-r28c"
URL = "https://dl.google.com/android/repository/android-ndk-r28c-linux.zip"
SIZE = 722261334
SHA1 = "a7b54a5de87fecd125a17d54f73c446199e72a64"
# Google SDK repository metadata and Android's official older-download page both
# publish this size and SHA-1. SHA-256 is also recorded for the actual download.
METADATA = "https://dl.google.com/android/repository/repository2-3.xml"


def file_digest(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_archive(path: Path, size: int = SIZE, sha1: str = SHA1) -> dict:
    actual_size = path.stat().st_size
    if actual_size != size or file_digest(path, "sha1") != sha1:
        raise ValueError("NDK archive differs from Google's pinned size/checksum")
    with zipfile.ZipFile(path) as archive:
        seen = set()
        expanded = 0
        for entry in archive.infolist():
            name = PurePosixPath(entry.filename)
            if (name.is_absolute() or ".." in name.parts or "\\" in entry.filename
                    or not name.parts or name.parts[0] != ARCHIVE_ROOT or entry.filename in seen
                    or entry.flag_bits & 1):
                raise ValueError("Unexpected NDK archive member")
            seen.add(entry.filename)
            expanded += entry.file_size
        broken = archive.testzip()
        if broken is not None:
            raise ValueError("NDK ZIP CRC verification failed")
    return {"archiveBytes": actual_size, "archiveSha1": sha1,
            "archiveSha256": file_digest(path, "sha256"), "expandedBytes": expanded,
            "entries": len(seen), "zipCrcVerified": True}


def verify_installation(path: Path) -> None:
    properties = (path / "source.properties").read_text(encoding="utf-8")
    if re.findall(r"(?m)^Pkg\.Revision\s*=\s*(\S+)\s*$", properties) != [VERSION]:
        raise ValueError("Installed NDK source.properties version differs")
    for relative in ("ndk-build", "build/cmake/android.toolchain.cmake",
                     "toolchains/llvm/prebuilt/linux-x86_64/bin/clang"):
        if not (path / relative).is_file():
            raise ValueError("Installed NDK is missing a required build tool")


def prepare(sdk: Path, output: Path, receipt: dict) -> None:
    if sys.platform != "linux" or os.uname().machine != "x86_64":
        raise ValueError("This fixed distribution is for the Linux x86_64 CI runner")
    sdk, output = sdk.resolve(strict=True), output.resolve()
    target = sdk / "ndk" / VERSION
    output.mkdir(parents=True, exist_ok=True)
    receipt.update(version=VERSION, sdkRoot=str(sdk), source=URL,
                   officialMetadata=METADATA, expectedBytes=SIZE, expectedSha1=SHA1,
                   freeSdkBytes=shutil.disk_usage(sdk).free)
    if target.exists():
        verify_installation(target)
        subprocess.run([str(target / "toolchains/llvm/prebuilt/linux-x86_64/bin/clang"), "--version"], check=True)
        receipt["state"] = "EXISTING_VERSION_VERIFIED"
        return
    archive = output / "android-ndk-r28c-linux.zip"
    if not archive.exists():
        request = urllib.request.Request(URL, headers={"Cache-Control": "no-cache", "Accept-Encoding": "identity"})
        with urllib.request.urlopen(request, timeout=60) as response, archive.open("xb") as stream:
            receipt.update(httpStatus=response.status, contentType=response.headers.get("Content-Type"),
                           contentLength=response.headers.get("Content-Length"))
            if response.status != 200:
                raise ValueError("NDK download was not a complete HTTP 200 response")
            received = 0
            while chunk := response.read(1024 * 1024):
                received += len(chunk)
                if received > SIZE:
                    raise ValueError("NDK response exceeded the official archive size")
                stream.write(chunk)
    receipt.update(downloadedBytes=archive.stat().st_size, downloadedSha256=file_digest(archive, "sha256"))
    with archive.open("rb") as stream:
        receipt["responsePrefixHex"] = stream.read(32).hex()
    receipt.update(verify_archive(archive))
    if shutil.disk_usage(sdk).free < receipt["expandedBytes"] + 512 * 1024 * 1024:
        raise ValueError("Insufficient measured space for the verified expanded NDK")
    target.parent.mkdir(parents=True, exist_ok=True)
    # Stage on the SDK volume so the final directory rename is atomic even if
    # RUNNER_TEMP lives on another mounted disk.
    staging = Path(tempfile.mkdtemp(prefix=".uten-ndk-stage-", dir=target.parent))
    receipt["stagingPath"] = str(staging)
    # The authenticated official ZIP contains Unix executable bits and internal
    # symlinks; native unzip preserves both, unlike zipfile.extractall.
    subprocess.run(["unzip", "-q", str(archive), "-d", str(staging)], check=True)
    unpacked = staging / ARCHIVE_ROOT
    verify_installation(unpacked)
    if target.exists():
        raise ValueError("NDK target appeared during preparation; refusing replacement")
    unpacked.rename(target)
    staging.rmdir()
    subprocess.run([str(target / "toolchains/llvm/prebuilt/linux-x86_64/bin/clang"), "--version"], check=True)
    receipt["state"] = "OFFICIAL_ARCHIVE_VERIFIED_INSTALLED"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    receipt = {"state": "REJECTED"}
    try:
        prepare(args.sdk_root, args.output_dir, receipt)
    except (OSError, ValueError, zipfile.BadZipFile, subprocess.SubprocessError) as failure:
        receipt["failureType"] = type(failure).__name__
        receipt["failure"] = str(failure)[:600]
        print("::error::The fixed Android NDK was not prepared; inspect the retained HTTP/hash/ZIP receipt.")
        return 1
    finally:
        archive = args.output_dir / "android-ndk-r28c-linux.zip"
        if archive.is_file():
            receipt["downloadedBytes"] = archive.stat().st_size
            receipt["downloadedSha256"] = file_digest(archive, "sha256")
            with archive.open("rb") as stream:
                receipt["responsePrefixHex"] = stream.read(32).hex()
        (args.output_dir / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(receipt))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
