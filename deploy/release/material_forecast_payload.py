#!/usr/bin/env python3
"""Build a signed-release component; independently verify it with only stdlib.

The surrounding release signature authenticates this verifier and release.json.
This component check does not replace the updater's signature or path checks.
"""
from __future__ import annotations

import argparse
import email.parser
import hashlib
import itertools
import json
import os
import platform
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
import zipfile


SCRIPT_PATH = "deploy/release/material_forecast_payload.py"
FACADE_PATH = "services/material_forecast/build_payload.py"
CATALOG_PATH = "server/src/main/resources/pricing/material-benchmarks.json"
CATALOG_SHA256 = "27ce10c71ff039cdb6d81e5b2f74dac687047f7f5973f8cbde0545a3a8b75587"
SOURCE_FILES = (
    "services/material_forecast/worker.py",
    "services/material_forecast/forecast_worker/__init__.py",
    "services/material_forecast/forecast_worker/__main__.py",
    "services/material_forecast/forecast_worker/cli.py",
    "services/material_forecast/forecast_worker/data.py",
    "services/material_forecast/forecast_worker/engine.py",
    "services/material_forecast/forecast_worker/automatic_engine.py",
    "services/material_forecast/forecast_worker/autofeed.py",
    "services/material_forecast/forecast_worker/shfe.py",
    "services/material_forecast/forecast_worker/locking.py",
    "services/material_forecast/prepare_runtime.py",
    "services/material_forecast/prepare_runtime.ps1",
    "services/material_forecast/MANAGED_RUNTIME.md",
    "services/material_forecast/README.md",
    "services/material_forecast/CONTRACT.md",
    "services/material_forecast/requirements.in",
    "services/material_forecast/requirements.txt",
    CATALOG_PATH,
)
LOCK_PACKAGES = frozenset((
    "adagio", "cloudpickle", "colorama", "coreforecast", "formulaic", "fsspec", "fugue",
    "interface-meta", "narwhals", "numpy", "packaging", "pandas", "patsy", "pyarrow",
    "python-dateutil", "pytz", "scipy", "six", "statsforecast", "statsmodels", "threadpoolctl",
    "tqdm", "triad", "typing-extensions", "tzdata", "utilsforecast", "wrapt",
))
TARGET = {"os": "ubuntu", "release": "24.04", "architecture": "x86_64",
          "implementation": "cpython", "python": "3.12"}
TARGETS = {"linux-x86_64": TARGET,
           "windows-x86_64": {"os": "windows", "architecture": "x86_64",
                              "implementation": "cpython", "python": "3.12"}}
DERIVED_FILES = ("services/material_forecast/requirements.runtime.txt",
                 *(f"services/material_forecast/runtime-locks/{target}.lock" for target in TARGETS))
HASH = re.compile(r"[a-f0-9]{64}\Z")
COMMIT = re.compile(r"[a-f0-9]{40}\Z")
VERSION = re.compile(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
SAFE_PATH = re.compile(r"[A-Za-z0-9._/-]+\Z")
MAX_JSON = 1024 * 1024
MAX_COMPONENT = 768 * 1024 * 1024
MAX_WHEEL = 256 * 1024 * 1024
MAX_WHEEL_EXPANDED = 1024 * 1024 * 1024


class PayloadError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PayloadError(message)


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def payload_path(source: str) -> str:
    return "material-benchmarks.json" if source == CATALOG_PATH else source.removeprefix("services/material_forecast/")


def safe_relative(value: str) -> str:
    require(isinstance(value, str) and len(value) <= 1024 and bool(SAFE_PATH.fullmatch(value)),
            "unsafe component path")
    parts = PurePosixPath(value).parts
    require(not value.startswith("/") and ".." not in value and parts and all(p != "." for p in parts)
            and str(PurePosixPath(value)) == value and all(len(p) <= 255 for p in parts),
            "unsafe component path")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def no_symlink_ancestors(path: Path) -> None:
    absolute = path.absolute()
    require(not any(is_link(p) for p in (absolute, *absolute.parents)), "symlink component path")


def is_link(path: Path) -> bool:
    return path.is_symlink() or path.is_junction()


def inventory(root: Path) -> dict[str, tuple[int, str]]:
    no_symlink_ancestors(root)
    require(root.is_dir(), "component directory is missing")
    files = {}
    total = 0
    for current, directories, names in os.walk(root, followlinks=False):
        for name in (*directories, *names):
            path = Path(current) / name
            relative = safe_relative(path.relative_to(root).as_posix())
            info = path.lstat()
            require(not stat.S_ISLNK(info.st_mode) and not is_link(path), "symlinks are forbidden in component")
            if stat.S_ISDIR(info.st_mode):
                continue
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "component needs independent regular files")
            require(0 < info.st_size <= MAX_WHEEL, "invalid component file size")
            total += info.st_size
            require(total <= MAX_COMPONENT, "component is too large")
            files[relative] = (info.st_size, sha256(path))
    return files


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON field")
        result[key] = value
    return result


def read_json(path: Path):
    require(path.stat().st_size <= MAX_JSON, "component JSON is too large")
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_unique_object)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PayloadError("invalid component JSON") from error


def parse_lock(path: Path, target: str = "linux-x86_64") -> tuple[dict, dict]:
    require(target in TARGETS, "unsupported runtime target")
    require(path.stat().st_size <= MAX_JSON, "dependency lock is too large")
    text = path.read_text(encoding="utf-8").replace("\\\n", " ")
    all_packages, selected = {}, {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"\s*([A-Za-z0-9_.-]+)==([A-Za-z0-9._]+)"
                             r"(?:\s*;\s*(.*?))?\s+((?:--hash=sha256:[a-f0-9]{64}\s*)+)\s*", line)
        require(match is not None, "dependency lock must contain only exact hashed pins")
        name, version, marker, hashes = match.groups()
        name = normalize(name)
        require(name not in all_packages, "duplicate dependency lock package")
        require(marker is None or marker.strip() == "sys_platform == 'win32'", "unreviewed dependency marker")
        require((name == "colorama") == (marker is not None), "invalid platform dependency marker")
        item = {"version": version, "hashes": set(re.findall(r"sha256:([a-f0-9]{64})", hashes))}
        all_packages[name] = item
        if marker is None or target == "windows-x86_64":
            selected[name] = item
    require(set(all_packages) == LOCK_PACKAGES, "dependency lock package allowlist changed")
    require(set(selected) == (LOCK_PACKAGES - {"colorama"} if target == "linux-x86_64" else LOCK_PACKAGES),
            "invalid platform dependency selection")
    return all_packages, selected


def _platform_tag(tag: str, target: str = "linux-x86_64") -> bool:
    if target == "windows-x86_64":
        return tag == "win_amd64"
    if tag in {"manylinux1_x86_64", "manylinux2010_x86_64", "manylinux2014_x86_64"}:
        return True
    match = re.fullmatch(r"manylinux_2_([0-9]+)_x86_64", tag)
    return bool(match and 5 <= int(match.group(1)) <= 39)


def _wheel_tags(python: str, abi: str, system: str, target: str = "linux-x86_64") -> set[str]:
    pythons, abis, systems = python.split("."), abi.split("."), system.split(".")
    tags = {"-".join(parts) for parts in itertools.product(pythons, abis, systems)}
    if systems == ["any"]:
        require(abis == ["none"] and set(pythons) <= {"py2", "py3"} and "py3" in pythons,
                "wheel is not a Python 3 pure wheel")
    else:
        require(all(_platform_tag(tag, target) for tag in systems), "wheel is not target x86_64 compatible")
        for py, abi_tag in itertools.product(pythons, abis):
            stable = re.fullmatch(r"cp3([0-9]{1,2})", py)
            require((py == "cp312" and abi_tag == "cp312")
                    or (stable is not None and 2 <= int(stable.group(1)) <= 12 and abi_tag == "abi3")
                    or (py == "py3" and abi_tag == "none"), "wheel has an unsupported CPython ABI")
    return tags


def inspect_wheel(path: Path, selected: dict, target: str = "linux-x86_64") -> dict:
    safe_relative(path.name)
    pieces = path.name[:-4].split("-") if path.name.endswith(".whl") else []
    require(len(pieces) in (5, 6), "wheel filename is invalid")
    if len(pieces) == 6:
        require(bool(re.fullmatch(r"[0-9][A-Za-z0-9_]*", pieces[2])), "wheel build tag is invalid")
    distribution, version = pieces[:2]
    name = normalize(distribution)
    require(name in selected and version == selected[name]["version"], "wheel name/version is outside the lock")
    digest = sha256(path)
    require(digest in selected[name]["hashes"], "wheel hash is outside the complete source lock")
    tags = _wheel_tags(*pieces[-3:], target)
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            names = [item.filename for item in infos]
            require(len(names) == len(set(names)) and len(names) <= 30000, "duplicate or excessive wheel members")
            require(sum(item.file_size for item in infos) <= MAX_WHEEL_EXPANDED, "wheel expanded size is excessive")
            for item in infos:
                member = PurePosixPath(item.filename)
                require(not item.filename.startswith("/") and "\\" not in item.filename and ":" not in item.filename
                        and "\0" not in item.filename and str(member) == item.filename.rstrip("/")
                        and all(part not in (".", "..") for part in member.parts)
                        and not (item.flag_bits & 1) and not stat.S_ISLNK(item.external_attr >> 16),
                        "unsafe wheel archive member")
            root = f"{distribution}-{version}.dist-info/"
            metadata_path, wheel_path = root + "METADATA", root + "WHEEL"
            require(metadata_path in names and wheel_path in names and root + "RECORD" in names,
                    "wheel metadata does not match its filename")
            require(archive.getinfo(metadata_path).file_size <= MAX_JSON
                    and archive.getinfo(wheel_path).file_size <= 65536, "wheel metadata is excessive")
            parser = email.parser.BytesParser()
            metadata = parser.parsebytes(archive.read(metadata_path))
            wheel = parser.parsebytes(archive.read(wheel_path))
            require(len(metadata.get_all("Name", [])) == 1 and len(metadata.get_all("Version", [])) == 1
                    and normalize(metadata["Name"]) == name and metadata["Version"] == version,
                    "wheel package metadata mismatch")
            listed_tags = wheel.get_all("Tag", [])
            require(wheel.get_all("Root-Is-Purelib") == ["true" if pieces[-1] == "any" else "false"],
                    "wheel pure/native metadata mismatch")
            require(wheel.get_all("Wheel-Version") == ["1.0"] and set(listed_tags) == tags
                    and len(listed_tags) == len(tags),
                    "wheel ABI metadata does not match its filename")
    except (zipfile.BadZipFile, UnicodeError, OSError, KeyError) as error:
        raise PayloadError("wheel archive is invalid") from error
    return {"filename": path.name, "package": name, "version": version, "sha256": digest}


def runtime_requirements(wheels: list[dict]) -> bytes:
    return "".join(f'{item["package"]}=={item["version"]} --hash=sha256:{item["sha256"]}\n'
                   for item in sorted(wheels, key=lambda value: value["package"])).encode("ascii")


def validate_identity(version: str, commit: str) -> None:
    require(isinstance(version, str) and bool(VERSION.fullmatch(version)), "expected vMAJOR.MINOR.PATCH version")
    require(isinstance(commit, str) and bool(COMMIT.fullmatch(commit)), "expected exact lowercase commit SHA")


def verify(payload: Path, version: str, commit: str, target: str = "linux-x86_64") -> dict:
    validate_identity(version, commit)
    require(target in TARGETS, "unsupported runtime target")
    actual = inventory(payload)
    require("release.json" in actual, "component manifest is missing")
    manifest = read_json(payload / "release.json")
    require(isinstance(manifest, dict) and set(manifest) == {
        "schemaVersion", "component", "version", "commit", "applicationVersion", "target", "files", "wheels"
    }, "component manifest fields are invalid")
    require(type(manifest["schemaVersion"]) is int and manifest["schemaVersion"] == 1
            and manifest["component"] == "material-forecast", "unsupported component manifest")
    require(manifest["version"] == version and manifest["commit"] == commit, "component source identity mismatch")
    require(isinstance(manifest["applicationVersion"], str)
            and bool(re.fullmatch(re.escape(version[1:]) + r"\+[1-9][0-9]*", manifest["applicationVersion"]))
            and manifest["target"] == TARGETS[target], "component application/target identity mismatch")
    records = manifest["files"]
    require(isinstance(records, list) and 1 <= len(records) <= 100, "invalid component file manifest")
    recorded = {}
    for item in records:
        require(isinstance(item, dict) and set(item) == {"path", "size", "sha256"}, "invalid component file record")
        path = safe_relative(item["path"])
        require(path != "release.json" and path not in recorded and type(item["size"]) is int
                and item["size"] > 0 and isinstance(item["sha256"], str) and bool(HASH.fullmatch(item["sha256"])),
                "duplicate or invalid component file record")
        recorded[path] = (item["size"], item["sha256"])
    require(recorded == {name: value for name, value in actual.items() if name != "release.json"},
            "component files are missing, extra, or have changed")
    require({payload_path(path) for path in SOURCE_FILES} | {"verify_payload.py", "runtime-requirements.txt"}
            <= set(actual), "component source allowlist is incomplete")
    require(actual[payload_path(CATALOG_PATH)][1] == CATALOG_SHA256, "unreviewed source benchmark catalog")
    catalog = read_json(payload / payload_path(CATALOG_PATH))
    require(isinstance(catalog, list) and {row.get("seriesId") for row in catalog if isinstance(row, dict)} == {
        "shfe_cu_main_daily", "shfe_al_main_daily", "shfe_ag_main_daily"
    } and len(catalog) == 3, "source benchmark identity mismatch")
    all_packages, selected = parse_lock(payload / "requirements.txt", target)
    direct = {}
    for line in (payload / "requirements.in").read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"([a-z0-9-]+)==([A-Za-z0-9._]+)", line.strip())
        require(match is not None and match.group(1) not in direct, "invalid direct dependency pins")
        direct[match.group(1)] = match.group(2)
    require(set(direct) == {"statsforecast", "numpy", "pandas"}
            and all(all_packages[name]["version"] == version for name, version in direct.items()),
            "direct dependencies differ from the complete source lock")
    wheels = [inspect_wheel(payload / name, selected, target) for name in actual if name.startswith("wheelhouse/")]
    require(len(wheels) == len(selected) and {item["package"] for item in wheels} == set(selected),
            "wheelhouse must contain exactly the platform lock closure")
    require(manifest["wheels"] == sorted(wheels, key=lambda value: value["package"]), "wheel manifest mismatch")
    expected = {payload_path(path) for path in SOURCE_FILES} | {
        "verify_payload.py", "runtime-requirements.txt", "release.json",
        *("wheelhouse/" + item["filename"] for item in wheels),
    }
    require(set(actual) == expected, "component violates its source/file allowlist")
    allowed_directories = {str(parent) for name in expected for parent in PurePosixPath(name).parents if str(parent) != "."}
    for directory, children, _ in os.walk(payload):
        for child in children:
            require((Path(directory) / child).relative_to(payload).as_posix() in allowed_directories,
                    "component contains an extra directory")
    require((payload / "runtime-requirements.txt").read_bytes() == runtime_requirements(wheels),
            "offline runtime requirements do not match the selected wheel hashes")
    return {"component": "material-forecast", "version": version, "commit": commit,
            "files": len(actual), "wheels": len(wheels), "target": TARGETS[target], "verified": True}


def _git(repo: Path, *arguments: str) -> bytes:
    result = subprocess.run(["git", "-C", str(repo), *arguments], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode == 0, "unable to read the exact source checkout")
    return result.stdout


def require_checkout(repo: Path, version: str, commit: str, development: bool = False) -> str:
    require(Path(_git(repo, "rev-parse", "--show-toplevel").decode().strip()).resolve() == repo.resolve(),
            "repo root is not the checkout root")
    require(_git(repo, "rev-parse", "HEAD").decode().strip() == commit, "checkout is not the requested commit")
    if development:
        # Flutter's working manifest is not a Python runtime input. Development
        # may change its version/dependencies while the payload still uses the
        # requested commit's application version and source identity below.
        for path in (*SOURCE_FILES, *DERIVED_FILES, SCRIPT_PATH, FACADE_PATH):
            source = repo / path
            no_symlink_ancestors(source)
            require(source.is_file() and source.stat().st_nlink == 1, "runtime source needs an independent regular file")
            # Runtime inputs have explicit LF checkout attributes. Compare the
            # actual bytes, rather than allowing a filter to normalize a change.
            require(source.read_bytes() == git_source(repo, commit, path),
                    "runtime source differs from the requested commit: " + path)
        directory = repo / "services/material_forecast/forecast_worker"
        expected = {str(Path(path).relative_to("services/material_forecast/forecast_worker")).replace("\\", "/")
                    for path in SOURCE_FILES if "/forecast_worker/" in path}
        actual = set()
        for current, children, files in os.walk(directory, followlinks=False):
            for name in (*children, *files):
                require(not is_link(Path(current) / name), "runtime source links are forbidden")
            children[:] = [name for name in children if name != "__pycache__"]
            actual.update((Path(current) / name).relative_to(directory).as_posix() for name in files)
        require(actual == expected, "runtime source allowlist changed")
    else:
        require(not _git(repo, "status", "--porcelain=v1", "--untracked-files=normal"), "checkout is dirty")
    pubspec = _git(repo, "show", commit + ":pubspec.yaml").decode("utf-8")
    versions = re.findall(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+\+[1-9][0-9]*)\s*$", pubspec, re.MULTILINE)
    require(len(versions) == 1 and versions[0].split("+")[0] == version[1:], "checkout application version mismatch")
    return versions[0]


def git_source(repo: Path, commit: str, path: str) -> bytes:
    listing = _git(repo, "ls-tree", "-z", commit, "--", path)
    require(listing.count(b"\0") == 1 and listing.split(b" ", 1)[0] in {b"100644", b"100755"}
            and listing.split(b"\t", 1)[1].rstrip(b"\0").decode() == path, "source file is missing or is a symlink")
    return _git(repo, "show", commit + ":" + path)


def verify_checkout_sources(payload: Path, repo: Path, commit: str) -> None:
    """Unsigned developer caches must prove source bytes against reviewed Git.

    A release signature authenticates release.json, whereas a local cache's
    self-reported digest manifest is not an authority for new executable code.
    """
    for source in SOURCE_FILES:
        require((payload / payload_path(source)).read_bytes() == git_source(repo, commit, source),
                "payload source differs from the requested commit: " + source)
    require((payload / "verify_payload.py").read_bytes() == git_source(repo, commit, SCRIPT_PATH),
            "payload verifier differs from the requested commit")


def require_build_host(target: str = "linux-x86_64") -> None:
    require(target in TARGETS, "unsupported runtime target")
    require(sys.implementation.name == "cpython" and sys.version_info[:2] == (3, 12)
            and platform.machine().lower() in {"amd64", "x86_64"}, "build requires x86_64 CPython 3.12")
    if target == "windows-x86_64":
        require(platform.system() == "Windows", "build requires the Windows x86_64 target")
        return
    require(platform.system() == "Linux", "build requires the Ubuntu 24.04 release target")
    values = {}
    for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value.strip('"')
    require(values.get("ID") == "ubuntu" and values.get("VERSION_ID") == "24.04",
            "build requires the Ubuntu 24.04 release target")


def write_manifest(payload: Path, version: str, commit: str, application_version: str, wheels: list[dict],
                   target: str = "linux-x86_64") -> None:
    files = inventory(payload)
    require("release.json" not in files, "refusing to overwrite a component manifest")
    manifest = {"schemaVersion": 1, "component": "material-forecast", "version": version, "commit": commit,
                "applicationVersion": application_version, "target": TARGETS[target],
                "files": [{"path": path, "size": size, "sha256": digest}
                          for path, (size, digest) in sorted(files.items())],
                "wheels": sorted(wheels, key=lambda value: value["package"])}
    raw = (json.dumps(manifest, ensure_ascii=True, sort_keys=True, indent=2) + "\n").encode("ascii")
    require(len(raw) <= MAX_JSON, "component manifest is too large")
    (payload / "release.json").write_bytes(raw)


def validate_derived(root: Path) -> None:
    """Compatibility exports may narrow hashes; requirements.txt is the authority."""
    all_packages, _ = parse_lock(root / "requirements.txt")
    versions = {}
    for line in (root / "requirements.runtime.txt").read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9._]+)", line.strip())
        require(match is not None, "invalid derived runtime pins")
        name = normalize(match[1])
        require(name not in versions, "duplicate derived runtime pin")
        versions[name] = match[2]
    require(versions == {name: item["version"] for name, item in all_packages.items()},
            "derived runtime pins differ from authoritative requirements.txt")
    for target in TARGETS:
        _, selected = parse_lock(root / "requirements.txt", target)
        exported = {}
        for line in (root / "runtime-locks" / (target + ".lock")).read_text(encoding="utf-8").splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9._]+) --hash=sha256:([a-f0-9]{64})", line)
            require(match is not None, "invalid derived platform lock")
            name, version, digest = normalize(match[1]), match[2], match[3]
            require(name not in exported and name in selected and version == selected[name]["version"]
                    and digest in selected[name]["hashes"], "derived platform lock differs from authority")
            exported[name] = version
        require(set(exported) == set(selected), "derived platform lock closure differs from authority")


def source_identity(repo: Path, version: str, commit: str, target: str, development: bool = False) -> str:
    require_checkout(repo, version, commit, development)
    require(target in TARGETS, "unsupported runtime target")
    sources = {path: hashlib.sha256(git_source(repo, commit, path)).hexdigest()
               for path in (*SOURCE_FILES, *DERIVED_FILES, SCRIPT_PATH, FACADE_PATH, "pubspec.yaml")}
    return hashlib.sha256(json.dumps({"version": version, "commit": commit, "target": TARGETS[target],
                                     "sources": sources}, sort_keys=True).encode("ascii")).hexdigest()


def build(repo: Path, output: Path, version: str, commit: str, offline_wheel_cache: Path | None = None,
          target: str = "linux-x86_64", development: bool = False) -> dict:
    validate_identity(version, commit)
    require_build_host(target)
    repo = repo.resolve()
    application_version = require_checkout(repo, version, commit, development)
    identity = source_identity(repo, version, commit, target, development)
    runtime_sources = set(_git(repo, "ls-tree", "-r", "--name-only", "-z", commit, "--",
                               "services/material_forecast/forecast_worker/").decode("utf-8").strip("\0").split("\0"))
    require(runtime_sources == {path for path in SOURCE_FILES if "/forecast_worker/" in path},
            "runtime source allowlist changed; review the component before release")
    output = output.absolute()
    no_symlink_ancestors(output)
    output = output.resolve()
    require(output.is_relative_to(repo / "build") and not output.exists(), "output must be a new checkout build directory")
    verifier = git_source(repo, commit, SCRIPT_PATH)
    require(verifier == Path(__file__).read_bytes(), "builder differs from the requested source commit")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".material-forecast-build-", dir=output.parent) as temporary:
        payload = Path(temporary) / "payload"
        payload.mkdir()
        for path in SOURCE_FILES:
            destination = payload / payload_path(path)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(git_source(repo, commit, path))
        (payload / "verify_payload.py").write_bytes(verifier)
        lock = payload / "requirements.txt"
        _, selected = parse_lock(lock, target)
        with tempfile.TemporaryDirectory(prefix="derived-", dir=temporary) as derived:
            for path in (*DERIVED_FILES, "services/material_forecast/requirements.txt"):
                destination = Path(derived) / path.removeprefix("services/material_forecast/")
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(git_source(repo, commit, path))
            validate_derived(Path(derived))
        wheelhouse = payload / "wheelhouse"
        wheelhouse.mkdir()
        source = ["--index-url", "https://pypi.org/simple"]
        if offline_wheel_cache is not None:
            no_symlink_ancestors(offline_wheel_cache)
            require(offline_wheel_cache.is_dir(), "offline wheel cache is missing")
            source = ["--no-index", "--find-links", str(offline_wheel_cache.resolve())]
        # Development builds stream into the developer's backend console; -q keeps
        # that console clean while failures still surface. Release builds stay verbose.
        quiet = ["-q"] if development else []
        result = subprocess.run([sys.executable, "-I", "-m", "pip", "--isolated", "download", *source, *quiet,
                                 "--disable-pip-version-check", "--require-hashes", "--only-binary=:all:",
                                 "--dest", str(wheelhouse), "--requirement", str(lock)],
                                check=False, stdout=sys.stderr)
        require(result.returncode == 0, "complete hashed binary wheel download failed")
        wheels = [inspect_wheel(path, selected, target) for path in wheelhouse.iterdir()]
        (payload / "runtime-requirements.txt").write_bytes(runtime_requirements(wheels))
        write_manifest(payload, version, commit, application_version, wheels, target)
        result = verify(payload, version, commit, target)
        require(source_identity(repo, version, commit, target, development) == identity, "runtime source changed during build")
        payload.rename(output)
    return result


def main(arguments: list[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if arguments is None else arguments)
    if not arguments or arguments[0].startswith("-"):
        arguments.insert(0, "verify")
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    builder = subparsers.add_parser("build")
    builder.add_argument("--repo-root", type=Path, required=True)
    builder.add_argument("--output", type=Path, required=True)
    builder.add_argument("--offline-wheel-cache", type=Path,
                         help="local validation only: copy through pip from an existing fully hashed wheel cache")
    verifier = subparsers.add_parser("verify")
    verifier.add_argument("--payload", type=Path, required=True)
    for command in (builder, verifier):
        command.add_argument("--commit", required=True)
        command.add_argument("--version", required=True)
        command.add_argument("--platform", choices=TARGETS, default="linux-x86_64")
    args = parser.parse_args(arguments)
    try:
        result = (build(args.repo_root, args.output, args.version, args.commit, args.offline_wheel_cache, args.platform)
                  if args.command == "build"
                  else verify(args.payload, args.version, args.commit, args.platform))
        print(json.dumps(result, sort_keys=True))
        return 0
    except (PayloadError, OSError, UnicodeError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        print("material-forecast payload rejected: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
