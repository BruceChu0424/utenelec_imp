"""Current loading discovery and historical-source reconciliation, not runtime acceptance."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import subprocess
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "docs/99-项目治理/全平台整改交接/evidence/loading-20261104/current-source-inventory.json"
MARKERS = {
    "pagedRows": r"PagedListController|readScopedPage|ScopedPagedRead|PagedReadCache",
    "completeResults": r"loadCompletePaged|loadCompleteCursor|withRowsFromResponsive|freezePagedRows",
    "tablePresentation": r"MasterDataTableView|UtenEditableGrid|UtenPagedGrid|UtenPickerPageControls",
    "categoriesAndCounts": r"ScopedCategoryRead|documentStatusCounts|DocumentStatusScope|badgeFact|badgeSummary",
    "preparedReads": r"PreparedPageRead|PagePreparationCoordinator|prepareNext|canPrefetch",
    "columnFacets": r"nativeFacetLoaders|MasterServerColumnFilters|loadFacetPage|NativeFacetOptions",
    "explicitReadOwnership": r"PagedReadIntent|captureRequestScope|AuthenticatedRequestScope|LatestRequestGuard",
    "completeDirectoryCandidates": r"loadAllDraftPages|activeApplications|while\s*\(true\)|totalPages",
    "asyncJoinCandidates": r"Future\.wait|ensureLoaded\(",
}


def content(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")


def record(path: Path, text: str, markers: dict[str, str]) -> dict:
    matches = {
        name: [i for i, line in enumerate(text.splitlines(), 1) if re.search(pattern, line)]
        for name, pattern in markers.items()
        if re.search(pattern, text)
    }
    return {
        "source": path.relative_to(ROOT).as_posix(),
        "normalizedSha256": hashlib.sha256(text.encode()).hexdigest(),
        "markers": matches,
    }


def inventory() -> dict:
    flutter = []
    for path in sorted((ROOT / "lib").rglob("*.dart")):
        text = content(path)
        if any(re.search(pattern, text) for pattern in MARKERS.values()):
            flutter.append(record(path, text, MARKERS))
    server_markers = {
        "routes": r"@(Get|Post|Request)Mapping",
        "paging": r"Pageables|PageResponse|Pageable|LIMIT|setMaxResults",
        "sourceIdentity": r"ImportedBusinessDocumentScope|fn_imported_business_document",
        "summaryOrMetadata": r"metadataSql|COUNT\(|count\(|summary|facets",
        "archiveLifecycle": r"archive|tiering|payload_archived_at",
    }
    server = []
    for path in sorted((ROOT / "server/src/main/java").rglob("*.java")):
        text = content(path)
        if any(re.search(pattern, text) for pattern in server_markers.values()):
            server.append(record(path, text, server_markers))
    native_markers = {
        "boundedReads": r"PageReadPriorityGate|DebouncedSearchInput|LoadPageAsync|ReadScopeRevision|CompletePagedSnapshot",
        "historyAndDrafts": r"History|Draft|Recovery",
    }
    native = []
    for path in sorted((ROOT / "clients/windows_legacy").rglob("*.cs")):
        if any(part in {"bin", "obj", "build"} for part in path.parts):
            continue
        text = content(path)
        if any(re.search(pattern, text) for pattern in native_markers.values()):
            native.append(record(path, text, native_markers))
    historical = ROOT / "docs/99-项目治理/全平台整改交接/B1-2026-10-25-查询入口覆盖清单.csv"
    with historical.open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    prior_sources = sorted({row["Controller"] for row in rows if row.get("Controller")})
    states = {
        "stillPresent": [source for source in prior_sources if (ROOT / source).is_file()],
        "requiresMoveOrRetirementReview": [source for source in prior_sources if not (ROOT / source).is_file()],
    }
    module_counts = Counter()
    for row in flutter:
        parts = row["source"].split("/")
        module_counts[parts[2] if len(parts) > 3 and parts[1] == "features" else "shared"] += 1
    return {
        "schemaVersion": 1,
        "baselineCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "interpretation": "Lexical discovery only. A marker is neither a defect nor proof of completed caller, role, scale or UI acceptance. Module reviews and executable receipts are required.",
        "runtimeAcceptance": False,
        "normalization": "UTF-8 without BOM; CRLF/CR normalized to LF",
        "flutterByModule": dict(sorted(module_counts.items())),
        "flutterCandidates": flutter,
        "serverCandidates": server,
        "nativeCandidates": native,
        "historicalReconciliation": {"entryRows": len(rows), "controllerSources": len(prior_sources), **states},
        "publicEntries": [
            "lib/core/network/api_client.dart",
            "lib/components/data_display/paged_list_controller.dart",
            "lib/shared/paging/scoped_paged_read.dart",
            "lib/shared/paging/scoped_category_read.dart",
            "lib/shared/paging/prepared_page_read.dart",
            "lib/shared/paging/page_preparation_coordinator.dart",
            "lib/features/basic_data/widgets/master_server_column_filters.dart",
            "lib/shared/providers/native_facet_options.dart",
            "lib/shared/drafts/draft_workspace_sources.dart",
            "server/src/main/java/com/uten/imp/common/history/ImportedBusinessDocumentScope.java",
        ],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = inventory()
    rendered = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.check and (not DEST.exists() or content(DEST) != rendered):
        raise SystemExit("Loading inventory is stale; regenerate from the current owning source.")
    if args.write:
        DEST.parent.mkdir(parents=True, exist_ok=True)
        DEST.write_text(rendered, encoding="utf-8", newline="\n")
    print(json.dumps({"flutterCandidates": len(result["flutterCandidates"]),
                      "serverCandidates": len(result["serverCandidates"]),
                      "nativeCandidates": len(result["nativeCandidates"]),
                      "historicalRows": result["historicalReconciliation"]["entryRows"],
                      "missingHistoricalSources": result["historicalReconciliation"]["requiresMoveOrRetirementReview"],
                      "runtimeAcceptance": False}, ensure_ascii=True))
