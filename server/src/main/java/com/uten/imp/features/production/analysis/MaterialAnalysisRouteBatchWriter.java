package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.PostgresUuidOrder;
import jakarta.persistence.EntityManager;

import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** One authorized route batch, with bounded SQL and unchanged row-level audit/constraints. */
final class MaterialAnalysisRouteBatchWriter {
    record Change(UUID materialId, String groupKey, UUID goodsId, String route, String reason) {}
    record Result(int materialsChanged, int goodsChanged) {}

    private static final MaterialSnapshotInput GOODS = new MaterialSnapshotInput("goods_id uuid", "source_type varchar");
    private static final MaterialSnapshotInput ROUTES = new MaterialSnapshotInput(
            "material_id uuid", "group_key varchar", "route varchar", "reason varchar", "suggestion varchar");
    private final EntityManager em;

    MaterialAnalysisRouteBatchWriter(EntityManager em) { this.em = em; }

    Result apply(UUID analysisId, UUID actorId, List<Change> changes) {
        if (changes.isEmpty()) return new Result(0, 0);
        Map<UUID, String> goodsRoutes = new HashMap<>();
        var mixedGoods = new HashSet<UUID>();
        for (Change change : changes) {
            String prior = goodsRoutes.putIfAbsent(change.goodsId(), change.route());
            if (prior != null && !prior.equals(change.route())) mixedGoods.add(change.goodsId());
        }
        // Lock order matches PostgreSQL UUID ordering and every other goods writer.
        List<UUID> goodsIds = goodsRoutes.keySet().stream().sorted(PostgresUuidOrder.INSTANCE).toList();
        String goodsInput = GOODS.json(goodsIds, id -> new Object[] {id,
                mixedGoods.contains(id) ? null : MaterialAnalysisService.sourceTypeForRoute(goodsRoutes.get(id))});
        var goods = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT goods.id, goods.source_type,
                       EXISTS (SELECT 1 FROM goods_bom_items bom WHERE bom.goods_id=goods.id AND NOT bom.is_deleted)
                FROM goods JOIN %s ON input.goods_id=goods.id
                WHERE NOT goods.is_deleted ORDER BY input._position FOR UPDATE OF goods
                """.formatted(GOODS.recordset("input"))).setParameter("snapshots", goodsInput));
        if (goods.size() != goodsIds.size()) throw MaterialAnalysisService.conflict("货品资料已变化，请刷新物料分析后重试");
        Map<UUID, String> retainedSuggestions = new HashMap<>();
        for (Object[] row : goods) retainedSuggestions.put((UUID) row[0],
                MaterialAnalysisService.suggestion(Objects.toString(row[1], null), Boolean.TRUE.equals(row[2])));

        String routeInput = ROUTES.json(changes.stream().sorted(Comparator.comparing(Change::materialId, PostgresUuidOrder.INSTANCE)).toList(),
                change -> new Object[] {change.materialId(), change.groupKey(), change.route(), change.reason(),
                        mixedGoods.contains(change.goodsId()) ? retainedSuggestions.get(change.goodsId()) : change.route()});
        Object[] checked = (Object[]) em.createNativeQuery("""
                WITH input AS MATERIALIZED (SELECT * FROM %s), conflicts AS (
                    SELECT input.material_id FROM input JOIN preplan_supply_actions action
                      ON action.analysis_id=:analysisId AND action.action_group_key=input.group_key
                    WHERE action.status<>'CANCELLED' AND action.route IS DISTINCT FROM input.route
                    UNION ALL
                    SELECT input.material_id FROM input JOIN preplan_supply_action_allocations allocation
                      ON allocation.analysis_id=:analysisId AND allocation.analysis_material_id=input.material_id
                    JOIN preplan_supply_actions action ON action.id=allocation.action_id AND action.analysis_id=:analysisId
                    WHERE action.status<>'CANCELLED' AND action.route IS DISTINCT FROM input.route
                )
                SELECT (SELECT count(*) FROM input JOIN production_material_analysis_materials material
                        ON material.id=input.material_id AND material.analysis_id=:analysisId AND material.active),
                       EXISTS(SELECT 1 FROM conflicts)
                """.formatted(ROUTES.recordset("selected")))
                .setParameter("analysisId", analysisId).setParameter("snapshots", routeInput).getSingleResult();
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
        int goodsCount = em.createNativeQuery("""
                UPDATE goods SET source_type = input.source_type, version = goods.version + 1,
                    updated_at = now(), updated_by = :actorId
                FROM %s
                WHERE goods.id=input.goods_id AND NOT goods.is_deleted AND input.source_type IS NOT NULL
                  AND goods.source_type IS DISTINCT FROM input.source_type
                """.formatted(GOODS.recordset("input")))
                .setParameter("snapshots", goodsInput).setParameter("actorId", actorId).executeUpdate();
        return new Result(materialCount, goodsCount);
    }
}
