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
        return locks.acquireAll(ids.stream().distinct().sorted()
                .map(id->FulfillmentMutationLocks.Footprint.undeclared(()->footprint.iqcCase(id))).toList());
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
        return locks.acquire(inventoryDeclared(dimensions),()->receiptInputsPlan(type,id,orderItems,dimensions,warehouse));
    }

    /** 一张到货收货单(一张订货单 x 一个入库仓)的登记输入; 新建收货单时 receiptId 为空。 */
    public record ArrivalInput(String type,UUID receiptId,List<UUID> orderItems,List<InventoryDimension> dimensions,UUID warehouse) {
        public ArrivalInput {
            orderItems=orderItems.stream().filter(java.util.Objects::nonNull).toList();
            dimensions=dimensions.stream().filter(java.util.Objects::nonNull).toList();
        }
    }

    /**
     * ADR-098 × ADR-090(2026-10-05) 仓库到货登记: 委外回厂时在 {@link #receiptInputs} 之上并进这些订货明细上
     * 被短交闸扣住的「先入库后质检」合格品所在收货单——这次登记让累计回厂到齐或进入允许损耗范围时,
     * 同一事务就把它们自动转正(嵌套的品质 / 入库命令只剩覆盖检查, 不能事后补锁)。采购到货原样。
     */
    public FulfillmentMutationLocks.Guard arrivalInputs(ArrivalInput input) {
        var arrival=arrivalFootprint(input);
        return locks.acquire(arrival.declared(),arrival.discovery());
    }

    /**
     * 「登记实际到货」一批(ADR-151 §5, 2026-10-06 修正): 服务端按「订货单 x 入库仓」分成多张收货单、一个事务建完,
     * 在写任何一组之前把每一组的 {@link #arrivalInputs} 足迹合成一次预锁(全部订货单、库存维度、主仓、分析);
     * 之后逐组登记里的取锁与送检回调都只核对覆盖。只按第一组取锁时, 后面各组的订货单不在预锁里,
     * 送检回调判结构性缺口、整批 409(用户现场: 3 张订货单 x 2 个仓)。
     */
    public FulfillmentMutationLocks.Guard arrivals(Collection<ArrivalInput> inputs) {
        return locks.acquireAll(inputs.stream().map(this::arrivalFootprint).toList());
    }

    private FulfillmentMutationLocks.Footprint arrivalFootprint(ArrivalInput input) {
        var declared=inventoryDeclared(input.dimensions());
        if(!"SUBCONTRACT".equals(input.type()))return new FulfillmentMutationLocks.Footprint(declared,
                ()->receiptInputsPlan(input.type(),input.receiptId(),input.orderItems(),input.dimensions(),input.warehouse()));
        List<UUID> items=input.orderItems().stream().distinct().toList();
        return new FulfillmentMutationLocks.Footprint(declared,()->withHeldPreStock(
                receiptInputsPlan(input.type(),input.receiptId(),input.orderItems(),input.dimensions(),input.warehouse()),items));
    }

    /**
     * 断点恢复的草稿收货单继续送检(单张 / 批量): 收货单足迹; 委外收货单再并上它们的订货明细上被短交闸扣住的
     * 「先入库后质检」合格品——送检后的短交登记会在同一事务把它们自动转正, 与登记实际到货
     * ({@link #arrivalInputs})同一份推导(2026-10-06 修正, 原来只锁收货单足迹)。
     */
    public FulfillmentMutationLocks.Guard arrivalDrafts(Collection<ProcurementMutationFootprint.ReceiptRef> refs) {
        var snapshot=List.copyOf(refs);
        return locks.acquire(()->{
            var receipts=footprint.receipts(snapshot);
            List<UUID> items=footprint.subcontractReceiptOrderItems(snapshot);
            return items.isEmpty()?receipts:withHeldPreStock(receipts,items);
        });
    }

    /**
     * ADR-098 × ADR-090(2026-10-05) 委外回厂短交判定(分批到货 / 接受损耗): 事务首次预锁 = 订货单足迹
     * (接受损耗时损耗单审核的足迹落在它里面) ∪ 本明细上被扣住的「先入库后质检」合格品所在收货单的
     * 品质与入库足迹。判定在案件行锁之前取锁, 与品质结论 / 入库(先预锁、后锁案件)同一顺序。
     */
    public FulfillmentMutationLocks.Guard subcontractShortDeliveryDecision(UUID orderId,Collection<UUID> orderItemIds) {
        var orders=List.of(new ProcurementMutationFootprint.OrderRef("SUBCONTRACT",orderId));
        List<UUID> items=orderItemIds.stream().filter(java.util.Objects::nonNull).distinct().toList();
        var declared=FulfillmentMutationLockPlan.declared(Set.of(new CommercialSource(CommercialType.SUBCONTRACT_ORDER,orderId)),
                Set.of(),Set.of());
        return locks.acquire(declared,()->withHeldPreStock(footprint.orders(orders),items));
    }

    private FulfillmentMutationLockPlan receiptInputsPlan(String type,UUID id,Collection<UUID> orderItems,
            Collection<InventoryDimension> dimensions,UUID warehouse) {
        return footprint.withInputs(id==null?empty("new-receipt"):footprint.receipts(List.of(new ProcurementMutationFootprint.ReceiptRef(type,id))),
                type.equals("PURCHASE")?CommercialType.PURCHASE_ORDER:CommercialType.SUBCONTRACT_ORDER,orderItems,dimensions,warehouse);
    }

    private FulfillmentMutationLockPlan withHeldPreStock(FulfillmentMutationLockPlan base,Collection<UUID> orderItemIds) {
        var held=footprint.heldSubcontractPreStock(orderItemIds);
        return FulfillmentMutationLockPlan.merge(com.uten.imp.common.util.CanonicalFingerprint.sha256(
                List.of(base.fingerprint(),held.fingerprint())),List.of(base,held));
    }
    public FulfillmentMutationLocks.Guard materialIssueInputs(UUID id,Collection<UUID> orderItems,
            Collection<InventoryDimension> dimensions,UUID warehouse) {
        return locks.acquire(inventoryDeclared(dimensions),
                ()->footprint.withInputs(id==null?empty("new-issue"):footprint.materialIssue(id),
                CommercialType.SUBCONTRACT_ORDER,orderItems,dimensions,warehouse));
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
                sourceItems,dimensions,warehouse));
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
