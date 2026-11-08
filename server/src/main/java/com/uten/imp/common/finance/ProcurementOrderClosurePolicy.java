package com.uten.imp.common.finance;

import jakarta.persistence.EntityManager;

import java.util.Collection;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Recalculates closure from net warehouse stock-in plus separately accepted subcontract loss. */
public final class ProcurementOrderClosurePolicy {

    public static final String PURCHASE = "PURCHASE";
    public static final String SUBCONTRACT = "SUBCONTRACT";

    private ProcurementOrderClosurePolicy() {
    }

    public static void recalculate(
            EntityManager em, String rawOrderType, UUID orderItemId) {
        if (orderItemId == null) return;
        recalculateItems(em, rawOrderType, List.of(orderItemId));
    }

    /** One receipt may contain many items of the same order; update each order only once. */
    public static void recalculateReceipt(EntityManager em, String rawOrderType, UUID receiptId) {
        recalculateReceipts(em, rawOrderType, receiptId == null ? List.of() : List.of(receiptId));
    }

    /**
     * W6-E (2026-11-08)：整份检验报告按订单去重一次重算——多张收货单可能指向同一张
     * 订货单，闭包值对同一订单是幂等的，逐单重算只是重复的全量相关子查询。订单集合先
     * DISTINCT，UPDATE 只写值真的变化的行（is_closed IS DISTINCT FROM computed），
     * 无值变化的行不再产生空 UPDATE（行版本、审计触发器与锁都不再空转）。
     */
    public static void recalculateReceipts(EntityManager em, String rawOrderType, Collection<UUID> receiptIds) {
        List<UUID> sources = receiptIds == null ? List.of() : receiptIds.stream()
                .filter(Objects::nonNull).distinct().sorted().toList();
        if (sources.isEmpty()) return;
        recalculateCore(em, rawOrderType, "("
                + "SELECT DISTINCT item.order_id FROM %receipt_item% receipt_item"
                + " JOIN %order_item% item ON item.id=receipt_item.order_item_id"
                + " WHERE receipt_item.receipt_id IN (:sourceIds)"
                + " AND COALESCE(receipt_item.is_deleted,FALSE)=FALSE)", sources);
    }

    private static void recalculateItems(EntityManager em, String rawOrderType, Collection<UUID> orderItemIds) {
        List<UUID> sources = orderItemIds == null ? List.of() : orderItemIds.stream()
                .filter(Objects::nonNull).distinct().sorted().toList();
        if (sources.isEmpty()) return;
        recalculateCore(em, rawOrderType, "("
                + "SELECT order_item.order_id FROM %order_item% order_item"
                + " WHERE order_item.id IN (:sourceIds))", sources);
    }

    /** [ordersSql] must select exactly one column of order ids bound to :sourceIds. */
    private static void recalculateCore(EntityManager em, String rawOrderType, String ordersSql, List<UUID> sourceIds) {
        String orderType = rawOrderType == null ? "" : rawOrderType.strip().toUpperCase();
        String orderTable;
        String orderItemTable;
        String receiptItemTable;
        String receiptTable;
        if (PURCHASE.equals(orderType)) {
            orderTable = "purchase_orders";
            orderItemTable = "purchase_order_items";
            receiptItemTable = "purchase_receipt_items";
            receiptTable = "purchase_receipts";
        } else if (SUBCONTRACT.equals(orderType)) {
            orderTable = "subcontract_orders";
            orderItemTable = "subcontract_order_items";
            receiptItemTable = "subcontract_receipt_items";
            receiptTable = "subcontract_receipts";
        } else {
            throw new IllegalArgumentException("unsupported procurement order type: " + rawOrderType);
        }
        String settledOrderQty = SUBCONTRACT.equals(orderType)
                ? " + " + SubcontractLossSettlementSql.acceptedLossQty("order_item.id") : "";
        String settledBaseQty = SUBCONTRACT.equals(orderType)
                ? settledOrderQty + " * COALESCE(order_item.unit_rate,0)" : "";
        em.createNativeQuery("""
                WITH candidate_orders AS MATERIALIZED (
                    SELECT DISTINCT orders.order_id AS order_id
                    FROM %6$s orders
                ), closure AS MATERIALIZED (
                    SELECT order_doc.id AS order_id,
                           order_doc.termination_case_id IS NOT NULL OR (
                               SELECT COALESCE(bool_and(
                                   CASE WHEN %1$s THEN
                                       fn_purchase_order_tranche_stocked_qty(order_item.id,'CHARGED')
                                           - COALESCE(order_item.returned_qty,0) >= COALESCE(order_item.qty,0)
                                   WHEN EXISTS (
                                       SELECT 1
                                       FROM %2$s receipt_item
                                       JOIN %3$s receipt_doc ON receipt_doc.id=receipt_item.receipt_id
                                       WHERE receipt_item.order_item_id = order_item.id
                                         AND receipt_doc.status=1
                                         AND COALESCE(receipt_doc.is_deleted,FALSE)=FALSE
                                         AND COALESCE(receipt_item.is_deleted,FALSE)=FALSE
                                   ) THEN
                                       COALESCE((
                                           SELECT SUM(
                                               CASE
                                                   WHEN inspection.id IS NULL
                                                       THEN receipt_item.qty*COALESCE(receipt_item.unit_rate,1)
                                                   WHEN inspection.status='REVERSED' THEN 0
                                                   ELSE inspection.warehouse_stocked_base_qty
                                               END)
                                           FROM %2$s receipt_item
                                           JOIN %3$s receipt_doc ON receipt_doc.id=receipt_item.receipt_id
                                           LEFT JOIN procurement_inspection_items inspection
                                             ON inspection.receipt_type=:receiptType
                                            AND inspection.receipt_item_id=receipt_item.id AND inspection.quantity_tranche<>'GIFT'
                                           WHERE receipt_item.order_item_id = order_item.id
                                             AND receipt_doc.status=1
                                             AND COALESCE(receipt_doc.is_deleted,FALSE)=FALSE
                                             AND COALESCE(receipt_item.is_deleted,FALSE)=FALSE
                                       ),0)
                                       - COALESCE(order_item.returned_qty,0)
                                           * COALESCE(order_item.unit_rate,1)%4$s
                                       >= COALESCE(order_item.qty,0)
                                           * COALESCE(order_item.unit_rate,1)
                                   ELSE
                                       COALESCE(order_item.received_qty,0)
                                           - COALESCE(order_item.returned_qty,0)%5$s
                                           >= COALESCE(order_item.qty,0)
                                   END %7$s
                               ),TRUE)
                               FROM %8$s order_item
                               WHERE order_item.order_id = order_doc.id
                                 AND COALESCE(order_item.is_deleted,FALSE)=FALSE
                           ) AS is_closed
                    FROM %9$s order_doc
                    WHERE order_doc.id IN (SELECT order_id FROM candidate_orders)
                )
                UPDATE %9$s order_doc
                SET is_closed = closure.is_closed
                FROM closure
                WHERE order_doc.id = closure.order_id
                  AND order_doc.is_closed IS DISTINCT FROM closure.is_closed
                """.formatted(
                        PURCHASE.equals(orderType) ? "order_item.quantity_semantics='CHARGED_PLUS_GIFT_V1'" : "FALSE",
                        receiptItemTable,
                        receiptTable,
                        settledBaseQty,
                        settledOrderQty,
                        ordersSql.replace("%receipt_item%", receiptItemTable).replace("%order_item%", orderItemTable),
                        PURCHASE.equals(orderType) ? """
                            AND (order_item.quantity_semantics='LEGACY_RECORDED' OR
                                fn_purchase_order_tranche_stocked_qty(order_item.id,'GIFT')
                                    - order_item.gift_returned_qty >= order_item.gift_qty)
                            """ : "",
                        orderItemTable,
                        orderTable))
                .setParameter("receiptType", orderType)
                .setParameter("sourceIds", sourceIds)
                .executeUpdate();
    }
}
