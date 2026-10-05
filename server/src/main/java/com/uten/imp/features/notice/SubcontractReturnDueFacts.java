package com.uten.imp.features.notice;

import com.uten.imp.common.util.NativeValueConverters;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Read-only projection for subcontract work that the supplier can still turn into
 * the subcontracted item but has not physically returned yet (ADR-143 §三.6).
 *
 * <p>Per order item with frozen draw-plan lines: unreturned = returnable sets
 * ({@code fn_subcontract_returnable_qty}: complete sets the supplier can make from the
 * material we actually sent, minus material returns and approved waste) minus the
 * material-basis quantity of effective approved receipts. Never sums materials of
 * different kinds. Approved order items always have plan lines; one without any has
 * returnable 0 and produces no reminder. IQC is deliberately absent: once the item is
 * physically back, quality owns its separate authoritative queue.
 */
final class SubcontractReturnDueFacts {

    private static final String PROJECTION = """
            SELECT order_header.id AS order_id,
                   order_header.bill_no,
                   order_header.deliver_date,
                   order_header.maker_id,
                   COALESCE(SUM(outbound.approved_outbound_lines), 0)
                       AS approved_outbound_lines,
                   COALESCE(SUM(GREATEST(
                       COALESCE(supply.returnable_qty, 0)
                       - COALESCE(received.material_basis_qty, 0), 0)), 0)
                       AS unreturned_qty
            FROM subcontract_orders order_header
            JOIN subcontract_order_items order_item
              ON order_item.order_id = order_header.id
             AND order_item.is_deleted = FALSE
            CROSS JOIN LATERAL (
                SELECT fn_subcontract_returnable_qty(order_item.id) AS returnable_qty
            ) supply
            LEFT JOIN LATERAL (
                SELECT COUNT(*) AS approved_outbound_lines
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_issues issue
                  ON issue.id = issue_item.issue_id
                 AND issue.status = 1
                 AND issue.is_deleted = FALSE
                WHERE issue_item.order_item_id = order_item.id
                  AND issue_item.plan_item_id IS NOT NULL
                  AND issue_item.is_deleted = FALSE
            ) outbound ON TRUE
            LEFT JOIN LATERAL (
                SELECT SUM(receipt_item.material_basis_qty) AS material_basis_qty
                FROM subcontract_receipt_items receipt_item
                JOIN subcontract_receipts receipt
                  ON receipt.id = receipt_item.receipt_id
                 AND receipt.status = 1
                 AND receipt.is_deleted = FALSE
                WHERE receipt_item.order_item_id = order_item.id
                  AND receipt_item.is_deleted = FALSE
            ) received ON TRUE
            WHERE order_header.status = 1
              AND order_header.is_deleted = FALSE
              AND order_header.deliver_date IS NOT NULL
              AND order_header.deliver_date <= ?
            """;

    private static final String GROUPING = """
            GROUP BY order_header.id, order_header.bill_no,
                     order_header.deliver_date, order_header.maker_id
            ORDER BY order_header.deliver_date, order_header.id
            """;

    private SubcontractReturnDueFacts() {
    }

    static List<Snapshot> findDue(JdbcTemplate jdbc, LocalDate deadline) {
        return jdbc.queryForList(PROJECTION + GROUPING, deadline).stream()
                .map(SubcontractReturnDueFacts::snapshot)
                .filter(Snapshot::requiresReminder)
                .toList();
    }

    static Snapshot findCurrent(
            JdbcTemplate jdbc, UUID orderId, LocalDate deadline) {
        List<Snapshot> rows = jdbc.queryForList(
                        PROJECTION + " AND order_header.id = ?\n" + GROUPING,
                        deadline,
                        orderId)
                .stream()
                .map(SubcontractReturnDueFacts::snapshot)
                .filter(Snapshot::requiresReminder)
                .toList();
        return rows.isEmpty() ? null : rows.get(0);
    }

    private static Snapshot snapshot(Map<String, Object> row) {
        return new Snapshot(
                (UUID) row.get("order_id"),
                text(row.get("bill_no")),
                NativeValueConverters.toLocalDate(row.get("deliver_date")),
                (UUID) row.get("maker_id"),
                number(row.get("approved_outbound_lines")),
                NativeValueConverters.toBigDecimal(row.get("unreturned_qty")));
    }

    private static long number(Object value) {
        return value instanceof Number number ? number.longValue() : 0L;
    }

    private static String text(Object value) {
        return value == null ? "" : value.toString();
    }

    record Snapshot(
            UUID orderId,
            String billNo,
            LocalDate deliverDate,
            UUID makerEmployeeId,
            long approvedOutboundLines,
            BigDecimal unreturnedQty) {

        boolean requiresReminder() {
            return approvedOutboundLines > 0
                    && unreturnedQty != null
                    && unreturnedQty.signum() > 0;
        }
    }
}
