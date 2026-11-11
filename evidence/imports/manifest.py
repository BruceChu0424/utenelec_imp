from pathlib import Path
import hashlib, json, re, subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
evidence = root / "evidence/imports"
baseline = "fdeda88b3d73b24b8691ad132caa765196b19a3d"
head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
paths = subprocess.check_output(["git", "diff", "--name-only", baseline, head, "--", "server/src/main/java", "server/src/test/java", "server/src/test/resources/import-column-remediation"], cwd=root, text=True).splitlines()
sources = []
for path in paths:
    raw = subprocess.check_output(["git", "show", f"{head}:{path}"], cwd=root)
    sources.append({"path": path, "bytePolicy": "Git blob bytes", "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)})

runs = {}
for name in ("parsers", "db", "goods", "cost", "legacy"):
    path = evidence / f"candidate-2/{name}.log"
    if not path.exists(): continue
    text = path.read_text(encoding="utf-8", errors="replace")
    fields = {key: re.findall(r"\[\s*(\d+) tests " + pattern + r"\s*\]", text) for key, pattern in {"found": "found", "successful": "successful", "failed": "failed", "skipped": "skipped", "aborted": "aborted"}.items()}
    runs[name] = {"source": str(path), "counts": {key: int(values[-1]) for key, values in fields.items() if values}, "completeSummaryPresent": bool(fields["successful"])}

initial = dict(tests=0, failures=0, errors=0, skipped=0)
for report in (evidence / "candidate-1/build/surefire-reports").glob("TEST-*.xml"):
    suite = ET.parse(report).getroot()
    for key in initial: initial[key] += int(suite.get(key, 0))
initial["successful"] = initial["tests"] - initial["failures"] - initial["errors"] - initial["skipped"]
runs["initialMaven"] = {"counts": initial, "preserved": True, "scope": "initial compile before final safety-version fixture corrections; not current acceptance"}

raw_files = []
for path in sorted(evidence.rglob("*")):
    if not path.is_file() or path.suffix.lower() not in {".log", ".exit", ".xls", ".xlsx", ".dump"}: continue
    if any(part in {"build", "classes", "test-classes", "upgrade-storage"} or part.startswith("tmp") or part.endswith("-classes") or part.endswith("-tmp") for part in path.relative_to(evidence).parts): continue
    raw = path.read_bytes()
    raw_files.append({"path": str(path), "bytePolicy": "actual raw binary bytes", "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)})

result = {"baseline": baseline, "productCommit": head, "finalIntegrationCandidate": "Owned by root acceptance report; this manifest does not claim final integration acceptance", "overlap": "Run groups overlap and must not be added", "sourceFingerprints": sources, "runs": runs, "rawFiles": raw_files}
(evidence / "manifest.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
