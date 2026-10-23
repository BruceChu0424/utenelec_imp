#!/usr/bin/env python3
"""Prepare an auditable Excel-authoritative goods overlay without a database.

Run after prepare_clean_master_data.py and before goods/BOM/transaction import.
The input goods CSV is never changed. The output retains its column order and
adds new Excel identities, while attributes absent from that schema go into a
separate SQL file to execute immediately after migrate_goods_data.sql.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from decimal import Decimal, InvalidOperation
import csv
import hashlib
import json
from pathlib import Path
import re

import xlrd

from prepare_clean_master_data import color_name, unit_name
from audit_goods_quantity_units import audit as audit_quantity_units


ROLE_MAP = {"自制件": "自制", "外购件": "采购", "委外件": "委外"}
WORKSHOPS = {"注塑车间": "注塑车间", "轨道生产车间": "轨道装配车间",
             "开关插座生产车间": "装配第一车间", "开关插座车间": "装配第一车间",
             "五金车间": "五金铜铸车间"}
ALIASES = dict(zip(
    "legacy_id code name short_name model spec parent_legacy unit_legacy_id color_legacy_id mould_legacy_id client_legacy_id vend_legacy_id vend2_legacy_id assteam_legacy_id veil_legacy_id approver_legacy_id make_legacy_id price a_price price2 max_qty min_qty init_stock init_count init_weight kqty kqty2 pieces lost_rate cap material thickness l_style z_weight m_weight pack b_pack paper series chart_id lights stock_place c_number v_number bs_test require_remark source_e work_e lacquer_e incidental_e plating_e casing_e manage_e polish_e electric_e machining_e lost_e rent_e make_e work_rate make_rate rent_rate total c_total g_total bom_status status app_status app_status2 g_style ck zk".split(),
    "ID ANumber Goods_Name Short_Name Number Standard ParentID UnitID MColorID MouldID ClientID VendID VendID2 AssTeamID VeilID ApproverID MakeID Price APrice Price2 Max_QTY Min_QTY InitStock InitCount InitWeight KQTY KQTY2 Pieces LostRate CAP Material Thickness LStyle ZWeight MWeight Pack BPack Paper Series ChartID Lights StockPlace CNumber VNumber BSTest Require SourceE WorkE LacquerE IncidentalE PlatingE CasingE ManageE PolishE ElectricE MachiningE LostE RentE MakeE WorkRate MakeRate RentRate Total CTotal GTotal BomStatus Status AppStatus AppStatus2 GStyle ck zk".split()))
TEXT_FIELDS = {"产品名称": "name", "简称": "short_name", "产品型号": "model", "规格": "spec",
               "系列": "series", "材质": "material", "客户型号": "c_number", "供应商型号": "v_number"}
DIRECT_FIELDS = {**TEXT_FIELDS, "产品编号": "code", "基本单位": "unit_legacy_id",
                 "颜色": "color_legacy_id", "模具编号": "mould_legacy_id", "关联客户": "client_legacy_id",
                 "主采购供应商": "vend_legacy_id (purchase_role)", "主委外供应商": "vend_legacy_id (subcontract_role)",
                 "供应商": "vend_legacy_id (generic_fallback)", "原ERP备注": "require_remark",
                 "默认销售折扣": "zk", "单重（克）": "m_weight", "建议售价": "price", "启用状态": "status"}
SQL_FIELDS = {"产品角色": "source_type", "所属仓库": "owning_warehouse_id",
              "生产车间": "owning_workshop_department_id", "采购入库超量上限(%)": "purchase_allowed_over_receipt_pct",
              "最小采购量": "min_order_qty", "最小包装量": "order_multiple_qty"}
# These source policies deliberately do not activate new-system workflow gates.
ARCHIVE_ONLY = {"审批状态", "产品属性", "计价方式", "自定义分组", "是否需要质检", "批号必填",
                "采购主单位", "序列号管理", "入库包装码", "建议进价", "最高进价", "最低售价",
                "产品分类", "部门", "停用", "单位", "比例", "包含单位"}
NOTE_FIELDS = {"产品说明", "产品参数", "图片与附件", "销售出库超量上限(%)", "其他供应商", "采购提前期",
               "预计销售周期", "最小分配供货量", "库存下限", "库存上限", "安全库存", "额定寿命", "寿命单位",
               "产品有效期", "有效期单位", "失效提前期", "提前期单位", "养护周期", "周期单位",
               "固定制造提前期(天)", "变动制造提前期(天)", "变动制造提前期批量", "损耗率(%)", "最小生产量",
               "主委外供应商", "产品开票名称", "产品开票型号", "享受税收优惠政策", "税收优惠政策类型",
               "税收分类编码", "税收分类名称", "是否含税", "可开具票据类型", "提成比例(%)", "条形码"}


def clean(value) -> str:
    if value is None:
        return ""
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value).strip()


def key(value: str) -> str:
    return re.sub(r"\s+", "", value or "").replace("（", "(").replace("）", ")").casefold()


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def read_csv(path: Path):
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="|")
        fields = reader.fieldnames
        if not fields or len(fields) != len(set(fields)):
            raise ValueError(f"Invalid CSV header: {path}")
        rows = list(reader)
        if any(None in row or any(v is None for v in row.values()) for row in rows):
            raise ValueError(f"Invalid CSV row width: {path}")
    return fields, rows


def write_csv(path: Path, fields, rows):
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="|", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def decimal(value: str, *, minimum=Decimal(0), maximum=None) -> str | None:
    try:
        result = Decimal(value)
        if not result.is_finite() or result < minimum or (maximum is not None and result > maximum):
            return None
        return format(result, "f")
    except (InvalidOperation, ValueError):
        return None


def load_excel(directory: Path, files: list[str]):
    result, manifests = [], []
    for filename in files:
        path = directory / filename
        if not path.is_file():
            raise ValueError(f"Required product workbook missing: {path}")
        before = digest(path)
        book = xlrd.open_workbook(str(path))
        sheets = []
        for sheet in book.sheets():
            headers = [clean(v) for v in sheet.row_values(0)]
            if len(headers) != len(set(headers)) or not {"产品名称", "产品编号", "产品角色", "基本单位"} <= set(headers):
                raise ValueError(f"Invalid product workbook header: {filename}/{sheet.name}")
            sheets.append({"name": sheet.name, "rows": sheet.nrows - 1, "columns": headers})
            previous_code = ""
            for index in range(1, sheet.nrows):
                values = {field: clean(sheet.cell_value(index, column)) for column, field in enumerate(headers)}
                if not any(values.values()):
                    continue
                if values["产品编号"]:
                    previous_code = values["产品编号"]
                result.append({"file": filename, "sheet": sheet.name, "row": index + 1,
                               "parent_code": previous_code, "values": values})
        if before != digest(path):
            raise ValueError(f"Workbook changed while being read: {path}")
        manifests.append({"file": filename, "sha256": before, "bytes": path.stat().st_size, "sheets": sheets})
    return result, manifests


def stable_new_ids(codes: list[str], occupied: set[int]) -> dict[str, int]:
    """A distinct negative identity per exact source code, independent of row order."""
    result = {}
    for code in sorted(codes):
        candidate = -(1_000_000_000 + int(hashlib.sha256(code.encode()).hexdigest()[:8], 16) % 1_000_000_000)
        while candidate in occupied:
            candidate -= 1
        occupied.add(candidate)
        result[code] = candidate
    return result


def lookup(rows, *, code_fields=("name",)):
    found = defaultdict(set)
    for row in rows:
        for field in code_fields:
            if clean(row.get(field)):
                found[key(row[field])].add(row["legacy_id"])
    return {name: next(iter(ids)) for name, ids in found.items() if len(ids) == 1}


def category_picker(rows):
    by_id = {row["legacy_id"]: row for row in rows}
    paths = {}
    for row in rows:
        names, current, seen = [], row, set()
        while current is not None and current["legacy_id"] not in seen:
            seen.add(current["legacy_id"])
            names.append(key(current["name"]))
            current = by_id.get(current.get("parent_legacy"))
        paths[row["legacy_id"]] = tuple(reversed(names))

    def pick(source_path):
        names = tuple(key(name) for name in source_path.split("->") if key(name))
        ranked = []
        for identity, path in paths.items():
            length = 0
            for a, b in zip(reversed(names), reversed(path)):
                if a != b:
                    break
                length += 1
            if length:
                ranked.append((length, identity))
        if ranked:
            highest = max(score for score, _ in ranked)
            winners = [identity for score, identity in ranked if score == highest]
            if len(winners) == 1:
                return winners[0], "exact_path_suffix" if highest > 1 else "unique_leaf"
        # Keep the nearest existing unambiguous ancestor; do not manufacture a
        # new Excel tree or silently drop the source's more precise category.
        for name in reversed(names):
            matches = [identity for identity, row in by_id.items() if key(row["name"]) == name]
            if len(matches) == 1:
                return matches[0], "nearest_unique_ancestor"
        return "-1", "historical_unclassified_fallback"
    return pick


def sql_string(value):
    return "NULL" if value is None or value == "" else "'" + str(value).replace("'", "''") + "'"


def emit_attributes(path: Path, attributes: list[dict]):
    columns = ["legacy_id", "source_type", "workshop_name", "over_receipt", "min_order", "order_multiple"]
    with path.open("w", encoding="utf-8", newline="") as handle:
        handle.write("-- Derived Excel attributes. Execute AFTER goods-data and BEFORE BOM/transactions.\n")
        handle.write("CREATE TEMP TABLE goods_excel_attributes (legacy_id integer PRIMARY KEY, source_type text, workshop_name text, over_receipt numeric, min_order numeric, order_multiple numeric) ON COMMIT DROP;\n")
        for offset in range(0, len(attributes), 500):
            block = attributes[offset:offset + 500]
            handle.write("INSERT INTO goods_excel_attributes VALUES\n" + ",\n".join(
                "(" + ",".join(sql_string(row.get(col)) for col in columns) + ")" for row in block) + ";\n")
        handle.write("""DO $excel_guard$ BEGIN
 IF EXISTS (SELECT 1 FROM goods_excel_attributes a LEFT JOIN goods g ON g.legacy_id=a.legacy_id AND NOT g.is_deleted WHERE g.id IS NULL) THEN
  RAISE EXCEPTION 'Excel goods identities missing; load the derived goods.csv first';
 END IF;
 IF EXISTS (SELECT 1 FROM goods_excel_attributes a WHERE a.workshop_name IS NOT NULL AND
   (SELECT count(*) FROM departments d WHERE NOT d.is_deleted AND d.name=a.workshop_name) <> 1) THEN
  RAISE EXCEPTION 'Excel workshop does not resolve to exactly one active department';
 END IF;
END $excel_guard$;
UPDATE goods g SET source_type=a.source_type,
 owning_workshop_department_id=COALESCE((SELECT id FROM departments d WHERE NOT d.is_deleted AND d.name=a.workshop_name),g.owning_workshop_department_id),
 purchase_allowed_over_receipt_pct=COALESCE(a.over_receipt,g.purchase_allowed_over_receipt_pct),
 min_order_qty=COALESCE(a.min_order,g.min_order_qty),
 order_multiple_qty=COALESCE(a.order_multiple,g.order_multiple_qty),
 updated_at=now(), version=g.version+1
FROM goods_excel_attributes a WHERE g.legacy_id=a.legacy_id AND NOT g.is_deleted;
SELECT 'Excel来源' AS verification, g.source_type, count(*) FROM goods g JOIN goods_excel_attributes a USING(legacy_id) GROUP BY g.source_type;
""")


def prepare(source_dir: Path, dictionary_dir: Path, excel_dir: Path, crosswalk: Path, output_dir: Path, files: list[str]):
    source_dir, dictionary_dir, output_dir = source_dir.resolve(), dictionary_dir.resolve(), output_dir.resolve()
    if output_dir in (source_dir, dictionary_dir):
        raise ValueError("Output directory must differ from both input directories")
    output_dir.mkdir(parents=True, exist_ok=True)
    headers, goods = read_csv(source_dir / "goods.csv")
    fields = {name: name if name in headers else old for name, old in ALIASES.items()}
    if not set(fields.values()) <= set(headers):
        raise ValueError("goods.csv does not match the reviewed goods schema")
    original = {int(row[fields["legacy_id"]]): row.copy() for row in goods}
    if len(original) != len(goods):
        raise ValueError("Duplicate legacy goods identity")
    by_code = {}
    for row in goods:
        code = key(row[fields["code"]])
        if code:
            if code in by_code:
                raise ValueError(f"Ambiguous legacy goods code: {row[fields['code']]}")
            by_code[code] = row
    excel, workbooks = load_excel(excel_dir, files)
    coded = [row for row in excel if row["values"]["产品编号"]]
    counts = Counter(key(row["values"]["产品编号"]) for row in coded)
    if any(count != 1 for count in counts.values()):
        raise ValueError("Duplicate Excel product code; refusing last-row-wins")
    dictionaries = {}
    dictionary_identities = {}
    unit_names = {}
    inputs = [source_dir / "goods.csv", crosswalk]
    reference_mapping = dictionary_dir / "excel_reference_mapping.csv"
    for filename, fields_to_index in [("unit.csv", ("name",)), ("color.csv", ("name",)),
                                      ("mould.csv", ("code", "mnumber")), ("supplier.csv", ("name",)),
                                      ("client.csv", ("name", "full_name"))]:
        path = dictionary_dir / filename
        if not path.exists():
            path = source_dir / filename
        if path.exists():
            _, records = read_csv(path)
            # In the enriched reference layer, code is a newly allocated UI
            # identifier. It is not the legacy Excel mould identifier. Only a
            # reviewed source alias or the preserved mnumber may resolve it.
            if filename == "mould.csv" and reference_mapping.exists():
                fields_to_index = ("mnumber",)
            dictionaries[filename] = lookup(records, code_fields=fields_to_index)
            dictionary_identities[filename] = {row["legacy_id"] for row in records}
            if filename == "unit.csv":
                unit_names = {row["legacy_id"]: row["name"] for row in records}
            inputs.append(path)
        else:
            dictionaries[filename] = {}
            dictionary_identities[filename] = set()
    if reference_mapping.exists():
        _, mappings = read_csv(reference_mapping)
        targets = {"supplier": "supplier.csv", "suppliers": "supplier.csv", "mould": "mould.csv", "moulds": "mould.csv"}
        for mapping in mappings:
            target = targets.get(mapping["domain"].casefold())
            if target is None:
                raise ValueError("Unknown Excel reference alias domain")
            alias, identity = key(mapping["source_value"]), mapping["target_legacy_id"]
            if not alias or not identity:
                raise ValueError("Empty Excel reference alias identity")
            if identity not in dictionary_identities[target]:
                raise ValueError("Excel reference alias target does not exist in its prepared master dictionary")
            previous = dictionaries[target].get(alias)
            if previous is not None and previous != identity:
                raise ValueError(f"Excel reference alias conflicts with an exact master key: {mapping['source_value']}")
            dictionaries[target][alias] = identity
        inputs.append(reference_mapping)
    _, categories = read_csv(source_dir / "goods_categories.csv")
    inputs.append(source_dir / "goods_categories.csv")
    pick_category = category_picker(categories)
    _, warehouse_rows = read_csv(crosswalk)
    warehouses = {}
    for row in warehouse_rows:
        if row["action"] in ("KEEP", "MERGE", "TARGET") and row["target_defective"].lower() == "false":
            name = key(row["target_name"])
            if name in warehouses and warehouses[name] != row["target_code"]:
                raise ValueError(f"Ambiguous target warehouse name: {row['target_name']}")
            warehouses[name] = row["target_code"]
    ids = stable_new_ids([row["values"]["产品编号"] for row in coded if key(row["values"]["产品编号"]) not in by_code], set(original))
    changes, identities, issues, owning, attributes, continuation = [], [], [], [], [], []
    quantity_unit_candidates = []
    stats = Counter()

    def issue(rec, field, value, reason):
        issues.append({"file": rec["file"], "row": rec["row"], "code": rec["values"]["产品编号"], "field": field, "value": value, "reason": reason})

    for rec in coded:
        values = rec["values"]
        code = values["产品编号"]
        row = by_code.get(key(code))
        is_new = row is None
        if is_new:
            row = dict.fromkeys(headers, "")
            for name, value in {"legacy_id": str(ids[code]), "code": code, "name": values["产品名称"], "status": "使用", "bom_status": "false", "min_qty": "0"}.items():
                row[fields[name]] = value
            category, category_method = pick_category(values.get("产品分类", ""))
            row[fields["parent_legacy"]] = category
            goods.append(row)
        else:
            category_method = "preserve_legacy_tree"
        identity = row[fields["legacy_id"]]
        identities.append({"legacy_id": identity, "excel_code": code, "kind": "excel_added" if is_new else "same_code",
                           "category_method": category_method, "source_file": rec["file"], "source_row": rec["row"]})
        stats["new_goods" if is_new else "matched_goods"] += 1

        def assign(field, value, reason="excel_nonempty_authority"):
            if value == "" or value is None:
                return
            column = fields[field]
            if row[column] != str(value):
                changes.append({"legacy_id": identity, "code": code, "field": field, "old": row[column], "new": str(value), "reason": reason})
                row[column] = str(value)
                stats["changed_" + field] += 1

        for source, target in TEXT_FIELDS.items():
            assign(target, values.get(source))
        assign("status", "使用" if values.get("启用状态") == "启用" else "禁用" if values.get("启用状态") == "停用" else "")
        unit_conflict = None
        for source, target, filename in [("基本单位", "unit_legacy_id", "unit.csv"), ("颜色", "color_legacy_id", "color.csv"),
                                          ("模具编号", "mould_legacy_id", "mould.csv"), ("关联客户", "client_legacy_id", "client.csv")]:
            value = values.get(source, "")
            if not value:
                continue
            alias = unit_name(value) if source == "基本单位" else color_name(value) if source == "颜色" else value
            reference = dictionaries[filename].get(key(alias))
            if reference is None:
                issue(rec, source, value, "unresolved_exact_dictionary_reference")
                if source in ("基本单位", "颜色"):
                    raise ValueError(f"Required cleaned dictionary reference missing: {code}/{source}/{value}")
            else:
                old_reference = row[fields[target]]
                if target == "unit_legacy_id" and old_reference not in ("", "0") and old_reference != reference:
                    unit_conflict = {"legacy_id": identity, "code": code, "name": values["产品名称"],
                                     "legacy_unit_id": old_reference, "excel_unit_id": reference, "excel_unit": value}
                    quantity_unit_candidates.append(unit_conflict)
                    issue(rec, source, value, "retain_legacy_base_unit_pending_quantity_reconciliation")
                    stats["retained_legacy_base_unit_conflict"] += 1
                else:
                    assign(target, reference)
        role = ROLE_MAP.get(values.get("产品角色"))
        if not role:
            raise ValueError(f"Unmapped Excel product role: {code}/{values.get('产品角色')}")
        supplier_field = "主委外供应商" if role == "委外" else "主采购供应商" if role == "采购" else "供应商"
        if not values.get(supplier_field):
            supplier_field = "供应商"
        supplier = values.get(supplier_field)
        if supplier:
            supplier_id = dictionaries["supplier.csv"].get(key(supplier))
            if supplier_id:
                assign("vend_legacy_id", supplier_id)
            else:
                issue(rec, supplier_field, supplier, "unresolved_exact_dictionary_reference_preserved_in_remark")
        for source, target in [("默认销售折扣", "zk"), ("单重（克）", "m_weight")]:
            value = values.get(source, "")
            if value:
                number = decimal(value, maximum=Decimal(1) if target == "zk" else None)
                if number is None:
                    issue(rec, source, value, "invalid_numeric_preserve_legacy_value")
                elif target == "m_weight" and unit_conflict:
                    issue(rec, source, value, "per_excel_unit_weight_deferred_with_base_unit_conflict")
                else:
                    assign(target, number)
        sale_price = decimal(values.get("建议售价", ""))
        if sale_price and Decimal(sale_price) > 0:
            if unit_conflict:
                issue(rec, "建议售价", values["建议售价"], "per_excel_unit_price_deferred_with_base_unit_conflict")
            elif key(values.get("单位")) == key(values.get("基本单位")) and decimal(values.get("比例", "")) == "1":
                assign("price", sale_price)
            else:
                issue(rec, "建议售价", values["建议售价"], "alternate_unit_price_preserved_in_raw_archive")
        notes = [values.get("原ERP备注", "") or row[fields["require_remark"]]]
        extras = {field: values[field] for field in sorted(NOTE_FIELDS) if values.get(field) not in (None, "", "0", "否", "无", "天")}
        if values.get("产品分类"):
            extras["产品分类"] = values["产品分类"]
        if unit_conflict:
            extras["基本单位待核对"] = {"保留老单位": unit_names.get(unit_conflict["legacy_unit_id"], "#" + unit_conflict["legacy_unit_id"]),
                                          "Excel新单位": unit_conflict["excel_unit"],
                                          "处理": "历史数量、BOM、单价、库存与换算闭合核对前保留旧单位"}
            for field in ("基本单位", "单位", "比例", "包含单位", "建议售价", "单重（克）", "最小采购量", "最小包装量"):
                if values.get(field):
                    extras["待核对_" + field] = values[field]
        # Unresolved foreign names stay searchable without inventing relationships.
        for field in ("供应商", "主采购供应商", "模具名称", "模具编号", "关联客户"):
            if values.get(field):
                extras[field] = values[field]
        if extras:
            notes.append("[Excel补充资料] " + json.dumps(extras, ensure_ascii=False, separators=(",", ":")))
        assign("require_remark", "\n".join(note for note in notes if note))
        warehouse = values.get("所属仓库", "")
        if warehouse:
            if key(warehouse) not in warehouses:
                raise ValueError(f"Unmapped Excel owning warehouse: {warehouse}")
            owning.append({"goods_legacy_id": identity, "warehouse_code": warehouses[key(warehouse)]})
        workshop = values.get("生产车间", "")
        if workshop and workshop not in WORKSHOPS:
            raise ValueError(f"Unmapped production workshop: {workshop}")
        attrs = {"legacy_id": identity, "source_type": role, "workshop_name": WORKSHOPS.get(workshop, "")}
        for source, target in [("采购入库超量上限(%)", "over_receipt"), ("最小采购量", "min_order"), ("最小包装量", "order_multiple")]:
            value = values.get(source, "")
            number = decimal(value, maximum=Decimal(100) if target == "over_receipt" else None) if value else None
            if value and number is None:
                issue(rec, source, value, "invalid_numeric_not_imported")
            # Multiples must be positive; exported zero means not configured.
            attrs[target] = number if target != "order_multiple" or number and Decimal(number) > 0 else ""
            if unit_conflict and target in ("min_order", "order_multiple"):
                attrs[target] = ""
        attributes.append(attrs)
    # Preserve reviewed legacy ownership for goods absent from the Excel code
    # list only where every exact-name Excel candidate agrees on one warehouse.
    name_warehouses = defaultdict(set)
    for rec in coded:
        value = rec["values"]
        if value.get("所属仓库"):
            name_warehouses[key(value["产品名称"])].add(warehouses[key(value["所属仓库"])])
    owned = {row["goods_legacy_id"] for row in owning}
    for row in goods:
        identity = row[fields["legacy_id"]]
        candidates = name_warehouses.get(key(row[fields["name"]]), set())
        if identity not in owned and len(candidates) == 1:
            owning.append({"goods_legacy_id": identity, "warehouse_code": next(iter(candidates))})
            stats["warehouse_exact_name_consensus"] += 1
            owned.add(identity)
    for rec in excel:
        if not rec["values"]["产品编号"]:
            if rec["values"].get("产品名称") != "【价格策略】" or not rec["parent_code"]:
                raise ValueError(f"Unidentified no-code Excel record: {rec['file']}:{rec['row']}")
            continuation.append(rec)
    output_goods = output_dir / "goods.csv"
    write_csv(output_goods, headers, goods)
    write_csv(output_dir / "goods_owning_warehouse.csv", ["goods_legacy_id", "warehouse_code"], owning)
    write_csv(output_dir / "goods_excel_attributes.csv", ["legacy_id", "source_type", "workshop_name", "over_receipt", "min_order", "order_multiple"], attributes)
    source_identities = {row["legacy_id"] for row in attributes}
    source_review = [{"legacy_id": row[fields["legacy_id"]], "code": row[fields["code"]],
                      "name": row[fields["name"]], "legacy_g_style": row[fields["g_style"]],
                      "legacy_assteam_id": row[fields["assteam_legacy_id"]],
                      "source_type": "", "resolution": "NO_EXCEL_SOURCE_ENGINEERING_REVIEW"}
                     for row in goods if row[fields["legacy_id"]] not in source_identities]
    write_csv(output_dir / "goods_source_engineering_review.csv",
              ["legacy_id", "code", "name", "legacy_g_style", "legacy_assteam_id", "source_type", "resolution"], source_review)
    for filename, records, columns in [("goods_excel_changes.csv", changes, ["legacy_id", "code", "field", "old", "new", "reason"]),
                                       ("goods_excel_identity.csv", identities, ["legacy_id", "excel_code", "kind", "category_method", "source_file", "source_row"]),
                                       ("goods_excel_issues.csv", issues, ["file", "row", "code", "field", "value", "reason"])]:
        write_csv(output_dir / filename, columns, records)
    coverage = []
    for field in workbooks[0]["sheets"][0]["columns"]:
        nonempty = sum(bool(rec["values"].get(field)) for rec in excel)
        policy = "goods.csv:" + DIRECT_FIELDS[field] if field in DIRECT_FIELDS else "attributes_sql:" + SQL_FIELDS[field] if field in SQL_FIELDS else "searchable_remark_and_raw_archive" if field in NOTE_FIELDS or field in {"模具名称", "产品分类"} else "raw_archive_only"
        coverage.append({"source_column": field, "nonempty_rows": nonempty, "policy": policy})
    write_csv(output_dir / "goods_excel_field_coverage.csv", ["source_column", "nonempty_rows", "policy"], coverage)
    with (output_dir / "goods_excel_raw.jsonl").open("w", encoding="utf-8", newline="") as handle:
        for rec in excel:
            handle.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
    emit_attributes(output_dir / "goods_excel_attributes.sql", attributes)
    evidence_inputs, quantity_summary = audit_quantity_units(source_dir, output_dir, quantity_unit_candidates, excel, unit_names)
    inputs = list(dict.fromkeys([*inputs, *evidence_inputs]))
    stats.update({"legacy_goods_rows": len(original), "derived_goods_rows": len(goods), "excel_rows": len(excel),
                  "excel_coded_rows": len(coded), "price_strategy_rows_archived": len(continuation), "owning_warehouse_rows": len(owning),
                  "issues": len(issues), "source_roles": len(attributes), "source_engineering_review": len(source_review),
                  "quantity_unit_review_goods": quantity_summary["candidate_goods"]})
    manifest = {"formatVersion": 1, "kind": "derived_excel_goods_overlay", "policy": "excel-nonempty-authority-preserve-historical-quantity-units-v2",
                "generators": [{"file": path.name, "sha256": digest(path)} for path in
                               (Path(__file__), Path(__file__).with_name("prepare_clean_master_data.py"), Path(__file__).with_name("audit_goods_quantity_units.py"))],
                "sourceInputs": [{"path": str(path.resolve()), "sha256": digest(path)} for path in inputs], "workbooks": workbooks,
                "statistics": dict(stats), "outputs": [{"file": path.name, "sha256": digest(path), "bytes": path.stat().st_size}
                  for path in sorted(output_dir.glob("goods*")) if path.is_file() and path.name != "goods_excel_manifest.json"]}
    (output_dir / "goods_excel_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument("--dictionary-dir", required=True, type=Path)
    parser.add_argument("--excel-dir", required=True, type=Path)
    parser.add_argument("--crosswalk", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--files", nargs="+", default=[f"20260409172229_{i}.xls" for i in (1, 2, 3)])
    args = parser.parse_args()
    result = prepare(args.source_dir, args.dictionary_dir, args.excel_dir, args.crosswalk, args.output_dir, args.files)
    print(json.dumps(result["statistics"], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
