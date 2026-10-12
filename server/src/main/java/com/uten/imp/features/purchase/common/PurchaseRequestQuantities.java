package com.uten.imp.features.purchase.common;

import com.uten.imp.common.finance.ProcurementQuantities;
import java.math.BigDecimal;

/** The material need is physical; paid and free commitments remain separate facts. */
public final class PurchaseRequestQuantities {
    private PurchaseRequestQuantities() { }
    public record Remaining(BigDecimal physicalRequired, BigDecimal physicalOrdered,
            BigDecimal physicalPending, BigDecimal physicalRemaining,
            BigDecimal chargedRemaining, BigDecimal giftRemaining) { }
    public static Remaining remaining(String semantics, BigDecimal chargedNeed, BigDecimal giftNeed,
            BigDecimal chargedOrdered, BigDecimal giftOrdered,
            BigDecimal chargedPending, BigDecimal giftPending) {
        BigDecimal promisedGift=ProcurementQuantities.isExtraGift(semantics)?zero(giftNeed):BigDecimal.ZERO;
        BigDecimal required=zero(chargedNeed).add(promisedGift);
        BigDecimal ordered=zero(chargedOrdered).add(zero(giftOrdered));
        BigDecimal pending=zero(chargedPending).add(zero(giftPending));
        BigDecimal physical=required.subtract(ordered).subtract(pending).max(BigDecimal.ZERO);
        BigDecimal free=promisedGift.subtract(zero(giftOrdered)).subtract(zero(giftPending))
                .max(BigDecimal.ZERO).min(physical);
        return new Remaining(required,ordered,pending,physical,physical.subtract(free),free);
    }
    public static String requiredSql(String alias) {
        return "(COALESCE("+alias+".qty,0)+CASE WHEN "+alias+".quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN COALESCE("+alias+".gift_qty,0) ELSE 0 END)";
    }
    public static String orderedSql(String alias) {
        return "(COALESCE("+alias+".ordered_qty,0)+COALESCE("+alias+".gift_ordered_qty,0))";
    }
    /** Pending financial orders retain their physical source shares until a decision.
     * Includes both modern source shares and historical single-anchor rows, exactly once. */
    public static String pendingJoin(String alias) {
        return """
            LEFT JOIN LATERAL (
              SELECT COALESCE(SUM(part.qty),0) AS pending_qty,
                     COALESCE(SUM(part.gift_qty),0) AS pending_gift_qty,
                     COALESCE(SUM(part.qty+part.gift_qty),0) AS pending_physical_qty
              FROM (
                SELECT src.alloc_qty AS qty,
                       CASE WHEN oi.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN COALESCE(src.allocated_gift_qty,0) ELSE 0 END AS gift_qty,
                       oi.order_id
                FROM purchase_order_item_sources src
                JOIN purchase_order_items oi ON oi.id=src.order_item_id AND NOT oi.is_deleted
                WHERE src.request_item_id=%s.id
                UNION ALL
                SELECT oi.qty,
                       CASE WHEN oi.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN COALESCE(oi.gift_qty,0) ELSE 0 END,
                       oi.order_id
                FROM purchase_order_items oi
                WHERE oi.request_item_id=%s.id AND NOT oi.is_deleted
                  AND NOT EXISTS(SELECT 1 FROM purchase_order_item_sources src WHERE src.order_item_id=oi.id)
              ) part
              JOIN purchase_orders o ON o.id=part.order_id
              WHERE o.status = 0 AND o.is_deleted = FALSE
                AND EXISTS(SELECT 1 FROM procurement_order_approval_cases approval
                    WHERE approval.order_type='PURCHASE' AND approval.order_id=o.id AND approval.status = 'PENDING')
            ) pending ON TRUE
            """.formatted(alias,alias);
    }
    private static BigDecimal zero(BigDecimal value) { return value==null?BigDecimal.ZERO:value; }
}
