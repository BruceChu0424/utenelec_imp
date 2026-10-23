#!/usr/bin/env python3
"""Evidence report for main-warehouse stock without an Excel owning warehouse.

Produces a separate proposed mapping; never changes clean inputs or a database.
Two agreeing independent source families are required for a corroborated proposal.
Missing/contradictory evidence remains explicitly unresolved, with signed facts.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from decimal import Decimal
import json
from pathlib import Path

from prepare_clean_master_data import digest, rows, write_csv


def audit(clean: Path, overlay: Path, output: Path):
    if output.exists() and any(output.iterdir()):
        raise ValueError("audit output directory must be empty")
    output.mkdir(parents=True, exist_ok=True)
    goods = {row.get("legacy_id", row.get("ID")): row for row in rows(clean / "goods.csv")}
    owning = {row["goods_legacy_id"]: row["warehouse_code"] for row in rows(overlay / "goods_owning_warehouse.csv")}
    crosswalk = list(rows(clean / "warehouse_crosswalk.csv"))
    main = next(row["legacy_id"] for row in crosswalk if row["action"] == "SPLIT")
    leaf_codes = {row["legacy_id"]: row["target_code"] for row in crosswalk
                  if row["legacy_id"] and row["action"] in ("KEEP", "MERGE")
                  and row["target_defective"].lower() == "false"}
    categories = defaultdict(Counter)
    for identity, row in goods.items():
        if identity in owning:
            categories[row.get("parent_legacy", row.get("ParentID", ""))][owning[identity]] += 1
    balances = list(rows(clean / "stock_goods.csv"))
    main_facts, other_leaf = defaultdict(list), defaultdict(set)
    for row in balances:
        if Decimal(row["fact_qty"] or "0") == 0 and Decimal(row["total"] or "0") == 0:
            continue
        identity = row["goods_legacy"]
        if row["stock_legacy"] == main and identity not in owning:
            main_facts[identity].append(row)
        elif row["stock_legacy"] in leaf_codes:
            other_leaf[identity].add(leaf_codes[row["stock_legacy"]])
    proposals, facts, supplemental = [], [], []
    for identity in sorted(main_facts, key=int):
        row = goods.get(identity, {})
        evidence = {}
        old_warehouse = row.get("ck", "")
        if old_warehouse in leaf_codes:
            evidence["LEGACY_GOODS_CK_ACTIVE_LEAF"] = {leaf_codes[old_warehouse]}
        category = row.get("parent_legacy", row.get("ParentID", ""))
        siblings = categories[category] if category not in ("", "0") else Counter()
        if len(siblings) == 1 and sum(siblings.values()) >= 3:
            evidence["EXACT_CATEGORY_UNANIMOUS_EXCEL_SIBLINGS"] = set(siblings)
        if other_leaf[identity]:
            evidence["OTHER_ACTIVE_LEAF_LATEST_NONZERO_STOCK"] = other_leaf[identity]
        destinations = set().union(*evidence.values()) if evidence else set()
        accepted = len(evidence) >= 2 and len(destinations) == 1 and bool(row)
        target = next(iter(destinations)) if len(destinations) == 1 else ""
        status = ("CORROBORATED_PROPOSAL" if accepted else "CONFLICT_REVIEW" if len(destinations) > 1
                  else "SINGLE_SOURCE_REVIEW" if evidence else "NO_WAREHOUSE_EVIDENCE")
        proposals.append({"goods_legacy_id": identity, "goods_code": row.get("code", row.get("ANumber", "")),
                          "goods_name": row.get("name", row.get("Goods_Name", "")),
                          "category_legacy_id": category, "legacy_goods_ck": old_warehouse,
                          "status": status, "proposed_warehouse_code": target,
                          "evidence": json.dumps({key: sorted(value) for key, value in evidence.items()}, ensure_ascii=False),
                          "excel_sibling_distribution": json.dumps(dict(siblings), ensure_ascii=False),
                          "original_master_present": str(bool(row)).lower()})
        if accepted:
            supplemental.append({"goods_legacy_id": identity, "warehouse_code": target})
        for balance in main_facts[identity]:
            facts.append({**balance, "review_status": status, "proposed_warehouse_code": target,
                          "source_master_present": str(bool(row)).lower()})
    proposal_headers = ["goods_legacy_id", "goods_code", "goods_name", "category_legacy_id", "legacy_goods_ck",
                        "status", "proposed_warehouse_code", "evidence", "excel_sibling_distribution", "original_master_present"]
    write_csv(output / "unassigned_warehouse_evidence.csv", proposal_headers, proposals)
    write_csv(output / "unassigned_stock_facts.csv", list(balances[0]) +
              ["review_status", "proposed_warehouse_code", "source_master_present"] if balances else ["goods_legacy"], facts)
    write_csv(output / "corroborated_owning_warehouse_proposals.csv", ["goods_legacy_id", "warehouse_code"], supplemental)
    summary = {"format": "uten-unassigned-warehouse-evidence-v1", "unassigned_goods": len(main_facts),
               "unassigned_dimension_rows": len(facts), "status_counts": dict(Counter(row["status"] for row in proposals)),
               "missing_original_goods_masters": sum(not goods.get(identity) for identity in main_facts),
               "automatic_input_changes": 0,
               "policy": "corroborated mappings are proposals; unresolved signed balances are retained, never zeroed or discarded",
               "inputs": {str(path): digest(path) for path in (clean / "goods.csv", clean / "stock_goods.csv",
                          clean / "warehouse_crosswalk.csv", overlay / "goods_owning_warehouse.csv")}}
    (output / "unassigned_warehouse_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clean-dir", type=Path, required=True)
    parser.add_argument("--overlay-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(audit(args.clean_dir, args.overlay_dir, args.output_dir), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
