package com.uten.imp.features.warehouse.history;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.util.TaskKeywordSearch;

/** Fixed, enum-selected SQL builders for the amount-free warehouse history projection. */
final class WarehouseHistoryQueries {

    private WarehouseHistoryQueries() {
    }

    static String listSql(WarehouseHistoryType type) {
        return listSql(type, DEFAULT_ORDER_BY);
    }

    /** 2026-09-25 单号列统一：列表排序接白名单 ORDER BY（未知/空回落默认单据日期倒序）。 */
    static String listSql(WarehouseHistoryType type, String orderBy) {
        return listSql(type, orderBy, WarehouseTaskScope.ALL);
    }

    static String listSql(WarehouseHistoryType type, String orderBy, WarehouseTaskScope scope) {
        String rank = TaskKeywordSearch.rankNamesFirstParameter("keyword", new String[]{}, new String[]{"history_goods.goods_names"},
                new String[]{"h.bill_no", "h.source_doc_no"}, "history_goods.goods_codes");
        return headerSelect(type) + ", line.id AS item_id,line.line_no,"
                + "COALESCE(NULLIF(line.goods_code_snapshot,''),goods.code),"
                + "COALESCE(NULLIF(line.goods_name_snapshot,''),goods.name),goods.spec,"
                + "color.name,unit.name,line.qty,line.weight "
                + lineJoins(type, scope) + where(true) + lineScopeFilter(type, scope)
                + orderBy.strip().replace("ORDER BY ", "ORDER BY " + rank + ", ")
                + ", line.line_no NULLS LAST,line.id\n" + """
                LIMIT :limit OFFSET :offset
                """;
    }

    /** 默认排序（单据日期倒序, 单号/id 稳定序）。 */
    static final String DEFAULT_ORDER_BY =
            "ORDER BY h.bill_date DESC, h.bill_no DESC, h.id DESC\n";

    /** 排序白名单（2026-09-25 单号列统一）：前端列 key→ORDER BY 表达式；
     *  未知/空回落 [DEFAULT_ORDER_BY]。 */
    static String orderBy(String sort, String order) {
        String dir = "desc".equalsIgnoreCase(order) ? "DESC" : "ASC";
        return switch (sort == null ? "" : sort) {
            case "billNo" -> "ORDER BY h.bill_no " + dir
                    + " NULLS LAST, h.bill_date DESC, h.id DESC\n";
            case "sourceDocNo" -> "ORDER BY h.source_doc_no " + dir
                    + " NULLS LAST, h.bill_date DESC, h.id DESC\n";
            default -> DEFAULT_ORDER_BY;
        };
    }

    /** 单号 facets（2026-09-25 单号列统一）：与列表同一 FROM/WHERE（同一过滤基座），
     *  按表达式分组计数；上限 500 桶由调用方 setMaxResults 收口。 */
    static String facetsSql(WarehouseHistoryType type, String expr) {
        return facetsSql(type, expr, WarehouseTaskScope.ALL);
    }

    static String facetsSql(WarehouseHistoryType type, String expr, WarehouseTaskScope scope) {
        return "SELECT " + expr + ", COUNT(*) " + lineJoins(type, scope)
                + where(true) + lineScopeFilter(type, scope) + " GROUP BY 1 ORDER BY 1\n";
    }

    static String countSql(WarehouseHistoryType type) {
        return countSql(type, WarehouseTaskScope.ALL);
    }

    static String countSql(WarehouseHistoryType type, WarehouseTaskScope scope) {
        return "SELECT COUNT(*) " + lineJoins(type, scope) + where(true) + lineScopeFilter(type, scope);
    }

    static String detailHeaderSql(WarehouseHistoryType type) {
        return detailHeaderSql(type, WarehouseTaskScope.ALL);
    }

    static String detailHeaderSql(WarehouseHistoryType type, WarehouseTaskScope scope) {
        return headerSelect(type) + searchJoins(type) + """
                WHERE COALESCE(h.is_deleted, FALSE) = FALSE
                  AND h.id = :id
                """ + scopeFilter(type, scope);
    }

    static String detailLinesSql(WarehouseHistoryType type) {
        return detailLinesSql(type, WarehouseTaskScope.ALL);
    }

    static String detailLinesSql(WarehouseHistoryType type, WarehouseTaskScope scope) {
        return """
                SELECT i.id,
                       i.line_no,
                       i.goods_id,
                       COALESCE(NULLIF(i.goods_code_snapshot, ''), goods.code) AS goods_code,
                       COALESCE(NULLIF(i.goods_name_snapshot, ''), goods.name) AS goods_name,
                       goods.stock_place,
                       color.name AS color_name,
                       unit.name AS unit_name,
                       i.qty,
                       i.weight,
                       %s AS returned_quantity,
                       %s AS wasted_quantity,
                       %s AS at_supplier_quantity,
                       %s AS consumed_quantity,
                       %s AS supplier_ending_quantity,
                       %s AS iqc_passed_base_quantity,
                       %s AS iqc_stocked_base_quantity,
                       %s AS iqc_pending_stock_in_base_quantity,
                       %s AS iqc_failed_base_quantity,
                       %s AS iqc_status,
                       %s AS reference_document_no,
                       %s AS ending_quantity,
                       %s AS standard_quantity,
                       %s AS waste_rate,
                       %s AS reason,
                       %s AS box_quantity,
                       %s AS parent_goods_code,
                       %s AS parent_goods_name,
                       %s AS parent_color_name
                FROM %s i
                JOIN %s h ON h.id = i.%s
                LEFT JOIN goods goods ON goods.id = i.goods_id
                LEFT JOIN colors color ON color.id = i.color_id
                LEFT JOIN units unit ON unit.id = i.unit_id
                %s
                %s
                WHERE i.%s = :id
                  AND COALESCE(i.is_deleted, FALSE) = FALSE
                  AND COALESCE(h.is_deleted, FALSE) = FALSE
                %s
                ORDER BY i.line_no NULLS LAST, i.id
                """.formatted(
                type.returnedQuantityExpression(),
                type.wastedQuantityExpression(),
                type.atSupplierQuantityExpression(),
                type.consumedQuantityExpression(),
                type.supplierEndingQuantityExpression(),
                type.iqcPassedQuantityExpression(),
                type.iqcStockedQuantityExpression(),
                type.iqcPendingStockInQuantityExpression(),
                type.iqcFailedQuantityExpression(),
                type.iqcStatusExpression(),
                type.referenceDocumentExpression(),
                type.endingQuantityExpression(),
                type.standardQuantityExpression(),
                type.wasteRateExpression(),
                type.reasonExpression(),
                type.boxQuantityExpression(),
                type.parentGoodsCodeExpression(),
                type.parentGoodsNameExpression(),
                type.parentColorNameExpression(),
                type.itemTable(),
                type.headerTable(),
                type.itemForeignKey(),
                type.parentGoodsJoin(),
                type.inspectionJoin(),
                type.itemForeignKey(),
                lineScopeFilter(type, scope).replaceAll("\\bline\\.", "i."));
    }

    private static String headerSelect(WarehouseHistoryType type) {
        return """
                SELECT h.id,
                       h.bill_no,
                       h.bill_date,
                       h.supplier_id,
                       supplier.name AS supplier_name,
                       h.warehouse_id,
                       warehouse.name AS warehouse_name,
                       h.status,
                       h.is_closed,
                       h.source_doc_no,
                       h.maker_id,
                       h.approver_id,
                       %s AS legacy_maker_name,
                       %s AS legacy_approver_name,
                       h.remark,
                       (SELECT COUNT(*)
                          FROM %s line
                         WHERE line.%s = h.id
                           AND COALESCE(line.is_deleted, FALSE) = FALSE) AS line_count
                """.formatted(
                type.legacyMakerNameExpression(),
                type.legacyApproverNameExpression(),
                type.itemTable(),
                type.itemForeignKey());
    }

    private static String searchJoins(WarehouseHistoryType type) {
        return """
                FROM %s h
                LEFT JOIN suppliers supplier ON supplier.id = h.supplier_id
                LEFT JOIN warehouses warehouse ON warehouse.id = h.warehouse_id
                LEFT JOIN LATERAL (
                  SELECT string_agg(concat_ws(' ',COALESCE(NULLIF(line.goods_code_snapshot,''),goods.code),
                           COALESCE(NULLIF(line.goods_name_snapshot,''),goods.name)),' ') AS goods_text,
                         array_agg(DISTINCT COALESCE(NULLIF(line.goods_code_snapshot,''),goods.code)) AS goods_codes,
                         array_agg(DISTINCT COALESCE(NULLIF(line.goods_name_snapshot,''),goods.name)) AS goods_names
                  FROM %s line LEFT JOIN goods ON goods.id=line.goods_id
                  WHERE line.%s=h.id AND NOT COALESCE(line.is_deleted,FALSE)
                ) history_goods ON TRUE
                """.formatted(type.headerTable(), type.itemTable(), type.itemForeignKey());
    }

    /** Search, facets and paging all share the same physical item relation. */
    private static String lineJoins(WarehouseHistoryType type, WarehouseTaskScope scope) {
        return """
                FROM %s h
                LEFT JOIN suppliers supplier ON supplier.id=h.supplier_id
                LEFT JOIN %s line ON line.%s=h.id AND NOT COALESCE(line.is_deleted,FALSE)
                LEFT JOIN goods ON goods.id=line.goods_id
                LEFT JOIN colors color ON color.id=line.color_id
                LEFT JOIN units unit ON unit.id=line.unit_id
                LEFT JOIN LATERAL (
                  SELECT string_agg(DISTINCT physical_warehouse.name,'、' ORDER BY physical_warehouse.name) AS name
                  FROM warehouses physical_warehouse WHERE physical_warehouse.id=ANY(%s) %s
                ) warehouse ON TRUE
                CROSS JOIN LATERAL (
                  SELECT concat_ws(' ',COALESCE(NULLIF(line.goods_code_snapshot,''),goods.code),
                           COALESCE(NULLIF(line.goods_name_snapshot,''),goods.name),goods.spec,color.name) AS goods_text,
                         ARRAY[COALESCE(NULLIF(line.goods_code_snapshot,''),goods.code)] AS goods_codes,
                         ARRAY[COALESCE(NULLIF(line.goods_name_snapshot,''),goods.name)] AS goods_names
                ) history_goods
                """.formatted(type.headerTable(),type.itemTable(),type.itemForeignKey(),lineWarehouseIds(type),
                        scope.active() ? " AND " + scope.predicateAny("ARRAY[physical_warehouse.id]", ":warehouse_scope") : "");
    }

    private static String lineScopeFilter(WarehouseHistoryType type, WarehouseTaskScope scope) {
        if (!scope.active()) return "";
        return " AND " + scope.predicateAny(lineWarehouseIds(type), ":warehouse_scope") + "\n";
    }

    private static String lineWarehouseIds(WarehouseHistoryType type) {
        return switch(type) {
            case PURCHASE_RECEIPT, SUBCONTRACT_RECEIPT -> """
                    ARRAY(SELECT COALESCE(inspection_scope.warehouse_id,h.warehouse_id)
                          FROM procurement_inspection_items inspection_scope
                          WHERE inspection_scope.receipt_type='%s' AND inspection_scope.receipt_item_id=line.id
                            AND inspection_scope.status<>'REVERSED'
                          UNION SELECT h.warehouse_id WHERE NOT EXISTS (
                            SELECT 1 FROM procurement_inspection_items active_inspection
                            WHERE active_inspection.receipt_type='%s' AND active_inspection.receipt_item_id=line.id
                              AND active_inspection.status<>'REVERSED'))
                    """.formatted(type == WarehouseHistoryType.PURCHASE_RECEIPT ? "PURCHASE" : "SUBCONTRACT",
                            type == WarehouseHistoryType.PURCHASE_RECEIPT ? "PURCHASE" : "SUBCONTRACT");
            case SUBCONTRACT_WASTE -> """
                    ARRAY(SELECT COALESCE((SELECT issued.warehouse_id FROM subcontract_material_issue_items issue_line
                          JOIN subcontract_material_issues issued ON issued.id=issue_line.issue_id
                          WHERE issue_line.id=line.material_issue_item_id),h.warehouse_id))
                    """;
            default -> "ARRAY[h.warehouse_id]";
        };
    }

    private static String scopeFilter(WarehouseHistoryType type, WarehouseTaskScope scope) {
        if (!scope.active()) return "";
        return " AND " + scope.predicateAny(warehouseIds(type), ":warehouse_scope") + "\n";
    }

    /** The physical warehouse relation is source-specific, rather than a goods master guess. */
    private static String warehouseIds(WarehouseHistoryType type) {
        return switch (type) {
            case PURCHASE_RECEIPT, SUBCONTRACT_RECEIPT -> """
                    ARRAY(SELECT h.warehouse_id
                          UNION SELECT inspection_scope.warehouse_id
                          FROM procurement_inspection_items inspection_scope
                          WHERE inspection_scope.receipt_type='%s' AND inspection_scope.receipt_id=h.id
                            AND inspection_scope.status<>'REVERSED')
                    """.formatted(type == WarehouseHistoryType.PURCHASE_RECEIPT ? "PURCHASE" : "SUBCONTRACT");
            // Supplier loss is traced to each issued material; its header captures only the first source warehouse.
            case SUBCONTRACT_WASTE -> """
                    ARRAY(SELECT h.warehouse_id
                          UNION SELECT issued.warehouse_id
                          FROM subcontract_waste_items loss
                          JOIN subcontract_material_issue_items issue_line ON issue_line.id=loss.material_issue_item_id
                          JOIN subcontract_material_issues issued ON issued.id=issue_line.issue_id
                          WHERE loss.waste_id=h.id AND NOT COALESCE(loss.is_deleted,FALSE))
                    """;
            // Both return commands post physical movement to their own header warehouse.
            case SUBCONTRACT_RETURN, SUBCONTRACT_MATERIAL_RETURN, SUBCONTRACT_MATERIAL_ISSUE -> "ARRAY[h.warehouse_id]";
        };
    }

    private static String where(boolean includeFilters) {
        String filters = includeFilters ? """
                  -- null 参数类型坑：可选过滤一律 CAST(:param AS 类型) IS NULL OR ...
                  AND (CAST(:status AS smallint) IS NULL OR h.status = CAST(:status AS smallint))
                  AND (CAST(:date_from AS date) IS NULL OR h.bill_date >= CAST(:date_from AS date))
                  AND (CAST(:date_to AS date) IS NULL OR h.bill_date <= CAST(:date_to AS date))
                  AND (%s)
                  -- 2026-09-25 单号列统一：单据号/来源单据号表头值筛选（等值精确匹配，
                  -- 空参数即不过滤；列表/计数/facets 三处同一段 WHERE）。
                  AND (CAST(:bill_no AS text) IS NULL OR h.bill_no = CAST(:bill_no AS text))
                  AND (CAST(:source_doc_no AS text) IS NULL
                       OR h.source_doc_no = CAST(:source_doc_no AS text))
                """.formatted(TaskKeywordSearch.conditionParameter("keyword",
                        "h.bill_no", "h.source_doc_no", "supplier.name", "warehouse.name", "history_goods.goods_text")) : "";
        return """
                WHERE COALESCE(h.is_deleted, FALSE) = FALSE
                """ + filters;
    }
}
