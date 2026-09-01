package com.uten.imp.features.warehouse.history;

/**
 * Warehouse-only history projection authorities.
 *
 * <p>These authorities deliberately do not reuse purchase/subcontract document view or
 * commercial-field authorities. Granting one of them permits only the corresponding
 * amount-free warehouse history projection.</p>
 */
public final class WarehouseHistoryPermissions {

    public static final String PURCHASE_RECEIPT_VIEW =
            "warehouse_purchase_receipt_history:view";
    public static final String SUBCONTRACT_RECEIPT_VIEW =
            "warehouse_subcontract_receipt_history:view";
    public static final String SUBCONTRACT_MATERIAL_ISSUE_VIEW =
            "warehouse_subcontract_outbound_history:view";
    public static final String SUBCONTRACT_RETURN_VIEW =
            "warehouse_subcontract_finished_return_history:view";
    public static final String SUBCONTRACT_MATERIAL_RETURN_VIEW =
            "warehouse_subcontract_material_return_history:view";
    public static final String SUBCONTRACT_WASTE_VIEW =
            "warehouse_subcontract_waste_history:view";

    private WarehouseHistoryPermissions() {
    }
}
