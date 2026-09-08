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
public class SalesMutationFootprintService {
    private final EntityManager em;
    private final FulfillmentMutationLocks locks;

    public record RequestedLine(UUID goodsId, UUID colorId, UUID orderItemId, UUID shipmentItemId) {}

    public void lockOrder(UUID id, Collection<InventoryDimension> requested) {
        List<RequestedLine> lines = requested == null ? List.of() : requested.stream()
                .map(d -> new RequestedLine(d.goodsId(), d.colorId(), null, null)).toList();
        lock(Document.ORDER, id, lines, List.of());
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
    public void lockShipmentBatch(Collection<UUID> orderItemIds) {
        lock(Document.SHIPMENT, null, List.of(), orderItemIds);
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
        List<RequestedLine> proposed = requested == null ? List.of() : List.copyOf(requested);
        List<UUID> selected = orderItems == null ? List.of() : List.copyOf(orderItems);
        var guard = locks.acquire(() -> discover(kind, id, proposed, selected));
        // Physical document heads are execution objects: never put them ahead of S/I.
        if (id != null && kind != Document.ORDER) {
            List<?> found = em.createNativeQuery("SELECT id FROM " + kind.header + " WHERE id=:id FOR UPDATE")
                    .setParameter("id", id).getResultList();
            if (found.size()!=1) throw new ApiException(ErrorCode.NOT_FOUND, "销售单据不存在");
        }
        return guard;
    }

    private FulfillmentMutationLockPlan discover(Document kind, UUID id,
            List<RequestedLine> requested, List<UUID> selectedOrderItems) {
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
                    + shipmentColumn + ",md5(to_jsonb(document)::text),md5(to_jsonb(item)::text) FROM "
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
                           md5(to_jsonb(item)::text),md5(to_jsonb(shipment)::text)
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
                           md5(to_jsonb(item)::text),md5(to_jsonb(document)::text)
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
        }
        return new FulfillmentMutationLockPlan(sources,inventory,Set.of(),Set.of(),CanonicalFingerprint.sha256(parts));
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
