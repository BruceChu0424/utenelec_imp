package com.uten.imp.features.notice;

import java.util.Map;
import java.util.Optional;

/**
 * 审核待办弹卡事件目录（V459 配套，ADR-063）。
 *
 * <p>注册后的 source_event 视为「可操作审核卡」：到达链弹带双按钮（去审核/稍后再看）
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
            // P0 三线（V459 批次接线）：
            // 销售订单审核后 → 财务确认（V294/V300，SalesOrderFinanceConfirmer 资格池）
            Map.entry(
                    "ORDER_PENDING_FINANCE_CONFIRMATION",
                    new Entry("SALES_ORDER", "SALES_ORDER_FINANCE_CONFIRM")),
            // 采购/委外订货 → 财务审批（V196 审批 case）
            Map.entry(
                    "PROCUREMENT_ORDER_APPROVAL_PENDING",
                    new Entry("PROCUREMENT_APPROVAL_CASE", "PROCUREMENT_FINANCE_APPROVE")),
            // 到货 IQC 待检处置
            Map.entry(
                    "PROCUREMENT_IQC_PENDING_INSPECTION",
                    new Entry("IQC_INSPECTION", "IQC_INSPECT")),
            // 订单生产全部完工 → 通知负责销售可发货（归属人定向，无 claim）
            Map.entry(
                    "SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP",
                    new Entry("SALES_ORDER", null)));

    private ReviewNoticeCatalog() {
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
