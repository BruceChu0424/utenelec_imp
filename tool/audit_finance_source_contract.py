"""Read-only comparison of the finance template contract against its source XLSX.

Does not evaluate formulas, follow external links, or emit business row values.
Only the requirement text, public template labels, counts and hashes are read.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import posixpath
from xml.etree import ElementTree as ET
from zipfile import ZipFile

NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"


def workbook_cells(path: Path):
    """Read saved cells only, including large sheets with inflated dimensions."""
    with ZipFile(path) as archive:
        strings = []
        if "xl/sharedStrings.xml" in archive.namelist():
            strings = [
                "".join(si.itertext()) if not si.findall(".//s:t", NS) else
                "".join(node.text or "" for node in si.findall(".//s:t", NS))
                for si in ET.fromstring(archive.read("xl/sharedStrings.xml"))
            ]
        relationships = {
            rel.attrib["Id"]: rel.attrib["Target"]
            for rel in ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
            if rel.attrib.get("TargetMode") != "External"
        }
        book = ET.fromstring(archive.read("xl/workbook.xml"))
        sheets = {}
        formula_count = 0
        for sheet in book.findall("s:sheets/s:sheet", NS):
            target = relationships[sheet.attrib[f"{{{REL}}}id"]]
            member = (target.lstrip("/") if target.startswith("/") else
                      posixpath.normpath(posixpath.join("xl", target)))
            cells = {}
            for cell in ET.fromstring(archive.read(member)).findall(".//s:sheetData/s:row/s:c", NS):
                if cell.find("s:f", NS) is not None:
                    formula_count += 1
                kind = cell.attrib.get("t")
                raw = cell.findtext("s:v", default="", namespaces=NS)
                if kind == "s":
                    value = strings[int(raw)] if raw else ""
                elif kind == "inlineStr":
                    value = "".join(t.text or "" for t in cell.findall("s:is//s:t", NS))
                else:
                    value = raw
                cells[cell.attrib["r"]] = value
            sheets[sheet.attrib["name"]] = cells
    return sheets, formula_count


def audit(workbook: Path, contract_path: Path):
    contract_bytes = contract_path.read_bytes()
    contract = json.loads(contract_bytes.decode("utf-8"))
    source_hash = hashlib.sha256(workbook.read_bytes()).hexdigest()
    sheets, formula_count = workbook_cells(workbook)
    differences = []
    if source_hash != contract["sourceSha256"]:
        differences.append({"kind": "sourceHash"})
    checked = 0
    for key, template in contract["templates"].items():
        header_source = template.get("headerSource", "")
        if "!" not in header_source:
            continue
        sheet = header_source.split("!", 1)[0].strip("'")
        if sheet not in sheets:
            differences.append({"kind": "sheetMissing", "template": key, "sheet": sheet})
            continue
        for parts in template.get("headerParts", []):
            for part in parts:
                checked += 1
                actual = sheets[sheet].get(part["cell"], "").strip()
                if actual != part["label"].strip():
                    differences.append({"kind": "header", "template": key,
                                        "cell": f"{sheet}!{part['cell']}"})
    numbered_rows = {}
    for key, sheet, label_col, line_col in (
        ("monthlyProfit", "附件11", "A", "B"),
        ("balanceSheet", "附年9", "A", "B"),
        ("balanceSheet", "附年9", "E", "F"),
    ):
        template = contract["templates"][key]
        # sourceRows retains the historical wording when finance later confirmed
        # a different business mapping. Do not overwrite that provenance.
        expected = template.get("sourceRows", template["rows"])
        found = {}
        for cell, raw in sheets[sheet].items():
            if not cell.startswith(line_col) or not cell[len(line_col):].isdigit():
                continue
            if raw not in expected:
                continue
            label = sheets[sheet].get(label_col + cell[len(line_col):], "").strip()
            found[raw] = label
            if label != expected[raw].strip():
                differences.append({"kind": "rowLabel", "template": key,
                                    "line": raw, "cell": sheet + "!" + cell})
        numbered_rows.setdefault(key, set()).update(found)
    for key, rows in numbered_rows.items():
        for line in contract["templates"][key]["rows"]:
            if line not in rows:
                differences.append({"kind": "rowMissing", "template": key, "line": line})
    requirements = [sheets.get("部门汇总", {}).get(f"A{row}", "").strip()
                    for row in range(2, 22)]
    if not all(requirements):
        differences.append({"kind": "requirementMissing"})
    return {
        "sourceSha256": source_hash,
        "contractSha256": hashlib.sha256(contract_bytes).hexdigest(),
        "sourceSheetCount": len(sheets),
        "requirementCount": sum(bool(value) for value in requirements),
        "sourceFormulaCellCount": formula_count,
        "contractTemplateCount": len(contract["templates"]),
        "checkedHeaderParts": checked,
        "numberedRows": {key: len(rows) for key, rows in numbered_rows.items()},
        "differences": differences,
        "passed": not differences,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workbook", type=Path, required=True)
    parser.add_argument("--contract", type=Path, default=Path(__file__).resolve().parents[1] /
                        "server/src/main/resources/finance/template-contract-v1.json")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = audit(args.workbook, args.contract)
    encoded = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded + "\n", encoding="utf-8")
    print(encoded)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
