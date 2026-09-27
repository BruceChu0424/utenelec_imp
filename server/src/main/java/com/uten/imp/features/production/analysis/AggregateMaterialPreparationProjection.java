package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** Restores actionable quantities to original paths without changing inventory or demand ownership. */
final class AggregateMaterialPreparationProjection {
    record OrderIntent(BigDecimal qty,boolean exact) { }
    private AggregateMaterialPreparationProjection() { }

    static List<MaterialView> apply(List<MaterialView> materials,List<ProductView> products,
            List<SupplyActionView> actions,Map<UUID,AggregateDelegationProjection.Delegation> delegations,
            Map<UUID,OrderIntent> intents,AggregateAdoptionIntentReader.Coverage adoptionIntent,Map<UUID,Map<UUID,BigDecimal>> inheritedByTarget,Map<UUID,Map<UUID,BigDecimal>> directPrivate) {
        Map<UUID,MaterialView> byId=materials.stream().collect(Collectors.toMap(MaterialView::materialLineId,Function.identity()));
        Map<String,MaterialView> byNode=materials.stream().collect(Collectors.toMap(row->row.analysisLineId()+"|"+row.nodeKey(),Function.identity()));
        Map<UUID,ProductView> byProduct=products.stream().collect(Collectors.toMap(ProductView::analysisLineId,Function.identity()));
        Map<UUID,SupplyActionView> byAction=actions.stream().collect(Collectors.toMap(SupplyActionView::actionId,Function.identity()));
        // Intermediate aggregate trees and original product trees describe the same demand
        // at different levels. Allocate each level separately, never dilute originals with aliases.
        Map<String,Map<UUID,BigDecimal>> weights=new HashMap<>();
        delegations.forEach((source,delegation)-> {
            MaterialView row=byId.get(source);if(row==null||delegation.member())return;
            boolean aggregate=byProduct.containsKey(row.analysisLineId())&&"AGGREGATE_MAKE".equals(byProduct.get(row.analysisLineId()).sourceType());
            delegation.targetShares().forEach((target,qty)->weights.computeIfAbsent(target+"|"+aggregate,ignored->new LinkedHashMap<>()).put(source,qty));
        });
        Map<UUID,BigDecimal> required=new HashMap<>(),allocated=new HashMap<>(),pending=new HashMap<>(),net=new HashMap<>(),adopted=new HashMap<>(),owned=new HashMap<>(),beforeShared=new HashMap<>();
        for(var bucket:weights.entrySet()) {
            MaterialView target=byId.get(UUID.fromString(bucket.getKey().split("\\|",2)[0]));if(target==null)continue;
            BigDecimal targetOrdered=privateOrdered(target,byProduct,byAction);
            Map<UUID,BigDecimal> intentWeights=new LinkedHashMap<>();
            bucket.getValue().forEach((source,qty)-> {
                BigDecimal intended=ancestorOrderWeight(byId.get(source),byNode,intents);
                intentWeights.put(source,intended==null?qty:intended);
            });
            Map<UUID,BigDecimal> preparationWeights=intentWeights;
            if(preparationWeights.values().stream().allMatch(qty->qty.signum()==0))
                preparationWeights=preparationWeights.keySet().stream().collect(Collectors.toMap(Function.identity(),ignored->BigDecimal.ONE));
            Map<UUID,BigDecimal> inherited=inheritedByTarget.getOrDefault(target.materialLineId(),Map.of());
            BigDecimal wholeNeed=number(target.requiredQty()).max(bucket.getValue().values().stream().reduce(BigDecimal.ZERO,BigDecimal::add));
            Map<UUID,BigDecimal> remainingWeights=new LinkedHashMap<>(AggregateDelegationProjection.proportional(wholeNeed,preparationWeights));
            remainingWeights.replaceAll((source,qty)->qty.subtract(inherited.getOrDefault(source,BigDecimal.ZERO)).max(BigDecimal.ZERO));
            if(remainingWeights.values().stream().allMatch(qty->qty.signum()==0))remainingWeights=new LinkedHashMap<>(preparationWeights);
            distribute(required,wholeNeed,preparationWeights);
            BigDecimal allocatedTotal=targetOrdered.min(bucket.getValue().values().stream().reduce(BigDecimal.ZERO,BigDecimal::add));
            Map<UUID,BigDecimal> provedOrdered=new LinkedHashMap<>();
            bucket.getValue().keySet().forEach(source->provedOrdered.put(source,directPrivate.getOrDefault(target.materialLineId(),Map.of()).getOrDefault(source,BigDecimal.ZERO)));
            BigDecimal provedTotal=provedOrdered.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add).min(allocatedTotal);
            distribute(allocated,provedTotal,provedOrdered);
            distribute(allocated,allocatedTotal.subtract(provedTotal),bucket.getValue());
            distribute(pending,target.planningUncoveredQty(),remainingWeights);
            distribute(net,target.netShortageQty(),remainingWeights);
            distribute(adopted,number(target.preparationAdoptedQty()).subtract(adoptionIntent.coveredByTarget()
                    .getOrDefault(target.materialLineId(),BigDecimal.ZERO)).max(BigDecimal.ZERO),preparationWeights);
            Map<UUID,BigDecimal> knownOwned=new LinkedHashMap<>();
            preparationWeights.keySet().forEach(source->knownOwned.put(source,inherited.getOrDefault(source,BigDecimal.ZERO)));
            BigDecimal knownTotal=knownOwned.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add).min(number(target.preparationOwnedAvailableQty()));
            distribute(owned,knownTotal,knownOwned);
            distribute(owned,number(target.preparationOwnedAvailableQty()).subtract(knownTotal),preparationWeights);
            distribute(beforeShared,number(target.preparationUncoveredBeforeSharedQty()),remainingWeights);
        }
        return materials.stream().map(row->{
            var delegation=delegations.get(row.materialLineId());
            boolean shared=row.downstreamReferences().stream().anyMatch(ref->byAction.containsKey(ref.actionId())
                    && "AGGREGATE_SUPPLY".equals(byAction.get(ref.actionId()).operationType()));
            BigDecimal directAdoption=number(row.preparationAdoptedQty()).subtract(adoptionIntent.coveredByTarget()
                    .getOrDefault(row.materialLineId(),BigDecimal.ZERO)).max(BigDecimal.ZERO)
                    .add(adoptionIntent.byOriginal().getOrDefault(row.materialLineId(),BigDecimal.ZERO));
            if(delegation==null&&!shared)return row.withPreparationAdoptedQty(directAdoption);
            List<UUID> targets=delegation==null?List.of():delegation.targetMaterialLineIds();
            List<MaterialView> effective=targets.isEmpty()?List.of(row):targets.stream().map(byId::get).filter(java.util.Objects::nonNull).toList();
            BigDecimal total=totalOrdered(effective,byProduct,byAction);
            BigDecimal own=AggregateMaterialOrderPreviewService.orderedQuantity(row,byProduct,byAction);
            BigDecimal allocatedQty=privateOrdered(row,byProduct,byAction).add(allocated.getOrDefault(row.materialLineId(),BigDecimal.ZERO));
            OrderIntent intent=intents.get(row.materialLineId());
            LegacyOrder legacy=legacyOrdered(row,byProduct,byAction);
            BigDecimal order=intent!=null&&intent.exact()?intent.qty().add(legacy.qty()):own.add(allocated.getOrDefault(row.materialLineId(),BigDecimal.ZERO));
            boolean exact=intent!=null&&intent.exact()&&legacy.exact();
            // A single original path owns the complete submitted amount, including its public part.
            if(!exact&&shared&&effective.size()==1&&row.downstreamReferences().stream()
                    .filter(ref->byAction.containsKey(ref.actionId())&&"AGGREGATE_SUPPLY".equals(byAction.get(ref.actionId()).operationType()))
                    .allMatch(ref->row.downstreamReferences().size()==1&&number(ref.allocatedQty()).compareTo(number(byAction.get(ref.actionId()).requestedQty()))==0)) {
                order=total;exact=true;
            }
            BigDecimal need=number(row.requiredQty()).add(required.getOrDefault(row.materialLineId(),BigDecimal.ZERO));
            BigDecimal uncovered=number(row.planningUncoveredQty()).add(pending.getOrDefault(row.materialLineId(),BigDecimal.ZERO));
            BigDecimal netNeed=number(row.netShortageQty()).add(net.getOrDefault(row.materialLineId(),BigDecimal.ZERO));
            boolean actionable=effective.stream().anyMatch(target->target.routeConfirmed()
                    && !Set.of("SHIP","REFERENCE").contains(java.util.Objects.toString(target.controlStage(),"")));
            String stage=row.flowStage();
            if(!targets.isEmpty()&&number(row.requiredQty()).signum()==0) {
                java.util.ArrayList<String> stages=new java.util.ArrayList<>(effective.stream().map(MaterialView::flowStage).filter(java.util.Objects::nonNull).toList());
                if(directAdoption.signum()>0&&row.flowStage()!=null&&!row.flowStage().endsWith("PENDING_ISSUE")) {
                    stages.removeIf(value->value.endsWith("PENDING_ISSUE"));stages.add(row.flowStage());
                }
                stage=stages.stream().min(java.util.Comparator.comparingInt(MaterialAnalysisService::preparationStageRank)).orElse(row.flowStage());
            }
            return row.withAggregatePreparation(new AggregatePreparationView(need,order,allocatedQty,total,exact,
                    uncovered,netNeed,targets,actionable)).withFlowStage(stage).withPreparationAdoptedQty(directAdoption.add(adopted.getOrDefault(row.materialLineId(),BigDecimal.ZERO))).withPreparationBudget(row.preparationPoolKey(),
                                            number(row.preparationSharedAvailableQty()),number(row.preparationOwnedAvailableQty()).add(owned.getOrDefault(row.materialLineId(),BigDecimal.ZERO)),
                                            number(row.preparationUncoveredBeforeSharedQty()).add(beforeShared.getOrDefault(row.materialLineId(),BigDecimal.ZERO)));
        }).toList();
    }
    private static BigDecimal privateOrdered(MaterialView row,Map<UUID,ProductView> products,Map<UUID,SupplyActionView> actions) {
        ProductView anchor=products.get(row.level()==0?row.analysisLineId():row.planAnchorAnalysisLineId());
        if(anchor!=null&&!"AGGREGATE_MAKE".equals(anchor.sourceType())
                &&("MAKE".equals(row.sourceConfirmed())||"SUBCONTRACT_MAKE".equals(anchor.sourceType())))
            return number(anchor.submittedQty()).add(number(anchor.approvedQty()))
                    .multiply(row.level()==0&&anchor.unitRate()!=null?anchor.unitRate():BigDecimal.ONE);
        return AggregateMaterialOrderPreviewService.orderedQuantity(row,products,actions);
    }

    record LegacyOrder(BigDecimal qty,boolean exact) { }
    static LegacyOrder legacyOrdered(MaterialView row,Map<UUID,ProductView> products,Map<UUID,SupplyActionView> actions) {
        ProductView anchor=products.get(row.level()==0?row.analysisLineId():row.planAnchorAnalysisLineId());
        if(anchor!=null&&!"AGGREGATE_MAKE".equals(anchor.sourceType())
                &&("MAKE".equals(row.sourceConfirmed())||"SUBCONTRACT_MAKE".equals(anchor.sourceType())))
            return new LegacyOrder(number(anchor.issuedPlanQty()),true);
        BigDecimal total=BigDecimal.ZERO;boolean exact=true;Set<UUID> seen=new HashSet<>();
        for(DownstreamReference ref:row.downstreamReferences()) {
            SupplyActionView action=actions.get(ref.actionId());
            if(action==null||!seen.add(action.actionId())||"CANCELLED".equals(action.status())
                    ||!java.util.Objects.equals(row.sourceConfirmed(),ref.route())
                    ||!"SUPPLY".equals(action.operationType()))continue;
            total=total.add(number(ref.allocatedQty()));
            if(number(ref.allocatedQty()).compareTo(number(action.requestedQty()))==0)total=total.add(number(action.publicSurplusQty()));
            else if(number(action.publicSurplusQty()).signum()>0)exact=false;
        }
        return new LegacyOrder(total,exact);
    }

    private static BigDecimal ancestorOrderWeight(MaterialView source,Map<String,MaterialView> byNode,Map<UUID,OrderIntent> intents) {
        Set<UUID> visited=new HashSet<>();
        MaterialView parent=source==null||source.parentNodeKey()==null?null:byNode.get(source.analysisLineId()+"|"+source.parentNodeKey());
        while(parent!=null&&visited.add(parent.materialLineId())) {
            OrderIntent intent=intents.get(parent.materialLineId());
            if(intent!=null&&intent.exact()&&intent.qty().signum()>0)return intent.qty();
            parent=parent.parentNodeKey()==null?null:byNode.get(parent.analysisLineId()+"|"+parent.parentNodeKey());
        }
        return null;
    }

    private static void distribute(Map<UUID,BigDecimal> into,BigDecimal total,Map<UUID,BigDecimal> weights) {
        AggregateDelegationProjection.proportional(number(total),weights).forEach((id,qty)->into.merge(id,qty,BigDecimal::add));
    }
    static BigDecimal totalOrdered(List<MaterialView> rows,Map<UUID,ProductView> products,Map<UUID,SupplyActionView> actions) {
        BigDecimal total=BigDecimal.ZERO;Set<UUID> seenActions=new HashSet<>(),seenAnchors=new HashSet<>();
        for(MaterialView row:rows) {
            ProductView anchor=products.get(row.level()==0?row.analysisLineId():row.planAnchorAnalysisLineId());
            boolean manufacturing=anchor!=null&&("MAKE".equals(row.sourceConfirmed())||"SUBCONTRACT_MAKE".equals(anchor.sourceType()));
            boolean shared=row.downstreamReferences().stream().anyMatch(ref->actions.containsKey(ref.actionId())
                    && "AGGREGATE_SUPPLY".equals(actions.get(ref.actionId()).operationType()));
            boolean legacy=manufacturing&&!"AGGREGATE_MAKE".equals(anchor.sourceType());
            if(manufacturing&&(!shared||legacy)&&seenAnchors.add(anchor.analysisLineId()))
                total=total.add(number(anchor.issuedPlanQty()));
            if(manufacturing&&!shared)continue;
            for(DownstreamReference ref:row.downstreamReferences()) {
                SupplyActionView action=actions.get(ref.actionId());
                if(action==null||"CANCELLED".equals(action.status())||!java.util.Objects.equals(row.sourceConfirmed(),ref.route())
                        ||Set.of("FUTURE_TRANSFER","SHARED_FUTURE_CLAIM","ROOT_OUTPUT","AGGREGATE_CONTINUATION").contains(java.util.Objects.toString(action.operationType(),"")))continue;
                if(legacy&&!"AGGREGATE_SUPPLY".equals(action.operationType()))continue;
                if(seenActions.add(action.actionId()))total=total.add(number(action.requestedQty())).add(number(action.publicSurplusQty())).add(number(action.safetyReplenishmentQty()));
            }
        }
        return total;
    }
    private static BigDecimal number(BigDecimal value){return value==null?BigDecimal.ZERO:value.max(BigDecimal.ZERO);}
}
