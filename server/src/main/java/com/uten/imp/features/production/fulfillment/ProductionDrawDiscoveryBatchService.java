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
import com.uten.imp.features.stock.dto.WeightInput;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchContracts.*;
import static com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.Material;

/**
 * One transaction owns material confirmation, ordinary DRAW issue, and the immutable batch result.
 *
 * <p>称重(ADR-135 §3.6): 已有领料单的逐行重量按明细 id 传; 待确认材料的重量按(货品, 颜色, 实际仓)传,
 * 材料确认生成领料单后对到新明细, 与已有明细的重量一起交给批量出库。重量进本批请求哈希。
 */
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

    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ,
            propagation = org.springframework.transaction.annotation.Propagation.REQUIRES_NEW)
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('stock_doc:view')")
    public com.uten.imp.features.stock.dto.StockDocIssueBatchReadContracts.Resolution receipt(String rawKey) {
        String key = rawKey == null ? "" : rawKey.strip();
        if (!key.matches("[A-Za-z0-9._:-]{8,128}")) throw validation("批量出库的防重复提交标识格式不正确");
        var rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT request_hash, response_snapshot::text, array_to_json(document_ids)::text
                FROM production_draw_issue_batches WHERE actor_user_id=:actor AND idempotency_key=:key
                """).setParameter("actor", currentUser.requireId()).setParameter("key", key));
        if (rows.isEmpty()) return new com.uten.imp.features.stock.dto.StockDocIssueBatchReadContracts.Resolution(
                "UNKNOWN", key, null, List.of(), null);
        var row = rows.getFirst();
        List<UUID> ids = readDocumentIds((String) row[2]);
        stock.requireIssueBatchReceiptReadable(ids);
        return new com.uten.imp.features.stock.dto.StockDocIssueBatchReadContracts.Resolution(
                "COMMITTED", key, (String) row[0], ids, readResponse((String) row[1]));
    }

    /**
     * 逐个申请登记材料(各自复核仓库岗位)再整批出库: 循环体不改组织与负责关系, 整批共用一次仓库范围解析
     * (ADR-149 §2.1), 嵌套的批量出库沿用同一窗口。
     */
    @Transactional
    public StockDocIssueBatchResponse issue(Request raw) {
        return warehouseAccess.withScopeCache(() -> issueInOneScope(raw));
    }

    private StockDocIssueBatchResponse issueInOneScope(Request raw) {
        requireWarehouse();
        Request request=normalize(raw);
        tx.bind();
        UUID actor=currentUser.requireId();
        String hash=requestHash(request);
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,727))")
                .setParameter("key",actor+":"+request.idempotencyKey()).getSingleResult();
        List<Object[]> previous=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT request_hash,response_snapshot::text,array_to_json(document_ids)::text FROM production_draw_issue_batches
                WHERE actor_user_id=:actor AND idempotency_key=:key
                """).setParameter("actor",actor).setParameter("key",request.idempotencyKey()));
        if(!previous.isEmpty()) {
            if(!hash.equals(previous.getFirst()[0]))throw conflict("相同批量键对应不同领料内容，请重新核对");
            stock.requireIssueBatchReceiptReadable(readDocumentIds((String)previous.getFirst()[2]));
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
        List<StockDocIssueBatchRequest.ItemWeight> weights=new ArrayList<>(request.weights());
        for(Discovery command:request.discoveries()) {
            String childKey=configurationKey(actor,request.idempotencyKey(),command.requestId());
            var configured=discovery.configure(command.requestId(),new ProductionMaterialDiscoveryContracts.Configure(
                    command.expectedVersion(),childKey,command.items()));
            documentIds.addAll(configured.drawDocIds());
            weights.addAll(configuredItemWeights(command));
        }
        if(documentIds.size()>StockDocIssueBatchRequest.MAX_DOCUMENTS)
            throw validation("本批按实际仓生成的领料单超过50张，请减少所选任务或分批办理");
        var command=new StockDocIssueBatchRequest();
        command.setIdempotencyKey("DISCOVERY-BATCH:"+batchId);
        command.setDocIds(documentIds.stream().sorted(Comparator.comparing(UUID::toString)).toList());
        command.setReason(request.reason());
        command.setWeights(weights.isEmpty()?null:weights);
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
            List<Material> materials=ProductionMaterialDiscoveryService.normalize(item.items());
            normalized.add(new Discovery(item.requestId(),item.expectedVersion(),materials,
                    normalizeDiscoveryWeights(item.weights(),materials)));
        }
        String reason=request.reason()==null||request.reason().isBlank()?null:request.reason().strip();
        if(reason!=null&&reason.length()>200)throw validation("统一备注最多200字");
        return new Request(key,documents.stream().sorted(Comparator.comparing(UUID::toString)).toList(),
                normalized.stream().sorted(Comparator.comparing(item->item.requestId().toString())).toList(),reason,
                normalizeItemWeights(request.weights()));
    }
    static String requestHash(Request request) {
        List<String> parts=new ArrayList<>(List.of("PRODUCTION-DRAW-DISCOVERY-BATCH-V1","reason:"+Objects.toString(request.reason(),"")));
        request.docIds().forEach(id->parts.add("DRAW:"+id));
        for(Discovery item:request.discoveries()) {
            parts.add("DISCOVERY:"+item.requestId()+":"+item.expectedVersion());
            for(Material material:item.items())parts.add(identity(material.goodsId(),material.colorId(),material.unitId())+":"
                    +material.warehouseId()+":"+material.qty().stripTrailingZeros().toPlainString());
            // 称重只在填了时进哈希, 不带重量的请求哈希与原口径一致。
            for(IssueWeight weight:item.weights())parts.add("DISCOVERY-WEIGHT:"+item.requestId()+":"
                    +place(weight.goodsId(),weight.colorId(),weight.warehouseId())+":"+WeightInput.text(weight.weightKg())
                    +":"+Boolean.TRUE.equals(weight.qtyFromWeight()));
        }
        for(StockDocIssueBatchRequest.ItemWeight weight:request.weights())parts.add("WEIGHT:"+weight.itemId()+":"
                +WeightInput.text(weight.weightKg())+":"+Boolean.TRUE.equals(weight.qtyFromWeight()));
        return CanonicalFingerprint.sha256(parts);
    }

    /**
     * 待确认材料的称重: 千克规范化(0 = 没称), 既没重量也没「按称重推算」的丢弃; 每条必须对应本申请的一种实际材料
     * (货品 + 颜色 + 实际仓), 同一材料只能填一次。按货品、颜色、仓排序(进哈希)。
     */
    static List<IssueWeight> normalizeDiscoveryWeights(List<IssueWeight> raw,List<Material> materials) {
        if(raw==null||raw.isEmpty())return List.of();
        Set<String> known=new HashSet<>();
        materials.forEach(material->known.add(place(material.goodsId(),material.colorId(),material.warehouseId())));
        Set<String> seen=new HashSet<>();List<IssueWeight> normalized=new ArrayList<>();
        for(IssueWeight weight:raw) {
            if(weight==null||weight.goodsId()==null||weight.warehouseId()==null)throw validation("材料重量缺少货品或实际仓库");
            String place=place(weight.goodsId(),weight.colorId(),weight.warehouseId());
            if(!known.contains(place))throw validation("材料重量对应不到本次申请的实际材料，请刷新后重新填写");
            if(!seen.add(place))throw validation("同一实际材料的重量只能填一次");
            BigDecimal kg=WeightInput.kg(weight.weightKg(),"本次实称重量");
            boolean fromWeight=Boolean.TRUE.equals(weight.qtyFromWeight());
            if(kg!=null||fromWeight)normalized.add(new IssueWeight(weight.goodsId(),weight.colorId(),weight.warehouseId(),kg,fromWeight));
        }
        return normalized.stream().sorted(Comparator.comparing((IssueWeight weight)->place(weight.goodsId(),weight.colorId(),weight.warehouseId()))).toList();
    }

    /** 已有领料单的逐行称重: 规范化与去重同批量出库, 按明细 id 排序(进哈希); 明细归属由批量出库核对。 */
    static List<StockDocIssueBatchRequest.ItemWeight> normalizeItemWeights(List<StockDocIssueBatchRequest.ItemWeight> raw) {
        if(raw==null||raw.isEmpty())return List.of();
        Set<UUID> seen=new HashSet<>();List<StockDocIssueBatchRequest.ItemWeight> normalized=new ArrayList<>();
        for(StockDocIssueBatchRequest.ItemWeight weight:raw) {
            if(weight==null||weight.itemId()==null)throw validation("逐行重量缺少领料明细");
            if(!seen.add(weight.itemId()))throw validation("同一领料明细的重量只能填一次");
            BigDecimal kg=WeightInput.kg(weight.weightKg(),"本次实称重量");
            boolean fromWeight=Boolean.TRUE.equals(weight.qtyFromWeight());
            if(kg!=null||fromWeight)normalized.add(new StockDocIssueBatchRequest.ItemWeight(weight.itemId(),kg,fromWeight));
        }
        return normalized.stream().sorted(Comparator.comparing(weight->weight.itemId().toString())).toList();
    }

    /**
     * 材料确认生成领料单后, 把按(货品, 颜色, 实际仓)填的重量对到新领料明细: 申请行 -> 需求 -> 该需求在实际仓那张
     * 领料单上的明细, 必须唯一。
     */
    private List<StockDocIssueBatchRequest.ItemWeight> configuredItemWeights(Discovery command) {
        if(command.weights().isEmpty())return List.of();
        Map<String,List<UUID>> itemsByPlace=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT line.goods_id,line.color_id,line.warehouse_id,item.id
                FROM production_material_discovery_lines line
                JOIN production_planning_package_document_items mapping
                  ON mapping.demand_id=line.demand_id AND mapping.document_type='DRAW'
                JOIN stock_document_items item ON item.id=mapping.document_item_id AND NOT item.is_deleted
                  AND item.goods_id=line.goods_id AND item.color_id IS NOT DISTINCT FROM line.color_id
                JOIN stock_documents document ON document.id=item.doc_id AND NOT document.is_deleted
                  AND document.warehouse_id=line.warehouse_id
                WHERE line.request_id=:request
                """).setParameter("request",command.requestId()))) {
            itemsByPlace.computeIfAbsent(place((UUID)row[0],(UUID)row[1],(UUID)row[2]),ignored->new ArrayList<>()).add((UUID)row[3]);
        }
        List<StockDocIssueBatchRequest.ItemWeight> mapped=new ArrayList<>();
        for(IssueWeight weight:command.weights()) {
            List<UUID> items=itemsByPlace.getOrDefault(place(weight.goodsId(),weight.colorId(),weight.warehouseId()),List.of());
            if(items.size()!=1)throw conflict("称重的材料没有对应到唯一的领料明细，请刷新后重新核对");
            mapped.add(new StockDocIssueBatchRequest.ItemWeight(items.getFirst(),weight.weightKg(),weight.qtyFromWeight()));
        }
        return mapped;
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
    private List<UUID> readDocumentIds(String value) {
        try {
            List<UUID> ids = new ArrayList<>();
            for (var id : mapper.readTree(value)) ids.add(UUID.fromString(id.asText()));
            return List.copyOf(ids);
        } catch (JsonProcessingException | IllegalArgumentException failure) {
            throw new IllegalStateException("材料明确批量出库回执无法读取", failure);
        }
    }
    private static String identity(UUID goods,UUID color,UUID unit){return goods+":"+Objects.toString(color,"")+":"+unit;}
    private static String place(UUID goods,UUID color,UUID warehouse){return goods+":"+Objects.toString(color,"")+":"+warehouse;}
    private static String configurationKey(UUID actor,String batchKey,UUID requestId){
        return "DISCOVERY-BATCH:"+CanonicalFingerprint.sha256(List.of(actor.toString(),batchKey,requestId.toString()));
    }
    private static ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
