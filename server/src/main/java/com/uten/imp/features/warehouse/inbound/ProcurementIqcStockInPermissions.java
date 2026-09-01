package com.uten.imp.features.warehouse.inbound;

/** Exact authorities for the warehouse-owned IQC stock-in surface. */
public final class ProcurementIqcStockInPermissions {
    public static final String VIEW = "warehouse_iqc_stock_in:view";
    public static final String CONFIRM = "warehouse_iqc_stock_in:confirm";

    private ProcurementIqcStockInPermissions() {
    }
}
