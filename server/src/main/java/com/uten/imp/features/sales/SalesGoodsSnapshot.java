package com.uten.imp.features.sales;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Immutable display snapshot used by sales document lines.
 *
 * <p>The UUID relation remains authoritative for business logic. Code and name are copied only so
 * approved history keeps the labels that users saw when the document was frozen.</p>
 */
public record SalesGoodsSnapshot(String code, String name, String source) {

    public static final String MASTER_AT_SAVE = "MASTER_AT_SAVE";
    public static final String MASTER_AT_APPROVAL = "MASTER_AT_APPROVAL";
    public static final String ORDER_ITEM_AT_SAVE = "ORDER_ITEM_AT_SAVE";
    public static final String ORDER_ITEM_AT_APPROVAL = "ORDER_ITEM_AT_APPROVAL";
    public static final String SHIPMENT_ITEM_AT_SAVE = "SHIPMENT_ITEM_AT_SAVE";
    public static final String SHIPMENT_ITEM_AT_APPROVAL = "SHIPMENT_ITEM_AT_APPROVAL";

    public static Map<UUID, SalesGoodsSnapshot> fromMaster(
            EntityManager em, Collection<UUID> goodsIds, String source) {
        List<UUID> ids = distinctIds(goodsIds);
        if (ids.isEmpty()) {
            return Map.of();
        }
        com.uten.imp.common.concurrency.GoodsQuantityBasisLocks.lockUnused(em, ids);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT goods.id, goods.code, goods.name
                FROM goods
                WHERE goods.id IN (:ids)
                """)
                .setParameter("ids", ids)
                .getResultList();
        return snapshots(rows, source);
    }

    public static Map<UUID, SalesGoodsSnapshot> fromOrderItems(
            EntityManager em, Collection<UUID> orderItemIds, String source) {
        List<UUID> ids = distinctIds(orderItemIds);
        if (ids.isEmpty()) {
            return Map.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT item.id, item.goods_code_snapshot, item.goods_name_snapshot
                FROM sales_order_items item
                WHERE item.id IN (:ids)
                """)
                .setParameter("ids", ids)
                .getResultList();
        return snapshots(rows, source);
    }

    public static Map<UUID, SalesGoodsSnapshot> fromShipmentItems(
            EntityManager em, Collection<UUID> shipmentItemIds, String source) {
        List<UUID> ids = distinctIds(shipmentItemIds);
        if (ids.isEmpty()) {
            return Map.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT item.id, item.goods_code_snapshot, item.goods_name_snapshot
                FROM sales_shipment_items item
                WHERE item.id IN (:ids)
                """)
                .setParameter("ids", ids)
                .getResultList();
        return snapshots(rows, source);
    }

    public static SalesGoodsSnapshot require(
            Map<UUID, SalesGoodsSnapshot> snapshots, UUID id, String subject) {
        SalesGoodsSnapshot snapshot = id == null ? null : snapshots.get(id);
        if (snapshot == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    subject + "关联的货品历史快照不存在，请刷新后重试");
        }
        return snapshot;
    }

    private static Map<UUID, SalesGoodsSnapshot> snapshots(
            List<Object[]> rows, String source) {
        Map<UUID, SalesGoodsSnapshot> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            result.put(
                    (UUID) row[0],
                    new SalesGoodsSnapshot(text(row[1]), text(row[2]), source));
        }
        return result;
    }

    private static List<UUID> distinctIds(Collection<UUID> ids) {
        if (ids == null || ids.isEmpty()) {
            return List.of();
        }
        LinkedHashSet<UUID> distinct = new LinkedHashSet<>();
        for (UUID id : ids) {
            if (id != null) {
                distinct.add(id);
            }
        }
        return List.copyOf(distinct);
    }

    private static String text(Object value) {
        return value == null ? null : Objects.toString(value);
    }
}
