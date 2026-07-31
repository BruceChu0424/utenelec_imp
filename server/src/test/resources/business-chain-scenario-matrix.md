# 销售—生产—仓库—采购—委外全链路可执行场景矩阵

> 基线日期：2026-07-31。本文是测试资源，不替代业务需求，也不构成生产放行结论。
> 需求与口径以 `docs/07-业务链路/04-生产订单排产与执行全链路需求.md` 为准；
> 实现状态必须以当前迁移、代码和自动化测试复核，不能从目标文档反推“已经上线”。

## 1. 状态约定

- `[GREEN]`：当前源码已有实现和针对性自动化证据；合并前仍须在最终工作树复跑。
- `[PARTIAL]`：核心的一部分已实现，场景仍有明确缺口。
- `[RED]`：仍是发布阻断；未关闭前不得把对应链路当成生产可用。
- `[BLOCKED]`：目标能力尚未实现或被 fail-closed，界面只能只读/隐藏入口。
- `[MANUAL]`：需要岗位、实物、数据、权限或运维验收，不能被单元测试替代。

## 2. 权威数据与不可破坏约束

| 业务事实 | 唯一权威来源 | 禁止做法 |
|---|---|---|
| 销售需求与未排数量 | 销售订单明细、有效 `plan_order_item_links` 与 V157 `execution_segment_sales_allocations`；精确分摊已纳入最终组合回归 | 从页面缓存、通知或计划表头反推 |
| 生产物料需求 | `production_material_demands` 与确认时 BOM 指纹/需求快照 | 用 BOM 当前版本覆盖已确认任务 |
| 现货物理占用 | `stock_reservations` 中有效的原量、消耗量、释放量 | 为生产另建孤立锁表，或把 WAITING 临时覆盖写成占用 |
| 采购/委外供应归属 | `production_material_supply_pegs`、显式转换/收货分摊及 V162/V163 来源守卫 | 仅按货号、颜色或日期猜测归属，或通用 CRUD 改写已挂接来源 |
| 执行批次 | `production_execution_segments`；不是 `subplan_links` 自制件子计划 | 用状态按钮直接伪造段进度 |
| 生产完成与成品入库 | 审核报工、精确执行段、审核成品入库明细 | 草稿报工或通知状态增加库存 |
| 领退料与清账 | DRAW/WDRAW 审核库存事实 + V161 append-only 物料事件/posting 精确分摊 | 直接改余额、修改/删除已接受事实或用百分比容差吞差异 |
| 通知投递 | 与业务事务同提交的 `business_outbox`；READY 按执行段+收货去重并按 `SUB_PLAN`/`DEPT_PROD` 部门权限树投递 | 业务提交后尽力调用一次，或依赖已下线角色猜接收人 |
| 系统审计 | HTTP/表审计加业务语义事件，保留 before/delta/after、来源和幂等键 | 只记 URL 和 HTTP 200 |

必须持续成立：

1. 同一销售订单明细的有效计划/执行分配总量不得超过审核有效需求。
2. 物理占用有效量为 `qty - consumed_qty - released_qty`，不得为负。
3. 同一需求的现货有效占用加未来供给有效分配不得超过需求量；同一供给不得超分。
4. READY 必须一次拥有完整套料；WAITING 不得占住零散现货或生成可发 DRAW。
5. 审核合格报工累计不得超过执行段计划量；关联成品入库不得超过审核合格量。
6. 清料必须满足“累计领用 = 已确认耗用 + 已验收退回 + 审批损耗/报废 + 合法在制”；差异不为零不得完成。
7. 确认、审核、取消、红冲和重试必须有稳定幂等维度；反向只恢复原动作仍有效的数量。
8. V161–V164 保护的台账、采购/委外来源、收货追溯和生产关联库存单据不得经通用 CRUD 绕过；纠错必须走可追溯专用反向。

## 3. 统一锁序与失败语义

写事务遵循“业务表头 `PESSIMISTIC_WRITE` → 上游表头/明细按类型和 UUID → 仓库/货品/颜色 `advisory lock` → 需求/占用/供给按 UUID → 累计、库存流水、Outbox、审计”的稳定顺序。陈旧版本、来源不明、混用 V0/V1 或数量不平时整体回滚；不得只重放库存或通知步骤。

## 4. 场景矩阵

| ID | 阶段 / 工作台 | 前置与动作 | 必须断言（含反向） | 当前证据 / 明确缺口 | 状态 |
|---|---|---|---|---|---|
| SC-01 | 销售审核→待排产 | 已审核订单重复提交审核 | 只生效一次；未排量不为负；销售对象范围正确 | 既有销售数量/预留测试；真实 HTTP 同单双审与人员范围仍需 UAT | `[PARTIAL][MANUAL]` |
| SC-02 | 部分齐套 | A 可做 10、B 可做 6，需求 10 | 生成 READY 6 + WAITING 4；WAITING 零占用、零 DRAW | `CompleteKitAllocatorTest`、`ProductionExecutionSegmentPostgresTest` | `[GREEN]` |
| SC-03 | 多任务抢同一库存 | 两事务申请同一仓货色 | 串行后不超余额；失败方整事务回滚；不同键可并行 | `InventoryTransactionalIntegrityPostgresTest`、`ProductionMaterialFulfillmentPostgresTest` | `[GREEN]` |
| SC-04 | 订单改量/取消 | 未开始、已领、生产中、已入库分别改单 | 未开始可安全释放；冻结销售分摊不得删除/缩到已分配以下；有下游必须变更/反向 | V1 未开始包取消/反向和 V157 冻结 link 409 守卫已有；完整跨阶段变更单仍缺 | `[PARTIAL][RED][MANUAL]` |
| SC-05 | 可用量视图 | 仓级与全局预留并存，多仓/空颜色 | 每条余额只出现一次，全局占用只扣一次 | V150 LATERAL 重建 + 兼容测试；现网全量对账仍是门禁 | `[PARTIAL][RED]` |
| SC-06 | 一键生成预览 | BOM 全展开，点击但不确认 | 预览零写；返回指纹、版本和可编辑 READY/WAITING 建议 | `production_execution_planning_model_test.dart`、Flutter 全量测试、排产 sheet 静态复核及规划预览服务；性能和无障碍需人工复核 | `[GREEN][MANUAL]` |
| SC-07 | 子计划确认 | 同/异幂等键并发确认、陈旧预览确认 | 同键同结果；同计划仅一份有效包；不同载荷冲突；陈旧预览拒绝 | `ProductionExecutionSegmentPostgresTest`、规划服务幂等/哈希守卫 | `[GREEN]` |
| SC-08 | 完整套料拆分 | 100 件仅够 40 件；多物料瓶颈不同 | READY 40、WAITING 60；段总量等于未排量；不按物料行重复缺口 | `CompleteKitAllocatorTest` 含小数保守舍入，PG 持久化覆盖 | `[GREEN]` |
| SC-09 | 产能与冻结期 | 默认车间超载、三日冻结任务、插单 | 只建议不静默挪动；给出影响清单和延期量 | 无权威有限产能日历、冻结事务和 APS | `[BLOCKED][MANUAL]` |
| SC-10 | 替代料 | 主料缺、替代料有换算与审批版本 | 仅批准版本可选并固化原料/替代/换算/审批 | 替代料主数据、审批和成本差异未闭环 | `[BLOCKED][MANUAL]` |
| SC-11 | 统一生产物料分配 | 多需求竞争现货和同一未来供给 | 现货/供给均不超分；取消/红冲只释放本需求剩余量 | V150 约束；`ProductionMaterialFulfillmentPostgresTest` | `[GREEN]` |
| SC-12 | 采购请求卡片 | BUY 缺料确认、重试、取消 | 形成可追溯采购申请和逐需求 peg；漏建采购时确认失败；反向不误伤下游 | V150/V153/V154/V162、`ProductionPlanningPackageServiceTest`、`ProductionSupplySourceGuardTest`；跨需求聚合策略仍有限 | `[PARTIAL]` |
| SC-13 | 采购批量转单 | 采购多选缺料请求 | 同一已审申请内可多选行；来源/数量保留；不兼容项拒绝 | Flutter 工作台测试与 V162 来源 CRUD/容量守卫；跨申请自动合并未实现 | `[PARTIAL][MANUAL]` |
| SC-14 | 采购单据并发 | request/order/receipt/return 双审与红冲 | 先锁表头再验最新状态；第二次不重复库存/累计/应付 | `ProcurementDocumentStateLockTest` 及既有 PG 证据 | `[GREEN]` |
| SC-15 | 采购收货→待料唤醒 | 分批到货、重试、晚到 | 收货一对一迁移 peg；只在全套可占时 WAITING→READY + DRAW；真实迁移后 READY 通知一次 | PG 状态迁移/来源追溯证据 + `ChainNoticeReadyEventTest` 的 publishOnce/dedupe payload + `ChainNoticeService` 部门映射源码 | `[GREEN]` |
| SC-16 | 采购退货/红冲 | 已收货部分被生产占用后反向 | 已消费时阻断；先拆精确下游再反向 peg/库存；重复红冲无副作用 | V154 精确反向、V162 来源保护、V163 receipt provenance 均有定向/PG 证据；应付与全部竞态仍需回归 | `[PARTIAL][RED]` |
| SC-17 | 来料不良/补料 | 点收或领后发现不良 | 隔离、批次责任、补料引用、供应商处置可追溯 | 质量批次、隔离库、补料审批未闭环 | `[BLOCKED][MANUAL]` |
| SC-18 | 自制/采购/委外路线 | 同一缺口人工选择 make/buy/subcontract | BUY/SUBCONTRACT 路线互斥且数量守恒；未知或 MAKE 来源 fail-closed | V158 + `ProductionExecutionPlanningServiceSupplyRouteTest`；MAKE 尚无权威多层自产路线 | `[PARTIAL][MANUAL]` |
| SC-19 | 委外申请→订单 | SUBCONTRACT 缺口生成申请，订单审核/反向 | 申请逐需求挂接；订单等量迁移 peg；重复回调幂等；未开工可精确反向 | V158 合同/迁移测试、V162 来源/转换守卫及执行段 PG；跨申请批量写刻意禁用 | `[GREEN][MANUAL]` |
| SC-20 | 委外发料卡片 | 委外订单下达，仓库分批发料 | 状态来自真实发料单；累计不超 BOM/批准超领；每笔有来源 | 既有委外发料库存联动；独立备料/交接卡片状态机未实现 | `[PARTIAL][MANUAL]` |
| SC-21 | 委外余料/损耗 | 良品退、不良退、损耗及反向 | returned+wasted 不超 issued；质量状态和原来源对称 | 既有数量守卫；委外逐需求清账、质量处置仍缺 | `[PARTIAL][RED][MANUAL]` |
| SC-22 | 委外收货/退货 | 分批回厂、重复回调、未开工/已消费后反向 | 回厂逐明细累计 peg；整套才转 READY；未开工可整套撤回，消费后反向失败 | V158 定向/执行段 PG 与 V162 receipt/peg/reservation/DRAW 守卫覆盖供给、整套唤醒及反向；加工费、质量、发料/余料仍缺 | `[PARTIAL][RED]` |
| SC-23 | 仓库生产领料卡片 | READY 生成 DRAW，分批审核领取 | 工作台状态来自 DRAW 的待领取/部分/已领取；点击回真实单据；通用 CRUD 不得改生产 DRAW | V153 同源工作台、V164 数据库/服务/UI capability 守卫和 Flutter 测试；无独立备料中/双方交接状态 | `[PARTIAL][MANUAL]` |
| SC-24 | 分批领料/超领/补料 | 多次领料、重复审核、申请超额 | 普通领料精确消费原占用且不重复；已接受 posting 不可改删；超领/补料必须审批 | `ProductionMaterialIssueReturnPostgresTest`、V161 append-only PG；超领/补料审批和成本仍缺 | `[PARTIAL][RED][MANUAL]` |
| SC-25 | 分批报工 | 同一段多次报工并并发提交 | 首次进入生产中；累计不超段计划；草稿不改累计 | V156、`DailyReportExecutionSegmentGuardTest`、`ProductionExecutionSegmentOperationsPostgresTest`；照片/完整工时人员未实现 | `[PARTIAL][MANUAL]` |
| SC-26 | 不良/返工/补产 | 不良率超阈值并再次报工 | 原因必填；补产只生成一次；通知去重；不掩盖原数量 | 基础数量守卫已有；质量原因、阈值、返工/补产审批未闭环 | `[BLOCKED][MANUAL]` |
| SC-27 | 成品入库 | 多次报工、合并销售来源、内部计划 | 每条精确销售分摊不超其审核合格余量；来源不明 fail-closed；内部计划不伪造销售 | V157 `ExecutionSegmentSalesAllocationPostgresTest` 已纳入组合回归证据并覆盖笛卡尔泄漏、报工/入库上限；历史迁移仍待 | `[PARTIAL][RED]` |
| SC-28 | 余料退库与清账 | 良品余料、多次退料、消耗/审批损耗/合法在制后结案 | 最大可退实时计算；验收后回库存；领用=消耗+退回+审批损耗+合法在制；红冲对称且原事实不可篡改 | V152 round-trip/并发 PG 与 V161 append-only 覆盖消耗、良退、审批损耗和合法在制；不良品实物处置与成本仍缺 | `[PARTIAL][MANUAL]` |
| SC-29 | 销售进度/通知 | 排产、开工、部分完成、完工、缺料、延期 | 主事务和 `business_outbox` 同提交；同事件一次；READY 按部门范围投递；销售订单行只显示自身执行段及公开数量 | V151/V157、`ChainNoticeReadyEventTest` publishOnce/dedupe、PG 状态迁移、部门映射源码和销售进度 UI；对象范围黑盒和部署 SLO 未验收 | `[PARTIAL][RED][MANUAL]` |
| SC-30 | 发货/退货/反向 | 部分发货/退货，完成成品入库再红冲 | 反向先验下游；数量不下穿；完成段须先显式重开，失败全回滚 | 销售反向既有测试 + `ProductionCompletionReversePostgresTest` | `[GREEN]` |
| SC-31 | 权限、对象范围、审计 | 六部门越权读写、批量部分越权、查数量变化 | 最小权限；对象范围；批量全有或全无；审计可看脱敏 before/after 和幂等来源 | 工作台权限、审计详情已有单元/Widget 证据；真实 API 权限矩阵和语义覆盖率未验收 | `[PARTIAL][RED][MANUAL]` |
| SC-32 | 历史迁移、对账、死锁恢复 | V90/旧 MRP/V150–V164 升级，构造中断和反锁序 | 历史先隔离再补链；升级前后零差异；死锁整事务回滚并幂等重试 | 空库 146 个迁移回放到 V165、V148 已部署 checksum 锁定测试和 V147→V165 升级测试通过、真实 PG 16 类/44 项全通过；历史全量快照、恢复、压力和回滚演练未完成 | `[PARTIAL][RED][MANUAL]` |

## 5. 发布闸门

1. `PLANNING_WRITE_READY` 或等价灰度开关只能在迁移/对账、规划确认与反向、库存/采购/委外分配、权限和语义审计同版本验收后开启。
2. SC-04、SC-05、SC-09、SC-10、SC-16、SC-17、SC-20 至 SC-29、SC-31、SC-32 的 `[RED]`/`[BLOCKED]`/`[MANUAL]` 必须按范围关闭或继续 fail-closed。
3. 默认测试、`UTEN_RUN_DB_TESTS=true` 的真实 PostgreSQL 测试、Flutter 测试/analyze、迁移回放、人工 UAT、容量、备份恢复和告警演练全部通过。
4. 仓库、采购、委外卡片的状态必须来自审核单据；“已领取/已收货/已完成”不得由界面直接改状态。
5. V150–V164 源码存在、空库迁移成功或定向测试通过，均不能替代生产历史数据对账和负责人签字。

## 6. 建议执行命令

结构与纯单元：

```powershell
cd server
mvn.cmd -q -Dtest=BusinessChainScenarioMatrixTest,ArchitectureBoundaryTest,CompleteKitAllocatorTest,ProductionPlanningPackageServiceTest,DailyReportExecutionSegmentGuardTest,AuditQueryServiceTest,ProductionMaterialAppendOnlyLedgerMigrationTest,ProductionSupplySourceGuardMigrationTest,ProductionSupplySourceGuardTest,ProductionPurchaseReceiptProvenanceMigrationTest,ProductionLinkedStockDocumentGuardMigrationTest,ProductionLinkedStockDocumentServiceContractTest,ChainNoticeReadyEventTest test
mvn.cmd -q -Dtest=ProductionExecutionPlanningServiceSupplyRouteTest,ProductionSubcontractSupplyTransitionContractTest,ProductionSubcontractSupplyTransitionMigrationTest test
```

真实 PostgreSQL 核心链：

```powershell
cd server
$env:UTEN_RUN_DB_TESTS='true'
mvn.cmd -q -Dtest=InventoryTransactionalIntegrityPostgresTest,StockReservationSalesCompatibilityPostgresTest,ProcurementDocumentStateLockPostgresTest,ReportablePlanLinePostgresTest,ProductionMaterialFulfillmentPostgresTest,ProductionExecutionSegmentPostgresTest,ExecutionSegmentSalesAllocationPostgresTest,ProductionPurchaseSupplyTransitionPostgresTest,ProductionMaterialIssueReturnPostgresTest,ProductionExecutionSegmentOperationsPostgresTest,ProductionCompletionReversePostgresTest,BusinessOutboxPostgresTest,FulfillmentWorkbenchProvisionalStockPostgresTest,ProductionMaterialAppendOnlyLedgerPostgresTest,ProductionPurchaseReceiptProvenancePostgresTest,ProductionLinkedStockDocumentGuardPostgresTest test
```

最终全仓：

```powershell
cd server
mvn.cmd test
cd ..
flutter test --no-pub
flutter analyze --no-pub
git diff --check
```

当前组合结果：后端 335 tests、0 failure/error、48 skipped（PG 默认跳过）；真实 PostgreSQL 16 classes / 44 tests、0 failure/error/skip，空库 146 个迁移到 V165；Flutter 144/144，`flutter analyze --no-pub` 无问题，Web Release 构建成功。
