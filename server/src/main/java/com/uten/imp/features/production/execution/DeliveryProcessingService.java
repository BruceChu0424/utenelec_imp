package com.uten.imp.features.production.execution;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.SalesDeliveryInventoryPort;
import com.uten.imp.application.port.SalesDeliveryMutationPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.security.ProductionWorkshopAssignmentScope;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.OffsetDateTime;
import java.util.HexFormat;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

import static com.uten.imp.features.production.execution.DeliveryProcessingContracts.*;

/** Exact physical processing evidence, with no synthetic input/output stock movement. */
@Service
@RequiredArgsConstructor
public class DeliveryProcessingService {
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionWorkshopMembership membership;
    private final ProductionAssignmentValidator assignments;
    private final SalesDeliveryMutationPort mutationFootprint;
    private final SalesDeliveryInventoryPort inventory;
    private final ObjectMapper mapper;

    private static final String FROM = """
            FROM sales_shipment_delivery_components component
            JOIN sales_shipments shipment ON shipment.id=component.shipment_id
            JOIN sales_shipment_items shipment_item ON shipment_item.id=component.shipment_item_id
            JOIN goods ON goods.id=component.goods_id
            LEFT JOIN warehouses warehouse ON warehouse.id=component.warehouse_id
            LEFT JOIN LATERAL (SELECT COALESCE(component.processing_workshop_id,
                goods.owning_workshop_department_id) AS workshop_department_id,
                component.processing_responsible_id AS responsible_employee_id) task ON TRUE
            LEFT JOIN departments workshop ON workshop.id=task.workshop_department_id
            LEFT JOIN employees responsible ON responsible.id=task.responsible_employee_id
            """;
    private static final String BASE = "NOT shipment.is_deleted AND NOT shipment_item.is_deleted"
            + " AND component.required_operations<>'[]'::jsonb";
    private static final String STATUS = "CASE WHEN component.processing_completed_qty=component.required_qty"
            + " THEN 'COMPLETED' WHEN component.processing_started_at IS NULL THEN 'WAITING' ELSE 'IN_PROGRESS' END";
    private static final String SELECT = """
            SELECT component.id,component.shipment_id,shipment.bill_no,component.order_item_id,
                component.bom_path::text,component.goods_id,component.goods_code_snapshot,component.goods_name_snapshot,
                component.color_id,component.unit_id,component.unit_name_snapshot,component.required_qty,
                component.processing_completed_qty,component.required_operations::text,component.warehouse_id,warehouse.name,
                task.workshop_department_id,workshop.name,task.responsible_employee_id,responsible.full_name,
                component.revision,component.processing_started_at,component.processing_started_by,
                component.processing_completed_at,component.processing_evidence,shipment.status,shipment.finance_audit,
                shipment.is_closed,shipment.rejected,shipment.finance_rejected,component.movement_id,
                component.processing_issued_at,component.processing_received_at,component.processing_targets::text
            """;

    @Transactional(readOnly=true)
    public PageResponse<Task> list(int page,int size,UUID shipmentId,String status,String keyword) {
        requireAuthority("production_execution:view");
        int p=Math.max(1,page),s=Math.clamp(size,1,200);
        if(status!=null&&!List.of("WAITING","IN_PROGRESS","COMPLETED").contains(status))throw invalid("加工任务状态不正确");
        Scope scope=readScope();
        String where=BASE+" AND ("+scope.predicate()+")"
                +(shipmentId==null?"":" AND component.shipment_id=:shipment")
                +(status==null?" AND component.movement_id IS NULL":" AND ("+STATUS+")=:status")
                +(keyword==null||keyword.isBlank()?"":" AND (COALESCE(component.goods_code_snapshot,'') ILIKE :keyword"
                    +" OR COALESCE(component.goods_name_snapshot,'') ILIKE :keyword OR shipment.bill_no ILIKE :keyword)");
        Query count=em.createNativeQuery("SELECT count(*) "+FROM+" WHERE "+where);
        Query data=em.createNativeQuery(SELECT+FROM+" WHERE "+where+" ORDER BY shipment.bill_date NULLS LAST,shipment.id,component.id");
        for(Query q:List.of(count,data)){
            bindScope(q,scope);if(shipmentId!=null)q.setParameter("shipment",shipmentId);
            if(status!=null)q.setParameter("status",status);
            if(keyword!=null&&!keyword.isBlank())q.setParameter("keyword","%"+keyword.strip()+"%");
        }
        long total=((Number)count.getSingleResult()).longValue();
        int totalPages=(int)Math.min(Integer.MAX_VALUE,(total+s-1)/s);
        int actualPage=Math.min(p,Math.max(1,totalPages));
        data.setFirstResult((int)Math.min(Integer.MAX_VALUE,(long)(actualPage-1)*s)).setMaxResults(s);
        return new PageResponse<>(NativeQueryResults.objectArrayRows(data).stream().map(this::view).toList(),actualPage,s,total,totalPages);
    }

    @Transactional(readOnly=true)
    public Task get(UUID id) { return view(read(id,false)); }

    @Transactional(readOnly=true)
    public ActionOutcome outcome(UUID componentId,UUID requestId) {
        read(componentId,false);
        var rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT component_id,actor_employee_id,resulting_version FROM sales_delivery_processing_actions WHERE request_id=:id")
                .setParameter("id",requestId));
        if(rows.isEmpty())return new ActionOutcome(requestId,false,null);
        var action=rows.getFirst();
        if(!Objects.equals(action[0],componentId)||!Objects.equals(action[1],currentUser.requireEmployeeId()))
            throw new ApiException(ErrorCode.NOT_FOUND,"该请求不属于当前加工任务及操作人");
        return new ActionOutcome(requestId,true,((Number)action[2]).longValue());
    }

    @Transactional(readOnly=true)
    public List<SalesDeliveryInventoryPort.Choice> warehouses(UUID componentId) {
        var row=read(componentId,false);
        requireAssigned(row);
        if(row[31]==null||row[14]==null)return List.of();
        return List.of(new SalesDeliveryInventoryPort.Choice((UUID)row[14],text(row[15]),decimal(row[11])));
    }

    @Transactional
    public Task assign(UUID id,Assignment request) {
        requireAuthority("production_execution:assign");
        Object[] row=lock(id);UUID actor=currentUser.requireEmployeeId();
        requirePlanningSource(row);
        String hash=hash("ASSIGN",id,request);
        if(replay(request.idempotencyKey(),id,"ASSIGN",hash))return get(id);
        requireMutable(row,request.expectedVersion());
        if(row[31]!=null||row[21]!=null||decimal(row[12]).signum()>0)
            throw conflict("实物已发至加工、开工或报工，不能改派车间或负责人；未加工实物须先由仓库实际收回并取消发出");
        assignments.validate(new ProductionAssignmentValidator.Assignment(request.workshopDepartmentId(),null,
                request.responsibleEmployeeId(),null,null));
        em.createNativeQuery("""
                UPDATE sales_shipment_delivery_components SET processing_workshop_id=:workshop,
                    processing_responsible_id=:responsible,revision=revision+1,updated_at=now()
                WHERE id=:id AND revision=:version
                """).setParameter("workshop",request.workshopDepartmentId()).setParameter("responsible",request.responsibleEmployeeId())
                .setParameter("id",id).setParameter("version",request.expectedVersion()).executeUpdate();
        record(request.idempotencyKey(),id,"ASSIGN",hash,actor,request.expectedVersion()+1);
        return get(id);
    }

    @Transactional
    public Task start(UUID id,Start request) {
        requireAuthority("production_execution:start");
        Object[] row=lock(id);UUID actor=currentUser.requireEmployeeId();requireAssigned(row);
        String hash=hash("START",id,request);
        if(replay(request.idempotencyKey(),id,"START",hash))return get(id);
        requireMutable(row,request.expectedVersion());
        if(row[21]!=null)throw conflict("该加工任务已开工，请刷新核对原结果");
        if(row[31]==null||!Objects.equals(row[14],request.warehouseId()))
            throw conflict("请先由仓库按实际来源发至加工，车间不能自行更换来源仓或占用库存");
        if(row[16]==null)throw invalid("请先为加工任务分配生产车间");
        assignments.validate(new ProductionAssignmentValidator.Assignment((UUID)row[16],null,(UUID)row[18],null,null));
        inventory.requireProcessingReservation(id,request.warehouseId(),(UUID)row[5],(UUID)row[8],decimal(row[11]));
        em.createNativeQuery("""
                UPDATE sales_shipment_delivery_components SET processing_workshop_id=:workshop,
                    processing_started_at=now(),processing_started_by=:actor,revision=revision+1,updated_at=now()
                WHERE id=:id AND revision=:version AND processing_started_at IS NULL
                """).setParameter("workshop",row[16]).setParameter("actor",actor)
                .setParameter("id",id).setParameter("version",request.expectedVersion()).executeUpdate();
        record(request.idempotencyKey(),id,"START",hash,actor,request.expectedVersion()+1);
        return get(id);
    }

    @Transactional
    public Task report(UUID id,Report request) {
        requireAuthority("production_daily_report:create");
        Object[] row=lock(id);UUID actor=currentUser.requireEmployeeId();requireAssigned(row);
        String hash=hash("REPORT",id,request);
        if(replay(request.idempotencyKey(),id,"REPORT",hash))return get(id);
        requireMutable(row,request.expectedVersion());
        if(row[21]==null)throw conflict("请先从实际来源仓占用实物并开工，再提交加工报工");
        if(!strings(row[13]).contains(request.operation())||!"LASER".equals(request.operation()))throw invalid("该任务没有此加工工序");
        BigDecimal completed=validatedCompleted(decimal(row[11]),decimal(row[12]),request.quantity(),request.evidence());
        em.createNativeQuery("""
                INSERT INTO sales_delivery_processing_events(component_id,request_id,quantity,operation,evidence,actor_employee_id)
                VALUES(:id,:request,:quantity,:operation,:evidence,:actor)
                """).setParameter("id",id).setParameter("request",request.idempotencyKey()).setParameter("quantity",request.quantity())
                .setParameter("operation",request.operation()).setParameter("evidence",request.evidence().strip()).setParameter("actor",actor).executeUpdate();
        em.createNativeQuery("""
                UPDATE sales_shipment_delivery_components SET processing_completed_qty=:completed,
                    processing_evidence=:evidence,processing_completed_by=:actor,
                    processing_completed_at=CASE WHEN :completed=required_qty THEN now() ELSE NULL END,
                    revision=revision+1,updated_at=now() WHERE id=:id AND revision=:version
                """).setParameter("completed",completed).setParameter("evidence",request.evidence().strip()).setParameter("actor",actor)
                .setParameter("id",id).setParameter("version",request.expectedVersion()).executeUpdate();
        record(request.idempotencyKey(),id,"REPORT",hash,actor,request.expectedVersion()+1);
        return get(id);
    }

    @Transactional
    public Task cancelStart(UUID id,CancelStart request) {
        requireAuthority("production_execution:start");
        Object[] row=lock(id);UUID actor=currentUser.requireEmployeeId();requireAssigned(row);
        String hash=hash("CANCEL_START",id,request);
        if(replay(request.idempotencyKey(),id,"CANCEL_START",hash))return get(id);
        requireMutable(row,request.expectedVersion());
        if(row[21]==null||decimal(row[12]).signum()>0)throw conflict("仅能撤销尚未报工的开工；实物占用须由仓库实际收回并取消发出后归还");
        em.createNativeQuery("UPDATE sales_shipment_delivery_components SET processing_started_at=NULL,processing_started_by=NULL,revision=revision+1,updated_at=now() WHERE id=:id AND revision=:version")
                .setParameter("id",id).setParameter("version",request.expectedVersion()).executeUpdate();
        record(request.idempotencyKey(),id,"CANCEL_START",hash,actor,request.expectedVersion()+1);
        return get(id);
    }

    static BigDecimal validatedCompleted(BigDecimal required,BigDecimal before,BigDecimal quantity,String evidence) {
        if(quantity==null||quantity.signum()<=0)throw invalid("本次加工数量必须大于零");
        com.uten.imp.common.util.FinancialExactAmount.quantity(quantity,"本次加工数量");
        if(evidence==null||evidence.isBlank()||evidence.length()>2000)throw invalid("请填写本次加工和检验的实际记录");
        BigDecimal total=before.add(quantity);
        if(total.compareTo(required)>0)throw conflict("累计加工报工超过本单物料数量");
        return total;
    }

    private Object[] lock(UUID id) {
        tx.bind();membership.requireActiveOperator();
        Object[] discovered=read(id,false);
        mutationFootprint.lockShipment((UUID)discovered[1]);
        return read(id,true);
    }
    private Object[] read(UUID id,boolean lock) {
        requireAuthority("production_execution:view");Scope scope=readScope();
        Query query=em.createNativeQuery(SELECT+FROM+" WHERE "+BASE+" AND component.id=:id AND ("+scope.predicate()+")"
                +(lock?" FOR UPDATE OF component":""));
        query.setParameter("id",id);bindScope(query,scope);
        List<Object[]> rows=NativeQueryResults.objectArrayRows(query);
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"加工任务不存在或不在本人范围");
        return rows.getFirst();
    }
    private void requireMutable(Object[] row,long version) {
        if(((Number)row[20]).longValue()!=version)throw conflict("加工任务已变化，请刷新后核对");
        if(((Number)row[25]).intValue()!=0||((Number)row[26]).intValue()!=1||Boolean.TRUE.equals(row[27])
                ||Boolean.TRUE.equals(row[28])||Boolean.TRUE.equals(row[29])||row[30]!=null)
            throw conflict("来源出货单未财务放行、已关闭、驳回或已出库，不能新增加工事实");
    }
    private void requireAssigned(Object[] row) {
        if(!membership.isWorkshopMember((UUID)row[16],(UUID)row[18],currentUser.employeeId().orElse(null)))
            throw new ApiException(ErrorCode.FORBIDDEN,"只能办理本人车间分配的加工任务");
    }
    private void requirePlanningSource(Object[] row) {
        if(currentUser.get().map(user->user.isSuperAdmin()).orElse(false))return;
        // A directly purchased component may need processing without ever requiring
        // a manufacturing analysis. Its already assigned workshop can dispatch it.
        if(membership.isWorkshopMember((UUID)row[16],(UUID)row[18],currentUser.employeeId().orElse(null)))return;
        var scope=access.nativeReadScope("analysis.maker_id","processingOwners");
        Query q=em.createNativeQuery("SELECT EXISTS(SELECT 1 FROM production_material_analysis_items item JOIN production_material_analyses analysis ON analysis.id=item.analysis_id WHERE item.sales_order_item_id=:orderItem AND NOT item.is_deleted AND NOT analysis.is_deleted AND analysis.status<>'CANCELLED' AND "+scope.predicate()+")");
        q.setParameter("orderItem",row[3]);scope.bind(q);
        if(!Boolean.TRUE.equals(q.getSingleResult()))throw new ApiException(ErrorCode.FORBIDDEN,"当前加工来源不在本人负责的生产分析范围");
    }
    private record Scope(String predicate,boolean employee,com.uten.imp.security.DocumentAccessPolicy.NativeReadScope owners) { }
    private Scope readScope() {
        if(currentUser.get().map(u->u.isSuperAdmin()).orElse(false)||access.hasAuthority("production_workshop_task:view:all"))return new Scope("TRUE",false,null);
        var owners=access.hasAuthority("production_execution:assign")?access.nativeReadScope("analysis.maker_id","processingReadOwners"):null;
        String assigned=ProductionWorkshopAssignmentScope.predicate("task");
        String planner=owners==null?"FALSE":"EXISTS(SELECT 1 FROM production_material_analysis_items source JOIN production_material_analyses analysis ON analysis.id=source.analysis_id WHERE source.sales_order_item_id=component.order_item_id AND NOT source.is_deleted AND NOT analysis.is_deleted AND analysis.status<>'CANCELLED' AND "+owners.predicate()+")";
        return new Scope("("+assigned+") OR ("+planner+")",true,owners);
    }
    private void bindScope(Query query, Scope scope) {
        if (scope.employee()) {
            query.setParameter("employeeId", currentUser.employeeId().orElse(null));
        }
        if (scope.owners() != null) {
            scope.owners().bind(query);
        }
    }
    private Task view(Object[] r) {
        BigDecimal required=decimal(r[11]),done=decimal(r[12]);boolean assigned=membership.isWorkshopMember((UUID)r[16],(UUID)r[18],currentUser.employeeId().orElse(null));
        boolean open=((Number)r[25]).intValue()==0&&((Number)r[26]).intValue()==1&&!Boolean.TRUE.equals(r[27])&&!Boolean.TRUE.equals(r[28])&&!Boolean.TRUE.equals(r[29])&&r[30]==null;
        String status=done.compareTo(required)==0?"COMPLETED":r[21]==null?"WAITING":"IN_PROGRESS";
        return new Task((UUID)r[0],(UUID)r[1],text(r[2]),(UUID)r[3],strings(r[4]),(UUID)r[5],text(r[6]),text(r[7]),(UUID)r[8],
                (UUID)r[9],text(r[10]),exact(required),exact(done),exact(required.subtract(done)),strings(r[13]),(UUID)r[14],text(r[15]),
                (UUID)r[16],text(r[17]),(UUID)r[18],text(r[19]),status,((Number)r[20]).longValue(),offset(r[21]),(UUID)r[22],
                offset(r[23]),text(r[24]),open&&r[21]==null&&r[31]==null&&done.signum()==0&&access.hasAuthority("production_execution:assign"),
                open&&assigned&&r[16]!=null&&r[21]==null&&r[31]!=null&&access.hasAuthority("production_execution:start"),
                open&&assigned&&r[21]!=null&&done.compareTo(required)<0&&access.hasAuthority("production_daily_report:create"),
                offset(r[31]),offset(r[32]),
                open&&assigned&&r[21]!=null&&done.signum()==0&&access.hasAuthority("production_execution:start"),targets(r[33]));
    }
    private boolean replay(UUID request,UUID component,String action,String hash) {
        var rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT component_id,action_type,request_hash,actor_employee_id FROM sales_delivery_processing_actions WHERE request_id=:id").setParameter("id",request));
        if(rows.isEmpty())return false;var old=rows.getFirst();
        if(!Objects.equals(old[0],component)||!Objects.equals(old[1],action)||!Objects.equals(old[2],hash)
                ||!Objects.equals(old[3],currentUser.requireEmployeeId()))throw conflict("同一请求编号对应不同加工操作或人员，不能重放");
        return true;
    }
    private void record(UUID request,UUID component,String action,String hash,UUID actor,long version) {
        em.createNativeQuery("INSERT INTO sales_delivery_processing_actions(request_id,component_id,action_type,request_hash,actor_employee_id,resulting_version) VALUES(:request,:component,:action,:hash,:actor,:version)")
                .setParameter("request",request).setParameter("component",component).setParameter("action",action).setParameter("hash",hash)
                .setParameter("actor",actor).setParameter("version",version).executeUpdate();
    }
    private String hash(String action,UUID id,Object request) {
        try{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest((action+"|"+id+"|"+mapper.writeValueAsString(request)).getBytes(StandardCharsets.UTF_8)));}
        catch(Exception failure){throw new IllegalStateException("无法生成加工操作指纹",failure);}
    }
    private List<String> strings(Object json){try{return mapper.readValue(json.toString(),new TypeReference<List<String>>(){});}catch(Exception ex){throw conflict("加工任务来源快照不正确");}}
    private List<com.uten.imp.common.delivery.DeliveryProcessingTargets.Target> targets(Object json){
        try {
            var targets = mapper.readValue(json.toString(),new TypeReference<List<com.uten.imp.common.delivery.DeliveryProcessingTargets.Target>>(){});
            if(targets.isEmpty())throw conflict("加工任务缺少冻结的实际加工对象，请先核对出货交付资料");
            return List.copyOf(targets);
        } catch (ApiException ex) { throw ex; }
        catch(Exception ex){throw conflict("加工任务的实际加工对象快照不正确");}
    }
    private void requireAuthority(String authority){if(!access.hasAuthority(authority))throw new ApiException(ErrorCode.FORBIDDEN,"没有相应加工任务操作权限");}
    private static String text(Object value){return value==null?null:value.toString();}
    private static OffsetDateTime offset(Object value){if(value==null)return null;if(value instanceof OffsetDateTime time)return time;
        if(value instanceof java.sql.Timestamp time)return time.toInstant().atOffset(java.time.ZoneOffset.UTC);
        if(value instanceof java.time.Instant time)return time.atOffset(java.time.ZoneOffset.UTC);return OffsetDateTime.parse(value.toString());}
    private static BigDecimal decimal(Object value){return value==null?BigDecimal.ZERO:(BigDecimal)value;}
    private static String exact(BigDecimal value){return value.stripTrailingZeros().toPlainString();}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
