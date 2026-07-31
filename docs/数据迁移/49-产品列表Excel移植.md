# 49 - 产品列表 Excel 移植（新 ERP → 平台）

> 时间：2026-07-30 · 依据：用户上传三个新 ERP 产品列表导出（`product lists/20260409172229_{1,2,3}.xls`），
> 要求：匹配上的产品补上「自制/采购」属性、搬有用数据与分类，并留下平台上架时可直跑的移植代码。
> 移植脚本：`server/legacy_migration/import_product_lists.py`（幂等，可重复执行）
> 数据目录：`product lists/`（三个 .xls 固定放这里，脚本默认直读）

> **【2026-07-31 决策修订】分类结构只走老树，Excel 只读取内容。**
> 2026-07-30 首次导入曾按 Excel「产品分类」路径新建 493 个 XL 分类、把 21883 个货品重指过去，
> 造成新老两棵树并存、老树大量分类被搬空。当日已全部回滚：货品 category_id 依 7/28 备份恢复到老树
> 原位置，493 个 XL 分类已删除；来源/系列/材质等补入字段全部保留。
> 此后脚本默认 **只补字段、绝不动分类**；按 Excel 路径建分类树并重指的行为改为
> `--recategorize` 显式开关（默认关闭，勿随意开启）。权限体系按归属人+权限点控制、
> 不绑定分类，本次回滚不涉及权限变更。

---

## 一、源文件画像

三个文件均为老式 OLE2 .xls，单工作表「产品列表」，80 列，合计 **23104 数据行**：

| 文件 | 行数 |
|---|---:|
| 20260409172229_1.xls | 10000 |
| 20260409172229_2.xls | 10000 |
| 20260409172229_3.xls | 3104 |

关键列（80 列里对本平台有价值的）：

| Excel 列 | 内容 | 本平台落点 |
|---|---|---|
| 产品编号 | 如 `UT0004` / `280202021` | **匹配键** = `goods.code` |
| 产品名称 | 名称核对用 | 仅核对，不回写 |
| 产品角色 | 自制件 13768 / 外购件 4569 / 委外件 4151 | **`goods.source_type`（V128）**：自制/采购/委外 |
| 产品分类 | `86开关插座->原材料->塑胶类->塑胶件` 路径，398 条叶路径、最深 6 级 | ~~建新分类树 + 重指 `goods.category_id`~~ **【2026-07-31 起停用】** 仅 `--recategorize` 显式开启才生效 |
| 系列 / 材质 / 型号 / 规格 | 基础属性 | 空值补齐（不覆盖已有值） |
| 颜色 | 白色 3752 / 灰色 2325 / 深灰色 1458 … | 按名对 `colors` 字典，缺名建色；仅补空 |
| 基本单位 | 个 20481 / 张 1170 / 千克 314 / 套 296 … | 按名对 `units` 字典（千克→kg 别名）；仅补空 |
| 原ERP备注 | 7284 行有值 | `goods.require_remark`；仅补空 |
| 客户型号 | 591 行有值 | `goods.c_number`；仅补空 |
| 单重（克） | 仅 27 行有值 | `goods.m_weight`；仅补空 |
| 启用状态 | 启用 22488 | **不导入**（见「三、有意跳过」） |
| 主采购供应商 | 约 3200 行有值 | **不导入**（见「三、有意跳过」） |
| 建议进价/售价等价格列 | 几乎全 0 | **不导入** |
| 无编号行 | 616 行「【价格策略】」 | 跳过（无匹配键） |

## 二、匹配与核对规则（“确定是这个产品”）

1. **匹配键**：Excel 产品编号（去空白）= `goods.code`（未软删）。
2. **名称核对**：编号命中后再比对名称（去全部空白字符）：
   - 完全一致，或一方包含另一方（多为 RoHS 后缀、括号全半角差异）→ 视为同一产品，执行导入；
   - 名称明显不同 → **不导入**，写入复核清单人工确认。
3. **结果**（2026-07-30 实跑）：

```
Excel 数据行 23104 · 唯一编号 22488 · 无编号行（价格策略）616
编号命中 21927 · 名称核对通过 21883（导入）· 名称不符 44（转人工）· 编号未命中 561
```

- 名称不符 44 条：如 `45A1030` Excel「45A动触片(覆银)」vs 库内「45A动触片(不覆银)」——
  同号不同款，必须人工裁决，见 `product lists/import_report/name_mismatch.csv`。
- 编号未命中 561 条：新 ERP 有、平台没有的货品，见 `unmatched_excel.csv`（未建新品，见「三」）。

## 三、有意跳过（决策记录）

| 数据 | 决策 | 理由 |
|---|---|---|
| 使用状态 status | 不用 Excel「启用状态」覆盖 | 平台现行状态（使用/禁用）是运营中的真实状态，Excel 是另一套系统的快照 |
| 供应商 | 不挂接 | Excel 供应商名与平台供应商主档仅 23 个重名，误挂风险高；待供应商主档对齐后再做 |
| 价格（建议进价/最高进价/建议售价/最低售价） | 不导入 | 几乎全 0，无参考价值 |
| 未命中货品（561） | 不自动新建 | 新品建档需编号生成、分类、单位等完整策略；先出清单人工确认是否需要 |
| 简称 | 跳过 | Excel 该列全空 |

## 四、落库内容（2026-07-30 APPLY 实跑结果）

```
更新货品 21883 行
来源：自制 13426 · 采购 4475 · 委外 3982
分类：新建节点 493（XL 编码，挂在根「货品资料」下），21883 行 category_id 重指到叶分类
补齐：require_remark 7229 · unit_legacy_id 229 · model 22 · material 7
      c_number 6 · spec 3 · series 1 · m_weight 0 · color 0
二次运行：0 更新（完全幂等）
```

**【2026-07-31 回滚记录】** 分类重指部分已全部回滚，其余保留：

| 项 | 处置 |
|---|---|
| 21883 个货品的 `category_id` | 依 `server/backups/uten_imp_20260728_190954.sql` 恢复到老树原位置 |
| 493 个 XL 新建分类 | 已全部删除（确认无货品引用后按层级从深到浅 DELETE） |
| 来源 source_type / 空值补齐字段 / 新建颜色 | **保留**（本次决策要的就是"只拿内容"） |
| 权限 | 无需变动（权限按归属人+权限点控制，不绑定分类） |

回滚后干跑验证：21883 行全部「无需更新」、0 行变更，脚本默认模式不再触碰分类。

- **来源值域**：`自制` / `采购` / `委外`（不加 CHECK 约束，留扩展余地如「客供」）。
- **分类结构**：以老库迁移树为唯一权威；Excel 路径不再建树（见文首 2026-07-31 决策修订）。
- **空值补齐原则**：只补库内为空的字段，绝不覆盖已有值（老库迁移数据优先）。

## 五、移植脚本用法（上架重导照此执行）

```bash
# 0. 依赖（一次性）
pip install xlrd psycopg2-binary

# 1. 三个 .xls 放在项目根 product lists/ 目录（默认文件名 20260409172229_{1,2,3}.xls，
#    换了文件名用 --files 指定）

# 2. 干跑：只出报告不写库（务必先看 summary.txt 与三份 CSV）
python server/legacy_migration/import_product_lists.py

# 3. 正式导入（只补字段，不动分类树）
python server/legacy_migration/import_product_lists.py --apply

# 3b. 【勿随意使用】按 Excel 分类路径建新树并重指货品分类（2026-07-31 起默认关闭）
python server/legacy_migration/import_product_lists.py --apply --recategorize

# 4. 非默认库 / 换目录
UTEN_DB_HOST=x.x.x.x UTEN_DB_PORT=5432 UTEN_DB_NAME=uten_imp \
UTEN_DB_USER=uten UTEN_DB_PASSWORD=*** \
python server/legacy_migration/import_product_lists.py --data-dir "product lists" --apply
```

**前置条件**：`goods.source_type` 列已存在（Flyway `V128__goods_source_type.sql`，
后端启动自动执行；手工执行亦可，脚本幂等）。

**报告产物**（每次运行刷新）：`product lists/import_report/`

| 文件 | 内容 |
|---|---|
| `summary.txt` | 总行数、命中、核对通过/不符、更新量、分类新建数 |
| `name_mismatch.csv` | 名称不符 44 条（需人工裁决是否同品） |
| `unmatched_excel.csv` | 编号未命中 561 条（新 ERP 有、平台无） |
| `skipped_no_code.csv` | 无编号行 616 条（价格策略等） |

## 六、配套功能改动（同批落地）

| 层 | 改动 | 文件 |
|---|---|---|
| DB | `goods.source_type VARCHAR(20)` + 索引 | `db/migration/V128__goods_source_type.sql` |
| 后端 | 实体/DTO/查询/facets/导出全链路加 sourceType | `features/master/goods/**` |
| 前端 | 编辑表单「来源」下拉（自制/采购/委外，`kGoodsSourceTypeOptions`） | `master_edit_dialog.dart` `product_category_page.dart` |
| 前端 | 货品列表新增「来源」列（带 autofilter facet） | `product_category_page.dart` |
| 前端 | 货品详情「基本信息」加「来源」行 | `product_category_page.dart` |
| 前端 | 详情列表按状态着色：使用=浅蓝、禁用=浅红、其他=白；单击选中加深加亮 | `master_data_table_view.dart`（新增 `rowColor` 参数） |
| 前端 | 大屏左树「未分类（历史孤儿）」默认收起 | `uten_category_tree_view.dart`（新增 `initiallyCollapsedNames`） |

> 版本号注意：开发库 flyway_schema_history 已由更新的代码树推进到 V127，
> 本迁移取下一空号 **V128**；若合入的代码树 V100–V127 齐备，保持 V128 不变即可。

## 七、复跑与验收清单

- [ ] 干跑 summary 与本文「二」数字同量级（数据文件更新后会变，看趋势不看绝对值）
- [ ] `name_mismatch.csv` 人工裁决后：如确认同品，改库内名称或线下补 UPDATE
- [ ] `unmatched_excel.csv` 决定是否需要新品建档流程
- [ ] 前端货品资料页：行色（蓝/红）、选中加深、来源列可筛选、编辑下来源可选
- [ ] 左树「未分类（历史孤儿）」默认收起
- [ ] 二次执行脚本 = 0 更新
