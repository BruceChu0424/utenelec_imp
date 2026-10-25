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
    /** Submitted and returned orders retain their source shares until explicitly canceled or deleted.
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
                JOIN (SELECT * FROM purchase_order_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('purchase_order_items',archive_origin.id)) oi ON oi.id=src.order_item_id AND NOT oi.is_deleted
                WHERE src.request_item_id=%s.id
                UNION ALL
                SELECT oi.qty,
                       CASE WHEN oi.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN COALESCE(oi.gift_qty,0) ELSE 0 END,
                       oi.order_id
                FROM (SELECT * FROM purchase_order_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('purchase_order_items',archive_origin.id)) oi
                WHERE oi.request_item_id=%s.id AND NOT oi.is_deleted
                  AND NOT EXISTS(SELECT 1 FROM purchase_order_item_sources src WHERE src.order_item_id=oi.id)
              ) part
              JOIN (SELECT * FROM purchase_orders archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('purchase_orders',archive_origin.id)) o ON o.id=part.order_id
              WHERE o.status = 0 AND o.is_deleted = FALSE
                AND fn_procurement_order_reserves_source('PURCHASE', o.id)
            ) pending ON TRUE
            """.formatted(alias,alias);
    }
    private static BigDecimal zero(BigDecimal value) { return value==null?BigDecimal.ZERO:value; }
}
