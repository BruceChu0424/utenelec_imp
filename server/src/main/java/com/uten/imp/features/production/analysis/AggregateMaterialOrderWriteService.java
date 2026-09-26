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
import com.uten.imp.features.production.plan.ProductionOverproductionAllowance;
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
        if(reviewed.groups().stream().anyMatch(group->group.blockedReason()!=null))throw conflict(reviewed.groups().stream().map(GroupPreview::blockedReason).filter(Objects::nonNull).findFirst().orElseThrow());
        requireIndependentGroups(request.groups(),reviewed.analysis());
        Map<String,GroupInput> inputs=request.groups().stream().collect(Collectors.toMap(GroupInput::clientGroupKey,value->value));
        Map<UUID,Integer> levels=reviewed.analysis().flatMaterials().stream().collect(Collectors.toMap(MaterialView::materialLineId,MaterialView::level));
        List<GroupPreview> ordered=reviewed.groups().stream().filter(group->group.requestedQty().signum()>0||group.safetyQty().signum()>0)
                .sorted(Comparator.comparingInt((GroupPreview group)->group.sources().stream().mapToInt(source->levels.getOrDefault(source.materialLineId(),Integer.MAX_VALUE)).min().orElse(Integer.MAX_VALUE))
                        .thenComparingInt(group->"BUY".equals(group.route())?2:"SUBCONTRACT".equals(group.route())?1:0).thenComparing(GroupPreview::clientGroupKey)).toList();
        if(ordered.isEmpty())throw invalid("本次没有正数下达量");
        analysis.refreshLocked(analysisId);
        List<BatchResult> results=new ArrayList<>();List<UUID> createdBatches=new ArrayList<>();Set<String> safetyDimensions=new HashSet<>();
        for(GroupPreview original:ordered) {
            GroupInput input=inputs.get(original.clientGroupKey());
            AnalysisView current=analysis.detailInternal(analysisId,false);
            GroupInput remapped=remap(input,createdBatches);
            PreviewRequest step=new PreviewRequest(current.version(),current.fingerprint(),request.idempotencyKey(),request.warehouseId(),request.billDate(),request.deliveryDate(),request.approveNow(),List.of(remapped));
            GroupPreview group=previews.resolve(analysisId,step,current).groups().getFirst();
            if(group.blockedReason()!=null)throw conflict(group.blockedReason());
            boolean manufacturing=manufacturing(group,current);
            if(manufacturing&&request.approveNow()&&!access.hasAuthority("production_plan:approve"))throw forbidden("立即审核需要生产计划审核权限");
            String permission=manufacturing?"production_material_analysis:generate":"production_material_analysis:notify";
            if(!access.hasAuthority(permission))throw forbidden("缺少本次汇总下达路线权限");
            if(!manufacturing&&group.publicExtraQty().signum()>0&&!access.hasAuthority("production_material_analysis:over_supply"))throw forbidden("外部公共备货需要独立超量下达权限");
            if(group.safetyQty().signum()>0&&!safetyDimensions.add(group.goodsId()+":"+Objects.toString(group.colorId(),"")))throw invalid("同一物料公共安全库存补库只能提交一次");
            if(!manufacturing) {
                Map<UUID,BigDecimal> claimed=commands.claimAggregateFuture(analysisId,current,group,stepKey(request.idempotencyKey(),group.clientGroupKey(),"CLAIM"),hash);
                List<SourcePreview> sources=group.sources().stream().map(source->source(source,source.allocatedQty().subtract(claimed.getOrDefault(source.materialLineId(),BigDecimal.ZERO)).max(BigDecimal.ZERO))).toList();
                group=quantities(group,sources,sum(sources).add(group.publicExtraQty()));
                if(group.requestedQty().signum()==0&&group.safetyQty().signum()==0)continue;
            }
            Map<UUID,CapacitySnapshot> capacities=manufacturing?captureSourceCapacities(group):Map.of();
            Batch batch=findReusable(analysisId,group,manufacturing,request.approveNow());
            boolean append=batch!=null;
            if(batch==null)batch=createBatch(analysisId,group,input,request,hash,manufacturing);
            else appendBatch(batch,group,input,request,hash);
            createdBatches.add(batch.id());
            if(manufacturing) {
                analysis.refreshLocked(analysisId);
                installAliases(batch,group,capacities,request.idempotencyKey());
                copySharedRoutes(batch);
                analysis.refreshLocked(analysisId);
                entitlements.delegateAggregateMakeEntitlements(analysisId,batch.action());
                var plan=commands.issueAggregateAnchor(analysisId,batch.id(),batch.anchor(),group,request.warehouseId(),request.approveNow(),stepKey(request.idempotencyKey(),group.clientGroupKey(),"PLAN"));
                if("SUBCONTRACT".equals(group.route()))createSubcontractTask(batch,group);
                analysis.refreshWithAnchorGrowth(analysisId);
                results.add(new BatchResult(batch.id(),group.clientGroupKey(),group.route(),"PRODUCTION_PLAN",plan.planId(),plan.planNo(),plan.planId(),batch.anchor(),group.requestedQty(),group.publicExtraQty(),group.sources()));
            } else {
                External external=append?growExternal(batch,group):createExternal(batch,group,request.warehouseId());
                notices.notifyPreplanSupplyDocumentCreated(external.id(),external.type());
                analysis.refreshLocked(analysisId);
                results.add(new BatchResult(batch.id(),group.clientGroupKey(),group.route(),external.type(),external.id(),external.no(),null,null,group.requestedQty().add(group.safetyQty()),group.publicExtraQty(),group.sources()));
            }
        }
        List<MaterialIdentityBridge> bridges=materialBridges(results.stream().filter(result->result.anchorAnalysisItemId()!=null).map(BatchResult::batchId).distinct().toList());
        ObjectNode payload=mapper.createObjectNode();payload.set("batches",mapper.valueToTree(results));payload.set("materialIdentityBridges",mapper.valueToTree(bridges));
        em.createNativeQuery("""
                INSERT INTO production_material_analysis_commands(analysis_id,operation,idempotency_key,request_hash,result_payload,created_by)
                VALUES(:analysis,'AGGREGATE_ORDER',:key,:hash,CAST(:payload AS jsonb),:actor)
                """).setParameter("analysis",analysisId).setParameter("key",request.idempotencyKey()).setParameter("hash",hash).setParameter("payload",payload.toString()).setParameter("actor",user.requireId()).executeUpdate();
        return new SubmitResult(analysis.detailInternal(analysisId,false),false,results,bridges);
    }

    private Batch createBatch(UUID analysisId,GroupPreview group,GroupInput original,SubmitRequest request,String hash,boolean manufacturing) {
        UUID id=UUID.randomUUID(),action=UUID.randomUUID(),anchor=manufacturing?UUID.randomUUID():null;
        String actionKey=CanonicalFingerprint.sha256(List.of("AGGREGATE-ACTION",group.compatibilityKey()));
        int generation=((Number)em.createNativeQuery("SELECT COALESCE(MAX(generation),0)+1 FROM preplan_supply_actions WHERE analysis_id=:analysis AND action_group_key=:key AND route=:route")
                .setParameter("analysis",analysisId).setParameter("key",actionKey).setParameter("route",group.route()).getSingleResult()).intValue();
        var material=analysis.detailInternal(analysisId,false).flatMaterials().stream().filter(row->row.materialLineId().equals(group.sources().getFirst().materialLineId())).findFirst().orElseThrow();
        ObjectNode config=mapper.valueToTree(original);config.set("originalMaterialLineIds",mapper.valueToTree(original.materialLineIds()));
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
            markExternal(batch,"MAKE".equals(group.route())?"PREPLAN_MAKE_TASK":"SUBCONTRACT_MAKE_TASK",anchor,"共享制造 "+id.toString().substring(0,8),anchor,null,null);
        }
        event(batch,"CREATE",group,request.idempotencyKey(),hash);
        return new Batch(id,analysisId,action,anchor,null,group.route(),1);
    }

    private Batch findReusable(UUID analysisId,GroupPreview group,boolean manufacturing,boolean approveNow) {
        var match=new AggregateMaterialBatchLookup(em).find(analysisId,group,manufacturing,approveNow,true);
        return match==null?null:new Batch(match.batchId(),analysisId,match.actionId(),match.anchorId(),match.planId(),match.route(),match.version());
    }
    private void appendBatch(Batch batch,GroupPreview group,GroupInput original,SubmitRequest request,String hash) {
        event(batch,"APPEND",group,request.idempotencyKey(),hash);
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
    private void event(Batch batch,String kind,GroupPreview group,String key,String hash) {
        ObjectNode deltas=mapper.createObjectNode();group.sources().stream().filter(source->source.allocatedQty().signum()>0).forEach(source->deltas.put(source.materialLineId().toString(),source.allocatedQty()));
        ObjectNode intent=mapper.valueToTree(group);intent.set("materialLineIds",mapper.valueToTree(group.sources().stream().map(SourcePreview::materialLineId).toList()));
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

    private Map<UUID,CapacitySnapshot> captureSourceCapacities(GroupPreview group) {
        List<UUID> parents=group.sources().stream().filter(source->source.allocatedQty().signum()>0).map(SourcePreview::materialLineId).toList();if(parents.isEmpty())return Map.of();
        Map<UUID,CapacitySnapshot> result=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT child.id,child.required_qty,GREATEST(child.required_qty+COALESCE((
                    SELECT SUM(fn_preplan_aggregate_alias_qty(alias.id)) FROM preplan_aggregate_material_aliases alias WHERE alias.source_material_id=child.id),0),
                    COALESCE((SELECT SUM(fn_preplan_allocation_admitted_qty(allocation.id)) FROM preplan_supply_action_allocations allocation
                        JOIN preplan_supply_actions action ON action.id=allocation.action_id AND action.status<>'CANCELLED'
                        WHERE allocation.analysis_material_id=child.id),0),
                    COALESCE((SELECT SUM(link.submitted_qty) FROM production_material_analysis_items anchor
                        JOIN production_material_analysis_plan_links link ON link.analysis_item_id=anchor.id AND link.allocation_status IN('SUBMITTED','APPROVED')
                        WHERE anchor.parent_analysis_material_id=child.id AND NOT anchor.is_deleted),0))
                FROM production_material_analysis_materials parent JOIN production_material_analysis_materials child ON child.analysis_item_id=parent.analysis_item_id
                  AND child.active AND ((parent.node_role='ROOT_SUPPLY' AND child.depth=1) OR child.parent_node_key=parent.node_key)
                WHERE parent.id IN(:parents)
                """).setParameter("parents",parents)))result.put((UUID)row[0],new CapacitySnapshot(decimal(row[1]),decimal(row[2])));
        return result;
    }
    private void installAliases(Batch batch,GroupPreview group,Map<UUID,CapacitySnapshot> snapshots,String commandKey) {
        BigDecimal output=group.requestedQty();
        if(batch.plan()!=null)output=output.add(decimal(em.createNativeQuery("SELECT qty FROM production_plan_items WHERE plan_id=:id AND NOT is_deleted").setParameter("id",batch.plan()).getSingleResult()));
        List<Object[]> children=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT child.id,child.bom_item_id,child.bom_qty,child.consumption_basis,child.basis_output_qty,child.allow_partial_package,
                    COALESCE((SELECT SUM(fn_preplan_aggregate_alias_qty(alias.id)) FROM preplan_aggregate_material_aliases alias WHERE alias.aggregate_material_id=child.id),0),
                    fn_preplan_aggregate_material_capacity(child.id)
                FROM production_material_analysis_materials child WHERE child.analysis_item_id=:anchor AND child.active AND child.depth=1 AND child.node_role='BOM_COMPONENT' ORDER BY child.bom_item_id
                """)
                .setParameter("anchor",batch.anchor()));
        record Original(UUID material,UUID alias,BigDecimal required,BigDecimal delegated,BigDecimal sourceCap){}
        Map<UUID,Map<UUID,List<Original>>> originalsByParent=new HashMap<>();
        List<UUID> parents=group.sources().stream().filter(source->source.allocatedQty().signum()>0).map(SourcePreview::materialLineId).toList();
        if(!parents.isEmpty())for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT parent.id,child.bom_item_id,child.id,alias.id,child.required_qty,
                    COALESCE((SELECT SUM(fn_preplan_aggregate_alias_qty(other.id)) FROM preplan_aggregate_material_aliases other WHERE other.source_material_id=child.id),0),
                    CASE WHEN alias.id IS NULL THEN 0 ELSE fn_preplan_aggregate_alias_source_capacity(alias.id) END
                FROM production_material_analysis_materials parent JOIN production_material_analysis_materials child ON child.analysis_item_id=parent.analysis_item_id
                  AND child.active AND ((parent.node_role='ROOT_SUPPLY' AND child.depth=1) OR child.parent_node_key=parent.node_key)
                LEFT JOIN preplan_aggregate_material_aliases alias ON alias.batch_id=:batch AND alias.source_material_id=child.id
                WHERE parent.id IN(:parents)
                """).setParameter("batch",batch.id()).setParameter("parents",parents)))
            originalsByParent.computeIfAbsent((UUID)row[0],ignored->new HashMap<>()).computeIfAbsent((UUID)row[1],ignored->new ArrayList<>())
                    .add(new Original((UUID)row[2],(UUID)row[3],decimal(row[4]),decimal(row[5]),decimal(row[6])));
        Map<UUID,BigDecimal> increases=new LinkedHashMap<>(),sourceCaps=new LinkedHashMap<>(),canonicalCaps=new LinkedHashMap<>();
        record NewAlias(UUID parent,UUID source,UUID target,UUID edge,BigDecimal qty,BigDecimal sourceCap,BigDecimal canonicalCap){}
        List<NewAlias> inserts=new ArrayList<>();
        for(Object[] child:children) {
            UUID target=(UUID)child[0],edge=(UUID)child[1];BigDecimal required=MaterialConsumptionMath.required(output,decimal(child[2]),(String)child[3],decimal(child[4]),Boolean.TRUE.equals(child[5]));
            BigDecimal already=decimal(child[6]);
            BigDecimal previousCapacity=decimal(child[7]);
            if(previousCapacity.signum()>0&&required.compareTo(previousCapacity)>0)canonicalCaps.put(target,required.subtract(previousCapacity));
            BigDecimal capacity=required.subtract(already).max(BigDecimal.ZERO);
            record Candidate(SourcePreview parent,UUID material,UUID alias,BigDecimal available,BigDecimal sourceCap,BigDecimal oldSourceCap){}
            List<Candidate> candidates=new ArrayList<>();
            for(SourcePreview source:group.sources())if(source.allocatedQty().signum()>0) {
                List<Original> originals=originalsByParent.getOrDefault(source.materialLineId(),Map.of()).getOrDefault(edge,List.of());
                if(originals.size()>1)throw conflict("共享BOM路径存在歧义，请刷新结构");
                if(!originals.isEmpty()){Original original=originals.getFirst();CapacitySnapshot snapshot=snapshots.get(original.material());if(snapshot==null)continue;
                    BigDecimal released=snapshot.required().subtract(original.required()).max(BigDecimal.ZERO);
                    BigDecimal available=snapshot.capacity().subtract(original.delegated()).max(BigDecimal.ZERO).min(released);
                    candidates.add(new Candidate(source,original.material(),original.alias(),available,snapshot.capacity(),original.sourceCap()));}
            }
            BigDecimal available=candidates.stream().map(Candidate::available).reduce(BigDecimal.ZERO,BigDecimal::add);BigDecimal transfer=capacity.min(available);
            if(candidates.isEmpty())continue;
            var split=AggregateQuantityAllocator.allocate(transfer,candidates.stream().map(candidate->new AggregateQuantityAllocator.SourceCapacity(candidate.material(),candidate.parent().allocationPriority(),candidate.parent().needDate(),candidate.available())).toList(),false);
            Map<UUID,BigDecimal> amounts=split.allocations().stream().collect(Collectors.toMap(AggregateQuantityAllocator.Allocation::sourceId,AggregateQuantityAllocator.Allocation::qty));
            for(Candidate candidate:candidates) {BigDecimal amount=amounts.getOrDefault(candidate.material(),BigDecimal.ZERO);
                if(candidate.alias()!=null){if(amount.signum()>0)increases.put(candidate.alias(),amount);
                    BigDecimal old=candidate.oldSourceCap();
                    if(candidate.sourceCap().compareTo(old)>0)sourceCaps.put(candidate.alias(),candidate.sourceCap().subtract(old));continue;}
                inserts.add(new NewAlias(candidate.parent().materialLineId(),candidate.material(),target,edge,amount,candidate.sourceCap(),required));
            }
        }
        if(!increases.isEmpty()||!sourceCaps.isEmpty()||!canonicalCaps.isEmpty())em.createNativeQuery("SELECT fn_complete_aggregate_alias_deltas(:batch,:key,CAST(:deltas AS jsonb),CAST(:source AS jsonb),CAST(:canonical AS jsonb))")
                .setParameter("batch",batch.id()).setParameter("key",commandKey).setParameter("deltas",mapper.valueToTree(increases).toString())
                .setParameter("source",mapper.valueToTree(sourceCaps).toString()).setParameter("canonical",mapper.valueToTree(canonicalCaps).toString()).getSingleResult();
        if(!inserts.isEmpty()){
        var insertRows=mapper.createArrayNode();for(NewAlias alias:inserts){var row=insertRows.addObject();row.put("parent_id",alias.parent().toString());row.put("source_id",alias.source().toString());row.put("target_id",alias.target().toString());row.put("edge_id",alias.edge().toString());row.put("qty",alias.qty());row.put("source_capacity",alias.sourceCap());row.put("canonical_capacity",alias.canonicalCap());}
        em.createNativeQuery("""
                INSERT INTO preplan_aggregate_material_aliases(batch_id,source_parent_material_id,source_material_id,aggregate_material_id,relative_bom_path,qty,source_capacity_qty,canonical_capacity_qty,capacity_version,created_by)
                SELECT batch.id,input.parent_id,input.source_id,input.target_id,ARRAY[input.edge_id],input.qty,input.source_capacity,input.canonical_capacity,batch.row_version,:actor
                FROM preplan_aggregate_batches batch CROSS JOIN jsonb_to_recordset(CAST(:rows AS jsonb)) AS input(
                    parent_id uuid,source_id uuid,target_id uuid,edge_id uuid,qty numeric,source_capacity numeric,canonical_capacity numeric)
                WHERE batch.id=:batch ORDER BY input.parent_id,input.source_id
                """).setParameter("batch",batch.id()).setParameter("rows",insertRows.toString()).setParameter("actor",user.requireId()).executeUpdate();
        }
    }
    private void copySharedRoutes(Batch batch) {
        em.createNativeQuery("UPDATE production_material_analysis_materials SET confirmed_route='MAKE',route_reason='共享制造批次内部执行',route_confirmed_at=now(),route_confirmed_by=:actor,updated_at=now() WHERE analysis_item_id=:anchor AND node_role='ROOT_SUPPLY' AND active")
                .setParameter("actor",user.requireId()).setParameter("anchor",batch.anchor()).executeUpdate();
        List<Object[]> routes=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH source_parents AS (
                    SELECT allocation.analysis_material_id FROM preplan_aggregate_batches batch JOIN preplan_supply_action_allocations allocation ON allocation.action_id=batch.action_id WHERE batch.id=:batch
                    UNION SELECT value::uuid FROM preplan_aggregate_batches batch CROSS JOIN LATERAL jsonb_array_elements_text(batch.configuration_snapshot->'materialLineIds') value WHERE batch.id=:batch
                    UNION SELECT value::uuid FROM preplan_aggregate_batch_events event CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(event.intent_snapshot->'materialLineIds','[]'::jsonb)) value WHERE event.batch_id=:batch)
                SELECT target.id,COUNT(DISTINCT source.confirmed_route),MIN(source.confirmed_route)
                FROM preplan_aggregate_batches batch JOIN source_parents selected ON TRUE
                JOIN production_material_analysis_materials parent ON parent.id=selected.analysis_material_id
                JOIN production_material_analysis_materials source ON source.analysis_item_id=parent.analysis_item_id
                  AND source.node_role='BOM_COMPONENT' AND source.active
                JOIN production_material_analysis_materials target ON target.analysis_item_id=batch.anchor_analysis_item_id AND target.bom_item_id=source.bom_item_id AND target.active
                  AND fn_aggregate_relative_bom_path(source.id,parent.id)=fn_aggregate_relative_bom_path(target.id,NULL)
                WHERE batch.id=:batch GROUP BY target.id
                """).setParameter("batch",batch.id()));
        for(Object[] route:routes) {
            if(((Number)route[1]).intValue()>1)throw conflict("各来源子料路线不同，不能合成同一制造批次");
            if(route[2]!=null)em.createNativeQuery("UPDATE production_material_analysis_materials SET confirmed_route=:route,route_reason='共享批次继承原来源已确认路线',route_confirmed_at=now(),route_confirmed_by=:actor,updated_at=now() WHERE id=:id")
                    .setParameter("route",route[2]).setParameter("actor",user.requireId()).setParameter("id",route[0]).executeUpdate();
        }
    }
    private void createSubcontractTask(Batch batch,GroupPreview group) {
        UUID task=(UUID)em.createNativeQuery("""
                INSERT INTO preplan_subcontract_make_tasks(analysis_id,analysis_material_id,supply_action_id,preparation_item_id,goods_id,color_id,unit_id,warehouse_id,required_qty,created_by,updated_by)
                SELECT batch.analysis_id,NULL,batch.action_id,batch.anchor_analysis_item_id,action.goods_id,action.color_id,action.unit_id,action.warehouse_id,action.requested_qty+action.public_surplus_qty,:actor,:actor
                FROM preplan_aggregate_batches batch JOIN preplan_supply_actions action ON action.id=batch.action_id WHERE batch.id=:batch
                ON CONFLICT (preparation_item_id) WHERE status='ACTIVE' AND analysis_material_id IS NULL DO UPDATE SET required_qty=EXCLUDED.required_qty,version=preplan_subcontract_make_tasks.version+1,updated_at=now(),updated_by=EXCLUDED.updated_by
                RETURNING id
                """).setParameter("actor",user.requireId()).setParameter("batch",batch.id()).getSingleResult();
        notices.notifySubcontractMakeTaskCreated(task);
    }
    private GroupInput remap(GroupInput input,List<UUID> batches) {
        if(batches.isEmpty())return input;
        List<Object[]> mappings=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT source_material_id,aggregate_material_id FROM preplan_aggregate_material_aliases WHERE batch_id IN(:batches) AND source_material_id IN(:sources)
                UNION
                SELECT source.id,target.id FROM preplan_aggregate_batches batch
                JOIN preplan_supply_action_allocations allocation ON allocation.action_id=batch.action_id
                JOIN production_material_analysis_materials parent ON parent.id=allocation.analysis_material_id
                JOIN production_material_analysis_materials source ON source.analysis_item_id=parent.analysis_item_id
                    AND ((parent.node_role='ROOT_SUPPLY' AND source.depth=1) OR source.parent_node_key=parent.node_key)
                JOIN production_material_analysis_materials target ON target.analysis_item_id=batch.anchor_analysis_item_id
                    AND target.depth=1 AND target.bom_item_id=source.bom_item_id AND target.active
                WHERE batch.id IN(:batches) AND source.id IN(:sources)
                """)
                .setParameter("batches",batches).setParameter("sources",input.materialLineIds()));Map<UUID,UUID> targets=new HashMap<>();
        for(Object[] mapping:mappings){UUID previous=targets.put((UUID)mapping[0],(UUID)mapping[1]);if(previous!=null&&!previous.equals(mapping[1]))throw conflict("来源在本次汇总中有多个制造接收方，请拆分核对");}
        return new GroupInput(input.clientGroupKey(),input.materialLineIds().stream().map(id->targets.getOrDefault(id,id)).distinct().toList(),input.route(),input.qty(),input.allowPublicExtra(),input.departmentId(),input.workerId(),input.teamDepartmentId(),input.billDate(),input.deliveryDate(),input.productNo(),input.allowedOverproductionRate(),input.safetyQty());
    }
    private List<MaterialIdentityBridge> materialBridges(List<UUID> batches) {
        if(batches.isEmpty())return List.of();
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH parents AS (
                    SELECT batch.id,batch.anchor_analysis_item_id,allocation.analysis_material_id FROM preplan_aggregate_batches batch JOIN preplan_supply_action_allocations allocation ON allocation.action_id=batch.action_id WHERE batch.id IN(:batches)
                    UNION SELECT batch.id,batch.anchor_analysis_item_id,value::uuid FROM preplan_aggregate_batches batch CROSS JOIN LATERAL jsonb_array_elements_text(batch.configuration_snapshot->'materialLineIds') value WHERE batch.id IN(:batches)
                    UNION SELECT batch.id,batch.anchor_analysis_item_id,value::uuid FROM preplan_aggregate_batches batch JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id
                        CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(event.intent_snapshot->'materialLineIds','[]'::jsonb)) value WHERE batch.id IN(:batches))
                SELECT target.id,source.id,source.required_qty,target.required_qty,array_to_string(fn_aggregate_relative_bom_path(target.id,NULL),'/')
                FROM parents binding JOIN production_material_analysis_materials parent ON parent.id=binding.analysis_material_id
                JOIN production_material_analysis_materials source ON source.analysis_item_id=parent.analysis_item_id AND source.active AND source.node_role='BOM_COMPONENT'
                JOIN production_material_analysis_materials target ON target.analysis_item_id=binding.anchor_analysis_item_id AND target.bom_item_id=source.bom_item_id AND target.active
                  AND fn_aggregate_relative_bom_path(source.id,parent.id)=fn_aggregate_relative_bom_path(target.id,NULL)
                ORDER BY target.id,source.id
                """).setParameter("batches",batches));
        Map<UUID,List<UUID>> origins=new LinkedHashMap<>();Map<UUID,BigDecimal> quantities=new HashMap<>();Map<UUID,String> paths=new HashMap<>();
        for(Object[] row:rows){UUID target=(UUID)row[0];origins.computeIfAbsent(target,ignored->new ArrayList<>());if(decimal(row[2]).signum()==0&&!origins.get(target).contains((UUID)row[1]))origins.get(target).add((UUID)row[1]);quantities.put(target,decimal(row[3]));paths.put(target,(String)row[4]);}
        return origins.entrySet().stream().map(entry->new MaterialIdentityBridge(entry.getValue(),entry.getKey(),paths.get(entry.getKey()),quantities.get(entry.getKey()))).toList();
    }
    private boolean manufacturing(GroupPreview group,AnalysisView view){if("MAKE".equals(group.route()))return true;if(!"SUBCONTRACT".equals(group.route()))return false;
        return commands.activeBomParentIds(List.of(group.goodsId())).contains(group.goodsId())&&!commands.soleComponentSubcontractGoodsIds(List.of(group.goodsId())).contains(group.goodsId());}
    private static GroupPreview quantities(GroupPreview group,List<SourcePreview> sources,BigDecimal quantity){return new GroupPreview(group.clientGroupKey(),group.compatibilityKey(),group.route(),group.goodsId(),group.goodsCode(),group.goodsName(),group.colorId(),group.colorName(),group.unitId(),group.unitName(),group.sourceRequiredQty(),group.orderedQty(),group.remainingQty(),quantity,group.publicExtraQty(),group.safetyQty(),group.departmentId(),group.workerId(),group.teamDepartmentId(),group.billDate(),group.deliveryDate(),group.productNo(),group.allowedOverproductionRate(),sources,group.sharedBomChildren(),group.blockedReason());}
    private static SourcePreview source(SourcePreview source,BigDecimal qty){return new SourcePreview(source.materialLineId(),source.analysisLineId(),source.sourceLabel(),source.allocationPriority(),source.needDate(),source.sourceRequiredQty(),source.remainingQty(),qty,source.orderedQty());}
    private static BigDecimal sum(List<SourcePreview> sources){return sources.stream().map(SourcePreview::allocatedQty).reduce(BigDecimal.ZERO,BigDecimal::add);}
    private String hashRequest(UUID analysisId,SubmitRequest request){ObjectNode data=mapper.valueToTree(request);data.remove("idempotencyKey");return CanonicalFingerprint.sha256(List.of("AGGREGATE-ORDER-V1",analysisId.toString(),data.toString()));}
    private static String stepKey(String key,String group,String stage){return "AGG-"+CanonicalFingerprint.sha256(List.of(key,group,stage));}
    private static BigDecimal decimal(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static void validateRequest(SubmitRequest request){if(request==null||request.groups().isEmpty()||request.idempotencyKey()==null||!request.idempotencyKey().matches("[A-Za-z0-9._:-]{8,128}"))throw invalid("汇总下单缺少有效内容或幂等键");AggregateMaterialOrderPreviewService.requireSourceScope(request.groups());}
    private static void requireIndependentGroups(List<GroupInput> groups,AnalysisView view) {
        Map<UUID,String> selected=new HashMap<>();groups.forEach(group->group.materialLineIds().forEach(id->selected.put(id,group.clientGroupKey())));
        Map<String,MaterialView> byNode=new HashMap<>();Map<UUID,MaterialView> roots=new HashMap<>();
        for(MaterialView row:view.flatMaterials()){byNode.put(row.analysisLineId()+"|"+row.nodeKey(),row);if("ROOT_SUPPLY".equals(row.nodeRole()))roots.put(row.analysisLineId(),row);}
        for(MaterialView row:view.flatMaterials())if(selected.containsKey(row.materialLineId())) {
            String key=selected.get(row.materialLineId());MaterialView parent=row.parentNodeKey()==null?roots.get(row.analysisLineId()):byNode.get(row.analysisLineId()+"|"+row.parentNodeKey());
            while(parent!=null&&!parent.materialLineId().equals(row.materialLineId())) {
                String owner=selected.get(parent.materialLineId());if(owner!=null&&!owner.equals(key))throw invalid("父件和子料请分段核对：先下达汇总父批次，再按返回的共享BOM核对子层总量");
                if("ROOT_SUPPLY".equals(parent.nodeRole()))break;
                parent=parent.parentNodeKey()==null?roots.get(parent.analysisLineId()):byNode.get(parent.analysisLineId()+"|"+parent.parentNodeKey());
            }
        }
    }
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException forbidden(String message){return new ApiException(ErrorCode.FORBIDDEN,message);}
    private record Batch(UUID id,UUID analysis,UUID action,UUID anchor,UUID plan,String route,long version){}
    private record External(String type,UUID id,String no,UUID item){}
    private record CapacitySnapshot(BigDecimal required,BigDecimal capacity){}
}
