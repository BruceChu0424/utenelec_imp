package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.UUID;
import java.util.Collection;

/** Physical receipt bounds shared by approved purchase/subcontract quantity revisions.
 * Callers hold the order header before reading these facts and keep it through the revision.
 * Expectation OPEN/CLOSED is presentation state, never authority for physical quantities.
 */
public final class ProcurementOrderQuantityBounds {
    private ProcurementOrderQuantityBounds() {}

    /** Legacy inconsistent target-unit facts require their original reversal path, never a guessed rewrite. */
    public static void requireConsistentTargetBasis(EntityManager em,Collection<UUID> orderItemIds) {
        if(orderItemIds.isEmpty()) return;
        var issues=em.createNativeQuery("""
                SELECT problem.plan_item_id FROM v_subcontract_quantity_basis_issues problem
                JOIN subcontract_material_plan_items pi ON pi.id=problem.plan_item_id
                WHERE problem.order_item_id IN (:ids)
                  AND (pi.is_deleted=FALSE OR problem.effective_issue_basis_inconsistent)
                ORDER BY problem.plan_item_id LIMIT 1
                """).setParameter("ids",orderItemIds).getResultList();
        if(!issues.isEmpty()) throw new ApiException(ErrorCode.CONFLICT,
                "历史委外目标件的基本单位与冻结换算率不一致，请先核对原出回仓记录并执行对应反向，不能继续累计数量");
    }

    public record ReceiptBound(BigDecimal retainedBase, BigDecimal postedExcessBase) {
        public BigDecimal minimumOrderedQty(BigDecimal orderUnitRate) {
            return retainedBase.subtract(postedExcessBase).max(BigDecimal.ZERO)
                    .divide(orderUnitRate,4,RoundingMode.CEILING);
        }
    }

    public static ReceiptBound receipts(EntityManager em, String orderType, UUID itemId) {
        String prefix=prefix(orderType);
        Object[] row=(Object[])em.createNativeQuery("""
                SELECT GREATEST(COALESCE(oi.received_qty,0)*COALESCE(oi.unit_rate,1),
                           COALESCE(facts.received_base,0)),
                       GREATEST(COALESCE(oi.returned_qty,0)*COALESCE(oi.unit_rate,1),
                           COALESCE(facts.returned_base,0)),
                       COALESCE(facts.iqc_returned_base,0), COALESCE(facts.excess_base,0)
                FROM %1$s_order_items oi
                LEFT JOIN LATERAL (
                    SELECT SUM(ri.qty*COALESCE(ri.unit_rate,1)) AS received_base,
                           SUM(COALESCE(returns.qty_base,0)) AS returned_base,
                           SUM(COALESCE(iqc.qty_base,0)) AS iqc_returned_base,
                           SUM(LEAST(COALESCE(excess.qty_base,0), GREATEST(
                               ri.qty*COALESCE(ri.unit_rate,1)-COALESCE(returns.qty_base,0)
                                   -COALESCE(iqc.qty_base,0),0))) AS excess_base
                    FROM %1$s_receipt_items ri
                    JOIN %1$s_receipts receipt ON receipt.id=ri.receipt_id
                      AND receipt.status=1 AND receipt.is_deleted=FALSE
                    LEFT JOIN LATERAL (
                        SELECT SUM(ret.qty*COALESCE(ret.unit_rate,1)) AS qty_base
                        FROM %1$s_return_items ret JOIN %1$s_returns rh ON rh.id=ret.return_id
                        WHERE ret.receipt_item_id=ri.id AND ret.order_item_id=oi.id
                          AND ret.is_deleted=FALSE AND rh.status=1 AND rh.is_deleted=FALSE
                    ) returns ON TRUE
                    LEFT JOIN LATERAL (
                        SELECT SUM(rejection.failed_base_qty) AS qty_base
                        FROM procurement_iqc_rejection_cases rejection
                        WHERE rejection.receipt_type=:orderType AND rejection.receipt_id=receipt.id
                          AND rejection.receipt_item_id=ri.id AND rejection.order_item_id=oi.id
                          AND rejection.is_deleted=FALSE AND rejection.return_recorded_at IS NOT NULL
                          AND rejection.status IN ('RETURN_RECORDED','CREDIT_CONFIRMED',
                              'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                    ) iqc ON TRUE
                    LEFT JOIN LATERAL (
                        SELECT SUM(exception.approved_excess_qty*COALESCE(ri.unit_rate,1)) AS qty_base
                        FROM procurement_arrival_exceptions exception
                        WHERE exception.order_type=:orderType AND exception.order_item_id=oi.id
                          AND exception.receipt_id=receipt.id AND exception.receipt_item_id=ri.id
                          AND exception.status IN ('RECEIPT_POSTED','CLOSED')
                    ) excess ON TRUE
                    WHERE ri.order_item_id=oi.id AND ri.is_deleted=FALSE
                ) facts ON TRUE
                WHERE oi.id=:itemId AND oi.is_deleted=FALSE
                """.formatted(prefix)).setParameter("orderType",orderType)
                .setParameter("itemId",itemId).getSingleResult();
        // Imported aggregate-only history remains a conservative lower bound; do not silently
        // discard recorded receipts because a legacy detail is unavailable. Replacement receipts
        // are already in received_base. Their allocation ledger must not be subtracted a second time.
        BigDecimal retained=decimal(row[0]).subtract(decimal(row[1])).subtract(decimal(row[2])).max(BigDecimal.ZERO);
        return new ReceiptBound(retained,decimal(row[3]).min(retained));
    }

    /** Set the active expectation from current order capacity, including CLOSED rows on increase. */
    public static void synchronizeExpectation(EntityManager em, String orderType, UUID itemId,
                                              BigDecimal orderedQty, BigDecimal orderUnitRate,
                                              ReceiptBound bound) {
        String prefix=prefix(orderType);
        em.createNativeQuery("""
                UPDATE inbound_expectation_items item
                SET ordered_qty=ROUND((:orderedBase + oi.arrival_overage_posted_qty*COALESCE(oi.unit_rate,1))
                                         / item.unit_rate,4),
                    accepted_qty=LEAST(ROUND(:retainedBase/item.unit_rate,4),
                        ROUND((:orderedBase + oi.arrival_overage_posted_qty*COALESCE(oi.unit_rate,1))
                                         / item.unit_rate,4)), updated_at=now()
                FROM inbound_expectations header, %s_order_items oi
                WHERE item.expectation_id=header.id AND header.order_type=:orderType
                  AND header.status IN ('OPEN','CLOSED') AND item.order_item_id=:itemId AND oi.id=item.order_item_id
                """.formatted(prefix)).setParameter("orderedBase",orderedQty.multiply(orderUnitRate))
                .setParameter("retainedBase",bound.retainedBase()).setParameter("orderType",orderType)
                .setParameter("itemId",itemId).executeUpdate();
        em.createNativeQuery("""
                UPDATE inbound_expectations header
                SET status=CASE WHEN EXISTS(SELECT 1 FROM inbound_expectation_items item
                    WHERE item.expectation_id=header.id AND item.accepted_qty<item.ordered_qty)
                    THEN 'OPEN' ELSE 'CLOSED' END,updated_at=now()
                WHERE header.order_type=:orderType AND header.status IN ('OPEN','CLOSED')
                  AND EXISTS(SELECT 1 FROM inbound_expectation_items item
                      WHERE item.expectation_id=header.id AND item.order_item_id=:itemId)
                """).setParameter("orderType",orderType).setParameter("itemId",itemId).executeUpdate();
    }

    private static String prefix(String orderType) {
        return switch(orderType) {
            case "PURCHASE" -> "purchase";
            case "SUBCONTRACT" -> "subcontract";
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED,"未知采购订单类型");
        };
    }
    private static BigDecimal decimal(Object value) { return value==null ? BigDecimal.ZERO : (BigDecimal)value; }
}
