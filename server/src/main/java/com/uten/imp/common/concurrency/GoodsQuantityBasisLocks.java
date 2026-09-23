package com.uten.imp.common.concurrency;

import jakarta.persistence.EntityManager;
import java.util.Collection;
import java.util.Objects;
import java.util.UUID;

/** Locks quantity bases before normalization, until the caller writes its source. */
public final class GoodsQuantityBasisLocks {
    private GoodsQuantityBasisLocks() {}

    public static void lockForQuantityUse(EntityManager em, Collection<UUID> goodsIds) {
        if (goodsIds == null) return;
        var ids = goodsIds.stream().filter(Objects::nonNull).distinct().sorted().toList();
        if (ids.isEmpty()) return;
        // FOR KEY SHARE is exactly what the source row's foreign-key check takes, so
        // concurrent writers of the same goods never queue on each other. It still
        // conflicts with the unit-change guard's FOR UPDATE (V651): if the unit edit
        // wins, normalization reads the new committed unit; if this writer wins, the
        // edit waits for its commit and then sees the new quantity reference.
        em.createNativeQuery("""
                SELECT id FROM goods
                WHERE id IN (:ids)
                ORDER BY id FOR KEY SHARE
                """).setParameter("ids", ids).getResultList();
    }
}
