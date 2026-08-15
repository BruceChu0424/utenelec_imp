package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.time.OffsetDateTime;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Immutable display snapshot for stock document lines.
 *
 * <p>The goods UUID remains authoritative for inventory and document relations.
 * Stock documents deliberately do not infer snapshot authority from the
 * polymorphic upstream fields; save and approval both read the goods master.</p>
 */
public record StockGoodsSnapshot(UUID goodsId, String code, String name, String source) {

    public static final String MASTER_AT_SAVE = "MASTER_AT_SAVE";
    public static final String MASTER_AT_APPROVAL = "MASTER_AT_APPROVAL";

    public static Map<UUID, StockGoodsSnapshot> fromMaster(
            EntityManager em, Collection<UUID> goodsIds, String source) {
        List<UUID> ids = distinctIds(goodsIds);
        if (ids.isEmpty()) {
            return Map.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT goods.id, goods.code, goods.name
                FROM goods
                WHERE goods.id IN (:ids)
                """)
                .setParameter("ids", ids)
                .getResultList();
        Map<UUID, StockGoodsSnapshot> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID goodsId = (UUID) row[0];
            result.put(
                    goodsId,
                    new StockGoodsSnapshot(
                            goodsId, text(row[1]), text(row[2]), source));
        }
        return result;
    }

    public static StockGoodsSnapshot require(
            Map<UUID, StockGoodsSnapshot> snapshots, UUID goodsId, String subject) {
        StockGoodsSnapshot snapshot = goodsId == null ? null : snapshots.get(goodsId);
        if (snapshot == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    subject + "关联的货品主数据不存在，请刷新后重试");
        }
        return snapshot;
    }

    public void applyTo(StockDocumentItem item, OffsetDateTime lockedAt) {
        if (!Objects.equals(goodsId, item.getGoodsId())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "仓库单据明细货品与快照不一致，请刷新后重试");
        }
        item.setGoodsCodeSnapshot(code);
        item.setGoodsNameSnapshot(name);
        item.setGoodsSnapshotSource(source);
        item.setGoodsSnapshotLockedAt(lockedAt);
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
