package com.uten.imp.features.purchase;

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
 * Immutable display snapshot used by purchase document lines.
 *
 * <p>The goods UUID remains authoritative for business logic. Code and name are
 * copied only so approved history keeps the labels users saw when the document
 * was frozen. Linked documents inherit the nearest upstream line snapshot.</p>
 */
public record PurchaseGoodsSnapshot(UUID goodsId, String code, String name, String source) {

    public static final String MASTER_AT_SAVE = "MASTER_AT_SAVE";
    public static final String MASTER_AT_APPROVAL = "MASTER_AT_APPROVAL";
    public static final String REQUEST_ITEM_AT_SAVE = "REQUEST_ITEM_AT_SAVE";
    public static final String REQUEST_ITEM_AT_APPROVAL = "REQUEST_ITEM_AT_APPROVAL";
    public static final String ORDER_ITEM_AT_SAVE = "ORDER_ITEM_AT_SAVE";
    public static final String ORDER_ITEM_AT_APPROVAL = "ORDER_ITEM_AT_APPROVAL";
    public static final String RECEIPT_ITEM_AT_SAVE = "RECEIPT_ITEM_AT_SAVE";
    public static final String RECEIPT_ITEM_AT_APPROVAL = "RECEIPT_ITEM_AT_APPROVAL";

    public static Map<UUID, PurchaseGoodsSnapshot> fromMaster(
            EntityManager em, Collection<UUID> goodsIds, String source) {
        List<UUID> ids = distinctIds(goodsIds);
        if (ids.isEmpty()) {
            return Map.of();
        }
        com.uten.imp.common.concurrency.GoodsQuantityBasisLocks.lockUnused(em, ids);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT goods.id, goods.id, goods.code, goods.name
                FROM goods
                WHERE goods.id IN (:ids)
                """)
                .setParameter("ids", ids)
                .getResultList();
        return snapshots(rows, source);
    }

    public static Map<UUID, PurchaseGoodsSnapshot> fromRequestItems(
            EntityManager em, Collection<UUID> itemIds, String source) {
        return fromItems(em, distinctIds(itemIds), source, "purchase_request_items");
    }

    public static Map<UUID, PurchaseGoodsSnapshot> fromOrderItems(
            EntityManager em, Collection<UUID> itemIds, String source) {
        return fromItems(em, distinctIds(itemIds), source, "purchase_order_items");
    }

    public static Map<UUID, PurchaseGoodsSnapshot> fromReceiptItems(
            EntityManager em, Collection<UUID> itemIds, String source) {
        return fromItems(em, distinctIds(itemIds), source, "purchase_receipt_items");
    }

    /**
     * Prefer a matching upstream snapshot. A genuinely absent link falls back to
     * the current master snapshot; a linked row for another goods UUID is rejected.
     */
    public static PurchaseGoodsSnapshot preferred(
            Map<UUID, PurchaseGoodsSnapshot> upstream,
            UUID upstreamItemId,
            Map<UUID, PurchaseGoodsSnapshot> master,
            UUID goodsId,
            String subject) {
        PurchaseGoodsSnapshot inherited = upstreamItemId == null
                ? null
                : upstream.get(upstreamItemId);
        if (inherited != null) {
            if (!Objects.equals(inherited.goodsId(), goodsId)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        subject + "关联明细的货品与当前行不一致，请刷新后重试");
            }
            return inherited;
        }
        return require(master, goodsId, subject);
    }

    public static PurchaseGoodsSnapshot require(
            Map<UUID, PurchaseGoodsSnapshot> snapshots, UUID id, String subject) {
        PurchaseGoodsSnapshot snapshot = id == null ? null : snapshots.get(id);
        if (snapshot == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    subject + "关联的货品主数据不存在，请刷新后重试");
        }
        return snapshot;
    }

    private static Map<UUID, PurchaseGoodsSnapshot> fromItems(
            EntityManager em, List<UUID> ids, String source, String table) {
        if (ids.isEmpty()) {
            return Map.of();
        }
        String sql = switch (table) {
            case "purchase_request_items" -> """
                    SELECT item.id, item.goods_id,
                           item.goods_code_snapshot, item.goods_name_snapshot
                    FROM purchase_request_items item
                    WHERE item.id IN (:ids)
                    """;
            case "purchase_order_items" -> """
                    SELECT item.id, item.goods_id,
                           item.goods_code_snapshot, item.goods_name_snapshot
                    FROM purchase_order_items item
                    WHERE item.id IN (:ids)
                    """;
            case "purchase_receipt_items" -> """
                    SELECT item.id, item.goods_id,
                           item.goods_code_snapshot, item.goods_name_snapshot
                    FROM purchase_receipt_items item
                    WHERE item.id IN (:ids)
                    """;
            default -> throw new IllegalArgumentException("Unsupported purchase snapshot table");
        };
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(sql)
                .setParameter("ids", ids)
                .getResultList();
        return snapshots(rows, source);
    }

    private static Map<UUID, PurchaseGoodsSnapshot> snapshots(
            List<Object[]> rows, String source) {
        Map<UUID, PurchaseGoodsSnapshot> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            result.put(
                    (UUID) row[0],
                    new PurchaseGoodsSnapshot(
                            (UUID) row[1], text(row[2]), text(row[3]), source));
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
