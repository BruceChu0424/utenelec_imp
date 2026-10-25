#!/usr/bin/env python3
"""Build an auditable, offline derivative of an immutable legacy CSV export.

No database connections. Unit labels are not conversion factors: references may
change, but quantities, frozen rates, prices, amounts and actual weights never do.
The caller must verify the raw export manifest before calling this preparation.
"""
from __future__ import annotations

import argparse
import collections
import csv
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
import shutil

UNIT_COLUMNS = {"unitid", "unit_legacy_id", "unit_legacy"}
COLOR_COLUMNS = {"mcolorid", "colorid", "color_legacy_id", "color_legacy",
                 "mcolor_legacy_id", "m_color_legacy_id", "parent_color_legacy_id"}
GOODS_COLUMNS = ("goods_legacy_id", "goods_legacy", "ID", "legacy_id")
UNIT_NAMES = {"个", "套", "只", "本", "件", "条", "支", "张", "平方", "把", "顶",
              "部", "台", "瓶", "块", "组", "kg", "g", "斤", "卷", "包", "米"}
UNIT_ALIASES = {"千克": "kg", "公斤": "kg", "克": "g"}
COLOR_ALIASES = {"兰色": "蓝色", "透明色": "透明", "透明蓝色": "透明蓝"}
WAREHOUSE_NAMES = {
    "仓库（14年版）": "主仓库", "原材料不良仓（14年版）": "原材料不良品仓库",
    "成品不良品仓": "成品不良品仓库", "轨道车间": "轨道车间仓库",
}
WORKSHOP_WAREHOUSE_REFERENCES = {
    "五金车间": {"workshop_code": "WS_WJTZ", "workshop_name": "五金铜铸车间"},
}
RETIRED_WAREHOUSE_CODES = {"WH000009"}
STABLE_WAREHOUSE_CODES = dict(zip(
    ("001", "002", "01", "C01", "C04", "C0401", "XW01", "XW02"),
    (f"WH{index:06d}" for index in range(1, 9))))


def warehouse_label_key(value):
    return re.sub(r"\s+", "", clean(value)).replace("（", "(").replace("）", ")").casefold()


def workshop_warehouse_reference(value):
    return next((dict(reference) for label, reference in WORKSHOP_WAREHOUSE_REFERENCES.items()
                 if warehouse_label_key(label) == warehouse_label_key(value)), None)


def ordinary_warehouse_targets(records):
    """Reviewed real warehouses win; a workshop hint never creates a TARGET."""
    result = {}
    for row in records:
        if row["action"] not in ("KEEP", "MERGE", "TARGET"):
            continue
        if row["target_code"] in RETIRED_WAREHOUSE_CODES | {"XW03"}:
            raise ValueError("Retired WH000009/XW03 cannot be reused as an import target")
        if row["action"] == "TARGET" and workshop_warehouse_reference(row["target_name"]):
            raise ValueError("Workshop reference requires unified bin opening, not a synthetic ordinary TARGET")
        if workshop_warehouse_reference(row["target_name"]) and not row.get("legacy_id"):
            raise ValueError("An ordinary workshop-named warehouse needs an actual reviewed legacy identity")
        if row.get("target_defective", "false").lower() != "false":
            continue
        key = warehouse_label_key(row["target_name"])
        if key in result and result[key] != row["target_code"]:
            raise ValueError("Ambiguous target warehouse name: " + row["target_name"])
        result[key] = row["target_code"]
    return result


def classify_owning_warehouse(value, ordinary):
    key = warehouse_label_key(value)
    if key in ordinary:
        return "ORDINARY", ordinary[key], None
    reference = workshop_warehouse_reference(value)
    if reference:
        return "WORKSHOP_REFERENCE", None, reference
    return "UNMAPPED", None, None


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def clean(value: str) -> str:
    return "".join(c for c in (value or "") if ord(c) >= 32).strip()


def name_key(value: str) -> str:
    return re.sub(r"\s+", "", clean(value))


def unit_name(value: str) -> str:
    value = clean(value)
    return UNIT_ALIASES.get(value, value)


def color_name(value: str) -> str:
    value = clean(value).rstrip(".，,。 ")
    if not value:
        return "未注明颜色"
    return COLOR_ALIASES.get(value, value)


def rows(path: Path):
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="|")
        headers = reader.fieldnames or []
        if len(headers) != len(set(headers)):
            raise ValueError(f"duplicate CSV columns: {path.name}")
        for number, row in enumerate(reader, 2):
            if None in row or any(value is None for value in row.values()):
                raise ValueError(f"CSV width mismatch: {path.name}:{number}")
            yield row


def write_csv(path: Path, headers: list[str], records):
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=headers, delimiter="|", lineterminator="\n")
        writer.writeheader()
        writer.writerows(records)


def excel_facts(directory: Path | None):
    facts = {"units": set(), "colors": set(), "by_name": collections.defaultdict(set)}
    files = []
    if directory is None:
        return facts, files
    import xlrd
    for path in sorted(directory.glob("*.xls")):
        book = xlrd.open_workbook(path, on_demand=True)
        sheet = book.sheet_by_name("产品列表")
        headers = [str(value).strip() for value in sheet.row_values(0)]
        for needed in ("产品名称", "基本单位", "颜色"):
            if headers.count(needed) != 1:
                raise ValueError(f"Excel column absent or repeated: {path.name}:{needed}")
        for index in range(1, sheet.nrows):
            name = str(sheet.cell_value(index, headers.index("产品名称")))
            unit = unit_name(str(sheet.cell_value(index, headers.index("基本单位"))))
            color = str(sheet.cell_value(index, headers.index("颜色"))).strip()
            if unit:
                if unit not in UNIT_NAMES:
                    raise ValueError(f"unreviewed Excel unit: {path.name}:{index + 1}:{unit}")
                facts["units"].add(unit)
                facts["by_name"][name_key(name)].add(unit)
            if color:
                facts["colors"].add(color_name(color))
        files.append({"file": path.name, "sha256": digest(path)})
        book.release_resources()
    return facts, files


def dictionaries(source: Path, facts: dict):
    old_units, old_colors = list(rows(source / "unit.csv")), list(rows(source / "color.csv"))
    by_unit, unit_map, dropped_units = {}, {}, []
    for row in sorted(old_units, key=lambda r: int(r["legacy_id"])):
        name = unit_name(row["name"])
        if name not in UNIT_NAMES:
            unit_map[row["legacy_id"]] = None
            dropped_units.append(row)
            continue
        if name not in by_unit:
            by_unit[name] = {**row, "name": name}
        unit_map[row["legacy_id"]] = by_unit[name]["legacy_id"]
    if any(int(row["legacy_id"]) <= 0 for row in old_units + old_colors):
        raise ValueError("raw dictionaries must contain positive source identities")
    # Negative identities are derived-only anchors, disjoint from SQL Server
    # identity values and from deleted historical masters still in documents.
    next_id = -1_000_001
    for name in sorted(facts["units"]):
        if name not in by_unit:
            by_unit[name] = {"legacy_id": str(next_id), "name": name, "status": "使用"}
            next_id -= 1
    units = sorted(by_unit.values(), key=lambda row: (int(row["legacy_id"]) < 0, abs(int(row["legacy_id"]))))
    for index, row in enumerate(units, 1):
        row["code"] = f"DW{index:06d}"

    by_color, color_map, dropped_colors = {}, {}, []
    for row in sorted(old_colors, key=lambda r: int(r["legacy_id"])):
        name = color_name(row["name"])
        # Numeric labels carry no known shade. Referenced ones become explicitly
        # unknown, never a guessed white/black; original labels stay in mapping.
        if re.fullmatch(r"[0-9.]+", name):
            name = "未注明颜色"
        if name_key(name) in {"颜色", "无颜色名称"}:
            name = "未注明颜色"
        key = name.casefold()
        if key not in by_color:
            by_color[key] = {**row, "name": name}
        elif row.get("status") == "使用":
            by_color[key]["status"] = "使用"
        color_map[row["legacy_id"]] = by_color[key]["legacy_id"]
        if re.fullmatch(r"[0-9.]+", clean(row["name"])) or name_key(row["name"]) == "颜色":
            dropped_colors.append(row)
    next_id = -2_000_001
    for name in sorted(facts["colors"]):
        if name.casefold() not in by_color:
            by_color[name.casefold()] = {"legacy_id": str(next_id), "name": name, "status": "使用"}
            next_id -= 1
    colors = sorted(by_color.values(), key=lambda row: (int(row["legacy_id"]) < 0, abs(int(row["legacy_id"]))))
    for index, row in enumerate(colors, 1):
        row["code"] = f"YS{index:06d}"
    return units, colors, unit_map, color_map, dropped_units, dropped_colors


def goods_unit_map(source: Path, facts: dict, units: list[dict], unit_map: dict):
    unit_ids = {row["name"]: row["legacy_id"] for row in units}
    result, evidence = {}, []
    for row in rows(source / "goods.csv"):
        identity = row.get("ID", row.get("legacy_id"))
        unit = row.get("UnitID", row.get("unit_legacy_id", ""))
        if unit in ("", "0"):
            continue
        target = unit_map.get(unit)
        if target is None:
            values = facts["by_name"].get(name_key(row.get("Goods_Name", row.get("name", ""))), set())
            if len(values) != 1:
                raise ValueError(f"invalid base unit needs exact Excel evidence: goods={identity}, unit={unit}")
            target = unit_ids[next(iter(values))]
            evidence.append({"goods_legacy_id": identity, "old_unit": unit, "new_unit": target,
                             "reason": "EXACT_EXCEL_NAME_UNIQUE_BASE_UNIT"})
        result[identity] = target
    return result, evidence


def warehouse_crosswalk(path: Path):
    records = list(rows(path))
    ordinary_warehouse_targets(records)
    root = [row for row in records if row["action"] == "SPLIT"]
    if len(root) != 1:
        raise ValueError("warehouse crosswalk must contain exactly one SPLIT")
    targets = {row["target_code"] for row in records if row["action"] != "DROP"}
    ordered = [root[0]["target_code"]] + sorted(targets - {root[0]["target_code"]})
    if any(old in STABLE_WAREHOUSE_CODES or old in STABLE_WAREHOUSE_CODES.values() for old in ordered):
        codes = {old: STABLE_WAREHOUSE_CODES.get(old, old) for old in ordered
                 if old in STABLE_WAREHOUSE_CODES or old in STABLE_WAREHOUSE_CODES.values()}
        next_code = 10
        for old in ordered:
            if old not in codes:
                while f"WH{next_code:06d}" in set(codes.values()) | RETIRED_WAREHOUSE_CODES:
                    next_code += 1
                codes[old] = f"WH{next_code:06d}"
                next_code += 1
    else:
        codes, next_code = {}, 1
        for old in ordered:
            while f"WH{next_code:06d}" in RETIRED_WAREHOUSE_CODES:
                next_code += 1
            codes[old] = f"WH{next_code:06d}"
            next_code += 1
    for row in records:
        if row["action"] != "DROP":
            row["target_code"] = codes[row["target_code"]]
            row["target_name"] = WAREHOUSE_NAMES.get(row["target_name"], row["target_name"])
    # Real old warehouses retain their identities. Workshop-reference labels
    # are preserved separately; they never imply an ordinary or opened bin.
    hardware = {row["target_code"] for row in records if row["target_name"] == "五金仓库"}
    if len(hardware) != 1:
        raise ValueError("crosswalk must define exactly one 五金仓库")
    return records, codes


def rewrite_row(row: dict, filename: str, unit_map: dict, color_map: dict,
                goods_units: dict, audit: collections.Counter):
    result = dict(row)
    for column, value in row.items():
        kind = column.lower()
        if value in ("", "0"):
            continue
        if kind in UNIT_COLUMNS | COLOR_COLUMNS and int(value) <= 0:
            raise ValueError(f"raw reference is outside the legacy identity domain: {filename}:{value}")
        if kind in UNIT_COLUMNS:
            if value not in unit_map:
                raise ValueError(f"missing raw unit identity: {filename}:{value}")
            target = unit_map[value]
            if target is None:
                rate = row.get("unit_rate", row.get("urate", ""))
                if rate.strip() and Decimal(rate) != 1:
                    raise ValueError(f"polluted unit has an unproven non-1 conversion rate: {filename}:{value}")
                goods_id = next((row[key] for key in GOODS_COLUMNS if key in row), None)
                target = goods_units.get(goods_id)
                if target is None:
                    raise ValueError(f"invalid transaction unit cannot resolve goods: {filename}:{value}")
            result[column] = target
        elif kind in COLOR_COLUMNS:
            if value not in color_map:
                # Missing historical master remains an explicit historical
                # anchor in the existing loader, never remapped by name.
                continue
            result[column] = color_map[value]
        if result[column] != value:
            audit[(filename, column, value, result[column])] += 1
    return result


def merge_stock_balances(path: Path, color_map: dict):
    latest, raw_count, same_year_rows, fact_qty_fallbacks = {}, 0, 0, 0
    numeric = ("qty", "fact_qty", "total", "weight", "fact_weight")
    for row in rows(path):
        raw_count += 1
        if not row["fact_qty"].strip():
            # Exactly the existing stock loader's COALESCE(FactQTY,QTY),
            # including a real zero FactQTY remaining zero.
            row["fact_qty"] = row["qty"] or "0"
            fact_qty_fallbacks += 1
        key = row["stock_legacy"], row["goods_legacy"], row["color_legacy"]
        previous = latest.get(key)
        if previous is None or int(row["year"]) > int(previous["year"]):
            latest[key] = row
        elif row["year"] == previous["year"]:
            # The export omits StockGoods' storage-place dimension; the
            # authoritative loader explicitly SUMs same-year place rows.
            for column in numeric:
                previous[column] = str(Decimal(previous[column] or "0") + Decimal(row[column] or "0"))
            same_year_rows += 1
    result, before = {}, collections.Counter()
    for row in latest.values():
        new_color = color_map.get(row["color_legacy"], row["color_legacy"])
        key = row["stock_legacy"], row["goods_legacy"], new_color
        for column in numeric:
            before[column] += Decimal(row[column] or "0")
        if key not in result:
            result[key] = {**row, "color_legacy": new_color}
        else:
            target = result[key]
            target["year"] = str(max(int(row["year"]), int(target["year"])))
            for column in numeric:
                target[column] = str(Decimal(target[column] or "0") + Decimal(row[column] or "0"))
    after = {column: sum((Decimal(row[column] or "0") for row in result.values()), Decimal(0))
             for column in numeric}
    if any(before[column] != after[column] for column in numeric):
        raise ValueError("stock balance consolidation changed numeric facts")
    return list(result.values()), {"raw_rows": raw_count, "original_latest_rows": len(latest),
                                  "normalized_latest_rows": len(result),
                                  "same_year_place_rows_aggregated": same_year_rows,
                                  "fact_qty_null_fallbacks": fact_qty_fallbacks,
                                  "numeric_totals_before": {key: str(value) for key, value in before.items()},
                                  "numeric_totals_after": {key: str(value) for key, value in after.items()}}


def prepare(source: Path, output: Path, excel_dir: Path | None, crosswalk: Path):
    source, output = source.resolve(), output.resolve()
    if source == output or source in output.parents:
        raise ValueError("derived output must be outside the immutable source directory")
    if output.exists() and any(output.iterdir()):
        raise ValueError("derived output directory must be empty")
    output.mkdir(parents=True, exist_ok=True)
    facts, excel_files = excel_facts(excel_dir)
    units, colors, unit_map, color_map, removed_units, removed_colors = dictionaries(source, facts)
    goods_units, evidence = goods_unit_map(source, facts, units, unit_map)
    crosswalk_rows, warehouse_codes = warehouse_crosswalk(crosswalk)
    headers = ["legacy_id", "code", "name", "status"]
    write_csv(output / "unit.csv", headers, units)
    write_csv(output / "color.csv", headers, colors)
    write_csv(output / "warehouse_crosswalk.csv", list(crosswalk_rows[0]), crosswalk_rows)
    audit, input_files, output_files = collections.Counter(), [], []
    balance_audit = None
    for path in sorted(source.glob("*.csv")):
        input_files.append({"file": path.name, "sha256": digest(path)})
        if path.name in ("unit.csv", "color.csv"):
            continue
        with path.open(encoding="utf-8-sig", newline="") as handle:
            file_headers = next(csv.reader(handle, delimiter="|"))
        if path.name == "stock_goods.csv":
            balances, balance_audit = merge_stock_balances(path, color_map)
            write_csv(output / path.name, file_headers, balances)
            actions = {row["legacy_id"]: row["action"] for row in crosswalk_rows if row["legacy_id"]}
            warehouse_summary = {}
            negative_rows = []
            for row in balances:
                warehouse = row["stock_legacy"]
                if warehouse not in actions:
                    raise ValueError(f"stock balance uses unreviewed warehouse: {warehouse}")
                action = actions[warehouse]
                qty = Decimal(row["fact_qty"] or "0")
                amount = Decimal(row["total"] or "0")
                summary = warehouse_summary.setdefault(warehouse, {
                    "warehouse_legacy_id": warehouse, "action": action, "rows": 0,
                    "nonzero_rows": 0, "negative_rows": 0, "fact_qty_checksum": Decimal(0),
                    "amount_checksum": Decimal(0), "minimum_fact_qty": qty, "maximum_fact_qty": qty})
                summary["rows"] += 1
                summary["nonzero_rows"] += qty != 0
                summary["negative_rows"] += qty < 0
                summary["fact_qty_checksum"] += qty
                summary["amount_checksum"] += amount
                summary["minimum_fact_qty"] = min(summary["minimum_fact_qty"], qty)
                summary["maximum_fact_qty"] = max(summary["maximum_fact_qty"], qty)
                if qty < 0:
                    negative_rows.append({**row, "warehouse_action": action,
                                          "resolution": "EXCLUDED_DELETED_WAREHOUSE" if action == "DROP"
                                          else "REVIEW_REQUIRED_PRESERVED_NEGATIVE_FACT"})
            for summary in warehouse_summary.values():
                for key, value in summary.items():
                    if isinstance(value, Decimal):
                        summary[key] = str(value)
            summary_rows = sorted(warehouse_summary.values(), key=lambda row: int(row["warehouse_legacy_id"]))
            write_csv(output / "stock_balance_warehouse_audit.csv", list(summary_rows[0]) if summary_rows else
                      ["warehouse_legacy_id", "action", "rows"], summary_rows)
            write_csv(output / "stock_balance_negative_exceptions.csv", file_headers + ["warehouse_action", "resolution"], negative_rows)
            balance_audit["warehouse_summary"] = summary_rows
            balance_audit["negative_fact_policy"] = "preserve; never zero, take absolute value, or infer a new opening balance"
            balance_audit["checksum_warning"] = "quantity checksums mix units; diagnostic conservation checks only, not business inventory totals"
        elif path.name == "warehouse.csv":
            lookup = {row["legacy_id"]: row for row in crosswalk_rows if row["legacy_id"]}
            records = []
            for row in rows(path):
                mapping = lookup.get(row["legacy_id"])
                if mapping is None:
                    raise ValueError(f"unreviewed warehouse: {row['legacy_id']}")
                if mapping["action"] != "DROP":
                    row = {**row, "code": mapping["target_code"], "name": mapping["target_name"]}
                records.append(row)
            write_csv(output / path.name, file_headers, records)
        elif not (set(column.lower() for column in file_headers) & (UNIT_COLUMNS | COLOR_COLUMNS)):
            shutil.copy2(path, output / path.name)
        else:
            write_csv(output / path.name, file_headers,
                      (rewrite_row(row, path.name, unit_map, color_map, goods_units, audit) for row in rows(path)))
    audit_rows = [{"file": key[0], "column": key[1], "old_id": key[2], "new_id": key[3], "rows": count}
                  for key, count in sorted(audit.items())]
    write_csv(output / "master_reference_changes.csv", ["file", "column", "old_id", "new_id", "rows"], audit_rows)
    mapping = {"unit_id_map": unit_map, "color_id_map": color_map, "warehouse_code_map": warehouse_codes,
               "goods_base_unit_repairs": evidence, "removed_invalid_unit_rows": removed_units,
               "removed_polluted_color_labels": removed_colors, "stock_balance_consolidation": balance_audit,
               "numeric_transaction_facts_changed": 0, "main_warehouse_code": "WH000001",
               "derived_identity_namespaces": {"unit": "negative from -1000001", "color": "negative from -2000001"}}
    (output / "master_mapping.json").write_text(json.dumps(mapping, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for path in sorted(output.glob("*.csv")):
        output_files.append({"file": path.name, "sha256": digest(path)})
    manifest = {"format": "uten-clean-master-derivative-v1", "raw_directory": str(source),
                "raw_manifest_sha256": digest(source / "export_manifest.json") if (source / "export_manifest.json").exists() else None,
                "preprocessor_sha256": digest(Path(__file__)), "crosswalk_sha256": digest(crosswalk),
                "inputs": input_files, "excel_inputs": excel_files, "outputs": output_files,
                "master_mapping_sha256": digest(output / "master_mapping.json")}
    (output / "clean_master_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return {"units": len(units), "colors": len(colors), "reference_rewrites": sum(audit.values()),
            "base_unit_repairs": len(evidence), "warehouse_targets": len(warehouse_codes), "output": str(output),
            "stock_balance_consolidation": balance_audit}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--excel-dir", type=Path)
    parser.add_argument("--crosswalk", type=Path, default=Path(__file__).with_name("warehouse_crosswalk.csv"))
    args = parser.parse_args()
    print(json.dumps(prepare(args.source_dir, args.output_dir, args.excel_dir, args.crosswalk), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
