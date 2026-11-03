package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.PostgresUuidOrder;
import jakarta.persistence.EntityManager;

import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** One authorized route batch, with bounded SQL and unchanged row-level audit/constraints. */
final class MaterialAnalysisRouteBatchWriter {
    record Change(UUID materialId, String groupKey, UUID goodsId, String route, String reason) {}
    record Result(int materialsChanged, int goodsChanged) {}

    private static final MaterialSnapshotInput GOODS = new MaterialSnapshotInput("goods_id uuid");
    private static final MaterialSnapshotInput ROUTES = new MaterialSnapshotInput(
            "material_id uuid", "group_key varchar", "route varchar", "reason varchar", "suggestion varchar");
    private final EntityManager em;

    MaterialAnalysisRouteBatchWriter(EntityManager em) { this.em = em; }

    /** 人工确认 (PUT /routes): 先按货品 UUID 顺序锁住本批涉及的全部货品行, 再写. */
    Result apply(UUID analysisId, UUID actorId, List<Change> changes, List<Change> supplyScope) {
        return apply(analysisId, actorId, changes, supplyScope, true);
    }

    /** Automatic snapshots read master defaults and never write the goods master. */
    Result applyAutomatic(UUID analysisId, UUID actorId, List<Change> changes) {
        return apply(analysisId, actorId, changes, changes, false);
    }

    private Result apply(UUID analysisId, UUID actorId, List<Change> changes, List<Change> supplyScope, boolean lockEveryGoods) {
        if (changes.isEmpty()) return new Result(0, 0);
        List<UUID> goodsIds = changes.stream().map(Change::goodsId).distinct().sorted(PostgresUuidOrder.INSTANCE).toList();
        String goodsInput = GOODS.json(goodsIds, id -> new Object[] {id});
        var goods = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT goods.id, goods.source_type,
                       fn_goods_has_order_bom(goods.id)
                FROM goods JOIN %s ON input.goods_id=goods.id
                WHERE NOT goods.is_deleted ORDER BY input._position %s
                """.formatted(GOODS.recordset("input"), lockEveryGoods ? "FOR UPDATE OF goods" : ""))
                .setParameter("snapshots", goodsInput));
        if (goods.size() != goodsIds.size()) throw MaterialAnalysisService.conflict("货品资料已变化，请刷新物料分析后重试");
        Map<UUID, String> retainedSuggestions = new HashMap<>();
        for (Object[] row : goods) retainedSuggestions.put((UUID) row[0],
                MaterialAnalysisService.suggestion(Objects.toString(row[1], null), Boolean.TRUE.equals(row[2])));
        if (lockEveryGoods && changes.stream().anyMatch(change ->
                !Objects.equals(change.route(), retainedSuggestions.get(change.goodsId())))) {
            throw MaterialAnalysisService.conflict("排产不能修改产品角色或供应方式；请由有权限的人员在货品资料维护默认来源，再刷新物料分析");
        }

        String routeInput = ROUTES.json(changes.stream().sorted(Comparator.comparing(Change::materialId, PostgresUuidOrder.INSTANCE)).toList(),
                change -> new Object[] {change.materialId(), change.groupKey(), change.route(), change.reason(),
                        retainedSuggestions.get(change.goodsId())});
        String supplyInput = ROUTES.json(supplyScope,
                change -> new Object[] {change.materialId(), change.groupKey(), change.route(), null, null});
        Object[] checked = (Object[]) em.createNativeQuery("""
                WITH input AS MATERIALIZED (SELECT * FROM %s),
                supply_scope AS MATERIALIZED (SELECT * FROM %s), issued_sources AS MATERIALIZED (
                    SELECT source.id, source.parent_analysis_material_id
                    FROM production_material_analysis_plan_links link
                    JOIN production_material_analysis_items source ON source.id=link.analysis_item_id
                        AND source.analysis_id=:analysisId AND NOT source.is_deleted
                    WHERE link.analysis_id=:analysisId AND link.allocation_status IN('SUBMITTED','APPROVED')
                        AND link.submitted_qty+link.public_surplus_qty>0
                ), issued_materials AS MATERIALIZED (
                    SELECT material.id FROM issued_sources source
                    JOIN production_material_analysis_materials material ON material.id=source.parent_analysis_material_id
                        AND material.analysis_id=:analysisId
                    UNION ALL
                    SELECT material.id FROM issued_sources source
                    JOIN production_material_analysis_materials material ON material.analysis_item_id=source.id
                        AND material.analysis_id=:analysisId AND material.node_role='ROOT_SUPPLY'
                ), conflicts AS (
                    SELECT input.material_id FROM supply_scope input JOIN preplan_supply_actions action
                      ON action.analysis_id=:analysisId AND action.action_group_key=input.group_key
                    WHERE action.status<>'CANCELLED' AND action.route IS DISTINCT FROM input.route
                    UNION ALL
                    SELECT input.material_id FROM supply_scope input JOIN preplan_supply_action_allocations allocation
                      ON allocation.analysis_id=:analysisId AND allocation.analysis_material_id=input.material_id
                    JOIN preplan_supply_actions action ON action.id=allocation.action_id AND action.analysis_id=:analysisId
                    WHERE action.status<>'CANCELLED' AND action.route IS DISTINCT FROM input.route
                    UNION ALL
                    SELECT input.material_id FROM supply_scope input
                    JOIN preplan_aggregate_batches batch ON batch.analysis_id=:analysisId
                    JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
                    JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id
                        AND event.event_type IN('CREATE','APPEND')
                    WHERE action.route IS DISTINCT FROM input.route AND jsonb_exists(COALESCE(
                        event.intent_snapshot->'originalMaterialLineIds',batch.configuration_snapshot->'originalMaterialLineIds',
                        event.intent_snapshot->'materialLineIds','[]'::jsonb),input.material_id::text)
                    UNION ALL
                    SELECT input.material_id FROM supply_scope input
                    JOIN issued_materials issued ON issued.id=input.material_id
                    WHERE input.route<>'MAKE'
                )
                SELECT (SELECT count(*) FROM input JOIN production_material_analysis_materials material
                        ON material.id=input.material_id AND material.analysis_id=:analysisId AND material.active),
                       EXISTS(SELECT 1 FROM conflicts)
                """.formatted(ROUTES.recordset("selected"), ROUTES.recordset("guarded").replace(":snapshots", ":supplySnapshots")))
                .setParameter("analysisId", analysisId).setParameter("snapshots", routeInput)
                .setParameter("supplySnapshots", supplyInput).getSingleResult();
        if (((Number) checked[0]).intValue() != changes.size()) throw MaterialAnalysisService.conflict("物料节点已变化，请刷新后重试");
        if (Boolean.TRUE.equals(checked[1])) throw MaterialAnalysisService.conflict("物料操作组已有不同路线的下游任务，请先撤回后再改路线");

        int materialCount = em.createNativeQuery("""
                WITH input AS MATERIALIZED (SELECT * FROM %s), changed AS MATERIALIZED (
                    SELECT material.id FROM production_material_analysis_materials material
                    JOIN input ON input.material_id=material.id
                    WHERE material.analysis_id=:analysisId AND material.active AND (
                        material.confirmed_route IS DISTINCT FROM input.route
                        OR material.source_suggestion IS DISTINCT FROM input.suggestion
                        OR material.route_reason IS DISTINCT FROM input.reason
                        OR material.route_confirmed_by IS NULL OR material.route_confirmed_at IS NULL)
                    ORDER BY input._position FOR UPDATE OF material
                )
                UPDATE production_material_analysis_materials material
                SET confirmed_route = input.route, source_suggestion = input.suggestion,
                    route_reason = input.reason, route_confirmed_by = :actorId,
                    route_confirmed_at = now(), updated_at = now(), updated_by = :actorId
                FROM input JOIN changed ON changed.id=input.material_id
                WHERE material.id=input.material_id AND material.analysis_id=:analysisId AND material.active
                """.formatted(ROUTES.recordset("selected")))
                .setParameter("analysisId", analysisId).setParameter("actorId", actorId)
                .setParameter("snapshots", routeInput).executeUpdate();
        // Planning stores its own route snapshot. Only the goods-master service may change the product role.
        return new Result(materialCount, 0);
    }
}
