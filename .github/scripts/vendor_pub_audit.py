#!/usr/bin/env python3
"""Verify reviewed Pub backports before producing hosted-version-only OSV inputs."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile
import urllib.request


GENERATED_DIRECTORIES = {".dart_tool", ".gradle", ".kotlin", ".cxx", "build"}


def digest(data):
    return hashlib.sha256(data.replace(b"\r\n", b"\n")).hexdigest()


def normalize_hygiene(data):
    lines = (line.rstrip(b" \t") for line in data.replace(b"\r\n", b"\n").split(b"\n"))
    return b"\n".join(lines).rstrip(b"\n") + b"\n"


def scalar(source, key):
    matches = re.findall(r"(?m)^" + re.escape(key) + r":\s*([^\r\n]+)$", source)
    if len(matches) != 1:
        raise ValueError(f"Ambiguous package {key}")
    return matches[0].strip().strip("\"'")


def archive_files(data):
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or member.issym() or member.islnk():
                raise ValueError("Unsafe upstream archive member")
            if member.isfile():
                if member.name in files or member.size > 10_000_000:
                    raise ValueError("Duplicate or oversized upstream archive member")
                files[member.name] = archive.extractfile(member).read()
    return files


def verify_package(root, record, archive_data):
    name, version, local = record["name"], record["upstreamVersion"], record["localVersion"]
    if not re.fullmatch(r"[a-z][a-z0-9_]*", name) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Invalid upstream package identity")
    if local != version + "+uten.1" or hashlib.sha256(archive_data).hexdigest() != record["archiveSha256"]:
        raise ValueError(f"Upstream archive/version mismatch: {name}")
    original = archive_files(archive_data)
    metadata = original["pubspec.yaml"].decode("utf-8")
    if scalar(metadata, "name") != name or scalar(metadata, "version") != version:
        raise ValueError(f"Upstream archive package identity mismatch: {name}")
    directory = root / "third_party" / name
    files = {path.relative_to(directory).as_posix(): path for path in directory.rglob("*")
             if path.is_file() and not any(part in GENERATED_DIRECTORIES for part in path.relative_to(directory).parts)}
    if not files or set(files) != set(record["files"]):
        raise ValueError(f"Vendor source closure changed: {name}")
    for relative, path in files.items():
        if path.is_symlink() or digest(path.read_bytes()) != record["files"][relative]:
            raise ValueError(f"Unreviewed vendor file: {name}/{relative}")
    modified = set(record["modifiedFiles"])
    hygiene = set(record.get("hygieneFiles", []))
    local_only = set(record["localOnlyFiles"])
    if ("LICENSE" in modified | hygiene or modified & hygiene or not (modified | hygiene | local_only).issubset(files)
            or any(not path.startswith("UPSTREAM") for path in local_only)):
        raise ValueError(f"Invalid vendor patch scope: {name}")
    for relative, path in files.items():
        if relative in local_only:
            continue
        if relative not in original:
            raise ValueError(f"Unbound upstream source: {name}/{relative}")
        if relative in hygiene:
            if path.read_bytes().replace(b"\r\n", b"\n") != normalize_hygiene(original[relative]):
                raise ValueError(f"Hygiene patch contains substantive source changes: {name}/{relative}")
            continue
        if relative not in modified and digest(path.read_bytes()) != digest(original[relative]):
            raise ValueError(f"Runtime differs from upstream outside reviewed patch: {name}/{relative}")
    if digest(files["LICENSE"].read_bytes()) != digest(original["LICENSE"]):
        raise ValueError(f"Upstream license changed: {name}")
    current = files["pubspec.yaml"].read_text(encoding="utf-8")
    if scalar(current, "name") != name or scalar(current, "version") != local:
        raise ValueError(f"Local package version mismatch: {name}")
    app_lock = (root / "pubspec.lock").read_text(encoding="utf-8")
    block = re.search(r"(?ms)^  " + re.escape(name) + r":\n(.*?)(?=^  [a-z_]|\Z)", app_lock)
    if not block or not re.search(r"(?m)^    source: path$", block[1]):
        raise ValueError(f"Application does not use reviewed vendor source: {name}")
    if re.findall(r'(?m)^    version: "([^\n]+)"$', block[1]) != [local]:
        raise ValueError(f"Application vendor version mismatch: {name}")
    if f'path: "third_party/{name}"' not in block[1]:
        raise ValueError(f"Application vendor path mismatch: {name}")
    return {"name": name, "upstreamVersion": version, "localVersion": local,
            "archiveSha256": record["archiveSha256"], "verifiedSourceFiles": len(files),
            "licenseVerified": True, "reviewedModifiedFiles": sorted(modified), "reviewedHygieneFiles": sorted(hygiene)}


def build_audit(root, registry, output, fetch=None):
    if registry.get("schemaVersion") != 1 or not registry.get("packages"):
        raise ValueError("Invalid vendor audit registry")
    fetch = fetch or (lambda url: urllib.request.urlopen(url, timeout=30).read(20_000_001))
    verified = []
    names = set()
    for record in registry["packages"]:
        name, version = record["name"], record["upstreamVersion"]
        if name in names or not re.fullmatch(r"[a-z][a-z0-9_]*", name) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
            raise ValueError("Duplicate or invalid vendor package")
        names.add(name)
        data = fetch(f"https://pub.dev/api/archives/{name}-{version}.tar.gz")
        if len(data) > 20_000_000:
            raise ValueError("Upstream archive exceeded the audit bound")
        verified.append(verify_package(root, record, data))
    lines = ["# Verified upstream package identities for security scanning only.", "packages:"]
    for record in verified:
        lines.extend([f'  {record["name"]}:', '    dependency: "direct main"', '    description:',
                      f'      name: {record["name"]}', f'      sha256: "{record["archiveSha256"]}"',
                      '      url: "https://pub.dev"', '    source: hosted', f'    version: "{record["upstreamVersion"]}"'])
    output.mkdir(parents=True, exist_ok=True)
    (output / "pubspec.lock").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (output / "evidence.json").write_text(json.dumps({"packages": verified}, indent=2) + "\n", encoding="utf-8")
    return verified


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    registry = json.loads((root / ".github/vendor-pub-audit.json").read_text(encoding="utf-8"))
    try:
        evidence = build_audit(root, registry, args.output)
    except (ValueError, KeyError, OSError, tarfile.TarError) as failure:
        raise SystemExit(f"Vendor provenance verification failed: {failure}; audit input was not generated.") from None
    print(f"Verified {len(evidence)} vendor archives, source closures, reviewed patches, versions, and licenses")


if __name__ == "__main__":
    main()
