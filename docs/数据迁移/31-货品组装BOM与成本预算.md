# 31 · 货品组装信息（BOM）+ 成本预算 —— 老库溯源 · 新库与迁移

> 2026-07-28 落地。货品详情弹窗三页签（基本信息 / **组装信息** / **成本预算**）+ A4 产品配件清单预览（打印 / 加密 Excel），
> 生产管理「BOM 成本展开」模块同期下线（UI 入口 + 前后端代码删除；`production_plan_costs` 历史数据表保留，物料反查报表仍以其为数据源）。

---

## 一、老库溯源

### 1. 组装信息：`B_BomItem`（218,820 行 / 23,322 个父货品）

老系统「公共资料定义窗 → 组装信息」页签（001.jpg）的数据源：

| 列 | 类型 | 含义 |
|---|---|---|
| `ID` | int PK | 行主键 |
| `BillID` | int | **父货品**（成品/半成品）→ `B_Goods.ID` |
| `GoodsID` | int | **组件货品** → `B_Goods.ID` |
| `ColorID` | int? | 组件颜色（0=未设） |
| `QTY` | decimal(18,5) | 用量 |
| `Price` | decimal(18,3) | 单价 |
| `Total` | decimal(18,2) | 金额 |
| `VendID` | int? | 默认供应商（0=未设） |
| `Summary` | varchar(250) | 备注（外购 / 外加工 / 外协…） |
| `BomStatus` / `SStatus` | bit | 标志位 |

实测要点：

- **树是递归出来的**：行本身无父子指针；组件 `GoodsID` 若自己也作为别人的 `BillID` 出现，
  即构成 001.jpg 的 +/- 展开树。新库保持同一语义（组件自身有 BOM 行 = 可展开）。
- `(BillID, GoodsID)` **0 重复**（实测）——「组件编号在同一成品下唯一」可落库约束。
- 孤儿行：`BillID` 指向已删除货品 10,028 行、`GoodsID` 孤儿 12,629 行（合计 20,717，有交集）——**迁移跳过**。
- 老库 `View_B_BomItem` 是带 数量/摘要 中文别名的视图（触发器用），迁移直接读基表。

### 2. 成本预算：`B_Goods` 成本项列（随货品主档已迁）

老系统「成本预算」页签（002.jpg）字段 → `goods` 表列（V32 已建、--goods-data 已灌，无需补迁）：

| 页签字段 | 列 | 页签字段 | 列 |
|---|---|---|---|
| 材料合计 | `source_e` | 成品价 | `total` |
| 加工费 | `machining_e` | 人工比率(%) / 人工费 | `work_rate` / `work_e` |
| 杂费 | `incidental_e` | 损耗比率(%) / 损耗费 | `lost_rate` / `lost_e` |
| 喷漆、朔费 | `lacquer_e` | 厂租比率(%) / 厂房租金 | `rent_rate` / `rent_e` |
| 电镀费 | `plating_e` | 生产利率(%) / 生产利润 | `make_rate` / `make_e` |
| 包装费 | `casing_e` | 成本价 | `c_total` |
| 抛光费 | `polish_e` | 出厂价 | `g_total` |

---

## 二、新库设计（V79）

```sql
goods_bom_items (
  id UUID PK, legacy_id INT UNIQUE,          -- B_BomItem.ID（溯源+幂等）
  goods_id UUID NOT NULL FK→goods,           -- 父货品（BillID）
  component_goods_id UUID NOT NULL FK→goods, -- 组件（GoodsID）
  color_legacy_id INT, qty NUMERIC(18,5) NOT NULL DEFAULT 1,
  price NUMERIC(18,3), total NUMERIC(18,2),
  vend_legacy_id INT, summary TEXT,
  bom_status BOOLEAN, sstatus BOOLEAN, sort_order INT NOT NULL DEFAULT 0,
  + 审计/软删
)
-- 唯一性：同一成品下同一组件只允许一条未删除记录
CREATE UNIQUE INDEX uq_goods_bom_component
  ON goods_bom_items(goods_id, component_goods_id) WHERE is_deleted = false;
```

- **编号唯一**：组件按货品编号关联（UI 搜索选择器锁定具体货品），唯一索引兜底；后端 service 先查给 409 友好报错「该组件已在组装清单中」。
- `sort_order`：迁移时按老库 `ID` 序生成（保持 001.jpg 行序）；手工新增 = max+1。
- `total`：显式传入优先，缺省后端按 `qty*price`（两位小数）兜底。

---

## 三、迁移

```bash
# 1. 导出老库 CSV（LocalDB YTDQ_2023；产出 data/goods_bom.csv，13.7MB / 218,820 行）
powershell -ExecutionPolicy Bypass -File server/legacy_migration/export_legacy.ps1 GoodsBom

# 2. 灌入新库（前提：V79 已由 server Flyway 建表 + --goods-data 已迁）
bash server/legacy_migration/migrate.sh --goods-bom
```

- 已并入 `migrate.sh --all`（紧随 `--goods-data` 之后）。
- **可重跑（非一次性）**：脚本开头 `TRUNCATE goods_bom_items` 全清重灌，老库 BOM 有更新时
  重新执行 §三 两步（重导 CSV → 重跑 `--goods-bom`）即可；迁移代码与本文档随结构调整同步维护。
- 孤儿跳过：父或组件货品在 `goods` 表查不到（`legacy_id` 映射失败）的行不灌入，末尾报跳过数。
- **本机首跑结果（2026-07-28）**：迁入 **198,103 行 / 21,977 个父货品**，跳过孤儿 **20,717 行**，
  与老库 218,820 行完全对账（218,820 − 20,717 = 198,103 ✓）。
- `color_legacy_id` / `vend_legacy_id`：老库 0 = 未设 → NULL。

---

## 四、后端 API（`master/goods` 包）

| 端点 | 权限 | 说明 |
|---|---|---|
| `GET /api/master/goods/{id}/bom` | `goods:view` | 组件清单（含组件编号/名称/型号/规格/单位/颜色/材质 + `hasChildren`） |
| `POST /api/master/goods/{id}/bom` | `goods:edit` | 添加组件（编号唯一校验、自身校验、qty>0） |
| `PUT /api/master/goods/{id}/bom/{itemId}` | `goods:edit` | 编辑行 |
| `DELETE /api/master/goods/{id}/bom/{itemId}` | `goods:edit` | 软删 |
| `POST /api/master/goods/{id}/bom/export` | `goods:export` | 产品配件清单加密 Excel（**整树展开平铺**：级联序号逐级缩进（1 / └ 3.1 / 　└ 3.1.1），编号前缀 `*`/`**` 标层级，名称列对齐不缩进；序号/物料编号/物料名称/规格/颜色/数量/材质/备注） |

组装树子级：前端对组件 id 再调 `GET .../bom` 懒加载（组件自身也是货品）。

成本预算：`GoodsDetail` / `GoodsSaveRequest` 扩 18 个成本字段（`cTotal`/`gTotal` 加 `@JsonProperty`
防 Jackson 连续大写 quirk，同 `mWeight`）。**注意**：后端 `apply` 全量覆盖——前端任何货品保存
都必须全量回传成本字段（基本信息编辑对话框以 `fixedValues` 原值回传；成本页签全量回传基础字段），
否则缺省字段会被清 null。

---

## 五、前端（Flutter）

| 文件 | 职责 |
|---|---|
| `widgets/goods_detail_dialog.dart` | 货品详情弹窗：三页签壳（基本/组装/成本）+ 头部「预览」按钮；compact 抽屉 / medium+ 920 宽面板 |
| `widgets/goods_bom_tab.dart` | 组装信息：复用统一表格组件 `MasterDataTableView`（与货品列表同款 Excel 表头分隔线 + 拖拽列宽 + 底部横滑条）；BOM 树按可见节点平铺——首列 `▶/▼` 标识「含子类」（点行展开/收起）、名称列子类缩进一格（`└` 分支符逐级加深）；工具条 添加/编辑/删除（编辑/删除作用于选中行，添加走搜索选择器，编号唯一） |
| `widgets/goods_cost_tab.dart` | 成本预算：18 字段可编辑表单（双列网格，goods:edit 可改） |
| `widgets/goods_bom_preview.dart` | A4 产品配件清单（003.jpg 版式）：**整树展开**（级联序号逐级缩进（1 / └ 3.1 / 　└ 3.1.1），编号前缀 `*`/`**` 标层级，名称列对齐不缩进，环路防护 + 10 层上限）；打印（`pdf`+`printing`，NotoSansSC 内置字体）+ 下载 Excel（`UtenExportButton`，与打印件同版式） |
| `models/goods_bom_item.dart` / `repositories/goods_bom_repository.dart` | BOM 行模型 / CRUD 仓库 |
| `repositories/goods_repository.dart` | 新增 `search(keyword)`（不限分类，组件选择器用；后端 `categoryId` 可空） |

- 货品行点击从通用 `showMasterDetailSheet` 改为 `showGoodsDetailDialog`（模具/客户/供应商不受影响）。
- `pubspec.yaml` 新增 `pdf` / `printing` 依赖。

---

## 六、生产管理「BOM 成本展开」下线清单

- 前端：hub 卡片、`/production/plan-cost` 路由与 `RouteName.productionPlanCost`、
  `Perm.productionPlanCostView`（含 `permission_by_path`）、`production_plan_cost_page.dart`、
  `models/production_plan_cost.dart`、`ProductionPlanCostRepository(+Filter+Provider)` 全删；
  物料反查页行点击不再下钻（改为空操作）。
- 后端：`features/production/plancost` 整包删除（Controller/Service/Repository/Entity/DTO）。
- **保留**：`production_plan_costs` 表与 136 万行历史数据（V78 物料反查产成品报表的数据源），
  以及 DB 里已 seed 的 `production_plan_cost:view` 权限行（历史 Flyway 不动）。

---

## ✅ 校验

- 后端 `mvn compile` 通过；前端 `flutter analyze` 0 error。
- Flyway V79 已在本机 PG 应用；`migrate.sh --goods-bom` 首跑对账一致（见 §三）。
- API 冒烟：`GET /api/master/goods/{id}/bom` 未带 token 返回 401（端点已注册，非 404）。
