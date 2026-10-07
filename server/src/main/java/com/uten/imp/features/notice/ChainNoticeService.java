package com.uten.imp.features.notice;

import com.uten.imp.application.port.SubcontractChainNoticePort;
import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.common.finance.SubcontractLossSettlementSql;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 业务链自动通知（SOP §一 8 类：排产/完工/部分完工/数量不足补产/发货/驳回/延期预警/取消确认/缺料）。
 *
 * <p><b>可靠旁路原则</b>：业务事务只向 {@code business_outbox} 追加事件；后台处理器
 * 以 {@code FOR UPDATE SKIP LOCKED} 认领，并在同一事务中生成全部站内通知和送达标记。
 * 任一接收人失败会整体回滚并指数退避重试，因此不会出现主单回滚后误发或部分通知永久丢失。
 *
 * <p>接收人解析：订单归属销售（owner_employee_id，回退 seller_id）→ 员工账号；
 * 采购/调度按角色码（buyer/planner）广播。业务 Service 只传单据 ID，内容在此统一按 ID 自查组装。
 *
 * <p>每条定向业务通知都带 actionRoute（站内「查看详情」直达源单据/任务页）：归属销售类跳源单据
 * 详情，调度/仓库/财务类跳各自任务中心。route 由各 notify* 方法硬编码（非用户输入），仅做基本
 * sanity check（见 {@link NoticeService#publishForUser} 6 参重载）。
 */
@Service
public class ChainNoticeService implements SubcontractChainNoticePort, com.uten.imp.application.port.ProductionDrawInstructionNoticePort {

    /** 合法类型见 NoticeService.TYPES；此处固定用到的子集。 */
    public static final String TYPE_WORKFLOW = "workflow";
    public static final String TYPE_TASK = "task";
    public static final String TYPE_URGENT = "urgent";
    public static final String TYPE_APPROVAL = "approval";

    private static final String PUBLISHER = "系统";
    public static final String EVENT_PLAN_SCHEDULED = "PRODUCTION_PLAN_SCHEDULED";
    static final String EVENT_PRODUCTION_REPORTED = "PRODUCTION_REPORTED";
    static final String EVENT_FINISHED_INBOUND = "PRODUCTION_FINISHED_INBOUND";
    static final String EVENT_FINISHED_INBOUND_PENDING =
            "PRODUCTION_FINISHED_INBOUND_PENDING";
    static final String EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING =
            "PRODUCTION_FINISHED_ARRIVAL_PENDING";
    static final String EVENT_FINISHED_INBOUND_REJECTED =
            "PRODUCTION_FINISHED_INBOUND_REJECTED";
    static final String EVENT_FINISHED_INBOUND_REVERSED =
            "PRODUCTION_FINISHED_INBOUND_REVERSED";
    static final String EVENT_PRODUCTION_DRAW_PENDING =
            "PRODUCTION_DRAW_PENDING";
    static final String EVENT_PRODUCTION_FQC_PENDING =
            "PRODUCTION_FQC_PENDING";
    static final String EVENT_PRODUCTION_FQC_RELEASED =
            "PRODUCTION_FQC_RELEASED";
    static final String EVENT_PRODUCTION_FQC_RESOLVED =
            "PRODUCTION_FQC_RESOLVED";
    static final String EVENT_PRODUCTION_DRAW_ISSUED =
            "PRODUCTION_DRAW_ISSUED";
    static final String EVENT_PRODUCTION_DRAW_ISSUE_REVERSED =
            "PRODUCTION_DRAW_ISSUE_REVERSED";
    static final String EVENT_REMAKE_CREATED = "PRODUCTION_REMAKE_CREATED";
    static final String EVENT_SEGMENT_READY = "PRODUCTION_SEGMENT_READY";
    static final String EVENT_SEGMENT_DISPATCHED = "PRODUCTION_SEGMENT_DISPATCHED";
    static final String EVENT_SEGMENT_STARTED = "PRODUCTION_SEGMENT_STARTED";
    static final String EVENT_SEGMENT_WORKSHOP_ASSIGNED =
            "PRODUCTION_SEGMENT_WORKSHOP_ASSIGNED";
    static final String EVENT_PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED =
            "PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED";
    static final String EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL =
            "PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL";
    static final String EVENT_SHIPMENT_APPROVED = "SALES_SHIPMENT_APPROVED";
    static final String EVENT_SHIPMENT_PENDING_FINANCE =
            "SALES_SHIPMENT_PENDING_FINANCE_AUDIT";
    static final String EVENT_SHIPMENT_PENDING_PICK =
            "SALES_SHIPMENT_PENDING_PICK";
    static final String EVENT_SHIPMENT_FINANCE_REVOKED =
            "SALES_SHIPMENT_FINANCE_RELEASE_REVOKED";
    static final String EVENT_SHIPMENT_REJECTED = "SALES_SHIPMENT_REJECTED";
    static final String EVENT_SHIPMENT_FINANCE_REJECTED = "SALES_SHIPMENT_FINANCE_REJECTED";
    static final String EVENT_DIRECT_SHIPMENT_FINANCE_REJECTED = "DIRECT_CUSTOMER_SHIPMENT_FINANCE_REJECTED";
    static final String EVENT_PREPLAN_SUPPLY_ACTION_CREATED =
            "PREPLAN_SUPPLY_ACTION_CREATED";
    static final String EVENT_PREPLAN_SUPPLY_DOCUMENT_CREATED =
            "PREPLAN_SUPPLY_DOCUMENT_CREATED";
    /**
     * ADR-143 §4.4 领料重算: 库存入库、预留释放、财务批准、改量之后由业务事务追加(载荷
     * {goodsId,colorId} 或订货明细), 只在 Outbox 投递时(事务已提交)才计算可领量并维护通知卡。
     * 不产生任何通知行。
     */
    public static final String EVENT_SUBCONTRACT_DRAW_RECHECK =
            com.uten.imp.application.port.SubcontractDrawRecheckPort.EVENT_TYPE;
    /** 委外可领料行动卡的通知来源(每个订货明细一张, 按最新可领量覆盖; 只由领料重算在投递里重建, 不走 outbox 事件)。 */
    static final String EVENT_SUBCONTRACT_DRAW_AVAILABLE =
            "SUBCONTRACT_DRAW_AVAILABLE";
    /** 内部事件: 撤掉某订货明细的可领料行动卡(提交领料、结束领料、订单红冲)。 */
    static final String EVENT_SUBCONTRACT_DRAW_AVAILABLE_RESOLVED =
            "SUBCONTRACT_DRAW_AVAILABLE_RESOLVED";
    /** ADR-156 委外申请可下单行动卡的通知来源(每个申请明细一张, 按最新可下单量覆盖; 只由可下单重算在投递里重建)。 */
    static final String EVENT_SUBCONTRACT_ORDER_KIT_READY =
            "SUBCONTRACT_ORDER_KIT_READY";
    /** 内部事件: 撤掉某委外申请明细的可下单行动卡(可下单归零、已下完、申请关闭)。 */
    static final String EVENT_SUBCONTRACT_ORDER_KIT_READY_RESOLVED =
            "SUBCONTRACT_ORDER_KIT_READY_RESOLVED";
    /** 委外人员撤回未发出的领料 → 通知草稿所在仓库。 */
    static final String EVENT_SUBCONTRACT_DRAW_WITHDRAWN =
            "SUBCONTRACT_DRAW_WITHDRAWN";
    /** 仓库把一张委外领料草稿整张退回(本次不发) → 通知提交领料的委外人员(载荷 reason)。 */
    static final String EVENT_SUBCONTRACT_DRAW_RETURNED =
            "SUBCONTRACT_DRAW_RETURNED";
    /** 一张委外领料草稿等仓库发料(事件名沿用, 含义改为「领料草稿待发料」)。 */
    static final String EVENT_SUBCONTRACT_OUTBOUND_READY =
            "SUBCONTRACT_OUTBOUND_READY";
    static final String EVENT_SUBCONTRACT_OUTBOUND_COMPLETED =
            "SUBCONTRACT_OUTBOUND_COMPLETED";
    static final String EVENT_SUBCONTRACT_OUTBOUND_REVERSED =
            "SUBCONTRACT_OUTBOUND_REVERSED";
    static final String EVENT_SUBCONTRACT_RETURN_DUE =
            "SUBCONTRACT_RETURN_DUE";
    static final String EVENT_MATERIAL_ANALYSIS_READY =
            "PRODUCTION_MATERIAL_ANALYSIS_READY";
    static final String EVENT_ORDER_CANCELED = "SALES_ORDER_CANCELED";
    static final String EVENT_ORDER_APPROVED = "SALES_ORDER_APPROVED";
    static final String EVENT_ORDER_PENDING_FINANCE =
            "SALES_ORDER_PENDING_FINANCE_CONFIRM";
    static final String EVENT_ORDER_FINANCE_CONFIRMED =
            "SALES_ORDER_FINANCE_CONFIRMED";
    static final String EVENT_ORDER_FINANCE_REJECTED =
            "SALES_ORDER_FINANCE_REJECTED";
    static final String EVENT_DELIVERY_DUE = "SALES_DELIVERY_DUE";
    static final String EVENT_RESERVATION_HOLD_OVERDUE = "SALES_RESERVATION_HOLD_OVERDUE";
    static final String EVENT_RESERVATION_YIELDED = "SALES_RESERVATION_YIELDED";
    static final String EVENT_PROCUREMENT_FINANCE_SUBMITTED =
            "PROCUREMENT_FINANCE_SUBMITTED";
    static final String EVENT_PROCUREMENT_FINANCE_APPROVED =
            "PROCUREMENT_FINANCE_APPROVED";
    static final String EVENT_PROCUREMENT_FINANCE_REJECTED =
            "PROCUREMENT_FINANCE_REJECTED";
    static final String EVENT_PROCUREMENT_ARRIVAL_DETECTED =
            "PROCUREMENT_ARRIVAL_EXCEPTION_DETECTED";
    static final String EVENT_PROCUREMENT_ARRIVAL_DECIDED =
            "PROCUREMENT_ARRIVAL_EXCEPTION_DECIDED";
    static final String EVENT_PROCUREMENT_RETURN_REQUIRED =
            "PROCUREMENT_SUPPLIER_RETURN_REQUIRED";
    static final String EVENT_PROCUREMENT_RETURN_COMPLETED =
            "PROCUREMENT_SUPPLIER_RETURN_COMPLETED";
    static final String EVENT_PROCUREMENT_ARRIVAL_RECEIPT_POSTED =
            "PROCUREMENT_ARRIVAL_RECEIPT_POSTED";
    /** ADR-098 委外回厂短交：发现(紧急) / 分批等待逾期(重要) / 已处理(只撤卡)。 */
    static final String EVENT_SUBCONTRACT_SHORT_DELIVERY_DETECTED =
            "SUBCONTRACT_SHORT_DELIVERY_DETECTED";
    static final String EVENT_SUBCONTRACT_SHORT_DELIVERY_WAIT_OVERDUE =
            "SUBCONTRACT_SHORT_DELIVERY_WAIT_OVERDUE";
    static final String EVENT_SUBCONTRACT_SHORT_DELIVERY_RESOLVED =
            "SUBCONTRACT_SHORT_DELIVERY_RESOLVED";
    static final String SUBCONTRACT_SHORT_DELIVERY_AGGREGATE = "SUBCONTRACT_SHORT_DELIVERY_CASE";
    static final String SUBCONTRACT_SHORT_DELIVERY_DECIDE_AUTHORITY = "subcontract_short_delivery:decide";
    static final String EVENT_BOM_UPDATED = "GOODS_BOM_UPDATED";
    /** ADR-143 §二.3 委外件缺 BOM 新建「完善 BOM」研发任务(RdBomGapService 发)。 */
    static final String EVENT_RD_TASK_FORWARDED = "RD_TASK_FORWARDED";
    /**
     * ADR-143 §二.3 研发完善委外件 BOM 后刷新一张物料分析(notifyBomUpdated 按候选分析各排一条,
     * 聚合 = 物料分析)：每张分析在自己的投递里刷新，失败只让这一条退避重试。
     */
    static final String EVENT_MATERIAL_ANALYSIS_BOM_REFRESH = "MATERIAL_ANALYSIS_BOM_REFRESH";
    static final String AGGREGATE_MATERIAL_ANALYSIS = "PRODUCTION_MATERIAL_ANALYSIS";
    static final String EVENT_RD_TASK_RESOLVED = "RD_TASK_RESOLVED";
    static final String EVENT_IQC_PENDING = "PROCUREMENT_IQC_PENDING";
    /** V459 订单全部完工（累计成品入库 ≥ 订货量）→ 通知负责销售可发货。 */
    static final String EVENT_ORDER_FULLY_PRODUCED_READY_TO_SHIP =
            "SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP";
    static final String EVENT_IQC_RESOLVED = "PROCUREMENT_IQC_RESOLVED";
    /** 先入库后检(V596)：仓库把待检品上架到实际仓/库位后，提醒品质部到库位检验。 */
    static final String EVENT_IQC_PRE_STOCKED = "PROCUREMENT_IQC_PRE_STOCKED";
    static final String EVENT_IQC_STOCK_IN_PENDING =
            "PROCUREMENT_IQC_STOCK_IN_PENDING";
    static final String EVENT_SUBCONTRACT_LOSS_OPENED =
            "SUBCONTRACT_LOSS_CLAIM_OPENED";
    static final String EVENT_SUBCONTRACT_LOSS_DECIDED =
            "SUBCONTRACT_LOSS_CLAIM_DECIDED";
    static final String EVENT_SUBCONTRACT_LOSS_FULFILLED =
            "SUBCONTRACT_LOSS_CLAIM_FULFILLED";
    static final String EVENT_SUBCONTRACT_LOSS_REVERSED =
            "SUBCONTRACT_LOSS_CLAIM_REVERSED";
    static final String EVENT_PROCUREMENT_IQC_REJECTION_OPENED =
            "PROCUREMENT_IQC_REJECTION_OPENED";
    static final String EVENT_PROCUREMENT_FINANCE_CHANGE_SUBMITTED =
            "PROCUREMENT_FINANCE_CHANGE_SUBMITTED";
    static final String EVENT_PROCUREMENT_IQC_REJECTION_DETECTED =
            "PROCUREMENT_IQC_REJECTION_DETECTED";
    static final String EVENT_PROCUREMENT_IQC_REJECTION_RETURNED =
            "PROCUREMENT_IQC_REJECTION_RETURNED";
    static final String EVENT_PROCUREMENT_IQC_CREDIT_CONFIRMED =
            "PROCUREMENT_IQC_CREDIT_CONFIRMED";
    static final String EVENT_PROCUREMENT_IQC_REJECTION_NO_CREDIT =
            "PROCUREMENT_IQC_REJECTION_NO_CREDIT";
    static final String EVENT_PROCUREMENT_IQC_REJECTION_REVERSED =
            "PROCUREMENT_IQC_REJECTION_REVERSED";
    static final String EVENT_PROCUREMENT_IQC_REJECTION_FINANCE_EXCEPTION =
            "PROCUREMENT_IQC_REJECTION_FINANCE_EXCEPTION";
    private static final String IQC_VIEW_AUTHORITY = "procurement_inspection:view";
    private static final String WAREHOUSE_IQC_STOCK_IN_VIEW_AUTHORITY =
            "warehouse_iqc_stock_in:view";
    private static final String NOTICE_READ_AUTHORITY = "notice:read";
    /** ADR-117 车间催计划下单子层物料(与 ProductionPlanningUrgeService 同名)。 */
    static final String EVENT_PRODUCTION_PLANNING_URGED = "PRODUCTION_PLANNING_URGED";
    static final String AGGREGATE_PRODUCTION_PLANNING_URGE = "PRODUCTION_PLANNING_URGE";
    /** 计划员部门池通知的打开门槛：能看生产计划(通知路由落在计划页)。 */
    private static final String PLAN_VIEW_AUTHORITY = "production_plan:view";
    /** 交货预警给计划员的落点是物料分析工作台。 */
    private static final String ANALYSIS_VIEW_AUTHORITY = "production_material_analysis:view";
    private static final String IQC_REJECTION_VIEW_AUTHORITY =
            "procurement_iqc_rejection:view";
    private static final String IQC_REJECTION_VIEW_ALL_AUTHORITY =
            "procurement_iqc_rejection:view:all";
    private static final String IQC_REJECTION_CONFIRM_CREDIT_AUTHORITY =
            "procurement_iqc_rejection:confirm_credit";
    private static final String IQC_REJECTION_RECORD_RETURN_AUTHORITY =
            "procurement_iqc_rejection:record_return";
    private static final String IQC_REJECTION_CLOSE_NO_CREDIT_AUTHORITY =
            "procurement_iqc_rejection:close_no_credit";
    private static final String PURCHASE_REQUEST_VIEW_AUTHORITY = "purchase_request:view";
    private static final String SUBCONTRACT_APPLICATION_VIEW_AUTHORITY =
            "subcontract_application:view";
    private static final String SUBCONTRACT_ORDER_VIEW_AUTHORITY = "subcontract_order:view";
    /** ADR-143 新权限点「委外领料(提交、撤回、结束领料)」。 */
    private static final String SUBCONTRACT_ORDER_DRAW_AUTHORITY = "subcontract_order:draw";
    /** 委外单据归属可见范围(与 SubcontractDocumentAccessPolicy 同一 scope / 查看全部权限)。 */
    private static final String SUBCONTRACT_OWNER_SCOPE = "subcontract";
    private static final String SUBCONTRACT_VIEW_ALL_AUTHORITY = "subcontract:view:all";
    private static final String SUBCONTRACT_OUTBOUND_VIEW_AUTHORITY = "subcontract_outbound:view";
    private static final String SUBCONTRACT_OUTBOUND_EXECUTE_AUTHORITY = "subcontract_outbound:execute";
    static final String AGGREGATE_SUBCONTRACT_ORDER_ITEM = "SUBCONTRACT_ORDER_ITEM";
    static final String AGGREGATE_SUBCONTRACT_MATERIAL_ISSUE = "SUBCONTRACT_MATERIAL_ISSUE";
    static final String AGGREGATE_SUBCONTRACT_APPLICATION_ITEM = "SUBCONTRACT_APPLICATION_ITEM";
    /** ADR-156 生成委外订货单(从委外任务中心分解委外申请)的权限点。 */
    private static final String SUBCONTRACT_ORDER_DECOMPOSE_AUTHORITY = "subcontract_order:decompose";
    /** 委外任务中心「待处理」分段(按申请单号搜索), 可下单行动卡的落点。 */
    static final String SUBCONTRACT_PENDING_SEGMENT_ROUTE = "/operations/workbench/subcontract?segment=pending&keyword=";
    /** 委外任务中心「领料」分段(按订货明细筛选), 可领料行动卡的落点。 */
    static final String SUBCONTRACT_DRAW_SEGMENT_ROUTE = "/operations/workbench/subcontract?segment=DRAW&orderItemId=";
    /** 仓库委外出仓工作台的一张领料草稿(拣货页)。 */
    static final String SUBCONTRACT_OUTBOUND_DRAFT_ROUTE = "/warehouse/subcontract-outbound/";
    /** 仓库委外出仓工作台的待发料列表(草稿已整张撤销时的落点: 拣货页只认待发草稿, 打开会是「不存在」)。 */
    static final String SUBCONTRACT_OUTBOUND_LIST_ROUTE = "/warehouse/subcontract-outbound";
    /** 委外任务中心「领料」分段(不限订货明细)。 */
    static final String SUBCONTRACT_DRAW_LIST_ROUTE = "/operations/workbench/subcontract?segment=DRAW";
    private static final ThreadLocal<Boolean> OUTBOX_DELIVERY =
            ThreadLocal.withInitial(() -> false);
    /** 当前锁定 Outbox 事件；用于给未显式传 sourceEvent 的通知补齐可靠事件来源。 */
    private static final ThreadLocal<String> OUTBOX_EVENT = new ThreadLocal<>();
    private static final DateTimeFormatter EVENT_TIME_FORMAT =
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm");


    private final NoticeService noticeService;
    private final UserAccountRepository userRepo;
    private final PermissionResolver permissionResolver;
    private final JdbcTemplate jdbc;
    private final BusinessEventPublisher outbox;
    private final RdTaskService rdTaskService;
    private final FinanceReviewerEligibilityPort financeReviewerEligibility;
    private final SalesOrderFinanceConfirmerEligibility salesOrderFinanceConfirmers;
    private final NoticePermissionCandidateQuery permissionCandidates;
    private final org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.WorkshopMaterialAvailabilityReadPort> workshopReadiness;
    /** ADR-149 仓库类通知唯一分发规则; 未注入(直接 new 的单测)时仓库类通知照旧发给整个通知池。 */
    private WarehouseNoticeRouter warehouseRouter;

    public ChainNoticeService(NoticeService noticeService,
                              UserAccountRepository userRepo,
                              PermissionResolver permissionResolver,
                              JdbcTemplate jdbc,
                              BusinessEventPublisher outbox,
                              RdTaskService rdTaskService,
                              FinanceReviewerEligibilityPort financeReviewerEligibility,
                              SalesOrderFinanceConfirmerEligibility salesOrderFinanceConfirmers) {
        this(noticeService, userRepo, permissionResolver, jdbc, outbox,
                rdTaskService, financeReviewerEligibility, salesOrderFinanceConfirmers, null);
    }

    public ChainNoticeService(NoticeService noticeService,
                              UserAccountRepository userRepo,
                              PermissionResolver permissionResolver,
                              JdbcTemplate jdbc,
                              BusinessEventPublisher outbox,
                              RdTaskService rdTaskService,
                              FinanceReviewerEligibilityPort financeReviewerEligibility,
                              SalesOrderFinanceConfirmerEligibility salesOrderFinanceConfirmers,
                              NoticePermissionCandidateQuery permissionCandidates) {
        this(noticeService,userRepo,permissionResolver,jdbc,outbox,rdTaskService,
                financeReviewerEligibility,salesOrderFinanceConfirmers,permissionCandidates,null);
    }

    @org.springframework.beans.factory.annotation.Autowired
    public ChainNoticeService(NoticeService noticeService, UserAccountRepository userRepo,
            PermissionResolver permissionResolver, JdbcTemplate jdbc,
            BusinessEventPublisher outbox, RdTaskService rdTaskService,
            FinanceReviewerEligibilityPort financeReviewerEligibility,
            SalesOrderFinanceConfirmerEligibility salesOrderFinanceConfirmers,
            NoticePermissionCandidateQuery permissionCandidates,
            org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.WorkshopMaterialAvailabilityReadPort> workshopReadiness) {
        this.noticeService = noticeService;
        this.userRepo = userRepo;
        this.permissionResolver = permissionResolver;
        this.jdbc = jdbc;
        this.outbox = outbox;
        this.rdTaskService = rdTaskService;
        this.financeReviewerEligibility = financeReviewerEligibility;
        this.salesOrderFinanceConfirmers = salesOrderFinanceConfirmers;
        this.permissionCandidates = permissionCandidates;
        this.workshopReadiness = workshopReadiness;
    }

    /** ADR-117：计划员待办卡按物料分析归属可见范围过滤收件人时，找交接后的现负责人。 */
    private com.uten.imp.security.EmployeeHandoverVisibility handoverVisibility;

    private com.uten.imp.application.port.SalesPlanningNoticeReadPort planningSources;

    @org.springframework.beans.factory.annotation.Autowired
    void setPlanningSources(com.uten.imp.application.port.SalesPlanningNoticeReadPort planningSources) {
        this.planningSources = planningSources;
    }

    static final String EVENT_SALES_PLANNING_CATCH_UP = "SALES_PLANNING_NOTICE_CATCH_UP";

    @org.springframework.beans.factory.annotation.Autowired(required = false)
    void setHandoverVisibility(com.uten.imp.security.EmployeeHandoverVisibility handoverVisibility) {
        this.handoverVisibility = handoverVisibility;
    }

    @org.springframework.beans.factory.annotation.Autowired(required = false)
    void setWarehouseRouter(WarehouseNoticeRouter warehouseRouter) {
        this.warehouseRouter = warehouseRouter;
    }

    /**
     * ADR-143 领料重算的执行方(委外领料模块)。它自己又依赖本类发可领料卡, 所以经
     * ObjectProvider 延迟取用, 不形成构造期循环依赖。
     */
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.SubcontractDrawRecheckPort> drawRecheck;

    @org.springframework.beans.factory.annotation.Autowired
    void setDrawRecheck(
            org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.SubcontractDrawRecheckPort> drawRecheck) {
        this.drawRecheck = drawRecheck;
    }

    /**
     * ADR-143 §二.3 研发完善委外件 BOM 后自动刷新物料分析(生产物料分析模块实现)。物料分析又依赖
     * 本类发通知, 经 ObjectProvider 延迟取用; 直接 new 本类的单测里为空, 只跳过刷新。
     */
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.MaterialAnalysisBomRefreshPort> bomRefresh;

    @org.springframework.beans.factory.annotation.Autowired
    void setBomRefresh(
            org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.MaterialAnalysisBomRefreshPort> bomRefresh) {
        this.bomRefresh = bomRefresh;
    }

    /**
     * 分批路线「当前可齐套生产量」的执行方(生产分批模块)。它自己又依赖本类发通知, 所以经
     * ObjectProvider 延迟取用, 不形成构造期循环依赖; 直接 new 本类的单测里为空, 视为不可计量。
     */
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.features.production.mrp.ProductionExecutionBatchService> batchSplits;

    @org.springframework.beans.factory.annotation.Autowired
    void setBatchSplits(
            org.springframework.beans.factory.ObjectProvider<com.uten.imp.features.production.mrp.ProductionExecutionBatchService> batchSplits) {
        this.batchSplits = batchSplits;
    }

    /**
     * 仓库类通知按仓分发(ADR-149, 取代 ADR-115 的「负责人 ∩ 池, 为空发整个池」):
     * 该仓链上的子仓负责人 ∩ 池; 没有则主管 ∩ 池; 再没有(还没配置任何负责人)才发整个池。
     * 单据还没定仓时直接走主管那一级。与列表范围同一套负责关系(WarehouseNoticeRouter)。
     */
    List<UUID> warehouseRecipients(List<UUID> pool, Collection<UUID> warehouseIds) {
        if (warehouseRouter == null || pool.isEmpty()) return pool;
        return warehouseRouter.recipients(pool, warehouseIds);
    }

    /** 仓库类通知池: 部门池 + 部门外的人还要满足的条件(在职、持有全部所需权限)。 */
    record WarehouseNoticePool(List<UUID> department, java.util.function.Predicate<UUID> qualifies) {
    }

    /**
     * 按这张单涉及的仓组池并分发: 部门池加上这些仓的子仓负责人与指定的主管里同样持有所需权限的部门外的人
     * (ADR-149: 子仓负责人不论部门都按登记的仓收通知; 别的仓的负责人不进这张单的池)。
     */
    List<UUID> warehouseRecipients(WarehouseNoticePool pool, Collection<UUID> warehouseIds) {
        if (warehouseRouter == null) return pool.department();
        return warehouseRecipients(warehouseRouter.pool(pool.department(), pool.qualifies(), warehouseIds),
                warehouseIds);
    }

    /** 仓库类通知池: 仓库部门(SUB_WH 子树)里持有全部所需权限的账号 + 部门外的人要满足的同样条件。 */
    private WarehouseNoticePool warehousePool(String... authorities) {
        List<UUID> department = departmentUserIdsWithAuthorities("SUB_WH", authorities);
        Set<String> required = Set.of(authorities);
        return new WarehouseNoticePool(department, userId -> userRepo.findById(userId)
                .filter(account -> !account.isDeleted() && "active".equals(account.getStatus()))
                .map(permissionResolver::permsOf)
                .map(permissions -> permissions.containsAll(required))
                .orElse(false));
    }

    /** 单据仓库列(可能为空)的 UUID 集合。 */
    private static List<UUID> warehouseIdsOf(Object... values) {
        List<UUID> ids = new ArrayList<>();
        for (Object value : values) {
            if (value instanceof UUID id) ids.add(id);
        }
        return ids;
    }

    /** 一条只返回仓库列的查询结果(去空去重)。 */
    private List<UUID> warehouseIdsQuery(String sql, Object... args) {
        return jdbc.queryForList(sql, UUID.class, args).stream()
                .filter(Objects::nonNull).distinct().toList();
    }

    /** Called only by the locked outbox processor inside its delivery transaction. */
    public void deliverOutboxEvent(String eventType, UUID aggregateId, JsonNode payload) {
        OUTBOX_DELIVERY.set(true);
        OUTBOX_EVENT.set(eventType);
        try {
            switch (eventType) {
                case "PRODUCTION_OVER_LIMIT_PENDING", "PRODUCTION_OVER_LIMIT_DECIDED", "PRODUCTION_OVER_LIMIT_WITHDRAWN" ->
                    deliverProductionOverLimit(eventType,aggregateId,payload);
                case "PRODUCTION_MATERIAL_DISCOVERY_PENDING",
                     "PRODUCTION_MATERIAL_DISCOVERY_CONFIGURED",
                     "PRODUCTION_MATERIAL_DISCOVERY_VISIBILITY",
                     "PRODUCTION_MATERIAL_DISCOVERY_CANCELLED" -> deliverMaterialDiscovery(eventType,aggregateId);
                case "PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED",
                     "PRODUCTION_OVERPRODUCTION_RATE_APPROVED",
                     "PRODUCTION_OVERPRODUCTION_RATE_RETURNED" ->
                        deliverProductionRateReview(eventType,aggregateId);
                case "PRODUCTION_MATERIAL_INCREMENT_SUBMITTED",
                     "PRODUCTION_MATERIAL_INCREMENT_APPROVED",
                     "PRODUCTION_MATERIAL_INCREMENT_CANCELLED",
                     "PRODUCTION_MATERIAL_INCREMENT_RETURNED" ->
                        deliverProductionMaterialIncrementReview(eventType,aggregateId);
                case EVENT_PLAN_SCHEDULED ->
                        notifyPlanScheduled(aggregateId, payload.path("shortage").asBoolean(false));
                case EVENT_PRODUCTION_REPORTED ->
                        notifyProductionReported(aggregateId);
                case EVENT_FINISHED_INBOUND ->
                        deliverFinishedInbound(aggregateId, payload);
                case EVENT_FINISHED_INBOUND_PENDING ->
                        notifyFinishedInboundPending(aggregateId);
                case EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING ->
                        notifyProductionFinishedArrivalPending(aggregateId);
                case EVENT_FINISHED_INBOUND_REJECTED ->
                        notifyFinishedInboundRejected(
                                aggregateId,
                                payload.path("reason").asText(""),
                                null);
                case EVENT_FINISHED_INBOUND_REVERSED ->
                        notifyFinishedInboundReversed(aggregateId, null);
                case EVENT_PRODUCTION_DRAW_PENDING ->
                        notifyProductionDrawPending(aggregateId);
                case EVENT_PRODUCTION_DRAW_ISSUED ->
                        notifyProductionDrawIssued(aggregateId, null);
                case EVENT_PRODUCTION_DRAW_ISSUE_REVERSED ->
                        notifyProductionDrawIssueReversed(aggregateId, null);
                case EVENT_PRODUCTION_FQC_PENDING,
                     EVENT_PRODUCTION_FQC_RELEASED,
                     EVENT_PRODUCTION_FQC_RESOLVED -> {
                    // FQC and warehouse queues are authoritative database
                    // projections. These durable events intentionally require
                    // no notice row to make the task discoverable.
                }
                case EVENT_REMAKE_CREATED ->
                        notifyRemakeCreated(aggregateId);
                case EVENT_SEGMENT_READY ->
                        notifyExecutionSegmentReady(
                                aggregateId,
                                null,
                                payload.path("sourceType").asText(""));
                case EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL ->
                        publishWorkshopMaterialArrival(
                                aggregateId,
                                payload.path("arrival").asText(""),
                                payload.path("evidenceType").asText("CURRENT_STATE"),
                                workshopEvidenceIds(payload.path("evidenceIds")));
                case EVENT_SEGMENT_DISPATCHED ->
                        notifyExecutionSegmentTransition(aggregateId, false);
                case EVENT_SEGMENT_STARTED ->
                        notifyExecutionSegmentTransition(aggregateId, true);
                case EVENT_SEGMENT_WORKSHOP_ASSIGNED ->
                        notifyExecutionSegmentWorkshopAssigned(aggregateId);
                case EVENT_SHIPMENT_APPROVED -> notifyShipmentApproved(aggregateId);
                case EVENT_SHIPMENT_PENDING_FINANCE ->
                        notifyShipmentPendingFinanceAudit(aggregateId,payload.path("submissionIdentity").asText(null));
                case EVENT_SHIPMENT_PENDING_PICK ->
                        notifyShipmentPendingPick(aggregateId);
                case EVENT_SHIPMENT_FINANCE_REVOKED ->
                        notifyShipmentFinanceReleaseRevoked(aggregateId);
                case EVENT_SHIPMENT_REJECTED ->
                        notifyShipmentRejected(aggregateId, payload.path("reason").asText(""));
                case EVENT_SHIPMENT_FINANCE_REJECTED, EVENT_DIRECT_SHIPMENT_FINANCE_REJECTED ->
                        notifyShipmentFinanceRejected(aggregateId,payload.path("reason").asText(""),
                                payload.hasNonNull("reviewRevision")?payload.path("reviewRevision").asLong():null);
                case EVENT_PREPLAN_SUPPLY_ACTION_CREATED ->
                        notifyPreplanSupplyActionCreated(aggregateId);
                case EVENT_PREPLAN_SUPPLY_DOCUMENT_CREATED -> {
                    if (payload.hasNonNull("addedQty")) {
                        notifyPreplanSupplyDocumentIncreased(
                                aggregateId, payload.path("documentType").asText(""),
                                new java.math.BigDecimal(payload.path("addedQty").asText("0")));
                    } else {
                        notifyPreplanSupplyDocumentCreated(
                                aggregateId, payload.path("documentType").asText(""));
                    }
                }
                case EVENT_SUBCONTRACT_DRAW_RECHECK ->
                        deliverSubcontractDrawRecheck(aggregateId, payload);
                case EVENT_SUBCONTRACT_DRAW_AVAILABLE_RESOLVED ->
                        resolveSubcontractDrawAvailable(aggregateId);
                case EVENT_SUBCONTRACT_ORDER_KIT_READY_RESOLVED ->
                        resolveSubcontractOrderKitReady(aggregateId);
                case EVENT_SUBCONTRACT_DRAW_WITHDRAWN ->
                        notifySubcontractDrawWithdrawn(aggregateId);
                case EVENT_SUBCONTRACT_DRAW_RETURNED ->
                        notifySubcontractDrawReturned(aggregateId, payload.path("reason").asText(""));
                case EVENT_SUBCONTRACT_OUTBOUND_READY ->
                        notifySubcontractOutboundReady(aggregateId);
                case EVENT_SUBCONTRACT_OUTBOUND_COMPLETED ->
                        notifySubcontractOutboundCompleted(aggregateId);
                case EVENT_SUBCONTRACT_OUTBOUND_REVERSED ->
                        notifySubcontractOutboundReversed(aggregateId);
                case EVENT_SUBCONTRACT_RETURN_DUE ->
                        notifySubcontractReturnDue(aggregateId, payload.path("dueDays").asInt(0));
                case EVENT_MATERIAL_ANALYSIS_READY -> {
                    // Retired planner-ready event: acknowledge old queued deliveries
                    // without recreating a planner task or sending a notice.
                }
                case EVENT_ORDER_CANCELED -> notifyOrderCanceled(aggregateId);
                case EVENT_ORDER_APPROVED, EVENT_ORDER_FINANCE_CONFIRMED, EVENT_SALES_PLANNING_CATCH_UP ->
                        deliverSalesPlanningHandoff(aggregateId,
                                payload.hasNonNull("reviewRevision") ? payload.path("reviewRevision").asLong() : null);
                case EVENT_ORDER_PENDING_FINANCE ->
                        notifyOrderPendingFinanceConfirmation(
                                aggregateId,
                                payload.path("afterModification").asBoolean(false));
                case EVENT_ORDER_FINANCE_REJECTED ->
                        notifyOrderFinanceRejected(aggregateId, payload.path("reason").asText(""));
                case EVENT_DELIVERY_DUE -> {
                    long daysLeft = payload.path("daysLeft").asLong();
                    if (payload.path("daily").asBoolean(false)) {
                        notifyDeliveryDueIfNotSentToday(aggregateId, daysLeft);
                    } else {
                        notifyDeliveryDue(aggregateId, daysLeft);
                    }
                }
                case EVENT_RESERVATION_HOLD_OVERDUE -> {
                    long overdueDays = payload.path("overdueDays").asLong();
                    if (payload.path("daily").asBoolean(false)) {
                        notifyReservationHoldOverdueIfNotSentToday(aggregateId, overdueDays);
                    } else {
                        notifyReservationHoldOverdue(aggregateId, overdueDays);
                    }
                }
                case EVENT_RESERVATION_YIELDED ->
                        notifyReservationYielded(aggregateId, payload.path("qty").asText(""),
                                payload.path("reason").asText(""), payload.path("yielderOrderNo").asText(""));
                case EVENT_PROCUREMENT_FINANCE_SUBMITTED,
                     EVENT_PROCUREMENT_FINANCE_CHANGE_SUBMITTED,
                     EVENT_PROCUREMENT_FINANCE_APPROVED,
                     EVENT_PROCUREMENT_FINANCE_REJECTED ->
                        notifyProcurementFinanceEvent(eventType, aggregateId);
                case EVENT_PROCUREMENT_ARRIVAL_DETECTED,
                     EVENT_PROCUREMENT_ARRIVAL_DECIDED,
                     EVENT_PROCUREMENT_RETURN_REQUIRED,
                     EVENT_PROCUREMENT_RETURN_COMPLETED,
                     EVENT_PROCUREMENT_ARRIVAL_RECEIPT_POSTED ->
                        notifyProcurementArrivalEvent(eventType, aggregateId);
                case EVENT_SUBCONTRACT_SHORT_DELIVERY_DETECTED,
                     EVENT_SUBCONTRACT_SHORT_DELIVERY_WAIT_OVERDUE,
                     EVENT_SUBCONTRACT_SHORT_DELIVERY_RESOLVED ->
                        notifySubcontractShortDeliveryEvent(eventType, aggregateId, payload);
                case EVENT_RD_TASK_FORWARDED -> notifyRdTaskForwarded(aggregateId);
                case EVENT_RD_TASK_RESOLVED -> notifyRdTaskResolved(aggregateId);
                case EVENT_IQC_PENDING ->
                        notifyIqcPendingForQuality(
                                aggregateId, payload.path("receiptType").asText(""));
                case EVENT_IQC_STOCK_IN_PENDING ->
                        notifyIqcStockInPendingForWarehouse(
                                aggregateId,
                                payload.path("receiptType").asText(""),
                                uuidOrNull(payload.path("receiptId").asText(null)));
                case EVENT_IQC_RESOLVED ->
                        notifyIqcResolvedForPutaway(
                                aggregateId, payload.path("receiptType").asText(""));
                case EVENT_IQC_PRE_STOCKED ->
                        notifyIqcPreStockedForQuality(
                                aggregateId, payload.path("receiptType").asText(""));
                case EVENT_SUBCONTRACT_LOSS_OPENED,
                     EVENT_SUBCONTRACT_LOSS_DECIDED,
                     EVENT_SUBCONTRACT_LOSS_FULFILLED,
                     EVENT_SUBCONTRACT_LOSS_REVERSED ->
                        notifySubcontractLossClaimEvent(eventType, aggregateId);
                case EVENT_PROCUREMENT_IQC_REJECTION_OPENED,
                     EVENT_PROCUREMENT_IQC_REJECTION_RETURNED,
                     EVENT_PROCUREMENT_IQC_CREDIT_CONFIRMED,
                     EVENT_PROCUREMENT_IQC_REJECTION_NO_CREDIT,
                     EVENT_PROCUREMENT_IQC_REJECTION_REVERSED,
                     EVENT_PROCUREMENT_IQC_REJECTION_FINANCE_EXCEPTION ->
                        notifyProcurementIqcRejectionEvent(eventType, aggregateId);
                case EVENT_PROCUREMENT_IQC_REJECTION_DETECTED -> {
                    // Internal projection trigger. The domain handler freezes
                    // the rejection case first and emits OPENED (or a safe
                    // FINANCE_EXCEPTION) afterwards; it must not notify twice.
                }
                case EVENT_BOM_UPDATED -> notifyBomUpdated(aggregateId);
                case EVENT_MATERIAL_ANALYSIS_BOM_REFRESH -> deliverMaterialAnalysisBomRefresh(aggregateId, payload);
                case EVENT_PRODUCTION_PLANNING_URGED -> deliverProductionPlanningUrged(aggregateId);
                case "STOCK_WEIGHT_OBSERVATION_CHANGED" -> {
                    // 单重学习重算(ADR-135)由库存模块的领域处理器在同一事务完成, 这里不发通知。
                    // 用字面量而非常量: notice 模块不得引用 stock 模块。
                }
                case "STOCK_COUNT_SUBMITTED", "STOCK_COUNT_APPROVED", "STOCK_COUNT_REJECTED", "STOCK_COUNT_CANCELLED" -> {
                    // StockCountNoticeHandler delivers the scoped review tasks and resolves them in this outbox transaction.
                }
                default -> throw new IllegalArgumentException(
                        "Unsupported business outbox event: " + eventType);
            }
        } finally {
            OUTBOX_EVENT.remove();
            OUTBOX_DELIVERY.remove();
        }
    }

    // ---------- 8 类通知入口（业务 Service 一行调用） ----------

    private void deliverProductionOverLimit(String event,UUID requestId,JsonNode payload) {
        deliverAtomically(() -> {
            Map<String,Object> request=one("""
                    SELECT request.status,request.row_version,request.created_by,request.qty,request.reason,
                           segment.segment_code,plan.maker_id,decision.reason AS decision_reason
                    FROM production_over_limit_dispositions request
                    JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
                    JOIN production_plans plan ON plan.id=request.plan_id
                    LEFT JOIN production_over_limit_decisions decision ON decision.id=request.last_decision_id
                    WHERE request.id=? FOR SHARE OF request
                    """,requestId);
            if(request==null)return;
            String status=str(request.get("status")),route="/production/over-limit-dispositions/"+requestId;
            String code=str(request.get("segment_code"));
            if("WITHDRAWN".equals(status)) {
                noticeService.resolveReviewNotices("PRODUCTION_OVER_LIMIT_DISPOSITION",requestId,"WITHDRAWN");
                return;
            }
            if("PRODUCTION_OVER_LIMIT_PENDING".equals(event)) {
                if(!Set.of("PENDING","HELD","RETURNED").contains(status))return;
                for(UUID user:departmentUserIdsWithSecondaryAuthorities("SUB_PLAN",NOTICE_READ_AUTHORITY,"production_plan:approve")) {
                    if(!canReadProductionAnalysis(user,(UUID)request.get("maker_id")))continue;
                    sendToUser(user,TYPE_APPROVAL,"超限产出待处理："+code,
                        "车间已登记实际产量，其中超限 "+qty(bd(request.get("qty")))+" 待处理。原因："+str(request.get("reason"))
                        +"。允许范围内的产量继续正常办理；请决定本批超限产出的接收方式。",
                        route,event,"normal",requestId);
                }
            } else if("PRODUCTION_OVER_LIMIT_DECIDED".equals(event)) {
                if("ACCEPTED".equals(status))noticeService.resolveReviewNotices("PRODUCTION_OVER_LIMIT_DISPOSITION",requestId,"ACCEPTED");
                // A newer decision supersedes an outbox item that has not been delivered yet.
                if(payload.path("version").asLong(-1)!=((Number)request.get("row_version")).longValue())return;
                String title=switch(status){case "ACCEPTED"->"超限产出已同意接收：";case "RETURNED"->"超限产出需要核实：";default->"超限产出继续待处理：";};
                sendToUser((UUID)request.get("created_by"),TYPE_WORKFLOW,title+code,
                    ("ACCEPTED".equals(status)?"本批已同意接收为公共备货，仍须品质合格并由仓库实际点收。":"实物和实际产量保留，超限部分继续冻结。")
                    +"处理说明："+str(request.get("decision_reason")),route,event,"normal",requestId);
            }
        });
    }

    private void deliverProductionRateReview(String event,UUID requestId) {
        deliverAtomically(() -> {
            Map<String,Object> request=one("""
                    SELECT request.status,request.submitted_by,request.before_rate,request.requested_rate,
                           request.before_snapshot->>'segmentCode' AS segment_code,decision.reason
                    FROM production_overproduction_rate_requests request
                    LEFT JOIN production_overproduction_rate_decisions decision ON decision.request_id=request.id
                    WHERE request.id=?
                    """,requestId);
            if(request==null)return;
            String route="/production/overproduction-rate-requests/"+requestId;
            String code=str(request.get("segment_code"));
            if("PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED".equals(event)) {
                if(!"PENDING".equals(request.get("status")))return;
                for(UUID user:departmentUserIdsWithSecondaryAuthorities("SUB_PLAN",NOTICE_READ_AUTHORITY,"production_plan:approve")) {
                    sendToUser(user,TYPE_APPROVAL,"允许超产比例待审批："+code,
                            "车间申请将允许超产比例从 "+qty(bd(request.get("before_rate")).multiply(new BigDecimal("100")))
                            +"% 调整为 "+qty(bd(request.get("requested_rate")).multiply(new BigDecimal("100")))
                            +"%。请在修改对照中核对红色旧行和绿色新行；审批通过前原比例继续生效。",route,event,"normal",requestId);
                }
            } else {
                String expected="PRODUCTION_OVERPRODUCTION_RATE_APPROVED".equals(event)?"APPROVED":"RETURNED";
                if(!expected.equals(request.get("status")))return;
                boolean approved="APPROVED".equals(expected);
                noticeService.resolveReviewNotices("PRODUCTION_OVERPRODUCTION_RATE_REQUEST",requestId,
                        approved?"APPROVED":"RETURNED");
                sendToUser((UUID)request.get("submitted_by"),TYPE_WORKFLOW,
                        "允许超产比例"+(approved?"已批准：":"已退回：")+code,
                        approved?"计划部已批准调整，请刷新任务查看当前有效比例。"
                                :"计划部退回本次调整，原有效比例未改变。原因："+str(request.get("reason")),
                        route,event,"normal",requestId);
            }
        });
    }

    /**
     * ADR-117 车间催计划：给计划员发一张居中待办卡(卡上点名缺哪几种、是第几次催)。
     *
     * <p>接收人 = 这张物料分析的制单计划员 + 计划 / 生产部门里能在物料分析页下单的人
     * (下达采购委外或下达车间，二者有其一)。同一条催办再催时先撤掉上一轮的卡片再发新的，
     * 计划员桌面上一个车间任务只留一张最新的。计划下够单或任务结束后由核对任务按聚合撤回。
     */
    private void deliverProductionPlanningUrged(UUID urgeId) {
        deliverAtomically(() -> {
            // FOR SHARE：与核对任务的办结 UPDATE 互斥。核对先办结 → 这里等它提交后读到 RESOLVED 不发；
            // 这里先读 → 核对的 UPDATE 等本事务提交，随后撤卡时已能看到本次发出的卡，不会留下撤不掉的卡。
            Map<String, Object> urge = one("""
                    SELECT urge.status, urge.urge_count, urge.gap_kind_count, urge.gap_summary,
                           urge.last_urged_by_name, urge.material_analysis_id, analysis.maker_id,
                           segment.segment_code, goods.name AS product_name, department.name AS workshop_name
                    FROM production_planning_urges urge
                    JOIN production_material_analyses analysis ON analysis.id = urge.material_analysis_id
                    JOIN production_execution_segments segment ON segment.id = urge.execution_segment_id
                    LEFT JOIN goods ON goods.id = segment.product_goods_id
                    LEFT JOIN departments department ON department.id = segment.workshop_department_id
                    WHERE urge.id = ?
                    FOR SHARE OF urge
                    """, urgeId);
            if (urge == null || !"OPEN".equals(urge.get("status"))) return;
            noticeService.resolveReviewNotices(AGGREGATE_PRODUCTION_PLANNING_URGE, urgeId, "RE_URGED");
            UUID analysisId = (UUID) urge.get("material_analysis_id");
            UUID makerEmployeeId = (UUID) urge.get("maker_id");
            Set<UUID> candidates = new LinkedHashSet<>();
            for (String action : List.of("production_material_analysis:notify", "production_material_analysis:generate")) {
                for (String department : List.of("SUB_PLAN", "DEPT_PROD")) {
                    candidates.addAll(departmentUserIdsWithSecondaryAuthorities(department,
                            NOTICE_READ_AUTHORITY, ANALYSIS_VIEW_AUTHORITY, action));
                }
            }
            // 制单计划员与交接后的现负责人不在计划 / 生产部门时也要收到；门槛与部门池同一套权限。
            UUID maker = userIdOfEmployee(makerEmployeeId);
            if (maker != null) candidates.add(maker);
            UUID successor = handoverVisibility == null ? null
                    : userIdOfEmployee(handoverVisibility.currentResponsible("production_plan", makerEmployeeId));
            if (successor != null) candidates.add(successor);
            Set<UUID> recipients = new LinkedHashSet<>();
            for (UUID candidate : candidates) {
                if (canHandlePlanningUrge(candidate) && canReadProductionAnalysis(candidate, makerEmployeeId)) {
                    recipients.add(candidate);
                }
            }
            int times = ((Number) urge.get("urge_count")).intValue();
            String workshop = blankTo(str(urge.get("workshop_name")), "车间");
            String product = blankTo(str(urge.get("product_name")), "产品");
            String title = "车间催你下单：" + workshop + (times > 1 ? "(第 " + times + " 次)" : "");
            String content = workshop + " " + str(urge.get("last_urged_by_name")) + " 在等料开工："
                    + str(urge.get("segment_code")) + " " + product + " 还缺 "
                    + str(urge.get("gap_summary")) + "，计划还没下单。"
                    + "请到物料分析补下单，下够后这张卡会自动消失。";
            String route = "/production/material-analysis?analysisId=" + analysisId;
            for (UUID recipient : recipients) {
                sendToUser(recipient, TYPE_TASK, title, content, route,
                        EVENT_PRODUCTION_PLANNING_URGED, "important", urgeId);
            }
        });
    }

    /** 能办车间催计划：能看通知、能看物料分析，并且能在物料分析页下单(下达采购委外或下达车间)。 */
    private boolean canHandlePlanningUrge(UUID userId) {
        return userHasAllAuthorities(userId, NOTICE_READ_AUTHORITY, ANALYSIS_VIEW_AUTHORITY)
                && (userHasAllAuthorities(userId, "production_material_analysis:notify")
                || userHasAllAuthorities(userId, "production_material_analysis:generate"));
    }

    /**
     * 这个人打开物料分析页能不能看到这份分析——与物料分析详情同一套归属可见范围(生产计划域
     * production_plan)：全量查看(含超管) / 本人制单 / 交接给本人的前任的单 / user_data_scopes
     * 授权的归属人。看不到的人收了卡也打不开，还会泄露物料与数量，所以不发。
     */
    private boolean canReadProductionAnalysis(UUID userId, UUID makerEmployeeId) {
        if (userHasAllAuthorities(userId, "production_plan:view:all")) return true;
        return canReadOwnedDocument(userId, "production_plan", makerEmployeeId);
    }

    /**
     * 归属可见范围(OwnerVisibility 同口径, 不含「查看全部」权限——调用方先判): 本人是归属人 /
     * 交接链上的现负责人 / user_data_scopes 授权了该归属人(按再入职代次)。超管恒可见。
     */
    private boolean canReadOwnedDocument(UUID userId, String scope, UUID ownerEmployeeId) {
        // 交接给别人的单，现负责人照样能看(OwnerVisibility 同一条交接链)。
        UUID responsible = handoverVisibility == null || ownerEmployeeId == null ? null
                : handoverVisibility.currentResponsible(scope, ownerEmployeeId);
        Boolean readable = jdbc.queryForObject("""
                SELECT EXISTS (
                    SELECT 1 FROM users account
                    WHERE account.id = ? AND account.is_deleted = FALSE AND account.status = 'active'
                      AND (
                        account.is_super_admin
                        OR account.employee_id = CAST(? AS uuid)
                        OR account.employee_id = CAST(? AS uuid)
                        OR EXISTS (
                            SELECT 1 FROM user_data_scopes data_scope
                            WHERE data_scope.user_id = account.id AND data_scope.scope = ?
                              AND data_scope.owner_employee_id = CAST(? AS uuid)
                              AND data_scope.owner_employment_generation = (
                                  SELECT count(*) FROM employment_history history
                                  WHERE history.employee_id = data_scope.owner_employee_id
                                    AND history.event_type = 'rehire'))
                      )
                )
                """, Boolean.class, userId, ownerEmployeeId, responsible, scope, ownerEmployeeId);
        return Boolean.TRUE.equals(readable);
    }

    private boolean userHasAllAuthorities(UUID userId, String... authorities) {
        Set<String> required = Set.of(authorities);
        return userRepo.findById(userId)
                .filter(account -> !account.isDeleted() && "active".equals(account.getStatus()))
                .map(permissionResolver::permsOf)
                .map(permissions -> permissions.containsAll(required))
                .orElse(false);
    }

    private static String blankTo(String value, String fallback) {
        return value == null || value.isBlank() ? fallback : value.strip();
    }

    private void deliverProductionMaterialIncrementReview(String event, UUID requestId) {
        deliverAtomically(() -> {
            Map<String, Object> request = one("""
                    SELECT request.status, request.submitted_by, request.delta_qty,
                           request.before_snapshot->>'segmentCode' AS segment_code,
                           request.after_snapshot->'items'->0->>'goodsName' AS goods_name,
                           decision.reason
                    FROM production_material_increment_requests request
                    LEFT JOIN production_material_increment_decisions decision ON decision.request_id=request.id
                    WHERE request.id=?
                    """, requestId);
            if (request == null) return;
            String route = "/production/material-increment-requests/" + requestId;
            String code = str(request.get("segment_code"));
            if ("PRODUCTION_MATERIAL_INCREMENT_SUBMITTED".equals(event)) {
                if (!"PENDING".equals(request.get("status"))) return;
                for (UUID user : departmentUserIdsWithSecondaryAuthorities("SUB_PLAN", NOTICE_READ_AUTHORITY, "production_plan:approve")) {
                    sendToUser(user, TYPE_APPROVAL, "追加用料待审批：" + code,
                            "车间申请追加 " + str(request.get("goods_name")) + " " + qty(bd(request.get("delta_qty")))
                                    + "。请核对原定额、已批追加与本次追加量；批准后由仓库实际发料。",
                            route, event, "normal", requestId);
                }
            } else {
                String decision = switch (event) {
                    case "PRODUCTION_MATERIAL_INCREMENT_APPROVED" -> "APPROVED";
                    case "PRODUCTION_MATERIAL_INCREMENT_CANCELLED" -> "CANCELLED";
                    default -> "RETURNED";
                };
                if (!decision.equals(request.get("status"))) return;
                noticeService.resolveReviewNotices("PRODUCTION_MATERIAL_INCREMENT_REQUEST", requestId, decision);
                boolean approved = "APPROVED".equals(decision);
                boolean cancelled = "CANCELLED".equals(decision);
                sendToUser((UUID) request.get("submitted_by"), TYPE_WORKFLOW,
                        "追加用料" + (approved ? "已批准：" : cancelled ? "授权已撤销：" : "已退回：") + code,
                        approved ? "计划部已批准追加用料，请到车间任务核对备料和领料进度。"
                                : cancelled ? "本次追加用料授权已撤销，原定额与历史实发、退料记录保留。"
                                : "计划部退回本次申请，原有用料额度未改变。原因：" + str(request.get("reason")),
                        route, event, "normal", requestId);
            }
        });
    }

    /**
     * 待登记实际领料卡只按投递时的现状重建: 先撤后发, 现状不在办只撤。同一申请的投递按申请串行(Outbox 按
     * SKIP LOCKED 多消费者投递): 先拿锁再读现状, 在途投递在计划停止前读到「仍在办」插的卡, 必在停止后的
     * 可见性投递办结之前提交; 任意先后到达的待领料/可见性事件都收敛到每人至多一张卡。
     */
    private void deliverMaterialDiscovery(String event,UUID requestId) {
        deliverAtomically(()->{
            lockMaterialDiscoveryNotices(requestId);
            Map<String,Object> request=one("""
                    SELECT request.status,segment.segment_code,package.warehouse_id,goods.name AS goods_name,
                           (NOT segment.is_deleted AND segment.status IN('READY','DISPATCHED') AND plan.status=1
                            AND NOT plan.is_deleted AND NOT plan.is_closed AND NOT plan.is_canceled AND NOT plan.is_stopped) AS active
                    FROM production_material_discovery_requests request
                    JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
                    JOIN production_plans plan ON plan.id=segment.plan_id
                    JOIN production_planning_packages package ON package.id=segment.package_id
                    JOIN goods ON goods.id=segment.product_goods_id WHERE request.id=?
                    """,requestId);
            if(request==null)return;
            if(!"PENDING".equals(request.get("status"))||!Boolean.TRUE.equals(request.get("active"))) {
                noticeService.resolveReviewNotices("PRODUCTION_MATERIAL_DISCOVERY_REQUEST",requestId,"STATE_CHANGED");return;
            }
            if(!"PRODUCTION_MATERIAL_DISCOVERY_PENDING".equals(event)&&!"PRODUCTION_MATERIAL_DISCOVERY_VISIBILITY".equals(event))return;
            noticeService.resolveReviewNotices("PRODUCTION_MATERIAL_DISCOVERY_REQUEST",requestId,"REFRESHED");
            for(UUID user:warehouseRecipients(warehousePool("stock_doc:view","stock_doc:approve","stock_doc:issue"),warehouseIdsOf(request.get("warehouse_id")))) {
                sendToUser(user,TYPE_TASK,"待登记实际领料："+str(request.get("segment_code")),
                        "车间申请生产「"+str(request.get("goods_name"))+"」。请与领料人核对材料，在生产领料任务中填写物料、数量和实际仓库。",
                        "/warehouse/tasks/draw","PRODUCTION_MATERIAL_DISCOVERY_PENDING",null,requestId);
            }
        });
    }

    /** 同一领料申请的待登记卡在投递之间串行重建; 只在 Outbox 投递事务里取, 业务事务从不取, 不参与业务锁顺序。 */
    private void lockMaterialDiscoveryNotices(UUID requestId) {
        jdbc.queryForObject("SELECT pg_advisory_xact_lock(hashtextextended(?, 0))::text",
                String.class, "material-discovery-notice:" + requestId);
    }

    /** ① 排产通知销售：计划单审核后，按订单聚合本次排产量。shortage=true 时另发缺料通知（⑧）。 */
    public void notifyPlanScheduled(UUID planId, boolean shortage) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_PLAN_SCHEDULED, "PRODUCTION_PLAN", planId,
                    Map.of("shortage", shortage));
            return;
        }
        deliverPlansScheduled(List.of(new PlanScheduled(planId, shortage)));
    }

    /** 排产事件载荷：计划单 + 是否真实缺料（分配核验后的及时缺口）。 */
    public record PlanScheduled(UUID planId, boolean shortage) {}

    /**
     * Outbox 合并投递入口（仅锁定的事务内被处理器调用）：批量审核同一订单的
     * 多张计划单（计划单与货品 1:1 不合单）会把 N 个事件一次性提交进 outbox；
     * 逐条投递会让销售按货品收到 N 条排产通知。处理器把同批待投递事件合并
     * 交给这里，按订单各合成一条排产/缺料通知；车间任务卡仍按计划单逐张下发。
     */
    public void deliverPlanScheduledGroup(List<PlanScheduled> plans) {
        if (plans.isEmpty()) return;
        OUTBOX_DELIVERY.set(true);
        OUTBOX_EVENT.set(EVENT_PLAN_SCHEDULED);
        try {
            deliverPlansScheduled(plans);
        } finally {
            OUTBOX_EVENT.remove();
            OUTBOX_DELIVERY.remove();
        }
    }

    private void deliverPlansScheduled(List<PlanScheduled> plans) {
        deliverAtomically(() -> {
            Map<UUID, BigDecimal> byOrder = new LinkedHashMap<>();
            Map<UUID, LinkedHashSet<String>> goodsByOrder = new LinkedHashMap<>();
            Map<UUID, Set<UUID>> plansByOrder = new LinkedHashMap<>();
            Map<UUID, String> planNoById = new LinkedHashMap<>();
            for (PlanScheduled ps : plans) {
                String planNo = oneStr("SELECT bill_no FROM production_plans WHERE id = ?", ps.planId());
                if (planNo == null) continue;
                planNoById.put(ps.planId(), planNo);
                for (Map<String, Object> r : jdbc.queryForList("""
                        SELECT oi.order_id, SUM(l.allocated_qty) AS qty, g.code AS goods
                        FROM plan_order_item_links l
                        JOIN sales_order_items oi ON oi.id = l.order_item_id
                        JOIN production_plan_items pi ON pi.id = l.plan_item_id
                        LEFT JOIN goods g ON g.id = pi.goods_id
                        WHERE pi.plan_id = ? AND l.is_deleted = false AND l.source = 0
                        GROUP BY oi.order_id, g.code
                        """, ps.planId())) {
                    UUID orderId = (UUID) r.get("order_id");
                    byOrder.merge(orderId, bd(r.get("qty")), BigDecimal::add);
                    goodsByOrder.computeIfAbsent(orderId, k -> new LinkedHashSet<>())
                            .add(str(r.get("goods")));
                    plansByOrder.computeIfAbsent(orderId, k -> new LinkedHashSet<>())
                            .add(ps.planId());
                }
            }
            for (var e : byOrder.entrySet()) {
                OrderRef o = orderRef(e.getKey());
                if (o == null) continue;
                Set<UUID> orderPlans = plansByOrder.getOrDefault(e.getKey(), Set.of());
                UUID onlyPlan = orderPlans.size() == 1 ? orderPlans.iterator().next() : null;
                notifyUser(o.ownerUserId(), TYPE_WORKFLOW,
                        "排产通知：" + o.billNo(),
                        "订单 " + o.billNo() + " 货品 "
                                + String.join("/", goodsByOrder.get(e.getKey()))
                                + " 已排产 " + qty(e.getValue())
                                + (onlyPlan != null
                                        ? "(计划单 " + planNoById.get(onlyPlan) + ")"
                                        : "(共 " + orderPlans.size() + " 张计划单)")
                                + "。",
                        o.route());
                if (plans.stream().anyMatch(ps -> ps.shortage() && orderPlans.contains(ps.planId()))) {
                    sendToUser(o.ownerUserId(), TYPE_URGENT,
                            "生产缺料：" + o.billNo(),
                            "订单 " + o.billNo() + " 的"
                                    + (onlyPlan != null
                                            ? "计划单 " + planNoById.get(onlyPlan)
                                            : " " + orderPlans.size() + " 张计划单")
                                    + " 已核验存在及时物料缺口，采购/调度已收到处理任务；"
                                    + "销售端排产进度会随到料、开工和完工继续更新。",
                            o.route(), null, "normal");
                }
            }
            List<PlanScheduled> shortagePlans = plans.stream()
                    .filter(ps -> ps.shortage() && planNoById.containsKey(ps.planId()))
                    .toList();
            if (!shortagePlans.isEmpty()) {
                if (shortagePlans.size() == 1) {
                    PlanScheduled ps = shortagePlans.get(0);
                    notifyDepartmentPool(PLAN_VIEW_AUTHORITY, List.of("SUB_PURCHASE", "SUB_PLAN"), TYPE_TASK,
                            "缺料提醒：" + planNoById.get(ps.planId()),
                            "计划单 " + planNoById.get(ps.planId())
                                    + " 审核后 BOM 净需求不足(订单行状态=待物料)，请采购/调度跟进备料。",
                            "/production/plans/" + ps.planId());
                } else {
                    notifyDepartmentPool(PLAN_VIEW_AUTHORITY, List.of("SUB_PURCHASE", "SUB_PLAN"), TYPE_TASK,
                            "缺料提醒：" + shortagePlans.size() + " 张计划单",
                            "计划单 " + planNoById.get(shortagePlans.get(0).planId()) + " 等 "
                                    + shortagePlans.size()
                                    + " 张审核后 BOM 净需求不足(订单行状态=待物料)，请采购/调度跟进备料。",
                            "/production/plans");
                }
            }
            for (PlanScheduled ps : plans) {
                publishWorkshopTasksForPlan(
                        ps.planId(), "生产计划已审核下达");
            }
        });
    }

    /**
     * 报工审核后通知归属销售。销售端进度直接读取订单/计划累计量，本通知只做可靠提醒，
     * 不复制一份易漂移的“进度状态”；Outbox 默认 2 秒轮询，正常情况下十秒内可见。
     */
    public void notifyProductionReported(UUID reportId) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_PRODUCTION_REPORTED,
                    "PRODUCTION_DAILY_REPORT", reportId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            String reportNo = oneStr(
                    "SELECT bill_no FROM production_daily_reports WHERE id = ?", reportId);
            for (Map<String, Object> r : jdbc.queryForList("""
                    WITH affected AS (
                        SELECT DISTINCT allocation.sales_order_item_id AS order_item_id
                        FROM production_daily_report_items ri
                        JOIN execution_segment_sales_allocations allocation
                          ON allocation.id =
                             ri.execution_segment_sales_allocation_id
                        WHERE ri.report_id = ?
                          AND ri.is_deleted = false
                        UNION
                        SELECT DISTINCT ri.sales_order_item_id AS order_item_id
                        FROM production_daily_report_items ri
                        WHERE ri.report_id = ?
                          AND ri.is_deleted = false
                          AND ri.sales_order_item_id IS NOT NULL
                        UNION
                        SELECT DISTINCT l.order_item_id AS order_item_id
                        FROM production_daily_report_items ri
                        JOIN plan_order_item_links l
                          ON l.plan_item_id = ri.plan_item_id
                         AND l.is_deleted = false
                        WHERE ri.report_id = ?
                          AND ri.is_deleted = false
                          AND ri.execution_segment_id IS NULL
                          AND ri.sales_order_item_id IS NULL
                    )
                    SELECT oi.order_id,
                           SUM(COALESCE(oi.produced_qty,0)) AS produced_qty,
                           SUM(COALESCE(oi.planned_qty,0)) AS planned_qty,
                           SUM(COALESCE(oi.qty,0)) AS order_qty,
                           string_agg(DISTINCT g.code, ' / ') AS goods
                    FROM affected a
                    JOIN sales_order_items oi ON oi.id = a.order_item_id
                    LEFT JOIN goods g ON g.id = oi.goods_id
                    WHERE oi.is_deleted = false
                    GROUP BY oi.order_id
                    """, reportId, reportId, reportId)) {
                OrderRef order = orderRef((UUID) r.get("order_id"));
                if (order == null) continue;
                BigDecimal produced = bd(r.get("produced_qty"));
                BigDecimal planned = bd(r.get("planned_qty"));
                boolean reportedComplete =
                        planned.signum() > 0 && produced.compareTo(planned) >= 0;
                notifyUser(order.ownerUserId(), TYPE_WORKFLOW,
                        (reportedComplete
                                ? "生产报工完成(待仓库登记/质检/点收)："
                                : "生产进度更新：")
                                + order.billNo(),
                        "订单 " + order.billNo() + " 货品 " + str(r.get("goods"))
                                + " 的报工单 " + reportNo
                                + " 已审核，累计完工申报 "
                                + qty(produced) + "/已排产 " + qty(planned)
                                + "(订单数量 " + qty(bd(r.get("order_qty"))) + ")。"
                                + (reportedComplete
                                ? "等待仓库登记送检、品质放行和最终点收；"
                                + "只有最终点收增加可用库存并更新可发货状态。"
                                : ""),
                        order.route(), EVENT_PRODUCTION_REPORTED);
            }
        });
    }

    /** ②③ 完工/部分完工通知销售：仓库最终点收后，按本单补的预留溯源订单行。 */
    public void notifyFinishedInbound(UUID stockDocId) {
        if (!isOutboxDelivery()) {
            List<Map<String, String>> allocations = finishedInboundSnapshot(stockDocId)
                    .stream()
                    .map(FinishedInboundSnapshot::payload)
                    .toList();
            outbox.publish(
                    EVENT_FINISHED_INBOUND,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    Map.of("allocations", allocations));
            return;
        }
        deliverFinishedInbound(stockDocId, null);
    }

    private void deliverFinishedInbound(UUID stockDocId, JsonNode payload) {
        deliverAtomically(() -> {
            // 完工入库审核时 DB 触发器 fn_reconcile_execution_segment_completion 已把
            // 满足条件的执行段置 COMPLETED；此处按本单关联段兜底办结「车间任务」卡
            //（开工已办结的段幂等无事；未经 START 直接完工的段靠这里收卡）。
            resolveProductionWorkshopTasks(
                    completedSegmentsOfFinishedInbound(stockDocId), "COMPLETED");
            List<FinishedInboundSnapshot> allocations =
                    finishedInboundPayload(payload);
            if (allocations.isEmpty()
                    && (payload == null || !payload.has("allocations"))) {
                // Compatibility for durable events written before the snapshot
                // payload was introduced.
                allocations = finishedInboundSnapshot(stockDocId);
            }
            for (FinishedInboundSnapshot allocation : allocations) {
                OrderRef order = orderRef(allocation.orderId());
                if (order == null) continue;
                String orderNo = allocation.orderBillNo().isBlank()
                        ? order.billNo() : allocation.orderBillNo();
                boolean completeShipmentRequired =
                        "REQUIRE_COMPLETE".equals(allocation.shipmentPolicy())
                                && allocation.producedQty()
                                        .compareTo(allocation.orderQty()) < 0;
                String availability = completeShipmentRequired
                        ? "本批新增成品预留 " + qty(allocation.batchQty())
                                + "；该订单要求整单齐套，当前暂不可分批发货。"
                        : "本批新增可发数量 " + qty(allocation.batchQty())
                                + "，可按订单策略安排分批发货。";
                String content = "订单 " + orderNo + " 货品 "
                        + allocation.goods() + " 已完成成品入库(入库单 "
                        + allocation.documentNo() + ")。" + availability
                        + " 累计成品入库 " + qty(allocation.producedQty())
                        + "/订货 " + qty(allocation.orderQty()) + "。";
                notifyUser(
                        order.ownerUserId(),
                        TYPE_WORKFLOW,
                        "本批成品已入库：" + orderNo,
                        content,
                        order.route(),
                        EVENT_FINISHED_INBOUND);
                notifyDepartmentPool(
                        PLAN_VIEW_AUTHORITY,
                        List.of("SUB_PLAN"),
                        TYPE_WORKFLOW,
                        "生产批次已入库：" + orderNo,
                        content,
                        "/production/plans");
                // V459 累计入库满足订货量 → 「全部完成生产，可以发货」审核卡
                // （归属人定向：仅负责销售本人；开立出货单后撤回）。
                if (allocation.orderQty().signum() > 0
                        && allocation.producedQty()
                                .compareTo(allocation.orderQty()) >= 0) {
                    notifyFullyProducedReadyToShip(order, orderNo);
                }
            }
        });
    }

    /**
     * V459 全部完工可发货（R12）：同一订单同事件存在未办结通知则不重发
     * （分批入库多次触发只有第一次生效；出货单开立或订单终态后撤回）。
     */
    private void notifyFullyProducedReadyToShip(OrderRef order, String orderNo) {
        Integer existing = jdbc.queryForObject("""
                SELECT COUNT(*) FROM notices
                WHERE source_event = ?
                  AND aggregate_kind = 'SALES_ORDER'
                  AND aggregate_id = ?
                  AND resolved_at IS NULL
                """, Integer.class,
                EVENT_ORDER_FULLY_PRODUCED_READY_TO_SHIP, order.orderId());
        if (existing != null && existing > 0) return;
        sendToUser(
                order.ownerUserId(),
                TYPE_TASK,
                "全部完成生产，可以发货：" + orderNo,
                "订单 " + orderNo + " 的累计成品入库已满足订货量，全部完成生产，"
                        + "可以发货。请及时开出货单；财务放行后仓库即可出库。",
                order.route(),
                EVENT_ORDER_FULLY_PRODUCED_READY_TO_SHIP,
                "important",
                order.orderId());
    }

    private List<FinishedInboundSnapshot> finishedInboundSnapshot(
            UUID stockDocId) {
        if (stockDocId == null) return List.of();
        return jdbc.queryForList("""
                WITH inbound_item AS (
                    SELECT reservation.order_item_id,
                           SUM(
                               reservation.qty
                               / CASE
                                   WHEN COALESCE(item.unit_rate, 1) > 0
                                       THEN COALESCE(item.unit_rate, 1)
                                   ELSE 1
                                 END
                           ) AS batch_qty
                    FROM stock_reservations reservation
                    JOIN sales_order_items item
                      ON item.id = reservation.order_item_id
                     AND item.is_deleted = FALSE
                    WHERE reservation.source_doc_type = 'PRODUCTION_INBOUND'
                      AND reservation.source_doc_id = ?
                      AND reservation.order_item_id IS NOT NULL
                      AND reservation.is_deleted = FALSE
                      AND COALESCE(reservation.released_qty, 0)
                            < reservation.qty
                    GROUP BY reservation.order_item_id
                ), affected AS (
                    SELECT item.order_id,
                           SUM(inbound_item.batch_qty) AS batch_qty,
                           string_agg(DISTINCT goods.code, ' / ') AS goods
                    FROM inbound_item
                    JOIN sales_order_items item
                      ON item.id = inbound_item.order_item_id
                     AND item.is_deleted = FALSE
                    LEFT JOIN goods ON goods.id = item.goods_id
                    GROUP BY item.order_id
                ), order_totals AS (
                    SELECT item.order_id,
                           SUM(COALESCE(item.produced_qty, 0)) AS produced_qty,
                           SUM(COALESCE(item.qty, 0)) AS order_qty
                    FROM sales_order_items item
                    WHERE item.is_deleted = FALSE
                    GROUP BY item.order_id
                )
                SELECT affected.order_id,
                       sales_order.bill_no AS order_bill_no,
                       document.bill_no AS document_no,
                       affected.goods,
                       affected.batch_qty,
                       order_totals.produced_qty,
                       order_totals.order_qty,
                       COALESCE(sales_order.shipment_policy, 'ALLOW_PARTIAL')
                           AS shipment_policy
                FROM affected
                JOIN sales_orders sales_order
                  ON sales_order.id = affected.order_id
                 AND sales_order.is_deleted = FALSE
                JOIN order_totals
                  ON order_totals.order_id = affected.order_id
                JOIN stock_documents document
                  ON document.id = ?
                ORDER BY affected.order_id
                """, stockDocId, stockDocId).stream()
                .map(row -> new FinishedInboundSnapshot(
                        (UUID) row.get("order_id"),
                        str(row.get("order_bill_no")),
                        str(row.get("document_no")),
                        str(row.get("goods")),
                        bd(row.get("batch_qty")),
                        bd(row.get("produced_qty")),
                        bd(row.get("order_qty")),
                        str(row.get("shipment_policy"))))
                .toList();
    }

    private List<FinishedInboundSnapshot> finishedInboundPayload(
            JsonNode payload) {
        if (payload == null || !payload.path("allocations").isArray()) {
            return List.of();
        }
        List<FinishedInboundSnapshot> result = new ArrayList<>();
        for (JsonNode allocation : payload.path("allocations")) {
            UUID orderId = uuidOrNull(allocation.path("orderId").asText(""));
            if (orderId == null) continue;
            result.add(new FinishedInboundSnapshot(
                    orderId,
                    allocation.path("orderBillNo").asText(""),
                    allocation.path("documentNo").asText(""),
                    allocation.path("goods").asText(""),
                    decimal(allocation.path("batchQty").asText("0")),
                    decimal(allocation.path("producedQty").asText("0")),
                    decimal(allocation.path("orderQty").asText("0")),
                    allocation.path("shipmentPolicy")
                            .asText("ALLOW_PARTIAL")));
        }
        return List.copyOf(result);
    }

    /** 报工生成成品入库草稿后，给仓库部门投递一次待审核任务。 */
    public void notifyFinishedInboundPending(UUID stockDocId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_FINISHED_INBOUND_PENDING,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    Map.of(),
                    EVENT_FINISHED_INBOUND_PENDING + ':' + stockDocId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one("""
                    SELECT stock.bill_no, stock.source_doc_no,
                           warehouse.name AS warehouse_name,
                           stock.warehouse_id
                    FROM stock_documents stock
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = stock.warehouse_id
                    WHERE stock.id = ?
                      AND stock.doc_type = 'FINISHED_IN'
                      AND stock.status = 0
                      AND stock.is_deleted = FALSE
                    """, stockDocId);
            if (document == null) return;
            String billNo = str(document.get("bill_no"));
            String sourceNo = str(document.get("source_doc_no"));
            String warehouse = str(document.get("warehouse_name"));
            String content = "成品入库单 " + billNo
                    + (sourceNo.isBlank() ? "" : "(来源报工 " + sourceNo + ")")
                    + " 已生成并等待仓库审核"
                    + (warehouse.isBlank() ? "。" : "，目标仓库 " + warehouse + "。")
                    + "请核对实物、数量和库位后处理；通知不代替库存审核。";
            for (UUID warehouseUser : warehouseRecipients(warehousePool("stock_doc:approve"), warehouseIdsOf(document.get("warehouse_id")))) {
                sendToUser(
                        warehouseUser,
                        TYPE_TASK,
                        "待审核成品入库：" + billNo,
                        content,
                        "/warehouse/FINISHED_IN/" + stockDocId,
                        EVENT_FINISHED_INBOUND_PENDING);
            }
        });
    }

    /** 新执行段报工审核后，可靠投递仓库目标仓/库位送检登记待办。 */
    public void notifyProductionFinishedArrivalPending(UUID reportId) {
        Map<String, Object> report = pendingProductionFinishedArrival(reportId);
        if (report == null) return;
        String reportNo = str(report.get("bill_no"));
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING,
                    "PRODUCTION_DAILY_REPORT",
                    reportId,
                    Map.of("reportId", reportId, "reportNo", reportNo),
                    EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING + ':' + reportId);
            return;
        }
        deliverAtomically(() -> {
            // 目标仓要到登记时才选; 先按成品货品主档的「所属仓库」(V587, 入库后回写为最近落仓)
            // 找负责人, 没登记所属仓库的成品照旧发给整个仓库部门。
            List<UUID> productWarehouses = warehouseIdsQuery("""
                    SELECT DISTINCT goods.owning_warehouse_id
                    FROM v_production_report_items_pending_registration pending
                    JOIN production_daily_report_items item ON item.id = pending.report_item_id
                    JOIN goods ON goods.id = item.goods_id
                    WHERE pending.report_id = ?
                    """, reportId);
            for (UUID warehouseUser : warehouseRecipients(warehousePool("stock_doc:view", "stock_doc:approve"), productWarehouses)) {
                sendToUser(
                        warehouseUser,
                        TYPE_TASK,
                        "待登记生产成品送检：" + reportNo,
                        "生产报工单 " + reportNo
                                + " 已审核，请仓库核对实物并登记成品目标仓、库位，"
                                + "然后送品质终检。通知不代替仓库任务队列、品质放行或库存事实。",
                        "/warehouse/production-finished-in/tasks",
                        EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING);
            }
        });
    }

    private Map<String, Object> pendingProductionFinishedArrival(UUID reportId) {
        if (reportId == null) return null;
        return one("""
                SELECT report.id, report.bill_no
                FROM production_daily_reports report
                WHERE report.id = ?
                  AND report.status = 1
                  AND report.is_deleted = FALSE
                  AND EXISTS (
                      SELECT 1
                      FROM v_production_report_items_pending_registration pending
                      WHERE pending.report_id = report.id)
                """, reportId);
    }

    /** 仓库零实收拒收后，可靠退回生产/计划岗位更正报工或重新交接。 */
    public void notifyFinishedInboundRejected(
            UUID stockDocId,
            String reason,
            String confirmationIdempotencyKey) {
        if (!isOutboxDelivery()) {
            if (confirmationIdempotencyKey == null
                    || confirmationIdempotencyKey.isBlank()) {
                throw new IllegalArgumentException(
                        "confirmationIdempotencyKey is required for rejection notice");
            }
            outbox.publishOnce(
                    EVENT_FINISHED_INBOUND_REJECTED,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    Map.of("reason", reason == null ? "" : reason),
                    EVENT_FINISHED_INBOUND_REJECTED + ':' + stockDocId + ':'
                            + confirmationIdempotencyKey.strip());
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one("""
                    SELECT stock.bill_no, stock.plan_no,
                           stock.source_daily_report_id,
                           stock.source_doc_no,
                           report_maker_user.id AS report_maker_user_id
                    FROM stock_documents stock
                    LEFT JOIN production_daily_reports report
                      ON report.id = stock.source_daily_report_id
                     AND report.is_deleted = FALSE
                    LEFT JOIN users report_maker_user
                      ON report_maker_user.employee_id = report.maker_id
                     AND report_maker_user.is_deleted = FALSE
                     AND report_maker_user.status = 'active'
                    WHERE stock.id = ?
                      AND stock.doc_type = 'FINISHED_IN'
                      AND stock.status = -1
                      AND stock.is_deleted = FALSE
                    """, stockDocId);
            if (document == null) return;
            String billNo = str(document.get("bill_no"));
            String planNo = str(document.get("plan_no"));
            String reportNo = str(document.get("source_doc_no"));
            UUID reportId = (UUID) document.get("source_daily_report_id");
            String content = "仓库点收成品入库单 " + billNo + " 时确认整单实收为 0"
                    + (reportNo.isBlank() ? "" : "(来源报工 " + reportNo + ")")
                    + (planNo.isBlank() ? "" : "，生产计划 " + planNo)
                    + "。拒收原因：" + (reason == null || reason.isBlank()
                            ? "未填写"
                            : reason)
                    + "。本次未增加库存或入库累计，请生产主管核对实物并更正/红冲报工。";
            UUID reportMakerUserId = (UUID) document.get(
                    "report_maker_user_id");
            Set<UUID> recipients = new LinkedHashSet<>();
            recipients.addAll(departmentUserIdsWithAuthority(
                    "DEPT_PROD", "production_daily_report:approve"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "DEPT_PROD", "production_daily_report:reverse"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "SUB_PLAN", "production_daily_report:approve"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "SUB_PLAN", "production_daily_report:reverse"));
            String route = reportId == null
                    ? "/production/daily-reports"
                    : "/production/daily-reports/" + reportId;
            if (reportMakerUserId != null) {
                sendToUser(
                        reportMakerUserId,
                        TYPE_URGENT,
                        "成品入库被仓库拒收：" + billNo,
                        content,
                        route,
                        EVENT_FINISHED_INBOUND_REJECTED);
                recipients.remove(reportMakerUserId);
            }
            for (UUID recipient : recipients) {
                sendToUser(
                        recipient,
                        TYPE_URGENT,
                        "成品入库被仓库拒收：" + billNo,
                        content,
                        route,
                        EVENT_FINISHED_INBOUND_REJECTED,
                        "normal");
            }
        });
    }

    /** 已点收成品被专用红冲后，提醒生产责任人并指明已重建仓库待点收任务。 */
    public void notifyFinishedInboundReversed(
            UUID stockDocId, UUID replacementStockDocId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_FINISHED_INBOUND_REVERSED,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    replacementStockDocId == null
                            ? Map.of()
                            : Map.of("replacementStockDocId",
                                    replacementStockDocId.toString()),
                    EVENT_FINISHED_INBOUND_REVERSED + ':' + stockDocId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one("""
                    SELECT source.bill_no, source.plan_no,
                           source.source_daily_report_id,
                           source.source_doc_no,
                           replacement.bill_no AS replacement_bill_no,
                           report_maker_user.id AS report_maker_user_id
                    FROM production_finished_in_confirmation_reversals reversal
                    JOIN stock_documents source
                      ON source.id = reversal.reversed_stock_document_id
                     AND source.status = -1
                     AND source.is_deleted = FALSE
                    JOIN stock_documents replacement
                      ON replacement.id =
                         reversal.replacement_stock_document_id
                     AND replacement.status = 0
                     AND replacement.is_deleted = FALSE
                    LEFT JOIN production_daily_reports report
                      ON report.id = source.source_daily_report_id
                     AND report.is_deleted = FALSE
                    LEFT JOIN users report_maker_user
                      ON report_maker_user.employee_id = report.maker_id
                     AND report_maker_user.is_deleted = FALSE
                     AND report_maker_user.status = 'active'
                    WHERE source.id = ?
                    """, stockDocId);
            if (document == null) return;
            String sourceNo = str(document.get("bill_no"));
            String replacementNo = str(document.get("replacement_bill_no"));
            String reportNo = str(document.get("source_doc_no"));
            UUID reportId = (UUID) document.get("source_daily_report_id");
            UUID reportMakerUserId = (UUID) document.get(
                    "report_maker_user_id");
            Set<UUID> recipients = new LinkedHashSet<>();
            recipients.addAll(departmentUserIdsWithAuthority(
                    "DEPT_PROD", "production_daily_report:approve"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "DEPT_PROD", "production_daily_report:reverse"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "SUB_PLAN", "production_daily_report:approve"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "SUB_PLAN", "production_daily_report:reverse"));
            String route = reportId == null
                    ? "/production/daily-reports"
                    : "/production/daily-reports/" + reportId;
            String content = "仓库已红冲成品入库单 " + sourceNo
                    + (reportNo.isBlank() ? "" : "(来源报工 " + reportNo + ")")
                    + "，原实收数量已从库存和入库累计回退，并重建待点收单 "
                    + replacementNo
                    + "。请核对生产实物与报工；通知不代替仓库重新点收。";
            if (reportMakerUserId != null) {
                sendToUser(
                        reportMakerUserId,
                        TYPE_URGENT,
                        "成品点收已红冲：" + sourceNo,
                        content,
                        route,
                        EVENT_FINISHED_INBOUND_REVERSED);
                recipients.remove(reportMakerUserId);
            }
            for (UUID recipient : recipients) {
                sendToUser(
                        recipient,
                        TYPE_URGENT,
                        "成品点收已红冲：" + sourceNo,
                        content,
                        route,
                        EVENT_FINISHED_INBOUND_REVERSED,
                        "normal");
            }
        });
    }

    /** 车间明确申请后，把真实 DRAW 草稿可靠投递给仓库任务人员。 */
    public void notifyProductionDrawPending(UUID stockDocId) {
        if (!isOutboxDelivery()) {
            if (!Boolean.TRUE.equals(jdbc.queryForObject(
                    "SELECT fn_production_draw_pending(?)", Boolean.class, stockDocId))) {
                return;
            }
            outbox.publishOnce(
                    EVENT_PRODUCTION_DRAW_PENDING,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    Map.of(),
                    EVENT_PRODUCTION_DRAW_PENDING + ":REQUESTED:" + stockDocId + ":"
                        + jdbc.queryForObject("""
                            SELECT COALESCE((SELECT event.id::text FROM production_execution_segment_events event
                            WHERE event.action='DRAW_REQUEST' AND event.draw_document_ids @> ARRAY[?]::uuid[]
                            ORDER BY event.created_at DESC,event.id DESC LIMIT 1),'LEGACY')
                            """, String.class, stockDocId));
            return;
        }
        deliverAtomically(() -> deliverProductionDrawPending(stockDocId, false));
    }

    /** Assignment has its own durable intent; the same pending handler always renders current facts. */
    public void notifyProductionDrawReassigned(UUID stockDocId, UUID segmentId, long resultingVersion) {
        if (!Boolean.TRUE.equals(jdbc.queryForObject(
                "SELECT fn_production_draw_pending(?)", Boolean.class, stockDocId))) return;
        outbox.publishOnce(EVENT_PRODUCTION_DRAW_PENDING,"STOCK_DOCUMENT",stockDocId,Map.of(),
                EVENT_PRODUCTION_DRAW_PENDING+":ASSIGNMENT:"+segmentId+":"+resultingVersion+":"+stockDocId);
    }

    /** A return may remove every pending line; delivery must also retire that old card. */
    public void notifyProductionDrawInstructionsChanged(UUID stockDocId, UUID confirmationId, boolean reverse) {
        outbox.publishOnce(EVENT_PRODUCTION_DRAW_PENDING,"STOCK_DOCUMENT",stockDocId,Map.of(),
                EVENT_PRODUCTION_DRAW_PENDING+":RETURN_INSTRUCTIONS:"+confirmationId+":"+(reverse?"RESTORE":"REDUCE")+":"+stockDocId);
    }

    private void deliverProductionDrawPending(UUID stockDocId, boolean preserveExistingPending) {
        jdbc.queryForList("SELECT id FROM stock_documents WHERE id=? FOR UPDATE",UUID.class,stockDocId);
        Map<String, Object> document = one("""
                SELECT stock.bill_no, stock.plan_no,
                       warehouse.name AS warehouse_name,
                       stock.warehouse_id,
                       department.name AS department_name,
                       worker.full_name AS worker_name,
                       COUNT(item.id) AS line_count
                FROM stock_documents stock
                LEFT JOIN warehouses warehouse
                  ON warehouse.id = stock.warehouse_id
                LEFT JOIN departments department
                  ON department.id = stock.department_id
                LEFT JOIN employees worker ON worker.id=stock.worker_id
                JOIN stock_document_items item
                  ON item.doc_id = stock.id
                 AND item.is_deleted = FALSE
                WHERE stock.id = ?
                  AND stock.doc_type = 'DRAW'
                  AND fn_production_draw_pending(stock.id)
                  AND fn_production_draw_item_requested_qty(item.id)>COALESCE(item.issued_qty,0)
                  AND stock.status IN (0,1)
                  AND stock.is_deleted = FALSE
                GROUP BY stock.bill_no, stock.plan_no, stock.warehouse_id,
                         warehouse.name, department.name, worker.full_name
                """, stockDocId);
        if (document == null) {
            noticeService.resolveReviewNotices("STOCK_DOCUMENT",stockDocId,"STATE_CHANGED");
            return;
        }
        if (!preserveExistingPending) noticeService.resolveReviewNotices("STOCK_DOCUMENT",stockDocId,"PENDING_REFRESHED");
        String billNo = str(document.get("bill_no"));
        String planNo = str(document.get("plan_no"));
        String warehouse = str(document.get("warehouse_name"));
        String department = str(document.get("department_name"));
        String worker = str(document.get("worker_name"));
        String content = "车间已提交生产领料单 " + billNo
                + (planNo.isBlank() ? "" : "(生产计划 " + planNo + ")")
                + "，共 " + str(document.get("line_count")) + " 行物料"
                + (warehouse.isBlank() ? "" : "，发料仓库「" + warehouse + "」")
                + (department.isBlank() ? "" : "，领料车间「" + department + "」")
                + (worker.isBlank() ? "" : "，领料负责人「" + worker + "」")
                + "。请核对实物后直接点“出库”；首次出库会在同一事务完成审核与本次扣账，"
                + "任一步失败都不会留下半审核状态。";
        for (UUID warehouseUser : warehouseRecipients(warehousePool("stock_doc:view", "stock_doc:approve",
                "stock_doc:issue"), warehouseIdsOf(document.get("warehouse_id")))) {
            if (preserveExistingPending && Boolean.TRUE.equals(jdbc.queryForObject("""
                    SELECT EXISTS(SELECT 1 FROM notices WHERE aggregate_kind='STOCK_DOCUMENT'
                      AND aggregate_id=? AND audience_user_id=? AND source_event=? AND resolved_at IS NULL)
                    """, Boolean.class, stockDocId, warehouseUser, EVENT_PRODUCTION_DRAW_PENDING))) continue;
            // 2026-09-05 起升级为居中行动卡：aggregate 绑定
            // (STOCK_DOCUMENT, stockDocId)，DRAW 实际出库后按聚合办结撤回。
            sendToUser(
                    warehouseUser,
                    TYPE_TASK,
                    "待处理生产领料：" + billNo,
                    content,
                    "/warehouse/DRAW/" + stockDocId,
                    EVENT_PRODUCTION_DRAW_PENDING,
                    null,
                    stockDocId);
        }
    }

    /** 仓库把 DRAW 全部实际出库后，仅通知精确执行段所属车间可以直接报工。 */
    public void notifyProductionDrawIssued(
            UUID stockDocId, String issueIdempotencyKey) {
        if (!isOutboxDelivery()) {
            if (issueIdempotencyKey == null || issueIdempotencyKey.isBlank()) {
                throw new IllegalArgumentException(
                        "issueIdempotencyKey is required for DRAW issued notice");
            }
            // The issue transaction already reduced reservations. Lower the arrival baseline now,
            // before another receipt can commit; delayed outbox delivery must not hide its growth.
            lowerWorkshopArrivalCapacityAfterIssue(stockDocId);
            outbox.publishOnce(
                    EVENT_PRODUCTION_DRAW_ISSUED,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    Map.of(),
                    EVENT_PRODUCTION_DRAW_ISSUED + ':' + stockDocId + ':'
                            + issueIdempotencyKey.strip());
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one("""
                    SELECT stock.bill_no, stock.plan_no,
                           warehouse.name AS warehouse_name
                    FROM stock_documents stock
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = stock.warehouse_id
                    WHERE stock.id = ?
                      AND stock.doc_type = 'DRAW'
                      AND stock.status = 1
                      AND stock.is_deleted = FALSE
                    """, stockDocId);
            if (document == null) return;
            // DRAW 已实际出库：撤回「待处理生产领料」居中行动卡（按单据聚合）。
            if (!Boolean.TRUE.equals(jdbc.queryForObject("SELECT fn_production_draw_pending(?)", Boolean.class, stockDocId))) {
                resolveReviewNotices("STOCK_DOCUMENT", stockDocId, "DRAW_ISSUED");
            }
            publishWorkshopTasksForDraw(
                    stockDocId,
                    "仓库已完成领料单 "
                            + str(document.get("bill_no"))
                            + " 的本轮实物出库",
                    true);
        });
    }

    /** 取消实物发料后提醒精确车间任务，并恢复尚未发完申请的仓库待办。 */
    public void notifyProductionDrawIssueReversed(
            UUID stockDocId, String reverseIdempotencyKey) {
        if (!isOutboxDelivery()) {
            if (reverseIdempotencyKey == null
                    || reverseIdempotencyKey.isBlank()) {
                throw new IllegalArgumentException(
                        "reverseIdempotencyKey is required for DRAW reverse notice");
            }
            outbox.publishOnce(
                    EVENT_PRODUCTION_DRAW_ISSUE_REVERSED,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    Map.of(),
                    EVENT_PRODUCTION_DRAW_ISSUE_REVERSED + ':' + stockDocId
                            + ':' + reverseIdempotencyKey.strip());
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one("""
                    SELECT stock.bill_no, stock.plan_no,
                           warehouse.name AS warehouse_name
                    FROM stock_documents stock
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = stock.warehouse_id
                    WHERE stock.id = ?
                      AND stock.doc_type = 'DRAW'
                      AND stock.status = 1
                      AND stock.issue_status <> 2
                      AND fn_production_draw_pending(stock.id)
                      AND stock.is_deleted = FALSE
                    """, stockDocId);
            if (document == null) return;
            publishWorkshopTasksForDraw(
                    stockDocId,
                    "领料单 " + str(document.get("bill_no"))
                            + " 已取消部分出库，等待仓库重新备料",
                    false);
            // The reversal outbox event is the new intent. Deliver in this same
            // transaction instead of reusing the already-processed request key.
            deliverProductionDrawPending(stockDocId, true);
        });
    }

    /**
     * 仓库审核采购/委外收货后通知品质部：收货单已进入 IQC 待检。
     * 接收人只取品质部子树内在职、启用且当前有效拥有查看权限的账号；通知不是角标真相。
     */
    public void notifyIqcPendingForQuality(UUID receiptId, String receiptType) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_IQC_PENDING,
                    "PROCUREMENT_INSPECTION",
                    receiptId,
                    Map.of("receiptType", receiptType),
                    EVENT_IQC_PENDING + ':' + receiptId);
            return;
        }
        deliverAtomically(() -> {
            boolean purchase = "PURCHASE".equals(receiptType);
            if (!purchase && !"SUBCONTRACT".equals(receiptType)) return;
            Map<String, Object> receipt = one(purchase
                    ? """
                    SELECT receipt.bill_no, supplier.name AS supplier_name,
                           warehouse.name AS warehouse_name
                    FROM purchase_receipts receipt
                    LEFT JOIN suppliers supplier ON supplier.id = receipt.supplier_id
                    LEFT JOIN warehouses warehouse ON warehouse.id = receipt.warehouse_id
                    WHERE receipt.id = ? AND COALESCE(receipt.is_deleted, FALSE) = FALSE AND receipt.legacy_id IS NULL
                    """
                    : """
                    SELECT receipt.bill_no, supplier.name AS supplier_name,
                           warehouse.name AS warehouse_name
                    FROM subcontract_receipts receipt
                    LEFT JOIN suppliers supplier ON supplier.id = receipt.supplier_id
                    LEFT JOIN warehouses warehouse ON warehouse.id = receipt.warehouse_id
                    WHERE receipt.id = ? AND COALESCE(receipt.is_deleted, FALSE) = FALSE AND receipt.legacy_id IS NULL
                    """, receiptId);
            if (receipt == null) return;
            Map<String, Object> pending = one("""
                    SELECT COUNT(*) AS pending_lines,
                           COALESCE(SUM(received_base_qty - passed_base_qty - failed_base_qty), 0)
                               AS pending_base_qty
                    FROM procurement_inspection_items
                    WHERE receipt_type = ? AND receipt_id = ?
                      AND status IN ('PENDING', 'PARTIAL')
                    """, receiptType, receiptId);
            long pendingLines = pending == null
                    ? 0L
                    : ((Number) pending.get("pending_lines")).longValue();
            if (pendingLines == 0L) return;
            BigDecimal pendingQty = bd(pending.get("pending_base_qty"));
            String billNo = str(receipt.get("bill_no"));
            String supplier = str(receipt.get("supplier_name"));
            String warehouse = str(receipt.get("warehouse_name"));
            String documentLabel = purchase ? "采购收货单 " : "委外进仓单 ";
            String content = documentLabel + billNo
                    + (supplier.isBlank() ? "" : "(" + supplier + ")")
                    + " 已由仓库审核并进入待检，共 " + pendingLines + " 行、待检 "
                    + qty(pendingQty) + "(基本单位)"
                    + (warehouse.isBlank() ? "。" : "，目标仓库「" + warehouse + "」。")
                    + "请到品质任务中心核验；角标和待检数量以任务中心实时数据为准。";
            for (UUID qualityUser : qualityInspectionViewerUserIds()) {
                // V459 审核待办弹卡：aggregate 绑定 (IQC_INSPECTION, receiptId)，
                // 检验完成（全部行 PASS/处置完毕）时批量撤回。
                sendToUser(
                        qualityUser,
                        TYPE_TASK,
                        "待检处置：" + billNo,
                        content,
                        "/quality/task-center",
                        EVENT_IQC_PENDING,
                        null,
                        receiptId);
            }
        });
    }

    /**
     * 先入库后检(V596)：仓库把仍在等结论的待检品上架到实际仓/库位后，用醒目通知提醒品质部
     * 到储放区域检验(合格由系统按上架位置自动转正入库，不合格由仓库从库位取出退回)。
     * 通知不是角标真相；位置以待检明细页实时数据为准。
     */
    public void notifyIqcPreStockedForQuality(UUID receiptId, String receiptType) {
        deliverAtomically(() -> {
            boolean purchase = "PURCHASE".equals(receiptType);
            if (!purchase && !"SUBCONTRACT".equals(receiptType)) return;
            Map<String, Object> receipt = one("""
                    SELECT receipt.bill_no, supplier.name AS supplier_name
                    FROM %s receipt
                    LEFT JOIN suppliers supplier ON supplier.id = receipt.supplier_id
                    WHERE receipt.id = ? AND COALESCE(receipt.is_deleted, FALSE) = FALSE AND receipt.legacy_id IS NULL
                    """.formatted(purchase ? "purchase_receipts" : "subcontract_receipts"), receiptId);
            if (receipt == null) return;
            List<Map<String, Object>> lines = jdbc.queryForList("""
                    SELECT goods.code AS goods_code, goods.name AS goods_name,
                           warehouse.name AS warehouse_name, inspection.pre_stocked_place,
                           inspection.received_base_qty - inspection.passed_base_qty
                               - inspection.failed_base_qty AS pending_qty
                    FROM procurement_inspection_items inspection
                    LEFT JOIN goods ON goods.id = inspection.goods_id
                    LEFT JOIN warehouses warehouse ON warehouse.id = inspection.pre_stocked_warehouse_id
                    WHERE inspection.receipt_type = ? AND inspection.receipt_id = ?
                      AND inspection.status IN ('PENDING', 'PARTIAL')
                      AND inspection.pre_stocked_at IS NOT NULL
                    ORDER BY inspection.received_at, inspection.id
                    """, receiptType, receiptId);
            if (lines.isEmpty()) return;
            String billNo = str(receipt.get("bill_no"));
            String supplier = str(receipt.get("supplier_name"));
            StringBuilder where = new StringBuilder();
            int shown = 0;
            for (Map<String, Object> line : lines) {
                if (shown == 3) {
                    where.append("；另 ").append(lines.size() - shown).append(" 行见明细");
                    break;
                }
                if (shown > 0) where.append('；');
                where.append((str(line.get("goods_code")) + " " + str(line.get("goods_name"))).strip())
                        .append(" → ").append(str(line.get("warehouse_name")))
                        .append(" / ").append(str(line.get("pre_stocked_place")))
                        .append('(').append(qty(bd(line.get("pending_qty")))).append(')');
                shown++;
            }
            String content = (purchase ? "采购收货单 " : "委外进仓单 ") + billNo
                    + (supplier.isBlank() ? "" : "(" + supplier + ")")
                    + " 的货品已先入库上架，需到对应储放区域检查：" + where
                    + "。合格后系统自动按上架位置转正入库；不合格由仓库从库位取出登记退回。";
            String route = "/warehouse/inspections/" + receiptType + '/' + receiptId;
            for (UUID qualityUser : qualityInspectionViewerUserIds()) {
                sendToUser(
                        qualityUser,
                        TYPE_TASK,
                        "货品已入库待检，请到库位检验：" + billNo,
                        content,
                        route,
                        EVENT_IQC_PRE_STOCKED);
            }
        });
    }

    /**
     * Every quality PASS slice immediately becomes a durable warehouse task.
     * The notification is only a permission-filtered reminder; remaining
     * quantity and action authority are always re-read from the task API.
     */
    public void notifyIqcStockInPendingForWarehouse(
            UUID passEventId, String receiptType, UUID receiptId) {
        if (!isOutboxDelivery()) {
            if (passEventId == null || receiptId == null) return;
            outbox.publishOnce(
                    EVENT_IQC_STOCK_IN_PENDING,
                    "PROCUREMENT_INSPECTION_PASS",
                    passEventId,
                    Map.of("receiptType", receiptType, "receiptId", receiptId),
                    EVENT_IQC_STOCK_IN_PENDING + ':' + passEventId);
            return;
        }
        deliverAtomically(() -> {
            boolean purchase = "PURCHASE".equals(receiptType);
            if ((!purchase && !"SUBCONTRACT".equals(receiptType))
                    || passEventId == null || receiptId == null) {
                return;
            }
            Map<String, Object> task = one("""
                    SELECT receipt.bill_no,
                           supplier.name AS supplier_name,
                           warehouse.name AS warehouse_name,
                           inspection.warehouse_id,
                           goods.code AS goods_code,
                           goods.name AS goods_name,
                           COALESCE(base_unit.name, source_unit.name) AS unit_name,
                           event.base_qty
                               - COALESCE(stocked.stocked_qty, 0) AS remaining_qty
                    FROM procurement_inspection_events event
                    JOIN procurement_inspection_items inspection
                      ON inspection.id = event.inspection_item_id
                     AND inspection.receipt_type = ?
                     AND inspection.receipt_id = ?
                     AND inspection.status <> 'REVERSED'
                    JOIN %s receipt
                      ON receipt.id = inspection.receipt_id
                     AND COALESCE(receipt.is_deleted, FALSE) = FALSE
                    LEFT JOIN suppliers supplier ON supplier.id = receipt.supplier_id
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = inspection.warehouse_id
                    LEFT JOIN goods ON goods.id = inspection.goods_id
                    LEFT JOIN units source_unit
                      ON source_unit.id = inspection.unit_id
                    LEFT JOIN units base_unit ON base_unit.id = goods.unit_id
                    LEFT JOIN LATERAL (
                        SELECT COALESCE(SUM(item.base_qty), 0) AS stocked_qty
                        FROM procurement_iqc_stock_in_batch_items item
                        WHERE item.pass_event_id = event.id
                    ) stocked ON TRUE
                    WHERE event.id = ?
                      AND event.action = 'PASS'
                      AND event.requires_warehouse_stock_in = TRUE
                    """.formatted(purchase
                            ? "purchase_receipts" : "subcontract_receipts"),
                    receiptType, receiptId, passEventId);
            if (task == null) return;
            BigDecimal remaining = bd(task.get("remaining_qty"));
            if (remaining.signum() <= 0) return;
            String billNo = str(task.get("bill_no"));
            String goodsLabel = (str(task.get("goods_code")) + " "
                    + str(task.get("goods_name"))).strip();
            String unitName = str(task.get("unit_name"));
            String content = (purchase ? "采购收货单 " : "委外进仓单 ")
                    + billNo
                    + (str(task.get("supplier_name")).isBlank()
                            ? "" : "(" + str(task.get("supplier_name")) + ")")
                    + " 的 " + goodsLabel + " 已由品质部放行，待仓库确认入库 "
                    + qty(remaining)
                    + (unitName.isBlank() ? "(基本单位)" : " " + unitName)
                    + (str(task.get("warehouse_name")).isBlank()
                            ? "。" : "，目标仓库「" + str(task.get("warehouse_name")) + "」。")
                    + "请核对实物数量和实际库位；确认前不会增加可用库存。";
            String route = "/warehouse/iqc-stock-ins/" + receiptType + '/' + receiptId;
            for (UUID warehouseUser : warehouseRecipients(warehousePool(NOTICE_READ_AUTHORITY,
                    WAREHOUSE_IQC_STOCK_IN_VIEW_AUTHORITY), warehouseIdsOf(task.get("warehouse_id")))) {
                // 2026-09-05 起升级为居中行动卡：aggregate 绑定
                // (PROCUREMENT_INSPECTION_PASS, passEventId)，该切片全部
                // 确认入库后按聚合办结撤回。
                sendToUser(
                        warehouseUser,
                        TYPE_TASK,
                        "品质已放行，待仓库入库：" + billNo,
                        content,
                        route,
                        EVENT_IQC_STOCK_IN_PENDING,
                        null,
                        passEventId);
            }
        });
    }

    /**
     * 仓库确认入库后的弹卡办结：把该收货单下已无待入库余量的品质放行切片
     * 按 (PROCUREMENT_INSPECTION_PASS, passEventId) 批量撤回。仍有余量的
     * 切片保留弹卡（部分入库不改余量口径）。幂等，可直接在入库事务内调用。
     */
    public void resolveIqcStockInPendingForWarehouse(
            String receiptType, UUID receiptId) {
        if (receiptType == null || receiptId == null) return;
        List<UUID> fullyStocked = jdbc.queryForList("""
                SELECT event.id
                FROM procurement_inspection_events event
                JOIN procurement_inspection_items inspection
                  ON inspection.id = event.inspection_item_id
                 AND inspection.receipt_type = ?
                 AND inspection.receipt_id = ?
                 AND inspection.status <> 'REVERSED'
                WHERE event.action = 'PASS'
                  AND event.requires_warehouse_stock_in = TRUE
                  AND event.base_qty - COALESCE((
                        SELECT SUM(item.base_qty)
                        FROM procurement_iqc_stock_in_batch_items item
                        WHERE item.pass_event_id = event.id
                      ), 0) <= 0
                """, UUID.class, receiptType, receiptId);
        for (UUID passEventId : fullyStocked) {
            resolveReviewNotices(
                    "PROCUREMENT_INSPECTION_PASS", passEventId,
                    "WAREHOUSE_STOCKED");
        }
    }

    /**
     * 采购/委外收货 IQC 整单结案结果回执。合格不等于已入库；仓库任务投影
     * 与 warehouse_stocked_base_qty 才是实际入库权威。
     * 事件由仓库 inbound 模块（ProcurementInspectionService）在结案同事务投递；
     * 本方法只在 outbox 处理事务内做真实通知写入。
     */
    public void notifyIqcResolvedForPutaway(UUID receiptId, String receiptType) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_IQC_RESOLVED,
                    "PROCUREMENT_INSPECTION",
                    receiptId,
                    Map.of("receiptType", receiptType),
                    EVENT_IQC_RESOLVED + ':' + receiptId);
            return;
        }
        deliverAtomically(() -> {
            boolean purchase = "PURCHASE".equals(receiptType);
            Map<String, Object> receipt = one(purchase
                    ? """
                    SELECT receipt.bill_no, supplier.name AS supplier_name,
                           warehouse.name AS warehouse_name
                    FROM purchase_receipts receipt
                    LEFT JOIN suppliers supplier ON supplier.id = receipt.supplier_id
                    LEFT JOIN warehouses warehouse ON warehouse.id = receipt.warehouse_id
                    WHERE receipt.id = ? AND COALESCE(receipt.is_deleted, FALSE) = FALSE AND receipt.legacy_id IS NULL
                    """
                    : """
                    SELECT receipt.bill_no, supplier.name AS supplier_name,
                           warehouse.name AS warehouse_name
                    FROM subcontract_receipts receipt
                    LEFT JOIN suppliers supplier ON supplier.id = receipt.supplier_id
                    LEFT JOIN warehouses warehouse ON warehouse.id = receipt.warehouse_id
                    WHERE receipt.id = ? AND COALESCE(receipt.is_deleted, FALSE) = FALSE AND receipt.legacy_id IS NULL
                    """, receiptId);
            if (receipt == null) return;
            Map<String, Object> sums = one("""
                    SELECT COALESCE(SUM(passed_base_qty), 0) AS passed,
                           COALESCE(SUM(failed_base_qty), 0) AS failed
                    FROM procurement_inspection_items
                    WHERE receipt_type = ? AND receipt_id = ? AND status <> 'REVERSED'
                    """, receiptType, receiptId);
            BigDecimal passed = sums == null
                    ? BigDecimal.ZERO : bd(sums.get("passed"));
            BigDecimal failed = sums == null
                    ? BigDecimal.ZERO : bd(sums.get("failed"));
            String billNo = str(receipt.get("bill_no"));
            String supplier = str(receipt.get("supplier_name"));
            String warehouse = str(receipt.get("warehouse_name"));
            // 先入库后检(V596)：合格已按上架位置自动转正，仓库只剩不合格取货退回这一件事。
            Map<String, Object> preStocked = one("""
                    SELECT COUNT(*) FILTER (WHERE pre_stocked_at IS NOT NULL) AS pre_stocked_lines,
                           COUNT(*) FILTER (WHERE pre_stocked_at IS NOT NULL AND failed_base_qty > 0)
                               AS failed_pre_stocked_lines
                    FROM procurement_inspection_items
                    WHERE receipt_type = ? AND receipt_id = ? AND status <> 'REVERSED'
                    """, receiptType, receiptId);
            long preStockedLines = preStocked == null
                    ? 0L : ((Number) preStocked.get("pre_stocked_lines")).longValue();
            long failedPreStockedLines = preStocked == null
                    ? 0L : ((Number) preStocked.get("failed_pre_stocked_lines")).longValue();
            String content = preStockedLines > 0
                    ? (purchase ? "采购收货单 " : "委外进仓单 ") + billNo
                            + (supplier.isBlank() ? "" : "(" + supplier + ")")
                            + " 品质部检验已结案(先入库后检)。合格部分已按上架位置自动转正入库，无需再确认；"
                            + (failed.signum() > 0
                                    ? (failedPreStockedLines > 0
                                            ? "不合格实物仍在上架库位，请到库位取出并登记退回。"
                                            : "本单含不合格实物，请跟进退回处置。")
                                    : "本单没有不合格实物。")
                    : (purchase ? "采购收货单 " : "委外进仓单 ") + billNo
                            + (supplier.isBlank() ? "" : "(" + supplier + ")")
                            + " 品质部检验已结案。合格量是否已经进入可用库存，"
                            + "必须以仓库确认入库任务为准"
                            + (warehouse.isBlank() ? "" : " 至「" + warehouse + "」")
                            + (failed.signum() > 0
                                    ? "；本单含不合格实物，请同时跟进退回处置。"
                                    : "。请在仓库专属页面核对剩余待入库切片。");
            if (hasWarehouseIqcStockInTask(passed) || preStockedLines > 0) {
                String route = preStockedLines > 0
                        ? "/warehouse/quality-results/" + receiptType + '/' + receiptId
                        : "/warehouse/iqc-stock-ins/" + receiptType + '/' + receiptId;
                // 入库目标仓与先入库后检的上架仓都算: 哪个仓的实物要处理, 就通知哪个仓的负责人。
                List<UUID> receiptWarehouses = warehouseIdsQuery("""
                        SELECT warehouse_id FROM procurement_inspection_items
                        WHERE receipt_type = ? AND receipt_id = ? AND status <> 'REVERSED'
                        UNION
                        SELECT pre_stocked_warehouse_id FROM procurement_inspection_items
                        WHERE receipt_type = ? AND receipt_id = ? AND status <> 'REVERSED'
                        """, receiptType, receiptId, receiptType, receiptId);
                for (UUID warehouseUser : warehouseRecipients(warehousePool(NOTICE_READ_AUTHORITY,
                        WAREHOUSE_IQC_STOCK_IN_VIEW_AUTHORITY), receiptWarehouses)) {
                    sendToUser(
                            warehouseUser,
                            TYPE_WORKFLOW,
                            (failed.signum() > 0
                                    ? "品质检验已结案（含不合格）："
                                    : "品质检验已结案：") + billNo,
                            content,
                            route,
                            EVENT_IQC_RESOLVED);
                }
            }
            if (!purchase) {
                notifySubcontractIqcResolvedStakeholders(
                        receiptId, billNo, passed, failed);
            }
        });
    }

    /**
     * 委外 IQC 结案除仓库上架回执外，还需回到订单归属人及原物料分析归属人。
     * 两条链均只按 UUID 外键重读；通知不携带供应商或商业金额。
     */
    private void notifySubcontractIqcResolvedStakeholders(
            UUID receiptId,
            String receiptBillNo,
            BigDecimal passed,
            BigDecimal failed) {
        String result = subcontractIqcResolutionMessage(
                receiptBillNo, passed, failed);
        for (Map<String, Object> order : jdbc.queryForList("""
                SELECT DISTINCT order_header.id AS order_id,
                       order_header.bill_no AS order_bill_no,
                       order_header.maker_id
                FROM subcontract_receipt_items receipt_item
                JOIN subcontract_order_items order_item
                  ON order_item.id = receipt_item.order_item_id
                 AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                JOIN subcontract_orders order_header
                  ON order_header.id = order_item.order_id
                 AND COALESCE(order_header.is_deleted, FALSE) = FALSE
                WHERE receipt_item.receipt_id = ?
                  AND COALESCE(receipt_item.is_deleted, FALSE) = FALSE
                ORDER BY order_header.id
                """, receiptId)) {
            UUID makerUserId = subcontractMakerUserId(
                    (UUID) order.get("maker_id"));
            notifyUser(
                    makerUserId,
                    failed.signum() > 0 ? TYPE_URGENT : TYPE_WORKFLOW,
                    "委外回厂来料质检已结案：" + str(order.get("order_bill_no")),
                    result,
                    "/subcontract/orders/" + order.get("order_id"),
                    EVENT_IQC_RESOLVED);
        }
        notifySubcontractAnalysisMakersIqcResolved(
                receiptId, receiptBillNo, passed, failed, result);
    }

    private void notifySubcontractAnalysisMakersIqcResolved(
            UUID receiptId,
            String receiptBillNo,
            BigDecimal passed,
            BigDecimal failed,
            String result) {
        for (Map<String, Object> analysis : jdbc.queryForList("""
                SELECT DISTINCT material_analysis.id AS analysis_id,
                       material_analysis.maker_id
                FROM subcontract_receipt_items receipt_item
                JOIN subcontract_order_items order_item
                  ON order_item.id = receipt_item.order_item_id
                 AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                JOIN subcontract_order_item_sources src
                  ON src.order_item_id = order_item.id
                JOIN subcontract_application_items application_item
                  ON application_item.id = src.application_item_id
                 AND COALESCE(application_item.is_deleted, FALSE) = FALSE
                JOIN subcontract_applications application
                  ON application.id = application_item.application_id
                 AND COALESCE(application.is_deleted, FALSE) = FALSE
                JOIN preplan_supply_action_allocations allocation
                  ON allocation.external_item_id = application_item.id
                JOIN preplan_supply_actions supply_action
                  ON supply_action.id = allocation.action_id
                 AND supply_action.route = 'SUBCONTRACT'
                 AND supply_action.status <> 'CANCELLED'
                 AND supply_action.external_document_type =
                     'SUBCONTRACT_APPLICATION'
                 AND supply_action.external_document_id = application.id
                JOIN production_material_analyses material_analysis
                  ON material_analysis.id = supply_action.analysis_id
                 AND material_analysis.is_deleted = FALSE
                WHERE receipt_item.receipt_id = ?
                  AND COALESCE(receipt_item.is_deleted, FALSE) = FALSE
                ORDER BY material_analysis.id
                """, receiptId)) {
            UUID makerUserId = userIdOfEmployee(
                    (UUID) analysis.get("maker_id"));
            notifyUser(
                    makerUserId,
                    failed.signum() > 0 ? TYPE_URGENT : TYPE_WORKFLOW,
                    "委外供给来料质检已结案：" + receiptBillNo,
                    result + (failed.signum() > 0
                            ? "请复核不合格量对当前可下达数量和补足需求的影响。"
                            : "请在原物料分析中查看最新可下达数量。"),
                    "/production/material-analyses/"
                            + analysis.get("analysis_id") + "/summary",
                    EVENT_IQC_RESOLVED);
        }
    }

    static boolean hasWarehouseIqcStockInTask(BigDecimal passed) {
        return passed != null && passed.signum() > 0;
    }

    static String subcontractIqcResolutionMessage(
            String receiptBillNo, BigDecimal passed, BigDecimal failed) {
        boolean hasPass = hasWarehouseIqcStockInTask(passed);
        boolean hasFail = failed != null && failed.signum() > 0;
        return "委外进仓单 " + receiptBillNo + " 的来料质检已结案："
                + (hasPass
                ? "存在合格量" + (hasFail ? "，同时存在不合格量。" : "。")
                    + "合格量只有经仓库确认后才进入可用库存；"
                : "未形成合格量，不会生成仓库待入库任务；")
                + "通知不代表委外订单或原物料分析任务已全部完成。";
    }

    /** 销售创建出货草稿后，只通知具备出货财审权限的人员。 */
    public void notifyShipmentPendingFinanceAudit(UUID shipmentId) {
        notifyShipmentPendingFinanceAudit(shipmentId,null);
    }

    private void notifyShipmentPendingFinanceAudit(UUID shipmentId,String expectedIdentity) {
        if (!isOutboxDelivery()) {
            String identity=shipmentFinanceSubmissionIdentity(shipmentId);
            if (identity==null) return;
            outbox.publishOnce(
                    EVENT_SHIPMENT_PENDING_FINANCE,
                    "SALES_SHIPMENT",
                    shipmentId,
                    Map.of("submissionIdentity",identity),
                    EVENT_SHIPMENT_PENDING_FINANCE + ':' + shipmentId+':'+identity);
            return;
        }
        deliverAtomically(() -> {
            if (expectedIdentity!=null && !expectedIdentity.equals(shipmentFinanceSubmissionIdentity(shipmentId))) return;
            String billNo = oneStr("""
                    SELECT bill_no
                    FROM sales_shipments
                    WHERE id = ?
                      AND status = 0
                      AND COALESCE(is_deleted, FALSE) = FALSE
                      AND COALESCE(rejected, FALSE) = FALSE
                      AND finance_audit = 0
                      AND NOT finance_rejected
                      AND (finance_gate_version<2 OR (sales_confirmed_at IS NOT NULL AND sales_confirmed_revision=review_revision))
                      AND warehouse_work_status = 'PENDING_PICK'
                    """, shipmentId);
            if (billNo == null || billNo.isBlank()) return;
            for (UUID userId : departmentUserIdsWithAuthorities(
                    "DEPT_FIN","sales_shipment_finance:approve", NOTICE_READ_AUTHORITY)) {
                sendToUser(
                        userId,
                        TYPE_APPROVAL,
                        "待出货财务审核：" + billNo,
                        "销售出货单 " + billNo
                                + " 已提交财务审核；财务放行后才会通知仓库拣货。",
                        "/sales/shipments/" + shipmentId,
                        EVENT_SHIPMENT_PENDING_FINANCE,"normal",shipmentId);
            }
        });
    }

    private String shipmentFinanceSubmissionIdentity(UUID shipmentId) {
        return oneStr("""
                SELECT shipment.review_revision::text||':'||COALESCE((SELECT event.id::text
                    FROM sales_shipment_finance_release_events event WHERE event.shipment_id=shipment.id
                      AND event.event_type='REVOKED' ORDER BY event.occurred_at DESC,event.id DESC LIMIT 1),'INITIAL')
                FROM sales_shipments shipment WHERE shipment.id=? AND shipment.status=0 AND NOT shipment.is_deleted
                  AND NOT shipment.rejected AND NOT shipment.finance_rejected AND shipment.finance_audit=0
                  AND shipment.warehouse_work_status='PENDING_PICK' AND (shipment.finance_gate_version<2 OR
                    (shipment.sales_confirmed_at IS NOT NULL AND shipment.sales_confirmed_revision=shipment.review_revision))
                """,shipmentId);
    }

    public void notifyShipmentFinanceRejected(UUID shipmentId,String reason) {
        notifyShipmentFinanceRejected(shipmentId,reason,null);
    }

    private void notifyShipmentFinanceRejected(UUID shipmentId,String reason,Long expectedRevision) {
        Map<String,Object> document=one("""
                SELECT bill_no,shipment_kind,owner_employee_id,maker_id,review_revision FROM sales_shipments
                WHERE id=? AND status=0 AND NOT is_deleted AND finance_rejected AND warehouse_work_status='PENDING_PICK'
                """,shipmentId);
        if(document==null)return;
        long revision=((Number)document.get("review_revision")).longValue();
        if(isOutboxDelivery() && expectedRevision!=null && expectedRevision!=revision)return;
        boolean direct="DIRECT_CUSTOMER".equals(document.get("shipment_kind"));
        String event=direct?EVENT_DIRECT_SHIPMENT_FINANCE_REJECTED:EVENT_SHIPMENT_FINANCE_REJECTED;
        if(!isOutboxDelivery()) {
            outbox.publishOnce(event,"SALES_SHIPMENT",shipmentId,Map.of("reason",Objects.toString(reason,""),"reviewRevision",revision),
                    event+":"+shipmentId+":"+document.get("review_revision"));
            return;
        }
        deliverAtomically(()->{
            // V578：退回通知只要求能看单（view）——此前 view+edit 双门槛导致只读销售
            // 或归属人为空的“公共单”收不到任何提示，退回后流程在两侧同时失联。
            // 归属人不可达时回退投递给制单人。
            UUID owner=userIdOfEmployee((UUID)document.get("owner_employee_id"));
            UUID fallback=userIdOfEmployee((UUID)document.get("maker_id"));
            String prefix=direct?"sales_other_shipment":"sales_shipment";
            UUID recipient = userHasPermissions(owner,NOTICE_READ_AUTHORITY,prefix+":view")
                    ? owner : (userHasPermissions(fallback,NOTICE_READ_AUTHORITY,prefix+":view") ? fallback : null);
            if(recipient==null)return;
            sendToUser(recipient,TYPE_URGENT,"发货已退回，请修改："+document.get("bill_no"),
                    "财务退回原因："+Objects.toString(reason,"")+"。请核对修改后重新确认，也可以取消尚未出库的单据。",
                    (direct?"/sales/customer-shipments/":"/sales/shipments/")+shipmentId,event,"important",shipmentId);
        });
    }

    /** 财务放行后，给仓库部门投递待拣货任务。 */
    public void notifyShipmentPendingPick(UUID shipmentId) {
        notifyShipmentPendingPick(shipmentId, null);
    }

    /** 每次真实财务放行使用审核时间形成独立幂等键，允许反审后重新放行再通知。 */
    public void notifyShipmentPendingPick(
            UUID shipmentId, java.time.OffsetDateTime financeAuditedAt) {
        if (!isOutboxDelivery()) {
            String releaseIdentity = financeAuditedAt == null
                    ? "legacy"
                    : financeAuditedAt.toInstant().toString();
            outbox.publishOnce(
                    EVENT_SHIPMENT_PENDING_PICK,
                    "SALES_SHIPMENT",
                    shipmentId,
                    Map.of(),
                    EVENT_SHIPMENT_PENDING_PICK + ':' + shipmentId + ':' + releaseIdentity);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> shipment = one("""
                    SELECT shipment.bill_no,
                           warehouse.name AS warehouse_name,
                           SUM(COALESCE(item.qty, 0)) AS shipment_qty
                    FROM sales_shipments shipment
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = shipment.warehouse_id
                    LEFT JOIN sales_shipment_items item
                      ON item.shipment_id = shipment.id
                     AND item.is_deleted = FALSE
                    WHERE shipment.id = ?
                      AND shipment.warehouse_work_status = 'PENDING_PICK'
                      AND shipment.status = 0
                      AND shipment.is_deleted = FALSE
                      AND COALESCE(shipment.rejected, FALSE) = FALSE
                      AND shipment.finance_audit = 1
                    GROUP BY shipment.bill_no, warehouse.name
                    """, shipmentId);
            if (shipment == null) return;
            String billNo = str(shipment.get("bill_no"));
            String warehouse = str(shipment.get("warehouse_name"));
            String content = "发货单 " + billNo + " 已进入待拣货，数量 "
                    + qty(bd(shipment.get("shipment_qty")))
                    + (warehouse.isBlank() ? "。" : "，出库仓库 " + warehouse + "。")
                    + "请按仓库作业流程核对库存并拣货；通知不代表已占用或已出库。";
            for (UUID warehouseUser : warehouseRecipients(warehousePool(NOTICE_READ_AUTHORITY,
                    "warehouse_sales_outbound:execute"), shipmentWarehouseIds(shipmentId))) {
                sendToUser(
                        warehouseUser,
                        TYPE_TASK,
                        "待拣货发货单：" + billNo,
                        content,
                        "/sales/shipments/" + shipmentId,
                        EVENT_SHIPMENT_PENDING_PICK,"normal",shipmentId);
            }
        });
    }

    /** 财务在拣货开始前撤回放行时，通知仓库暂停该任务。 */
    public void notifyShipmentFinanceReleaseRevoked(UUID shipmentId) {
        if (!isOutboxDelivery()) {
            outbox.publish(
                    EVENT_SHIPMENT_FINANCE_REVOKED,
                    "SALES_SHIPMENT",
                    shipmentId,
                    Map.of());
            return;
        }
        deliverAtomically(() -> {
            String billNo = oneStr("""
                    SELECT bill_no
                    FROM sales_shipments
                    WHERE id = ?
                      AND status = 0
                      AND COALESCE(is_deleted, FALSE) = FALSE
                      AND finance_audit = 0
                      AND warehouse_work_status = 'PENDING_PICK'
                    """, shipmentId);
            if (billNo == null || billNo.isBlank()) return;
            for (UUID warehouseUser : warehouseRecipients(warehousePool(NOTICE_READ_AUTHORITY,
                    "warehouse_sales_outbound:execute"), shipmentWarehouseIds(shipmentId))) {
                sendToUser(
                        warehouseUser,
                        TYPE_URGENT,
                        "出货财务放行已撤回：" + billNo,
                        "出货单 " + billNo + " 的财务放行已撤回，请暂停拣货并等待重新审核。",
                        "/sales/shipments/" + shipmentId,
                        EVENT_SHIPMENT_FINANCE_REVOKED);
            }
        });
    }

    /**
     * Reliable handoff after material analysis creates a real purchase or
     * subcontract application. The action remains the aggregate authority:
     * delivery re-reads route, downstream document and material snapshots.
     * Cancelled actions or actions without a real downstream link are ignored.
     */
    public void notifyPreplanSupplyActionCreated(UUID actionId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_PREPLAN_SUPPLY_ACTION_CREATED,
                    "PREPLAN_SUPPLY_ACTION",
                    actionId,
                    Map.of(),
                    EVENT_PREPLAN_SUPPLY_ACTION_CREATED + ':' + actionId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> action = one("""
                    SELECT supply.route, supply.requested_qty, supply.need_date,
                           supply.external_document_type, supply.external_document_id,
                           supply.external_document_no,
                           goods.code AS goods_code, goods.name AS goods_name
                    FROM preplan_supply_actions supply
                    JOIN goods ON goods.id = supply.goods_id
                    WHERE supply.id = ?
                      AND supply.status <> 'CANCELLED'
                      AND supply.external_document_id IS NOT NULL
                      AND supply.external_document_no IS NOT NULL
                      AND (
                            (supply.route = 'BUY'
                             AND supply.external_document_type = 'PURCHASE_REQUEST'
                             AND EXISTS (
                                 SELECT 1
                                 FROM purchase_requests request
                                 WHERE request.id = supply.external_document_id
                                   AND request.is_deleted = FALSE
                             ))
                         OR (supply.route = 'SUBCONTRACT'
                             AND supply.external_document_type = 'SUBCONTRACT_APPLICATION'
                             AND EXISTS (
                                 SELECT 1
                                 FROM subcontract_applications application
                                 WHERE application.id = supply.external_document_id
                                   AND application.is_deleted = FALSE
                             ))
                      )
                    """, actionId);
            if (action == null) return;

            String supplyRoute = str(action.get("route"));
            UUID documentId = (UUID) action.get("external_document_id");
            String documentNo = str(action.get("external_document_no"));
            String goodsLabel = (str(action.get("goods_code")) + " "
                    + str(action.get("goods_name"))).strip();
            if (goodsLabel.isBlank()) {
                goodsLabel = "\u6240\u9009\u7269\u6599";
            }
            String needDate = str(action.get("need_date"));
            String quantity = qty(bd(action.get("requested_qty")));

            String title;
            String content;
            String actionRoute;
            String requiredViewAuthority;
            if ("BUY".equals(supplyRoute)) {
                title = "\u65b0\u91c7\u8d2d\u9700\u6c42\uff1a" + documentNo;
                content = "\u8ba1\u5212\u90e8\u5df2\u4e0b\u8fbe\u91c7\u8d2d\u7533\u8bf7 "
                        + documentNo + "\uff0c\u7269\u6599 " + goodsLabel
                        + "\uff0c\u6570\u91cf " + quantity
                        + (needDate.isBlank()
                                ? "\u3002"
                                : "\uff0c\u9700\u6c42\u65e5\u671f " + needDate + "\u3002")
                        + "\u8bf7\u5230\u91c7\u8d2d\u7533\u8bf7\u8be6\u60c5\u6838\u5bf9\uff0c"
                        + "\u5e76\u4ece\u91c7\u8d2d\u4efb\u52a1\u4e2d\u5fc3\u7ee7\u7eed"
                        + "\u5206\u89e3\u8ba2\u8d27\u3002";
                actionRoute = "/purchase/requests/" + documentId;
                requiredViewAuthority = PURCHASE_REQUEST_VIEW_AUTHORITY;
            } else if ("SUBCONTRACT".equals(supplyRoute)) {
                title = "\u65b0\u59d4\u5916\u9700\u6c42\uff1a" + documentNo;
                content = "\u8ba1\u5212\u90e8\u5df2\u4e0b\u8fbe\u59d4\u5916\u7533\u8bf7 "
                        + documentNo + "\uff0c\u7269\u6599 " + goodsLabel
                        + "\uff0c\u6570\u91cf " + quantity
                        + (needDate.isBlank()
                                ? "\u3002"
                                : "\uff0c\u9700\u6c42\u65e5\u671f " + needDate + "\u3002")
                        + "\u8bf7\u5230\u59d4\u5916\u7533\u8bf7\u8be6\u60c5\u6838\u5bf9\uff0c"
                        + "\u5e76\u4ece\u59d4\u5916\u4efb\u52a1\u4e2d\u5fc3\u7ee7\u7eed"
                        + "\u5206\u89e3\u8ba2\u8d27\u3002";
                actionRoute = "/subcontract/applications/" + documentId;
                requiredViewAuthority = SUBCONTRACT_APPLICATION_VIEW_AUTHORITY;
            } else {
                return;
            }
            notifyPreplanSupplyRecipients(
                    TYPE_TASK,
                    title,
                    content,
                    actionRoute,
                    requiredViewAuthority);
        });
    }

    /**
     * ADR-065 修订（2026-09-03）：同批备料下达合并为一张采购/委外申请后，
     * 通知按「单据」聚合——每张申请只给接收人提醒一次（单号 + N 种物料 +
     * 直达详情），不再逐 action 重复发条。旧 action 级事件保留，仅用于
     * 已入箱历史事件的投递兼容。
     */
    /**
     * ADR-099 就地追加：计划部把一张仍未订货的采购/委外申请的明细数量改大后，
     * 给同一批接收人再提醒一次（单号 + 追加量 + 直达详情）。每次追加各提醒一次。
     */
    public void notifyPreplanSupplyDocumentIncreased(
            UUID documentId, String documentType, java.math.BigDecimal addedQty) {
        boolean purchase = "PURCHASE_REQUEST".equals(documentType);
        boolean subcontract = "SUBCONTRACT_APPLICATION".equals(documentType);
        if (!purchase && !subcontract || addedQty == null || addedQty.signum() <= 0) return;
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_PREPLAN_SUPPLY_DOCUMENT_CREATED,
                    "PREPLAN_SUPPLY_DOCUMENT",
                    documentId,
                    Map.of("documentType", documentType,
                            "addedQty", addedQty.stripTrailingZeros().toPlainString()),
                    EVENT_PREPLAN_SUPPLY_DOCUMENT_CREATED + ":INCREASED:" + documentType
                            + ':' + documentId + ':' + UUID.randomUUID());
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one(purchase ? """
                    SELECT request.bill_no
                    FROM purchase_requests request
                    WHERE request.id = ? AND request.is_deleted = FALSE
                    """ : """
                    SELECT application.bill_no
                    FROM subcontract_applications application
                    WHERE application.id = ? AND application.is_deleted = FALSE
                    """, documentId);
            if (document == null) return;
            String billNo = str(document.get("bill_no"));
            String noun = purchase ? "采购" : "委外";
            String title = noun + "需求追加：" + billNo + "（追加 " + qty(addedQty) + "）";
            String content = "计划部在" + noun + "申请 " + billNo + " 上追加了 " + qty(addedQty)
                    + "，该申请尚未订货，明细数量已直接改大。请到" + noun
                    + "申请详情核对，并从" + noun + "任务中心按新数量分解订货。";
            String actionRoute = (purchase ? "/purchase/requests/"
                    : "/subcontract/applications/") + documentId;
            notifyPreplanSupplyRecipients(
                    TYPE_TASK, title, content, actionRoute,
                    purchase ? PURCHASE_REQUEST_VIEW_AUTHORITY : SUBCONTRACT_APPLICATION_VIEW_AUTHORITY);
        });
    }

    public void notifyPreplanSupplyDocumentCreated(UUID documentId, String documentType) {
        boolean purchase = "PURCHASE_REQUEST".equals(documentType);
        boolean subcontract = "SUBCONTRACT_APPLICATION".equals(documentType);
        if (!purchase && !subcontract) return;
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_PREPLAN_SUPPLY_DOCUMENT_CREATED,
                    "PREPLAN_SUPPLY_DOCUMENT",
                    documentId,
                    Map.of("documentType", documentType),
                    EVENT_PREPLAN_SUPPLY_DOCUMENT_CREATED
                            + ':' + documentType + ':' + documentId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one(purchase ? """
                    SELECT request.bill_no,
                           COUNT(DISTINCT item.goods_id) AS goods_count,
                           COUNT(item.id) AS line_count
                    FROM purchase_requests request
                    JOIN purchase_request_items item
                      ON item.request_id = request.id AND item.is_deleted = FALSE
                    WHERE request.id = ?
                      AND request.is_deleted = FALSE
                    GROUP BY request.bill_no
                    """ : """
                    SELECT application.bill_no,
                           COUNT(DISTINCT item.goods_id) AS goods_count,
                           COUNT(item.id) AS line_count
                    FROM subcontract_applications application
                    JOIN subcontract_application_items item
                      ON item.application_id = application.id AND item.is_deleted = FALSE
                    WHERE application.id = ?
                      AND application.is_deleted = FALSE
                    GROUP BY application.bill_no
                    """, documentId);
            if (document == null) return;

            String billNo = str(document.get("bill_no"));
            int goodsCount = document.get("goods_count") == null
                    ? 0 : ((Number) document.get("goods_count")).intValue();
            int lineCount = document.get("line_count") == null
                    ? 0 : ((Number) document.get("line_count")).intValue();
            String noun = purchase ? "\u91c7\u8d2d" : "\u59d4\u5916";
            String title = "\u65b0" + noun + "\u9700\u6c42\uff1a" + billNo
                    + "\uff08" + goodsCount + " \u79cd\u7269\u6599\uff09";
            String content = "\u8ba1\u5212\u90e8\u5df2\u4e0b\u8fbe" + noun
                    + "\u7533\u8bf7 " + billNo + "\uff0c\u5171 " + goodsCount
                    + " \u79cd\u7269\u6599\uff08" + lineCount
                    + " \u6761\u660e\u7ec6\uff09\u3002\u8bf7\u5230" + noun
                    + "\u7533\u8bf7\u8be6\u60c5\u6838\u5bf9\uff0c\u5e76\u4ece"
                    + noun + "\u4efb\u52a1\u4e2d\u5fc3\u7ee7\u7eed\u5206\u89e3\u8ba2\u8d27\u3002"
                    + (subcontract ? subcontractApplicationKitSentence(documentId) : "");
            String actionRoute = (purchase ? "/purchase/requests/"
                    : "/subcontract/applications/") + documentId;
            String requiredViewAuthority = purchase
                    ? PURCHASE_REQUEST_VIEW_AUTHORITY
                    : SUBCONTRACT_APPLICATION_VIEW_AUTHORITY;
            notifyPreplanSupplyRecipients(
                    TYPE_TASK,
                    title,
                    content,
                    actionRoute,
                    requiredViewAuthority);
        });
    }

    /**
     * ADR-156: 新委外需求提醒里说明直属物料齐不齐——一条都不能下时任务中心先锁住、物料到了再提醒可下单;
     * 部分明细能下时提示先按「可下单」数量下单。可下单数量只读 fn_subcontract_application_orderable_qty。
     */
    private String subcontractApplicationKitSentence(UUID applicationId) {
        Map<String, Object> kit = one("""
                SELECT COUNT(*) AS line_count,
                       COUNT(*) FILTER (WHERE fn_subcontract_application_orderable_qty(item.id) > 0) AS orderable_lines
                FROM subcontract_application_items item
                WHERE item.application_id = ? AND item.is_deleted = FALSE
                """, applicationId);
        long lines = kit == null || kit.get("line_count") == null ? 0 : ((Number) kit.get("line_count")).longValue();
        long orderable = kit == null || kit.get("orderable_lines") == null
                ? 0 : ((Number) kit.get("orderable_lines")).longValue();
        if (lines == 0) return "";
        if (orderable == 0) {
            return "直属物料还没齐套，委外任务中心先锁住这张申请(委外价格每天不一样，物料齐了才解锁下单)，物料到了系统会再提醒可下单。";
        }
        if (orderable < lines) {
            return "其中 " + orderable + " 条明细的直属物料已够下单，可先按委外任务中心显示的「可下单」数量下单，其余等物料到了再提醒。";
        }
        return "直属物料已够下单，请按委外任务中心显示的「可下单」数量下单。";
    }

    // ---------- ADR-143 委外领料: 可领料卡 / 领料待发料 / 撤回 / 发料回执 / 红冲 ----------

    /**
     * 领料重算(Outbox 投递, 业务事务已提交): 交给委外领料模块按实时数据算受影响订货明细的可领量,
     * 由它比对提醒水位后回调 {@link #refreshSubcontractDrawAvailable} / {@link #resolveSubcontractDrawAvailable}。
     * 载荷 {goodsId,colorId} 按物料找受影响的订货明细; 否则按 orderItemIds / orderItemId / 聚合 id。
     * 先取委外领料提醒的全局串行锁: 两个并发投递不会各自读到旧水位重复提醒, 旧快照也不会把刚撤掉的卡发回来。
     */
    private void deliverSubcontractDrawRecheck(UUID aggregateId, JsonNode payload) {
        com.uten.imp.application.port.SubcontractDrawRecheckPort recheck =
                drawRecheck == null ? null : drawRecheck.getIfAvailable();
        if (recheck == null) {
            throw new IllegalStateException("委外领料可领量重算服务未注册");
        }
        JsonNode facts = payload == null
                ? com.fasterxml.jackson.databind.node.MissingNode.getInstance() : payload;
        lockSubcontractDrawNotices();
        UUID goodsId = uuidOrNull(facts.path("goodsId").asText(null));
        if (goodsId != null) {
            recheck.recheckForMaterial(goodsId, uuidOrNull(facts.path("colorId").asText(null)));
            return;
        }
        Set<UUID> orderItemIds = new LinkedHashSet<>();
        for (JsonNode id : facts.path("orderItemIds")) {
            UUID orderItemId = uuidOrNull(id.asText(null));
            if (orderItemId != null) orderItemIds.add(orderItemId);
        }
        UUID single = uuidOrNull(facts.path("orderItemId").asText(null));
        if (single != null) orderItemIds.add(single);
        if (orderItemIds.isEmpty() && aggregateId != null) orderItemIds.add(aggregateId);
        if (!orderItemIds.isEmpty()) recheck.recheckForOrderItems(List.copyOf(orderItemIds));
    }

    /** 委外领料提醒的全局串行锁: 只在 Outbox 投递事务里取, 业务事务从不取, 不参与业务锁顺序。 */
    private void lockSubcontractDrawNotices() {
        jdbc.queryForObject("SELECT pg_advisory_xact_lock(hashtextextended(?, 0))::text",
                String.class, "subcontract-draw-notice");
    }

    /**
     * 同一张领料草稿的待发料卡在投递之间串行重建(待发料 / 撤回 / 发出回执): 先撤后发不会被并发投递
     * 插成两张卡, 也不会让旧快照在发出后把卡发回来。同样只在 Outbox 投递事务里取。
     */
    private void lockSubcontractDrawDraftNotices(UUID issueId) {
        jdbc.queryForObject("SELECT pg_advisory_xact_lock(hashtextextended(?, 0))::text",
                String.class, "subcontract-draw-draft-notice:" + issueId);
    }

    /**
     * 可领料行动卡(ADR-143 §4.4): 每个订货明细一张, 重要级, 收件人 = 订货单可见范围内持有
     * 领料权限的人。只由领料重算在 Outbox 投递事务里调用: 文案按 fn_subcontract_draw_summary 的实时
     * 可领量生成, 每次先撤旧卡再发新卡; 可领为 0、订货单已不在执行或领料计划已关闭时只撤卡。
     * 返回卡上写的可领量(只撤卡时 0), 重算按它记提醒水位。
     */
    @Override
    public BigDecimal refreshSubcontractDrawAvailable(UUID orderItemId) {
        if (orderItemId == null) return BigDecimal.ZERO;
        requireOutboxDelivery();
        lockSubcontractDrawNotices();
        return publishSubcontractDrawAvailable(orderItemId);
    }

    private BigDecimal publishSubcontractDrawAvailable(UUID orderItemId) {
        Map<String, Object> task = one("""
                SELECT order_header.id AS order_id, order_header.bill_no AS order_bill_no,
                       order_header.maker_id,
                       goods.code AS goods_code, goods.name AS goods_name,
                       unit.name AS unit_name,
                       summary.drawable_qty
                FROM subcontract_order_items order_item
                JOIN subcontract_orders order_header
                  ON order_header.id = order_item.order_id
                 AND order_header.status = 1
                 AND order_header.is_deleted = FALSE
                 AND COALESCE(order_header.is_closed, FALSE) = FALSE
                JOIN goods ON goods.id = order_item.goods_id
                LEFT JOIN units unit ON unit.id = order_item.unit_id
                CROSS JOIN LATERAL fn_subcontract_draw_summary(order_item.id) summary
                WHERE order_item.id = ?
                  AND order_item.is_deleted = FALSE
                  AND EXISTS (SELECT 1 FROM subcontract_material_plans plan
                              JOIN subcontract_material_plan_items open_line
                                ON open_line.plan_id = plan.id
                               AND open_line.order_item_id = order_item.id
                               AND open_line.is_deleted = FALSE
                               AND open_line.draw_closed_at IS NULL
                               AND open_line.issued_qty < fn_subcontract_draw_needed_qty(
                                   open_line.order_item_id, open_line.planned_qty, open_line.bom_unit_qty)
                              WHERE plan.order_id = order_header.id
                                AND plan.status = 'OPEN'
                                AND plan.is_deleted = FALSE)
                  AND GREATEST(COALESCE(order_item.received_qty, 0) - COALESCE(order_item.returned_qty, 0), 0)
                      + %s < order_item.qty
                """.formatted(SubcontractLossSettlementSql.acceptedLossQty("order_item.id")), orderItemId);
        BigDecimal drawable = task == null ? BigDecimal.ZERO : bd(task.get("drawable_qty"));
        resolveReviewNotices(AGGREGATE_SUBCONTRACT_ORDER_ITEM, orderItemId,
                drawable.signum() > 0 ? "STATE_CHANGED" : "NOT_DRAWABLE");
        if (drawable.signum() <= 0) return BigDecimal.ZERO;
        String orderNo = str(task.get("order_bill_no"));
        String target = subcontractTargetName(task);
        String quantity = qtyWithUnit(drawable, task.get("unit_name"));
        String title = "委外可领料：" + orderNo + " " + target + " 可领 " + quantity;
        String content = "委外订货单 " + orderNo + " 的委外件 " + target + " 现在可领 " + quantity
                + "(直属物料已备齐这部分)。请到委外任务中心「领料」核对后提交领料，提交后由仓库发料；"
                + "可领数量以领料页实时计算为准，被别的委外任务先领走时会变少。";
        String route = SUBCONTRACT_DRAW_SEGMENT_ROUTE + orderItemId;
        for (UUID recipient : subcontractDrawRecipients((UUID) task.get("maker_id"))) {
            sendToUser(recipient, TYPE_TASK, title, content, route,
                    EVENT_SUBCONTRACT_DRAW_AVAILABLE, "important", orderItemId);
        }
        return drawable;
    }

    /** 提交领料、结束领料、订单红冲或可领归零: 撤掉该订货明细的可领料行动卡。 */
    @Override
    public void resolveSubcontractDrawAvailable(UUID orderItemId) {
        if (orderItemId == null) return;
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_SUBCONTRACT_DRAW_AVAILABLE_RESOLVED, AGGREGATE_SUBCONTRACT_ORDER_ITEM,
                    orderItemId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            lockSubcontractDrawNotices();
            resolveReviewNotices(AGGREGATE_SUBCONTRACT_ORDER_ITEM, orderItemId, "DRAW_HANDLED");
        });
    }

    /**
     * ADR-156 可下单行动卡: 每个委外申请明细一张, 重要级, 收件人 = 采购委外部门里能读通知、能看委外申请、
     * 能生成委外订货单的人(与「新委外需求」同一批人)。只由可下单重算在 Outbox 投递事务里调用: 文案按
     * fn_subcontract_application_orderable_qty 的实时可下单量生成, 每次先撤旧卡再发新卡; 可下单为 0 时只撤卡。
     * 返回卡上写的可下单量(只撤卡时 0), 重算按它记提醒水位。
     */
    @Override
    public BigDecimal refreshSubcontractOrderKitReady(UUID applicationItemId) {
        if (applicationItemId == null) return BigDecimal.ZERO;
        requireOutboxDelivery();
        lockSubcontractDrawNotices();
        return publishSubcontractOrderKitReady(applicationItemId);
    }

    private BigDecimal publishSubcontractOrderKitReady(UUID applicationItemId) {
        Map<String, Object> task = one("""
                SELECT application.bill_no, goods.code AS goods_code, goods.name AS goods_name,
                       unit.name AS unit_name,
                       fn_subcontract_application_open_qty(item.id) AS open_qty,
                       fn_subcontract_application_orderable_qty(item.id) AS orderable_qty
                FROM subcontract_application_items item
                JOIN subcontract_applications application ON application.id = item.application_id
                JOIN goods ON goods.id = item.goods_id
                LEFT JOIN units unit ON unit.id = item.unit_id
                WHERE item.id = ? AND item.is_deleted = FALSE
                """, applicationItemId);
        BigDecimal orderable = task == null ? BigDecimal.ZERO : bd(task.get("orderable_qty"));
        resolveReviewNotices(AGGREGATE_SUBCONTRACT_APPLICATION_ITEM, applicationItemId,
                orderable.signum() > 0 ? "STATE_CHANGED" : "NOT_ORDERABLE");
        if (orderable.signum() <= 0) return BigDecimal.ZERO;
        String billNo = str(task.get("bill_no"));
        String target = subcontractTargetName(task);
        BigDecimal open = bd(task.get("open_qty"));
        String quantity = qtyWithUnit(orderable, task.get("unit_name"));
        boolean whole = orderable.compareTo(open) >= 0;
        String title = "委外可下单：" + billNo + " " + target + " 可下单 " + quantity;
        String content = "委外申请 " + billNo + " 的委外件 " + target + " 直属物料"
                + (whole ? "已全部齐套" : "已够做 " + quantity + "(还差 "
                        + qtyWithUnit(open.subtract(orderable), task.get("unit_name")) + " 等物料)")
                + "，现在可以生成委外订货单，可下单 " + quantity
                + "。请到委外任务中心「待处理」生成委外订货单；可下单数量以任务中心实时计算为准，"
                + "物料被别的委外单先占走时会变少。";
        String route = SUBCONTRACT_PENDING_SEGMENT_ROUTE + java.net.URLEncoder.encode(
                billNo, java.nio.charset.StandardCharsets.UTF_8);
        for (UUID recipient : subcontractOrderKitRecipients()) {
            sendToUser(recipient, TYPE_TASK, title, content, route,
                    EVENT_SUBCONTRACT_ORDER_KIT_READY, "important", applicationItemId);
        }
        return orderable;
    }

    /** 可下单归零、已全部下单或申请关闭: 撤掉该申请明细的可下单行动卡。 */
    @Override
    public void resolveSubcontractOrderKitReady(UUID applicationItemId) {
        if (applicationItemId == null) return;
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_SUBCONTRACT_ORDER_KIT_READY_RESOLVED, AGGREGATE_SUBCONTRACT_APPLICATION_ITEM,
                    applicationItemId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            lockSubcontractDrawNotices();
            resolveReviewNotices(AGGREGATE_SUBCONTRACT_APPLICATION_ITEM, applicationItemId, "NOT_ORDERABLE");
        });
    }

    /** 可下单卡的收件人: 采购委外部门(含下级)里能读通知、能看委外申请、能生成委外订货单的在职账号。 */
    private List<UUID> subcontractOrderKitRecipients() {
        List<UUID> recipients = new ArrayList<>();
        for (UUID userId : new LinkedHashSet<>(departmentUserIds("SUB_PURCHASE"))) {
            if (userHasAllAuthorities(userId, NOTICE_READ_AUTHORITY, SUBCONTRACT_APPLICATION_VIEW_AUTHORITY,
                    SUBCONTRACT_ORDER_DECOMPOSE_AUTHORITY)) {
                recipients.add(userId);
            }
        }
        return recipients;
    }

    /**
     * 委外领料行动的收件人: 能读通知、能看委外订货、持有领料权限, 且这张订货单在其归属可见
     * 范围内(查看全部 / 本人经手 / 交接现负责人 / 数据范围授权)。经手人没有领料权限时不发。
     */
    private List<UUID> subcontractDrawRecipients(UUID makerEmployeeId) {
        List<UUID> recipients = new ArrayList<>();
        for (UUID userId : userIdsWithPermissions(NOTICE_READ_AUTHORITY,
                SUBCONTRACT_ORDER_VIEW_AUTHORITY, SUBCONTRACT_ORDER_DRAW_AUTHORITY)) {
            if (userHasAllAuthorities(userId, SUBCONTRACT_VIEW_ALL_AUTHORITY)
                    || canReadOwnedDocument(userId, SUBCONTRACT_OWNER_SCOPE, makerEmployeeId)) {
                recipients.add(userId);
            }
        }
        return recipients;
    }

    /**
     * 一张委外领料草稿等仓库发料(ADR-143 §4.4「委外领料待发料」): 每张草稿一张行动卡, 发给草稿
     * 所在仓库的仓管(ADR-115 按仓分发)。草稿永不合并, 所以一张草稿只投递一次。
     */
    @Override
    public void notifySubcontractOutboundReady(UUID issueId) {
        if (issueId == null) return;
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_SUBCONTRACT_OUTBOUND_READY,
                    AGGREGATE_SUBCONTRACT_MATERIAL_ISSUE,
                    issueId,
                    Map.of(),
                    EVENT_SUBCONTRACT_OUTBOUND_READY + ':' + issueId);
            return;
        }
        deliverAtomically(() -> publishSubcontractDrawPending(issueId, null));
    }

    /**
     * 按草稿当前明细重建「委外领料待发料」卡: 先撤旧卡; 草稿已发出、已撤销或已没有领料行时只撤卡,
     * 返回 null。{@code leadIn} 非空时作为卡片正文开头(撤回部分领料后刷新卡片用)。
     */
    private Map<String, Object> publishSubcontractDrawPending(UUID issueId, String leadIn) {
        lockSubcontractDrawDraftNotices(issueId);
        Map<String, Object> draft = one("""
                SELECT issue.bill_no AS issue_bill_no, issue.warehouse_id,
                       warehouse.name AS warehouse_name,
                       supplier.name AS supplier_name,
                       COALESCE(submitter.full_name, issue.maker_name) AS submitter_name,
                       MIN(order_header.bill_no) AS order_bill_no,
                       COUNT(DISTINCT concat_ws(':', item.goods_id::text, item.color_id::text))
                           AS material_kind_count
                FROM subcontract_material_issues issue
                JOIN subcontract_material_issue_items item
                  ON item.issue_id = issue.id
                 AND item.is_deleted = FALSE
                 AND item.plan_item_id IS NOT NULL
                JOIN subcontract_order_items order_item ON order_item.id = item.order_item_id
                JOIN subcontract_orders order_header ON order_header.id = order_item.order_id
                LEFT JOIN warehouses warehouse ON warehouse.id = issue.warehouse_id
                LEFT JOIN suppliers supplier ON supplier.id = issue.supplier_id
                LEFT JOIN employees submitter ON submitter.id = issue.maker_id
                WHERE issue.id = ?
                  AND issue.status = 0
                  AND issue.is_deleted = FALSE
                GROUP BY issue.bill_no, issue.warehouse_id, warehouse.name, supplier.name,
                         submitter.full_name, issue.maker_name
                """, issueId);
        resolveReviewNotices(AGGREGATE_SUBCONTRACT_MATERIAL_ISSUE, issueId,
                draft == null ? "STATE_CHANGED" : "PENDING_REFRESHED");
        if (draft == null) return null;
        String orderNo = str(draft.get("order_bill_no"));
        String kinds = str(draft.get("material_kind_count"));
        String warehouse = str(draft.get("warehouse_name"));
        String supplier = str(draft.get("supplier_name"));
        String submitter = str(draft.get("submitter_name"));
        String content = (leadIn == null || leadIn.isBlank() ? "" : leadIn.strip())
                + "委外人员" + (submitter.isBlank() ? "" : " " + submitter)
                + " 已提交委外订货单 " + orderNo + " 的领料，出仓草稿 "
                + str(draft.get("issue_bill_no")) + "，共 " + kinds + " 种物料"
                + (warehouse.isBlank() ? "" : "，发料仓库「" + warehouse + "」")
                + (supplier.isBlank() ? "" : "，发给委外商「" + supplier + "」")
                + "。请核对实物后拣货发出：实发只能少于或等于提交数量，少发的部分下次领料自动补齐；"
                + "能做哪些操作以拣货页上实际显示的按钮为准。";
        for (UUID warehouseUser : warehouseRecipients(warehousePool(NOTICE_READ_AUTHORITY,
                SUBCONTRACT_OUTBOUND_VIEW_AUTHORITY,
                SUBCONTRACT_OUTBOUND_EXECUTE_AUTHORITY), warehouseIdsOf(draft.get("warehouse_id")))) {
            sendToUser(
                    warehouseUser,
                    TYPE_TASK,
                    "委外领料待发料：" + orderNo + " 共 " + kinds + " 种物料",
                    content,
                    SUBCONTRACT_OUTBOUND_DRAFT_ROUTE + issueId,
                    EVENT_SUBCONTRACT_OUTBOUND_READY,
                    null,
                    issueId);
        }
        return draft;
    }

    /**
     * 委外人员撤回了这张草稿里尚未发出的领料。部分撤回: 按草稿剩余明细刷新待发料卡;
     * 整张撤销: 撤掉待发料卡并告诉仓管不用再拣货。
     */
    @Override
    public void notifySubcontractDrawWithdrawn(UUID issueId) {
        if (issueId == null) return;
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_SUBCONTRACT_DRAW_WITHDRAWN, AGGREGATE_SUBCONTRACT_MATERIAL_ISSUE,
                    issueId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> remaining = publishSubcontractDrawPending(
                    issueId, "委外人员撤回了这张草稿里的部分领料，请按草稿现有明细拣货，已撤回的物料不要再发。");
            if (remaining != null) return;
            Map<String, Object> header = one("""
                    SELECT issue.bill_no AS issue_bill_no, issue.warehouse_id, issue.status,
                           (SELECT order_header.bill_no
                            FROM subcontract_material_issue_items item
                            JOIN subcontract_order_items order_item ON order_item.id = item.order_item_id
                            JOIN subcontract_orders order_header ON order_header.id = order_item.order_id
                            WHERE item.issue_id = issue.id
                            ORDER BY item.line_no, item.id
                            LIMIT 1) AS order_bill_no
                    FROM subcontract_material_issues issue
                    WHERE issue.id = ?
                    """, issueId);
            // 已经审核发出的草稿不是被撤回的(发料回执另行通知), 不发撤回。
            Object status = header == null ? null : header.get("status");
            if (header == null || (status instanceof Number number && number.intValue() == 1)) return;
            String issueNo = str(header.get("issue_bill_no"));
            String orderNo = str(header.get("order_bill_no"));
            for (UUID warehouseUser : warehouseRecipients(warehousePool(NOTICE_READ_AUTHORITY,
                    SUBCONTRACT_OUTBOUND_VIEW_AUTHORITY), warehouseIdsOf(header.get("warehouse_id")))) {
                sendToUser(
                        warehouseUser,
                        TYPE_WORKFLOW,
                        "委外领料已撤回：" + issueNo,
                        "委外人员已撤回出仓草稿 " + issueNo
                                + (orderNo.isBlank() ? "" : "(委外订货单 " + orderNo + ")")
                                + " 的全部未发领料，草稿已撤销、占用的库存已释放，不用再拣货。",
                        // 草稿已撤销, 拣货页只认待发草稿: 落到待发料列表, 不落到打不开的拣货页。
                        SUBCONTRACT_OUTBOUND_LIST_ROUTE,
                        EVENT_SUBCONTRACT_DRAW_WITHDRAWN,
                        "normal");
            }
        });
    }

    /**
     * 仓库把一张委外领料草稿整张退回(本次不发): 撤掉仓库的待发料卡; 告诉提交领料的委外人员这批没有发、
     * 占用已释放、原因是什么, 料到了可以重新领。草稿永远是提交人建的(created_by), 不按订货经手人猜。
     */
    @Override
    public void notifySubcontractDrawReturned(UUID issueId, String reason) {
        if (issueId == null) return;
        String normalizedReason = reason == null ? "" : reason.strip();
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_SUBCONTRACT_DRAW_RETURNED, AGGREGATE_SUBCONTRACT_MATERIAL_ISSUE,
                    issueId, Map.of("reason", normalizedReason));
            return;
        }
        deliverAtomically(() -> {
            // 草稿已作废: 这里只撤仓库的待发料卡, 不会再发新卡。
            publishSubcontractDrawPending(issueId, null);
            Map<String, Object> header = one("""
                    SELECT issue.bill_no AS issue_bill_no, issue.created_by AS submitter_user_id,
                           warehouse.name AS warehouse_name,
                           (SELECT order_header.bill_no
                            FROM subcontract_material_issue_items item
                            JOIN subcontract_order_items order_item ON order_item.id = item.order_item_id
                            JOIN subcontract_orders order_header ON order_header.id = order_item.order_id
                            WHERE item.issue_id = issue.id
                            ORDER BY item.line_no, item.id
                            LIMIT 1) AS order_bill_no,
                           (SELECT CASE WHEN COUNT(DISTINCT item.order_item_id) = 1
                                        THEN MIN(item.order_item_id::text) END
                            FROM subcontract_material_issue_items item
                            WHERE item.issue_id = issue.id AND item.plan_item_id IS NOT NULL) AS order_item_id
                    FROM subcontract_material_issues issue
                    LEFT JOIN warehouses warehouse ON warehouse.id = issue.warehouse_id
                    WHERE issue.id = ? AND issue.status = 0
                    """, issueId);
            if (header == null || !(header.get("submitter_user_id") instanceof UUID submitter)) return;
            String issueNo = str(header.get("issue_bill_no"));
            String orderNo = str(header.get("order_bill_no"));
            String warehouse = str(header.get("warehouse_name"));
            String orderItemId = str(header.get("order_item_id"));
            sendToUser(
                    submitter,
                    TYPE_WORKFLOW,
                    "仓库退回了领料：" + (orderNo.isBlank() ? issueNo : orderNo),
                    (warehouse.isBlank() ? "仓库" : "仓库「" + warehouse + "」") + "退回了"
                            + (orderNo.isBlank() ? "" : "委外订货单 " + orderNo + " 的")
                            + "领料出仓单 " + issueNo + "，这批物料没有发出，占用的库存已释放"
                            + (normalizedReason.isBlank() ? "" : "。退回原因：" + normalizedReason)
                            + "。物料备齐后请在委外任务中心重新领料。",
                    orderItemId.isBlank()
                            ? SUBCONTRACT_DRAW_LIST_ROUTE
                            : SUBCONTRACT_DRAW_SEGMENT_ROUTE + orderItemId,
                    EVENT_SUBCONTRACT_DRAW_RETURNED,
                    "normal");
        });
    }

    /**
     * 仓库审核发出一张委外领料草稿(ADR-143 §4.4): 撤掉待发料卡; 告诉经手人与持有领料权限的人
     * 「本次发出后累计已发齐 X」并列出少发的物料; 委外商能做成委外件时提醒仓库预计回厂;
     * 来源分析的计划员收进度提醒。回厂登记的是委外件, 不按物料登记。
     */
    @Override
    public void notifySubcontractOutboundCompleted(UUID issueId) {
        if (issueId == null) return;
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_SUBCONTRACT_OUTBOUND_COMPLETED,
                    AGGREGATE_SUBCONTRACT_MATERIAL_ISSUE,
                    issueId,
                    Map.of(),
                    EVENT_SUBCONTRACT_OUTBOUND_COMPLETED + ':' + issueId);
            return;
        }
        deliverAtomically(() -> {
            lockSubcontractDrawDraftNotices(issueId);
            resolveReviewNotices(AGGREGATE_SUBCONTRACT_MATERIAL_ISSUE, issueId, "ISSUED");
            List<Map<String, Object>> targets = jdbc.queryForList("""
                    SELECT order_header.id AS order_id, order_header.bill_no AS order_bill_no,
                           order_header.maker_id, issue.bill_no AS issue_bill_no,
                           goods.code AS goods_code, goods.name AS goods_name,
                           unit.name AS unit_name,
                           summary.drawn_qty,
                           GREATEST(COALESCE(fn_subcontract_returnable_qty(order_item.id), 0)
                               - COALESCE((SELECT SUM(receipt_item.material_basis_qty)
                                           FROM subcontract_receipt_items receipt_item
                                           JOIN subcontract_receipts receipt
                                             ON receipt.id = receipt_item.receipt_id
                                            AND receipt.status = 1
                                            AND receipt.is_deleted = FALSE
                                           WHERE receipt_item.order_item_id = order_item.id
                                             AND receipt_item.is_deleted = FALSE), 0), 0)
                               AS returnable_qty
                    FROM subcontract_material_issues issue
                    JOIN subcontract_order_items order_item
                      ON EXISTS (SELECT 1 FROM subcontract_material_issue_items issue_item
                                 WHERE issue_item.issue_id = issue.id
                                   AND issue_item.order_item_id = order_item.id
                                   AND issue_item.is_deleted = FALSE
                                   AND issue_item.plan_item_id IS NOT NULL)
                    JOIN subcontract_orders order_header
                      ON order_header.id = order_item.order_id
                     AND order_header.status = 1
                     AND order_header.is_deleted = FALSE
                    JOIN goods ON goods.id = order_item.goods_id
                    LEFT JOIN units unit ON unit.id = order_item.unit_id
                    CROSS JOIN LATERAL fn_subcontract_draw_summary(order_item.id) summary
                    WHERE issue.id = ?
                      AND issue.status = 1
                      AND issue.is_deleted = FALSE
                    ORDER BY order_header.id, order_item.line_no, order_item.id
                    """, issueId);
            if (targets.isEmpty()) return;
            List<String> shortIssued = new ArrayList<>();
            // 少发 = 每种物料「提交量」(在用的行 + 仓库整行删掉不发的行) − 实发(在用的行)。
            // 委外人员撤回的行不写 warehouse_dropped_at, 不算少发。
            for (Map<String, Object> line : jdbc.queryForList("""
                    SELECT goods.code AS goods_code, goods.name AS goods_name,
                           unit.name AS unit_name,
                           SUM(issue_item.requested_qty)
                               - COALESCE(SUM(issue_item.qty) FILTER (WHERE issue_item.is_deleted = FALSE), 0)
                               AS short_qty
                    FROM subcontract_material_issue_items issue_item
                    JOIN goods ON goods.id = issue_item.goods_id
                    LEFT JOIN units unit ON unit.id = issue_item.unit_id
                    WHERE issue_item.issue_id = ?
                      AND issue_item.plan_item_id IS NOT NULL
                      AND (issue_item.is_deleted = FALSE OR issue_item.warehouse_dropped_at IS NOT NULL)
                    GROUP BY goods.id, goods.code, goods.name, unit.name
                    HAVING SUM(issue_item.requested_qty)
                           - COALESCE(SUM(issue_item.qty) FILTER (WHERE issue_item.is_deleted = FALSE), 0) > 0
                    ORDER BY goods.code, goods.name
                    """, issueId)) {
                shortIssued.add(goodsName(line, "物料") + " "
                        + qtyWithUnit(bd(line.get("short_qty")), line.get("unit_name")));
            }
            Map<UUID, List<Map<String, Object>>> byOrder = new LinkedHashMap<>();
            for (Map<String, Object> target : targets) {
                byOrder.computeIfAbsent((UUID) target.get("order_id"), ignored -> new ArrayList<>())
                        .add(target);
            }
            for (List<Map<String, Object>> orderTargets : byOrder.values()) {
                Map<String, Object> first = orderTargets.get(0);
                UUID orderId = (UUID) first.get("order_id");
                String orderNo = str(first.get("order_bill_no"));
                String issueNo = str(first.get("issue_bill_no"));
                List<String> drawn = new ArrayList<>();
                List<String> returnable = new ArrayList<>();
                for (Map<String, Object> target : orderTargets) {
                    BigDecimal drawnQty = bd(target.get("drawn_qty"));
                    if (drawnQty.signum() > 0) {
                        drawn.add(subcontractTargetName(target) + " "
                                + qtyWithUnit(drawnQty, target.get("unit_name")));
                    }
                    BigDecimal returnableQty = bd(target.get("returnable_qty"));
                    if (returnableQty.signum() > 0) {
                        returnable.add(subcontractTargetName(target) + " "
                                + qtyWithUnit(returnableQty, target.get("unit_name")));
                    }
                }
                String content = "委外出仓单 " + issueNo + " 已审核发出直属物料。"
                        + (drawn.isEmpty()
                                ? "本次发出后还没有发齐一整套委外件，其余物料发出后再通知委外商加工"
                                : "本次发出后累计已发齐 " + String.join("、", drawn) + "，可通知委外商加工")
                        + (shortIssued.isEmpty()
                                ? ""
                                : "；少发：" + String.join("、", shortIssued) + "(下次领料自动补齐)")
                        + "。回厂时登记的是委外件，不按物料登记；通知不代表已回厂。";
                Set<UUID> recipients = new LinkedHashSet<>();
                UUID makerUserId = subcontractMakerUserId((UUID) first.get("maker_id"));
                if (makerUserId != null) recipients.add(makerUserId);
                recipients.addAll(subcontractDrawRecipients((UUID) first.get("maker_id")));
                for (UUID recipient : recipients) {
                    sendToUser(
                            recipient,
                            TYPE_WORKFLOW,
                            "委外直属物料已发出：" + orderNo,
                            content,
                            "/subcontract/orders/" + orderId,
                            EVENT_SUBCONTRACT_OUTBOUND_COMPLETED);
                }
                if (returnable.isEmpty()) continue;
                for (UUID warehouseUser : warehouseRecipients(warehousePool(NOTICE_READ_AUTHORITY, "warehouse_inbound:view"),
                        subcontractOrderWarehouseIds(orderId))) {
                    sendToUser(
                            warehouseUser,
                            TYPE_TASK,
                            "委外预计回厂：" + orderNo,
                            "委外出仓单 " + issueNo + " 已审核发出直属物料，委外商手里的料还能做成 "
                                    + String.join("、", returnable)
                                    + "。回厂时请在预计到货任务中心按委外件登记实际回厂，不要按物料登记；"
                                    + "通知不代表已经到货。",
                            "/warehouse/inbound/expectations",
                            EVENT_SUBCONTRACT_OUTBOUND_COMPLETED);
                }
            }
            for (Map<String, Object> analysis : jdbc.queryForList("""
                    SELECT DISTINCT material_analysis.id AS analysis_id,
                           material_analysis.maker_id,
                           issue.bill_no AS issue_bill_no
                    FROM subcontract_material_issues issue
                    JOIN subcontract_material_issue_items issue_item
                      ON issue_item.issue_id = issue.id
                     AND issue_item.is_deleted = FALSE
                     AND issue_item.plan_item_id IS NOT NULL
                    JOIN subcontract_order_items order_item
                      ON order_item.id = issue_item.order_item_id
                     AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                    JOIN subcontract_order_item_sources src
                      ON src.order_item_id = order_item.id
                    JOIN subcontract_application_items application_item
                      ON application_item.id = src.application_item_id
                     AND COALESCE(application_item.is_deleted, FALSE) = FALSE
                    JOIN subcontract_applications application
                      ON application.id = application_item.application_id
                     AND COALESCE(application.is_deleted, FALSE) = FALSE
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.external_item_id = application_item.id
                    JOIN preplan_supply_actions supply_action
                      ON supply_action.id = allocation.action_id
                     AND supply_action.route = 'SUBCONTRACT'
                     AND supply_action.status <> 'CANCELLED'
                     AND supply_action.external_document_type =
                         'SUBCONTRACT_APPLICATION'
                     AND supply_action.external_document_id = application.id
                    JOIN production_material_analyses material_analysis
                      ON material_analysis.id = supply_action.analysis_id
                     AND material_analysis.is_deleted = FALSE
                    WHERE issue.id = ?
                      AND issue.status = 1
                      AND issue.is_deleted = FALSE
                    ORDER BY material_analysis.id
                    """, issueId)) {
                UUID makerUserId = userIdOfEmployee(
                        (UUID) analysis.get("maker_id"));
                notifyUser(
                        makerUserId,
                        TYPE_WORKFLOW,
                        "委外直属物料已发出：" + str(analysis.get("issue_bill_no")),
                        "委外订货的直属物料已审核发给委外商，现等待委外加工、回厂收货和来料质检。"
                                + "请在原物料分析查看该委外行动的进度；本通知不代表已回厂或"
                                + "品质已结案。",
                        "/production/material-analyses/"
                                + analysis.get("analysis_id") + "/summary",
                        EVENT_SUBCONTRACT_OUTBOUND_COMPLETED);
            }
        });
    }

    /**
     * 已发出的委外领料被红冲: 按物料列出撤销发出的数量, 告诉经手人与持有领料权限的人;
     * 并补偿此前给仓库的「预计回厂」提醒。可领量由领料重算另行刷新。
     */
    @Override
    public void notifySubcontractOutboundReversed(UUID issueId) {
        if (issueId == null) return;
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_SUBCONTRACT_OUTBOUND_REVERSED,
                    AGGREGATE_SUBCONTRACT_MATERIAL_ISSUE,
                    issueId,
                    Map.of(),
                    EVENT_SUBCONTRACT_OUTBOUND_REVERSED + ':' + issueId);
            return;
        }
        deliverAtomically(() -> {
            Map<UUID, List<Map<String, Object>>> byOrder = new LinkedHashMap<>();
            for (Map<String, Object> line : jdbc.queryForList("""
                    SELECT order_header.id AS order_id, order_header.bill_no AS order_bill_no,
                           order_header.maker_id, issue.bill_no AS issue_bill_no,
                           goods.code AS goods_code, goods.name AS goods_name,
                           unit.name AS unit_name,
                           SUM(issue_item.qty) AS reversed_qty
                    FROM subcontract_material_issues issue
                    JOIN subcontract_material_issue_items issue_item
                      ON issue_item.issue_id = issue.id
                     AND issue_item.is_deleted = FALSE
                     AND issue_item.plan_item_id IS NOT NULL
                    JOIN subcontract_order_items order_item
                      ON order_item.id = issue_item.order_item_id
                    JOIN subcontract_orders order_header
                      ON order_header.id = order_item.order_id
                     AND order_header.is_deleted = FALSE
                    JOIN goods ON goods.id = issue_item.goods_id
                    LEFT JOIN units unit ON unit.id = issue_item.unit_id
                    WHERE issue.id = ?
                      AND issue.status = -1
                      AND issue.is_deleted = FALSE
                    GROUP BY order_header.id, order_header.bill_no, order_header.maker_id,
                             issue.bill_no, goods.id, goods.code, goods.name, unit.name
                    ORDER BY order_header.id, goods.code, goods.name
                    """, issueId)) {
                byOrder.computeIfAbsent((UUID) line.get("order_id"), ignored -> new ArrayList<>())
                        .add(line);
            }
            for (List<Map<String, Object>> lines : byOrder.values()) {
                Map<String, Object> first = lines.get(0);
                UUID orderId = (UUID) first.get("order_id");
                String orderNo = str(first.get("order_bill_no"));
                String issueNo = str(first.get("issue_bill_no"));
                List<String> materials = new ArrayList<>();
                for (Map<String, Object> line : lines) {
                    materials.add(goodsName(line, "物料") + " "
                            + qtyWithUnit(bd(line.get("reversed_qty")), line.get("unit_name")));
                }
                String content = "委外出仓单 " + issueNo + " 已红冲，撤销发出："
                        + String.join("、", materials)
                        + "。这些物料视为没有发给委外商，已领数量与可回厂数量按实时数据重算；"
                        + "需要时请到委外任务中心「领料」重新领料。";
                Set<UUID> recipients = new LinkedHashSet<>();
                UUID makerUserId = subcontractMakerUserId((UUID) first.get("maker_id"));
                if (makerUserId != null) recipients.add(makerUserId);
                recipients.addAll(subcontractDrawRecipients((UUID) first.get("maker_id")));
                for (UUID recipient : recipients) {
                    sendToUser(
                            recipient,
                            TYPE_URGENT,
                            "委外领料发出已红冲：" + orderNo,
                            content,
                            "/subcontract/orders/" + orderId,
                            EVENT_SUBCONTRACT_OUTBOUND_REVERSED);
                }
                for (UUID warehouseUser : warehouseRecipients(warehousePool(NOTICE_READ_AUTHORITY, "warehouse_inbound:view"),
                        subcontractOrderWarehouseIds(orderId))) {
                    sendToUser(
                            warehouseUser,
                            TYPE_URGENT,
                            "委外预计回厂已撤回：" + orderNo,
                            "委外出仓单 " + issueNo + " 已红冲，本批发出的物料已撤销。"
                                    + "请刷新预计到货任务中心；委外商手里其余已发物料能做成的委外件仍可登记回厂。",
                            "/warehouse/inbound/expectations",
                            EVENT_SUBCONTRACT_OUTBOUND_REVERSED);
                }
            }
        });
    }

    /**
     * Daily supplier-return warning. Delivery rechecks the physical facts so a
     * delayed event cannot report an order that has already returned in full.
     * IQC is intentionally not part of this warning; physically returned goods
     * belong to the quality queue even while inspection remains pending.
     */
    private void notifySubcontractReturnDue(UUID orderId, int dueDays) {
        if (dueDays < 1) return;   // 事件缺少窗口天数: 视为无效事件, 不按猜测的天数发提醒
        deliverAtomically(() -> {
            LocalDate today = BusinessTime.today();
            SubcontractReturnDueFacts.Snapshot order =
                    SubcontractReturnDueFacts.findCurrent(
                            jdbc,
                            orderId,
                            today.plusDays(dueDays));
            if (order == null || order.deliverDate() == null) return;

            Set<UUID> recipients = new LinkedHashSet<>();
            UUID orderMaker = subcontractMakerUserId(order.makerEmployeeId());
            if (orderMaker != null) recipients.add(orderMaker);
            for (Map<String, Object> analysis : jdbc.queryForList("""
                    SELECT DISTINCT material_analysis.maker_id
                    FROM subcontract_order_items order_item
                    JOIN subcontract_order_item_sources src
                      ON src.order_item_id = order_item.id
                    JOIN subcontract_application_items application_item
                      ON application_item.id = src.application_item_id
                     AND COALESCE(application_item.is_deleted, FALSE) = FALSE
                    JOIN subcontract_applications application
                      ON application.id = application_item.application_id
                     AND COALESCE(application.is_deleted, FALSE) = FALSE
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.external_item_id = application_item.id
                    JOIN preplan_supply_actions supply_action
                      ON supply_action.id = allocation.action_id
                     AND supply_action.route = 'SUBCONTRACT'
                     AND supply_action.status <> 'CANCELLED'
                     AND supply_action.external_document_type =
                         'SUBCONTRACT_APPLICATION'
                     AND supply_action.external_document_id = application.id
                    JOIN production_material_analyses material_analysis
                      ON material_analysis.id = supply_action.analysis_id
                     AND material_analysis.is_deleted = FALSE
                    WHERE order_item.order_id = ?
                      AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                    ORDER BY material_analysis.maker_id
                    """, orderId)) {
                UUID analysisMaker = userIdOfEmployee(
                        (UUID) analysis.get("maker_id"));
                if (analysisMaker != null) recipients.add(analysisMaker);
            }
            if (recipients.isEmpty()) return;

            long daysLeft = ChronoUnit.DAYS.between(today, order.deliverDate());
            String timing = daysLeft < 0
                    ? "已逾期 " + (-daysLeft) + " 天"
                    : daysLeft == 0
                            ? "今日到期"
                            : "距约定回厂日 " + daysLeft + " 天";
            String title = (daysLeft < 0
                    ? "委外回厂已逾期："
                    : "委外回厂交期提醒：") + order.billNo();
            String content = "委外订货单 " + order.billNo() + " " + timing
                    + "。该单已把直属物料发给委外商，委外商手里还有能做成的委外件尚未物理回厂。"
                    + "请跟进委外商，并在实物到厂后由仓库登记回厂。"
                    + "本通知仅作交期提醒，不代表已回厂、来料质检已结案或订单完成；"
                    + "实际状态以订单全链路进度为准。";
            String route = "/subcontract/orders/" + orderId;
            String priority = daysLeft < 0 ? "important" : "normal";
            for (UUID recipient : recipients) {
                sendToUser(
                        recipient,
                        TYPE_URGENT,
                        title,
                        content,
                        route,
                        EVENT_SUBCONTRACT_RETURN_DUE,
                        priority);
            }
        });
    }

    /** 出货单涉及的仓库: 表头仓 + 拣货时逐行选定的仓(V631)。 */
    private List<UUID> shipmentWarehouseIds(UUID shipmentId) {
        return warehouseIdsQuery("""
                SELECT warehouse_id FROM sales_shipments WHERE id = ?
                UNION
                SELECT warehouse_id FROM sales_shipment_items
                WHERE shipment_id = ? AND is_deleted = FALSE
                """, shipmentId, shipmentId);
    }

    /** 委外回厂的收货仓(ADR-149): 与预计到货同一逐行规则(订货表头仓 → 委外申请表头仓 → 货品所属仓)。 */
    private List<UUID> subcontractOrderWarehouseIds(UUID orderId) {
        if (orderId == null) return List.of();
        return warehouseIdsQuery(
                "SELECT unnest(fn_procurement_order_inbound_warehouse_ids('SUBCONTRACT', CAST(? AS uuid)))", orderId);
    }

    /** 「编号 名称」标签(委外件); 两者都没有时用「委外件」。 */
    private static String subcontractGoodsLabel(Map<String, Object> item) {
        String label = (str(item.get("goods_code")) + " "
                + str(item.get("goods_name"))).strip();
        return label.isBlank() ? "委外件" : label;
    }

    /** 委外件名称(没有名称时用编号)。 */
    private static String subcontractTargetName(Map<String, Object> row) {
        return goodsName(row, "委外件");
    }

    /** 货品名称; 没有名称时用编号, 都没有时用 fallback。 */
    private static String goodsName(Map<String, Object> row, String fallback) {
        String name = str(row.get("goods_name")).strip();
        if (!name.isBlank()) return name;
        String code = str(row.get("goods_code")).strip();
        return code.isBlank() ? fallback : code;
    }

    /** 数量 + 单位(单位为空时只有数量)。 */
    private static String qtyWithUnit(BigDecimal value, Object unitName) {
        String unit = str(unitName).strip();
        return qty(value) + (unit.isBlank() ? "" : " " + unit);
    }

    /** ④ 数量不足（补产）通知销售：报工完结缺额自动生成补产计划后。 */
    public void notifyRemakeCreated(UUID reportId) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_REMAKE_CREATED, "PRODUCTION_DAILY_REPORT", reportId,
                    Map.of());
            return;
        }
        deliverAtomically(() -> {
            String reportBillNo = oneStr(
                    "SELECT bill_no FROM production_daily_reports WHERE id = ?", reportId);
            for (Map<String, Object> r : jdbc.queryForList("""
                    SELECT oi.order_id, rp.bill_no AS plan_no, SUM(rl.allocated_qty) AS qty
                    FROM production_plans rp
                    JOIN production_plan_items ri ON ri.plan_id = rp.id
                    JOIN plan_order_item_links rl ON rl.plan_item_id = ri.id AND rl.is_deleted = false AND rl.source = 1
                    JOIN sales_order_items oi ON oi.id = rl.order_item_id
                    WHERE rp.source_daily_report_id = ?
                    GROUP BY oi.order_id, rp.bill_no
                    """, reportId)) {
                OrderRef o = orderRef((UUID) r.get("order_id"));
                if (o == null) continue;
                notifyUser(o.ownerUserId(), TYPE_TASK,
                        "数量不足·已补产：" + o.billNo(),
                        "订单 " + o.billNo() + " 报工完结缺额 " + qty(bd(r.get("qty")))
                                + "，已自动生成补产计划 " + str(r.get("plan_no")) + "(报工单 " + reportBillNo
                                + ")，待调度审核排产。",
                        o.route());
            }
        });
    }

    /**
     * 执行段派工/开工节点通知归属销售。销售来源只认精确分摊账，
     * 不按相同货品或计划行猜测订单；内部生产段因此不会误发销售通知。
     */
    public void notifyExecutionSegmentTransition(UUID segmentId, boolean started) {
        String eventType = started ? EVENT_SEGMENT_STARTED : EVENT_SEGMENT_DISPATCHED;
        if (!isOutboxDelivery()) {
            outbox.publish(eventType, "PRODUCTION_EXECUTION_SEGMENT", segmentId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> segment = one("""
                    SELECT s.segment_code, s.planned_qty, s.plan_begin_date,
                           s.plan_end_date, p.bill_no AS plan_no, g.code AS goods
                    FROM production_execution_segments s
                    JOIN production_plans p ON p.id = s.plan_id
                    JOIN goods g ON g.id = s.product_goods_id
                    WHERE s.id = ? AND s.is_deleted = false
                    """, segmentId);
            if (segment == null) return;
            List<Map<String, Object>> owners = jdbc.queryForList("""
                    SELECT oi.order_id, SUM(a.allocated_qty) AS allocated_qty
                    FROM execution_segment_sales_allocations a
                    JOIN sales_order_items oi ON oi.id = a.sales_order_item_id
                    WHERE a.execution_segment_id = ?
                      AND oi.is_deleted = false
                    GROUP BY oi.order_id
                    ORDER BY oi.order_id
                    """, segmentId);
            String node = started ? "已开工" : "已派工";
            String titlePrefix = started ? "生产开工：" : "生产派工：";
            for (Map<String, Object> owner : owners) {
                OrderRef order = orderRef((UUID) owner.get("order_id"));
                if (order == null) continue;
                String begin = segment.get("plan_begin_date") == null
                        ? "未定" : segment.get("plan_begin_date").toString();
                String end = segment.get("plan_end_date") == null
                        ? "未定" : segment.get("plan_end_date").toString();
                notifyUser(order.ownerUserId(), TYPE_WORKFLOW,
                        titlePrefix + order.billNo(),
                        "订单 " + order.billNo() + " 的货品 "
                                + str(segment.get("goods")) + " " + node
                                + " " + qty(bd(owner.get("allocated_qty")))
                                + "(计划 " + str(segment.get("plan_no"))
                                + "，子任务 " + str(segment.get("segment_code"))
                                + "，计划 " + begin + " 至 " + end + ")。",
                        order.route());
            }
        });
    }

    /**
     * A purchase/subcontract receipt changed a material-complete execution
     * segment from WAITING to READY. The receipt id is part of the dedupe key:
     * replaying the same receipt is silent, while a later legitimate
     * demotion/re-kit can notify again from its new receipt.
     */
    public void notifyExecutionSegmentReady(
            UUID segmentId,
            UUID triggeringReceiptId,
            String sourceType) {
        String normalizedSource = sourceType == null ? "" : sourceType.strip();
        if (!isOutboxDelivery()) {
            if (triggeringReceiptId == null) {
                throw new IllegalArgumentException(
                        "triggeringReceiptId is required for a READY event");
            }
            outbox.publishOnce(
                    EVENT_SEGMENT_READY,
                    "PRODUCTION_EXECUTION_SEGMENT",
                    segmentId,
                    Map.of(
                            "triggeringReceiptId",
                            triggeringReceiptId.toString(),
                            "sourceType",
                            normalizedSource),
                    EVENT_SEGMENT_READY + ':' + segmentId + ':'
                            + triggeringReceiptId);
            return;
        }
        deliverAtomically(() -> {
            String sourceLabel = executionReadySourceLabel(normalizedSource);
            publishWorkshopTask(
                    segmentId, sourceLabel + "后工单已齐套，请确认领料安排");
        });
    }

    static String executionReadySourceLabel(String sourceType) {
        return switch (sourceType == null ? "" : sourceType.strip()) {
            case "PURCHASE" -> "采购到货";
            case "SUBCONTRACT" -> "委外回厂";
            case "MAKE" -> "自制件完工入库";
            case "MANUAL_RELEASE" -> "人工解除暂缓";
            default -> "物料状态变化";
        };
    }

    /**
     * 执行段后补/变更车间（或负责人）后重建车间任务卡：先按段办结旧卡（旧车间
     * 弹窗随即撤下），再按当前车间收件人口径重新投递。计划下达时车间为空的段，
     * 其首张任务卡正是由这里的后补分配补发——否则该段永远收不到车间通知。
     */
    public void notifyExecutionSegmentWorkshopAssigned(UUID segmentId) {
        if (!isOutboxDelivery()) {
            outbox.publish(
                    EVENT_SEGMENT_WORKSHOP_ASSIGNED,
                    "PRODUCTION_EXECUTION_SEGMENT",
                    segmentId,
                    Map.of());
            return;
        }
        deliverAtomically(() ->
                publishWorkshopTask(segmentId, "生产任务已分配到您的车间"));
    }

    private void publishWorkshopTasksForPlan(
            UUID planId, String triggerDescription) {
        List<UUID> segmentIds = jdbc.queryForList("""
                SELECT segment.id
                FROM production_execution_segments segment
                JOIN production_planning_packages package
                  ON package.id = segment.package_id
                 AND package.is_deleted = FALSE
                 AND package.status = 'CONFIRMED'
                WHERE segment.plan_id = ?
                  AND segment.is_deleted = FALSE
                  AND segment.status IN (
                      'WAITING','READY','DISPATCHED','IN_PROGRESS')
                ORDER BY segment.id
                """, UUID.class, planId);
        for (UUID segmentId : segmentIds) {
            publishWorkshopTask(segmentId, triggerDescription);
        }
    }

    private void publishWorkshopTasksForDraw(
            UUID stockDocId,
            String triggerDescription,
            boolean onlyFullyIssued) {
        List<UUID> segmentIds = jdbc.queryForList("""
                SELECT DISTINCT demand.execution_segment_id
                FROM stock_document_items item
                JOIN production_planning_package_document_items mapping
                  ON mapping.document_type = 'DRAW'
                 AND mapping.document_id = item.doc_id
                 AND mapping.document_item_id = item.id
                JOIN production_material_demands demand
                  ON demand.id = mapping.demand_id
                 AND demand.is_deleted = FALSE
                 AND demand.execution_segment_id IS NOT NULL
                JOIN production_planning_package_documents header
                  ON header.package_id = mapping.package_id
                 AND header.document_type = 'DRAW'
                 AND header.document_id = item.doc_id
                 AND header.execution_segment_id =
                     demand.execution_segment_id
                JOIN production_planning_packages package
                  ON package.id = mapping.package_id
                 AND package.status = 'CONFIRMED'
                 AND package.is_deleted = FALSE
                JOIN production_execution_segments segment
                  ON segment.id = demand.execution_segment_id
                 AND segment.package_id = mapping.package_id
                 AND segment.is_deleted = FALSE
                WHERE item.doc_id = ?
                  AND item.is_deleted = FALSE
                ORDER BY demand.execution_segment_id
                """, UUID.class, stockDocId);
        for (UUID segmentId : segmentIds) {
            publishWorkshopTask(
                    segmentId, triggerDescription, onlyFullyIssued);
        }
    }

    /** Existing callers and old outbox rows rebuild current facts without asserting unverifiable arrival quantities. */
    public void notifyWorkshopMaterialArrival(
            UUID segmentId, String triggerKey, String arrivalSummary) {
        notifyWorkshopMaterialArrival(segmentId, triggerKey, arrivalSummary, "CURRENT_STATE", List.of());
    }

    /** A physical arrival carries its immutable source identity; delivery revalidates reversal state. */
    public void notifyWorkshopMaterialArrival(UUID segmentId, String triggerKey, String arrivalSummary,
            String evidenceType, Collection<UUID> evidenceIds) {
        List<UUID> ids = evidenceIds == null ? List.of() : evidenceIds.stream()
                .filter(Objects::nonNull).distinct().sorted().toList();
        if (!isOutboxDelivery()) {
            outbox.publishOnce(EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,
                    "PRODUCTION_EXECUTION_SEGMENT", segmentId,
                    Map.of("arrival", arrivalSummary == null ? "" : arrivalSummary,
                            "evidenceType", evidenceType == null ? "CURRENT_STATE" : evidenceType,
                            "evidenceIds", ids.stream().map(UUID::toString).toList()),
                    EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL + ':' + segmentId + ':'
                            + (triggerKey == null ? "" : triggerKey));
            return;
        }
        publishWorkshopMaterialArrival(segmentId, arrivalSummary, evidenceType, ids);
    }

    private static List<UUID> workshopEvidenceIds(JsonNode node) {
        if (!node.isArray()) return List.of();
        List<UUID> ids = new ArrayList<>();
        for (JsonNode value : node) {
            try { ids.add(UUID.fromString(value.asText())); }
            catch (IllegalArgumentException invalid) { return List.of(); }
        }
        return ids.stream().distinct().sorted().toList();
    }

    boolean workshopArrivalEvidenceValid(String type, Collection<UUID> evidenceIds) {
        if (evidenceIds == null || evidenceIds.isEmpty()) return false;
        String source = switch (type == null ? "" : type) {
            case "FINISHED_IN" -> """
                SELECT document.id FROM stock_documents document
                WHERE document.id=ANY(CAST(string_to_array(?, ',') AS uuid[]))
                  AND document.doc_type='FINISHED_IN' AND document.status=1 AND NOT document.is_deleted
                """;
            case "DIRECT_REPORT" -> """
                SELECT report.id FROM production_daily_reports report
                WHERE report.id=ANY(CAST(string_to_array(?, ',') AS uuid[]))
                  AND report.status=1 AND NOT report.is_deleted
                  AND EXISTS (SELECT 1 FROM production_workshop_direct_transfers transfer
                      JOIN production_workshop_direct_transfer_items item ON item.transfer_id=transfer.id
                      WHERE transfer.source_report_id=report.id AND item.reversal_id IS NULL)
                  AND NOT EXISTS (SELECT 1 FROM production_workshop_direct_transfers transfer
                      JOIN production_workshop_direct_transfer_items item ON item.transfer_id=transfer.id
                      WHERE transfer.source_report_id=report.id AND item.reversal_id IS NOT NULL)
                """;
            case "IQC_STOCK_IN" -> """
                SELECT batch.id FROM procurement_iqc_stock_in_batches batch
                WHERE batch.id=ANY(CAST(string_to_array(?, ',') AS uuid[]))
                  AND EXISTS (SELECT 1 FROM procurement_iqc_stock_in_batch_items item WHERE item.batch_id=batch.id)
                  AND NOT EXISTS (SELECT 1 FROM procurement_iqc_stock_in_batch_items item
                      JOIN procurement_inspection_items inspection ON inspection.id=item.inspection_item_id
                      WHERE item.batch_id=batch.id AND inspection.status='REVERSED')
                  AND ((batch.receipt_type='PURCHASE' AND EXISTS (
                      SELECT 1 FROM purchase_receipts receipt WHERE receipt.id=batch.receipt_id
                        AND receipt.status=1 AND NOT receipt.is_deleted))
                    OR (batch.receipt_type='SUBCONTRACT' AND EXISTS (
                      SELECT 1 FROM subcontract_receipts receipt WHERE receipt.id=batch.receipt_id
                        AND receipt.status=1 AND NOT receipt.is_deleted)))
                """;
            default -> null;
        };
        if (source == null) return false;
        Set<UUID> ids = Set.copyOf(evidenceIds);
        String joined = ids.stream().sorted().map(UUID::toString).collect(java.util.stream.Collectors.joining(","));
        return Set.copyOf(jdbc.queryForList(source, UUID.class, joined)).equals(ids);
    }

    /** Notification eligibility uses actual source rights plus the same availability projection as preparation. */
    boolean workshopArrivalCanBenefit(UUID segmentId, String evidenceType, Collection<UUID> evidenceIds) {
        if ("DIRECT_REPORT".equals(evidenceType)) {
            if (evidenceIds == null || evidenceIds.isEmpty()) return false;
            String reports=evidenceIds.stream().distinct().sorted().map(UUID::toString)
                    .collect(java.util.stream.Collectors.joining(","));
            return Boolean.TRUE.equals(jdbc.queryForObject("""
                    SELECT EXISTS(SELECT 1 FROM production_material_demands demand
                      JOIN v_workshop_direct_supply_lots lot
                        ON lot.to_demand_id IN(demand.id,demand.split_root_demand_id) AND lot.received_qty>0
                      JOIN production_workshop_direct_transfer_items item ON item.id=lot.id
                      JOIN production_workshop_direct_transfers transfer ON transfer.id=item.transfer_id
                      WHERE demand.execution_segment_id=? AND NOT demand.is_deleted
                        AND demand.status NOT IN ('RELEASED','REVERSED')
                        AND transfer.source_report_id=ANY(CAST(string_to_array(?, ',') AS uuid[]))
                        AND fn_workshop_direct_relationship_allows(lot.producing_segment_id,demand.id))
                    """,Boolean.class,segmentId,reports));
        }
        String sources = switch (evidenceType) {
            case "IQC_STOCK_IN" -> """
                SELECT item.id,item.warehouse_id,item.goods_id,item.color_id,item.base_qty AS qty
                FROM procurement_iqc_stock_in_batch_items item
                WHERE item.batch_id=ANY(CAST(string_to_array(?, ',') AS uuid[]))
                """;
            case "FINISHED_IN" -> """
                SELECT item.id,document.warehouse_id,item.goods_id,item.color_id,
                    COALESCE(item.base_qty,item.qty*COALESCE(item.unit_rate,1)) AS qty
                FROM stock_documents document JOIN stock_document_items item ON item.doc_id=document.id
                WHERE document.id=ANY(CAST(string_to_array(?, ',') AS uuid[])) AND NOT item.is_deleted
                """;
            default -> null;
        };
        if (sources == null || evidenceIds == null || evidenceIds.isEmpty()) return false;
        String ids=evidenceIds.stream().distinct().sorted().map(UUID::toString).collect(java.util.stream.Collectors.joining(","));
        List<Map<String,Object>> rows=jdbc.queryForList("""
                WITH event_sources AS (%s), origins AS (
                    SELECT origin.* FROM preplan_stock_entitlement_events origin
                    JOIN event_sources source ON source.id=origin.event_group_id
                    WHERE origin.event_type IN ('ORIGIN_IQC','ORIGIN_MAKE')
                )
                SELECT DISTINCT demand.id AS demand_id,source.warehouse_id,
                    package.warehouse_id AS package_warehouse_id,plan.material_analysis_id AS analysis_id,
                    plan.material_analysis_item_id AS analysis_item_id,
                    source.qty>COALESCE((SELECT SUM(origin.qty) FROM origins origin
                        WHERE origin.event_group_id=source.id),0) AS public_slice,
                    EXISTS(SELECT 1 FROM origins origin
                        JOIN v_preplan_stock_entitlement_beneficiary_balance beneficiary
                          ON beneficiary.stock_reservation_id=origin.stock_reservation_id
                        WHERE origin.event_group_id=source.id AND beneficiary.effective_qty>0
                          AND beneficiary.beneficiary_analysis_id=plan.material_analysis_id
                          AND fn_analysis_plan_material_matches(plan.material_analysis_item_id,beneficiary.beneficiary_analysis_material_id)
                          AND fn_preplan_reservation_has_qualified_origin(origin.stock_reservation_id)) AS own_slice,
                    EXISTS(SELECT 1 FROM origins origin
                        JOIN preplan_stock_entitlement_events formal ON formal.stock_reservation_id=origin.stock_reservation_id
                            AND formal.event_type='FORMALIZE'
                        JOIN stock_reservations target ON target.id=formal.target_stock_reservation_id
                            AND NOT target.is_deleted AND target.qty-target.released_qty>0
                        WHERE origin.event_group_id=source.id
                          AND (target.demand_id=demand.id OR target.demand_id=demand.split_root_demand_id)
                          AND NOT EXISTS(SELECT 1 FROM preplan_stock_entitlement_events restored
                              WHERE restored.event_type='RESTORE' AND restored.counter_event_id=formal.id)) AS handed_over,
                    EXISTS(SELECT 1 FROM stock_reservations held
                        WHERE held.demand_id=demand.id AND held.warehouse_id=source.warehouse_id
                          AND fn_warehouse_same_main(source.warehouse_id,demand.warehouse_id)
                          AND NOT held.is_deleted AND held.qty-held.released_qty>0) AS public_prepared
                FROM event_sources source
                JOIN production_material_demands demand ON demand.goods_id=source.goods_id
                    AND demand.color_id IS NOT DISTINCT FROM source.color_id
                JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
                JOIN production_planning_packages package ON package.id=segment.package_id
                JOIN production_plans plan ON plan.id=segment.plan_id
                WHERE demand.execution_segment_id=? AND NOT demand.is_deleted
                    AND demand.status NOT IN ('RELEASED','REVERSED')
                """.formatted(sources),ids,segmentId);
        // Formal promotion may already have moved this public stock into the exact demand.
        if (rows.stream().anyMatch(row->Boolean.TRUE.equals(row.get("handed_over"))
                || Boolean.TRUE.equals(row.get("public_slice")) && Boolean.TRUE.equals(row.get("public_prepared")))) return true;
        if (rows.stream().noneMatch(row->Boolean.TRUE.equals(row.get("own_slice"))
                || Boolean.TRUE.equals(row.get("public_slice")))) return false;
        if (workshopReadiness == null || rows.isEmpty()) return false;
        var context=rows.getFirst();
        var availability=workshopReadiness.getObject().batchAvailability(
                (UUID)context.get("package_warehouse_id"),rows.stream().map(row->(UUID)row.get("demand_id")).distinct().toList(),
                (UUID)context.get("analysis_id"),(UUID)context.get("analysis_item_id"));
        var byDemand=availability.stream().collect(java.util.stream.Collectors.groupingBy(
                com.uten.imp.application.port.WorkshopMaterialAvailabilityReadPort.Availability::demandId));
        Map<UUID,BigDecimal> publicBudgets=new java.util.HashMap<>();
        for (var row:rows) {
            UUID demand=(UUID)row.get("demand_id"),warehouse=(UUID)row.get("warehouse_id");
            var material=byDemand.getOrDefault(demand,List.of());
            BigDecimal publicBudget=publicBudgets.computeIfAbsent(demand,ignored->
                    com.uten.imp.common.inventory.MainWarehouseStockBudget.publicBudget(
                    material.stream().map(item->item.publicQty()).reduce(BigDecimal.ZERO,BigDecimal::add),
                    material.stream().map(item->item.safetyQty()).max(BigDecimal::compareTo).orElse(BigDecimal.ZERO)));
            for (var item:material) if (item.warehouseId().equals(warehouse)) {
                if (Boolean.TRUE.equals(row.get("own_slice")) && item.qualifiedQty().signum()>0) return true;
                if (Boolean.TRUE.equals(row.get("public_slice")) && item.publicQty().signum()>0 && publicBudget.signum()>0) return true;
            }
        }
        return false;
    }

    private void publishWorkshopMaterialArrival(UUID segmentId, String arrivalSummary,
            String evidenceType, Collection<UUID> evidenceIds) {
        List<UUID> lockedSegmentIds = jdbc.queryForList("""
                SELECT id
                FROM production_execution_segments
                WHERE id = ? AND is_deleted = FALSE
                FOR UPDATE
                """, UUID.class, segmentId);
        if (lockedSegmentIds.isEmpty()) return;
        Map<String, Object> task = one("""
                SELECT task.segment_id, task.segment_code, task.plan_no,
                       task.segment_status,
                       task.product_code, task.product_name,
                       task.product_color_name, task.product_unit_name,
                       task.planned_qty, task.workshop_department_id, task.workshop_name,
                       task.responsible_employee_id,
                       route.start_route, route.continuous_supply,
                       route.auto_promote_when_ready,
                       notice_state.arrival_notice_capacity,
                       fn_execution_route_allows_auto_promote(task.segment_id) AS route_allows_auto_promote,
                       fn_execution_start_material_ready(task.segment_id) AS start_material_ready,
                       fn_execution_material_output_capacity(task.segment_id, FALSE) AS prepared_capacity
                FROM v_production_execution_workbench_segments task
                JOIN production_execution_segments route ON route.id = task.segment_id
                LEFT JOIN production_execution_segment_notice_state notice_state
                  ON notice_state.segment_id = task.segment_id
                JOIN production_plans active_plan ON active_plan.id=route.plan_id
                  AND active_plan.status=1 AND NOT active_plan.is_deleted
                  AND NOT active_plan.is_closed AND NOT active_plan.is_stopped AND NOT active_plan.is_canceled
                WHERE task.segment_id = ?
                """, segmentId);
        if (task == null) {
            noticeService.resolveReviewNotices("PRODUCTION_EXECUTION_SEGMENT", segmentId, "PLAN_INACTIVE");
            return;
        }
        String status = str(task.get("segment_status"));
        if (!Set.of("WAITING", "READY", "DISPATCHED", "IN_PROGRESS").contains(status)) {
            noticeService.resolveReviewNotices("PRODUCTION_EXECUTION_SEGMENT", segmentId, "STATE_CHANGED");
            return;
        }
        boolean validArrival = workshopArrivalEvidenceValid(evidenceType, evidenceIds);
        if (validArrival && !workshopArrivalCanBenefit(segmentId, evidenceType, evidenceIds)) return;
        UUID workshopId = (UUID) task.get("workshop_department_id");
        if (workshopId == null) return;
        List<Map<String, Object>> missingRows = jdbc.queryForList("""
                SELECT material.demand_id, goods.code AS goods_code, goods.name AS goods_name,
                       COALESCE(color.name, '') AS color_name,
                       material.stock_shortage_qty, units.name AS unit_name,
                       material.supply_route = 'MAKE' AS in_house_child
                FROM v_production_execution_segment_materials material
                JOIN goods ON goods.id = material.goods_id
                LEFT JOIN colors color ON color.id = material.color_id
                LEFT JOIN units ON units.id = material.unit_id
                WHERE material.execution_segment_id = ?
                  AND material.demand_status NOT IN ('RELEASED', 'REVERSED')
                  AND material.stock_shortage_qty > 0
                ORDER BY goods.name, goods.code
                """, segmentId);
        // 齐套生产到齐前不做段级预留，缺口只看预留会把「已到 100 还缺 900」说成「还缺 1000」
        // (ADR-095)：按齐套提升同口径的仓库可用量(专属权益 + 允许动用的公共库存)扣减后再说缺口。
        Map<UUID, BigDecimal> arrivedByDemand = workshopWarehouseAvailableByDemand(segmentId,
                missingRows.stream().map(row -> (UUID) row.get("demand_id")).toList());
        String route = str(task.get("start_route"));
        // 2026-10-06 修订二(ADR-165 / ADR-091 §九): 到货进展行动卡按「可支撑产能水位」弹——
        // 每种物料都有一些才首次给「可以生产 X 件」; 后续到货产能不涨不弹, 涨了(扣已领)才再弹;
        // 发卡或回落都把水位同步成当前值。路线未确认不发; 到货撤销(validArrival=false)不受
        // 闸门约束, 仍即时通知。
        if (validArrival && "WAITING".equals(status)
                && Boolean.TRUE.equals(task.get("auto_promote_when_ready"))
                && Boolean.TRUE.equals(task.get("route_allows_auto_promote"))) {
            // 会自动提升的段由齐套/可开工行动卡负责(tryPromote→notifyExecutionSegmentReady)——
            // 到货进展再发就是同一件事弹两次, 且发送前的 ARRIVAL_PROGRESS 办结还会把刚投递的
            // important 卡撤掉。这里不抬水位: 万一提升没成、任务随后被暂缓, 全齐卡仍要能弹出来。
            return;
        }
        BigDecimal capacity = workshopArrivalCapacity(segmentId, task, status, route, missingRows, arrivedByDemand);
        if (validArrival && !arrivalProgressWarrantsNotice(task, status, route, capacity)) {
            syncArrivalCapacityWatermark(segmentId, capacity);
            return;
        }
        String productUnit = str(task.get("product_unit_name"));
        String capacityText = capacity == null || capacity.signum() <= 0 ? ""
                : "（现有物料可支撑生产 " + qty(capacity) + (productUnit.isBlank() ? "" : " " + productUnit) + "）";
        String nextStep;
        if (route.isBlank()) {
            nextStep = "请先在「我的车间任务」确认生产路线（齐套 / 分批 / 持续生产）";
        } else if ("BATCH".equals(route)) {
            nextStep = Boolean.TRUE.equals(task.get("auto_promote_when_ready"))
                    ? "本单为分批生产路线：可按「分批领料」核对并领出本批" + capacityText
                    // 暂缓段拆批会被页面拒绝(「请先解除暂缓」), 指引先解除暂缓, 不邀请会被拦下的动作。
                    : "本单为分批生产路线：物料已能支撑本批" + capacityText + "；任务在暂缓中，请先解除暂缓再分批领料";
        } else if ("CONTINUOUS".equals(route)) {
            nextStep = "IN_PROGRESS".equals(status)
                    ? "持续生产中：请在原工单核对补料和报工进度" + capacityText
                        + "；同车间直送按实际交接投入，无需再开工或另建工单"
                    : workshopStartSupported(status, route, Boolean.TRUE.equals(task.get("start_material_ready")))
                        ? "现有物料已支持部分生产，可在原工单开工" + capacityText
                            + "；直送料将在开工时实际投入，后续继续补料"
                        : bd(task.get("prepared_capacity")).signum() > 0
                            ? "持续生产路线：已备物料支持部分产量" + capacityText + "，请提交领料，实际发料后开工"
                            : "持续生产路线：仍需等待各项必需物料共同支持部分产量；已有可领物料可先在原工单核对";
        } else if (missingRows.isEmpty()) {
            nextStep = "物料已齐套，可提交领料，领齐后开工";
        } else {
            nextStep = "齐套生产路线：等待剩余物料到货，到齐后提交领料";
        }
        StringBuilder shortages = new StringBuilder();
        int shown = 0;
        for (Map<String, Object> missing : missingRows) {
            if (shown == 6) {
                shortages.append("；等 ").append(missingRows.size()).append(" 种");
                break;
            }
            if (shown > 0) shortages.append("；");
            BigDecimal shortage = bd(missing.get("stock_shortage_qty"));
            BigDecimal arrived = arrivedByDemand.getOrDefault((UUID) missing.get("demand_id"), BigDecimal.ZERO)
                    .max(BigDecimal.ZERO).min(shortage);
            BigDecimal remaining = shortage.subtract(arrived);
            String unit = str(missing.get("unit_name")).isBlank() ? "" : " " + str(missing.get("unit_name"));
            shortages.append(str(missing.get("goods_name"))).append(' ')
                    .append(str(missing.get("goods_code")))
                    .append(str(missing.get("color_name")).isBlank()
                            ? "" : "(" + str(missing.get("color_name")) + ")")
                    .append(arrived.signum() > 0 ? " 仓库已到 " + qty(arrived) + unit + "，" : " ")
                    .append(remaining.signum() > 0 ? "还缺 " + qty(remaining) + unit : "已到齐待预留")
                    // 自制子件做完可能直送本车间也可能入库后领料，只说来源不许诺交接方式(ADR-096)。
                    .append(Boolean.TRUE.equals(missing.get("in_house_child")) ? "(自制子件在产)" : "");
            shown++;
        }
        String segmentCode = str(task.get("segment_code"));
        String product = (str(task.get("product_code")) + " "
                + str(task.get("product_name"))).strip();
        String workshop = str(task.get("workshop_name"));
        String content = (validArrival && arrivalSummary != null && !arrivalSummary.isBlank()
                ? arrivalSummary.strip()
                : "物料来源状态已更新（原到货数量不再作为当前可用量依据），已重新核对当前缺口")
                + "。生产计划 " + str(task.get("plan_no"))
                + "，工单 " + segmentCode
                + "，产品 " + (product.isBlank() ? "未命名产品" : product)
                + (workshop.isBlank() ? "" : "，车间 " + workshop)
                + (missingRows.isEmpty() ? "；当前物料没有缺口" : "；仍缺：" + shortages)
                + "；" + nextStep + "。请到「我的车间任务」办理。";
        noticeService.resolveReviewNotices(
                "PRODUCTION_EXECUTION_SEGMENT", segmentId, "ARRIVAL_PROGRESS");
        for (UUID recipient : workshopRecipientUserIds(
                workshopId, (UUID) task.get("responsible_employee_id"))) {
            sendToUser(
                    recipient, TYPE_TASK, (validArrival ? "物料到货进展：" : "物料状态更新：") + segmentCode, content,
                    "/production/workshop-tasks",
                    EVENT_PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED,
                    "normal", segmentId);
        }
        syncArrivalCapacityWatermark(segmentId, capacity);
    }

    /**
     * 到货进展行动卡闸门（2026-10-06 修订二, ADR-165 / ADR-091 §九）。
     * <ul>
     *   <li>路线未确认或产能不可计量：不发——页面内自办。</li>
     *   <li>会自动提升的段在调用方先返回（不评估、不抬水位，万一提升没成、任务随后被暂缓，
     *       全齐卡仍要能弹出来）。分批路线 {@code fn_execution_route_allows_auto_promote} 恒
     *       FALSE、暂缓段 auto_promote_when_ready=FALSE，全齐感知只能靠这里补位。</li>
     *   <li>其余只有「当前可支撑产能比上次通知水位高」才发：每种物料都有一些 → 首次
     *       「可以生产 X 件」；后续到货产能不涨不弹；涨了（扣已领）才再弹。</li>
     * </ul>
     */
    boolean arrivalProgressWarrantsNotice(Map<String, Object> task, String status, String route,
            BigDecimal capacity) {
        if (route.isBlank() || capacity == null) return false;
        return capacity.compareTo(bd(task.get("arrival_notice_capacity"))) > 0;
    }

    /**
     * 本段「当前可支撑产量」——行动卡里“可以生产 X 件”用这把尺子量, 按路线取口径:
     * <ul>
     *   <li>BATCH: 分批领料核对页的“当前可齐套生产量”（冻结曲线二分 × 仓库可用量, 剩余段
     *       自动扣前批），与页面同一个数；不可计量（路线已改、前批固定料未领齐等）返回 null。</li>
     *   <li>CONTINUOUS: 已备预留产能 {@code fn_execution_material_output_capacity(segment, FALSE)}
     *       ——已领走的料不占这口径，“还能生产多少”只算没领的。</li>
     *   <li>FULL_KIT: 齐套是全有或全无——只在 WAITING 且仓库口径盖住全部缺口时给 planned_qty,
     *       否则 0（READY 及之后由齐套/可开工行动卡接管）。</li>
     * </ul>
     */
    BigDecimal workshopArrivalCapacity(UUID segmentId, Map<String, Object> task, String status, String route,
            List<Map<String, Object>> missingRows, Map<UUID, BigDecimal> arrivedByDemand) {
        if ("BATCH".equals(route)) return workshopBatchCapacity(segmentId);
        if ("CONTINUOUS".equals(route)) return bd(task.get("prepared_capacity")).max(BigDecimal.ZERO);
        boolean covered = missingRows.stream().allMatch(row -> {
            BigDecimal shortage = bd(row.get("stock_shortage_qty"));
            BigDecimal arrived = arrivedByDemand.getOrDefault((UUID) row.get("demand_id"), BigDecimal.ZERO)
                    .max(BigDecimal.ZERO);
            return arrived.compareTo(shortage) >= 0;
        });
        return covered && "WAITING".equals(status) ? bd(task.get("planned_qty")).max(BigDecimal.ZERO) : BigDecimal.ZERO;
    }

    /**
     * 分批路线当前可齐套生产量; 尺子缺位返回 null(不发卡, 水位不动)。不可计量的正常中间态
     * (前批固定料未领齐、路线已改等)由 {@code currentSplitCapacity} 在事务边界内吞掉; 这里
     * 不再捕获——异常一旦越过 @Transactional 代理出口, 共享的 outbox 投递事务会被标记
     * rollback-only, 事件重试到死信, 到货通知就丢了。
     */
    BigDecimal workshopBatchCapacity(UUID segmentId) {
        if (batchSplits == null) return null;
        return batchSplits.getObject().currentSplitCapacity(segmentId);
    }

    /**
     * 每次到货事件评估后同步水位: 上涨发卡时抬上去, 回落时落下来——“涨了”永远相对最近一次。
     * 水位放 1:1 侧表(V814)而不是段表加列: 段表的 BEFORE UPDATE 触发器会 bump lock_version/
     * updated_at 并重验车间负责人, 每次水位变化会把在途的领料核对 CAS(「车间任务已变化,
     * 请刷新」)顶失效。值不变不写。
     */
    private void syncArrivalCapacityWatermark(UUID segmentId, BigDecimal capacity) {
        if (capacity == null) return;
        jdbc.update("""
                INSERT INTO production_execution_segment_notice_state (segment_id, arrival_notice_capacity)
                VALUES (?, ?)
                ON CONFLICT (segment_id) DO UPDATE SET arrival_notice_capacity = EXCLUDED.arrival_notice_capacity,
                    updated_at = now()
                WHERE production_execution_segment_notice_state.arrival_notice_capacity
                    IS DISTINCT FROM EXCLUDED.arrival_notice_capacity
                """, segmentId, capacity);
    }

    /** Physical issue lowers remaining capacity; it is not a new arrival and never raises the watermark. */
    void lowerWorkshopArrivalCapacityAfterIssue(UUID stockDocId) {
        List<UUID> segments = jdbc.queryForList("""
                SELECT segment.id FROM production_execution_segments segment
                WHERE NOT segment.is_deleted AND segment.start_route = 'CONTINUOUS'
                  AND EXISTS (
                    SELECT 1 FROM production_planning_package_document_items mapping
                    JOIN production_material_demands demand ON demand.id = mapping.demand_id
                    JOIN production_material_stock_postings posting ON posting.demand_id = demand.id
                      AND posting.stock_document_item_id = mapping.document_item_id
                      AND posting.posting_type = 'ISSUE' AND posting.recorded_tx_id = pg_current_xact_id()
                    WHERE mapping.document_id = ? AND mapping.document_type = 'DRAW'
                      AND demand.execution_segment_id = segment.id AND NOT demand.is_deleted
                      AND mapping.package_id = segment.package_id)
                ORDER BY segment.id FOR UPDATE
                """, UUID.class, stockDocId);
        for (UUID segmentId : segments) {
            jdbc.update("""
                    UPDATE production_execution_segment_notice_state
                    SET arrival_notice_capacity = LEAST(arrival_notice_capacity,
                            GREATEST(fn_execution_material_output_capacity(?, FALSE), 0)),
                        updated_at = now()
                    WHERE segment_id = ? AND arrival_notice_capacity
                        > GREATEST(fn_execution_material_output_capacity(?, FALSE), 0)
                    """, segmentId, segmentId, segmentId);
        }
    }

    /**
     * 仓库当前可给这些需求用的实物(专属来源权益 + 允许动用的公共库存，扣安全库存)，与齐套提升
     * 的 batchAvailability 同口径；无端口或任务无确认计划包时返回空表，卡片退回只说预留缺口。
     */
    private Map<UUID, BigDecimal> workshopWarehouseAvailableByDemand(UUID segmentId, List<UUID> demandIds) {
        if (workshopReadiness == null || demandIds.isEmpty()) return Map.of();
        List<Map<String, Object>> context = jdbc.queryForList("""
                SELECT package.warehouse_id, plan.material_analysis_id, plan.material_analysis_item_id
                FROM production_execution_segments segment
                JOIN production_planning_packages package ON package.id = segment.package_id
                  AND package.status = 'CONFIRMED' AND NOT package.is_deleted
                JOIN production_plans plan ON plan.id = segment.plan_id
                WHERE segment.id = ? AND NOT segment.is_deleted
                """, segmentId);
        if (context.isEmpty() || context.getFirst().get("warehouse_id") == null) return Map.of();
        Map<String, Object> first = context.getFirst();
        List<com.uten.imp.application.port.WorkshopMaterialAvailabilityReadPort.Availability> availability;
        try {
            availability = workshopReadiness.getObject().batchAvailability((UUID) first.get("warehouse_id"),
                    demandIds, (UUID) first.get("material_analysis_id"), (UUID) first.get("material_analysis_item_id"));
        } catch (RuntimeException unavailable) {
            // 历史异常位置等让齐套口径拒绝计算时，卡片退回只按预留缺口说话，不猜到货量。
            return Map.of();
        }
        Map<UUID, BigDecimal> qualified = new java.util.HashMap<>();
        Map<UUID, BigDecimal> publicQty = new java.util.HashMap<>();
        Map<UUID, BigDecimal> safety = new java.util.HashMap<>();
        for (var row : availability) {
            qualified.merge(row.demandId(), row.qualifiedQty().max(BigDecimal.ZERO), BigDecimal::add);
            publicQty.merge(row.demandId(), row.publicQty().max(BigDecimal.ZERO), BigDecimal::add);
            safety.merge(row.demandId(), row.safetyQty(), BigDecimal::max);
        }
        Map<UUID, BigDecimal> result = new java.util.HashMap<>();
        for (UUID demandId : demandIds) {
            BigDecimal budget = com.uten.imp.common.inventory.MainWarehouseStockBudget.publicBudget(
                    publicQty.getOrDefault(demandId, BigDecimal.ZERO), safety.getOrDefault(demandId, BigDecimal.ZERO));
            result.put(demandId, qualified.getOrDefault(demandId, BigDecimal.ZERO).add(budget));
        }
        return result;
    }

    static boolean workshopStartSupported(String status, String route, boolean materialReady) {
        return Set.of("READY", "DISPATCHED").contains(status)
                && route != null && Set.of("FULL_KIT", "CONTINUOUS").contains(route) && materialReady;
    }

    /**
     * Rebuilds one actionable workshop notice from current database facts.
     * Every state transition resolves the previous card first, so out-of-order
     * outbox delivery cannot leave a stale “ready” or “preparing” popup.
     */
    private void publishWorkshopTask(
            UUID segmentId, String triggerDescription) {
        publishWorkshopTask(segmentId, triggerDescription, false);
    }

    private void publishWorkshopTask(
            UUID segmentId,
            String triggerDescription,
            boolean onlyFullyIssued) {
        // Scheduler delivery and on-demand workers can rebuild the same aggregate
        // concurrently. Lock the segment row so resolve + publish stays serialized.
        List<UUID> lockedSegmentIds = jdbc.queryForList("""
                SELECT id
                FROM production_execution_segments
                WHERE id = ? AND is_deleted = FALSE
                FOR UPDATE
                """, UUID.class, segmentId);
        if (lockedSegmentIds.isEmpty()) return;
        Map<String, Object> task = one("""
                SELECT task.segment_id, task.segment_code, task.plan_no,
                       task.product_code, task.product_name,
                       task.product_color_name, task.product_unit_name,
                       task.planned_qty, task.segment_status,
                       segment.start_route, segment.continuous_supply,
                       fn_execution_start_material_ready(task.segment_id) AS start_material_ready,
                       task.material_status, task.preparation_status,
                       (task.issued OR fn_split_batch_empty_issued(task.segment_id)) AS issued,
                       task.workshop_department_id, task.workshop_name,
                       task.responsible_employee_id,
                       task.responsible_employee_name,
                       draw.summary AS draw_summary,
                       draw.requested AS draw_requested
                FROM v_production_execution_workbench_segments task
                JOIN production_execution_segments segment ON segment.id=task.segment_id
                JOIN production_plans active_plan ON active_plan.id=segment.plan_id
                  AND active_plan.status=1 AND NOT active_plan.is_deleted
                  AND NOT active_plan.is_closed AND NOT active_plan.is_stopped AND NOT active_plan.is_canceled
                LEFT JOIN LATERAL (
                    SELECT string_agg(draw_row.summary, '；'
                        ORDER BY draw_row.created_at,draw_row.id) AS summary,
                           bool_and(fn_production_draw_fully_requested(draw_row.id)) AS requested
                    FROM (
                        SELECT DISTINCT document.id, document.created_at,
                               document.bill_no || '（' ||
                               COALESCE(parent.name || ' - ' || warehouse.name,
                                        warehouse.name, '仓库待核实') || '）' AS summary
                        FROM production_planning_package_documents link
                        JOIN stock_documents document
                          ON document.id=link.document_id
                         AND document.doc_type='DRAW'
                         AND document.is_deleted=FALSE
                         AND document.status <> -1
                        LEFT JOIN warehouses warehouse ON warehouse.id=document.warehouse_id
                        LEFT JOIN warehouses parent ON parent.id=warehouse.parent_id
                        WHERE link.execution_segment_id=task.segment_id
                          AND link.document_type='DRAW'
                    ) draw_row
                ) draw ON TRUE
                WHERE task.segment_id = ?
                """, segmentId);
        if (task == null) {
            noticeService.resolveReviewNotices("PRODUCTION_EXECUTION_SEGMENT", segmentId, "PLAN_INACTIVE");
            return;
        }
        String status = str(task.get("segment_status"));
        // continuous_supply is an incremental-material flag (ADR-095). It may
        // remain true after switching a prepared task back to FULL_KIT; only
        // the explicit route determines whether this is continuous production.
        String route = str(task.get("start_route"));
        boolean continuous = "CONTINUOUS".equals(route);
        if (!Set.of("WAITING", "READY", "DISPATCHED").contains(status)
                && !(continuous && "IN_PROGRESS".equals(status))) {
            noticeService.resolveReviewNotices("PRODUCTION_EXECUTION_SEGMENT", segmentId, "STATE_CHANGED");
            return;
        }
        UUID workshopId = (UUID) task.get("workshop_department_id");
        UUID responsibleId = (UUID) task.get("responsible_employee_id");
        if (workshopId == null) return;

        boolean issued = Boolean.TRUE.equals(task.get("issued"));
        boolean canStart = workshopStartSupported(status, route, Boolean.TRUE.equals(task.get("start_material_ready")));
        String drawNo = str(task.get("draw_summary"));
        if (onlyFullyIssued && !canStart && !"IN_PROGRESS".equals(status)) return;
        noticeService.resolveReviewNotices(
                "PRODUCTION_EXECUTION_SEGMENT", segmentId, "STATE_CHANGED");
        // A delayed READY/assignment event must not recreate an action card
        // after the workshop already submitted its request. Warehouse issue
        // completion will publish the next actionable START card.
        if (!canStart && !issued && Boolean.TRUE.equals(task.get("draw_requested"))
                && Set.of("READY", "DISPATCHED").contains(status)) return;
        String taskState;
        String titlePrefix;
        if (route.isBlank()) {
            taskState = "请先确认齐套或持续生产路线；只有需要独立管理各批次时才选择分批";
            titlePrefix = "生产任务·待确认路线：";
        } else if (continuous && "IN_PROGRESS".equals(status)) {
            taskState = "本次物料状态已更新，请核对原工单补料与实际报工；无需再开工或另建工单";
            titlePrefix = "持续生产·物料进展：";
        } else if (continuous && canStart) {
            taskState = "各项必需物料已共同支持部分产量，可以开工；后续到料在原工单继续领取或直送";
            titlePrefix = "部分物料已支持·可以开工：";
        } else if (continuous) {
            taskState = "持续生产等待各项必需物料共同支持部分产量；请核对本次可领物料和直送交接";
            titlePrefix = "持续生产·待补料：";
        } else if (canStart) {
            taskState = "物料已领齐，可以开工"
                    + (drawNo.isBlank() ? "" : "；领料单 " + drawNo);
            titlePrefix = "物料已领齐·可以开工：";
        } else if ("KIT_SHORT".equals(str(task.get("material_status")))
                || "WAITING".equals(status)) {
            taskState = "物料尚未齐套，任务已分配并持续跟踪";
            titlePrefix = "生产任务·备料中：";
        } else if (!drawNo.isBlank() && !Boolean.TRUE.equals(task.get("draw_requested"))) {
            taskState = "物料已齐套，请在我的车间任务中选择工单并提交领料汇总；提交后仓库才会收到领料任务";
            titlePrefix = "物料齐套·待申请领料：";
        } else if (!drawNo.isBlank()) {
            taskState = "物料已齐套，领料单 " + drawNo + "；请按仓库安排领料";
            titlePrefix = "物料齐套·等待领料：";
        } else {
            taskState = "物料已齐套，正在核对领料明细；明细确认后请提交领料汇总";
            titlePrefix = "生产任务·核对领料明细：";
        }
        String segmentCode = str(task.get("segment_code"));
        String product = (str(task.get("product_code")) + " "
                + str(task.get("product_name"))).strip();
        String workshop = str(task.get("workshop_name"));
        String content = (triggerDescription == null
                || triggerDescription.isBlank()
                        ? "生产任务状态已更新"
                        : triggerDescription.strip())
                + "。生产计划 " + str(task.get("plan_no"))
                + "，工单 " + segmentCode
                + "，产品 " + (product.isBlank() ? "未命名产品" : product)
                + "，数量 " + qty(bd(task.get("planned_qty")))
                + (str(task.get("product_unit_name")).isBlank()
                        ? "" : " " + str(task.get("product_unit_name")))
                + (workshop.isBlank() ? "" : "，车间 " + workshop)
                + "；当前状态：" + taskState
                + "。请从“我的车间任务”查看进度；开工后才能报工。";
        boolean actionable = canStart || (!drawNo.isBlank() && !"WAITING".equals(status));
        for (UUID recipient : workshopRecipientUserIds(
                workshopId, responsibleId)) {
            if (actionable) {
                sendToUser(
                        recipient, TYPE_TASK, titlePrefix + segmentCode, content,
                        "/production/workshop-tasks",
                        EVENT_PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED,
                        "important", segmentId);
            } else {
                // WAITING/短料只是进度更新：保留顶部通知和任务入口，但不制造
                // “现在来领料”的中间行动卡；真正生成 DRAW 后再升级为行动卡。
                sendToUser(
                        recipient, TYPE_TASK, titlePrefix + segmentCode, content,
                        "/production/workshop-tasks",
                        EVENT_PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED,
                        "normal", segmentId);
            }
        }
    }

    /**
     * 车间任务行动卡收件人（2026-10-06 修订二, ADR-165）: 只发「持车间任务办理权限 且 是该车间的
     * 负责人」——车间（含下级班组）各部门负责人 departments.manager_id 与本任务负责人
     * responsible_employee_id, 再逐人校验当前有效权限（notice:read + production_execution:view +
     * start/报工, 含个人回收）。计划部等职能岗即使个人加授了权限, 不是车间负责人也不收卡。
     * 没有合格负责人时不扩大发送范围；普通成员仍可按自己的权限在车间任务页办理。
     */
    List<UUID> workshopRecipientUserIds(
            UUID workshopDepartmentId, UUID responsibleEmployeeId) {
        if (workshopDepartmentId == null) return List.of();
        return withWorkshopTaskPermission(jdbc.queryForList("""
                WITH RECURSIVE workshop_tree(id) AS (
                    SELECT id
                    FROM departments
                    WHERE id = ? AND is_deleted = FALSE
                    UNION ALL
                    SELECT child.id
                    FROM departments child
                    JOIN workshop_tree parent ON child.parent_id = parent.id
                    WHERE child.is_deleted = FALSE
                )
                SELECT DISTINCT user_account.id
                FROM (
                    SELECT department.manager_id AS employee_id
                    FROM departments department
                    WHERE department.id IN (SELECT id FROM workshop_tree)
                      AND department.manager_id IS NOT NULL
                    UNION
                    SELECT CAST(? AS uuid)
                ) candidate
                JOIN employees employee ON employee.id = candidate.employee_id
                JOIN users user_account
                  ON user_account.employee_id = employee.id
                WHERE candidate.employee_id IS NOT NULL
                  AND employee.is_deleted = FALSE
                  AND employee.status IN (
                      'active','probation','onLeave')
                  AND user_account.is_deleted = FALSE
                  AND user_account.status = 'active'
                ORDER BY user_account.id
                """, UUID.class, workshopDepartmentId, responsibleEmployeeId));

    }

    /** 候选账号逐人过当前有效权限: 在职账号 + notice:read + 车间任务办理权(canHandleWorkshop, 含个人回收)。 */
    private List<UUID> withWorkshopTaskPermission(List<UUID> candidates) {
        return candidates.stream()
                .filter(userId -> userRepo.findById(userId)
                        .filter(account -> !account.isDeleted()
                                && "active".equals(account.getStatus()))
                        .map(permissionResolver::permsOf)
                        .map(ReviewNoticeAudience::canHandleWorkshop)
                        .orElse(false))
                .toList();
    }

    /**
     * 预计到货弹卡办结：expectation 离开 OPEN（全部登记完 CLOSED / 订单侧
     * CANCELED）时，按 (PROCUREMENT_ORDER, orderId) 撤回「预计到货」行动卡。
     * 仍在 OPEN 时不动作（部分登记不撤卡）。幂等。
     */
    public void resolveArrivalExpectationNotices(
            String orderType, UUID orderId) {
        if (orderType == null || orderId == null) return;
        List<String> statuses = jdbc.queryForList("""
                SELECT status FROM inbound_expectations
                WHERE order_type = ? AND order_id = ?
                """, String.class, orderType, orderId);
        for (String status : statuses) {
            if (!"OPEN".equals(status)) {
                resolveReviewNotices(
                        "PROCUREMENT_ORDER", orderId,
                        "EXPECTATION_" + status);
            }
        }
    }

    /**
     * Resolves every current workshop-task popup for the exact segments. Called at
     * every point where the task stops being actionable for the workshop: START
     * (ProductionExecutionSegmentService.applyTransition, reason STARTED), completion
     * (finished-inbound delivery, COMPLETED), cancel/reverse, and workshop
     * unassignment/reassignment. Daily reports do not resolve the card.
     */
    public int resolveProductionWorkshopTasks(
            Collection<UUID> segmentIds, String reason) {
        if (segmentIds == null || segmentIds.isEmpty()) return 0;
        int resolved = 0;
        for (UUID segmentId : segmentIds.stream()
                .filter(java.util.Objects::nonNull)
                .distinct()
                .sorted()
                .toList()) {
            resolved += noticeService.resolveReviewNotices(
                    "PRODUCTION_EXECUTION_SEGMENT",
                    segmentId,
                    reason == null || reason.isBlank()
                            ? "COMPLETED" : reason.strip());
            for(UUID request:jdbc.queryForList("""
                    SELECT request.id FROM production_material_discovery_requests request
                    JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
                    JOIN production_plans plan ON plan.id=segment.plan_id
                    WHERE segment.id=? AND (request.status<>'PENDING' OR segment.is_deleted
                        OR segment.status IN('CANCELLED','REVERSED','COMPLETED') OR plan.is_deleted OR plan.is_canceled OR plan.is_closed OR plan.is_stopped)
                    """,UUID.class,segmentId)) {
                resolved+=noticeService.resolveReviewNotices("PRODUCTION_MATERIAL_DISCOVERY_REQUEST",request,"STATE_CHANGED");
            }
        }
        return resolved;
    }

    /**
     * Segments referenced by a FINISHED_IN document whose status is already
     * COMPLETED (the V156 reconciliation trigger runs in the approval transaction,
     * before this outbox delivery). Segments reopened by a completion reverse are
     * IN_PROGRESS again and therefore not returned.
     */
    List<UUID> completedSegmentsOfFinishedInbound(UUID stockDocId) {
        if (stockDocId == null) return List.of();
        return jdbc.queryForList("""
                SELECT DISTINCT item.execution_segment_id
                FROM stock_document_items item
                JOIN production_execution_segments segment
                  ON segment.id = item.execution_segment_id
                 AND segment.is_deleted = FALSE
                 AND segment.status = 'COMPLETED'
                WHERE item.doc_id = ?
                  AND item.is_deleted = FALSE
                  AND item.execution_segment_id IS NOT NULL
                ORDER BY item.execution_segment_id
                """, UUID.class, stockDocId);
    }

    /** ⑤ 发货通知销售：出货单审核后，按订单聚合本次出货量。（出货单暂无物流单号字段，内容含单号/数量/仓库。） */
    public void notifyShipmentApproved(UUID shipmentId) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_SHIPMENT_APPROVED, "SALES_SHIPMENT", shipmentId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> h = one("SELECT bill_no, warehouse_id,shipment_kind,owner_employee_id FROM sales_shipments WHERE id = ? AND status=1 AND warehouse_work_status='SHIPPED' AND NOT is_deleted", shipmentId);
            if (h == null) return;
            String wh = oneStr("SELECT name FROM warehouses WHERE id = ?", h.get("warehouse_id"));
            if ("DIRECT_CUSTOMER".equals(h.get("shipment_kind"))) {
                notifyUser(userIdOfEmployee((UUID)h.get("owner_employee_id")),TYPE_WORKFLOW,
                        "客户零星发货已出库："+str(h.get("bill_no")),"仓库已完成实际出库，请查看发货明细。",
                        "/sales/customer-shipments/"+shipmentId);
                return;
            }
            Map<UUID, BigDecimal> byOrder = new LinkedHashMap<>();
            for (Map<String, Object> r : jdbc.queryForList("""
                    SELECT oi.order_id, SUM(si.qty) AS qty
                    FROM sales_shipment_items si
                    JOIN sales_order_items oi ON oi.id = si.order_item_id
                    WHERE si.shipment_id = ?
                    GROUP BY oi.order_id
                    """, shipmentId)) {
                byOrder.merge((UUID) r.get("order_id"), bd(r.get("qty")), BigDecimal::add);
            }
            for (var e : byOrder.entrySet()) {
                OrderRef o = orderRef(e.getKey());
                if (o == null) continue;
                notifyUser(o.ownerUserId(), TYPE_WORKFLOW,
                        "发货通知：" + o.billNo(),
                        "订单 " + o.billNo() + " 已发货 " + qty(e.getValue()) + "(出货单 " + str(h.get("bill_no"))
                                + (wh.isEmpty() ? "" : "，仓库 " + wh) + ")。",
                        "/sales/shipments/" + shipmentId);
            }
        });
    }

    /** ⑥ 驳回通知销售：仓库驳回出货单（草稿）后，按订单聚合缺口量。 */
    public void notifyShipmentRejected(UUID shipmentId, String reason) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_SHIPMENT_REJECTED, "SALES_SHIPMENT", shipmentId,
                    Map.of("reason", reason == null ? "" : reason));
            return;
        }
        deliverAtomically(() -> {
            String billNo = oneStr("SELECT bill_no FROM sales_shipments WHERE id = ?", shipmentId);
            for (Map<String, Object> r : jdbc.queryForList("""
                    SELECT oi.order_id, SUM(si.qty) AS qty
                    FROM sales_shipment_items si
                    JOIN sales_order_items oi ON oi.id = si.order_item_id
                    WHERE si.shipment_id = ? AND si.order_item_id IS NOT NULL
                    GROUP BY oi.order_id
                    """, shipmentId)) {
                OrderRef o = orderRef((UUID) r.get("order_id"));
                if (o == null) continue;
                notifyUser(o.ownerUserId(), TYPE_URGENT,
                        "出货驳回：" + o.billNo(),
                        "出货单 " + billNo + " 被仓库驳回(" + (reason == null || reason.isBlank() ? "备货异常" : reason)
                                + ")，订单 " + o.billNo() + " 缺口 " + qty(bd(r.get("qty")))
                                + " 已释放预留并回到调度待排产。",
                        "/sales/shipments/" + shipmentId);
            }
        });
    }

    /** ⑦ 取消确认：订单整单取消后，确认销售 + 通知调度不用排。 */
    public void notifyOrderCanceled(UUID orderId) {
        if (!isOutboxDelivery()) {
            // Closing an actionable card is part of the cancellation transaction;
            // the confirmation message remains a durable outbox delivery.
            resolveReviewNotices("SALES_ORDER", orderId, "CANCELLED");
            outbox.publish(EVENT_ORDER_CANCELED, "SALES_ORDER", orderId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            // A delayed cancellation event must not close the new pending task of a resumed order.
            if (jdbc.queryForList("""
                    SELECT id FROM sales_orders
                    WHERE id = ? AND (is_deleted OR status = -1 OR is_stopped OR requoted_to_id IS NOT NULL)
                    FOR UPDATE
                    """, orderId).isEmpty()) return;
            resolveReviewNotices("SALES_ORDER", orderId, "CANCELLED");
            OrderRef o = orderRef(orderId);
            if (o == null) return;
            notifyUser(o.ownerUserId(), TYPE_WORKFLOW,
                    "取消确认：" + o.billNo(),
                    "订单 " + o.billNo() + " 已整单取消：销售库存预留已释放；"
                            + "系统已确认不存在待清理的排产、领料或完工承诺。",
                    o.route());
            notifyDepartmentPool(PLAN_VIEW_AUTHORITY, List.of("SUB_PLAN"), TYPE_WORKFLOW,
                    "订单取消·无需排产：" + o.billNo(),
                    "订单 " + o.billNo() + " 已取消且没有有效生产承诺，无需后续排产。",
                    "/production/plans");
        });
    }

    /** ⑦.5 订单财务确认后通知计划员接手物料分析（V294 起由财务确认事件驱动，不在审核落点发）。 */
    public void notifyOrderApproved(UUID orderId) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_ORDER_APPROVED, "SALES_ORDER", orderId, planningRevisionPayload(orderId));
            return;
        }
        deliverSalesPlanningHandoff(orderId, null);
    }

    private Map<String, ?> planningRevisionPayload(UUID orderId) {
        Long revision = jdbc.queryForObject("SELECT finance_review_revision FROM sales_orders WHERE id=?", Long.class, orderId);
        return Map.of("reviewRevision", revision);
    }

    /** Called only inside the outbox transaction, serialized with source acquisition and finance decisions. */
    private void deliverSalesPlanningHandoff(UUID orderId, Long expectedRevision) {
        deliverAtomically(() -> {
            if (!lockActiveOrderForNotice(orderId, true)) return;
            long revision = jdbc.queryForObject("SELECT finance_review_revision FROM sales_orders WHERE id=?", Long.class, orderId);
            if (expectedRevision != null && expectedRevision != revision) return;
            if (!planningSources.needsInitialHandoff(orderId)) return;
            OrderRef o = orderRef(orderId);
            if (o == null) return;
            Map<String, Object> agg = one("""
                    SELECT COUNT(*) AS lines,
                           MIN(COALESCE(i.deliver_date, oo.deliver_date)) AS deliver,
                           string_agg(DISTINCT g.code, ' / ') AS goods
                    FROM sales_order_items i
                    JOIN sales_orders oo ON oo.id = i.order_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    WHERE i.order_id = ? AND i.is_deleted = false
                    """, orderId);
            String lines = agg == null ? "?" : str(agg.get("lines"));
            Object d = agg == null ? null : agg.get("deliver");
            String deliver = d == null ? "未定" : d.toString();
            String goods = agg == null || agg.get("goods") == null ? "" : str(agg.get("goods"));
            // V477 办结闭环：绑定 (SALES_ORDER, orderId) 聚合——生产部创建物料
            // 分析后按聚合撤回全部接收人的这条待办（此前无聚合永不办结）。
            // 2026-09-05 修弹窗串台：接收池从「planner 角色 ∪ SUB_PLAN 主部门」
            // （角色不看部门，跨部门挂角色者会收到别的部门的弹窗）收敛为
            // ADR-063 口径「(主部门 OR 兼职部门) ∈ SUB_PLAN 子树 AND 持有
            // 物料分析查看权」——与财务/品质弹窗同款双条件，超管不再隐式命中。
            Set<UUID> targets = new LinkedHashSet<>(
                    departmentUserIdsWithSecondaryAuthorities(
                            "SUB_PLAN", NOTICE_READ_AUTHORITY,
                            "production_material_analysis:view", "production_material_analysis:create"));
            for (UUID uid : targets) {
                if (hasPlanningHandoff(orderId, uid, revision)) continue;
                // 角色/部门池是公共任务广播，即使事件本身重要，也不得阻塞每个成员。
                noticeService.publishSalesPlanningHandoff(uid, orderId, revision,
                        "新订单待物料分析：" + o.billNo(),
                        "订单 " + o.billNo() + " 已审核并通过财务确认，共 " + lines + " 行货品(" + goods
                                + ")待分析，最早交货日 " + deliver
                                + "。请先核对库存并按采购、委外、自制拆分需求，再下达生产计划。");
            }
        });
    }

    private boolean hasPlanningHandoff(UUID orderId, UUID userId, long revision) {
        // A legacy NULL revision cannot be assigned using event/DB/app timestamps.
        // Suppress that recipient conservatively; newly eligible recipients have no such historical receipt.
        return Boolean.TRUE.equals(jdbc.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM notices WHERE aggregate_kind='SALES_ORDER' AND aggregate_id=?
                  AND source_event='SALES_ORDER_APPROVED' AND audience_user_id=?
                  AND (source_revision=? OR source_revision IS NULL))
                """, Boolean.class, orderId, userId, revision));
    }

    /** One bounded reconciliation item. Never writes from inbox reads. */
    @org.springframework.transaction.annotation.Transactional
    public boolean enqueueSalesPlanningCatchUp(UUID orderId) {
        if (!lockActiveOrderForNotice(orderId, true, true) || !planningSources.needsInitialHandoff(orderId)) return false;
        long revision = jdbc.queryForObject("SELECT finance_review_revision FROM sales_orders WHERE id=?", Long.class, orderId);
        boolean missing = departmentUserIdsWithSecondaryAuthorities("SUB_PLAN", NOTICE_READ_AUTHORITY,
                "production_material_analysis:view", "production_material_analysis:create").stream()
                .anyMatch(userId -> !hasPlanningHandoff(orderId, userId, revision));
        if (!missing || Boolean.TRUE.equals(jdbc.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM business_outbox WHERE event_type=? AND aggregate_id=? AND status=0)
                """, Boolean.class, EVENT_SALES_PLANNING_CATCH_UP, orderId))) return false;
        // A skipped (e.g. temporarily revoked) signal must not permanently consume a phase/user dedupe key.
        outbox.publish(EVENT_SALES_PLANNING_CATCH_UP, "SALES_ORDER", orderId, Map.of("reviewRevision", revision));
        return true;
    }

    /** ⑦.6 订单审核后通知财务确认（V294 闸门：财务确认前计划部不可见该订单）。 */
    public void notifyOrderPendingFinanceConfirmation(UUID orderId) {
        notifyOrderPendingFinanceConfirmation(orderId, false);
    }

    /**
     * 2026-09-05 财务确认后改量：订单重新进入财务确认队列时带「改后待确认」
     * 口径投递——内容指引财务按审核页「修改清单」复核 以前→现在。
     */
    public void notifyOrderPendingFinanceConfirmation(
            UUID orderId, boolean afterModification) {
        if (!isOutboxDelivery()) {
            outbox.publish(
                    EVENT_ORDER_PENDING_FINANCE,
                    "SALES_ORDER",
                    orderId,
                    afterModification
                            ? Map.of("afterModification", true)
                            : Map.of());
            return;
        }
        deliverAtomically(() -> {
            // Serialize with cancellation/requotation and other deliveries: an old
            // outbox row must never recreate an actionable card for a completed order.
            if (!lockActiveOrderForNotice(orderId, false)) return;
            OrderRef o = orderRef(orderId);
            if (o == null) return;
            // V459 审核待办弹卡：直达单据级财务审核页；aggregate 绑定订单，
            // 办结（确认/驳回）时按 (SALES_ORDER, orderId) 批量撤回全部接收人的弹卡。
            List<UUID> confirmers = salesOrderFinanceConfirmers.eligibleUserIds();
            for (UUID userId : confirmers) {
                if (Boolean.TRUE.equals(jdbc.queryForObject("""
                        SELECT EXISTS(SELECT 1 FROM notices
                        WHERE aggregate_kind = 'SALES_ORDER' AND aggregate_id = ?
                          AND source_event = ? AND audience_user_id = ? AND resolved_at IS NULL)
                        """, Boolean.class, orderId, EVENT_ORDER_PENDING_FINANCE, userId))) continue;
                sendToUser(userId, TYPE_APPROVAL,
                        (afterModification ? "改量后待财务确认：" : "待财务确认：")
                                + o.billNo(),
                        afterModification
                                ? "销售订货单 " + o.billNo()
                                      + " 在财务确认后修改了数量，已重新进入确认队列；"
                                      + "请按审核页「修改清单」复核每行 以前→现在 数量后确认。"
                                : "销售订货单 " + o.billNo() + " 已审核，待财务确认；确认后计划部才可见并排产。",
                        afterModification ? "/finance/sales-order-changes"
                                : "/finance/sales-order-confirmations/" + orderId,
                        EVENT_ORDER_PENDING_FINANCE, null, orderId);
            }
        });
    }

    /** ⑦.7 财务确认完成：经 outbox 转⑦.5 通知计划员（保留独立事件便于审计与重放）。 */
    public void notifyOrderFinanceConfirmed(UUID orderId) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_ORDER_FINANCE_CONFIRMED, "SALES_ORDER", orderId, planningRevisionPayload(orderId));
            return;
        }
        notifyOrderApproved(orderId);
    }

    /** ⑦.8 财务驳回（V300）：通知归属销售修正——驳回原因直达，点通知跳订单详情处理。 */
    public void notifyOrderFinanceRejected(UUID orderId, String reason) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_ORDER_FINANCE_REJECTED, "SALES_ORDER", orderId,
                    Map.of("reason", reason == null ? "" : reason));
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> rejection = one("""
                    SELECT sales_order.bill_no,
                           sales_order.owner_employee_id,
                           sales_order.seller_id,
                           sales_order.finance_rejected_at,
                           COALESCE(reviewer.full_name, '财务人员') AS reviewer_name
                    FROM sales_orders sales_order
                    LEFT JOIN employees reviewer
                      ON reviewer.id = sales_order.finance_rejected_by
                    WHERE sales_order.id = ?
                    """, orderId);
            if (rejection == null) return;
            UUID ownerUserId = userIdOfEmployee(
                    (UUID) rejection.get("owner_employee_id"));
            if (ownerUserId == null) {
                ownerUserId = userIdOfEmployee((UUID) rejection.get("seller_id"));
            }
            if (ownerUserId == null) return;
            String billNo = str(rejection.get("bill_no"));
            String reviewerName = str(rejection.get("reviewer_name"));
            String rejectedAt = businessEventTime(
                    rejection.get("finance_rejected_at"));
            String why = reason == null || reason.isBlank() ? "未填写原因" : reason.trim();
            sendToUser(ownerUserId, TYPE_URGENT,
                    "订单被财务驳回：" + billNo,
                    "销售订货单 " + billNo + " 未通过财务确认，由财务 "
                            + (reviewerName.isBlank() ? "人员" : reviewerName)
                            + (rejectedAt.isBlank() ? "" : " 于 " + rejectedAt)
                            + " 驳回。驳回原因：" + why
                            + "。请修改订单并重新完成销售审核，系统会再次提交财务确认。",
                    "/sales/orders/" + orderId);
        });
    }

    /** ⑧ 延期预警（每日扫描调用）：交货 ≤3 天未结案订单，通知业务员 + 调度。 */
    public void notifyDeliveryDue(UUID orderId, long daysLeft) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_DELIVERY_DUE, "SALES_ORDER", orderId,
                    Map.of("daysLeft", daysLeft, "daily", false));
            return;
        }
        OrderRef o = orderRef(orderId);
        if (o == null) return;
        String when = daysLeft < 0 ? "已超期 " + (-daysLeft) + " 天"
                : daysLeft == 0 ? "今日交货" : "距交货 " + daysLeft + " 天";
        String title = "交货预警：" + o.billNo();
        String content = "订单 " + o.billNo() + " " + when + "，尚未结案，请跟进生产/发货进度。";
        Set<UUID> targets = new LinkedHashSet<>();
        if (o.ownerUserId() != null) targets.add(o.ownerUserId());
        targets.addAll(departmentPoolWithPermission(ANALYSIS_VIEW_AUTHORITY, List.of("SUB_PLAN")));
        for (UUID uid : targets) {
            // owner 跳订单详情跟进；planner 先到物料分析工作台查看待料缺口。
            String route = uid.equals(o.ownerUserId())
                    ? o.route() : "/production/material-analysis";
            if (uid.equals(o.ownerUserId())) {
                sendToUser(
                        uid,
                        TYPE_URGENT,
                        title,
                        content,
                        route,
                        null,
                        daysLeft < 0 ? "important" : "normal");
            } else {
                sendToUser(uid, TYPE_URGENT, title, content, route, null, "normal");
            }
        }
    }

    /** ⑧ 延期预警（调度器入口）：同一订单同一接收人同日只发一条（notices 标题+接收人+当日去重）。 */
    public void notifyDeliveryDueIfNotSentToday(UUID orderId, long daysLeft) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(EVENT_DELIVERY_DUE, "SALES_ORDER", orderId,
                    Map.of("daysLeft", daysLeft, "daily", true),
                    EVENT_DELIVERY_DUE + ':' + orderId + ':' + BusinessTime.today());
            return;
        }
        try {
            OrderRef o = orderRef(orderId);
            if (o == null) return;
            String title = "交货预警：" + o.billNo();
            Instant startOfToday = BusinessTime.startOfDayInstant(BusinessTime.today());
            String when = daysLeft < 0 ? "已超期 " + (-daysLeft) + " 天"
                    : daysLeft == 0 ? "今日交货" : "距交货 " + daysLeft + " 天";
            String content = "订单 " + o.billNo() + " " + when + "，尚未结案，请跟进生产/发货进度。";
            Set<UUID> targets = new LinkedHashSet<>();
            if (o.ownerUserId() != null) targets.add(o.ownerUserId());
            targets.addAll(departmentPoolWithPermission(ANALYSIS_VIEW_AUTHORITY, List.of("SUB_PLAN")));
            for (UUID uid : targets) {
                Boolean sent = jdbc.queryForObject(
                        "SELECT EXISTS(SELECT 1 FROM notices WHERE audience_user_id = ? AND title = ? AND published_at >= ?)",
                        Boolean.class, uid, title, java.sql.Timestamp.from(startOfToday));
                if (Boolean.TRUE.equals(sent)) continue;
                String route = uid.equals(o.ownerUserId())
                        ? o.route() : "/production/material-analysis";
                if (uid.equals(o.ownerUserId())) {
                    sendToUser(
                            uid,
                            TYPE_URGENT,
                            title,
                            content,
                            route,
                            null,
                            daysLeft < 0 ? "important" : "normal");
                } else {
                    sendToUser(uid, TYPE_URGENT, title, content, route, null, "normal");
                }
            }
        } catch (Exception error) {
            throw new IllegalStateException("Failed to deliver due-date warning for " + orderId, error);
        }
    }

    /**
     * ⑨ 预留持有逾期（即时）：订单有生效预留且持有截止已过、仍未发完，通知归属销售跟进发货或释放。
     * 持有截止 = COALESCE(预留 hold_until, 订单交货日 + 宽限期)；与延期预警(⑧ 交货前)互补、不重叠。
     */
    public void notifyReservationHoldOverdue(UUID orderId, long overdueDays) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_RESERVATION_HOLD_OVERDUE, "SALES_ORDER", orderId,
                    Map.of("overdueDays", overdueDays, "daily", false));
            return;
        }
        sendHoldOverdueNotice(orderId, overdueDays);
    }

    /** ⑨ 预留持有逾期（调度器入口）：同一订单同一接收人同日只发一条（notices 标题+接收人+当日去重）。 */
    public void notifyReservationHoldOverdueIfNotSentToday(UUID orderId, long overdueDays) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(EVENT_RESERVATION_HOLD_OVERDUE, "SALES_ORDER", orderId,
                    Map.of("overdueDays", overdueDays, "daily", true),
                    EVENT_RESERVATION_HOLD_OVERDUE + ':' + orderId + ':' + BusinessTime.today());
            return;
        }
        try {
            OrderRef o = orderRef(orderId);
            if (o == null || o.ownerUserId() == null) return;
            String title = "预留持有逾期：" + o.billNo();
            Instant startOfToday = BusinessTime.startOfDayInstant(BusinessTime.today());
            Boolean sent = jdbc.queryForObject(
                    "SELECT EXISTS(SELECT 1 FROM notices WHERE audience_user_id = ? AND title = ? AND published_at >= ?)",
                    Boolean.class, o.ownerUserId(), title, java.sql.Timestamp.from(startOfToday));
            if (Boolean.TRUE.equals(sent)) return;
            sendHoldOverdueNotice(orderId, overdueDays);
        } catch (Exception error) {
            throw new IllegalStateException("Failed to deliver hold-overdue notice for " + orderId, error);
        }
    }

    private void sendHoldOverdueNotice(UUID orderId, long overdueDays) {
        OrderRef o = orderRef(orderId);
        if (o == null || o.ownerUserId() == null) return;
        String title = "预留持有逾期：" + o.billNo();
        String content = "订单 " + o.billNo() + " 的现货预留已过持有截止"
                + (overdueDays <= 0 ? "" : " " + overdueDays + " 天")
                + "，仍未发货。请尽快安排出货；若客户暂不需要，请改量或取消以释放库存，"
                + "或由主管做稀缺让单重排。长期不处理将影响可承诺量。";
        sendToUser(
                o.ownerUserId(),
                TYPE_URGENT,
                title,
                content,
                o.route(),
                null,
                "important");
    }

    /**
     * ⑩ 让单通知：低优先级订单行的预留被主管让单重排后，通知其归属销售——
     * 库存已被高优先级急单调用，其缺口已自动回到调度待排产（将转生产补足）。
     */
    public void notifyReservationYielded(UUID orderItemId, String qtyText, String reason, String yielderOrderNo) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_RESERVATION_YIELDED, "SALES_ORDER_ITEM", orderItemId, Map.of(
                    "qty", qtyText == null ? "" : qtyText,
                    "reason", reason == null ? "" : reason,
                    "yielderOrderNo", yielderOrderNo == null ? "" : yielderOrderNo));
            return;
        }
        Map<String, Object> row = one("""
                SELECT o.id AS order_id, o.bill_no, g.code AS goods
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                LEFT JOIN goods g ON g.id = i.goods_id
                WHERE i.id = ?
                """, orderItemId);
        if (row == null) return;
        OrderRef o = orderRef((UUID) row.get("order_id"));
        if (o == null) return;
        String why = reason == null || reason.isBlank() ? "急单优先" : reason.trim();
        sendToUser(o.ownerUserId(), TYPE_URGENT,
                "库存被让单重排：" + o.billNo(),
                "订单 " + o.billNo() + " 货品 " + str(row.get("goods")) + " 的现货预留 "
                        + (qtyText == null || qtyText.isBlank() ? "" : qtyText + " ")
                        + "已被主管让单给" + (yielderOrderNo == null || yielderOrderNo.isBlank() ? "急单" : "订单 " + yielderOrderNo)
                        + "(原因：" + why + ")。缺口已自动回到调度待排产，将转生产补足，进度会在排产后更新。",
                o.route(), null, "important");
    }

    private void notifyProcurementFinanceEvent(
            String eventType, UUID approvalCaseId) {
        deliverAtomically(() -> {
            Map<String, Object> approval = one("""
                    SELECT approval_case.bill_no_snapshot,
                           approval_case.amount_snapshot,
                           approval_case.order_type,
                           approval_case.order_id,
                           approval_case.assignee_user_id,
                           approval_case.submitted_by_user_id,
                           approval_case.rejection_reason,
                           approval_case.decided_at,
                           COALESCE(decider.full_name, '财务人员') AS reviewer_name,
                           expectation.expected_date,
                           warehouse.name AS warehouse_name
                    FROM procurement_order_approval_cases approval_case
                    LEFT JOIN employees decider
                      ON decider.id = approval_case.decided_by_employee_id
                    LEFT JOIN inbound_expectations expectation
                      ON expectation.approval_case_id = approval_case.id
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = expectation.warehouse_id
                    WHERE approval_case.id = ?
                    """, approvalCaseId);
            if (approval == null) {
                return;
            }
            String billNo = str(approval.get("bill_no_snapshot"));
            String orderLabel = "SUBCONTRACT".equals(
                    str(approval.get("order_type")))
                    ? "委外订货单"
                    : "采购订货单";
            if (EVENT_PROCUREMENT_FINANCE_SUBMITTED.equals(eventType)) {
                String title = "待财务审核：" + billNo;
                String content = orderLabel + " " + billNo + " 已提交财务审核，金额 "
                        + str(approval.get("amount_snapshot"))
                        + "。请到钱流管理任务中心处理。";
                for (UUID reviewer : financeReviewerUserIds()) {
                    // V459 审核待办弹卡：aggregate 绑定审批 case，批准/驳回时批量撤回。
                    sendToUser(reviewer, TYPE_APPROVAL, title, content,
                            "/finance/procurement-approvals",
                            EVENT_PROCUREMENT_FINANCE_SUBMITTED, null, approvalCaseId);
                }
                return;
            }
            if (EVENT_PROCUREMENT_FINANCE_CHANGE_SUBMITTED.equals(eventType)) {
                Long changeCount = jdbc.queryForObject("""
                        SELECT count(*) FROM procurement_order_qty_change_logs
                        WHERE case_id = ?
                        """, Long.class, approvalCaseId);
                long changes = changeCount == null ? 0 : changeCount;
                String title = "改量待财务复核：" + billNo;
                String content = orderLabel + " " + billNo + " 财务批准后改量 "
                        + changes + " 处，新数量已生效；请在任务中心打开该 case，"
                        + "按修改清单（以前 → 现在）复核后通过或驳回。"
                        + "驳回不会自动还原数量，制单人会收到原因并再次改量。";
                for (UUID reviewer : financeReviewerUserIds()) {
                    sendToUser(reviewer, TYPE_APPROVAL, title, content,
                            "/finance/procurement-approvals",
                            EVENT_PROCUREMENT_FINANCE_CHANGE_SUBMITTED, null,
                            approvalCaseId);
                }
                return;
            }
            if (EVENT_PROCUREMENT_FINANCE_REJECTED.equals(eventType)) {
                UUID orderId = (UUID) approval.get("order_id");
                String actionRoute = "SUBCONTRACT".equals(
                        str(approval.get("order_type")))
                        ? "/subcontract/orders/" + orderId
                        : "/purchase/orders/" + orderId;
                String reviewerName = str(approval.get("reviewer_name"));
                String decidedAt = businessEventTime(approval.get("decided_at"));
                notifyUser(
                        (UUID) approval.get("submitted_by_user_id"),
                        TYPE_URGENT,
                        "财务驳回：" + billNo,
                        orderLabel + " " + billNo + " 未通过财务审核，由财务 "
                                + (reviewerName.isBlank() ? "人员" : reviewerName)
                                + (decidedAt.isBlank() ? "" : " 于 " + decidedAt)
                                + " 驳回。原因："
                                + str(approval.get("rejection_reason"))
                                + "。请修改后重新提交。",
                        actionRoute);
                return;
            }
            UUID orderId = (UUID) approval.get("order_id");
            boolean subcontract = "SUBCONTRACT".equals(str(approval.get("order_type")));
            String actionRoute = subcontract
                    ? "/subcontract/orders/" + orderId
                    : "/purchase/orders/" + orderId;
            String approvedResult = subcontract
                    ? "直属物料备齐后会提醒你到委外任务中心「领料」提交领料，仓库发出后委外商才能加工、"
                            + "才进入仓库预计到货。"
                    : "仓储部已收到预计到货提醒。";
            notifyUser(
                    (UUID) approval.get("submitted_by_user_id"),
                    TYPE_WORKFLOW,
                    "财务通过：" + billNo,
                    orderLabel + " " + billNo
                            + " 已通过财务审核并正式生效，" + approvedResult,
                    actionRoute);
            if (!subcontract) {
                String warehouseName = str(approval.get("warehouse_name"));
                String expectedDate = str(approval.get("expected_date"));
                // ADR-149: 预计到货的所在仓按逐行到货仓(订货表头仓 → 申请表头仓 → 货品所属仓)推出;
                // inbound_expectations.warehouse_id 自 ADR-038 起恒为空, 不再用它分发。
                List<UUID> expectationWarehouses = warehouseIdsQuery(
                        "SELECT unnest(fn_inbound_expectation_warehouse_ids(id)) FROM inbound_expectations"
                                + " WHERE approval_case_id = ?",
                        approvalCaseId);
                for (UUID warehouseUser : warehouseRecipients(warehousePool(NOTICE_READ_AUTHORITY, "warehouse_inbound:view"),
                        expectationWarehouses)) {
                    // 2026-09-05 起升级为居中行动卡：aggregate 绑定
                    // (PROCUREMENT_ORDER, orderId)，到货全部登记完
                    // （expectation CLOSED/CANCELED）后按聚合办结撤回。
                    sendToUser(
                            warehouseUser,
                            TYPE_TASK,
                            "预计到货：" + billNo,
                            orderLabel + " " + billNo + " 已生效"
                                    + (warehouseName.isBlank()
                                            ? ""
                                            : "，目标仓库 " + warehouseName)
                                    + (expectedDate.isBlank()
                                            ? ""
                                            : "，预计日期 " + expectedDate)
                                    + "。请在仓库预计到货队列跟进。",
                            "/warehouse/inbound/expectations",
                            null,
                            null,
                            orderId);
                }
            }
        });
    }

    /**
     * ADR-098 委外回厂短交通知：发现(低于允许下限)给订货单制单人紧急卡、业务员与其他持判定权限的人
     * 知会; 分批等待逾期给制单人重要卡; 判定/自然到齐/作废只撤卡。同一案件只留最新一张卡。
     * 文案只用大白话数字, 不带代号(准则 14 §五之三)。
     */
    private void notifySubcontractShortDeliveryEvent(String eventType, UUID caseId, JsonNode payload) {
        deliverAtomically(() -> {
            if (EVENT_SUBCONTRACT_SHORT_DELIVERY_RESOLVED.equals(eventType)) {
                resolveReviewNotices(SUBCONTRACT_SHORT_DELIVERY_AGGREGATE, caseId,
                        payload == null ? "RESOLVED" : payload.path("reason").asText("RESOLVED"));
                return;
            }
            Map<String, Object> shortCase = one("""
                    SELECT c.status, c.severity, c.order_bill_no_snapshot, c.receipt_bill_no_snapshot,
                           c.ordered_qty, c.allowed_loss_pct, c.floor_qty, c.delivered_qty, c.shortfall_qty,
                           c.shortfall_pct, c.expected_complete_by, c.owner_user_id,
                           COALESCE(c.goods_name_snapshot, goods.name) AS goods_name,
                           COALESCE(c.goods_code_snapshot, goods.code) AS goods_code,
                           color.name AS color_name, unit.name AS unit_name, supplier.name AS supplier_name,
                           order_doc.purchaser_id
                    FROM subcontract_short_delivery_cases c
                    JOIN goods ON goods.id = c.goods_id
                    JOIN subcontract_orders order_doc ON order_doc.id = c.order_id
                    LEFT JOIN colors color ON color.id = c.color_id
                    LEFT JOIN units unit ON unit.id = c.unit_id
                    LEFT JOIN suppliers supplier ON supplier.id = c.supplier_id
                    WHERE c.id = ?
                    FOR UPDATE OF c
                    """, caseId);
            // 锁住案件行再判程度: 补货登记改程度与本次投递串行。否则投递读到旧程度、慢慢发卡期间
            // 登记已进容差且「撤卡」已先跑完, 这批催货卡就留成没人撤的待办。
            if (shortCase == null) return;
            String status = str(shortCase.get("status"));
            boolean overdueEvent = EVENT_SUBCONTRACT_SHORT_DELIVERY_WAIT_OVERDUE.equals(eventType);
            if (overdueEvent ? !"WAITING_MORE".equals(status)
                    : !"PENDING_OWNER".equals(status) && !"WAITING_MORE".equals(status)) {
                return;
            }
            // Outbox 可能在补货登记之后才投递；已达到约定下限就不再重建旧催货行动卡。
            if ("WITHIN_TOLERANCE".equals(str(shortCase.get("severity")))) {
                resolveReviewNotices(SUBCONTRACT_SHORT_DELIVERY_AGGREGATE, caseId, "WITHIN_TOLERANCE");
                return;
            }
            String orderNo = str(shortCase.get("order_bill_no_snapshot"));
            String goods = java.util.stream.Stream.of(
                            str(shortCase.get("goods_name")), str(shortCase.get("goods_code")),
                            str(shortCase.get("color_name")))
                    .filter(part -> part != null && !part.isBlank())
                    .collect(java.util.stream.Collectors.joining(" "));
            String unit = str(shortCase.get("unit_name"));
            unit = unit == null || unit.isBlank() ? "" : " " + unit;
            String supplier = str(shortCase.get("supplier_name"));
            supplier = supplier == null || supplier.isBlank() ? "委外商" : "委外商 " + supplier;
            String route = "/subcontract/short-deliveries?caseId=" + caseId;
            String title;
            String content;
            String type;
            if (overdueEvent) {
                title = "委外分批到货已过预计到齐日仍未到齐：" + orderNo;
                content = supplier + " 的货品「" + goods + "」订 " + plainQty(shortCase.get("ordered_qty")) + unit
                        + "，累计回厂 " + plainQty(shortCase.get("delivered_qty")) + unit
                        + "，还少 " + plainQty(shortCase.get("shortfall_qty")) + unit
                        + "(" + plainQty(shortCase.get("shortfall_pct")) + "%)，预计到齐日 "
                        + str(shortCase.get("expected_complete_by"))
                        + " 已过。请催货后重新填预计到齐日，或接受损耗结案。";
                type = TYPE_TASK;
            } else {
                String severe = "SEVERE".equals(str(shortCase.get("severity"))) ? "，属严重短交" : "";
                title = "委外回厂数量明显少于订货量：" + orderNo;
                content = supplier + " 的货品「" + goods + "」订 " + plainQty(shortCase.get("ordered_qty")) + unit
                        + "，允许损耗 " + plainQty(shortCase.get("allowed_loss_pct")) + "%(最少应到 "
                        + plainQty(shortCase.get("floor_qty")) + unit + ")，收货单 "
                        + str(shortCase.get("receipt_bill_no_snapshot")) + " 登记后累计回厂 "
                        + plainQty(shortCase.get("delivered_qty")) + unit + "，少 "
                        + plainQty(shortCase.get("shortfall_qty")) + unit + "("
                        + plainQty(shortCase.get("shortfall_pct")) + "%)" + severe
                        + "。请判定：分批到货继续等，还是接受损耗结案(自动登记损耗单并把订货量改为已回厂量)。";
                type = TYPE_URGENT;
            }
            resolveReviewNotices(SUBCONTRACT_SHORT_DELIVERY_AGGREGATE, caseId, "SUPERSEDED");
            Set<UUID> notified = new LinkedHashSet<>();
            UUID owner = (UUID) shortCase.get("owner_user_id");
            if (owner != null) {
                sendToUser(owner, type, title, content, route, eventType, null, caseId);
                notified.add(owner);
            }
            UUID purchaser = userIdOfEmployee((UUID) shortCase.get("purchaser_id"));
            if (purchaser != null && notified.add(purchaser)) {
                sendToUser(purchaser, type, title, content, route, eventType, "normal", caseId);
            }
            for (UUID follower : userIdsWithPermissions(
                    SUBCONTRACT_SHORT_DELIVERY_DECIDE_AUTHORITY, NOTICE_READ_AUTHORITY)) {
                if (notified.add(follower)) {
                    sendToUser(follower, TYPE_TASK, title, content, route, eventType, "normal", caseId);
                }
            }
        });
    }

    private static String plainQty(Object value) {
        BigDecimal number = bd(value);
        return number == null ? "0" : number.stripTrailingZeros().toPlainString();
    }

    /**
     * 「到货超量待财务审核」的委外补句(ADR-143 §二.3/§二.12)。已批准的委外明细一定有冻结领料计划行
     * (缺 BOM 的委外件不能批准): 多出来的超出了我方已发直属物料能做成的数量, 是委外商自带料做的,
     * 并列出我方发给委外商的全部直属物料(万一没有计划行, 只说超出了我方已发直属物料能做成的数量)。
     * 采购单或算不出超出量时返回空串, 原文案一个字不动。
     */
    private String subcontractSupplierOwnMaterialSentence(String orderType, UUID orderItemId,
                                                          BigDecimal declaredQty, BigDecimal approvedRemainingQty) {
        if (!"SUBCONTRACT".equals(orderType) || orderItemId == null || declaredQty == null) return "";
        BigDecimal excess = declaredQty.subtract(approvedRemainingQty == null ? BigDecimal.ZERO : approvedRemainingQty);
        if (excess.signum() <= 0) return "";
        Map<String, Object> line = one("""
                SELECT goods.code AS goods_code, goods.name AS goods_name,
                       unit.name AS unit_name,
                       materials.labels AS material_labels
                FROM subcontract_order_items order_item
                JOIN goods ON goods.id = order_item.goods_id
                LEFT JOIN units unit ON unit.id = order_item.unit_id
                LEFT JOIN LATERAL (
                    SELECT string_agg(concat_ws(' ', material.code, material.name), '、'
                                      ORDER BY plan_item.line_no, plan_item.id) AS labels
                    FROM subcontract_material_plan_items plan_item
                    JOIN goods material ON material.id = plan_item.goods_id
                    WHERE plan_item.order_item_id = order_item.id
                      AND plan_item.is_deleted = FALSE
                ) materials ON TRUE
                WHERE order_item.id = ?
                """, orderItemId);
        String target = line == null ? "委外件" : subcontractGoodsLabel(line);
        String unit = line == null || line.get("unit_name") == null ? "" : " " + str(line.get("unit_name"));
        String materials = line == null ? "" : str(line.get("material_labels")).strip();
        return "多出来的 " + plainQty(excess) + unit
                + " 超出了我方已发直属物料能做成的数量，是委外商自带料做出来的委外件 " + target
                + "，请确认价格与归属。"
                + (materials.isBlank() ? "" : "我方发给委外商的直属物料：" + materials + "。");
    }

    private void notifyProcurementArrivalEvent(String eventType, UUID exceptionId) {
        deliverAtomically(() -> {
            Map<String, Object> arrival = one("""
                    SELECT exception.order_type,
                           exception.receipt_bill_no_snapshot,
                           exception.order_bill_no_snapshot,
                           exception.owner_user_id,
                           exception.finance_assignee_user_id,
                           exception.declared_qty,
                           exception.approved_remaining_qty,
                           exception.approved_excess_qty,
                           exception.accepted_qty,
                           exception.unaccepted_qty,
                           exception.status,
                           exception.decision,
                           exception.finance_reason,
                           exception.order_item_id,
                           exception.warehouse_id,
                           exception.order_qty_snapshot,
                           exception.allowed_over_receipt_pct_snapshot,
                           exception.tolerance_qty_snapshot,
                           exception.prior_net_received_qty_snapshot,
                           return_task.qty AS return_qty,
                           return_task.status AS return_status
                    FROM procurement_arrival_exceptions exception
                    LEFT JOIN supplier_return_tasks return_task
                      ON return_task.arrival_exception_id = exception.id
                    WHERE exception.id = ?
                    """, exceptionId);
            if (arrival == null) return;
            UUID ownerUser = (UUID) arrival.get("owner_user_id");
            String orderNo = str(arrival.get("order_bill_no_snapshot"));
            String receiptNo = str(arrival.get("receipt_bill_no_snapshot"));
            String orderLabel = "SUBCONTRACT".equals(str(arrival.get("order_type")))
                    ? "委外订货单" : "采购订货单";

            if (EVENT_PROCUREMENT_ARRIVAL_DETECTED.equals(eventType)) {
                String title = "到货超量待财务审核：" + orderNo;
                String content;
                if ("PURCHASE".equals(str(arrival.get("order_type")))
                        && arrival.get("order_qty_snapshot") != null) {
                    // ADR-144 §2.3: 采购写明订货量、允许超收比例与最多可收、此前已收与累计, 以及要审批的超量。
                    BigDecimal declared = bd(arrival.get("declared_qty"));
                    BigDecimal orderQty = bd(arrival.get("order_qty_snapshot"));
                    BigDecimal priorNet = bd(arrival.get("prior_net_received_qty_snapshot"));
                    BigDecimal excess = declared.subtract(bd(arrival.get("approved_remaining_qty")))
                            .max(BigDecimal.ZERO);
                    content = "收货单 " + receiptNo + " 实到 " + plainQty(declared)
                            + "：订 " + plainQty(orderQty)
                            + "，允许超收 " + plainQty(arrival.get("allowed_over_receipt_pct_snapshot"))
                            + "%(最多 " + plainQty(orderQty.add(bd(arrival.get("tolerance_qty_snapshot"))))
                            + ")，此前已收 " + plainQty(priorNet)
                            + "，累计 " + plainQty(priorNet.add(declared))
                            + "，需审批超量 " + plainQty(excess)
                            + "。本次未入库、未立应付；请财务持权人员到仓库到货异常任务中心审核。";
                } else {
                    content = "收货单 " + receiptNo + " 的实际到货量 "
                            + str(arrival.get("declared_qty"))
                            + " 超过当前财务批准剩余可收量 "
                            + str(arrival.get("approved_remaining_qty"))
                            + "。本次未入库、未立应付；请财务持权人员到仓库到货异常任务中心审核。"
                            + subcontractSupplierOwnMaterialSentence(
                                    str(arrival.get("order_type")),
                                    (UUID) arrival.get("order_item_id"),
                                    bd(arrival.get("declared_qty")),
                                    bd(arrival.get("approved_remaining_qty")));
                }
                UUID assignee = (UUID) arrival.get("finance_assignee_user_id");
                Set<UUID> reviewers = new LinkedHashSet<>(financeReviewerUserIds());
                if (assignee != null) {
                    sendToUser(assignee, TYPE_URGENT, title, content,
                            "/finance/procurement-arrival-exceptions");
                    reviewers.remove(assignee);
                }
                for (UUID reviewer : reviewers) {
                    sendToUser(reviewer, TYPE_URGENT, title, content,
                            "/finance/procurement-arrival-exceptions", null, "normal");
                }
                return;
            }
            if (EVENT_PROCUREMENT_RETURN_REQUIRED.equals(eventType)) {
                String returnQty = str(arrival.get("return_qty"));
                notifyUser(ownerUser, TYPE_TASK,
                        "供应商退回任务：" + orderNo,
                        orderLabel + " " + orderNo + " 的未接收数量 "
                                + returnQty
                                + " 已形成持久任务。请完成实物退回后在本人任务中确认；通知不能代替任务台账。",
                        "/procurement/arrival-exceptions");
                broadcastToProcurementReturnFollowers(
                        str(arrival.get("order_type")), ownerUser,
                        TYPE_TASK, "供应商退回任务：" + orderNo,
                        orderLabel + " " + orderNo + " 有未接收数量 " + returnQty
                                + " 待退回，请跟进实物退回。",
                        "/procurement/arrival-exceptions");
                return;
            }
            if (EVENT_PROCUREMENT_ARRIVAL_RECEIPT_POSTED.equals(eventType)) {
                // 仓库一键入库后、本异常仍有待退量 → 通知采购/委外安排退回。
                String acceptedQty = str(arrival.get("accepted_qty"));
                String unacceptedQty = str(arrival.get("unaccepted_qty"));
                String content = orderLabel + " " + orderNo + " 的收货单 " + receiptNo
                        + " 已按财务批准量入库 " + acceptedQty
                        + "，未接收 " + unacceptedQty
                        + " 待退回供应商/委外商。请尽快安排实物退回。";
                // 原下单人须在本人任务确认退回；部门内其他人广播知会（去重避免重复通知）。
                notifyUser(ownerUser, TYPE_TASK, "到货已入库，余量待退：" + orderNo,
                        content, "/procurement/arrival-exceptions");
                broadcastToProcurementReturnFollowers(
                        str(arrival.get("order_type")), ownerUser, TYPE_TASK,
                        "到货已入库，余量待退：" + orderNo, content,
                        "/procurement/arrival-exceptions");
                return;
            }
            if (EVENT_PROCUREMENT_RETURN_COMPLETED.equals(eventType)) {
                notifyUser(ownerUser, TYPE_WORKFLOW,
                        "供应商退回已登记：" + orderNo,
                        orderLabel + " " + orderNo + " 的供应商退回任务已登记完成。",
                        "/procurement/arrival-exceptions");
                return;
            }

            BigDecimal accepted = bd(arrival.get("accepted_qty"));
            for (UUID warehouseUser : warehouseRecipients(warehousePool(NOTICE_READ_AUTHORITY, "warehouse_inbound:stock_in"),
                    warehouseIdsOf(arrival.get("warehouse_id")))) {
                if (accepted.signum() > 0) {
                    sendToUser(warehouseUser, TYPE_TASK,
                            "到货数量已由财务审核：" + orderNo,
                            "财务批准本行接收 " + str(arrival.get("accepted_qty"))
                                    + "，未接收 " + str(arrival.get("unaccepted_qty"))
                                    + "，批准额外超量 "
                                    + str(arrival.get("approved_excess_qty"))
                                    + "。收货草稿已由服务端调整，请重新核对并审核；不得按原申报量入库。",
                            "/warehouse/inbound/arrival-exceptions");
                } else {
                    sendToUser(warehouseUser, TYPE_WORKFLOW,
                            "到货超量已由财务拒绝：" + orderNo,
                            "财务未批准收货单 " + receiptNo
                                    + " 的该行接收，收货草稿行已移除；未接收数量 "
                                    + str(arrival.get("unaccepted_qty"))
                                    + " 已转原下单人处理供应商退回。",
                            "/warehouse/inbound/arrival-exceptions");
                }
            }
        });
    }

    /** 采购沿用采购池；委外按当前有效任务权限解析，不再硬编码到采购部。 */
    private void broadcastToProcurementReturnFollowers(
            String orderType,
            UUID excludeUser,
            String type,
            String title,
            String content,
            String route) {
        Set<UUID> targets = "SUBCONTRACT".equals(orderType)
                ? userIdsWithPermissions(
                        "supplier_return_task:view", NOTICE_READ_AUTHORITY)
                : new LinkedHashSet<>(departmentUserIds("SUB_PURCHASE"));
        for (UUID uid : targets) {
            if (excludeUser != null && excludeUser.equals(uid)) continue;
            sendToUser(uid, type, title, content, route, null, "normal");
        }
    }

    private Set<UUID> userIdsWithPermissions(String... required) {
        return userIdsWithRequiredAndAnyPermission(Set.of(required), Set.of());
    }

    /** Active users with notice read plus at least one all-case/action permission. */
    private Set<UUID> userIdsWithNoticeAndAnyPermission(
            String... anyPermission) {
        return userIdsWithRequiredAndAnyPermission(
                Set.of(NOTICE_READ_AUTHORITY), Set.of(anyPermission));
    }

    /** One effective snapshot per active candidate, including all required page/action gates. */
    private Set<UUID> userIdsWithRequiredAndAnyPermission(
            Set<String> required, Set<String> alternatives) {
        Set<String> possibleActions = new LinkedHashSet<>(alternatives.isEmpty() ? required : alternatives);
        possibleActions.remove(NOTICE_READ_AUTHORITY);
        List<UserAccount> candidates = permissionCandidates == null ? userRepo.findAll()
                : permissionCandidates.possibleUsers(possibleActions)
                        .map(userRepo::findAllById).orElseGet(userRepo::findAll);
        Set<UUID> result = new LinkedHashSet<>();
        Set<String> administratorPermissions = null;
        for (UserAccount user : candidates) {
            if (user == null
                    || user.isDeleted()
                    || !"active".equals(user.getStatus())) {
                continue;
            }
            Set<String> permissions;
            if (user.isSuperAdmin()) {
                if (administratorPermissions == null) administratorPermissions = permissionResolver.permsOf(user);
                permissions = administratorPermissions;
            } else {
                permissions = permissionResolver.permsOf(user);
            }
            if (!permissions.containsAll(required)) continue;
            if (alternatives.isEmpty() || alternatives.stream().anyMatch(permissions::contains)) {
                result.add(user.getId());
            }
        }
        return result;
    }

    /** IQC task notices must open successfully: notice read + exact page view + one role action. */
    private Set<UUID> userIdsWithIqcViewAndAnyPermission(
            String... anyPermission) {
        return userIdsWithRequiredAndAnyPermission(
                Set.of(NOTICE_READ_AUTHORITY, IQC_REJECTION_VIEW_AUTHORITY),
                Set.of(anyPermission));
    }

    private boolean userHasPermissions(UUID userId, String... required) {
        if (userId == null) return false;
        Set<String> permissions = Set.of(required);
        return userRepo.findById(userId)
                .filter(user -> !user.isDeleted()
                        && "active".equals(user.getStatus()))
                .map(permissionResolver::permsOf)
                .map(authorities -> authorities.containsAll(permissions))
                .orElse(false);
    }

    private void notifySubcontractLossClaimEvent(String eventType, UUID caseId) {
        deliverAtomically(() -> {
            Map<String, Object> claim = one("""
                    SELECT loss.waste_bill_no,loss.status,supplier.name AS supplier_name
                    FROM subcontract_loss_cases loss
                    JOIN suppliers supplier ON supplier.id=loss.supplier_id
                    WHERE loss.id=?
                    """, caseId);
            if (claim == null) return;
            String wasteNo = str(claim.get("waste_bill_no"));
            String supplier = str(claim.get("supplier_name"));
            String status = str(claim.get("status"));
            String title;
            String content;
            String type;
            if (EVENT_SUBCONTRACT_LOSS_OPENED.equals(eventType)) {
                title = "委外超耗待财务决定：" + wasteNo;
                content = "委外商 " + supplier + " 的损耗单 " + wasteNo
                        + " 已形成超耗责任单。请核对公司承担、索赔、合法抵销、现金或实物补偿；"
                        + "损耗事实本身不会自动冲应付。";
                type = TYPE_APPROVAL;
                for (UUID reviewer : userIdsWithPermissions(
                        "subcontract_loss_claim:review", NOTICE_READ_AUTHORITY)) {
                    sendToUser(reviewer, type, title, content, "/finance/payables");
                }
                return;
            }
            if (EVENT_SUBCONTRACT_LOSS_DECIDED.equals(eventType)) {
                title = "委外超耗责任已决定：" + wasteNo;
                content = "委外商 " + supplier + " 的超耗责任已更新为 " + status
                        + "。待履约方案必须继续关联真实资金或实物证据。";
                type = TYPE_WORKFLOW;
            } else if (EVENT_SUBCONTRACT_LOSS_FULFILLED.equals(eventType)) {
                title = "委外超耗履约已登记：" + wasteNo;
                content = "委外商 " + supplier + " 的超耗补偿履约已登记，当前状态 "
                        + status + "。请按责任单核对抵销、到账或实物单据。";
                type = TYPE_WORKFLOW;
            } else {
                title = "委外超耗责任已反向：" + wasteNo;
                content = "委外商 " + supplier + " 的超耗责任/履约发生受控反向，当前状态 "
                        + status + "。请重新核对后续应付、资金和实物事实。";
                type = TYPE_URGENT;
            }

            Set<UUID> financeTargets = new LinkedHashSet<>(userIdsWithPermissions(
                    "subcontract_loss_claim:view", NOTICE_READ_AUTHORITY));
            if ("AWAITING_FULFILLMENT".equals(status)) {
                financeTargets.addAll(userIdsWithPermissions(
                        "subcontract_loss_claim:fulfill", NOTICE_READ_AUTHORITY));
            }
            for (UUID target : financeTargets) {
                sendToUser(target, type, title, content, "/finance/payables");
            }
            List<Map<String, Object>> owners = jdbc.queryForList("""
                    SELECT DISTINCT owner_user.id AS user_id,orders.id AS order_id
                    FROM subcontract_loss_case_lines line
                    JOIN subcontract_order_items order_item ON order_item.id=line.order_item_id
                    JOIN subcontract_orders orders ON orders.id=order_item.order_id
                    JOIN users owner_user ON owner_user.employee_id=orders.maker_id
                    WHERE line.case_id=?
                      AND owner_user.status='active'
                      AND COALESCE(owner_user.is_deleted,FALSE)=FALSE
                    """, caseId);
            for (Map<String, Object> owner : owners) {
                UUID ownerUserId = (UUID) owner.get("user_id");
                if (financeTargets.contains(ownerUserId)) continue;
                sendToUser(
                        ownerUserId,
                        type,
                        title,
                        content,
                        "/subcontract/orders/" + owner.get("order_id"));
            }
        });
    }

    /**
     * IQC failure, physical supplier return and the AP/credit decision are
     * separate facts. Notifications therefore point to the durable rejection
     * case and never copy commercial prices, exchange rates or credit amounts.
     *
     * <p>Ordinary {@code :view} is row-scoped: only the order owner may receive
     * that case. Global finance broadcasts require {@code notice:read} plus an
     * explicit all-case/action permission, so a user who can read only their
     * own orders cannot learn another order's rejection details.</p>
     */
    private void notifyProcurementIqcRejectionEvent(
            String eventType, UUID caseId) {
        deliverAtomically(() -> {
            Map<String, Object> rejection = one("""
                    SELECT rejection.receipt_type,
                           rejection.receipt_bill_no,
                           rejection.order_bill_no,
                           rejection.status,
                           rejection.owner_user_id,
                           rejection.failed_qty,
                           goods.code AS goods_code,
                           goods.name AS goods_name,
                           unit.name AS unit_name,
                           pre_stocked_warehouse.name AS pre_stocked_warehouse_name,
                           inspection.pre_stocked_place
                    FROM procurement_iqc_rejection_cases rejection
                    JOIN goods ON goods.id = rejection.goods_id
                    LEFT JOIN units unit ON unit.id = rejection.unit_id
                    LEFT JOIN procurement_inspection_items inspection
                      ON inspection.id = rejection.inspection_item_id
                    LEFT JOIN warehouses pre_stocked_warehouse
                      ON pre_stocked_warehouse.id = inspection.pre_stocked_warehouse_id
                    WHERE rejection.id = ?
                      AND COALESCE(rejection.is_deleted, FALSE) = FALSE
                    """, caseId);
            if (rejection == null) return;
            // 先入库后检(V596)：不合格实物已经在真实库位上，退回前必须先取出。
            String preStockedWarehouse = str(rejection.get("pre_stocked_warehouse_name"));
            String preStockedPlace = str(rejection.get("pre_stocked_place"));
            String preStockedHint = preStockedWarehouse.isBlank() && preStockedPlace.isBlank()
                    ? ""
                    : " 该批实物已先入库上架在「" + preStockedWarehouse
                            + (preStockedPlace.isBlank() ? "" : " / " + preStockedPlace)
                            + "」，请到库位取出后登记退回，不得当作可用库存使用。";

            String orderNo = str(rejection.get("order_bill_no"));
            String receiptNo = str(rejection.get("receipt_bill_no"));
            String goods = (str(rejection.get("goods_code")) + " "
                    + str(rejection.get("goods_name"))).strip();
            String failedQty = qty(bd(rejection.get("failed_qty")));
            String unit = str(rejection.get("unit_name"));
            String sourceLabel = ("SUBCONTRACT".equals(
                    str(rejection.get("receipt_type")))
                    ? "委外订货单 " : "采购订货单 ")
                    + (orderNo.isBlank() ? "（单号缺失）" : orderNo)
                    + " 的收货单 "
                    + (receiptNo.isBlank() ? "（单号缺失）" : receiptNo);
            String goodsLabel = goods.isBlank()
                    ? ""
                    : "，物料 " + goods + "，不合格数量 " + failedQty
                            + (unit.isBlank() ? "" : " " + unit);
            String route = "/procurement/iqc-rejections/" + caseId;

            String title;
            String content;
            String type;
            Set<UUID> recipients;
            if (EVENT_PROCUREMENT_IQC_REJECTION_OPENED.equals(eventType)) {
                title = "来料质检不合格待处置：" + displayNo(orderNo, receiptNo);
                content = sourceLabel + goodsLabel
                        + " 已形成独立退回/贷项任务。来料质检不合格的货不会进入可用库存，"
                        + "实物退回与供应商贷项必须分别留痕；请在任务详情跟进。" + preStockedHint;
                type = TYPE_TASK;
                recipients = userIdsWithIqcViewAndAnyPermission(
                        IQC_REJECTION_VIEW_ALL_AUTHORITY,
                        IQC_REJECTION_RECORD_RETURN_AUTHORITY,
                        IQC_REJECTION_CONFIRM_CREDIT_AUTHORITY,
                        IQC_REJECTION_CLOSE_NO_CREDIT_AUTHORITY);
                UUID ownerUserId = (UUID) rejection.get("owner_user_id");
                if (userHasPermissions(
                        ownerUserId,
                        NOTICE_READ_AUTHORITY,
                        IQC_REJECTION_VIEW_AUTHORITY)) {
                    recipients.add(ownerUserId);
                }
            } else if (EVENT_PROCUREMENT_IQC_REJECTION_RETURNED.equals(eventType)) {
                title = "来料质检不合格退回已登记，待财务结案："
                        + displayNo(orderNo, receiptNo);
                content = sourceLabel + goodsLabel
                        + " 的实物退回证据已登记。请财务核对后选择确认供应商贷项"
                        + "或无贷项结案；通知不代表应付已自动冲减。";
                type = TYPE_APPROVAL;
                recipients = userIdsWithIqcViewAndAnyPermission(
                        IQC_REJECTION_CONFIRM_CREDIT_AUTHORITY,
                        IQC_REJECTION_CLOSE_NO_CREDIT_AUTHORITY);
                UUID ownerUserId = (UUID) rejection.get("owner_user_id");
                if (userHasPermissions(
                        ownerUserId,
                        NOTICE_READ_AUTHORITY,
                        IQC_REJECTION_VIEW_AUTHORITY)) {
                    recipients.add(ownerUserId);
                }
            } else if (EVENT_PROCUREMENT_IQC_REJECTION_FINANCE_EXCEPTION.equals(
                    eventType)) {
                title = "来料质检不合格财务处置异常待复核："
                        + displayNo(orderNo, receiptNo);
                content = sourceLabel + goodsLabel
                        + " 的财务动作未完成，任务仍停留在持久状态 "
                        + str(rejection.get("status"))
                        + "。请从任务详情核对来源应付、贷项和抵销事实；"
                        + "不得据此通知手工修改应付余额。";
                type = TYPE_URGENT;
                recipients = userIdsWithIqcViewAndAnyPermission(
                        IQC_REJECTION_VIEW_ALL_AUTHORITY,
                        IQC_REJECTION_CONFIRM_CREDIT_AUTHORITY,
                        IQC_REJECTION_CLOSE_NO_CREDIT_AUTHORITY);
            } else {
                recipients = new LinkedHashSet<>(userIdsWithPermissions(
                        NOTICE_READ_AUTHORITY,
                        IQC_REJECTION_VIEW_ALL_AUTHORITY));
                UUID ownerUserId = (UUID) rejection.get("owner_user_id");
                if (userHasPermissions(
                        ownerUserId,
                        NOTICE_READ_AUTHORITY,
                        IQC_REJECTION_VIEW_AUTHORITY)) {
                    recipients.add(ownerUserId);
                }
                if (EVENT_PROCUREMENT_IQC_CREDIT_CONFIRMED.equals(eventType)) {
                    title = "来料质检不合格供应商贷项已确认："
                            + displayNo(orderNo, receiptNo);
                    content = sourceLabel + goodsLabel
                            + " 的供应商贷项与来源应付抵销已受控确认。"
                            + "具体商业数据仅在持权任务详情中查看。";
                    type = TYPE_WORKFLOW;
                } else if (EVENT_PROCUREMENT_IQC_REJECTION_NO_CREDIT.equals(
                        eventType)) {
                    title = "来料质检不合格无贷项已结案："
                            + displayNo(orderNo, receiptNo);
                    content = sourceLabel + goodsLabel
                            + " 已按留痕原因完成无贷项结案，未生成供应商贷项或自动应付抵销。"
                            + "具体商业数据仅在持权任务详情中查看。";
                    type = TYPE_WORKFLOW;
                } else {
                    title = "来料质检拒收处置已反向："
                            + displayNo(orderNo, receiptNo);
                    content = sourceLabel + goodsLabel
                            + " 的退回/贷项处置发生受控反向，当前持久状态 "
                            + str(rejection.get("status"))
                            + "。请按任务详情重新执行后续步骤；通知本身不改变库存或应付。";
                    type = TYPE_URGENT;
                }
            }
            // 2026-09-05 通知补齐：OPENED/RETURNED 是「该谁干活」节点，升级为居中
            // 行动卡（aggregate 绑定拒收 case）；贷项确认/无贷项结案/反向时批量撤卡。
            boolean actionable = EVENT_PROCUREMENT_IQC_REJECTION_OPENED.equals(
                    eventType)
                    || EVENT_PROCUREMENT_IQC_REJECTION_RETURNED.equals(eventType);
            for (UUID recipient : recipients) {
                if (actionable) {
                    sendToUser(
                            recipient,
                            type,
                            title,
                            content,
                            route,
                            eventType,
                            null,
                            caseId);
                } else {
                    sendToUser(
                            recipient,
                            type,
                            title,
                            content,
                            route,
                            eventType);
                }
            }
            if (EVENT_PROCUREMENT_IQC_CREDIT_CONFIRMED.equals(eventType)
                    || EVENT_PROCUREMENT_IQC_REJECTION_NO_CREDIT.equals(eventType)
                    || EVENT_PROCUREMENT_IQC_REJECTION_REVERSED.equals(eventType)) {
                resolveReviewNotices("IQC_REJECTION_CASE", caseId, eventType);
            }
        });
    }

    private static String displayNo(String orderNo, String receiptNo) {
        return orderNo == null || orderNo.isBlank() ? receiptNo : orderNo;
    }

    // ---------- 接收人解析与发送 ----------

    /** 订单快照：id + 单号 + 归属销售的用户账号（owner_employee_id 优先，回退 seller_id）。 */
    private OrderRef orderRef(UUID orderId) {
        Map<String, Object> r = one(
                "SELECT bill_no, owner_employee_id, seller_id FROM sales_orders WHERE id = ?", orderId);
        if (r == null) return null;
        UUID userId = userIdOfEmployee((UUID) r.get("owner_employee_id"));
        if (userId == null) userId = userIdOfEmployee((UUID) r.get("seller_id"));
        return new OrderRef(orderId, str(r.get("bill_no")), userId);
    }

    /** Both finance and planning cards must still refer to the current active stage. */
    private boolean lockActiveOrderForNotice(UUID orderId, boolean financeConfirmed) {
        return lockActiveOrderForNotice(orderId, financeConfirmed, false);
    }

    private boolean lockActiveOrderForNotice(UUID orderId, boolean financeConfirmed, boolean skipLocked) {
        return !jdbc.queryForList("""
                SELECT id FROM sales_orders
                WHERE id = ? AND NOT is_deleted AND status = 1 AND NOT is_closed
                  AND NOT is_stopped AND requoted_to_id IS NULL
                  AND finance_confirmed = ? AND NOT finance_rejected
                FOR UPDATE
                """ + (skipLocked ? " SKIP LOCKED" : ""), orderId, financeConfirmed).isEmpty();
    }

    private record OrderRef(UUID orderId, String billNo, UUID ownerUserId) {
        /** 订单详情页路由（问题 #12：通知点击跳源单据）。 */
        String route() {
            return "/sales/orders/" + orderId;
        }
    }

    /** 员工 → 活跃账号（无账号/已停用/已删除 → null，静默跳过）。 */
    private UUID userIdOfEmployee(UUID employeeId) {
        if (employeeId == null) return null;
        return userRepo.findByEmployeeId(employeeId)
                .filter(u -> "active".equals(u.getStatus()) && !u.isDeleted())
                .map(UserAccount::getId)
                .orElse(null);
    }

    /** Current subcontract maker_id is an employee UUID, never a user UUID. */
    private UUID subcontractMakerUserId(UUID makerIdentity) {
        return userIdOfEmployee(makerIdentity);
    }

    private void notifyUser(UUID userId, String type, String title, String content) {
        notifyUser(userId, type, title, content, null, null);
    }

    /** 带跳转入口的定向通知（问题 #12：点排产/发货等通知能跳到对应单据）。 */
    private void notifyUser(UUID userId, String type, String title, String content, String actionRoute) {
        notifyUser(userId, type, title, content, actionRoute, null);
    }

    /** 带事件来源标记的定向通知：sourceEvent 写入 notices.source_event，供按事件统计未读徽章。 */
    private void notifyUser(UUID userId, String type, String title, String content,
                            String actionRoute, String sourceEvent) {
        if (userId == null) return;
        sendToUser(userId, type, title, content, actionRoute, sourceEvent);
    }

    /**
     * 部门池广播(ADR-109 取代按角色群发)：部门子树(含兼职)里当前有效权限同时含
     * 通知读取与 {@code requiredAuthority} 的在职账号；被收回查看权的人不再收到带单号的通知。
     */
    private void notifyDepartmentPool(
            String requiredAuthority,
            List<String> departmentCodes,
            String type,
            String title,
            String content,
            String actionRoute) {
        for (UUID uid : departmentPoolWithPermission(requiredAuthority, departmentCodes)) {
            // 部门池是公共任务广播，即使事件本身重要，也不得阻塞每个成员。
            sendToUser(uid, type, title, content, actionRoute, null, "normal");
        }
    }

    /** 部门子树成员里「能读通知且持有 requiredAuthority」的账号(每人一次权限合成)。 */
    private Set<UUID> departmentPoolWithPermission(
            String requiredAuthority, List<String> departmentCodes) {
        Set<UUID> candidates = new LinkedHashSet<>();
        for (String departmentCode : departmentCodes) {
            candidates.addAll(departmentUserIds(departmentCode));
        }
        Set<UUID> result = new LinkedHashSet<>();
        if (candidates.isEmpty()) {
            return result;
        }
        for (UserAccount account : userRepo.findAllById(candidates)) {
            if (account == null
                    || account.isDeleted()
                    || !"active".equals(account.getStatus())) {
                continue;
            }
            Set<String> authorities = permissionResolver.permsOf(account);
            if (authorities.contains(NOTICE_READ_AUTHORITY)
                    && authorities.contains(requiredAuthority)) {
                result.add(account.getId());
            }
        }
        return result;
    }

    /**
     * 物料分析生成采购/委外申请后的办理人池。
     *
     * <p>候选是采购部子树，最终必须同时拥有通知读取权和目标申请查看权。这样个人
     * revoke 后不会继续收到包含物料、数量和单号的通知。
     */
    private void notifyPreplanSupplyRecipients(
            String type,
            String title,
            String content,
            String actionRoute,
            String requiredViewAuthority) {
        Set<UUID> candidates = new LinkedHashSet<>(departmentUserIds("SUB_PURCHASE"));
        for (UUID userId : candidates) {
            UserAccount account = userRepo.findById(userId).orElse(null);
            if (account == null
                    || account.isDeleted()
                    || !"active".equals(account.getStatus())) {
                continue;
            }
            Set<String> authorities = permissionResolver.permsOf(account);
            if (!authorities.contains(NOTICE_READ_AUTHORITY)
                    || !authorities.contains(requiredViewAuthority)) {
                continue;
            }
            sendToUser(userId, type, title, content, actionRoute);
        }
    }

    /**
     * Operational recipients follow the current department-permission model.
     * Legacy role lookup remains above for migrated accounts, while this query
     * covers the selected department and all active descendants.
     */
    private List<UUID> departmentUserIds(String departmentCode) {
        return jdbc.queryForList("""
                WITH RECURSIVE subtree(id) AS (
                    SELECT id
                    FROM departments
                    WHERE code = ? AND is_deleted = false
                    UNION ALL
                    SELECT child.id
                    FROM departments child
                    JOIN subtree parent ON child.parent_id = parent.id
                    WHERE child.is_deleted = false
                )
                SELECT DISTINCT user_account.id
                FROM users user_account
                JOIN employees employee
                  ON employee.id = user_account.employee_id
                WHERE (employee.department_id IN (SELECT id FROM subtree)
                       OR EXISTS (
                           SELECT 1 FROM employee_secondary_departments secondary
                           WHERE secondary.employee_id = employee.id
                             AND secondary.department_id IN (SELECT id FROM subtree)))
                  AND employee.is_deleted = false
                  AND employee.status <> 'resigned'
                  AND user_account.is_deleted = false
                  AND user_account.status = 'active'
                ORDER BY user_account.id
                """, UUID.class, departmentCode);
    }

    /**
     * 品质待检通知池：只允许品质部子树内当前在职、账号启用的用户，并以服务端有效权限
     * 再次复核查看权。PMC/生产部门的默认查看权、跨部门个人加授和超管全集均不扩张此池。
     */
    private List<UUID> qualityInspectionViewerUserIds() {
        List<UUID> qualityCandidates = jdbc.queryForList("""
                WITH RECURSIVE quality_departments(id) AS (
                    SELECT id
                    FROM departments
                    WHERE code = 'DEPT_QA' AND is_deleted = FALSE
                    UNION ALL
                    SELECT child.id
                    FROM departments child
                    JOIN quality_departments parent ON child.parent_id = parent.id
                    WHERE child.is_deleted = FALSE
                )
                SELECT DISTINCT user_account.id
                FROM users user_account
                JOIN employees employee
                  ON employee.id = user_account.employee_id
                WHERE (employee.department_id IN (SELECT id FROM quality_departments)
                       OR EXISTS (
                           SELECT 1 FROM employee_secondary_departments secondary
                           WHERE secondary.employee_id = employee.id
                             AND secondary.department_id IN (SELECT id FROM quality_departments)))
                  AND employee.is_deleted = FALSE
                  AND employee.status IN ('active', 'probation', 'onLeave')
                  AND user_account.is_deleted = FALSE
                  AND user_account.status = 'active'
                ORDER BY user_account.id
                """, UUID.class);
        return qualityCandidates.stream()
                .filter(userId -> userRepo.findById(userId)
                        .filter(account -> !account.isDeleted()
                                && "active".equals(account.getStatus()))
                        .map(permissionResolver::permsOf)
                        .map(permissions -> permissions.containsAll(Set.of(
                                NOTICE_READ_AUTHORITY, IQC_VIEW_AUTHORITY,
                                "procurement_inspection:handle")))
                        .orElse(false))
                .toList();
    }

    /**
     * 当前可审批财务任务的接收人池：财务部门树内在职、账号启用且持有
     * finance_order_approval:approve 或 :reject 的全部合格用户（ADR-027 审核组模型）。
     */
    private List<UUID> financeReviewerUserIds() {
        return financeReviewerEligibility.allEligible().stream()
                .map(FinanceReviewerEligibilityPort.EligibleFinanceReviewer::userId)
                .toList();
    }

    /** 部门树候选与当前有效权限求交，个人 revoke 后不会继续收到业务详情。 */
    private List<UUID> departmentUserIdsWithAuthority(
            String departmentCode, String authority) {
        return departmentUserIdsWithAuthorities(departmentCode, authority);
    }

    /** 部门树候选与多个当前有效权限取交集。 */
    private List<UUID> departmentUserIdsWithAuthorities(
            String departmentCode, String... authorities) {
        Set<String> required = Set.of(authorities);
        return departmentUserIds(departmentCode).stream()
                .filter(userId -> userRepo.findById(userId)
                        .filter(account -> !account.isDeleted()
                                && "active".equals(account.getStatus()))
                        .map(permissionResolver::permsOf)
                        .map(permissions -> permissions.containsAll(required))
                        .orElse(false))
                .toList();
    }

    /**
     * ADR-063 弹窗口径的接收池：(主部门 ∈ 部门子树 OR 兼职部门 ∈ 部门子树)
     * AND 持有全部权限码，双条件缺一不可。与 {@link #departmentUserIdsWithAuthorities}
     * 的差别只在兼职部门也参与命中（与车间树、财务确认池同语义）。
     */
    private List<UUID> departmentUserIdsWithSecondaryAuthorities(
            String departmentCode, String... authorities) {
        Set<String> required = Set.of(authorities);
        List<UUID> candidates = jdbc.queryForList("""
                WITH RECURSIVE subtree(id) AS (
                    SELECT id
                    FROM departments
                    WHERE code = ? AND is_deleted = FALSE
                    UNION ALL
                    SELECT child.id
                    FROM departments child
                    JOIN subtree parent ON child.parent_id = parent.id
                    WHERE child.is_deleted = FALSE
                ), candidate_employee(id) AS (
                    SELECT employee.id
                    FROM employees employee
                    WHERE employee.department_id IN (SELECT id FROM subtree)
                    UNION
                    SELECT secondary.employee_id
                    FROM employee_secondary_departments secondary
                    WHERE secondary.department_id IN (SELECT id FROM subtree)
                )
                SELECT DISTINCT user_account.id
                FROM candidate_employee candidate
                JOIN employees employee ON employee.id = candidate.id
                JOIN users user_account
                  ON user_account.employee_id = employee.id
                WHERE employee.is_deleted = FALSE
                  AND employee.status IN ('active', 'probation', 'onLeave')
                  AND user_account.is_deleted = FALSE
                  AND user_account.status = 'active'
                ORDER BY user_account.id
                """, UUID.class, departmentCode);
        return candidates.stream()
                .filter(userId -> userRepo.findById(userId)
                        .filter(account -> !account.isDeleted()
                                && "active".equals(account.getStatus()))
                        .map(permissionResolver::permsOf)
                        .map(permissions -> permissions.containsAll(required))
                        .orElse(false))
                .toList();
    }

    private void sendToUser(UUID userId, String type, String title, String content) {
        sendToUser(userId, type, title, content, null, null);
    }

    /** 停用/删除账号跳过；写入失败交给 Outbox 整体回滚重试。 */
    private void sendToUser(UUID userId, String type, String title, String content, String actionRoute) {
        sendToUser(userId, type, title, content, actionRoute, null);
    }

    private void sendToUser(UUID userId, String type, String title, String content,
                            String actionRoute, String sourceEvent) {
        sendToUser(userId, type, title, content, actionRoute, sourceEvent, null);
    }

    private void sendToUser(UUID userId, String type, String title, String content,
                            String actionRoute, String sourceEvent,
                            String explicitPriority) {
        sendToUser(userId, type, title, content, actionRoute, sourceEvent,
                explicitPriority, null);
    }

    /**
     * V459 审核待办入口：显式 aggregateId。sourceEvent 在
     * {@link ReviewNoticeCatalog} 注册时绑定聚合（办结撤回 + 弹卡认领状态查询）；
     * 未注册事件等价于普通 sendToUser。
     */
    private void sendToUser(UUID userId, String type, String title, String content,
                            String actionRoute, String sourceEvent,
                            String explicitPriority, UUID aggregateId) {
        UserAccount u = userRepo.findById(userId).orElse(null);
        if (u == null || !"active".equals(u.getStatus()) || u.isDeleted()) return;
        String effectiveSourceEvent = sourceEvent;
        if (effectiveSourceEvent == null || effectiveSourceEvent.isBlank()) {
            effectiveSourceEvent = OUTBOX_EVENT.get();
        }
        if (aggregateId == null) {
            // 无聚合：保持历史调用形态（7/8 参重载），既有测试与语义零变化。
            if (explicitPriority == null) {
                noticeService.publishForUser(
                        userId, title, content, type, PUBLISHER,
                        actionRoute, effectiveSourceEvent);
            } else {
                noticeService.publishForUser(
                        userId, title, content, type, PUBLISHER,
                        actionRoute, effectiveSourceEvent, explicitPriority);
            }
            return;
        }
        noticeService.publishForUser(
                userId, title, content, type, PUBLISHER, actionRoute,
                effectiveSourceEvent, explicitPriority, aggregateId);
    }

    /**
     * V459 办结撤回（业务落点统一入口）：审核通过/驳回/取消/开单等完成动作后，
     * 按 (aggregateKind, aggregateId) 批量 resolve 全部接收人的待审通知——
     * 弹卡停止展示、收件台计数归零、通知中心灰显「已办结」。幂等。
     */
    public int resolveReviewNotices(
            String aggregateKind, UUID aggregateId, String reason) {
        return noticeService.resolveReviewNotices(aggregateKind, aggregateId, reason);
    }

    public int resolveSalesFinanceReviewNotices(UUID orderId, String reason) {
        return noticeService.resolveReviewNoticesByEvent("SALES_ORDER", orderId, EVENT_ORDER_PENDING_FINANCE, reason);
    }

    // ---------- 研发任务 / BOM 维护 通知 ----------

    /**
     * BOM 维护完成(GoodsBomService 增删改、BOM 学习后发 GOODS_BOM_UPDATED)。ADR-143 §二.3，货品现在有
     * 可发外的直属物料时：
     * <ol>
     *   <li>还没按新 BOM 展开出这些直属物料的未结束物料分析，每张排一条
     *       {@value #EVENT_MATERIAL_ANALYSIS_BOM_REFRESH}。这里只排队不刷新：一张分析刷新要几秒，
     *       放在本投递里会卡住所有通知的投递，某一张失败也没人重试；</li>
     *   <li>自动完成它未完成的「完善 BOM」研发任务，并按等待名单逐个通知(直达各自被挡住的物料分析 /
     *       委外订货单 / 委外任务中心)。等着要刷新的那张物料分析的人，由那张分析刷新完再通知；
     *       其余的人马上通知，文案不说物料分析已更新。</li>
     * </ol>
     * 清空 BOM、或只剩不能发外的边(按包装、出货阶段、整批领料)时什么都不做，任务保持未完成。
     */
    public void notifyBomUpdated(UUID goodsId) {
        deliverAtomically(() -> {
            // 删除清空 BOM 时不应误完成——仅当确实已有可用 BOM 行才处理。
            Integer ready = jdbc.queryForObject(
                    "SELECT COUNT(*) FROM goods_bom_items WHERE goods_id = ? AND is_deleted = false",
                    Integer.class, goodsId);
            if (ready == null || ready == 0) return;
            // 「完善 BOM」任务等的是可发外的直属物料(唯一判定 fn_subcontract_draw_edges)，有了才算完成。
            Boolean drawable = jdbc.queryForObject(
                    "SELECT EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(?))", Boolean.class, goodsId);
            if (!Boolean.TRUE.equals(drawable)) return;
            List<RdTaskService.BomTaskWaiter> waiters = rdTaskService.openBomTaskWaiters(goodsId);
            Set<UUID> refreshing = enqueueMaterialAnalysisBomRefreshes(goodsId, waiters);
            int updated = rdTaskService.resolveOpenBomTasksForGoods(goodsId, "BOM 已完善，自动完成");
            if (updated == 0) return;
            String goodsLabel = bomGoodsLabel(goodsId);
            for (RdTaskService.BomTaskWaiter waiter : waiters) {
                if (waitsForAnalysisRefresh(waiter, refreshing)) continue;
                UUID uid = userIdOfEmployee(waiter.employeeId());
                if (uid != null) {
                    sendToUser(uid, TYPE_TASK,
                            "BOM 已完善：" + goodsLabel,
                            bomReadyContent(goodsLabel, waiter.sourceDocType()),
                            bomWaiterRoute(waiter));
                }
            }
        });
    }

    /**
     * 给还没按新 BOM 展开的每张物料分析排一条刷新事件，带上等这张分析的人(研发任务在本事务里随即完成，
     * 刷新那边已读不到等待名单)。去重键 = 分析 + 货品 + 本次 BOM 事件投递：排队与本条 BOM 事件的「已投递」
     * 在同一事务提交，本条事件只会在整体回滚后重新投递，那时这些排队也一并撤销。
     *
     * @return 排了刷新事件的分析
     */
    private Set<UUID> enqueueMaterialAnalysisBomRefreshes(UUID goodsId, List<RdTaskService.BomTaskWaiter> waiters) {
        var refresher = bomRefresh == null ? null : bomRefresh.getIfAvailable();
        if (refresher == null || goodsId == null) return Set.of();
        List<UUID> analyses = refresher.analysesAwaitingBomRefresh(goodsId);
        if (analyses.isEmpty()) return Set.of();
        String delivery = UUID.randomUUID().toString();
        Set<UUID> queued = new LinkedHashSet<>();
        for (UUID analysisId : analyses) {
            List<String> waiting = waiters.stream()
                    .filter(waiter -> waitsForAnalysisRefresh(waiter, Set.of(analysisId)))
                    .map(waiter -> waiter.employeeId().toString())
                    .distinct().sorted().toList();
            outbox.publishOnce(EVENT_MATERIAL_ANALYSIS_BOM_REFRESH, AGGREGATE_MATERIAL_ANALYSIS, analysisId,
                    Map.of("analysisId", analysisId.toString(), "goodsId", goodsId.toString(),
                            "waiterEmployeeIds", waiting),
                    EVENT_MATERIAL_ANALYSIS_BOM_REFRESH + ':' + analysisId + ':' + goodsId + ':' + delivery);
            queued.add(analysisId);
        }
        return queued;
    }

    /**
     * 按新 BOM 刷新一张物料分析({@link #notifyBomUpdated} 按分析各排一条)。刷新在实现方自己的独立事务里、
     * 以分析负责人身份进行；刷新失败原样抛出，本条事件退避重试(不再只记日志就算了)。刷新完、或这张分析
     * 早已按新 BOM 展开，才告诉等这张分析的人「物料分析已自动更新」；不能自动刷新(分析已结束、负责人账号
     * 不能用)时改请他们打开物料分析刷新。
     */
    private void deliverMaterialAnalysisBomRefresh(UUID analysisId, JsonNode payload) {
        deliverAtomically(() -> {
            UUID goodsId = uuidOrNull(payload.path("goodsId").asText(null));
            if (analysisId == null || goodsId == null) return;
            var refresher = bomRefresh == null ? null : bomRefresh.getIfAvailable();
            var outcome = refresher == null
                    ? com.uten.imp.application.port.MaterialAnalysisBomRefreshPort.Outcome.SKIPPED
                    : outsideNoticeDelivery(() -> refresher.refreshAnalysisAfterBomUpdated(analysisId, goodsId));
            List<UUID> waiting = new ArrayList<>();
            payload.path("waiterEmployeeIds").forEach(node -> {
                UUID employeeId = uuidOrNull(node.asText(null));
                if (employeeId != null) waiting.add(employeeId);
            });
            if (waiting.isEmpty()) return;
            String goodsLabel = bomGoodsLabel(goodsId);
            String content = outcome == com.uten.imp.application.port.MaterialAnalysisBomRefreshPort.Outcome.SKIPPED
                    ? bomReadyContent(goodsLabel, com.uten.imp.application.port.RdBomGapPort.SOURCE_MATERIAL_ANALYSIS)
                    : goodsLabel + " 的 BOM 已完善，物料分析已自动更新，可以下达。";
            String route = bomWaiterRoute(new RdTaskService.BomTaskWaiter(null,
                    com.uten.imp.application.port.RdBomGapPort.SOURCE_MATERIAL_ANALYSIS, analysisId));
            for (UUID employeeId : waiting) {
                UUID uid = userIdOfEmployee(employeeId);
                if (uid != null) {
                    sendToUser(uid, TYPE_TASK, "BOM 已完善：" + goodsLabel, content, route, EVENT_BOM_UPDATED);
                }
            }
        });
    }

    /**
     * 刷新物料分析期间暂时撤下「正在投递 outbox」标记：刷新顺带产生的通知照常进 outbox 排队，
     * 不在本投递事务里直接送达。
     */
    private <T> T outsideNoticeDelivery(java.util.function.Supplier<T> work) {
        String event = OUTBOX_EVENT.get();
        OUTBOX_DELIVERY.set(false);
        OUTBOX_EVENT.remove();
        try {
            return work.get();
        } finally {
            OUTBOX_DELIVERY.set(true);
            if (event != null) OUTBOX_EVENT.set(event);
        }
    }

    /** 等的是这些物料分析之一(由那张分析刷新完再通知)。 */
    private static boolean waitsForAnalysisRefresh(RdTaskService.BomTaskWaiter waiter, Set<UUID> analyses) {
        return waiter.employeeId() != null && waiter.sourceDocId() != null
                && com.uten.imp.application.port.RdBomGapPort.SOURCE_MATERIAL_ANALYSIS.equals(waiter.sourceDocType())
                && analyses.contains(waiter.sourceDocId());
    }

    /** 不说物料分析已更新的「BOM 已完善」文案：等物料分析的请他打开分析刷新，其余可以直接继续办。 */
    private static String bomReadyContent(String goodsLabel, String sourceDocType) {
        return com.uten.imp.application.port.RdBomGapPort.SOURCE_MATERIAL_ANALYSIS.equals(sourceDocType)
                ? goodsLabel + " 的 BOM 已完善，打开物料分析刷新后即可下达。"
                : goodsLabel + " 的 BOM 已完善，可以继续下达 / 下委外单。";
    }

    /** 货品显示名「名称(编号)」。 */
    private String bomGoodsLabel(UUID goodsId) {
        return oneStr("""
                SELECT COALESCE(name, '')
                       || CASE WHEN COALESCE(code, '') = '' THEN '' ELSE '(' || code || ')' END
                FROM goods WHERE id = ?
                """, goodsId);
    }

    /** 等待人被挡住的来源单据：物料分析 / 委外订货单 / 生产计划直达，委外申请回委外任务中心。 */
    private static String bomWaiterRoute(RdTaskService.BomTaskWaiter waiter) {
        String type = waiter.sourceDocType() == null ? "" : waiter.sourceDocType();
        UUID id = waiter.sourceDocId();
        return switch (type) {
            case com.uten.imp.application.port.RdBomGapPort.SOURCE_SUBCONTRACT_ORDER ->
                    id == null ? "/operations/workbench/subcontract" : "/subcontract/orders/" + id;
            case com.uten.imp.application.port.RdBomGapPort.SOURCE_SUBCONTRACT_APPLICATION ->
                    "/operations/workbench/subcontract";
            case com.uten.imp.application.port.RdBomGapPort.SOURCE_MATERIAL_ANALYSIS ->
                    id == null ? "/production/material-analysis"
                            : "/production/material-analysis?analysisId=" + id;
            case com.uten.imp.application.port.RdBomGapPort.SOURCE_PRODUCTION_PLAN ->
                    id == null ? "/production/plans" : "/production/plans/" + id;
            default -> "/production/material-analysis";
        };
    }

    /**
     * 委外件缺 BOM 新建「完善 BOM」研发任务(RdBomGapService 发，同一货品只在建任务时发一次)：
     * 通知工程研发部里能看研发任务的人。
     */
    public void notifyRdTaskForwarded(UUID taskId) {
        deliverAtomically(() -> {
            Map<String, Object> t = one("""
                    SELECT r.source_doc_no, g.code AS goods_code, g.name AS goods_name
                    FROM rd_tasks r LEFT JOIN goods g ON g.id = r.goods_id
                    WHERE r.id = ? AND r.is_deleted = false AND r.status IN ('OPEN','IN_PROGRESS')
                    """, taskId);
            if (t == null) return;
            String goodsLabel = com.uten.imp.application.port.RdBomGapPort.goodsLabel(
                    str(t.get("goods_name")), str(t.get("goods_code")));
            String sourceNo = str(t.get("source_doc_no")).strip();
            String content = goodsLabel + " 是委外件，还没有维护直属物料，计划和委外都在等。"
                    + (sourceNo.isEmpty() ? "" : "来源 " + sourceNo);
            for (UUID uid : departmentUserIdsWithAuthorities(
                    "DEPT_ENG", NOTICE_READ_AUTHORITY, "rd_task:view")) {
                sendToUser(uid, TYPE_TASK, "请完善 BOM：" + goodsLabel, content, "/rd/tasks");
            }
        });
    }

    /** 研发任务手动完成（RdTaskService.resolve 发）：通知制单人/转发人。 */
    public void notifyRdTaskResolved(UUID taskId) {
        deliverAtomically(() -> {
            Map<String, Object> t = one("""
                    SELECT r.title, r.reporter_employee_id, r.source_doc_type, r.source_doc_id,
                           g.code AS goods_code, g.name AS goods_name
                    FROM rd_tasks r LEFT JOIN goods g ON g.id = r.goods_id
                    WHERE r.id = ? AND r.is_deleted = false
                    """, taskId);
            if (t == null) return;
            UUID reporter = (UUID) t.get("reporter_employee_id");
            UUID uid = userIdOfEmployee(reporter);
            if (uid == null) return;
            String goodsLabel = com.uten.imp.application.port.RdBomGapPort.goodsLabel(
                    str(t.get("goods_name")), str(t.get("goods_code")));
            sendToUser(uid, TYPE_TASK,
                    "研发任务已完成：" + goodsLabel,
                    "工程研发部已标记完成：" + str(t.get("title")) + "。",
                    bomWaiterRoute(new RdTaskService.BomTaskWaiter(reporter,
                            (String) t.get("source_doc_type"), (UUID) t.get("source_doc_id"))));
        });
    }

    // ---------- Outbox 原子送达 ----------

    /** 只允许已锁定 Outbox 事件的处理事务执行真实通知写入。 */
    private void deliverAtomically(Runnable task) {
        requireOutboxDelivery();
        task.run();
    }

    private void requireOutboxDelivery() {
        if (!isOutboxDelivery()) {
            throw new IllegalStateException("Notice delivery must be invoked by the outbox processor");
        }
    }

    private boolean isOutboxDelivery() {
        return Boolean.TRUE.equals(OUTBOX_DELIVERY.get());
    }

    // ---------- 查询小工具 ----------

    private Map<String, Object> one(String sql, Object... args) {
        List<Map<String, Object>> rows = jdbc.queryForList(sql, args);
        return rows.isEmpty() ? null : rows.get(0);
    }

    private static String str(Object v) {
        return v == null ? "" : v.toString();
    }

    /** 将持久化的业务发生时间统一展示为 Asia/Shanghai，而不是通知异步投递时间。 */
    private static String businessEventTime(Object value) {
        if (value instanceof OffsetDateTime time) {
            return EVENT_TIME_FORMAT.format(time.atZoneSameInstant(BusinessTime.ZONE));
        }
        if (value instanceof Instant time) {
            return EVENT_TIME_FORMAT.format(time.atZone(BusinessTime.ZONE));
        }
        if (value instanceof java.sql.Timestamp time) {
            return EVENT_TIME_FORMAT.format(time.toInstant().atZone(BusinessTime.ZONE));
        }
        return str(value);
    }

    /**
     * 单值查询：SQL 只投影一列时取该列的值。{@link #one} 返回整行 {@code Map<String,Object>}，
     * 之前多处直接 {@code str(one(...))} 把整行 Map 的 toString()（如 {@code {bill_no=SJ26080016}}）
     * 拼进通知文案，用户能在通知卡片里看到裸的字段名（问题 #12）；改用本方法只取列值。
     */
    private String oneStr(String sql, Object... args) {
        Map<String, Object> row = one(sql, args);
        if (row == null || row.isEmpty()) return "";
        return str(row.values().iterator().next());
    }

    private static BigDecimal bd(Object v) {
        return v instanceof BigDecimal b ? b : BigDecimal.ZERO;
    }

    private static BigDecimal decimal(String value) {
        try {
            return value == null || value.isBlank()
                    ? BigDecimal.ZERO : new BigDecimal(value);
        } catch (NumberFormatException ignored) {
            return BigDecimal.ZERO;
        }
    }

    private static UUID uuidOrNull(String value) {
        try {
            return value == null || value.isBlank()
                    ? null : UUID.fromString(value);
        } catch (IllegalArgumentException ignored) {
            return null;
        }
    }

    private static String qty(BigDecimal v) {
        return v.stripTrailingZeros().toPlainString();
    }

    private record FinishedInboundSnapshot(
            UUID orderId,
            String orderBillNo,
            String documentNo,
            String goods,
            BigDecimal batchQty,
            BigDecimal producedQty,
            BigDecimal orderQty,
            String shipmentPolicy) {
        Map<String, String> payload() {
            return Map.of(
                    "orderId", orderId.toString(),
                    "orderBillNo", orderBillNo,
                    "documentNo", documentNo,
                    "goods", goods,
                    "batchQty", qty(batchQty),
                    "producedQty", qty(producedQty),
                    "orderQty", qty(orderQty),
                    "shipmentPolicy", shipmentPolicy);
        }
    }
}
