package com.uten.imp.support;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.UUID;

/** Test cases created after V691 must carry the same row identities as real submissions. */
public final class ProcurementApprovalFixtureSupport {
    private ProcurementApprovalFixtureSupport() {}

    public static String submittedSnapshot(Connection connection, String type, UUID orderId) throws SQLException {
        String prefix = switch (type) {
            case "PURCHASE" -> "purchase";
            case "SUBCONTRACT" -> "subcontract";
            default -> throw new IllegalArgumentException(type);
        };
        String sql = """
                SELECT COALESCE((SELECT jsonb_build_object(
                    'orderType', ?, 'orderId', head.id, 'billNo', head.bill_no, 'billDate', head.bill_date,
                    'supplierId', head.supplier_id, 'warehouseId', head.warehouse_id, 'currencyId', head.currency_id,
                    'exchangeRate', head.exchange_rate::text, 'settlementMethodId', head.settlement_method_id,
                    'taxRate', head.tax_rate::text, 'purchaserEmployeeId', head.purchaser_id,
                    'makerEmployeeId', head.maker_id, 'deliverDate', head.deliver_date,
                    'totalOriginal', head.total_original::text, 'totalLocal', head.total_local::text,
                    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                        'itemId', item.id, 'lineNo', item.line_no, 'goodsId', item.goods_id,
                        'colorId', item.color_id, 'unitId', item.unit_id,
                        'sourceItemId', COALESCE(to_jsonb(item)->'request_item_id',to_jsonb(item)->'application_item_id'),
                        'unitRate', item.unit_rate::text, 'qty', item.qty::text, 'price', item.price::text,
                        'amountOriginal', item.amount_original::text, 'amountLocal', item.amount_local::text,
                        'deliverDate', item.deliver_date) ORDER BY item.line_no,item.id)
                        FROM %s_order_items item WHERE item.order_id=head.id AND NOT item.is_deleted), '[]'::jsonb))::text
                    FROM %s_orders head WHERE head.id=?), '{}')
                """.formatted(prefix, prefix);
        try (var statement = connection.prepareStatement(sql)) {
            statement.setString(1, type);
            statement.setObject(2, orderId);
            try (var result = statement.executeQuery()) {
                result.next();
                return result.getString(1);
            }
        }
    }
}
