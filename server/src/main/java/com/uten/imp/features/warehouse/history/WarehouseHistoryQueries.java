package com.uten.imp.features.warehouse.history;

/** Fixed, enum-selected SQL builders for the amount-free warehouse history projection. */
final class WarehouseHistoryQueries {

    private WarehouseHistoryQueries() {
    }

    static String listSql(WarehouseHistoryType type) {
        return listSql(type, DEFAULT_ORDER_BY);
    }

    /** 2026-09-25 单号列统一：列表排序接白名单 ORDER BY（未知/空回落默认单据日期倒序）。 */
    static String listSql(WarehouseHistoryType type, String orderBy) {
        return headerSelect(type) + searchJoins(type) + where(type, true) + orderBy + "\n" + """
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
        return "SELECT " + expr + ", COUNT(*) " + searchJoins(type)
                + where(type, true) + " GROUP BY 1 ORDER BY 1\n";
    }

    static String countSql(WarehouseHistoryType type) {
        return "SELECT COUNT(*) " + searchJoins(type) + where(type, true);
    }

    static String detailHeaderSql(WarehouseHistoryType type) {
        return headerSelect(type) + searchJoins(type) + """
                WHERE COALESCE(h.is_deleted, FALSE) = FALSE
                  AND h.id = :id
                """;
    }

    static String detailLinesSql(WarehouseHistoryType type) {
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
                type.itemForeignKey());
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
                """.formatted(type.headerTable());
    }

    private static String where(WarehouseHistoryType type, boolean includeFilters) {
        String filters = includeFilters ? """
                  -- null 参数类型坑：可选过滤一律 CAST(:param AS 类型) IS NULL OR ...
                  AND (CAST(:status AS smallint) IS NULL OR h.status = CAST(:status AS smallint))
                  AND (CAST(:date_from AS date) IS NULL OR h.bill_date >= CAST(:date_from AS date))
                  AND (CAST(:date_to AS date) IS NULL OR h.bill_date <= CAST(:date_to AS date))
                  AND (
                       CAST(:keyword AS text) = ''
                       OR LOWER(COALESCE(h.bill_no, '')) LIKE :keyword_pattern
                       OR LOWER(COALESCE(h.source_doc_no, '')) LIKE :keyword_pattern
                       OR LOWER(COALESCE(supplier.name, '')) LIKE :keyword_pattern
                       OR LOWER(COALESCE(warehouse.name, '')) LIKE :keyword_pattern
                       OR EXISTS (
                           SELECT 1
                             FROM %s search_item
                            WHERE search_item.%s = h.id
                              AND COALESCE(search_item.is_deleted, FALSE) = FALSE
                              AND (
                                  LOWER(COALESCE(search_item.goods_code_snapshot, '')) LIKE :keyword_pattern
                                  OR LOWER(COALESCE(search_item.goods_name_snapshot, '')) LIKE :keyword_pattern
                              )
                       )
                  )
                  -- 2026-09-25 单号列统一：单据号/来源单据号表头值筛选（等值精确匹配，
                  -- 空参数即不过滤；列表/计数/facets 三处同一段 WHERE）。
                  AND (CAST(:bill_no AS text) IS NULL OR h.bill_no = CAST(:bill_no AS text))
                  AND (CAST(:source_doc_no AS text) IS NULL
                       OR h.source_doc_no = CAST(:source_doc_no AS text))
                """.formatted(type.itemTable(), type.itemForeignKey()) : "";
        return """
                WHERE COALESCE(h.is_deleted, FALSE) = FALSE
                """ + filters;
    }
}
