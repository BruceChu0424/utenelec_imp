#!/usr/bin/env python3
"""Audit all material texts and prepare evidenced neutral raw-material identities.

PC E-15 -> existing virgin resin 14533 is explicitly reviewed by the user.
Sprue/regrind 18657 and defective output 24922 are outputs, not normal inputs.
Unknown usage remains PENDING_QUANTITY evidence for V904. The executable BOM
is unchanged. Neither qty=1 nor a change to ORDER/PERIODIC policy is synthesized.
The generated loader is not executed by this preparation program.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
from decimal import Decimal, InvalidOperation
import hashlib
import json
from pathlib import Path
import re
import unicodedata


RAW_MATERIAL_ID = "14533"
RAW_MATERIAL_NAME = "PC面板料E-15"
RAW_UNIT_ID = "108"
FORBIDDEN_INPUT_IDS = {"18657", "24922"}
APPROVED_TEXTS = {"pce-15", "pc面板料e-15"}
RAW_CATEGORY_NAMES = {"塑胶原料", "五金原料", "轨道原材"}
MASS_UNIT_IDENTITIES = {"108": "kg", "109": "g", "241": "斤"}
WORKSHOP_ALIASES = {"注塑车间": "注塑车间", "五金车间": "五金铜铸车间",
                    "开关插座生产车间": "装配第一车间", "开关插座车间": "装配第一车间",
                    "轨道生产车间": "轨道装配车间"}
OUTPUT_LABELS = ("水口", "回料", "废料", "废品", "不良品", "边料", "边角")
LIFECYCLE_WORDS = ("不再生产", "停止再生产", "再生产", "不再投产", "停止生产", "已停产")
OUTPUT_CATEGORY_NAMES = {"五金边料", "水口料", "废料", "废品", "不良品", "边角料"}
HANDLING_PURPOSE_WORDS = ("周转箱", "周转桶", "收集箱", "收集桶", "收集袋", "回收箱", "回收桶",
                          "料箱", "料桶", "料盒", "料筐", "料篮", "不良品箱", "不良品盒", "不良品桶", "不良品筐",
                          "废料袋", "废品箱", "废品桶", "容器", "粉碎机", "剪刀")
POLYMERS = ("pa66", "abs", "pom", "pvc", "pet", "pc", "pa", "pp", "pe")


class MaterialCatalog(dict):
    """Full master lookup with compact indexes for repeated material resolution."""
    raw_ids = ()
    material_literal_ids = None


class BomGraph(defaultdict):
    def __init__(self):
        super().__init__(set)
        self.raw_reachable = {}


def bind_raw_bom_reachability(graph: BomGraph, catalog: dict):
    reverse = defaultdict(set)
    for parent, components in graph.items():
        for component in components:
            reverse[component].add(parent)
    reachable = defaultdict(set)
    for material in catalog.raw_ids:
        if material not in reverse or catalog[material]["row"].get("status") == "禁用":
            continue
        pending, visited = list(reverse[material]), set()
        while pending:
            product = pending.pop()
            if product not in visited:
                visited.add(product)
                if product != material:
                    reachable[product].add(material)
                pending.extend(reverse[product] - visited)
    graph.raw_reachable = reachable


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def text(value) -> str:
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return "" if value is None else str(value).strip()


def key(value: str) -> str:
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", value or "")).casefold()


def polymer(value: str) -> str:
    value = key(value)
    return next((family for family in POLYMERS if family in value), "")


def identity_key(value: str) -> str:
    """Cosmetic normalization; never deletes grade/formula/color qualifiers."""
    value = key(value)
    family = polymer(value)
    if family:
        index = value.index(family)
        return family + value[:index] + value[index + len(family):]
    return value


def domain(value: str) -> str:
    normalized = key(value)
    if not normalized:
        return "EMPTY"
    family = polymer(value)
    if family:
        return "POLYMER_" + family.upper()
    if any(label in normalized for label in ("铜", "铝", "铁", "钢", "锡", "合金")):
        return "METAL"
    if any(label in normalized for label in ("电镀", "镀", "喷油", "拉丝", "抛光")):
        return "SURFACE_OR_PROCESS"
    if any(label in normalized for label in ("胶", "粉", "油", "硅", "橡")):
        return "CHEMICAL_OR_AUXILIARY"
    return "OTHER"


def category_paths(categories: list[dict]) -> dict:
    indexed = {row["legacy_id"]: row for row in categories}
    result = {}
    for identity in indexed:
        current, visited, names = identity, set(), []
        while current in indexed:
            if current in visited:
                raise ValueError("category cycle prevents proving raw-material classification")
            visited.add(current)
            names.append(indexed[current]["name"])
            current = indexed[current]["parent_legacy"]
        result[identity] = tuple(reversed(names))
    return result


def material_role(row: dict, path: tuple, mass_unit_proven: bool, attribute: dict):
    """Classify the physical identity and purpose, never a material-description substring."""
    original = row["name"]
    name = unicodedata.normalize("NFKC", original)
    lifecycle = [word for word in LIFECYCLE_WORDS if word in name]
    for word in LIFECYCLE_WORDS:
        name = name.replace(word, "")
    category_names = set(path)
    raw_category = bool(RAW_CATEGORY_NAMES.intersection(category_names))
    output_category = bool(OUTPUT_CATEGORY_NAMES.intersection(category_names))
    labels = [label for label in OUTPUT_LABELS if label in name]
    handling = [word for word in HANDLING_PURPOSE_WORDS if word in name]
    evidence = {"rule": "NO_PROVEN_OUTPUT_IDENTITY", "lifecycle_annotations": lifecycle,
                "identity_labels": labels, "handling_purpose_words": handling,
                "mass_unit_proven": mass_unit_proven, "raw_category_proven": raw_category,
                "dedicated_output_category": output_category,
                "source_type": attribute.get("source_type", ""),
                "workshop_name": attribute.get("workshop_name", "")}
    if handling:
        evidence["rule"] = "HANDLING_GOODS_IS_NOT_ITS_CONTENT"
        return "OTHER_MASTER", evidence
    explicit_identity = bool(labels) and (mass_unit_proven or raw_category or output_category
                                        or "不良品" in name or "废品" in name)
    if row["legacy_id"] in FORBIDDEN_INPUT_IDS:
        evidence["rule"] = "USER_CONFIRMED_SPRUE_OR_DEFECTIVE_OUTPUT_IDENTITY"
        return "WASTE_REGRIND_OR_DEFECTIVE_OUTPUT", evidence
    if explicit_identity or (output_category and mass_unit_proven):
        if attribute.get("source_type") == "采购":
            evidence["rule"] = "PURCHASED_SECONDARY_MATERIAL_PURPOSE_REQUIRES_REVIEW"
            return "SECONDARY_MATERIAL_PURPOSE_REVIEW", evidence
        evidence["rule"] = "EXPLICIT_OUTPUT_IDENTITY_AND_CLASSIFICATION_OR_UNIT"
        return "WASTE_REGRIND_OR_DEFECTIVE_OUTPUT", evidence
    if raw_category and mass_unit_proven:
        evidence["rule"] = ("RECYCLED_RAW_MASTER_NOT_PROVEN_PRODUCTION_OUTPUT" if "再生" in name
                            else "RAW_CATEGORY_AND_PROVEN_MASS_UNIT")
        return "MASS_RAW_MATERIAL_INPUT", evidence
    return "OTHER_MASTER", evidence


def material_catalog(goods: list[dict], categories: list[dict], units: list[dict], attributes=None):
    paths = category_paths(categories)
    proven_units = {row["legacy_id"] for row in units
                    if MASS_UNIT_IDENTITIES.get(row["legacy_id"]) == row["name"]}
    attributes = {row["legacy_id"]: row for row in (attributes or [])}
    catalog, alias_index = MaterialCatalog(), defaultdict(lambda: defaultdict(set))
    for row in goods:
        path = paths.get(row.get("parent_legacy", ""), ())
        role, role_evidence = material_role(row, path, row.get("unit_legacy_id") in proven_units,
                                             attributes.get(row["legacy_id"], {}))
        record = {"row": row, "category_path": path, "role": role, "role_evidence": role_evidence,
                  "family": polymer(row.get("material", "")) or polymer(row["name"]),
                  "mass_unit_proven": row.get("unit_legacy_id") in proven_units}
        catalog[row["legacy_id"]] = record
        if role != "MASS_RAW_MATERIAL_INPUT":
            continue
        aliases = [(identity_key(row["name"]), "EXACT_RAW_MASTER_NAME")]
        model = key(row.get("model", ""))
        if model and model not in POLYMERS and len(model) >= 3:
            aliases.append((identity_key(model), "EXACT_RAW_MASTER_MODEL"))
            if record["family"] and record["family"] not in model:
                aliases.append((identity_key(record["family"] + model), "EXACT_POLYMER_AND_RAW_MODEL"))
            # Keep every color/brand/special-use qualifier in the name; only
            # remove the literal role words before combining it with its model.
            stem = row["name"]
            for word in ("面板料", "支架料", "底料", "原料", "面料", "胶料", "料"):
                stem = stem.replace(word, "")
            if stem and record["family"]:
                aliases.append((identity_key(stem + model), "EXACT_RAW_NAME_AND_MODEL"))
        for alias, rule in aliases:
            if alias:
                alias_index[alias][row["legacy_id"]].add(rule)
    catalog.raw_ids = tuple(identity for identity, record in catalog.items() if record["role"] == "MASS_RAW_MATERIAL_INPUT")
    catalog.material_literal_ids = defaultdict(list)
    for identity in catalog.raw_ids:
        literal = identity_key(catalog[identity]["row"].get("material", ""))
        if literal:
            catalog.material_literal_ids[literal].append(identity)
    return catalog, alias_index


def resolve_material(parent: dict, catalog: dict, alias_index: dict, graph: dict):
    value = parent.get("material", "")
    normalized = identity_key(value)
    own = catalog[parent["legacy_id"]]
    if own["role"] == "WASTE_REGRIND_OR_DEFECTIVE_OUTPUT":
        return {"status": "OUTPUT_PRODUCT_NOT_NORMAL_INPUT", "targets": [], "candidates": [], "rules": {}}
    if not normalized:
        defined = sorted(graph.raw_reachable.get(parent["legacy_id"], set()), key=int)
        if defined:
            return {"status": "ALREADY_DEFINED_RAW_INPUT_WITH_BLANK_TEXT", "targets": defined, "candidates": defined,
                    "rules": {identity: ["EXISTING_POSITIVE_BOM_IDENTITIES_DESPITE_BLANK_MATERIAL_TEXT"] for identity in defined}}
        return {"status": "EMPTY_MATERIAL", "targets": [], "candidates": [], "rules": {}}
    exact = alias_index.get(normalized, {})
    # E-15 was explicitly adjudicated by the user. This is an exact reviewed
    # identity override, not a fuzzy preference for the first name match.
    if key(value) in APPROVED_TEXTS and RAW_MATERIAL_ID in catalog:
        pinned = catalog[RAW_MATERIAL_ID]["row"]
        if pinned["name"] != RAW_MATERIAL_NAME or pinned.get("unit_legacy_id") != RAW_UNIT_ID:
            return {"status": "USER_CONFIRMED_IDENTITY_CHANGED_REVIEW", "targets": [], "candidates": [RAW_MATERIAL_ID], "rules": {}}
        exact = {RAW_MATERIAL_ID: {"USER_CONFIRMED_PC_E15_VIRGIN_IDENTITY"}}
    if exact:
        candidates = sorted(exact, key=int)
        if len(candidates) != 1:
            directly_defined = [identity for identity in candidates if identity in graph.get(parent["legacy_id"], set())
                                and catalog[identity]["row"].get("status") != "禁用"]
            indirectly_defined = [identity for identity in candidates if identity not in directly_defined
                                  and catalog[identity]["row"].get("status") != "禁用"
                                  and identity in graph.raw_reachable.get(parent["legacy_id"], set())]
            if len(directly_defined) == 1:
                return {"status": "ALREADY_DEFINED_BY_DIRECT_BOM", "targets": directly_defined, "candidates": candidates,
                        "rules": {directly_defined[0]: ["EXISTING_DIRECT_BOM_RESOLVES_LITERAL_AMBIGUITY"]}}
            if not directly_defined and len(indirectly_defined) == 1:
                return {"status": "ALREADY_COVERED_BY_INDIRECT_BOM", "targets": indirectly_defined, "candidates": candidates,
                        "rules": {indirectly_defined[0]: ["EXISTING_INDIRECT_BOM_RESOLVES_LITERAL_AMBIGUITY"]}}
            return {"status": "AMBIGUOUS_RAW_IDENTITIES", "targets": [], "candidates": candidates,
                    "rules": {identity: sorted(exact[identity]) for identity in candidates}}
        identity = candidates[0]
        record = catalog[identity]
        if record["role"] != "MASS_RAW_MATERIAL_INPUT" or not record["mass_unit_proven"]:
            return {"status": "RAW_CLASSIFICATION_OR_MASS_UNIT_UNPROVEN", "targets": [], "candidates": candidates, "rules": {}}
        if record["row"].get("status") == "禁用":
            return {"status": "DISABLED_RAW_MATERIAL", "targets": [], "candidates": candidates, "rules": {}}
        if identity == parent["legacy_id"] or reaches(graph, identity, parent["legacy_id"]):
            return {"status": "SELF_OR_CYCLE_REVIEW", "targets": [], "candidates": candidates, "rules": {}}
        return {"status": "RESOLVED_UNIQUE_LITERAL_IDENTITY", "targets": candidates, "candidates": candidates,
                "rules": {identity: sorted(exact[identity])}}
    # A real existing component identity is stronger evidence than a generic
    # copper/plastic family. Only exact material literals on that component
    # count; disabled/output components never authorize a neutral input.
    existing = [identity for identity in graph.get(parent["legacy_id"], set())
                if catalog.get(identity, {}).get("role") == "MASS_RAW_MATERIAL_INPUT"
                and catalog[identity]["row"].get("status") != "禁用"
                and identity_key(catalog[identity]["row"].get("material", "")) == normalized]
    if existing:
        return {"status": "RESOLVED_EXPLICIT_EXISTING_BOM_IDENTITIES", "targets": sorted(existing, key=int),
                "candidates": sorted(existing, key=int),
                "rules": {identity: ["EXISTING_DIRECT_BOM_AND_EXACT_COMPONENT_MATERIAL"] for identity in existing}}
    descendants = [identity for identity in catalog.material_literal_ids.get(normalized, [])
                   if catalog[identity]["row"].get("status") != "禁用"
                   and identity != parent["legacy_id"] and identity in graph.raw_reachable.get(parent["legacy_id"], set())]
    if descendants:
        return {"status": "ALREADY_COVERED_BY_INDIRECT_BOM", "targets": sorted(descendants, key=int),
                "candidates": sorted(descendants, key=int),
                "rules": {identity: ["EXISTING_INDIRECT_BOM_AND_EXACT_COMPONENT_MATERIAL"] for identity in descendants}}
    if any(symbol in normalized for symbol in ("+", "/", "%", "混合", "混配")):
        status = "MIXTURE_FORMULA_REQUIRES_REVIEW"
    elif normalized in POLYMERS or value in ("黄铜", "高精黄铜", "磷铜", "紫铜", "铝合金", "不锈钢", "钢", "铁", "铜"):
        status = "GENERIC_MATERIAL_NEEDS_GRADE_OR_SPECIFICATION"
    elif domain(value) == "SURFACE_OR_PROCESS":
        status = "SURFACE_OR_PROCESS_IS_NOT_RAW_IDENTITY"
    else:
        status = "MISSING_EXACT_RAW_MASTER_OR_ALIAS"
    family = polymer(value)
    candidates = sorted((identity for identity in catalog.raw_ids if family and catalog[identity]["family"] == family), key=int)
    return {"status": status, "targets": [], "candidates": candidates, "rules": {}}


def read_csv(path: Path):
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="|")
        headers = reader.fieldnames or []
        if not headers or len(headers) != len(set(headers)):
            raise ValueError(f"invalid CSV header: {path}")
        records = list(reader)
        if any(None in row or any(value is None for value in row.values()) for row in records):
            raise ValueError(f"invalid CSV width: {path}")
        return headers, records


def write_csv(path: Path, headers, records):
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=headers, delimiter="|", lineterminator="\n")
        writer.writeheader()
        writer.writerows(records)


def positive(value: str):
    try:
        result = Decimal(value)
        return result if result.is_finite() and result > 0 else None
    except (InvalidOperation, ValueError):
        return None


def reaches(graph: dict, origin: str, target: str) -> bool:
    visited, pending = set(), [origin]
    while pending:
        current = pending.pop()
        if current == target:
            return True
        if current not in visited:
            visited.add(current)
            pending.extend(graph.get(current, set()) - visited)
    return False


def inspect(goods: list[dict], attributes: list[dict], bom: list[dict], excel_sources: dict,
            raw_goods: dict, bindings: dict, catalog: dict, alias_index: dict):
    goods_by_id = {row["legacy_id"]: row for row in goods}
    if len(goods_by_id) != len(goods):
        raise ValueError("goods identities must be unique")
    graph = BomGraph()
    source_edge_counts = Counter(row["goods_legacy_id"] for row in bom)
    for row in bom:
        if positive(row["qty"]) and row["goods_legacy_id"] in goods_by_id and row["component_legacy_id"] in goods_by_id \
                and goods_by_id[row["component_legacy_id"]].get("status") != "禁用":
            graph[row["goods_legacy_id"]].add(row["component_legacy_id"])
    bind_raw_bom_reachability(graph, catalog)
    if len({row["legacy_id"] for row in attributes}) != len(attributes):
        raise ValueError("workshop/source attributes repeat a product identity")
    attributes_by_id = {row["legacy_id"]: row for row in attributes}
    audit, relations = [], []
    for parent in goods:
        identity = parent["legacy_id"]
        attribute = attributes_by_id.get(identity, {})
        source = excel_sources.get(key(parent["code"]))
        in_house = attribute.get("source_type") == "自制"
        if in_house:
            if source is None or source["values"].get("产品角色") != "自制件":
                raise ValueError("in-house scope is not supported by its exact Excel product identity")
            source_workshop = source["values"].get("生产车间", "")
            if WORKSHOP_ALIASES.get(source_workshop, source_workshop) != attribute.get("workshop_name", ""):
                raise ValueError("workshop attribute differs from the explicit Excel workshop mapping")
            source_material = source["values"].get("材质", "")
            if source_material and key(source_material) != key(parent.get("material", "")):
                raise ValueError("final material differs from its nonempty authoritative Excel material")
        resolution = resolve_material(parent, catalog, alias_index, graph)
        literal_status = resolution["status"]
        literal_identity_proved = bool(resolution["targets"]) and bool(parent.get("material", "").strip())
        existing_with_text_review = False
        if not resolution["targets"] and graph.raw_reachable.get(identity) and catalog[identity]["role"] != "WASTE_REGRIND_OR_DEFECTIVE_OUTPUT":
            # Preserve an explicit recipe even when its material text describes
            # a different/unresolved blend. This proves the stored edge, not an
            # alias for the text; keep the textual inconsistency open for review.
            defined = sorted(graph.raw_reachable[identity], key=int)
            resolution = {"status": "EXISTING_BOM_IDENTITY_WITH_MATERIAL_TEXT_REVIEW", "targets": defined,
                          "candidates": resolution["candidates"],
                          "rules": {item: ["PRESERVED_POSITIVE_BOM_IDENTITY_TEXT_NOT_RECONCILED"] for item in defined}}
            existing_with_text_review = True
        placement = ""
        audit_state = resolution["status"]
        if audit_state == "EMPTY_MATERIAL":
            if graph[identity]:
                audit_state = "BLANK_MATERIAL_WITH_DEFINED_ACTIVE_BOM"
            elif source_edge_counts[identity]:
                audit_state = "BLANK_MATERIAL_WITH_ONLY_EXCLUDED_BOM_ROWS"
            elif in_house:
                audit_state = "BLANK_MANUFACTURING_LEAF_PENDING"
        if resolution["targets"] and all(child in graph[identity] for child in resolution["targets"]):
            audit_state = "ALREADY_DEFINED_ACTIVE_BOM"
        elif resolution["targets"] and all(reaches(graph, identity, child) for child in resolution["targets"]):
            audit_state = "ALREADY_COVERED_INDIRECT_BOM"
        if existing_with_text_review:
            audit_state = "ALREADY_DEFINED_BOM_WITH_MATERIAL_TEXT_REVIEW" if all(child in graph[identity] for child in resolution["targets"]) else "ALREADY_COVERED_INDIRECT_WITH_MATERIAL_TEXT_REVIEW"
        if in_house:
            for child in resolution["targets"]:
                material_record = catalog[child]
                material = material_record["row"]
                if child in graph[identity]:
                    placement = "EXISTING_DIRECT_BOM_IDENTITY_NO_NEW_QUANTITY"
                elif reaches(graph, identity, child):
                    placement = "EXISTING_DESCENDANT_BOM_IDENTITY_REVIEW"
                elif graph[identity]:
                    placement = "EXISTING_COMPONENT_LAYERS_REVIEW_NO_DOUBLE_INPUT"
                else:
                    placement = "PENDING_PROVEN_CONSUMPTION"
                if placement in ("EXISTING_DIRECT_BOM_IDENTITY_NO_NEW_QUANTITY", "EXISTING_DESCENDANT_BOM_IDENTITY_REVIEW"):
                    continue
                raw = raw_goods.get(identity, {})
                provenance = {
                    "rule": "EXACT_EXCEL_IN_HOUSE_PRODUCT_AND_PROVEN_RAW_MATERIAL_IDENTITY_V2",
                    "identity_match_rules": resolution["rules"][child], "resolution_status": resolution["status"],
                    "normalized_material_text": key(parent.get("material", "")),
                    "normalized_identity_key": identity_key(parent.get("material", "")),
                    "source_material_text": parent.get("material", ""),
                    "raw_goods": {**bindings.get("raw_goods", {}), "legacy_id": identity,
                                  "row": raw.get("_source_row"), "material_text": raw.get("material", raw.get("Material", ""))},
                    "excel": {"path": source["path"], "sha256": source["sha256"], "row": source["row"],
                              "product_code": source["values"]["产品编号"], "material_text": source_material,
                              "workshop": source["values"].get("生产车间", ""), "product_role": "自制件"},
                    "expected_workshop_name": attribute.get("workshop_name", ""),
                    "material_master": {"legacy_id": child, "code": material["code"], "name": material["name"],
                                        "model": material.get("model", ""), "material": material.get("material", ""),
                                        "parent_legacy": material.get("parent_legacy", ""),
                                        "category_path": list(material_record["category_path"]),
                                        "unit_legacy_id": material["unit_legacy_id"],
                                        "unit_name": MASS_UNIT_IDENTITIES[material["unit_legacy_id"]],
                                        "status": material.get("status", ""), "role": material_record["role"]},
                    "final_goods": bindings.get("final_goods", {}), "original_bom": bindings.get("bom", {}),
                    "user_decision": "全面统计材质对应原料；没有真实单耗，先记录对应关系和待核项；禁用料不入活动BOM或中性关系；水口/回料/废/不良品是产出，不猜回投循环或配方",
                    "quantity_unknown": True, "active_bom_edge_added": False, "material_issue_method_changed": False,
                    "excluded_normal_input_goods": ["18657", "24922"], "automatic_regrind_cycle": False,
                    "excluded_normal_input_role_labels": list(OUTPUT_LABELS),
                    "needs_child_layer_review": bool(graph[identity]), "existing_component_legacy_ids": sorted(graph[identity]),
                    "placement_state": placement}
                relations.append({"product_legacy_id": identity, "material_legacy_id": child,
                                  "material_color_legacy_id": "0", "source_kind": "LEGACY_MATERIAL_TEXT",
                                  "status": "PENDING_QUANTITY", "provenance": json.dumps(provenance, ensure_ascii=False, separators=(",", ":"))})
        audit.append({"parent_legacy_id": identity, "parent_code": parent["code"], "parent_name": parent["name"],
                      "workshop_name": attribute.get("workshop_name", ""), "source_type": attribute.get("source_type", ""),
                      "scope": "EXCEL_IN_HOUSE" if in_house else "OTHER_GOODS_AUDIT_ONLY", "domain": domain(parent.get("material", "")),
                      "material_text": parent.get("material", ""), "normalized_material_text": key(parent.get("material", "")),
                      "input_material_legacy_id": ",".join(resolution["targets"]),
                      "input_material_name": json.dumps([goods_by_id[item]["name"] for item in resolution["targets"]], ensure_ascii=False),
                      "input_unit_legacy_id": ",".join(goods_by_id[item]["unit_legacy_id"] for item in resolution["targets"]),
                      "state": audit_state, "placement_state": placement,
                      "material_text_resolution_status": literal_status,
                      "material_text_identity_proved": str(literal_identity_proved).lower(),
                      "candidate_material_ids": json.dumps(resolution["candidates"]),
                      "per_unit_qty": "", "evidence_reference": json.dumps(resolution["rules"], ensure_ascii=False),
                      "legacy_z_weight": parent.get("z_weight", ""), "legacy_m_weight": parent.get("m_weight", ""),
                      "legacy_weight_unit_policy": "unproven legacy weights are not input consumption",
                      "active_bom_component_count": len(graph[identity]), "source_bom_row_count": source_edge_counts[identity],
                      "product_status": parent.get("status", ""),
                      "product_category_path": "/".join(catalog[identity]["category_path"]),
                      "existing_children": json.dumps(sorted(graph[identity]), ensure_ascii=False)})
    return audit, relations


def excel_weight_audit(excel_dir: Path):
    import xlrd
    files, facts, product_sources = [], [], {}
    for path in sorted(excel_dir.glob("*.xls")):
        before = digest(path)
        book = xlrd.open_workbook(str(path), on_demand=True)
        sheet = book.sheet_by_name("产品列表")
        headers = [text(value) for value in sheet.row_values(0)]
        required = {"产品编号", "产品名称", "产品角色", "生产车间", "材质", "单重（克）"}
        if len(headers) != len(set(headers)) or not required <= set(headers):
            raise ValueError("product workbook does not contain explicit injection/gram-weight columns")
        for index in range(1, sheet.nrows):
            values = {field: text(sheet.cell_value(index, column)) for column, field in enumerate(headers)}
            if values["产品编号"]:
                product_key = key(values["产品编号"])
                if product_key in product_sources:
                    raise ValueError("Excel repeats a product code; neutral material evidence must be unambiguous")
                product_sources[product_key] = {"path": str(path.resolve()), "sha256": before, "row": index + 1, "values": values}
            if values["生产车间"] == "注塑车间" and values["单重（克）"]:
                facts.append({"file": path.name, "row": index + 1, "product_code": values["产品编号"],
                              "product_name": values["产品名称"], "material_text": values["材质"],
                              "source_weight_cell": values["单重（克）"],
                              "status": "EXPLICIT_GRAM_WEIGHT_NOT_PROVEN_INPUT_CONSUMPTION" if positive(values["单重（克）"])
                              else "INVALID_NON_NUMERIC_OR_NON_POSITIVE_WEIGHT"})
        book.release_resources()
        if digest(path) != before:
            raise ValueError("workbook changed during material audit")
        files.append({"path": str(path.resolve()), "sha256": before})
    if not files:
        raise ValueError("no product workbooks")
    return facts, files, product_sources


def production_cost_audit(path: Path | None, raw_material_ids=None):
    if path is None:
        return {"checked": False}, []
    raw_material_ids = set(raw_material_ids or {RAW_MATERIAL_ID})
    matching, self_rows, counts = [], 0, Counter()
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.reader(handle, delimiter="|")
        headers = next(reader)
        component = headers.index("goods_legacy_id")
        parent = headers.index("mgoods_legacy_id")
        for row in reader:
            if len(row) != len(headers):
                raise ValueError("production cost CSV width differs")
            if row[component] in raw_material_ids:
                matching.append(dict(zip(headers, row)))
                counts[row[component]] += 1
            if row[component] == "52620" and row[parent] == "52620":
                self_rows += 1
    return {"checked": True, "raw_material_identities_checked": len(raw_material_ids),
            "raw_material_plan_cost_rows": len(matching), "rows_by_material_identity": dict(counts),
            "example_parent_self_rows_not_resin_usage": self_rows, "quantity_inference_performed": False}, matching


def scope_summary(rows: list[dict], relations: list[dict]):
    nonempty = sum(bool(row["material_text"].strip()) for row in rows)
    resolved = sum(bool(row["input_material_legacy_id"]) for row in rows)
    resolved_nonempty = sum(row["material_text_identity_proved"] == "true" for row in rows)
    ids = {row["parent_legacy_id"] for row in rows}
    return {"goods": len(rows), "nonempty_material": nonempty, "blank_material": len(rows) - nonempty,
            "original_nonempty_material_strings": len({row["material_text"] for row in rows if row["material_text"].strip()}),
            "resolved_raw_identity_products": resolved,
            "resolved_nonempty_material_products": resolved_nonempty,
            "resolved_fraction_of_nonempty": str(round(Decimal(resolved_nonempty) / nonempty, 6)) if nonempty else None,
            "pending_quantity_relations": sum(row["product_legacy_id"] in ids for row in relations),
            "states": dict(Counter(row["state"] for row in rows)), "domains": dict(Counter(row["domain"] for row in rows)),
            "workshops": dict(Counter(row["workshop_name"] or "<unspecified>" for row in rows)),
            "blank_with_defined_bom": sum(not row["material_text"].strip() and row["active_bom_component_count"] > 0 for row in rows),
            "blank_manufacturing_leaf_pending": sum(row["state"] == "BLANK_MANUFACTURING_LEAF_PENDING" for row in rows),
            "blank_with_only_excluded_bom_rows": sum(row["state"] == "BLANK_MATERIAL_WITH_ONLY_EXCLUDED_BOM_ROWS" for row in rows)}


def material_distribution(rows: list[dict]):
    grouped = defaultdict(list)
    for row in rows:
        grouped[row["material_text"]].append(row)
    result = []
    for material_text, products in sorted(grouped.items(), key=lambda pair: (-len(pair[1]), pair[0])):
        self_rows = [row for row in products if row["scope"] == "EXCEL_IN_HOUSE"]
        targets = sorted({identity for row in products for identity in row["input_material_legacy_id"].split(",") if identity}, key=int)
        result.append({"material_text": material_text, "normalized_material_text": key(material_text), "domain": domain(material_text),
                       "all_goods": len(products), "excel_in_house_goods": len(self_rows),
                       "injection_goods": sum(row["workshop_name"] == "注塑车间" for row in self_rows),
                       "resolution_states": json.dumps(dict(Counter(row["state"] for row in products)), ensure_ascii=False),
                       "resolved_material_identities": json.dumps(targets),
                       "workshop_distribution": json.dumps(dict(Counter(row["workshop_name"] or "<unspecified>" for row in self_rows)), ensure_ascii=False),
                       "sample_products": json.dumps([{key: row[key] for key in ("parent_legacy_id", "parent_code", "parent_name", "product_status", "state")}
                                                       for row in products[:5]], ensure_ascii=False)})
    return result


def bom_link_audit(rows: list[dict], bom: list[dict], goods: list[dict]):
    goods_by_id = {row["legacy_id"]: row for row in goods}
    graph, edge_rows = defaultdict(set), defaultdict(list)
    for edge in bom:
        parent, component = edge["goods_legacy_id"], edge["component_legacy_id"]
        if positive(edge["qty"]) and parent in goods_by_id and component in goods_by_id and goods_by_id[component].get("status") != "禁用":
            graph[parent].add(component)
            edge_rows[(parent, component)].append(edge)
    results = []
    for row in rows:
        if not row["state"].startswith("ALREADY_"):
            continue
        for target in filter(None, row["input_material_legacy_id"].split(",")):
            pending, visited, found = [(row["parent_legacy_id"], [])], set(), []
            while pending:
                current, path = pending.pop()
                if current == target:
                    found = path
                    break
                if current not in visited:
                    visited.add(current)
                    pending.extend((child, path + [(current, child)]) for child in sorted(graph[current]) if child not in visited)
            facts = [{"source_bom_legacy_id": edge["legacy_id"], "parent_legacy_id": parent, "component_legacy_id": child,
                      "qty": edge["qty"], "color_legacy_id": edge.get("color_legacy_id", ""),
                      "component_unit_legacy_id": goods_by_id[child].get("unit_legacy_id", "")}
                     for parent, child in found for edge in edge_rows[(parent, child)]]
            results.append({"product_legacy_id": row["parent_legacy_id"], "product_code": row["parent_code"],
                            "material_legacy_id": target, "state": row["state"],
                            "preserved_path_edge_facts": json.dumps(facts, ensure_ascii=False), "new_pending_relationship": "false"})
    return results


LOAD_SQL = r"""-- V904 neutral material identities. No BOM/quantity/issue-method writes.
-- Caller owns BEGIN/COMMIT and sets uten.bootstrap_run_id to the base import.
CREATE TEMP TABLE injection_material_identity_stage (
    product_legacy_id integer, material_legacy_id integer, material_color_legacy_id integer,
    source_kind text, status text, provenance jsonb
) ON COMMIT DROP;
\copy injection_material_identity_stage FROM '/tmp/goods_material_identity.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM legacy_migration_runs
        WHERE run_id=NULLIF(current_setting('uten.bootstrap_run_id',true),'')::uuid
          AND migration_mode='BOOTSTRAP' AND status IN ('RUNNING','SUCCESS')) THEN
        RAISE EXCEPTION 'neutral material evidence requires its explicit base import run';
    END IF;
    IF EXISTS (SELECT 1 FROM injection_material_identity_stage
        WHERE product_legacy_id=material_legacy_id
          OR material_color_legacy_id IS DISTINCT FROM 0
          OR source_kind IS DISTINCT FROM 'LEGACY_MATERIAL_TEXT'
          OR status IS DISTINCT FROM 'PENDING_QUANTITY'
          OR provenance IS NULL OR jsonb_typeof(provenance)<>'object' OR provenance='{}'::jsonb
          OR provenance->>'quantity_unknown' IS DISTINCT FROM 'true'
          OR provenance->>'active_bom_edge_added' IS DISTINCT FROM 'false'
          OR provenance->>'material_issue_method_changed' IS DISTINCT FROM 'false')
       OR EXISTS (SELECT 1 FROM injection_material_identity_stage
                   GROUP BY product_legacy_id,material_legacy_id,material_color_legacy_id HAVING count(*)<>1) THEN
        RAISE EXCEPTION 'neutral injection identities contain duplicate or unreviewed source relationships';
    END IF;
    IF EXISTS (
       (SELECT * FROM injection_material_identity_stage EXCEPT ALL SELECT * FROM approved_material_identity_stage)
       UNION ALL
       (SELECT * FROM approved_material_identity_stage EXCEPT ALL SELECT * FROM injection_material_identity_stage)
    ) THEN RAISE EXCEPTION 'material identity CSV or per-row provenance differs from the sealed approved mapping set'; END IF;
    IF EXISTS (
        SELECT 1 FROM injection_material_identity_stage stage
        LEFT JOIN goods product ON product.legacy_id=stage.product_legacy_id AND NOT product.is_deleted AND NOT product.auto_created
        LEFT JOIN departments workshop ON workshop.id=product.owning_workshop_department_id AND NOT workshop.is_deleted
        LEFT JOIN goods material ON material.legacy_id=stage.material_legacy_id AND NOT material.is_deleted AND NOT material.auto_created
        LEFT JOIN units unit_master ON unit_master.id=material.unit_id
        LEFT JOIN unit_measurement_profiles profile ON profile.unit_id=unit_master.id
        LEFT JOIN material_categories category ON category.id=material.category_id
        WHERE product.id IS NULL OR material.id IS NULL OR material.status='禁用'
          OR material.legacy_id IN (18657,24922)
          OR btrim(material.name) IS DISTINCT FROM btrim(stage.provenance#>>'{material_master,name}')
          OR btrim(COALESCE(material.model,'')) IS DISTINCT FROM btrim(stage.provenance#>>'{material_master,model}')
          OR material.code IS DISTINCT FROM stage.provenance#>>'{material_master,code}'
          OR unit_master.legacy_id IS DISTINCT FROM (stage.provenance#>>'{material_master,unit_legacy_id}')::integer
          OR unit_master.name IS DISTINCT FROM stage.provenance#>>'{material_master,unit_name}'
          OR profile.measurement_dimension IS DISTINCT FROM 'MASS'
          OR category.legacy_id IS DISTINCT FROM (stage.provenance#>>'{material_master,parent_legacy}')::integer
          OR stage.provenance#>>'{material_master,role}' IS DISTINCT FROM 'MASS_RAW_MATERIAL_INPUT'
          OR product.source_type IS DISTINCT FROM '自制'
          OR (NULLIF(stage.provenance->>'expected_workshop_name','') IS NOT NULL
              AND workshop.name IS DISTINCT FROM stage.provenance->>'expected_workshop_name')
          OR btrim(COALESCE(product.material,'')) IS DISTINCT FROM btrim(stage.provenance->>'source_material_text')
    ) THEN RAISE EXCEPTION 'neutral material evidence does not match imported product/workshop/virgin resin identities'; END IF;
    IF EXISTS (
        SELECT 1 FROM injection_material_identity_stage stage
        JOIN goods product ON product.legacy_id=stage.product_legacy_id
        JOIN goods material ON material.legacy_id=stage.material_legacy_id
        JOIN goods_material_identity_evidence existing ON existing.product_goods_id=product.id
          AND existing.material_goods_id=material.id AND existing.material_color_id IS NULL AND NOT existing.is_deleted
        WHERE existing.source_kind IS DISTINCT FROM stage.source_kind OR existing.status IS DISTINCT FROM stage.status
          OR existing.provenance IS DISTINCT FROM stage.provenance
          OR existing.import_run_id IS DISTINCT FROM current_setting('uten.bootstrap_run_id')::uuid
    ) THEN RAISE EXCEPTION 'existing material identity evidence differs; do not overwrite user or prior-import decisions'; END IF;
END; $$;

INSERT INTO goods_material_identity_evidence (
    product_goods_id,material_goods_id,material_color_id,source_kind,status,provenance,import_run_id,created_by,updated_by
)
SELECT product.id,material.id,NULL,stage.source_kind,stage.status,stage.provenance,
       current_setting('uten.bootstrap_run_id')::uuid,
       NULLIF(current_setting('uten.rehearsal_actor_user_id',true),'')::uuid,
       NULLIF(current_setting('uten.rehearsal_actor_user_id',true),'')::uuid
FROM injection_material_identity_stage stage
JOIN goods product ON product.legacy_id=stage.product_legacy_id
JOIN goods material ON material.legacy_id=stage.material_legacy_id
ON CONFLICT DO NOTHING;

DO $$ DECLARE matched bigint; expected bigint; affected integer; BEGIN
    SELECT count(*) INTO expected FROM injection_material_identity_stage;
    SELECT count(*) INTO matched FROM injection_material_identity_stage stage
    JOIN goods product ON product.legacy_id=stage.product_legacy_id
    JOIN goods material ON material.legacy_id=stage.material_legacy_id
    JOIN goods_material_identity_evidence evidence ON evidence.product_goods_id=product.id
      AND evidence.material_goods_id=material.id AND evidence.material_color_id IS NULL AND NOT evidence.is_deleted
      AND evidence.status=stage.status AND evidence.source_kind=stage.source_kind
      AND evidence.provenance=stage.provenance AND evidence.import_run_id=current_setting('uten.bootstrap_run_id')::uuid;
    IF matched<>expected THEN RAISE EXCEPTION 'neutral injection identity count or source provenance differs'; END IF;
    UPDATE legacy_migration_runs SET reconciliation_summary=COALESCE(reconciliation_summary,'{}'::jsonb)||
        jsonb_build_object('injectionMaterialIdentities',jsonb_build_object(
            'phase','V904-neutral-material-identity-evidence','status','PENDING_QUANTITY',
            'expectedRelations',expected,'matchedRelations',matched,'activeBomEdgesAdded',0,
            'materialIssueMethodChanged',false,'wasteOutputAddedAsInput',false,
            'existingBomParents',(SELECT count(*) FROM injection_material_identity_stage stage
               JOIN goods product ON product.legacy_id=stage.product_legacy_id
               WHERE EXISTS(SELECT 1 FROM goods_bom_items edge WHERE edge.goods_id=product.id AND NOT edge.is_deleted))))
    WHERE run_id=current_setting('uten.bootstrap_run_id')::uuid AND migration_mode='BOOTSTRAP' AND status IN ('RUNNING','SUCCESS');
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF affected<>1 THEN RAISE EXCEPTION 'neutral material evidence summary requires one base import run'; END IF;
END; $$;
"""


def sql_literal(value: str) -> str:
    return "E'" + value.replace("\\", "\\\\").replace("'", "''").replace("\r", "\\r").replace("\n", "\\n") + "'"


def render_loader(relations: list[dict]) -> str:
    """Seal exact approved pairs and full JSON provenance into the SQL artifact."""
    approval = "CREATE TEMP TABLE approved_material_identity_stage (LIKE injection_material_identity_stage) ON COMMIT DROP;\n"
    for offset in range(0, len(relations), 100):
        batch = relations[offset:offset + 100]
        approval += "INSERT INTO approved_material_identity_stage VALUES\n" + ",\n".join(
            "(" + ",".join((str(int(row["product_legacy_id"])), str(int(row["material_legacy_id"])),
                            str(int(row["material_color_legacy_id"])), sql_literal(row["source_kind"]),
                            sql_literal(row["status"]), sql_literal(row["provenance"]) + "::jsonb")) + ")"
            for row in batch) + ";\n"
    return LOAD_SQL.replace("DO $$ BEGIN", approval + "DO $$ BEGIN", 1)


def prepare(goods_csv: Path, attributes_csv: Path, bom_csv: Path, unit_csv: Path, excel_dir: Path,
            output_dir: Path, production_costs_csv: Path | None = None, raw_goods_csv: Path | None = None,
            categories_csv: Path | None = None, baseline_layer: Path | None = None):
    generator_sha = digest(Path(__file__))
    if output_dir.exists() and any(output_dir.iterdir()):
        raise ValueError("output directory must be new or empty")
    categories_csv = categories_csv or bom_csv.parent / "goods_categories.csv"
    input_paths = [goods_csv, attributes_csv, bom_csv, unit_csv, categories_csv]
    if baseline_layer is not None:
        input_paths.extend(baseline_layer / filename for filename in
                           ("material_master_roles.csv", "goods_material_identity.csv", "injection_material_manifest.json"))
    if raw_goods_csv is None:
        parent_manifest = bom_csv.parent / "clean_master_manifest.json"
        if not parent_manifest.is_file():
            raise ValueError("raw goods source must be specified or bound by the clean parent manifest")
        parent = json.loads(parent_manifest.read_text(encoding="utf-8-sig"))
        raw_goods_csv = Path(parent["raw_directory"]) / "goods.csv"
    for optional in (production_costs_csv, raw_goods_csv):
        if optional is not None:
            input_paths.append(optional)
    for parent in (goods_csv.parent / "goods_excel_manifest.json", bom_csv.parent / "clean_master_manifest.json"):
        if parent.is_file() and parent not in input_paths:
            input_paths.append(parent)
    inputs = [{"path": str(path.resolve()), "sha256": digest(path)} for path in input_paths]
    _, goods = read_csv(goods_csv)
    _, attributes = read_csv(attributes_csv)
    bom_headers, bom = read_csv(bom_csv)
    _, units = read_csv(unit_csv)
    _, categories = read_csv(categories_csv)
    catalog, alias_index = material_catalog(goods, categories, units, attributes)
    _, raw_records = read_csv(raw_goods_csv)
    raw_goods = {row.get("legacy_id", row.get("ID")): {**row, "_source_row": index}
                 for index, row in enumerate(raw_records, 2)}
    bindings = {"raw_goods": {"path": str(raw_goods_csv.resolve()), "sha256": digest(raw_goods_csv)},
                "final_goods": {"path": str(goods_csv.resolve()), "sha256": digest(goods_csv)},
                "bom": {"path": str(bom_csv.resolve()), "sha256": digest(bom_csv)}}
    weight_facts, excel_inputs, excel_sources = excel_weight_audit(excel_dir)
    candidates, relations = inspect(goods, attributes, bom, excel_sources, raw_goods, bindings, catalog, alias_index)
    history, cost_rows = production_cost_audit(production_costs_csv, catalog.raw_ids)
    output_dir.mkdir(parents=True, exist_ok=True)
    # This layer never writes an executable BOM. User has confirmed that
    # actual input consumption is currently unknown.
    headers = list(candidates[0]) if candidates else ["parent_legacy_id", "state"]
    write_csv(output_dir / "all_goods_material_audit.csv", headers, candidates)
    write_csv(output_dir / "all_excel_in_house_material_audit.csv", headers, [row for row in candidates if row["scope"] == "EXCEL_IN_HOUSE"])
    write_csv(output_dir / "injection_material_structure.csv", headers,
              [row for row in candidates if row["scope"] == "EXCEL_IN_HOUSE" and row["workshop_name"] == "注塑车间"])
    write_csv(output_dir / "material_identity_pending_or_unresolved.csv", headers,
              [row for row in candidates if row["scope"] == "EXCEL_IN_HOUSE" and row["state"] not in
               ("ALREADY_DEFINED_ACTIVE_BOM", "ALREADY_COVERED_INDIRECT_BOM", "BLANK_MATERIAL_WITH_DEFINED_ACTIVE_BOM")])
    write_csv(output_dir / "goods_material_identity.csv", ["product_legacy_id", "material_legacy_id", "material_color_legacy_id", "source_kind", "status", "provenance"], relations)
    (output_dir / "goods_material_identity.sql").write_text(render_loader(relations), encoding="utf-8")
    (output_dir / "approved_material_identity_mapping.json").write_text(json.dumps(relations, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_csv(output_dir / "injection_excel_weight_audit.csv", ["file", "row", "product_code", "product_name", "material_text", "source_weight_cell", "status"], weight_facts)
    roles = [{"goods_legacy_id": identity, "code": record["row"]["code"], "name": record["row"]["name"],
              "model": record["row"].get("model", ""), "material": record["row"].get("material", ""),
              "status": record["row"].get("status", ""), "unit_legacy_id": record["row"].get("unit_legacy_id", ""),
              "category_path": "/".join(record["category_path"]), "role": record["role"],
              "normal_input_eligible": str(record["role"] == "MASS_RAW_MATERIAL_INPUT" and record["row"].get("status") != "禁用").lower()}
             for identity, record in catalog.items() if record["role"] != "OTHER_MASTER"]
    role_headers = list(roles[0]) if roles else ["goods_legacy_id", "role"]
    write_csv(output_dir / "material_master_roles.csv", role_headers, roles)
    role_decisions = [{"goods_legacy_id": identity, "code": record["row"]["code"],
                       "name": record["row"]["name"], "category_path": "/".join(record["category_path"]),
                       "unit_legacy_id": record["row"].get("unit_legacy_id", ""),
                       "status": record["row"].get("status", ""), "role": record["role"],
                       "role_evidence": json.dumps(record["role_evidence"], ensure_ascii=False)}
                      for identity, record in catalog.items()]
    write_csv(output_dir / "material_role_decisions.csv", list(role_decisions[0]), role_decisions)
    if baseline_layer is not None:
        _, old_roles = read_csv(baseline_layer / "material_master_roles.csv")
        old_output = {row["goods_legacy_id"]: row for row in old_roles
                      if row["role"] == "WASTE_REGRIND_OR_DEFECTIVE_OUTPUT"}
        review = [{**row, "previous_role": old_output[row["goods_legacy_id"]]["role"]}
                  for row in role_decisions if row["goods_legacy_id"] in old_output]
        write_csv(output_dir / "prior_output_identity_review.csv", [*list(role_decisions[0]), "previous_role"], review)
        _, old_relations = read_csv(baseline_layer / "goods_material_identity.csv")
        identity = lambda row: (row["product_legacy_id"], row["material_legacy_id"], row["material_color_legacy_id"])
        before = {identity(row): row for row in old_relations}
        after = {identity(row): row for row in relations}
        common_policy_only = 0
        unexpected_changes = []
        for pair in before.keys() & after.keys():
            old, new = json.loads(before[pair]["provenance"]), json.loads(after[pair]["provenance"])
            old.pop("excluded_normal_input_role_labels", None)
            new.pop("excluded_normal_input_role_labels", None)
            if old != new or any(before[pair][key] != after[pair][key] for key in before[pair] if key != "provenance"):
                unexpected_changes.append(pair)
            elif before[pair]["provenance"] != after[pair]["provenance"]:
                common_policy_only += 1
        delta = {"added": [after[pair] for pair in sorted(after.keys() - before.keys())],
                 "removed": [before[pair] for pair in sorted(before.keys() - after.keys())],
                 "unexpected_common_source_or_identity_changes": unexpected_changes,
                 "common_policy_label_provenance_updates": common_policy_only,
                 "prior_output_candidates_reviewed": len(review),
                 "role_review_counts": dict(Counter(row["role"] for row in review))}
        (output_dir / "material_role_identity_delta.json").write_text(json.dumps(delta, ensure_ascii=False, indent=2), encoding="utf-8")
    write_csv(output_dir / "disabled_raw_materials_review.csv", role_headers,
              [row for row in roles if row["role"] == "MASS_RAW_MATERIAL_INPUT" and row["status"] == "禁用"])
    distribution = material_distribution(candidates)
    write_csv(output_dir / "material_text_distribution.csv", list(distribution[0]), distribution)
    in_house = [row for row in candidates if row["scope"] == "EXCEL_IN_HOUSE"]
    injection = [row for row in in_house if row["workshop_name"] == "注塑车间"]
    write_csv(output_dir / "blank_material_structure_audit.csv", headers, [row for row in in_house if not row["material_text"].strip()])
    for reason, filename in (("DISABLED_RAW_MATERIAL", "disabled_material_product_review.csv"),
                             ("AMBIGUOUS_RAW_IDENTITIES", "ambiguous_material_product_review.csv"),
                             ("MIXTURE_FORMULA_REQUIRES_REVIEW", "mixed_formula_product_review.csv"),
                             ("MISSING_EXACT_RAW_MASTER_OR_ALIAS", "missing_raw_master_or_alias_review.csv"),
                             ("GENERIC_MATERIAL_NEEDS_GRADE_OR_SPECIFICATION", "generic_material_specification_review.csv")):
        write_csv(output_dir / filename, headers, [row for row in in_house if row["material_text_resolution_status"] == reason])
    links = bom_link_audit(candidates, bom, goods)
    write_csv(output_dir / "existing_bom_material_coverage.csv",
              ["product_legacy_id", "product_code", "material_legacy_id", "state", "preserved_path_edge_facts", "new_pending_relationship"], links)
    resolved_usage = []
    for target in sorted({row["material_legacy_id"] for row in relations}, key=int):
        matches = [row for row in relations if row["material_legacy_id"] == target]
        target_master = catalog[target]["row"]
        resolved_usage.append({"material_legacy_id": target, "material_code": target_master["code"], "material_name": target_master["name"],
                               "raw_model": target_master.get("model", ""), "pending_quantity_products": len(matches),
                               "workshop_distribution": json.dumps(dict(Counter(json.loads(row["provenance"])["expected_workshop_name"] or "<unspecified>" for row in matches)), ensure_ascii=False),
                               "sample_product_ids": json.dumps([row["product_legacy_id"] for row in matches[:8]])})
    write_csv(output_dir / "resolved_raw_material_coverage.csv", list(resolved_usage[0]) if resolved_usage else ["material_legacy_id"], resolved_usage)
    if production_costs_csv is not None:
        with production_costs_csv.open(encoding="utf-8-sig", newline="") as handle:
            cost_headers = next(csv.reader(handle, delimiter="|"))
        write_csv(output_dir / "injection_historical_material_cost_rows.csv", cost_headers, cost_rows)
    summary = {"format": "uten-material-identity-comprehensive-audit-v2", "all_goods": scope_summary(candidates, relations),
               "excel_in_house": scope_summary(in_house, relations), "injection": scope_summary(injection, relations),
               "raw_catalog_roles": dict(Counter(record["role"] for record in catalog.values())),
               "raw_material_identities_proved": len(catalog.raw_ids), "resolved_pending_material_types": len(resolved_usage),
               "disabled_raw_identity_count": sum(row["role"] == "MASS_RAW_MATERIAL_INPUT" and row["status"] == "禁用" for row in roles),
               "injection_goods_checked": len(injection),
               "approved_pc_e15_product_relations": sum(row["material_legacy_id"] == RAW_MATERIAL_ID for row in relations),
               "states": dict(Counter(row["state"] for row in in_house)), "active_bom_edges_added": 0,
               "neutral_pending_quantity_relations": len(relations), "executable_bom_bytes_unchanged": digest(bom_csv) == bindings["bom"]["sha256"],
               "original_bom_edges_preserved": len(bom), "source_weight_cell_issues": len(weight_facts),
               "valid_explicit_gram_weights": sum(row["status"].startswith("EXPLICIT_GRAM") for row in weight_facts),
               "historical_cost_evidence": history,
               "original_material_strings_audited": len(distribution), "existing_bom_material_links_preserved": len(links),
               "consumption_policy": "unknown consumption recorded only as V904 neutral identity; no active BOM edge, no 1/0/NULL placeholder, no net-weight guess",
               "issue_policy_changed": False, "waste_output_is_not_normal_input": True, "database_writes": 0}
    (output_dir / "injection_material_bom_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if any(digest(Path(record["path"])) != record["sha256"] for record in inputs + excel_inputs):
        raise ValueError("a bound input changed during injection-material preparation")
    if digest(Path(__file__)) != generator_sha:
        raise ValueError("the injection-material generator changed during preparation")
    outputs = [{"file": path.name, "sha256": digest(path)} for path in sorted(output_dir.iterdir()) if path.is_file()]
    manifest = {"format": "uten-material-identity-layer-v2", "generator_sha256": generator_sha,
                "inputs": inputs, "evidence_sources": excel_inputs, "outputs": outputs, "summary": summary}
    (output_dir / "injection_material_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("goods-csv", "attributes-csv", "bom-csv", "unit-csv", "excel-dir", "output-dir"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--production-costs-csv", type=Path)
    parser.add_argument("--raw-goods-csv", type=Path)
    parser.add_argument("--categories-csv", type=Path)
    parser.add_argument("--baseline-layer", type=Path)
    args = parser.parse_args()
    print(json.dumps(prepare(args.goods_csv, args.attributes_csv, args.bom_csv, args.unit_csv, args.excel_dir,
                             args.output_dir, args.production_costs_csv, args.raw_goods_csv, args.categories_csv,
                             args.baseline_layer), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
