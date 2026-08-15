package com.uten.imp.features.subcontract;

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
 * Immutable display identity for one goods UUID on a subcontract document line.
 *
 * <p>The UUID remains authoritative.  Code and name snapshots are copied only so
 * approved history continues to show the identity that was frozen at that point
 * in the document chain.  A linked row is never silently coalesced to today's
 * goods master label.</p>
 */
public record SubcontractGoodsSnapshot(UUID goodsId, String code, String name, String source) {

    public static final String MASTER_AT_SAVE = "MASTER_AT_SAVE";
    public static final String MASTER_AT_APPROVAL = "MASTER_AT_APPROVAL";
    public static final String APPLICATION_ITEM_AT_SAVE = "APPLICATION_ITEM_AT_SAVE";
    public static final String APPLICATION_ITEM_AT_APPROVAL = "APPLICATION_ITEM_AT_APPROVAL";
    public static final String ORDER_ITEM_AT_SAVE = "ORDER_ITEM_AT_SAVE";
    public static final String ORDER_ITEM_AT_APPROVAL = "ORDER_ITEM_AT_APPROVAL";
    public static final String RECEIPT_ITEM_AT_SAVE = "RECEIPT_ITEM_AT_SAVE";
    public static final String RECEIPT_ITEM_AT_APPROVAL = "RECEIPT_ITEM_AT_APPROVAL";
    public static final String MATERIAL_ISSUE_ITEM_AT_SAVE = "MATERIAL_ISSUE_ITEM_AT_SAVE";
    public static final String MATERIAL_ISSUE_ITEM_AT_APPROVAL = "MATERIAL_ISSUE_ITEM_AT_APPROVAL";

    public static Map<UUID, SubcontractGoodsSnapshot> fromMaster(
            EntityManager em, Collection<UUID> goodsIds, String source) {
        List<UUID> ids = distinctIds(goodsIds);
        if (ids.isEmpty()) {
            return Map.of();
        }
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

    public static Map<UUID, SubcontractGoodsSnapshot> fromApplicationItems(
            EntityManager em, Collection<UUID> itemIds, String source) {
        return fromItems(em, itemIds, source, ItemTable.APPLICATION, false);
    }

    public static Map<UUID, SubcontractGoodsSnapshot> fromOrderItems(
            EntityManager em, Collection<UUID> itemIds, String source) {
        return fromItems(em, itemIds, source, ItemTable.ORDER, false);
    }

    public static Map<UUID, SubcontractGoodsSnapshot> fromReceiptItems(
            EntityManager em, Collection<UUID> itemIds, String source) {
        return fromItems(em, itemIds, source, ItemTable.RECEIPT, false);
    }

    public static Map<UUID, SubcontractGoodsSnapshot> fromMaterialIssueItems(
            EntityManager em, Collection<UUID> itemIds, String source) {
        return fromItems(em, itemIds, source, ItemTable.MATERIAL_ISSUE, false);
    }

    public static Map<UUID, SubcontractGoodsSnapshot> fromMaterialIssueParentItems(
            EntityManager em, Collection<UUID> itemIds, String source) {
        return fromItems(em, itemIds, source, ItemTable.MATERIAL_ISSUE, true);
    }

    /**
     * Prefer the linked line's immutable display identity.  An absent optional
     * link falls back to the master snapshot, but a linked line for another UUID
     * is a conflict and never falls back.
     */
    public static SubcontractGoodsSnapshot preferred(
            Map<UUID, SubcontractGoodsSnapshot> upstream,
            UUID upstreamItemId,
            Map<UUID, SubcontractGoodsSnapshot> master,
            UUID goodsId,
            String subject) {
        SubcontractGoodsSnapshot inherited = upstreamItemId == null
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

    public static SubcontractGoodsSnapshot optionalPreferred(
            Map<UUID, SubcontractGoodsSnapshot> upstream,
            UUID upstreamItemId,
            Map<UUID, SubcontractGoodsSnapshot> master,
            UUID goodsId,
            String subject) {
        return goodsId == null
                ? null
                : preferred(upstream, upstreamItemId, master, goodsId, subject);
    }

    public static SubcontractGoodsSnapshot require(
            Map<UUID, SubcontractGoodsSnapshot> snapshots, UUID id, String subject) {
        SubcontractGoodsSnapshot snapshot = id == null ? null : snapshots.get(id);
        if (snapshot == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    subject + "关联的货品主数据不存在，请刷新后重试");
        }
        return snapshot;
    }

    private static Map<UUID, SubcontractGoodsSnapshot> fromItems(
            EntityManager em,
            Collection<UUID> itemIds,
            String source,
            ItemTable table,
            boolean parent) {
        List<UUID> ids = distinctIds(itemIds);
        if (ids.isEmpty()) {
            return Map.of();
        }
        String sql = table.query(parent);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(sql)
                .setParameter("ids", ids)
                .getResultList();
        return snapshots(rows, source);
    }

    private static Map<UUID, SubcontractGoodsSnapshot> snapshots(
            List<Object[]> rows, String source) {
        Map<UUID, SubcontractGoodsSnapshot> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID goodsId = (UUID) row[1];
            if (goodsId != null) {
                result.put(
                        (UUID) row[0],
                        new SubcontractGoodsSnapshot(
                                goodsId, text(row[2]), text(row[3]), source));
            }
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

    private enum ItemTable {
        APPLICATION,
        ORDER,
        RECEIPT,
        MATERIAL_ISSUE;

        String query(boolean parent) {
            if (parent && this != MATERIAL_ISSUE) {
                throw new IllegalArgumentException("Only material issue lines have parent snapshots");
            }
            return switch (this) {
                case APPLICATION -> """
                        SELECT item.id, item.goods_id,
                               item.goods_code_snapshot, item.goods_name_snapshot
                        FROM subcontract_application_items item
                        WHERE item.id IN (:ids)
                        """;
                case ORDER -> """
                        SELECT item.id, item.goods_id,
                               item.goods_code_snapshot, item.goods_name_snapshot
                        FROM subcontract_order_items item
                        WHERE item.id IN (:ids)
                        """;
                case RECEIPT -> """
                        SELECT item.id, item.goods_id,
                               item.goods_code_snapshot, item.goods_name_snapshot
                        FROM subcontract_receipt_items item
                        WHERE item.id IN (:ids)
                        """;
                case MATERIAL_ISSUE -> parent ? """
                        SELECT item.id, item.parent_goods_id,
                               item.parent_goods_code_snapshot,
                               item.parent_goods_name_snapshot
                        FROM subcontract_material_issue_items item
                        WHERE item.id IN (:ids)
                        """ : """
                        SELECT item.id, item.goods_id,
                               item.goods_code_snapshot, item.goods_name_snapshot
                        FROM subcontract_material_issue_items item
                        WHERE item.id IN (:ids)
                        """;
            };
        }
    }
}
