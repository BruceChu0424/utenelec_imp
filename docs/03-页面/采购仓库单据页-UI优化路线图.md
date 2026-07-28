# 采购 / 仓库单据页 · UI 优化路线图

> 建立时间：2026-07-26 · 来源：`/ui-ux-pro-max` 设计系统评审 + 实测
> 适用：采购 4 单据、仓库 8 单据（及未来销售/委外/生产等同款"主从表单据列表"页）
> 状态：第 1、2、3 项已完成（3 = 编辑页 Excel 明细 + 日期/下拉统一，2026-07-27 跨模块重构落地）；原"待做 1/2/3"按价值排序以后迭代

---

## 一、设计基底（已对齐 `ui-ux-pro-max`）

跑过设计系统推荐（ERP/制造/仓储 → **Flat 工业风**）：

| 维度 | 取值 | 说明 |
|---|---|---|
| 风格 | Flat Design（触感优先） | 零重阴影、纯色块图标容器、几何感 |
| 主色 | slate `#334155` + 品牌深绿 `#0F3D2E` / 强调绿 `#059669` | 与现有 `UtenColors` 一致 |
| 语义色 | 已审=绿、红冲=红、草稿/全部=中性 slate | 颜色+文字双编码（`color-not-only`） |
| 字体 | 现有 type system（不改） | tabular figures 用于数字列/金额 |
| 间距 | 4/8dp 节奏（`UtenSpacing`） | 已遵循 |

**核心问题（评审结论）**：列表页一上来就是稀疏表格，**没有"业务一眼看懂"的指标**——ERP 的价值在数据概览，而页面把它藏在了表格里。下列优化围绕"把业务价值提到首屏"展开。

---

## 二、已完成 ✅

### 1. 列表页 KPI 摘要条（`lib/shared/widgets/doc_kpi_bar.dart`）
- 列表顶部 4 张卡片：**总数 / 草稿 / 已审 / 红冲**，既是指标又是状态筛选（点击切换）。
- 并行 `list(size=1, status=X).total` 取计数，**无需后端改**。
- 已接入：采购 4 单据列表 + 仓库 8 单据列表。
- 复用性：销售/委外/生产等列表以后一行 `DocKpiBar(counter:, selected:, onSelect:)` 即套用。

### 2. 仓库 hub 分区标题
- `WarehouseHubPage` 加「出入库单据」标题 + 副标题，对齐采购 hub 的两组卡片层次。

### 3. 编辑页明细改可编辑 Excel 表 + 日期/下拉统一（2026-07-27，跨模块重构落地）
- **明细 Excel 化**：新建 `lib/components/layout/uten_editable_grid.dart`（`UtenEditableGrid` — controller + `AmountRowMixin` + `ValueListenable` 杀重建风暴；加行/加 N 行/删行；sticky 表头 + 列宽拖拽 + 表头竖分隔线 + 表头左对齐；内容撑高的 body 给 ListView）。采购/仓库（及其它三模块）各配套 `lib/features/{module}/widgets/{module}_grid_columns.dart`（`{Module}GridRow` + columns）。**替换原来编辑页的纵向卡列表明细编辑器**（采购 4 单据 + 仓库 8 单据编辑页全改）。
- **日期字段统一**：新建 `lib/components/inputs/uten_date_field.dart`（`UtenDateField`，outlined，与其它字段一致），替换编辑页里 ListTile 风格的日期选择器。
- **下拉字段统一**：新建 `lib/components/inputs/uten_dropdown_field.dart`（`UtenDropdownField`，Overlay 弹层，样式镜像货品主档 `_FilterCell`：`surfaceContainerHigh`+`elevation8`+`radius8`+选中 `primaryContainer`+勾），替换编辑页表头与 grid 单元格里所有的 `DropdownButtonFormField`。
- **单据号系统生成（配套）**：编辑页 billNo 字段只读"保存后自动生成"（后端 `DocNumberService` + V76 `doc_number_sequences`，详见 [数据迁移/27-DDL一致性契约] §一 V76 段 + [数据迁移/28-Java后端契约] §九）。
- **skip-list**：采购 request（请购）配置 `skipListOnCreate`，管理卡直跳新建页（编辑页 AppBar 加"查看历史"按钮进列表）。
- **保存按钮文案**："存草稿"→"保存"（草稿→审核→红冲流程不变）。

---

## 三、待做（按价值排序）

### 待做 1 · 详情页：状态步骤条 + 金额汇总卡 【中价值，纯前端】
**现状**：详情页头部是 KV 卡（单据号/日期/供应商/…/状态/合计），状态只是一个文字，金额埋在 KV 里，不够醒目。
**目标**：把"这张单到哪一步、值多少钱"做到首屏最显眼处。

- **状态步骤条（Stepper）**：`草稿 → 已审`（+ 红冲分支）。横向 3 段，当前段高亮主题色，已完成段打勾。让单据生命周期一眼可见。
- **金额汇总卡**：独立的醒目卡（贴顶），大字号显示 `合计（本币）¥X`，副行 `原币 ¥Y · 明细 N 行`；收货/退货单再加 `已收/已退` 汇总。
- 涉及文件：`purchase_doc_detail_page.dart`、`stock_doc_detail_page.dart`（+ 抽一个 `DocStatusStepper` 共享组件到 `lib/shared/widgets/`）。
- 设计依据：`visual-hierarchy`、`primary-action`、`color-semantic`。

### 待做 2 · 列表页：表尾汇总行 + `/summary` 端点  【中价值，需后端】
**现状**：KPI 条只有"计数"，没有"金额"概览（金额需 sum，列表分页拿不到全局合计）。
**目标**：表尾一行「筛选结果 N 条 · 合计 ¥X」（按当前筛选条件汇总）。

- **后端**：各单据加 `GET /api/{module}/{doc}/summary?...同筛选条件` → `{ count, totalAmountLocal, totalAmountOriginal, draftCount, approvedCount, reversedCount }`（一条聚合 SQL）。
- **前端**：列表底部 `MasterDataTableView` 下方加汇总条（tabular figures）；KPI 条可顺带用 summary 的金额做一张"金额 KPI 卡"。
- 涉及：4 采购 + 仓库 Service/Controller 加 `summary`；前端 list 页。
- 设计依据：`number-tabular`、`data-density`。

### 待做 3 · PMC 工作台 / 首页：真仪表盘  【高价值，新页】
**现状**：工作台是模块 tile 网格，没有"业务驾驶舱"。这是"最大展现业务价值"的地方。
**目标**：PMC 进工作台先看到 KPI 仪表盘：

- **KPI 网格**：待审采购单 / 待交货订货（量+额）/ 本月收货额 / 当前库存预警（低储/负储数）/ 待盘点。
- **待办列表**：待我审核的单据（点击直跳详情审核）。
- **趋势**：近 6 月采购额/收货额折线（`purchase_monthly_mv` + `stock_monthly_mv` 已有数据）。
- 数据来源都已就绪（单据表 + MV + stock_balances）。需新增一个 `/api/dashboard/pmc` 聚合端点 + 一个 `PmcDashboardPage`（或嵌进现有 Dashboard）。
- 设计依据：`chart-type`（趋势→线）、`stat-tile`、`empty-data-state`。

---

## 四、复用组件清单（已建 / 待建）

| 组件 | 路径 | 状态 | 用途 |
|---|---|---|---|
| `DocKpiBar` | `lib/shared/widgets/doc_kpi_bar.dart` | ✅ 已建 | 列表页状态计数 KPI 条 |
| `MasterDataTableView` | `lib/features/basic_data/widgets/` | ✅ 已建（支持 facets 空列降级纯标签） | 主档/单据通用表格 |
| `DocStatusStepper` | `lib/shared/widgets/`（待建） | ⏳ 待做 1 | 详情页状态生命周期条 |
| `AmountSummaryCard` | `lib/shared/widgets/`（待建） | ⏳ 待做 1 | 详情页金额汇总卡 |
| `ListFooterSummary` | `lib/shared/widgets/`（待建） | ⏳ 待做 2 | 列表表尾计数+金额汇总 |

---

## 五、优先级建议

1. **待做 3（PMC 仪表盘）**——价值最高，数据已就绪，是"展现业务价值"的核心。
2. **待做 1（详情页 stepper + 金额卡）**——纯前端、低风险、立竿见影。
3. **待做 2（列表表尾 + /summary）**——需后端，价值中等，可随各模块迭代补。

> 跑测：`flutter run --dart-define=API_BASE_URL=http://localhost:8080/api -d chrome --web-port=53764`
> 关联：`docs/数据迁移/17-仓库管理-新库与迁移.md`、记忆 `purchase-module-progress` / `warehouse-module-investigation`。
