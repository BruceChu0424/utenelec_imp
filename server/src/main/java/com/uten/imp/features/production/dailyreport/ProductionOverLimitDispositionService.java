package com.uten.imp.features.production.dailyreport;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProductionOverLimitReleasePort;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.features.production.quality.ProductionQualityMutationFootprintService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import static com.uten.imp.features.production.dailyreport.ProductionOverLimitDispositionContracts.*;

/** Plans release already-produced quantities; this service never creates output or material use. */
@Service
@RequiredArgsConstructor
@Transactional(readOnly=true)
public class ProductionOverLimitDispositionService {
    public static final String APPROVE="production_plan:approve";
    public static final String AGGREGATE="PRODUCTION_OVER_LIMIT_DISPOSITION";
    public static final String PENDING="PRODUCTION_OVER_LIMIT_PENDING";
    public static final String DECIDED="PRODUCTION_OVER_LIMIT_DECIDED";
    public static final String WITHDRAWN="PRODUCTION_OVER_LIMIT_WITHDRAWN";
    private static final Set<String> OPEN=Set.of("PENDING","HELD","RETURNED");
    private final EntityManager em;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionWorkshopMembership membership;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final BusinessEventPublisher events;
    private final ProductionQualityMutationFootprintService footprints;
    private final ProductionOverLimitReleasePort releases;

    /** Called inside the report transaction after save/approve/reverse/delete; drafts do not notify. */
    @Transactional(propagation=Propagation.MANDATORY)
    public void syncReport(UUID reportId) {
        em.flush();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                INSERT INTO production_over_limit_dispositions(report_item_id,report_id,execution_segment_id,
                    plan_id,qty,actual_batch_qty,planned_qty,allowed_rate,reason,status,created_by)
                SELECT item.id,item.report_id,item.execution_segment_id,segment.plan_id,item.qty,item.output_batch_qty,
                    (item.overproduction_authorization_snapshot->>'plannedQty')::numeric,
                    (item.overproduction_authorization_snapshot->>'allowedRate')::numeric,item.over_limit_reason,
                    CASE WHEN report.status=1 THEN 'PENDING' ELSE 'DRAFT' END,:actor
                FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
                JOIN production_execution_segments segment ON segment.id=item.execution_segment_id
                WHERE item.report_id=:report AND item.is_over_limit AND item.fqc_recovery_authorization_id IS NULL
                  AND NOT item.is_deleted AND NOT report.is_deleted AND report.status IN(0,1)
                  AND NOT EXISTS(SELECT 1 FROM production_over_limit_dispositions existing WHERE existing.report_item_id=item.id)
                RETURNING id,status
                """).setParameter("report",reportId).setParameter("actor",currentUser.requireId()))) {
            if("PENDING".equals(row[1]))publish(PENDING,(UUID)row[0],0);
        }
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                UPDATE production_over_limit_dispositions request SET status='PENDING',row_version=request.row_version+1
                FROM production_daily_reports report,production_daily_report_items item
                WHERE request.report_id=:report AND request.report_id=report.id AND request.report_item_id=item.id
                  AND request.status='DRAFT' AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted
                RETURNING request.id,request.row_version
                """).setParameter("report",reportId)))publish(PENDING,(UUID)row[0],((Number)row[1]).longValue());
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                UPDATE production_over_limit_dispositions request SET status='WITHDRAWN',row_version=request.row_version+1
                FROM production_daily_reports report,production_daily_report_items item
                WHERE request.report_id=:report AND request.report_id=report.id AND request.report_item_id=item.id
                  AND request.status<>'WITHDRAWN'
                  AND (report.is_deleted OR item.is_deleted OR report.status NOT IN(0,1)
                    OR (report.status=0 AND request.status<>'DRAFT'))
                RETURNING request.id,request.row_version
                """).setParameter("report",reportId)))publish(WITHDRAWN,(UUID)row[0],((Number)row[1]).longValue());
    }

    public PageResponse<View> list(String status,int page,int size) {
        requireApprover();
        String filter=status==null?"PENDING":status.strip().toUpperCase(java.util.Locale.ROOT);
        if(!Set.of("PENDING","HELD","RETURNED","ACCEPTED","WITHDRAWN","ALL").contains(filter))
            throw validation("超限处理状态不正确");
        var scope=access.nativeReadScope("plan.maker_id","owners");
        String predicate=scope.predicate()+" AND request.status<>'DRAFT'";
        if("PENDING".equals(filter))predicate+=" AND request.status IN('PENDING','HELD','RETURNED')";
        else if(!"ALL".equals(filter))predicate+=" AND request.status=:status";
        var count=em.createNativeQuery("SELECT COUNT(*) "+FROM+" WHERE "+predicate);
        var query=em.createNativeQuery(PROJECTION+FROM+" WHERE "+predicate+" ORDER BY request.created_at DESC,request.id DESC");
        scope.bind(count);scope.bind(query);
        if(!Set.of("PENDING","ALL").contains(filter)){count.setParameter("status",filter);query.setParameter("status",filter);}
        long total=((Number)count.getSingleResult()).longValue();
        int actualPage=Math.max(page,1),actualSize=Math.min(Math.max(size,1),100);
        long offset=(long)(actualPage-1)*actualSize;
        if(offset>Integer.MAX_VALUE)throw validation("页码超出范围");
        query.setFirstResult((int)offset).setMaxResults(actualSize);
        boolean active=membership.isActiveOperator();
        List<View> rows=NativeQueryResults.objectArrayRows(query).stream().map(row->view(row,active,List.of())).toList();
        return new PageResponse<>(rows,actualPage,actualSize,total,total==0?0:(int)((total+actualSize-1)/actualSize));
    }

    public long count() {
        requireApprover();
        var scope=access.nativeReadScope("plan.maker_id","owners");
        var query=em.createNativeQuery("SELECT COUNT(*) "+FROM+" WHERE request.status IN('PENDING','HELD','RETURNED') AND "+scope.predicate());
        scope.bind(query);
        return ((Number)query.getSingleResult()).longValue();
    }

    public View detail(UUID id) {
        Object[] row=row(id);
        requireReadable(row);
        List<DecisionView> history=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT action,reason,decided_by_name,decided_at FROM production_over_limit_decisions
                WHERE disposition_id=:id ORDER BY expected_version,id
                """).setParameter("id",id)).stream().map(r->new DecisionView((String)r[0],(String)r[1],
                    (String)r[2],NativeValueConverters.toOffsetDateTime(r[3]))).toList();
        return view(row,access.hasAuthority(APPROVE)&&access.canRead((UUID)row[26])&&membership.isActiveOperator(),history);
    }

    @Transactional
    public View decide(UUID id,DecisionRequest request) {
        tx.bind();requireApprover();membership.requireActiveOperator();
        if(request==null||request.expectedVersion()==null||request.expectedVersion()<0)throw validation("缺少处理版本");
        if(!Set.of("ACCEPT_PUBLIC","HOLD","RETURN_FOR_REVIEW").contains(Objects.toString(request.action(),"")))
            throw validation("处理方式不正确");
        String reason=reason(request.reason()),key=key(request.idempotencyKey());
        UUID actor=currentUser.requireId();
        String hash=CanonicalFingerprint.sha256(List.of("PRODUCTION-OVER-LIMIT-V1",id.toString(),request.action(),
                request.expectedVersion().toString(),reason));
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
            .setParameter("key","over-limit:"+actor+":"+key).getSingleResult();
        Object[] source=row(id);
        access.requireReadable((UUID)source[26],"超限产出不存在或不可见");
        List<Object[]> replay=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT disposition_id,request_hash FROM production_over_limit_decisions
                WHERE decided_by=:actor AND idempotency_key=:key
                """).setParameter("actor",actor).setParameter("key",key));
        if(!replay.isEmpty()) {
            if(!id.equals(replay.getFirst()[0])||!hash.equals(replay.getFirst()[1]))throw conflict("同一防重复提交标识已用于另一项处理，请刷新后重试");
            return detail(id);
        }
        UUID report=(UUID)source[3],item=(UUID)source[5];
        List<UUID> inspections=NativeQueryResults.typedRows(em.createNativeQuery(
            "SELECT id FROM production_fqc_inspections WHERE source_report_id=:report "
                +"OR fn_daily_report_output_authorization_root(source_report_item_id)=:item ORDER BY id")
            .setParameter("report",report).setParameter("item",item),UUID.class);
        var footprint=inspections.isEmpty()?footprints.beginReport(report):footprints.beginInspections(inspections);
        em.createNativeQuery("SELECT id FROM production_daily_reports WHERE id=:id FOR UPDATE").setParameter("id",report).getResultList();
        em.createNativeQuery("SELECT id FROM production_execution_segments WHERE id=:id FOR UPDATE").setParameter("id",source[7]).getResultList();
        em.createNativeQuery("SELECT id FROM production_over_limit_dispositions WHERE id=:id FOR UPDATE").setParameter("id",id).getResultList();
        source=row(id);footprint.verifyUnchanged();
        access.requireScopedOperationWritable((UUID)source[26],"无权处理此计划的超限产出",APPROVE);
        if(!OPEN.contains((String)source[1])||((Number)source[2]).longValue()!=request.expectedVersion()
                ||!Boolean.TRUE.equals(source[29]))throw conflict("报工或处理状态已变化，请刷新后核对");
        em.createNativeQuery("""
                INSERT INTO production_over_limit_decisions(disposition_id,action,reason,expected_version,
                    decided_by,decided_by_name,idempotency_key,request_hash)
                VALUES(:id,:action,:reason,:version,:actor,:name,:key,:hash)
                """).setParameter("id",id).setParameter("action",request.action()).setParameter("reason",reason)
                .setParameter("version",request.expectedVersion()).setParameter("actor",actor)
                .setParameter("name",operatorName()).setParameter("key",key).setParameter("hash",hash).executeUpdate();
        if("ACCEPT_PUBLIC".equals(request.action()))releases.releasePendingForReportItem(item);
        publish(DECIDED,id,request.expectedVersion()+1);
        return detail(id);
    }

    private Object[] row(UUID id) {
        var rows=NativeQueryResults.objectArrayRows(em.createNativeQuery(PROJECTION+FROM+" WHERE request.id=:id").setParameter("id",id));
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"超限产出不存在或不可见");
        return rows.getFirst();
    }
    private void requireReadable(Object[] row) {
        boolean planner=(access.hasAuthority(APPROVE)||access.hasAuthority("production_plan:view"))&&access.canRead((UUID)row[26]);
        boolean workshop=access.hasAuthority("production_execution:view")&&membership.isActiveOperator()
            &&membership.isWorkshopMember((UUID)row[27],(UUID)row[28],currentUser.employeeId().orElse(null));
        UUID employee=currentUser.employeeId().orElse(null);
        boolean author=employee!=null&&access.hasAuthority("production_daily_report:view")&&employee.equals(row[30]);
        if(!planner&&!workshop&&!author)throw new ApiException(ErrorCode.NOT_FOUND,"超限产出不存在或不可见");
    }
    private View view(Object[] r,boolean reviewer,List<DecisionView> history) {
        boolean canDecide=reviewer&&OPEN.contains((String)r[1])&&Boolean.TRUE.equals(r[29]);
        String blocked="DRAFT".equals(r[1])?"日报尚未审核，车间主管审核后交计划处理":
            "WITHDRAWN".equals(r[1])?"来源报工已撤回，原实物及成本按反向链处理":
            "ACCEPTED".equals(r[1])?"本批已同意接收，仍按品质判定和仓库实收形成库存":null;
        return new View((UUID)r[0],(String)r[1],((Number)r[2]).longValue(),(UUID)r[3],(String)r[4],
            (UUID)r[5],(UUID)r[6],(UUID)r[7],(String)r[8],(UUID)r[9],(String)r[10],
            (String)r[11],(String)r[12],(String)r[13],(String)r[14],number(r[15]),number(r[16]),
            number(r[17]),number(r[18]),number(r[19]),(String)r[20],NativeValueConverters.toOffsetDateTime(r[21]),
            (String)r[22],(String)r[23],NativeValueConverters.toOffsetDateTime(r[24]),canDecide,blocked,history);
    }
    private void requireApprover(){if(!access.hasAuthority(APPROVE))throw new ApiException(ErrorCode.FORBIDDEN,"缺少计划审批权限");}
    private void publish(String event,UUID id,long version){events.publishOnce(event,AGGREGATE,id,Map.of("version",version),event+":"+id+":"+version);}
    private String operatorName(){return Objects.toString(em.createNativeQuery("SELECT full_name FROM employees WHERE id=:id")
        .setParameter("id",currentUser.requireEmployeeId()).getSingleResult(),"员工");}
    static String reason(String value){if(value==null||value.strip().length()<2||value.strip().length()>500)throw validation("请填写2至500字的处理原因");return value.strip();}
    static String key(String value){if(value==null||!value.strip().matches("[A-Za-z0-9._:-]{8,128}"))throw validation("防重复提交标识格式不正确");return value.strip();}
    private static BigDecimal number(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static ApiException validation(String text){return new ApiException(ErrorCode.VALIDATION_FAILED,text);}
    private static ApiException conflict(String text){return new ApiException(ErrorCode.CONFLICT,text);}
    private static final String PROJECTION="""
        SELECT request.id,request.status,request.row_version,request.report_id,report.bill_no,item.id,item.output_batch_id,
               request.execution_segment_id,segment.segment_code,request.plan_id,plan.bill_no,goods.code,goods.name,
               color.name,unit.name,request.planned_qty,request.allowed_rate,request.actual_batch_qty,
               request.actual_batch_qty-(SELECT COALESCE(SUM(piece.qty),0) FROM production_daily_report_items piece
                   WHERE piece.report_id=item.report_id AND piece.output_batch_id=item.output_batch_id AND piece.is_over_limit AND NOT piece.is_deleted),
               request.qty,request.reason,request.created_at,decision.reason,decision.decided_by_name,decision.decided_at,
               request.last_decision_id,plan.maker_id,segment.workshop_department_id,segment.responsible_employee_id,
               (report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted),report.maker_id
        """;
    private static final String FROM="""
        FROM production_over_limit_dispositions request
        JOIN production_daily_report_items item ON item.id=request.report_item_id
        JOIN production_daily_reports report ON report.id=request.report_id
        JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
        JOIN production_plans plan ON plan.id=request.plan_id
        JOIN goods ON goods.id=item.goods_id
        LEFT JOIN colors color ON color.id=item.color_id LEFT JOIN units unit ON unit.id=item.unit_id
        LEFT JOIN production_over_limit_decisions decision ON decision.id=request.last_decision_id
        """;
}
