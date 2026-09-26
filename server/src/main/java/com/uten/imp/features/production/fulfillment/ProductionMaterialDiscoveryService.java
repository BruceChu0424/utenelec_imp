package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.*;
import static com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.*;

/** Unknown BOM materials become ordinary immutable demands before any inventory issue. */
@Service
@RequiredArgsConstructor
@Transactional(readOnly=true)
public class ProductionMaterialDiscoveryService {
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionWorkshopMembership membership;
    private final ProductionStockTaskAccessPolicy warehouseAccess;
    private final ProductionPlanMutationFootprintService footprints;
    private final ProductionExecutionReadinessService readiness;
    private final ChainNoticeService notices;
    private final BusinessEventPublisher events;

    public Context context(UUID segmentId) {
        Segment segment=segment(segmentId,false); requireWorkshop(segment,false);
        List<Object[]> requests=rows("SELECT id,status FROM production_material_discovery_requests WHERE execution_segment_id=:id AND status<>'CANCELLED'",segmentId);
        Object[] request=requests.isEmpty()?null:requests.getFirst();
        return new Context(segmentId,segment.version(),segment.discovery(),request==null?null:(UUID)request[0],
                request==null?null:(String)request[1],segment.eligible()&&request==null&&access.hasAuthority("production_execution:start")
                    &&Boolean.TRUE.equals(em.createNativeQuery("SELECT start_route IN('FULL_KIT','CONTINUOUS') FROM production_execution_segments WHERE id=:id").setParameter("id",segmentId).getSingleResult()));
    }

    @Transactional public Detail request(UUID segmentId,Request command) {
        validate(command);tx.bind();Segment discovered=segment(segmentId,false);requireWorkshop(discovered,true);
        String hash=hash(List.of("DISCOVERY-REQUEST",segmentId.toString(),command.expectedVersion().toString()));
        lockCommand(command.idempotencyKey());
        List<Object[]> replay=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT id,request_hash FROM production_material_discovery_requests WHERE created_by=:actor AND idempotency_key=:key")
                .setParameter("actor",currentUser.requireId()).setParameter("key",command.idempotencyKey()));
        if(!replay.isEmpty()){if(!hash.equals(replay.getFirst()[1]))throw conflict("幂等键已用于另一项领料申请");return detail((UUID)replay.getFirst()[0]);}
        var footprint=footprints.beginPlan(discovered.plan(),List.of());Segment segment=segment(segmentId,true);footprint.verifyUnchanged();requireWorkshop(segment,true);
        if(!segment.eligible()||segment.version()!=command.expectedVersion())throw conflict("任务已变化，请刷新后重新申请");
        if(!Boolean.TRUE.equals(em.createNativeQuery("SELECT start_route IN('FULL_KIT','CONTINUOUS') FROM production_execution_segments WHERE id=:id").setParameter("id",segmentId).getSingleResult()))
            throw conflict("实际物料尚未确定，请先选择齐套或持续生产路线再申请领料");
        if(!rows("SELECT id FROM production_material_discovery_requests WHERE execution_segment_id=:id AND status<>'CANCELLED'",segmentId).isEmpty())throw conflict("此任务已提交领料，请查看仓库处理进度");
        UUID id=UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO production_material_discovery_requests(id,execution_segment_id,expected_version,created_by,idempotency_key,request_hash)
                VALUES(:id,:segment,:version,:actor,:key,:hash)
                """).setParameter("id",id).setParameter("segment",segmentId).setParameter("version",segment.version())
                .setParameter("actor",currentUser.requireId()).setParameter("key",command.idempotencyKey()).setParameter("hash",hash).executeUpdate();
        bump(segmentId);publish(id,"PENDING");return detail(id);
    }

    @Transactional public Detail cancel(UUID id,Request command) {
        validate(command);tx.bind();Detail discovered=detail(id);Segment before=segment(discovered.segmentId(),false);requireWorkshop(before,true);
        String hash=hash(List.of("DISCOVERY-CANCEL",id.toString(),command.expectedVersion().toString()));lockCommand(command.idempotencyKey());
        List<Object[]> replay=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT id,cancellation_hash FROM production_material_discovery_requests WHERE cancelled_by=:actor AND cancellation_key=:key")
                .setParameter("actor",currentUser.requireId()).setParameter("key",command.idempotencyKey()));
        if(!replay.isEmpty()){if(!id.equals(replay.getFirst()[0])||!hash.equals(replay.getFirst()[1]))throw conflict("幂等键已用于另一项撤回申请");return detail(id);}
        var footprint=footprints.beginPlan(before.plan(),List.of());Segment segment=segment(before.id(),true);
        Object[] request=requestRow(id,true);footprint.verifyUnchanged();requireWorkshop(segment,true);
        if(!"PENDING".equals(request[0])||((Number)request[1]).longValue()!=command.expectedVersion())throw conflict("申请已由仓库处理，不能撤回");
        em.createNativeQuery("UPDATE production_material_discovery_requests SET status='CANCELLED',row_version=row_version+1,cancelled_by=:actor,cancelled_at=now(),cancellation_key=:key,cancellation_hash=:hash WHERE id=:id")
                .setParameter("id",id).setParameter("actor",currentUser.requireId()).setParameter("key",command.idempotencyKey()).setParameter("hash",hash).executeUpdate();
        bump(segment.id());publish(id,"CANCELLED");return detail(id);
    }

    @Transactional public Detail configure(UUID id,Configure command) {
        requireWarehouse(true);tx.bind();
        if(command==null)throw validation("请填写实际领用物料");validate(new Request(command.expectedVersion(),command.idempotencyKey()));
        List<Material> items=normalize(command.items());
        List<String> parts=new ArrayList<>(List.of("DISCOVERY-CONFIGURE",id.toString(),command.expectedVersion().toString()));
        items.forEach(item->parts.add(item.goodsId()+"|"+Objects.toString(item.colorId(),"")+"|"+item.unitId()+"|"+item.warehouseId()+"|"+item.qty().stripTrailingZeros().toPlainString()));
        String hash=hash(parts);lockCommand(command.idempotencyKey());Detail before=detail(id);
        List<Object[]> replay=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT id,configuration_hash FROM production_material_discovery_requests WHERE configured_by=:actor AND configuration_key=:key")
                .setParameter("actor",currentUser.requireId()).setParameter("key",command.idempotencyKey()));
        if(!replay.isEmpty()){if(!id.equals(replay.getFirst()[0])||!hash.equals(replay.getFirst()[1]))throw conflict("幂等键已用于另一项仓库登记");return before;}
        Segment discovered=segment(before.segmentId(),false);
        var footprint=footprints.beginPlan(discovered.plan(),items.stream()
                .map(item->new ProductionPlanMutationFootprintService.RequestedLine(item.goodsId(),item.colorId(),null)).distinct().toList());
        Segment segment=segment(discovered.id(),true);Object[] request=requestRow(id,true);footprint.verifyUnchanged();
        if("CONFIGURED".equals(request[0])) {
            if(Objects.equals(request[2],command.idempotencyKey())&&Objects.equals(request[3],hash)&&Objects.equals(request[6],currentUser.requireId()))return detail(id);
            throw conflict("仓库已登记此申请，请查看正式领料单");
        }
        if(!segment.eligible()||!"PENDING".equals(request[0])||((Number)request[1]).longValue()!=command.expectedVersion())throw conflict("领料申请或任务已变化，请刷新");
        if(segment.version()!=((Number)request[7]).longValue()+1)throw conflict("申请后生产任务已变化，请车间撤回申请并按最新任务重新领料");
        for(Material item:items)validateMaterial(segment,item);
        Map<String,UUID> demands=new LinkedHashMap<>();Map<String,BigDecimal> totals=new HashMap<>();
        for(Material item:items){String dimension=dimension(item);demands.computeIfAbsent(dimension,ignored->UUID.randomUUID());totals.merge(dimension,item.qty(),BigDecimal::add);}
        totals.values().forEach(ProductionMaterialIncrementService::quantity);
        Set<UUID> inserted=new HashSet<>();
        for(Material item:items) {
            UUID demand=demands.get(dimension(item));BigDecimal total=totals.get(dimension(item));String fingerprint=hash(List.of("DISCOVERY-DEMAND",id.toString(),dimension(item),total.toPlainString(),hash));
            em.createNativeQuery("""
                    INSERT INTO production_material_discovery_lines(request_id,demand_id,goods_id,color_id,unit_id,warehouse_id,qty,created_by)
                    VALUES(:request,:demand,:goods,:color,:unit,:warehouse,:qty,:actor)
                    """).setParameter("request",id).setParameter("demand",demand).setParameter("goods",item.goodsId()).setParameter("color",item.colorId())
                    .setParameter("unit",item.unitId()).setParameter("warehouse",item.warehouseId()).setParameter("qty",item.qty()).setParameter("actor",currentUser.requireId()).executeUpdate();
            if(!inserted.add(demand))continue;
            em.createNativeQuery("""
                    INSERT INTO production_material_demands(id,package_id,plan_id,warehouse_id,goods_id,color_id,unit_id,required_qty,
                        supply_route,idempotency_key,execution_segment_id,source_plan_item_id,per_product_qty,requirement_mode,
                        required_for_product_qty,requirement_fingerprint,created_by,updated_by)
                    VALUES(:id,:package,:plan,:warehouse,:goods,:color,:unit,:qty,'BUY',:key,:segment,:source,:per,'EXACT_SNAPSHOT',:output,:fingerprint,:actor,:actor)
                    """).setParameter("id",demand).setParameter("package",segment.pack()).setParameter("plan",segment.plan()).setParameter("warehouse",segment.warehouse())
                    .setParameter("goods",item.goodsId()).setParameter("color",item.colorId()).setParameter("unit",item.unitId()).setParameter("qty",total)
                    .setParameter("key","DISCOVERY:"+id+":"+demand).setParameter("segment",segment.id()).setParameter("source",segment.source())
                    .setParameter("per",total.divide(segment.output(),6,RoundingMode.UP)).setParameter("output",segment.output())
                    .setParameter("fingerprint",fingerprint).setParameter("actor",currentUser.requireId()).executeUpdate();
        }
        em.createNativeQuery("""
                UPDATE production_material_discovery_requests SET status='CONFIGURED',row_version=row_version+1,
                    configured_by=:actor,configured_at=now(),configuration_key=:key,configuration_hash=:hash WHERE id=:id
                """).setParameter("actor",currentUser.requireId()).setParameter("key",command.idempotencyKey()).setParameter("hash",hash).setParameter("id",id).executeUpdate();
        em.createNativeQuery("""
                UPDATE production_execution_segments SET material_requirement_mode='DEMANDED',zero_material_reason=NULL,
                    zero_material_analysis_id=NULL,zero_material_exception_reason=NULL,zero_material_authorized_by=NULL,
                    lock_version=lock_version+1,updated_at=now(),updated_by=:actor WHERE id=:id
                """).setParameter("actor",currentUser.requireId()).setParameter("id",segment.id()).executeUpdate();
        List<UUID> documents=readiness.prepareDiscoveredMaterials(segment.id(),id);
        // This fulfills the workshop's explicit unknown-material request. The warehouse still issues separately.
        em.createNativeQuery("""
                INSERT INTO production_execution_segment_events(execution_segment_id,action,idempotency_key,request_hash,
                    expected_version,resulting_version,created_by,draw_document_ids,draw_item_quantities)
                SELECT :segment,'DRAW_REQUEST',:key,:hash,:version,:result,:actor,CAST(:documents AS uuid[]),
                    (SELECT jsonb_object_agg(item.id::text,item.qty) FROM stock_document_items item
                     WHERE item.doc_id=ANY(CAST(:documents AS uuid[])) AND NOT item.is_deleted)
                """).setParameter("segment",segment.id()).setParameter("key","DISCOVERY:"+id).setParameter("hash",hash)
                .setParameter("version",segment.version()).setParameter("result",segment.version()+1).setParameter("actor",currentUser.requireId())
                .setParameter("documents","{"+String.join(",",documents.stream().map(UUID::toString).toList())+"}").executeUpdate();
        documents.forEach(notices::notifyProductionDrawPending);publish(id,"CONFIGURED");return detail(id);
    }

    public Detail detail(UUID id) {
        List<Object[]> rows=rows("""
                SELECT request.id,segment.id,segment.segment_code,plan.bill_no,goods.code,goods.name,segment.planned_qty,
                       unit.name,department.name,request.status,request.row_version
                FROM production_material_discovery_requests request JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
                JOIN production_plans plan ON plan.id=segment.plan_id JOIN goods ON goods.id=segment.product_goods_id
                LEFT JOIN units unit ON unit.id=segment.product_unit_id LEFT JOIN departments department ON department.id=segment.workshop_department_id
                WHERE request.id=:id
                """,id);
        if(rows.isEmpty())throw notFound();Object[] r=rows.getFirst();
        if(!(access.hasAuthority("stock_doc:view")&&warehouseAccess.canAccessWarehouseTasks()))requireWorkshop(segment((UUID)r[1],false),false);
        List<Item> items=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT line.id,line.demand_id,line.goods_id,goods.code,goods.name,line.color_id,color.name,line.unit_id,unit.name,line.warehouse_id,warehouse.name,line.qty
                FROM production_material_discovery_lines line JOIN goods ON goods.id=line.goods_id LEFT JOIN colors color ON color.id=line.color_id
                JOIN units unit ON unit.id=line.unit_id JOIN warehouses warehouse ON warehouse.id=line.warehouse_id WHERE line.request_id=:id ORDER BY goods.code,line.id
                """).setParameter("id",id)).stream().map(line->new Item((UUID)line[0],(UUID)line[1],(UUID)line[2],(String)line[3],(String)line[4],(UUID)line[5],(String)line[6],(UUID)line[7],(String)line[8],(UUID)line[9],(String)line[10],decimal(line[11]))).toList();
        List<UUID> docs=NativeQueryResults.typedRows(em.createNativeQuery("SELECT DISTINCT mapping.document_id FROM production_material_discovery_lines line JOIN production_planning_package_document_items mapping ON mapping.demand_id=line.demand_id AND mapping.document_type='DRAW' WHERE line.request_id=:id ORDER BY mapping.document_id").setParameter("id",id),UUID.class);
        return new Detail((UUID)r[0],(UUID)r[1],(String)r[2],(String)r[3],(String)r[4],(String)r[5],decimal(r[6]),(String)r[7],(String)r[8],(String)r[9],((Number)r[10]).longValue(),items,docs);
    }
    public PageResponse<Detail> list(String status,int page,int size) {
        requireWarehouse(false);String filter=status==null?"PENDING":status;
        if(!List.of("PENDING","CONFIGURED","CANCELLED").contains(filter))throw validation("申请状态无效");
        int p=Math.max(1,page),s=Math.max(1,Math.min(100,size));
        String predicate=" FROM production_material_discovery_requests request JOIN production_execution_segments segment ON segment.id=request.execution_segment_id JOIN production_plans plan ON plan.id=segment.plan_id WHERE request.status=:status AND NOT segment.is_deleted AND segment.status NOT IN('CANCELLED','REVERSED') AND NOT plan.is_deleted AND NOT plan.is_canceled AND NOT plan.is_closed";
        long total=((Number)em.createNativeQuery("SELECT count(*)"+predicate).setParameter("status",filter).getSingleResult()).longValue();
        List<UUID> ids=NativeQueryResults.typedRows(em.createNativeQuery("SELECT request.id"+predicate+" ORDER BY request.created_at,request.id LIMIT :size OFFSET :offset").setParameter("status",filter).setParameter("size",s).setParameter("offset",(long)(p-1)*s),UUID.class);
        return new PageResponse<>(ids.stream().map(this::detail).toList(),p,s,total,(int)((total+s-1)/s));
    }
    private Segment segment(UUID id,boolean lock) {
        List<Object[]> rows=rows("""
                SELECT segment.id,segment.plan_id,segment.package_id,package.warehouse_id,segment.source_plan_item_id,
                       segment.workshop_department_id,segment.responsible_employee_id,plan.maker_id,segment.lock_version,
                       COALESCE(segment.material_snapshot_product_qty,segment.planned_qty),segment.material_discovery_required,
                       (segment.material_discovery_required AND segment.material_requirement_mode='ZERO_MATERIAL'
                        AND segment.zero_material_reason='DIRECT_MAKE' AND segment.status IN('READY','DISPATCHED')
                        AND NOT segment.is_deleted AND plan.status=1 AND NOT plan.is_deleted AND NOT plan.is_closed
                        AND NOT plan.is_canceled AND NOT plan.is_stopped AND package.status='CONFIRMED' AND NOT package.is_deleted
                        AND NOT EXISTS(SELECT 1 FROM production_daily_report_items report WHERE report.execution_segment_id=segment.id))
                FROM production_execution_segments segment JOIN production_plans plan ON plan.id=segment.plan_id
                JOIN production_planning_packages package ON package.id=segment.package_id WHERE segment.id=:id
                """+(lock?" FOR UPDATE OF segment":""),id);
        if(rows.isEmpty())throw notFound();Object[] r=rows.getFirst();return new Segment((UUID)r[0],(UUID)r[1],(UUID)r[2],(UUID)r[3],(UUID)r[4],(UUID)r[5],(UUID)r[6],(UUID)r[7],((Number)r[8]).longValue(),decimal(r[9]),Boolean.TRUE.equals(r[10]),Boolean.TRUE.equals(r[11]));
    }
    private void validateMaterial(Segment segment,Material item) {
        boolean valid=Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT EXISTS(SELECT 1 FROM goods JOIN warehouses warehouse ON warehouse.id=:warehouse
                    JOIN units unit ON unit.id=goods.unit_id AND NOT unit.is_deleted
                    WHERE goods.id=:goods AND NOT goods.is_deleted AND goods.unit_id=:unit
                      AND goods.id<>(SELECT product_goods_id FROM production_execution_segments WHERE id=:segment)
                      AND NOT warehouse.is_deleted AND warehouse.is_accountable AND NOT warehouse.is_defective
                      AND warehouse.status='使用' AND NOT COALESCE(warehouse.is_line_side,FALSE)
                      AND fn_warehouse_same_main(warehouse.id,:logical)
                      AND NOT EXISTS(SELECT 1 FROM warehouses child WHERE child.parent_id=warehouse.id AND NOT child.is_deleted)
                      AND (CAST(:color AS uuid) IS NULL OR EXISTS(SELECT 1 FROM colors WHERE id=:color AND NOT is_deleted)))
                """).setParameter("warehouse",item.warehouseId()).setParameter("goods",item.goodsId()).setParameter("unit",item.unitId()).setParameter("segment",segment.id()).setParameter("logical",segment.warehouse()).setParameter("color",item.colorId()).getSingleResult());
        if(!valid)throw validation("物料、颜色、基本单位或实际仓库无效；必须选择同主仓下的普通实际叶仓");
        if(Boolean.TRUE.equals(em.createNativeQuery("""
                WITH RECURSIVE descendants(id) AS (
                    SELECT CAST(:goods AS uuid)
                    UNION SELECT bom.component_goods_id
                    FROM descendants JOIN goods_bom_items bom ON bom.goods_id=descendants.id AND NOT bom.is_deleted)
                SELECT EXISTS(SELECT 1 FROM descendants WHERE id=(SELECT product_goods_id FROM production_execution_segments WHERE id=:segment))
                """).setParameter("goods",item.goodsId()).setParameter("segment",segment.id()).getSingleResult()))throw validation("此材料会形成组件结构循环，请核对所领物料");
    }
    static List<Material> normalize(List<Material> items) {
        if(items==null||items.isEmpty()||items.size()>100)throw validation("请填写1至100种实际物料");
        Set<String> keys=new HashSet<>();for(Material item:items) {
            if(item==null||item.goodsId()==null||item.unitId()==null||item.warehouseId()==null)throw validation("物料、基本单位和实际仓库必填");
            ProductionMaterialIncrementService.quantity(item.qty());
            if(!keys.add(dimension(item)+":"+item.warehouseId()))throw validation("同一实际仓库的相同物料颜色请合并为一行");
        }
        return items.stream().sorted(Comparator.comparing(Material::goodsId).thenComparing(item->Objects.toString(item.colorId(),"")).thenComparing(Material::warehouseId)).toList();
    }
    private static String dimension(Material item){return item.goodsId()+":"+Objects.toString(item.colorId(),"");}
    private void requireWorkshop(Segment segment,boolean write) {
        membership.requireActiveOperator();if(!access.hasAuthority("production_execution:view")||(write&&!access.hasAuthority("production_execution:start")))throw new ApiException(ErrorCode.FORBIDDEN,"缺少车间领料权限");
        if(!membership.isWorkshopMember(segment.workshop(),segment.responsible(),currentUser.employeeId().orElse(null)))
            access.requireScopedOperationWritable(segment.maker(),"无权办理此车间任务",write?"production_execution:start":"production_execution:view");
    }
    private void requireWarehouse(boolean write) {
        membership.requireActiveOperator();warehouseAccess.requireWarehouseTaskAccess("只有仓库岗位可以登记实际领料");
        if(!access.hasAuthority("stock_doc:view")||(write&&(!access.hasAuthority("stock_doc:approve")||!access.hasAuthority("stock_doc:issue"))))throw new ApiException(ErrorCode.FORBIDDEN,"缺少仓库领料办理权限");
    }
    private Object[] requestRow(UUID id,boolean lock) {return rows("SELECT status,row_version,configuration_key,configuration_hash,cancelled_by,cancellation_key,configured_by,expected_version FROM production_material_discovery_requests WHERE id=:id"+(lock?" FOR UPDATE":""),id).getFirst();}
    private List<Object[]> rows(String sql,UUID id){return NativeQueryResults.objectArrayRows(em.createNativeQuery(sql).setParameter("id",id));}
    private void bump(UUID id){em.createNativeQuery("UPDATE production_execution_segments SET lock_version=lock_version+1,updated_at=now(),updated_by=:actor WHERE id=:id").setParameter("id",id).setParameter("actor",currentUser.requireId()).executeUpdate();}
    private void lockCommand(String key){em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,710))").setParameter("key",currentUser.requireId()+":"+key).getSingleResult();}
    private void publish(UUID id,String state){events.publishOnce("PRODUCTION_MATERIAL_DISCOVERY_"+state,"PRODUCTION_MATERIAL_DISCOVERY_REQUEST",id,Map.of(),"MATERIAL_DISCOVERY:"+id+":"+state);}
    private static void validate(Request command){if(command==null||command.expectedVersion()==null||command.expectedVersion()<0)throw validation("申请缺少有效版本");ProductionMaterialIncrementService.key(command.idempotencyKey());}
    private static String hash(List<String> values){return CanonicalFingerprint.sha256(values);}
    private static BigDecimal decimal(Object value){return new BigDecimal(value.toString());}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private static ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException notFound(){return new ApiException(ErrorCode.NOT_FOUND,"领料申请或任务不存在或不可见");}
    private record Segment(UUID id,UUID plan,UUID pack,UUID warehouse,UUID source,UUID workshop,UUID responsible,UUID maker,long version,BigDecimal output,boolean discovery,boolean eligible) {}
}
