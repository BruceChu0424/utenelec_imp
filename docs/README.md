# 文档索引

[准则索引与开发清单](00-项目准则/00-准则索引与开发清单.md)是开发起点。本页帮助从业务规则找到页面、服务、迁移和测试，不另维护当前版本或通过数量。

当前范围与未完成事项见[全平台审计计划](01-规划/2026-09-07-全平台业务链审计与整改计划.md)，最新结果见[本地审计与整改验收](99-项目治理/2026-09-07-全平台本地审计与整改验收.md)，执行顺序见[串行收口](99-项目治理/2026-09-07-执行纠偏与串行收口.md)。接手业务改动先读[续作指引](07-业务链路/03-续作指引.md)。

## 业务到实现

表中服务是实际源码入口，方法与验证范围以源码及专题为准；迁移号表示规则来源，不是当前数据库安装版本。后端综合场景集中在 [FullChainEndToEndTest](../server/src/test/java/com/uten/imp/businesschain/FullChainEndToEndTest.java)，专项和真实HTTP结果在统一验收中区分记录。

| 业务规则 | 页面 | 服务函数 | 迁移与测试 |
|---|---|---|---|
| [销售订货到发货SOP](07-业务链路/01-销售订货到发货全链路-SOP.md)；[财审租约](99-项目治理/2026-09-07-财务审核租约与订单互斥.md) | [销售订单财务审核](03-页面/销售订单财务审核页.md)、[客户零星发货](03-页面/客户零星发货与出货财务审核.md)、[仓库发货](03-页面/销售出货仓库作业页.md) | SalesOrderService 的审核/改量、SalesOrderFinanceConfirmService 的认领/决策、SalesShipmentService 的财审/仓库动作 | [V492修改复核](数据迁移/108-V492销售订单完整修改与财务版本复核.md)、[V511统一发货](数据迁移/125-V511客户零星发货统一流程.md)；[场景矩阵](07-业务链路/2026-09-07-销售资金库存场景矩阵与压力验收.md) |
| [排产与执行需求](07-业务链路/04-生产订单排产与执行全链路需求.md)、[预留生命周期](07-业务链路/05-销售现货预留生命周期与稀缺仲裁.md) | [物料分析](03-页面/生产物料分析页.md)、[履约工作台](03-页面/生产履约任务工作台.md)、[我的车间任务](03-页面/我的车间任务页.md) | [MaterialAnalysisService.refreshLocked](../server/src/main/java/com/uten/imp/features/production/analysis/MaterialAnalysisService.java)、MaterialAnalysisCommandService、MaterialAnalysisRootSupplyService | [ADR-073本批履约](99-决策记录-ADR/ADR-073-本批物料履约与同主仓分仓领料.md)；[PlanningEligibilityTest](../server/src/test/java/com/uten/imp/features/production/analysis/MaterialAnalysisPlanningEligibilityTest.java)、FullChain |
| [采购/委外到货与退换货](99-项目治理/采购与委外到货退换货实现与验收.md)、[委外SOP](07-业务链路/08-委外全链路-订货出仓回仓重设计.md) | [到货登记](03-页面/仓库到货登记页.md)、[IQC合格待入库](03-页面/采购委外IQC合格待入库任务页.md)、[应付结算](03-页面/采购委外应付结算工作台.md) | ProcurementReceiptConsiderationService.freezeReceipt/freezeQuality/settleStockIn、ProcurementIqcRejectionService.previewCredit/confirmCredit/reverse | V518+V519；[ProcurementConsiderationMigrationPostgresTest](../server/src/test/java/com/uten/imp/migration/ProcurementConsiderationMigrationPostgresTest.java)、IQC Widget、FullChain；链接在专题内 |
| [实际库存成本与在制](99-项目治理/库存实际成本接线与验收.md) | [出入库记录](03-页面/出入库记录页.md)、[生产执行与报工](03-页面/生产执行分段与报工页.md)、[产成品点收](03-页面/产成品待点收任务页.md) | StockService→StockValuationCoordinator.value；ProductionInventoryValueService.settled/refresh；InventoryValueWorkService.runBatch | V506/V514/V517/V521–V527；[精度复核](99-项目治理/2026-09-07-库存成本账内精度与精确份额复核.md)、[守恒压力矩阵](99-项目治理/2026-09-07-生产链逐步守恒与压力测试矩阵.md) |
| [销售退货品质与处置](07-业务链路/06-销售退货质检冻结与处置.md) | [销售退货品质页](03-页面/销售退货质检冻结处置页.md) | SalesReturnService.approve、SalesReturnQualityService、SalesReturnInventoryValueService.qualityEventRecorded | 原发货UUID/品质事件/真实成本来源；FullChain及成本专题中的分支证据 |
| [实际金额与精确分摊](07-业务链路/2026-09-07-财务原始金额与精确分摊口径.md) | [财务表单源码](../lib/features/finance/pages/finance_doc_edit_page.dart)、[财务详情](../lib/features/finance/pages/finance_doc_detail_page.dart) | FinancialExactAmount、ProcurementCreditBookAllocationService.plan/applyOffset、FinanceReceiptService、FinancePaymentService、CustomerPrepaymentOffsetService | V519/V520/V523；[银行/Book/Exact专项](99-项目治理/2026-09-07-V519-V520-V523财务实际金额与银行链验收交接.md)。客户现金退款另见[工作包](07-业务链路/2026-09-07-客户现金退款工作包方案.md)，不能把负AR当现金退款 |

## 按文档职责查找

| 内容 | 入口和边界 |
|---|---|
| 全局规范 | [00-项目准则](00-项目准则/00-准则索引与开发清单.md)：命名、组件、权限、安全、性能和交付规则。 |
| 规划与范围 | [01-规划](01-规划)：愿景、取舍及当前整改计划。 |
| 公共组件 | [组件总览](02-组件库/组件总览.md)：共享行为和组件使用合同。 |
| 页面与岗位操作 | [页面总览](03-页面/页面总览.md)：入口、字段、权限、动作与错误反馈。 |
| 数据模型、架构和决策 | [04-数据模型](04-数据模型)、[05-架构](05-架构)、[ADR索引](99-决策记录-ADR/README.md)。正式ADR保留决策背景，前向变更不能靠改旧决策原文伪造历史。 |
| 迁移和历史兼容 | [数据迁移索引](数据迁移/README.md)、[正式SQL](../server/src/main/resources/db/migration)。旧阶段版本号不能用于猜当前目标库版本，已应用SQL不改字节。 |
| 本轮专项证据 | [统一验收](99-项目治理/2026-09-07-全平台本地审计与整改验收.md)及其专题索引。测试日志按原目录、候选、时间及限制解释。 |
| 发布和运维 | [部署运行手册](../deploy/simple/RUNBOOK.zh-CN.md)、[多端签名](99-项目治理/多端发布与签名.md)、[首装指引](99-项目治理/2026-09-01-新库上线与首装操作指引.md)。 |

更新时直接修改所属规则或专题，删除被完整替代的续作段并更新引用。历史报告只解释对应版本；不要在多份文档顶部重复叠加“最高优先”“当前全绿”或服务器状态。
