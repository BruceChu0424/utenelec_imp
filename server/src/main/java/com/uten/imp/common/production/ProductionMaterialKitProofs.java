package com.uten.imp.common.production;

import jakarta.persistence.EntityManager;
import java.util.Collection;
import java.util.UUID;

/** Routes existing locked owner boundaries to the single database checkpoint authority. */
public final class ProductionMaterialKitProofs {
    private ProductionMaterialKitProofs() {}

    public static void captureSegment(EntityManager em, UUID segment) {
        if (segment != null) em.createNativeQuery("SELECT fn_capture_execution_full_material_kit(:segment)")
                .setParameter("segment", segment).getResultList();
    }

    public static void captureDemands(EntityManager em, Collection<UUID> demands) {
        if (demands == null || demands.isEmpty()) return;
        em.createNativeQuery("""
                SELECT fn_capture_execution_full_material_kit(source.execution_segment_id)
                FROM (SELECT DISTINCT execution_segment_id FROM production_material_demands
                      WHERE id IN (:ids) AND execution_segment_id IS NOT NULL AND NOT is_deleted) source
                ORDER BY source.execution_segment_id
                """).setParameter("ids", demands).getResultList();
    }

    public static void capturePlanItem(EntityManager em, UUID planItem) {
        if (planItem != null) em.createNativeQuery("""
                SELECT fn_capture_execution_full_material_kit(segment.id)
                FROM production_execution_segments segment
                WHERE segment.source_plan_item_id=:item AND NOT segment.is_deleted ORDER BY segment.id
                """).setParameter("item", planItem).getResultList();
    }

    /** Caller already holds the stock document's complete production mutation graph. */
    public static void captureIssueSources(EntityManager em, Collection<UUID> sourceItems) {
        if (sourceItems == null || sourceItems.isEmpty()) return;
        em.createNativeQuery("""
                SELECT fn_capture_execution_full_material_kit(source.execution_segment_id)
                FROM (SELECT DISTINCT demand.execution_segment_id
                      FROM production_material_stock_postings issue JOIN production_material_demands demand ON demand.id=issue.demand_id
                      WHERE issue.stock_document_item_id IN (:items) AND issue.posting_type='ISSUE'
                        AND demand.execution_segment_id IS NOT NULL AND NOT demand.is_deleted) source
                ORDER BY source.execution_segment_id
                """).setParameter("items", sourceItems).getResultList();
    }

    /** After the complete WDRAW owner has flushed its final lifecycle state. */
    public static void captureReturnDocument(EntityManager em, UUID document, Collection<UUID> sourceItems) {
        var items = sourceItems == null ? java.util.List.<UUID>of() : sourceItems.stream().filter(java.util.Objects::nonNull).distinct().toList();
        String stockSources = items.isEmpty() ? "" : """
                 UNION SELECT demand.execution_segment_id
                 FROM production_material_stock_postings issue JOIN production_material_demands demand ON demand.id=issue.demand_id
                 WHERE issue.stock_document_item_id IN (:items) AND issue.posting_type='ISSUE'
                   AND demand.execution_segment_id IS NOT NULL AND NOT demand.is_deleted
                """;
        var query = em.createNativeQuery("""
                SELECT source.execution_segment_id,EXISTS(
                    SELECT 1 FROM production_execution_segments segment
                    JOIN production_planning_packages package ON package.id=segment.package_id AND NOT package.is_deleted
                    JOIN production_plans plan ON plan.id=package.plan_id AND plan.id=segment.plan_id AND NOT plan.is_deleted
                    JOIN plan_draw_links link ON link.plan_id=plan.id AND link.draw_id=:document AND NOT link.is_deleted
                    WHERE segment.id=source.execution_segment_id AND NOT segment.is_deleted)
                FROM (SELECT execution_segment_id FROM production_material_return_requests WHERE id=:document
                """ + stockSources + ") source ORDER BY source.execution_segment_id").setParameter("document", document);
        if (!items.isEmpty()) query.setParameter("items", items);
        var sources = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(query);
        for (Object[] source : sources) {
            if (!Boolean.TRUE.equals(source[1])) {
                throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,
                        "退料来源工单不在本次已锁定的计划图中，请核对原领退料记录");
            }
        }
        // lockProductionDocumentGraphs already locks these active link -> plan ->
        // package -> segment rows in that order. Never discover a new row lock here.
        for (Object[] source : sources) captureSegment(em,(UUID)source[0]);
    }
}
