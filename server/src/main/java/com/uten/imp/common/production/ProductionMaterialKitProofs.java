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
}
