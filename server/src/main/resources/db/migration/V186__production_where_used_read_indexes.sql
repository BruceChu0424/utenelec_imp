-- V186: material where-used read-side indexes.
--
-- The report combines the current recursive BOM, legacy production snapshots,
-- V1 execution demands and legacy subcontract evidence.  These partial,
-- covering indexes keep the selected material as the leading key and avoid
-- heap reads for the aggregate columns used by the report.

CREATE EXTENSION IF NOT EXISTS pg_trgm;


CREATE INDEX IF NOT EXISTS idx_gbi_where_used_active
    ON goods_bom_items(component_goods_id, goods_id)
    INCLUDE (qty)
    WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_ppc_where_used_active
    ON production_plan_costs(goods_id, bill_date, master_goods_id, bill_item_id)
    INCLUDE (dqty, qty, pdraw_qty, owdraw_qty)
    WHERE is_deleted = FALSE
      AND node_class = 0
      AND master_goods_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_pmd_where_used_all_evidence
    ON production_material_demands(goods_id, execution_segment_id, need_date)
    INCLUDE (status, supply_route, required_qty, per_product_qty, plan_id)
    WHERE is_deleted = FALSE;


CREATE INDEX IF NOT EXISTS idx_pmd_where_used_segment
    ON production_material_demands(goods_id, execution_segment_id, need_date)
    INCLUDE (status, supply_route, required_qty, per_product_qty, plan_id)
    WHERE is_deleted = FALSE
      AND execution_segment_id IS NOT NULL
      AND status <> 'REVERSED';

CREATE INDEX IF NOT EXISTS idx_pmd_where_used_unattributed
    ON production_material_demands(goods_id, need_date, plan_id)
    INCLUDE (required_qty, status)
    WHERE is_deleted = FALSE
      AND execution_segment_id IS NULL
      AND status <> 'REVERSED';

CREATE INDEX IF NOT EXISTS idx_scoci_where_used_active
    ON subcontract_order_cost_items(goods_id, bill_date, order_item_id)
    INCLUDE (order_id, unit_qty, qty)
    WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_smisi_where_used_active
    ON subcontract_material_issue_items(goods_id, bill_date, order_item_id)
    INCLUDE (issue_id, parent_goods_id, qty, returned_qty, wasted_qty)
    WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_goods_where_used_search_trgm
    ON goods USING GIN ((
        LOWER(
            COALESCE(code, '') || ' ' ||
            COALESCE(name, '') || ' ' ||
            COALESCE(model, '') || ' ' ||
            COALESCE(spec, '') || ' ' ||
            COALESCE(series, '') || ' ' ||
            COALESCE(c_number, '') || ' ' ||
            COALESCE(material, '') || ' ' ||
            COALESCE(require_remark, '')
        )
    ) gin_trgm_ops);

ANALYZE goods;

ANALYZE goods_bom_items;
ANALYZE production_plan_costs;
ANALYZE production_material_demands;
ANALYZE subcontract_order_cost_items;
ANALYZE subcontract_material_issue_items;
