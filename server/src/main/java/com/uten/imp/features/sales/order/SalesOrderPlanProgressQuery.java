package com.uten.imp.features.sales.order;

import com.uten.imp.features.sales.order.dto.PlanProgressLine.MaterialAnalysisProgress;
import com.uten.imp.features.sales.order.dto.PlanProgressLine.SupplyActionProgress;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Sales-safe query projection for the V234 pre-plan analysis lifecycle. */
@Component
@RequiredArgsConstructor
class SalesOrderPlanProgressQuery {

    private final EntityManager em;

    /** Readiness is the authoritative shared-pool snapshot persisted by analysis refresh. */
    @SuppressWarnings("unchecked")
    Map<UUID, List<MaterialAnalysisProgress>> load(List<UUID> orderItemIds) {
        if (orderItemIds.isEmpty()) return Map.of();

        List<Object[]> sourceRows = em.createNativeQuery("""
                SELECT ai.analysis_id, ai.id, ai.sales_order_item_id,
                       analysis.status, analysis.analyzed_at,
                       ai.requested_qty, ai.submitted_qty, ai.approved_qty,
                       ai.delivery_date, ai.line_priority,
                       goods.production_bom_policy,
                       ai.ready_now_qty, ai.ready_by_date_qty,
                       CASE
                           WHEN ai.ready_now_qty <
                                ai.requested_qty-ai.submitted_qty-ai.approved_qty
                            AND ai.ready_by_date_qty >=
                                ai.requested_qty-ai.submitted_qty-ai.approved_qty
                           THEN (
                               SELECT MAX(material.expected_ready_date)
                               FROM production_material_analysis_materials material
                               WHERE material.analysis_id = ai.analysis_id
                                 AND material.analysis_item_id = ai.id
                                 AND material.depth = 1
                                 AND material.active = TRUE
                                 AND material.expected_ready_date IS NOT NULL
                           )
                           ELSE NULL
                       END AS expected_ready_date
                FROM production_material_analysis_items ai
                JOIN production_material_analyses analysis
                  ON analysis.id = ai.analysis_id
                JOIN goods ON goods.id = ai.goods_id
                WHERE ai.analysis_id IN (
                    SELECT DISTINCT selected.analysis_id
                    FROM production_material_analysis_items selected
                    WHERE selected.sales_order_item_id IN (:orderItemIds)
                      AND selected.is_deleted = FALSE
                )
                  AND ai.is_deleted = FALSE
                  AND analysis.is_deleted = FALSE
                ORDER BY ai.analysis_id, ai.line_priority,
                         ai.delivery_date NULLS LAST, ai.id
                """).setParameter("orderItemIds", orderItemIds).getResultList();
        if (sourceRows.isEmpty()) return Map.of();

        Map<UUID, List<SourceSnapshot>> sourcesByAnalysis = new LinkedHashMap<>();
        for (Object[] row : sourceRows) {
            SourceSnapshot source = new SourceSnapshot(
                     (UUID) row[0], (UUID) row[1], (UUID) row[2],
                     (String) row[3], offsetDateTime(row[4]),
                     decimal(row[5]), decimal(row[6]), decimal(row[7]),
                     localDate(row[8]), (String) row[10],
                     decimal(row[11]), decimal(row[12]), localDate(row[13]));
            sourcesByAnalysis.computeIfAbsent(source.analysisId(), ignored -> new ArrayList<>())
                    .add(source);
        }
        List<UUID> analysisIds = List.copyOf(sourcesByAnalysis.keySet());

        List<Object[]> actionRows = em.createNativeQuery("""
                SELECT material.analysis_item_id, action.id, action.route,
                       action.status, SUM(allocation.allocated_qty), action.need_date
                FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action
                  ON action.id = allocation.action_id
                 AND action.analysis_id = allocation.analysis_id
                JOIN production_material_analysis_materials material
                  ON material.id = allocation.analysis_material_id
                 AND material.analysis_id = allocation.analysis_id
                WHERE action.analysis_id IN (:analysisIds)
                GROUP BY material.analysis_item_id, action.id, action.route,
                         action.status, action.need_date, action.created_at
                ORDER BY material.analysis_item_id, action.created_at, action.id
                """).setParameter("analysisIds", analysisIds).getResultList();
        Map<UUID, List<SupplyActionProgress>> actionsByAnalysisItem = new HashMap<>();
        for (Object[] row : actionRows) {
            actionsByAnalysisItem.computeIfAbsent((UUID) row[0], ignored -> new ArrayList<>())
                    .add(new SupplyActionProgress(
                            (UUID) row[1], (String) row[2], (String) row[3],
                            decimal(row[4]), localDate(row[5])));
        }

        return build(orderItemIds, sourcesByAnalysis, actionsByAnalysisItem);
    }

    private static Map<UUID, List<MaterialAnalysisProgress>> build(
            List<UUID> orderItemIds,
            Map<UUID, List<SourceSnapshot>> sourcesByAnalysis,
            Map<UUID, List<SupplyActionProgress>> actionsByAnalysisItem) {
        Set<UUID> selectedOrderItemIds = Set.copyOf(orderItemIds);
        Map<UUID, List<MaterialAnalysisProgress>> result = new HashMap<>();
        for (Map.Entry<UUID, List<SourceSnapshot>> entry : sourcesByAnalysis.entrySet()) {
            for (SourceSnapshot source : entry.getValue()) {
                BigDecimal remainingQty = source.requestedQty()
                        .subtract(source.submittedQty())
                        .subtract(source.approvedQty())
                        .max(BigDecimal.ZERO);
                BigDecimal readyNowQty = source.readyNowQty().min(remainingQty);
                BigDecimal readyByDateQty = source.readyByDateQty().min(remainingQty);

                if (source.salesOrderItemId() == null
                        || !selectedOrderItemIds.contains(source.salesOrderItemId())) {
                    continue;
                }
                result.computeIfAbsent(
                                source.salesOrderItemId(), ignored -> new ArrayList<>())
                        .add(new MaterialAnalysisProgress(
                                 source.analysisId(), source.status(), source.analyzedAt(),
                                 source.requestedQty(), source.submittedQty(), source.approvedQty(),
                                 remainingQty, readyNowQty, readyByDateQty,
                                 source.expectedReadyDate(),
                                List.copyOf(actionsByAnalysisItem.getOrDefault(
                                        source.analysisItemId(), List.of()))));
            }
        }
        result.replaceAll((ignored, analyses) -> analyses.stream()
                .sorted(Comparator
                        .comparing(MaterialAnalysisProgress::analyzedAt,
                                Comparator.nullsLast(Comparator.reverseOrder()))
                        .thenComparing(value -> value.analysisId().toString()))
                .toList());
        return result;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        return ((java.sql.Date) value).toLocalDate();
    }

    private static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime dateTime) return dateTime;
        if (value instanceof java.time.ZonedDateTime dateTime) {
            return dateTime.toOffsetDateTime();
        }
        if (value instanceof java.time.Instant instant) {
            return instant.atOffset(java.time.ZoneOffset.UTC);
        }
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toInstant().atOffset(java.time.ZoneOffset.UTC);
        }
        throw new IllegalArgumentException("Unsupported timestamp type: " + value.getClass());
    }

    private record SourceSnapshot(
            UUID analysisId,
            UUID analysisItemId,
            UUID salesOrderItemId,
            String status,
            OffsetDateTime analyzedAt,
            BigDecimal requestedQty,
            BigDecimal submittedQty,
            BigDecimal approvedQty,
            LocalDate deliveryDate,
            String productionBomPolicy,
            BigDecimal readyNowQty,
            BigDecimal readyByDateQty,
            LocalDate expectedReadyDate) {
    }
}
