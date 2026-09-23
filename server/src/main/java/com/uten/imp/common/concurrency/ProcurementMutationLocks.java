package com.uten.imp.common.concurrency;

import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.util.Collection;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * Procurement entry-point adapter; all actual locks use the shared platform coordinator.
 *
 * <p>ADR-107: 各入口把手里已知的订货单与库存维度作为「声明」交给协调器——嵌套在已持有预锁的
 * 命令里时只做内存覆盖检查, 不再重跑发现。</p>
 */
@Component
@RequiredArgsConstructor
@Transactional(propagation=Propagation.MANDATORY)
public class ProcurementMutationLocks {
    private final ProcurementMutationFootprint footprint;
    private final FulfillmentMutationLocks locks;

    public FulfillmentMutationLocks.Guard order(String type,UUID id) {
        return orders(List.of(new ProcurementMutationFootprint.OrderRef(type,id)));
    }
    public FulfillmentMutationLocks.Guard orders(Collection<ProcurementMutationFootprint.OrderRef> refs) {
        var snapshot=List.copyOf(refs);
        var declared=FulfillmentMutationLockPlan.declared(snapshot.stream()
                .map(ref->new CommercialSource(orderType(ref.type()),ref.id())).toList(),Set.of(),Set.of());
        return locks.acquire(declared,()->footprint.orders(snapshot));
    }
    public FulfillmentMutationLocks.Guard receipt(String type,UUID id) {
        return receipts(List.of(new ProcurementMutationFootprint.ReceiptRef(type,id)));
    }
    public FulfillmentMutationLocks.Guard receipts(Collection<ProcurementMutationFootprint.ReceiptRef> refs) {
        var snapshot=List.copyOf(refs); return locks.acquire(()->footprint.receipts(snapshot));
    }
    public FulfillmentMutationLocks.Guard inspection(String type,UUID receiptId,Collection<UUID> inspectionIds) {
        return receipts(List.of(new ProcurementMutationFootprint.ReceiptRef(type,receiptId,new java.util.HashSet<>(inspectionIds))));
    }
    public record StockInRef(String type,UUID receiptId,List<UUID> passEventIds,java.util.Map<UUID,UUID> warehouseByPassEvent) {
        public StockInRef { warehouseByPassEvent=java.util.Map.copyOf(warehouseByPassEvent==null?java.util.Map.of():warehouseByPassEvent); }
        public StockInRef(String type,UUID receiptId,List<UUID> passEventIds){this(type,receiptId,passEventIds,java.util.Map.of());}
    }
    public FulfillmentMutationLocks.Guard stockIn(Collection<StockInRef> refs) {
        var snapshot=List.copyOf(refs);
        return locks.acquire(()->footprint.receipts(snapshot.stream()
                .map(ref->footprint.stockInReceipt(ref.type(),ref.receiptId(),ref.passEventIds(),ref.warehouseByPassEvent())).toList()));
    }
    public FulfillmentMutationLocks.Guard productReturn(String type,UUID id) {
        return locks.acquire(()->footprint.productReturn(type,id));
    }
    public FulfillmentMutationLocks.Guard materialIssue(UUID id) { return locks.acquire(()->footprint.materialIssue(id)); }
    public FulfillmentMutationLocks.Guard materialReturn(UUID id) { return locks.acquire(()->footprint.materialReturn(id)); }
    public FulfillmentMutationLocks.Guard materialWaste(UUID id) { return locks.acquire(()->footprint.materialWaste(id)); }
    public FulfillmentMutationLocks.Guard iqcCase(UUID id) { return locks.acquire(()->footprint.iqcCase(id)); }
    public FulfillmentMutationLocks.Guard iqcCases(Collection<UUID> ids) {
        var sorted=ids.stream().distinct().sorted().toList();
        return locks.acquire(()->{
            var parts=sorted.stream().map(footprint::iqcCase).toList();
            return FulfillmentMutationLockPlan.merge(
                    com.uten.imp.common.util.CanonicalFingerprint.sha256(parts.stream()
                            .map(FulfillmentMutationLockPlan::fingerprint).toList()),parts);
        });
    }

    /**
     * 收货审核/红冲的写后回调: 本收货单涉及的订货单与货品维度必须已在本事务预锁里(纯内存比较,
     * 只读一次收货明细拿这两个已知集合, 不再重跑整张依赖图的发现)。
     */
    public void requireReceiptCovered(String type,UUID id) {
        locks.requireCovered(footprint.receiptDeclaration(type,id));
    }

    public FulfillmentMutationLocks.Guard receiptInputs(String type,UUID id,Collection<UUID> orderItems,
            Collection<InventoryDimension> dimensions,UUID warehouse) {
        return locks.acquire(inventoryDeclared(dimensions),
                ()->footprint.withInputs(id==null?empty("new-receipt"):footprint.receipts(List.of(new ProcurementMutationFootprint.ReceiptRef(type,id))),
                type.equals("PURCHASE")?CommercialType.PURCHASE_ORDER:CommercialType.SUBCONTRACT_ORDER,orderItems,dimensions,warehouse,false));
    }
    public FulfillmentMutationLocks.Guard materialIssueInputs(UUID id,Collection<UUID> orderItems,
            Collection<InventoryDimension> dimensions,UUID warehouse) {
        return locks.acquire(inventoryDeclared(dimensions),
                ()->footprint.withInputs(id==null?empty("new-issue"):footprint.materialIssue(id),
                CommercialType.SUBCONTRACT_ORDER,orderItems,dimensions,warehouse,false));
    }
    public FulfillmentMutationLocks.Guard returnInputs(String type,UUID id,boolean materials,Collection<UUID> orderItems,
            Collection<UUID> originalItems,Collection<InventoryDimension> dimensions,UUID warehouse) {
        return locks.acquire(inventoryDeclared(dimensions),
                ()->footprint.returnInputs(type,id,materials,orderItems,originalItems,dimensions,warehouse));
    }
    public FulfillmentMutationLocks.Guard orderInputs(String type,UUID id,Collection<UUID> sourceItems,
            Collection<InventoryDimension> dimensions,UUID warehouse) {
        var declared=FulfillmentMutationLockPlan.declared(id==null?Set.of():Set.of(new CommercialSource(orderType(type),id)),
                dimensions,Set.of());
        return locks.acquire(declared,()->footprint.withInputs(id==null?empty("new-order"):footprint.order(type,id),
                type.equals("PURCHASE")?CommercialType.PURCHASE_REQUEST:CommercialType.SUBCONTRACT_APPLICATION,
                sourceItems,dimensions,warehouse,type.equals("SUBCONTRACT")));
    }
    public void expectCreatedOrder(String type,UUID id) {
        locks.expectCreatedSource(new CommercialSource(orderType(type),id));
    }
    public void registerCreatedOrder(String type,UUID id) {
        locks.registerCreatedSource(new CommercialSource(orderType(type),id));
    }
    private static CommercialType orderType(String type) {
        return type.equals("PURCHASE")?CommercialType.PURCHASE_ORDER:CommercialType.SUBCONTRACT_ORDER;
    }
    private static FulfillmentMutationLockPlan inventoryDeclared(Collection<InventoryDimension> dimensions) {
        return FulfillmentMutationLockPlan.declared(Set.of(),dimensions,Set.of());
    }
    private static FulfillmentMutationLockPlan empty(String key) {
        return new FulfillmentMutationLockPlan(java.util.Set.of(),java.util.Set.of(),java.util.Set.of(),java.util.Set.of(),key);
    }
}
