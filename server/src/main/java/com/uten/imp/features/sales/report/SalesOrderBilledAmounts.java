package com.uten.imp.features.sales.report;

/** Reads posted shipment amounts in their frozen billing currency; never revalues historical orders. */
final class SalesOrderBilledAmounts {
    private SalesOrderBilledAmounts() {}

    static String forItem(String itemId, String currencyId) {
        return aggregate("shipped.order_item_id = " + identifier(itemId), currencyId);
    }

    static String forOrder(String orderId, String currencyId) {
        return aggregate("EXISTS (SELECT 1 FROM sales_order_items ordered WHERE ordered.id = shipped.order_item_id"
                + " AND ordered.order_id = " + identifier(orderId) + " AND NOT ordered.is_deleted)", currencyId);
    }

    private static String aggregate(String predicate, String currencyId) {
        return """
                SELECT CASE WHEN COUNT(*) FILTER (WHERE shipped.amount_local IS NULL) > 0
                       THEN NULL ELSE COALESCE(SUM(shipped.amount_local), 0) END AS amount
                FROM sales_shipment_items shipped
                JOIN sales_shipments shipment ON shipment.id = shipped.shipment_id
                WHERE NOT shipped.is_deleted AND NOT shipment.is_deleted
                  AND shipment.status = 1 AND shipment.finance_audit = 1
                  AND shipment.warehouse_work_status = 'SHIPPED'
                  AND shipment.shipment_kind <> 'LEGACY'
                  AND shipment.currency_id IS NOT DISTINCT FROM %s
                  AND (%s)
                """.formatted(identifier(currencyId), predicate);
    }

    private static String identifier(String value) {
        if (!value.matches("[a-zA-Z_][a-zA-Z_0-9]*\\.[a-zA-Z_][a-zA-Z_0-9]*")) {
            throw new IllegalArgumentException("report column identity");
        }
        return value;
    }
}
