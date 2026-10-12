package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.util.*;
import java.util.stream.Collectors;

import static com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** Proves which external orders can share a snapshot without sharing a quantity decision. */
final class AggregateExternalOrderCohort {
    private AggregateExternalOrderCohort() { }

    static List<GroupPreview> prefix(List<GroupPreview> groups,Map<String,GroupInput> inputs,AnalysisView view) {
        if(groups.isEmpty()||!external(groups.getFirst()))return List.of();
        Map<UUID,MaterialView> rows=view.flatMaterials().stream().collect(Collectors.toMap(MaterialView::materialLineId,row->row));
        Map<String,MaterialView> byNode=view.flatMaterials().stream().collect(Collectors.toMap(row->row.analysisLineId()+"|"+row.nodeKey(),row->row));
        Map<UUID,Set<UUID>> aliases=new HashMap<>(),dependencies=new HashMap<>(),sourceRoots=new HashMap<>();
        Map<String,UUID> physicalRepresentatives=new HashMap<>();
        for(MaterialView row:rows.values()) {
            // A changed descendant demand can redistribute the same physical
            // stock to another source, even when those rows have no alias link.
            // A star keeps this dependency linear for thousands of same-good rows.
            UUID representative=physicalRepresentatives.putIfAbsent(row.goodsId()+"|"+row.colorId(),row.materialLineId());
            if(representative!=null) {
                edge(dependencies,representative,row.materialLineId());edge(dependencies,row.materialLineId(),representative);
            }
            if(row.parentNodeKey()==null)edge(sourceRoots,row.analysisLineId(),row.materialLineId());
            else {
                MaterialView parent=byNode.get(row.analysisLineId()+"|"+row.parentNodeKey());
                if(parent!=null)edge(dependencies,parent.materialLineId(),row.materialLineId());
            }
            if(row.aggregatePreparation()!=null)for(UUID target:row.aggregatePreparation().targetMaterialLineIds()) {
                // The original and the current owner describe the same responsibility.
                // Changes on either side can affect descendants on the other side.
                edge(aliases,row.materialLineId(),target);edge(aliases,target,row.materialLineId());
                edge(dependencies,row.materialLineId(),target);edge(dependencies,target,row.materialLineId());
            }
        }
        // A MAKE member can own a separate shared source tree without an alias on
        // the parent itself. Include that edge before checking cross-group ancestry.
        for(MaterialView row:rows.values())if(row.planAnchorAnalysisLineId()!=null)
            for(UUID root:sourceRoots.getOrDefault(row.planAnchorAnalysisLineId(),Set.of()))edge(dependencies,row.materialLineId(),root);
        Set<UUID> legacyActions=view.supplyActions().stream().filter(action->"SUPPLY".equals(action.operationType()))
                .map(SupplyActionView::actionId).collect(Collectors.toSet());
        Set<String> dimensions=new HashSet<>();Set<UUID> selected=new HashSet<>(),affected=new HashSet<>();
        List<GroupPreview> result=new ArrayList<>();
        for(GroupPreview group:groups) {
            if(!external(group)||group.safetyQty().signum()>0||group.blockedReason()!=null
                    ||!dimensions.add(group.goodsId()+"|"+group.colorId()))break;
            GroupInput input=inputs.get(group.clientGroupKey());
            if(input==null||!provenSources(group,input,rows))break;
            Set<UUID> ids=new HashSet<>(input.materialLineIds());
            group.sources().forEach(source->ids.add(source.materialLineId()));
            Set<UUID> related=reachable(ids,aliases);
            if(related.stream().map(rows::get).anyMatch(row->!independentRow(row,legacyActions)||!completeAncestry(row,byNode)))break;
            Set<UUID> impacts=reachable(related,dependencies);
            // Borrow effective quantities are recomputed from current donor and
            // recipient demand. Even an effective-zero active borrow can alter a
            // complete-kit allocation in another dimension after this write.
            if(impacts.stream().map(rows::get).anyMatch(row->row==null||row.borrowRefs()!=null&&!row.borrowRefs().isEmpty()))break;
            if(!Collections.disjoint(related,affected)||!Collections.disjoint(impacts,selected))break;
            selected.addAll(related);affected.addAll(impacts);result.add(group);
        }
        return List.copyOf(result);
    }

    private static boolean provenSources(GroupPreview group,GroupInput input,Map<UUID,MaterialView> rows) {
        Set<UUID> originals=new HashSet<>(input.materialLineIds());
        Set<UUID> proven=new HashSet<>();
        for(SourcePreview source:group.sources()) {
            if(source.originalMaterialLineIds().isEmpty()||!originals.containsAll(source.originalMaterialLineIds()))return false;
            for(UUID original:source.originalMaterialLineIds()) {
                MaterialView row=rows.get(original);
                if(row==null||!original.equals(source.materialLineId())&&(row.aggregatePreparation()==null
                        ||!row.aggregatePreparation().targetMaterialLineIds().contains(source.materialLineId())))return false;
                proven.add(original);
            }
        }
        return !group.sources().isEmpty()&&proven.equals(originals);
    }

    private static boolean independentRow(MaterialView row,Set<UUID> legacyActions) {
        return row!=null&&row.planAnchorAnalysisLineId()==null
                &&!positive(row.priorityMakeSupplementQty())&&!positive(row.borrowedInQty())&&!positive(row.borrowedOutQty())
                &&(row.makePublicSupplyRefs()==null||row.makePublicSupplyRefs().stream().noneMatch(candidate->candidate.adoptable()&&positive(candidate.availableQty())))
                &&(row.sharedFutureSupplyRefs()==null||row.sharedFutureSupplyRefs().stream().noneMatch(candidate->positive(candidate.availableToClaimQty())))
                &&row.downstreamReferences().stream().noneMatch(ref->legacyActions.contains(ref.actionId())&&!"CANCELLED".equals(ref.status()));
    }

    private static boolean completeAncestry(MaterialView row,Map<String,MaterialView> byNode) {
        Set<UUID> visited=new HashSet<>();
        while(row!=null) {
            if(!visited.add(row.materialLineId()))return false;
            if(row.parentNodeKey()==null)return true;
            row=byNode.get(row.analysisLineId()+"|"+row.parentNodeKey());
        }
        return false;
    }

    private static Set<UUID> reachable(Set<UUID> seeds,Map<UUID,Set<UUID>> graph) {
        Set<UUID> visited=new HashSet<>(seeds);Deque<UUID> pending=new ArrayDeque<>(seeds);
        while(!pending.isEmpty())for(UUID next:graph.getOrDefault(pending.removeFirst(),Set.of()))if(visited.add(next))pending.addLast(next);
        return visited;
    }
    private static void edge(Map<UUID,Set<UUID>> graph,UUID from,UUID to) {
        if(!from.equals(to))graph.computeIfAbsent(from,ignored->new HashSet<>()).add(to);
    }
    private static boolean positive(BigDecimal value) { return value!=null&&value.signum()>0; }
    private static boolean external(GroupPreview group) { return "BUY".equals(group.route())||"SUBCONTRACT".equals(group.route()); }
}
