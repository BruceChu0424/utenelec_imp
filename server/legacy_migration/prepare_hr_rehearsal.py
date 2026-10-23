#!/usr/bin/env python3
"""Prepare a private, deterministic HR bootstrap; never opens a database.

Excel is the active roster. B_Worker supplies missing attributes and historical
people. The only active person added outside Excel is chairman 朱德洪. Outputs
contain PII: use an ignored/private output directory, never attach them to Git.
"""
from __future__ import annotations

import argparse
import contextlib
import csv
import hashlib
import io
import json
import re
import sys
from collections import Counter, defaultdict
from datetime import date, datetime
from pathlib import Path

CHAIRMAN = "朱德洪"
# Exact identity confirms the historical spelling error. This is not a fuzzy
# name rule and cannot merge a new same-name person from a later snapshot.
NAME_CORRECTIONS = {("程雪莲", "程雪连")}
DEPARTMENTS = {2129: "GM", 2130: "DEPT_SALES", 2131: "DEPT_SALES",
               2132: "DEPT_HR", 2133: "DEPT_ENG", 2134: "DEPT_QA",
               2139: "DEPT_PROD", 2142: "WS_ZHUSU", 2146: "WS_WJTZ",
               2147: "SUB_PLAN", 2148: "DEPT_FIN", 2527: "DEPT_HR",
               2675: "SUB_WH", 2676: "DEPT_HR", 2680: "SUB_PURCHASE"}
COLS = ["emp_code", "seq", "legacy_id", "full_name", "gender", "political_status",
        "birth_date", "hire_date", "dept_code", "pos_name", "pos_level", "id_card",
        "phone", "huji", "residence", "note", "confirmed_at", "base_salary",
        "allowance_standard", "status", "office_phone", "email", "education",
        "source_kind", "hire_date_verified"]


class ReconciliationError(ValueError):
    """Diagnostics use row identifiers, never identity numbers or phone values."""


def text(value) -> str:
    return "" if value is None else str(value).strip()


def identity(value) -> str:
    return re.sub(r"\s", "", text(value)).upper()


def phone(value) -> str:
    return re.sub(r"\D", "", text(value).removesuffix(".0"))


def valid_date(value, *, source: str) -> str:
    value = text(value).split(" ")[0].replace("/", "-")
    if not value:
        return ""
    try:
        year, month, day = (int(part) for part in value.split("-"))
        return date(year, month, day).isoformat()
    except ValueError as exc:
        raise ReconciliationError(f"Invalid calendar date at {source}") from exc


def read_csv(path: Path) -> list[dict]:
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="|"))


def read_roster(xls: Path, out: Path) -> tuple[list[dict], list[dict], dict]:
    # Reuse reviewed department/rank, partial-date and HR annotation decisions.
    # This invocation writes only private files and suppresses old salary logs.
    import build_hr_roster as old
    import xlrd

    sheet = xlrd.open_workbook(str(xls), formatting_info=True).sheet_by_index(0)
    expected_headers = ["序号", "姓名", "性别", "政治面貌", "出生日期", "入职时间", "工龄", "工号",
                        "所在管理中心", "一级主管部门", "二级分管部门（车间）", "职级", "岗位职务",
                        "联系电话", "身份证号", "籍贯", "现居住地址", "其它"]
    if sheet.ncols != len(expected_headers) or [text(value) for value in sheet.row_values(1)] != expected_headers:
        raise ReconciliationError("Excel header/order changed; review field mapping before importing")
    sequences = []
    for rowno in range(2, sheet.nrows):
        if not text(sheet.cell_value(rowno, 1)):
            continue
        sequences.append(int(sheet.cell_value(rowno, 0)))
        center, first, second, rank = (text(sheet.cell_value(rowno, column)) for column in (8, 9, 10, 11))
        if center not in old.CENTER_MAP:
            raise ReconciliationError(f"Unknown management center at Excel row {rowno + 1}")
        if rank not in old.EXEC_RANKS:
            if second and second not in old.DEPT2_MAP:
                raise ReconciliationError(f"Unknown subordinate department at Excel row {rowno + 1}")
            if not second and first not in old.DEPT1_MAP:
                raise ReconciliationError(f"Unknown primary department at Excel row {rowno + 1}")
    if len(sequences) != len(set(sequences)) or any(value <= 0 for value in sequences):
        raise ReconciliationError("Excel sequence values must be positive and unique")
    previous = (old.DATA, old.UT_START, sys.argv)
    try:
        old.DATA, old.UT_START = out, 1
        sys.argv = [str(Path(old.__file__)), str(xls)]
        with contextlib.redirect_stdout(io.StringIO()):
            if old.main():
                raise ReconciliationError("Roster builder failed")
    finally:
        old.DATA, old.UT_START, sys.argv = previous
    rows = read_csv(out / "hr_roster.csv")
    managers = read_csv(out / "hr_managers.csv")
    raw = []
    for rowno in range(2, sheet.nrows):
        if not text(sheet.cell_value(rowno, 1)):
            continue
        values = []
        for cell in sheet.row(rowno):
            if cell.ctype == xlrd.XL_CELL_DATE:
                value = xlrd.xldate.xldate_as_datetime(cell.value, sheet.book.datemode).isoformat()
            else:
                value = cell.value
            values.append(value)
        comments = {str(c): n.text for (r, c), n in getattr(sheet, "cell_note_map", {}).items() if r == rowno}
        raw.append({"excel_row": rowno + 1, "values": values, "comments": comments})
    if len(raw) != len(rows):
        raise ReconciliationError("Spreadsheet and normalized roster counts differ")
    # Annotated compensation mappings are verified against the actual text,
    # preventing a future sheet from inheriting obsolete amounts silently.
    known_notes = {(40, "苏燕霞"): "组长300元/月", (46, "谢宝城"): "6.1转正4500",
                   (55, "庞兴茂"): "6.1调整5000元/月"}
    for index, row in enumerate(rows):
        for field, value in row.items():
            if value.lower() == "nan":
                row[field] = ""
        key = (int(row["seq"]), row["full_name"])
        normalized_note = re.sub(r"\s", "", row["note"].replace("\\n", ""))
        normalized_note = normalized_note.removeprefix("Mayn:")
        if row["note"] and normalized_note != known_notes.get(key):
            raise ReconciliationError(f"Unreviewed Excel annotation at sequence {row['seq']}")
        if key in known_notes and not row["note"]:
            row["confirmed_at"] = row["base_salary"] = row["allowance_standard"] = ""
        source = raw[index]["values"]
        if text(source[17]):
            row["note"] = "\n".join(filter(None, [row["note"], text(source[17])]))
    return rows, managers, {"headers": sheet.row_values(1), "rows": raw}


def reconcile(roster: list[dict], legacy: list[dict]) -> tuple[list[dict], list[dict], dict]:
    """Exact identity, then unique name+mobile, then unique compatible name.

    Same-name contradictory identity is blocked rather than silently merged.
    Historical duplicate identities remain separate historical rows, preserving
    each B_Worker ID required by the existing downstream importers.
    """
    output, matches = [], []
    by_id, by_phone, by_name = defaultdict(list), defaultdict(list), defaultdict(list)
    for index, source in enumerate(roster):
        row = {key: text(source.get(key)) for key in COLS}
        row.update(emp_code=f"UT{index + 1:04d}", legacy_id="", status="active",
                   source_kind="excel", hire_date_verified="true")
        row["id_card"], row["phone"] = identity(row["id_card"]), phone(row["phone"])
        row["birth_date"] = valid_date(row["birth_date"], source=f"Excel sequence {row['seq']}")
        row["hire_date"] = valid_date(row["hire_date"], source=f"Excel sequence {row['seq']}")
        if not row["hire_date"] or not row["dept_code"] or not row["pos_name"]:
            raise ReconciliationError(f"Incomplete mandatory roster fields at sequence {row['seq']}")
        output.append(row)
        if row["id_card"]:
            by_id[row["id_card"]].append(index)
        if row["phone"]:
            by_phone[row["phone"]].append(index)
        by_name[row["full_name"]].append(index)
    if any(len(group) > 1 for group in by_id.values()):
        raise ReconciliationError("Duplicate identity in authoritative roster")
    if any(len(group) > 1 for group in by_phone.values()):
        raise ReconciliationError("Duplicate mobile in authoritative roster")
    if CHAIRMAN in by_name:
        raise ReconciliationError("Chairman is now in Excel; review exception before proceeding")

    ids = [int(row["legacy_id"]) for row in legacy]
    if len(ids) != len(set(ids)) or any(value <= 0 for value in ids):
        raise ReconciliationError("Legacy worker IDs must be positive and unique")
    chairman_rows = [row for row in legacy if text(row.get("full_name")) == CHAIRMAN]
    if len(chairman_rows) != 1:
        raise ReconciliationError("Exactly one chairman source row is required")

    claimed: dict[int, int] = {}
    historical, match_counts, conflicts = [], Counter(), []
    for source in sorted(legacy, key=lambda row: int(row["legacy_id"])):
        lid = int(source["legacy_id"])
        name, idc, mobile = text(source.get("full_name")), identity(source.get("id_card")), phone(source.get("mobile"))
        if not name:
            raise ReconciliationError(f"Missing legacy name at worker {lid}")
        candidate, method = None, "historical"
        if idc and idc in by_id:
            candidate, method = by_id[idc][0], "identity"
            if output[candidate]["full_name"] != name and (name, output[candidate]["full_name"]) not in NAME_CORRECTIONS:
                raise ReconciliationError(f"Identity/name disagreement at legacy worker {lid}")
        elif mobile and mobile in by_phone and output[by_phone[mobile][0]]["full_name"] == name:
            candidate, method = by_phone[mobile][0], "name_mobile"
        elif name in by_name:
            options = by_name[name]
            if len(options) != 1:
                raise ReconciliationError(f"Ambiguous name at legacy worker {lid}")
            candidate, method = options[0], "unique_name"
        if candidate is not None:
            target = output[candidate]
            # Preserve contradictory old identity as a separate resigned
            # archive. Only the unique name+mobile pair permits old identity
            # to yield to the authoritative Excel identity.
            if idc and target["id_card"] and idc != target["id_card"]:
                if method == "name_mobile":
                    method = "name_mobile_excel_identity"
                    conflicts.append({"legacy_id": lid, "resolution": "excel_identity_by_name_mobile"})
                else:
                    historical.append((source, "legacy_identity_conflict"))
                    conflicts.append({"legacy_id": lid, "resolution": "retained_resigned_separate_identity"})
                    continue
            if candidate in claimed:
                # Keep the second historical ID as a separate resigned archive;
                # no business reference is lost and it cannot become active.
                historical.append((source, "legacy_duplicate"))
                matches.append({"legacy_id": lid, "canonical_code": target["emp_code"], "method": "duplicate_historical"})
                continue
            claimed[candidate] = lid
            target["legacy_id"] = str(lid)
            for dest, src in [("office_phone", "work_phone"), ("email", "email"),
                              ("education", "education"), ("id_card", "id_card"),
                              ("phone", "mobile"), ("huji", "nat_place"), ("residence", "address")]:
                if not target[dest]:
                    target[dest] = text(source.get(src))
            if not target["office_phone"]:
                target["office_phone"] = text(source.get("phone"))
            target["id_card"], target["phone"] = identity(target["id_card"]), phone(target["phone"])
            matches.append({"legacy_id": lid, "canonical_code": target["emp_code"], "method": method})
            match_counts[method] += 1
        else:
            historical.append((source, "chairman" if name == CHAIRMAN else "legacy_only"))

    # Chairman follows Excel people, followed by historical people by source ID.
    historical.sort(key=lambda item: (item[1] != "chairman", int(item[0]["legacy_id"])))
    default_dates = 0
    for source, kind in historical:
        lid = int(source["legacy_id"])
        raw_hire = valid_date(source.get("work_date"), source=f"legacy worker {lid}")
        if not raw_hire:
            default_dates += 1
        row = dict.fromkeys(COLS, "")
        row.update(emp_code=f"UT{len(output) + 1:04d}", legacy_id=str(lid),
                   full_name=text(source["full_name"]), status="active" if kind == "chairman" else "resigned",
                   source_kind=kind, hire_date=raw_hire or "2000-01-01", hire_date_verified="true" if raw_hire else "false",
                   birth_date=valid_date(source.get("birth_date"), source=f"legacy worker {lid}"),
                   gender={"1": "male", "2": "female"}.get(text(source.get("sex")), ""),
                   dept_code="GM" if kind == "chairman" else DEPARTMENTS.get(int(source.get("dept_legacy_id") or 0), ""),
                   pos_name="董事长" if kind == "chairman" else text(source.get("emp_style")) or "历史人员（岗位未详）",
                   pos_level="领导层" if kind == "chairman" else "员工",
                   id_card=identity(source.get("id_card")), phone=phone(source.get("mobile")),
                   huji=text(source.get("nat_place")), residence=text(source.get("address")),
                   office_phone=text(source.get("work_phone")) or text(source.get("phone")),
                   email=text(source.get("email")), education=text(source.get("education")))
        if not row["dept_code"]:
            raise ReconciliationError(f"Unmapped legacy department at worker {lid}")
        output.append(row)
        if kind != "legacy_duplicate":
            matches.append({"legacy_id": lid, "canonical_code": row["emp_code"], "method": kind})
    report = {"roster_count": len(roster), "legacy_count": len(legacy), "employee_count_excluding_admin": len(output),
              "active_excluding_admin": sum(row["status"] == "active" for row in output),
              "resigned_count": sum(row["status"] == "resigned" for row in output),
              "matches": dict(match_counts), "legacy_hire_date_fallback_count": default_dates,
              "identity_conflicts": conflicts,
              "first_code": output[0]["emp_code"], "last_code": output[-1]["emp_code"],
              "chairman_code": next(row["emp_code"] for row in output if row["source_kind"] == "chairman"),
              "identities_with_multiple_archive_rows": sum(n > 1 for n in Counter(row["id_card"] for row in output if row["id_card"]).values())}
    return output, matches, report


def write_csv(path: Path, rows: list[dict], fields: list[str]):
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, delimiter="|", lineterminator="\n")
        writer.writeheader()
        writer.writerows({field: row.get(field, "") for field in fields} for row in rows)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xls", type=Path, required=True)
    parser.add_argument("--legacy-workers", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    roster, managers, raw = read_roster(args.xls, args.out_dir)
    legacy = read_csv(args.legacy_workers)
    rows, crosswalk, report = reconcile(roster, legacy)
    report["input_sha256"] = {"xls": hashlib.sha256(args.xls.read_bytes()).hexdigest(),
                               "legacy_workers": hashlib.sha256(args.legacy_workers.read_bytes()).hexdigest()}
    report["normalized_field_nonempty_counts"] = {field: sum(bool(text(row[field])) for row in rows) for field in COLS}
    report["excel_column_nonempty_counts"] = {str(column + 1): sum(bool(text(row["values"][column])) for row in raw["rows"]) for column in range(len(raw["headers"]))}
    report["excel_annotation_count"] = sum(len(row["comments"]) for row in raw["rows"])
    report["raw_source_archived"] = True
    write_csv(args.out_dir / "hr_rehearsal.csv", rows, COLS)
    write_csv(args.out_dir / "hr_rehearsal_crosswalk.csv", crosswalk, ["legacy_id", "canonical_code", "method"])
    # Original cells, annotations, old IDs, descriptions and remarks stay
    # inspectable here even where the current application has no target field.
    (args.out_dir / "hr_source_archive.private.json").write_text(json.dumps({"excel": raw, "legacy": legacy}, ensure_ascii=False, indent=2), encoding="utf-8")
    (args.out_dir / "hr_rehearsal_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    manifest = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(args.out_dir.glob("hr*")) if path.is_file() and path.name != "hr_rehearsal_manifest.json"}
    (args.out_dir / "hr_rehearsal_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReconciliationError as error:
        print(f"HR reconciliation blocked: {error}", file=sys.stderr)
        raise SystemExit(2)
