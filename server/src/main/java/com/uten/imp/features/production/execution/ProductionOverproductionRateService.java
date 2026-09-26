package com.uten.imp.features.production.execution;

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
import java.math.RoundingMode;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.execution.ProductionOverproductionRateContracts.*;

/** One approval-backed authority for a task's effective overproduction tolerance. */
@Service
@RequiredArgsConstructor
@Transactional(readOnly=true)
public class ProductionOverproductionRateService {
    public static final String REQUEST_PERMISSION="production_execution:request_overproduction_rate";
    public static final String APPROVE_PERMISSION="production_plan:approve";
    public static final String SUBMITTED="PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED";
    public static final String APPROVED="PRODUCTION_OVERPRODUCTION_RATE_APPROVED";
    public static final String RETURNED="PRODUCTION_OVERPRODUCTION_RATE_RETURNED";
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionWorkshopMembership membership;
    private final TxSessionVars tx;
    private final ObjectMapper mapper;
    private final BusinessEventPublisher events;
    private final ProductionPlanMutationFootprintService planFootprints;

    public Map<UUID, BigDecimal> defaults(Set<UUID> goodsIds) {
        return com.uten.imp.features.production.plan.ProductionOverproductionAllowance.defaults(em, goodsIds);
    }

    public RateContext context(UUID id) {
        Segment segment=segment(id,false);
        requireReadable(segment);
        List<Object[]> pending=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,requested_rate FROM production_overproduction_rate_requests
                WHERE execution_segment_id=:id AND status='PENDING'
                """).setParameter("id",id));
        return new RateContext(segment.id(),segment.planId(),segment.planNo(),segment.code(),
                segment.goodsCode(),segment.goodsName(),segment.colorName(),segment.unitName(),
                segment.planned(),segment.rate(),segment.version(),limit(segment.planned(),segment.rate()),
                pending.isEmpty()?null:(UUID)pending.getFirst()[0],pending.isEmpty()?null:decimal(pending.getFirst()[1]),
                segment.open() && segment.policyApplies() && pending.isEmpty() && canRequest(segment),segment.policyApplies(),
                ((Number)em.createNativeQuery("SELECT COUNT(*) FROM production_overproduction_rate_requests WHERE execution_segment_id=:id")
                        .setParameter("id",id).getSingleResult()).longValue());
    }

    @Transactional
    public RequestView submit(SubmitRequest request) {
        tx.bind();
        requirePermission(REQUEST_PERMISSION);
        requirePermission("production_execution:view");
        if(request==null || request.segmentId()==null || request.expectedRateVersion()==null
                || request.expectedRateVersion()<0)throw validation("调整申请缺少任务或当前比例版本");
        BigDecimal requested=rate(request.requestedRate());
        String reason=reason(request.reason(),true);
        String key=key(request.idempotencyKey());
        UUID actor=currentUser.requireId();
        String hash=CanonicalFingerprint.sha256(List.of("PRODUCTION-RATE-SUBMIT-V1",request.segmentId().toString(),
                request.expectedRateVersion().toString(),requested.stripTrailingZeros().toPlainString(),reason));
        commandLock("SUBMIT",actor,key);
        List<Object[]> replay=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,request_hash FROM production_overproduction_rate_requests
                WHERE submitted_by=:actor AND idempotency_key=:key
                """).setParameter("actor",actor).setParameter("key",key));
        if(!replay.isEmpty()) {
            if(!hash.equals(replay.getFirst()[1]))throw conflict("此幂等键已用于另一份比例调整申请");
            return detail((UUID)replay.getFirst()[0]);
        }
        Segment discovered=segment(request.segmentId(),false);
        if(!canRequest(discovered))throw forbidden("无权为此车间任务申请调整超产比例");
        var footprint=planFootprints.beginPlan(discovered.planId(),List.of());
        Segment segment=segment(request.segmentId(),true);
        footprint.verifyUnchanged();
        if(!canRequest(segment))throw forbidden("无权为此车间任务申请调整超产比例");
        if(!segment.policyApplies())throw conflict("这是按本次实产核准的固定追加量，请回原批次续报，不能再次调整超产比例");
        if(!segment.open())throw conflict("任务已结束或计划已停止、取消，不能调整允许超产比例");
        if(segment.version()!=request.expectedRateVersion())throw conflict("允许超产比例已更新，请核对当前有效比例后重新提交");
        if(segment.rate().compareTo(requested)==0)throw validation("申请比例与当前有效比例相同");
        if(countPending(segment.id())>0)throw conflict("此任务已有待审批的比例调整，请先查看原申请");
        requireSufficientRate(segment,requested);
        UUID id=UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO production_overproduction_rate_requests(id,execution_segment_id,before_rate,requested_rate,
                    expected_rate_version,planned_qty,before_snapshot,after_snapshot,reason,idempotency_key,
                    request_hash,submitted_by,submitted_by_employee_id,submitted_by_name)
                VALUES(:id,:segment,:before,:requested,:version,:planned,CAST(:beforeSnapshot AS jsonb),
                    CAST(:afterSnapshot AS jsonb),:reason,:key,:hash,:actor,:employee,:name)
                """).setParameter("id",id).setParameter("segment",segment.id()).setParameter("before",segment.rate())
                .setParameter("requested",requested).setParameter("version",segment.version()).setParameter("planned",segment.planned())
                .setParameter("beforeSnapshot",snapshot(segment,segment.rate()).toString())
                .setParameter("afterSnapshot",snapshot(segment,requested).toString()).setParameter("reason",reason)
                .setParameter("key",key).setParameter("hash",hash).setParameter("actor",actor)
                .setParameter("employee",currentUser.requireEmployeeId()).setParameter("name",operatorName()).executeUpdate();
        events.publishOnce(SUBMITTED,"PRODUCTION_OVERPRODUCTION_RATE_REQUEST",id,Map.of(),SUBMITTED+":"+id);
        return detail(id);
    }

    public PageResponse<RequestView> list(String status,int page,int size) {
        requirePermission(APPROVE_PERMISSION);
        String filter=status==null?"PENDING":status.strip().toUpperCase(java.util.Locale.ROOT);
        if(!Set.of("PENDING","APPROVED","RETURNED","ALL").contains(filter))throw validation("比例调整状态无效");
        String predicate="ALL".equals(filter)?"TRUE":"request.status=:status";
        var count=em.createNativeQuery("SELECT COUNT(*) FROM production_overproduction_rate_requests request WHERE "+predicate);
        if(!"ALL".equals(filter))count.setParameter("status",filter);
        long total=((Number)count.getSingleResult()).longValue();
        int boundedSize=Math.min(Math.max(size,1),100),boundedPage=Math.max(page,1);
        var query=em.createNativeQuery(PROJECTION+" WHERE "+predicate+" ORDER BY request.submitted_at DESC,request.id DESC LIMIT :size OFFSET :offset")
                .setParameter("size",boundedSize).setParameter("offset",(long)(boundedPage-1)*boundedSize);
        if(!"ALL".equals(filter))query.setParameter("status",filter);
        return new PageResponse<>(NativeQueryResults.objectArrayRows(query).stream().map(this::view).toList(),
                boundedPage,boundedSize,total,total==0?0:(int)((total+boundedSize-1)/boundedSize));
    }

    public long count() {
        requirePermission(APPROVE_PERMISSION);
        return ((Number)em.createNativeQuery("SELECT COUNT(*) FROM production_overproduction_rate_requests WHERE status='PENDING'")
                .getSingleResult()).longValue();
    }

    public RequestView detail(UUID id) {
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery(PROJECTION+" WHERE request.id=:id").setParameter("id",id));
        if(rows.isEmpty())throw notFound();
        requireReadable(segment((UUID)rows.getFirst()[1],false));
        return view(rows.getFirst());
    }

    @Transactional
    public RequestView decide(UUID id,DecisionRequest request,boolean approve) {
        tx.bind();
        requirePermission(APPROVE_PERMISSION);
        membership.requireActiveOperator();
        if(request==null || request.expectedVersion()==null || request.expectedVersion()<0)throw validation("审批缺少申请版本");
        String key=key(request.idempotencyKey()),reason=reason(request.reason(),!approve);
        UUID actor=currentUser.requireId();
        String decision=approve?"APPROVED":"RETURNED";
        String hash=CanonicalFingerprint.sha256(List.of("PRODUCTION-RATE-DECIDE-V1",id.toString(),
                decision,request.expectedVersion().toString(),reason==null?"":reason));
        commandLock("DECISION",actor,key);
        List<Object[]> replay=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT request_id,request_hash FROM production_overproduction_rate_decisions
                WHERE decided_by=:actor AND idempotency_key=:key
                """).setParameter("actor",actor).setParameter("key",key));
        if(!replay.isEmpty()) {
            if(!Objects.equals(id,replay.getFirst()[0]) || !hash.equals(replay.getFirst()[1]))throw conflict("此幂等键已用于另一项审批");
            return detail(id);
        }
        List<UUID> ids=NativeQueryResults.typedRows(em.createNativeQuery("SELECT execution_segment_id FROM production_overproduction_rate_requests WHERE id=:id")
                .setParameter("id",id),UUID.class);
        if(ids.isEmpty())throw notFound();
        Segment discovered=segment(ids.getFirst(),false);
        var footprint=planFootprints.beginPlan(discovered.planId(),List.of());
        Segment segment=segment(ids.getFirst(),true);
        em.createNativeQuery("SELECT id FROM production_overproduction_rate_requests WHERE id=:id FOR UPDATE")
                .setParameter("id",id).getResultList();
        RequestView current=detail(id);
        footprint.verifyUnchanged();
        if(!"PENDING".equals(current.status()) || current.rowVersion()!=request.expectedVersion())throw conflict("申请已被处理或版本已变化，请刷新核对");
        if(approve) {
            requireSufficientRate(segment,current.requestedRate());
            if(!current.canApprove())throw conflict("生产安排或有效比例已变化，请退回并按最新任务重新提交");
        }
        // The append-only decision applies the effective rate and resolves the
        // request atomically in V698; there is no second unreviewed update path.
        em.createNativeQuery("""
                INSERT INTO production_overproduction_rate_decisions(id,request_id,decision,reason,expected_version,
                    decided_by,decided_by_employee_id,decided_by_name,idempotency_key,request_hash)
                VALUES(:id,:request,:decision,:reason,:version,:actor,:employee,:name,:key,:hash)
                """).setParameter("id",UUID.randomUUID()).setParameter("request",id).setParameter("decision",decision)
                .setParameter("reason",reason).setParameter("version",request.expectedVersion()).setParameter("actor",actor)
                .setParameter("employee",currentUser.requireEmployeeId()).setParameter("name",operatorName())
                .setParameter("key",key).setParameter("hash",hash).executeUpdate();
        String event=approve?APPROVED:RETURNED;
        events.publishOnce(event,"PRODUCTION_OVERPRODUCTION_RATE_REQUEST",id,Map.of(),event+":"+id);
        return detail(id);
    }

    private Segment segment(UUID id,boolean lock) {
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT segment.id,plan.id,plan.bill_no,segment.segment_code,goods.code,goods.name,
                       color.name,unit.name,segment.planned_qty,segment.allowed_overproduction_rate,
                       segment.overproduction_rate_version,plan.maker_id,segment.workshop_department_id,
                       segment.responsible_employee_id,
                       (NOT segment.is_deleted AND segment.status IN('WAITING','READY','DISPATCHED','IN_PROGRESS')
                        AND plan.status=1 AND NOT plan.is_deleted AND NOT plan.is_stopped AND NOT plan.is_canceled
                        AND NOT plan.is_closed AND package.status='CONFIRMED' AND NOT package.is_deleted),
                       segment.product_goods_id,segment.product_color_id,segment.product_unit_id,segment.product_unit_rate,
                       fn_execution_actual_surplus_qty(segment.id,TRUE),fn_execution_overproduction_policy_applies(segment.id)
                FROM production_execution_segments segment
                JOIN production_plans plan ON plan.id=segment.plan_id
                JOIN production_planning_packages package ON package.id=segment.package_id
                JOIN goods ON goods.id=segment.product_goods_id
                LEFT JOIN colors color ON color.id=segment.product_color_id
                LEFT JOIN units unit ON unit.id=segment.product_unit_id
                WHERE segment.id=:id
                """+(lock?" FOR UPDATE OF segment":"")).setParameter("id",id));
        if(rows.isEmpty())throw notFound();
        Object[] r=rows.getFirst();
        return new Segment((UUID)r[0],(UUID)r[1],(String)r[2],(String)r[3],(String)r[4],(String)r[5],
                (String)r[6],(String)r[7],decimal(r[8]),decimal(r[9]),((Number)r[10]).longValue(),
                (UUID)r[11],(UUID)r[12],(UUID)r[13],Boolean.TRUE.equals(r[14]),(UUID)r[15],(UUID)r[16],(UUID)r[17],decimal(r[18]),decimal(r[19]),Boolean.TRUE.equals(r[20]));
    }

    private boolean canRequest(Segment segment) {
        return access.hasAuthority(REQUEST_PERMISSION) && access.hasAuthority("production_execution:view")
                && membership.isActiveOperator() && membership.isWorkshopMember(segment.workshop(),segment.responsible(),currentUser.employeeId().orElse(null));
    }

    private void requireReadable(Segment segment) {
        if(access.hasAuthority(APPROVE_PERMISSION))return; // Existing production planning approval pool.
        if(access.hasAuthority("production_execution:view") && membership.isActiveOperator()
                && membership.isWorkshopMember(segment.workshop(),segment.responsible(),currentUser.employeeId().orElse(null)))return;
        throw notFound();
    }

    private long countPending(UUID segment) {
        return ((Number)em.createNativeQuery("SELECT COUNT(*) FROM production_overproduction_rate_requests WHERE execution_segment_id=:id AND status='PENDING'")
                .setParameter("id",segment).getSingleResult()).longValue();
    }

    private void requireSufficientRate(Segment segment,BigDecimal rate) {
        if(segment.usedActual().compareTo(segment.planned().multiply(rate).setScale(4,RoundingMode.DOWN))>0)
            throw conflict("已有已审或待审的公共超产数量超过申请上限，请先核对原报工；不能修改历史数量来调低比例");
    }

    private ObjectNode snapshot(Segment s,BigDecimal rate) {
        ObjectNode root=mapper.createObjectNode();
        root.put("planId",s.planId().toString());root.put("planNo",s.planNo());root.put("segmentCode",s.code());
        putUuid(root,"workshopDepartmentId",s.workshop());putUuid(root,"responsibleEmployeeId",s.responsible());
        ObjectNode item=root.putArray("items").addObject();item.put("itemId",s.id().toString());
        putUuid(item,"goodsId",s.goods());putUuid(item,"colorId",s.color());putUuid(item,"unitId",s.unit());
        item.put("goodsCode",s.goodsCode());item.put("goodsName",s.goodsName());item.put("colorName",s.colorName());item.put("unitName",s.unitName());
        item.put("plannedQty",s.planned());item.put("unitRate",s.unitRate());
        item.put("allowedOverproductionRate",rate);item.put("allowedTotalQty",limit(s.planned(),rate));
        return root;
    }

    private static void putUuid(ObjectNode node,String key,UUID value) {if(value==null)node.putNull(key);else node.put(key,value.toString());}

    private RequestView view(Object[] row) {
        JsonNode before=json(row[10]),after=json(row[11]),item=before.path("items").path(0);
        boolean pending="PENDING".equals(row[6]),review=access.hasAuthority(APPROVE_PERMISSION);
        boolean current=Boolean.TRUE.equals(row[15]);
        return new RequestView((UUID)row[0],(UUID)row[1],UUID.fromString(before.path("planId").asText()),
                before.path("planNo").asText(),before.path("segmentCode").asText(),item.path("goodsName").asText(),
                item.path("goodsCode").asText(),item.path("colorName").asText(null),item.path("unitName").asText(null),
                decimal(row[2]),decimal(row[3]),decimal(row[4]),(String)row[6],((Number)row[7]).longValue(),
                (String)row[8],(String)row[9],NativeValueConverters.toOffsetDateTime(row[5]),before,after,
                (String)row[12],(String)row[13],NativeValueConverters.toOffsetDateTime(row[14]),pending&&review&&current,pending&&review,
                pending&&!current?"原任务安排、有效比例或报工占用已变化，请退回后按最新事实重新提交":null);
    }

    private JsonNode json(Object raw) {try{return mapper.readTree(raw.toString());}catch(java.io.IOException error){throw new IllegalStateException("审批快照损坏",error);}}
    private String operatorName() {return Objects.toString(em.createNativeQuery("SELECT full_name FROM employees WHERE id=:id AND NOT is_deleted")
            .setParameter("id",currentUser.requireEmployeeId()).getSingleResult(),"员工");}
    private void commandLock(String kind,UUID actor,String key) {em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
            .setParameter("key","production-rate:"+kind+":"+actor+":"+key).getSingleResult();}
    private void requirePermission(String permission) {if(!access.hasAuthority(permission))throw forbidden("缺少此操作权限");}
    static BigDecimal rate(BigDecimal rate) {if(rate==null||rate.signum()<0||rate.stripTrailingZeros().scale()>6||rate.compareTo(new BigDecimal("1000"))>=0)
        throw validation("允许超产比例无效，最多四位百分比小数");return rate;}
    static String key(String key) {if(key==null||!key.strip().matches("[A-Za-z0-9._:-]{8,128}"))throw validation("幂等键格式无效");return key.strip();}
    static String reason(String reason,boolean required) {String value=reason==null?null:reason.strip();
        if((required&&(value==null||value.length()<2))||(value!=null&&value.length()>500))throw validation("请填写2至500字的原因");
        return value==null||value.isEmpty()?null:value;}
    private static BigDecimal decimal(Object value) {return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static BigDecimal limit(BigDecimal qty,BigDecimal rate) {return qty.multiply(BigDecimal.ONE.add(rate)).setScale(4,RoundingMode.DOWN);}
    private static ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private static ApiException forbidden(String message){return new ApiException(ErrorCode.FORBIDDEN,message);}
    private static ApiException notFound(){return new ApiException(ErrorCode.NOT_FOUND,"比例调整任务不存在或不可见");}
    private record Segment(UUID id,UUID planId,String planNo,String code,String goodsCode,String goodsName,String colorName,String unitName,
            BigDecimal planned,BigDecimal rate,long version,UUID maker,UUID workshop,UUID responsible,boolean open,
            UUID goods,UUID color,UUID unit,BigDecimal unitRate,BigDecimal usedActual,boolean policyApplies) {}
    private static final String PROJECTION="""
            SELECT request.id,request.execution_segment_id,request.planned_qty,request.before_rate,request.requested_rate,
                   request.submitted_at,request.status,request.row_version,request.reason,request.submitted_by_name,
                   request.before_snapshot::text,request.after_snapshot::text,
                   decision.reason,decision.decided_by_name,decision.decided_at,
                   fn_production_rate_request_ready(request.id)
            FROM production_overproduction_rate_requests request
            LEFT JOIN production_overproduction_rate_decisions decision ON decision.request_id=request.id
            """;
}
