package com.uten.imp.features.subcontract.receipt;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 委外回厂约束的唯一 Java 读取口(ADR-143 §三.6)。
 *
 * <p>累计回厂(订货单位，折成基本单位比较) ≤ 委外商处物料可做成的完整套数
 * {@code fn_subcontract_returnable_qty}(各种物料取最小，不相加) + 财务批准的委外商自带料
 * + 已退回委外商的来料质检不合格量。已批准的委外订货明细一定有冻结计划行(缺 BOM 的委外件
 * 不能下单，ADR-143 §二.3)；万一没有计划行，可做套数按 0 计(只认财务批准与质检退回额度)。
 *
 * <p>回厂草稿保存、回厂审核、发料红冲共用这一段 SQL；读取时按订货明细 id 顺序加行锁，
 * 与发料审核(订货明细 → 计划行)同一锁序。
 */
public final class SubcontractReturnCapacity {

    private SubcontractReturnCapacity() {
    }

    /** 一条订货明细的回厂额度事实(基本单位)。 */
    public record Facts(
            UUID orderItemId,
            BigDecimal unitRate,
            BigDecimal returnableBase,
            BigDecimal returnedFailureBase,
            BigDecimal approvedSupplierOwnBase,
            BigDecimal approvedReceiptBase,
            BigDecimal activeDraftBase) {

        /** 允许的累计回厂上限(基本单位)。 */
        public BigDecimal authorizedBase() {
            return returnableBase.add(returnedFailureBase).add(approvedSupplierOwnBase);
        }
    }

    /**
     * 锁定并读取订货明细的回厂额度。{@code excludedReceiptId} 非空时，已审回厂与回厂草稿
     * 都不计该单(审核本单 / 改写本单草稿时用)。
     */
    public static Map<UUID, Facts> lockAndRead(
            EntityManager em, Collection<UUID> orderItemIds, UUID excludedReceiptId) {
        List<UUID> ids = orderItemIds == null ? List.of()
                : orderItemIds.stream().filter(Objects::nonNull).distinct().sorted().toList();
        if (ids.isEmpty()) return Map.of();
        String approvedExclusion = excludedReceiptId == null
                ? "" : " AND receipt_item.receipt_id <> :excludedReceiptId";
        String draftExclusion = excludedReceiptId == null
                ? "" : " AND draft.id <> :excludedReceiptId";
        var query = em.createNativeQuery("""
                SELECT order_item.id,
                       COALESCE(order_item.unit_rate, 1) AS order_unit_rate,
                       COALESCE(fn_subcontract_returnable_qty(order_item.id), 0)
                           * COALESCE(order_item.unit_rate, 1) AS returnable_base,
                       COALESCE((
                           SELECT SUM(rejection.failed_base_qty)
                           FROM procurement_iqc_rejection_cases rejection
                           WHERE rejection.receipt_type = 'SUBCONTRACT'
                             AND rejection.order_item_id = order_item.id
                             AND rejection.is_deleted = FALSE
                             AND rejection.return_recorded_at IS NOT NULL
                             AND rejection.status IN (
                                 'RETURN_RECORDED','CREDIT_CONFIRMED',
                                 'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                       ), 0) AS returned_failure_base,
                       COALESCE((
                           SELECT SUM(exception_row.approved_excess_qty
                                   * COALESCE(order_item.unit_rate, 1))
                           FROM procurement_arrival_exceptions exception_row
                           WHERE exception_row.order_type = 'SUBCONTRACT'
                             AND exception_row.order_item_id = order_item.id
                             AND exception_row.status IN (
                                 'RECEIPT_ADJUSTED', 'RECEIPT_POSTED', 'CLOSED')
                             AND exception_row.decision IN ('APPROVE_ALL', 'APPROVE_CUSTOM')
                             AND exception_row.approved_excess_qty > 0
                       ), 0) AS approved_supplier_own_base,
                       COALESCE((
                           SELECT SUM(receipt_item.qty * COALESCE(receipt_item.unit_rate, 1))
                           FROM subcontract_receipt_items receipt_item
                           JOIN subcontract_receipts receipt
                             ON receipt.id = receipt_item.receipt_id
                            AND receipt.status = 1
                            AND receipt.is_deleted = FALSE
                           WHERE receipt_item.order_item_id = order_item.id
                             AND receipt_item.is_deleted = FALSE
                """ + approvedExclusion + """
                       ), 0) AS approved_receipt_base,
                       COALESCE((
                           SELECT SUM(draft_item.qty * COALESCE(draft_item.unit_rate, 1))
                           FROM subcontract_receipt_items draft_item
                           JOIN subcontract_receipts draft
                             ON draft.id = draft_item.receipt_id
                            AND draft.status = 0 AND draft.legacy_id IS NULL
                            AND draft.is_deleted = FALSE
                           WHERE draft_item.order_item_id = order_item.id
                             AND draft_item.is_deleted = FALSE
                """ + draftExclusion + """
                       ), 0) AS active_draft_base
                FROM subcontract_order_items order_item
                WHERE order_item.id IN (:orderItemIds)
                  AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                ORDER BY order_item.id
                FOR UPDATE OF order_item
                """).setParameter("orderItemIds", ids);
        if (excludedReceiptId != null) {
            query.setParameter("excludedReceiptId", excludedReceiptId);
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.getResultList();
        if (rows.size() != ids.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "委外回厂来源订货明细不存在或已删除");
        }
        Map<UUID, Facts> facts = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID id = (UUID) row[0];
            facts.put(id, new Facts(id, decimal(row[1]), decimal(row[2]), decimal(row[3]),
                    decimal(row[4]), decimal(row[5]), decimal(row[6])));
        }
        return facts;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }
}
