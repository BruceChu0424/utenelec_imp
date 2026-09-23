#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
产品列表 Excel 移植脚本（新 ERP → uten_imp 平台）

用途
----
平台上架 / 数据重导时，把 `product lists/` 目录下三个新 ERP 导出的产品列表
（20260409172229_1.xls / _2.xls / _3.xls，工作表「产品列表」，80 列）灌入平台库。
下面第 1、2 段按 **产品编号 = goods.code** 匹配；第 3 段(所属仓库)按 **产品名称** 匹配：

1. 「来源」属性（goods.source_type，V128）：产品角色 自制件→自制、外购件→采购、委外件→委外。
2. 空值补齐（仅当库内字段为空才补，不覆盖已有值）：
   系列 series、材质 material、型号 model、规格 spec、客户型号 c_number、
   备注 require_remark（←原ERP备注）、单重 m_weight（←单重（克））、
   主颜色 color_legacy_id（←颜色，按名称对 colors 字典，缺名自动建色）、
   单位 unit_legacy_id（←基本单位，按名称对 units 字典，千克→kg 别名）。

【2026-07-31 决策修订】分类树只走老树，Excel 只读取内容：
- 默认 **不再** 按 Excel「产品分类」路径建新分类、不再改 goods.category_id；
  分类结构以老库迁移树为准（2026-07-30 的首次导入曾重指 21883 个货品分类，
  已于 2026-07-31 全部回滚并删除新建的 493 个 XL 分类）。
- 只有显式传 `--recategorize` 才恢复旧行为（按 `a->b->c` 路径幂等建节点挂在
  根「货品资料」下，并把匹配货品的 category_id 重指到叶子分类）。
4. 核对机制（“确定是这个产品”）：编号命中后再比对名称（去空白）。
   - 名称一致或互相包含 → 视为同一产品，执行导入；
   - 名称明显不同 → 不导入，写入复核清单 `import_report/name_mismatch.csv` 人工确认。

不导入（有意跳过，见文档 docs/数据迁移/49-产品列表Excel移植.md）：
- 使用状态 status（平台现行状态为准，不用 Excel「启用状态」覆盖）；
- 供应商（Excel 供应商名与平台供应商主档仅 23 个重名，误挂风险高）；
- 价格类（建议进价/售价多为 0，无参考价值）。

用法
----
    pip install xlrd psycopg2-binary
    python server/legacy_migration/import_product_lists.py            # 干跑（只出报告，不写库）
    python server/legacy_migration/import_product_lists.py --apply    # 正式导入

数据库连接走环境变量（主机等默认本机开发库；密码必须显式注入）：
    UTEN_DB_HOST(127.0.0.1) UTEN_DB_PORT(5433) UTEN_DB_NAME(uten_imp)
    UTEN_DB_USER(uten) UTEN_DB_PASSWORD(required)

另有一段**按产品名称**匹配(与上面按编号的补字段完全分开)：

3. 所属仓库 goods.owning_warehouse_id(V587)：Excel「所属仓库」列(五金仓库 /
   塑胶仓库 / 包材仓库 / 成品仓库 / 五金车间)按**产品名称**对上库内货品。
   为什么这一段不按编号：这批 Excel 的编号只命中 22488 分之 85，名称却是干净的
   (17010 个不重名、同名映射到两个仓库的冲突 0 条)，2026-09-15 用户明确指定按名称。
   - 只填空：库里已有值一律不动，重跑不会冲掉界面上人工改过的所属仓库
     (要覆盖得显式传 --overwrite-warehouse)；
   - 仓库按名称对 warehouses，缺的补建 auto_created=true 存根(编码 XW01/XW02…)；
   - 库里没有 goods.owning_warehouse_id(V587 未应用)时整段跳过并明说。

幂等：可重复执行。分类按(父, 名称)查建、颜色按名称查建、仓库按名称查建、
货品更新结果收敛(实测第二遍写入 0 行、补建 0 个仓库)。
报告：`<数据目录>/import_report/` 下 summary.txt + 四份 CSV
(含 warehouse_unmatched.csv：Excel 有这个名字、库里没有同名货品，属正常差集)。
"""
from __future__ import annotations

import argparse
import csv
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import psycopg2
import xlrd

# ----- 默认路径：环境变量 UTEN_LEGACY_INPUT_DIR 下的 product lists 目录 -----
# 原始 Excel 含业务数据, 2026-09-23 起不放在代码仓库里; 未设置变量时必须显式传 --data-dir。
_LEGACY_INPUT_DIR = os.environ.get("UTEN_LEGACY_INPUT_DIR", "").strip()
DEFAULT_DATA_DIR = Path(_LEGACY_INPUT_DIR) / "product lists" if _LEGACY_INPUT_DIR else None
DEFAULT_FILES = [
    "20260409172229_1.xls",
    "20260409172229_2.xls",
    "20260409172229_3.xls",
]

ROLE_MAP = {"自制件": "自制", "外购件": "采购", "委外件": "委外"}
UNIT_ALIAS = {"千克": "kg"}  # Excel 单位名 → 平台 units.name
ROOT_CODE = "GOODS"          # 分类树根「货品资料」
NEW_CODE_PREFIX = "XL"       # 新建分类编码前缀（XL01/XL02…，每父级内按序）
NEW_WAREHOUSE_PREFIX = "XW"  # 自动补建仓库存根的编码前缀（XW01/XW02…）


def cell_str(v) -> str:
    """xlrd 单元格 → 干净字符串（数值型编号去 .0，去首尾空白）。"""
    if v is None:
        return ""
    if isinstance(v, float):
        if v == int(v):
            return str(int(v))
        return str(v).strip()
    return str(v).strip()


def norm_name(s: str) -> str:
    """名称比对用：去全部空白字符。"""
    return re.sub(r"\s+", "", s or "")


# =====================================================================
# 1. 读取 Excel
# =====================================================================

def load_rows(data_dir: Path, files: list[str]) -> list[dict]:
    rows: list[dict] = []
    for fn in files:
        p = data_dir / fn
        if not p.exists():
            print(f"[WARN] 文件不存在，跳过：{p}")
            continue
        wb = xlrd.open_workbook(str(p))
        s = wb.sheet_by_index(0)
        hdr = [cell_str(s.cell_value(0, c)) for c in range(s.ncols)]
        ci = {h: k for k, h in enumerate(hdr)}
        need = ["产品名称", "产品编号", "产品角色", "产品分类"]
        for col in need:
            if col not in ci:
                raise SystemExit(f"{fn} 缺少必需列「{col}」，表头={hdr[:10]}…")

        def g(r, col):
            return cell_str(s.cell_value(r, ci[col])) if col in ci else ""

        for r in range(1, s.nrows):
            rec = {
                "file": fn, "row": r + 1,
                "code": g(r, "产品编号"),
                "name": g(r, "产品名称"),
                "role": g(r, "产品角色"),
                "category_path": g(r, "产品分类"),
                "series": g(r, "系列"),
                "color": g(r, "颜色"),
                "material": g(r, "材质"),
                "spec": g(r, "规格"),
                "model": g(r, "产品型号"),
                "c_number": g(r, "客户型号"),
                "m_weight": g(r, "单重（克）"),
                "remark": g(r, "原ERP备注"),
                "unit": g(r, "基本单位"),
                # 所属仓库(V587)：这批货平时归哪个仓管。列可能缺席(旧导出)，
                # 缺了就是空串，后面整段自动跳过。
                "warehouse": g(r, "所属仓库"),
            }
            if not rec["code"] and not rec["name"]:
                continue  # 空行
            rows.append(rec)
    return rows


# =====================================================================
# 2. 主流程
# =====================================================================

def main() -> None:
    ap = argparse.ArgumentParser(description="产品列表 Excel 移植（干跑/导入）")
    ap.add_argument("--apply", action="store_true", help="正式写库（缺省只干跑出报告）")
    ap.add_argument("--recategorize", action="store_true",
                    help="【默认关闭】按 Excel 产品分类路径建新分类树并重指货品分类；"
                         "2026-07-31 决策：分类结构只走老树，Excel 只补字段，勿随意开启")
    ap.add_argument("--overwrite-warehouse", action="store_true",
                    help="【默认关闭】连库里已有的所属仓库一起覆盖；默认只填空，不冲掉界面上人工改过的值")
    ap.add_argument("--data-dir", default=str(DEFAULT_DATA_DIR) if DEFAULT_DATA_DIR else None,
                    required=DEFAULT_DATA_DIR is None,
                    help="Excel 所在目录(默认 $UTEN_LEGACY_INPUT_DIR/product lists)")
    ap.add_argument("--files", nargs="*", default=DEFAULT_FILES, help="文件名列表")
    args = ap.parse_args()

    data_dir = Path(args.data_dir)
    report_dir = data_dir / "import_report"
    report_dir.mkdir(parents=True, exist_ok=True)

    rows = load_rows(data_dir, args.files)
    print(f"Excel 数据行：{len(rows)}")

    # 编号去重（同号后出现的覆盖先出现的，并记录；价格策略等无编号行单列）
    by_code: dict[str, dict] = {}
    no_code: list[dict] = []
    dup_codes: Counter = Counter()
    for rec in rows:
        if not rec["code"]:
            no_code.append(rec)
            continue
        if rec["code"] in by_code:
            dup_codes[rec["code"]] += 1
        by_code[rec["code"]] = rec
    print(f"唯一产品编号：{len(by_code)}；无编号行（价格策略等）：{len(no_code)}；重复编号：{sum(dup_codes.values())}")

    database_password = os.environ.get("UTEN_DB_PASSWORD")
    if database_password is None or not database_password.strip():
        raise SystemExit("UTEN_DB_PASSWORD is required for legacy product-list import")

    conn = psycopg2.connect(
        host=os.environ.get("UTEN_DB_HOST", "127.0.0.1"),
        port=int(os.environ.get("UTEN_DB_PORT", "5433")),
        dbname=os.environ.get("UTEN_DB_NAME", "uten_imp"),
        user=os.environ.get("UTEN_DB_USER", "uten"),
        password=database_password,
    )
    conn.autocommit = False
    cur = conn.cursor()
    cur.execute("SELECT set_config('app.business_identifier_legacy_import', 'on', true)")

    # ----- 库内货品（未软删、有编号） -----
    cur.execute("""
        SELECT id, code, name, series, material, model, spec, c_number,
               require_remark, m_weight, color_legacy_id, unit_legacy_id,
               source_type, category_id
        FROM goods WHERE is_deleted = false AND code IS NOT NULL
    """)
    db = {}
    for r in cur.fetchall():
        db[r[1].strip()] = {
            "id": r[0], "name": r[2], "series": r[3], "material": r[4],
            "model": r[5], "spec": r[6], "c_number": r[7], "remark": r[8],
            "m_weight": r[9], "color": r[10], "unit": r[11],
            "source_type": r[12], "category_id": r[13],
        }
    print(f"库内货品（有编号）：{len(db)}")

    # ----- 匹配 + 名称核对 -----
    verified: list[tuple[dict, dict]] = []   # (excel, db)
    mismatch: list[tuple[dict, str]] = []    # (excel, db_name)
    unmatched: list[dict] = []
    for code, rec in by_code.items():
        g = db.get(code)
        if g is None:
            unmatched.append(rec)
            continue
        xn, dn = norm_name(rec["name"]), norm_name(g["name"] or "")
        if xn and (xn == dn or xn in dn or dn in xn):
            verified.append((rec, g))
        else:
            mismatch.append((rec, g["name"] or ""))
    print(f"匹配命中：{len(verified) + len(mismatch)}；名称核对通过：{len(verified)}；"
          f"名称不符（转人工复核）：{len(mismatch)}；编号未命中：{len(unmatched)}")

    # ----- 分类树：按路径建节点（仅 --recategorize 显式开启时；默认不动分类结构） -----
    by_parent_name: dict[tuple, tuple] = {}  # (parent_id, name) -> (id, level, path)
    child_codes: dict[object, set] = {}
    root = None
    if args.recategorize:
        cur.execute("SELECT id, parent_id, name, code, level, path FROM material_categories WHERE is_deleted = false")
        cat_rows = cur.fetchall()
        for cid, pid, name, code, level, path in cat_rows:
            by_parent_name[(pid, name)] = (cid, level, path)
            child_codes.setdefault(pid, set()).add(code or "")
            if pid is None and code == ROOT_CODE:
                root = (cid, level, path)
        if root is None:
            raise SystemExit("找不到分类根「货品资料」(code=GOODS)，请先完成老库分类迁移")

    stats: Counter = Counter()
    now = datetime.now(timezone.utc)

    def next_code(pid) -> str:
        used = child_codes.setdefault(pid, set())
        n = 1
        while f"{NEW_CODE_PREFIX}{n:02d}" in used:
            n += 1
        code = f"{NEW_CODE_PREFIX}{n:02d}"
        used.add(code)
        return code

    def ensure_category(path_str: str):
        """按 `a->b->c` 路径幂等建节点，返回叶子 (id, level, path)。"""
        parts = [p.strip() for p in path_str.split("->") if p.strip()]
        if not parts:
            return None
        pid, level, path = root
        for name in parts:
            hit = by_parent_name.get((pid, name))
            if hit is None:
                code = next_code(pid)
                cid = None
                if args.apply:
                    cur.execute(
                        """INSERT INTO material_categories
                           (id, legacy_id, code, name, parent_id, level, sort_order, path,
                            created_at, updated_at, is_deleted)
                           VALUES (gen_random_uuid(), NULL, %s, %s, %s, %s, %s, %s, %s, %s, false)
                           RETURNING id""",
                        (code, name, pid, level + 1, 0, f"{path}{code}/", now, now))
                    cid = cur.fetchone()[0]
                else:
                    cid = f"dry:{pid}:{name}"
                hit = (cid, level + 1, f"{path}{code}/")
                by_parent_name[(pid, name)] = hit
                stats["分类新建"] += 1
            pid, level, path = hit
        return (pid, level, path)

    # ----- 颜色字典：按名对 legacy_id，缺名建色 -----
    cur.execute("SELECT legacy_id, name FROM colors WHERE is_deleted = false AND name IS NOT NULL")
    color_by_name = {}
    max_color_legacy = 0
    for lid, name in cur.fetchall():
        clean = norm_name(name)
        if clean and clean not in color_by_name:
            color_by_name[clean] = lid
        if lid and lid > max_color_legacy:
            max_color_legacy = lid

    def ensure_color(name: str):
        key = norm_name(name)
        if not key:
            return None
        if key in color_by_name:
            return color_by_name[key]
        nonlocal_max[0] += 1
        lid = nonlocal_max[0]
        if args.apply:
            cur.execute(
                """INSERT INTO colors (id, legacy_id, code, name, status,
                                       created_at, updated_at, is_deleted)
                   VALUES (gen_random_uuid(), %s, %s, %s, '使用', %s, %s, false)""",
                (lid, f"XC{lid:04d}", name, now, now))
        color_by_name[key] = lid
        stats["颜色新建"] += 1
        return lid

    nonlocal_max = [max_color_legacy]

    # ----- 单位字典：别名 + 按名 -----
    cur.execute("SELECT legacy_id, name FROM units WHERE is_deleted = false AND name IS NOT NULL")
    unit_by_name = {}
    for lid, name in cur.fetchall():
        clean = norm_name(name)
        if clean and clean not in unit_by_name:
            unit_by_name[clean] = lid

    def unit_legacy(name: str):
        key = norm_name(name)
        if not key:
            return None
        key = UNIT_ALIAS.get(key, key)
        return unit_by_name.get(key)

    # ----- 逐条更新 -----
    def blank(v):
        return v is None or (isinstance(v, str) and v.strip() == "")

    updates = 0
    for rec, g in verified:
        sets, params = {}, []

        role = ROLE_MAP.get(rec["role"])
        if role and g["source_type"] != role:
            sets["source_type"] = role

        # 分类重指：仅 --recategorize 时启用（默认分类结构只走老树，Excel 只补内容字段）
        if args.recategorize:
            leaf = ensure_category(rec["category_path"]) if rec["category_path"] else None
            if leaf and str(g["category_id"]) != str(leaf[0]):
                sets["category_id"] = leaf[0]

        fills = [
            ("series", "series", str), ("material", "material", str),
            ("model", "model", str), ("spec", "spec", str),
            ("c_number", "c_number", str), ("remark", "require_remark", str),
        ]
        for xkey, col, _ in fills:
            xv = rec[xkey]
            if xv and blank(g[xkey if xkey != "remark" else "remark"]):
                sets[col] = xv
                stats[f"补-{col}"] += 1

        if rec["m_weight"] and g["m_weight"] is None:
            try:
                sets["m_weight"] = float(rec["m_weight"])
                stats["补-m_weight"] += 1
            except ValueError:
                pass

        if rec["color"] and g["color"] is None:
            lid = ensure_color(rec["color"])
            if lid:
                sets["color_legacy_id"] = lid
                stats["补-color_legacy_id"] += 1

        if rec["unit"] and g["unit"] is None:
            lid = unit_legacy(rec["unit"])
            if lid:
                sets["unit_legacy_id"] = lid
                stats["补-unit_legacy_id"] += 1

        if not sets:
            stats["无需更新"] += 1
            continue
        updates += 1
        if args.apply:
            sets["updated_at"] = now
            cols = ", ".join(f"{k} = %s" for k in sets)
            cur.execute(f"UPDATE goods SET {cols} WHERE id = %s",
                        (*sets.values(), g["id"]))
        if "source_type" in sets:
            stats[f"来源-{role}"] += 1
        if "category_id" in sets:
            stats["分类重指"] += 1

    # =================================================================
    # 3. 所属仓库(V587，goods.owning_warehouse_id)
    # =================================================================
    # 与上面「按产品编号补字段」**完全分开的一段**，因为匹配键不同：
    # 编号在这批 Excel 里只命中 85/22488，名称却是干净的(17010 个不重名、
    # 同名映射到两个仓库的冲突 0 条)。2026-09-15 用户明确指定按名称匹配。
    #
    # 三条口径：
    # ① 只填空：库里已经有值就不动。界面上计划员可以改所属仓库，重跑本脚本
    #    绝不能把人工改过的值冲掉(--overwrite-warehouse 显式覆盖除外)。
    # ② 仓库按名称对 warehouses；缺的仓库补建 auto_created=true 存根
    #    (与本脚本既有的「缺名自动建色」同款处理)，挂在根仓下。
    # ③ V587 未应用时整段跳过并明说，不让脚本在 42703 上炸掉。
    wh_updates = 0
    wh_created: list[str] = []
    wh_unmatched: list[tuple[str, str]] = []
    cur.execute("""
        SELECT 1 FROM information_schema.columns
         WHERE table_name = 'goods' AND column_name = 'owning_warehouse_id'
    """)
    has_warehouse_column = cur.fetchone() is not None
    excel_warehouse_rows = sum(1 for rec in rows if rec.get("warehouse"))

    if not has_warehouse_column:
        print("[SKIP] 所属仓库：库里没有 goods.owning_warehouse_id，请先应用 V587 迁移")
    elif excel_warehouse_rows == 0:
        print("[SKIP] 所属仓库：Excel 没有「所属仓库」列(旧版导出)")
    else:
        # ---- Excel 侧：名称 → 仓库名(冲突名整条丢弃，宁可不填也不填错) ----
        wh_by_name: dict[str, str] = {}
        wh_conflicts: set[str] = set()
        for rec in rows:
            key, wh = norm_name(rec["name"]), rec["warehouse"]
            if not key or not wh:
                continue
            prev = wh_by_name.get(key)
            if prev is None:
                wh_by_name[key] = wh
            elif prev != wh:
                wh_conflicts.add(key)
        for key in wh_conflicts:
            wh_by_name.pop(key, None)

        # ---- 平台侧：仓库字典 + 根仓(新建存根挂在它下面) ----
        # V610：正常归属不得指向车间流转位置。to_jsonb 保留对 V587 老目录的兼容。
        cur.execute("""
            SELECT id, name, code,
                   COALESCE((to_jsonb(warehouse)->>'is_line_side')::boolean, false),
                   is_deleted
              FROM warehouses warehouse
        """)
        warehouse_rows = cur.fetchall()
        warehouse_by_name = {}
        used_warehouse_codes = set()
        for wid, wname, wcode, is_line_side, is_deleted in warehouse_rows:
            clean = norm_name(wname or "")
            if clean and not is_line_side and not is_deleted and clean not in warehouse_by_name:
                warehouse_by_name[clean] = wid
            if wcode:
                used_warehouse_codes.add(wcode)
        cur.execute("""
            SELECT id FROM warehouses warehouse
             WHERE is_deleted = false AND parent_id IS NULL
               AND COALESCE((to_jsonb(warehouse)->>'is_line_side')::boolean, false) = false
             ORDER BY code NULLS LAST LIMIT 1
        """)
        root_row = cur.fetchone()
        warehouse_root = root_row[0] if root_row else None

        def ensure_warehouse(name: str):
            key = norm_name(name)
            if not key:
                return None
            if key in warehouse_by_name:
                return warehouse_by_name[key]
            n = 1
            while f"{NEW_WAREHOUSE_PREFIX}{n:02d}" in used_warehouse_codes:
                n += 1
            code = f"{NEW_WAREHOUSE_PREFIX}{n:02d}"
            used_warehouse_codes.add(code)
            wid = f"dry:{code}"
            if args.apply:
                cur.execute(
                    """INSERT INTO warehouses (id, code, name, parent_id, status,
                                               is_accountable, auto_created,
                                               created_at, updated_at, is_deleted)
                       VALUES (gen_random_uuid(), %s, %s, %s, '使用', true, true,
                               %s, %s, false)
                       RETURNING id""",
                    (code, name, warehouse_root, now, now))
                wid = cur.fetchone()[0]
            warehouse_by_name[key] = wid
            wh_created.append(f"{name}({code})")
            return wid

        # ---- 逐个货品按名称匹配 ----
        cur.execute("""
            SELECT id, name, owning_warehouse_id
              FROM goods WHERE is_deleted = false AND name IS NOT NULL
        """)
        goods_rows = cur.fetchall()
        matched_names: set[str] = set()
        for gid, gname, current_warehouse in goods_rows:
            key = norm_name(gname)
            target_name = wh_by_name.get(key)
            if not target_name:
                continue
            matched_names.add(key)
            if current_warehouse is not None and not args.overwrite_warehouse:
                stats["所属仓库-已有值不动"] += 1
                continue
            wid = ensure_warehouse(target_name)
            if wid is None:
                continue
            wh_updates += 1
            stats[f"所属仓库-{target_name}"] += 1
            if args.apply:
                cur.execute(
                    """UPDATE goods
                          SET owning_warehouse_id = %s,
                              version = version + 1,
                              updated_at = %s
                        WHERE id = %s AND is_deleted = false""",
                    (wid, now, gid))

        # Excel 有名称、库里没有同名货品 —— 正常差集，出报告供人工核对，不强灌。
        for key, wh in wh_by_name.items():
            if key not in matched_names:
                wh_unmatched.append((key, wh))

        print(f"所属仓库：Excel 去重名称 {len(wh_by_name)}(丢弃冲突名 {len(wh_conflicts)})；"
              f"库内匹配 {len(matched_names)}；本次写入 {wh_updates}；"
              f"补建仓库 {len(wh_created)}")

    # ----- 提交 / 报告 -----
    if args.apply:
        conn.commit()
        print(f"已提交：更新货品 {updates} 行；所属仓库 {wh_updates} 行")
    else:
        conn.rollback()
        print(f"干跑完成：预计更新货品 {updates} 行、所属仓库 {wh_updates} 行"
              f"（未写库，加 --apply 正式导入）")

    def write_csv(name, header, data):
        with open(report_dir / name, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.writer(f)
            w.writerow(header)
            w.writerows(data)

    write_csv("name_mismatch.csv",
              ["文件", "行号", "产品编号", "Excel产品名称", "库内产品名称", "产品角色", "产品分类"],
              [(m["file"], m["row"], m["code"], m["name"], dn, m["role"], m["category_path"])
               for m, dn in mismatch])
    write_csv("unmatched_excel.csv",
              ["文件", "行号", "产品编号", "产品名称", "产品角色", "产品分类"],
              [(u["file"], u["row"], u["code"], u["name"], u["role"], u["category_path"])
               for u in unmatched])
    write_csv("skipped_no_code.csv",
              ["文件", "行号", "产品名称"],
              [(n["file"], n["row"], n["name"]) for n in no_code])
    write_csv("warehouse_unmatched.csv",
              ["归一后产品名称", "Excel所属仓库"],
              sorted(wh_unmatched))

    summary = [
        f"运行时间: {now.isoformat()}  模式: {'APPLY' if args.apply else 'DRY-RUN'}",
        f"Excel 数据行: {len(rows)}  唯一编号: {len(by_code)}  无编号行: {len(no_code)}",
        f"编号命中: {len(verified) + len(mismatch)}  名称核对通过: {len(verified)}  "
        f"名称不符: {len(mismatch)}  编号未命中: {len(unmatched)}",
        f"更新货品: {updates}",
        f"所属仓库写入: {wh_updates}  补建仓库: {len(wh_created)}  Excel有名库里无此货品: {len(wh_unmatched)}",
        "",
        "明细统计:",
        *[f"  {k}: {v}" for k, v in sorted(stats.items())],
    ]
    text = "\n".join(summary)
    with open(report_dir / "summary.txt", "w", encoding="utf-8") as f:
        f.write(text + "\n")
    print("\n" + text)
    print(f"\n报告已写入：{report_dir}")
    conn.close()


if __name__ == "__main__":
    sys.exit(main())
