package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.features.stock.*;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

import static com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest.*;

/** Workshop authority for surplus return intent, preserving the original warehouse and unit. */
@Service
@RequiredArgsConstructor
public class ProductionMaterialReturnRequestService {
    private final EntityManager em;
    private final ProductionMaterialTaskAccessPolicy access;
    private final ProductionStockTaskAccessPolicy warehouseAccess;
    private final SecurityContextCurrentUser user;
    private final TxSessionVars tx;
    private final StockDocumentRepository documents;
    private final StockDocumentItemRepository documentItems;
    private final DocNumberService numbers;

    @Transactional(readOnly = true)
    public List<Source> sources(UUID planId, UUID segmentId) {
        requireSegment(segmentId);
        access.readable(planId, segmentId);
        return readSources(planId, segmentId);
    }

    private List<Source> readSources(UUID planId, UUID segmentId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT issue.id,demand.id,draw.id,draw.bill_no,item.id,
                       draw.warehouse_id,warehouse.name,item.goods_id,
                       item.goods_code_snapshot,item.goods_name_snapshot,item.color_id,color.name,
                       item.unit_id,unit.name,item.unit_rate,issue.qty_base,
                       fn_material_issue_unsettled(issue.id),fn_material_issue_pending_return(issue.id,NULL),
                       fn_material_issue_available(issue.id,NULL),fn_issue_committed_to_later_batch(issue.id),segment.status
                FROM production_material_stock_postings issue
                JOIN production_material_demands demand ON demand.id=issue.demand_id
                JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id AND NOT segment.is_deleted
                JOIN stock_document_items item ON item.id=issue.stock_document_item_id AND NOT item.is_deleted
                JOIN stock_documents draw ON draw.id=item.doc_id AND draw.doc_type='DRAW' AND draw.status=1 AND NOT draw.is_deleted
                LEFT JOIN warehouses warehouse ON warehouse.id=draw.warehouse_id
                LEFT JOIN colors color ON color.id=item.color_id
                LEFT JOIN units unit ON unit.id=item.unit_id
                WHERE issue.posting_type='ISSUE' AND demand.plan_id=:planId
                  AND demand.execution_segment_id=:segmentId AND NOT demand.is_deleted
                  AND demand.status NOT IN ('RELEASED','REVERSED')
                  AND item.unit_rate>0 AND fn_material_issue_unsettled(issue.id)>0
                ORDER BY draw.warehouse_id,draw.id,item.id,issue.created_at,issue.id
                """).setParameter("planId", planId).setParameter("segmentId", segmentId));
        return rows.stream().map(row -> {
            BigDecimal rate = decimal(row[14]);
            boolean committedToLaterBatch = Boolean.TRUE.equals(row[19]);
            boolean hasStarted = List.of("IN_PROGRESS","COMPLETED").contains(str(row[20]));
            String blockedReason = !hasStarted
                    ? "任务尚未开工，退回已领物料请由仓库办理取消出库；开工后可登记余料退仓"
                    : committedToLaterBatch ? "此物料已被后续生产批次承接，请先保留后续批次用料" : null;
            return new Source(uuid(row[0]),uuid(row[1]),uuid(row[2]),str(row[3]),uuid(row[4]),uuid(row[5]),
                    str(row[6]),uuid(row[7]),str(row[8]),str(row[9]),uuid(row[10]),str(row[11]),uuid(row[12]),
                    str(row[13]),rate,inUnit(row[15],rate),inUnit(row[16],rate),inUnit(row[17],rate),
                    blockedReason != null ? BigDecimal.ZERO : inUnit(row[18],rate),blockedReason);
        }).toList();
    }

    @Transactional
    public List<Document> submit(UUID planId, Submit request) {
        if (request == null) throw validation("请填写退料请求");
        requireSegment(request.executionSegmentId());
        String key = key(request.idempotencyKey()), reason = reason(request.reason());
        List<Item> items = normalize(request.items());
        tx.bind();
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,560))")
                .setParameter("key",user.requireId()+":RETURN_REQUEST:"+key).getSingleResult();
        lockPlan(planId);
        List<UUID> demands = demandIds(items.stream().map(Item::issuePostingId).toList(), planId, request.executionSegmentId());
        access.requireDemandWrite(planId,demands,request.executionSegmentId(),"production_material:settle");
        String hash = hash(planId, request.executionSegmentId(), reason, items);
        List<Object[]> replay = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,request_hash FROM production_material_return_requests
                WHERE created_by=:actor AND idempotency_key=:key ORDER BY id
                """).setParameter("actor",user.requireId()).setParameter("key",key));
        if (!replay.isEmpty()) {
            if (replay.stream().anyMatch(row -> !hash.equals(row[1]))) throw conflict("相同幂等键对应不同退料申请");
            return readDocuments(replay.stream().map(row -> uuid(row[0])).toList());
        }
        lockDemandsAndIssues(demands, items.stream().map(Item::issuePostingId).toList());
        Map<UUID,Source> sources = new LinkedHashMap<>();
        readSources(planId,request.executionSegmentId()).forEach(source -> sources.put(source.issuePostingId(), source));
        Map<UUID,List<Item>> warehouses = new LinkedHashMap<>();
        for (Item item : items) {
            Source source = sources.get(item.issuePostingId());
            if (source != null && source.returnBlockedReason() != null) throw conflict(source.returnBlockedReason());
            if (source == null || item.qty().compareTo(source.availableQty())>0) {
                throw conflict("可退余料已变化或已提交待收料，请刷新后核对");
            }
            baseQty(item.qty(),source.unitRate());
            warehouses.computeIfAbsent(source.warehouseId(), ignored -> new ArrayList<>()).add(item);
        }
        Object[] plan = (Object[]) em.createNativeQuery("""
                SELECT plan.bill_no,segment.workshop_department_id,segment.responsible_employee_id
                FROM production_plans plan JOIN production_execution_segments segment ON segment.plan_id=plan.id
                WHERE plan.id=:planId AND segment.id=:segmentId
                """).setParameter("planId",planId).setParameter("segmentId",request.executionSegmentId()).getSingleResult();
        List<UUID> created = new ArrayList<>();
        for (var warehouse : warehouses.entrySet()) {
            StockDocument document = new StockDocument();
            document.setDocType("WDRAW");
            document.setBillNo(numbers.nextNumber(DocNumberPrefix.STOCK_WDRAW));
            document.setBillDate(BusinessTime.today());
            document.setWarehouseId(warehouse.getKey());
            document.setDepartmentId(uuid(plan[1]));
            document.setWorkerId(user.requireEmployeeId());
            document.setMakerId(user.requireEmployeeId());
            document.setPlanNo(str(plan[0]));
            document.setSourceDocNo(str(plan[0]));
            document.setRemark(reason);
            document.setStatus((short)0);
            documents.saveAndFlush(document);
            em.createNativeQuery("""
                    INSERT INTO production_material_return_requests(id,plan_id,execution_segment_id,warehouse_id,
                      idempotency_key,request_hash,reason,created_by)
                    VALUES (:id,:planId,:segmentId,:warehouseId,:key,:hash,:reason,:actor)
                    """).setParameter("id",document.getId()).setParameter("planId",planId)
                    .setParameter("segmentId",request.executionSegmentId()).setParameter("warehouseId",warehouse.getKey())
                    .setParameter("key",key).setParameter("hash",hash).setParameter("reason",reason)
                    .setParameter("actor",user.requireId()).executeUpdate();
            int lineNo = 0;
            for (Item selected : warehouse.getValue()) {
                Source source = sources.get(selected.issuePostingId());
                StockDocumentItem original = documentItems.findById(source.drawItemId())
                        .orElseThrow(() -> conflict("原领料行不存在"));
                StockDocumentItem item = new StockDocumentItem();
                item.setDocId(document.getId());item.setBillType("WDRAW");item.setBillNo(document.getBillNo());
                item.setBillDate(document.getBillDate());item.setLineNo(++lineNo);
                item.setGoodsId(source.goodsId());item.setGoodsCodeSnapshot(original.getGoodsCodeSnapshot());
                item.setGoodsNameSnapshot(original.getGoodsNameSnapshot());item.setGoodsSnapshotSource(original.getGoodsSnapshotSource());
                item.setGoodsSnapshotLockedAt(original.getGoodsSnapshotLockedAt());item.setColorId(source.colorId());
                item.setUnitId(source.unitId());item.setUnitRate(source.unitRate());item.setQty(selected.qty());
                item.setBaseQty(baseQty(selected.qty(),source.unitRate()));item.setUpstreamItemId(source.drawItemId());
                item.setSourceDocNo(source.drawNo());
                documentItems.saveAndFlush(item);
                em.createNativeQuery("""
                        INSERT INTO production_material_return_request_items(request_id,stock_document_item_id,
                          issue_posting_id,qty_base,created_by) VALUES (:request,:item,:issue,:qty,:actor)
                        """).setParameter("request",document.getId()).setParameter("item",item.getId())
                        .setParameter("issue",source.issuePostingId()).setParameter("qty",item.getBaseQty())
                        .setParameter("actor",user.requireId()).executeUpdate();
            }
            em.createNativeQuery("INSERT INTO plan_draw_links(plan_id,draw_id,created_by) VALUES (:plan,:doc,:actor)")
                    .setParameter("plan",planId).setParameter("doc",document.getId()).setParameter("actor",user.requireId()).executeUpdate();
            created.add(document.getId());
        }
        return readDocuments(created);
    }

    @Transactional(readOnly = true)
    public List<Document> list(UUID planId, UUID segmentId) {
        requireSegment(segmentId);access.readable(planId,segmentId);
        List<UUID> ids = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT id FROM production_material_return_requests WHERE plan_id=:plan AND execution_segment_id=:segment
                ORDER BY created_at DESC,id DESC
                """,UUID.class).setParameter("plan",planId).setParameter("segment",segmentId),UUID.class);
        return ids.isEmpty()?List.of():readDocuments(ids);
    }

    @Transactional
    public Document cancel(UUID planId, UUID documentId, Cancel request) {
        if (request==null) throw validation("请填写取消原因");
        String key=key(request.idempotencyKey()),reason=reason(request.reason());
        tx.bind();lockPlan(planId);
        List<?> headers=em.createNativeQuery("SELECT execution_segment_id FROM production_material_return_requests WHERE id=:id AND plan_id=:plan")
                .setParameter("id",documentId).setParameter("plan",planId).getResultList();
        if(headers.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"退料申请不存在");
        UUID segmentId=uuid(headers.getFirst());
        List<UUID> issues=NativeQueryResults.typedRows(em.createNativeQuery("SELECT issue_posting_id FROM production_material_return_request_items WHERE request_id=:id ORDER BY issue_posting_id",UUID.class)
                .setParameter("id",documentId),UUID.class);
        List<UUID> demands=demandIds(issues,planId,segmentId);
        access.requireDemandWrite(planId,demands,segmentId,"production_material:settle");
        lockDemandsAndIssues(demands,issues);
        List<Object[]> replay=NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT idempotency_key,request_hash FROM production_material_return_request_cancellations WHERE request_id=:id")
                .setParameter("id",documentId));
        String hash=CanonicalFingerprint.sha256(List.of(documentId.toString(),reason));
        if(!replay.isEmpty()) {
            if(!key.equals(replay.getFirst()[0])||!hash.equals(replay.getFirst()[1]))throw conflict("退料申请已取消，请刷新");
            return readDocuments(List.of(documentId)).getFirst();
        }
        Object[] document=(Object[])em.createNativeQuery("SELECT status,is_deleted FROM stock_documents WHERE id=:id FOR UPDATE")
                .setParameter("id",documentId).getSingleResult();
        if(((Number)document[0]).intValue()!=0||Boolean.TRUE.equals(document[1]))throw conflict("仓库已收料或申请已变更，不能取消");
        em.createNativeQuery("""
                INSERT INTO production_material_return_request_cancellations(request_id,idempotency_key,request_hash,reason,created_by)
                VALUES (:id,:key,:hash,:reason,:actor)
                """).setParameter("id",documentId).setParameter("key",key).setParameter("hash",hash)
                .setParameter("reason",reason).setParameter("actor",user.requireId()).executeUpdate();
        em.createNativeQuery("SELECT set_config('app.production_stock_cleanup_doc_id',:id,true)").setParameter("id",documentId.toString()).getSingleResult();
        em.createNativeQuery("UPDATE stock_documents SET is_deleted=TRUE,deleted_at=now(),updated_at=now(),updated_by=:actor WHERE id=:id")
                .setParameter("actor",user.requireId()).setParameter("id",documentId).executeUpdate();
        return readDocuments(List.of(documentId)).getFirst();
    }

    @Transactional(readOnly=true)
    public long warehousePendingCount() {
        if(!warehouseAccess.canAccessWarehouseTasks())return 0;
        return ((Number)em.createNativeQuery("SELECT count(*) FROM production_material_return_requests request JOIN stock_documents document ON document.id=request.id WHERE document.status=0 AND NOT document.is_deleted").getSingleResult()).longValue();
    }

    private List<Document> readDocuments(List<UUID> ids) {
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT document.id,document.bill_no,document.warehouse_id,warehouse.name,
                  CASE WHEN cancellation.id IS NOT NULL THEN 'CANCELLED' WHEN document.status=1 THEN 'RECEIVED'
                       WHEN document.status=-1 THEN 'REVERSED' ELSE 'PENDING' END,
                  item.id,request_item.issue_posting_id,issue.demand_id,item.upstream_item_id,
                  item.goods_code_snapshot,item.goods_name_snapshot,color.name,unit.name,item.qty,item.base_qty
                FROM production_material_return_requests request JOIN stock_documents document ON document.id=request.id
                JOIN production_material_return_request_items request_item ON request_item.request_id=request.id
                JOIN stock_document_items item ON item.id=request_item.stock_document_item_id
                JOIN production_material_stock_postings issue ON issue.id=request_item.issue_posting_id
                LEFT JOIN warehouses warehouse ON warehouse.id=document.warehouse_id
                LEFT JOIN colors color ON color.id=item.color_id LEFT JOIN units unit ON unit.id=item.unit_id
                LEFT JOIN production_material_return_request_cancellations cancellation ON cancellation.request_id=request.id
                WHERE request.id IN (:ids) ORDER BY document.bill_no DESC,item.line_no,item.id
                """).setParameter("ids",ids));
        Map<UUID,List<Line>> lines=new LinkedHashMap<>();Map<UUID,Object[]> headers=new LinkedHashMap<>();
        for(Object[] row:rows){UUID id=uuid(row[0]);headers.putIfAbsent(id,row);
            lines.computeIfAbsent(id,ignored->new ArrayList<>()).add(new Line(uuid(row[5]),uuid(row[6]),uuid(row[7]),uuid(row[8]),
                    str(row[9]),str(row[10]),str(row[11]),str(row[12]),decimal(row[13]),decimal(row[14])));}
        return headers.entrySet().stream().map(entry->{Object[] row=entry.getValue();return new Document(entry.getKey(),str(row[1]),uuid(row[2]),str(row[3]),str(row[4]),List.copyOf(lines.get(entry.getKey())));}).toList();
    }
    private void lockPlan(UUID id){if(em.createNativeQuery("SELECT id FROM production_plans WHERE id=:id AND NOT is_deleted FOR UPDATE").setParameter("id",id).getResultList().isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"生产计划不存在");}
    private List<UUID> demandIds(List<UUID> issues,UUID plan,UUID segment){
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT issue.id,demand.id FROM production_material_stock_postings issue
                JOIN production_material_demands demand ON demand.id=issue.demand_id
                WHERE issue.id IN (:ids) AND issue.posting_type='ISSUE' AND demand.plan_id=:plan
                  AND demand.execution_segment_id=:segment AND NOT demand.is_deleted ORDER BY demand.id,issue.id
                """).setParameter("ids",issues).setParameter("plan",plan).setParameter("segment",segment));
        if(rows.size()!=issues.size())throw conflict("退料来源不属于当前车间任务");
        return rows.stream().map(row->uuid(row[1])).distinct().toList();
    }
    private void lockDemandsAndIssues(List<UUID> demands,List<UUID> issues){
        em.createNativeQuery("SELECT id FROM production_material_demands WHERE id IN (:ids) ORDER BY id FOR UPDATE").setParameter("ids",demands).getResultList();
        em.createNativeQuery("SELECT id FROM production_material_stock_postings WHERE id IN (:ids) ORDER BY id FOR UPDATE").setParameter("ids",issues).getResultList();
    }
    static List<Item> normalize(List<Item> items){
        if(items==null||items.isEmpty()||items.size()>200)throw validation("请选择1-200笔原领料余量");
        Map<UUID,Item> unique=new LinkedHashMap<>();for(Item item:items){
            if(item==null||item.issuePostingId()==null||item.qty()==null||item.qty().signum()<=0||item.qty().stripTrailingZeros().scale()>4)throw validation("退料数量必须大于零且最多4位小数");
            if(unique.putIfAbsent(item.issuePostingId(),item)!=null)throw validation("同一原领料来源不能重复选择");}
        return unique.values().stream().sorted(Comparator.comparing(Item::issuePostingId)).toList();
    }
    private static String hash(UUID plan,UUID segment,String reason,List<Item> items){List<String> parts=new ArrayList<>(List.of("MATERIAL-RETURN-V1",plan.toString(),segment.toString(),reason));items.forEach(item->parts.add(item.issuePostingId()+":"+item.qty().stripTrailingZeros().toPlainString()));return CanonicalFingerprint.sha256(parts);}
    private static BigDecimal baseQty(BigDecimal qty,BigDecimal rate){try{return qty.multiply(rate).setScale(4,RoundingMode.UNNECESSARY);}catch(ArithmeticException failure){throw validation("按原单位换算后的基本量超过4位小数，请调整退料数量");}}
    private static BigDecimal inUnit(Object qty,BigDecimal rate){return decimal(qty).divide(rate,4,RoundingMode.DOWN);}
    private static String key(String value){if(value==null||!value.matches("[A-Za-z0-9._:-]{8,128}"))throw validation("缺少有效幂等键");return value;}
    private static String reason(String value){if(value==null||value.strip().length()<2||value.strip().length()>500)throw validation("请填写2-500字的退料或取消原因");return value.strip();}
    private static void requireSegment(UUID id){if(id==null)throw validation("请选择准确车间任务");}
    private static UUID uuid(Object value){return value==null?null:(UUID)value;}
    private static String str(Object value){return value==null?null:value.toString();}
    private static BigDecimal decimal(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
