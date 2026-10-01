-- Domain additions to the common permanent history contract. Current row projections
-- keep their existing active-only quantities, uniqueness, locks and write guards.
-- DELETE/TRUNCATE before-images retain exact original IDs/content/parents atomically.
SELECT fn_register_record_retention('production_plans');
SELECT fn_register_record_retention('production_plan_items','production_plans','plan_id');
SELECT fn_register_record_retention('production_daily_reports');
SELECT fn_register_record_retention('production_daily_report_items','production_daily_reports','report_id');
SELECT fn_register_record_retention('production_daily_report_workers','production_daily_reports','report_id');
SELECT fn_register_record_retention('production_daily_report_material_usages','production_daily_reports','report_id');
SELECT fn_register_record_retention('production_planning_package_documents','production_planning_packages','package_id');
SELECT fn_register_record_retention('production_planning_package_document_items','production_planning_packages','package_id');
SELECT fn_register_record_retention('stock_documents');
SELECT fn_register_record_retention('stock_document_items','stock_documents','doc_id');
SELECT fn_register_record_retention('goods_weight_estimates','goods','goods_id');
SELECT fn_register_record_retention('workshop_material_periods','warehouses','bin_warehouse_id');
SELECT fn_register_record_retention('workshop_material_counts','workshop_material_periods','period_id');
SELECT fn_register_record_retention('workshop_material_count_lines','workshop_material_counts','count_id');

-- Read-only history proves exact production provenance even after a mapping was
-- replaced. This does not reopen a deleted document for any production/stock write.
CREATE FUNCTION fn_stock_document_has_history_provenance(p_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM stock_documents document
        WHERE document.id=p_id
          AND (fn_is_production_linked_stock_document(document.id)
               OR EXISTS (
                   SELECT 1 FROM business_record_history history
                   WHERE history.source_table='production_planning_package_documents'
                     AND history.payload->>'document_id'=document.id::text
                     AND history.payload->>'document_type'=document.doc_type)
               OR (document.doc_type='DRAW' AND EXISTS (
                   SELECT 1 FROM business_record_history history
                   WHERE history.source_table='plan_draw_links'
                     AND history.payload->>'draw_id'=document.id::text))
               OR EXISTS (
                   SELECT 1 FROM business_record_history history
                   WHERE history.source_table='stock_document_items'
                     AND history.parent_table='stock_documents'
                     AND history.parent_id=document.id::text
                     AND (history.payload->>'execution_segment_id' IS NOT NULL
                          OR history.payload->>'execution_segment_sales_allocation_id' IS NOT NULL)))
    )
$$;
COMMENT ON FUNCTION fn_stock_document_has_history_provenance(uuid) IS
    'Only retained exact original production mappings prove warehouse history visibility; current organization and action permissions remain mandatory';
SELECT fn_register_record_retention('plan_draw_links','stock_documents','draw_id');
