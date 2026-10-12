# 平台业务守恒与独立下单检查矩阵

复核日期：2026-10-11。范围是当前源码、迁移基线、隔离 PostgreSQL 回归与页面入口；不包含公司业务数据库写入、部署或岗位实物验收。旧 `business-chain-scenario-matrix.md` 的 V430 与 2026-08-30 标记仅作历史记录，不能判断当前功能是否已实现。

本文列出**待本轮执行和核对的用例**。用例存在、编译通过、聚焦回归通过、完整测试通过和真实账号 UAT 是不同证据；本轮测试汇总和原始 Surefire/Failsafe XML 决定执行结果，本文不把源码清单当作通过结果。2026-10-11 初次发现的 businesschain 测试为 150 个类、1072 个 `@Test`；新增独立下单类后应重新发现，不把这个快照当作最终测试分母。

| 场景 | 权威事实与必须成立的结果 | 当前可执行回归 | 仍需核对 |
|---|---|---|---|
| 销售→财务接受→计划→采购/委外→品质→仓库→发货→收款 | 销售 UUID、计划分摊、库存流水、AR/AP、收款核销和 GL 同源；每阶段只计实际生效量 | `FullChainEndToEndTest`：`planner_createDraftAndApprove_writesPlannedQtyAndPegsOrder`、`shipment_fullShip_consumesReservationPostsArAndClosesOrder`、`salesCashCycle_partialShipAdvanceSettlementReturnQualityAndOrderedReversalsReconcile` | 全类执行、真实部门账号 HTTP 和页面流转 |
| 独立计划与物料分析生成计划 | 无销售单也有可执行计划；数量、单位、允许超产默认值相同；各自预留与撤销不互相影响 | `StandaloneDepartmentLifecycleConservationEndToEndTest#manualAndGeneratedPlansShareDefaultsAndReleaseOnlyTheirOwnExactMaterialReservations` | 默认日期、车间、班组和表头/字段页面一致性 |
| 独立计划小数边界 | NULL、0、负数、5 位有效小数和 14 位整数溢出不得落库；后行失败整单回滚 | `StandaloneDepartmentLifecycleConservationEndToEndTest#independentPlanRejectsLossyQuantityAndInvalidBatchWithoutPersistingAnyDocument` | 当前修复前可由 `1.00005` 触发 PostgreSQL 隐式舍入；修复后须保留 400/业务错误证据 |
| 独立采购申请与计划生成采购申请 | 同数量、币种、汇率、税率、结算方式得到相同精确金额；订货审批累加、撤销对称减回自己的来源 | `StandaloneDepartmentLifecycleConservationEndToEndTest#manualAndAnalysisPurchaseRequestsUseTheSameCommercialAmountsAndRestoreTheirOwnOrderedTotals` | 当前采购订货要求申请来源；是否另提供部门直接订货应由产品契约统一，不可删来源身份 |
| 独立委外与申请分解委外 | 无申请手工行和有申请行使用同一商业、齐套、审批、冻结领料计划规则；撤销未发物料不制造库存/AP | `StandaloneDepartmentLifecycleConservationEndToEndTest#independentAndApplicationSubcontractOrdersShareDefaultsAndUndoMaterialPlansWithoutPhysicalMovements` | 独立录入和生成页面同字段、同默认、同编辑流程 |
| 采购分批、待财务与取消 | 已审数量与待财务数量分开；驳回、重提、取消只恢复自身承诺；不能重复批准 | `PurchaseRequestPartialOrderEndToEndTest`、`FullChainEndToEndTest#concurrency_financeApprovalCannotBeDoubleApproved` | 前端在审编辑入口与领取中的任务取消 |
| 采购/委外批准后改单 | 真实已收净量是数量下限；冻结汇率和总额比例保持；重审不重记订货/库存 | `ProcurementOrderSourceRevisionEndToEndTest`、`FullChainEndToEndTest#subcontractQuantityRevision_preservesExactOriginalAmountUsingFrozenExchangeRate` | 对应财务单元格修改和 old→new 展示 |
| 外币、小额与分批金额 | 完整乘积保存；来源分批金额之和等于原额；全退两种币应付归零 | `MoneyConservationEndToEndTest` | 同期间和跨期间分批组合 |
| 数量/单位转换 | 箱、件、基本单位不能混加；部分发料、退料、回厂以冻结换算率算 | `FullChainEndToEndTest#rootSupply_oneBoxTransfersTwentyBaseUnitsWithoutDoubleCounting`、`FullChainEndToEndTest#subcontractMultiUnit_partialOutboundReturnAndQualifiedReceiptConsumeExactTargetBase` | 小数换算尾量与全部现有量纲消费者 |
| IQC 隔离、分批判定、分仓入库 | 待检/不合格不计可用；合格与不合格金额合计为来源金额；实仓拥有实收来源 | `MoneyConservationEndToEndTest#iqcReleaseFailedAmountAndReturnableLimitSplitOneReceiptWithOneRuleInEitherOrder`、`FullChainEndToEndTest#iqcConfirmedSliceWarehousesOwnPhysicalStockEntitlementAndReversal` | 批处理响应丢失与实物批次 UAT |
| 多来源合单和替换补货 | 来源 analysis/path/receipt UUID 不丢；不合格补货不重复 AP、不抢其他已占用来源 | `FullChainEndToEndTest#mergedOrderIqcOriginalReplacementPreservesExactOwnershipAndValueAfterTerminalFailure`、`FullChainEndToEndTest#subcontractMixedFreeReplacementRetainsOriginalCostsInAnotherActualWarehouse` | 终态后供应商实际贷项和原货退款 |
| 齐套、占用与多任务竞争 | complete-kit 取每种物料可支持数量的最小值；WAITING 不占散料；并发不超库存 | `WorkshopSupplyAdversarialEndToEndTest`、`ProductionQuantityAdversarialEndToEndTest` | 多部门同一物料的真实多人 UAT |
| 车间分批领料、实耗、退料与撤销 | 累计领用=实耗+已验收退回+损耗+合法在制；撤销精确回到原领料/价值来源 | `WorkshopMaterialReturnSourceConservationEndToEndTest`、`WorkshopMaterialReturnValueDagEndToEndTest` | 完工前清账和晚到退料的岗位验收 |
| 超产、品质不良和公共库存 | 实际产出、需求分配、超产、FQC 和仓库实收分开；不良实物不丢成本 | `ProductionOverLimitQualityCostEndToEndTest`、`ProductionOverLimitDispositionEndToEndTest`、`WorkshopPublicSurplusEndToEndTest` | 不同品质处置组合和责任审批 |
| 成品分批入库、发货与反向 | 已入库不超过审核产出；已发货不得用反向制造回库；部分入库可继续生产 | `FullChainEndToEndTest#exactExecutionSegment_partialInboundCanShipWhileSegmentContinuesThenCloses`、`FullChainEndToEndTest#rootSupply_shippedPurchaseReceiptCannotBeReversedOrLeavePartialValueFacts` | 历史 SHIPPED 缺时间字段和实际退货质检 |
| 委外供应商持有物料与成本 | 发出=耗用+退回+损耗+供应商结存；回厂反向恢复原物料价值和加工费 | `SubcontractLossValueEndToEndTest`、`SubcontractToleranceAutoSettleEndToEndTest`、`FullChainEndToEndTest#subcontractStoredReceiptReversalRestoresOriginalMaterialAndSupplierFeeSeparately` | 供应商分批实际结存、允许损耗版本和期末签认 |
| 撤销/反审与重审 | 先检查有效下游并反向业务事实，再回草稿；重审只能计一次；原审计/历史必须留下 | 当前标准撤销类；新增反审与财务修改回归按本轮实现记录补充 | 下游阻断、重复命令、陈旧版本、领取中的财务任务、重审后的来源约束 |
| 跨期间、付款/收款后撤销 | 已关闭期间不可改原账；原币、本币、银行金额、核销、GL 同时对称；失败全部回滚 | `GlPostingCrossPeriodReversalGuardTest`、`AccountPostingReversalPostgresTest`、`FullChainEndToEndTest#salesCashCycle_foreignAdvanceThenReceiptAndReversalKeepSeparateBookAndBankAmounts` | 期末关闭/重开/供应商对账结合的真库链 |
| 重量与实测/估算来源 | 实测重量按原流水或原切片反向；未知重量保持未知；数量与称重不能互相偷换 | `ProcurementInspectionIntegrityPostgresTest`、`MeasurementWeightRequestValidationTest` 和 `features/stock/weight` 回归 | `FullChainEndToEndTest`、`MoneyConservationEndToEndTest` 尚无 weight 断言，需补完整采购/发运/撤回的重量链 |
| 真实 HTTP、权限和对象范围 | 同权限不同 owner、已知 UUID 直调、过期版本、跨部门申请均不得越权；拒绝不留下半笔库存/AP | `CriticalHttpContractEndToEndTest`、`WarehouseDataScopeEndToEndTest`、`FullChainEndToEndTest#permissions_roleIsolationAndObjectScope` | 浏览器每个角色完整操作和安装版验证 |

执行门槛：数据库类只有 `UTEN_RUN_DB_TESTS=true` 才运行；缺少 Docker/测试环境而 skipped 不算通过。根任务统一运行 Maven，使用独立 `uten.build.directory` 保存完整 XML。出现实际失败时先保留复现，修复权威层，再执行受影响和完整回归。此矩阵不授权公司服务器、数据库或网络配置写入。
