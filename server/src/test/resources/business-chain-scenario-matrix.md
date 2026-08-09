# 销售—生产—仓库—采购—委外全链路可执行场景矩阵

> 当前复核日期：2026-08-09。源码最高 V246，公司目标库只读证据到 V238，隔离非空克隆验证到 V244；V202/V190 数字仅是早期场景快照。目标库 V239–V246 迁移、历史对账、真实岗位 UAT 和发布签字仍未完成。
> 本文是测试资源，不替代业务需求，也不构成生产放行结论。
> 需求与口径以 `docs/07-业务链路/04-生产订单排产与执行全链路需求.md` 为准；
> 计划申请、订货财务审批和超量到货以 `docs/99-决策记录-ADR/ADR-019-计划需求分解与采购委外财务审批.md` 为准；
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
| 销售需求与未排数量 | 销售订单明细、有效 `plan_order_item_links` 与 V157 `execution_segment_sales_allocations`；精确分摊已有候选回归证据 | 从页面缓存、通知或计划表头反推 |
| 销售订单商业事实 | 已审核来源订单头/行；订单只形成币种与原币额（数量×单价×折扣），出货按发货量比例重取本次原币事实，`SHIPPED` 才锁财务汇率并形成发运/AR 本币 | 接受客户端汇率、本币金额、成本或商业条款，或把不同币种/商业条件的订单合并成一张出货 |
| 销售订单有效预留 | 审核后 `stock_reservations`；减少 ATP，不扣在手，`warehouse_id=NULL` 可表示尚未定发货仓；实际从某仓交接时只把本次消耗段拆出并绑定该仓，剩余承诺继续全局有效 | 草稿占库存、把有效预留说成已拣货，或把部分发货后的全部剩余预留错误绑定首个仓；当前销售订单没有独立提交态 |
| 销售仓库作业事件 | V188 `sales_shipment_warehouse_events` 追加式事件账 + V187 出货当前状态投影 | 只改当前状态不留原因，或 UPDATE/DELETE 已接受事件 |
| 销售退货质量 | V189 `sales_return_quality_items` 当前冻结投影 + `sales_return_quality_events` 追加式处置证据 | 退货审核即进入可售库存，或伪造历史退货质检结论 |
| 生产物料需求 | `production_material_demands` 与确认时 BOM 指纹/需求快照 | 用 BOM 当前版本覆盖已确认任务 |
| 现货物理占用 | `stock_reservations` 中有效的原量、消耗量、释放量 | 为生产另建孤立锁表，或把 WAITING 临时覆盖写成占用 |
| 采购/委外供应归属 | `production_material_supply_pegs`、显式转换/收货分摊及 V162/V163 来源守卫 | 仅按货号、颜色或日期猜测归属，或通用 CRUD 改写已挂接来源 |
| 采购/委外需求申请 | 计划链已下达的申请头/行、逐需求 peg 与 V199 未分解余量投影 | 让采购/委外部门自行新建、编辑或审核申请，或向计划暴露供应商、价格、币税字段 |
| 采购/委外订货生效 | V196 审批实例、追加式审批事件、订单状态和来源行；只有精确财务负责人通过后 `status=1` | 把草稿、待财务或驳回订货计入在途，或由其他财务/超级管理员代审 |
| 执行批次 | `production_execution_segments`；不是 `subplan_links` 自制件子计划 | 用状态按钮直接伪造段进度 |
| 生产完成与成品入库 | 审核报工、精确执行段、审核成品入库明细 | 草稿报工或通知状态增加库存 |
| 领退料与清账 | DRAW/WDRAW 单据、分轮 `issue`/验收及 V161 append-only 物料事件/posting 精确分摊 | 把 DRAW 审核当实物扣库、直接改余额、修改/删除已接受事实或用百分比容差吞差异 |
| 质量可用 | 目标为到货/回厂待检、检验结论与合格转可用；当前最小质量门尚未落地 | 把 supply peg、到货或 `COVERED` 直接当合格现货 |
| 委外供应商库存 | 目标为供应商+地点+物料/批次+所有权的发出、耗用、退回、损耗和结存账；当前未落地 | 发料即耗用，或只校验退料+损耗上限就宣称完整守恒 |
| 通知投递 | 与业务事务同提交的 `business_outbox`；READY 按执行段+收货去重并按 `SUB_PLAN`/`DEPT_PROD` 部门权限树投递 | 业务提交后尽力调用一次，或依赖已下线角色猜接收人 |
| 系统审计 | HTTP/表审计加业务语义事件，保留 before/delta/after、来源和幂等键；候选 V202 在 V196/V201 新表后重跑全部 `public` 业务表的 fail-closed sweep | 只记 URL 和 HTTP 200，或把隔离空库 V202 证据冒充目标库 V190 已升级 |

必须持续成立：

1. 同一销售订单明细的有效计划/执行分配总量不得超过审核有效需求。
2. 物理占用有效量为 `qty - consumed_qty - released_qty`，不得为负。
3. 同一需求的现货有效占用加未来供给有效分配不得超过需求量；同一供给不得超分。
4. READY 必须一次拥有完整套料；WAITING 不得占住零散现货或生成可发 DRAW。
5. 审核合格报工累计不得超过执行段计划量；关联成品入库不得超过审核合格量。
6. 清料必须满足“累计领用 = 已确认耗用 + 已验收退回 + 审批损耗/报废 + 合法在制”；差异不为零不得完成。
7. 确认、审核、取消、红冲和重试必须有稳定幂等维度；反向只恢复原动作仍有效的数量。
8. V161–V164 保护的台账、采购/委外来源、收货追溯和生产关联库存单据不得经通用 CRUD 绕过；纠错必须走可追溯专用反向。
9. 在途、待检、冻结和不合格数量不得进入当前可用库存或唤醒 READY。
10. 委外目标必须满足“累计发出 = 合格产出对应耗用 + 良/不良退回 + 审批损耗 + 供应商期末结存”。
11. `SHIPPED` 是已经交接的业务事实；无论历史行是否缺 `handed_over_at`，普通销售出货红冲都不得直接制造回库数量。
12. 财务已审核的出货在财务反审前不得编辑、删除或驳回；价格无权用户的列表/详情/导出不得泄露商业字段。
13. 新销售退货审核只进入质量冻结；仅 `GOOD_RELEASE` 可增加可售库存，`SCRAP`/`REWORK` 只记处置事实。
14. V90 `chain_status=0` 且没有有效预留的旧未结订单不得新建 V187 出货；先逐行对账后显式激活，禁止自动批量伪造预留。
15. 普通退货质检查看受销售 owner/委派范围约束；现有单退货质检 GET/POST 已复用 PMC 操作旁路，但尚无独立跨 owner 任务发现入口，不能宣称 PMC 已可端到端领取任务。直接接口仍须验证 view/handle 组合、已知 UUID 和返回投影的最小权限。
16. 计划下达的采购/委外申请在业务部门只读；订货必须逐行保留 `request_item_id`/`application_item_id`，待财务数量同样占住未分解余量。
17. 订货提交和审批必须锁来源并重新校验数量、单位和负责人；只有审批实例中的精确财务账号可以通过或驳回，默认负责人变更不偷换在途任务。
18. 实到超过财务批准剩余量时，本次审核必须在库存、订单累计和 AP 之前失败并持久化财务异常；批准追加量只绑定原收货单，仓库再审后才过账。
19. 财务未接受的数量只形成原下单人的供应商退回任务；原下单人只能确认实物退回，不能改变财务接受量。

## 3. 统一锁序与失败语义

写事务遵循“业务表头 `PESSIMISTIC_WRITE` → 上游表头/明细按类型和 UUID → 仓库/货品/颜色 `advisory lock` → 需求/占用/供给按 UUID → 累计、库存流水、Outbox、审计”的稳定顺序。陈旧版本、来源不明、混用 V0/V1 或数量不平时整体回滚；不得只重放库存或通知步骤。

## 4. 场景矩阵

| ID | 阶段 / 工作台 | 前置与动作 | 必须断言（含反向） | 当前证据 / 明确缺口 | 状态 |
|---|---|---|---|---|---|
| SC-01 | 销售草稿/审核→待计划 | 草稿保存、审核及重复审核；验证当前无独立提交端点/状态 | 草稿不占 ATP；审核只生效一次并形成订单有效预留；未排量不为负；对象范围正确；订单保存/审核不读取汇率 | 既有销售数量、币种/汇率与预留测试；真实 HTTP 同单双审、信用条件与人员范围仍需 UAT | `[PARTIAL][MANUAL]` |
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
| SC-12 | 计划采购请求卡片→采购任务 | BUY 缺料由计划链确认、重试或取消，采购查看申请/任务 | 计划一次形成可追溯只读申请和逐需求 peg；采购不能新增、编辑、审核申请；计划端看不到供应商、价格、币税；反向不误伤下游 | V199/V200、`ProductionDemandRequestReleaseTest`、`ProductionPurchaseRequestFacadeTest`、`ProductionRequestApplicantIdentityContractTest`；真实计划/采购账号 UAT 待做 | `[GREEN][MANUAL]` |
| SC-13 | 采购/委外跨申请分解订货 | 业务员跨多张申请多选行、部分分解，并选择同一供应商与仓库 | 每个订货行保留来源申请行；同单只能一个供应商/委外商和一个仓库；待财务订单也占住余量；不兼容项、超余量及并发冲突拒绝 | V199、`PurchaseRequestDecompositionPreviewTest`、`SubcontractApplicationDecompositionPreviewTest`、`PurchaseOrderPendingCapacityTest` 及 Flutter 工作台测试；真实多人并发 UAT 待做 | `[GREEN][MANUAL]` |
| SC-14 | 订货提交→精确财务审批 | 采购/委外保存订货，指定财务负责人通过或驳回，业务员修改驳回单后重提 | 保存即提交并冻结来源；只有审批实例快照中的账号且具备复核权限可处理，超级管理员无对象旁路；通过后才 `status=1` 并形成在途/未来入库；驳回不占在途 | V196、`ProcurementOrderSourceRequirementTest`、`ProcurementApprovalProjectionQueryTest`、`ProcurementRejectedOrderEditTest`、`ProcurementDocumentStateLockTest`；真实多账号越权 UAT 待做 | `[GREEN][MANUAL]` |
| SC-15 | 到货→仓库审核→待料唤醒 | 正常分批到货，或实到超过财务批准剩余量 | 正常量仓库审核后按既有链路过账；超量在库存、订单累计和 AP 前持久化异常并返回 409，财务处置后仓库须按接受量重新审核；仅质量合格且整套可占才 WAITING→READY + DRAW | V201/V202、`ProcurementArrivalWorkflowContractTest`、`ProcurementArrivalGuardPostgresTest`；当前完整 IQC 待检隔离未落地，不能把收货回写当质量合格 | `[PARTIAL][RED][MANUAL]` |
| SC-16 | 采购退货/红冲 | 已收货部分被生产占用后反向 | 已消费时阻断；先拆精确下游再反向 peg/库存；重复红冲无副作用 | V154 精确反向、V162 来源保护、V163 receipt provenance 均有定向/PG 证据；应付与全部竞态仍需回归 | `[PARTIAL][RED]` |
| SC-17 | 来料不良/补料 | 点收或领后发现不良 | 隔离、批次责任、补料引用、供应商处置可追溯 | 质量批次、隔离库、补料审批未闭环 | `[BLOCKED][MANUAL]` |
| SC-18 | 自制/采购/委外路线 | 同一缺口选择 make/buy/subcontract/transfer | BUY/SUBCONTRACT 路线互斥且数量守恒；MAKE 可派生一层真实自制子计划；未知路线 fail-closed | V158/V176 与路线测试；MAKE 父需求 supply peg、改道审批和多层反向证据仍缺，TRANSFER 未闭环 | `[PARTIAL][RED][MANUAL]` |
| SC-19 | 委外申请→订货→财务 | SUBCONTRACT 缺口由计划生成申请，委外人员跨申请部分分解并保存订货 | 申请只读且逐需求挂接；订货保留来源、单委外商/单仓；待财务占余量；只有精确财务负责人通过后才迁移为有效供给；未开工可精确反向 | V158/V196/V199/V200、`ProductionSubcontractSupplyTransitionContractTest`、`SubcontractApplicationDecompositionPreviewTest`、`SubcontractOrderMaterialAuthorityTest`；真实岗位 UAT 待做 | `[GREEN][MANUAL]` |
| SC-20 | 委外发料卡片 | 委外订单下达，仓库分批发料 | 状态来自真实发料/交接；发出转供应商处我方库存而非立即耗用；累计不超批准量 | 既有委外发料单据；供应商持有库存、备料/交接和逐需求来源未闭环 | `[PARTIAL][RED][MANUAL]` |
| SC-21 | 委外余料/损耗 | 良品退、不良退、损耗及反向 | 局部 returned+wasted 不超 issued；完整发出/耗用/退回/损耗/期末结存守恒，质量和原来源对称 | 既有数量上限；供应商结存、合同损耗、逐需求清账和质量处置仍缺 | `[PARTIAL][RED][MANUAL]` |
| SC-22 | 委外收货/退货 | 分批回厂、待检、重复回调、未开工/已消费后反向 | 回厂逐明细累计 peg；质量合格且整套才转 READY；未开工可撤回，消费后反向失败 | V158/V162 证明供给挂接/来源/反向部分；IQC、加工费、发料/余料守恒仍缺 | `[PARTIAL][RED][MANUAL]` |
| SC-23 | 仓库生产领料卡片 | READY 生成 DRAW，审核后分轮 `issue` | 工作台区分 DRAW 确认与实际发料累计；点击回真实单据；通用 CRUD 不得改生产 DRAW | V153/V164 与 Flutter 测试；无独立备料中/双方交接状态 | `[PARTIAL][MANUAL]` |
| SC-24 | 分批领料/超领/补料 | 多次领料、重复审核、申请超额 | 普通领料精确消费原占用且不重复；已接受 posting 不可改删；超领/补料必须审批 | `ProductionMaterialIssueReturnPostgresTest`、V161 append-only PG；超领/补料审批和成本仍缺 | `[PARTIAL][RED][MANUAL]` |
| SC-25 | 分批报工 | 同一段多次报工并并发提交 | 首次进入生产中；累计不超段计划；草稿不改累计 | V156、`DailyReportExecutionSegmentGuardTest`、`ProductionExecutionSegmentOperationsPostgresTest`；照片/完整工时人员未实现 | `[PARTIAL][MANUAL]` |
| SC-26 | 不良/返工/补产 | 不良率超阈值并再次报工 | 原因必填；补产只生成一次；通知去重；不掩盖原数量 | 基础数量守卫已有；质量原因、阈值、返工/补产审批未闭环 | `[BLOCKED][MANUAL]` |
| SC-27 | 成品入库 | 多次报工、合并销售来源、内部计划 | 每条精确销售分摊不超其审核合格余量；来源不明 fail-closed；内部计划不伪造销售 | V157 `ExecutionSegmentSalesAllocationPostgresTest` 已纳入组合回归证据并覆盖笛卡尔泄漏、报工/入库上限；历史迁移仍待 | `[PARTIAL][RED]` |
| SC-28 | 余料退库与清账 | 良品余料、多次退料、消耗/审批损耗/合法在制后结案 | 最大可退实时计算；验收后回库存；领用=消耗+退回+审批损耗+合法在制；红冲对称且原事实不可篡改 | V152 round-trip/并发 PG 与 V161 append-only 覆盖消耗、良退、审批损耗和合法在制；不良品实物处置与成本仍缺 | `[PARTIAL][MANUAL]` |
| SC-29 | 销售进度/通知 | 排产、开工、部分完成、完工、缺料、延期 | 主事务和 `business_outbox` 同提交；同事件一次；READY 按部门范围投递；销售订单行只显示自身执行段及公开数量 | V151/V157、`ChainNoticeReadyEventTest` publishOnce/dedupe、PG 状态迁移、部门映射源码和销售进度 UI；对象范围黑盒和部署 SLO 未验收 | `[PARTIAL][RED][MANUAL]` |
| SC-30 | 发货交接与受控反向 | 新旧销售出货进入 `SHIPPED` 后尝试普通红冲；完成成品入库再红冲 | 所有 `SHIPPED` 均拒绝普通红冲，即使历史缺交接时间；完成生产段须先显式重开，失败全回滚 | `SalesShipmentReverseGuardTest`、`SalesShipmentWarehouseTransitionPolicyTest`、`ProductionCompletionReversePostgresTest`；退货入库另见 SC-40 | `[GREEN][MANUAL]` |
| SC-31 | 权限、对象范围、审计 | 六部门越权读写、批量部分越权、退货质检普通查看/PMC 跨 owner 任务发现与处置、handle-only、已知 UUID 直调、查数量变化 | 最小权限；普通查看按 owner/委派过滤；跨 owner 任务须有独立最小投影入口并验证 view/handle 组合，不能靠已知 UUID 绕过发现与查看权限；批量全有或全无；审计可看脱敏 before/after 和幂等来源 | `SalesReturnQualityOwnerBoundaryTest` 只覆盖 Service 调用对象策略的结构契约；独立任务入口、真实 API 多账号权限矩阵、handle-only 负向、Widget 深链和语义覆盖率均未验收 | `[PARTIAL][RED][MANUAL]` |
| SC-32 | 历史迁移、对账、死锁恢复 | 公司目标库 V238 向当前源码 V246 升级，构造中断和反锁序 | 历史先快照/隔离再补链；升级前后零差异；死锁整事务回滚并幂等重试；已执行 Flyway 不改原文件 | 早期空库 V202 与当前隔离非空克隆 V244 证据均仅是阶段快照；公司目标库 V239–V246 真迁移、历史快照、恢复、压力和回滚演练未完成 | `[PARTIAL][RED][MANUAL]` |
| SC-33 | 生产/销售多入口子计划导航 | 点击执行分段、生成结果、销售进度、生产看板真实子计划 | 执行段通过 parentPlanId + `executionSegmentId` 在父计划内开一次详情；真实子计划进 childPlanId；权限/无效链接有反馈；计划切换无旧状态 | 三份新增 Widget 测试与相关 33 项回归通过；登录态浏览器 UAT 未执行 | `[GREEN][MANUAL]` |
| SC-34 | 现货预留与整单发运策略 | 多品项一项现货、其余长周期；两仓各有余额；部分从 A 仓交接；尝试给 V90 未激活旧单新建出货 | 全局 ATP 为各有货仓分别扣安全库存后的可售容量之和再扣有效预留；按 `ALLOW_PARTIAL/REQUIRE_COMPLETE/CUSTOMER_CONFIRM` 决定；只把本次消耗段绑定 A 仓，剩余仍可由 B 仓履约；旧单在逐行对账并显式激活前提前 fail-closed；不自动抢占/造预留 | V90/V178/V187、`StockReservationWarehouseSplitTest` 与销售安全库存/历史激活守卫测试已有；自动调拨、完整 WMS、目标 PG/历史对账/岗位 UAT仍缺 | `[PARTIAL][RED][MANUAL]` |
| SC-35 | 采购/委外质量门 | 到货/回厂分批待检、合格、不合格、特采、反向 | 待检不进可用/不唤醒；只有合格结论参与整套；反向保持来源和质量事实 | 完整 IQC/隔离/特采状态未落地 | `[BLOCKED][RED][MANUAL]` |
| SC-36 | 委外供应商库存守恒 | 分批发料、耗用、良/不良退料、损耗、期末对账 | 按供应商/地点/物料/批次/所有权守恒；差异有责任与版本化合同 | 供应商持有库存/在制实体和逐需求清账未落地 | `[BLOCKED][RED][MANUAL]` |
| SC-37 | MAKE 子计划供给父需求 | V176 子计划生成、确认自己的包、尝试通用删除/红冲，再完工/入库、改量、取消 | 派生子计划登记为父包 `SUBPLAN` 单据；通用删除/红冲 fail-closed；父包不能越过子计划自己的已确认包；最终仍须由 supply peg 证明子产出回供父需求且反向守恒 | `ProductionMakeSubplanLifecycleContractTest` 已覆盖登记和生命周期防孤儿；父需求↔子计划明细↔`FINISHED_IN` peg/唤醒/反向仍缺 | `[PARTIAL][RED]` |
| SC-38 | 销售商业事实、财务锁与脱敏 | 客户端篡改价格/汇率/原本币金额/成本/币税条件，分批出货，`finance_audit=1` 后再编辑/删除/驳回，无价格权查看 | 订单原币额=qty×price×discount，订单不形成新本币事实；出货按来源原币金额和数量比例计额，`SHIPPED` 才锁财务汇率形成发运/AR 本币；不兼容条件拒绝合单；财务已审先反审才可变；无权商业字段为空 | 商业权威/出货/状态测试已有；正式价目、折扣/税额最终结算及多次分批舍入尾差 condition/invoice 引擎仍缺 | `[PARTIAL][RED][MANUAL]` |
| SC-39 | 聚合工作台、财务任务与对象权限 | 计划、采购、委外、财务、仓库及原下单人分别登录并深链 | `department+actionDocType` 精确映射；采购/委外只能看只读申请并分解订货；财务任务只投递审批实例快照账号；仓库看未来入库/异常；退回任务只投递原下单人；无权列表和已知 UUID 直调均拒绝 | `FulfillmentWorkbenchAccessPolicyTest`、`ProcurementApprovalProjectionQueryTest`、Flutter 财务/仓库/订货工作台测试；真实多账号 HTTP/浏览器对象范围 UAT 未完成 | `[GREEN][MANUAL]` |
| SC-40 | 销售退货冻结、需求重开与客户处置 | 新退货审核、分批良品释放/报废/返工、未处置/处置后红冲；客户选择退款/换货/补发/维修；误判处置 | 审核不改可售库存，但重开替换需求并清空旧确认；不直接加预留；仅 `GOOD_RELEASE` 入库；事件不可改删；V220 客户处置经审批并写追加式事件；处置后整单红冲阻断，纠错须追加补偿而非改历史 | V189 覆盖冻结/三类质量处置，V220 已落 `customer_disposition`、审批和追加式事件；仍缺处置级复核纠错/补偿命令、历史对账、完整 RMA/QMS 与岗位 UAT | `[PARTIAL][RED][MANUAL]` |
| SC-41 | 财务订货审批越权（审核组） | 财务部门持权者 A/B、非财务持权者、不在财务部门的超管分别尝试审批 | 财务部门树内持 `finance_order_approval:review` 的任一员工可通过/驳回（互为备份）；非财务持权者与不在财务部门的超管被服务层资格判定拒绝；乐观锁防并发双审；任务对所有持 view 权限财务人员可见；处理追加事件且幂等 | V229/ADR-027 审批投影与契约测试；真实多账号正反向 UAT 未完成 | `[GREEN][MANUAL]` |
| SC-42 | 订 10、实到 100 超量处置 | 仓库登记 100，财务分别拒绝超量、自定义追加 5、批准全部 | 首次仓库审核返回专用 409 且库存/订单累计/AP 均未动；三种结果分别为入库/退回 `10/90`、`15/85`、`100/0`；全收/自定义必填原因；追加量仅原收货可用，仓库再审后才过账 | V201/V202、`ProcurementArrivalWorkflowContractTest`、`ProcurementArrivalGuardPostgresTest` 2/2；三岗位实物演练未完成 | `[GREEN][MANUAL]` |
| SC-43 | 未接受数量供应商退回 | 财务处置后原采购/委外下单人领取退回任务并确认实物退回 | 任务按原订单创建人精确归属；其他人和管理员对象旁路失败；确认人只能记录退回，不得修改财务接受量；数量和原因可审计 | V201/V202 与到货工作流契约测试；供应商签收、运输损耗及线下责任 UAT 未完成 | `[PARTIAL][MANUAL]` |
| SC-44 | 销售出货→正式 AR→分批收款→总账 | 外币订单无汇率审核、现金客户财务放行、出货草稿篡改本币、缺开账汇率交接、分批 SHIPPED、收款缺/错到账汇率、同人审核、部分/超额/跨币核销、红冲后重跑期间 | 订单与待收计划只保留币种/原币；财务放行不写汇率或 AR；出货草稿本币为空；`SHIPPED` 原子扣库存/消费预留/回写订单并按财务开账汇率立正式 AR；收款逐行显式到账汇率且制审分离，服务端重算本币/汇兑并同事务更新 AR、账户、流水；GL 按期间从现行审核事实重建且平衡 | `SalesOrderExchangeRateAuthorityTest`、`SalesShipmentFinanceRatePolicyTest`、`FinanceReceiptSettlementTest`、`GlPostingServiceReceiptAccountingTest` 已覆盖定向契约；目标 PostgreSQL 真实 HTTP、历史空币种整链修复/对账和销售/仓库/财务多岗位 UAT 未完成 | `[PARTIAL][RED][MANUAL]` |

## 5. 发布闸门

1. `PLANNING_WRITE_READY` 或等价灰度开关只能在迁移/对账、规划确认与反向、库存/采购/委外分配、权限和语义审计同版本验收后开启。
2. SC-04、SC-05、SC-09、SC-10、SC-15 至 SC-44 中标记的 `[RED]`/`[BLOCKED]`/`[MANUAL]` 必须按范围关闭或继续 fail-closed。
3. 默认测试、`UTEN_RUN_DB_TESTS=true` 的真实 PostgreSQL 测试、Flutter 测试/analyze、迁移回放、人工 UAT、容量、备份恢复和告警演练全部通过。
4. 仓库、采购、委外卡片的状态必须来自审核单据；“已领取/已收货/已完成”不得由界面直接改状态。
5. V150–V246 源码存在、空库/隔离克隆迁移成功或定向测试通过，均不能替代公司目标库 V238→V246 升级、历史数据快照/对账、真实岗位 UAT、实物退回演练和负责人签字；当前仍是生产 `NO-GO`。

## 6. 建议执行命令

结构与纯单元：

```powershell
cd server
mvn.cmd -q -Dtest=BusinessChainScenarioMatrixTest,ArchitectureBoundaryTest,CompleteKitAllocatorTest,ProductionPlanningPackageServiceTest,DailyReportExecutionSegmentGuardTest,AuditQueryServiceTest,ProductionMaterialAppendOnlyLedgerMigrationTest,ProductionSupplySourceGuardMigrationTest,ProductionSupplySourceGuardTest,ProductionPurchaseReceiptProvenanceMigrationTest,ProductionLinkedStockDocumentGuardMigrationTest,ProductionLinkedStockDocumentServiceContractTest,ChainNoticeReadyEventTest test
mvn.cmd -q -Dtest=ProductionExecutionPlanningServiceSupplyRouteTest,ProductionSubcontractSupplyTransitionContractTest,ProductionSubcontractSupplyTransitionMigrationTest test
mvn.cmd -q -Dtest=SalesOrderCommercialAuthorityTest,SalesShipmentOwnerBoundaryTest,SalesShipmentWarehouseTransitionPolicyTest,SalesShipmentReverseGuardTest,StockReservationWarehouseSplitTest,SalesShipmentWarehouseEventMigrationContractTest,SalesReturnQualityServiceTest,SalesReturnQualityOwnerBoundaryTest,SalesReturnQualityQuarantineMigrationContractTest,FulfillmentWorkbenchAccessPolicyTest,ProductionMakeSubplanLifecycleContractTest,AuditTriggerCoverageMigrationContractTest test
mvn.cmd -q -Dtest=SalesOrderExchangeRateAuthorityTest,SalesShipmentFinanceRatePolicyTest,FinanceReceiptSettlementTest,GlPostingServiceReceiptAccountingTest test
mvn.cmd -q -Dtest=ProductionDemandRequestReleaseTest,ProductionRequestApplicantIdentityContractTest,DemandDecompositionControllerContractTest,PurchaseRequestDecompositionPreviewTest,SubcontractApplicationDecompositionPreviewTest,PurchaseOrderPendingCapacityTest,ProcurementOrderSourceRequirementTest,ProcurementApprovalProjectionQueryTest,ProcurementRejectedOrderEditTest,ProcurementArrivalWorkflowContractTest test
```

真实 PostgreSQL 核心链：

```powershell
cd server
$env:UTEN_RUN_DB_TESTS='true'
mvn.cmd -q -Dtest=InventoryTransactionalIntegrityPostgresTest,StockReservationSalesCompatibilityPostgresTest,ProcurementDocumentStateLockPostgresTest,ReportablePlanLinePostgresTest,ProductionMaterialFulfillmentPostgresTest,ProductionExecutionSegmentPostgresTest,ExecutionSegmentSalesAllocationPostgresTest,ProductionPurchaseSupplyTransitionPostgresTest,ProductionMaterialIssueReturnPostgresTest,ProductionExecutionSegmentOperationsPostgresTest,ProductionCompletionReversePostgresTest,BusinessOutboxPostgresTest,FulfillmentWorkbenchProvisionalStockPostgresTest,ProductionMaterialAppendOnlyLedgerPostgresTest,ProductionPurchaseReceiptProvenancePostgresTest,ProductionLinkedStockDocumentGuardPostgresTest,ProcurementArrivalGuardPostgresTest test
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

2026-07-31 历史组合结果：后端 343 tests、0 failure/error、48 skipped（PG 默认跳过）；真实 PostgreSQL 16 classes / 44 tests、0 failure/error/skip，空库 146 个迁移到 V165；Flutter 157/157，`flutter analyze --no-pub` 无问题，Web Release 构建成功。

2026-08-01 中间候选证据：隔离 Testcontainers PostgreSQL 16.14 从空库成功迁移并 Flyway validate 171 个迁移至 V190；18 组真实 PG 测试 54/54、定向 JVM 56/56、Java 默认套件 589 项（0 failure/error、54 skipped）、Flutter 全量 278/278 通过。本次链路 Dart 定向分析为 0；全仓分析另有 10 条并行基础资料 warning/info、无 error。该证据只保留为中间历史，不是最终候选或 UAT 结果。

文档收口后又在隔离构建目录补跑退货质检 Service 与 owner 边界测试 5/5，以及场景矩阵契约 2/2。前者只证明 Service 会调用带操作旁路的对象策略及三项处置纯函数契约，不证明独立跨 owner 任务发现、真实方法鉴权或多账号端到端已经完成；后者覆盖 40 个场景编号和核心门禁完整性。这是聚焦增量证据，不把前述 589 项历史全量数字擅自改写成新的全量结果。

2026-08-01 最终候选工程证据：Flutter analyze 0 issue、全量 306/306，Web JavaScript 与 Windows x64 Release 构建成功；Java 默认套件 611 项（0 failure/error、58 skipped），PostgreSQL 16.14 / Docker 29.5.3 专项 19 类 58/58（0 failure/error/skip），Flyway validate 171 个迁移并到 V190，后端 JAR 打包成功。新增的退货质检 PG 链覆盖首次处置/精确重放、同键异载荷冲突、并发只过账一次，以及库存流水、余额、投影写入后末端事件失败的整事务回滚。Web Wasm、公司目标库升级、历史全量对账、真实账号岗位 UAT、压测、备份恢复、签名与生产放行仍未通过。

2026-08-02 采购/委外财务与超量到货候选证据：后端默认套件 221 类、775 项（0 failure/error、70 skipped，实际执行 705 项）；Flutter 全量 438/438；隔离 PostgreSQL 16.14 从空库回放 183 个迁移至 V202，`ProcurementArrivalGuardPostgresTest` 2/2，并证明 INSERT 路径不读取 `OLD`、未批准超量 fail-closed、追加量绑定原收货。公司目标库只读证据仍停在 V190；V196–V202、真实多账号岗位、实物仓储/退回、完整 IQC 和发布签字均未验收，因此仍为生产 `NO-GO`。
