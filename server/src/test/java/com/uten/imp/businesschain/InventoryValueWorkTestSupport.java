package com.uten.imp.businesschain;

import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.sql.SQLException;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;

/** Real worker coordination for fixtures sharing a database with other Spring contexts. */
final class InventoryValueWorkTestSupport {
    private static final int REFRESH_CLAIM_NAMESPACE = 0x5657524B;
    private static final Duration DRAIN_DEADLINE = Duration.ofSeconds(45);

    private InventoryValueWorkTestSupport() {}

    static <T> T withRefreshClaim(JdbcTemplate jdbc, UUID scope, Supplier<T> action) {
        try (var claim = jdbc.getDataSource().getConnection()) {
            claim.setAutoCommit(false);
            try {
                claim.createStatement().execute("SET LOCAL lock_timeout = '15s'");
                try (var statement = claim.prepareStatement(
                        "SELECT pg_advisory_xact_lock(?, hashtext(CAST(? AS text)))")) {
                    statement.setInt(1, REFRESH_CLAIM_NAMESPACE);
                    statement.setObject(2, scope);
                    statement.execute();
                }
                // Business transactions never acquire this worker-only claim.
                // They commit normally while another context's poller skips it.
                return action.get();
            } finally {
                claim.rollback();
            }
        } catch (SQLException failure) {
            throw new AssertionError("Could not coordinate the real production-cost worker", failure);
        }
    }

    static void drain(InventoryValueWorkService worker, JdbcTemplate jdbc, List<UUID> goodsIds) {
        if (goodsIds.isEmpty()) throw new IllegalArgumentException("A concrete fixture goods scope is required");
        var database = new NamedParameterJdbcTemplate(jdbc);
        long deadline = System.nanoTime() + DRAIN_DEADLINE.toNanos();
        do {
            worker.runBatch();
            // Zero processed tasks only describes this invocation: a different
            // worker may own an uncommitted claim. All five durable queues must
            // settle for this fixture; unrelated worlds can deliberately remain pending.
            if (!worker.hasPendingWork() || !pendingForGoods(database, goodsIds)) return;
            try {
                Thread.sleep(20);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new AssertionError("Interrupted while draining fixture inventory-value work", interrupted);
            }
        } while (System.nanoTime() < deadline);
        throw new AssertionError("Inventory-value work remained pending for fixture goods after "
                + DRAIN_DEADLINE.toSeconds() + " seconds: " + goodsIds);
    }

    private static boolean pendingForGoods(NamedParameterJdbcTemplate database, List<UUID> goodsIds) {
        return Boolean.TRUE.equals(database.queryForObject("""
                WITH pools AS MATERIALIZED (
                    SELECT id FROM stock_value_pools WHERE goods_id IN (:goods)
                ), objects AS MATERIALIZED (
                    SELECT execution_segment_id,business_refresh_pending
                    FROM stock_value_production_cost_objects WHERE product_pool_id IN (SELECT id FROM pools)
                )
                SELECT EXISTS(SELECT 1 FROM objects WHERE business_refresh_pending)
                    OR EXISTS(SELECT 1 FROM stock_value_production_cost_dirty dirty
                        JOIN objects USING(execution_segment_id)
                        WHERE dirty.observed_revision>dirty.cleared_revision)
                    OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks task
                        JOIN objects USING(execution_segment_id) WHERE task.status='PENDING')
                    OR EXISTS(SELECT 1 FROM stock_value_tasks task
                        JOIN stock_value_edges edge ON edge.id=task.edge_id
                        JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id
                        JOIN stock_value_nodes child ON child.id=edge.child_node_id
                        WHERE task.status='PENDING' AND (parent.pool_id IN (SELECT id FROM pools)
                            OR child.pool_id IN (SELECT id FROM pools)))
                    OR EXISTS(SELECT 1 FROM stock_value_jobs job
                        JOIN stock_value_events event ON event.id=job.event_id
                        JOIN stock_value_nodes source ON source.id=job.source_node_id
                        WHERE job.status<>'APPLIED' AND (event.pool_id IN (SELECT id FROM pools)
                            OR source.pool_id IN (SELECT id FROM pools)))
                """, Map.of("goods", goodsIds), Boolean.class));
    }
}
