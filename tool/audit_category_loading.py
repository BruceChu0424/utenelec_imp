"""Source-backed category/table consumer inventory; never infers runtime acceptance."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/99-项目治理/全平台整改交接/evidence/category-loading-20261101/coverage.json"


def record(path: Path, text: str, markers: tuple[str, ...]) -> dict:
    return {
        "source": path.relative_to(ROOT).as_posix(),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "lines": [i for i, line in enumerate(text.splitlines(), 1) if any(marker in line for marker in markers)],
    }


def inventory() -> dict:
    documents, categories, reads, facts = [], [], [], []
    for path in sorted((ROOT / "lib/features").rglob("*.dart")):
        text = path.read_text(encoding="utf-8-sig")
        if "effectiveDocumentStatusCountsProvider" in text:
            documents.append(record(path, text, ("effectiveDocumentStatusCountsProvider", "DocumentStatusScope")))
        if "MasterDataTableView" in text and any(marker in text for marker in (
            "UtenFilterToolbar", "UtenSegmentBadgeLabel", "_categoryCounts", "_statusCounts")):
            categories.append(record(path, text, ("UtenFilterToolbar", "UtenSegmentBadgeLabel", "_categoryCounts", "_statusCounts")))
        if any(marker in text for marker in ("api.get(", "_api.get(", "api.getList(", "_api.getList(")):
            reads.append(record(path, text, (".get(", ".getList(")))
        if path.parent.name == "providers" and "badge_registry.dart" in text:
            facts.append(record(path, text, ("badgeFact", "badgeEntry", "badgeSummary", "warehouseTask")))
    work = json.loads((ROOT / "clients/windows_legacy/progress/work-items.json").read_text(encoding="utf-8-sig"))
    related = {item["source"] for item in categories + documents}
    return {
        "schemaVersion": 1,
        "baselineCommit": "bd7e8525b",
        "interpretation": "Lexical consumer inventory, not workflow count or proof of per-page interaction acceptance; see the companion verification report.",
        "publicEntries": {
            "transport": "lib/core/network/interceptors/page_read_priority_interceptor.dart",
            "documentCategories": "lib/shared/providers/document_status_counts_provider.dart",
            "categoryRetention": "lib/shared/providers/retain_read_snapshot.dart",
            "overviewReads": "lib/shared/paging/scoped_category_read.dart",
            "warehouseCategories": "lib/shared/warehouse/warehouse_task_badges.dart",
            "nativeTransport": "clients/windows_legacy/Uten.Legacy.Core/PageReadPriorityGate.cs",
        },
        "scopeContract": ["monotonic reader epoch", "account/actor/dataset", "server/API instance", "permissions", "document kind", "shipment kind", "document type", "warehouse", "keyword and domain-specific category predicates", "local write revision"],
        "documentCategoryConsumers": documents,
        "categoryTableSources": categories,
        "directFeatureApiReadSources": reads,
        "existingFactCategoryProviders": facts,
        "nativePackages": [{"id": item["id"], "source": item["businessSource"], "status": item["status"],
                            "interpretation": "Unmigrated/candidate status preserved; shared transport coverage does not finish this business package."}
                           for item in work["tasks"] if item.get("businessSource") in related],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    result = inventory()
    rendered = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.write:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(rendered, encoding="utf-8", newline="\n")
    print(json.dumps({key: len(result[key]) for key in (
        "documentCategoryConsumers", "categoryTableSources", "directFeatureApiReadSources", "existingFactCategoryProviders", "nativePackages")}, ensure_ascii=False))
