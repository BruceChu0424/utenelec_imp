#!/usr/bin/env python3
"""Enrich mould/supplier masters from explicit product-Excel references, offline.

Original identities and names remain intact. All display codes use GY/MJ from 1;
old numbers remain in evidence/remarks. Ambiguous names, numeric mould noise and
inconsistent new mould code/name pairs never create guessed relationships.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
from pathlib import Path
import re
import unicodedata


SUPPLIER_FIELDS = ("供应商", "主采购供应商", "主委外供应商", "其他供应商")
PLACEHOLDERS = {"", "无", "无供应商", "供应商", "外购", "自制", "自制件", "采购", "待定", "其他", "null", "none", "nan"}


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def text(value) -> str:
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return "" if value is None else str(value).strip()


def key(value: str) -> str:
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", value or "")).casefold()


def name_key(value: str) -> str:
    return key(value).translate(str.maketrans({"“": '"', "”": '"', "‘": "'", "’": "'"}))


def shelf_free_code(value: str) -> str:
    # Only the explicit trailing rack-location notation is cosmetic. Names and
    # arbitrary bracketed model qualifiers are not stripped.
    return re.sub(r"\s*[【\[]\s*[A-Za-z][0-9]+-[0-9]+\s*[】\]]\s*$", "", value).strip()


def read_csv(path: Path):
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="|")
        headers = reader.fieldnames or []
        if not headers or len(headers) != len(set(headers)):
            raise ValueError(f"invalid CSV header: {path}")
        records = list(reader)
        if any(None in row or any(value is None for value in row.values()) for row in records):
            raise ValueError(f"invalid CSV width: {path}")
        if "legacy_id" in headers and len({row["legacy_id"] for row in records}) != len(records):
            raise ValueError(f"repeated legacy master identity: {path}")
        return headers, records


def write_csv(path: Path, headers, records):
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=headers, delimiter="|", lineterminator="\n")
        writer.writeheader()
        writer.writerows(records)


def load_excel(directory: Path):
    import xlrd
    references, files = [], []
    for path in sorted(directory.glob("*.xls")):
        before = digest(path)
        book = xlrd.open_workbook(str(path), on_demand=True)
        sheet = book.sheet_by_name("产品列表")
        headers = [text(value) for value in sheet.row_values(0)]
        required = {"产品编号", "产品名称", "模具编号", "模具名称", "供应商", "主采购供应商"}
        if len(headers) != len(set(headers)) or not required <= set(headers):
            raise ValueError(f"unreviewed product workbook schema: {path.name}")
        for index in range(1, sheet.nrows):
            values = {header: text(sheet.cell_value(index, column)) for column, header in enumerate(headers)}
            if any(values.values()):
                references.append({"file": path.name, "row": index + 1, "values": values})
        book.release_resources()
        if digest(path) != before:
            raise ValueError(f"workbook changed during read: {path.name}")
        files.append({"path": str(path.resolve()), "sha256": before})
    if not files:
        raise ValueError("no product workbooks")
    return references, files


def index_fields(records, fields, normalizer=key):
    index = defaultdict(set)
    for row in records:
        for field in fields:
            if row.get(field):
                index[normalizer(row[field])].add(row["legacy_id"])
    return index


def supplier_brand(value: str) -> str:
    value = key(value)
    value = re.sub(r"^(?:(?:广东省|佛山市|中山市|东莞市|深圳市|珠海市|江门市|广州市|惠州市|顺德区|南海区|勒流镇|勒流街道|小榄镇|东凤镇|南头镇))+", "", value)
    value = re.sub(r"(?:有限责任公司|有限公司|公司|五金制品厂|塑料制品厂|塑胶制品厂|五金厂|电器厂|贸易行|经营部|工厂|厂)$", "", value)
    value = re.sub(r"(?:塑料五金制品|塑胶五金制品|五金制品|塑料制品|塑胶制品|五金塑料|五金|塑胶|电器|贸易)$", "", value)
    return value


def supplier_match(value: str, records, exact_index):
    candidates = exact_index.get(key(value), set())
    if candidates:
        return candidates, "EXACT_NAME_OR_DESCRIPTION"
    brand = supplier_brand(value)
    if len(brand) < 2 or brand in {"五金", "塑胶", "电器", "中山", "贸易", "塑料"}:
        return set(), "NO_MATCH"
    candidates = set()
    for row in records:
        # A full company label may explicitly expand a unique short name. A
        # contradictory existing full description prevents this abbreviation.
        if key(row["name"]) == brand:
            description = row.get("description", "")
            if not description or supplier_brand(description) == brand:
                candidates.add(row["legacy_id"])
    return candidates, "UNIQUE_SHORT_NAME_EXPANSION" if candidates else "NO_MATCH"


def valid_supplier(value: str) -> bool:
    return key(value) not in PLACEHOLDERS and len(key(value)) >= 2 and bool(re.search(r"[A-Za-z\u4e00-\u9fff]", value)) and not re.search(r"[;；\n\r]", value)


def valid_mould_code(value: str) -> bool:
    return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{1,79}", value)) and bool(re.search(r"[A-Za-z-]", value)) and key(value) not in PLACEHOLDERS


def new_identity(domain: str, value: str, occupied: set[int]) -> str:
    identity = -(500_000_000 + int(hashlib.sha256((domain + "\0" + key(value)).encode()).hexdigest()[:8], 16) % 400_000_000)
    while identity in occupied:
        identity -= 1
    occupied.add(identity)
    return str(identity)


def enrich(supplier_headers, suppliers, mould_headers, moulds, references):
    suppliers = [dict(row) for row in suppliers]
    moulds = [dict(row) for row in moulds]
    supplier_refs, mould_refs = defaultdict(list), defaultdict(list)
    for record in references:
        values = record["values"]
        for field in SUPPLIER_FIELDS:
            value = values.get(field, "")
            if value:
                supplier_refs[value].append((record, field))
        if values.get("模具编号"):
            mould_refs[key(values["模具编号"])].append(record)
    mapping, conflicts, creations = [], [], []

    def mapped(domain, value, identity, resolution, evidence, count):
        mapping.append({"domain": domain, "source_value": value, "target_legacy_id": identity,
                        "resolution": resolution, "evidence": evidence, "reference_fields": count})

    def conflict(domain, value, reason, candidates, names, count):
        conflicts.append({"domain": domain, "source_value": value, "reason": reason,
                          "candidate_legacy_ids": json.dumps(sorted(candidates), ensure_ascii=False),
                          "source_names": json.dumps(sorted(names), ensure_ascii=False), "reference_fields": count})

    def mould_mapped(records, identity, resolution, evidence):
        variants = Counter(record["values"]["模具编号"] for record in records)
        for value, count in sorted(variants.items()):
            mapped("mould", value, identity, resolution, evidence, count)

    def mould_conflict(records, reason, candidates, names):
        variants = Counter(record["values"]["模具编号"] for record in records)
        for value, count in sorted(variants.items()):
            conflict("mould", value, reason, candidates, names, count)

    supplier_index = index_fields(suppliers, ("name", "description"))
    occupied_suppliers = {int(row["legacy_id"]) for row in suppliers}
    for value, records in sorted(supplier_refs.items(), key=lambda pair: key(pair[0])):
        candidates, evidence = supplier_match(value, suppliers, supplier_index)
        if len(candidates) == 1:
            mapped("supplier", value, next(iter(candidates)), "MATCH_EXISTING", evidence, len(records))
        elif candidates:
            conflict("supplier", value, "AMBIGUOUS_EXISTING_SUPPLIER_IDENTITIES", candidates, {value}, len(records))
        elif valid_supplier(value):
            identity = new_identity("supplier", value, occupied_suppliers)
            created = {header: "" for header in supplier_headers}
            created.update(legacy_id=identity, parent_legacy="-1", name=value, description=value,
                           status="使用", remark="[Excel新增供应商] 来源名称明确；联系人、地址、银行及结算资料未提供，保持空值。")
            suppliers.append(created)
            supplier_index[key(value)].add(identity)
            creations.append({"domain": "supplier", "legacy_id": identity, "source_value": value, "source_name": value})
            mapped("supplier", value, identity, "NEW_EXCEL_MASTER", "EXPLICIT_SUPPLIER_FIELD_NO_EXISTING_IDENTITY", len(records))
        else:
            conflict("supplier", value, "INVALID_OR_COMPOUND_SUPPLIER_LABEL", set(), {value}, len(records))

    mould_code_index = index_fields(moulds, ("code", "mnumber"))
    mould_name_index = index_fields(moulds, ("name",), name_key)
    mould_by_id = {row["legacy_id"]: row for row in moulds}
    shelf_index = defaultdict(set)
    for row in moulds:
        stripped = shelf_free_code(row["code"])
        if stripped != row["code"]:
            shelf_index[key(stripped)].add(row["legacy_id"])
    excel_name_codes = defaultdict(set)
    for code, records in mould_refs.items():
        for record in records:
            if record["values"].get("模具名称"):
                excel_name_codes[name_key(record["values"]["模具名称"])].add(key(code))
    occupied_moulds = {int(row["legacy_id"]) for row in moulds}
    for canonical_code, records in sorted(mould_refs.items()):
        value = sorted({record["values"]["模具编号"] for record in records})[0]
        names = {record["values"].get("模具名称", "") for record in records} - {""}
        normalized_names = {name_key(name) for name in names}
        exact = mould_code_index.get(key(value), set())
        if len(exact) == 1:
            mould_mapped(records, next(iter(exact)), "MATCH_EXISTING", "EXACT_ORIGINAL_MOULD_CODE_OR_MNUMBER")
            continue
        if len(exact) > 1:
            candidates = {identity for identity in exact if len(normalized_names) == 1
                          and name_key(mould_by_id[identity]["name"]) in normalized_names}
            if len(candidates) == 1:
                mould_mapped(records, next(iter(candidates)), "MATCH_EXISTING", "EXACT_CODE_AND_UNIQUE_EXACT_NAME")
            else:
                mould_conflict(records, "AMBIGUOUS_EXISTING_MOULD_CODE", exact, names)
            continue
        candidates = {identity for identity in shelf_index.get(key(value), set())
                      if len(normalized_names) == 1 and name_key(mould_by_id[identity]["name"]) in normalized_names}
        if len(candidates) == 1:
            mould_mapped(records, next(iter(candidates)), "MATCH_EXISTING", "RACK_SUFFIX_CODE_AND_EXACT_NAME")
            continue
        if candidates:
            mould_conflict(records, "AMBIGUOUS_RACK_CODE_AND_NAME", candidates, names)
            continue
        if not valid_mould_code(value):
            mould_conflict(records, "NUMERIC_NOISE_OR_COMPOUND_MOULD_CODE", set(), names)
            continue
        if len(normalized_names) != 1 or any(name_key(name) in PLACEHOLDERS or
                not re.search(r"[A-Za-z\u4e00-\u9fff]", name) for name in names):
            mould_conflict(records, "MISSING_OR_INCONSISTENT_EXCEL_MOULD_NAME", set(), names)
            continue
        name = sorted(names)[0]
        name_candidates = mould_name_index.get(name_key(name), set())
        if len(name_candidates) == 1 and len(excel_name_codes[name_key(name)]) == 1:
            mould_mapped(records, next(iter(name_candidates)), "MATCH_EXISTING", "UNIQUE_EXACT_NAME_AND_UNIQUE_EXCEL_CODE")
        elif name_candidates or shelf_index.get(key(value)):
            # A code expansion with a contradictory name, or an already used
            # name with competing numbers, is not proof of a new physical mould.
            mould_conflict(records, "EXISTING_NAME_OR_CODE_NEEDS_IDENTITY_REVIEW",
                           name_candidates | shelf_index.get(key(value), set()), names)
        else:
            identity = new_identity("mould", value, occupied_moulds)
            created = {header: "" for header in mould_headers}
            created.update(legacy_id=identity, parent_legacy="-1", name=name, mnumber=value,
                           status="禁用" if any(label in name for label in ("封存", "停用", "报废")) else "使用",
                           remark="[Excel新增模具] 编号与名称在全部来源行一致；制造日期、保管人、穴数、存放位置未提供，保持空值。")
            moulds.append(created)
            creations.append({"domain": "mould", "legacy_id": identity, "source_value": value, "source_name": name})
            mould_mapped(records, identity, "NEW_EXCEL_MASTER", "CONSISTENT_EXPLICIT_MOULD_CODE_AND_NAME")

    original_codes = []
    for domain, records, prefix in (("supplier", suppliers, "GY"), ("mould", moulds, "MJ")):
        new_source = {row["legacy_id"]: row["source_value"] for row in creations if row["domain"] == domain}
        records.sort(key=lambda row: (int(row["legacy_id"]) < 0,
                                     int(row["legacy_id"]) if int(row["legacy_id"]) >= 0 else key(new_source.get(row["legacy_id"], row["name"]))))
        for number, row in enumerate(records, 1):
            old_code, old_mnumber = row.get("code", ""), row.get("mnumber", "")
            row["code"] = f"{prefix}{number:06d}"
            original_codes.append({"domain": domain, "legacy_id": row["legacy_id"], "original_code": old_code,
                                   "original_mnumber": old_mnumber, "new_code": row["code"]})
            if old_code:
                note = "[原始主档编号] " + json.dumps({"code": old_code, "mnumber": old_mnumber}, ensure_ascii=False, separators=(",", ":"))
                row["remark"] = "\n".join(value for value in (row.get("remark", ""), note) if value)
    return suppliers, moulds, mapping, conflicts, creations, original_codes


def prepare(source_dir: Path, excel_dir: Path, output_dir: Path):
    source_dir, excel_dir, output_dir = source_dir.resolve(), excel_dir.resolve(), output_dir.resolve()
    if source_dir == output_dir or source_dir in output_dir.parents:
        raise ValueError("output must be outside the immutable clean input directory")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise ValueError("output directory must be new or empty")
    supplier_headers, suppliers = read_csv(source_dir / "supplier.csv")
    mould_headers, moulds = read_csv(source_dir / "mould.csv")
    source_paths = [source_dir / "supplier.csv", source_dir / "mould.csv"]
    parent_manifest = source_dir / "clean_master_manifest.json"
    if not parent_manifest.is_file():
        raise ValueError("clean input provenance manifest is required")
    parent = json.loads(parent_manifest.read_text(encoding="utf-8-sig"))
    parent_outputs = {record["file"]: record["sha256"] for record in parent["outputs"]}
    if any(parent_outputs.get(path.name) != digest(path) for path in source_paths):
        raise ValueError("clean input differs from its bound parent manifest")
    source_paths.append(parent_manifest)
    source_inputs = [{"path": str(path), "sha256": digest(path)} for path in source_paths]
    references, excel_inputs = load_excel(excel_dir)
    result = enrich(supplier_headers, suppliers, mould_headers, moulds, references)
    suppliers, moulds, mapping, conflicts, creations, original_codes = result
    output_dir.mkdir(parents=True, exist_ok=True)
    write_csv(output_dir / "supplier.csv", supplier_headers, suppliers)
    write_csv(output_dir / "mould.csv", mould_headers, moulds)
    write_csv(output_dir / "excel_reference_mapping.csv", ["domain", "source_value", "target_legacy_id", "resolution", "evidence", "reference_fields"], mapping)
    write_csv(output_dir / "excel_reference_conflicts.csv", ["domain", "source_value", "reason", "candidate_legacy_ids", "source_names", "reference_fields"], conflicts)
    write_csv(output_dir / "excel_reference_new_masters.csv", ["domain", "legacy_id", "source_value", "source_name"], creations)
    write_csv(output_dir / "original_master_codes.csv", ["domain", "legacy_id", "original_code", "original_mnumber", "new_code"], original_codes)
    aliases = {"format": "uten-reference-alias-evidence-v1", "supplier": {}, "mould": {}}
    for row in mapping:
        aliases[row["domain"]][row["source_value"]] = {"legacy_id": row["target_legacy_id"], "resolution": row["resolution"], "evidence": row["evidence"]}
    (output_dir / "ref_dictionary_aliases.json").write_text(json.dumps(aliases, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    summary = {"supplier_rows": len(suppliers), "mould_rows": len(moulds), "new_masters": dict(Counter(row["domain"] for row in creations)),
               "matched_existing_unique_values": dict(Counter(row["domain"] for row in mapping if row["resolution"] == "MATCH_EXISTING")),
               "resolved_reference_fields": dict(Counter({domain: sum(row["reference_fields"] for row in mapping if row["domain"] == domain) for domain in ("supplier", "mould")})),
               "unresolved_unique_values": dict(Counter(row["domain"] for row in conflicts)),
               "unresolved_reference_fields": {domain: sum(row["reference_fields"] for row in conflicts if row["domain"] == domain) for domain in ("supplier", "mould")},
               "resolution_counts": dict(Counter(row["evidence"] for row in mapping)),
               "conflict_reasons": dict(Counter(row["reason"] for row in conflicts)), "database_writes": 0}
    (output_dir / "reference_masters_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if any(digest(Path(record["path"])) != record["sha256"] for record in source_inputs + excel_inputs):
        raise ValueError("an input changed during reference preparation")
    outputs = [{"file": path.name, "sha256": digest(path)} for path in sorted(output_dir.iterdir()) if path.is_file()]
    manifest = {"format": "uten-excel-reference-masters-v1", "script_sha256": digest(Path(__file__)),
                "source_inputs": source_inputs, "excel_inputs": excel_inputs, "outputs": outputs,
                "raw_manifest_sha256": parent.get("raw_manifest_sha256"),
                "identity_policy": "positive original identities retained; stable negative Excel reference identities; GY/MJ from 1",
                "summary": summary}
    (output_dir / "reference_masters_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--excel-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.source_dir, args.excel_dir, args.output_dir), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
