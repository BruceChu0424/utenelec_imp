# W4（P4 读通道：首批即显 + 整流预取）实测与定论 2026-11-07

## 1. P4.1 主档完整流首批 provisional 发布（已完成）

链路（纯客户端，服务端 NDJSON 协议零变更、`contracts/complete-summary-stream-v1.json` 零变更）：

- `PagedReadIntent.provisionalRead/currentProvisional` + `PagedReadProvisionalSink`：zone 内一次性首批槽，**只由拥有视图行的完整读取认领**（`claim()` 一次；同 zone 内辅助完整读取认领失败、永不发布）。
- `loadCompletePagedResult(onProvisionalBatch:)`：仅在首批校验通过且仍有后批时发布一次（服务端精确 total 原样带出）；单批结果不发布 provisional，直接给权威结果。
- `readVersionedSummarySnapshot(onProvisionalBatch:)` → `readCompleteMasterSummary` 在首个 await 之前同步捕获 zone 槽，帧边界再核 owner 当前性后发布。10 个主档仓库调用方零改动。
- `ScopedPagedRead.read(onProvisionalBatch:)`：只有**无已接受结果的新读取**发布 provisional（refresh 仍走既有"上次权威结果 pending"语义）；provisional 行经同一 `PagedReadWindowSession.bindResult(pending:true)` 绑定 owner 证明，失败/访问拒绝沿用既有 `fail()/invalidate()` 退休。`readScopedPage` 透传。
- 主档面板 `MasterEntityDetailPane`：provisional 到达即显示首批，`_listLoading` 保持到完整结果——导出/打印/批量/写入入口（既有 `!_listLoading` 门）在 provisional 期间保持禁用；表格用既有 `loadingMore` 语义（不新增提示行，遵守界面提示规范）；**任何失败或被退休的读取整体撤下 provisional 行**，恢复读取前画面（同查询刷新）或空（换查询）。
- 规范同步修订（同批）：`AGENTS.md`「业务列表单页连续展示」节、`docs/00-项目准则/09-组件库使用规范.md` 五节、`docs/00-项目准则/16-统一实现与公共能力.md` 第 71 行同义例外条款。
- 设计技能：按 AGENTS.md 先读 `frontend-design`；本项无新视觉元素，复用既有加载语义（克制原则）。

测试：`test/shared/paging/provisional_first_batch_test.dart` 8/8（首批唯一发布+精确 total、单批不发布、同会话绑定、断流整批失败、被替代请求不发布、refresh 后重新新读、zone 槽一次认领、fetchComplete 路径可见槽）；`master_entity_detail_pane_test.dart` 19/19（「后续批未完成」测试按新合同改断言：首批 100 行可见 + `loadingMore`；新增「断流整体退休不留半份」）；`test/features/basic_data/` + `test/shared/paging/` 合计 2026 全绿。

## 2. P4.2 货品整流：流内不变事实一次求值 + 名称映射跨批复用（已完成部分）

- `BoundedMasterReadSource.memo(key, supplier)`：同一计数游标（同一 RR 快照、游标已拒绝筛选变化）内，`GoodsService.list` 的 `resolveCategoryScopeIds`（子树递归）、`goodsScope()`、`keywordPlan(f)`（含整表分类树）由**每批一次**改为**每流一次**；游标外每次照常求值（非流路径零变化）。
- `BoundedMasterReadSource.lookup(domain, keys, loader)`：所属仓库名、归属车间名、历史颜色/单位名映射跨批复用，只查本批新出现的键（未命中也记住）；值只存纯事实（不缓存托管实体——历史模具映射含实体，仍按批）。
- 效果（语句数口径）：33k 行根分类流 331 批，每批 ~5–6 条（子树+范围+BOM+库存+仓库名+车间名）→ ~2 条（BOM+库存，名称映射首批后基本零查询），约少 1,300 条语句/次。
- 测试：`MasterSummaryStreamTest.streamInvariantFactsResolveOncePerCursorAndLookupsOnlyQueryUnseenKeys`（不变事实每流 1 次、查找只查新键且记住未命中、游标外不缓存）；货品列表相关 46/46 全绿。

**本波未做（待用户决定）**：
1. 51 字段轻投影、不水合实体：`BoundedMasterReadSource` 计数游标同时服务完整流与导出、选择实体根；改投影须新增一条 45+ 字段 + 价格/折扣/币种可见性 + 可写判定的第二映射路径，对拍面大。流内冗余辅助查询（主要可消除成本）已由上项去除。
2. facets 客户端化：**与现有口径冲突**——服务端分面对每列**排除该列自身表头筛选**（选中某色时颜色分面仍显示全部颜色），而客户端已下载的是**已应用全部筛选后**的结果，无法还原"排除自身筛选"的桶。可行的不改口径做法是"无任何表头筛选时客户端算、否则走服务端"，属新取舍，需用户拍板。
3. keywordPlan 跨请求会话级缓存（按分类树 revision）：流内每批重载已消除；跨请求（流与分面各一次）仍各算一次，未做。

## 3. P4.3 任务中心/报表一次化

- 首请求带 metadata：**已是现状**（`operations_workbench_repository.dart:121` 续页 `includeMetadata:false`，服务端 `rowsOnlySql`）。
- 续页并发 `maxConcurrentPages`：`ScopedPagedRead.read/readScopedPage` 已透传该参数（默认 1）；**履约工作台未开启**——客户端并发管线要求每批携带 `readSnapshotRevision/readDataVersion`（64 位十六进制）凭据，`FulfillmentWorkbenchPage` 响应目前没有，强开会以 INCOMPLETE_READ_PROTOCOL 拒绝整次读取（已在页面测试中复现后撤回）。开启前需先给工作台响应补读取凭据（服务端+客户端解析），记为后续项。
- 报表 `stock_balances` 全表 GROUP BY 收窄：**经实测不做**——公司库 `stock_balances` 8,787 行、8,614 货品，全表 HashAggregate 3.4ms；改为按页货品集过滤无用户可感知收益（与偏差 3/W2-5 同口径）。
- 报表元数据/取行拆分（`ReportPagedRead` 同候选集一次算完 rows/count/facets/totals）：未做。

## 4. P4.4 选择器/弹窗收敛：未做

14 个财务弹窗 + `uten_employee_selection_panel` 直调 `loadCompletePagedResult` 收敛到 gateway/`readScopedPage` 属统一实现迁移（逐个回归），本波未开工；P4.1 的 provisional 机制已对走 `readScopedPage`/主档完整流的选择器生效。
