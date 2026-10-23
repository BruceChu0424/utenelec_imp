#!/usr/bin/env python3
"""Audit proposed goods base-unit changes without changing any numeric fact.

An Excel unit/rate describes the Excel base; it does not prove that historical
stock quantities, BOM quantities, or frozen document rates used that same base.
Even an explicit package conversion remains a review proposal until every
affected historical quantity and inverse price transformation is approved.
"""
from __future__ import annotations

from collections import Counter, defaultdict
import csv
from decimal import Decimal, InvalidOperation
import hashlib
import json
from pathlib import Path


GOODS_COLUMNS = {"goods_legacy_id", "goods_legacy", "component_legacy_id", "mgoods_legacy_id",
                 "m_goods_legacy_id", "parent_goods_legacy_id", "alt_goods_legacy_id", "alt_goods_legacy"}
DIRECT_COLUMNS = {"goods_legacy_id", "goods_legacy"}
UNIT_COLUMNS = ("unit_legacy_id", "unit_legacy", "UnitID")
RATE_COLUMNS = ("unit_rate", "urate", "URate")


def digest(path: Path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def records(path: Path):
    with path.open(encoding="utf-8-sig", newline="") as handle:
        yield from csv.DictReader(handle, delimiter="|")


def number(value):
    try:
        result = Decimal(value)
        return result if result.is_finite() else None
    except (InvalidOperation, ValueError, TypeError):
        return None


def write_csv(path, fields, rows):
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="|", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def audit(source: Path, output: Path, candidates: list[dict], excel: list[dict], units: dict[str, str]):
    """Return consumed files and summary; emit per-goods and aggregated evidence."""
    by_id = {row["legacy_id"]: row for row in candidates}
    by_code = {row["code"]: row for row in candidates}
    aggregate = Counter()
    references = Counter()
    balances = defaultdict(lambda: Counter())
    historical_units = defaultdict(set)
    consumed = []
    stock_evidence = []
    for path in sorted(source.glob("*.csv")):
        if path.name == "goods.csv":
            continue
        with path.open(encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="|")
            fields = reader.fieldnames or []
            goods_columns = GOODS_COLUMNS & set(fields)
            if not goods_columns:
                continue
            before = digest(path)
            consumed.append(path)
            unit_column = next((field for field in UNIT_COLUMNS if field in fields), None)
            rate_column = next((field for field in RATE_COLUMNS if field in fields), None)
            for row_number, row in enumerate(reader, 2):
                for column in sorted(goods_columns):
                    identity = row[column]
                    if identity not in by_id:
                        continue
                    references[identity] += 1
                    # A secondary parent/component does not inherit the main
                    # item's unit or rate snapshot. Preserve that distinction.
                    direct = column in DIRECT_COLUMNS and path.name != "goods_bom.csv"
                    unit = row.get(unit_column, "") if direct else ""
                    rate = row.get(rate_column, "") if direct else ""
                    scope = "direct_goods_snapshot" if direct and unit_column else "base_quantity_without_unit_snapshot"
                    aggregate[(identity, path.name, column, scope, unit, rate)] += 1
                    if unit not in ("", "0"):
                        historical_units[identity].add(unit)
                    if path.name == "stock_goods.csv" and column in DIRECT_COLUMNS:
                        stock = balances[identity]
                        stock["all_stock_keys"] += 1
                        fact_qty = number(row.get("fact_qty"))
                        if fact_qty is None:
                            fact_qty = number(row.get("qty"))
                        main = row.get("stock_legacy") == "132"
                        stock["nonzero_stock_keys"] += fact_qty is not None and fact_qty != 0
                        stock["main_stock_keys"] += main
                        stock["nonzero_main_stock_keys"] += main and fact_qty is not None and fact_qty != 0
                        stock_evidence.append({"legacy_id": identity, "code": by_id[identity]["code"],
                                               "source_row": row_number, **row,
                                               "quantity_base": "RETAIN_LEGACY_BASE_UNIT_NO_CONVERSION"})
            if before != digest(path):
                raise ValueError(f"Quantity evidence changed while reading: {path}")
    strategies = defaultdict(list)
    strategy_evidence = []
    for record in excel:
        code = record["values"].get("产品编号") or record.get("parent_code")
        if code not in by_code:
            continue
        values = record["values"]
        item = {"file": record["file"], "row": record["row"], "source_name": values.get("产品名称", ""),
                "unit": values.get("单位", ""), "ratio_to_excel_base": values.get("比例", ""),
                "excel_base_unit": values.get("基本单位", ""), "included_units": values.get("包含单位", ""),
                "sale_price": values.get("建议售价", ""), "unit_weight_grams": values.get("单重（克）", "")}
        strategies[code].append(item)
        strategy_evidence.append({"legacy_id": by_code[code]["legacy_id"], "code": code, **item})
    review = []
    for candidate in candidates:
        identity, code = candidate["legacy_id"], candidate["code"]
        legacy_name = units.get(candidate["legacy_unit_id"], "#" + candidate["legacy_unit_id"])
        excel_name = units.get(candidate["excel_unit_id"], candidate["excel_unit"])
        explicit = []
        for strategy in strategies[code]:
            ratio = number(strategy["ratio_to_excel_base"])
            if strategy["unit"] == legacy_name and ratio is not None and ratio > 0:
                explicit.append(str(ratio))
        package_factor = explicit[0] if explicit and len(set(explicit)) == 1 else ""
        # No arithmetic conversion is authorized by this audit. A factor alone
        # cannot prove the base of historical rows lacking unit snapshots.
        row = {**candidate, "legacy_unit": legacy_name, "effective_unit_id": candidate["legacy_unit_id"],
               "effective_unit": legacy_name, "proposed_excel_unit": excel_name,
               "excel_units_per_legacy_unit_proposal": package_factor,
               "historical_unit_names": json.dumps(sorted(units.get(unit, "#" + unit) for unit in historical_units[identity]), ensure_ascii=False),
               "reference_rows": references[identity],
               **dict.fromkeys(("all_stock_keys", "nonzero_stock_keys", "main_stock_keys", "nonzero_main_stock_keys"), 0),
               **balances[identity], "resolution": "RETAIN_LEGACY_BASE_UNIT_PENDING_ENGINEERING_RECONCILIATION",
               "reason": "EXPLICIT_EXCEL_FACTOR_WITHOUT_CLOSED_HISTORICAL_RECONCILIATION" if package_factor else "NO_EXPLICIT_LEGACY_TO_EXCEL_UNIT_CONVERSION",
               "numeric_facts_changed": 0}
        review.append(row)
    review_fields = ["legacy_id", "code", "name", "legacy_unit_id", "legacy_unit", "excel_unit_id", "excel_unit",
                     "effective_unit_id", "effective_unit", "proposed_excel_unit", "excel_units_per_legacy_unit_proposal",
                     "historical_unit_names", "reference_rows", "all_stock_keys", "nonzero_stock_keys", "main_stock_keys",
                     "nonzero_main_stock_keys", "resolution", "reason", "numeric_facts_changed"]
    write_csv(output / "goods_quantity_unit_review.csv", review_fields, review)
    evidence = [{"legacy_id": identity, "code": by_id[identity]["code"], "source_file": filename,
                 "goods_column": column, "unit_scope": scope, "unit_id": unit, "unit_name": units.get(unit, ""),
                 "unit_rate_snapshot": rate, "source_rows": count}
                for (identity, filename, column, scope, unit, rate), count in sorted(aggregate.items())]
    write_csv(output / "goods_quantity_unit_history_evidence.csv", ["legacy_id", "code", "source_file", "goods_column",
              "unit_scope", "unit_id", "unit_name", "unit_rate_snapshot", "source_rows"], evidence)
    write_csv(output / "goods_quantity_unit_excel_evidence.csv", ["legacy_id", "code", "file", "row", "source_name",
              "unit", "ratio_to_excel_base", "excel_base_unit", "included_units", "sale_price", "unit_weight_grams"], strategy_evidence)
    stock_fields = ["legacy_id", "code", "source_row"] + sorted({field for row in stock_evidence for field in row} - {"legacy_id", "code", "source_row", "quantity_base"}) + ["quantity_base"]
    write_csv(output / "goods_quantity_unit_stock_evidence.csv", stock_fields, stock_evidence)
    summary = {"candidate_goods": len(review), "retained_legacy_base_units": len(review), "numeric_facts_changed": 0,
               "with_explicit_excel_conversion_proposal": sum(bool(row["excel_units_per_legacy_unit_proposal"]) for row in review),
               "unit_transition_counts": dict(Counter(row["legacy_unit"] + " -> " + row["proposed_excel_unit"] for row in review)),
               "reference_rows": sum(references.values()),
               **{field: sum(row[field] for row in review) for field in ("all_stock_keys", "nonzero_stock_keys", "main_stock_keys", "nonzero_main_stock_keys")}}
    (output / "goods_quantity_unit_review_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return consumed, summary
