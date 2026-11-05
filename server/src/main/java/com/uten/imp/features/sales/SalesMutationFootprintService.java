package com.uten.imp.features.sales;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Sales only follows actual order/shipment references; reservations do not wake unrelated analyses. */
@Service
@RequiredArgsConstructor
@Transactional(propagation = Propagation.MANDATORY)
public class SalesMutationFootprintService implements com.uten.imp.application.port.SalesDeliveryMutationPort {
    private final EntityManager em;
    private final FulfillmentMutationLocks locks;
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.SalesDeliveryFulfillmentPort> deliveryFulfillment;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.application.port.MasterReferenceValidationPort masterReferences;

    public record RequestedLine(UUID goodsId, UUID colorId, UUID orderItemId, UUID shipmentItemId) {}
    /** Only product identity and intent enter discovery; quantities and client BOM paths never define locks. */
    public record ProposedOrderLine(UUID goodsId,UUID colorId,boolean physicalDelivery) {}

    public void lockOrderUpdate(UUID id,Collection<ProposedOrderLine> requested) {
        List<ProposedOrderLine> changes=requested==null?List.of():requested.stream().filter(line->line.goodsId()!=null).toList();
        var roots=changes.stream().map(line->new RequestedLine(line.goodsId(),line.colorId(),null,null)).toList();
        var request=footprint(Document.ORDER,id,roots,List.of(),changes);
        locks.acquire(request.declared(),request.discovery()).verifyUnchanged();
    }

    public void lockOrder(UUID id, Collection<InventoryDimension> requested) {
        List<RequestedLine> lines = requested == null ? List.of() : requested.stream()
                .map(d -> new RequestedLine(d.goodsId(), d.colorId(), null, null)).toList();
        lock(Document.ORDER, id, lines, List.of());
    }

    /** A historical quote may reference several terminated orders; acquire all S locks before any I lock. */
    public void lockOrders(Collection<UUID> orderIds) {
        List<UUID> ids = sorted(new LinkedHashSet<>(orderIds));
        locks.acquireAll(ids.stream().map(id -> footprint(Document.ORDER, id, List.of(), List.of())).toList())
                .verifyUnchanged();
    }

    public UUID lockOrderItem(UUID itemId) {
        List<?> rows = em.createNativeQuery("SELECT order_id FROM sales_order_items WHERE id=:id")
                .setParameter("id", itemId).getResultList();
        if (rows.size()!=1) throw new ApiException(ErrorCode.NOT_FOUND, "订单行不存在");
        UUID orderId = (UUID) rows.getFirst();
        lock(Document.ORDER, orderId, List.of(), List.of(itemId));
        return orderId;
    }

    public void lockShipment(UUID id, Collection<RequestedLine> requested) {
        lock(Document.SHIPMENT, id, requested, List.of());
    }
    @Override public void lockShipment(UUID id) { lockShipment(id,List.of()); }
    public void lockShipmentBatch(Collection<UUID> orderItemIds) {
        lock(Document.SHIPMENT, null, List.of(), orderItemIds);
    }

    /**
     * 出货单财务批量放行 / 批量退回(2026-10-06 修正): 写任何一张之前对全部出货单合并预锁——足迹与逐张
     * {@link #lockShipment} 同一份推导(来源销售订单 + 库存维度), 出货单头按 UUID 序一次上锁。只按第一张
     * 取锁时, 后面几张的来源订单在出货单行锁之后才被锁行写入, 违反「商业来源先于执行对象」。
     */
    public void lockShipments(Collection<UUID> shipmentIds) {
        List<UUID> ids = sorted(shipmentIds.stream().filter(java.util.Objects::nonNull).distinct().toList());
        var guard = locks.acquireAll(ids.stream()
                .map(id -> footprint(Document.SHIPMENT, id, List.of(), List.of())).toList());
        if (!ids.isEmpty()) {
            List<?> found = em.createNativeQuery("SELECT id FROM " + Document.SHIPMENT.header
                    + " WHERE id IN (:ids) ORDER BY id FOR UPDATE").setParameter("ids", ids).getResultList();
            if (found.size()!=ids.size()) throw new ApiException(ErrorCode.NOT_FOUND, "销售单据不存在");
        }
        guard.verifyUnchanged();
    }

    public void lockReturn(UUID id, Collection<RequestedLine> requested) {
        lock(Document.RETURN, id, requested, List.of());
    }
    public FulfillmentMutationLocks.Guard beginReturn(UUID id) {
        return begin(Document.RETURN, id, List.of(), List.of());
    }
    public void lockOtherShipment(UUID id, Collection<RequestedLine> requested) {
        lock(Document.OTHER_SHIPMENT, id, requested, List.of());
    }

    private void lock(Document kind, UUID id, Collection<RequestedLine> requested, Collection<UUID> orderItems) {
        begin(kind,id,requested,orderItems).verifyUnchanged();
    }

    private FulfillmentMutationLocks.Guard begin(Document kind, UUID id, Collection<RequestedLine> requested, Collection<UUID> orderItems) {
        var request = footprint(kind, id, requested, orderItems);
        var guard = locks.acquire(request.declared(), request.discovery());
        // Physical document heads are execution objects: never put them ahead of S/I.
        if (id != null && kind != Document.ORDER) {
            List<?> found = em.createNativeQuery("SELECT id FROM " + kind.header + " WHERE id=:id FOR UPDATE")
                    .setParameter("id", id).getResultList();
            if (found.size()!=1) throw new ApiException(ErrorCode.NOT_FOUND, "销售单据不存在");
        }
        return guard;
    }

    /** 单张入口与批量入口共用的足迹: 声明(嵌套时内存核对) + 发现。 */
    private FulfillmentMutationLocks.Footprint footprint(Document kind, UUID id, Collection<RequestedLine> requested,
            Collection<UUID> orderItems) {
        return footprint(kind,id,requested,orderItems,List.of());
    }
    private FulfillmentMutationLocks.Footprint footprint(Document kind, UUID id, Collection<RequestedLine> requested,
            Collection<UUID> orderItems,Collection<ProposedOrderLine> orderChanges) {
        List<RequestedLine> proposed = requested == null ? List.of() : List.copyOf(requested);
        List<UUID> selected = orderItems == null ? List.of() : List.copyOf(orderItems);
        List<ProposedOrderLine> changes=List.copyOf(orderChanges);
        // ADR-107: 嵌套在已持有预锁的命令里时, 手里已知的订单与请求维度只在内存里核对覆盖。
        var declaredInventory = new LinkedHashSet<InventoryDimension>();
        proposed.forEach(line -> add(declaredInventory, line.goodsId(), line.colorId()));
        var declared = FulfillmentMutationLockPlan.declared(kind == Document.ORDER && id != null
                ? Set.of(new CommercialSource(CommercialType.SALES_ORDER, id)) : Set.of(), declaredInventory, Set.of());
        return new FulfillmentMutationLocks.Footprint(declared, () -> discover(kind, id, proposed, selected,changes));
    }

    private FulfillmentMutationLockPlan discover(Document kind, UUID id,
            List<RequestedLine> requested, List<UUID> selectedOrderItems,List<ProposedOrderLine> orderChanges) {
        var sources = new LinkedHashSet<CommercialSource>();
        var inventory = new LinkedHashSet<InventoryDimension>();
        var orderItems = new LinkedHashSet<>(selectedOrderItems);
        var shipmentItems = new LinkedHashSet<UUID>();
        var parts = new ArrayList<String>();
        parts.add("root:" + kind + ":" + id);
        for (RequestedLine line : requested) {
            parts.add("request:" + line);
            add(inventory, line.goodsId(), line.colorId());
            if (line.orderItemId()!=null) orderItems.add(line.orderItemId());
            if (line.shipmentItemId()!=null) shipmentItems.add(line.shipmentItemId());
        }
        if (id!=null) {
            if (kind==Document.ORDER) sources.add(new CommercialSource(CommercialType.SALES_ORDER,id));
            String orderColumn = kind==Document.ORDER ? "item.id" : "item.order_item_id";
            String shipmentColumn = kind==Document.RETURN ? "item.out_item_id" : "CAST(NULL AS uuid)";
            for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery(
                    "SELECT document.id,item.id,item.goods_id,item.color_id," + orderColumn + ","
                    + shipmentColumn + ",document.xmin::text,item.xmin::text FROM "
                    + kind.header + " document LEFT JOIN " + kind.items + " item ON item." + kind.parent
                    + "=document.id AND item.is_deleted=FALSE WHERE document.id=:id ORDER BY item.id")
                    .setParameter("id",id))) {
                parts.add("root-row:" + java.util.Arrays.toString(row));
                add(inventory,(UUID)row[2],(UUID)row[3]);
                if (row[4]!=null) orderItems.add((UUID)row[4]);
                if (row[5]!=null) shipmentItems.add((UUID)row[5]);
            }
        }
        if (!shipmentItems.isEmpty()) {
            List<Object[]> shipmentRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT item.id,item.order_item_id,item.goods_id,item.color_id,
                           item.xmin::text,shipment.xmin::text
                    FROM sales_shipment_items item JOIN sales_shipments shipment ON shipment.id=item.shipment_id
                    WHERE item.id IN (:ids) ORDER BY item.id
                    """).setParameter("ids",sorted(shipmentItems)));
            if (shipmentRows.size()!=shipmentItems.size()) {
                throw new ApiException(ErrorCode.CONFLICT,"原出货来源不存在，请刷新后重试");
            }
            for (Object[] row : shipmentRows) {
                parts.add("shipment-source:" + java.util.Arrays.toString(row));
                if (row[1]!=null) orderItems.add((UUID)row[1]);
                add(inventory,(UUID)row[2],(UUID)row[3]);
            }
        }
        if (!orderItems.isEmpty()) {
            List<Object[]> orderRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT item.id,item.order_id,item.goods_id,item.color_id,
                           item.xmin::text,document.xmin::text
                    FROM sales_order_items item JOIN sales_orders document ON document.id=item.order_id
                    WHERE item.id IN (:ids) ORDER BY item.id
                    """).setParameter("ids",sorted(orderItems)));
            if (orderRows.size()!=orderItems.size()) {
                throw new ApiException(ErrorCode.CONFLICT,"原订单来源不存在，请刷新后重试");
            }
            for (Object[] row : orderRows) {
                parts.add("order-source:" + java.util.Arrays.toString(row));
                sources.add(new CommercialSource(CommercialType.SALES_ORDER,(UUID)row[1]));
                add(inventory,(UUID)row[2],(UUID)row[3]);
            }
            // Frozen order recipes are part of the complete stock prefix before any execution row lock.
            for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT DISTINCT item.id,node->>'goodsId',node->>'colorId'
                    FROM sales_order_items item
                    CROSS JOIN LATERAL jsonb_path_query(item.delivery_bom_snapshot,'$.root.** ? (@.goodsId != null)') node
                    WHERE item.id IN(:ids) AND (item.delivery_plan->>'mode'='BOM'
                      OR jsonb_array_length(COALESCE(item.delivery_plan->'processes','[]'::jsonb))>0)
                    ORDER BY item.id,node->>'goodsId',node->>'colorId'
                    """).setParameter("ids",sorted(orderItems)))) {
                parts.add("delivery-source:"+java.util.Arrays.toString(row));
                add(inventory,UUID.fromString((String)row[1]),row[2]==null?null:UUID.fromString((String)row[2]));
            }
        }
        if (kind==Document.SHIPMENT && id!=null) {
            for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT id,goods_id,color_id FROM sales_shipment_delivery_components WHERE shipment_id=:id ORDER BY id
                    """).setParameter("id",id))) {
                parts.add("delivery-physical:"+java.util.Arrays.toString(row));
                add(inventory,(UUID)row[1],(UUID)row[2]);
            }
        }
        if(!orderChanges.isEmpty()) discoverProposedOrderDelivery(orderChanges,inventory,parts);
        var base=new FulfillmentMutationLockPlan(sources,inventory,Set.of(),Set.of(),CanonicalFingerprint.sha256(parts));
        if(kind==Document.SHIPMENT&&deliveryFulfillment!=null){
            var bridge=deliveryFulfillment.getIfAvailable();
            if(bridge!=null){
                var dependency=bridge.discover(orderItems,id==null?List.of():List.of(id));
                return FulfillmentMutationLockPlan.merge(CanonicalFingerprint.sha256(List.of(base.fingerprint(),dependency.fingerprint())),List.of(base,dependency));
            }
        }
        return base;
    }

    private void discoverProposedOrderDelivery(List<ProposedOrderLine> changes,Set<InventoryDimension> inventory,List<String> parts) {
        Set<UUID> roots=new LinkedHashSet<>(),physical=new LinkedHashSet<>();
        changes.forEach(line->{roots.add(line.goodsId());if(line.physicalDelivery())physical.add(line.goodsId());});
        // This is a read-only discovery before S/I. Do not acquire the graph transaction lock
        // ahead of inventory: the ordinary save acquires that lock later and revalidates its reviewed fingerprint.
        if(masterReferences==null)throw new ApiException(ErrorCode.CONFLICT,"交付预锁资料校验服务不可用");
        masterReferences.requireVisibleGoodsBatch(roots);
        // Lock the complete proposed delivery configuration before S/I, including
        // PERIODIC goods that an explicit customer frontier may physically ship.
        // The input has no reviewed path selection yet; ordinary no-work intent
        // remains root-only and stored physical snapshots above remain protected.
        var query=em.createNativeQuery("""
            WITH RECURSIVE proposed(root_id) AS (SELECT id FROM goods WHERE id IN(:roots)),
            reachable(root_id,goods_id) AS (
              SELECT root_id,root_id FROM proposed
              UNION SELECT reachable.root_id,edge.component_goods_id FROM reachable
                JOIN goods_bom_items edge ON edge.goods_id=reachable.goods_id AND NOT edge.is_deleted
            ), needed(root_id) AS (
              SELECT proposed.root_id FROM proposed WHERE %s OR EXISTS(
                SELECT 1 FROM reachable JOIN goods_bom_items edge ON edge.goods_id=reachable.goods_id AND NOT edge.is_deleted
                JOIN goods_bom_delivery_rules rule ON rule.bom_edge_id=edge.id
                WHERE reachable.root_id=proposed.root_id AND jsonb_array_length(rule.required_operations)>0)
            )
            SELECT needed.root_id,CAST(NULL AS uuid),CAST(NULL AS uuid),goods.id,goods.color_id,
              '1', 'PER_UNIT', '1',TRUE,FALSE,'PART','[]',goods.unit_id,goods.is_deleted,goods.auto_created,goods.status
            FROM needed JOIN goods ON goods.id=needed.root_id
            UNION ALL
            SELECT reachable.root_id,edge.id,edge.goods_id,component.id,COALESCE(edge.color_id,component.color_id),
              edge.qty::text,edge.consumption_basis,edge.basis_output_qty::text,edge.allow_partial_package,
              COALESCE(rule.mandatory_assembly,FALSE),COALESCE(rule.material_role,'UNCLASSIFIED'),
              COALESCE(rule.required_operations::text,'[]'),component.unit_id,component.is_deleted,component.auto_created,component.status
            FROM reachable JOIN needed ON needed.root_id=reachable.root_id
            JOIN goods_bom_items edge ON edge.goods_id=reachable.goods_id AND NOT edge.is_deleted
            JOIN goods component ON component.id=edge.component_goods_id
            LEFT JOIN goods_bom_delivery_rules rule ON rule.bom_edge_id=edge.id
            ORDER BY 1,2 NULLS FIRST,3,4,5
            """.formatted(physical.isEmpty()?"FALSE":"proposed.root_id IN(:physical)"))
                .setParameter("roots",sorted(roots)).setMaxResults(10001);
        if(!physical.isEmpty())query.setParameter("physical",sorted(physical));
        var rows=NativeQueryResults.objectArrayRows(query);
        if(rows.size()>10000)throw new ApiException(ErrorCode.CONFLICT,"本次交付BOM预锁超过10000条边，请拆单办理");
        Set<UUID> visible=new LinkedHashSet<>();
        for(var row:rows){parts.add("proposed-delivery:"+java.util.Arrays.toString(row));
            visible.add((UUID)row[3]);add(inventory,(UUID)row[3],(UUID)row[4]);}
        if(!visible.isEmpty())masterReferences.requireVisibleGoodsBatch(visible);
    }

    private static void add(Set<InventoryDimension> inventory,UUID goods,UUID color) {
        if (goods!=null) inventory.add(new InventoryDimension(goods,color));
    }
    private static List<UUID> sorted(Collection<UUID> ids) {
        return ids.stream().sorted(Comparator.comparing(UUID::toString)).toList();
    }
    private enum Document {
        ORDER("sales_orders","sales_order_items","order_id"),
        SHIPMENT("sales_shipments","sales_shipment_items","shipment_id"),
        RETURN("sales_returns","sales_return_items","return_id"),
        OTHER_SHIPMENT("sales_other_shipments","sales_other_shipment_items","shipment_id");
        final String header,items,parent;
        Document(String header,String items,String parent) {this.header=header;this.items=items;this.parent=parent;}
    }
}
