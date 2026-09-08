package com.uten.imp.common.concurrency;

import jakarta.persistence.EntityManager;
import java.util.Collection;
import java.util.Objects;
import java.util.UUID;

/** Locks mutable quantity bases before normalization, until the caller writes its source. */
public final class GoodsQuantityBasisLocks {
    private GoodsQuantityBasisLocks() {}

    public static void lockUnused(EntityManager em, Collection<UUID> goodsIds) {
        if (goodsIds == null) return;
        var ids = goodsIds.stream().filter(Objects::nonNull).distinct().sorted().toList();
        if (ids.isEmpty()) return;
        // A used basis is immutable, so hot goods do not serialize new business.
        // An unused basis must be read only after this lock: if its edit wins,
        // subsequent normalization sees the new committed UUID, not an old row.
        em.createNativeQuery("""
                SELECT id FROM goods
                WHERE id IN (:ids) AND NOT quantity_unit_locked
                ORDER BY id FOR NO KEY UPDATE
                """).setParameter("ids", ids).getResultList();
    }
}
