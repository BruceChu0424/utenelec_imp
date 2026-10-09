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

    /**
     * 全行可搜（2026-10-09「行里显示什么就能按什么搜」）：单据号 + 明细货品快照
     * + 委外商名称/编号 + 执行仓库名称。八种委外单据实体统一 supplierId /
     * warehouseId 字段，名称经主档子查询翻译成外键 IN；JPA count 同谓词派生。
     */
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
        Subquery<UUID> suppliers = query.subquery(UUID.class);
        Root<com.uten.imp.features.master.supplier.Supplier> supplier =
                suppliers.from(com.uten.imp.features.master.supplier.Supplier.class);
        suppliers.select(supplier.get("id")).where(
                cb.isFalse(supplier.get("deleted")),
                cb.or(
                        cb.like(cb.lower(supplier.get("name")), pattern),
                        cb.like(cb.lower(supplier.get("code")), pattern)));
        Subquery<UUID> warehouses = query.subquery(UUID.class);
        Root<com.uten.imp.features.master.warehouse.Warehouse> warehouse =
                warehouses.from(com.uten.imp.features.master.warehouse.Warehouse.class);
        warehouses.select(warehouse.get("id")).where(
                cb.isFalse(warehouse.get("deleted")),
                cb.like(cb.lower(warehouse.get("name")), pattern));
        return cb.or(
                cb.like(cb.lower(document.get("billNo")), pattern),
                cb.exists(itemMatch),
                document.get("supplierId").in(suppliers),
                document.get("warehouseId").in(warehouses));
    }
}
