#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =====================================================================
# HR 正式名录构建器：中山市优腾电器职工信息表.xls → data/hr_roster.csv + data/hr_managers.csv
# ---------------------------------------------------------------------
# 用法：python server/legacy_migration/build_hr_roster.py [xls路径]
#   默认 xls 路径 = 仓库根目录「中山市优腾电器职工信息表.xls」。
# 产出（data/ 下，供 migrate.sh --hr-roster 使用）：
#   hr_roster.csv    — 141 人清洗后名册（| 分隔，UTF-8，含表头）
#   hr_managers.csv  — 部门负责人指派（dept_code, emp_code）
#   并自动把两个 CSV 的 sha256 写入 data/export_manifest.sha256（copy_csv 审计要求）。
# 清洗规则（全部决策见 docs/数据迁移/53-人事正式名录迁移.md）：
#   · 出生日期/性别：身份证可解析且年份在 1945..2012 → 以身份证为准；否则以表内为准，全部记录告警。
#   · 入职时间：YYYY.MM.DD→全日期；YYYY.MM / YYYY.M→该月 1 日（单数字月份按字面解析并告警）。
#   · 高层（常务副总经理/副总经理）→ 部门=总经办(GM)，岗位职级=领导层；
#     经理 → 领导层；拉长/领班 → 班组管理；其余 → 员工。
#   · 工号：表内全空 → 由本脚本按序号从 UT_START 起编（幂等键，upsert 按 code）。
#   · 工龄：不入库——系统按 hire_date 动态计算（见员工列表/详情页）。
# =====================================================================
import hashlib
import re
import sys
from pathlib import Path

import pandas as pd
import xlrd

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
DEFAULT_XLS = HERE.parent.parent / "中山市优腾电器职工信息表.xls"
UT_START = 2  # UT0001 为已删除的测试员工，不复用；从 UT0002 起编

# ---------- 单元格批注（Excel cell comments，pandas 读不到，必须 xlrd 解析） ----------
# 名录只有姓名列 3 条批注（作者 Mayn）。结构化结论人工判读后登记在此；
# 脚本自动抽取批注原文进 note 列，若发现未登记的新批注会告警（强制人工判读）。
NOTE_STRUCTURED = {
    # (序号, 姓名): confirmed_at / base_salary / allowance_standard
    (40, "苏燕霞"): {"confirmed_at": "", "base_salary": "", "allowance_standard": "组长津贴300元/月"},
    (46, "谢宝城"): {"confirmed_at": "2026-06-01", "base_salary": "4500", "allowance_standard": ""},
    (55, "庞兴茂"): {"confirmed_at": "", "base_salary": "5000", "allowance_standard": ""},
}

# ---------- 组织映射（表内值 → departments.code） ----------
CENTER_MAP = {
    "制造与研发管理中心": "MFG_CENTER",
    "营销与新媒体管理中心": "MKT_CENTER",
    "财税与行政管理中心": "FIN_CENTER",
}
DEPT1_MAP = {
    "生产部": "DEPT_PROD",
    "工程研发部": "DEPT_ENG",
    "品质管理部": "DEPT_QA",
    "PMC运营计划部": "SUB_PLAN",
    "PMC运营采购部": "SUB_PURCHASE",
    "PMC运营仓储部": "SUB_WH",
    "综合营销事业部": "DEPT_SALES",
    "财务部": "DEPT_FIN",
    "行政与人力资源部": "DEPT_HR",
}
DEPT2_MAP = {
    "装配第一车间": "WS_ZHUANG",   # 库内原名 装配车间 → 迁移 SQL §0 改名对齐表格
    "轨道装配车间": "WS_DLGD",     # 库内原名 电力轨道装配车间 → 迁移 SQL §0 改名对齐表格
    "注塑车间": "WS_ZHUSU",
    "五金铜铸车间": "WS_WJTZ",     # 库内原名 五金铜柱车间 → 迁移 SQL §0 按表格改名（用户钦定）
    "机械加工车间": "WS_JXJG",
    "检验检测室": "QA_TEST",
}
EXEC_RANKS = {"常务副总经理", "副总经理"}   # 高层 → 总经办
TEAM_LEAD_JOBS = {"拉长", "领班"}          # 班组管理

# ---------- 部门负责人指派（规则 + 显式个案） ----------
# 规则 A：高层 → 兼任其「所在管理中心」负责人（manager_id 表达兼职，employee 仍挂 GM）。
# 规则 B：职级=经理 且 岗位职务=部门经理 → 任其最终部门负责人；同部门多人时任序号靠前者，其余告警。
# 个案（表内无法表达、按用户口述规则补充）：
EXTRA_MANAGES = {
    "朱舜炜": ["GM"],            # 常务副总经理 → 总经办负责人（董事长/总经理不在名录内）
    "徐保银": ["DEPT_PROD"],     # 副总经理兼厂长 → 兼生产部负责人
}


def parse_id_card(idc: str):
    """返回 (birth 'YYYY-MM-DD', gender 'male'/'female') 或 None。"""
    m = re.match(r"^(\d{6})(\d{4})(\d{2})(\d{2})(\d{3})([\dXx])$", (idc or "").strip())
    if not m:
        return None
    y, mo, d = int(m.group(2)), int(m.group(3)), int(m.group(4))
    if not (1 <= mo <= 12 and 1 <= d <= 31):
        return None
    if not (1945 <= y <= 2012):  # 在职员工合理出生年区间
        return None
    return f"{y:04d}-{mo:02d}-{d:02d}", ("male" if int(m.group(5)) % 2 == 1 else "female")


def id_checksum_ok(idc: str) -> bool:
    w = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
    codes = "10X98765432"
    s = sum(int(idc[i]) * w[i] for i in range(17))
    return codes[s % 11] == idc[17].upper()


def parse_sheet_date(v) -> str | None:
    """表内出生日期：'1998-03-13 00:00:00' / '1983.1.24' / '200.04.23' → YYYY-MM-DD。"""
    s = str(v).strip().split(" ")[0].replace(".", "-").replace("/", "-")
    parts = s.split("-")
    if len(parts) != 3:
        return None
    try:
        y, mo, d = int(parts[0]), int(parts[1]), int(parts[2])
        if not (1945 <= y <= 2012 and 1 <= mo <= 12 and 1 <= d <= 31):
            return None
        return f"{y:04d}-{mo:02d}-{d:02d}"
    except ValueError:
        return None


def parse_hire_date(v, warns, seq, name) -> str:
    """入职时间：'YYYY.MM.DD'→全日期；'YYYY.MM'/'YYYY.M'→该月 1 日。"""
    s = str(v).strip()
    parts = s.split(".")
    y = int(parts[0])
    mo = int(parts[1]) if len(parts) > 1 and parts[1] else 1
    d = int(parts[2]) if len(parts) > 2 and parts[2] else 1
    if len(parts) == 2 and len(parts[1]) == 1:
        warns.append(f"#{seq} {name}: 入职时间为单数字月份 {s!r}，按 {y:04d}-{mo:02d}-01 录入（请 HR 核实是否为 {mo} 月）")
    return f"{y:04d}-{mo:02d}-{d:02d}"


def norm_phone(v) -> str:
    s = str(v).strip()
    if s.endswith(".0"):
        s = s[:-2]
    return re.sub(r"\D", "", s)


def main() -> int:
    xls_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_XLS
    if not xls_path.exists():
        print(f"✗ 找不到 xls：{xls_path}")
        return 1

    df = pd.read_excel(xls_path, header=1)
    df.columns = ["序号", "姓名", "性别", "政治面貌", "出生日期", "入职时间", "工龄", "工号",
                  "所在管理中心", "一级主管部门", "二级分管部门", "职级", "岗位职务",
                  "联系电话", "身份证号", "籍贯", "现居住地址", "其它"]
    df = df[df["姓名"].notna()].reset_index(drop=True)

    # --- 单元格批注抽取（pandas 不读批注，必须 xlrd；姓名列=第 1 列） ---
    notes_by_seq: dict[int, str] = {}
    book = xlrd.open_workbook(str(xls_path), formatting_info=True)
    sheet = book.sheet_by_index(0)
    for (r, _c), note in getattr(sheet, "cell_note_map", {}).items():
        seq = int(sheet.cell_value(r, 0))
        notes_by_seq[seq] = note.text.strip()

    warns: list[str] = []
    rows: list[dict] = []
    for _, r in df.iterrows():
        seq = int(r["序号"])
        name = str(r["姓名"]).strip()

        # --- 批注：原文入 note 列，结构化字段取登记表；未登记的新批注告警 ---
        raw_note = notes_by_seq.get(seq, "")
        structured = NOTE_STRUCTURED.get((seq, name), {})
        if raw_note and not structured:
            warns.append(f"#{seq} {name}: 发现未登记的批注 {raw_note!r} → 仅原文入 note 列，请人工判读后登记 NOTE_STRUCTURED")
        idc = str(r["身份证号"]).strip()
        idc = idc[:-2] if idc.endswith(".0") else idc

        # --- 出生日期 / 性别：身份证优先（可解析时），表内兜底 ---
        id_parsed = parse_id_card(idc)
        sheet_birth = parse_sheet_date(r["出生日期"])
        sheet_gender = {"男": "male", "女": "female"}.get(str(r["性别"]).strip())
        if id_parsed:
            birth, gender = id_parsed
            if sheet_birth and sheet_birth != birth:
                warns.append(f"#{seq} {name}: 表内出生 {sheet_birth} 与身份证 {birth} 不一致 → 以身份证为准")
            if sheet_gender and sheet_gender != gender:
                warns.append(f"#{seq} {name}: 表内性别 {r['性别']} 与身份证 {'男' if gender=='male' else '女'} 不一致 → 以身份证为准")
        else:
            birth, gender = sheet_birth, sheet_gender
            warns.append(f"#{seq} {name}: 身份证 {idc!r} 无法解析有效出生日期 → 以表内 {birth} 为准，身份证原样入库，请 HR 核实")
        if not id_checksum_ok(idc):
            warns.append(f"#{seq} {name}: 身份证 {idc} 校验位不符 → 原样入库，请 HR 核实")

        # --- 入职时间 ---
        hire = parse_hire_date(r["入职时间"], warns, seq, name)

        # --- 部门 ---
        center = str(r["所在管理中心"]).strip()
        d1 = r["一级主管部门"]
        d2 = r["二级分管部门"]
        d1 = str(d1).strip() if pd.notna(d1) else ""
        d2 = str(d2).strip() if pd.notna(d2) else ""
        rank = str(r["职级"]).strip()
        job = str(r["岗位职务"]).strip() if pd.notna(r["岗位职务"]) else ""
        if center not in CENTER_MAP:
            warns.append(f"#{seq} {name}: 未知管理中心 {center!r}")
        if rank in EXEC_RANKS:
            dept_code = "GM"                      # 高层一律挂总经办
        elif d2:
            dept_code = DEPT2_MAP.get(d2, "")
            if not dept_code:
                warns.append(f"#{seq} {name}: 未知二级部门 {d2!r}")
        elif d1:
            dept_code = DEPT1_MAP.get(d1, "")
            if not dept_code:
                warns.append(f"#{seq} {name}: 未知一级部门 {d1!r}")
        else:
            dept_code = ""
            warns.append(f"#{seq} {name}: 无部门信息 → 兜底 DEPT_HR")
        dept_code = dept_code or "DEPT_HR"

        # --- 岗位（名称 + 职级） ---
        pos_name = job if job else rank           # 高层无岗位职务时用职级（常务副总经理/副总经理）
        if rank in EXEC_RANKS or rank == "经理":
            pos_level = "领导层"
        elif job in TEAM_LEAD_JOBS:
            pos_level = "班组管理"
        else:
            pos_level = "员工"

        rows.append({
            "emp_code": f"UT{UT_START + len(rows):04d}",
            "seq": seq,
            "full_name": name,
            "gender": gender or "",
            "political_status": str(r["政治面貌"]).strip() if pd.notna(r["政治面貌"]) else "",
            "birth_date": birth or "",
            "hire_date": hire,
            "dept_code": dept_code,
            "pos_name": pos_name,
            "pos_level": pos_level,
            "id_card": idc,
            "phone": norm_phone(r["联系电话"]),
            "huji": str(r["籍贯"]).strip() if pd.notna(r["籍贯"]) else "",
            "residence": str(r["现居住地址"]).strip() if pd.notna(r["现居住地址"]) else "",
            "note": raw_note,
            "confirmed_at": structured.get("confirmed_at", ""),
            "base_salary": structured.get("base_salary", ""),
            "allowance_standard": structured.get("allowance_standard", ""),
        })

    # --- 部门负责人指派 ---
    managers: dict[str, str] = {}                 # dept_code → emp_code
    for row in rows:
        manages: list[str] = []
        if row["pos_name"] in EXEC_RANKS or row["full_name"] in ("朱舜炜", "王少春", "徐保银"):
            center_code = None
            # 高层按其所在管理中心兼任中心负责人
            seq_row = df[df["序号"] == row["seq"]].iloc[0]
            center_code = CENTER_MAP.get(str(seq_row["所在管理中心"]).strip())
            if center_code:
                manages.append(center_code)
        if row["pos_level"] == "领导层" and row["pos_name"] == "部门经理":
            manages.append(row["dept_code"])
        manages += EXTRA_MANAGES.get(row["full_name"], [])
        for dc in manages:
            if dc in managers and managers[dc] != row["emp_code"]:
                warns.append(f"#{row['seq']} {row['full_name']}: 部门 {dc} 已有负责人 "
                             f"{managers[dc]} → 保留先者，请 HR 在部门页核验")
                continue
            managers[dc] = row["emp_code"]

    # --- 写 CSV（| 分隔，字段不含 | 和换行） ---
    def clean(v: str) -> str:
        return v.replace("|", "/").replace("\n", " ").replace("\r", " ")

    DATA.mkdir(exist_ok=True)
    roster_cols = ["emp_code", "seq", "full_name", "gender", "political_status", "birth_date",
                   "hire_date", "dept_code", "pos_name", "pos_level", "id_card", "phone", "huji",
                   "residence", "note", "confirmed_at", "base_salary", "allowance_standard"]
    roster_path = DATA / "hr_roster.csv"
    with roster_path.open("w", encoding="utf-8", newline="") as f:
        f.write("|".join(roster_cols) + "\n")
        for row in rows:
            f.write("|".join(clean(str(row[c])) for c in roster_cols) + "\n")

    mgr_path = DATA / "hr_managers.csv"
    with mgr_path.open("w", encoding="utf-8", newline="") as f:
        f.write("dept_code|emp_code\n")
        for dc, ec in sorted(managers.items()):
            f.write(f"{dc}|{ec}\n")

    # --- 更新 sha256 审计清单（copy_csv 强制校验） ---
    manifest = DATA / "export_manifest.sha256"
    lines = manifest.read_text(encoding="utf-8").splitlines() if manifest.exists() else []
    for path in (roster_path, mgr_path):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines = [ln for ln in lines if not ln.endswith(f"*{path.name}")]
        lines.append(f"{digest} *{path.name}")
    manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")

    # --- 报告 ---
    print(f"✔ 名册 {len(rows)} 人 → {roster_path}")
    print(f"✔ 负责人指派 {len(managers)} 部门 → {mgr_path}")
    noted = [r for r in rows if r["note"]]
    print(f"✔ 单元格批注 {len(noted)} 条（转正/薪酬/津贴已结构化入 compensation/confirmed_at）")
    for r in noted:
        print(f"    #{r['seq']} {r['full_name']}: {r['note']!r} → confirmed_at={r['confirmed_at'] or '-'} "
              f"base={r['base_salary'] or '-'} allowance={r['allowance_standard'] or '-'}")
    for dc, ec in sorted(managers.items()):
        name = next(r["full_name"] for r in rows if r["emp_code"] == ec)
        print(f"    {dc:<12} → {ec} {name}")
    print(f"\n---- 清洗告警 {len(warns)} 条 ----")
    for w in warns:
        print("  " + w)
    return 0


if __name__ == "__main__":
    sys.exit(main())
