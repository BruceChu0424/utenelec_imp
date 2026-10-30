"""One command for the formal Windows client pair (Setup.exe + update ZIP).

Every step that previously depended on the operator copying a long command
correctly is enforced here, closing the incident classes of 2026-10-30:

- version/build come from pubspec.yaml only, so the pair can never disagree
  with the audited release commit (and stray rename-variants cannot appear);
- the working tree must be a clean git commit (the source the server release
  was audited from), unless --allow-dirty records the deviation;
- both approved endpoints are mandatory, must be HTTPS company/cloud entries,
  and are byte-verified inside data/app.so after the build (a formal client
  built without CLOUD_API_BASE_URL can never log in from outside);
- Setup.exe and the update ZIP are produced from one validated payload and
  then replayed against the server's paired_v1 publishing contract locally
  (verify_windows_release) so upload-time rejection cannot happen anymore;
- a delivery receipt with hashes, manifest echo and the exact publish-form
  values is written next to the artifacts.

Usage (formal release, from the repository root):
  python deploy/client/build_windows_release.py \
    --output-dir '<独立输出目录>' \
    --api 'https://<公司域名>/api' --cloud-api 'https://<可信云端域名>/api' \
    --iscc '<已验证的ISCC.exe路径>'

Local-test packages (Profile build, localhost backend) keep using
build_windows_installer.py --local-test directly; this tool refuses them.
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path

from build_windows_installer import build_windows_setup, find_compiler
from package_windows import MANIFEST_NAME
from verify_client_endpoints import missing_endpoints
from verify_windows_release import verify_pair

SCRIPT = Path(__file__).resolve()
REPOSITORY = SCRIPT.parents[2]
PUBSPEC = "pubspec.yaml"
BUNDLE = Path("build/windows/x64/runner/Release")
ENDPOINT_SNAPSHOT = BUNDLE / "data/app.so"


def read_release_version(repository: Path) -> tuple[str, int]:
    """pubspec.yaml is the single source of the display version and build number."""
    text = (repository / PUBSPEC).read_text(encoding="utf-8")
    match = re.search(r"^version:\s*(\d+(?:\.\d+){2})\+(\d+)\s*$", text, re.MULTILINE)
    if match is None:
        raise ValueError(f"{PUBSPEC} has no 'version: X.Y.Z+N' line; bump the release version there first")
    return match.group(1), int(match.group(2))


def formal_endpoints(api: str, cloud_api: str) -> tuple[str, str]:
    """A formal client only ever gets HTTPS company/cloud entries, never localhost."""
    approved = []
    for name, url in (("api", api), ("cloud-api", cloud_api)):
        scheme, _, host = url.partition("://")
        host = host.split("/", 1)[0].split(":", 1)[0].strip("[]").lower()
        if scheme != "https" or not host:
            raise ValueError(f"--{name} must be an HTTPS URL: {url!r}")
        if host in {"localhost", "127.0.0.1", "::1", "0.0.0.0"}:
            raise ValueError(f"--{name} must be the formal company endpoint, not a local test address: {url!r}")
        approved.append(url)
    return approved[0], approved[1]


def audit_repository(repository: Path, *, runner=subprocess.run) -> dict:
    def git(*arguments: str) -> str:
        result = runner(["git", *arguments], cwd=repository, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise ValueError(f"git {' '.join(arguments)} failed: {(result.stderr or '').strip()[:400]}")
        return result.stdout

    commit = git("rev-parse", "HEAD").strip()
    status = git("status", "--porcelain")
    # Porcelain's leading space is significant (staged vs unstaged column).
    changes = [line for line in status.splitlines() if line.strip()]
    if changes and not commit:
        raise ValueError("not inside a git repository")
    return {"commit": commit, "treeClean": not changes, "changes": changes}


def _snapshot_pubspec_lock(repository: Path) -> bytes | None:
    path = repository / "pubspec.lock"
    return path.read_bytes() if path.is_file() else None


def default_flutter_build(repository: Path, *, version: str, build_number: int,
                          api: str, cloud_api: str, runner=subprocess.run,
                          executable: str = "flutter") -> None:
    command = [executable, "build", "windows", "--release",
               f"--build-name={version}", f"--build-number={build_number}",
               f"--dart-define=APP_VERSION={version}",
               f"--dart-define=APP_BUILD_ID={build_number}",
               f"--dart-define=API_BASE_URL={api}",
               f"--dart-define=CLOUD_API_BASE_URL={cloud_api}"]
    result = runner(command, cwd=repository, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        tail = "\n".join((result.stderr or result.stdout or "").splitlines()[-25:])
        raise ValueError(f"flutter build failed (exit {result.returncode}):\n{tail}")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_formal_release(repository: Path, output_dir: Path, *, api: str, cloud_api: str,
                         architecture: str = "x64", iscc: Path | None = None,
                         runner=subprocess.run, allow_dirty: bool = False, skip_build: bool = False,
                         flutter_build=None, package_pair=None) -> dict:
    api, cloud_api = formal_endpoints(api, cloud_api)
    version, build_number = read_release_version(repository)
    audit = audit_repository(repository, runner=runner)
    if not audit["treeClean"] and not allow_dirty:
        raise ValueError("working tree is dirty; commit or stash first, or pass --allow-dirty to record the deviation: "
                         + "; ".join(audit["changes"][:6]))
    bundle = repository / BUNDLE
    if not (bundle / "uten_imp.exe").is_file():
        if skip_build:
            raise ValueError(f"--skip-build was requested but {bundle} has no previously built payload")
        skip_build = False

    lock_before = _snapshot_pubspec_lock(repository)
    lock_note = None
    if skip_build:
        build_step = "reused-existing-bundle"
    else:
        (flutter_build or default_flutter_build)(repository, version=version, build_number=build_number,
                                                 api=api, cloud_api=cloud_api, runner=runner)
        build_step = "executed"
        # CN mirrors rewrite pubspec.lock URL lines on pub get; a build side
        # effect must not leak into an audited tree. Restore only when the
        # lock was pristine before the build; with an intentionally dirty
        # tree keep the operator's bytes and record the change instead.
        lock_after = _snapshot_pubspec_lock(repository)
        if lock_after != lock_before and lock_before is not None:
            if audit["treeClean"]:
                (repository / "pubspec.lock").write_bytes(lock_before)
            else:
                lock_note = "pubspec.lock changed during the build and was left in place (tree was already dirty)"
    snapshot = repository / ENDPOINT_SNAPSHOT
    if not snapshot.is_file():
        raise ValueError(f"build produced no {ENDPOINT_SNAPSHOT}; cannot verify endpoints")
    missing = missing_endpoints(snapshot, [api, cloud_api])
    if missing:
        raise ValueError("approved endpoints missing from data/app.so (a formal client without them "
                         "cannot log in from the corresponding network): " + ", ".join(missing))

    output_dir.mkdir(parents=True, exist_ok=True)
    setup_path = output_dir / f"UTEN-{version}-Windows-{architecture}-Setup.exe"
    update_path = output_dir / f"UTEN-{version}-Windows-{architecture}-update.zip"
    compiler = find_compiler(iscc)
    if package_pair is None and compiler is None:
        raise ValueError("Inno Setup ISCC.exe was not found; pass --iscc with the approved compiler path")
    (package_pair or _default_package_pair)(bundle, setup_path, update_path, version=version,
                                            build_number=build_number, architecture=architecture,
                                            compiler=compiler, repository=repository, runner=runner)

    preflight = verify_pair(setup_path, update_path, version=version, build_number=build_number,
                            architecture=architecture, required_endpoints=(api, cloud_api))
    with zipfile.ZipFile(update_path) as archive:
        manifest = json.loads(archive.read(MANIFEST_NAME))
    receipt = {
        "state": "FORMAL_WINDOWS_PAIR_READY_FOR_PUBLISH",
        "commit": audit["commit"],
        "treeClean": audit["treeClean"],
        "version": version,
        "buildNumber": build_number,
        "architecture": architecture,
        "runtimeFamily": "flutter",
        "flutterBuild": build_step,
        "pubspecLockNote": lock_note,
        "endpoints": {"API_BASE_URL": api, "CLOUD_API_BASE_URL": cloud_api,
                      "embeddedVerification": "byte-verified in data/app.so"},
        "artifacts": [
            {"path": str(setup_path), "bytes": setup_path.stat().st_size, "sha256": _sha256(setup_path),
             "installMode": "windows_setup", "packageKind": "installer"},
            {"path": str(update_path), "bytes": update_path.stat().st_size, "sha256": _sha256(update_path),
             "installMode": "windows_archive", "packageKind": "update",
             "manifest": {key: manifest.get(key) for key in
                          ("schemaVersion", "platform", "architecture", "version", "buildNumber",
                           "packageKind", "runtimeFamily", "executable")}},
        ],
        "preflight": {"ok": preflight["ok"], "failures": preflight["failures"]},
        "publishForm": [
            {"file": setup_path.name, "platform": "windows", "runtimeFamily": "flutter",
             "architecture": architecture, "packageKind": "installer",
             "version": version, "buildNumber": build_number},
            {"file": update_path.name, "platform": "windows", "runtimeFamily": "flutter",
             "architecture": architecture, "packageKind": "update",
             "version": version, "buildNumber": build_number},
        ],
        "publication": {"clientCatalogPublicationPerformed": False,
                        "guidance": "create FRESH publish entries for both files; never resume old drafts "
                                    "(they pin an older expectedSha256)"},
    }
    if not preflight["ok"]:
        receipt["state"] = "FORMAL_WINDOWS_PAIR_REJECTED_BY_PREFLIGHT"
    (output_dir / "delivery-receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=1),
                                                     encoding="utf-8")
    return receipt


def _default_package_pair(bundle: Path, setup_path: Path, update_path: Path, *, version: str,
                          build_number: int, architecture: str, compiler, repository: Path,
                          runner=subprocess.run) -> None:
    build_windows_setup(bundle, setup_path, version=version, build_number=build_number,
                        architecture=architecture, compiler=compiler, compile=True,
                        update_output=update_path, source_root=repository)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--api", required=True, help="approved company HTTPS API endpoint, e.g. https://<域名>/api")
    parser.add_argument("--cloud-api", required=True, help="approved cloud HTTPS API endpoint")
    parser.add_argument("--iscc", type=Path, help="approved Inno Setup ISCC.exe path")
    parser.add_argument("--architecture", choices=("x64",), default="x64")
    parser.add_argument("--repository", type=Path, default=REPOSITORY)
    parser.add_argument("--skip-build", action="store_true",
                        help="reuse an existing build/windows/x64/runner/Release payload (still verified end-to-end)")
    parser.add_argument("--allow-dirty", action="store_true",
                        help="record a dirty tree deviation instead of refusing (emergencies only)")
    args = parser.parse_args(argv)
    try:
        receipt = build_formal_release(args.repository, args.output_dir, api=args.api, cloud_api=args.cloud_api,
                                       architecture=args.architecture, iscc=args.iscc,
                                       allow_dirty=args.allow_dirty, skip_build=args.skip_build)
    except ValueError as error:
        print(f"[FAIL] {error}")
        return 1
    print(json.dumps(receipt, ensure_ascii=False, indent=1))
    if receipt["preflight"]["ok"]:
        print(f"[OK] {receipt['artifacts'][0]['path']}")
        print(f"[OK] {receipt['artifacts'][1]['path']}")
        print("Upload both as fresh publish entries with the values under publishForm.")
        return 0
    print("[FAIL] the pair was produced but does not satisfy the paired_v1 contract:")
    for failure in receipt["preflight"]["failures"]:
        print(f"  - {failure}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
