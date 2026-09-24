package com.uten.imp.features.production.fulfillment;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.production.fulfillment.ProductionMaterialIncrementContracts.*;

@Service
@RequiredArgsConstructor
@Transactional(readOnly=true)
public class ProductionMaterialIncrementService {
    public static final String REQUEST_PERMISSION="production_execution:request_material_increment";
    public static final String APPROVE_PERMISSION="production_plan:approve";
    public static final String SUBMITTED="PRODUCTION_MATERIAL_INCREMENT_SUBMITTED";
    public static final String APPROVED="PRODUCTION_MATERIAL_INCREMENT_APPROVED";
    public static final String RETURNED="PRODUCTION_MATERIAL_INCREMENT_RETURNED";
    public static final String CANCELLED="PRODUCTION_MATERIAL_INCREMENT_CANCELLED";
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionWorkshopMembership membership;
    private final TxSessionVars tx;
    private final ObjectMapper mapper;
    private final BusinessEventPublisher events;
    private final ProductionPlanMutationFootprintService footprints;
    private final ProductionExecutionReadinessService readiness;
    private final com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade allocation;
    private final com.uten.imp.application.port.ProductionDrawInstructionNoticePort drawNotices;

    public Context context(UUID id) {
        Segment segment=segment(id,false); requireReadable(segment);
        List<DemandView> demands=demands(segment).stream().map(Demand::view).toList();
        boolean eligible=segment.open()&&!demands.isEmpty();
        return new Context(id,segment.planId(),segment.planNo(),segment.code(),segment.proof(),
                eligible&&canRequest(segment),eligible?null:"当前任务没有可申请增量的原冻结物料，或任务已经结束",demands);
    }

    @Transactional public RequestView submit(SubmitRequest request) {
        tx.bind(); requirePermission(REQUEST_PERMISSION);requirePermission("production_execution:view");
        if(request==null||request.originalDemandId()==null||request.targetSegmentId()==null
                ||request.expectedDemandVersion()==null||request.expectedDemandVersion()<0)throw validation("补料申请缺少任务、原物料或版本");
        BigDecimal quantity=quantity(request.deltaQty());String reason=reason(request.reason(),true),key=key(request.idempotencyKey());
        UUID actor=currentUser.requireId();
        String hash=CanonicalFingerprint.sha256(List.of("MATERIAL-INCREMENT-SUBMIT-V1",request.originalDemandId().toString(),
                request.targetSegmentId().toString(),Objects.toString(request.supplementProofId(),""),
                request.expectedDemandVersion().toString(),quantity.stripTrailingZeros().toPlainString(),reason));
        commandLock("SUBMIT",actor,key);
        List<Object[]> replay=rows("SELECT id,request_hash FROM production_material_increment_requests WHERE submitted_by=:actor AND idempotency_key=:key",actor,key);
        if(!replay.isEmpty()) {if(!hash.equals(replay.getFirst()[1]))throw conflict("幂等键已用于另一份补料申请");return detail((UUID)replay.getFirst()[0]);}
        Segment discovered=segment(request.targetSegmentId(),false);
        if(!canRequest(discovered))throw forbidden("无权为此车间申请实际补料");
        var footprint=footprints.beginPlan(discovered.planId(),List.of());
        Segment segment=segment(request.targetSegmentId(),true);
        Demand demand=demands(segment).stream().filter(item->item.id().equals(request.originalDemandId())).findFirst().orElseThrow(()->conflict("此物料不是目标任务的合法原冻结来源"));
        em.createNativeQuery("SELECT id FROM production_material_demands WHERE id=:id FOR UPDATE").setParameter("id",demand.id()).getResultList();
        footprint.verifyUnchanged();
        if(!canRequest(segment))throw forbidden("无权为此车间申请实际补料");
        if(!segment.open()||!Objects.equals(segment.proof(),request.supplementProofId())||demand.version()!=request.expectedDemandVersion())
            throw conflict("任务、追加证明或物料版本已变化，请刷新核对");
        if(((Number)em.createNativeQuery("SELECT count(*) FROM production_material_increment_requests WHERE original_demand_id=:demand AND target_segment_id=:target AND status='PENDING'")
                .setParameter("demand",demand.id()).setParameter("target",segment.id()).getSingleResult()).longValue()>0)
            throw conflict("此物料已有待审批补料申请，请查看原申请");
        UUID id=UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO production_material_increment_requests(id,original_demand_id,target_segment_id,supplement_proof_id,
                    expected_demand_version,original_required_qty,approved_increment_qty,delta_qty,authorized_demand_id,
                    before_snapshot,after_snapshot,reason,idempotency_key,request_hash,submitted_by,submitted_by_employee_id,submitted_by_name)
                VALUES(:id,:demand,:target,:proof,:version,:required,:approved,:delta,:authorized,CAST(:before AS jsonb),
                    CAST(:after AS jsonb),:reason,:key,:hash,:actor,:employee,:name)
                """).setParameter("id",id).setParameter("demand",demand.id()).setParameter("target",segment.id()).setParameter("proof",segment.proof())
                .setParameter("version",demand.version()).setParameter("required",demand.required()).setParameter("approved",demand.approved())
                .setParameter("delta",quantity).setParameter("authorized",UUID.randomUUID())
                .setParameter("before",snapshot(segment,demand,BigDecimal.ZERO).toString()).setParameter("after",snapshot(segment,demand,quantity).toString())
                .setParameter("reason",reason).setParameter("key",key).setParameter("hash",hash).setParameter("actor",actor)
                .setParameter("employee",currentUser.requireEmployeeId()).setParameter("name",operatorName()).executeUpdate();
        events.publishOnce(SUBMITTED,"PRODUCTION_MATERIAL_INCREMENT_REQUEST",id,Map.of(),SUBMITTED+":"+id);
        return detail(id);
    }

    @Transactional public RequestView decide(UUID id,DecisionRequest request,boolean approve) {
        tx.bind();requirePermission(APPROVE_PERMISSION);membership.requireActiveOperator();
        if(request==null||request.expectedVersion()==null||request.expectedVersion()<0)throw validation("补料审批缺少申请版本");
        UUID actor=currentUser.requireId();String key=key(request.idempotencyKey()),reason=reason(request.reason(),!approve),decision=approve?"APPROVED":"RETURNED";
        String hash=CanonicalFingerprint.sha256(List.of("MATERIAL-INCREMENT-DECIDE-V1",id.toString(),decision,request.expectedVersion().toString(),Objects.toString(reason,"")));
        commandLock("DECISION",actor,key);
        List<Object[]> replay=rows("SELECT request_id,request_hash FROM production_material_increment_decisions WHERE decided_by=:actor AND idempotency_key=:key",actor,key);
        if(!replay.isEmpty()) {if(!id.equals(replay.getFirst()[0])||!hash.equals(replay.getFirst()[1]))throw conflict("幂等键已用于另一项补料审批");return detail(id);}
        RequestView discovered=detail(id);
        var footprint=footprints.beginPlan(discovered.planId(),List.of());
        Segment segment=segment(discovered.targetSegmentId(),true);
        em.createNativeQuery("SELECT id FROM production_material_demands WHERE id=:id FOR UPDATE").setParameter("id",discovered.originalDemandId()).getResultList();
        em.createNativeQuery("SELECT id FROM production_material_increment_requests WHERE id=:id FOR UPDATE").setParameter("id",id).getResultList();
        RequestView current=detail(id); footprint.verifyUnchanged();
        if(!"PENDING".equals(current.status())||current.rowVersion()!=request.expectedVersion())throw conflict("补料申请已被处理，请刷新");
        if(approve&&!current.canApprove())throw conflict("原任务或冻结物料已变化，请退回后重新提交");
        em.createNativeQuery("""
                INSERT INTO production_material_increment_decisions(id,request_id,decision,reason,expected_version,
                    decided_by,decided_by_employee_id,decided_by_name,idempotency_key,request_hash)
                VALUES(:id,:request,:decision,:reason,:version,:actor,:employee,:name,:key,:hash)
                """).setParameter("id",UUID.randomUUID()).setParameter("request",id).setParameter("decision",decision)
                .setParameter("reason",reason).setParameter("version",request.expectedVersion()).setParameter("actor",actor)
                .setParameter("employee",currentUser.requireEmployeeId()).setParameter("name",operatorName())
                .setParameter("key",key).setParameter("hash",hash).executeUpdate();
        if(approve)readiness.prepareApprovedMaterialIncrement(segment.id(),segment.warehouse(),id);
        String event=approve?APPROVED:RETURNED;
        events.publishOnce(event,"PRODUCTION_MATERIAL_INCREMENT_REQUEST",id,Map.of(),event+":"+id);
        return detail(id);
    }

    public PageResponse<RequestView> list(String status,int page,int size) {
        requirePermission(APPROVE_PERMISSION);String filter=status==null?"PENDING":status.strip().toUpperCase(Locale.ROOT);
        if(!Set.of("PENDING","APPROVED","RETURNED","CANCELLED","ALL").contains(filter))throw validation("补料申请状态无效");
        String predicate="ALL".equals(filter)?"TRUE":"(CASE WHEN EXISTS(SELECT 1 FROM production_material_increment_reversals reversed WHERE reversed.request_id=request.id) THEN 'CANCELLED' ELSE request.status END)=:status";
        var count=em.createNativeQuery("SELECT count(*) FROM production_material_increment_requests request WHERE "+predicate);
        if(!"ALL".equals(filter))count.setParameter("status",filter);
        long total=((Number)count.getSingleResult()).longValue();int boundedSize=Math.min(Math.max(size,1),100),boundedPage=Math.max(page,1);
        var query=em.createNativeQuery(PROJECTION+" WHERE "+predicate+" ORDER BY request.submitted_at DESC,request.id DESC LIMIT :size OFFSET :offset")
                .setParameter("size",boundedSize).setParameter("offset",(long)(boundedPage-1)*boundedSize);
        if(!"ALL".equals(filter))query.setParameter("status",filter);
        return new PageResponse<>(NativeQueryResults.objectArrayRows(query).stream().map(this::view).toList(),boundedPage,boundedSize,total,total==0?0:(int)((total+boundedSize-1)/boundedSize));
    }
    public long count(){requirePermission(APPROVE_PERMISSION);return ((Number)em.createNativeQuery("SELECT count(*) FROM production_material_increment_requests WHERE status='PENDING'").getSingleResult()).longValue();}
    public RequestView detail(UUID id) {
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery(PROJECTION+" WHERE request.id=:id").setParameter("id",id));
        if(rows.isEmpty())throw notFound();requireReadable(segment((UUID)rows.getFirst()[2],false));return view(rows.getFirst());
    }

    @Transactional public RequestView cancel(UUID id,DecisionRequest request) {
        tx.bind();requirePermission(APPROVE_PERMISSION);membership.requireActiveOperator();
        if(request==null||request.expectedVersion()==null||request.expectedVersion()<0)throw validation("撤销授权缺少申请版本");
        UUID actor=currentUser.requireId();String key=key(request.idempotencyKey()),reason=reason(request.reason(),true);
        String hash=CanonicalFingerprint.sha256(List.of("MATERIAL-INCREMENT-CANCEL-V1",id.toString(),request.expectedVersion().toString(),reason));
        commandLock("CANCEL",actor,key);
        List<Object[]> replay=rows("SELECT request_id,request_hash FROM production_material_increment_reversals WHERE created_by=:actor AND idempotency_key=:key",actor,key);
        if(!replay.isEmpty()){if(!id.equals(replay.getFirst()[0])||!hash.equals(replay.getFirst()[1]))throw conflict("幂等键已用于另一项撤销授权");return detail(id);}
        RequestView discovered=detail(id);var footprint=footprints.beginPlan(discovered.planId(),List.of());
        segment(discovered.targetSegmentId(),true);
        em.createNativeQuery("SELECT id FROM production_material_increment_requests WHERE id=:id FOR UPDATE").setParameter("id",id).getResultList();
        RequestView current=detail(id);
        if(!current.canCancel()||current.rowVersion()!=request.expectedVersion())throw conflict("补料仍有实际领用、结耗、待退料或下游供给，请先按领退料反向链处理");
        List<UUID> documents=NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT DISTINCT document.id FROM production_planning_package_document_items mapping
                JOIN stock_documents document ON document.id=mapping.document_id AND document.doc_type='DRAW' AND NOT document.is_deleted
                WHERE mapping.demand_id=:demand AND mapping.document_type='DRAW' ORDER BY document.id
                """).setParameter("demand",current.authorizedDemandId()),UUID.class);
        if(!documents.isEmpty())em.createNativeQuery("SELECT id FROM stock_documents WHERE id IN(:ids) ORDER BY id FOR UPDATE").setParameter("ids",documents).getResultList();
        List<Object[]> instructions=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id,GREATEST(fn_production_draw_item_effective_qty(item.id)-COALESCE(item.issued_qty,0),0)
                FROM production_planning_package_document_items mapping
                JOIN stock_document_items item ON item.id=mapping.document_item_id AND NOT item.is_deleted
                JOIN stock_documents document ON document.id=item.doc_id AND document.doc_type='DRAW' AND document.status IN(0,1) AND NOT document.is_deleted
                WHERE mapping.demand_id=:demand AND mapping.document_type='DRAW' ORDER BY item.id FOR UPDATE OF item
                """).setParameter("demand",current.authorizedDemandId()));
        footprint.verifyUnchanged();
        allocation.releaseByDemands(List.of(current.authorizedDemandId()),reason);
        ObjectNode quantities=mapper.createObjectNode();instructions.stream().filter(row->decimal(row[1]).signum()>0).forEach(row->quantities.put(row[0].toString(),decimal(row[1])));
        UUID reversalId=UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO production_material_increment_reversals(id,request_id,expected_version,reason,draw_item_quantities,
                    created_by,created_by_employee_id,created_by_name,idempotency_key,request_hash)
                VALUES(:id,:request,:version,:reason,CAST(:quantities AS jsonb),:actor,:employee,:name,:key,:hash)
                """).setParameter("id",reversalId).setParameter("request",id).setParameter("version",request.expectedVersion()).setParameter("reason",reason)
                .setParameter("quantities",quantities.toString()).setParameter("actor",actor).setParameter("employee",currentUser.requireEmployeeId())
                .setParameter("name",operatorName()).setParameter("key",key).setParameter("hash",hash).executeUpdate();
        for(UUID document:documents)drawNotices.notifyProductionDrawInstructionsChanged(document,reversalId,false);
        events.publishOnce(CANCELLED,"PRODUCTION_MATERIAL_INCREMENT_REQUEST",id,Map.of(),CANCELLED+":"+id);
        return detail(id);
    }
    private Segment segment(UUID id,boolean lock) {
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT target.id,target.plan_id,plan.bill_no,target.segment_code,target.workshop_department_id,target.responsible_employee_id,
                       package.warehouse_id,COALESCE(target.material_snapshot_product_qty,target.planned_qty),
                       (NOT target.is_deleted AND target.status IN('WAITING','READY','DISPATCHED','IN_PROGRESS')
                        AND target.material_requirement_mode='DEMANDED' AND plan.status=1 AND NOT plan.is_deleted
                        AND NOT plan.is_closed AND NOT plan.is_canceled AND NOT plan.is_stopped
                        AND package.status='CONFIRMED' AND NOT package.is_deleted),proof.id,COALESCE(proof.source_execution_segment_id,target.id)
                FROM production_execution_segments target JOIN production_plans plan ON plan.id=target.plan_id
                JOIN production_planning_packages package ON package.id=target.package_id
                LEFT JOIN production_actual_output_supplement_proofs proof ON proof.supplement_execution_segment_id=target.id
                    AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id)
                WHERE target.id=:id
                """+(lock?" FOR UPDATE OF target":"")).setParameter("id",id));
        if(rows.isEmpty())throw notFound();Object[] r=rows.getFirst();
        return new Segment((UUID)r[0],(UUID)r[1],(String)r[2],(String)r[3],(UUID)r[4],(UUID)r[5],(UUID)r[6],decimal(r[7]),Boolean.TRUE.equals(r[8]),(UUID)r[9],(UUID)r[10]);
    }
    private List<Demand> demands(Segment segment) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT original.id,original.plan_id,original.execution_segment_id,original.goods_id,goods.code,goods.name,
                       color.name,unit.name,original.required_qty,
                       (SELECT COALESCE(SUM(delta_qty),0) FROM production_material_increment_requests approved
                        WHERE approved.original_demand_id=original.id AND approved.target_segment_id=:target AND approved.status='APPROVED'
                          AND NOT EXISTS(SELECT 1 FROM production_material_increment_reversals reversed WHERE reversed.request_id=approved.id)),
                       (SELECT COALESCE(SUM(fn_execution_material_net_issued_qty(family.id)),0)
                        FROM production_material_demands family WHERE NOT family.is_deleted AND (family.id=original.id
                          OR family.id IN(SELECT approved.authorized_demand_id FROM production_material_increment_requests approved
                              WHERE approved.original_demand_id=original.id AND approved.target_segment_id=:target AND approved.status='APPROVED'
                                AND NOT EXISTS(SELECT 1 FROM production_material_increment_reversals reversed WHERE reversed.request_id=approved.id)))),
                       (SELECT COALESCE(SUM(fn_material_issue_available(issue.id,NULL)),0) FROM production_material_stock_postings issue
                        WHERE issue.posting_type='ISSUE' AND (issue.demand_id=original.id OR issue.demand_id IN(
                            SELECT approved.authorized_demand_id FROM production_material_increment_requests approved
                            WHERE approved.original_demand_id=original.id AND approved.target_segment_id=:target AND approved.status='APPROVED'
                              AND NOT EXISTS(SELECT 1 FROM production_material_increment_reversals reversed WHERE reversed.request_id=approved.id)))),
                       original.lock_version,original.color_id,original.unit_id,original.warehouse_id,pending.id,pending.delta_qty,
                       (SELECT COUNT(*) FROM production_material_increment_requests history
                        WHERE history.original_demand_id=original.id AND history.target_segment_id=:target)
                FROM production_material_demands original JOIN goods ON goods.id=original.goods_id
                LEFT JOIN colors color ON color.id=original.color_id LEFT JOIN units unit ON unit.id=original.unit_id
                LEFT JOIN production_material_increment_requests pending ON pending.original_demand_id=original.id
                    AND pending.target_segment_id=:target AND pending.status='PENDING'
                WHERE original.execution_segment_id=:source AND original.material_increment_request_id IS NULL
                  AND fn_material_increment_source_valid(original.id,:target,CAST(:proof AS uuid))
                ORDER BY goods.code,original.id
                """).setParameter("target",segment.id()).setParameter("source",segment.source()).setParameter("proof",segment.proof())).stream()
                .map(r->new Demand((UUID)r[0],(UUID)r[1],(UUID)r[2],(UUID)r[3],(String)r[4],(String)r[5],(String)r[6],(String)r[7],decimal(r[8]),decimal(r[9]),decimal(r[10]),decimal(r[11]),((Number)r[12]).longValue(),(UUID)r[13],(UUID)r[14],(UUID)r[15],(UUID)r[16],r[17]==null?null:decimal(r[17]),((Number)r[18]).longValue())).toList();
    }
    private ObjectNode snapshot(Segment segment,Demand demand,BigDecimal delta) {
        ObjectNode node=mapper.createObjectNode();node.put("planId",segment.planId().toString());node.put("planNo",segment.planNo());node.put("segmentCode",segment.code());
        putUuid(node,"workshopDepartmentId",segment.workshop());putUuid(node,"responsibleEmployeeId",segment.responsible());
        ObjectNode item=node.putArray("items").addObject();putUuid(item,"itemId",demand.id());putUuid(item,"goodsId",demand.goods());
        putUuid(item,"colorId",demand.color());putUuid(item,"unitId",demand.unit());putUuid(item,"warehouseId",demand.warehouse());
        item.put("goodsCode",demand.code());item.put("goodsName",demand.name());item.put("colorName",demand.colorName());item.put("unitName",demand.unitName());
        item.put("requiredQty",demand.required());item.put("approvedIncrementQty",demand.approved().add(delta));
        item.put("authorizedQty",demand.required().add(demand.approved()).add(delta));item.put("requiredForProductQty",segment.planned());return node;
    }
    private RequestView view(Object[] r) {
        JsonNode before=json(r[12]),after=json(r[13]),item=before.path("items").path(0);
        boolean pending="PENDING".equals(r[7]),review=access.hasAuthority(APPROVE_PERMISSION),ready=Boolean.TRUE.equals(r[17]);
        boolean approved="APPROVED".equals(r[7]),cancelReady=Boolean.TRUE.equals(r[19]);
        return new RequestView((UUID)r[0],(UUID)r[1],(UUID)r[2],(UUID)r[3],UUID.fromString(before.path("planId").asText()),before.path("planNo").asText(),
                before.path("segmentCode").asText(),item.path("goodsName").asText(),item.path("goodsCode").asText(),item.path("colorName").asText(null),item.path("unitName").asText(null),
                decimal(r[4]),decimal(r[5]),decimal(r[6]),(String)r[7],((Number)r[8]).longValue(),(String)r[9],(String)r[10],NativeValueConverters.toOffsetDateTime(r[11]),
                before,after,(String)r[14],(String)r[15],NativeValueConverters.toOffsetDateTime(r[16]),pending&&review&&ready,pending&&review,
                pending&&!ready?"任务或原物料事实已变化，请退回后重新核对":approved&&!cancelReady?"实际领用、结耗、待退料或下游供给尚未反向清零":null,
                approved||"CANCELLED".equals(r[7])?(UUID)r[18]:null,approved&&review&&cancelReady);
    }
    private boolean canRequest(Segment segment){return access.hasAuthority(REQUEST_PERMISSION)&&access.hasAuthority("production_execution:view")&&membership.isActiveOperator()
            &&membership.isWorkshopMember(segment.workshop(),segment.responsible(),currentUser.employeeId().orElse(null));}
    private void requireReadable(Segment segment){if(access.hasAuthority(APPROVE_PERMISSION))return;
        if(access.hasAuthority("production_execution:view")&&membership.isActiveOperator()&&membership.isWorkshopMember(segment.workshop(),segment.responsible(),currentUser.employeeId().orElse(null)))return;throw notFound();}
    private List<Object[]> rows(String sql,UUID actor,String key){return NativeQueryResults.objectArrayRows(em.createNativeQuery(sql).setParameter("actor",actor).setParameter("key",key));}
    private void requirePermission(String permission){if(!access.hasAuthority(permission))throw forbidden("缺少此操作权限");}
    private void commandLock(String type,UUID actor,String key){em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))").setParameter("key","material-increment:"+type+":"+actor+":"+key).getSingleResult();}
    private String operatorName(){return Objects.toString(em.createNativeQuery("SELECT full_name FROM employees WHERE id=:id AND NOT is_deleted").setParameter("id",currentUser.requireEmployeeId()).getSingleResult(),"员工");}
    private JsonNode json(Object value){try{return mapper.readTree(value.toString());}catch(java.io.IOException error){throw new IllegalStateException("补料快照损坏",error);}}
    private static void putUuid(ObjectNode node,String key,UUID value){if(value==null)node.putNull(key);else node.put(key,value.toString());}
    static BigDecimal quantity(BigDecimal value){if(value==null||value.signum()<=0||value.stripTrailingZeros().scale()>4||value.compareTo(new BigDecimal("100000000000000"))>=0)throw validation("补料数量必须大于0且最多四位小数");return value;}
    static String key(String value){if(value==null||!value.strip().matches("[A-Za-z0-9._:-]{8,128}"))throw validation("幂等键格式无效");return value.strip();}
    static String reason(String value,boolean required){String text=value==null?null:value.strip();if((required&&(text==null||text.length()<2))||(text!=null&&text.length()>500))throw validation("请填写2至500字的原因");return text==null||text.isEmpty()?null:text;}
    private static BigDecimal decimal(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private static ApiException forbidden(String message){return new ApiException(ErrorCode.FORBIDDEN,message);}
    private static ApiException notFound(){return new ApiException(ErrorCode.NOT_FOUND,"补料申请或任务不存在或不可见");}
    private record Segment(UUID id,UUID planId,String planNo,String code,UUID workshop,UUID responsible,UUID warehouse,BigDecimal planned,boolean open,UUID proof,UUID source){}
    private record Demand(UUID id,UUID plan,UUID segment,UUID goods,String code,String name,String colorName,String unitName,BigDecimal required,BigDecimal approved,BigDecimal issued,BigDecimal available,long version,UUID color,UUID unit,UUID warehouse,UUID pendingRequestId,BigDecimal pendingDeltaQty,long generation){
        DemandView view(){return new DemandView(id,plan,segment,goods,code,name,colorName,unitName,required,approved,issued,available,version,pendingRequestId,pendingDeltaQty,generation);}
    }
    private static final String PROJECTION="""
            SELECT request.id,request.original_demand_id,request.target_segment_id,request.supplement_proof_id,
                   request.original_required_qty,request.approved_increment_qty,request.delta_qty,
                   CASE WHEN reversed.id IS NOT NULL THEN 'CANCELLED' ELSE request.status END,request.row_version,
                   request.reason,request.submitted_by_name,request.submitted_at,request.before_snapshot::text,request.after_snapshot::text,
                   COALESCE(reversed.reason,decision.reason),COALESCE(reversed.created_by_name,decision.decided_by_name),
                   COALESCE(reversed.created_at,decision.decided_at),fn_material_increment_request_ready(request.id),request.authorized_demand_id,
                   fn_material_increment_cancel_ready(request.id)
            FROM production_material_increment_requests request
            LEFT JOIN production_material_increment_decisions decision ON decision.request_id=request.id
            LEFT JOIN production_material_increment_reversals reversed ON reversed.request_id=request.id
            """;
}
