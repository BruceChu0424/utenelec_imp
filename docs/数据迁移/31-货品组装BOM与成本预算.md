# 31 · 货品组装信息（BOM）+ 成本预算 —— 老库溯源 · 新库与迁移

> 2026-07-28 初版落地。当前货品详情由 `GoodsDetailPage` + `GoodsDetailBody` 整页承载三页签
>（基本信息 / **组装信息** / **成本预算**）和 A4 产品配件清单预览（打印 / 加密 Excel），
> 生产管理「BOM 成本展开」模块同期下线（UI 入口 + 前后端代码删除；`production_plan_costs` 历史数据表保留，物料反查报表仍以其为数据源）。
>
> **2026-08-01 增强（§七）**：「新增货品」并入三 Tab 弹窗（mode 感知 create/edit/view）+ 组件右滑窗选择（component scope）
> + 组件层级添加（选中默认子组件 + DAG 环检测）+ 组件信息只读 + 成本自动汇总（后端聚合 sourceE + 前端级联）
> + 颜色/单位内联新建（后端补合成 legacy_id 解鸿沟 + 名称查重）。
>
> **2026-08-13 当前形态**：新增、查看和编辑统一改走 `/basicinfo/goods/new`、
> `/basicinfo/goods/:id?tab=` 整页路由；旧 `goods_detail_dialog.dart` 已删除。
>
> **2026-08-01 数据纠偏（V181）**：历史单据需要保留的 `goods.auto_created` 占位只作外键锚，
> 不属于当前货品/BOM/MRP；软删误接入的 81 条 BOM 迁移行，并在迁移、数据库和 Service 三层拒绝复发。

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
- 孤儿行：`BillID` 指向已删除货品 10,028 行、`GoodsID` 孤儿 12,629 行、两端同时缺失 1,859 行；
  去重后是 **20,798 行**（10,028 + 12,629 − 1,859），应全部拒绝，真实可迁 **198,022 行**。
- 老库 `View_B_BomItem` 是带 数量/摘要 中文别名的视图（触发器用），迁移直接读基表。

#### 20344 / Q7 7.1 的根因与安全边界

- `B_Goods`/`goods.csv` 没有 `ID=20344`，但历史业务/快照仍引用它：生产成本快照 18,109 行、
  委外成本 4 行；错误 BOM 又在新系统派生出仓库草稿明细 2 行和采购申请草稿 1 行。委外迁移为满足 NOT NULL FK 创建
  `(migration auto-stub legacy 20344)`；该名字由迁移代码拼出，不是老库货品。
- Q7「86型13A方插」(`legacy_id=39651`) 的第 7 项是 `14729 安装螺钉包组件`；该组件唯一子 BOM
  `141455: 14729 → 20344`，所以旧实现递归显示为 7.1。
- 旧 `migrate_goods_bom.sql` 只按目标库 `goods.legacy_id` JOIN。stub 已先存在时，81 条本应拒绝的
  孤儿被误当真货品接入（stub 作组件 60、作父件 21），形成旧错误口径 198,103 = 198,022 + 81。
- **已验证清理（V181 已应用）**：V181 软删上述 81 条迁移 BOM 行；Q7 保留真实第 7 项，移除虚假 7.1。对错误
  BOM 已派生的草稿，V181 只有在“新系统生成、草稿、未领用/未下单、来源链接唯一、所有库存/采购/
  计划包/供给/财务/Outbox 下游均为 0”时才清理：`SL26070266`、`SL26070268` 各软删
  20344 明细 1 条（其余各 25 条保留），`CS26070032` 的唯一明细、MRP 链接和空申请头一并软删。
  任一安全条件不成立就回滚整个 V181，不会静默跳过或级联删除。
  **不能硬删 31 个 `goods` 历史锚**：它们都仍有历史外键引用；生产成本快照中 `goods_id` 引用 29,540 条、`master_goods_id` 引用 177 条，
  另有委外/单据引用，其中 7 条 `stock_balances` 仍承载历史余额。强删会损坏单据、余额与成本快照，
  所以它们继续隐藏保留；20344 自身的 18,109 条生产成本和 4 条委外成本也原样保留。

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
bash server/legacy_migration/migrate.sh --goods-bom --confirm-destructive
```

- 已并入 `migrate.sh --bootstrap-all --confirm-destructive`（紧随 `--goods-data` 之后）。
- **仅限首次导入/演练重跑**：脚本开头 `TRUNCATE goods_bom_items` 全清重灌；模块切流后不得用它做增量同步。
- 有效货品必须同时满足 `legacy_id` 命中、`is_deleted=false`、`auto_created=false`；父或组件不满足即拒绝。
- **纠正后的源快照口径（2026-08-01，已实测）**：有效迁移 **198,022 行**，拒绝 **20,798 行**，
  与老库 218,820 行守恒（218,820 = 198,022 + 20,798）。V181 清理 81 条误接迁移行；本机另有
  3 条 `legacy_id IS NULL` 的新系统手工 BOM，不在迁移清理范围；V181 后活动总数实测为 **198,025**，活动 stub 端点为 **0**。
- 脚本末尾同时输出拒绝数，并硬断言“活动 BOM 的父件/组件命中 `auto_created` = 0”；执行顺序不再影响结果。
- V181 还断言活动生产领料单和采购申请不得继续使用 `auto_created`；历史迁移单据（包括 11 条盘点
  明细）、7 条库存余额以及生产/委外成本快照不在运营草稿清理范围，原样保留。
- `color_legacy_id` / `vend_legacy_id`：老库 0 = 未设 → NULL。

---

## 四、后端 API（`master/goods` 包）

| 端点 | 权限 | 说明 |
|---|---|---|
| `GET /api/master/goods/{id}/bom` | `goods:view` | 组件清单（含组件编号/名称/型号/规格/单位/颜色/材质 + `hasChildren`） |
| `POST /api/master/goods/{id}/bom` | `goods:edit` | 添加组件（编号唯一、自身、qty>0、父件/组件均非迁移占位） |
| `PUT /api/master/goods/{id}/bom/{itemId}` | `goods:edit` | 编辑行 |
| `DELETE /api/master/goods/{id}/bom/{itemId}` | `goods:edit` | 软删 |
| `POST /api/master/goods/{id}/bom/export` | `goods:export` | 产品配件清单加密 Excel（**整树展开平铺**：级联序号逐级缩进（1 / └ 3.1 / 　└ 3.1.1），编号前缀 `*`/`**` 标层级，名称列对齐不缩进；序号/物料编号/物料名称/规格/颜色/数量/材质/备注） |

组装树子级：前端对组件 id 再调 `GET .../bom` 懒加载（组件自身也是货品）。

成本预算：`GoodsDetail` / `GoodsSaveRequest` 扩 18 个成本字段（`cTotal`/`gTotal` 加 `@JsonProperty`
防 Jackson 连续大写 quirk，同 `mWeight`）。**注意**：后端 `apply` 全量覆盖——前端任何货品保存
都必须全量回传成本字段（基本信息编辑以 `fixedValues` 原值回传；成本页签全量回传基础字段），
否则缺省字段会被清 null。

**2026-08-01 增强（`GoodsBomService`）**：
- **材料合计自动聚合**：BOM create/update/delete 后 `recalcSourceE(parent)` 重算父货品 `source_e` 并写回——
  直接组件中 `source_type∈{采购,委外}` 取 `price×qty`，**自制 / 有 BOM（半成品）取其 `c_total×qty`**
  （自制件 price 常 0，取其成本价才不失真；求和 `setScale(2)`）。前端成本页签 `sourceE` 只读显示此值，
  不再手填。这是"组件价格→父货品材料合计"的唯一真源（前端 `Σ(qty×price)` 对自制件是错的，故由后端做）。
- **DAG 环检测**：`ensureNoCycle(parentGoodsId, componentId)`——加边前 BFS 下溯组件子树（深度上限 10），
  若已含 parentGoodsId 则 409「会形成组装环路」（"加为某组件的子组件"让环路更易人为构造，写入侧必须防护；
  预览/导出侧早有路径去重 + 10 层上限）。
- **`BomItemView` 加 `componentSourceType`**：`list` / `toView` 拼组件 `g.source_type`，前端组装表显「来源」列、
  添加组件弹窗组件信息只读展示。

---

## 五、前端（Flutter）

| 文件 | 职责 |
|---|---|
| `pages/goods_detail_page.dart` / `widgets/goods_detail_body.dart` | 货品详情/编辑整页：**mode 感知（create / edit / view）**三页签主体（基本/组装/成本）+ 头部「预览」按钮（仅已保存货品）；新增保存后在同页切换到 edit 态（见 §七） |
| `widgets/goods_bom_tab.dart` | 组装信息：复用 `MasterDataTableView`（Excel 表头分隔线 + 拖拽列宽 + 底部横滑条 + 点行高亮 + `onSelectionChanged`）；BOM 树按可见节点平铺——首列 `▶/▼` 标识「含子类」（点行展开/收起）、名称列子类缩进（`└` 逐级加深）；**层级添加**（选中组件行→添加默认其子组件，弹窗内父级可选顶层/任一可见组件，仿部门 `initialParent`）+ 加子组件后 `_expandedIds` 保活 + `_restoreExpansion` 让新子件可见；工具条 添加/编辑/删除；`AutomaticKeepAliveClientMixin` 切页签不丢状态 |
| `widgets/goods_cost_tab.dart` | 成本预算：18 字段表单。**sourceE 只读（后端聚合）**；6 项加工费 + 4 项比率手填；成品价/各项费/成本价/出厂价 `_recompute` 自动级联（见 §七）；`didUpdateWidget(materialTotal)` + `AutomaticKeepAliveClientMixin` |
| `widgets/goods_bom_preview.dart` | A4 产品配件清单（003.jpg 版式）：**整树展开**（级联序号逐级缩进（1 / └ 3.1 / 　└ 3.1.1），编号前缀 `*`/`**` 标层级，名称列对齐不缩进，环路防护 + 10 层上限）；打印（`pdf`+`printing`，NotoSansSC 内置字体）+ 下载 Excel（`UtenExportButton`，与打印件同版式） |
| `widgets/master_edit_dialog.dart` | **抽出公共 `MasterEditForm`**（字段网格 + 校验 + `buildBody()`，无 header/actions）；`showMasterEditDialog` 改薄包装（10 主档零回归）；货品基本页签内嵌它。`MasterFieldDef` 加 `onAddNew`（颜色/单位内联新建，返新值自动选中） |
| `widgets/uten_goods_picker.dart` | 统一货品选择器加 scope `component`（白名单 6 分类，BOM 组件选择用，见 [UtenGoodsPicker](../02-组件库/UtenGoodsPicker.md)） |
| `providers/color_unit_dict.dart` | 颜色/单位字典 provider（`colorDictProvider`/`unitDictProvider`）+ 内联新建 helper（`showColorAddSheet`/`showUnitAddSheet`：预查重→POST→invalidate→返新 legacy_id 自动选中） |
| `models/goods_bom_item.dart` / `repositories/goods_bom_repository.dart` | BOM 行模型（加 `componentSourceType`）/ CRUD 仓库 |
| `repositories/goods_repository.dart` | `search(keyword)`（不限分类）+ `create` 改返 `GoodsDetail`（create→edit 同页切换拿 id） |
| `repositories/color_repository.dart` / `unit_repository.dart` | `create` 改返 `ColorDetail`/`UnitDetail`（内联新建后取 legacy_id 自动选中） |
| `components/inputs/uten_dropdown_field.dart` | 加可选 `onAddNew`/`addNewLabel`：浮层搜索框下方渲染浅绿「添加」按钮（null=不显示，默认行为不变） |
| `widgets/master_data_table_view.dart` | 加可选 `onSelectionChanged(T?)`：单击选中行除 `onRowTap` 外上抛选中项（BOM 据此定「添加组件」默认父级） |

- 货品行点击 / 新增 / 编辑统一走 `GoodsDetailPage` 整页路由（mode 感知）；模具/客户/供应商不受影响。
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

## 七、货品详情演进：三 Tab + 组件层级 + 成本自动 + 颜色单位内联新建

> 2026-08-01 将新增、编辑和查看合并为 mode 感知三页签；2026-08-13 再将容器改为
> `GoodsDetailPage` 整页路由。当前实现保留同一 `GoodsDetailBody`，不再维护弹窗分支。

### 1. mode 感知详情整页（`goods_detail_page.dart` + `goods_detail_body.dart`）
- `/basicinfo/goods/new?categoryId=` 进入 create，`/basicinfo/goods/:id?tab=` 进入 view/edit；权限由详情页实时判定。
- **两阶段**：BOM API 要货品 id 已存在，故 create 态基本信息页签可编辑、组装/成本页签空态「请先保存基本信息」；
  保存（`POST /master/goods` 返 `GoodsDetail`，前端仓库 `create` 改返实体）→ `_enterEdit` **同页转 edit 态**，
  组装/成本页签用 `ValueKey('bom/cost-$_goodsId')` 重建激活。
- 全量覆盖契约下：任何变更后 `_refreshDetail`（GET 详情），各页签保存带**最新完整快照**（基本信息 PUT 带 18 成本字段防清空）。
- `product_category_page.dart` 三入口（新增/编辑/查看）统一导航到详情路由；颜色/单位改走 provider。

### 2. 颜色/单位内联新建 + UUID 关系
- **现行边界（2026-08-14）**：`color_id/unit_id` UUID 是在线关系真源；`color_legacy_id/unit_legacy_id`
  只保存旧库迁移影子，在线新颜色/单位的 `legacy_id` 保持 `NULL`，不得用 `max+1` 合成旧身份。
- **解法**：`ColorService`/`UnitService.create` 返回含 UUID `id` 的 `ColorDetail`/`UnitDetail`，名称查重继续由
  `existsByNameIgnoreCaseAndDeletedFalse` 提供（命中 409）；货品保存直接提交 UUID。
- 前端：`UtenDropdownField` 加 `onAddNew`（浮层搜索下浅绿「添加」按钮）；`MasterFieldDef.onAddNew` 返新值自动选中；
  颜色/单位字典抽 `colorDictProvider`/`unitDictProvider`，新建后 `invalidate` 全局刷新（`providers/color_unit_dict.dart`）。

### 3. 组件选择改右滑窗（`component` scope）
- `showUtenGoodsPicker` 加 scope `component`（白名单 6 分类：原材料 2113 / 半成品 2149 / 辅料 2480 / OEM成品 2304 /
  OEM物料 2305 / OEM功能件 2460，仿 `material` 的 `_keepMaterialTree`）。BOM `_BomItemEditDialog` 内联 search 换成
  `showUtenGoodsPicker(scope: component)`。legacyId 源 [02](02-货品分类-老库溯源.md) §3.1。
  > ⚠️ OEM 在老库是 3 个独立根（code 都叫 OEM）；6 类集合在常量 `_componentRootLegacyIds` 可调。

### 4. 组件层级添加 + 多选批量 + 信息只读
- `MasterDataTableView` 加 `onSelectionChanged(T?)` 上抛选中行。选中组件行→「添加组件」默认作其子组件
  （`parentGoodsId = selected.componentGoodsId`），弹窗内父级可选顶层/任一可见组件（仿部门 `initialParent`）。
  `POST /master/goods/{parentGoodsId}/bom`。加子组件后失效化选中节点 children + 重展开（`_expandedIds`）。
- **一个层级一次添加多个组件**：`_BomItemAddDialog` 用 `showUtenGoodsPickerMulti`（多选右滑窗，点行勾选/取消 +
  底部「确定(N)」）批量勾选，每个用量默认 1 可改、单价取自组件，一次 POST 多条到同一父级（重复/环路 409 逐条跳过并提示）。
  单条编辑走 `_BomItemEditDialog`（组件/父级锁定，仅用量/备注可改）。
- 选完组件从 `GoodsListItem`/`GoodsBomItem` 自动回填 编号/名称/型号/规格/单位/颜色/材质/单价/来源 → **只读**；用量 qty + 备注 可改。
- **下拉浮层自动避让**：`UtenDropdownField`（颜色/单位等所有表单下拉共用）打开时测量上下空间，下方不够则向上展开
  并按可用空间收限高，避免靠近底部被裁（表头筛选/表头设置从顶部向下展开到表体，无此问题）。

### 5. 成本自动汇总
- **材料合计 `sourceE` = 后端聚合**（§四 `recalcSourceE`），前端只读显示；BOM 变动后详情主体 `_refreshDetail` 取新值。
- 下游前端 `_recompute` 级联（`goods_cost_tab.dart`）：成品价 = sourceE + 6 项加工费；人工/损耗/厂租费 = 成品价 × 对应比率%；
  成本价 = 成品价 + 三费；生产利润 = 成本价 × 生产利率%；出厂价 = 成本价 + 生产利润。比率 + 加工费手填，其余只读自动。
  内部 double 不舍入（仅显示 `toStringAsFixed(2)`），空比率按 0。
  > 公式按字段语义推导（人工/损耗/厂租以成品价为基、利润以成本价为基）。若有老系统 002.jpg 实际公式可对齐。

---

## ✅ 校验

- 后端 `mvn compile` 通过；前端 `flutter analyze` 0 error（仅剩 1 个无关 info：`material_review_dialog.dart` use_decorated_box，分支既有）。
- Flyway V79 已在本机 PG 应用；`migrate.sh --goods-bom` 首跑对账一致（见 §三）。
- API 冒烟：`GET /api/master/goods/{id}/bom` 未带 token 返回 401（端点已注册，非 404）。
- **运行验收待做**（须重启后端应用颜色/单位/BOM Java 改动 + 重建前端）：自签 token 测 color 同名 409 / goods POST 返 detail /
  bom 加组件后 goods.sourceE 聚合更新 / 造环 409；profile web 测全流程。

## 八、2026-08-07 折扣字段 + 成本可见性 + 即时库存展示（V226）

### 1. 折扣 = 复用老库 `goods.zk`（零迁移）

老库 `B_Goods.zk`（拼音「折扣」首字母）随货品主档 V32 一并迁入 `goods.zk`（`NUMERIC(18,4)`），但此前**从未被任何 DTO/service/UI 启用**。全 36,226 行均有值：32,003 行 `1.00`（原价）、3,681 行 `0.17~0.37`（真实折扣）、64 行 `0`、2 行 `>1`。

本次将其暴露为折扣字段：

- `Goods.java` 字段 `zk` → `discount`，`@Column(name = "zk", precision = 18, scale = 4)` 保留 DB 列名 → **不加列、不改 checksum、不改迁移**。
- **倍率语义**：`1.00` = 原价、`0.90` = 9 折（优惠 10%），有效售价 = 单价 × 折扣。
- 接入 `GoodsSaveRequest`/`GoodsDetail`/`GoodsListItem` + `GoodsService.apply/toDetail/toList`；前端基本信息 Tab「价格」旁加「折扣」列、详情行、成本 Tab 保存体回传、货品资料列表「折扣」列。
- 销售订货单选品时自动带入货品折扣并锁定（见 [20-销售管理](20-销售管理-新库与迁移.md)）。

### 2. 售价/折扣编辑授权 + 成本可见性（两新权限点）

详见 [54-部门默认权限矩阵 §V226](54-部门默认权限矩阵.md)。要点：

- **`goods:price:edit`（写侧字段级）**：未持权者改 `price`/`discount` → 后端 403；前端对无权者锁定售价/折扣只读（`MasterEditForm.readOnlyKeys`，仅禁 UI、仍以原值回传，后端判「未改」放行）。
- **`goods:cost:view`（读侧脱敏）**：未持权时 `GoodsDetail` 的 18 个成本字段置 null + `costMasked=true`，前端**隐藏「成本预算」Tab**（非打码）。列表/导出本就不含成本。
- 两者默认授 `DEPT_FIN`，并在 V226 给财务部补 `goods:edit`（改价须走 `PUT /master/goods/{id}`）。

### 3. 即时库存展示（关联仓库，不加列）

库存数据**早已迁移**：老库 `StockGoods.FactQTY`（取最新年）→ `stock_balances`（按 `仓库×货品×颜色`，仅 `warehouses.is_accountable` 参与核算），口径见 [32-即时库存](32-即时库存.md)。`goods` 表无实时库存列（只有静态 `init_stock`）。

本次在货品页**展示**即时库存（不加冗余列、不产生第二数据源）：

- 详情：合计数量 + 按仓库（×颜色）展开的明细行。
- 列表：「库存量」列（合计）。
- 实现位置在 `GoodsService`（原生 SQL 直查 `stock_balances` 表）——**架构边界测试禁止 `master→stock` 的 Java 依赖**，故不注入 `StockQueryService`，改用 `EntityManager` 表访问（与即时库存页同口径）。

## 九、2026-08-28 V421 成本非负完整性与历史异常治理

- **在线输入边界**：18 个可写/派生成本金额必须位于
  `0..99999999999999.9999` 且最多 4 位小数；人工、损耗、厂租、生产四个费率必须位于
  `0%..100%`。Flutter 使用 `Form/TextFormField` 在字段旁提示，Bean Validation 与
  `GoodsCostValuePolicy` 覆盖创建、编辑和导入，数据库 CHECK 是最终守卫。
- **历史异常不静默抹除**：V421 只选择负值或越界行，先向长期保留的 `audit_log` 写入
  20 个原字段、异常原因、修复策略与恢复来源，再夹紧输入项并按 §七同一公式重算派生金额。
  原值可从 `audit_log.before.values` 前向恢复；禁止直接改旧迁移或用 Flyway repair 掩盖。
- **即时库存解耦**：`goods.c_total` 继续作为 BOM/标准成本预算，不再乘库存数量冒充库存价值。
  即时库存与导出从 V421 起显示 `SUM(stock_balances.amount_local)`，详见
  [32-即时库存](32-即时库存.md)。
- **可丢弃测试库零基线**：`server/ops/reset_business_data.sql` 从 2026-08-29 起把 `goods.min_qty`
  和上述 20 项成本金额/费率（含 NULL）与 legacy 期初库存同事务归为字面 `0`，同时保留货品 UUID/编号/名称、
  分类/单位关系、BOM、`max_qty` 与业务售价 `price/a_price/price2`；提交前有独立全零断言，UPDATE 共享
  审计 request ID，并仅对真实变化行推进 `version/updated_at`。2026-08-29 经业务方本轮明确授权，当前
  本机开发库已在完整备份/恢复验证后执行；137 个货品和 202 条 BOM 保留，131 个变化货品完成归零与
  版本/审计推进。后续 V423 启动链三次重新运行并产生业务数据，均在新备份/恢复验证后按明确授权执行
  第二、第三、第四次重置；货品/成本主档原已全零，因此三次主档 UPDATE 与新增审计均为 0，137 个货品
  和 202 条 BOM 指纹继续不变。后端又应用 V424/V425 并产生业务数据后，第五次清理继续保持货品/BOM
  指纹不变，同时对 191 张业务表执行 `RESTART IDENTITY`；审计日志及其 ID 未获单独删除授权而完整保留。
  后续 V426–V429 新增日报参与人表后，第六次将其纳入第 192 张 CLEAR 表；137 个货品和 202 条 BOM
  指纹继续不变。第六次完成后项目 Java、Maven 和 8080 保持关闭。
  该本机证据不授权公司目标库或生产清理。
- **验收边界**：迁移契约、服务策略、隔离 PostgreSQL 和 V420 备份恢复克隆均已通过；
  当前开发库已应用 V421并保留修复审计。目标非空库与历史成本业务复核仍须分别留证。
