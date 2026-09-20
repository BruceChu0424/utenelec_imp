package com.uten.imp.features.warehouse;

/** Shared eligibility for a goods-master destination suggestion; historical receipts never override it. */
public final class WarehouseMasterDefaultsSql {
    private WarehouseMasterDefaultsSql() {}

    public static String owningWarehouseJoin(String goods, String warehouse) {
        if (!goods.matches("[a-z][a-z0-9_]*") || !warehouse.matches("[a-z][a-z0-9_]*")) {
            throw new IllegalArgumentException("SQL aliases must be fixed identifiers");
        }
        return "LEFT JOIN warehouses " + warehouse + " ON " + warehouse + ".id=" + goods + ".owning_warehouse_id\n"
                + " AND NOT " + goods + ".is_deleted\n"
                + " AND fn_warehouse_is_active_accounting_leaf(" + warehouse + ".id)\n";
    }
}
