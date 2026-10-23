#!/usr/bin/env python3
"""Install a pinned, upstream-signed WireGuard tools release when the OS has no package.

Does not install dependencies, change firewall/routes, generate tunnel keys, or start services.
Requires root, Python 3.11+, gpg, gcc and make. Prefer the OS package when available.
The pinned signing fingerprint is published in WireGuard's signed release announcements:
https://lists.zx2c4.com/pipermail/wireguard/2019-December/004787.html
"""
from __future__ import annotations

import hashlib
import json
import lzma
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

VERSION = "1.0.20260223"
SIGNER = "AB9942E6D4A4CFC3412620A749FC7012A5DE03AE"
SOURCE_URL = f"https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-{VERSION}.tar.xz"
SIGNATURE_URL = f"https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-{VERSION}.tar.asc"
KEY_URL = f"https://keys.openpgp.org/vks/v1/by-fingerprint/{SIGNER}"
WORK = Path("/usr/local/src/uten-wireguard-tools") / VERSION
RECEIPT = Path("/usr/local/lib/uten-remote/wireguard-tools-install.json")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fetch(url: str, target: Path, maximum: int) -> None:
    with urllib.request.urlopen(url, timeout=60) as response:
        if response.status != 200:
            raise RuntimeError("upstream download did not succeed")
        data = response.read(maximum + 1)
    if not data or len(data) > maximum:
        raise RuntimeError("upstream download size is invalid")
    target.write_bytes(data)


def run(args: list[str], log: Path) -> str:
    result = subprocess.run(args, capture_output=True, text=True, timeout=180)
    with log.open("a", encoding="utf-8") as output:
        output.write(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("upstream verification/build failed; protected build log retained")
    return result.stdout


def require_safe_tree_parent(path: Path) -> None:
    for parent in (path, *path.parents):
        if not parent.exists():
            continue
        info = parent.lstat()
        if parent.is_symlink() or info.st_uid != 0 or info.st_mode & 0o022:
            raise RuntimeError("installation parent must be root-owned without writable aliases")


def verify_installed_receipt() -> dict | None:
    if not RECEIPT.exists():
        return None
    require_safe_tree_parent(RECEIPT)
    receipt = json.loads(RECEIPT.read_text())
    if receipt.get("version") != VERSION or receipt.get("signerFingerprint") != SIGNER:
        raise RuntimeError("existing install receipt differs; explicit operator review required")
    for name, expected in receipt.get("installedFiles", {}).items():
        path = Path(name)
        if not path.is_file() or path.is_symlink() or digest(path) != expected:
            raise RuntimeError("installed WireGuard tools no longer match the verified receipt")
    if not receipt.get("installedFiles"):
        raise RuntimeError("existing install receipt has no verified files")
    return receipt


def main() -> int:
    try:
        if os.geteuid() != 0:
            raise RuntimeError("requires root")
        os.umask(0o077)
        existing = verify_installed_receipt()
        if existing:
            print(json.dumps({"version": VERSION, "signatureVerified": True, "alreadyInstalled": True,
                              "serviceStarted": False}))
            return 0
        for target in (Path("/usr/bin/wg"), Path("/usr/bin/wg-quick"),
                       Path("/usr/lib/systemd/system/wg-quick@.service")):
            if target.exists() or target.is_symlink():
                raise RuntimeError("existing WireGuard tools must be managed by their current installer")
        for executable in ("gpg", "gcc", "make"):
            if not shutil.which(executable):
                raise RuntimeError("missing approved build dependency: " + executable)
        require_safe_tree_parent(WORK.parent)
        WORK.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        WORK.mkdir(mode=0o700, exist_ok=False)
        log = WORK / "verification-and-build.log"
        archive, signature, key = WORK / "source.tar.xz", WORK / "source.tar.asc", WORK / "signer.asc"
        fetch(SOURCE_URL, archive, 2 * 1024 * 1024)
        fetch(SIGNATURE_URL, signature, 64 * 1024)
        fetch(KEY_URL, key, 128 * 1024)
        home = WORK / "gnupg"
        home.mkdir(mode=0o700)
        gpg = ["gpg", "--batch", "--no-options", "--homedir", str(home)]
        inspection = run(gpg + ["--with-colons", "--import-options", "show-only", "--import", str(key)], log)
        fingerprints = [line.split(":")[9] for line in inspection.splitlines() if line.startswith("fpr:")]
        if not fingerprints or fingerprints[0] != SIGNER:
            raise RuntimeError("downloaded signing key fingerprint differs from the pinned upstream identity")
        run(gpg + ["--import", str(key)], log)
        tar = WORK / "source.tar"
        tar.write_bytes(lzma.decompress(archive.read_bytes(), memlimit=64 * 1024 * 1024))
        verified = run(gpg + ["--status-fd", "1", "--verify", str(signature), str(tar)], log)
        if not any(line.startswith("[GNUPG:] VALIDSIG " + SIGNER + " ") for line in verified.splitlines()):
            raise RuntimeError("archive signature did not validate against the pinned upstream identity")
        with tarfile.open(tar) as content:
            content.extractall(WORK, filter="data")
        source = WORK / ("wireguard-tools-" + VERSION) / "src"
        run(["make", "-C", str(source), "-j2"], log)
        built_version = run([str(source / "wg"), "--version"], log).strip()
        if not built_version.startswith("wireguard-tools v" + VERSION):
            raise RuntimeError("built binary version differs")
        stage = WORK / "install-root"
        run(["make", "-C", str(source), "install", "DESTDIR=" + str(stage), "PREFIX=/usr",
             "SYSTEMDUNITDIR=/usr/lib/systemd/system", "WITH_WGQUICK=yes", "WITH_SYSTEMDUNITS=yes"], log)
        files = {}
        for relative in ("usr/bin/wg", "usr/bin/wg-quick", "usr/lib/systemd/system/wg-quick@.service"):
            origin = stage / relative
            if not origin.is_file() or origin.is_symlink():
                raise RuntimeError("upstream install staging is incomplete")
            target = Path("/") / relative
            require_safe_tree_parent(target.parent)
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(target.name + ".uten-install")
            with temporary.open("xb") as output:
                output.write(origin.read_bytes())
            temporary.chmod(0o755 if relative.startswith("usr/bin/") else 0o644)
            temporary.replace(target)
            files[str(target)] = digest(target)
        require_safe_tree_parent(RECEIPT.parent)
        RECEIPT.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        receipt = {"version": VERSION, "sourceUrl": SOURCE_URL, "sourceSha256": digest(archive),
                   "signerFingerprint": SIGNER, "signatureVerified": True, "installedFiles": files,
                   "serviceStarted": False}
        RECEIPT.write_text(json.dumps(receipt, indent=2) + "\n")
        RECEIPT.chmod(0o600)
        print(json.dumps({"version": VERSION, "signatureVerified": True, "sourceSha256": receipt["sourceSha256"],
                          "installedFileCount": len(files), "serviceStarted": False}))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as failure:
        print("WireGuard tools installation stopped: " + str(failure), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
