# W4 收官（续页并发凭据 + 弹窗收敛 + 两项定论）实测 2026-11-07

接 w4-provisional-and-stream-prefetch.md（P4.1/P4.2 已完成部分与两项待用户决定事项——本次交互未获答复，按主文档口径继续：轻投影维持「未做、待拍板」，facets 客户端化维持「与口径冲突、不做」，均不再推进）。

## 1. 工作台续页并发（P4.3 第一项，提交 `73f385afb`）

### 实现

- **V1118 `fulfillment-workbench` 读取新鲜度域**：表集不是手抄——以页面 SQL 全量标识符（FulfillmentWorkbenchQueryService/PageRead + SubcontractLossSettlementSql/ProcurementDeliveryDifference）为种子，经**视图重写依赖 + 函数体正则闭包递归**在 V1117 库上求出 59 张公共基表（含手追极难漏的 `production_material_discovery_lines`、`subcontract_component_stock_handoffs`、`preplan_supply_actions` 等）。导入登记表排除（业务表自身写的纯投影）。迁移为显式表数组 + 逐表 4 条 statement marker 触发器（V1104/V1110 形态）+ 末尾 `fn_refresh_summary_read_marker_gates()`，内嵌 236 条自检。副本库事务内试跑回滚验证后定稿。
- **服务端**：`FulfillmentWorkbenchQueryService.queryVersioned` 用 `VersionedSummaryPages.read`（双 REPEATABLE_READ 栅栏，读前/读后两次 stamp，读中数据漂移即 SNAPSHOT_CHANGED）。revision identity 含 department/status/keyword/exception/日期/table(排序+列筛选+发证/需求区间)/仓库范围，**不含页码与 includeMetadata**——续页与首页同 revision。授权域按部门用现成 `native_purchase_owner`/`native_subcontract_owner`/`native_warehouse_tasks`。控制器三个分页端点切换；导出/聚焦查询保持原路。`FulfillmentWorkbenchPage` 增 readScopeVersion/readSnapshotRevision/readDataVersion（旧构造器兼容，内部调用零改动）。
- **客户端**：`VersionedPagedReadSnapshot`（PagedReadSnapshot 子类，实现 `VersionedPagedResultProof`，withRows 保凭据）；`OperationsWorkbenchData` 解析并携带凭据；工作台页与委外任务中心（同一端点族）`maxConcurrentPages: 2`。
- **测试**：真库 `FulfillmentWorkbenchVersionedReadPostgresTest` 4/4（全链 Flyway 至 V1118：三部门页/续页/rowsOnly 同凭据、不同筛选不同凭据、marker 提交后 revision 变化、读中授权漂移 READ_SCOPE_CHANGED、59×4 触发器全带持久事务门）；客户端契约 `operations_workbench_read_proof_test` 4/4（双续页在飞+乱序放行全局次序、数据版本漂移整读退休、无凭据首批即拒 INCOMPLETE_READ_PROTOCOL）；工作台 12 个替身文件改为按真实端点协议回包（窗口切片+精确分页字段+凭据，`test/helpers/workbench_read_fixture.dart`），多页重验证场景改为 101 行两批的真实完整读。
- **预算/契约复核全绿**：IqcTriggerProfileEndToEndTest 1/1、WorkshopDirectTransferBatchEndToEndTest 14/14（守卫调用预算不变——marker 触发器不进守卫遍历计数）、AuditTriggerCoverage PG 11 + 迁移契约 17、HotTableTriggerHygiene 9、SchemaIndexHygiene 6、LegacyMigrationSafety 12、VersionedSummaryPagesPostgresTest 15、ForwardMigrationSequence 4；工作台服务端 46、客户端 114+226+4。
- README 标记 V1118/1057。

## 2. 报表元数据与取行拆分（P4.3 第二项）：定论不做

- **拆分已是现状**：`ReportPagedRead`/`ReportMetadataReuse` 30s 租约 + `metadataReuse:true`+`readScopeVersion` 门 + 服务端 `ReportReadPlanInterceptor` includeCount/includeFacets/includeTotals 计划——同 scope 的续页零元数据重算（`/api/(sales|purchase|…)/reports` 全族）。补做项只剩「首页 rows+count+facets+totals 合一语句」。
- **实测（副本库 `uten_perf_w2`，销售订货明细=最重通用形状）**：单月窗 count 全 JOIN 11ms(热)/204ms(冷)，去掉无引用 JOIN 2.9ms；全年窗 22.6ms/4.6ms；首页 50 行 58ms；第 40 页(offset 1950) 9.8ms；单列分面 GROUP BY 4.2ms。首页元数据合计 ≈60-80ms(热)，合一语句最多省几十 ms——与偏差 3/W2-5/W3-4/stock_balances 同口径：无用户可感知收益，不做。合一还需把 count(含筛选)/facets(排除自身筛选)/totals 三种谓词并进一条语句，口径风险不成比例。
- 记档观察：完整读取的墙钟由**串行 HTTP 往返**主导（每批 50 行逐页 GET）；报表接入并发管线需要与工作台同型的服务端凭据（报表响应只有 readScopeVersion 头，无 revision/dataVersion），属另一波次的通用能力，未在本波范围。

## 3. P4.4 财务弹窗/选择面板收敛（9 迁移 + 6 保留）

前端改动前已读 frontend-design；本项为纯数据管线收敛，无新视觉元素，全部复用各弹窗既有加载/错误/遮罩语义（克制原则），UtenBusyOverlay 与提示 icon 规范不受影响（未动按钮与提示）。

**已收敛到 `ScopedPagedReadViewMixin.readScopedPage`（统一入口）**，逐个回归：

| 弹窗 | 测试 |
|---|---|
| finance_auxiliary_dialog（目录） | 6/6 |
| finance_native_posting_accounts_dialog | 7/7 |
| finance_subcontract_loss_policy_dialog | 12/12 |
| finance_material_context_picker | 由 material_statement 10/10 覆盖 |
| finance_procurement_confirmation_dialog | 3/3 |
| finance_supplier_prepayment_dialog（列读收敛；前置 detail get 保留） | 8/8 |
| finance_expense_analysis_dialog（assignment 模式） | 4/4 |
| finance_open_item_classification_dialog（目录） | 5/5 |
| finance_statement_document_dialog（目录） | 17/17 |

finance 全目录 1,223 测全绿。迁移要点：mixins 由 `ReadViewActivityMixin` 升级为 `ScopedPagedReadViewMixin`（自带同名 readViewActivity）；刷新/写后加载一律新鲜读（useCache 仅分页翻页可用——首个用例「保存后重试」最初误开 useCache 被测试抓住后修正）；query/currentQuery 成对，查询变化由 scope 身份退休。

**保留（真实语义差异，非欠账）**：

- `finance_material_statement_dialog`（4 处 `_readMaterialPages`）、`finance_asset_opening_group_dialog`（草稿选择）、`finance_subcontract_quantity_evidence_dialog`（2 处）：读取在 `captureRequestScope().run` 内执行——整次完整读钉住同一凭据快照，防中途换 token 改变身份；统一入口无此语义。
- `finance_native_legacy_opening_dialog`、`finance_payroll_preparation`：页 1 响应信封捕获（binding 元数据/balancePool）+ 复合后续读取在同一 activity 块，readScopedPage 不暴露首页原始信封。
- `finance_statement_document_dialog._OriginalState`：冻结原件核对读，逐批比对 documentMetadata 身份且**刻意不带 idOf**（保留重复行），是文档核对语义不是列表读。
- `uten_employee_selection_panel`：`allowUnknownTotal` 游口语义 + `onBatch` 渐进前缀显示 + 非 Consumer 组件契约，三者均不在统一入口参数面内。

## 4. P4.2 遗留两问与 keywordPlan 缓存（维持不做）

- 51 字段轻投影、facets 客户端化：维持证据文件既有定论（待用户拍板/口径冲突），本波未动。
- keywordPlan 按分类树 revision 跨请求缓存：`keywordPlan` 的整表加载 = material_categories 910 行、4.4ms（副本库实测），且仅在有搜索词时每请求一次；缓存收益 ≤5ms/请求，换来 revision 键失效面。不做（与偏差 3 同口径）。
