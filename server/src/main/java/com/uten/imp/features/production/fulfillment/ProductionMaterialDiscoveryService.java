package com.uten.imp.features.production.fulfillment;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
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
    private final ObjectMapper mapper;
    private final DocNumberService numbers;

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
        List<RequestedMaterial> requestedItems=normalizeRequested(command.items());
        String hash=requestHash(segmentId,command.expectedVersion(),requestedItems);
        lockCommand(command.idempotencyKey());
        List<Object[]> replay=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT id,request_hash FROM production_material_discovery_requests WHERE created_by=:actor AND idempotency_key=:key")
                .setParameter("actor",currentUser.requireId()).setParameter("key",command.idempotencyKey()));
        if(!replay.isEmpty()){if(!hash.equals(replay.getFirst()[1]))throw conflict("幂等键已用于另一项领料申请");return detail((UUID)replay.getFirst()[0]);}
        var footprint=footprints.beginPlan(discovered.plan(),List.of());Segment segment=segment(segmentId,true);footprint.verifyUnchanged();requireWorkshop(segment,true);
        requireDiscoveryRoute(segment);
        if(!segment.eligible()||segment.version()!=command.expectedVersion())throw conflict("任务已变化，请刷新后重新申请");
        if(!Boolean.TRUE.equals(em.createNativeQuery("SELECT start_route IN('FULL_KIT','CONTINUOUS') FROM production_execution_segments WHERE id=:id").setParameter("id",segmentId).getSingleResult()))
            throw conflict("实际物料尚未确定，请先选择齐套或持续生产路线再申请领料");
        if(Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT EXISTS(SELECT 1 FROM production_material_discovery_requests
                    WHERE execution_segment_id=:id AND status<>'CANCELLED')
                """).setParameter("id",segmentId).getSingleResult()))
            throw conflict("此任务已提交领料，请查看仓库处理进度");
        List<SuggestedItem> suggestions=requestedItems.stream().map(item->suggestion(segment,item)).toList();
        UUID id=UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO production_material_discovery_requests(id,execution_segment_id,expected_version,created_by,idempotency_key,request_hash,requested_materials,request_no)
                VALUES(:id,:segment,:version,:actor,:key,:hash,CAST(:materials AS jsonb),:number)
                """).setParameter("id",id).setParameter("segment",segmentId).setParameter("version",segment.version())
                .setParameter("actor",currentUser.requireId()).setParameter("key",command.idempotencyKey()).setParameter("hash",hash)
                .setParameter("materials",mapper.valueToTree(suggestions).toString())
                .setParameter("number",numbers.nextNumber(DocNumberPrefix.PRODUCTION_MATERIAL_REQUEST)).executeUpdate();
        bump(segmentId);publish(id,"PENDING");return detail(id);
    }

    @Transactional public Detail cancel(UUID id,Request command) {
        validate(command);
        if(command.items()!=null&&!command.items().isEmpty())throw validation("撤回申请不接受物料明细");
        tx.bind();Detail discovered=detail(id);Segment before=segment(discovered.segmentId(),false);requireWorkshop(before,true);
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
        requireDiscoveryRoute(segment);
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
                       unit.name,department.name,request.status,request.row_version,request.request_no
                FROM production_material_discovery_requests request JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
                JOIN production_plans plan ON plan.id=segment.plan_id JOIN goods ON goods.id=segment.product_goods_id
                LEFT JOIN units unit ON unit.id=segment.product_unit_id LEFT JOIN departments department ON department.id=segment.workshop_department_id
                WHERE request.id=:id
                """,id);
        if(rows.isEmpty())throw notFound();Object[] r=rows.getFirst();
        if(!(access.hasAuthority("stock_doc:view")&&warehouseAccess.canAccessWarehouseTasks()))requireWorkshop(segment((UUID)r[1],false),false);
        List<Item> items=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT line.id,line.demand_id,line.goods_id,goods.code,goods.name,line.color_id,color.name,line.unit_id,unit.name,line.warehouse_id,warehouse.name,line.qty,
                       goods.spec,goods.stock_place
                FROM production_material_discovery_lines line JOIN goods ON goods.id=line.goods_id LEFT JOIN colors color ON color.id=line.color_id
                JOIN units unit ON unit.id=line.unit_id JOIN warehouses warehouse ON warehouse.id=line.warehouse_id WHERE line.request_id=:id ORDER BY goods.code,line.id
                """).setParameter("id",id)).stream().map(line->new Item((UUID)line[0],(UUID)line[1],(UUID)line[2],(String)line[3],(String)line[4],(UUID)line[5],(String)line[6],(UUID)line[7],(String)line[8],(UUID)line[9],(String)line[10],decimal(line[11]),(String)line[12],(String)line[13])).toList();
        List<DrawDocument> documents=rows("""
                SELECT DISTINCT document.id,document.bill_no,document.warehouse_id,warehouse.name
                FROM production_material_discovery_lines line
                JOIN production_planning_package_document_items mapping ON mapping.demand_id=line.demand_id AND mapping.document_type='DRAW'
                JOIN stock_documents document ON document.id=mapping.document_id
                LEFT JOIN warehouses warehouse ON warehouse.id=document.warehouse_id
                WHERE line.request_id=:id ORDER BY document.id
                """,id).stream().map(row->new DrawDocument((UUID)row[0],(String)row[1],(UUID)row[2],(String)row[3])).toList();
        List<UUID> docs=documents.stream().map(DrawDocument::id).toList();
        List<SuggestedItem> suggestions=rows("""
                SELECT item."goodsId",item."goodsCode",item."goodsName",item."colorId",item."colorName",item."unitId",item."unitName",item.qty,item.spec,item."stockPlace"
                FROM production_material_discovery_requests request
                CROSS JOIN LATERAL jsonb_to_recordset(request.requested_materials) AS item(
                    "goodsId" uuid,"goodsCode" text,"goodsName" text,"colorId" uuid,"colorName" text,"unitId" uuid,"unitName" text,qty numeric,spec text,"stockPlace" text)
                WHERE request.id=:id ORDER BY item."goodsId",item."colorId" NULLS FIRST
                """,id).stream().map(item->new SuggestedItem((UUID)item[0],(String)item[1],(String)item[2],(UUID)item[3],(String)item[4],(UUID)item[5],(String)item[6],item[7]==null?null:decimal(item[7]),(String)item[8],(String)item[9])).toList();
        return new Detail((UUID)r[0],(UUID)r[1],(String)r[2],(String)r[3],(String)r[4],(String)r[5],decimal(r[6]),(String)r[7],(String)r[8],(String)r[9],((Number)r[10]).longValue(),items,docs,suggestions,(String)r[11],documents);
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
                       COALESCE(segment.material_snapshot_product_qty,segment.planned_qty),fn_material_discovery_pending(segment.id),
                       (fn_material_discovery_pending(segment.id) AND segment.material_requirement_mode='ZERO_MATERIAL'
                        AND segment.zero_material_reason='DIRECT_MAKE' AND segment.status IN('READY','DISPATCHED')
                        AND NOT (%s)
                        AND NOT segment.is_deleted AND plan.status=1 AND NOT plan.is_deleted AND NOT plan.is_closed
                        AND NOT plan.is_canceled AND NOT plan.is_stopped AND package.status='CONFIRMED' AND NOT package.is_deleted
                        AND NOT EXISTS(SELECT 1 FROM production_daily_report_items report WHERE report.execution_segment_id=segment.id)),
                       fn_segment_bin_material_state(segment.id)
                FROM production_execution_segments segment JOIN production_plans plan ON plan.id=segment.plan_id
                JOIN production_planning_packages package ON package.id=segment.package_id WHERE segment.id=:id
                """.formatted(ProductionOrderMaterialGate.unresolvedSql("segment.id"))+(lock?" FOR UPDATE OF segment":""),id);
        if(rows.isEmpty())throw notFound();Object[] r=rows.getFirst();return new Segment((UUID)r[0],(UUID)r[1],(UUID)r[2],(UUID)r[3],(UUID)r[4],(UUID)r[5],(UUID)r[6],(UUID)r[7],((Number)r[8]).longValue(),decimal(r[9]),Boolean.TRUE.equals(r[10]),Boolean.TRUE.equals(r[11]),(String)r[12]);
    }

    private void requireDiscoveryRoute(Segment segment) {
        ProductionOrderMaterialGate.requireResolved(segment.binMaterialState());
        if (!segment.discovery()) {
            throw conflict("任务已不需要按工单登记材料；如有未办理的原领料申请，请车间撤回后按当前用料方式开工");
        }
    }
    private void validateMaterial(Segment segment,Material item) {
        validateMaterialIdentity(segment,item.goodsId(),item.colorId(),item.unitId());
        boolean valid=Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT EXISTS(SELECT 1 FROM warehouses warehouse WHERE warehouse.id=:warehouse
                      AND NOT warehouse.is_deleted AND warehouse.is_accountable AND NOT warehouse.is_defective
                      AND warehouse.status='使用' AND NOT COALESCE(warehouse.is_line_side,FALSE)
                      AND fn_warehouse_same_main(warehouse.id,:logical)
                      AND fn_warehouse_is_operational_leaf(warehouse.id))
                """).setParameter("warehouse",item.warehouseId()).setParameter("logical",segment.warehouse()).getSingleResult());
        if(!valid)throw validation("实际仓库无效；必须选择同主仓下的普通实际叶仓");
    }
    private void validateMaterialIdentity(Segment segment,UUID goodsId,UUID colorId,UUID unitId) {
        boolean valid=Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT EXISTS(SELECT 1 FROM goods JOIN units unit ON unit.id=goods.unit_id AND NOT unit.is_deleted
                    WHERE goods.id=:goods AND NOT goods.is_deleted AND goods.unit_id=:unit
                      AND goods.id<>(SELECT product_goods_id FROM production_execution_segments WHERE id=:segment)
                      AND (CAST(:color AS uuid) IS NULL OR EXISTS(SELECT 1 FROM colors WHERE id=:color AND NOT is_deleted)))
                """).setParameter("goods",goodsId).setParameter("unit",unitId).setParameter("segment",segment.id()).setParameter("color",colorId).getSingleResult());
        if(!valid)throw validation("物料、颜色或基本单位无效，请重新选择实际材料");
        requireOrderIssuedMaterial(goodsId);
        if(Boolean.TRUE.equals(em.createNativeQuery("""
                WITH RECURSIVE descendants(id) AS (
                    SELECT CAST(:goods AS uuid)
                    UNION SELECT bom.component_goods_id
                    FROM descendants JOIN goods_bom_items bom ON bom.goods_id=descendants.id AND NOT bom.is_deleted)
                SELECT EXISTS(SELECT 1 FROM descendants WHERE id=(SELECT product_goods_id FROM production_execution_segments WHERE id=:segment))
                """).setParameter("goods",goodsId).setParameter("segment",segment.id()).getSingleResult()))throw validation("此材料会形成组件结构循环，请核对所领物料");
    }
    /**
     * ADR-131：整批领到车间内料仓的料不按工单领(车间申请时与仓库登记时各拦一次，数据库全局守卫兜底)。
     * 认料勾了「还要按工单领别的料」的产品照常走领料发现，只能登记非整批领料的料(例如嵌件)。
     */
    private void requireOrderIssuedMaterial(UUID goodsId) {
        List<Object[]> periodic=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT goods.name,goods.code FROM goods WHERE goods.id=:goods AND goods.issue_method='PERIODIC'
                """).setParameter("goods",goodsId));
        if(periodic.isEmpty())return;
        Object[] row=periodic.getFirst();
        String name=row[0]==null||row[0].toString().isBlank()?Objects.toString(row[1],"这种料"):row[0].toString();
        throw validation("「"+name+"」已整批放在车间内料仓, 不用按工单领; 请在开工确认表里认料");
    }
    private SuggestedItem suggestion(Segment segment,RequestedMaterial item) {
        validateMaterialIdentity(segment,item.goodsId(),item.colorId(),item.unitId());
        List<Object[]> available=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT goods.code,goods.name,color.name,unit.name,goods.spec,goods.stock_place FROM goods JOIN units unit ON unit.id=goods.unit_id
                LEFT JOIN colors color ON color.id=:color WHERE goods.id=:goods
                  AND NOT goods.auto_created AND goods.status IS DISTINCT FROM '禁用'
                  AND unit.status IS DISTINCT FROM '禁用' AND color.status IS DISTINCT FROM '禁用'
                """).setParameter("goods",item.goodsId()).setParameter("color",item.colorId()));
        if(available.isEmpty())throw validation("请选择可用的货品、颜色和基本单位，不能使用停用或系统占位主档");
        Object[] row=available.getFirst();
        return new SuggestedItem(item.goodsId(),(String)row[0],(String)row[1],item.colorId(),(String)row[2],item.unitId(),(String)row[3],item.qty(),(String)row[4],(String)row[5]);
    }
    static List<RequestedMaterial> normalizeRequested(List<RequestedMaterial> items) {
        if(items==null||items.isEmpty())return List.of();
        if(items.size()>100)throw validation("提前填写的实际材料最多100行");
        Set<String> keys=new HashSet<>();
        for(RequestedMaterial item:items) {
            if(item==null||item.goodsId()==null||item.unitId()==null)throw validation("已选择的材料必须填写货品和基本单位");
            if(item.qty()!=null)ProductionMaterialIncrementService.quantity(item.qty());
            if(!keys.add(item.goodsId()+":"+Objects.toString(item.colorId(),"")))throw validation("相同物料颜色请合并为一行");
        }
        return items.stream().sorted(Comparator.comparing(RequestedMaterial::goodsId)
                .thenComparing(item->Objects.toString(item.colorId(),""))).toList();
    }
    static String requestHash(UUID segmentId,long expectedVersion,List<RequestedMaterial> items) {
        // Preserve hashes of requests created before workshop suggestions were supported.
        List<String> parts=new ArrayList<>(List.of("DISCOVERY-REQUEST",segmentId.toString(),Long.toString(expectedVersion)));
        for(RequestedMaterial item:items)parts.add("MATERIAL:"+item.goodsId()+"|"+Objects.toString(item.colorId(),"")+"|"
                +item.unitId()+"|"+(item.qty()==null?"UNSPECIFIED":item.qty().stripTrailingZeros().toPlainString()));
        return hash(parts);
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
    // Batch orchestrators take these same command locks before their complete inventory prefix.
    void lockCommand(String key){em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,710))").setParameter("key",currentUser.requireId()+":"+key).getSingleResult();}
    private void publish(UUID id,String state){events.publishOnce("PRODUCTION_MATERIAL_DISCOVERY_"+state,"PRODUCTION_MATERIAL_DISCOVERY_REQUEST",id,Map.of(),"MATERIAL_DISCOVERY:"+id+":"+state);}
    private static void validate(Request command){if(command==null||command.expectedVersion()==null||command.expectedVersion()<0)throw validation("申请缺少有效版本");ProductionMaterialIncrementService.key(command.idempotencyKey());}
    private static String hash(List<String> values){return CanonicalFingerprint.sha256(values);}
    private static BigDecimal decimal(Object value){return new BigDecimal(value.toString());}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private static ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException notFound(){return new ApiException(ErrorCode.NOT_FOUND,"领料申请或任务不存在或不可见");}
    private record Segment(UUID id,UUID plan,UUID pack,UUID warehouse,UUID source,UUID workshop,UUID responsible,UUID maker,long version,BigDecimal output,boolean discovery,boolean eligible,String binMaterialState) {}
}
