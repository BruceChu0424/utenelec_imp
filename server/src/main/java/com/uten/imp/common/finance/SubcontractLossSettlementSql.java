package com.uten.imp.common.finance;

/**
 * Accepted short delivery is a separate fulfilment fact, never a receipt or stock quantity.
 * SQL arguments are trusted query expressions supplied by server code.
 */
public final class SubcontractLossSettlementSql {
    private SubcontractLossSettlementSql() {}

    /** Order-unit loss. Legacy cases that already reduced the order must not be deducted twice. */
    public static String acceptedLossQty(String orderItemIdExpression) {
        return "fn_subcontract_settled_loss_qty(" + orderItemIdExpression + ")";
    }

    /** Convert only the settlement fact to the expectation's frozen unit; never guess an unknown rate. */
    public static String acceptedLossInExpectationUnits(String expectationItemAlias) {
        return """
                COALESCE((
                    SELECT ROUND((%s) * loss_order_item.unit_rate / NULLIF(%s.unit_rate, 0), 4)
                    FROM subcontract_order_items loss_order_item
                    WHERE loss_order_item.id = %s.order_item_id
                      AND NOT loss_order_item.is_deleted
                      AND loss_order_item.unit_rate > 0
                ), 0)
                """.formatted(acceptedLossQty("loss_order_item.id"),
                        expectationItemAlias, expectationItemAlias).strip();
    }

    /** Remaining delivery obligation, independent of finance approval and physical accepted_qty. */
    public static String expectationRemainingQty(String itemAlias, String orderTypeExpression) {
        return """
                GREATEST(%1$s.ordered_qty - %1$s.accepted_qty
                    - CASE WHEN %2$s = 'SUBCONTRACT' THEN %3$s ELSE 0 END, 0)
                """.formatted(itemAlias, orderTypeExpression,
                        acceptedLossInExpectationUnits(itemAlias)).strip();
    }
}
