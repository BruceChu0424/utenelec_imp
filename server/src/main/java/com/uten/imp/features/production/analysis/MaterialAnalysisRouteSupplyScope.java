package com.uten.imp.features.production.analysis;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Supply guards follow proved order identities without rewriting aliases or allocations. */
final class MaterialAnalysisRouteSupplyScope {
    private MaterialAnalysisRouteSupplyScope() { }

    static List<MaterialAnalysisRouteBatchWriter.Change> expand(
            List<MaterialAnalysisRouteBatchWriter.Change> changes,
            Map<UUID, AggregateDelegationProjection.Delegation> delegations,
            Map<UUID, MaterialAnalysisService.MaterialRow> materials) {
        Map<UUID, MaterialAnalysisRouteBatchWriter.Change> scope = new LinkedHashMap<>();
        for (var change : changes) {
            add(scope, change);
            var delegation = delegations.get(change.materialId());
            if (delegation == null) continue;
            for (UUID targetId : delegation.targetMaterialLineIds()) {
                var target = materials.get(targetId);
                if (target == null) throw MaterialAnalysisService.conflict("物料办理来源已变化，请刷新后再修改供应方式");
                add(scope, new MaterialAnalysisRouteBatchWriter.Change(targetId, target.actionGroupKey(),
                        target.goodsId(), change.route(), change.reason()));
            }
        }
        return List.copyOf(scope.values());
    }

    private static void add(Map<UUID, MaterialAnalysisRouteBatchWriter.Change> scope,
            MaterialAnalysisRouteBatchWriter.Change change) {
        var previous = scope.putIfAbsent(change.materialId(), change);
        if (previous != null && !previous.route().equals(change.route()))
            throw MaterialAnalysisService.conflict("同一实际办理节点不能同时选择不同供应方式，请统一后重试");
    }
}
