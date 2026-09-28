package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.CanonicalFingerprint;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;
import java.util.stream.Collectors;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreparationSharedSupplySlice;

/** Read-only facts for one shared editing budget; no reservations are created here. */
final class MaterialPreparationBudgetReader {
    private final EntityManager em;
    MaterialPreparationBudgetReader(EntityManager em) { this.em = em; }

    record Facts(Map<UUID, BigDecimal> privateMakePendingByMaterial,
                 Map<UUID, BigDecimal> outgoingInheritedPendingByMaterial,
                 Map<String, BigDecimal> sharedQtyByPoolKey,
                 Map<UUID, String> poolKeyByMaterial,
                 Map<UUID,List<PreparationSharedSupplySlice>> slicesByMaterial) { }

    Facts read(UUID analysisId, UUID warehouseId, List<MaterialView> materials,
               Set<UUID> selectedWarehouseIds) {
        return read(analysisId,warehouseId,materials,selectedWarehouseIds,null);
    }
    Facts read(UUID analysisId,UUID warehouseId,List<MaterialView> materials,Set<UUID> selectedWarehouseIds,
            Map<UUID,BigDecimal> outgoingSnapshot) {
        if (materials.isEmpty()) return new Facts(Map.of(), Map.of(), Map.of(), Map.of(), Map.of());
        String scope = selectedWarehouseIds.stream().map(UUID::toString).sorted().collect(Collectors.joining(","));
        Map<UUID, String> keys = new HashMap<>();
        Map<String, Map<UUID, BigDecimal>> leaves = new HashMap<>();
        for (MaterialView material : materials) {
            String key = poolKey(warehouseId, material.goodsId(), material.colorId(), material.unitId(), scope);
            keys.put(material.materialLineId(), key);
            for (var leaf : material.warehouseBreakdown()) {
                if (!selectedWarehouseIds.contains(leaf.warehouseId())) continue;
                // Every original BOM occurrence repeats the same warehouse projection.
                // Its analysis-owned pegs are private, never another row's free supply.
                leaves.computeIfAbsent(key, ignored -> new HashMap<>()).merge(leaf.warehouseId(),
                        nonnegative(leaf.availableQty()).subtract(nonnegative(leaf.ownPeggedQty())).max(BigDecimal.ZERO),
                        BigDecimal::max);
            }
        }
        Map<String,Map<String,BigDecimal>> quantitiesByPool = new HashMap<>();
        Map<UUID,Map<String,PreparationSharedSupplySlice>> slices = new HashMap<>();
        for(MaterialView material:materials) {
            String pool=keys.get(material.materialLineId());
            BigDecimal physical=leaves.getOrDefault(pool,Map.of()).values().stream().reduce(BigDecimal.ZERO,BigDecimal::add);
            String key=CanonicalFingerprint.sha256(List.of("PREPARATION-STOCK",pool));
            Map<String,PreparationSharedSupplySlice> row=new LinkedHashMap<>();
            if(physical.signum()>0) {
                row.put(key,new PreparationSharedSupplySlice(key,physical,true));
                quantitiesByPool.computeIfAbsent(pool,ignored->new LinkedHashMap<>()).put(key,physical);
            }
            slices.put(material.materialLineId(),row);
        }
        String goodsIds = materials.stream().map(MaterialView::goodsId).distinct()
                .map(UUID::toString).collect(Collectors.joining(","));
        // A single statement returns a shared physical-source identity and row-specific
        // eligibility. Source UUIDs and private document metadata never leave this reader.
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH sources AS (
                  SELECT 'EXTERNAL_PUBLIC'::text kind,source_action_id source_id,claim_external_item_id item_id,
                         source_analysis_id,goods_id,color_id,unit_id,available_to_claim_qty,warehouse_id
                  FROM fn_preplan_public_surplus_sources(:analysis)
                  UNION ALL
                  SELECT 'MAKE_PUBLIC',source_plan_item_id,NULL::uuid,
                         source_analysis_id,goods_id,color_id,unit_id,available_to_claim_qty,warehouse_id
                  FROM fn_preplan_make_public_supply_sources(:analysis)
                )
                SELECT material.id,source.kind,source.source_id,source.item_id,source.available_to_claim_qty,
                       CASE WHEN source.source_analysis_id<>:analysis THEN TRUE
                            WHEN source.kind='MAKE_PUBLIC'
                              THEN NOT fn_preplan_make_public_target_is_source(source.source_id,material.id)
                            ELSE NOT fn_preplan_public_target_is_source(source.source_id,material.id) END
                FROM sources source
                JOIN production_material_analysis_materials material ON material.analysis_id=:analysis AND material.active
                  AND material.goods_id=source.goods_id AND material.color_id IS NOT DISTINCT FROM source.color_id
                  AND material.unit_id=source.unit_id
                WHERE fn_warehouse_same_main(source.warehouse_id,:warehouse)
                  AND source.goods_id IN (SELECT unnest(CAST(string_to_array(:goods,',') AS uuid[])))
                  AND source.available_to_claim_qty>0
                ORDER BY source.kind,source.source_id,source.item_id,material.id
                """).setParameter("analysis",analysisId).setParameter("warehouse", warehouseId).setParameter("goods", goodsIds))) {
            UUID material=(UUID)row[0];String pool=keys.get(material);
            if(pool==null)continue;
            String key=CanonicalFingerprint.sha256(List.of((String)row[1],row[2].toString(),Objects.toString(row[3],"")));
            BigDecimal qty=nonnegative((BigDecimal)row[4]);
            quantitiesByPool.computeIfAbsent(pool,ignored->new LinkedHashMap<>()).merge(key,qty,BigDecimal::max);
            slices.get(material).put(key,new PreparationSharedSupplySlice(key,qty,Boolean.TRUE.equals(row[5])));
        }
        Map<String,BigDecimal> shared=new HashMap<>();
        quantitiesByPool.forEach((pool,values)->shared.put(pool,values.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add)));
        Map<UUID,List<PreparationSharedSupplySlice>> perMaterial=new HashMap<>();
        slices.forEach((id,values)->perMaterial.put(id,List.copyOf(values.values())));
        return new Facts(privateMakePending(analysisId), outgoingSnapshot==null?outgoingPending(analysisId):outgoingSnapshot,
                Map.copyOf(shared), Map.copyOf(keys),Map.copyOf(perMaterial));
    }

    private Map<UUID, BigDecimal> privateMakePending(UUID analysisId) {
        Map<UUID, BigDecimal> result = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH private_plans AS MATERIALIZED (
                  SELECT origin.id source_id,origin.parent_analysis_material_id,parent.node_role,
                    item.id plan_item_id,link.submitted_qty*COALESCE(item.unit_rate,1) private_qty,
                    plan.is_stopped OR plan.is_closed AS ended
                  FROM production_material_analysis_plan_links link
                  JOIN production_plans plan ON plan.id=link.plan_id
                    AND plan.status IN(0,1) AND NOT plan.is_deleted AND NOT plan.is_canceled
                  JOIN production_plan_items item ON item.plan_id=plan.id AND NOT item.is_deleted
                  JOIN production_material_analysis_items origin ON origin.id=link.analysis_item_id
                    AND NOT origin.is_deleted
                  LEFT JOIN production_material_analysis_materials parent ON parent.id=origin.parent_analysis_material_id
                  WHERE link.analysis_id=:analysis AND link.allocation_status IN('SUBMITTED','APPROVED')
                    AND origin.source_type NOT IN('AGGREGATE_MAKE','SUBCONTRACT_MAKE','SUBCONTRACT_PREPARATION')
                ), progress AS (
                  SELECT source.*,
                    COALESCE((SELECT SUM(output.base_qty) FROM stock_document_items output
                      JOIN stock_documents document ON document.id=output.doc_id AND document.status=1
                        AND NOT document.is_deleted AND document.doc_type='FINISHED_IN'
                      WHERE output.upstream_item_id=source.plan_item_id AND NOT output.is_deleted
                        AND NOT fn_finished_in_is_public_output(output.id)),0) received,
                    CASE WHEN source.ended THEN COALESCE((SELECT SUM(output.qty*COALESCE(output.unit_rate,1))
                      FROM production_daily_report_items output JOIN production_daily_reports document
                        ON document.id=output.report_id AND document.status=1 AND NOT document.is_deleted
                      WHERE output.plan_item_id=source.plan_item_id AND NOT output.is_deleted
                        AND NOT fn_daily_report_is_public_output(output.id)),0) ELSE source.private_qty END produced
                  FROM private_plans source
                )
                SELECT material.id,SUM(GREATEST(LEAST(progress.private_qty,progress.produced)-progress.received,0))
                FROM progress JOIN production_material_analysis_materials material
                  ON material.analysis_id=:analysis AND material.active
                  AND (material.id=progress.parent_analysis_material_id
                    OR (progress.parent_analysis_material_id IS NULL AND material.analysis_item_id=progress.source_id
                      AND material.node_role='ROOT_SUPPLY'))
                GROUP BY material.id
                """).setParameter("analysis", analysisId))) result.put((UUID) row[0], nonnegative((BigDecimal) row[1]));
        return Map.copyOf(result);
    }

    private Map<UUID, BigDecimal> outgoingPending(UUID analysisId) {
        Map<UUID, BigDecimal> result = new HashMap<>();
        // The function allocates an old source's pending supply FIFO among aliases.
        // Summing raw quotas here would count the same source several times.
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT CAST(source->>'sourceMaterialId' AS uuid),
                       SUM(CAST(source->>'pendingQuantity' AS numeric))
                FROM fn_preplan_aggregate_alias_coverage(:analysis) coverage
                CROSS JOIN LATERAL jsonb_array_elements(coverage.source_aliases) source
                GROUP BY CAST(source->>'sourceMaterialId' AS uuid)
                """).setParameter("analysis", analysisId))) result.put((UUID) row[0], nonnegative((BigDecimal) row[1]));
        return Map.copyOf(result);
    }

    static String poolKey(UUID warehouse, UUID goods, UUID color, UUID unit, String scope) {
        return warehouse + "[" + scope + "]|" + goods + "|" + Objects.toString(color, "") + "|" + unit;
    }

    /**
     * 行上下发的共用备料池标识 (preparationPoolKey, 2026-09-27 瘦身): 同一个池同一个值、不同池不同值的
     * 定长不透明串. 内部池键带着本次全部范围仓 ID, 每个节点重复一遍约 600 多字节; 页面只拿它分组比较、
     * 从不拆开读, 所以只下发它的摘要. 同样的输入永远得到同样的值, 前后两次响应之间也能直接比较.
     */
    static String wireKey(String pool) {
        return pool == null ? null : CanonicalFingerprint.sha256(List.of("PREPARATION-POOL", pool));
    }
    private static BigDecimal nonnegative(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value.max(BigDecimal.ZERO);
    }
}
