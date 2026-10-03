package com.uten.imp.businesschain;

import com.uten.imp.application.port.InventoryValuationPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Read-only facts for the controlled load fixtures, after the runner explicitly
 * calls InventoryValueWorkTestSupport.drain. This never drains, repairs, approves
 * an opening, or marks incomplete production cost FINAL.
 *
 * SOURCE evidence is classified by its actual lane. An approved OTHER_IN uses
 * RECEIVE plus its warehouse document; POSITION_ACQUIRE uses acquisition_sources;
 * production RECEIVE uses production_cost_outputs; opening sources use openings.
 * Unknown acquisition lanes fail closed instead of being called verified.
 */
public final class ControlledLoadFacts {
    private ControlledLoadFacts() {}

    public static Map<String, Object> verify(JdbcTemplate jdbc, InventoryValuationPort values,
                                             Set<UUID> goodsIds) {
        Objects.requireNonNull(jdbc, "jdbc");
        Objects.requireNonNull(values, "values");
        if (goodsIds == null || goodsIds.isEmpty() || goodsIds.stream().anyMatch(Objects::isNull)) {
            throw new IllegalArgumentException("A nonempty concrete fixture goods scope is required");
        }
        var db = new NamedParameterJdbcTemplate(jdbc);
        Map<String, Object> parameters = Map.of("goods", goodsIds.stream().sorted().toList());
        Map<String, Object> facts = new LinkedHashMap<>();
        facts.put("scopeGoodsCount", goodsIds.size());
        facts.put("scope", "all warehouse/goods/color dimensions for the supplied fixture goods");

        Map<String, Object> physical = db.queryForMap("""
                WITH balances AS (
                    SELECT warehouse_id,goods_id,color_id,COUNT(*) AS row_count,SUM(qty) AS qty
                    FROM stock_balances WHERE goods_id IN (:goods) GROUP BY warehouse_id,goods_id,color_id
                ), movements AS (
                    SELECT warehouse_id,goods_id,color_id,COUNT(*) AS row_count,SUM(direction*qty) AS qty
                    FROM stock_movements WHERE goods_id IN (:goods) GROUP BY warehouse_id,goods_id,color_id
                ), dimensions AS (
                    SELECT warehouse_id,goods_id,color_id FROM balances
                    UNION SELECT warehouse_id,goods_id,color_id FROM movements
                )
                SELECT COUNT(*) AS dimension_count,COALESCE(SUM(movement.row_count),0) AS movement_count,
                       COUNT(*) FILTER(WHERE balance.row_count>1) AS duplicate_balance_dimensions,
                       COUNT(*) FILTER(WHERE COALESCE(balance.qty,0)<0) AS negative_balance_dimensions,
                       COUNT(*) FILTER(WHERE COALESCE(balance.qty,0)<>COALESCE(movement.qty,0)) AS quantity_mismatches
                FROM dimensions dimension
                LEFT JOIN balances balance ON balance.warehouse_id=dimension.warehouse_id AND balance.goods_id=dimension.goods_id
                  AND balance.color_id IS NOT DISTINCT FROM dimension.color_id
                LEFT JOIN movements movement ON movement.warehouse_id=dimension.warehouse_id AND movement.goods_id=dimension.goods_id
                  AND movement.color_id IS NOT DISTINCT FROM dimension.color_id
                """, parameters);
        facts.put("physical", physical);
        zero(physical, "duplicate_balance_dimensions");
        zero(physical, "negative_balance_dimensions");
        zero(physical, "quantity_mismatches");
        assertTrue(number(physical, "movement_count") > 0, "controlled inputs must have real physical movements");

        // There is no stock_movements.value_node_id column. The actual immutable
        // linkage is nodes.movement_id plus events.movement_id/result_node_id.
        Map<String, Object> bindings = db.queryForMap("""
                SELECT COUNT(*) AS movement_count,
                       COUNT(*) FILTER(WHERE node.id IS NULL OR event.id IS NULL) AS missing_value_bindings,
                       COUNT(*) FILTER(WHERE node.id IS NOT NULL AND event.id IS NOT NULL AND (
                           event.result_node_id IS DISTINCT FROM node.id OR node.creation_event_id IS DISTINCT FROM event.id
                           OR node.pool_id IS DISTINCT FROM event.pool_id OR pool.id IS NULL
                           OR pool.goods_id IS DISTINCT FROM movement.goods_id
                           OR pool.warehouse_id IS DISTINCT FROM movement.warehouse_id
                           OR pool.color_id IS DISTINCT FROM movement.color_id
                           OR event.source_doc_type IS DISTINCT FROM movement.source_doc_type
                           OR event.source_doc_id IS DISTINCT FROM movement.source_doc_id
                           OR event.source_item_id IS DISTINCT FROM movement.source_item_id
                           OR event.qty_base IS DISTINCT FROM movement.qty
                           OR event.known_value_local IS DISTINCT FROM movement.amount_local
                           OR movement.direction IS DISTINCT FROM
                               CASE WHEN event.operation IN ('ISSUE','POSITION_STORE_REVERSE') THEN -1 ELSE 1 END
                       )) AS mismatched_value_bindings
                FROM stock_movements movement
                LEFT JOIN stock_value_nodes node ON node.movement_id=movement.id
                LEFT JOIN stock_value_events event ON event.movement_id=movement.id
                LEFT JOIN stock_value_pools pool ON pool.id=event.pool_id
                WHERE movement.goods_id IN (:goods)
                """, parameters);
        facts.put("movementValueBindings", bindings);
        zero(bindings, "missing_value_bindings");
        zero(bindings, "mismatched_value_bindings");

        List<Map<String, Object>> sources = db.queryForList("""
                WITH sources AS (
                    SELECT node.id,node.source_final,
                           COALESCE(node.source_initial_amount_exact,node.initial_known_value) AS initial_value,
                           CASE
                               WHEN output.source_node_id=node.id AND output.movement_id=node.movement_id
                                 AND object.execution_segment_id=output.execution_segment_id
                                 AND output.qty_base=node.quantity_basis AND event.result_node_id=node.id
                                 AND event.operation='RECEIVE' THEN 'PRODUCTION_OUTPUT'
                               WHEN acquisition.source_node_id=node.id AND acquisition.event_id=event.id
                                 AND event.operation='POSITION_ACQUIRE' AND event.source_node_id=node.id
                                 AND node.movement_id IS NULL AND acquisition.quantity_basis=node.quantity_basis
                                 THEN 'ACQUISITION'
                               WHEN opening.source_node_id=node.id AND opening.event_id=event.id
                                 AND opening.pool_id=node.pool_id AND event.source_node_id=node.id
                                 AND event.operation IN ('OPENING','EMPTY_OPENING') AND node.movement_id IS NULL
                                 THEN 'OPENING'
                               WHEN event.operation='RECEIVE' AND event.result_node_id=node.id
                                 AND event.movement_id=node.movement_id AND event.source_doc_type='STOCK_DOC'
                                 AND document.doc_type='OTHER_IN' AND document.status IN (1,-1)
                                 AND item.id=event.source_item_id AND item.doc_id=document.id
                                 AND item.goods_id=pool.goods_id AND item.color_id IS NOT DISTINCT FROM pool.color_id
                                 AND document.warehouse_id=pool.warehouse_id THEN 'APPROVED_OTHER_IN'
                               ELSE 'UNPROVEN'
                           END AS evidence_kind
                    FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id
                    LEFT JOIN stock_value_events event ON event.id=node.creation_event_id
                    LEFT JOIN stock_value_production_cost_outputs output ON output.source_node_id=node.id
                    LEFT JOIN stock_value_production_cost_objects object ON object.execution_segment_id=output.execution_segment_id
                    LEFT JOIN stock_value_acquisition_sources acquisition ON acquisition.source_node_id=node.id
                    LEFT JOIN stock_value_openings opening ON opening.source_node_id=node.id
                    LEFT JOIN stock_documents document ON document.id=event.source_doc_id
                    LEFT JOIN stock_document_items item ON item.id=event.source_item_id
                    WHERE pool.goods_id IN (:goods) AND node.kind='SOURCE'
                )
                SELECT evidence_kind,COUNT(*) AS source_count,
                       COUNT(*) FILTER(WHERE NOT source_final) AS source_not_final_count,
                       COALESCE(SUM(initial_value),0) AS initial_value,
                       COUNT(*) FILTER(WHERE initial_value<=0) AS nonpositive_initial_sources
                FROM sources GROUP BY evidence_kind ORDER BY evidence_kind
                """, parameters);
        facts.put("sourceEvidence", sources);
        assertTrue(sources.stream().noneMatch(row -> "UNPROVEN".equals(row.get("evidence_kind"))),
                () -> "unproven controlled SOURCE lane: " + sources);
        BigDecimal initialPurchasedValue = BigDecimal.ZERO;
        for (var row : sources) {
            String kind = row.get("evidence_kind").toString();
            if ("APPROVED_OTHER_IN".equals(kind)) {
                zero(row, "nonpositive_initial_sources");
            }
            if (Set.of("APPROVED_OTHER_IN", "ACQUISITION").contains(kind)) {
                initialPurchasedValue = initialPurchasedValue.add((BigDecimal) row.get("initial_value"));
            }
        }
        assertTrue(initialPurchasedValue.signum() > 0, "controlled raw inputs must have positive initial approved value");
        facts.put("initialApprovedAcquisitionValue", initialPurchasedValue);

        List<Map<String, Object>> pools = db.queryForList("""
                SELECT id,warehouse_id,goods_id,color_id,state,head_node_id
                FROM stock_value_pools WHERE goods_id IN (:goods) ORDER BY id
                """, parameters);
        assertTrue(pools.stream().noneMatch(row -> "LEGACY_UNVERIFIED".equals(row.get("state"))),
                "controlled inputs must never inherit unverified legacy pools");
        List<Map<String, Object>> poolFacts = new ArrayList<>();
        for (var pool : pools) {
            // Reuse the canonical database validator, including known-value and
            // unique-balance identity checks. It only SELECTs and raises on drift.
            db.query("SELECT fn_check_stock_value_pool(:id)", Map.of("id", pool.get("id")), (rs, index) -> 0);
            var value = values.pool(new InventoryValuationPort.PoolKey((UUID) pool.get("warehouse_id"),
                    (UUID) pool.get("goods_id"), (UUID) pool.get("color_id")));
            assertNotEquals(InventoryValuationPort.State.LEGACY_UNVERIFIED, value.state(),
                    "canonical pool projection must match its current physical balance");
            Map<String, Object> fact = new LinkedHashMap<>();
            fact.put("poolId", pool.get("id"));
            fact.put("warehouseId", pool.get("warehouse_id"));
            fact.put("goodsId", pool.get("goods_id"));
            fact.put("quantity", value.qtyBase());
            fact.put("knownValueLocal", value.knownValueLocal());
            fact.put("state", value.state().name());
            // The port's flag is global, not scoped. Do not mistake another
            // scenario's durable work for this fixture's unfinished projection.
            fact.put("apiGlobalPropagationPending", value.propagationPending());
            poolFacts.add(fact);
        }
        facts.put("pools", poolFacts);
        facts.put("pendingCostPoolCount", poolFacts.stream().filter(row -> "PENDING".equals(row.get("state"))).count());

        Map<String, Object> queued = db.queryForMap("""
                WITH pools AS MATERIALIZED (SELECT id FROM stock_value_pools WHERE goods_id IN (:goods)),
                objects AS MATERIALIZED (
                    SELECT execution_segment_id,business_refresh_pending FROM stock_value_production_cost_objects
                    WHERE product_pool_id IN (SELECT id FROM pools)
                )
                SELECT
                    (SELECT COUNT(*) FROM objects WHERE business_refresh_pending) AS production_business_refresh,
                    (SELECT COUNT(*) FROM stock_value_production_cost_dirty dirty JOIN objects USING(execution_segment_id)
                        WHERE dirty.observed_revision>dirty.cleared_revision) AS production_dirty,
                    (SELECT COUNT(*) FROM stock_value_production_cost_tasks task JOIN objects USING(execution_segment_id)
                        WHERE task.status='PENDING') AS production_tasks,
                    (SELECT COUNT(*) FROM stock_value_tasks task JOIN stock_value_edges edge ON edge.id=task.edge_id
                        JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id JOIN stock_value_nodes child ON child.id=edge.child_node_id
                        WHERE task.status='PENDING' AND (parent.pool_id IN (SELECT id FROM pools) OR child.pool_id IN (SELECT id FROM pools))) AS value_tasks,
                    (SELECT COUNT(*) FROM stock_value_jobs job JOIN stock_value_events event ON event.id=job.event_id
                        JOIN stock_value_nodes source ON source.id=job.source_node_id
                        WHERE job.status<>'APPLIED' AND (event.pool_id IN (SELECT id FROM pools) OR source.pool_id IN (SELECT id FROM pools))) AS value_jobs
                """, parameters);
        facts.put("scopedQueuedWorkAfterExplicitDrain", queued);
        queued.forEach((name, count) -> assertEquals(0L, ((Number) count).longValue(),
                "runner must explicitly drain before verification; pending " + name + ": " + count));
        facts.put("productionCostStates", db.queryForList("""
                SELECT object.state,COUNT(*) AS object_count
                FROM stock_value_production_cost_objects object JOIN stock_value_pools pool ON pool.id=object.product_pool_id
                WHERE pool.goods_id IN (:goods) GROUP BY object.state ORDER BY object.state
                """, parameters));
        facts.put("proofScope", "physical quantity, canonical current pools, exact movement/value identity and typed source bindings; legal pending costs retained");
        return Map.copyOf(facts);
    }

    private static long number(Map<String, Object> facts, String key) {
        return ((Number) facts.get(key)).longValue();
    }

    private static void zero(Map<String, Object> facts, String key) {
        assertEquals(0L, number(facts, key), () -> key + ": " + facts);
    }
}
