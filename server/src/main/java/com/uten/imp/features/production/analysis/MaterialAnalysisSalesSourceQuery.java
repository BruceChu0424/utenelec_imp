package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.TaskKeywordSearch;

/** Same private-demand projection for the source picker and initial planning handoff. */
final class MaterialAnalysisSalesSourceQuery {
    private MaterialAnalysisSalesSourceQuery() {}

    static String fromWhere(String keyword, boolean billNoFilter) {
        String predicate = """
                o.status = 1 AND o.is_deleted = FALSE
                AND o.finance_confirmed = TRUE
                AND COALESCE(o.is_stopped, FALSE) = FALSE
                AND o.is_closed = FALSE
                AND i.is_deleted = FALSE
                AND g.is_deleted = FALSE
                AND GREATEST(
                    COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)
                    + COALESCE(i.returned_qty,0) - COALESCE(i.flag_qty,0)
                    - COALESCE(i.reserved_qty,0)
                    - GREATEST(COALESCE(i.planned_qty,0)
                               - COALESCE(i.produced_qty,0),0)
                    - COALESCE(draft.qty,0), 0) > 0
                """;
        if (!keyword.isEmpty()) {
            predicate += " AND " + TaskKeywordSearch.conditionParameter("kw",
                    "o.bill_no", "c.name", "g.code", "g.name", "g.spec", "col.name", "u.name") + "\n";
        }
        if (billNoFilter) predicate += " AND COALESCE(o.bill_no, '') = :orderBillNo\n";
        return """
                FROM (SELECT * FROM sales_orders archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('sales_orders',archive_origin.id)) o
                JOIN (SELECT * FROM sales_order_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('sales_order_items',archive_origin.id)) i ON i.order_id = o.id
                JOIN goods g ON g.id = i.goods_id
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                LEFT JOIN LATERAL (
                    -- Public surplus does not occupy the private sales source (V588).
                    SELECT SUM(CASE WHEN link.id IS NOT NULL THEN link.submitted_qty ELSE pi.qty END) AS qty
                    FROM (SELECT * FROM production_plan_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('production_plan_items',archive_origin.id)) pi
                    JOIN (SELECT * FROM production_plans archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('production_plans',archive_origin.id)) p ON p.id = pi.plan_id
                    LEFT JOIN production_material_analysis_plan_links link
                      ON link.plan_id = p.id AND link.analysis_id = p.material_analysis_id
                     AND link.analysis_item_id = p.material_analysis_item_id
                    WHERE pi.sales_order_item_id = i.id
                      AND pi.is_deleted = FALSE AND p.is_deleted = FALSE
                      AND p.status = 0 AND p.is_canceled = FALSE
                ) draft ON TRUE
                WHERE
                """ + predicate;
    }
}
