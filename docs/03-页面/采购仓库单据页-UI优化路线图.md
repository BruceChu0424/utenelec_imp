# 采购 / 仓库单据页 · UI 优化路线图

> 建立时间：2026-07-26 · 来源：`/ui-ux-pro-max` 设计系统评审 + 实测
> 适用：采购 4 单据、仓库 8 单据（及未来销售/委外/生产等同款"主从表单据列表"页）
> 状态：第 1、2、3 项已完成（3 = 编辑页 Excel 明细 + 日期/下拉统一，2026-07-27 跨模块重构落地）；原"待做 1/2/3"按价值排序以后迭代
> **现行后置覆盖**：下文保留 7 月 UI 演进证据，但采购申请已改为计划链下达、采购端只读，不再直跳新建或沿用普通草稿审核。采购任务中心可跨申请选行并部分分解；一张订货单只能选择一个供应商（仓库已随 2026-08-16 V292/ADR-038 从订货中移除：订货不选仓库、跨仓明细可并入同一张订货，入库仓库到收货登记时必填），保存后送财务审核组（V229/ADR-027 已取代早期精确负责人）。只有合格审核人通过才把订货置为 `status=1` 并形成预计到货（预计到货可无仓库，登记时选仓）；超量先不写库存/AP，再由审核组决定，批准量由仓库再审，未批量只交原下单人退回。
> V202 是对全部 `public` 业务表的 fail-closed 审计 sweep，不是三张表定向补丁，且已包含在目标库 V238 以内。完整 IQC、真实岗位/实物 UAT 和发布签字未完成，生产 **NO-GO**。
>
> **2026-08-11 生产来源覆盖**：生产计划员在统一 BOM 树显式「采用采购/采用委外」后，只有真正可执行的节点才出现复选框；点「提交采购需求（N）」或「提交委外需求（N）」才创建计划前 action、逐路径 allocation 和真实申请。采购/委外列表必须保留这些来源 ID 和行级关联，允许回查 analysis、产品和 BOM path，不能只显示一条无来源的通知。超过 500 个最终任务时按稳定身份分批，后一批续用新版 CAS，同一精确 chunk 重试的幂等键不变。
>
> 财务批准的预计到货不是库存。实际收货/回厂后只有 IQC PASS 且进入原分析目标仓的合格可用量才刷新物料齐套；它不能直接增加生产计划的「已报工」或成品「已入库」。仓库单据应从申请/订货/收货/质检/库存流水一路回查到原逐路径 allocation，生产端据此刷新可完工量。当前真实多岗位与实物流转仍未闭环，这是一条验收合同，不是“已全链上线”的声明。
>
> 物料页 AppBar「备料汇总预览」打开的「生产备料计划汇总单」只提供「打印 / 导出 PDF」，不负责把采购/委外任务送入本模块；真正交接只认上述 action/申请事实。MAKE/root 的计划向导也只提交生产计划草稿，三种职责链不得在单据 UI 中混成一张可审核的大单。


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
- **滚动布局（2026-08-17 起）**：KPI 条不再常驻挤压表格——采购 / 仓库 / 销售（订货单统计卡）单据列表页接入 [UtenCollapsingHeaderScrollView](../02-组件库/UtenCollapsingHeaderScrollView.md)，任意位置上滑先收起 KPI / 统计卡条腾出空间，标题行（图标 + 计数 + 新建）钉在表格上方常驻，`MasterDataTableView(primary: true)` 表体内部滚动、表头吸顶，与货品资料 / 任务工作台一致。

### 2. 仓库 hub 分区标题
- `WarehouseHubPage` 加「出入库单据」标题 + 副标题，对齐采购 hub 的两组卡片层次。

### 3. 编辑页明细改可编辑 Excel 表 + 日期/下拉统一（2026-07-27，跨模块重构落地）
- **明细 Excel 化**：新建 `lib/components/layout/uten_editable_grid.dart`（`UtenEditableGrid` — controller + `AmountRowMixin` + `ValueListenable` 杀重建风暴；加行/加 N 行/删行；sticky 表头 + 列宽拖拽 + 表头竖分隔线 + 表头左对齐；内容撑高的 body 给 ListView）。采购/仓库（及其它三模块）各配套 `lib/features/{module}/widgets/{module}_grid_columns.dart`（`{Module}GridRow` + columns）。**替换原来编辑页的纵向卡列表明细编辑器**（采购 4 单据 + 仓库 8 单据编辑页全改）。
- **日期字段统一**：新建 `lib/components/inputs/uten_date_field.dart`（`UtenDateField`，outlined，与其它字段一致），替换编辑页里 ListTile 风格的日期选择器。
- **下拉字段统一**：新建 `lib/components/inputs/uten_dropdown_field.dart`（`UtenDropdownField`，Overlay 弹层，样式镜像货品主档 `_FilterCell`：`surfaceContainerHigh`+`elevation8`+`radius8`+选中 `primaryContainer`+勾），替换编辑页表头与 grid 单元格里所有的 `DropdownButtonFormField`。
- **单据号系统生成（配套）**：编辑页 billNo 字段只读“保存后自动生成”，不预取或猜测下一号。V76 `doc_number_sequences` 为历史取号基线；V279 当前候选由后端命名空间、上海业务日和 6 位日流水生成权威号码。Flutter 不保存前缀镜像表，保存成功后展示服务端返回值。详见 [数据迁移/27-DDL一致性契约] §一、[数据迁移/28-Java后端契约] §九与 [ADR-036](../99-决策记录-ADR/ADR-036-全局业务标识与单据号命名空间.md)。
- **采购申请后置更正**：历史 `skipListOnCreate` 直跳新建已被 ADR-019 取代；采购申请管理卡只进入计划下达申请的只读列表/详情，不显示新建、编辑、审核、反审、红冲或删除。
- **订货保存后置更正**：采购/委外订货主按钮为“保存并提交财务”；提交失败保留草稿并明确提示，不能把草稿显示成待审。申请没有保存动作，其余普通单据仍按各自状态机显示动作。
- **货品选择统一（2026-07-28；2026-08-14 搜索升级）**：明细货品选择器统一为 `showUtenGoodsPicker`。左树顶部一个框同时搜索 scope 内分类和货品，展开关联路径；右侧显示同词受限分页结果。超过 32 个根分批完整合并，纯分类命中不误传货品关键词，禁用/stub 失败关闭排除。全模块（销售/采购/委外/仓库/生产）共用；选中后颜色/单位自动回填。详见 [UtenGoodsPicker](../02-组件库/UtenGoodsPicker.md) · [ADR-015](../99-决策记录-ADR/ADR-015-统一货品选择器与legacy到UUID桥接.md)。
- **从上游引入 Excel 化（2026-07-28）**：销售出货/退货编辑页「从上游引入」从居中 Dialog 换成**右滑入大面板（840）**，两步各自 Excel 表——Step1 上游单据 `MasterDataTableView`（搜索 + 客户筛选 + 分页 + 排序，状态固定已审）；Step2 该单据明细 `UtenEditableGrid`（`showAddRow:false`）勾选 + 本次数量 + 全选/反选。点单据切明细，引入沿用 `SalesLinkedItem` 映射。`UtenEditableGrid` 通用组件加 `showAddRow` 开关（默认 true 不影响编辑页）。

---

## 三、待做（按价值排序）

### 待做 1 · 详情页：状态步骤条 + 金额汇总卡 【中价值，纯前端】
**现状**：详情页头部是 KV 卡（单据号/日期/供应商/…/状态/合计），状态只是一个文字，金额埋在 KV 里，不够醒目。
**目标**：把"这张单到哪一步、值多少钱"做到首屏最显眼处。

- **状态步骤条（Stepper）**：采购/委外订货显示 `DRAFT → PENDING → APPROVED / REJECTED` 财务状态，并把“财务通过后原生 `status=1`”单独解释；申请只读显示计划下达状态，不套普通草稿/审核/红冲步骤。其余单据沿用自己的状态机。
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

### 待做 3 · PMC 采购履约驾驶舱（不授财务审批权） 【高价值，现有聚合待办上增强】
**现状**：当前已有部门/权限过滤的聚合 TODO、生产履约任务工作台以及仓库/采购/委外三个真实任务入口，不再只是模块 tile；订货与超量审批只属于钱流任务中心的财务审核组，PMC/采购卡不能代审。
**目标**：在现有聚合工作台上补 PMC 履约 KPI：

- **KPI 网格**：未分解申请余量 / 待财务订货（只读状态）/ 已批预计到货（量+额）/ 本月收货额 / 当前库存预警（低储/负储数）/ 待盘点。
- **待办列表**：复用当前真实可操作清单与服务端权限过滤，不另造与点击目标不一致的计数。
- **趋势**：近 6 月采购额/收货额折线（`purchase_monthly_mv` + `stock_monthly_mv` 已有数据）。
- 单据表、MV 与 stock_balances 可作为输入，但 IQC、完整 WMS 和历史对账未闭环，指标定义必须标来源与更新时间。可新增 `/api/dashboard/pmc` 聚合端点并嵌入现有工作台。
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

1. **待做 3（PMC 专属趋势/预警/审批驾驶舱）**——在现有真实聚合待办上增强，先统一指标口径和权限。
2. **待做 1（详情页 stepper + 金额卡）**——纯前端、低风险、立竿见影。
3. **待做 2（列表表尾 + /summary）**——需后端，价值中等，可随各模块迭代补。

> 跑测：`flutter run --dart-define=API_BASE_URL=http://localhost:8080/api -d chrome --web-port=53764`
> 关联：`docs/数据迁移/17-仓库管理-新库与迁移.md`、记忆 `purchase-module-progress` / `warehouse-module-investigation`。
