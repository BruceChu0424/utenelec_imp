package com.uten.imp.features.warehouse.inbound;

/** Exact authorities for the warehouse-owned IQC stock-in surface. */
public final class ProcurementIqcStockInPermissions {
    public static final String VIEW = "warehouse_iqc_stock_in:view";
    public static final String CONFIRM = "warehouse_iqc_stock_in:confirm";
    /** 先入库后检(V596)：品质结论前把到货上架到实际叶仓与库位；独立于 confirm，可单独回收。 */
    public static final String BEFORE_INSPECTION = "warehouse_iqc_stock_in:before_inspection";

    private ProcurementIqcStockInPermissions() {
    }
}
