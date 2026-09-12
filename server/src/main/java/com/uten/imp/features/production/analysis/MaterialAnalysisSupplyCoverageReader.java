package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * Command-local supply coverage. All selected nodes are read together before
 * any new action is written. Historical grouped action keys and actual qualified
 * stock-in quantities retain the same conservative no-duplicate-supply rules.
 * This snapshot must never be retained across a command or refreshed mid-write.
 */
final class MaterialAnalysisSupplyCoverageReader {
    private final EntityManager em;
    MaterialAnalysisSupplyCoverageReader(EntityManager em) { this.em = em; }

    record Group(String key, String route, List<UUID> materialIds) {}
    record Key(String key, String route) {}
    record Coverage(Map<Key, BigDecimal> active, Map<Key, BigDecimal> replacement) {
        BigDecimal active(String key, String route) { return active.getOrDefault(new Key(key, route), BigDecimal.ZERO); }
        BigDecimal replacement(String key, String route) { return replacement.getOrDefault(new Key(key, route), BigDecimal.ZERO); }
    }

    Coverage read(UUID analysisId, List<Group> groups) {
        if (groups.isEmpty()) return new Coverage(Map.of(), Map.of());
        Map<UUID, Set<Key>> legacyByMaterial = new HashMap<>();
        List<UUID> materialIds = groups.stream().flatMap(group -> group.materialIds().stream()).distinct().sorted().toList();
        if (!materialIds.isEmpty()) {
            for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT DISTINCT allocation.analysis_material_id, action.action_group_key, action.route
                    FROM preplan_supply_action_allocations allocation
                    JOIN preplan_supply_actions action ON action.id = allocation.action_id
                    WHERE allocation.analysis_id = :analysisId
                      AND allocation.analysis_material_id IN (SELECT unnest(CAST(string_to_array(:materialIds, ',') AS uuid[])))
                      AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                    """).setParameter("analysisId", analysisId).setParameter("materialIds", materialIds.stream()
                            .map(UUID::toString).collect(java.util.stream.Collectors.joining(","))))) {
                legacyByMaterial.computeIfAbsent((UUID) row[0], ignored -> new LinkedHashSet<>())
                        .add(new Key((String) row[1], (String) row[2]));
            }
        }
        Map<Key, Set<Key>> keysByGroup = new LinkedHashMap<>();
        Map<String, Set<String>> keysByRoute = new LinkedHashMap<>();
        for (Group group : groups) {
            Key current = new Key(group.key(), group.route());
            Set<Key> aliases = new LinkedHashSet<>();
            aliases.add(current);
            for (UUID material : group.materialIds()) {
                legacyByMaterial.getOrDefault(material, Set.of()).stream()
                        .filter(key -> key.route().equals(group.route())).forEach(aliases::add);
            }
            keysByGroup.put(current, aliases);
            for (Key alias : aliases) keysByRoute.computeIfAbsent(alias.route(), ignored -> new LinkedHashSet<>()).add(alias.key());
        }
        Map<Key, BigDecimal> activeByKey = new HashMap<>();
        Map<Key, BigDecimal> replacementByKey = new HashMap<>();
        for (var route : keysByRoute.entrySet()) {
            String kind = route.getKey();
            Set<String> keys = route.getValue();
            if ("MAKE".equals(kind)) {
                readQuantities(MAKE_SQL, analysisId, keys, kind, null, activeByKey);
            } else {
                readQuantities("BUY".equals(kind) ? BUY_SQL : EXTERNAL_SQL,
                        analysisId, keys, kind, null, activeByKey);
                if ("SUBCONTRACT".equals(kind)) readQuantities(SUBCONTRACT_MAKE_SQL,
                        analysisId, keys, kind, null, activeByKey);
                readQuantities(REPLACEMENT_SQL.formatted("BUY".equals(kind) ? PURCHASE_JOIN : SUBCONTRACT_JOIN,
                                "BUY".equals(kind) ? "request_item_id" : "application_item_id"),
                        analysisId, keys, kind, "BUY".equals(kind) ? "PURCHASE" : "SUBCONTRACT", replacementByKey);
            }
        }
        Map<Key, BigDecimal> active = new LinkedHashMap<>();
        keysByGroup.forEach((key, aliases) -> active.put(key, aliases.stream()
                .map(alias -> activeByKey.getOrDefault(alias, BigDecimal.ZERO))
                .reduce(BigDecimal.ZERO, BigDecimal::add)));
        // IQC replacement historically follows the exact current group, whereas
        // still-active legacy actions also follow their allocation aliases.
        return new Coverage(Map.copyOf(active), Map.copyOf(replacementByKey));
    }

    private void readQuantities(String sql, UUID analysisId, Set<String> groupKeys,
            String route, String receiptType, Map<Key, BigDecimal> into) {
        Query query = em.createNativeQuery(sql).setParameter("analysisId", analysisId)
                .setParameter("groupKeys", groupKeys);
        if (sql.contains(":route")) query.setParameter("route", route);
        if (receiptType != null) query.setParameter("receiptType", receiptType);
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            into.merge(new Key((String) row[0], route), (BigDecimal) row[1], BigDecimal::add);
        }
    }

    private static final String BUY_SQL = """
                    SELECT action.action_group_key, COALESCE(SUM(LEAST(
                        GREATEST(
                            progress.demand_requested_qty
                                - progress.demand_qualified_qty,
                            0),
                        progress.demand_future_qty
                    )),0)
                    FROM preplan_supply_actions action
                    JOIN v_preplan_buy_action_slice_progress progress
                      ON progress.action_id = action.id
                    WHERE action.analysis_id = :analysisId
                      AND action.action_group_key IN (:groupKeys)
                      AND action.route = 'BUY'
                      AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                      AND progress.demand_source_valid = TRUE
                GROUP BY action.action_group_key
                """;

    private static final String EXTERNAL_SQL = """
                SELECT action.action_group_key, COALESCE(SUM(CASE
                    WHEN action.external_document_type = 'PURCHASE_REQUEST'
                         AND EXISTS (
                             SELECT 1
                             FROM preplan_supply_action_allocations allocation
                             JOIN purchase_request_items request_item
                               ON request_item.id = allocation.external_item_id
                              AND request_item.is_deleted = FALSE
                             JOIN purchase_requests request
                               ON request.id = request_item.request_id
                              AND request.id = action.external_document_id
                              AND request.is_deleted = FALSE
                              AND request.status IN (0,1)
                              AND request.is_stopped = FALSE
                             WHERE allocation.action_id = action.id)
                        THEN GREATEST(action.requested_qty - LEAST(
                            action.requested_qty, COALESCE((
                                -- V463：合并订货行按来源 FIFO 分摊到各申请行后再汇总。
                                SELECT SUM(fn_purchase_order_source_share(
                                    item.id, src.request_item_id,
                                    GREATEST(
                                        COALESCE((
                                            SELECT SUM(CASE
                                                WHEN inspection.id IS NULL
                                                THEN receipt_item.qty * COALESCE(
                                                    receipt_item.unit_rate,1)
                                                WHEN inspection.status IN (
                                                    'PARTIAL','RESOLVED')
                                                THEN inspection.warehouse_stocked_base_qty
                                                ELSE 0
                                            END)
                                            FROM purchase_receipt_items receipt_item
                                            JOIN purchase_receipts receipt
                                              ON receipt.id = receipt_item.receipt_id
                                             AND receipt.status = 1
                                             AND receipt.is_deleted = FALSE
                                            LEFT JOIN procurement_inspection_items inspection
                                              ON inspection.receipt_type = 'PURCHASE'
                                             AND inspection.receipt_item_id = receipt_item.id
                                            WHERE receipt_item.order_item_id = item.id
                                              AND receipt_item.is_deleted = FALSE
                                        ),0) - COALESCE(item.returned_qty,0)
                                            * COALESCE(item.unit_rate,1), 0)))
                                FROM purchase_order_item_sources src
                                JOIN purchase_order_items item
                                  ON item.id = src.order_item_id
                                 AND item.is_deleted = FALSE
                                JOIN purchase_orders purchase_order
                                  ON purchase_order.id = item.order_id
                                 AND purchase_order.status = 1
                                 AND purchase_order.is_deleted = FALSE
                                WHERE src.request_item_id IN (
                                      SELECT DISTINCT allocation.external_item_id
                                      FROM preplan_supply_action_allocations allocation
                                      WHERE allocation.action_id = action.id
                                        AND allocation.external_item_id IS NOT NULL)
                            ),0)), 0)
                    WHEN action.external_document_type = 'SUBCONTRACT_APPLICATION'
                         AND EXISTS (
                             SELECT 1
                             FROM preplan_supply_action_allocations allocation
                             JOIN subcontract_application_items application_item
                               ON application_item.id = allocation.external_item_id
                              AND application_item.is_deleted = FALSE
                             JOIN subcontract_applications application
                               ON application.id = application_item.application_id
                              AND application.id = action.external_document_id
                              AND application.is_deleted = FALSE
                              AND application.status IN (0,1)
                             WHERE allocation.action_id = action.id)
                        THEN GREATEST(action.requested_qty - LEAST(
                            action.requested_qty, COALESCE((
                                -- V463：合并订货行按来源 FIFO 分摊到各申请行后再汇总。
                                SELECT SUM(fn_subcontract_order_source_share(
                                    item.id, src.application_item_id,
                                    GREATEST(
                                        COALESCE((
                                            SELECT SUM(CASE
                                                WHEN inspection.id IS NULL
                                                THEN receipt_item.qty * COALESCE(
                                                    receipt_item.unit_rate,1)
                                                WHEN inspection.status IN (
                                                    'PARTIAL','RESOLVED')
                                                THEN inspection.warehouse_stocked_base_qty
                                                ELSE 0
                                            END)
                                            FROM subcontract_receipt_items receipt_item
                                            JOIN subcontract_receipts receipt
                                              ON receipt.id = receipt_item.receipt_id
                                             AND receipt.status = 1
                                             AND receipt.is_deleted = FALSE
                                            LEFT JOIN procurement_inspection_items inspection
                                              ON inspection.receipt_type = 'SUBCONTRACT'
                                             AND inspection.receipt_item_id = receipt_item.id
                                            WHERE receipt_item.order_item_id = item.id
                                              AND receipt_item.is_deleted = FALSE
                                        ),0) - COALESCE(item.returned_qty,0)
                                            * COALESCE(item.unit_rate,1), 0)))
                                FROM subcontract_order_item_sources src
                                JOIN subcontract_order_items item
                                  ON item.id = src.order_item_id
                                 AND item.is_deleted = FALSE
                                JOIN subcontract_orders subcontract_order
                                  ON subcontract_order.id = item.order_id
                                 AND subcontract_order.status = 1
                                 AND subcontract_order.is_deleted = FALSE
                                WHERE src.application_item_id IN (
                                      SELECT DISTINCT allocation.external_item_id
                                      FROM preplan_supply_action_allocations allocation
                                      WHERE allocation.action_id = action.id
                                        AND allocation.external_item_id IS NOT NULL)
                            ),0)), 0)
                    ELSE 0
                END),0)
                FROM preplan_supply_actions action
                WHERE action.analysis_id = :analysisId
                  AND action.action_group_key IN (:groupKeys)
                  AND action.route = :route
                  AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                GROUP BY action.action_group_key
                """;

    private static final String MAKE_SQL = """
                WITH active_actions AS (
                    SELECT action.action_group_key, action.external_document_id AS child_item_id,
                           SUM(action.requested_qty) AS requested_qty
                    FROM preplan_supply_actions action
                    WHERE action.analysis_id = :analysisId
                      AND action.action_group_key IN (:groupKeys)
                      AND action.route = 'MAKE'
                      AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                      AND action.external_document_type = 'PREPLAN_MAKE_TASK'
                      AND action.external_document_id IS NOT NULL
                    GROUP BY action.action_group_key, action.external_document_id
                ), child_open AS (
                    SELECT active.action_group_key, active.child_item_id, active.requested_qty,
                           GREATEST(
                               child.requested_qty - child.approved_qty
                               + COALESCE((
                                   SELECT SUM(GREATEST(
                                       plan_item.qty - COALESCE(plan_item.iqty,0), 0))
                                   FROM production_material_analysis_plan_links analysis_link
                                   JOIN production_plans plan
                                     ON plan.id = analysis_link.plan_id
                                    AND plan.status = 1
                                    AND plan.is_deleted = FALSE
                                    AND plan.is_canceled = FALSE
                                   JOIN production_plan_items plan_item
                                     ON plan_item.plan_id = plan.id
                                    AND plan_item.is_deleted = FALSE
                                   WHERE analysis_link.analysis_item_id = child.id
                                     AND analysis_link.allocation_status = 'APPROVED'
                               ),0), 0) AS open_qty
                    FROM active_actions active
                    JOIN production_material_analysis_items child
                      ON child.id = active.child_item_id
                     AND child.analysis_id = :analysisId
                     AND child.source_type = 'MAKE_COMPONENT'
                     AND child.is_deleted = FALSE
                )
                SELECT action_group_key, COALESCE(SUM(LEAST(requested_qty, open_qty)),0)
                FROM child_open
                GROUP BY action_group_key
                """;

    private static final String SUBCONTRACT_MAKE_SQL = """
                WITH active_actions AS (
                    SELECT action.action_group_key, action.external_document_id AS child_item_id,
                           SUM(action.requested_qty) AS requested_qty
                    FROM preplan_supply_actions action
                    WHERE action.analysis_id = :analysisId
                      AND action.action_group_key IN (:groupKeys)
                      AND action.route = 'SUBCONTRACT'
                      AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                      AND action.external_document_type = 'SUBCONTRACT_MAKE_TASK'
                      AND action.external_document_id IS NOT NULL
                    GROUP BY action.action_group_key, action.external_document_id
                ), child_open AS (
                    SELECT active.action_group_key, active.child_item_id, active.requested_qty,
                           GREATEST(
                               child.requested_qty - child.approved_qty
                               + COALESCE((
                                   SELECT SUM(GREATEST(
                                       plan_item.qty - COALESCE(plan_item.iqty,0), 0))
                                   FROM production_material_analysis_plan_links analysis_link
                                   JOIN production_plans plan
                                     ON plan.id = analysis_link.plan_id
                                    AND plan.status = 1
                                    AND plan.is_deleted = FALSE
                                    AND plan.is_canceled = FALSE
                                   JOIN production_plan_items plan_item
                                     ON plan_item.plan_id = plan.id
                                    AND plan_item.is_deleted = FALSE
                                   WHERE analysis_link.analysis_item_id = child.id
                                     AND analysis_link.allocation_status = 'APPROVED'
                               ),0), 0) AS open_qty
                    FROM active_actions active
                    JOIN production_material_analysis_items child
                      ON child.id = active.child_item_id
                     AND child.analysis_id = :analysisId
                     AND child.source_type = 'SUBCONTRACT_MAKE'
                     AND child.is_deleted = FALSE
                )
                SELECT action_group_key, COALESCE(SUM(LEAST(requested_qty, open_qty)),0)
                FROM child_open
                GROUP BY action_group_key
                """;

    private static final String PURCHASE_JOIN = """
                  JOIN preplan_supply_action_allocations allocation
                    ON allocation.action_id = action.id
                   AND allocation.external_item_id IS NOT NULL
                  JOIN purchase_order_item_sources src
                    ON src.request_item_id = allocation.external_item_id
                  JOIN purchase_order_items order_item
                    ON order_item.id = src.order_item_id
                   AND order_item.is_deleted = FALSE
                  JOIN purchase_orders po ON po.id = order_item.order_id
                   AND po.status = 1 AND po.is_deleted = FALSE
                                  """;

    private static final String SUBCONTRACT_JOIN = """
                  JOIN preplan_supply_action_allocations allocation
                    ON allocation.action_id = action.id
                   AND allocation.external_item_id IS NOT NULL
                  JOIN subcontract_order_item_sources src
                    ON src.application_item_id = allocation.external_item_id
                  JOIN subcontract_order_items order_item
                    ON order_item.id = src.order_item_id
                   AND order_item.is_deleted = FALSE
                  JOIN subcontract_orders po ON po.id = order_item.order_id
                   AND po.status = 1 AND po.is_deleted = FALSE
                                  """;

    private static final String REPLACEMENT_SQL = """
                WITH selected_sources AS (
                    SELECT DISTINCT action.action_group_key,
                           order_item.id AS order_item_id, src.%2$s AS source_item_id,
                           COALESCE(order_item.qty,0) * COALESCE(order_item.unit_rate,1) AS ordered_base,
                           GREATEST((COALESCE(order_item.received_qty,0)
                               - COALESCE(order_item.returned_qty,0))
                               * COALESCE(order_item.unit_rate,1) - COALESCE((
                                   SELECT SUM(rejection.failed_base_qty)
                                   FROM procurement_iqc_rejection_cases rejection
                                   WHERE rejection.receipt_type = :receiptType
                                     AND rejection.order_item_id = order_item.id
                                     AND rejection.is_deleted = FALSE
                                     AND rejection.return_recorded_at IS NOT NULL
                                     AND rejection.status IN (
                                         'RETURN_RECORDED','CREDIT_CONFIRMED',
                                         'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                               ),0),0) AS accounted_base
                    FROM preplan_supply_actions action
                    %1$s
                    WHERE action.analysis_id = :analysisId
                      AND action.action_group_key IN (:groupKeys)
                      AND action.route = :route
                      AND action.status = 'CANCELLED'
                      AND action.cancellation_reason IN (
                          '到货质检存在不合格且原采购需求已无在途，需重新通知补采',
                          '到货质检存在不合格且原委外需求已无在途，需重新通知补委外',
                          '需求或公共安全补库存在终态不合格且已无未来供给，需按失败切片重新通知')
                )
                SELECT action_group_key, COALESCE(SUM(fn_procurement_source_interval_qty(
                    :receiptType, order_item_id, source_item_id, accounted_base, ordered_base)),0)
                FROM selected_sources
                GROUP BY action_group_key
                """;
}
