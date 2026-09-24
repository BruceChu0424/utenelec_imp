# 文档索引

[准则索引与开发清单](00-项目准则/00-准则索引与开发清单.md)是开发起点。本页帮助从业务规则找到页面、服务、迁移和测试，不另维护当前版本或通过数量。

**当前状态(v2.0.1, 迁移头 V688)与后续工作**见[全平台整改交接总览](99-项目治理/全平台整改交接/01-交接总览.md)(含 239 条审计发现、后续工作流任务书、编排与验收方法、重构后验证清单)。历史候选与发布证据见[当前版本验证与交付](99-项目治理/当前版本验证.md)。接手业务改动先读[续作指引](07-业务链路/03-续作指引.md)，再按下表定位规则、实现和测试。历史审计报告保留原候选与时间，不作为当前通过结论。

## 业务到实现

表中服务是实际源码入口，方法与验证范围以源码及专题为准；迁移号表示规则来源，不是当前数据库安装版本。后端综合场景集中在 [FullChainEndToEndTest](../server/src/test/java/com/uten/imp/businesschain/FullChainEndToEndTest.java)，专项和真实HTTP结果在统一验收中区分记录。

| 业务规则 | 页面 | 服务函数 | 迁移与测试 |
|---|---|---|---|
| [全平台机制(第一阶段整改)](99-项目治理/全平台整改交接/01-交接总览.md): [审计三清单](99-决策记录-ADR/ADR-105-审计白名单行级审计与分区留存.md)、[触发器与索引](99-决策记录-ADR/ADR-106-热表触发器按相关列起跳与索引卫生.md)、[预锁与截止时间](99-决策记录-ADR/ADR-107-履约预锁一轮发现与服务端截止时间.md)、[徽章汇总](99-决策记录-ADR/ADR-108-前端性能徽章汇总会话快照与刷新时机.md)、[权限目录](99-决策记录-ADR/ADR-109-权限目录单一事实源与授权策略.md)、[会话与再认证](99-决策记录-ADR/ADR-110-服务端会话与敏感操作再认证.md)、[主档引用保护](99-决策记录-ADR/ADR-111-主档删除引用保护与批量原子命令.md)、[金额口径](99-决策记录-ADR/ADR-112-金额口径统一与资金过账单一入口.md) | 工作台与各 hub、权限管理、系统设置、审计查询 | FulfillmentMutationLocks、AuditService、PermissionGrantPolicyCatalog、AuthSessionService、MasterReferenceCatalog、MoneyPolicy、WorkbenchBadgeService | V670–V687；FullChain 160 场景、AuditTriggerCoverage*、MasterReferenceCatalogCoverageTest、WorkbenchBadgeSummaryPostgresTest |
| [委外损耗独立结清, 不改订货量](99-决策记录-ADR/ADR-114-委外损耗独立结清不改订货量.md)、[委外子件精确库存交接](99-决策记录-ADR/ADR-113-委外子件精确库存归属交接.md) | [委外回厂短交判定](03-页面/委外回厂短交判定页.md)、委外 hub 与订货单 | SubcontractOrderService、SubcontractLossSettlementSql、ProcurementArrivalControlService、StockService | [V688](数据迁移/234-V688委外损耗独立履约结清.md)、[V646](数据迁移/231-V646委外子件精确库存交接.md)；SubcontractShortDelivery/ToleranceAutoSettle/ComponentReturnLeg 等 E2E |
| [未领料自制追加到原工单](99-决策记录-ADR/ADR-104-追加自制并入未开工的生产计划.md) | [物料分析](03-页面/生产物料分析页.md)、[我的车间任务](03-页面/我的车间任务页.md) | MaterialAnalysisCommandService.growPlan、ProductionExecutionPackageCommandService.growSegment、ProductionExecutionReadinessService | [V647](数据迁移/232-V647未领料车间工单原位追加.md)；[本轮专项验收](99-项目治理/2026-09-23-自制追加原车间工单验收.md) |
| [车间路线与供料场景](07-业务链路/车间任务路线与供料场景矩阵.md)、[计量与来源守恒](07-业务链路/生产计量与来源守恒.md) | [我的车间任务](03-页面/我的车间任务页.md) | ProductionExecutionSegmentService、ProductionExecutionReadinessService、ProductionDailyReportService、ProductionWorkshopDirectTransferService | V609–V616；[并行对抗验证](99-项目治理/2026-09-19-车间全链路并行对抗验证.md) |
| [销售订货到发货SOP](07-业务链路/01-销售订货到发货全链路-SOP.md)；[财审租约](99-项目治理/2026-09-07-财务审核租约与订单互斥.md) | [销售订单财务审核](03-页面/销售订单财务审核页.md)、[客户零星发货](03-页面/客户零星发货与出货财务审核.md)、[仓库发货](03-页面/销售出货仓库作业页.md) | SalesOrderService 的审核/改量、SalesOrderFinanceConfirmService 的认领/决策、SalesShipmentService 的财审/仓库动作 | [V492修改复核](数据迁移/108-V492销售订单完整修改与财务版本复核.md)、[V511统一发货](数据迁移/125-V511客户零星发货统一流程.md)；[场景矩阵](07-业务链路/2026-09-07-销售资金库存场景矩阵与压力验收.md) |
| [排产与执行需求](07-业务链路/04-生产订单排产与执行全链路需求.md)、[预留生命周期](07-业务链路/05-销售现货预留生命周期与稀缺仲裁.md) | [物料分析](03-页面/生产物料分析页.md)、[履约工作台](03-页面/生产履约任务工作台.md)、[我的车间任务](03-页面/我的车间任务页.md) | [MaterialAnalysisService.refreshLocked](../server/src/main/java/com/uten/imp/features/production/analysis/MaterialAnalysisService.java)、MaterialAnalysisCommandService、MaterialAnalysisRootSupplyService | [ADR-073本批履约](99-决策记录-ADR/ADR-073-本批物料履约与同主仓分仓领料.md)；[PlanningEligibilityTest](../server/src/test/java/com/uten/imp/features/production/analysis/MaterialAnalysisPlanningEligibilityTest.java)、FullChain |
| [分批生产、物料调度与销售出货](99-项目治理/2026-09-12-车间分批领退料本地验收.md) | [物料分析](03-页面/生产物料分析页.md)、[车间任务](03-页面/我的车间任务页.md)、[产品进度与发货](03-页面/销售订单进度详情页.md)、[仓库枢纽](03-页面/仓库管理枢纽页.md) | ProductionExecutionBatchService、ProductionDrawRequestService、PreplanFutureSupplyTransferService、SalesShipmentBatchAllocation | [逐行领料](数据迁移/160-V564逐行分批领料申请数量.md)、[实仓拣货](数据迁移/162-V566销售无仓提交与仓库实仓拣货.md)、[补自制](数据迁移/164-V568让料后的自制补供责任.md)、[在途归属](数据迁移/165-V569在途供给归属调整.md)；真实PG及Flutter证据按专题范围解释 |
| [采购/委外到货与退换货](99-项目治理/采购与委外到货退换货实现与验收.md)、[委外SOP](07-业务链路/08-委外全链路-订货出仓回仓重设计.md) | [到货登记](03-页面/仓库到货登记页.md)、[IQC合格待入库](03-页面/采购委外IQC合格待入库任务页.md)、[应付结算](03-页面/采购委外应付结算工作台.md) | ProcurementReceiptConsiderationService.freezeReceipt/freezeQuality/settleStockIn、ProcurementIqcRejectionService.previewCredit/confirmCredit/reverse | V518+V519；[ProcurementConsiderationMigrationPostgresTest](../server/src/test/java/com/uten/imp/migration/ProcurementConsiderationMigrationPostgresTest.java)、IQC Widget、FullChain；链接在专题内 |
| [实际库存成本与在制](99-项目治理/库存实际成本接线与验收.md) | [出入库记录](03-页面/出入库记录页.md)、[生产执行与报工](03-页面/生产执行分段与报工页.md)、[产成品点收](03-页面/产成品待点收任务页.md) | StockService→StockValuationCoordinator.value；ProductionInventoryValueService.settled/refresh；InventoryValueWorkService.runBatch | V506/V514/V517/V521–V527；[精度复核](99-项目治理/2026-09-07-库存成本账内精度与精确份额复核.md)、[守恒压力矩阵](99-项目治理/2026-09-07-生产链逐步守恒与压力测试矩阵.md) |
| [销售退货品质与处置](07-业务链路/06-销售退货质检冻结与处置.md) | [销售退货品质页](03-页面/销售退货质检冻结处置页.md) | SalesReturnService.approve、SalesReturnQualityService、SalesReturnInventoryValueService.qualityEventRecorded | 原发货UUID/品质事件/真实成本来源；FullChain及成本专题中的分支证据 |
| [实际金额与精确分摊](07-业务链路/2026-09-07-财务原始金额与精确分摊口径.md) | [钱流单据](03-页面/钱流单据页.md)、[财务表单源码](../lib/features/finance/pages/finance_doc_edit_page.dart)、[财务详情](../lib/features/finance/pages/finance_doc_detail_page.dart) | FinancialExactAmount、ProcurementCreditBookAllocationService.plan/applyOffset、FinanceReceiptService、FinancePaymentService、CustomerPrepaymentOffsetService | V519/V520/V523；[银行/Book/Exact专项](99-项目治理/2026-09-07-V519-V520-V523财务实际金额与银行链验收交接.md)。客户现金退款另见[工作包](07-业务链路/2026-09-07-客户现金退款工作包方案.md)，不能把负AR当现金退款 |
| [员工报销 SOP](07-业务链路/员工报销全链路-SOP.md)、[合规依据与凭证清单](07-业务链路/员工报销合规依据与凭证清单.md) | [我的报销](03-页面/报销列表页.md)、[新建/编辑](03-页面/新建报销页.md)、[报销详情](03-页面/报销详情页.md)、[报销审批](03-页面/报销审批列表页.md) | ExpenseClaimService 的 create/edit/submit/approve(Batch)/pay、InvoiceRecognitionService | [ADR-094](99-决策记录-ADR/ADR-094-报销链路完整化.md)、[V608](数据迁移/198-V608报销链路完整化.md)；[本轮验收矩阵](99-项目治理/2026-09-19-员工报销全链路验收.md)，测试、部署与岗位验收分别记录 |

## 按文档职责查找

| 内容 | 入口和边界 |
|---|---|
| 全局规范 | [00-项目准则](00-项目准则/00-准则索引与开发清单.md)：命名、组件、权限、安全、性能和交付规则。 |
| 规划与范围 | [01-规划](01-规划)：愿景、取舍及当前整改计划。 |
| 公共组件 | [组件总览](02-组件库/组件总览.md)：共享行为和组件使用合同。 |
| 页面与岗位操作 | [页面总览](03-页面/页面总览.md)：入口、字段、权限、动作与错误反馈。 |
| 数据模型、架构和决策 | [04-数据模型](04-数据模型)、[05-架构](05-架构)、[ADR索引](99-决策记录-ADR/README.md)。正式ADR保留决策背景，前向变更不能靠改旧决策原文伪造历史。 |
| 迁移和历史兼容 | [数据迁移索引](数据迁移/README.md)、[正式SQL](../server/src/main/resources/db/migration)。旧阶段版本号不能用于猜当前目标库版本，已应用SQL不改字节。 |
| 本轮专项证据 | [性能与稳定性统一验收](99-项目治理/2026-09-12-全站性能与稳定性验收.md)及其物料、仓库、设置专题。测试日志按原目录、候选、时间及限制解释。 |
| 发布和运维 | [部署运行手册](../deploy/simple/RUNBOOK.zh-CN.md)(服务器上只用更新器迁移, 演练在开发机库副本上做)、[版本号规则（语义化，2026-09-18 起）](../README.md#版本号规则)、[多端签名](99-项目治理/多端发布与签名.md)、[首装指引](99-项目治理/2026-09-01-新库上线与首装操作指引.md)。 |

更新时直接修改所属规则或专题，删除被完整替代的续作段并更新引用。历史报告只解释对应版本；不要在多份文档顶部重复叠加“最高优先”“当前全绿”或服务器状态。
