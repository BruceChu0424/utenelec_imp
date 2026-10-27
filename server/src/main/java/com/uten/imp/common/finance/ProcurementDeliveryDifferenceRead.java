package com.uten.imp.common.finance;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.report.ReportQueryKit.WhereBuilder;
import com.uten.imp.security.DocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** Read-only source-order projection shared by explicitly linked procurement documents. */
public final class ProcurementDeliveryDifferenceRead {
    private ProcurementDeliveryDifferenceRead() { }

    /** One-to-one source projection: absent permission/link/facts stays null and never drops the receipt row. */
    public static String reportJoin(DocumentAccessPolicy access, String orderType, WhereBuilder where) {
        String prefix = prefix(orderType);
        if (access == null || !access.hasAuthority(prefix + "_order:view")) {
            return " LEFT JOIN LATERAL (SELECT NULL::numeric AS qty, NULL::text AS unit_name) source_order_difference ON TRUE";
        }
        var scope = access.nativeReadScope("source_order.maker_id", "sourceDifferenceOwners");
        if (scope.parameterName() != null) where.add("TRUE", scope.parameterName(), scope.owners());
        return """
                 LEFT JOIN LATERAL (
                    SELECT %s AS qty, source_unit.name AS unit_name
                    FROM %s_order_items source_item
                    JOIN %s_orders source_order ON source_order.id=source_item.order_id
                    LEFT JOIN units source_unit ON source_unit.id=source_item.unit_id
                    WHERE source_item.id=i.order_item_id AND NOT source_item.is_deleted AND NOT source_order.is_deleted
                      AND (%s)
                ) source_order_difference ON TRUE
                """.formatted(ProcurementDeliveryDifference.sql("source_item.qty", "source_item.received_qty", "source_item.returned_qty"),
                        prefix, prefix, scope.predicate());
    }

    public static void enrich(EntityManager em, DocumentAccessPolicy access, String orderType,
                              Collection<? extends ProcurementSourceOrderDifferenceResponse> items) {
        String prefix = prefix(orderType);
        if (items.isEmpty() || access == null || !access.hasAuthority(prefix + "_order:view")) return;
        List<UUID> ids = items.stream().map(ProcurementSourceOrderDifferenceResponse::getOrderItemId)
                .filter(Objects::nonNull).distinct().toList();
        if (ids.isEmpty()) return;
        var scope = access.nativeReadScope("source_order.maker_id", "sourceDifferenceOwners");
        var query = em.createNativeQuery("""
                SELECT item.id, %s, item.unit_id
                FROM %s_order_items item
                JOIN %s_orders source_order ON source_order.id=item.order_id
                WHERE item.id IN (:ids) AND NOT item.is_deleted AND NOT source_order.is_deleted
                  AND (%s)
                """.formatted(ProcurementDeliveryDifference.sql("item.qty", "item.received_qty", "item.returned_qty"),
                        prefix, prefix, scope.predicate())).setParameter("ids", ids);
        scope.bind(query);
        Map<UUID, Object[]> facts = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) facts.put((UUID) row[0], row);
        for (var item : items) {
            Object[] row = facts.get(item.getOrderItemId());
            if (row != null) {
                item.setSourceOrderDifferenceQty((BigDecimal) row[1]);
                item.setSourceOrderDifferenceUnitId((UUID) row[2]);
            }
        }
    }

    private static String prefix(String orderType) {
        return switch (orderType) {
            case "PURCHASE" -> "purchase";
            case "SUBCONTRACT" -> "subcontract";
            default -> throw new IllegalArgumentException("Unknown procurement order type: " + orderType);
        };
    }
}
