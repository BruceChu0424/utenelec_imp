#!/usr/bin/env python3
"""Capture local source/report facts for handover, never infer Win7 acceptance.

No backend request, credential access, install, restore, merge or deployment.
Ignored local logs may be historical; their existence is recorded separately
from current-source validation and target-machine evidence.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "clients/windows_legacy/progress/evidence/handover-baseline.json"


def git(*args):
    result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
    if result.returncode:
        raise ValueError("Git inspection failed")
    return result.stdout.strip()


def file_fact(path: Path):
    if not path.is_file():
        return {"path": path.relative_to(ROOT).as_posix(), "exists": False}
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"path": path.relative_to(ROOT).as_posix(), "exists": True,
            "size": path.stat().st_size, "sha256": digest,
            "modifiedAtUtc": datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat()}


def collect():
    scope = ["clients/windows_legacy", "server/src/main/java/com/uten/imp/features/clientupdates",
             "server/src/test/java/com/uten/imp/features/clientupdates", "lib/features/client_update",
             "lib/core/network/api_client.dart", "lib/core/theme", "pubspec.yaml", "pubspec.lock"]
    source_paths = git("ls-files", "--cached", "--others", "--exclude-standard", "--", *scope).splitlines()
    source_paths = sorted(set(path for path in source_paths if "/progress/" not in path and (ROOT / path).is_file()))
    source_files = [file_fact(ROOT / path) for path in source_paths]
    source_digest = hashlib.sha256(json.dumps([(item["path"], item["sha256"]) for item in source_files], separators=(",", ":")).encode()).hexdigest()
    java_sources = [ROOT / path for path in source_paths if "/clientupdates/" in path and path.endswith(".java")]
    latest_java = max((path.stat().st_mtime for path in java_sources), default=0)
    report_dir = ROOT / "build/wpf-runtime-backend-final/surefire-reports"
    reports = []
    for path in sorted(report_dir.glob("TEST-*.xml")):
        suite = ET.parse(path).getroot()
        reports.append({**file_fact(path), "suite": suite.attrib.get("name"),
                        **{key: int(suite.attrib.get(key, 0)) for key in ("tests", "failures", "errors", "skipped")}})
    report_latest = max(((ROOT / item["path"]).stat().st_mtime for item in reports), default=0)
    flutter = ROOT / "build/legacy-client-update-tests.log"
    flutter_fact = file_fact(flutter)
    if flutter.is_file():
        text = flutter.read_text(encoding="utf-8", errors="replace")
        counts = re.findall(r"\+(\d+)", text)
        flutter_fact.update(reportedPassedCount=max(map(int, counts), default=0),
                            reportsAllPassed="All tests passed!" in text,
                            limitation="Historical local log; rerun after affected source changes. No Win7 target acceptance.")
    artifacts = [file_fact(ROOT / ("build/windows-wpf/" + arch + "/Uten.Legacy.Desktop.exe")) for arch in ("x86", "x64")]
    return {"schemaVersion": 1, "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
            "clientContextDate": "2026-10-28", "clientTimezone": "America/Denver",
            "branch": git("branch", "--show-current"), "head": git("rev-parse", "HEAD"),
            "workingTreeDirty": bool(git("status", "--porcelain=v1")),
            "environment": {"os": platform.platform(), "isWin7Acceptance": False},
            "sourceSnapshotSha256": source_digest, "sourceFiles": source_files,
            "backendReports": {"files": reports,
                "totals": {key: sum(item[key] for item in reports) for key in ("tests", "failures", "errors", "skipped")},
                "owningSourceNewerThanLatestReport": latest_java > report_latest,
                "limitation": "JUnit files are evidence of their recorded runs; they do not prove deployment, business UAT or Win7 acceptance."},
            "flutterHistoricalLog": flutter_fact, "localDesktopArtifacts": artifacts,
            "notProven": ["full native ERP workflows", "Win7 x86 real-machine acceptance", "Win7 x64 real-machine acceptance",
                          "full installer/bootstrap/updater integration", "formal paired distribution or production activation"],
            "mergeMainAllowed": False, "productionDeploymentAllowed": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    result = collect()
    if args.write:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"branch": result["branch"], "sourceFiles": len(result["sourceFiles"]),
                      "sourceSnapshotSha256": result["sourceSnapshotSha256"],
                      "backendTotals": result["backendReports"]["totals"],
                      "backendSourceNewerThanReports": result["backendReports"]["owningSourceNewerThanLatestReport"],
                      "flutterReportedPasses": result["flutterHistoricalLog"].get("reportedPassedCount"),
                      "win7Accepted": False, "mergeMainAllowed": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
