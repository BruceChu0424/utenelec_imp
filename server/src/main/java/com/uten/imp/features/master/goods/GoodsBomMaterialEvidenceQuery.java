package com.uten.imp.features.master.goods;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;
import java.util.function.Predicate;

/**
 * 已认料、已申请与仓库已登记的材料身份。它们解释尚未形成 BOM 学习样本的材料，
 * 不代表已经耗用，不提供推测数量，也不创建 BOM 边。调用方先验证父件可见性。
 */
@Service
@RequiredArgsConstructor
public class GoodsBomMaterialEvidenceQuery {
    private final EntityManager em;

    /** sourceCount 按认料/申请单去重，同一申请分仓登记不重复计数。 */
    public record Evidence(String source, String status, UUID componentGoodsId, String componentCode,
                           String componentName, UUID colorId, String colorName, UUID unitId,
                           String unitName, boolean inBom, long sourceCount, OffsetDateTime updatedAt) { }

    public List<Evidence> list(UUID goodsId, Predicate<UUID> visibleOwner) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery(SQL).setParameter("goods", goodsId))
                .stream().filter(row -> visibleOwner.test((UUID) row[12]))
                .map(row -> new Evidence((String) row[0], (String) row[1], (UUID) row[2],
                        (String) row[3], (String) row[4], (UUID) row[5], (String) row[6], (UUID) row[7],
                        (String) row[8], Boolean.TRUE.equals(row[9]), ((Number) row[10]).longValue(),
                        NativeValueConverters.toOffsetDateTime(row[11])))
                .toList();
    }

    static final String SQL = """
            WITH active_requests AS MATERIALIZED (
                SELECT request.id, request.status, request.requested_materials,
                       request.created_at, request.configured_at
                FROM production_execution_segments segment
                JOIN production_plans plan ON plan.id = segment.plan_id
                JOIN production_material_discovery_requests request ON request.execution_segment_id = segment.id
                WHERE segment.product_goods_id = :goods AND NOT segment.is_deleted
                  AND segment.status NOT IN ('CANCELLED', 'REVERSED')
                  AND NOT plan.is_deleted AND NOT plan.is_canceled
                  AND request.status IN ('PENDING', 'CONFIGURED')
                  AND (request.status = 'CONFIGURED' OR NOT plan.is_closed)
            ), evidence AS (
                SELECT 'PERIODIC_CHOICE'::text AS source, 'CONFIRMED'::text AS status,
                       choice.id AS source_id, choice.material_goods_id AS goods_id,
                       choice.material_color_id AS color_id, material.unit_id, choice.chosen_at AS updated_at
                FROM goods_periodic_material_choices choice
                JOIN goods material ON material.id = choice.material_goods_id
                WHERE choice.product_goods_id = :goods AND choice.kind = 'MATERIAL'
                  AND choice.superseded_at IS NULL
                UNION ALL
                SELECT 'DISCOVERY_REQUEST', 'PENDING', request.id,
                       item."goodsId", item."colorId", item."unitId", request.created_at
                FROM active_requests request
                CROSS JOIN LATERAL jsonb_to_recordset(request.requested_materials) AS item(
                    "goodsId" uuid, "colorId" uuid, "unitId" uuid)
                WHERE request.status = 'PENDING'
                UNION ALL
                SELECT 'DISCOVERY_CONFIGURED', 'CONFIGURED', request.id,
                       line.goods_id, line.color_id, line.unit_id, request.configured_at
                FROM active_requests request
                JOIN production_material_discovery_lines line ON line.request_id = request.id
                JOIN production_material_demands demand ON demand.id = line.demand_id AND NOT demand.is_deleted
                WHERE request.status = 'CONFIGURED'
            ), grouped AS (
                SELECT source, status, goods_id, color_id, unit_id,
                       count(DISTINCT source_id) AS source_count, max(updated_at) AS updated_at
                FROM evidence
                GROUP BY source, status, goods_id, color_id, unit_id
            )
            SELECT evidence.source, evidence.status, material.id, material.code, material.name,
                   evidence.color_id, color.name, evidence.unit_id, unit.name,
                   EXISTS(SELECT 1 FROM goods_bom_items edge
                          WHERE edge.goods_id = :goods AND edge.component_goods_id = material.id
                            AND NOT edge.is_deleted AND evidence.unit_id = material.unit_id
                            AND COALESCE(edge.color_id, material.color_id) IS NOT DISTINCT FROM evidence.color_id),
                   evidence.source_count, evidence.updated_at, material.owner_employee_id
            FROM grouped evidence
            JOIN goods material ON material.id = evidence.goods_id AND NOT material.is_deleted AND NOT material.auto_created
            LEFT JOIN units unit ON unit.id = evidence.unit_id
            LEFT JOIN colors color ON color.id = evidence.color_id
            ORDER BY material.code, material.id, evidence.color_id NULLS FIRST, evidence.unit_id, evidence.source
            """;
}
