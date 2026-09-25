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
        List<GroupPreview> result=new ArrayList<>();
        for(GroupInput group:request.groups()) {
            if(group==null||group.clientGroupKey()==null||group.clientGroupKey().isBlank()||!clientKeys.add(group.clientGroupKey()))throw invalid("汇总行标识缺失或重复");
            if(group.materialLineIds().isEmpty())throw invalid("汇总行必须包含明确的来源物料");
            List<MaterialView> members=new ArrayList<>();
            for(UUID id:group.materialLineIds()) {
                if(id==null||!used.add(id))throw invalid("同一来源不能在本次汇总下单中出现两次");
                MaterialView material=materials.get(id);
                if(material==null)throw conflict("汇总来源已变化或不可见，请刷新并重新核对");
                members.add(material);
            }
            members.sort(Comparator.comparing(member->member.materialLineId().toString()));
            GroupPreview resolved=resolveGroup(analysisId,request,group,members,products,actions,children,view.overproductionDefaults());
            if(!compatibilityKeys.add(resolved.compatibilityKey()))throw invalid("同一物料及相同办理规则只能提交一组，请合并来源和总量后重新核对");
            result.add(resolved);
        }
        String token=previewFingerprint(request,result);
        return new Preview(analysisId,view.version(),view.fingerprint(),token,result,view);
    }

    private GroupPreview resolveGroup(UUID analysisId,PreviewRequest request,GroupInput input,List<MaterialView> members,
            Map<UUID,ProductView> products,Map<UUID,SupplyActionView> actions,Map<String,List<MaterialView>> children,
            Map<UUID,BigDecimal> rateDefaults) {
        MaterialView first=members.getFirst();
        String reason=null;
        if(!Set.of("BUY","MAKE","SUBCONTRACT").contains(Objects.toString(input.route(),"")))throw invalid("汇总供应方式无效");
        List<String> recipe=recipe(first,children);
        for(MaterialView member:members) {
            if(member.level()==0)throw invalid("顶层产品请按产品办理，保留原产品及销售订单来源；物料汇总只办理组件");
            if(!Objects.equals(first.goodsId(),member.goodsId())||!Objects.equals(first.colorId(),member.colorId())||!Objects.equals(first.unitId(),member.unitId()))throw invalid("不同货品、颜色或单位不能合并为一行下单");
            if(!member.routeConfirmed()||!input.route().equals(member.sourceConfirmed()))reason="来源供应方式不一致或尚未确认，请先核对供应方式";
            if(!recipe.equals(recipe(member,children)))reason="相同物料的冻结组件规则不同，请按生产规则分别办理";
            if(!member.actionable()&&number(member.requiredQty()).signum()==0&&number(member.planningUncoveredQty()).signum()==0
                    && !Set.of("ACTIVE","TRANSFERRED_TO_PLAN").contains(Objects.toString(member.requirementState(),"")))reason="部分来源已转交其他任务或本批无需办理，请按当前有效来源重新选择";
        }
        boolean manufacture="MAKE".equals(input.route()) || ("SUBCONTRACT".equals(input.route()) && !recipe.isEmpty()
                && !"COMPONENT_OUTBOUND".equals(first.subcontractOutboundForm()));
        LocalDate bill=input.billDate()==null?request.billDate():input.billDate();
        LocalDate delivery=input.deliveryDate()==null?request.deliveryDate():input.deliveryDate();
        if(delivery!=null&&bill!=null&&delivery.isBefore(bill))reason="计划完成日期不能早于下单日期";
        if(number(input.qty()).signum()>0) {
            if(manufacture&&(input.departmentId()==null||input.workerId()==null))reason="请为汇总批次填写生产车间和负责人";
            String permission=manufacture?"production_material_analysis:generate":"production_material_analysis:notify";
            if(!access.hasAuthority(permission))reason=manufacture?"缺少下达车间权限":"缺少下达采购或委外权限";
            if(manufacture&&request.approveNow()&&!access.hasAuthority("production_plan:approve"))reason="生成并审核需要生产计划审核权限";
        }
        BigDecimal rate=manufacture?(input.allowedOverproductionRate()==null
                ?rateDefaults.getOrDefault(first.goodsId(),BigDecimal.ZERO):input.allowedOverproductionRate()):null;
        if(rate!=null&&(rate.signum()<0||rate.compareTo(new BigDecimal("1000"))>=0||rate.stripTrailingZeros().scale()>6))throw invalid("允许超产比例无效");
        List<AggregateQuantityAllocator.SourceCapacity> capacities=new ArrayList<>();
        Map<UUID,BigDecimal> ordered=new LinkedHashMap<>();
        Map<UUID,BigDecimal> remainingBySource=new HashMap<>();
        for(MaterialView member:members) {
            ProductView product=products.get(member.analysisLineId());
            BigDecimal remaining=number(member.planningUncoveredQty());
            ProductView anchor=member.planAnchorAnalysisLineId()==null?null:products.get(member.planAnchorAnalysisLineId());
            if(manufacture&&anchor!=null&&!"AGGREGATE_MAKE".equals(anchor.sourceType())&&number(anchor.remainingQty()).signum()>0) {
                remaining=remaining.max(anchor.remainingQty());
                reason="已有按原来源建立的待下达制造责任，请先在原任务完成或撤回后再汇总";
            }
            remainingBySource.put(member.materialLineId(),remaining);
            capacities.add(new AggregateQuantityAllocator.SourceCapacity(member.materialLineId(),
                    product==null?0:product.allocationPriority(),product==null?null:product.deliveryDate(),
                    remaining));
            ordered.put(member.materialLineId(),orderedQuantity(member,products,actions));
        }
        var allocation=AggregateQuantityAllocator.allocate(input.qty(),capacities,true);
        if(allocation.publicExtraQty().signum()>0 && !input.allowPublicExtra())reason="本次超出待安排需求，请明确核对公共备货量";
        if(allocation.publicExtraQty().signum()>0 && !manufacture && !access.hasAuthority("production_material_analysis:over_supply"))reason="公共超量备货需要超量下达权限";
        if(number(input.safetyQty()).signum()>0)reason="公共安全库存补库请使用既有独立补库入口，不能混入产品来源汇总";
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
                    shares.getOrDefault(member.materialLineId(),BigDecimal.ZERO),ordered.get(member.materialLineId())));
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
        List<ChildPreview> childRows=sharedChildren(first,prior.add(number(input.qty())),prior,children);
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
        if(!shared&&anchor!=null&&("MAKE".equals(material.sourceConfirmed())||"SUBCONTRACT_MAKE".equals(anchor.sourceType()))) {
            return number(anchor.issuedPlanQty()).multiply(material.level()==0&&anchor.unitRate()!=null?anchor.unitRate():BigDecimal.ONE);
        }
        boolean legacyManufacturing=anchor!=null&&!"AGGREGATE_MAKE".equals(anchor.sourceType())
                &&("MAKE".equals(material.sourceConfirmed())||"SUBCONTRACT_MAKE".equals(anchor.sourceType()));
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
                        &&("MAKE".equals(material.sourceConfirmed())||"SUBCONTRACT_MAKE".equals(anchor.sourceType()));
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

    private static List<String> recipe(MaterialView parent,Map<String,List<MaterialView>> children,Set<UUID> visiting) {
        if(!visiting.add(parent.materialLineId()))throw conflict("组件结构存在循环，请先刷新并核对组件表");
        List<String> result=new ArrayList<>();
        for(MaterialView child:children.getOrDefault(nodeRef(parent.analysisLineId(),parent.nodeKey()),List.of())) {
            List<String> fields=new ArrayList<>();
            add(fields,relativePath(parent.nodeKey(),child.nodeKey()),child.goodsId(),child.colorId(),child.unitId(),child.controlStage(),
                    child.consumptionBasis(),child.bomQty(),child.basisOutputQty(),child.allowPartialPackage(),child.hardGate(),child.sourceConfirmed(),child.routeConfirmed());
            fields.addAll(recipe(child,children,visiting));result.add(CanonicalFingerprint.sha256(fields));
        }
        visiting.remove(parent.materialLineId());
        result.sort(String::compareTo);return List.copyOf(result);
    }

    static String previewFingerprint(PreviewRequest request,List<GroupPreview> groups) {
        List<String> fields=new ArrayList<>();add(fields,request.version(),request.fingerprint(),request.warehouseId(),request.billDate(),request.deliveryDate(),request.approveNow());
        groups.stream().sorted(Comparator.comparing(GroupPreview::clientGroupKey)).forEach(group->{
            add(fields,group.clientGroupKey(),group.compatibilityKey(),group.requestedQty(),group.publicExtraQty(),group.safetyQty(),group.blockedReason(),group.existingBatchId(),group.priorOutputQty());
            group.sources().stream().sorted(Comparator.comparing(source->source.materialLineId().toString())).forEach(source->
                    add(fields,source.materialLineId(),source.analysisLineId(),source.allocationPriority(),source.needDate(),source.remainingQty(),source.allocatedQty(),source.orderedQty()));
            group.sharedBomChildren().forEach(child->add(fields,child.relativeBomPath(),child.goodsId(),child.colorId(),child.unitId(),child.requiredQty()));
        });
        return CanonicalFingerprint.sha256(fields);
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
