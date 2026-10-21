"""Prepare a managed CPython 3.12 environment from verified local wheels only."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import runpy
import stat
import subprocess
import sys
import tempfile
import time
import venv
from contextlib import contextmanager
from pathlib import Path

sys.dont_write_bytecode = True


def linked(path: Path) -> bool:
    return path.is_symlink() or path.is_junction()


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


@contextmanager
def install_lock(path: Path):
    if (any(linked(item) for item in (path, *path.parents))
            or path.exists() and (not path.is_file() or path.stat().st_nlink != 1)):
        raise ValueError("runtime installation lock is unsafe")
    with path.open("a+b") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("runtime installation lock is unsafe")
        if handle.tell() == 0:
            handle.write(b"0")
            handle.flush()
        deadline = time.monotonic() + 180
        while True:
            try:
                handle.seek(0)
                if os.name == "nt":
                    import msvcrt
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.lockf(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB, 1, 0, os.SEEK_SET)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise ValueError("runtime installation is busy")
                time.sleep(.2)
        try:
            yield
        finally:
            handle.seek(0)
            if os.name == "nt":
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.lockf(handle.fileno(), fcntl.LOCK_UN, 1, 0, os.SEEK_SET)


def validate(payload: Path) -> dict:
    # Updater signature verification authenticates this helper, verifier and
    # release.json before launch. Reuse that same strict component protocol;
    # never accept the older independently editable runtime-manifest format.
    if (not payload.is_absolute() or not payload.is_dir()
            or any(linked(path) for path in (payload, *payload.parents))):
        raise ValueError("payload must be a real absolute directory")
    verifier = payload / "verify_payload.py"
    if not verifier.is_file() or linked(verifier) or verifier.stat().st_nlink != 1:
        raise ValueError("strict payload verifier is missing or linked")
    strict = runpy.run_path(str(verifier))
    target = "windows-x86_64" if os.name == "nt" else "linux-x86_64"
    strict["require_build_host"](target)
    manifest_path = payload / "release.json"
    if linked(manifest_path) or not manifest_path.is_file() or manifest_path.stat().st_nlink != 1:
        raise ValueError("component manifest must be an independent regular file")
    manifest = strict["read_json"](manifest_path)
    if not isinstance(manifest, dict):
        raise ValueError("component manifest must be an object")
    strict["verify"](payload, manifest.get("version"), manifest.get("commit"), target)
    versions = re.findall(r'^__version__ = "([A-Za-z0-9._]+)"$',
                          (payload / "forecast_worker/__init__.py").read_text(encoding="utf-8"), re.MULTILINE)
    if len(versions) != 1:
        raise ValueError("verified worker version is missing")
    return {"schemaVersion": 1, "platform": target, "workerVersion": versions[0],
            "lockDigest": digest(payload / "runtime-requirements.txt"), "commit": manifest["commit"]}


def child_environment() -> dict:
    keep = ("SYSTEMROOT", "WINDIR", "COMSPEC", "TEMP", "TMP", "HOME", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR")
    result = {key: os.environ[key] for key in keep if key in os.environ}
    if os.name == "nt":
        # Windows PowerShell/.NET requires this OS token even in an otherwise
        # cleared environment; leaving it absent creates literal %SystemDrive%
        # cache paths. Derive it from the fixed Windows directory, not app env.
        system_root = result.get("SYSTEMROOT") or result.get("WINDIR") or r"C:\Windows"
        drive = Path(system_root).drive
        if re.fullmatch(r"[A-Za-z]:", drive):
            result["SystemDrive"] = drive
    result.update(PIP_CONFIG_FILE=os.devnull, PIP_NO_INPUT="1", PIP_DISABLE_PIP_VERSION_CHECK="1",
                  PYTHONDONTWRITEBYTECODE="1", OMP_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1", MKL_NUM_THREADS="1")
    return result


def atomic_marker(path: Path, value: dict) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run(command: list[str], timeout: int = 180) -> None:
    completed = subprocess.run(command, env=child_environment(), capture_output=True, timeout=timeout)
    if completed.returncode:
        # Never return inherited environment, pip exceptions, paths or unbounded diagnostics.
        raise ValueError("offline runtime validation or installation failed")


def prepare(payload: Path, cache: Path) -> dict:
    payload = payload.absolute()
    manifest = validate(payload)
    if (not cache.is_absolute() or any(linked(path) for path in (cache, *cache.parents))
            or cache.resolve().is_relative_to(payload.resolve())):
        raise ValueError("cache must be an absolute private directory")
    cache.mkdir(parents=True, exist_ok=True)
    # Windows packaged hosts may virtualize LocalAppData without a symlink.
    # Bind the returned executable to the actual physical private directory.
    cache = cache.resolve(strict=True)
    # Keep extension DLL paths below Windows MAX_PATH even under MSIX LocalAppData.
    # The full platform/digest identity is still checked in the readiness marker.
    key = ("w-" if os.name == "nt" else "l-") + manifest["lockDigest"][:24]
    root = cache / key
    with install_lock(cache / (key + ".lock")):
        new_root = not root.exists()
        root.mkdir(exist_ok=True)
        if linked(root) or linked(root / "venv"):
            raise ValueError("runtime directory links are forbidden")
        python = root / "venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
        marker = root / "ready.json"
        if marker.is_symlink() or marker.exists() and marker.stat().st_size > 8192:
            raise ValueError("runtime marker is unsafe")
        ready = json.loads(marker.read_text(encoding="utf-8")) if marker.exists() else None
        identity = {"schemaVersion": 1, "lockDigest": manifest["lockDigest"], "platform": manifest["platform"]}
        owner_marker = root / "managed.json"
        if owner_marker.is_symlink():
            raise ValueError("runtime ownership marker is unsafe")
        if new_root or not any(root.iterdir()):
            atomic_marker(owner_marker, identity)
        if ready is None:
            # An interrupted installation is repaired only inside this exact managed cache key.
            if not owner_marker.exists() or json.loads(owner_marker.read_text(encoding="utf-8")) != identity:
                raise ValueError("unrecognized incomplete runtime cache")
            target = root / "venv"
            if target.resolve().parent != root.resolve():
                raise ValueError("runtime repair target escaped its managed key")
            venv.EnvBuilder(with_pip=True, clear=True, symlinks=False).create(target)
            run([str(python), "-I", "-m", "pip", "install", "--no-index", "--no-deps", "--require-hashes",
                 "--only-binary=:all:", "--find-links", str(payload / "wheelhouse"), "-r", str(payload / "runtime-requirements.txt")])
        elif ready != identity:
            raise ValueError("runtime readiness marker differs")
        run([str(python), "-I", "-m", "pip", "check"])
        run([str(python), "-I", "-c", "import statsforecast,numpy,pandas; from statsforecast.models import Naive; assert statsforecast.__version__ == '2.1.1'; Naive().forecast(y=numpy.array([1.,2.,3.]),h=2)"])
        if validate(payload) != manifest:
            raise ValueError("payload changed during runtime preparation")
        atomic_marker(owner_marker, identity)
        atomic_marker(marker, identity)
        return {"schemaVersion": 1, "state": "READY", "platform": manifest["platform"],
                "pythonExecutable": str(python), "workerScript": str(payload / "worker.py"),
                "catalog": str(payload / "material-benchmarks.json"), "lockDigest": manifest["lockDigest"],
                "workerVersion": manifest["workerVersion"]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload", required=True, type=Path)
    parser.add_argument("--cache", required=True, type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.payload, args.cache)))
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print('{"schemaVersion":1,"state":"ERROR","errorCode":"PREPARATION_FAILED"}')
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
