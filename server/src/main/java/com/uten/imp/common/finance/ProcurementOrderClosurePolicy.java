package com.uten.imp.common.finance;

import jakarta.persistence.EntityManager;

import java.util.UUID;

/** Recalculates purchase/subcontract order closure from warehouse-stocked, net-returned quantity. */
public final class ProcurementOrderClosurePolicy {

    public static final String PURCHASE = "PURCHASE";
    public static final String SUBCONTRACT = "SUBCONTRACT";

    private ProcurementOrderClosurePolicy() {
    }

    public static void recalculate(
            EntityManager em, String rawOrderType, UUID orderItemId) {
        if (orderItemId == null) return;
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
        em.createNativeQuery("""
                UPDATE %s order_doc
                SET is_closed = (
                    SELECT COALESCE(bool_and(
                        CASE WHEN EXISTS (
                            SELECT 1
                            FROM %s receipt_item
                            JOIN %s receipt_doc ON receipt_doc.id=receipt_item.receipt_id
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
                                FROM %s receipt_item
                                JOIN %s receipt_doc ON receipt_doc.id=receipt_item.receipt_id
                                LEFT JOIN procurement_inspection_items inspection
                                  ON inspection.receipt_type=:receiptType
                                 AND inspection.receipt_item_id=receipt_item.id
                                WHERE receipt_item.order_item_id = order_item.id
                                  AND receipt_doc.status=1
                                  AND COALESCE(receipt_doc.is_deleted,FALSE)=FALSE
                                  AND COALESCE(receipt_item.is_deleted,FALSE)=FALSE
                            ),0)
                            - COALESCE(order_item.returned_qty,0)
                                * COALESCE(order_item.unit_rate,1)
                            >= COALESCE(order_item.qty,0)
                                * COALESCE(order_item.unit_rate,1)
                        ELSE
                            COALESCE(order_item.received_qty,0)
                                - COALESCE(order_item.returned_qty,0)
                                >= COALESCE(order_item.qty,0)
                        END
                    ),TRUE)
                    FROM %s order_item
                    WHERE order_item.order_id = order_doc.id
                      AND COALESCE(order_item.is_deleted,FALSE)=FALSE
                )
                WHERE order_doc.id = (
                    SELECT order_id FROM %s WHERE id=:orderItemId)
                """.formatted(
                        orderTable,
                        receiptItemTable,
                        receiptTable,
                        receiptItemTable,
                        receiptTable,
                        orderItemTable,
                        orderItemTable))
                .setParameter("receiptType", orderType)
                .setParameter("orderItemId", orderItemId)
                .executeUpdate();
    }
}
