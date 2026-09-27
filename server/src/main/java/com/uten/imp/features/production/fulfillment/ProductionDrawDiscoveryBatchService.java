package com.uten.imp.features.production.fulfillment;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.stock.dto.StockDocIssueBatchResponse;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.*;
import static com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchContracts.*;
import static com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.Material;

/** One transaction owns material confirmation, ordinary DRAW issue, and the immutable batch result. */
@Service
@RequiredArgsConstructor
public class ProductionDrawDiscoveryBatchService {
    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionWorkshopMembership membership;
    private final ProductionStockTaskAccessPolicy warehouseAccess;
    private final ProductionMaterialDiscoveryService discovery;
    private final StockDocService stock;
    private final ProductionPlanMutationFootprintService plans;
    private final ProductionMutationFootprintPort stockFootprints;
    private final FulfillmentMutationLocks locks;
    private final ObjectMapper mapper;

    @Transactional
    public StockDocIssueBatchResponse issue(Request raw) {
        requireWarehouse();
        Request request=normalize(raw);
        tx.bind();
        UUID actor=currentUser.requireId();
        String hash=requestHash(request);
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,727))")
                .setParameter("key",actor+":"+request.idempotencyKey()).getSingleResult();
        List<Object[]> previous=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT request_hash,response_snapshot::text FROM production_draw_issue_batches
                WHERE actor_user_id=:actor AND idempotency_key=:key
                """).setParameter("actor",actor).setParameter("key",request.idempotencyKey()));
        if(!previous.isEmpty()) {
            if(!hash.equals(previous.getFirst()[0]))throw conflict("相同批量键对应不同领料内容，请重新核对");
            var saved=readResponse((String)previous.getFirst()[1]);
            return new StockDocIssueBatchResponse(0,saved.skippedCount(),saved.issuedCount()+saved.replayedCount(),true,List.of());
        }
        // Child issue commands belong to this server-created execution. A caller of
        // the legacy batch API cannot preoccupy them using a predictable client key.
        UUID batchId=UUID.randomUUID();
        request.discoveries().stream().map(item->configurationKey(actor,request.idempotencyKey(),item.requestId()))
                .sorted().forEach(discovery::lockCommand);

        Map<UUID,UUID> discoveryPlans=new LinkedHashMap<>();
        for(Discovery command:request.discoveries()) {
            var pending=discovery.detail(command.requestId());
            if(!"PENDING".equals(pending.status())||pending.version()!=command.expectedVersion())
                throw conflict("领料申请已变化，请刷新后重新核对");
            if(pending.suggestedItems().isEmpty())throw validation("尚未确定材料的申请，请先在填写实际领料页面选料");
            Set<String> suggested=new HashSet<>();
            pending.suggestedItems().forEach(item->suggested.add(identity(item.goodsId(),item.colorId(),item.unitId())));
            Set<String> supplied=new HashSet<>();
            command.items().forEach(item->supplied.add(identity(item.goodsId(),item.colorId(),item.unitId())));
            if(!suggested.equals(supplied))throw validation("批量出库须保留申请中已选的全部材料、颜色和基本单位；改料请回实际领料页面办理");
            discoveryPlans.put(command.requestId(),(UUID)em.createNativeQuery("SELECT plan_id FROM production_execution_segments WHERE id=:id")
                    .setParameter("id",pending.segmentId()).getSingleResult());
        }
        Set<UUID> planIds=new HashSet<>(discoveryPlans.values());
        if(!request.docIds().isEmpty())planIds.addAll(NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT DISTINCT plan.id FROM plan_draw_links link
                JOIN production_plans plan ON plan.id=link.plan_id AND NOT plan.is_deleted
                WHERE link.draw_id IN(:ids) AND NOT link.is_deleted
                """).setParameter("ids",request.docIds()),UUID.class));
        // Freeze the union before any child command acquires inventory/plan locks or writes.
        var guard=locks.acquire(()->{
            List<FulfillmentMutationLockPlan> parts=new ArrayList<>();
            if(!planIds.isEmpty())parts.add(plans.discoverPlans(planIds));
            if(!request.docIds().isEmpty())parts.add(stockFootprints.forStockDocuments(request.docIds()));
            for(Discovery command:request.discoveries())parts.add(plans.discover(discoveryPlans.get(command.requestId()),
                    command.items().stream().map(item->new ProductionPlanMutationFootprintService.RequestedLine(item.goodsId(),item.colorId(),null)).toList()));
            return FulfillmentMutationLockPlan.merge(CanonicalFingerprint.sha256(parts.stream().map(FulfillmentMutationLockPlan::fingerprint).toList()),parts);
        });
        // All plans, including existing DRAW plans, precede every newly configured request.
        if(!planIds.isEmpty())plans.beginPlans(planIds);
        if(!request.discoveries().isEmpty())em.createNativeQuery("""
                SELECT id FROM production_material_discovery_requests WHERE id IN(:ids) ORDER BY id FOR UPDATE
                """).setParameter("ids",request.discoveries().stream().map(Discovery::requestId).toList()).getResultList();
        guard.verifyUnchanged();

        Set<UUID> documentIds=new HashSet<>(request.docIds());
        for(Discovery command:request.discoveries()) {
            String childKey=configurationKey(actor,request.idempotencyKey(),command.requestId());
            var configured=discovery.configure(command.requestId(),new ProductionMaterialDiscoveryContracts.Configure(
                    command.expectedVersion(),childKey,command.items()));
            documentIds.addAll(configured.drawDocIds());
        }
        if(documentIds.size()>StockDocIssueBatchRequest.MAX_DOCUMENTS)
            throw validation("本批按实际仓生成的领料单超过50张，请减少所选任务或分批办理");
        var command=new StockDocIssueBatchRequest();
        command.setIdempotencyKey("DISCOVERY-BATCH:"+batchId);
        command.setDocIds(documentIds.stream().sorted(Comparator.comparing(UUID::toString)).toList());
        command.setReason(request.reason());
        var response=stock.issueFullBatch(command);
        // Freeze success only when every authorized remainder was actually issued.
        // A nested replay must never turn a still-unissued line into a successful batch.
        if(Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT EXISTS(SELECT 1 FROM stock_document_items item
                    WHERE item.doc_id IN(:ids) AND NOT item.is_deleted
                      AND fn_production_draw_item_requested_qty(item.id)>COALESCE(item.issued_qty,0))
                """).setParameter("ids",command.getDocIds()).getSingleResult()))
            throw conflict("本批仍有未实际出库的领料数量，整批未生效，请刷新后核对");
        em.createNativeQuery("""
                INSERT INTO production_draw_issue_batches(id,actor_user_id,actor_employee_id,idempotency_key,request_hash,
                    request_snapshot,response_snapshot,document_ids)
                VALUES(:id,:actor,:employee,:key,:hash,CAST(:request AS jsonb),CAST(:response AS jsonb),CAST(:documents AS uuid[]))
                """).setParameter("id",batchId).setParameter("actor",actor).setParameter("employee",currentUser.requireEmployeeId())
                .setParameter("key",request.idempotencyKey()).setParameter("hash",hash)
                .setParameter("request",mapper.valueToTree(request).toString()).setParameter("response",mapper.valueToTree(response).toString())
                .setParameter("documents","{"+String.join(",",command.getDocIds().stream().map(UUID::toString).toList())+"}").executeUpdate();
        return response;
    }

    static Request normalize(Request request) {
        if(request==null)throw validation("批量出库内容不能为空");
        String key=ProductionMaterialIncrementService.key(request.idempotencyKey());
        List<UUID> documents=request.docIds()==null?List.of():request.docIds();
        List<Discovery> discoveries=request.discoveries()==null?List.of():request.discoveries();
        if(documents.size()+discoveries.size()<1||documents.size()+discoveries.size()>50)
            throw validation("一次请选择1至50个领料任务");
        if(documents.stream().anyMatch(Objects::isNull)||new HashSet<>(documents).size()!=documents.size())throw validation("领料单不能缺少标识或重复选择");
        Set<UUID> ids=new HashSet<>();List<Discovery> normalized=new ArrayList<>();
        for(Discovery item:discoveries) {
            if(item==null||item.requestId()==null||item.expectedVersion()==null||item.expectedVersion()<0||!ids.add(item.requestId()))
                throw validation("材料申请缺少有效标识、版本或重复选择");
            normalized.add(new Discovery(item.requestId(),item.expectedVersion(),ProductionMaterialDiscoveryService.normalize(item.items())));
        }
        String reason=request.reason()==null||request.reason().isBlank()?null:request.reason().strip();
        if(reason!=null&&reason.length()>200)throw validation("统一备注最多200字");
        return new Request(key,documents.stream().sorted(Comparator.comparing(UUID::toString)).toList(),
                normalized.stream().sorted(Comparator.comparing(item->item.requestId().toString())).toList(),reason);
    }
    static String requestHash(Request request) {
        List<String> parts=new ArrayList<>(List.of("PRODUCTION-DRAW-DISCOVERY-BATCH-V1","reason:"+Objects.toString(request.reason(),"")));
        request.docIds().forEach(id->parts.add("DRAW:"+id));
        for(Discovery item:request.discoveries()) {
            parts.add("DISCOVERY:"+item.requestId()+":"+item.expectedVersion());
            for(Material material:item.items())parts.add(identity(material.goodsId(),material.colorId(),material.unitId())+":"
                    +material.warehouseId()+":"+material.qty().stripTrailingZeros().toPlainString());
        }
        return CanonicalFingerprint.sha256(parts);
    }
    private void requireWarehouse() {
        membership.requireActiveOperator();warehouseAccess.requireWarehouseTaskAccess("只有仓库岗位可以办理批量领料出库");
        if(!access.hasAuthority("stock_doc:view")||!access.hasAuthority("stock_doc:approve")||!access.hasAuthority("stock_doc:issue"))
            throw new ApiException(ErrorCode.FORBIDDEN,"批量领料须具备查看、审核和出库权限");
    }
    private StockDocIssueBatchResponse readResponse(String value) {
        try{return mapper.readValue(value,StockDocIssueBatchResponse.class);}
        catch(JsonProcessingException failure){throw new IllegalStateException("批量领料结果快照损坏",failure);}
    }
    private static String identity(UUID goods,UUID color,UUID unit){return goods+":"+Objects.toString(color,"")+":"+unit;}
    private static String configurationKey(UUID actor,String batchKey,UUID requestId){
        return "DISCOVERY-BATCH:"+CanonicalFingerprint.sha256(List.of(actor.toString(),batchKey,requestId.toString()));
    }
    private static ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
