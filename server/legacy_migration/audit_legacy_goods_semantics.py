#!/usr/bin/env python3
"""Resolve evidenced legacy goods semantics without connecting to a database.

Run after the final Excel overlay and reference-master preparation. Raw notes
remain in a private row-level ledger. Only explicit reviewed semantics produce
SQL: latest Excel original remarks -> displayed paper, V457 rear-insert codes,
unambiguous labelled missing mould references, and mould-code rack suffixes.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SEMANTIC_FIELDS = ["paper", "require_remark", "material", "pack", "b_pack", "chart_id",
                   "lights", "stock_place", "l_style", "c_number", "v_number"]
REAR_PATTERNS = [re.compile(r"换后模(.{1,30}?)镶件"),
                 re.compile(r"后模镶件用([^ \t，。;；]{1,30})")]
CODE = r"[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)+"
MOULD_PATTERNS = [re.compile(r"模具(?:编号)?\s*[:：]?\s*(" + CODE + r")"),
                  re.compile(r"(" + CODE + r")\s*模具")]
FRONT = re.compile(r"前模芯(?:编号)?\s*[:：]?\s*(" + CODE + r")")
UNSPECIFIED_CORE = re.compile(r"(?<!前)(?<!后)模芯(?:编号)?\s*[:：]?\s*(" + CODE + r")")
RACK_SUFFIX = re.compile(r"【([A-H][1-9]-[0-9]{1,2})】$")


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_csv(path: Path) -> list[dict]:
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="|"))


def write_csv(path: Path, rows: list[dict], fields: list[str]):
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, delimiter="|", lineterminator="\n")
        writer.writeheader()
        writer.writerows({field: row.get(field, "") for field in fields} for row in rows)


def rear_codes(note: str) -> set[str]:
    return {match.group(1).strip() for pattern in REAR_PATTERNS for match in pattern.finditer(note or "")}


def mould_codes(note: str) -> set[str]:
    return {match.group(1) for pattern in MOULD_PATTERNS for match in pattern.finditer(note or "")}


def location(original_code: str, existing_place: str) -> tuple[str, str] | None:
    match = RACK_SUFFIX.search(original_code or "")
    if not match:
        return None
    rack = match.group(1)
    if re.search(r"(?<![A-Za-z0-9-])"+re.escape(rack)+r"(?![A-Za-z0-9-])",existing_place or ""):
        return rack, existing_place
    return rack, " / ".join(value for value in (existing_place.strip(), rack) if value)


def field_disposition(field: str) -> str:
    return {
        "paper": "goods.paper; latest nonempty Excel original remark takes priority",
        "require_remark": "goods.require_remark; not B_Goods.Paper; retain Excel supplementary archive",
        "stock_place": "archive only; legacy B_StoragePlace identity is not a verified current goods rack",
    }.get(field, "goods." + field + "; direct named source field; never infer from an unrelated note")


SQL = """-- Derived semantic enrichment; run AFTER final goods Excel attributes and
-- mould-data, BEFORE BOM/transactions. Caller owns the transaction.
CREATE TEMP TABLE goods_note_semantics (
 goods_legacy_id int, expected_paper text, latest_paper text, expected_rear text,
 proposed_rear text, rear_action text, source_file text, source_row text);
\\copy goods_note_semantics FROM '/tmp/goods_note_semantics.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
CREATE TEMP TABLE mould_location_semantics (
 mould_legacy_id int, original_code text, expected_place text, rack_code text, proposed_place text);
\\copy mould_location_semantics FROM '/tmp/mould_location_semantics.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
CREATE TEMP TABLE goods_mould_semantics (
 goods_legacy_id int, expected_mould_id int, proposed_mould_id int, source_text text, evidence text);
\\copy goods_mould_semantics FROM '/tmp/goods_mould_semantics.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM goods_note_semantics s LEFT JOIN goods g ON g.legacy_id=s.goods_legacy_id
            WHERE g.id IS NULL OR (COALESCE(g.paper,'')<>COALESCE(s.expected_paper,'') AND COALESCE(g.paper,'')<>s.latest_paper)) THEN
  RAISE EXCEPTION 'Semantic enrichment: goods note identity or expected source drift';
 END IF;
 IF EXISTS (SELECT 1 FROM mould_location_semantics s LEFT JOIN moulds m ON m.legacy_id=s.mould_legacy_id
            WHERE m.id IS NULL OR (COALESCE(m.place,'')<>COALESCE(s.expected_place,'') AND m.place<>s.proposed_place)) THEN
  RAISE EXCEPTION 'Semantic enrichment: mould location identity or source drift';
 END IF;
 IF EXISTS (SELECT 1 FROM goods_mould_semantics s LEFT JOIN goods g ON g.legacy_id=s.goods_legacy_id
            LEFT JOIN moulds m ON m.legacy_id=s.proposed_mould_id WHERE g.id IS NULL OR m.id IS NULL
            OR COALESCE(g.mould_legacy_id,0) NOT IN (COALESCE(s.expected_mould_id,0),s.proposed_mould_id)) THEN
  RAISE EXCEPTION 'Semantic enrichment: source-backed mould reference drift';
 END IF;
END $$;
UPDATE goods g SET paper=s.latest_paper FROM goods_note_semantics s
WHERE g.legacy_id=s.goods_legacy_id AND g.paper IS DISTINCT FROM s.latest_paper;
UPDATE goods g SET rear_insert_code=s.proposed_rear FROM goods_note_semantics s
WHERE g.legacy_id=s.goods_legacy_id AND s.rear_action='SET'
AND g.rear_insert_code IS DISTINCT FROM s.proposed_rear;
UPDATE moulds m SET place=s.proposed_place FROM mould_location_semantics s
WHERE m.legacy_id=s.mould_legacy_id AND m.place IS DISTINCT FROM s.proposed_place;
UPDATE goods g SET mould_legacy_id=s.proposed_mould_id,mould_id=m.id
FROM goods_mould_semantics s JOIN moulds m ON m.legacy_id=s.proposed_mould_id
WHERE g.legacy_id=s.goods_legacy_id AND (g.mould_legacy_id IS DISTINCT FROM s.proposed_mould_id OR g.mould_id IS DISTINCT FROM m.id);
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM goods_note_semantics s JOIN goods g ON g.legacy_id=s.goods_legacy_id
            WHERE g.paper IS DISTINCT FROM s.latest_paper OR (s.rear_action='SET' AND g.rear_insert_code IS DISTINCT FROM s.proposed_rear))
 OR EXISTS (SELECT 1 FROM mould_location_semantics s JOIN moulds m ON m.legacy_id=s.mould_legacy_id WHERE m.place IS DISTINCT FROM s.proposed_place) THEN
  RAISE EXCEPTION 'Semantic enrichment: target fields differ from reviewed source';
 END IF;
END $$;
SELECT 'Excel original remarks' AS semantic_check,count(*) AS rows FROM goods_note_semantics
UNION ALL SELECT 'Mould rack locations',count(*) FROM mould_location_semantics
UNION ALL SELECT 'Evidenced missing mould references',count(*) FROM goods_mould_semantics;
"""


def audit(raw: Path, overlay: Path, references: Path, output: Path) -> dict:
    raw_goods = read_csv(raw / "goods.csv")
    final_goods = read_csv(overlay / "goods.csv")
    final = {row["legacy_id"]: row for row in final_goods}
    raw_by_id = {row["legacy_id"]: row for row in raw_goods}
    identities = {row["excel_code"]: row for row in read_csv(overlay / "goods_excel_identity.csv")}
    latest = {}
    with (overlay / "goods_excel_raw.jsonl").open(encoding="utf-8") as stream:
        for line in stream:
            record = json.loads(line)
            code = record["values"].get("产品编号", "")
            if code and code in identities:
                identity = identities[code]["legacy_id"]
                if identity in latest and latest[identity]["values"] != record["values"]:
                    raise ValueError("Repeated contradictory authoritative Excel master")
                latest[identity] = record
    moulds = {row["legacy_id"]: row for row in read_csv(references / "mould.csv")}
    old_codes = {row["legacy_id"]: row for row in read_csv(references / "original_master_codes.csv") if row["domain"] == "mould"}
    exact_moulds = defaultdict(set)
    for identity, row in old_codes.items():
        for field in ("original_code", "original_mnumber"):
            if row[field].strip():
                exact_moulds[row[field].strip()].add(identity)
    ledger, sources, notes, places, mould_updates = [], [], [], [], []
    counters = Counter()
    for row in raw_goods:
        for field in SEMANTIC_FIELDS:
            value = row[field]
            if value.strip():
                sources.append(dict(goods_legacy_id=row["legacy_id"],code=row["code"],source_column=field,
                                    source_text=value,target_policy=field_disposition(field)))
    for identity, row in final.items():
        old = raw_by_id.get(identity, {})
        rec = latest.get(identity, {})
        values = rec.get("values", {})
        latest_note = values.get("原ERP备注", "")
        selected_note = latest_note or row.get("paper", "")
        selected_source = "excel_original_remark" if latest_note else "legacy_paper"
        selected_rear = rear_codes(selected_note)
        previous_rear = rear_codes(row.get("paper", ""))
        if latest_note:
            rear_action = "SET" if len(selected_rear) == 1 else "PRESERVE"
            notes.append(dict(goods_legacy_id=identity,expected_paper=row.get("paper", ""),latest_paper=latest_note,
                              expected_rear=next(iter(previous_rear), ""),proposed_rear=next(iter(selected_rear), "") if len(selected_rear) == 1 else "",
                              rear_action=rear_action,source_file=rec["file"],source_row=rec["row"]))
            if latest_note != row.get("paper", ""):
                counters["latest_display_note_changes"] += 1
                if row.get("paper"):
                    counters["latest_display_note_nonempty_conflicts"] += 1
        if len(selected_rear) > 1:
            counters["conflicting_rear_codes"] += 1
        semantic_notes = []
        if old.get("paper"):
            semantic_notes.append(("B_Goods.Paper", old["paper"]))
        if latest_note:
            semantic_notes.append(("Excel.原ERP备注", latest_note))
        for source_field, note in semantic_notes:
            def evidence(kind, value, resolution, detail):
                ledger.append(dict(goods_legacy_id=identity,code=row["code"],source_field=source_field,
                    source_text=note,semantic_kind=kind,candidate_value=value,
                    selected_mould_legacy_id=row.get("mould_legacy_id", ""),
                    selected_mould_original_code=old_codes.get(row.get("mould_legacy_id"), {}).get("original_code", ""),
                    excel_mould_code=values.get("模具编号", ""),excel_mould_name=values.get("模具名称", ""),
                    resolution=resolution,evidence=detail,source_file=rec.get("file", "goods.csv") if source_field.startswith("Excel") else "goods.csv",
                    source_row=rec.get("row", "") if source_field.startswith("Excel") else identity))
            for candidate in sorted(rear_codes(note)):
                evidence("rear_insert_code",candidate,"STRUCTURED_V457" if source_field.startswith("Excel") or not latest_note else "LEGACY_EVIDENCE_KEEP_EXCEL_PRIORITY",
                         "V457 explicitly identifies rear insert; never use front or generic core as rear")
            for candidate in FRONT.findall(note):
                evidence("front_core_code",candidate,"PRESERVE_NO_CURRENT_TARGET_FIELD","Explicit front core; current schema has rear_insert_code only, no front-core field")
            for candidate in UNSPECIFIED_CORE.findall(note):
                evidence("unspecified_side_core_code",candidate,"PRESERVE_NO_GUESS","Core is explicit but front/rear side is not; do not populate rear_insert_code")
            for candidate in sorted(mould_codes(note)):
                selected_id = row.get("mould_legacy_id", "")
                selected_original = old_codes.get(selected_id, {})
                selected_aliases = {selected_original.get("original_code", ""),selected_original.get("original_mnumber", "")}
                if selected_original.get("original_code"):
                    selected_aliases.add(RACK_SUFFIX.sub("", selected_original["original_code"]))
                matched = exact_moulds.get(candidate, set())
                if candidate in selected_aliases and selected_id not in ("", "0"):
                    resolution, detail = "EXISTING_RELATION_CONFIRMED", "Explicit note agrees with selected legacy/Excel mould identity"
                elif selected_id not in ("", "0"):
                    resolution, detail = "KEEP_EXPLICIT_RELATION_CONFLICT", "Different or parent-tooling code in note cannot replace direct MouldID or latest Excel relation"
                elif values.get("模具编号") or values.get("模具名称"):
                    resolution, detail = "KEEP_EXCEL_REFERENCE_REVIEW", "Latest Excel mould fields exist; old note cannot override unresolved newer identity"
                elif latest_note and not source_field.startswith("Excel"):
                    resolution, detail = "KEEP_LATEST_NOTE_PRIORITY", "Latest nonempty Excel remark is authoritative; old-note-only tooling cannot override its context"
                elif len(matched) == 1 and len(mould_codes(note)) == 1:
                    target = next(iter(matched))
                    resolution, detail = "FILL_MISSING_EXACT_LABELLED_REFERENCE", "Explicit mould label plus one exact original code/backup code and no current/Excel relation"
                    proposed = dict(goods_legacy_id=identity,expected_mould_id=selected_id or "0",proposed_mould_id=target,source_text=note,evidence=detail)
                    if not any(previous["goods_legacy_id"] == identity for previous in mould_updates):
                        mould_updates.append(proposed)
                else:
                    resolution, detail = "PRESERVE_UNRESOLVED_REFERENCE", "No unique exact complete source mould code; do not truncate rack suffix or fuzzy-match a prefix"
                evidence("mould_reference",candidate,resolution,detail)
            if any(word in note for word in ("模具","镶件","前模","后模")) and not (mould_codes(note) or rear_codes(note) or FRONT.search(note) or UNSPECIFIED_CORE.search(note)):
                evidence("unresolved_tooling_instruction","","PRESERVE_NO_GUESS","Instruction lacks a unique explicit identity or rear insert code")
            if "材质" in note or "材料" in note:
                evidence("material_or_recipe_context","","KEEP_NAMED_MATERIAL_FIELD","Recipe, component material or commercial unit price is not the whole product material; Material/Excel材质 remains authoritative")
            if any(word in note for word in ("包装","螺丝","喷码","贴纸","定签","定装")):
                evidence("packaging_or_marking_instruction","","PRESERVE_IN_DISPLAYED_NOTE","Mixed assembly/brand/printing instructions cannot become a numeric package quantity or purchase multiple")
    for identity, source in old_codes.items():
        result = location(source["original_code"], moulds[identity].get("place", ""))
        if result:
            rack, proposed = result
            places.append(dict(mould_legacy_id=identity,original_code=source["original_code"],
                               expected_place=moulds[identity].get("place", ""),rack_code=rack,proposed_place=proposed))
    output.mkdir(parents=True, exist_ok=True)
    write_csv(output / "goods_semantic_field_sources.csv",sources,["goods_legacy_id","code","source_column","source_text","target_policy"])
    ledger_fields = ["goods_legacy_id","code","source_field","source_text","semantic_kind","candidate_value","selected_mould_legacy_id","selected_mould_original_code","excel_mould_code","excel_mould_name","resolution","evidence","source_file","source_row"]
    write_csv(output / "goods_semantic_decisions.csv",ledger,ledger_fields)
    write_csv(output / "goods_note_semantics.csv",notes,["goods_legacy_id","expected_paper","latest_paper","expected_rear","proposed_rear","rear_action","source_file","source_row"])
    write_csv(output / "mould_location_semantics.csv",places,["mould_legacy_id","original_code","expected_place","rack_code","proposed_place"])
    write_csv(output / "goods_mould_semantics.csv",mould_updates,["goods_legacy_id","expected_mould_id","proposed_mould_id","source_text","evidence"])
    (output / "goods_legacy_semantics.sql").write_text(SQL,encoding="utf-8")
    summary = dict(raw_goods=len(raw_goods),final_goods=len(final_goods),excel_original_remarks=len(notes),
                   raw_field_nonempty_counts={field:sum(bool(row[field].strip()) for row in raw_goods) for field in SEMANTIC_FIELDS},
                   semantic_decisions=len(ledger),resolutions=dict(Counter(row["resolution"] for row in ledger)),
                   distinct_goods_by_resolution={resolution:len({row["goods_legacy_id"] for row in ledger if row["resolution"]==resolution}) for resolution in sorted({row["resolution"] for row in ledger})},
                   mould_rack_locations=len(places),mould_missing_exact_reference_fills=len(mould_updates),
                   rear_insert_explicit_excel_count=sum(row["rear_action"]=="SET" for row in notes),
                   changes=dict(counters),production_acceptance=False)
    (output / "goods_semantics_summary.json").write_text(json.dumps(summary,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    parents = [raw/"export_manifest.json",raw/"goods.csv",overlay/"goods.csv",overlay/"goods_excel_raw.jsonl",overlay/"goods_excel_identity.csv",
               overlay/"goods_excel_manifest.json",references/"mould.csv",references/"original_master_codes.csv",references/"reference_masters_manifest.json"]
    evidence_paths=[ROOT/"docs/数据迁移/04-模具资料-老库溯源.md",ROOT/"docs/数据迁移/77-V457货品后模镶件编号.md",
                    ROOT/"server/src/main/resources/db/migration/V457__goods_rear_insert_code.sql",HERE/"migrate_goods_data.sql"]
    manifest = dict(kind="evidenced-goods-semantics-v1",generator_sha256=digest(Path(__file__)),
                    inputs=[dict(path=str(path.resolve()),sha256=digest(path)) for path in parents],
                    evidence_sources=[dict(path=str(path.resolve()),sha256=digest(path)) for path in evidence_paths],
                    outputs=[dict(file=path.name,sha256=digest(path),bytes=path.stat().st_size) for path in sorted(output.iterdir()) if path.is_file() and path.name!="goods_semantics_manifest.json"])
    (output / "goods_semantics_manifest.json").write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    return summary


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-data",type=Path,required=True)
    parser.add_argument("--overlay",type=Path,required=True)
    parser.add_argument("--references",type=Path,required=True)
    parser.add_argument("--out-dir",type=Path,required=True)
    args=parser.parse_args()
    print(json.dumps(audit(args.raw_data,args.overlay,args.references,args.out_dir),ensure_ascii=False,indent=2))


if __name__ == "__main__":
    main()
