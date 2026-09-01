package com.uten.imp.features.warehouse.inbound;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

/** JDBC persistence and deterministic row locking for arrival-exception stock-in batches. */
@Repository
@RequiredArgsConstructor
public class WarehouseArrivalExceptionStockInBatchRepository {

    private final JdbcTemplate jdbc;

    public void lockCommand(UUID actorUserId, String idempotencyKey) {
        jdbc.queryForObject(
                "SELECT pg_advisory_xact_lock(hashtextextended(?, 0)) IS NULL",
                Boolean.class,
                "WAREHOUSE_ARRIVAL_EXCEPTION_STOCK_IN|"
                        + actorUserId + "|" + idempotencyKey);
    }

    public ExistingCommand findExisting(UUID actorUserId, String idempotencyKey) {
        List<ExistingCommand> rows = jdbc.query("""
                SELECT id, request_hash, status, result_snapshot::text
                FROM warehouse_arrival_exception_stock_in_batches
                WHERE actor_user_id = ? AND idempotency_key = ?
                """, (rs, rowNum) -> new ExistingCommand(
                        rs.getObject("id", UUID.class),
                        rs.getString("request_hash"),
                        rs.getString("status"),
                        rs.getString("result_snapshot")),
                actorUserId, idempotencyKey);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    public void insertPending(
            UUID batchId,
            UUID actorUserId,
            UUID actorEmployeeId,
            String idempotencyKey,
            String requestHash,
            int requestedExceptionCount) {
        requireOne(jdbc.update("""
                INSERT INTO warehouse_arrival_exception_stock_in_batches(
                    id, actor_user_id, actor_employee_id, idempotency_key,
                    request_hash, requested_exception_count)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                batchId,
                actorUserId,
                actorEmployeeId,
                idempotencyKey,
                requestHash,
                requestedExceptionCount));
    }

    /**
     * Locks selected exception rows in canonical aggregate order. The service
     * re-sorts defensively before grouping, so mocked or alternative adapters
     * cannot change business execution order.
     */
    public List<LockedException> lockExceptions(List<UUID> exceptionIds) {
        String placeholders = String.join(
                ",", Collections.nCopies(exceptionIds.size(), "?"));
        return jdbc.query("""
                SELECT id, order_type, receipt_id, receipt_bill_no_snapshot,
                       accepted_qty, status, version
                FROM procurement_arrival_exceptions
                WHERE id IN (
                """ + placeholders + """
                )
                ORDER BY order_type, receipt_id, id
                FOR UPDATE
                """,
                (rs, rowNum) -> new LockedException(
                        rs.getObject("id", UUID.class),
                        rs.getString("order_type"),
                        rs.getObject("receipt_id", UUID.class),
                        rs.getString("receipt_bill_no_snapshot"),
                        rs.getBigDecimal("accepted_qty"),
                        rs.getString("status"),
                        rs.getLong("version")),
                exceptionIds.toArray());
    }

    public void insertItems(UUID batchId, List<PersistedItem> items) {
        int lineNo = 0;
        for (PersistedItem item : items) {
            lineNo++;
            requireOne(jdbc.update("""
                    INSERT INTO warehouse_arrival_exception_stock_in_batch_items(
                        batch_id, line_no, arrival_exception_id, expected_version,
                        order_type, receipt_id, receipt_bill_no_snapshot,
                        result_status, result_version, submitted_for_inspection)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, TRUE)
                    """,
                    batchId,
                    lineNo,
                    item.exceptionId(),
                    item.expectedVersion(),
                    item.orderType(),
                    item.receiptId(),
                    item.receiptBillNo(),
                    item.resultStatus(),
                    item.resultVersion()));
        }
    }

    public void complete(UUID batchId, int receiptGroupCount, String resultJson) {
        requireOne(jdbc.update("""
                UPDATE warehouse_arrival_exception_stock_in_batches
                SET status = 'COMPLETED',
                    receipt_group_count = ?,
                    submitted_for_inspection = TRUE,
                    result_snapshot = CAST(? AS jsonb),
                    completed_at = now()
                WHERE id = ? AND status = 'PENDING'
                """, receiptGroupCount, resultJson, batchId));
    }

    private static void requireOne(int changed) {
        if (changed != 1) {
            throw new IllegalStateException(
                    "warehouse arrival exception stock-in batch persistence conflict");
        }
    }

    public record ExistingCommand(
            UUID batchId,
            String requestHash,
            String status,
            String resultJson) {
    }

    public record LockedException(
            UUID exceptionId,
            String orderType,
            UUID receiptId,
            String receiptBillNo,
            BigDecimal acceptedQty,
            String status,
            long version) {
    }

    public record PersistedItem(
            UUID exceptionId,
            long expectedVersion,
            String orderType,
            UUID receiptId,
            String receiptBillNo,
            String resultStatus,
            long resultVersion) {
    }
}
