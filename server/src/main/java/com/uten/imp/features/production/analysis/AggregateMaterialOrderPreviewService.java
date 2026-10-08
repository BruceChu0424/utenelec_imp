package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.ProductView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.SupplyActionView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.DownstreamReference;

/** The same reviewed source allocation is used by the read-only UI and the locked write command. */
@Service
@RequiredArgsConstructor
public class AggregateMaterialOrderPreviewService {
    private final MaterialAnalysisService analysisService;
    private final ProductionDocumentAccessPolicy access;
    private final AggregateMaterialBatchLookup batches;

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Preview preview(UUID analysisId, PreviewRequest request) {
        if(request==null)throw invalid("汇总下单信息不完整");
        requireSourceScope(request.groups());
        MaterialAnalysisService.AnalysisHeader header=analysisService.readOnlyHeader(analysisId);
        access.requireWritable(header.makerId(),"只能从本人负责的物料分析核对汇总下单",analysisService.scopeForAnalysis(header));
        analysisService.requireCurrent(header,request.version(),request.fingerprint());
        if(!Objects.equals(header.warehouseId(),request.warehouseId()))throw conflict("分析仓库已变化，请刷新后重新核对");
        MaterialAnalysisIssuePreviewOverlay overlay=MaterialAnalysisIssuePreviewOverlay.create();
        analysisService.projectIssuePreviewBase(analysisId,overlay);
        return resolve(analysisId,request,analysisService.issuePreviewView(analysisId,overlay,Map.of()));
    }

    /** Caller on the write side must obtain and validate its complete mutation footprint first. */
    public Preview resolve(UUID analysisId,PreviewRequest request,AnalysisView view) {
        validateHeader(analysisId,request,view);
        requireSourceScope(request.groups());
        Map<UUID,MaterialView> materials=new HashMap<>();
        Map<UUID,ProductView> products=new HashMap<>();
        Map<UUID,SupplyActionView> actions=new HashMap<>();
        Map<String,List<MaterialView>> children=new HashMap<>();
        for(ProductView product:view.products())products.put(product.analysisLineId(),product);
        for(SupplyActionView action:view.supplyActions())actions.put(action.actionId(),action);
        for(MaterialView material:view.flatMaterials()) {
            materials.put(material.materialLineId(),material);
            if(material.parentNodeKey()!=null)children.computeIfAbsent(nodeRef(material.analysisLineId(),material.parentNodeKey()),ignored->new ArrayList<>()).add(material);
        }
        var used=new HashSet<UUID>();var clientKeys=new HashSet<String>();var compatibilityKeys=new HashSet<String>();
        Map<UUID,BigDecimal> makeBudget=new HashMap<>();
        for(MaterialView row:view.flatMaterials())if(row.makePublicSupplyRefs()!=null)for(var candidate:row.makePublicSupplyRefs())
            if(candidate.adoptable())makeBudget.put(candidate.sourcePlanItemId(),candidate.availableQty());
        Map<String,BigDecimal> externalBudget=new HashMap<>();
        for(MaterialView row:view.flatMaterials())if(row.sharedFutureSupplyRefs()!=null)for(var candidate:row.sharedFutureSupplyRefs())
            if(candidate.budgetKey()!=null)externalBudget.put(candidate.budgetKey(),candidate.availableToClaimQty());
        List<GroupPreview> result=new ArrayList<>();
        for(GroupInput group:request.groups()) {
            if(group==null||group.clientGroupKey()==null||group.clientGroupKey().isBlank()||!clientKeys.add(group.clientGroupKey()))throw invalid("汇总行标识缺失或重复");
            if(group.materialLineIds().isEmpty())throw invalid("汇总行必须包含明确的来源物料");
            validateSourceQuantities(group);
            List<MaterialView> members=new ArrayList<>();
            Map<UUID,java.util.LinkedHashSet<UUID>> originalScope=new LinkedHashMap<>();
            for(UUID id:group.materialLineIds()) {
                if(id==null||!used.add(id))throw invalid("同一来源不能在本次汇总下单中出现两次");
                MaterialView material=materials.get(id);
                if(material==null)throw conflict("汇总来源已变化或不可见，请刷新并重新核对");
                Map<UUID,String> planningBlocks=view.planningBlockedReasons()==null?Map.of():view.planningBlockedReasons();
                String originBlocked=planningBlocks.get(material.analysisLineId());
                if(originBlocked!=null)throw conflict(originBlocked);
                ProductView originalProduct=products.get(material.analysisLineId());
                if(originalProduct!=null&&"AGGREGATE_MAKE".equals(originalProduct.sourceType())) {
                    String inheritedBlock=view.flatMaterials().stream().filter(row->row.aggregatePreparation()!=null
                            &&row.aggregatePreparation().targetMaterialLineIds().contains(id))
                            .map(row->planningBlocks.get(row.analysisLineId())).filter(Objects::nonNull).findFirst().orElse(null);
                    if(inheritedBlock!=null)throw conflict(inheritedBlock);
                }
                List<UUID> targets=material.aggregatePreparation()==null?List.of():material.aggregatePreparation().targetMaterialLineIds();
                boolean retainOriginal=targets.isEmpty()||number(material.requiredQty()).signum()>0;
                if(retainOriginal) {
                    if(members.stream().noneMatch(value->value.materialLineId().equals(id)))members.add(material);
                    originalScope.computeIfAbsent(id,ignored->new java.util.LinkedHashSet<>()).add(id);
                }
                List<MaterialView> targetMembers=new ArrayList<>();
                for(UUID targetId:targets) {
                    MaterialView target=materials.get(targetId);
                    if(target==null)throw conflict("合并来源目标已变化，请刷新后重新核对");
                    targetMembers.add(target);
                }
                boolean hasCurrentResponsibility=retainOriginal&&AggregateMaterialSourceEligibility.hasResponsibility(material,products)
                        || targetMembers.stream()
                        .anyMatch(target->AggregateMaterialSourceEligibility.hasResponsibility(target,products));
                for(MaterialView target:targetMembers) {
                    // Keep immutable aliases in the read model. A zero-responsibility retired target
                    // cannot block its origin's remaining demand or another live target, or receive new allocation.
                    // With no live responsibility, the original admission guard still rejects;
                    // unknown/missing targets never disappear from validation.
                    if(hasCurrentResponsibility&&AggregateMaterialSourceEligibility.isRetiredContext(target,products))continue;
                    UUID targetId=target.materialLineId();
                    if(members.stream().noneMatch(value->value.materialLineId().equals(targetId)))members.add(target);
                    originalScope.computeIfAbsent(targetId,ignored->new java.util.LinkedHashSet<>()).add(id);
                }
            }
            members.sort(Comparator.comparing(member->member.materialLineId().toString()));
            Map<UUID,BigDecimal> requestedPrivateCaps=new LinkedHashMap<>();
            group.sourceRequestedQtyByMaterialLineId().forEach((id,requested)-> {
                MaterialView row=materials.get(id);
                BigDecimal pending=number(row.aggregatePreparation()==null?row.planningUncoveredQty():row.aggregatePreparation().planningUncoveredQty())
                        .max(number(row.priorityMakeSupplementQty()));
                ProductView anchor=products.get(row.planAnchorAnalysisLineId());
                if(anchor!=null&&!"AGGREGATE_MAKE".equals(anchor.sourceType()))pending=pending.max(number(anchor.remainingQty()));
                requestedPrivateCaps.put(id,requested.min(pending));
            });
            GroupPreview resolved=resolveGroup(analysisId,request,group,members,products,actions,children,view.overproductionDefaults(),makeBudget,externalBudget,originalScope,requestedPrivateCaps,materials);
            if(!compatibilityKeys.add(resolved.compatibilityKey()))throw invalid("同一物料及相同办理规则只能提交一组，请合并来源和总量后重新核对");
            result.add(resolved);
        }
        String token=CanonicalFingerprint.sha256(List.of(previewFingerprint(request,result),
                CanonicalFingerprint.sha256(view.flatMaterials().stream().filter(row->row.makePublicSupplyRefs()!=null)
                    .flatMap(row->row.makePublicSupplyRefs().stream()).map(candidate->candidate.sourcePlanItemId()+":"+candidate.availableQty().stripTrailingZeros().toPlainString()).distinct().toList())));
        token=CanonicalFingerprint.sha256(List.of(token,CanonicalFingerprint.sha256(view.flatMaterials().stream()
                .filter(row->row.sharedFutureSupplyRefs()!=null).flatMap(row->row.sharedFutureSupplyRefs().stream())
                .filter(candidate->candidate.budgetKey()!=null)
                .map(candidate->candidate.budgetKey()+":"+candidate.availableToClaimQty().stripTrailingZeros().toPlainString()).distinct().toList())));
        return new Preview(analysisId,view.version(),view.fingerprint(),token,result,view);
    }

    private static void validateSourceQuantities(GroupInput group) {
        if(group.sourceRequestedQtyByMaterialLineId().isEmpty())return;
        if(!group.sourceRequestedQtyByMaterialLineId().keySet().equals(new HashSet<>(group.materialLineIds())))
            throw invalid("逐来源下单数量必须完整对应本次原物料行");
        BigDecimal total=BigDecimal.ZERO;
        for(BigDecimal qty:group.sourceRequestedQtyByMaterialLineId().values()) {
            if(qty==null||qty.signum()<0||qty.stripTrailingZeros().scale()>4||qty.precision()-qty.scale()>14)
                throw invalid("逐来源下单数量必须为非负数且最多四位小数");
            total=total.add(qty);
        }
        if(total.compareTo(group.qty())!=0)throw invalid("逐来源下单数量之和必须等于本组下单总量");
    }

    private GroupPreview resolveGroup(UUID analysisId,PreviewRequest request,GroupInput input,List<MaterialView> members,
            Map<UUID,ProductView> products,Map<UUID,SupplyActionView> actions,Map<String,List<MaterialView>> children,
            Map<UUID,BigDecimal> rateDefaults,Map<UUID,BigDecimal> makeBudget,Map<String,BigDecimal> externalBudget,Map<UUID,java.util.LinkedHashSet<UUID>> originalScope,Map<UUID,BigDecimal> requestedPrivateCaps,Map<UUID,MaterialView> originalMaterials) {
        MaterialView first=members.getFirst();
        String reason=null;
        if(!Set.of("BUY","MAKE","SUBCONTRACT").contains(Objects.toString(input.route(),"")))throw invalid("汇总供应方式不正确");
        List<String> recipe=recipe(first,children);
        for(MaterialView member:members) {
            if(member.level()==0)throw invalid("顶层产品请按产品办理，保留原产品及销售订单来源；物料汇总只办理组件");
            if(!Objects.equals(first.goodsId(),member.goodsId())||!Objects.equals(first.colorId(),member.colorId())||!Objects.equals(first.unitId(),member.unitId()))throw invalid("不同货品、颜色或单位不能合并为一行下单");
            if(!member.routeConfirmed()||!input.route().equals(member.sourceConfirmed()))reason="来源供应方式不一致或尚未确认，请先核对供应方式";
            if(!recipe.equals(recipe(member,children)))reason="相同物料的冻结组件规则不同，请按生产规则分别办理";
            if(!AggregateMaterialSourceEligibility.hasResponsibility(member,products))
                reason="部分来源已转交其他任务或本批无需办理，请按当前有效来源重新选择";
        }
        // ADR-143：委外汇总永远建外部批次(委外申请)，只有自制才是制造批次。
        boolean manufacture="MAKE".equals(input.route());
        LocalDate bill=input.billDate()==null?request.billDate():input.billDate();
        LocalDate delivery=input.deliveryDate()==null?request.deliveryDate():input.deliveryDate();
        if(delivery!=null&&bill!=null&&delivery.isBefore(bill))reason="计划完成日期不能早于下单日期";
        if(number(input.qty()).signum()>0||number(input.safetyQty()).signum()>0) {
            if(manufacture&&(input.departmentId()==null||input.workerId()==null))reason="请为汇总批次填写生产车间和负责人";
            String permission=manufacture?"production_material_analysis:generate":"production_material_analysis:notify";
            if(!access.hasAuthority(permission))reason=manufacture?"缺少下达车间权限":"缺少下达采购或委外权限";
            if(manufacture&&request.approveNow()&&!access.hasAuthority("production_plan:approve"))reason="生成并审核需要生产计划审核权限";
        }
        BigDecimal rate=manufacture?(input.allowedOverproductionRate()==null
                ?defaultOverproductionRate(rateDefaults,first.goodsId()):input.allowedOverproductionRate()):null;
        if(rate!=null&&(rate.signum()<0||rate.compareTo(new BigDecimal("1000"))>=0||rate.stripTrailingZeros().scale()>6))throw invalid("允许超产比例不正确");
        List<AggregateQuantityAllocator.SourceCapacity> capacities=new ArrayList<>();
        Map<UUID,BigDecimal> ordered=new LinkedHashMap<>();
        Map<UUID,BigDecimal> remainingBySource=new HashMap<>();
        for(MaterialView member:members) {
            ProductView product=products.get(member.analysisLineId());
            BigDecimal remaining=number(member.planningUncoveredQty()).max(number(member.priorityMakeSupplementQty()));
            ProductView anchor=member.planAnchorAnalysisLineId()==null?null:products.get(member.planAnchorAnalysisLineId());
            if(manufacture&&anchor!=null&&!"AGGREGATE_MAKE".equals(anchor.sourceType())&&number(anchor.remainingQty()).signum()>0) {
                remaining=remaining.max(anchor.remainingQty());
                if(members.size()>1)reason="已有按原来源建立的待下达制造责任，请先在原任务完成或撤回后再汇总";
            }
            remainingBySource.put(member.materialLineId(),remaining);
            capacities.add(new AggregateQuantityAllocator.SourceCapacity(member.materialLineId(),
                    product==null?0:product.allocationPriority(),product==null?null:product.deliveryDate(),
                    remaining));
            ordered.put(member.materialLineId(),orderedQuantity(member,products,actions));
        }
        List<AggregateQuantityAllocator.SourceCapacity> allocationCaps=capacities;
        Map<UUID,BigDecimal> privateByOriginal=new LinkedHashMap<>();
        if(!requestedPrivateCaps.isEmpty()) {
            Map<UUID,List<UUID>> proof=new LinkedHashMap<>();originalScope.forEach((target,origins)->proof.put(target,List.copyOf(origins)));
            var flow=AggregateOriginalTargetAllocator.allocate(requestedPrivateCaps,remainingBySource,proof,false);
            flow.byTarget().values().forEach(sharesByOrigin->sharesByOrigin.forEach((id,qty)->privateByOriginal.merge(id,qty,BigDecimal::add)));
            allocationCaps=capacities.stream().map(capacity->new AggregateQuantityAllocator.SourceCapacity(capacity.sourceId(),capacity.allocationPriority(),capacity.needDate(),
                    flow.byTarget().getOrDefault(capacity.sourceId(),Map.of()).values().stream().reduce(BigDecimal.ZERO,BigDecimal::add))).toList();
        }
        var allocation=AggregateQuantityAllocator.allocate(input.qty(),allocationCaps,true);
        if(allocation.publicExtraQty().signum()>0 && !input.allowPublicExtra())reason="本次超出待安排需求，请明确核对公共备货量";
        if(allocation.publicExtraQty().signum()>0 && !manufacture && !access.hasAuthority("production_material_analysis:over_supply"))reason="公共超量备货需要超量下达权限";
        if(number(input.safetyQty()).signum()>0) {
            if(!"BUY".equals(input.route()))reason="公共安全补库仅支持采购路线";
            else if(input.safetyQty().compareTo(number(first.mainWarehouseSafetyReplenishmentGapQty()))>0)
                reason="公共安全补库量超过当前主仓缺口，请刷新后重新核对";
        }
        Map<UUID,BigDecimal> shares=new HashMap<>();
        allocation.allocations().forEach(value->shares.put(value.sourceId(),value.qty()));
        List<SourcePreview> sourceRows=new ArrayList<>();
        for(MaterialView member:members) {
            ProductView product=products.get(member.analysisLineId());
            String label=product==null?member.parentLabel():String.join(" ",Objects.toString(product.goodsCode(),""),Objects.toString(product.goodsName(),""));
            if(member.path()!=null&&!member.path().isEmpty())label=Objects.toString(label,"")+" / "+String.join(" / ",member.path());
            sourceRows.add(new SourcePreview(member.materialLineId(),member.analysisLineId(),label,
                    product==null?0:product.allocationPriority(),product==null?null:product.deliveryDate(),
                    number(member.sourceRequiredQty()),remainingBySource.get(member.materialLineId()),
                    shares.getOrDefault(member.materialLineId(),BigDecimal.ZERO),ordered.get(member.materialLineId()),
                    originalScope.getOrDefault(member.materialLineId(),new java.util.LinkedHashSet<>(List.of(member.materialLineId()))).stream().sorted(Comparator.comparing(UUID::toString)).toList()));
        }
        List<String> keyParts=new ArrayList<>();
        add(keyParts,request.warehouseId(),first.goodsId(),first.colorId(),first.unitId(),input.route(),
                input.departmentId(),input.workerId(),input.teamDepartmentId(),bill,delivery,input.productNo(),rate);
        keyParts.addAll(recipe);
        String compatibility=CanonicalFingerprint.sha256(keyParts);
        boolean anyExisting=products.values().stream().anyMatch(product->"AGGREGATE_MAKE".equals(product.sourceType()))
                || actions.values().stream().anyMatch(action->"AGGREGATE_SUPPLY".equals(action.operationType()));
        var existing=anyExisting?batches.find(analysisId,compatibility,input.route(),rate,input.safetyQty(),manufacture,request.approveNow(),false):null;
        BigDecimal prior=existing==null?BigDecimal.ZERO:existing.priorOutputQty();
        BigDecimal adoptableMake=BigDecimal.ZERO;
        Map<UUID,MaterialView> memberById=new HashMap<>();members.forEach(member->memberById.put(member.materialLineId(),member));
        List<AggregateQuantityAllocator.Allocation> adoptionTargets=allocation.allocations();
        if(!requestedPrivateCaps.isEmpty()) {
            memberById.putAll(originalMaterials);
            adoptionTargets=privateByOriginal.entrySet().stream().sorted(Map.Entry.comparingByKey(Comparator.comparing(UUID::toString)))
                    .map(entry->new AggregateQuantityAllocator.Allocation(entry.getKey(),entry.getValue())).toList();
        }
        for(var source:adoptionTargets) {
            MaterialView member=memberById.get(source.sourceId());
            ProductView responsibility=products.get(member.planAnchorAnalysisLineId());
            if(number(member.priorityMakeSupplementQty()).signum()>0||number(member.requiredQty()).signum()==0
                    &&responsibility!=null&&!"AGGREGATE_MAKE".equals(responsibility.sourceType())&&number(responsibility.remainingQty()).signum()>0)continue;
            BigDecimal remaining=source.qty();
            for(var candidate:member.makePublicSupplyRefs()==null?List.<PreplanMakePublicSupplyService.Candidate>of():member.makePublicSupplyRefs()) {
                if(!candidate.adoptable())continue;
                BigDecimal take=remaining.min(makeBudget.getOrDefault(candidate.sourcePlanItemId(),BigDecimal.ZERO));
                if(take.signum()==0)continue;
                makeBudget.compute(candidate.sourcePlanItemId(),(id,qty)->qty.subtract(take));
                adoptableMake=adoptableMake.add(take);remaining=remaining.subtract(take);
            }
            for(var candidate:member.sharedFutureSupplyRefs()==null?List.<MaterialAnalysisContracts.SharedFutureSupplyRef>of():member.sharedFutureSupplyRefs()) {
                if(candidate.budgetKey()==null)continue;
                BigDecimal take=remaining.min(externalBudget.getOrDefault(candidate.budgetKey(),BigDecimal.ZERO));
                externalBudget.computeIfPresent(candidate.budgetKey(),(id,qty)->qty.subtract(take));
                adoptableMake=adoptableMake.add(take);remaining=remaining.subtract(take);
            }
        }
        BigDecimal actualNewOutput=number(input.qty()).subtract(adoptableMake);
        if(actualNewOutput.signum()==0&&"请为汇总批次填写生产车间和负责人".equals(reason))reason=null;
        // ADR-143 §二.3：缺 BOM 的委外件不能汇总下达委外(研发正在完善)，这个原因优先显示。
        // 与提交时的拦截同一判定(按货品现查)，不看只标真有需求节点的「缺 BOM」角标。
        if("SUBCONTRACT".equals(input.route())) {
            List<String> bomGaps=List.copyOf(analysisService.subcontractBomGapLabels(members).values());
            if(!bomGaps.isEmpty())reason=com.uten.imp.application.port.RdBomGapPort.subcontractBomMissingMessage(bomGaps,true);
        }
        List<ChildPreview> childRows=sharedChildren(first,prior.add(actualNewOutput),prior,children);
        return new GroupPreview(input.clientGroupKey(),compatibility,input.route(),
                first.goodsId(),first.goodsCode(),first.goodsName(),first.colorId(),first.colorName(),first.unitId(),first.unitName(),
                sourceRows.stream().map(SourcePreview::sourceRequiredQty).reduce(BigDecimal.ZERO,BigDecimal::add),
                MoneyPolicy.quantity(ordered.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add).add(publicOrdered(members,products,actions))),
                capacities.stream().map(AggregateQuantityAllocator.SourceCapacity::remainingQty).reduce(BigDecimal.ZERO,BigDecimal::add),
                number(input.qty()),allocation.publicExtraQty(),number(input.safetyQty()),input.departmentId(),input.workerId(),
                input.teamDepartmentId(),bill,delivery,input.productNo(),rate,sourceRows,childRows,reason,existing==null?null:existing.batchId(),prior);
    }

    static BigDecimal orderedQuantity(MaterialView material,Map<UUID,ProductView> products,Map<UUID,SupplyActionView> actions) {
        boolean shared=material.downstreamReferences()!=null&&material.downstreamReferences().stream().anyMatch(reference->{
            SupplyActionView action=reference.actionId()==null?null:actions.get(reference.actionId());
            return action!=null&&"AGGREGATE_SUPPLY".equals(action.operationType());
        });
        ProductView anchor=material.level()==0?products.get(material.analysisLineId()):
                material.planAnchorAnalysisLineId()==null?null:products.get(material.planAnchorAnalysisLineId());
        if(!shared&&anchor!=null&&"MAKE".equals(material.sourceConfirmed())) {
            return number(anchor.issuedPlanQty()).multiply(material.level()==0&&anchor.unitRate()!=null?anchor.unitRate():BigDecimal.ONE);
        }
        boolean legacyManufacturing=anchor!=null&&!"AGGREGATE_MAKE".equals(anchor.sourceType())
                &&"MAKE".equals(material.sourceConfirmed());
        BigDecimal total=shared&&legacyManufacturing?number(anchor.issuedPlanQty()):BigDecimal.ZERO;Set<UUID> seen=new HashSet<>();
        for(DownstreamReference reference:material.downstreamReferences()==null?List.<DownstreamReference>of():material.downstreamReferences()) {
            if(reference.actionId()==null||!seen.add(reference.actionId())||"CANCELLED".equals(reference.status())||!Objects.equals(material.sourceConfirmed(),reference.route()))continue;
            SupplyActionView action=actions.get(reference.actionId());
            if(action!=null&&Set.of("FUTURE_TRANSFER","SHARED_FUTURE_CLAIM","ROOT_OUTPUT","AGGREGATE_CONTINUATION").contains(Objects.toString(action.operationType(),"")))continue;
            boolean aggregate=action!=null&&"AGGREGATE_SUPPLY".equals(action.operationType());
            if(shared&&legacyManufacturing&&!aggregate)continue;
            BigDecimal privateQty=number(reference.allocatedQty());
            total=total.add(privateQty);
        }
        return total;
    }

    private static BigDecimal publicOrdered(List<MaterialView> materials,Map<UUID,ProductView> products,Map<UUID,SupplyActionView> actions) {
        Map<UUID,BigDecimal> covered=new HashMap<>();
        for(MaterialView material:materials) {
            Set<UUID> seen=new HashSet<>();
            for(DownstreamReference reference:material.downstreamReferences()==null?List.<DownstreamReference>of():material.downstreamReferences()) {
                if(reference.actionId()==null||!seen.add(reference.actionId())||"CANCELLED".equals(reference.status())||!Objects.equals(material.sourceConfirmed(),reference.route()))continue;
                SupplyActionView action=actions.get(reference.actionId());
                if(action==null||Set.of("FUTURE_TRANSFER","SHARED_FUTURE_CLAIM","ROOT_OUTPUT","AGGREGATE_CONTINUATION").contains(Objects.toString(action.operationType(),"")))continue;
                ProductView anchor=material.planAnchorAnalysisLineId()==null?null:products.get(material.planAnchorAnalysisLineId());
                boolean legacyManufacturing=anchor!=null&&!"AGGREGATE_MAKE".equals(anchor.sourceType())
                        &&"MAKE".equals(material.sourceConfirmed());
                if(legacyManufacturing&&!"AGGREGATE_SUPPLY".equals(action.operationType()))continue;
                covered.merge(action.actionId(),number(reference.allocatedQty()),BigDecimal::add);
            }
        }
        BigDecimal total=BigDecimal.ZERO;
        for(var entry:covered.entrySet()) {
            SupplyActionView action=actions.get(entry.getKey());
            if(entry.getValue().compareTo(number(action.requestedQty()))>=0)total=total.add(number(action.publicSurplusQty()));
            else if(!"AGGREGATE_SUPPLY".equals(action.operationType())&&number(action.requestedQty()).signum()>0)
                total=total.add(MoneyPolicy.quantityShare(number(action.publicSurplusQty()),entry.getValue(),action.requestedQty()));
        }
        return total;
    }

    private static List<ChildPreview> sharedChildren(MaterialView parent,BigDecimal output,BigDecimal prior,Map<String,List<MaterialView>> children) {
        List<ChildPreview> result=new ArrayList<>();
        for(MaterialView child:children.getOrDefault(nodeRef(parent.analysisLineId(),parent.nodeKey()),List.of())) {
            if(Set.of("SHIP","REFERENCE").contains(Objects.toString(child.controlStage(),"")))continue;
            BigDecimal required=MaterialConsumptionMath.required(output,child.bomQty(),child.consumptionBasis(),child.basisOutputQty(),child.allowPartialPackage())
                    .subtract(MaterialConsumptionMath.required(prior,child.bomQty(),child.consumptionBasis(),child.basisOutputQty(),child.allowPartialPackage())).max(BigDecimal.ZERO);
            result.add(new ChildPreview(child.materialLineId(),child.goodsId(),child.goodsCode(),child.goodsName(),child.colorId(),child.colorName(),
                    child.unitId(),child.unitName(),relativePath(parent.nodeKey(),child.nodeKey()),child.controlStage(),child.consumptionBasis(),
                    child.bomQty(),child.basisOutputQty(),child.allowPartialPackage(),required));
        }
        result.sort(Comparator.comparing(ChildPreview::relativeBomPath));return result;
    }

    private static List<String> recipe(MaterialView parent,Map<String,List<MaterialView>> children) {
        return recipe(parent,children,new HashSet<>());
    }

    /**
     * 配方键按设计使用数量(ADR-129 §2.5)：真实使用数量随学习变化，按它做键会让后续追加找不到
     * 原批次；本批的子件需求仍按各行实际采用的用量(bomQty)展开。
     */
    private static List<String> recipe(MaterialView parent,Map<String,List<MaterialView>> children,Set<UUID> visiting) {
        if(!visiting.add(parent.materialLineId()))throw conflict("组件结构存在循环，请先刷新并核对组件表");
        List<String> result=new ArrayList<>();
        for(MaterialView child:children.getOrDefault(nodeRef(parent.analysisLineId(),parent.nodeKey()),List.of())) {
            List<String> fields=new ArrayList<>();
            add(fields,relativePath(parent.nodeKey(),child.nodeKey()),child.goodsId(),child.colorId(),child.unitId(),child.controlStage(),
                    child.consumptionBasis(),child.designBomQty()==null?child.bomQty():child.designBomQty(),
                    child.basisOutputQty(),child.allowPartialPackage(),child.hardGate(),child.sourceConfirmed(),child.routeConfirmed());
            fields.addAll(recipe(child,children,visiting));result.add(CanonicalFingerprint.sha256(fields));
        }
        visiting.remove(parent.materialLineId());
        result.sort(String::compareTo);return List.copyOf(result);
    }

    static String previewFingerprint(PreviewRequest request,List<GroupPreview> groups) {
        List<String> fields=new ArrayList<>();addTuple(fields,request.version(),request.fingerprint(),request.warehouseId(),request.billDate(),request.deliveryDate(),request.approveNow());
        request.groups().stream().sorted(Comparator.comparing(GroupInput::clientGroupKey)).forEach(input->{
            addTuple(fields,input.clientGroupKey());
            input.materialLineIds().stream().sorted(Comparator.comparing(UUID::toString)).forEach(id->addTuple(fields,id));
            input.sourceRequestedQtyByMaterialLineId().entrySet().stream().sorted(Map.Entry.comparingByKey(Comparator.comparing(UUID::toString)))
                    .forEach(entry->addTuple(fields,entry.getKey(),entry.getValue()));
        });
        groups.stream().sorted(Comparator.comparing(GroupPreview::clientGroupKey)).forEach(group->{
            addTuple(fields,group.clientGroupKey(),group.compatibilityKey(),group.requestedQty(),group.publicExtraQty(),group.safetyQty(),group.blockedReason(),group.existingBatchId(),group.priorOutputQty());
            group.sources().stream().sorted(Comparator.comparing(source->source.materialLineId().toString())).forEach(source->
                    addTuple(fields,source.materialLineId(),source.analysisLineId(),source.allocationPriority(),source.needDate(),source.remainingQty(),source.allocatedQty(),source.orderedQty()));
            group.sources().forEach(source->source.originalMaterialLineIds().forEach(original->addTuple(fields,"original-source",source.materialLineId(),original)));
            group.sharedBomChildren().forEach(child->addTuple(fields,child.relativeBomPath(),child.goodsId(),child.colorId(),child.unitId(),child.requiredQty()));
        });
        return CanonicalFingerprint.sha256(fields);
    }

    private static void addTuple(List<String> target,Object... values) {
        StringBuilder tuple=new StringBuilder();
        for(Object value:values) {
            String text=value==null?"N":"V"+(value instanceof BigDecimal decimal?decimal.stripTrailingZeros().toPlainString():value.toString());
            tuple.append(text.length()).append(':').append(text);
        }
        target.add(tuple.toString());
    }

    private static void validateHeader(UUID id,PreviewRequest request,AnalysisView view) {
        if(request==null||request.version()==null||request.fingerprint()==null||request.warehouseId()==null||request.billDate()==null||request.groups().isEmpty())throw invalid("汇总下单信息不完整");
        if(!Objects.equals(id,view.analysisId())||request.version()!=view.version()||!request.fingerprint().equals(view.fingerprint())||!request.warehouseId().equals(view.warehouseId()))throw conflict("分析或库存范围已变化，请刷新并重新核对汇总");
        if(view.fqcReplenishmentOnly())throw invalid("品质补产使用原来源专用办理入口");
        if(!Set.of("ACTIVE","PARTIALLY_PLANNED").contains(view.status()))throw conflict("当前物料分析已结束，不能继续下单");
    }

    static void requireSourceScope(List<GroupInput> groups) {
        long count=groups.stream().filter(Objects::nonNull).mapToLong(group->group.materialLineIds().size()).sum();
        if(count>RequestLimits.MATERIAL_AGGREGATE_SOURCE_PATHS)
            throw invalid("单次汇总最多核对10000条原来源路径，请分次选择物料；同一物料的来源请保留在一组");
    }

    /**
     * 没填允许超产比例 = 按货品默认(ADR-129 §2.10，{@code ProductionOverproductionAllowance.defaults}
     * 随分析视图一次取回)，不再静默按 0。默认表里没有该货品说明货品已删除或停用。
     */
    private static BigDecimal defaultOverproductionRate(Map<UUID,BigDecimal> defaults,UUID goodsId) {
        BigDecimal rate=defaults.get(goodsId);
        if(rate==null)throw conflict("货品不存在或已停用，无法读取允许超产比例");
        return rate;
    }

    private static String relativePath(String parent,String child) {
        if(parent!=null&&child!=null&&child.startsWith(parent))return child.substring(parent.length());
        return Objects.toString(child,"");
    }
    private static String nodeRef(UUID source,String key) { return source+"|"+key; }
    private static void add(List<String> target,Object... values) { for(Object value:values)target.add(value==null?"N":"V"+(value instanceof BigDecimal decimal?decimal.stripTrailingZeros().toPlainString():value.toString())); }
    private static BigDecimal number(BigDecimal value) { return value==null?BigDecimal.ZERO:value; }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED,message); }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT,message); }
}
