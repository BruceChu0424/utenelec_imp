package com.uten.imp.features.workbench.badge;

import java.util.List;

/**
 * 工作台徽章入口目录(ADR-108): 入口 → 归属容器 + 红/黄两个数由哪些事实数相加。
 *
 * <p>全站红(待办)/黄(进行中)徽章的唯一口径登记处。原来这张表在前端两张注册表里各写
 * 一份并由约 40 个轮询各自取数, 现在服务端按当前主体一次算完; 前端注册表只保留
 * 「入口 → 显示位置」, 不再做加法。入口键与前端 {@code BadgeEntry} 枚举逐字一致
 * (前端 badge_registry_contract_test 读本文件核对)。
 *
 * <p>事实数键 = 来源键 + "." + 端点返回的字段名(见 {@code WorkbenchBadgeSources}); 以
 * ".*" 结尾表示「该前缀下全部字段之和」(品质结果按来源大类分开返回)。
 *
 * <p>两条硬口径沿用 docs/00-项目准则/14-徽章与计数口径.md: 只有待办进红、只有在办进黄;
 * 同一条链内同一件活只计一次(链内去重说明见各入口注释与准则)。
 */
enum WorkbenchBadgeCatalog {

    // —— 人事与访客 ——
    /** 我的访客: 红 = 待我确认; 黄 = 我已确认、这趟来访还没走完(HR 审批中 + 已通过待来访)。 */
    visitorHost(Module.people, facts("visitorHost.pending"), facts("visitorHost.ongoing")),
    /** 访客审批: 红 = HR 待审批; 黄 = 已批准、访客还没来核验。 */
    visitorApproval(Module.people, facts("visitorApproval.pending"), facts("visitorApproval.ongoing")),
    /** 信息变更审核: 员工资料变更待审。 */
    hrProfileReview(Module.people, facts("profileReview.count"), none()),
    /** HR 任务中心: 今日转正/逾期转正/今日生日/今日周年。 */
    hrTaskCenter(Module.people, facts("hrTask.count"), none()),
    /** 我的报销: 红 = 草稿 + 驳回待修订; 黄 = 已提交在审批/待付款。 */
    expenseMine(Module.people, facts("expense.draftCount", "expense.rejectedCount"),
            facts("expense.processingCount")),

    // —— 钱流 ——
    /**
     * 业务审核中心(2026-09-18 起一张卡承载全部审核队列): 销售订货财务确认(含订单修改)、
     * 出货财务审核、订货审批、超量到货审批、IQC 不合格退回与贷项(仍需财务处理的案件, 见来源 open)。
     */
    financeAuditCenter(Module.finance, facts(
            "salesOrderFinance.count",
            "shipmentFinance.count",
            "procurementApproval.count",
            "financeArrivalException.count",
            "iqcRejection.open"), none()),
    /** 财务报销: 待审批 + 待付款(每张单只处于一个队列)。 */
    expenseFinance(Module.finance, facts("expense.pendingApprovalCount", "expense.pendingPaymentCount"), none()),
    /** 钱流草稿: 收款/付款/费用/其它收入/银行转账。 */
    financeDrafts(Module.finance, facts(
            "drafts.financeReceipt",
            "drafts.financePayment",
            "drafts.financeExpense",
            "drafts.financeOtherIncome",
            "drafts.financeBankTransfer"), none()),

    // —— 生产(计划员视角) ——
    /** 生产调度: 待排产行。 */
    productionSchedule(Module.production, facts("productionSchedule.count"), none()),
    /** Pending workshop tolerance changes, resolved only by planning approval. */
    productionRateApprovals(Module.production, facts("productionOverproductionRate.count"), none()),
    productionMaterialIncrementApprovals(Module.production, facts("productionMaterialIncrement.count"), none()),
    /** 生产管理: 进行中的物料分析 / 根计划批次(黄)。 */
    productionBatches(Module.production, none(), facts("productionExecution.count")),
    /** 生产草稿: 生产计划 / 生产日报。 */
    productionDrafts(Module.production, facts("drafts.productionPlan", "drafts.productionDailyReport"), none()),

    // —— 车间(车间工视角, 工作台另有一张卡, 与生产管理卡分开计) ——
    /** 我的车间任务: 红 = 等待物料(要去领料); 黄 = 生产中。 */
    productionWorkshop(Module.workshop, facts("workshopTask.preparing"), facts("workshopTask.inProgress")),

    // —— 研发 ——
    /** 工程研发部任务中心: 红 = 待认领; 黄 = 已认领在办。 */
    rdTaskCenter(Module.rd, facts("rdTask.open"), facts("rdTask.inProgress")),

    // —— 仓库(一张任务中心卡一个入口; 卡内分段用事实数) ——
    /** 出库任务中心: 销售待出库 + 委外待出仓(等子件到货那档只画在分段上, 已在委外任务中心计过黄)。 */
    warehouseOutboundCenter(Module.warehouse, facts(
            "warehouseSalesOutbound.PENDING_PICK",
            "subcontractOutbound.count"), none()),
    /** 入库任务中心: 预计到货 + 到货异常(仓库侧) + 产成品待点收。 */
    warehouseInboundCenter(Module.warehouse, facts(
            "warehouseInboundExpectation.count",
            "warehouseArrivalException.count",
            "finishedInbound.count"), none()),
    /** 生产领料任务中心: 待领任务 + 车间已提交待仓库确认实收的退料。 */
    warehouseDrawCenter(Module.warehouse, facts(
            "productionDraw.count",
            "productionReturn.count"), none()),
    /** 品质部检查结果: 红 = 轮到仓库动手(待入库 + 部分合格 + 需退回); 黄 = 等待检查结果。 */
    warehouseQualityResult(Module.warehouse, facts("qualityResult.actionable.*"), facts("qualityResult.inProgress.*")),
    /** 仓库草稿: stock_documents 全类型合计(不能用调拨/盘点切片, 会双计)。 */
    warehouseDrafts(Module.warehouse, facts("drafts.stockDocument"), none()),

    // —— 采购 ——
    /** 采购任务中心: 红 = 待分解 + 财务驳回; 黄 = 等待财务审核 + 财务已通过 + 财务驳回。 */
    purchaseTaskCenter(Module.purchase, facts("purchaseTask.pending"), facts("purchaseTask.inProgress")),
    /** 采购「待退回供应商」任务。 */
    purchaseSupplierReturn(Module.purchase, facts("purchaseSupplierReturn.count"), none()),
    /** 采购草稿: 订货/收货/退货。 */
    purchaseDrafts(Module.purchase, facts("drafts.purchaseOrder", "drafts.purchaseReceipt", "drafts.purchaseReturn"), none()),

    // —— 委外 ——
    /** 委外任务中心: 红 = 待处理(含前置生产) + 财务驳回; 黄 = 进行中三档。 */
    subcontractTaskCenter(Module.subcontract, facts("subcontractTask.pending"), facts("subcontractTask.inProgress")),
    /** 委外「待退回供应商」任务。 */
    subcontractSupplierReturn(Module.subcontract, facts("subcontractSupplierReturn.count"), none()),
    /** 委外草稿: 订货/退货/退料/废品。 */
    subcontractDrafts(Module.subcontract, facts(
            "drafts.subcontractOrder",
            "drafts.subcontractReturn",
            "drafts.subcontractMaterialReturn",
            "drafts.subcontractWaste"), none()),

    // —— 品质 ——
    /** 待检处置 · IQC 待检收货单。 */
    qualityIqcPending(Module.quality, facts("iqcPending.count"), none()),
    /** 待检处置 · FQC 自制产成品待检。 */
    qualityFqcPending(Module.quality, facts("fqcPending.count"), none()),

    // —— 销售 ——
    /** 订单进度: 红 = 财务驳回待修正 + 可分批发货待开单。 */
    salesAttention(Module.sales, facts("salesStage.REJECTED", "salesStage.SHIPPABLE"), none()),
    /**
     * 订单进度: 黄 = 在途订单(待排产 + 生产中 + 出货待财审 + 等仓库出货)。出货/订货/报价/退货
     * 四张单据卡的在途数不再登记: 出货待财审/等仓库出货本就从出货单派生, 再数一遍就是翻倍。
     */
    salesOrderInFlight(Module.sales, none(), facts(
            "salesStage.PENDING",
            "salesStage.PRODUCING",
            "salesStage.SHIPMENT_PENDING",
            "salesStage.WAREHOUSE_PENDING")),
    /** 销售出货「财务已退回」(采购/委外订货的退回件已由各自任务中心计入)。 */
    salesShipmentFinanceRejected(Module.sales, facts("financeRejected.salesShipment"), none()),
    /** 销售草稿: 订货/发货/退货/报价。 */
    salesDrafts(Module.sales, facts("drafts.salesOrder", "drafts.salesShipment", "drafts.salesReturn", "drafts.salesQuote"), none()),

    // —— 系统管理 ——
    /** 服务器状态: 越过警告或危急阈值的告警条数。 */
    serverStatusAlert(Module.system, facts("serverStatus.alerts"), none());

    /** 徽章容器: 一个容器对应工作台上的一张模块卡 / 一个 hub。 */
    enum Module {
        people, finance, production, workshop, rd, warehouse, purchase, subcontract, quality, sales, system
    }

    private final Module module;
    private final List<String> todoFacts;
    private final List<String> inProgressFacts;

    WorkbenchBadgeCatalog(Module module, List<String> todoFacts, List<String> inProgressFacts) {
        this.module = module;
        this.todoFacts = todoFacts;
        this.inProgressFacts = inProgressFacts;
    }

    Module module() {
        return module;
    }

    List<String> todoFacts() {
        return todoFacts;
    }

    List<String> inProgressFacts() {
        return inProgressFacts;
    }

    private static List<String> facts(String... keys) {
        return List.of(keys);
    }

    private static List<String> none() {
        return List.of();
    }

    /** 事实数键的来源键(第一个点号之前)。 */
    static String sourceOf(String factKey) {
        int dot = factKey.indexOf('.');
        return dot < 0 ? factKey : factKey.substring(0, dot);
    }
}
