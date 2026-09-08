package com.uten.imp.common.concurrency;

import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.util.Collection;
import java.util.List;
import java.util.UUID;

/** Procurement entry-point adapter; all actual locks use the shared platform coordinator. */
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
        return locks.acquire(()->footprint.orders(snapshot));
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
    public record StockInRef(String type,UUID receiptId,List<UUID> passEventIds) {}
    public FulfillmentMutationLocks.Guard stockIn(Collection<StockInRef> refs) {
        var snapshot=List.copyOf(refs);
        return locks.acquire(()->footprint.receipts(snapshot.stream()
                .map(ref->footprint.stockInReceipt(ref.type(),ref.receiptId(),ref.passEventIds())).toList()));
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
    public void requireReceiptCovered(String type,UUID id) {
        locks.requireCovered(footprint.receipts(List.of(new ProcurementMutationFootprint.ReceiptRef(type,id))));
    }

    public FulfillmentMutationLocks.Guard receiptInputs(String type,UUID id,Collection<UUID> orderItems,
            Collection<InventoryDimension> dimensions,UUID warehouse) {
        return locks.acquire(()->footprint.withInputs(id==null?empty("new-receipt"):footprint.receipts(List.of(new ProcurementMutationFootprint.ReceiptRef(type,id))),
                type.equals("PURCHASE")?CommercialType.PURCHASE_ORDER:CommercialType.SUBCONTRACT_ORDER,orderItems,dimensions,warehouse,false));
    }
    public FulfillmentMutationLocks.Guard materialIssueInputs(UUID id,Collection<UUID> orderItems,
            Collection<InventoryDimension> dimensions,UUID warehouse) {
        return locks.acquire(()->footprint.withInputs(id==null?empty("new-issue"):footprint.materialIssue(id),
                CommercialType.SUBCONTRACT_ORDER,orderItems,dimensions,warehouse,false));
    }
    public FulfillmentMutationLocks.Guard returnInputs(String type,UUID id,boolean materials,Collection<UUID> orderItems,
            Collection<UUID> originalItems,Collection<InventoryDimension> dimensions,UUID warehouse) {
        return locks.acquire(()->footprint.returnInputs(type,id,materials,orderItems,originalItems,dimensions,warehouse));
    }
    public FulfillmentMutationLocks.Guard orderInputs(String type,UUID id,Collection<UUID> sourceItems,
            Collection<InventoryDimension> dimensions,UUID warehouse) {
        return locks.acquire(()->footprint.withInputs(id==null?empty("new-order"):footprint.order(type,id),
                type.equals("PURCHASE")?CommercialType.PURCHASE_REQUEST:CommercialType.SUBCONTRACT_APPLICATION,
                sourceItems,dimensions,warehouse,type.equals("SUBCONTRACT")));
    }
    public void expectCreatedOrder(String type,UUID id) {
        locks.expectCreatedSource(new FulfillmentMutationLockPlan.CommercialSource(
                type.equals("PURCHASE")?CommercialType.PURCHASE_ORDER:CommercialType.SUBCONTRACT_ORDER,id));
    }
    public void registerCreatedOrder(String type,UUID id) {
        locks.registerCreatedSource(new FulfillmentMutationLockPlan.CommercialSource(
                type.equals("PURCHASE")?CommercialType.PURCHASE_ORDER:CommercialType.SUBCONTRACT_ORDER,id));
    }
    private static FulfillmentMutationLockPlan empty(String key) {
        return new FulfillmentMutationLockPlan(java.util.Set.of(),java.util.Set.of(),java.util.Set.of(),java.util.Set.of(),key);
    }
}
