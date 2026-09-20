"""Generate synthetic, explicitly non-production legacy CSVs using real COPY schemas."""
import csv
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
legacy = root / "server/legacy_migration"
data = legacy / "data"
data.mkdir(exist_ok=True)
schemas = {}
for path in legacy.glob("migrate_*.sql"):
    sql = re.sub(r"--[^\n]*", "", path.read_text(encoding="utf-8-sig"))
    tables = {}
    for match in re.finditer(r"CREATE TEMP TABLE\s+(\w+)\s*\((.*?)\)\s*(?:ON COMMIT DROP)?;", sql, re.S | re.I):
        inherited = re.fullmatch(r"\s*LIKE\s+(\w+)(?:\s+INCLUDING\s+DEFAULTS)?\s*", match[2], re.I)
        if inherited:
            tables[match[1]] = list(tables[inherited[1]])
        else:
            tables[match[1]] = [column.strip().split()[0] for column in
                                re.split(r",(?![^()]*\))", match[2])]
    for match in re.finditer(r"\\copy\s+(\w+)(?:\(([^)]+)\))?\s+FROM '/tmp/([^']+)'", sql):
        columns = match[2].split(",") if match[2] else tables[match[1]]
        if match[3] in schemas and schemas[match[3]] != columns:
            raise ValueError(f"conflicting COPY schemas for {match[3]}")
        schemas[match[3]] = columns
exporter = legacy / "export_legacy.ps1"
inventory = set(re.findall(r"Join-Path\s+\$dataDir\s+'([A-Za-z0-9][A-Za-z0-9_.-]*[.]csv)'",
                           exporter.read_text(encoding="utf-8-sig")))
fixture = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
for variant_path in sys.argv[3:]:
    for filename, rows in json.loads(pathlib.Path(variant_path).read_text(encoding="utf-8")).items():
        fixture.setdefault(filename, []).extend(rows)
if set(fixture) - inventory:
    raise ValueError("fixture contains a file outside the real All export inventory")
records = []
for filename in sorted(inventory):
    columns = schemas[filename]
    rows = fixture.get(filename, [])
    path = data / filename
    with path.open("w", encoding="utf-8", newline="") as target:
        writer = csv.DictWriter(target, columns, delimiter="|", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    content = path.read_bytes()
    records.append(dict(file=filename, rows=len(rows), bytes=len(content),
                        sha256=hashlib.sha256(content).hexdigest()))
sidecar = data / "export_manifest.sha256"
sidecar.write_text("".join(f"{row['sha256']} *{row['file']}\n" for row in records), encoding="ascii")
snapshot = json.dumps(fixture, sort_keys=True, separators=(",", ":")).encode("utf-8")
(root / "synthetic-source-snapshot.json").write_bytes(snapshot)
manifest = dict(formatVersion=4, sourceSnapshotAsOfUtc="2025-01-31T15:59:59Z", target="All", exportedAtUtc="2026-01-01T00:00:00Z",
                sourceAuthorityId="synthetic-offline-fixture",
                consistency="serializable-read-transaction", offlineBackupRequired=True,
                sourceBackupSha256=hashlib.sha256(snapshot).hexdigest(),
                approvalReference="synthetic-test-approval",
                repositoryCommit=subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
                exportScriptSha256=hashlib.sha256(exporter.read_bytes()).hexdigest(),
                checksumManifestSha256=hashlib.sha256(sidecar.read_bytes()).hexdigest(), files=records)
(data / "export_manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
