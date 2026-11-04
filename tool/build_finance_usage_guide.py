"""Reproducible finance training DOCX builder. Run with workspace Python only.

Authoring requires an explicit reviewed final-state receipt and actual app
screenshots. `--validate-only` never creates a DOCX. The caller runs the skill
artifact-operation marker once immediately before the first authoring call.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_CELL_VERTICAL_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTENT = Path(__file__).with_name("finance_usage_guide_content.json")
DEFAULT_IMAGES = Path(__file__).with_name("finance_usage_guide_screenshots.json")
FONT = "微软雅黑"
BLACK = RGBColor(0, 0, 0)


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def set_font(style, size: float, bold: bool = False) -> None:
    style.font.name = FONT
    style.font.size = Pt(size)
    style.font.bold = bold
    style.font.color.rgb = BLACK
    rpr = style.element.get_or_add_rPr()
    fonts = rpr.find(qn("w:rFonts"))
    if fonts is None:
        fonts = OxmlElement("w:rFonts")
        rpr.append(fonts)
    for slot in ("ascii", "hAnsi", "eastAsia", "cs"):
        fonts.set(qn(f"w:{slot}"), FONT)
    for slot in ("asciiTheme", "hAnsiTheme", "eastAsiaTheme", "cstheme"):
        fonts.attrib.pop(qn(f"w:{slot}"), None)
    color = rpr.find(qn("w:color"))
    if color is not None:
        for attribute in ("themeColor", "themeTint", "themeShade"):
            color.attrib.pop(qn(f"w:{attribute}"), None)
    borders = style.element.find(".//" + qn("w:pBdr"))
    if borders is not None:
        borders.getparent().remove(borders)


def configure_document(doc: Document) -> None:
    section = doc.sections[0]
    section.page_width = Cm(21)
    section.page_height = Cm(29.7)
    section.top_margin = Cm(1.9)
    section.bottom_margin = Cm(1.7)
    section.left_margin = Cm(2.0)
    section.right_margin = Cm(2.0)
    section.footer_distance = Cm(0.7)
    styles = doc.styles
    for name, size, bold in (("Normal", 10.5, False), ("Title", 23, True), ("Heading 1", 16, True), ("Heading 2", 12, True), ("Caption", 9, False)):
        set_font(styles[name], size, bold)
    normal = styles["Normal"].paragraph_format
    normal.line_spacing = 1.22
    normal.space_after = Pt(6)
    normal.widow_control = True
    for name in ("Heading 1", "Heading 2"):
        pf = styles[name].paragraph_format
        pf.keep_with_next = True
        pf.space_before = Pt(11)
        pf.space_after = Pt(7)
    styles["Title"].paragraph_format.space_after = Pt(12)
    styles["Caption"].paragraph_format.space_after = Pt(7)
    styles["Caption"].paragraph_format.keep_with_next = False
    footer = section.footer.paragraphs[0]
    footer.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    run = footer.add_run()
    run.font.name = FONT
    run.font.size = Pt(8)
    field = OxmlElement("w:fldSimple")
    field.set(qn("w:instr"), "PAGE")
    run._r.addnext(field)
    doc.core_properties.title = "财务日常操作与业务链说明"
    doc.core_properties.subject = "财务培训操作手册"
    doc.core_properties.author = "Uten"
    doc.core_properties.last_modified_by = "Uten"
    doc.core_properties.keywords = "财务 操作手册 业务链"


def add_body(doc: Document, text: str):
    return doc.add_paragraph(text)


def add_label(doc: Document, label: str, text: str) -> None:
    p = doc.add_paragraph()
    run = p.add_run(label + "  ")
    run.bold = True
    p.add_run(text)


def add_steps(doc: Document, steps: list[str]) -> None:
    doc.add_heading("操作步骤", level=2)
    for number, text in enumerate(steps, 1):
        p = doc.add_paragraph()
        p.paragraph_format.keep_together = True
        p.paragraph_format.left_indent = Cm(0.55)
        p.paragraph_format.first_line_indent = Cm(-0.55)
        p.add_run(f"{number}. ").bold = True
        p.add_run(text)


def set_cell_shading(cell, fill: str) -> None:
    pr = cell._tc.get_or_add_tcPr()
    node = OxmlElement("w:shd")
    node.set(qn("w:fill"), fill)
    pr.append(node)


def add_table(doc: Document, headers: list[str], rows: list[list[str]], widths: list[float]) -> None:
    table = doc.add_table(rows=1, cols=len(headers))
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    table_pr = table._tbl.tblPr
    borders = OxmlElement("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        node = OxmlElement(f"w:{edge}")
        for key, value in (("val", "single"), ("sz", "4"), ("color", "D9D9D9")):
            node.set(qn(f"w:{key}"), value)
        borders.append(node)
    table_pr.append(borders)
    margins = OxmlElement("w:tblCellMar")
    for edge in ("top", "left", "bottom", "right"):
        node = OxmlElement(f"w:{edge}")
        node.set(qn("w:w"), "90" if edge in ("top", "bottom") else "100")
        node.set(qn("w:type"), "dxa")
        margins.append(node)
    table_pr.append(margins)
    for index, width in enumerate(widths):
        table.columns[index].width = Cm(width)
    for index, label in enumerate(headers):
        table.rows[0].cells[index].text = label
        set_cell_shading(table.rows[0].cells[index], "E7E6E6")
    repeat = OxmlElement("w:tblHeader")
    table.rows[0]._tr.get_or_add_trPr().append(repeat)
    for record in rows:
        cells = table.add_row().cells
        for cell, value in zip(cells, record):
            cell.text = str(value)
    for row_index, row in enumerate(table.rows):
        row._tr.get_or_add_trPr().append(OxmlElement("w:cantSplit"))
        for col_index, cell in enumerate(row.cells):
            cell.width = Cm(widths[col_index])
            cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
            for p in cell.paragraphs:
                p.paragraph_format.space_after = Pt(2)
                p.paragraph_format.line_spacing = 1.1
                for run in p.runs:
                    run.font.name = FONT
                    run.font.size = Pt(9)
                    run.font.bold = row_index == 0
                    run.font.color.rgb = BLACK
    doc.add_paragraph().paragraph_format.space_after = Pt(0)


def add_picture(doc: Document, record: dict[str, Any], number: int) -> None:
    path = Path(record["path"])
    with Image.open(path) as im:
        width, height = im.size
    crop = record.get("crop", [0, 0, 0, 0])
    left, top, right, bottom = crop
    effective_width, effective_height = width * (1 - left - right), height * (1 - top - bottom)
    width_cm = 17.0
    height_cm = width_cm * effective_height / effective_width
    # Preserve original aspect ratio; do not stretch narrow dialogs to fill a page.
    if height_cm > 10.0:
        height_cm = 10.0
        width_cm = height_cm * effective_width / effective_height
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.keep_with_next = True
    p.paragraph_format.space_before = Pt(3)
    p.paragraph_format.space_after = Pt(3)
    run = p.add_run()
    drawing = run.add_picture(str(path), width=Cm(width_cm), height=Cm(height_cm))
    drawing._inline.docPr.set("descr", record["caption"])
    if any(crop):
        fill = drawing._inline.graphic.graphicData.pic.blipFill
        source_rect = OxmlElement("a:srcRect")
        for key, value in zip(("l", "t", "r", "b"), crop): source_rect.set(key, str(round(value * 100000)))
        fill.insert(1, source_rect)
    caption = doc.add_paragraph(f"图{number}  {record['caption']}", style="Caption")
    caption.alignment = WD_ALIGN_PARAGRAPH.CENTER


def validate(content: dict, screenshots: dict, state: dict | None) -> list[str]:
    errors: list[str] = []
    if len(content.get("requirementIndex", [])) != 20:
        errors.append("Expected exactly 20 original requirement index rows")
    ids = [s["id"] for s in content["sections"]]
    if len(set(ids)) != len(ids):
        errors.append("Duplicate section IDs")
    for section in content["sections"]:
        if section.get("table"):
            matrix = section["table"]
            if len(matrix["widths"]) != len(matrix["headers"]) or any(len(row) != len(matrix["headers"]) for row in matrix["rows"]):
                errors.append(f"Table schema differs in section: {section['id']}")
            if abs(sum(matrix["widths"]) - 17.0) > 0.01:
                errors.append(f"Table width exceeds designed page area: {section['id']}")
    canonical = read_json(ROOT / "server/src/main/resources/finance/template-contract-v1.json")
    entry_names = set()
    def collect(obj):
        if isinstance(obj, dict):
            for key, value in obj.items():
                if key == "entryName":
                    entry_names.add(value)
                collect(value)
        elif isinstance(obj, list):
            for item in obj:
                collect(item)
    collect(canonical)
    all_labels = [row[1] for row in content["requirementIndex"]] + [row[0] for row in content.get("crossIndex", [])]
    for labels in all_labels:
        for label in labels.split("；"):
            if label not in entry_names and label != "客户发货审核":
                errors.append(f"Requirement label differs from canonical: {label}")
    actual_images = 0
    unique_images: set[str] = set()
    for group in screenshots["groups"]:
        for record in group.get("images", []):
            p = Path(record.get("path", ""))
            if not p.is_absolute() or not p.is_file():
                errors.append(f"Screenshot is not an existing absolute path: {p}")
                continue
            if record.get("actualApp") is not True or not record.get("verifiedBy"):
                errors.append(f"Screenshot must be verified actual app: {p}")
            if not record.get("caption"):
                errors.append(f"Screenshot caption missing: {p}")
            with Image.open(p) as im:
                if min(im.size) < 300:
                    errors.append(f"Screenshot too small to read: {p}")
            actual_images += 1
            unique_images.add(sha256(p))
    if state is not None:
        required = ["final_ready", "actual_ui_verified", "cost_chain_verified", "applications_review_complete"]
        for key in required:
            if state.get(key) is not True:
                errors.append(f"Final authoring gate not met: {key}")
        if not state.get("reviewed_source_revision") or not state.get("reviewed_by"):
            errors.append("Final state needs reviewed source revision and reviewer")
        if len(unique_images) < screenshots.get("minimumVerifiedImages", 10):
            errors.append(f"Only {len(unique_images)} distinct actual screenshots; insufficient for the illustrated guide")
    return errors


def write_impact_markdown(content: dict, destination: Path, state: dict | None = None) -> None:
    final = state is not None and state.get("final_ready") is True
    status_intro = (
        "本文依据最终审核整合源码梳理原业务链、处理后的结果、上下游影响和历史兼容界限。具体验证结果见下文；不将本地联合验证视为财务认可或公司已上线。"
        if final else
        "本文依据当前整合工作树梳理原业务链、变动后的核对方式、上下游影响和历史兼容界限。当前仍在联合验证；本说明不是财务验收、上线或公司数据导入回执。最终源码、实际交互及成本链结果由整合负责人补充。"
    )
    parts = [
        "# 财务复刻业务链影响说明", "",
        "更新日期：" + content.get("dateIso", "2026-11-04") + "。" + status_intro, "",
        "本轮范围为 Web 与现有 Flutter 桌面共用业务；Win7/WPF 由用户明确排除。没有推送、部署、正式打包或公司数据库写入。", "",
        "## 财务口径与跨链原则", "",
        "销售进入主营业务收入，加工人工进入制造费用，金本进入其他业务收入，退税及客户税点按营业外口径。利息收入按真实凭证处理，缺目录科目可按实际新增，不能以同名猜配。损益类即使期末无余额，仍须按真实发生和明确结转进入利润表。", "",
        "目录、原来源、审核草稿、正式应收应付、真实资金和已过账凭证是不同状态。报表查询、原表比对、资料补录和原件生成不得再造现金、库存、应收应付或GL。原值、精度、币别、来源、历史和未知提交保留。", "",
        "塑料比例为当月结算用量÷实际耗用×100；应收汇总物料金额为期末仍欠。手续费/尾数由财务逐单选择仍欠或不再欠；仍欠只改变本次付款参考，不再欠经过真实另一人复核后冲减债务及损益。银行手续费、退货与成本调价继续按各自原业务办理。", "",
        "## 逐条业务链影响", "",
    ]
    for index, item in enumerate(content["impacts"], 1):
        parts.extend([f"### {index} {item['title']}", ""])
        for label, key in (("原触发与来源", "source"), ("原处理及核对差异", "before"), ("本轮变动", "change"), ("上下游结果", "effect"), ("旧单新单及历史日期", "history"), ("权限反审与重试", "control")):
            parts.extend([f"**{label}。** {item[key]}", ""])
        if item.get("finalizationGate") and not (state or {}).get(item["finalizationGate"]):
            gate_note = ("当前申请同源、原稿接续和原件查阅仍需最终联合实际交互及对应源码验证；不能将定向或隔离数据库结果写成全部业务验收。" if item["finalizationGate"] == "applications_review_complete" else "此链仍由成本实现负责人完成最后来源证明、真实反向与后台续办封口；未核部分保留待核，不能将保护性拦截写成业务已经完成。")
            parts.extend(["**当前验证边界。** " + gate_note, ""])
    parts.extend(["## 原20项与横切范围", "", "| 原项 | 原表或入口 | 手册位置 |", "| --- | --- | --- |"])
    for row in content["requirementIndex"]:
        parts.append("| " + " | ".join(row) + " |")
    parts.extend(["", "科目目录、科目余额表、原账套接续、应收及应付辅助明细为横切能力，不能据此减少原20项。原模板合同含30项并不代表原有30条需求。", "", "## 证据与最终结论边界", "",
        "结构核对已覆盖原20项、21张需求工作表、255个表头片段、资产55列、待摊42列、已提完39列与30个canonical入口名。后端定向、Flutter组件、真实HTTP/DB以及实际浏览器或桌面交互须各自标明，不以定向测试数相加当最终完成率。", "",
        "已有本域证据按各拥有记录查阅：全20原稿结构及混币/经营均值见《2026-11-03-财务全需求逐项验收复核》；称重采用量及调用方见《2026-11-03-称重数量采用精度与调用方回执》；一次性来源脚本见《2026-11-03-财务来源一次性手动导入说明》。这些不代表公司资料已录入、正式发布或财务已经认可。", "",
    ])
    if final:
        parts.extend([f"最终审核源码：`{state['reviewed_source_revision']}`。审核人：{state['reviewed_by']}。", ""])
        for item in state.get("validation_summary", []):
            parts.extend([item, ""])
        for item in state.get("remaining_scope", []):
            parts.extend([item, ""])
    else:
        parts.extend(["最终收口仍需冻结同一审核源码、全20联合回归、实际Web/Flutter交互、快速重复/取消/硬关闭恢复、原件全量XLSX/PDF及逐页视觉检查、成本晚到差额与真实GL反向证明，以及审批重构最新稳定实现融合。详细测试数量和最后结果只在对应冻结回执确认后更新。", ""])
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n".join(parts), encoding="utf-8")


def build(content: dict, screenshots: dict, output: Path, draft: bool = False) -> None:
    doc = Document()
    configure_document(doc)
    doc.add_paragraph(content["title"], style="Title")
    add_body(doc, content["date"])
    if draft:
        status=doc.add_paragraph();run=status.add_run("当前进度版  未最终验收");run.bold=True;run.font.size=Pt(15)
        add_body(doc,"本版先供财务熟悉入口、字段和核对顺序。尚未完成全20项的最终同源业务验收，未部署至公司服务器；示例来自本地匿名演示环境。")
        add_body(doc,"配套交接文件为同目录的《财务需求实施交接与后续使用说明.md》。详细现状、范围调整和后续接手以该文件为准。")
        footer=doc.sections[0].footer.paragraphs[0];footer.runs[0].text="当前进度版  ";footer.runs[0].font.size=Pt(8)
    for paragraph in content["intro"]:
        add_body(doc, paragraph)
    if draft:
        doc.add_heading("当前使用提醒",level=1)
        for paragraph in content.get("draftLimitations",[]):add_body(doc,paragraph)
        doc.add_page_break()
    doc.add_heading("按工作顺序阅读", level=1)
    for index, section in enumerate(content["sections"], 1):
        p = doc.add_paragraph(f"{index}  {section['title']}")
        p.paragraph_format.space_after = Pt(3)
    doc.add_page_break()
    images_by_id = {g["id"]: g.get("images", []) for g in screenshots["groups"]}
    picture_number = 0
    for number, section in enumerate(content["sections"], 1):
        doc.add_heading(f"{number}  {section['title']}", level=1)
        if draft and section.get("draftNote"):add_label(doc,"本章当前状态",section["draftNote"])
        for paragraph in section.get("paragraphs", []):
            add_body(doc, paragraph)
        if section.get("table"):
            matrix = section["table"]
            add_table(doc, matrix["headers"], matrix["rows"], matrix["widths"])
        records = [r for group in section.get("figures", []) for r in images_by_id.get(group, [])]
        if records:
            for record in records:
                picture_number += 1
                add_picture(doc, record, picture_number)
        add_steps(doc, section.get("steps", []))
        add_label(doc, "核对结果", section["result"])
    doc.add_page_break()
    doc.add_heading("原20项需求查找目录", level=1)
    add_body(doc, "以下表名保持财务原名。原附表位于相应报表切换入口，不另造业务菜单。")
    add_table(doc, ["原项", "原表或入口", "阅读位置"], content["requirementIndex"], [1.2, 9.1, 6.7])
    doc.add_heading("科目期初与辅助核对入口", level=2)
    add_table(doc, ["入口", "阅读位置"], content["crossIndex"], [10.0, 7.0])
    doc.add_page_break()
    doc.add_heading("原业务链影响", level=1)
    add_body(doc, "以下按原业务发生顺序说明哪些上下游一起变化，以及历史单据、反审和重试应如何保持一致。")
    for index, item in enumerate(content["impacts"], 1):
        doc.add_heading(f"{index}  {item['title']}", level=2)
        for label, key in (("原来源", "source"), ("原处理", "before"), ("处理与结果", "change"), ("上下游", "effect"), ("历史与反向", "history"), ("核对要点", "control")):
            add_label(doc, label, item[key])
    if draft:
        doc.add_page_break();doc.add_heading("后续财务验收与接续摘要",level=1)
        for title,text in content.get("draftRemaining",[]):
            doc.add_heading(title,level=2);add_body(doc,text)
        add_body(doc,"完整20项清单、当前代码位置和接手顺序详见配套交接文件。原入口与表头另见《财务表格入口与表头清单.md》。")
    output.parent.mkdir(parents=True, exist_ok=True)
    doc.save(output)
    print(json.dumps({"output": str(output), "bytes": output.stat().st_size, "sha256": sha256(output), "sections": len(content["sections"]), "requirements": len(content["requirementIndex"]), "actualImages": picture_number}, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--content", type=Path, default=DEFAULT_CONTENT)
    parser.add_argument("--screenshots", type=Path, default=DEFAULT_IMAGES)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "output/finance-usage-guide-20261103/财务日常操作与业务链说明.docx")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--draft",action="store_true",help="User-requested current progress copy, without asserting final gates")
    parser.add_argument("--write-impact-md", type=Path)
    args = parser.parse_args()
    content = read_json(args.content)
    screenshots = read_json(args.screenshots)
    state = read_json(args.state) if args.state else None
    problems = validate(content, screenshots, None if args.draft else state)
    if problems:
        raise SystemExit("\n".join(problems))
    if args.write_impact_md:
        write_impact_markdown(content, args.write_impact_md, state)
    if args.validate_only:
        print(json.dumps({"valid": True, "sections": len(content["sections"]), "requirements": 20, "impacts": len(content["impacts"]), "finalStateProvided": state is not None}, ensure_ascii=False))
        return
    if state is None and not args.draft:
        raise SystemExit("Authoring requires --state with reviewed final-state receipt")
    build(content, screenshots, args.output, draft=args.draft)


if __name__ == "__main__":
    main()
