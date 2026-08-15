package com.uten.imp.features.subcontract;

import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import jakarta.persistence.criteria.Subquery;

import java.util.Locale;
import java.util.UUID;

/** Shared list keyword predicate that searches immutable line snapshots. */
public final class SubcontractGoodsKeyword {

    private SubcontractGoodsKeyword() {
    }

    public static <D, I> Predicate predicate(
            CriteriaBuilder cb,
            CriteriaQuery<?> query,
            Root<D> document,
            Class<I> itemType,
            String documentIdAttribute,
            String keyword) {
        String pattern = "%" + keyword.toLowerCase(Locale.ROOT) + "%";
        Subquery<UUID> itemMatch = query.subquery(UUID.class);
        Root<I> item = itemMatch.from(itemType);
        Expression<String> itemName = item.get("goodsNameSnapshot");
        Expression<String> itemCode = item.get("goodsCodeSnapshot");
        itemMatch.select(item.get(documentIdAttribute));
        itemMatch.where(
                cb.equal(item.get(documentIdAttribute), document.get("id")),
                cb.or(
                        cb.like(cb.lower(cb.coalesce(itemName, "")), pattern),
                        cb.like(cb.lower(cb.coalesce(itemCode, "")), pattern)));
        return cb.or(
                cb.like(cb.lower(document.get("billNo")), pattern),
                cb.exists(itemMatch));
    }
}
