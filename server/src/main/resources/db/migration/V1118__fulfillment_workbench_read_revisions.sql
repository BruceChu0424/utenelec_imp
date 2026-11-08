-- Fulfillment workbench pages (purchase/subcontract/warehouse task centers) may
-- fetch continuation batches concurrently only when every batch carries one
-- stable data revision. This domain is the read-freshness closure of those
-- page reads: every public base table reachable from the page SQL
-- (FulfillmentWorkbenchQueryService/PageRead and their finance helpers)
-- through view rewrite dependencies and function bodies, as resolved on the
-- V1117 schema. Over-inclusion only retires an in-flight complete read (the
-- client retries); a missing source could stitch two data versions, so the
-- closure is deliberately conservative. The imported-document registry is
-- excluded: it is a pure projection of these business tables' own writes.
--
-- Read freshness only: no change to writes, permissions, page caps or
-- business authority. Marker triggers follow the V1104/V1110 statement shape;
-- the persisted-transaction gate is applied by the canonical refresh below.
INSERT INTO summary_read_domains(domain) VALUES ('fulfillment-workbench');

DO $fulfillment_workbench_markers$
DECLARE
    source text;
    sources constant text[] := ARRAY[
        'accounts','colors','departments','employees','goods','goods_bom_items',
        'preplan_stock_entitlement_events','preplan_supply_action_allocations','preplan_supply_actions',
        'procurement_arrival_exceptions','procurement_inspection_items','procurement_iqc_rejection_cases',
        'procurement_order_approval_cases',
        'production_execution_segment_events','production_execution_segments',
        'production_material_analysis_items','production_material_analysis_materials',
        'production_material_demands','production_material_discovery_lines','production_material_discovery_requests',
        'production_material_increment_reversals','production_material_stock_postings','production_material_supply_pegs',
        'production_planning_package_document_items','production_planning_package_documents',
        'production_planning_packages','production_plans',
        'purchase_order_item_sources','purchase_order_items','purchase_orders',
        'purchase_receipt_items','purchase_receipts','purchase_request_items','purchase_requests',
        'rd_tasks','sales_order_items',
        'stock_balances','stock_document_items','stock_documents','stock_measurement_holds',
        'stock_reservation_storage_positions','stock_reservations',
        'subcontract_application_items','subcontract_applications','subcontract_component_stock_handoffs',
        'subcontract_material_issue_items','subcontract_material_issues',
        'subcontract_material_plan_items','subcontract_material_plans',
        'subcontract_order_item_sources','subcontract_order_items','subcontract_orders',
        'subcontract_receipt_items','subcontract_receipts','subcontract_short_delivery_cases','subcontract_wastes',
        'suppliers','units','warehouses'];
    installed integer;
BEGIN
    FOREACH source IN ARRAY sources LOOP
        EXECUTE format('CREATE TRIGGER trg_fulfillment_workbench_insert AFTER INSERT ON public.%I REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain(%L)', source, 'fulfillment-workbench');
        EXECUTE format('CREATE TRIGGER trg_fulfillment_workbench_update AFTER UPDATE ON public.%I REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain(%L)', source, 'fulfillment-workbench');
        EXECUTE format('CREATE TRIGGER trg_fulfillment_workbench_delete AFTER DELETE ON public.%I REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain(%L)', source, 'fulfillment-workbench');
        EXECUTE format('CREATE TRIGGER trg_fulfillment_workbench_truncate AFTER TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION public.fn_mark_summary_read_domain(%L)', source, 'fulfillment-workbench');
    END LOOP;
    SELECT count(*) INTO installed FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = ANY(sources)
      AND t.tgname LIKE 'trg\_fulfillment\_workbench\_%'
      AND t.tgfoid = 'public.fn_mark_summary_read_domain()'::regprocedure;
    IF installed <> 4 * cardinality(sources) THEN
        RAISE EXCEPTION 'Fulfillment workbench read markers incomplete: % of %', installed, 4 * cardinality(sources);
    END IF;
END $fulfillment_workbench_markers$;

-- Newly installed statement triggers use the same persisted-transaction gate.
SELECT public.fn_refresh_summary_read_marker_gates();
