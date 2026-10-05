package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.purchase.request.ProductionPurchaseRequestFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.*;
import java.util.stream.Collectors;
import static com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;

/** One reviewed material total becomes one real compatible order or manufacturing batch. */
@Service
@RequiredArgsConstructor
public class AggregateMaterialOrderWriteService implements AggregateMaterialOrderContracts.Writer {
    private final EntityManager em;
    private final MaterialAnalysisService analysis;
    private final MaterialAnalysisCommandService commands;
    private final AggregateMaterialOrderPreviewService previews;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionPurchaseRequestFacade purchases;
    private final ProductionSubcontractRequestPort subcontract;
    private final PreplanStockEntitlementService entitlements;
    private final SecurityContextCurrentUser user;
    private final TxSessionVars tx;
    private final ObjectMapper mapper;
    private final ChainNoticeService notices;
    private final com.uten.imp.features.production.plan.ProductionPlanService planService;
    private final com.uten.imp.features.production.mrp.ProductionPlanningPackageService planningPackages;
    private final AggregateMissingDeepAliasRepair missingDeepAliases;

    @Override @Transactional public AnalysisView cancel(UUID analysisId,UUID actionId,MaterialAnalysisContracts.CancelRequest request) {
        if(request==null||request.version()==null||request.fingerprint()==null||request.idempotencyKey()==null
                ||!request.idempotencyKey().matches("[A-Za-z0-9._:-]{8,128}"))throw invalid("整批撤回缺少版本或幂等键");
        tx.bind();var guard=commands.lockAnalysisWithClaimableShared(analysisId);var header=analysis.headerAfterPrelock(analysisId);
        access.requireWritable(header.makerId(),"只能撤回本人负责的共享批次",analysis.scopeForAnalysis(header));
        String hash=CanonicalFingerprint.sha256(List.of("AGGREGATE-CANCEL-V1",analysisId.toString(),actionId.toString(),request.version().toString(),request.fingerprint(),request.effectiveReason()));
        List<?> replay=em.createNativeQuery("SELECT request_hash FROM production_material_analysis_commands WHERE analysis_id=:analysis AND operation='AGGREGATE_CANCEL' AND idempotency_key=:key")
                .setParameter("analysis",analysisId).setParameter("key",request.idempotencyKey()).getResultList();
        if(!replay.isEmpty()){if(!hash.equals(replay.getFirst()))throw conflict("相同撤回键已用于另一项操作");return analysis.detailInternal(analysisId,false);}
        guard.verifyUnchanged();analysis.requireCurrent(header,request.version(),request.fingerprint());
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT batch.id,batch.plan_id,batch.route,action.status,batch.row_version FROM preplan_aggregate_batches batch JOIN preplan_supply_actions action ON action.id=batch.action_id WHERE batch.analysis_id=:analysis AND batch.action_id=:action FOR UPDATE OF batch,action")
                .setParameter("analysis",analysisId).setParameter("action",actionId));
        if(rows.isEmpty())throw conflict("共享批次不存在或不属于当前分析");Object[] row=rows.getFirst();UUID plan=(UUID)row[1];
        String permission=plan==null?"production_material_analysis:notify":"production_material_analysis:generate";
        if(!access.hasAuthority(permission))throw forbidden("缺少该共享批次的撤回权限");
        if(!"CANCELLED".equals(row[3])) {
            if(plan!=null) {
                Object[] state=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT status,is_deleted FROM production_plans WHERE id=:id FOR UPDATE").setParameter("id",plan)).getFirst();
                if(!Boolean.TRUE.equals(state[1])&&((Number)state[0]).intValue()==1) {
                    if(!access.hasAuthority("production_plan:reverse"))throw forbidden("撤回已审核共享计划需要生产计划红冲权限");
                    for(UUID pack:NativeQueryResults.typedRows(em.createNativeQuery("SELECT id FROM production_planning_packages WHERE plan_id=:plan AND status='CONFIRMED' AND NOT is_deleted ORDER BY id").setParameter("plan",plan),UUID.class))
                        planningPackages.reverse(plan,pack,new com.uten.imp.features.production.mrp.PlanningPackageLifecycleRequest(stepKey(request.idempotencyKey(),pack.toString(),"CANCEL-PACKAGE"),request.effectiveReason()));
                    planService.reverse(plan);
                } else if(!Boolean.TRUE.equals(state[1])&&((Number)state[0]).intValue()==0) {
                    if(!access.hasAuthority("production_plan:delete"))throw forbidden("撤回共享草稿计划需要生产计划删除权限");planService.delete(plan);
                }
                entitlements.restoreMakeDelegationsForAction(analysisId,actionId,"MAKE-DELEGATE-CANCEL:"+actionId);
            }
            commands.cancelAggregateAction(analysisId,actionId,request.effectiveReason());
            em.createNativeQuery("""
                    INSERT INTO preplan_aggregate_batch_events(batch_id,event_type,expected_version,resulting_version,idempotency_key,request_hash,created_by)
                    VALUES(:batch,'CANCEL',:version,:result,:key,:hash,:actor)
                    """).setParameter("batch",row[0]).setParameter("version",((Number)row[4]).longValue()).setParameter("result",((Number)row[4]).longValue()+1)
                    .setParameter("key","CANCEL:"+request.idempotencyKey()).setParameter("hash",hash).setParameter("actor",user.requireId()).executeUpdate();
            em.createNativeQuery("UPDATE preplan_aggregate_batches SET row_version=row_version+1 WHERE id=:id").setParameter("id",row[0]).executeUpdate();
            analysis.refreshLocked(analysisId);
        }
        ObjectNode payload=mapper.createObjectNode();payload.put("actionId",actionId.toString());payload.put("batchId",row[0].toString());
        em.createNativeQuery("INSERT INTO production_material_analysis_commands(analysis_id,operation,idempotency_key,request_hash,result_payload,created_by) VALUES(:analysis,'AGGREGATE_CANCEL',:key,:hash,CAST(:payload AS jsonb),:actor)")
                .setParameter("analysis",analysisId).setParameter("key",request.idempotencyKey()).setParameter("hash",hash).setParameter("payload",payload.toString()).setParameter("actor",user.requireId()).executeUpdate();
        return analysis.detailInternal(analysisId,false);
    }

    @Transactional public SubmitResult submit(UUID analysisId,SubmitRequest request) {
        validateRequest(request);tx.bind();
        var guard=commands.lockAnalysisWithClaimableShared(analysisId);
        var header=analysis.headerAfterPrelock(analysisId);
        access.requireWritable(header.makerId(),"只能下达本人负责的物料分析",analysis.scopeForAnalysis(header));
        String hash=hashRequest(analysisId,request);
        List<Object[]> replay=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT request_hash,result_payload::text FROM production_material_analysis_commands
                WHERE analysis_id=:analysis AND operation='AGGREGATE_ORDER' AND idempotency_key=:key
                """).setParameter("analysis",analysisId).setParameter("key",request.idempotencyKey()));
        if(!replay.isEmpty()) {
            if(!hash.equals(replay.getFirst()[0]))throw conflict("相同幂等键不能用于不同汇总下单意图");
            try{var payload=mapper.readTree((String)replay.getFirst()[1]);return new SubmitResult(analysis.detailInternal(analysisId,false),true,
                    mapper.readValue(payload.path("batches").toString(),new TypeReference<List<BatchResult>>(){}),
                    payload.has("materialIdentityBridges")?mapper.readValue(payload.path("materialIdentityBridges").toString(),new TypeReference<List<MaterialIdentityBridge>>(){}):List.of());}
            catch(java.io.IOException failure){throw new IllegalStateException("汇总下单回执损坏",failure);}
        }
        guard.verifyUnchanged();analysis.requireCurrent(header,request.version(),request.fingerprint());
        // Admission preview is recomputed against the same live stock snapshot under the complete footprint.
        MaterialAnalysisIssuePreviewOverlay overlay=MaterialAnalysisIssuePreviewOverlay.create();
        analysis.projectIssuePreviewBase(analysisId,overlay);
        Preview reviewed=previews.resolve(analysisId,request.previewRequest(),analysis.issuePreviewView(analysisId,overlay,Map.of()));
        if(!Objects.equals(reviewed.previewFingerprint(),request.previewFingerprint()))throw conflict("汇总来源、已下达或可用供给已变化，请重新核对");
        // ADR-143 §二.3：缺 BOM 的委外件先转研发(独立事务立即提交，随后的 409 不撤销)，再拒绝本次汇总下达。
        Map<UUID,MaterialView> reviewedRows=reviewed.analysis().flatMaterials().stream()
                .collect(Collectors.toMap(MaterialView::materialLineId,row->row,(left,right)->left));
        analysis.rejectSubcontractBomGaps(header,reviewed.groups().stream().filter(group->"SUBCONTRACT".equals(group.route()))
                .flatMap(group->group.sources().stream()).map(source->reviewedRows.get(source.materialLineId()))
                .filter(Objects::nonNull).toList());
        if(reviewed.groups().stream().anyMatch(group->group.blockedReason()!=null))throw conflict(reviewed.groups().stream().map(GroupPreview::blockedReason).filter(Objects::nonNull).findFirst().orElseThrow());
        // Parent groups commit first inside this transaction. Each following group
        // resolves its unchanged original ids against the refreshed exact alias graph.
        Map<String,GroupInput> inputs=request.groups().stream().collect(Collectors.toMap(GroupInput::clientGroupKey,value->value));
        Map<UUID,Integer> levels=reviewed.analysis().flatMaterials().stream().collect(Collectors.toMap(MaterialView::materialLineId,MaterialView::level));
        List<GroupPreview> ordered=reviewed.groups().stream().filter(group->group.requestedQty().signum()>0||group.safetyQty().signum()>0)
                .sorted(Comparator.comparingInt((GroupPreview group)->inputs.get(group.clientGroupKey()).materialLineIds().stream().mapToInt(source->levels.getOrDefault(source,Integer.MAX_VALUE)).min().orElse(Integer.MAX_VALUE))
                        .thenComparingInt(group->"BUY".equals(group.route())?2:"SUBCONTRACT".equals(group.route())?1:0).thenComparing(GroupPreview::clientGroupKey)).toList();
        if(ordered.isEmpty())throw invalid("本次没有正数下达量");
        analysis.refreshLocked(analysisId);
        AnalysisView nextSnapshot=analysis.detailInternal(analysisId,false);
        List<BatchResult> results=new ArrayList<>();List<SourceAdoptionIntent> sourceAdoptions=new ArrayList<>();
        Set<String> safetyDimensions=new HashSet<>();
        int cursor=0;
        while(cursor<ordered.size()) {
            AnalysisView current=nextSnapshot==null?analysis.detailInternal(analysisId,false):nextSnapshot;
            nextSnapshot=null;
            List<GroupPreview> cohort=new ArrayList<>();int end=cursor;
            while(end<ordered.size()) {
                List<GroupPreview> candidate=new ArrayList<>(cohort);candidate.add(ordered.get(end));
                if(!independentManufacturing(candidate,inputs,current))break;
                cohort.add(ordered.get(end++));
            }
            if(cohort.size()>1) {
                List<BatchResult> grouped=submitIndependentManufacturing(analysisId,request,cohort,inputs,current,hash);
                if(grouped!=null){results.addAll(grouped);cursor=end;continue;}
            }
            GroupPreview original=ordered.get(cursor++);
            GroupInput input=inputs.get(original.clientGroupKey());
            GroupInput remapped=input; // resolve() reads the current exact alias projection for every depth.
            PreviewRequest step=new PreviewRequest(current.version(),current.fingerprint(),request.idempotencyKey(),request.warehouseId(),request.billDate(),request.deliveryDate(),request.approveNow(),List.of(remapped));
            GroupPreview group=previews.resolve(analysisId,step,current).groups().getFirst();
            if(group.blockedReason()!=null)throw conflict(group.blockedReason());
            boolean manufacturing=manufacturing(group);
            if(manufacturing&&request.approveNow()&&!access.hasAuthority("production_plan:approve"))throw forbidden("立即审核需要生产计划审核权限");
            String permission=manufacturing?"production_material_analysis:generate":"production_material_analysis:notify";
            if(!access.hasAuthority(permission))throw forbidden("缺少本次汇总下达路线权限");
            if(!manufacturing&&group.publicExtraQty().signum()>0&&!access.hasAuthority("production_material_analysis:over_supply"))throw forbidden("外部公共备货需要独立超量下达权限");
            if(group.safetyQty().signum()>0&&!safetyDimensions.add(group.goodsId()+":"+Objects.toString(group.colorId(),"")))throw invalid("同一物料公共安全库存补库只能提交一次");
            Set<UUID> selectedIds=group.sources().stream().map(SourcePreview::materialLineId).collect(Collectors.toSet());
            Map<UUID,MaterialAnalysisContracts.ProductView> currentProducts=current.products().stream().collect(Collectors.toMap(MaterialAnalysisContracts.ProductView::analysisLineId,value->value));
            boolean retainedMakeResponsibility=current.flatMaterials().stream().filter(row->selectedIds.contains(row.materialLineId()))
                    .anyMatch(row->{var anchor=currentProducts.get(row.planAnchorAnalysisLineId());return row.priorityMakeSupplementQty().signum()>0||row.requiredQty().signum()==0
                        &&anchor!=null&&!"AGGREGATE_MAKE".equals(anchor.sourceType())&&anchor.remainingQty().signum()>0;});
            List<AdoptedClaim> adoptedClaims=new ArrayList<>();
            // One material split into several orders (ADR-120 §8) commits group by group. A sibling's new
            // public share was not part of the reviewed preview, so it is never adopted here.
            Set<UUID> commandPlans=results.stream().map(BatchResult::planId).filter(Objects::nonNull).collect(Collectors.toSet());
            Map<UUID,Map<UUID,BigDecimal>> originalFlow=originalPrivateFlow(input,group,current);
            List<SourceAdoptionIntent> adoptionIntents;
            // ADR-099 修订(2026-09-29)：skipAutoClaim = 用户明确选择「足额下单，不扣可用
            // 数量」，两类自动认领(自制公共超产/同主仓公共在途)一并不做，按核对数量足额下达。
            if(originalFlow!=null&&!retainedMakeResponsibility&&!request.skipClaims()) {
                Map<UUID,BigDecimal> desired=originalFlowTotals(input,originalFlow);
                Set<UUID> repairOrigins=current.flatMaterials().stream()
                        .filter(row->desired.getOrDefault(row.materialLineId(),BigDecimal.ZERO).signum()>0
                                && decimal(row.preparationAdoptableSharedQty()).signum()>0)
                        .map(MaterialView::materialLineId).collect(Collectors.toSet());
                // Historical releases may predate deep alias recording. Establish
                // only their proven responsibility before a MAKE claim's DB capacity check.
                if(!repairOrigins.isEmpty())missingDeepAliases.repair(analysisId,repairOrigins);
                Map<UUID,BigDecimal> makeClaims=commands.claimOriginalAggregateMakeFuture(analysisId,desired,
                        stepKey(request.idempotencyKey(),group.clientGroupKey(),"MAKE-PUBLIC-CLAIM"),commandPlans,adoptedClaims::add);
                Map<UUID,BigDecimal> remaining=new LinkedHashMap<>(desired);
                makeClaims.forEach((id,qty)->remaining.compute(id,(ignored,value)->value.subtract(qty)));
                commands.claimOriginalAggregateFuture(analysisId,current,remaining,
                        stepKey(request.idempotencyKey(),group.clientGroupKey(),"CLAIM"),hash,adoptedClaims::add);
                adoptionIntents=adoptedClaims.stream().map(claim->new SourceAdoptionIntent(claim.targetMaterialLineId(),claim.targetMaterialLineId(),claim.kind(),claim.claimId(),claim.qty())).toList();
                if(!adoptedClaims.isEmpty()) {
                    BigDecimal actualNew=group.requestedQty().subtract(adoptedClaims.stream().map(AdoptedClaim::qty).reduce(BigDecimal.ZERO,BigDecimal::add));
                    analysis.refreshLocked(analysisId);current=analysis.detailInternal(analysisId,false);
                    // Existing aliases may retain part at the original row before forwarding it FIFO.
                    // Re-resolve the remaining intent from those real claims, never guess its target split.
                    GroupInput remainingIntent=issuedIntent(input,actualNew,adoptionIntents);
                    group=previews.resolve(analysisId,new PreviewRequest(current.version(),current.fingerprint(),request.idempotencyKey(),
                            request.warehouseId(),request.billDate(),request.deliveryDate(),request.approveNow(),List.of(remainingIntent)),current).groups().getFirst();
                    if(group.blockedReason()!=null&&actualNew.signum()>0)throw conflict(group.blockedReason());
                    originalFlow=originalPrivateFlow(remainingIntent,group,current);
                }
            } else {
            Map<UUID,BigDecimal> makeClaims=retainedMakeResponsibility||request.skipClaims()?Map.of():commands.claimAggregateMakeFuture(analysisId,current,group,
                    stepKey(request.idempotencyKey(),group.clientGroupKey(),"MAKE-PUBLIC-CLAIM"),commandPlans,adoptedClaims::add);
            if(!makeClaims.isEmpty()) {
                List<SourcePreview> sources=group.sources().stream().map(source->source(source,
                        source.allocatedQty().subtract(makeClaims.getOrDefault(source.materialLineId(),BigDecimal.ZERO)).max(BigDecimal.ZERO))).toList();
                group=quantities(group,sources,sum(sources).add(group.publicExtraQty()));
                analysis.refreshLocked(analysisId);
                current=analysis.detailInternal(analysisId,false);
            }
            if(!retainedMakeResponsibility&&!request.skipClaims()) {
                Map<UUID,BigDecimal> claimed=commands.claimAggregateFuture(analysisId,current,group,stepKey(request.idempotencyKey(),group.clientGroupKey(),"CLAIM"),hash,adoptedClaims::add);
                List<SourcePreview> sources=group.sources().stream().map(source->source(source,source.allocatedQty().subtract(claimed.getOrDefault(source.materialLineId(),BigDecimal.ZERO)).max(BigDecimal.ZERO))).toList();
                group=quantities(group,sources,sum(sources).add(group.publicExtraQty()));
                if(!claimed.isEmpty()&&claimed.values().stream().anyMatch(qty->qty.signum()>0)) {
                    analysis.refreshLocked(analysisId);
                    current=analysis.detailInternal(analysisId,false);
                }
            }
            adoptionIntents=sourceAdoptionIntents(input,group,adoptedClaims,reviewed.analysis());
            }
            Map<UUID,BigDecimal> privateProof=originalFlow==null||!hasOriginalBeneficiaryProof(input,current)?null:originalFlowTotals(input,originalFlow);
            sourceAdoptions.addAll(adoptionIntents);
            if(group.requestedQty().signum()==0&&group.safetyQty().signum()==0)continue;
            BatchResult legacy=issueExistingSingleSource(analysisId,current,group,request,manufacturing,input.allowedOverproductionRate());
            if(legacy!=null){results.add(legacy);continue;}
            GroupInput issueIntent=issuedIntent(input,group.requestedQty(),adoptionIntents);
            Map<UUID,CapacitySnapshot> capacities=manufacturing?captureSourceCapacities(group,current):Map.of();
            Batch batch=findReusable(analysisId,group,manufacturing,request.approveNow());
            boolean append=batch!=null;
            if(batch==null)batch=createBatch(analysisId,group,issueIntent,request,hash,manufacturing,current,privateProof,originalFlow);
            else appendBatch(batch,group,issueIntent,request,hash,privateProof,originalFlow);
            if(manufacturing) {
                analysis.refreshLocked(analysisId);
                installAliases(batch,group,capacities,request.idempotencyKey());
                copySharedRoutes(batch);
                analysis.refreshLocked(analysisId);
                entitlements.delegateAggregateMakeEntitlements(analysisId,batch.action());
                var plan=commands.issueAggregateAnchor(analysisId,batch.id(),batch.anchor(),group,input.allowedOverproductionRate(),
                        request.warehouseId(),request.approveNow(),stepKey(request.idempotencyKey(),group.clientGroupKey(),"PLAN"));
                analysis.refreshWithAnchorGrowth(analysisId);
                results.add(new BatchResult(batch.id(),group.clientGroupKey(),group.route(),"PRODUCTION_PLAN",plan.planId(),plan.planNo(),plan.planId(),batch.anchor(),group.requestedQty(),group.publicExtraQty(),group.sources(),plan));
            } else {
                External external=append?growExternal(batch,group):createExternal(batch,group,request.warehouseId());
                notices.notifyPreplanSupplyDocumentCreated(external.id(),external.type());
                analysis.refreshLocked(analysisId);
                results.add(new BatchResult(batch.id(),group.clientGroupKey(),group.route(),external.type(),external.id(),external.no(),null,null,group.requestedQty().add(group.safetyQty()),group.publicExtraQty(),group.sources()));
            }
        }
        List<MaterialIdentityBridge> bridges=materialBridges(results.stream().filter(result->result.batchId()!=null&&result.anchorAnalysisItemId()!=null).map(BatchResult::batchId).distinct().toList());
        ObjectNode payload=mapper.createObjectNode();payload.set("batches",mapper.valueToTree(results));payload.set("materialIdentityBridges",mapper.valueToTree(bridges));
        payload.set("sourceOrderIntent",mapper.valueToTree(request.groups()));
        payload.set("sourceAdoptionIntent",mapper.valueToTree(sourceAdoptions));
        em.createNativeQuery("""
                INSERT INTO production_material_analysis_commands(analysis_id,operation,idempotency_key,request_hash,result_payload,created_by)
                VALUES(:analysis,'AGGREGATE_ORDER',:key,:hash,CAST(:payload AS jsonb),:actor)
                """).setParameter("analysis",analysisId).setParameter("key",request.idempotencyKey()).setParameter("hash",hash).setParameter("payload",payload.toString()).setParameter("actor",user.requireId()).executeUpdate();
        return new SubmitResult(analysis.detailInternal(analysisId,false),false,results,bridges);
    }

    /**
     * Independent manufacturing outputs share tree rebuilding, never execution inventory snapshots.
     * Every plan still creates/approves sequentially against the live, already-locked stock budget.
     */
    private List<BatchResult> submitIndependentManufacturing(UUID analysisId,SubmitRequest request,List<GroupPreview> ordered,
            Map<String,GroupInput> inputs,AnalysisView current,String hash) {
        if(ordered.size()<2||!independentManufacturing(ordered,inputs,current))return null;
        PreviewRequest step=new PreviewRequest(current.version(),current.fingerprint(),request.idempotencyKey(),request.warehouseId(),
                request.billDate(),request.deliveryDate(),request.approveNow(),ordered.stream().map(group->inputs.get(group.clientGroupKey())).toList());
        Map<String,GroupPreview> resolved=previews.resolve(analysisId,step,current).groups().stream()
                .collect(Collectors.toMap(GroupPreview::clientGroupKey,value->value));
        if(!independentManufacturing(ordered.stream().map(group->resolved.get(group.clientGroupKey())).toList(),inputs,current))return null;
        record Prepared(Batch batch,GroupPreview group,Map<UUID,CapacitySnapshot> capacities) { }
        List<Prepared> prepared=new ArrayList<>();
        Map<UUID,CapacitySnapshot> capacities=captureSourceCapacities(
                ordered.stream().map(group->resolved.get(group.clientGroupKey())).toList(),current);
        for(GroupPreview original:ordered) {
            GroupPreview group=resolved.get(original.clientGroupKey());
            if(group.blockedReason()!=null)throw conflict(group.blockedReason());
            Batch batch=findReusable(analysisId,group,true,request.approveNow());
            GroupInput originalInput=inputs.get(group.clientGroupKey());
            Map<UUID,Map<UUID,BigDecimal>> flow=originalPrivateFlow(originalInput,group,current);
            Map<UUID,BigDecimal> privateProof=flow==null?null:originalFlowTotals(originalInput,flow);
            if(batch==null)batch=createBatch(analysisId,group,originalInput,request,hash,true,current,privateProof,flow);
            else appendBatch(batch,group,originalInput,request,hash,privateProof,flow);
            prepared.add(new Prepared(batch,group,capacities));
        }
        analysis.refreshLocked(analysisId);
        Map<UUID,AliasReadSnapshot> aliasReads=readAliasSnapshots(prepared.stream()
                .map(item->new AliasReadRequest(item.batch(),item.group())).toList());
        for(Prepared item:prepared) {
            installAliases(item.batch(),item.group(),item.capacities(),request.idempotencyKey(),aliasReads.get(item.batch().id()));
        }
        copySharedRoutes(prepared.stream().map(Prepared::batch).toList());
        analysis.refreshLocked(analysisId);
        for(Prepared item:prepared)entitlements.delegateAggregateMakeEntitlements(analysisId,item.batch().action());
        Map<UUID,MaterialAnalysisPlanSource> anchors=analysis.aggregatePlanSources(analysisId,
                prepared.stream().map(item->item.batch().anchor()).collect(Collectors.toSet()));
        List<BatchResult> results=new ArrayList<>();
        for(Prepared item:prepared) {
            Batch batch=item.batch();GroupPreview group=item.group();
            var plan=commands.issueAggregateAnchor(analysisId,batch.id(),batch.anchor(),group,
                    inputs.get(group.clientGroupKey()).allowedOverproductionRate(),request.warehouseId(),request.approveNow(),
                    stepKey(request.idempotencyKey(),group.clientGroupKey(),"PLAN"),anchors.get(batch.anchor()));
            results.add(new BatchResult(batch.id(),group.clientGroupKey(),group.route(),"PRODUCTION_PLAN",plan.planId(),plan.planNo(),
                    plan.planId(),batch.anchor(),group.requestedQty(),group.publicExtraQty(),group.sources(),plan));
            // This completed plan has returned only IDs/immutable views and its
            // execution snapshot scope is closed. Flush before detaching so the
            // next plan does not dirty-check every earlier package/JSON draft on
            // each query. The transaction and all database locks remain held;
            // the next plan reads the latest stock through its usual locked path.
            em.flush();
            em.clear();
        }
        analysis.refreshWithAnchorGrowth(analysisId);
        return results;
    }

    static boolean independentManufacturing(List<GroupPreview> groups,Map<String,GroupInput> inputs,AnalysisView view) {
        if(groups.isEmpty()||groups.stream().anyMatch(group->!"MAKE".equals(group.route())||group.safetyQty().signum()>0))return false;
        Map<UUID,MaterialView> rows=view.flatMaterials().stream().collect(Collectors.toMap(MaterialView::materialLineId,value->value));
        Map<UUID,MaterialAnalysisContracts.ProductView> products=view.products().stream()
                .collect(Collectors.toMap(MaterialAnalysisContracts.ProductView::analysisLineId,value->value));
        Map<String,MaterialView> byNode=view.flatMaterials().stream().collect(Collectors.toMap(row->row.analysisLineId()+"|"+row.nodeKey(),value->value));
        Set<String> dimensions=new HashSet<>();Set<UUID> selected=new HashSet<>();
        for(GroupPreview group:groups) {
            // Different output dimensions cannot consume each other's newly created public output.
            if(!dimensions.add(group.goodsId()+"|"+group.colorId()+"|"+group.unitId()))return false;
            for(UUID original:inputs.get(group.clientGroupKey()).materialLineIds()) {
                MaterialView row=rows.get(original);if(row==null)return false;
                var owner=products.get(row.analysisLineId());
                if(owner!=null&&"AGGREGATE_MAKE".equals(owner.sourceType()))return false;
                if(row.makePublicSupplyRefs()!=null&&row.makePublicSupplyRefs().stream().anyMatch(candidate->candidate.adoptable()&&candidate.availableQty().signum()>0))return false;
                if(row.sharedFutureSupplyRefs()!=null&&row.sharedFutureSupplyRefs().stream().anyMatch(candidate->candidate.availableToClaimQty().signum()>0))return false;
                selected.add(original);
            }
            for(SourcePreview source:group.sources()) {
                MaterialView row=rows.get(source.materialLineId());if(row==null)return false;
                var anchor=products.get(row.planAnchorAnalysisLineId());
                if(anchor!=null&&!"AGGREGATE_MAKE".equals(anchor.sourceType()))return false;
                if(decimal(row.priorityMakeSupplementQty()).signum()>0||decimal(row.borrowedInQty()).signum()>0||decimal(row.borrowedOutQty()).signum()>0)return false;
                if(row.makePublicSupplyRefs()!=null&&row.makePublicSupplyRefs().stream().anyMatch(candidate->candidate.adoptable()&&candidate.availableQty().signum()>0))return false;
                if(row.sharedFutureSupplyRefs()!=null&&row.sharedFutureSupplyRefs().stream().anyMatch(candidate->candidate.availableToClaimQty().signum()>0))return false;
                selected.add(row.materialLineId());
            }
        }
        for(UUID id:selected) {
            MaterialView row=rows.get(id);Set<UUID> visited=new HashSet<>();visited.add(id);
            while(row!=null&&row.parentNodeKey()!=null) {
                row=byNode.get(row.analysisLineId()+"|"+row.parentNodeKey());
                if(row==null)break;
                if(!visited.add(row.materialLineId())||selected.contains(row.materialLineId()))return false;
            }
        }
        return true;
    }

    private static boolean hasOriginalBeneficiaryProof(GroupInput input,AnalysisView view) {
        Set<UUID> internal=view.products().stream().filter(product->"AGGREGATE_MAKE".equals(product.sourceType()))
                .map(MaterialAnalysisContracts.ProductView::analysisLineId).collect(Collectors.toSet());
        return view.flatMaterials().stream().filter(row->input.materialLineIds().contains(row.materialLineId()))
                .noneMatch(row->internal.contains(row.analysisLineId()));
    }

    private static Map<UUID,Map<UUID,BigDecimal>> originalPrivateFlow(GroupInput input,GroupPreview group,AnalysisView view) {
        if(input.sourceRequestedQtyByMaterialLineId().isEmpty())return null;
        Map<UUID,MaterialView> rows=view.flatMaterials().stream().collect(Collectors.toMap(MaterialView::materialLineId,row->row));
        Map<UUID,MaterialAnalysisContracts.ProductView> products=view.products().stream().collect(Collectors.toMap(MaterialAnalysisContracts.ProductView::analysisLineId,row->row));
        Map<UUID,BigDecimal> originals=new LinkedHashMap<>();
        input.sourceRequestedQtyByMaterialLineId().forEach((id,qty)-> {
            MaterialView row=rows.get(id);
            BigDecimal pending=(row.aggregatePreparation()==null?row.planningUncoveredQty():row.aggregatePreparation().planningUncoveredQty()).max(decimal(row.priorityMakeSupplementQty()));
            var anchor=products.get(row.planAnchorAnalysisLineId());
            if(anchor!=null&&!"AGGREGATE_MAKE".equals(anchor.sourceType()))pending=pending.max(anchor.remainingQty());
            originals.put(id,qty.min(pending));
        });
        Map<UUID,BigDecimal> targets=group.sources().stream().collect(Collectors.toMap(SourcePreview::materialLineId,SourcePreview::allocatedQty));
        Map<UUID,List<UUID>> proof=group.sources().stream().collect(Collectors.toMap(SourcePreview::materialLineId,SourcePreview::originalMaterialLineIds));
        Map<UUID,Map<UUID,BigDecimal>> result=new LinkedHashMap<>();
        AggregateOriginalTargetAllocator.allocate(originals,targets,proof,true).byTarget().forEach((id,shares)->result.put(id,new LinkedHashMap<>(shares)));
        return result;
    }
    private static Map<UUID,BigDecimal> originalFlowTotals(GroupInput input,Map<UUID,Map<UUID,BigDecimal>> flow) {
        Map<UUID,BigDecimal> result=new LinkedHashMap<>();input.materialLineIds().forEach(id->result.put(id,BigDecimal.ZERO));
        flow.values().forEach(shares->shares.forEach((id,qty)->result.merge(id,qty,BigDecimal::add)));
        return result;
    }
    static List<SourceAdoptionIntent> sourceAdoptionIntents(GroupInput original,GroupPreview group,
            List<AdoptedClaim> claims,AnalysisView reviewed) {
        if(claims.isEmpty()||original.sourceRequestedQtyByMaterialLineId().isEmpty())return List.of();
        Map<UUID,MaterialView> rows=reviewed.flatMaterials().stream().collect(Collectors.toMap(MaterialView::materialLineId,value->value));
        Map<UUID,BigDecimal> capacities=new LinkedHashMap<>();
        original.sourceRequestedQtyByMaterialLineId().forEach((id,qty)-> {
            MaterialView row=rows.get(id);
            BigDecimal pending=row==null?BigDecimal.ZERO:row.aggregatePreparation()==null?row.planningUncoveredQty():row.aggregatePreparation().planningUncoveredQty();
            capacities.put(id,qty.min(pending));
        });
        Map<UUID,List<UUID>> origins=group.sources().stream().collect(Collectors.toMap(SourcePreview::materialLineId,SourcePreview::originalMaterialLineIds));
        Map<UUID,BigDecimal> targets=new LinkedHashMap<>();claims.forEach(claim->targets.merge(claim.targetMaterialLineId(),claim.qty(),BigDecimal::add));
        Map<UUID,Map<UUID,BigDecimal>> matched=new LinkedHashMap<>();
        AggregateOriginalTargetAllocator.allocate(capacities,targets,targets.keySet().stream()
                        .collect(Collectors.toMap(id->id,id->origins.getOrDefault(id,List.of()))),true).byTarget()
                .forEach((target,shares)->matched.put(target,new LinkedHashMap<>(shares)));
        List<SourceAdoptionIntent> result=new ArrayList<>();
        for(AdoptedClaim claim:claims) {
            Map<UUID,BigDecimal> targetShares=matched.get(claim.targetMaterialLineId());
            List<AggregateQuantityAllocator.SourceCapacity> eligible=targetShares.entrySet().stream()
                    .map(entry->new AggregateQuantityAllocator.SourceCapacity(entry.getKey(),0,null,entry.getValue())).toList();
            var allocation=AggregateQuantityAllocator.allocate(claim.qty(),eligible,false);
            for(var share:allocation.allocations())if(share.qty().signum()>0) {
                targetShares.compute(share.sourceId(),(id,qty)->qty.subtract(share.qty()));
                result.add(new SourceAdoptionIntent(share.sourceId(),claim.targetMaterialLineId(),claim.kind(),claim.claimId(),share.qty()));
            }
        }
        return List.copyOf(result);
    }

    private static GroupInput issuedIntent(GroupInput original,BigDecimal issuedQty,List<SourceAdoptionIntent> adoptionIntents) {
        if(original.qty().compareTo(issuedQty)==0||original.sourceRequestedQtyByMaterialLineId().isEmpty())return original;
        Map<UUID,BigDecimal> actual=new LinkedHashMap<>(original.sourceRequestedQtyByMaterialLineId());
        for(SourceAdoptionIntent intent:adoptionIntents)actual.compute(intent.originalMaterialLineId(),(id,qty)->qty.subtract(intent.qty()));
        if(actual.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add).compareTo(issuedQty)!=0)
            throw conflict("采用份额与原行下单意图已变化，请重新核对");
        return new GroupInput(original.clientGroupKey(),original.materialLineIds(),original.route(),issuedQty,original.allowPublicExtra(),
                original.departmentId(),original.workerId(),original.teamDepartmentId(),original.billDate(),original.deliveryDate(),original.productNo(),
                original.allowedOverproductionRate(),original.safetyQty(),actual);
    }

    /**
     * A unified component entry must still grow an eligible pre-aggregate document in place.
     * [requestedRate] 是人在下单请求里填的比例；空表示按货品默认，不能拿预览已填好的默认值冒充人确认(ADR-129 §2.10)。
     */
    private BatchResult issueExistingSingleSource(UUID analysisId,AnalysisView current,GroupPreview group,
            SubmitRequest request,boolean manufacturing,BigDecimal requestedRate) {
        if(group.sources().size()!=1||group.safetyQty().signum()>0)return null;
        UUID id=group.sources().getFirst().materialLineId();
        MaterialView row=current.flatMaterials().stream().filter(value->value.materialLineId().equals(id)).findFirst().orElseThrow();
        Map<UUID,MaterialAnalysisContracts.SupplyActionView> actions=current.supplyActions().stream()
                .collect(Collectors.toMap(MaterialAnalysisContracts.SupplyActionView::actionId,value->value));
        if(row.downstreamReferences().stream().anyMatch(ref->actions.containsKey(ref.actionId())
                && "AGGREGATE_SUPPLY".equals(actions.get(ref.actionId()).operationType())))return null;
        var anchor=current.products().stream().filter(value->value.analysisLineId().equals(row.planAnchorAnalysisLineId()))
                .findFirst().orElse(null);
        String key=stepKey(request.idempotencyKey(),group.clientGroupKey(),"EXISTING-SOURCE");
        if(manufacturing) {
            if(anchor==null||"AGGREGATE_MAKE".equals(anchor.sourceType()))return null;
            var line=new MaterialAnalysisContracts.IssueWorkshopPlansRequest.IssuePlanLine(id,null,group.requestedQty(),
                    group.billDate(),group.deliveryDate(),group.departmentId(),null,group.workerId(),group.teamDepartmentId(),group.productNo(),
                    anchor.remainingQty().signum()==0&&group.publicExtraQty().signum()>0,requestedRate);
            var result=commands.issueWorkshopPlans(analysisId,new MaterialAnalysisContracts.IssueWorkshopPlansRequest(
                    current.version(),current.fingerprint(),key,request.warehouseId(),group.billDate(),group.deliveryDate(),request.approveNow(),List.of(line),
                    request.skipClaims()?Boolean.TRUE:null));
            var plan=result.plans().getFirst();
            return new BatchResult(null,group.clientGroupKey(),group.route(),"PRODUCTION_PLAN",plan.planId(),plan.planNo(),plan.planId(),
                    anchor.analysisLineId(),group.requestedQty(),group.publicExtraQty(),group.sources(),plan);
        }
        boolean legacy=row.downstreamReferences().stream().anyMatch(ref->Objects.equals(group.route(),ref.route())
                && !"CANCELLED".equals(ref.status())&&actions.containsKey(ref.actionId())
                && "SUPPLY".equals(actions.get(ref.actionId()).operationType()));
        if(!legacy)return null;
        var result=commands.notifySupply(analysisId,new MaterialAnalysisContracts.NotifyRequest(current.version(),current.fingerprint(),key,
                group.route(),List.of(id),null,List.of(new MaterialAnalysisContracts.SupplyQuantityInput(null,id,group.requestedQty(),BigDecimal.ZERO)),
                request.skipClaims()?Boolean.TRUE:null));
        MaterialView updated=result.flatMaterials().stream().filter(value->value.materialLineId().equals(id)).findFirst().orElseThrow();
        var ref=updated.downstreamReferences().stream().filter(value->Objects.equals(group.route(),value.route())&&!"CANCELLED".equals(value.status()))
                .max(Comparator.comparingInt(value->result.supplyActions().stream().filter(action->action.actionId().equals(value.actionId()))
                        .mapToInt(MaterialAnalysisContracts.SupplyActionView::generation).max().orElse(0))).orElseThrow();
        return new BatchResult(null,group.clientGroupKey(),group.route(),ref.documentType(),ref.documentId(),ref.documentNo(),null,null,
                group.requestedQty(),group.publicExtraQty(),group.sources());
    }

    private Batch createBatch(UUID analysisId,GroupPreview group,GroupInput original,SubmitRequest request,String hash,boolean manufacturing,AnalysisView current,Map<UUID,BigDecimal> privateProof,Map<UUID,Map<UUID,BigDecimal>> privateFlow) {
        UUID id=UUID.randomUUID(),action=UUID.randomUUID(),anchor=manufacturing?UUID.randomUUID():null;
        String actionKey=CanonicalFingerprint.sha256(List.of("AGGREGATE-ACTION",group.compatibilityKey()));
        int generation=((Number)em.createNativeQuery("SELECT COALESCE(MAX(generation),0)+1 FROM preplan_supply_actions WHERE analysis_id=:analysis AND action_group_key=:key AND route=:route")
                .setParameter("analysis",analysisId).setParameter("key",actionKey).setParameter("route",group.route()).getSingleResult()).intValue();
        var material=current.flatMaterials().stream().filter(row->row.materialLineId().equals(group.sources().getFirst().materialLineId())).findFirst().orElseThrow();
        ObjectNode config=mapper.valueToTree(original);config.set("originalMaterialLineIds",mapper.valueToTree(original.materialLineIds()));
        if(privateProof!=null){config.set("sourcePrivateQtyByMaterialLineId",mapper.valueToTree(privateProof));
            config.set("sourcePrivateQtyByTargetMaterialLineId",mapper.valueToTree(privateFlow));}
        config.set("materialLineIds",mapper.valueToTree(group.sources().stream().map(SourcePreview::materialLineId).toList()));config.put("manufacturing",manufacturing);
        em.createNativeQuery("""
                INSERT INTO preplan_aggregate_batches(id,analysis_id,action_id,anchor_analysis_item_id,route,compatibility_key,configuration_snapshot,created_by)
                VALUES(:id,:analysis,:action,:anchor,:route,:compatibility,CAST(:configuration AS jsonb),:actor)
                """).setParameter("id",id).setParameter("analysis",analysisId).setParameter("action",action).setParameter("anchor",anchor).setParameter("route",group.route())
                .setParameter("compatibility",group.compatibilityKey()).setParameter("configuration",config.toString()).setParameter("actor",user.requireId()).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO preplan_supply_actions(id,analysis_id,warehouse_id,goods_id,color_id,unit_id,need_date,route,requested_qty,
                    public_surplus_qty,safety_replenishment_qty,safety_stock_snapshot_qty,public_available_snapshot_qty,open_safety_supply_snapshot_qty,
                    status,idempotency_key,action_group_key,request_business_key,generation,request_hash,created_by)
                VALUES(:id,:analysis,:warehouse,:goods,:color,:unit,:date,:route,:qty,:public,:safety,:safetyStock,:available,:openSafety,
                    'OPEN',:key,:group,:business,:generation,:hash,:actor)
                """).setParameter("id",action).setParameter("analysis",analysisId).setParameter("warehouse",request.warehouseId())
                .setParameter("goods",group.goodsId()).setParameter("color",group.colorId()).setParameter("unit",group.unitId()).setParameter("date",group.deliveryDate())
                .setParameter("route",group.route()).setParameter("qty",sum(group.sources())).setParameter("public",group.publicExtraQty()).setParameter("safety",group.safetyQty())
                .setParameter("safetyStock",material.safetyStockQty()).setParameter("available",material.mainWarehousePublicAvailableQty()).setParameter("openSafety",material.mainWarehouseOpenSafetySupplyQty())
                .setParameter("key",stepKey(request.idempotencyKey(),group.clientGroupKey(),"ACTION")).setParameter("group",actionKey)
                .setParameter("business",CanonicalFingerprint.sha256(List.of("AGGREGATE-BATCH",id.toString()))).setParameter("generation",generation).setParameter("hash",hash).setParameter("actor",user.requireId()).executeUpdate();
        Batch batch=new Batch(id,analysisId,action,anchor,null,group.route(),0);
        allocations(batch,group.sources(),false);
        if(manufacturing) {
            em.createNativeQuery("""
                    INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,color_id,unit_id,source_ref,source_reason,
                        requested_qty,delivery_date,line_priority,created_by,updated_by)
                    VALUES(:id,:analysis,'AGGREGATE_MAKE',:goods,:color,:unit,:ref,'同料汇总共享制造批次',:qty,:date,:priority,:actor,:actor)
                    """).setParameter("id",anchor).setParameter("analysis",analysisId).setParameter("goods",group.goodsId()).setParameter("color",group.colorId()).setParameter("unit",group.unitId())
                    .setParameter("ref","共享制造 "+BusinessTime.today()+" "+id.toString().substring(0,8)).setParameter("qty",sum(group.sources())).setParameter("date",group.deliveryDate())
                    .setParameter("priority",group.sources().stream().mapToInt(SourcePreview::allocationPriority).min().orElse(1)).setParameter("actor",user.requireId()).executeUpdate();
            markExternal(batch,"PREPLAN_MAKE_TASK",anchor,"共享制造 "+id.toString().substring(0,8),anchor,null,null);
        }
        event(batch,"CREATE",group,original,request.idempotencyKey(),hash,privateProof,privateFlow);
        return new Batch(id,analysisId,action,anchor,null,group.route(),1);
    }

    private Batch findReusable(UUID analysisId,GroupPreview group,boolean manufacturing,boolean approveNow) {
        var match=new AggregateMaterialBatchLookup(em).find(analysisId,group,manufacturing,approveNow,true);
        return match==null?null:new Batch(match.batchId(),analysisId,match.actionId(),match.anchorId(),match.planId(),match.route(),match.version());
    }
    private void appendBatch(Batch batch,GroupPreview group,GroupInput original,SubmitRequest request,String hash,Map<UUID,BigDecimal> privateProof,Map<UUID,Map<UUID,BigDecimal>> privateFlow) {
        event(batch,"APPEND",group,original,request.idempotencyKey(),hash,privateProof,privateFlow);
        em.createNativeQuery("UPDATE preplan_supply_actions SET requested_qty=requested_qty+:qty,public_surplus_qty=public_surplus_qty+:public,public_surplus_external_item_id=CASE WHEN :public>0 THEN COALESCE(public_surplus_external_item_id,CAST(:publicItem AS uuid)) ELSE public_surplus_external_item_id END,updated_at=now() WHERE id=:id")
                .setParameter("qty",sum(group.sources())).setParameter("public",group.publicExtraQty()).setParameter("publicItem",batch.anchor()==null?externalItem(batch):null).setParameter("id",batch.action()).executeUpdate();
        allocations(batch,group.sources(),true);
        if(batch.anchor()!=null)em.createNativeQuery("UPDATE production_material_analysis_items SET requested_qty=requested_qty+:qty,updated_at=now(),updated_by=:actor WHERE id=:id")
                .setParameter("qty",sum(group.sources())).setParameter("actor",user.requireId()).setParameter("id",batch.anchor()).executeUpdate();
    }
    private void allocations(Batch batch,List<SourcePreview> sources,boolean append) {
        var entries=mapper.createArrayNode();for(SourcePreview source:sources)if(source.allocatedQty().signum()>0){var row=entries.addObject();row.put("material_id",source.materialLineId().toString());row.put("qty",source.allocatedQty());}
        if(entries.isEmpty())return;
        String payload=entries.toString();
        if(append)em.createNativeQuery("""
                UPDATE preplan_supply_action_allocations allocation SET allocated_qty=allocation.allocated_qty+input.qty
                FROM jsonb_to_recordset(CAST(:rows AS jsonb)) AS input(material_id uuid,qty numeric)
                WHERE allocation.action_id=:action AND allocation.analysis_material_id=input.material_id
                """).setParameter("rows",payload).setParameter("action",batch.action()).executeUpdate();
        em.createNativeQuery("""
                    INSERT INTO preplan_supply_action_allocations(analysis_id,action_id,analysis_material_id,allocated_qty,external_item_id,created_by)
                    SELECT :analysis,:action,input.material_id,input.qty,CAST(:external AS uuid),:actor
                    FROM jsonb_to_recordset(CAST(:rows AS jsonb)) AS input(material_id uuid,qty numeric)
                    WHERE NOT EXISTS(SELECT 1 FROM preplan_supply_action_allocations existing WHERE existing.action_id=:action AND existing.analysis_material_id=input.material_id)
                    ORDER BY input.material_id
                    """).setParameter("analysis",batch.analysis()).setParameter("action",batch.action()).setParameter("rows",payload)
                    .setParameter("external",append?externalItem(batch):null).setParameter("actor",user.requireId()).executeUpdate();
    }
    private UUID externalItem(Batch batch){return batch.anchor()!=null?batch.anchor():(UUID)em.createNativeQuery("SELECT COALESCE((SELECT external_item_id FROM preplan_supply_action_allocations WHERE action_id=:id AND external_item_id IS NOT NULL ORDER BY id LIMIT 1),public_surplus_external_item_id) FROM preplan_supply_actions WHERE id=:id").setParameter("id",batch.action()).getSingleResult();}
    private void event(Batch batch,String kind,GroupPreview group,GroupInput original,String key,String hash,Map<UUID,BigDecimal> privateProof,Map<UUID,Map<UUID,BigDecimal>> privateFlow) {
        ObjectNode deltas=mapper.createObjectNode();group.sources().stream().filter(source->source.allocatedQty().signum()>0).forEach(source->deltas.put(source.materialLineId().toString(),source.allocatedQty()));
        ObjectNode intent=mapper.valueToTree(group);if(privateProof!=null){intent.set("sourcePrivateQtyByMaterialLineId",mapper.valueToTree(privateProof));
            intent.set("sourcePrivateQtyByTargetMaterialLineId",mapper.valueToTree(privateFlow));}intent.set("materialLineIds",mapper.valueToTree(group.sources().stream().map(SourcePreview::materialLineId).toList()));
        intent.set("originalMaterialLineIds",mapper.valueToTree(original.materialLineIds()));
        intent.set("sourceRequestedQtyByMaterialLineId",mapper.valueToTree(original.sourceRequestedQtyByMaterialLineId()));
        em.createNativeQuery("""
                INSERT INTO preplan_aggregate_batch_events(batch_id,event_type,allocation_deltas,intent_snapshot,public_delta,safety_delta,expected_version,resulting_version,idempotency_key,request_hash,created_by)
                VALUES(:batch,:type,CAST(:allocations AS jsonb),CAST(:intent AS jsonb),:public,:safety,:version,:result,:key,:hash,:actor)
                """).setParameter("batch",batch.id()).setParameter("type",kind).setParameter("allocations",deltas.toString()).setParameter("public",group.publicExtraQty()).setParameter("safety",group.safetyQty())
                .setParameter("intent",intent.toString()).setParameter("version",batch.version()).setParameter("result",batch.version()+1).setParameter("key",key).setParameter("hash",hash).setParameter("actor",user.requireId()).executeUpdate();
        em.createNativeQuery("UPDATE preplan_aggregate_batches SET row_version=row_version+1 WHERE id=:id AND row_version=:version").setParameter("id",batch.id()).setParameter("version",batch.version()).executeUpdate();
    }
    private External createExternal(Batch batch,GroupPreview group,UUID warehouse) {
        UUID publicSlice=UUID.randomUUID(),safetySlice=UUID.randomUUID();BigDecimal regular=group.requestedQty();
        // 来源标签（V719/V720）：汇总批次锚定单一分析，直接用其 WL 编号——采购/委外
        // 「计划号/来源计划」列与经典通道同值可排序；无编号的夹具行回退旧日期标签。
        Object noRow=em.createNativeQuery("SELECT analysis_no FROM production_material_analyses WHERE id=:id")
                .setParameter("id",batch.analysis()).getSingleResult();
        String source=noRow==null||noRow.toString().isBlank()
                ?"物料分析汇总 "+BusinessTime.today():noRow.toString();
        UUID item=null,safetyItem=null;External result;
        if("BUY".equals(group.route())) {
            List<ProductionPurchaseRequestFacade.DraftLine> lines=new ArrayList<>();
            if(regular.signum()>0)lines.add(new ProductionPurchaseRequestFacade.DraftLine(batch.action(),group.goodsId(),group.colorId(),group.unitId(),regular,group.deliveryDate(),"同料多来源汇总备料"));
            if(group.safetyQty().signum()>0)lines.add(new ProductionPurchaseRequestFacade.DraftLine(safetySlice,group.goodsId(),group.colorId(),group.unitId(),group.safetyQty(),group.deliveryDate(),"公共安全库存补库"));
            var made=purchases.createProductionDraft(source,batch.analysis(),group.deliveryDate(),warehouse,lines,user.requireEmployeeId(),user.requireEmployeeId());
            for(var line:made.lines())if(line.demandId().equals(batch.action()))item=line.requestItemId();else if(line.demandId().equals(safetySlice))safetyItem=line.requestItemId();
            result=new External("PURCHASE_REQUEST",made.requestId(),made.billNo(),item);
        } else {
            var made=subcontract.createProductionDraft(source,batch.analysis(),group.deliveryDate(),warehouse,List.of(new ProductionSubcontractRequestPort.DraftLine(batch.action(),group.goodsId(),group.colorId(),group.unitId(),regular,group.deliveryDate(),"同料多来源汇总委外")),user.requireEmployeeId(),user.requireEmployeeId());
            item=made.lines().getFirst().applicationItemId();result=new External("SUBCONTRACT_APPLICATION",made.applicationId(),made.billNo(),item);
        }
        markExternal(batch,result.type(),result.id(),result.no(),sum(group.sources()).signum()>0?item:null,safetyItem,group.publicExtraQty().signum()>0?item:null);return result;
    }
    private External growExternal(Batch batch,GroupPreview group) {
        Object[] row=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT external_document_type,external_document_id,external_document_no FROM preplan_supply_actions WHERE id=:id").setParameter("id",batch.action())).getFirst();UUID item=externalItem(batch);
        if("BUY".equals(group.route()))purchases.increaseProductionDraftLine((UUID)row[1],item,group.requestedQty());else subcontract.increaseProductionDraftLine((UUID)row[1],item,group.requestedQty());
        if(group.publicExtraQty().signum()>0)em.createNativeQuery("UPDATE preplan_supply_actions SET public_surplus_external_item_id=COALESCE(public_surplus_external_item_id,:item) WHERE id=:id").setParameter("item",item).setParameter("id",batch.action()).executeUpdate();
        return new External((String)row[0],(UUID)row[1],(String)row[2],item);
    }
    private void markExternal(Batch batch,String type,UUID document,String no,UUID item,UUID safety,UUID surplus) {
        em.createNativeQuery("UPDATE preplan_supply_actions SET status='CREATED',external_document_type=:type,external_document_id=:doc,external_document_no=:no,safety_external_item_id=:safety,public_surplus_external_item_id=:public WHERE id=:id")
                .setParameter("type",type).setParameter("doc",document).setParameter("no",no).setParameter("safety",safety).setParameter("public",surplus).setParameter("id",batch.action()).executeUpdate();
        if(item!=null)em.createNativeQuery("UPDATE preplan_supply_action_allocations SET external_item_id=:item WHERE action_id=:id").setParameter("item",item).setParameter("id",batch.action()).executeUpdate();
    }

    private Map<UUID,CapacitySnapshot> captureSourceCapacities(GroupPreview group,AnalysisView view) {
        return captureSourceCapacities(List.of(group),view);
    }
    /** One pre-write read for disjoint cohort subtrees; no supply snapshot crosses a phase. */
    private Map<UUID,CapacitySnapshot> captureSourceCapacities(List<GroupPreview> groups,AnalysisView view) {
        Map<UUID,MaterialView> materialById=view.flatMaterials().stream().collect(Collectors.toMap(MaterialView::materialLineId,row->row));
        Map<UUID,MaterialAnalysisContracts.ProductView> products=view.products().stream().collect(Collectors.toMap(MaterialAnalysisContracts.ProductView::analysisLineId,row->row));
        List<SourcePreview> selectedSources=groups.stream().flatMap(group->group.sources().stream()).toList();
        List<UUID> parents=selectedSources.stream().filter(source->source.allocatedQty().signum()>0).map(SourcePreview::materialLineId).toList();if(parents.isEmpty())return Map.of();
        if(new HashSet<>(parents).size()!=parents.size())throw conflict("同批制造组包含重复父件责任");
        Map<UUID,CapacitySnapshot> result=new HashMap<>();
        Map<UUID,BigDecimal[]> outputs=new HashMap<>();
        for(SourcePreview selected:selectedSources) {
            MaterialView parent=materialById.get(selected.materialLineId());
            var anchor=parent==null?null:products.get(parent.planAnchorAnalysisLineId());
            if(parent!=null&&(anchor==null||"AGGREGATE_MAKE".equals(anchor.sourceType()))) {
                BigDecimal before=parent.planningUncoveredQty().max(decimal(parent.priorityMakeSupplementQty()));
                outputs.put(parent.materialLineId(),new BigDecimal[]{before,before.subtract(selected.allocatedQty()).max(BigDecimal.ZERO)});
            }
        }
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery(SOURCE_DESCENDANTS_SQL+"""
                SELECT child.id,child.required_qty,GREATEST(child.required_qty+COALESCE((
                    SELECT SUM(fn_preplan_aggregate_alias_qty(alias.id)) FROM preplan_aggregate_material_aliases alias WHERE alias.source_material_id=child.id),0),
                    COALESCE((SELECT SUM(fn_preplan_allocation_admitted_qty(allocation.id)) FROM preplan_supply_action_allocations allocation
                        JOIN preplan_supply_actions action ON action.id=allocation.action_id AND action.status<>'CANCELLED'
                        WHERE allocation.analysis_material_id=child.id),0),
                    COALESCE((SELECT SUM(link.submitted_qty) FROM production_material_analysis_items anchor
                        JOIN production_material_analysis_plan_links link ON link.analysis_item_id=anchor.id AND link.allocation_status IN('SUBMITTED','APPROVED')
                        WHERE anchor.parent_analysis_material_id=child.id AND NOT anchor.is_deleted),0)),
                    path.parent_id,child.bom_qty,child.consumption_basis,child.basis_output_qty,child.allow_partial_package,path.invalid,
                    CASE WHEN EXISTS(SELECT 1 FROM preplan_supply_action_allocations WHERE analysis_material_id=child.id)
                        OR EXISTS(SELECT 1 FROM production_material_analysis_items item WHERE item.parent_analysis_material_id=child.id AND NOT item.is_deleted)
                        OR EXISTS(SELECT 1 FROM preplan_make_public_claims WHERE target_material_id=child.id)
                        OR EXISTS(SELECT 1 FROM preplan_stock_entitlement_events WHERE beneficiary_analysis_material_id=child.id)
                        OR EXISTS(SELECT 1 FROM preplan_aggregate_material_aliases WHERE aggregate_material_id=child.id)
                    THEN fn_preplan_aggregate_material_pending_qty(child.id)+fn_preplan_aggregate_target_committed_qty(child.id)
                    ELSE 0 END
                FROM descendants path JOIN production_material_analysis_materials child ON child.id=path.id
                WHERE NOT path.frozen ORDER BY cardinality(path.path),path.id
                """).setParameter("parents",parents))) {
            if(Boolean.TRUE.equals(row[8]))throw conflict("共享BOM路径存在循环或层级超过256");
            BigDecimal parentReleased=BigDecimal.ZERO,parentRetained=BigDecimal.ZERO;
            BigDecimal[] parentOutput=outputs.get((UUID)row[3]);
            if(parentOutput!=null) {
                BigDecimal before=childQuantity(parentOutput[0],decimal(row[4]),(String)row[5],decimal(row[6]),Boolean.TRUE.equals(row[7]));
                parentRetained=childQuantity(parentOutput[1],decimal(row[4]),(String)row[5],decimal(row[6]),Boolean.TRUE.equals(row[7]));
                parentReleased=before.subtract(parentRetained).max(BigDecimal.ZERO);
                outputs.put((UUID)row[0],new BigDecimal[]{before,parentRetained});
            }
            BigDecimal owned=decimal(row[9]);
            result.put((UUID)row[0],new CapacitySnapshot(decimal(row[1]),decimal(row[2]).max(owned),parentReleased,parentRetained,owned));
        }
        return Map.copyOf(result);
    }
    private record Original(UUID material,UUID alias,BigDecimal required,BigDecimal delegated,BigDecimal sourceCap,BigDecimal historicCap){}
    private record AliasReadRequest(Batch batch,GroupPreview group){}
    private record AliasReadSnapshot(BigDecimal existingOutput,List<Object[]> children,Map<UUID,Map<String,List<Original>>> originals){}

    private void installAliases(Batch batch,GroupPreview group,Map<UUID,CapacitySnapshot> snapshots,String commandKey) {
        installAliases(batch,group,snapshots,commandKey,readAliasSnapshots(List.of(new AliasReadRequest(batch,group))).get(batch.id()));
    }

    /** Reads one post-refresh phase. Independent cohorts have disjoint source subtrees
     * and target anchors, so another batch's alias write cannot change these budgets. */
    private Map<UUID,AliasReadSnapshot> readAliasSnapshots(List<AliasReadRequest> requests) {
        if(requests.isEmpty())return Map.of();
        List<UUID> batchIds=requests.stream().map(request->request.batch().id()).toList();
        if(new HashSet<>(batchIds).size()!=batchIds.size())throw conflict("同批别名快照包含重复制造批次");
        List<UUID> planIds=requests.stream().map(request->request.batch().plan()).filter(Objects::nonNull).distinct().toList();
        Map<UUID,BigDecimal> existingOutputs=new HashMap<>();
        if(!planIds.isEmpty())for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT plan_id,COUNT(*),MIN(qty) FROM production_plan_items
                WHERE plan_id IN(:plans) AND NOT is_deleted GROUP BY plan_id
                """).setParameter("plans",planIds))) {
            if(((Number)row[1]).intValue()!=1)throw conflict("共享生产计划必须且只能包含一条有效明细");
            existingOutputs.put((UUID)row[0],decimal(row[2]));
        }
        if(existingOutputs.size()!=planIds.size())throw conflict("共享生产计划的有效明细已失效");
        Map<UUID,List<Object[]>> children=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery(EXACT_BOM_DESCENDANTS_SQL+"""
                SELECT child.id,array_to_string(path.path,'/'),child.bom_qty,child.consumption_basis,child.basis_output_qty,child.allow_partial_package,
                    COALESCE((SELECT SUM(fn_preplan_aggregate_alias_qty(alias.id)) FROM preplan_aggregate_material_aliases alias WHERE alias.aggregate_material_id=child.id),0),
                    fn_preplan_aggregate_material_capacity(child.id),child.parent_node_key,child.node_key,path.invalid,path.batch_id
                FROM target_paths path JOIN production_material_analysis_materials child ON child.id=path.id
                ORDER BY path.batch_id,cardinality(path.path),child.id
                """).setParameter("batches",batchIds)))
            children.computeIfAbsent((UUID)row[11],ignored->new ArrayList<>()).add(row);
        var scopes=mapper.createArrayNode();Set<UUID> parents=new LinkedHashSet<>();
        for(AliasReadRequest request:requests)for(SourcePreview source:request.group().sources())if(source.allocatedQty().signum()>0) {
            var scope=scopes.addObject();scope.put("batch_id",request.batch().id().toString());scope.put("parent_id",source.materialLineId().toString());
            if(!parents.add(source.materialLineId()))throw conflict("同批别名来源父件责任重叠");
        }
        Map<UUID,Map<UUID,Map<String,List<Original>>>> originalsByBatch=new HashMap<>();
        if(!parents.isEmpty())for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery(SOURCE_DESCENDANTS_SQL+"""
                , requested_parents AS (
                    SELECT input.batch_id,input.parent_id FROM jsonb_to_recordset(CAST(:scopes AS jsonb)) input(batch_id uuid,parent_id uuid)
                ), bindings AS (
                    SELECT requested.batch_id,requested.parent_id,batch.action_id,allocation.id allocation_id
                    FROM requested_parents requested LEFT JOIN preplan_aggregate_batches batch ON batch.id=requested.batch_id
                    LEFT JOIN preplan_supply_action_allocations allocation ON allocation.action_id=batch.action_id
                      AND allocation.analysis_material_id=requested.parent_id AND allocation.external_item_id=batch.anchor_analysis_item_id
                )
                SELECT path.source_parent_id,array_to_string(path.path,'/'),child.id,alias.id,child.required_qty,
                    COALESCE((SELECT SUM(fn_preplan_aggregate_alias_qty(other.id)) FROM preplan_aggregate_material_aliases other WHERE other.source_material_id=child.id),0),
                    CASE WHEN alias.id IS NULL THEN 0 ELSE fn_preplan_aggregate_alias_source_capacity(alias.id) END,
                    COALESCE((SELECT MAX(fn_preplan_aggregate_alias_source_capacity(other.id)) FROM preplan_aggregate_material_aliases other WHERE other.source_material_id=child.id),0),
                    binding.batch_id,FALSE invalid_binding
                FROM descendants path JOIN production_material_analysis_materials child ON child.id=path.id
                JOIN bindings binding ON binding.parent_id=path.source_parent_id AND binding.allocation_id IS NOT NULL
                LEFT JOIN preplan_aggregate_material_aliases alias ON alias.batch_id=binding.batch_id AND alias.source_material_id=child.id
                WHERE NOT path.frozen AND NOT path.invalid
                UNION ALL SELECT NULL::uuid,NULL::text,NULL::uuid,NULL::uuid,NULL::numeric,NULL::numeric,NULL::numeric,NULL::numeric,binding.batch_id,TRUE
                FROM bindings binding WHERE binding.allocation_id IS NULL
                """).setParameter("parents",parents).setParameter("scopes",scopes.toString()))) {
            if(Boolean.TRUE.equals(row[9]))throw conflict("共享别名缺少本批真实父件分配");
            originalsByBatch.computeIfAbsent((UUID)row[8],ignored->new HashMap<>()).computeIfAbsent((UUID)row[0],ignored->new HashMap<>())
                    .computeIfAbsent((String)row[1],ignored->new ArrayList<>())
                    .add(new Original((UUID)row[2],(UUID)row[3],decimal(row[4]),decimal(row[5]),decimal(row[6]),decimal(row[7])));
        }
        Map<UUID,AliasReadSnapshot> result=new LinkedHashMap<>();
        for(AliasReadRequest request:requests) {
            Map<UUID,Map<String,List<Original>>> originalRows=new HashMap<>();
            originalsByBatch.getOrDefault(request.batch().id(),Map.of()).forEach((parent,paths)->{
                Map<String,List<Original>> copies=new HashMap<>();paths.forEach((path,rows)->copies.put(path,List.copyOf(rows)));
                originalRows.put(parent,Map.copyOf(copies));
            });
            result.put(request.batch().id(),new AliasReadSnapshot(existingOutputs.getOrDefault(request.batch().plan(),BigDecimal.ZERO),
                    List.copyOf(children.getOrDefault(request.batch().id(),List.of())),Map.copyOf(originalRows)));
        }
        return Map.copyOf(result);
    }

    private void installAliases(Batch batch,GroupPreview group,Map<UUID,CapacitySnapshot> snapshots,String commandKey,AliasReadSnapshot read) {
        if(read==null)throw conflict("共享别名缺少本阶段读取快照");
        BigDecimal output=group.requestedQty().add(read.existingOutput());
        List<Object[]> children=read.children();
        Map<UUID,Map<String,List<Original>>> originalsByParent=read.originals();
        Map<UUID,BigDecimal> increases=new LinkedHashMap<>(),sourceCaps=new LinkedHashMap<>(),canonicalCaps=new LinkedHashMap<>();
        record NewAlias(UUID parent,UUID source,UUID target,String path,BigDecimal qty,BigDecimal sourceCap,BigDecimal canonicalCap){}
        List<NewAlias> inserts=new ArrayList<>();
        Map<String,BigDecimal> targetOutputs=new HashMap<>();
        for(Object[] child:children) {
            if(Boolean.TRUE.equals(child[10]))throw conflict("共享BOM路径存在循环或层级超过256");
            UUID target=(UUID)child[0];String edge=(String)child[1];
            BigDecimal parentOutput=edge.indexOf('/')<0?output:targetOutputs.get((String)child[8]);
            if(parentOutput==null)throw conflict("共享BOM路径缺少真实父层");
            BigDecimal required=childQuantity(parentOutput,decimal(child[2]),(String)child[3],decimal(child[4]),Boolean.TRUE.equals(child[5]));
            targetOutputs.put((String)child[9],required);
            BigDecimal already=decimal(child[6]);
            BigDecimal previousCapacity=decimal(child[7]);
            if(previousCapacity.signum()>0&&required.compareTo(previousCapacity)>0)canonicalCaps.put(target,required.subtract(previousCapacity));
            BigDecimal capacity=required.subtract(already).max(BigDecimal.ZERO);
            record Candidate(SourcePreview parent,UUID material,UUID alias,BigDecimal available,BigDecimal oldSourceCap,BigDecimal retained,BigDecimal owned){}
            List<Candidate> candidates=new ArrayList<>();
            for(SourcePreview source:group.sources())if(source.allocatedQty().signum()>0) {
                List<Original> originals=originalsByParent.getOrDefault(source.materialLineId(),Map.of()).getOrDefault(edge,List.of());
                if(originals.size()>1)throw conflict("共享BOM路径存在歧义，请刷新结构");
                if(!originals.isEmpty()){Original original=originals.getFirst();CapacitySnapshot snapshot=snapshots.get(original.material());if(snapshot==null)continue;
                    BigDecimal released=snapshot.required().subtract(original.required()).max(BigDecimal.ZERO).max(snapshot.parentReleased());
                    BigDecimal retained=original.required().max(snapshot.parentRetained());
                    BigDecimal available=snapshot.capacity().subtract(original.delegated()).subtract(retained).max(BigDecimal.ZERO).min(released);
                    candidates.add(new Candidate(source,original.material(),original.alias(),available,original.sourceCap(),
                            retained.add(original.delegated()),snapshot.owned().max(original.historicCap())));}
            }
            BigDecimal available=candidates.stream().map(Candidate::available).reduce(BigDecimal.ZERO,BigDecimal::add);BigDecimal transfer=capacity.min(available);
            if(candidates.isEmpty())continue;
            var split=AggregateQuantityAllocator.allocate(transfer,candidates.stream().map(candidate->new AggregateQuantityAllocator.SourceCapacity(candidate.material(),candidate.parent().allocationPriority(),candidate.parent().needDate(),candidate.available())).toList(),false);
            Map<UUID,BigDecimal> amounts=split.allocations().stream().collect(Collectors.toMap(AggregateQuantityAllocator.Allocation::sourceId,AggregateQuantityAllocator.Allocation::qty));
            for(Candidate candidate:candidates) {BigDecimal amount=amounts.getOrDefault(candidate.material(),BigDecimal.ZERO);
                BigDecimal newSourceCapacity=candidate.retained().add(amount).max(candidate.owned());
                if(candidate.alias()!=null){if(amount.signum()>0)increases.put(candidate.alias(),amount);
                    BigDecimal old=candidate.oldSourceCap();
                    if(newSourceCapacity.compareTo(old)>0)sourceCaps.put(candidate.alias(),newSourceCapacity.subtract(old));continue;}
                // Released, unarranged demand is not private stock. Preserve actual
                // old supply and immutable earlier responsibility, not vanished pre-merge rounding.
                inserts.add(new NewAlias(candidate.parent().materialLineId(),candidate.material(),target,edge,amount,newSourceCapacity,required));
            }
        }
        if(!increases.isEmpty()||!sourceCaps.isEmpty()||!canonicalCaps.isEmpty())em.createNativeQuery("SELECT fn_complete_aggregate_alias_deltas(:batch,:key,CAST(:deltas AS jsonb),CAST(:source AS jsonb),CAST(:canonical AS jsonb))")
                .setParameter("batch",batch.id()).setParameter("key",commandKey).setParameter("deltas",mapper.valueToTree(increases).toString())
                .setParameter("source",mapper.valueToTree(sourceCaps).toString()).setParameter("canonical",mapper.valueToTree(canonicalCaps).toString()).getSingleResult();
        if(!inserts.isEmpty()){
        var insertRows=mapper.createArrayNode();for(NewAlias alias:inserts){var row=insertRows.addObject();row.put("parent_id",alias.parent().toString());row.put("source_id",alias.source().toString());row.put("target_id",alias.target().toString());row.put("edge_path",alias.path());row.put("qty",alias.qty());row.put("source_capacity",alias.sourceCap());row.put("canonical_capacity",alias.canonicalCap());}
        em.createNativeQuery("""
                INSERT INTO preplan_aggregate_material_aliases(batch_id,source_parent_material_id,source_material_id,aggregate_material_id,relative_bom_path,qty,source_capacity_qty,canonical_capacity_qty,capacity_version,created_by)
                SELECT batch.id,input.parent_id,input.source_id,input.target_id,string_to_array(input.edge_path,'/')::uuid[],input.qty,input.source_capacity,input.canonical_capacity,batch.row_version,:actor
                FROM preplan_aggregate_batches batch CROSS JOIN jsonb_to_recordset(CAST(:rows AS jsonb)) AS input(
                    parent_id uuid,source_id uuid,target_id uuid,edge_path text,qty numeric,source_capacity numeric,canonical_capacity numeric)
                WHERE batch.id=:batch ORDER BY input.parent_id,input.source_id
                """).setParameter("batch",batch.id()).setParameter("rows",insertRows.toString()).setParameter("actor",user.requireId()).executeUpdate();
        }
    }
    /** Descendant responsibility follows immutable BOM edges. An intermediate ordinary
     * plan keeps its own material responsibility; its descendants cannot be delegated
     * merely because an ancestor is combined into a different manufacturing batch. */
    private static final String SOURCE_DESCENDANTS_SQL="""
            WITH RECURSIVE descendants AS (
                SELECT parent.id source_parent_id,parent.id parent_id,child.id,child.analysis_item_id,child.node_key,
                    child.confirmed_route,ARRAY[child.bom_item_id] path,ARRAY[child.id] visited,FALSE invalid,FALSE frozen
                FROM production_material_analysis_materials parent JOIN production_material_analysis_materials child
                  ON child.analysis_item_id=parent.analysis_item_id AND child.active AND child.node_role='BOM_COMPONENT'
                  AND ((parent.node_role='ROOT_SUPPLY' AND child.depth=1) OR child.parent_node_key=parent.node_key)
                WHERE parent.id IN(:parents)
                UNION ALL
                SELECT parent.source_parent_id,parent.id,child.id,child.analysis_item_id,child.node_key,child.confirmed_route,
                    parent.path||child.bom_item_id,parent.visited||child.id,
                    child.id=ANY(parent.visited) OR cardinality(parent.path)>=256,
                    parent.frozen OR parent.confirmed_route IS DISTINCT FROM 'MAKE' OR EXISTS(
                        SELECT 1 FROM production_material_analysis_items anchor
                        JOIN production_material_analysis_plan_links link ON link.analysis_item_id=anchor.id
                          AND link.allocation_status IN('SUBMITTED','APPROVED')
                        JOIN production_plans plan ON plan.id=link.plan_id AND plan.status IN(0,1)
                          AND NOT plan.is_deleted AND NOT plan.is_canceled
                        WHERE anchor.parent_analysis_material_id=parent.id AND NOT anchor.is_deleted
                          AND anchor.source_type<>'AGGREGATE_MAKE')
                FROM descendants parent JOIN production_material_analysis_materials child
                  ON child.analysis_item_id=parent.analysis_item_id AND child.parent_node_key=parent.node_key
                  AND child.active AND child.node_role='BOM_COMPONENT' AND NOT parent.invalid AND NOT parent.frozen
            )
            """;
    private static final String EXACT_BOM_DESCENDANTS_SQL = """
                WITH RECURSIVE selected_batches AS MATERIALIZED (
                    SELECT id,action_id,anchor_analysis_item_id,configuration_snapshot FROM preplan_aggregate_batches WHERE id IN(:batches)
                ), source_parents AS (
                    SELECT batch.id batch_id,allocation.analysis_material_id FROM selected_batches batch
                      JOIN preplan_supply_action_allocations allocation ON allocation.action_id=batch.action_id
                    UNION SELECT batch.id,value::uuid FROM selected_batches batch
                      CROSS JOIN LATERAL jsonb_array_elements_text(batch.configuration_snapshot->'materialLineIds') value
                    UNION SELECT batch.id,value::uuid FROM selected_batches batch JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id
                      CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(event.intent_snapshot->'materialLineIds','[]'::jsonb)) value
                ), source_paths AS (
                    SELECT selected.batch_id,child.id,child.analysis_item_id,child.node_key,ARRAY[child.bom_item_id] path,child.confirmed_route,ARRAY[child.id] visited,FALSE invalid
                    FROM source_parents selected JOIN production_material_analysis_materials parent ON parent.id=selected.analysis_material_id
                    JOIN production_material_analysis_materials child ON child.analysis_item_id=parent.analysis_item_id
                      AND child.active AND child.node_role='BOM_COMPONENT'
                      AND ((parent.node_role='ROOT_SUPPLY' AND child.depth=1) OR child.parent_node_key=parent.node_key)
                    UNION ALL
                    SELECT parent.batch_id,child.id,child.analysis_item_id,child.node_key,parent.path||child.bom_item_id,child.confirmed_route,
                      parent.visited||child.id,child.id=ANY(parent.visited) OR cardinality(parent.path)>=256
                    FROM source_paths parent JOIN production_material_analysis_materials child ON child.analysis_item_id=parent.analysis_item_id
                      AND child.parent_node_key=parent.node_key AND child.active AND child.node_role='BOM_COMPONENT' AND NOT parent.invalid
                ), target_paths AS (
                    SELECT batch.id batch_id,child.id,child.analysis_item_id,child.node_key,ARRAY[child.bom_item_id] path,ARRAY[child.id] visited,FALSE invalid
                    FROM selected_batches batch JOIN production_material_analysis_materials child ON child.analysis_item_id=batch.anchor_analysis_item_id
                      AND child.active AND child.node_role='BOM_COMPONENT' AND child.depth=1
                    UNION ALL
                    SELECT parent.batch_id,child.id,child.analysis_item_id,child.node_key,parent.path||child.bom_item_id,
                      parent.visited||child.id,child.id=ANY(parent.visited) OR cardinality(parent.path)>=256
                    FROM target_paths parent JOIN production_material_analysis_materials child ON child.analysis_item_id=parent.analysis_item_id
                      AND child.parent_node_key=parent.node_key AND child.active AND child.node_role='BOM_COMPONENT' AND NOT parent.invalid
                )
                """;

    private void copySharedRoutes(Batch batch) { copySharedRoutes(List.of(batch)); }

    /** Walk each exact descendant edge once, instead of rescanning each complete source tree. */
    private void copySharedRoutes(List<Batch> batches) {
        if(batches.isEmpty())return;
        em.createNativeQuery("UPDATE production_material_analysis_materials SET confirmed_route='MAKE',route_reason='共享制造批次内部执行',route_confirmed_at=now(),route_confirmed_by=:actor,updated_at=now() WHERE analysis_item_id IN(:anchors) AND node_role='ROOT_SUPPLY' AND active")
                .setParameter("actor",user.requireId()).setParameter("anchors",batches.stream().map(Batch::anchor).toList()).executeUpdate();
        List<Object[]> routes=NativeQueryResults.objectArrayRows(em.createNativeQuery(EXACT_BOM_DESCENDANTS_SQL + """
                SELECT target.id,COUNT(DISTINCT source.confirmed_route),MIN(source.confirmed_route)
                FROM target_paths target JOIN source_paths source ON source.batch_id=target.batch_id AND source.path=target.path
                GROUP BY target.id
                UNION ALL SELECT NULL::uuid,2::bigint,NULL::text
                WHERE EXISTS(SELECT 1 FROM source_paths WHERE invalid) OR EXISTS(SELECT 1 FROM target_paths WHERE invalid)
                """).setParameter("batches",batches.stream().map(Batch::id).toList()));
        var updates=mapper.createArrayNode();
        for(Object[] route:routes) {
            if(((Number)route[1]).intValue()>1)throw conflict("各来源子料路线不同，不能合成同一制造批次");
            if(route[2]!=null){var update=updates.addObject();update.put("id",route[0].toString());update.put("route",route[2].toString());}
        }
        if(!updates.isEmpty())em.createNativeQuery("""
                UPDATE production_material_analysis_materials material
                SET confirmed_route=input.route,route_reason='共享批次继承原来源已确认路线',route_confirmed_at=now(),route_confirmed_by=:actor,updated_at=now()
                FROM jsonb_to_recordset(CAST(:updates AS jsonb)) input(id uuid,route text) WHERE material.id=input.id
                """).setParameter("actor",user.requireId()).setParameter("updates",updates.toString()).executeUpdate();
    }
    private List<MaterialIdentityBridge> materialBridges(List<UUID> batches) {
        if(batches.isEmpty())return List.of();
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery(EXACT_BOM_DESCENDANTS_SQL + """
                SELECT target.id,source.id,original.required_qty,canonical.required_qty,array_to_string(target.path,'/')
                FROM target_paths target JOIN source_paths source ON source.batch_id=target.batch_id AND source.path=target.path
                JOIN production_material_analysis_materials original ON original.id=source.id
                JOIN production_material_analysis_materials canonical ON canonical.id=target.id
                UNION ALL SELECT NULL::uuid,NULL::uuid,NULL::numeric,NULL::numeric,NULL::text
                WHERE EXISTS(SELECT 1 FROM source_paths WHERE invalid) OR EXISTS(SELECT 1 FROM target_paths WHERE invalid)
                ORDER BY 1,2
                """).setParameter("batches",batches));
        Map<UUID,List<UUID>> origins=new LinkedHashMap<>();Map<UUID,BigDecimal> quantities=new HashMap<>();Map<UUID,String> paths=new HashMap<>();
        for(Object[] row:rows){if(row[0]==null)throw conflict("共享BOM路径存在循环或层级超过256，不能提交身份映射");UUID target=(UUID)row[0];origins.computeIfAbsent(target,ignored->new ArrayList<>());if(decimal(row[2]).signum()==0&&!origins.get(target).contains((UUID)row[1]))origins.get(target).add((UUID)row[1]);quantities.put(target,decimal(row[3]));paths.put(target,(String)row[4]);}
        return origins.entrySet().stream().map(entry->new MaterialIdentityBridge(entry.getValue(),entry.getKey(),paths.get(entry.getKey()),quantities.get(entry.getKey()))).toList();
    }
    /** ADR-143：只有自制建共享制造批次；委外批次永远是外部批次(无锚点)，成员 P 节点各自展开直属物料。 */
    private static boolean manufacturing(GroupPreview group){return "MAKE".equals(group.route());}
    private static GroupPreview quantities(GroupPreview group,List<SourcePreview> sources,BigDecimal quantity){return new GroupPreview(group.clientGroupKey(),group.compatibilityKey(),group.route(),group.goodsId(),group.goodsCode(),group.goodsName(),group.colorId(),group.colorName(),group.unitId(),group.unitName(),group.sourceRequiredQty(),group.orderedQty(),group.remainingQty(),quantity,group.publicExtraQty(),group.safetyQty(),group.departmentId(),group.workerId(),group.teamDepartmentId(),group.billDate(),group.deliveryDate(),group.productNo(),group.allowedOverproductionRate(),sources,group.sharedBomChildren(),group.blockedReason());}
    private static SourcePreview source(SourcePreview source,BigDecimal qty){return new SourcePreview(source.materialLineId(),source.analysisLineId(),source.sourceLabel(),source.allocationPriority(),source.needDate(),source.sourceRequiredQty(),source.remainingQty(),qty,source.orderedQty(),source.originalMaterialLineIds());}
    private static BigDecimal sum(List<SourcePreview> sources){return sources.stream().map(SourcePreview::allocatedQty).reduce(BigDecimal.ZERO,BigDecimal::add);}
    private String hashRequest(UUID analysisId,SubmitRequest request){ObjectNode data=mapper.valueToTree(request);data.remove("idempotencyKey");
        // ADR-099 修订(2026-09-29)：未跳过认领时移除该字段，哈希与历史逐字节一致。
        if(!request.skipClaims())data.remove("skipAutoClaim");
        return CanonicalFingerprint.sha256(List.of("AGGREGATE-ORDER-V1",analysisId.toString(),data.toString()));}
    private static String stepKey(String key,String group,String stage){return "AGG-"+CanonicalFingerprint.sha256(List.of(key,group,stage));}
    private static BigDecimal decimal(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static void validateRequest(SubmitRequest request){if(request==null||request.groups().isEmpty()||request.idempotencyKey()==null||!request.idempotencyKey().matches("[A-Za-z0-9._:-]{8,128}"))throw invalid("汇总下单缺少有效内容或幂等键");AggregateMaterialOrderPreviewService.requireSourceScope(request.groups());}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException forbidden(String message){return new ApiException(ErrorCode.FORBIDDEN,message);}
    private record Batch(UUID id,UUID analysis,UUID action,UUID anchor,UUID plan,String route,long version){}
    private record External(String type,UUID id,String no,UUID item){}
    static BigDecimal releasedChildQuantity(BigDecimal before,BigDecimal after,BigDecimal bomQty,String basis,BigDecimal basisOutput,boolean partial) {
        return childQuantity(before,bomQty,basis,basisOutput,partial).subtract(childQuantity(after,bomQty,basis,basisOutput,partial)).max(BigDecimal.ZERO);
    }
    private static BigDecimal childQuantity(BigDecimal output,BigDecimal bomQty,String basis,BigDecimal basisOutput,boolean partial) {
        try{return MaterialConsumptionMath.required(output,bomQty,basis,basisOutput,partial);}
        catch(IllegalArgumentException invalid){throw conflict("BOM 包装/批次计量数据无效，不能计算可转交供给");}
    }
    private record CapacitySnapshot(BigDecimal required,BigDecimal capacity,BigDecimal parentReleased,BigDecimal parentRetained,BigDecimal owned){}
}
