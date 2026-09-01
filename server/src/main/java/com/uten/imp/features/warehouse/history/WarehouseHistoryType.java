package com.uten.imp.features.warehouse.history;

/**
 * Fixed warehouse history sources.
 *
 * <p>Table names and SQL expressions are compile-time constants selected only by controller
 * methods. No request value is ever interpreted as a table name or SQL fragment.</p>
 */
enum WarehouseHistoryType {
    PURCHASE_RECEIPT(
            "purchase-receipts",
            WarehouseHistoryPermissions.PURCHASE_RECEIPT_VIEW,
            "purchase_receipts",
            "purchase_receipt_items",
            "receipt_id",
            "h.maker_name",
            "h.approver_name",
            "COALESCE(i.returned_qty, 0::numeric)",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "inspection.passed_base_qty",
            "inspection.failed_base_qty",
            "CASE WHEN inspection.id IS NULL AND h.status = 0 THEN 'NOT_SUBMITTED'"
                    + " WHEN inspection.id IS NULL AND h.status = 1 THEN 'LEGACY_NO_IQC'"
                    + " ELSE inspection.status END",
            "COALESCE(NULLIF(i.order_no, ''), NULLIF(i.source_doc_no, ''), NULLIF(h.source_doc_no, ''))",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::text",
            "NULL::numeric",
            "NULL::text",
            "NULL::text",
            "",
            "LEFT JOIN procurement_inspection_items inspection"
                    + " ON inspection.receipt_type = 'PURCHASE'"
                    + " AND inspection.receipt_item_id = i.id"),
    SUBCONTRACT_RECEIPT(
            "subcontract-receipts",
            WarehouseHistoryPermissions.SUBCONTRACT_RECEIPT_VIEW,
            "subcontract_receipts",
            "subcontract_receipt_items",
            "receipt_id",
            "h.maker_name",
            "h.approver_name",
            "COALESCE(i.returned_qty, 0::numeric)",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "inspection.passed_base_qty",
            "inspection.failed_base_qty",
            "CASE WHEN inspection.id IS NULL AND h.status = 0 THEN 'NOT_SUBMITTED'"
                    + " WHEN inspection.id IS NULL AND h.status = 1 THEN 'LEGACY_NO_IQC'"
                    + " ELSE inspection.status END",
            "COALESCE(NULLIF(i.order_no, ''), NULLIF(i.source_doc_no, ''), NULLIF(h.source_doc_no, ''))",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::text",
            "NULL::numeric",
            "NULL::text",
            "NULL::text",
            "",
            "LEFT JOIN procurement_inspection_items inspection"
                    + " ON inspection.receipt_type = 'SUBCONTRACT'"
                    + " AND inspection.receipt_item_id = i.id"),
    SUBCONTRACT_MATERIAL_ISSUE(
            "subcontract-material-issues",
            WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_ISSUE_VIEW,
            "subcontract_material_issues",
            "subcontract_material_issue_items",
            "issue_id",
            "h.maker_name",
            "h.approver_name",
            "COALESCE(i.returned_qty, 0::numeric)",
            "COALESCE(i.wasted_qty, 0::numeric)",
            "COALESCE(i.at_supplier_qty, 0::numeric)",
            "COALESCE(i.consumed_qty, 0::numeric)",
            "i.supplier_ending",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::text",
            "COALESCE(NULLIF(i.order_no, ''), NULLIF(i.source_doc_no, ''), NULLIF(h.source_doc_no, ''))",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::text",
            "i.box_qty",
            "COALESCE(NULLIF(i.parent_goods_code_snapshot, ''), parent_goods.code)",
            "COALESCE(NULLIF(i.parent_goods_name_snapshot, ''), parent_goods.name)",
            "LEFT JOIN goods parent_goods ON parent_goods.id = i.parent_goods_id",
            ""),
    SUBCONTRACT_RETURN(
            "subcontract-returns",
            WarehouseHistoryPermissions.SUBCONTRACT_RETURN_VIEW,
            "subcontract_returns",
            "subcontract_return_items",
            "return_id",
            "h.maker_name",
            "h.approver_name",
            "i.qty",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::text",
            "COALESCE(NULLIF(i.receipt_no, ''), NULLIF(i.order_no, ''), NULLIF(i.source_doc_no, ''), NULLIF(h.source_doc_no, ''))",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::text",
            "NULL::numeric",
            "NULL::text",
            "NULL::text",
            "",
            ""),
    SUBCONTRACT_MATERIAL_RETURN(
            "subcontract-material-returns",
            WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_RETURN_VIEW,
            "subcontract_material_returns",
            "subcontract_material_return_items",
            "material_return_id",
            "h.maker_name",
            "h.approver_name",
            "i.qty",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::text",
            "COALESCE(NULLIF(i.issue_no, ''), NULLIF(i.order_no, ''), NULLIF(i.source_doc_no, ''), NULLIF(h.source_doc_no, ''))",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::text",
            "NULL::numeric",
            "COALESCE(NULLIF(i.parent_goods_code_snapshot, ''), parent_goods.code)",
            "COALESCE(NULLIF(i.parent_goods_name_snapshot, ''), parent_goods.name)",
            "LEFT JOIN goods parent_goods ON parent_goods.id = i.parent_goods_id",
            ""),
    SUBCONTRACT_WASTE(
            "subcontract-wastes",
            WarehouseHistoryPermissions.SUBCONTRACT_WASTE_VIEW,
            "subcontract_wastes",
            "subcontract_waste_items",
            "waste_id",
            "NULL::text",
            "NULL::text",
            "NULL::numeric",
            "i.qty",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::numeric",
            "NULL::text",
            "COALESCE(NULLIF(i.source_doc_no, ''), NULLIF(h.source_doc_no, ''))",
            "i.ending_qty",
            "i.standard_qty",
            "i.waste_rate",
            "i.cause",
            "NULL::numeric",
            "NULL::text",
            "NULL::text",
            "",
            "");

    private final String pathSegment;
    private final String permission;
    private final String headerTable;
    private final String itemTable;
    private final String itemForeignKey;
    private final String legacyMakerNameExpression;
    private final String legacyApproverNameExpression;
    private final String returnedQuantityExpression;
    private final String wastedQuantityExpression;
    private final String atSupplierQuantityExpression;
    private final String consumedQuantityExpression;
    private final String supplierEndingQuantityExpression;
    private final String iqcPassedQuantityExpression;
    private final String iqcFailedQuantityExpression;
    private final String iqcStatusExpression;
    private final String referenceDocumentExpression;
    private final String endingQuantityExpression;
    private final String standardQuantityExpression;
    private final String wasteRateExpression;
    private final String reasonExpression;
    private final String boxQuantityExpression;
    private final String parentGoodsCodeExpression;
    private final String parentGoodsNameExpression;
    private final String parentGoodsJoin;
    private final String inspectionJoin;

    WarehouseHistoryType(
            String pathSegment,
            String permission,
            String headerTable,
            String itemTable,
            String itemForeignKey,
            String legacyMakerNameExpression,
            String legacyApproverNameExpression,
            String returnedQuantityExpression,
            String wastedQuantityExpression,
            String atSupplierQuantityExpression,
            String consumedQuantityExpression,
            String supplierEndingQuantityExpression,
            String iqcPassedQuantityExpression,
            String iqcFailedQuantityExpression,
            String iqcStatusExpression,
            String referenceDocumentExpression,
            String endingQuantityExpression,
            String standardQuantityExpression,
            String wasteRateExpression,
            String reasonExpression,
            String boxQuantityExpression,
            String parentGoodsCodeExpression,
            String parentGoodsNameExpression,
            String parentGoodsJoin,
            String inspectionJoin) {
        this.pathSegment = pathSegment;
        this.permission = permission;
        this.headerTable = headerTable;
        this.itemTable = itemTable;
        this.itemForeignKey = itemForeignKey;
        this.legacyMakerNameExpression = legacyMakerNameExpression;
        this.legacyApproverNameExpression = legacyApproverNameExpression;
        this.returnedQuantityExpression = returnedQuantityExpression;
        this.wastedQuantityExpression = wastedQuantityExpression;
        this.atSupplierQuantityExpression = atSupplierQuantityExpression;
        this.consumedQuantityExpression = consumedQuantityExpression;
        this.supplierEndingQuantityExpression = supplierEndingQuantityExpression;
        this.iqcPassedQuantityExpression = iqcPassedQuantityExpression;
        this.iqcFailedQuantityExpression = iqcFailedQuantityExpression;
        this.iqcStatusExpression = iqcStatusExpression;
        this.referenceDocumentExpression = referenceDocumentExpression;
        this.endingQuantityExpression = endingQuantityExpression;
        this.standardQuantityExpression = standardQuantityExpression;
        this.wasteRateExpression = wasteRateExpression;
        this.reasonExpression = reasonExpression;
        this.boxQuantityExpression = boxQuantityExpression;
        this.parentGoodsCodeExpression = parentGoodsCodeExpression;
        this.parentGoodsNameExpression = parentGoodsNameExpression;
        this.parentGoodsJoin = parentGoodsJoin;
        this.inspectionJoin = inspectionJoin;
    }

    String pathSegment() {
        return pathSegment;
    }

    String permission() {
        return permission;
    }

    String headerTable() {
        return headerTable;
    }

    String itemTable() {
        return itemTable;
    }

    String itemForeignKey() {
        return itemForeignKey;
    }

    String legacyMakerNameExpression() {
        return legacyMakerNameExpression;
    }

    String legacyApproverNameExpression() {
        return legacyApproverNameExpression;
    }

    String returnedQuantityExpression() {
        return returnedQuantityExpression;
    }

    String wastedQuantityExpression() {
        return wastedQuantityExpression;
    }

    String atSupplierQuantityExpression() {
        return atSupplierQuantityExpression;
    }

    String consumedQuantityExpression() {
        return consumedQuantityExpression;
    }

    String supplierEndingQuantityExpression() {
        return supplierEndingQuantityExpression;
    }

    String iqcPassedQuantityExpression() {
        return iqcPassedQuantityExpression;
    }

    String iqcStockedQuantityExpression() {
        return iqcPassedQuantityExpression.contains("inspection.")
                ? "inspection.warehouse_stocked_base_qty"
                : "NULL::numeric";
    }

    String iqcPendingStockInQuantityExpression() {
        return iqcPassedQuantityExpression.contains("inspection.")
                ? "GREATEST(inspection.passed_base_qty"
                    + " - inspection.warehouse_stocked_base_qty, 0)"
                : "NULL::numeric";
    }

    String iqcFailedQuantityExpression() {
        return iqcFailedQuantityExpression;
    }

    String iqcStatusExpression() {
        return iqcStatusExpression;
    }

    String referenceDocumentExpression() {
        return referenceDocumentExpression;
    }

    String endingQuantityExpression() {
        return endingQuantityExpression;
    }

    String standardQuantityExpression() {
        return standardQuantityExpression;
    }

    String wasteRateExpression() {
        return wasteRateExpression;
    }

    String reasonExpression() {
        return reasonExpression;
    }

    String boxQuantityExpression() {
        return boxQuantityExpression;
    }

    String parentGoodsCodeExpression() {
        return parentGoodsCodeExpression;
    }

    String parentGoodsNameExpression() {
        return parentGoodsNameExpression;
    }

    String parentGoodsJoin() {
        return parentGoodsJoin;
    }

    String inspectionJoin() {
        return inspectionJoin;
    }
}
