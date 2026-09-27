package com.uten.imp.features.production.analysis;

import com.uten.imp.common.finance.MoneyPolicy;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Exact alias/BOM-edge projection. It never invents a material identity from goods or row order. */
final class AggregateDelegationProjection {
    record Node(UUID materialId, UUID analysisLineId, String nodeKey, String parentNodeKey,
                UUID goodsId, UUID bomItemId, BigDecimal bomQty, String consumptionBasis,
                BigDecimal basisOutputQty, boolean allowPartialPackage, boolean rootSupply) { }
    record Member(UUID materialId, UUID anchorAnalysisLineId, BigDecimal qty) { }
    record Alias(UUID sourceMaterialId, UUID targetMaterialId, BigDecimal qty) { }
    record Delegation(BigDecimal qty, Map<UUID,BigDecimal> targetShares, boolean member) {
        Delegation { targetShares=Map.copyOf(targetShares); }
        UUID targetMaterialLineId() {
            return targetShares.size()==1 ? targetShares.keySet().iterator().next() : null;
        }
        List<UUID> targetMaterialLineIds() {
            return targetShares.keySet().stream().sorted(Comparator.comparing(UUID::toString)).toList();
        }
    }
    private record Pair(UUID source, UUID target) { }
    private AggregateDelegationProjection() { }

    static Map<UUID,Delegation> project(List<Node> nodes,List<Member> members,List<Alias> aliases) {
        Map<UUID,Node> byId=new HashMap<>();
        Map<String,Node> byNode=new HashMap<>();
        Map<String,List<Node>> children=new HashMap<>();
        for(Node node:nodes) {
            byId.put(node.materialId(),node);
            byNode.put(key(node.analysisLineId(),node.nodeKey()),node);
            if(node.parentNodeKey()!=null)children.computeIfAbsent(key(node.analysisLineId(),node.parentNodeKey()),ignored->new ArrayList<>()).add(node);
        }
        Map<UUID,BigDecimal> memberAmounts=new HashMap<>();
        for(Member member:members)if(byId.containsKey(member.materialId()))
            memberAmounts.merge(member.materialId(),positive(member.qty()),BigDecimal::add);
        Map<Pair,BigDecimal> shares=new LinkedHashMap<>();
        Set<Pair> explicit=new HashSet<>();
        for(Alias alias:aliases) {
            if(!byId.containsKey(alias.sourceMaterialId())||!byId.containsKey(alias.targetMaterialId()))continue;
            Pair pair=new Pair(alias.sourceMaterialId(),alias.targetMaterialId());
            explicit.add(pair);
            shares.merge(pair,positive(alias.qty()),BigDecimal::add);
        }
        Map<UUID,Map<UUID,BigDecimal>> byTarget=new HashMap<>();
        shares.forEach((pair,qty)->byTarget.computeIfAbsent(pair.target(),ignored->new LinkedHashMap<>()).put(pair.source(),qty));
        // A target's full batch is rounded once, then divided among its exact source paths.
        // Rounding f(each source) independently would manufacture extra whole packages.
        List<Node> ordered=nodes.stream().sorted(Comparator.comparingInt(node->depth(node,byNode))).toList();
        for(Node target:ordered) {
            Map<UUID,BigDecimal> parents=byTarget.getOrDefault(target.materialId(),Map.of());
            if(parents.isEmpty())continue;
            for(Node targetChild:children.getOrDefault(key(target.analysisLineId(),target.nodeKey()),List.of())) {
                if(targetChild.bomItemId()==null)continue;
                Map<UUID,BigDecimal> weights=new LinkedHashMap<>();
                for(var entry:parents.entrySet()) {
                    Node parent=byId.get(entry.getKey());
                    List<Node> matches=children.getOrDefault(key(parent.analysisLineId(),parent.nodeKey()),List.of()).stream()
                            .filter(child->targetChild.bomItemId().equals(child.bomItemId())).toList();
                    if(matches.size()!=1)continue; // Ambiguity is never resolved by picking a row.
                    Node sourceChild=matches.getFirst();
                    if(!explicit.contains(new Pair(sourceChild.materialId(),targetChild.materialId())))
                        weights.merge(sourceChild.materialId(),entry.getValue(),BigDecimal::add);
                }
                if(weights.isEmpty())continue;
                BigDecimal totalParent=weights.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add);
                BigDecimal totalChild=MaterialConsumptionMath.required(totalParent,targetChild.bomQty(),
                        targetChild.consumptionBasis(),targetChild.basisOutputQty(),targetChild.allowPartialPackage());
                proportional(totalChild,weights).forEach((source,qty)-> {
                    shares.put(new Pair(source,targetChild.materialId()),qty);
                    byTarget.computeIfAbsent(targetChild.materialId(),ignored->new LinkedHashMap<>()).put(source,qty);
                });
            }
        }
        Map<UUID,Map<UUID,BigDecimal>> outgoing=new HashMap<>();
        shares.forEach((pair,qty)->outgoing.computeIfAbsent(pair.source(),ignored->new LinkedHashMap<>()).merge(pair.target(),qty,BigDecimal::add));
        Map<UUID,Delegation> result=new LinkedHashMap<>();
        Set<UUID> sources=new HashSet<>(outgoing.keySet());sources.addAll(memberAmounts.keySet());
        for(UUID source:sources) {
            boolean member=memberAmounts.containsKey(source);
            // Batch members carry their own action/plan identity. A component in the anchor
            // tree is not a substitute root for that product and must not become its write id.
            Map<UUID,BigDecimal> targets=new LinkedHashMap<>();
            if(!member)for(var edge:outgoing.getOrDefault(source,Map.of()).entrySet())
                resolve(edge.getKey(),edge.getValue(),outgoing,memberAmounts.keySet(),new HashSet<>(Set.of(source)),targets);
            BigDecimal qty=member?memberAmounts.get(source):targets.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add);
            result.put(source,new Delegation(qty,targets,member));
        }
        return Map.copyOf(result);
    }

    private static void resolve(UUID target,BigDecimal qty,Map<UUID,Map<UUID,BigDecimal>> outgoing,
            Set<UUID> members,Set<UUID> visited,Map<UUID,BigDecimal> result) {
        if(!visited.add(target))throw new IllegalStateException("Aggregate material alias cycle");
        Map<UUID,BigDecimal> next=outgoing.getOrDefault(target,Map.of());
        if(next.isEmpty()||members.contains(target))result.merge(target,qty,BigDecimal::add);
        else proportional(qty,next).forEach((id,share)->resolve(id,share,outgoing,members,new HashSet<>(visited),result));
    }

    /** Four-decimal deterministic proportional shares; the sum always equals the batch amount. */
    static Map<UUID,BigDecimal> proportional(BigDecimal total,Map<UUID,BigDecimal> weights) {
        List<UUID> ids=weights.keySet().stream().sorted(Comparator.comparing(UUID::toString)).toList();
        if(ids.isEmpty())return Map.of();
        BigInteger ticks=MoneyPolicy.quantity(positive(total)).unscaledValue();
        BigDecimal weightTotal=weights.values().stream().map(AggregateDelegationProjection::positive).reduce(BigDecimal.ZERO,BigDecimal::add);
        Map<UUID,BigDecimal> result=new LinkedHashMap<>();
        BigInteger allocated=BigInteger.ZERO;
        for(UUID id:ids) {
            BigInteger amount=weightTotal.signum()==0 ? BigInteger.ZERO
                    : new BigDecimal(ticks).multiply(positive(weights.get(id))).divide(weightTotal,0,RoundingMode.DOWN).toBigIntegerExact();
            result.put(id,new BigDecimal(amount,4));allocated=allocated.add(amount);
        }
        if(weightTotal.signum()==0) {
            // Zero-quantity aliases preserve identity only; they must not fabricate ownership.
            return result;
        }
        int remainder=ticks.subtract(allocated).intValueExact();
        for(UUID id:ids) {
            if(remainder==0)break;
            if(positive(weights.get(id)).signum()>0){result.put(id,result.get(id).add(new BigDecimal("0.0001")));remainder--;}
        }
        return result;
    }
    private static int depth(Node node,Map<String,Node> byNode) {
        int result=0;Set<UUID> visited=new HashSet<>();
        while(node!=null&&visited.add(node.materialId())) {
            result++;node=node.parentNodeKey()==null?null:byNode.get(key(node.analysisLineId(),node.parentNodeKey()));
        }
        return result;
    }
    private static BigDecimal positive(BigDecimal value){return value==null?BigDecimal.ZERO:value.max(BigDecimal.ZERO);}
    private static String key(UUID line,String node){return line+"|"+node;}
}
