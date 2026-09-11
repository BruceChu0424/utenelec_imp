package com.uten.imp.features.notice;

import java.util.Map;
import java.util.Optional;

/**
 * 可行动待办弹卡事件目录（V459 配套，ADR-063；V470 扩展车间任务）。
 *
 * <p>注册后的 source_event 视为「可操作行动卡」：到达链弹带双按钮（去办理/稍后再看）
 * 的非阻塞卡片，通知 DTO 的 {@code interactive=true}；弹卡与收件台按
 * aggregate 定位查认领状态（他人正在审核）与办结撤回（已办结不弹）。
 *
 * <p>注册项声明：sourceEvent → (聚合类型, 任务认领 targetType)。targetKey 统一为
 * aggregateId 字符串。新增业务线接线时在 {@link #ENTRIES} 登记一行，前端无需感知
 * 事件清单（靠 DTO 的 interactive 标志与 claim 状态接口）。
 */
public final class ReviewNoticeCatalog {

    /** sourceEvent → 注册项。 */
    private static final Map<String, Entry> ENTRIES = Map.ofEntries(
            Map.entry("SALES_SHIPMENT_PENDING_FINANCE_AUDIT",new Entry("SALES_SHIPMENT","SALES_SHIPMENT_FINANCE_AUDIT")),
            Map.entry("SALES_SHIPMENT_PENDING_PICK",new Entry("SALES_SHIPMENT",null)),
            Map.entry("SALES_SHIPMENT_FINANCE_REJECTED",new Entry("SALES_SHIPMENT",null)),
            Map.entry("DIRECT_CUSTOMER_SHIPMENT_FINANCE_REJECTED",new Entry("SALES_SHIPMENT",null)),
            // P0 三线（V459 批次接线；事件名与 ChainNoticeService 现有常量一致，
            // 保证 unread-count-by-source 等既有统计口径不变）：
            // 销售订单审核后 → 财务确认（V294/V300，SalesOrderFinanceConfirmer 资格池）
            Map.entry(
                    "SALES_ORDER_PENDING_FINANCE_CONFIRM",
                    new Entry("SALES_ORDER", "SALES_ORDER_FINANCE_CONFIRM")),
            // 采购/委外订货 → 财务审批（V196 审批 case）
            Map.entry(
                    "PROCUREMENT_FINANCE_SUBMITTED",
                    new Entry("PROCUREMENT_APPROVAL_CASE", "PROCUREMENT_FINANCE_APPROVE")),
            // 到货 IQC 待检处置（仓库审核收货后）
            Map.entry(
                    "PROCUREMENT_IQC_PENDING",
                    new Entry("IQC_INSPECTION", "IQC_INSPECT")),
            // 订单生产全部完工 → 通知负责销售可发货（归属人定向，无 claim）
            Map.entry(
                    "SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP",
                    new Entry("SALES_ORDER", null)),
            // 新订单待物料分析（财务确认后广播计划部）。生产部创建物料分析
            // 即按 (SALES_ORDER, orderId) 办结撤回（无排他认领，2026-09-05
            // 补办结闭环：此前无聚合计绑定，通知永不办结）。
            Map.entry(
                    "SALES_ORDER_APPROVED",
                    new Entry("SALES_ORDER", null)),
            // 生产计划下达、待料转齐套和仓库实发共用同一执行段任务。
            // 无排他认领：同一车间可协作办理。办结点（2026-09-10 修正）：
            // 车间开工（START）即按段办结；完工入库（段 COMPLETED）兜底办结；
            // 取消/红冲、清空车间、换车间重投时也按段办结。报工本身不办结。
            Map.entry(
                    "PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED",
                    new Entry("PRODUCTION_EXECUTION_SEGMENT", null)),
            // ===== 2026-09-05 全链弹窗补齐（用户口径：每个「该谁干活」的节点
            // 都要有居中行动卡；办结动作后按聚合撤回）=====
            // 品质放行 → 仓库确认入库（每个 PASS 切片一张卡；该切片全部入库即办结）
            Map.entry(
                    "PROCUREMENT_IQC_STOCK_IN_PENDING",
                    new Entry("PROCUREMENT_INSPECTION_PASS", null)),
            // 计划部领料单 → 仓库出库（DRAW 单据级；实际出库后办结）
            Map.entry(
                    "PRODUCTION_DRAW_PENDING",
                    new Entry("STOCK_DOCUMENT", null)),
            // 财务批准 → 仓库预计到货（订单级；到货全部登记完/CLOSED 即办结）
            Map.entry(
                    "PROCUREMENT_FINANCE_APPROVED",
                    new Entry("PROCUREMENT_ORDER", null)),
            // 委外前置自制待启动（计划行级；目标件真实出仓后办结）
            Map.entry(
                    "SUBCONTRACT_PREPARATION_REQUIRED",
                    new Entry("SUBCONTRACT_MATERIAL_PLAN_ITEM", null)),
            // ===== 2026-09-05 委外收敛 + IQC/改量通知补齐 =====
            // 直接下单有子层目标件：草稿期自动发单给计划（分析级；完工入库后办结）
            Map.entry(
                    "SUBCONTRACT_ORDER_PREPARATION_DISPATCHED",
                    new Entry("MATERIAL_ANALYSIS", null)),
            // IQC 不合格建案 → 仓库/订单归属人登记实物退回（case 级；
            // 贷项确认/无贷项结案/反向时撤卡）
            Map.entry(
                    "PROCUREMENT_IQC_REJECTION_OPENED",
                    new Entry("IQC_REJECTION_CASE", null)),
            // 实物退回已登记 → 财务确认贷项或无贷项结案（case 级；同上撤卡）
            Map.entry(
                    "PROCUREMENT_IQC_REJECTION_RETURNED",
                    new Entry("IQC_REJECTION_CASE", null)),
            // 财务批准后改量 → 重回财务复核队列（case 级；复核通过/驳回时撤卡）
            Map.entry(
                    "PROCUREMENT_FINANCE_CHANGE_SUBMITTED",
                    new Entry("PROCUREMENT_APPROVAL_CASE", "PROCUREMENT_FINANCE_APPROVE")),
            // ===== 2026-09-09 人事域弹卡接入（HrNoticeService；接收人=职能权限池，
            // 不限部门——ADR-063 明示例外）=====
            // 员工提交信息变更 → HR 审核（批次级；批准/驳回/员工撤销时撤卡）
            Map.entry(
                    "PROFILE_CHANGE_SUBMITTED",
                    new Entry("PROFILE_CHANGE", null)),
            // 访客申请 → HR 审批（申请级；终态时撤卡）
            Map.entry(
                    "VISITOR_APPLY_SUBMITTED",
                    new Entry("VISITOR_APPLICATION", null)),
            // HR 转接待人 → 被访人确认接待。独立聚合（2026-09-10）：接待人确认后申请
            // 回到 HR 批准，HR 卡须继续有效，故不能与 VISITOR_APPLICATION 同 kind；
            // 接待人确认/拒绝、HR 批准/驳回均撤本卡。
            Map.entry(
                    "VISITOR_HOST_CONFIRM_REQUIRED",
                    new Entry("VISITOR_HOST_CONFIRM", null)),
            // 报销提交 → 审批人（单级；终态/撤回时撤卡）。claim 与
            // ExpenseClaimService 的 EXPENSE_APPROVE/targetKey=claimId 对齐，
            // 弹窗显示「XX 正在审核」。
            Map.entry(
                    "EXPENSE_CLAIM_SUBMITTED",
                    new Entry("EXPENSE_CLAIM", "EXPENSE_APPROVE")),
            // 报销审批通过 → 打款人接棒（单级；打款/撤回时撤卡）
            Map.entry(
                    "EXPENSE_CLAIM_PENDING_PAYMENT",
                    new Entry("EXPENSE_CLAIM", null)),
            // 工资批次提交 → 审核人（批次级；审毕时撤卡）
            Map.entry(
                    "PAYROLL_BATCH_SUBMITTED",
                    new Entry("PAYROLL_BATCH", null)),
            // 工资批次审核通过 → 发布人接棒（批次级；发布时撤卡；2026-09-10）
            Map.entry(
                    "PAYROLL_BATCH_PENDING_PUBLISH",
                    new Entry("PAYROLL_BATCH", null)),
            // 建议箱提交 → 回复人（建议级；回复推进到 resolved/rejected 时撤卡；2026-09-10）
            Map.entry(
                    "SUGGESTION_SUBMITTED",
                    new Entry("SUGGESTION", null)));

    private ReviewNoticeCatalog() {
    }

    /** 全部注册事件（登录检查/待办查询用）。 */
    public static java.util.Set<String> events() {
        return ENTRIES.keySet();
    }

    public static boolean isReviewEvent(String sourceEvent) {
        return sourceEvent != null && ENTRIES.containsKey(sourceEvent);
    }

    public static Optional<Entry> of(String sourceEvent) {
        return Optional.ofNullable(sourceEvent).map(ENTRIES::get);
    }

    /** aggregateKind：办结撤回与收件台按 (kind,id) 定位；claimType：null=归属人线无认领。 */
    public record Entry(String aggregateKind, String claimTargetType) {
    }
}
