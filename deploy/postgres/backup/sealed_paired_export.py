#!/usr/bin/python3
"""Export one verified paired set as ciphertext; no upload, retention or restore.

The recipient public key is read from stdin and pinned by its full fingerprint.
No decryption key, passphrase, production secret, or GPG stderr is printed.
Only a complete directory containing archive.gpg and receipt.json is published.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

if os.name == "posix":
    import fcntl

SET_ID = re.compile(r"[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}\Z")
FINGERPRINT = re.compile(r"(?:[A-F0-9]{40}|[A-F0-9]{64})\Z")
GPG = "/usr/bin/gpg"
FORMAT = "uten-sealed-paired-v1"
RECOVERY_ALLOWLIST = (
    "etc/uten-imp/server.env",
    "etc/uten-imp/migrator.env",
    "etc/uten-imp/paired-internal-backup.json",
    "etc/pgbackrest.conf",
    "etc/pgbackrest/conf.d/20-uten-imp-repo2.conf",
)
REQUIRED_RECOVERY = "etc/uten-imp/server.env"
HELPERS = ("paired_internal_backup.py", "market_state_backup.py", "client_release_state_backup.py")
MAX_FILES = 200000
MAX_KEY = 65536
CHUNK = 1024 * 1024


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(CHUNK):
            value.update(block)
    return value.hexdigest()


def safe_path(path: Path, *, directory=False, private=False) -> os.stat_result:
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("Expected a normalized absolute path")
    for item in (path, *path.parents):
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("Symbolic links are forbidden")
        if item != path and (info.st_uid not in (0, os.geteuid()) or
                info.st_mode & 0o022 and not (info.st_uid == 0 and info.st_mode & stat.S_ISVTX)):
            raise ValueError("Unsafe path ancestor")
    info = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(info.st_mode) or info.st_uid not in (0, os.geteuid()):
        raise ValueError("Unsafe file identity")
    if info.st_mode & (0o077 if private else 0o022):
        raise ValueError("Unsafe file permissions")
    return info


def load_paired(helper: Path):
    safe_path(helper)
    if helper.name != "paired_internal_backup.py":
        raise ValueError("Unexpected verification helper")
    spec = importlib.util.spec_from_file_location("uten_sealed_paired_verifier", helper)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@contextmanager
def shared_backup_lock(root: Path, timeout=30):
    safe_path(root, directory=True)
    path = root / ".backup.lock"
    before = safe_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        if not os.path.samestat(before, os.fstat(fd)):
            raise ValueError("Backup barrier changed")
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Backup barrier is busy") from None
                time.sleep(.05)
        yield
    finally:
        os.close(fd)


def _read_json(path: Path, maximum=65536):
    safe_path(path)
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("Oversized metadata")
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("Duplicate metadata key")
            value[key] = item
        return value
    return json.loads(data, object_pairs_hook=unique)


def _relative(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or any(p in ("", ".", "..") for p in value.split("/")):
        raise ValueError("Invalid archive relative path")
    return path


def remote_catalog():
    spec=importlib.util.spec_from_file_location('uten_remote_recovery_catalog',
        Path(__file__).with_name('remote_recovery_catalog.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def collect_files(root: Path, paired, helper: Path, recovery_root: Path, recovery_names, *, include_remote_recovery=False):
    latest = _read_json(root / "latest-success.json")
    name = latest.get("set_id")
    if not isinstance(name, str) or not SET_ID.fullmatch(name):
        raise ValueError("Invalid successful set identity")
    directory = root / name
    safe_path(directory, directory=True)
    digest = sha256(directory / "manifest.json")
    if digest != latest.get("manifest_sha256"):
        raise ValueError("Successful set manifest binding failed")
    summary = paired.verify_set(directory)
    if summary.get("set_id") != name:
        raise ValueError("Set identity disagrees with its manifest")
    selected = {"manifest.json", "database.dump", "objects.jsonl"}
    if summary["format"] == "uten-paired-internal-v2":
        selected.add("references.jsonl")
    with (directory / "objects.jsonl").open(encoding="utf-8") as stream:
        for line in stream:
            row = json.loads(line)
            relative = _relative(row["relative_path"])
            provider = row["storage_provider"]
            if provider not in ("internal", "local"):
                raise ValueError("Unrecognized media provider")
            prefix = "media/final" if provider == "internal" else "media/local/final"
            selected.add(f"{prefix}/{relative}")
            if len(selected) > MAX_FILES:
                raise ValueError("Archive inventory is too large")
    # Both optional subtree verifiers enforce their complete manifest inventories.
    for field, subtree in (("market_state", "market-state"),
                           ("client_release_state", "client-release-state")):
        if summary.get(field):
            for parent, dirs, files in os.walk(directory / subtree, followlinks=False):
                safe_path(Path(parent), directory=True)
                for child in dirs:
                    safe_path(Path(parent) / child, directory=True)
                for child in files:
                    selected.add((Path(parent) / child).relative_to(directory).as_posix())
                    if len(selected) > MAX_FILES:
                        raise ValueError("Archive inventory is too large")
    result = [(directory / item, f"paired/{name}/{item}") for item in sorted(selected)]
    names = tuple(recovery_names)
    if len(names) != len(set(names)) or not set(names).issubset(RECOVERY_ALLOWLIST):
        raise ValueError("Recovery inputs must use the exact allowlist")
    if REQUIRED_RECOVERY not in names:
        raise ValueError("The application crypto recovery configuration is required")
    for item in names:
        path = recovery_root / item
        details = safe_path(path)
        # The application legitimately reads root:application 0640 server.env.
        if details.st_mode & 0o037 or details.st_nlink != 1 or details.st_size > 4 * 1024 * 1024:
            raise ValueError("Unsafe crypto recovery input")
        result.append((path, f"recovery/{item}"))
    if include_remote_recovery:
        remote_entries,metadata=remote_catalog().collect(recovery_root,safe_path)
        result.extend(remote_entries)
        summary={**summary,'remote_recovery':metadata}
    for name in HELPERS:
        path = helper.with_name(name)
        if path.exists():
            result.append((path, f"restore-tools/{name}"))
    for path, _ in result:
        safe_path(path)
    return summary["set_id"], digest, result, summary


def check_recipient(public_key: bytes, fingerprint: str, homedir: Path):
    if not FINGERPRINT.fullmatch(fingerprint) or not public_key or len(public_key) > MAX_KEY:
        raise ValueError("A public key and its full pinned fingerprint are required")
    if b"PRIVATE KEY" in public_key or b"SECRET KEY" in public_key:
        raise ValueError("Secret keys cannot be used as recipients")
    process = subprocess.run([GPG, "--no-options", "--batch", "--no-tty", "--no-autostart",
        "--homedir", str(homedir), "--with-colons", "--import-options", "show-only",
        "--dry-run", "--import"], input=public_key, capture_output=True, timeout=30,
        env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"})
    if process.returncode:
        raise ValueError("Recipient key inspection failed")
    rows = [line.split(":") for line in process.stdout.decode("utf-8").splitlines()]
    if sum(row[0] == "pub" for row in rows) != 1 or any(row[0] in ("sec", "ssb") for row in rows):
        raise ValueError("Expected exactly one public recipient key")
    primary = next((row[9] for i, row in enumerate(rows) if row[0] == "fpr"
                    and i and rows[i - 1][0] == "pub"), None)
    if primary != fingerprint:
        raise ValueError("Recipient fingerprint mismatch")


def _sync_directory(path: Path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def verify_plaintext_tar(stream, receipt: dict) -> dict:
    """Check a decrypted stream without extracting or returning any secret bytes.

    The caller must also check the decryptor's exit status, including its final
    authentication result, before treating this result as verified.
    """
    if receipt.get("format") != FORMAT or not SET_ID.fullmatch(receipt.get("sourceSetId", "")):
        raise ValueError("Invalid ciphertext receipt")
    expected, observed = {}, set()
    total = 0
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        first = archive.next()
        if first is None or first.name != "export-manifest.json" or not first.isfile() or first.size > 64 * 1024 * 1024:
            raise ValueError("Missing bounded export inventory")
        inventory = json.load(archive.extractfile(first))
        if (inventory.get("format") != FORMAT or inventory.get("sourceSetId") != receipt["sourceSetId"]
                or inventory.get("sourceManifestSha256") != receipt.get("sourceManifestSha256")
                or inventory.get("recipientFingerprint") != receipt.get("recipientFingerprint")
                or inventory.get("cryptoRecoveryIncluded") is not True):
            raise ValueError("Encrypted inventory differs from the external receipt")
        rows = inventory.get("files")
        if not isinstance(rows, list) or not 1 <= len(rows) <= MAX_FILES + 1024:
            raise ValueError("Invalid export inventory size")
        prefix = "paired/" + receipt["sourceSetId"] + "/"
        for row in rows:
            if not isinstance(row, dict) or set(row) != {"path", "size", "sha256"}:
                raise ValueError("Invalid export inventory row")
            name = row["path"]
            _relative(name)
            allowed = name.startswith(prefix) or name.startswith('recovery/') and remote_catalog().allowed(name[9:]) or name in {
                *("recovery/" + item for item in RECOVERY_ALLOWLIST),
                *("restore-tools/" + item for item in HELPERS)}
            if (not allowed or name in expected or type(row["size"]) is not int or row["size"] < 0
                    or not re.fullmatch(r"[a-f0-9]{64}", row["sha256"])):
                raise ValueError("Invalid export inventory binding")
            expected[name] = row
        if inventory.get('scope',{}).get('remoteGatewayRecovery') is not None:
            remote_catalog().validate_metadata(inventory['scope']['remoteGatewayRecovery'],set(expected))
        elif any(name.startswith('recovery/') and remote_catalog().allowed(name[9:]) for name in expected):
            raise ValueError('Remote recovery files lack their complete catalog')
        manifest_name = prefix + "manifest.json"
        if (expected.get(manifest_name, {}).get("sha256") != receipt["sourceManifestSha256"]
                or "recovery/" + REQUIRED_RECOVERY not in expected or prefix + "database.dump" not in expected):
            raise ValueError("Required database/crypto recovery scope is missing")
        for member in archive:
            # tarfile's iterator includes a previously read first member.
            if member is first:
                continue
            row = expected.get(member.name)
            if not member.isfile() or row is None or member.name in observed or member.size != row["size"]:
                raise ValueError("Unexpected decrypted archive member")
            digest = hashlib.sha256()
            with archive.extractfile(member) as original:
                while block := original.read(CHUNK):
                    digest.update(block)
            if digest.hexdigest() != row["sha256"]:
                raise ValueError("Decrypted archive member digest failed")
            observed.add(member.name)
            total += member.size
    if observed != set(expected):
        raise ValueError("Decrypted archive is incomplete")
    return {"state": "DECRYPTED_INVENTORY_VERIFIED", "sourceSetId": receipt["sourceSetId"],
            "filesVerified": len(observed), "plaintextBytesVerified": total,
            "cryptoRecoveryIncluded": True, "databaseRestored": False}


def export(root: Path, output: Path, public_key: bytes, fingerprint: str,
           recovery_names, *, helper: Path | None = None, recovery_root=Path("/"), lock_timeout=30,
           include_remote_recovery=False):
    if os.name != "posix" or not hasattr(os, "memfd_create"):
        raise ValueError("The exporter requires Linux memfd and file locking")
    safe_path(output, directory=True, private=True)
    if output == root or root in output.parents:
        raise ValueError("Export output cannot overlap the paired backup root")
    safe_path(Path(GPG))
    helper = helper or Path(__file__).with_name("paired_internal_backup.py")
    paired = load_paired(helper)
    now = datetime.now(timezone.utc)
    export_id = "sealed-" + now.strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]
    stage = output / (".incomplete-" + export_id)
    final = output / export_id
    stage.mkdir(mode=0o700)
    key_fd = None
    process = None
    try:
        home = stage / ".gnupg"
        home.mkdir(mode=0o700)
        check_recipient(public_key, fingerprint, home)
        key_fd = os.memfd_create("uten-export-recipient", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
        os.write(key_fd, public_key)
        os.lseek(key_fd, 0, os.SEEK_SET)
        fcntl.fcntl(key_fd, fcntl.F_ADD_SEALS,
                    fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL)
        archive = stage / "archive.gpg"
        with shared_backup_lock(root, timeout=lock_timeout):
            set_id, manifest_digest, entries, summary = collect_files(root, paired, helper,
                                                                     recovery_root, recovery_names,
                                                                     include_remote_recovery=include_remote_recovery)
            total = sum(path.stat().st_size for path, _ in entries)
            if shutil.disk_usage(output).free < total * 1.1 + 16 * 1024 * 1024:
                raise OSError("Insufficient space for encrypted export")
            inventory = [{"path": name, "size": path.stat().st_size, "sha256": sha256(path)}
                         for path, name in entries]
            recovery_manifest = json.dumps({"format": FORMAT, "sourceSetId": set_id,
                "sourceManifestSha256": manifest_digest, "recipientFingerprint": fingerprint,
                "files": inventory, "cryptoRecoveryIncluded": True,
                "scope": {"marketStateIncluded": bool(summary.get("market_state")),
                          "clientReleaseStateIncluded": bool(summary.get("client_release_state")),
                          "remoteGatewayRecovery": summary.get('remote_recovery')}},
                sort_keys=True, separators=(",", ":")).encode()
            with archive.open("xb") as encrypted, tempfile.TemporaryFile() as error_log:
                process = subprocess.Popen([GPG, "--no-options", "--batch", "--no-tty", "--no-autostart",
                    "--homedir", str(home), "--trust-model", "always", "--compress-algo", "none",
                    "--cipher-algo", "AES256", "--recipient-file", f"/proc/self/fd/{key_fd}",
                    "--output", "-", "--encrypt"], stdin=subprocess.PIPE, stdout=encrypted,
                    stderr=error_log, pass_fds=(key_fd,),
                    env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"})
                with tarfile.open(fileobj=process.stdin, mode="w|", format=tarfile.PAX_FORMAT) as tar:
                    record = tarfile.TarInfo("export-manifest.json")
                    record.size, record.mode = len(recovery_manifest), 0o600
                    tar.addfile(record, io.BytesIO(recovery_manifest))
                    for (path, name), expected in zip(entries, inventory):
                        before = safe_path(path)
                        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                        with os.fdopen(fd, "rb") as plain:
                            opened = os.fstat(plain.fileno())
                            if not os.path.samestat(before, opened) or opened.st_size != expected["size"]:
                                raise ValueError("Export input changed")
                            info = tarfile.TarInfo(name)
                            info.size, info.mode, info.mtime = opened.st_size, 0o600, int(opened.st_mtime)
                            tar.addfile(info, plain)
                            after = os.fstat(plain.fileno())
                            if (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) != (
                                    after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                                raise ValueError("Export input changed during read")
                        if sha256(path) != expected["sha256"]:
                            raise ValueError("Export input digest changed")
                process.stdin.close()
                if process.wait(timeout=120) != 0:
                    raise ValueError("Public-key encryption failed")
                encrypted.flush()
                os.fsync(encrypted.fileno())
            # No producer/retention race occurred while the fixed set was consumed.
            if sha256(root / set_id / "manifest.json") != manifest_digest:
                raise ValueError("Source manifest changed")
        receipt = {"format": FORMAT, "exportId": export_id, "state": "CIPHERTEXT_CREATED",
            "sourceSetId": set_id, "sourceManifestSha256": manifest_digest,
            "recipientFingerprint": fingerprint, "ciphertextFile": "archive.gpg",
            "ciphertextBytes": archive.stat().st_size, "ciphertextSha256": sha256(archive),
            "cryptoRecoveryIncluded": True, "completedAt": datetime.now(timezone.utc).isoformat(),
            "targetCopyVerified": False, "restoreVerified": False,
            "marketStateIncluded": bool(summary.get("market_state")),
            "clientReleaseStateIncluded": bool(summary.get("client_release_state"))}
        with (stage / "receipt.json").open("x", encoding="utf-8") as stream:
            json.dump(receipt, stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        shutil.rmtree(home)
        _sync_directory(stage)
        os.rename(stage, final)
        _sync_directory(output)
        return final, receipt
    except BaseException:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        # This is the exact freshly created private work directory, never a source/retention path.
        if stage.exists():
            shutil.rmtree(stage)
        raise
    finally:
        if key_fd is not None:
            os.close(key_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backup-root", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--recipient-fingerprint", required=True)
    parser.add_argument("--recovery-file", action="append", choices=RECOVERY_ALLOWLIST, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        public_key = sys.stdin.buffer.read(MAX_KEY + 1)
        directory, receipt = export(args.backup_root, args.output_directory, public_key,
                                    args.recipient_fingerprint, args.recovery_file)
        print(json.dumps({"directory": str(directory), **receipt}))
    except Exception as error:
        # No exception messages from GPG, config parsing or secret-bearing inputs cross stdout/stderr.
        print(json.dumps({"state": "FAILED", "errorType": type(error).__name__}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
