package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Reads an admitted batch's BOM graphs in two bounded database round trips.
 * Validation retains cycle, depth and deleted-master guards. Rows remain keyed
 * by the analysis item UUID so repeated goods never merge independent demand.
 * The result is scoped to this invocation; no cache survives a master-data edit.
 * Parameterized lateral edge reads retain the current root/frontier bound when
 * PostgreSQL estimates a large recursive forest; unrelated historical BOMs must
 * not become the recursive step's input. OFFSET 0 preserves that query boundary.
 */
final class MaterialAnalysisBomSnapshotReader {
    private final EntityManager em;

    MaterialAnalysisBomSnapshotReader(EntityManager em) { this.em = em; }

    Map<UUID, List<Object[]>> read(List<MaterialAnalysisService.SourceLine> sources) {
        if (sources.isEmpty()) return Map.of();
        for (var source : sources) {
            if (source.unitRate() == null || source.unitRate().signum() <= 0) {
                throw conflict("生产需求单位换算率必须大于零");
            }
        }
        validate(sources.stream().map(MaterialAnalysisService.SourceLine::goodsId).distinct().toList());
        StringBuilder roots = new StringBuilder("VALUES ");
        for (int i = 0; i < sources.size(); i++) {
            if (i > 0) roots.append(',');
            roots.append("(CAST(:source").append(i).append(" AS uuid),CAST(:goods")
                    .append(i).append(" AS uuid),CAST(:rate").append(i).append(" AS numeric))");
        }
        Query query = em.createNativeQuery(TREE_SQL.formatted(roots));
        for (int i = 0; i < sources.size(); i++) {
            var source = sources.get(i);
            query.setParameter("source" + i, source.analysisItemId())
                    .setParameter("goods" + i, source.goodsId())
                    .setParameter("rate" + i, source.unitRate());
        }
        Map<UUID, List<Object[]>> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            result.computeIfAbsent((UUID) row[24], ignored -> new ArrayList<>()).add(row);
        }
        return result;
    }

    private void validate(List<UUID> goodsIds) {
        Object[] row = NativeQueryResults.objectArrayRows(em.createNativeQuery(VALIDATION_SQL)
                .setParameter("goodsIds", goodsIds)).getFirst();
        if (Boolean.TRUE.equals(row[0])) throw conflict("BOM 存在循环引用，不能进行物料分析");
        if (Boolean.TRUE.equals(row[1])) throw conflict("BOM 超过十层，不能静默截断分析");
        if (Boolean.TRUE.equals(row[2])) {
            throw conflict("BOM 存在非正用量、失效组件、颜色或基本单位异常");
        }
    }

    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }

    private static final String TREE_SQL = """
                WITH RECURSIVE roots(analysis_item_id, goods_id, unit_rate) AS (%s), exp AS (
                    SELECT roots.analysis_item_id AS source_id, b.id AS bom_item_id, b.goods_id AS parent_goods_id,
                           b.component_goods_id AS goods_id,
                           resolved_color.id AS color_id,
                           component_unit.id AS unit_id,
                           1 AS depth, ARRAY[b.id]::uuid[] AS bom_path,
                           roots.unit_rate AS parent_per_product_qty,
                           b.qty AS bom_qty,
                           (roots.unit_rate * b.qty /
                                CASE WHEN b.consumption_basis = 'PER_UNIT' THEN 1
                                     ELSE b.basis_output_qty END
                           )::numeric AS per_product_qty,
                           component.code, component.name, component.spec,
                           resolved_color.name AS color_name,
                           component_unit.name AS unit_name,
                           GREATEST(COALESCE(component.min_qty,0),0)::numeric AS safety_stock,
                           component.source_type,
                           EXISTS (SELECT 1 FROM goods_bom_items child
                                   WHERE child.goods_id = b.component_goods_id
                                     AND child.is_deleted = FALSE LIMIT 1 OFFSET 0) AS has_children,
                           b.control_stage, b.consumption_basis,
                           b.basis_output_qty, b.allow_partial_package, b.hard_gate
                    FROM roots
                    JOIN LATERAL (
                        SELECT edge.* FROM goods_bom_items edge
                        WHERE edge.goods_id = roots.goods_id AND edge.is_deleted = FALSE
                        OFFSET 0
                    ) b ON TRUE
                    JOIN goods component ON component.id = b.component_goods_id
                                         AND component.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, component.color_id)
                                                    AND resolved_color.is_deleted = FALSE
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                                                   AND component_unit.is_deleted = FALSE
                    WHERE b.is_deleted = FALSE
                    UNION ALL
                    SELECT exp.source_id, b.id, b.goods_id, b.component_goods_id,
                           resolved_color.id,
                           component_unit.id,
                           exp.depth + 1, exp.bom_path || b.id,
                           exp.per_product_qty,
                           b.qty,
                           (exp.per_product_qty * b.qty /
                                CASE WHEN b.consumption_basis = 'PER_UNIT' THEN 1
                                     ELSE b.basis_output_qty END
                           )::numeric,
                           component.code, component.name, component.spec,
                           resolved_color.name,
                           component_unit.name,
                           GREATEST(COALESCE(component.min_qty,0),0)::numeric,
                           component.source_type,
                           EXISTS (SELECT 1 FROM goods_bom_items child
                                   WHERE child.goods_id = b.component_goods_id
                                     AND child.is_deleted = FALSE LIMIT 1 OFFSET 0),
                           b.control_stage, b.consumption_basis,
                           b.basis_output_qty, b.allow_partial_package, b.hard_gate
                    FROM exp
                    JOIN LATERAL (
                        SELECT edge.* FROM goods_bom_items edge
                        WHERE edge.goods_id = exp.goods_id AND edge.is_deleted = FALSE
                        OFFSET 0
                    ) b ON TRUE
                    JOIN goods component ON component.id = b.component_goods_id
                                         AND component.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, component.color_id)
                                                    AND resolved_color.is_deleted = FALSE
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                                                   AND component_unit.is_deleted = FALSE
                    WHERE exp.depth < 10 AND NOT b.id = ANY(exp.bom_path)
                )
                SELECT bom_item_id, parent_goods_id, goods_id, color_id, unit_id,
                       depth, array_to_string(bom_path, '/'),
                        CASE WHEN depth = 1 THEN NULL
                             ELSE array_to_string(trim_array(bom_path, 1), '/') END,
                       parent_per_product_qty, bom_qty, per_product_qty,
                       code, name, spec, color_name, unit_name,
                       safety_stock, source_type, has_children,
                       control_stage, consumption_basis, basis_output_qty,
                       allow_partial_package, hard_gate, source_id
                FROM exp
                ORDER BY source_id, bom_path
                """;

    private static final String VALIDATION_SQL = """
                WITH RECURSIVE walk AS (
                    SELECT b.id, b.component_goods_id AS goods_id, 1 AS depth,
                           ARRAY[b.id]::uuid[] AS path, FALSE AS cycle,
                            (b.qty <= 0 OR component.is_deleted
                             OR component.unit_id IS NULL OR component_unit.id IS NULL
                             OR (COALESCE(b.color_id, component.color_id) IS NOT NULL
                                 AND resolved_color.id IS NULL)
                             OR (b.color_id IS NULL
                                 AND NULLIF(b.color_legacy_id,0) IS NOT NULL)
                             OR (component.color_id IS NULL
                                 AND NULLIF(component.color_legacy_id,0) IS NOT NULL)) AS invalid
                    FROM goods_bom_items b
                    JOIN goods component ON component.id = b.component_goods_id
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                                                   AND component_unit.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, component.color_id)
                                                    AND resolved_color.is_deleted = FALSE
                    WHERE b.goods_id IN (:goodsIds) AND b.is_deleted = FALSE
                    UNION ALL
                    SELECT b.id, b.component_goods_id, walk.depth + 1,
                           walk.path || b.id, b.id = ANY(walk.path),
                            (walk.invalid OR b.qty <= 0 OR component.is_deleted
                             OR component.unit_id IS NULL OR component_unit.id IS NULL
                             OR (COALESCE(b.color_id, component.color_id) IS NOT NULL
                                 AND resolved_color.id IS NULL)
                             OR (b.color_id IS NULL
                                 AND NULLIF(b.color_legacy_id,0) IS NOT NULL)
                             OR (component.color_id IS NULL
                                 AND NULLIF(component.color_legacy_id,0) IS NOT NULL))
                    FROM walk
                    JOIN LATERAL (
                        SELECT edge.* FROM goods_bom_items edge
                        WHERE edge.goods_id = walk.goods_id AND edge.is_deleted = FALSE
                        OFFSET 0
                    ) b ON TRUE
                    JOIN goods component ON component.id = b.component_goods_id
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                                                   AND component_unit.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, component.color_id)
                                                    AND resolved_color.is_deleted = FALSE
                    WHERE walk.depth <= 10 AND walk.cycle = FALSE
                )
                SELECT COALESCE(bool_or(cycle),FALSE),
                       COALESCE(bool_or(depth > 10),FALSE),
                       COALESCE(bool_or(invalid),FALSE)
                FROM walk
                """;
}
