package com.uten.imp.common.concurrency;

import com.uten.imp.application.concurrency.FulfillmentDiscoveryRound;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

/**
 * Directed read-only procurement sources. Never acquires a lock or walks from extra stock keys to other orders.
 *
 * <p>ADR-107: 行快照只取 {@code (id, xmin)} 行版本; 同一轮发现里订货单、来源明细、单据足迹与目标 BOM
 * 按参数只读一次(见 {@link FulfillmentDiscoveryRound})。</p>
 */
@Component
@RequiredArgsConstructor
@Transactional(propagation=Propagation.MANDATORY,readOnly=true)
public class ProcurementMutationFootprint {
    private final EntityManager em;
    private final ProductionMutationFootprintPort production;

    public record OrderRef(String type,UUID id) {}
    public record ReceiptRef(String type,UUID id,Set<UUID> changedInspectionIds,
                             Set<ProductionMutationFootprintPort.WarehouseDimension> stockInDestinations) {
        public ReceiptRef {
            changedInspectionIds=Set.copyOf(changedInspectionIds==null?Set.of():changedInspectionIds);
            stockInDestinations=Set.copyOf(stockInDestinations==null?Set.of():stockInDestinations);
        }
        public ReceiptRef(String type,UUID id,Set<UUID> changedInspectionIds){this(type,id,changedInspectionIds,Set.of());}
        public ReceiptRef(String type,UUID id){this(type,id,Set.of(),Set.of());}
    }

    /** Receipt approval/reversal or IQC state/stock-in: only changed source dimensions seed wakeups. */
    public FulfillmentMutationLockPlan receipts(Collection<ReceiptRef> refs) {
        List<ReceiptRef> snapshot=List.copyOf(refs);
        return FulfillmentDiscoveryRound.memo("procurement.receipts",snapshot,()->receiptFootprint(snapshot));
    }

    private FulfillmentMutationLockPlan receiptFootprint(List<ReceiptRef> refs) {
        var own=new Discovery();
        Set<OrderRef> orders=new LinkedHashSet<>();
        Set<ProductionMutationFootprintPort.WarehouseDimension> changed=new LinkedHashSet<>();
        for(ReceiptRef ref:refs) {
            String prefix=prefix(ref.type()); own.parts.add("receipt:"+ref);
            for(var destination:ref.stockInDestinations()) {
                changed.add(destination);
                own.warehouse(destination.warehouseId());
                own.inventory(destination.goodsId(),destination.colorId());
            }
            for(Object[] row:rows("""
                    SELECT h.id,h.warehouse_id,i.id,i.goods_id,i.color_id,oi.order_id,
                           h.xmin::text,i.xmin::text,inspection.id,inspection.xmin::text,inspection.status,
                           inspection.pre_stocked_warehouse_id
                    FROM %1$s_receipts h LEFT JOIN %1$s_receipt_items i ON i.receipt_id=h.id AND i.is_deleted=FALSE
                    LEFT JOIN %1$s_order_items oi ON oi.id=i.order_item_id
                    LEFT JOIN procurement_inspection_items inspection ON inspection.receipt_type=:type AND inspection.receipt_item_id=i.id
                    WHERE h.id=:id ORDER BY i.id,inspection.id
                    """.formatted(prefix),Map.of("id",ref.id(),"type",ref.type()))) {
                own.row("receipt-source",row); own.inventory((UUID)row[3],(UUID)row[4]);
                if(row[5]!=null)orders.add(new OrderRef(ref.type(),(UUID)row[5]));
                boolean affected=ref.changedInspectionIds().isEmpty()
                        || ref.changedInspectionIds().contains(row[8]) || "RESOLVED".equals(row[10]);
                if(row[1]!=null && row[3]!=null && affected)
                    changed.add(new ProductionMutationFootprintPort.WarehouseDimension((UUID)row[1],(UUID)row[3],(UUID)row[4]));
                // 先入库后检(V596)：品质 PASS 会在同一事务把该行按上架仓自动转正入库，
                // 上架仓与收货参考仓可能不同，必须在首次预锁时就纳入可用量/主仓维度。
                if(row[11]!=null && row[3]!=null && affected)
                    changed.add(new ProductionMutationFootprintPort.WarehouseDimension((UUID)row[11],(UUID)row[3],(UUID)row[4]));
            }
            for(Object[] row:rows("""
                    SELECT id,owner_id,goods_id,color_id,reservation.xmin::text
                    FROM stock_reservations reservation WHERE source_doc_id=:id AND source_doc_type=:sourceType
                      AND owner_type='PREPLAN_ANALYSIS' AND is_deleted=FALSE ORDER BY id
                    """,Map.of("id",ref.id(),"sourceType",ref.type()+"_RECEIPT"))) {
                own.row("receipt-entitlement",row); own.analysis((UUID)row[1]); own.inventory((UUID)row[2],(UUID)row[3]);
            }
            for(Object[] row:rows("""
                    SELECT stock.id,stock.inspection_item_id,stock.warehouse_id,stock.goods_id,stock.color_id,
                           inspection.status,stock.xmin::text
                    FROM procurement_iqc_stock_in_batch_items stock
                    JOIN procurement_iqc_stock_in_batches batch ON batch.id=stock.batch_id
                    JOIN procurement_inspection_items inspection ON inspection.id=stock.inspection_item_id
                    WHERE batch.receipt_type=:type AND batch.receipt_id=:id ORDER BY stock.id
                    """,Map.of("type",ref.type(),"id",ref.id()))) {
                own.row("receipt-actual-stock",row);
                if(ref.changedInspectionIds().isEmpty()||ref.changedInspectionIds().contains(row[1])||"RESOLVED".equals(row[5])) {
                    changed.add(new ProductionMutationFootprintPort.WarehouseDimension((UUID)row[2],(UUID)row[3],(UUID)row[4]));
                    own.inventory((UUID)row[3],(UUID)row[4]);
                }
            }
        }
        return physical(own,orders,changed);
    }

    /**
     * ADR-098 × ADR-090(2026-10-05): 这些委外订货明细上被短交闸扣住(或上架仓失效退回)、还没转正的
     * 「先入库后质检」合格品所在收货单的品质足迹与入库足迹——与品质结论({@code inspection})和自动转正
     * ({@code stockIn})各自取锁时发现的是同一组收货单引用。没有这种货时返回空计划。
     */
    public FulfillmentMutationLockPlan heldSubcontractPreStock(Collection<UUID> orderItemIds) {
        List<SubcontractHeldPreStock.Release> held = SubcontractHeldPreStock.ofOrderItems(em, orderItemIds);
        if (held.isEmpty()) {
            return new FulfillmentMutationLockPlan(Set.of(), Set.of(), Set.of(), Set.of(), "held-pre-stock:none");
        }
        Map<UUID, List<SubcontractHeldPreStock.Release>> byReceipt = new LinkedHashMap<>();
        for (SubcontractHeldPreStock.Release release : held) {
            byReceipt.computeIfAbsent(release.receiptId(), ignored -> new ArrayList<>()).add(release);
        }
        List<ReceiptRef> refs = new ArrayList<>();
        List<String> parts = new ArrayList<>();
        for (Map.Entry<UUID, List<SubcontractHeldPreStock.Release>> receipt : byReceipt.entrySet()) {
            Set<UUID> inspections = new LinkedHashSet<>();
            Map<UUID, UUID> shelves = new LinkedHashMap<>();
            for (SubcontractHeldPreStock.Release release : receipt.getValue()) {
                inspections.add(release.inspectionItemId());
                shelves.put(release.passEventId(), release.warehouseId());
                parts.add("held-pre-stock:" + release);
            }
            refs.add(new ReceiptRef("SUBCONTRACT", receipt.getKey(), inspections));
            refs.add(stockInReceipt("SUBCONTRACT", receipt.getKey(), shelves.keySet(), shelves));
        }
        FulfillmentMutationLockPlan receipts = receipts(refs);
        parts.add(receipts.fingerprint());
        return FulfillmentMutationLockPlan.merge(CanonicalFingerprint.sha256(parts), List.of(receipts));
    }

    /**
     * 这些委外收货单有效明细引用的订货明细(采购收货单不读)——与送检后短交登记补做自动转正时
     * 读的是同一组订货明细({@code WarehouseArrivalRegistrationService#recordSubcontractShortDelivery})。
     */
    public List<UUID> subcontractReceiptOrderItems(Collection<ReceiptRef> refs) {
        List<UUID> ids=refs.stream().filter(ref->"SUBCONTRACT".equals(ref.type())).map(ReceiptRef::id)
                .distinct().sorted(Comparator.comparing(UUID::toString)).toList();
        if(ids.isEmpty())return List.of();
        return FulfillmentDiscoveryRound.memo("procurement.subcontract-receipt-order-items",ids,()->rows("""
                SELECT DISTINCT order_item_id FROM subcontract_receipt_items
                WHERE receipt_id IN (:ids) AND order_item_id IS NOT NULL AND NOT is_deleted
                ORDER BY order_item_id
                """,Map.of("ids",ids)).stream().map(row->(UUID)row[0]).toList());
    }

    /** 收货单的已知声明: 明细引用的订货单与明细货品维度; 只读一次明细, 不展开依赖图(ADR-107)。 */
    public FulfillmentMutationLockPlan receiptDeclaration(String type,UUID id) {
        Set<CommercialSource> sources=new LinkedHashSet<>();
        Set<InventoryDimension> inventory=new LinkedHashSet<>();
        CommercialType orderType=type.equals("PURCHASE")?CommercialType.PURCHASE_ORDER:CommercialType.SUBCONTRACT_ORDER;
        for(Object[] row:rows("""
                SELECT DISTINCT oi.order_id,i.goods_id,i.color_id
                FROM %1$s_receipt_items i LEFT JOIN %1$s_order_items oi ON oi.id=i.order_item_id
                WHERE i.receipt_id=:id AND i.is_deleted=FALSE
                """.formatted(prefix(type)),Map.of("id",id))) {
            if(row[0]!=null)sources.add(new CommercialSource(orderType,(UUID)row[0]));
            if(row[1]!=null)inventory.add(new InventoryDimension((UUID)row[1],(UUID)row[2]));
        }
        return FulfillmentMutationLockPlan.declared(sources,inventory,Set.of());
    }

    public ReceiptRef stockInReceipt(String type,UUID receiptId,Collection<UUID> passEventIds) {
        return stockInReceipt(type,receiptId,passEventIds,Map.of());
    }

    public ReceiptRef stockInReceipt(String type,UUID receiptId,Collection<UUID> passEventIds,Map<UUID,UUID> warehouseByPassEvent) {
        Set<UUID> inspections=new LinkedHashSet<>();
        Set<ProductionMutationFootprintPort.WarehouseDimension> destinations=new LinkedHashSet<>();
        if(!passEventIds.isEmpty())for(Object[] row:rows("""
                SELECT event.id,event.inspection_item_id,inspection.goods_id,inspection.color_id,inspection.warehouse_id
                FROM procurement_inspection_events event
                JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id
                WHERE event.id IN (:ids) AND inspection.receipt_type=:type AND inspection.receipt_id=:receipt
                ORDER BY event.id
                """,Map.of("ids",passEventIds,"type",type,"receipt",receiptId))) {
            inspections.add((UUID)row[1]);
            UUID warehouse=warehouseByPassEvent.getOrDefault((UUID)row[0],(UUID)row[4]);
            if(warehouse!=null&&row[2]!=null)destinations.add(new ProductionMutationFootprintPort.WarehouseDimension(
                    warehouse,(UUID)row[2],(UUID)row[3]));
        }
        // Invalid/missing PASS ids remain rejected by the locked stock-in command validation.
        return new ReceiptRef(type,receiptId,inspections,destinations);
    }

    /** Supplier product returns alter the actual return warehouse, while keeping exact original order provenance. */
    public FulfillmentMutationLockPlan productReturn(String type,UUID id) {
        return FulfillmentDiscoveryRound.memo("procurement.product-return",List.of(type,id),()->productReturnFootprint(type,id));
    }

    private FulfillmentMutationLockPlan productReturnFootprint(String type,UUID id) {
        String prefix=prefix(type); var own=new Discovery();
        own.parts.add("product-return:"+type+":"+id);
        Set<OrderRef> orders=new LinkedHashSet<>();
        Set<ProductionMutationFootprintPort.WarehouseDimension> changed=new LinkedHashSet<>();
        for(Object[] row:rows("""
                SELECT h.id,h.warehouse_id,i.id,i.goods_id,i.color_id,oi.order_id,
                       h.xmin::text,i.xmin::text,ri.xmin::text,receipt.xmin::text
                FROM %1$s_returns h LEFT JOIN %1$s_return_items i ON i.return_id=h.id AND i.is_deleted=FALSE
                LEFT JOIN %1$s_receipt_items ri ON ri.id=i.receipt_item_id
                LEFT JOIN %1$s_receipts receipt ON receipt.id=ri.receipt_id
                LEFT JOIN %1$s_order_items oi ON oi.id=COALESCE(i.order_item_id,ri.order_item_id)
                WHERE h.id=:id ORDER BY i.id
                """.formatted(prefix),Map.of("id",id))) {
            own.row("return-source",row); own.inventory((UUID)row[3],(UUID)row[4]);
            if(row[5]!=null)orders.add(new OrderRef(type,(UUID)row[5]));
            if(row[1]!=null && row[3]!=null)changed.add(new ProductionMutationFootprintPort.WarehouseDimension((UUID)row[1],(UUID)row[3],(UUID)row[4]));
        }
        return physical(own,orders,changed);
    }

    public FulfillmentMutationLockPlan materialIssue(UUID id) { return materialDocument(id,false); }
    public FulfillmentMutationLockPlan materialReturn(UUID id) { return materialDocument(id,true); }

    public FulfillmentMutationLockPlan materialWaste(UUID id){
        var own=new Discovery();Set<OrderRef> orders=new LinkedHashSet<>();
        for(Object[] row:rows("""
                SELECT waste.id,item.id,item.goods_id,item.color_id,issue.order_item_id,target.order_id,
                    target.goods_id,target.color_id,waste.xmin::text,item.xmin::text,issue.xmin::text
                FROM subcontract_wastes waste JOIN subcontract_waste_items item ON item.waste_id=waste.id AND NOT item.is_deleted
                JOIN subcontract_material_issue_items issue ON issue.id=item.material_issue_item_id
                JOIN subcontract_order_items target ON target.id=issue.order_item_id WHERE waste.id=:id ORDER BY item.id
                """,Map.of("id",id))){
            own.row("subcontract-waste",row);own.inventory((UUID)row[2],(UUID)row[3]);own.inventory((UUID)row[6],(UUID)row[7]);
            orders.add(new OrderRef("SUBCONTRACT",(UUID)row[5]));
        }
        return physical(own,orders,Set.of());
    }

    public FulfillmentMutationLockPlan returnInputs(String type,UUID id,boolean materials,Collection<UUID> requestedOrderItems,
            Collection<UUID> originalItemIds,Collection<InventoryDimension> dimensions,UUID warehouse) {
        Set<UUID> orderItems=new LinkedHashSet<>(); requestedOrderItems.stream().filter(Objects::nonNull).forEach(orderItems::add);
        List<UUID> original=originalItemIds.stream().filter(Objects::nonNull).distinct().toList();
        var parts=new ArrayList<String>();
        if(!original.isEmpty())for(Object[] row:rows("SELECT id,order_item_id,item.xmin::text FROM "
                +(materials?"subcontract_material_issue_items":prefix(type)+"_receipt_items")
                +" item WHERE id IN (:ids) ORDER BY id",Map.of("ids",original))) {
            if(row[1]!=null)orderItems.add((UUID)row[1]);parts.add(Arrays.toString(row));
        }
        var previous=id==null?new FulfillmentMutationLockPlan(Set.of(),Set.of(),Set.of(),Set.of(),"new-return")
                :materials?materialReturn(id):productReturn(type,id);
        var merged=withInputs(previous,type.equals("PURCHASE")?CommercialType.PURCHASE_ORDER:CommercialType.SUBCONTRACT_ORDER,
                orderItems,dimensions,warehouse);
        parts.add(merged.fingerprint());
        return FulfillmentMutationLockPlan.merge(CanonicalFingerprint.sha256(parts),List.of(merged));
    }

    public FulfillmentMutationLockPlan withInputs(FulfillmentMutationLockPlan existing,CommercialType sourceType,
            Collection<UUID> sourceItemIds,Collection<InventoryDimension> rawDimensions,UUID warehouseId) {
        var input=new Discovery();
        var dimensions=rawDimensions.stream().filter(Objects::nonNull).distinct().sorted().toList();
        input.parts.add("requested-dimensions:"+dimensions+":"+warehouseId);
        input.inventory.addAll(dimensions); input.warehouse(warehouseId);
        var sources=sourceItems(sourceType,sourceItemIds);
        input.analyses.addAll(existing.analysisIds()); input.analyses.addAll(sources.analysisIds());
        var availability=production.forInventoryChange(dimensions.stream()
                .map(d->new ProductionMutationFootprintPort.WarehouseDimension(warehouseId,d.goodsId(),d.colorId())).toList(),input.analyses);
        var requested=finish(input);
        return FulfillmentMutationLockPlan.merge(CanonicalFingerprint.sha256(List.of(existing.fingerprint(),sources.fingerprint(),
                requested.fingerprint(),availability.fingerprint())),List.of(existing,sources,requested,availability));
    }

    /** Original and newly requested source items are both discovered before any source is locked. */
    public FulfillmentMutationLockPlan sourceItems(CommercialType type,Collection<UUID> rawIds) {
        var ids=rawIds.stream().filter(Objects::nonNull).distinct().sorted(Comparator.comparing(UUID::toString)).toList();
        return FulfillmentDiscoveryRound.memo("procurement.source-items",List.of(type,ids),()->sourceItemFootprint(type,ids));
    }

    private FulfillmentMutationLockPlan sourceItemFootprint(CommercialType type,List<UUID> ids) {
        var own=new Discovery();own.parts.add("source-items:"+type+":"+ids);
        if(ids.isEmpty())return finish(own);
        String table,header,parent,procurementType;
        switch(type) {
            case PURCHASE_ORDER -> {table="purchase_order_items";header="purchase_orders";parent="order_id";procurementType="PURCHASE";}
            case SUBCONTRACT_ORDER -> {table="subcontract_order_items";header="subcontract_orders";parent="order_id";procurementType="SUBCONTRACT";}
            case PURCHASE_REQUEST -> {table="purchase_request_items";header="purchase_requests";parent="request_id";procurementType="PURCHASE";}
            case SUBCONTRACT_APPLICATION -> {table="subcontract_application_items";header="subcontract_applications";parent="application_id";procurementType="SUBCONTRACT";}
            default -> throw new IllegalArgumentException("Unsupported procurement source items");
        }
        Set<OrderRef> orderRefs=new LinkedHashSet<>();
        for(Object[] row:rows("""
                SELECT i.id,h.id,h.warehouse_id,i.goods_id,i.color_id,i.xmin::text,h.xmin::text
                FROM %s i JOIN %s h ON h.id=i.%s WHERE i.id IN (:ids) ORDER BY i.id
                """.formatted(table,header,parent),Map.of("ids",ids))) {
            own.row("requested-source",row);own.source(type,(UUID)row[1]);own.warehouse((UUID)row[2]);
            own.inventory((UUID)row[3],(UUID)row[4]);
            if(parent.equals("order_id"))orderRefs.add(new OrderRef(procurementType,(UUID)row[1]));
        }
        if(!parent.equals("order_id"))for(Object[] row:rows("""
                SELECT allocation.id,action.analysis_id,allocation.xmin::text,action.xmin::text
                FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id
                WHERE allocation.external_item_id IN (:ids) AND action.route=:route ORDER BY allocation.id
                """,Map.of("ids",ids,"route",procurementType.equals("PURCHASE")?"BUY":"SUBCONTRACT"))) {
            own.row("requested-analysis",row);own.analysis((UUID)row[1]);
        }
        var linked=orders(orderRefs);var ownPlan=finish(own);
        return FulfillmentMutationLockPlan.merge(CanonicalFingerprint.sha256(List.of(ownPlan.fingerprint(),linked.fingerprint())),List.of(ownPlan,linked));
    }

    private FulfillmentMutationLockPlan materialDocument(UUID id,boolean returning) {
        return FulfillmentDiscoveryRound.memo("procurement.material-document",List.of(id,returning),
                ()->materialDocumentFootprint(id,returning));
    }

    private FulfillmentMutationLockPlan materialDocumentFootprint(UUID id,boolean returning) {
        var own=new Discovery(); own.parts.add("material:"+returning+":"+id);
        Set<OrderRef> orders=new LinkedHashSet<>();
        Set<ProductionMutationFootprintPort.WarehouseDimension> changed=new LinkedHashSet<>();
        String header=returning?"subcontract_material_returns":"subcontract_material_issues";
        String detail=returning?"subcontract_material_return_items":"subcontract_material_issue_items";
        String parent=returning?"material_return_id":"issue_id";
        String original=returning?"LEFT JOIN subcontract_material_issue_items original ON original.id=i.material_issue_item_id":"";
        String orderItem=returning?"COALESCE(i.order_item_id,original.order_item_id)":"i.order_item_id";
        for(Object[] row:rows("""
                SELECT h.id,h.warehouse_id,i.id,i.goods_id,i.color_id,oi.order_id,
                       h.xmin::text,i.xmin::text
                FROM %s h LEFT JOIN %s i ON i.%s=h.id AND i.is_deleted=FALSE
                %s LEFT JOIN subcontract_order_items oi ON oi.id=%s
                WHERE h.id=:id ORDER BY i.id
                """.formatted(header,detail,parent,original,orderItem),Map.of("id",id))) {
            own.row("material-source",row); own.inventory((UUID)row[3],(UUID)row[4]);
            if(row[5]!=null)orders.add(new OrderRef("SUBCONTRACT",(UUID)row[5]));
            if(row[1]!=null && row[3]!=null)changed.add(new ProductionMutationFootprintPort.WarehouseDimension((UUID)row[1],(UUID)row[3],(UUID)row[4]));
        }
        return physical(own,orders,changed);
    }

    public FulfillmentMutationLockPlan iqcCase(UUID caseId) {
        List<Object[]> rows=rows("SELECT receipt_type,receipt_id,inspection_item_id,c.xmin::text FROM procurement_iqc_rejection_cases c WHERE id=:id",Map.of("id",caseId));
        if(rows.isEmpty())return orders(List.of());
        Object[] row=rows.getFirst();
        var receipt=receipts(List.of(new ReceiptRef((String)row[0],(UUID)row[1],Set.of((UUID)row[2]))));
        return FulfillmentMutationLockPlan.merge(CanonicalFingerprint.sha256(List.of("iqc-case:"+caseId+":"+row[3],receipt.fingerprint())),List.of(receipt));
    }

    private FulfillmentMutationLockPlan physical(Discovery own,Set<OrderRef> orders,
            Collection<ProductionMutationFootprintPort.WarehouseDimension> changed) {
        var orderPlan=orders(orders); own.analyses.addAll(orderPlan.analysisIds());
        var availability=production.forInventoryChange(changed,own.analyses);
        own.parts.add("orders:"+orderPlan.fingerprint()); own.parts.add("availability:"+availability.fingerprint());
        return FulfillmentMutationLockPlan.merge(CanonicalFingerprint.sha256(own.parts),List.of(orderPlan,availability,
                new FulfillmentMutationLockPlan(own.sources,own.inventory,Set.of(),own.analyses,"physical-source")));
    }

    private static String prefix(String type) {
        return switch(type){case "PURCHASE"->"purchase";case "SUBCONTRACT"->"subcontract";
            default->throw new IllegalArgumentException("Unsupported procurement source type");};
    }

    public FulfillmentMutationLockPlan order(String type,UUID orderId) {
        return orders(List.of(new OrderRef(type,orderId)));
    }

    public FulfillmentMutationLockPlan orders(Collection<OrderRef> orders) {
        List<OrderRef> requested=orders.stream().filter(Objects::nonNull).distinct()
                .sorted(Comparator.comparing(OrderRef::type).thenComparing(ref->ref.id().toString())).toList();
        return FulfillmentDiscoveryRound.memo("procurement.orders",requested,()->orderFootprint(requested));
    }

    private FulfillmentMutationLockPlan orderFootprint(List<OrderRef> requested) {
        var result=new Discovery();
        result.parts.add("orders:"+requested);
        for(String type:List.of("PURCHASE","SUBCONTRACT")) {
            List<UUID> ids=requested.stream().filter(ref->type.equals(ref.type())).map(OrderRef::id).toList();
            if(!ids.isEmpty()) addOrders(result,type,ids);
        }
        if(requested.stream().anyMatch(ref->!Set.of("PURCHASE","SUBCONTRACT").contains(ref.type())))
            throw new IllegalArgumentException("Unsupported procurement source type");
        return finish(result);
    }

    private void addOrders(Discovery result,String type,List<UUID> ids) {
        String prefix=type.equals("PURCHASE")?"purchase":"subcontract";
        String sourceType=type.equals("PURCHASE")?"request":"application";
        String sourceColumn=sourceType+"_item_id";
        CommercialType orderType=type.equals("PURCHASE")?CommercialType.PURCHASE_ORDER:CommercialType.SUBCONTRACT_ORDER;
        CommercialType sourceHeaderType=type.equals("PURCHASE")?CommercialType.PURCHASE_REQUEST:CommercialType.SUBCONTRACT_APPLICATION;
        Set<UUID> itemIds=new LinkedHashSet<>(),sourceIds=new LinkedHashSet<>();
        for(Object[] row:rows("""
                SELECT h.id,h.warehouse_id,i.id,i.goods_id,i.color_id,i.%2$s,
                       h.xmin::text,i.xmin::text
                FROM %1$s_orders h LEFT JOIN %1$s_order_items i ON i.order_id=h.id AND i.is_deleted=FALSE
                WHERE h.id IN (:ids) ORDER BY h.id,i.id
                """.formatted(prefix,sourceColumn),Map.of("ids",ids))) {
            result.row("order",row); result.source(orderType,(UUID)row[0]); result.warehouse((UUID)row[1]);
            if(row[2]!=null)itemIds.add((UUID)row[2]);
            result.inventory((UUID)row[3],(UUID)row[4]);
            if(row[5]!=null)sourceIds.add((UUID)row[5]);
        }
        if(itemIds.isEmpty())return;
        for(Object[] row:rows("""
                SELECT s.id,s.%2$s,s.xmin::text
                FROM %1$s_order_item_sources s WHERE s.order_item_id IN (:ids) ORDER BY s.id
                """.formatted(prefix,sourceColumn),Map.of("ids",itemIds))) {
            result.row("source-allocation",row); sourceIds.add((UUID)row[1]); // zero anchors remain restorable sources
        }
        if(!sourceIds.isEmpty()) {
            for(Object[] row:rows("""
                    SELECT item.id,h.id,h.warehouse_id,item.goods_id,item.color_id,
                           item.xmin::text,h.xmin::text
                    FROM %1$s_%2$s_items item JOIN %1$s_%2$ss h ON h.id=item.%2$s_id
                    WHERE item.id IN (:ids) ORDER BY item.id
                    """.formatted(prefix,sourceType),Map.of("ids",sourceIds))) {
                result.row("upstream",row); result.source(sourceHeaderType,(UUID)row[1]); result.warehouse((UUID)row[2]);
                result.inventory((UUID)row[3],(UUID)row[4]);
            }
            for(Object[] row:rows("""
                    SELECT allocation.id,action.analysis_id,allocation.xmin::text,action.xmin::text
                    FROM preplan_supply_action_allocations allocation
                    JOIN preplan_supply_actions action ON action.id=allocation.action_id
                    WHERE allocation.external_item_id IN (:ids) AND action.route=:route ORDER BY allocation.id
                    """,Map.of("ids",sourceIds,"route",type.equals("PURCHASE")?"BUY":"SUBCONTRACT"))) {
                result.row("source-analysis",row); result.analysis((UUID)row[1]);
            }
        }
        Set<UUID> planIds=new LinkedHashSet<>();
        Map<String,Object> parameters=Map.of("ids",itemIds,"supplyType",type+"_ORDER_ITEM");
        for(Object[] row:rows("""
                WITH affected AS (
                    SELECT DISTINCT demand.execution_segment_id,demand.id
                    FROM production_material_supply_pegs peg
                    JOIN production_material_demands demand ON demand.id=peg.demand_id AND demand.is_deleted=FALSE
                    WHERE peg.supply_type=:supplyType AND peg.supply_item_id IN (:ids) AND peg.status<>'REVERSED'
                )
                SELECT DISTINCT demand.id,demand.goods_id,demand.color_id,demand.plan_id,plan.material_analysis_id,
                       demand.xmin::text
                FROM affected JOIN production_material_demands demand
                  ON demand.execution_segment_id=affected.execution_segment_id OR demand.id=affected.id
                JOIN production_plans plan ON plan.id=demand.plan_id
                WHERE demand.is_deleted=FALSE ORDER BY demand.id
                """,parameters)) {
            result.row("formal-demand",row); result.inventory((UUID)row[1],(UUID)row[2]);
            planIds.add((UUID)row[3]); result.analysis((UUID)row[4]);
        }
        addPlanSales(result,planIds);
        if(type.equals("SUBCONTRACT")) {
            // ADR-143 §4.2: 领料的库存维度只认财务批准时冻结的计划行(物料 + 冻结颜色), 不读现时 BOM;
            // 待发领料草稿所在仓一并纳入(撤回、仓库改少、结束领料都会在那里释放预留)。
            for(Object[] row:rows("""
                    SELECT pi.id,pi.goods_id,pi.color_id,pi.xmin::text
                    FROM subcontract_material_plan_items pi JOIN subcontract_material_plans plan ON plan.id=pi.plan_id
                    WHERE plan.order_id IN (:ids) AND pi.is_deleted=FALSE ORDER BY pi.id
                    """,Map.of("ids",ids))) {
                result.row("subcontract-plan",row); result.inventory((UUID)row[1],(UUID)row[2]);
            }
            for(Object[] row:rows("""
                    SELECT DISTINCT issue.id,issue.warehouse_id
                    FROM subcontract_material_issues issue
                    JOIN subcontract_material_issue_items item ON item.issue_id=issue.id AND item.is_deleted=FALSE
                    WHERE item.order_item_id IN (:items) AND item.plan_item_id IS NOT NULL
                      AND issue.status=0 AND issue.is_deleted=FALSE
                    ORDER BY issue.id
                    """,Map.of("items",itemIds))) {
                result.row("subcontract-draw-draft",row); result.warehouse((UUID)row[1]);
            }
            // 尚未批准(还没有冻结计划行)的明细: 财务批准会按 fn_subcontract_draw_edges 冻结这些直属物料,
            // 预先纳入它们的维度。已冻结的明细不再读现时 BOM。
            for(Object[] row:rows("""
                    SELECT item.id,edge.edge_id,edge.component_goods_id,edge.color_id
                    FROM subcontract_order_items item
                    CROSS JOIN LATERAL fn_subcontract_draw_edges(item.goods_id) edge
                    WHERE item.id IN (:items)
                      AND NOT EXISTS (SELECT 1 FROM subcontract_material_plan_items frozen
                                      WHERE frozen.order_item_id=item.id AND frozen.is_deleted=FALSE)
                    ORDER BY item.id,edge.sort_order,edge.edge_id
                    """,Map.of("items",itemIds))) {
                result.row("subcontract-draw-edge",row); result.inventory((UUID)row[2],(UUID)row[3]);
            }
        }
    }

    private void addPlanSales(Discovery result,Set<UUID> planIds) {
        if(planIds.isEmpty())return;
        for(Object[] row:rows("""
                SELECT item.id,direct.order_id,link.id,linked.order_id,item.xmin::text,link.xmin::text
                FROM production_plan_items item
                LEFT JOIN sales_order_items direct ON direct.id=item.sales_order_item_id
                LEFT JOIN plan_order_item_links link ON link.plan_item_id=item.id AND link.is_deleted=FALSE
                LEFT JOIN sales_order_items linked ON linked.id=link.order_item_id
                WHERE item.plan_id IN (:ids) AND item.is_deleted=FALSE ORDER BY item.id,link.id
                """,Map.of("ids",planIds))) {
            result.row("formal-sales",row); result.source(CommercialType.SALES_ORDER,(UUID)row[1]);
            result.source(CommercialType.SALES_ORDER,(UUID)row[3]);
        }
    }

    private FulfillmentMutationLockPlan finish(Discovery result) {
        List<UUID> leaves=result.warehouseLeaves.stream().sorted(Comparator.comparing(UUID::toString)).toList();
        if(!leaves.isEmpty())for(Object[] row:FulfillmentDiscoveryRound.memo("procurement.warehouse-path",leaves,
                ()->List.copyOf(readWarehousePath(leaves)))) {
            result.row("warehouse-path",row); if(row[1]==null)result.warehouses.add((UUID)row[0]);
        }
        var productionPlan=production.forAnalyses(result.analyses);
        result.parts.add("production:"+productionPlan.fingerprint());
        return FulfillmentMutationLockPlan.merge(CanonicalFingerprint.sha256(result.parts),List.of(productionPlan,
                new FulfillmentMutationLockPlan(result.sources,result.inventory,result.warehouses,result.analyses,"procurement")));
    }

    private List<Object[]> readWarehousePath(List<UUID> leaves) {
        return rows("""
                WITH RECURSIVE ancestry AS (
                    SELECT id,parent_id,ARRAY[id] AS path FROM warehouses WHERE id IN (:ids) AND is_deleted=FALSE
                    UNION ALL SELECT w.id,w.parent_id,child.path||w.id FROM ancestry child
                    JOIN warehouses w ON w.id=child.parent_id AND w.is_deleted=FALSE WHERE NOT w.id=ANY(child.path)
                ) SELECT DISTINCT id,parent_id FROM ancestry ORDER BY id
                """,Map.of("ids",leaves));
    }

    private List<Object[]> rows(String sql,Map<String,?> parameters) {
        var query=em.createNativeQuery(sql); parameters.forEach(query::setParameter); return NativeQueryResults.objectArrayRows(query);
    }
    private static final class Discovery {
        final Set<CommercialSource> sources=new LinkedHashSet<>();
        final Set<InventoryDimension> inventory=new LinkedHashSet<>();
        final Set<UUID> analyses=new LinkedHashSet<>(),warehouseLeaves=new LinkedHashSet<>(),warehouses=new LinkedHashSet<>();
        final List<String> parts=new ArrayList<>();
        void source(CommercialType type,UUID id){if(id!=null)sources.add(new CommercialSource(type,id));}
        void inventory(UUID goods,UUID color){if(goods!=null)inventory.add(new InventoryDimension(goods,color));}
        void analysis(UUID id){if(id!=null)analyses.add(id);}
        void warehouse(UUID id){if(id!=null)warehouseLeaves.add(id);}
        void row(String tag,Object[] row){parts.add(tag+":"+Arrays.toString(row));}
    }
}
