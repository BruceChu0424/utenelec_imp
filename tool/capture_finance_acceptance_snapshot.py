"""Capture immutable local UI sources so parallel edits cannot alter a running build."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
name = sys.argv[1]
if not name.replace("-", "").isalnum():
    raise ValueError("Invalid task-owned snapshot name")
target = root / "build/finance-closeout-20261104/source-snapshots" / name
if (target / "acceptance-source-manifest.json").exists():
    raise FileExistsError("Verified acceptance snapshots are never overwritten")
prefixes = ["lib", "assets", "windows", "web", "third_party", "tool", "integration_test",
            "pubspec.yaml", "pubspec.lock", "analysis_options.yaml", "l10n.yaml", ".metadata"]
names = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard", "-z", "--", *prefixes], cwd=root).decode().split("\0")
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
manifest = []
for relative in sorted(set(filter(None, names))):
    source = root / relative
    if not source.is_file():
        continue
    destination = target / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    # A capture rejected for concurrent edits has no manifest and is not an
    # accepted snapshot. Complete that candidate without recopying static fonts.
    if not destination.exists() or digest(source) != digest(destination):
        shutil.copyfile(source, destination)
    manifest.append({"path": relative, "sha256": digest(destination)})
changed = [row["path"] for row in manifest if digest(root / row["path"]) != row["sha256"]]
if changed:
    raise RuntimeError(f"Source changed during capture: {changed}")
(target / "acceptance-source-manifest.json").write_text(json.dumps({"localOnly": True, "files": manifest}, indent=2), encoding="utf-8")
print(f"Captured {len(manifest)} verified UI source files to {target}")
