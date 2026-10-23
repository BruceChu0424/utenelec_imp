package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/** Current master-data admission facts, without changing an admitted analysis's history. */
final class MaterialAnalysisGoodsLifecycleReader {
    private final EntityManager em;

    MaterialAnalysisGoodsLifecycleReader(EntityManager em) { this.em = em; }

    /** Serialize new commitments with status edits; NOWAIT preserves the existing mutation lock order. */
    void lockSources(UUID analysisId) {
        em.createNativeQuery("""
                SELECT goods.id FROM goods
                WHERE goods.id IN (
                    SELECT item.goods_id FROM production_material_analysis_items item
                    WHERE item.analysis_id=:analysisId AND NOT item.is_deleted
                    UNION
                    SELECT material.goods_id FROM production_material_analysis_materials material
                    WHERE material.analysis_id=:analysisId AND material.active)
                ORDER BY goods.id FOR SHARE OF goods NOWAIT
                """).setParameter("analysisId", analysisId).getResultList();
    }

    /**
     * A deleted BOM edge remains stale even after its component is enabled again.
     * Check every snapshotted depth: the direct-layer structure fingerprint alone
     * cannot detect a disabled grandchild. Historical rows remain visible until a
     * safe refresh reconciles them through the existing stock/downstream guards.
     */
    Map<UUID, String> blockedReasons(UUID analysisId) {
        Map<UUID, String> reasons = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery(SQL)
                .setParameter("analysisId", analysisId))) {
            String label = ((row[2] == null ? "" : row[2].toString().strip()) + " "
                    + (row[3] == null ? "" : row[3].toString().strip())).strip();
            if (label.isEmpty()) label = "原货品";
            String reason = switch (String.valueOf(row[1])) {
                case "SOURCE_DELETED" -> "货品「" + label + "」已删除，不能新增安排；已有任务与单据仍保留";
                case "SOURCE_DISABLED" -> "货品「" + label + "」已禁用，不能新增安排；已有任务与单据仍保留";
                case "ORPHAN_SOURCE" -> "「" + label + "」子任务引用的原组装物料已移除，不能新增安排；"
                        + "请先核对原任务和组装信息，重新启用货品不会恢复旧引用";
                case "EMPTY_AFTER_DISABLE" -> "「" + label + "」最后一项生产物料已因禁用移除，"
                        + "请先维护并核对组装信息，不能直接按零物料生产下达";
                case "PERIODIC_CHANGED" -> "BOM 中的「" + label + "」已改为整批领料，请先刷新物料分析；"
                        + "若该物料已有下达单据或专属库存，请先核对原单据与库存用途";
                default -> "BOM 中的「" + label + "」已禁用、删除或组装行已移除，请先刷新物料分析；"
                        + "若该物料已有下达单据或专属库存，请先核对原单据与库存用途";
            };
            reasons.put((UUID) row[0], reason);
        }
        return Map.copyOf(reasons);
    }

    private static final String SQL = """
            WITH manufacturing_nodes AS (
                SELECT item.id AS analysis_item_id, item.goods_id, 0 AS depth
                FROM production_material_analysis_items item
                JOIN goods ON goods.id=item.goods_id
                LEFT JOIN production_material_analysis_materials root_material
                  ON root_material.id=item.root_material_id
                WHERE item.analysis_id=:analysisId AND NOT item.is_deleted
                  AND COALESCE(root_material.confirmed_route,root_material.source_suggestion,
                      CASE goods.source_type WHEN '自制' THEN 'MAKE' WHEN '委外' THEN 'SUBCONTRACT' END)
                      IN ('MAKE','SUBCONTRACT')
                UNION ALL
                SELECT material.analysis_item_id,material.goods_id,material.depth
                FROM production_material_analysis_materials material
                JOIN production_material_analysis_items item
                  ON item.analysis_id=material.analysis_id AND item.id=material.analysis_item_id
                  AND NOT item.is_deleted
                WHERE material.analysis_id=:analysisId AND material.active
                  AND material.node_role='BOM_COMPONENT'
                  AND COALESCE(material.confirmed_route,material.source_suggestion) IN ('MAKE','SUBCONTRACT')
            ), goods_lifecycle_issues AS (
                SELECT item.id AS analysis_item_id,
                       CASE WHEN goods.is_deleted THEN 'SOURCE_DELETED' ELSE 'SOURCE_DISABLED' END AS kind,
                       goods.code, goods.name, 0 AS priority, 0 AS depth
                FROM production_material_analysis_items item
                JOIN goods ON goods.id=item.goods_id
                WHERE item.analysis_id=:analysisId AND NOT item.is_deleted
                  AND (goods.is_deleted OR goods.status='禁用')
                UNION ALL
                SELECT item.id,'ORPHAN_SOURCE',goods.code,goods.name,1,0
                FROM production_material_analysis_items item
                JOIN goods ON goods.id=item.goods_id
                LEFT JOIN production_material_analysis_materials parent
                  ON parent.id=item.parent_analysis_material_id AND parent.analysis_id=item.analysis_id
                WHERE item.analysis_id=:analysisId AND NOT item.is_deleted
                  AND item.parent_analysis_material_id IS NOT NULL
                  AND (parent.id IS NULL OR NOT parent.active)
                UNION ALL
                SELECT material.analysis_item_id,
                       CASE WHEN component.issue_method='PERIODIC' THEN 'PERIODIC_CHANGED' ELSE 'STALE_BOM' END,
                       component.code, component.name,
                       1, material.depth
                FROM production_material_analysis_materials material
                JOIN production_material_analysis_items item
                  ON item.analysis_id=material.analysis_id AND item.id=material.analysis_item_id
                  AND NOT item.is_deleted
                JOIN goods component ON component.id=material.goods_id
                LEFT JOIN goods_bom_items bom ON bom.id=material.bom_item_id
                WHERE material.analysis_id=:analysisId AND material.active
                  AND material.node_role='BOM_COMPONENT'
                  AND (component.is_deleted OR component.status='禁用' OR bom.is_deleted
                       OR component.issue_method='PERIODIC')
                UNION ALL
                SELECT node.analysis_item_id,'EMPTY_AFTER_DISABLE',goods.code,goods.name,2,node.depth
                FROM manufacturing_nodes node JOIN goods ON goods.id=node.goods_id
                WHERE EXISTS (
                    SELECT 1 FROM goods_bom_items retired
                    JOIN goods previous_component ON previous_component.id=retired.component_goods_id
                      AND previous_component.issue_method<>'PERIODIC'
                    WHERE retired.goods_id=node.goods_id AND retired.is_deleted
                      AND retired.retirement_reason='COMPONENT_DISABLED'
                      AND retired.retirement_resolved_at IS NULL
                      AND retired.hard_gate AND retired.control_stage IN ('START','ASSEMBLY','FINISH'))
                  AND NOT EXISTS (
                    SELECT 1 FROM goods_bom_items current_edge
                    JOIN goods current_component ON current_component.id=current_edge.component_goods_id
                      AND NOT current_component.is_deleted AND COALESCE(current_component.status,'使用')<>'禁用'
                      AND NOT COALESCE(current_component.auto_created,FALSE)
                      AND current_component.issue_method<>'PERIODIC'
                    WHERE current_edge.goods_id=node.goods_id AND NOT current_edge.is_deleted
                      AND current_edge.qty>0 AND current_edge.hard_gate
                      AND current_edge.control_stage IN ('START','ASSEMBLY','FINISH'))
            )
            SELECT DISTINCT ON (analysis_item_id) analysis_item_id, kind, code, name
            FROM goods_lifecycle_issues
            ORDER BY analysis_item_id, priority, depth, code NULLS LAST, name NULLS LAST
            """;
}
