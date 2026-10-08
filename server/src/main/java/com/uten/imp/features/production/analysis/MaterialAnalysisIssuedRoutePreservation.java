package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** Preserves an existing order's route through snapshot refresh, never a new master-data decision. */
final class MaterialAnalysisIssuedRoutePreservation {
    private MaterialAnalysisIssuedRoutePreservation() { }

    record Identity(UUID id, UUID analysisItemId, String nodeKey, UUID goodsId, UUID colorId, UUID unitId,String confirmedRoute) {
        String key() { return analysisItemId+"|"+nodeKey; }
        boolean sameMaterial(Identity other) {
            return other!=null && Objects.equals(goodsId,other.goodsId)
                    && Objects.equals(colorId,other.colorId) && Objects.equals(unitId,other.unitId);
        }
    }
    record Proofs(Map<UUID,Set<String>> routes,Map<UUID,String> dependencyRoutes,Set<UUID> dependenciesMissingRoute) { }
    record SourceLinks(Map<UUID,AggregateDelegationProjection.Delegation> delegations,
                       Map<UUID,Map<UUID,BigDecimal>> inheritedByTarget) {
        static final SourceLinks EMPTY=new SourceLinks(Map.of(),Map.of());
    }

    /** Positive inherited coverage carries supply identity; a zero alias carries no route authority. */
    static Proofs inherit(Proofs direct,List<Identity> materials,Map<UUID,Map<UUID,BigDecimal>> inheritedByTarget) {
        Map<UUID,Identity> byId=new HashMap<>();materials.forEach(material->byId.put(material.id(),material));
        Map<UUID,Set<String>> routes=new HashMap<>();direct.routes().forEach((id,values)->routes.put(id,new HashSet<>(values)));
        Map<UUID,String> dependencies=new HashMap<>(direct.dependencyRoutes());
        Set<UUID> missing=new HashSet<>(direct.dependenciesMissingRoute());
        Map<UUID,Set<UUID>> outgoing=new HashMap<>();Map<UUID,Integer> incomingCount=new HashMap<>();
        for(var target:inheritedByTarget.entrySet())for(var source:target.getValue().entrySet()) {
            if(source.getValue()==null||source.getValue().signum()<0)throw conflict("继承供给数量证明不完整，请先核对来源单据");
            if(source.getValue().signum()==0)continue;
            Identity from=byId.get(source.getKey()),to=byId.get(target.getKey());
            if(from==null||to==null||!from.sameMaterial(to))throw conflict("继承供给的物料身份不完整或不一致，请先核对来源单据");
            incomingCount.putIfAbsent(from.id(),0);incomingCount.putIfAbsent(to.id(),0);
            if(outgoing.computeIfAbsent(from.id(),ignored->new HashSet<>()).add(to.id()))incomingCount.merge(to.id(),1,Integer::sum);
        }
        var ready=new java.util.PriorityQueue<UUID>(java.util.Comparator.comparing(UUID::toString));
        incomingCount.forEach((id,count)->{if(count==0)ready.add(id);});int visited=0;
        while(!ready.isEmpty()) {
            UUID source=ready.remove();visited++;
            Set<String> sourceRoutes=routes.getOrDefault(source,Set.of());
            for(UUID target:outgoing.getOrDefault(source,Set.of())) {
                if(!sourceRoutes.isEmpty())routes.computeIfAbsent(target,ignored->new HashSet<>()).addAll(sourceRoutes);
                else if(dependencies.containsKey(source)||missing.contains(source)) {
                    // Adopted supply protects the recipient's prior decision, never the donor's route.
                    String recipientRoute=byId.get(target).confirmedRoute();
                    if(recipientRoute==null)missing.add(target);else dependencies.put(target,recipientRoute);
                }
                if(incomingCount.merge(target,-1,Integer::sum)==0)ready.add(target);
            }
        }
        if(visited!=incomingCount.size())throw conflict("继承供给来源存在循环，请先核对真实来源单据");
        Map<UUID,Set<String>> immutable=new HashMap<>();routes.forEach((id,values)->immutable.put(id,Set.copyOf(values)));
        return new Proofs(Map.copyOf(immutable),Map.copyOf(dependencies),Set.copyOf(missing));
    }

    static Map<String,String> project(List<Identity> previous, Map<String,Identity> incoming,
            Proofs direct,
            Map<UUID,AggregateDelegationProjection.Delegation> delegations) {
        Map<UUID,Identity> byId=new HashMap<>();
        previous.forEach(row->byId.put(row.id(),row));
        Map<String,String> result=new LinkedHashMap<>();
        for(Identity row:previous) {
            Set<String> routes=new HashSet<>(direct.routes().getOrDefault(row.id(),Set.of()));
            Set<String> dependencyRoutes=new HashSet<>();
            if(direct.dependencyRoutes().containsKey(row.id()))dependencyRoutes.add(direct.dependencyRoutes().get(row.id()));
            boolean missingRoute=direct.dependenciesMissingRoute().contains(row.id());
            var delegation=delegations.get(row.id());
            if(delegation!=null)for(UUID targetId:delegation.targetMaterialLineIds()) {
                Identity target=byId.get(targetId);
                if(target==null)throw conflict("已下达供给的原物料关联不完整，请核对来源单据后再刷新");
                Set<String> targetRoutes=direct.routes().getOrDefault(targetId,Set.of());
                missingRoute|=direct.dependenciesMissingRoute().contains(targetId);
                if(direct.dependencyRoutes().containsKey(targetId))dependencyRoutes.add(direct.dependencyRoutes().get(targetId));
                if((!targetRoutes.isEmpty()||direct.dependencyRoutes().containsKey(targetId)||direct.dependenciesMissingRoute().contains(targetId))&&!row.sameMaterial(target))
                    throw conflict("已下达供给与原物料的货品、颜色或单位不一致，请先核对来源单据");
                routes.addAll(targetRoutes);
            }
            if(routes.isEmpty()) {
                if(missingRoute)throw conflict("此物料已有有效认领或调入，但原供应方式记录缺失，请先核对并撤回认领或调入后重新选择");
                routes.addAll(dependencyRoutes);
            }
            if(routes.isEmpty())continue;
            if(routes.size()!=1)throw conflict("同一物料来源已有不同供应方式的有效单据，请先核对并撤回冲突单据");
            if(!row.sameMaterial(incoming.get(row.key())))
                throw conflict("已下达供给的物料身份发生变化，请先核对货品、颜色和单位及原单据");
            result.put(row.key(),routes.iterator().next());
        }
        return Map.copyOf(result);
    }

    static Proofs directRoutes(List<Identity> materials,
            Map<UUID,List<DownstreamReference>> references,List<SupplyActionView> actions,
            Map<UUID,UUID> anchors,List<MaterialAnalysisService.SourceLine> sources) {
        Map<UUID,SupplyActionView> byAction=new HashMap<>();
        actions.forEach(action->byAction.put(action.actionId(),action));
        Map<UUID,MaterialAnalysisService.SourceLine> bySource=new HashMap<>();
        sources.forEach(source->bySource.put(source.analysisItemId(),source));
        Map<UUID,Set<String>> result=new HashMap<>();
        Map<UUID,String> dependencyRoutes=new HashMap<>();
        Set<UUID> missingRoutes=new HashSet<>();
        for(Identity material:materials) {
            Set<String> routes=new HashSet<>();
            for(DownstreamReference ref:references.getOrDefault(material.id(),List.of())) {
                SupplyActionView action=ref.actionId()==null?null:byAction.get(ref.actionId());
                if(action==null||"CANCELLED".equals(action.status())||"CANCELLED".equals(ref.status())
                        ||!(positive(action.requestedQty())||positive(action.publicSurplusQty())||positive(action.safetyReplenishmentQty())))continue;
                String operation=Objects.toString(action.operationType(),"");
                boolean dependency=Set.of("SHARED_FUTURE_CLAIM","FUTURE_TRANSFER","AGGREGATE_CONTINUATION").contains(operation);
                if(!dependency&&!Set.of("SUPPLY","AGGREGATE_SUPPLY").contains(operation))continue;
                if(!Objects.equals(material.goodsId(),action.goodsId())||!Objects.equals(material.colorId(),action.colorId())
                        ||!Objects.equals(material.unitId(),action.unitId()))
                    throw conflict("已下达供给与当前物料身份不一致，请核对货品、颜色和单位及原单据");
                // Transfers keep the donor's route in action.route. Only the recipient's
                // existing confirmation proves its route; adopted supply is never a new order.
                String route=dependency?material.confirmedRoute():action.route();
                if(dependency&&route==null){missingRoutes.add(material.id());continue;}
                if(!Set.of("BUY","MAKE","SUBCONTRACT").contains(Objects.toString(route,"")))
                    throw conflict("已下达供给缺少明确供应方式，请核对原单据");
                if(dependency)dependencyRoutes.put(material.id(),route);
                else routes.add(route);
            }
            UUID anchorId=anchors.get(material.id());
            var source=anchorId==null?null:bySource.get(anchorId);
            if(source!=null&&positive(source.issuedPlanQty())) {
                if(!Objects.equals(material.goodsId(),source.goodsId())||!Objects.equals(material.colorId(),source.colorId()))
                    throw conflict("已下达生产计划与当前物料身份不一致，请核对原计划");
                routes.add("MAKE");
            }
            if(!routes.isEmpty())result.put(material.id(),Set.copyOf(routes));
        }
        return new Proofs(Map.copyOf(result),Map.copyOf(dependencyRoutes),Set.copyOf(missingRoutes));
    }

    private static boolean positive(BigDecimal value) { return value!=null&&value.signum()>0; }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT,message); }
}
