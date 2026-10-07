package com.uten.imp.features.production.analysis;

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
            predicate += " AND (lower(o.bill_no) LIKE :kw OR lower(COALESCE(c.name,'')) LIKE :kw"
                    + " OR lower(COALESCE(g.code,'')) LIKE :kw OR lower(COALESCE(g.name,'')) LIKE :kw)\n";
        }
        if (billNoFilter) predicate += " AND COALESCE(o.bill_no, '') = :orderBillNo\n";
        return """
                FROM sales_orders o
                JOIN sales_order_items i ON i.order_id = o.id
                JOIN goods g ON g.id = i.goods_id
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN LATERAL (
                    -- Public surplus does not occupy the private sales source (V588).
                    SELECT SUM(CASE WHEN link.id IS NOT NULL THEN link.submitted_qty ELSE pi.qty END) AS qty
                    FROM production_plan_items pi
                    JOIN production_plans p ON p.id = pi.plan_id
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
