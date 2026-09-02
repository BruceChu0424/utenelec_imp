package com.uten.imp.features.notice;

import com.uten.imp.common.util.NativeValueConverters;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Read-only projection for subcontract target items that have physically left
 * the company but have not yet physically returned.
 *
 * <p>New V436 target-item flows use the V221 supplier-held ledger's
 * {@code supplier_ending} quantity. It already subtracts return-to-factory
 * consumption, material return and approved loss, so those terminal facts do
 * not produce false overdue warnings. Historical component flows cannot compare
 * BOM component quantities with processed-parent quantity, so they retain the
 * order-line completion equation, but only after an approved subcontract
 * outbound exists for that exact line. IQC is deliberately absent: once the
 * item is physically back, quality owns its separate authoritative queue.
 */
final class SubcontractReturnDueFacts {

    private static final String PROJECTION = """
            WITH flow_by_item AS (
                SELECT plan_item.order_item_id,
                       BOOL_OR(plan_item.flow_mode IN (
                           'DIRECT_OUTBOUND', 'MAKE_THEN_OUTBOUND', 'PREPARED_OUTBOUND'))
                           AS target_item_flow
                FROM subcontract_material_plan_items plan_item
                WHERE plan_item.is_deleted = FALSE
                GROUP BY plan_item.order_item_id
            ),
            approved_outbound_by_item AS (
                SELECT issue_item.order_item_id,
                       COUNT(*) AS approved_outbound_lines,
                       COALESCE(SUM(
                           CASE WHEN plan_item.flow_mode IN (
                                   'DIRECT_OUTBOUND', 'MAKE_THEN_OUTBOUND', 'PREPARED_OUTBOUND')
                                THEN GREATEST(
                                    COALESCE(issue_item.supplier_ending, 0), 0)
                                ELSE 0 END
                       ), 0) AS target_supplier_ending
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_issues issue
                  ON issue.id = issue_item.issue_id
                 AND issue.status = 1
                 AND issue.is_deleted = FALSE
                LEFT JOIN subcontract_material_plan_items plan_item
                  ON plan_item.id = issue_item.plan_item_id
                 AND plan_item.is_deleted = FALSE
                WHERE issue_item.order_item_id IS NOT NULL
                  AND issue_item.is_deleted = FALSE
                GROUP BY issue_item.order_item_id
            )
            SELECT order_header.id AS order_id,
                   order_header.bill_no,
                   order_header.deliver_date,
                   order_header.maker_id,
                   COALESCE(SUM(outbound.approved_outbound_lines), 0)
                       AS approved_outbound_lines,
                   COALESCE(SUM(
                       CASE WHEN COALESCE(flow.target_item_flow, FALSE)
                            THEN outbound.target_supplier_ending
                            ELSE 0 END
                   ), 0) AS new_unreturned_base,
                   COUNT(*) FILTER (
                       WHERE outbound.approved_outbound_lines > 0
                         AND NOT COALESCE(flow.target_item_flow, FALSE)
                         AND COALESCE(order_item.qty, 0)
                             - COALESCE(order_item.received_qty, 0)
                             + COALESCE(order_item.returned_qty, 0) > 0
                   ) AS legacy_unreturned_lines
            FROM subcontract_orders order_header
            JOIN subcontract_order_items order_item
              ON order_item.order_id = order_header.id
             AND order_item.is_deleted = FALSE
            LEFT JOIN flow_by_item flow
              ON flow.order_item_id = order_item.id
            LEFT JOIN approved_outbound_by_item outbound
              ON outbound.order_item_id = order_item.id
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
                NativeValueConverters.toBigDecimal(row.get("new_unreturned_base")),
                number(row.get("legacy_unreturned_lines")));
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
            BigDecimal newUnreturnedBase,
            long legacyUnreturnedLines) {

        boolean requiresReminder() {
            return approvedOutboundLines > 0
                    && (newUnreturnedBase.signum() > 0
                    || legacyUnreturnedLines > 0);
        }
    }
}
