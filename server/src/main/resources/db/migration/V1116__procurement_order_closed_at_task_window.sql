-- Closed procurement orders stay in the fulfillment task projection for 30 days
-- after they were actually closed. The window read updated_at, which the legacy
-- import reset for every historical order and any later edit of a closed order
-- extends, so ~10k long-closed historical orders were evaluated on every read.
-- No order status, quantity, amount, source, approval or termination fact changes.
ALTER TABLE purchase_orders ADD COLUMN closed_at timestamptz;
ALTER TABLE subcontract_orders ADD COLUMN closed_at timestamptz;
COMMENT ON COLUMN purchase_orders.closed_at IS
 'Moment is_closed became true (V1116 trigger). NULL for open orders and for orders closed before V1116 outside the then-current 30-day task window.';
COMMENT ON COLUMN subcontract_orders.closed_at IS
 'Moment is_closed became true (V1116 trigger). NULL for open orders and for orders closed before V1116 outside the then-current 30-day task window.';

-- Cutover keeps every visible task identical: a native order whose window membership
-- depended on updated_at keeps that instant (31 days covers any session time zone).
-- Imported orders never appear in a native task list; they leave the window now.
UPDATE purchase_orders po SET closed_at=po.updated_at
WHERE po.is_closed AND po.updated_at >= CURRENT_DATE - INTERVAL '31 days'
  AND NOT EXISTS(SELECT 1 FROM imported_document_registry registry
                 WHERE registry.table_name='purchase_orders' AND registry.row_id=po.id);
UPDATE subcontract_orders so SET closed_at=so.updated_at
WHERE so.is_closed AND so.updated_at >= CURRENT_DATE - INTERVAL '31 days'
  AND NOT EXISTS(SELECT 1 FROM imported_document_registry registry
                 WHERE registry.table_name='subcontract_orders' AND registry.row_id=so.id);

-- The column follows is_closed only; a caller cannot move a close back into the window.
CREATE FUNCTION fn_procurement_order_closed_at() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
    IF NOT NEW.is_closed THEN
        NEW.closed_at:=NULL;
    ELSIF TG_OP='INSERT' OR NOT OLD.is_closed THEN
        NEW.closed_at:=now();
    ELSE
        NEW.closed_at:=OLD.closed_at;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_purchase_orders_closed_at BEFORE INSERT OR UPDATE OF is_closed, closed_at ON purchase_orders
    FOR EACH ROW EXECUTE FUNCTION fn_procurement_order_closed_at();
CREATE TRIGGER trg_subcontract_orders_closed_at BEFORE INSERT OR UPDATE OF is_closed, closed_at ON subcontract_orders
    FOR EACH ROW EXECUTE FUNCTION fn_procurement_order_closed_at();

-- Regenerate only the live projection. fn_procurement_order_reserves_source reads
-- ORDER approval cases of the order and APPROVED CLOSE_AND_REORDER cases naming it as
-- the replacement, so one of those cases existing is a necessary condition: checking
-- it first keeps the exact verdict while closed history no longer pays a function call.
DO $$
DECLARE definition text;
BEGIN
    SELECT pg_get_viewdef('v_procurement_decomposition_tasks'::regclass,TRUE) INTO definition;
    IF strpos(definition,'(NOT po.is_closed OR po.updated_at >= (CURRENT_DATE - ''30 days''::interval) OR fn_procurement_order_reserves_source(''PURCHASE''::text, po.id))')=0
       OR strpos(definition,'(NOT so.is_closed OR so.updated_at >= (CURRENT_DATE - ''30 days''::interval) OR fn_procurement_order_reserves_source(''SUBCONTRACT''::text, so.id))')=0 THEN
        RAISE EXCEPTION 'Procurement closed-order window anchors changed';
    END IF;
    definition:=replace(definition,
        '(NOT po.is_closed OR po.updated_at >= (CURRENT_DATE - ''30 days''::interval) OR fn_procurement_order_reserves_source(''PURCHASE''::text, po.id))',
        '(NOT po.is_closed OR po.closed_at >= (CURRENT_DATE - ''30 days''::interval)'
        ||' OR (po.id IN (SELECT approval.order_id FROM procurement_order_approval_cases approval'
        ||' WHERE approval.order_type=''PURCHASE'' AND approval.request_type=''ORDER'''
        ||' UNION ALL SELECT approval.replacement_order_id FROM procurement_order_approval_cases approval'
        ||' WHERE approval.order_type=''PURCHASE'' AND approval.request_type=''CLOSE_AND_REORDER'''
        ||' AND approval.status=''APPROVED'' AND approval.replacement_order_id IS NOT NULL)'
        ||' AND fn_procurement_order_reserves_source(''PURCHASE''::text, po.id)))');
    definition:=replace(definition,
        '(NOT so.is_closed OR so.updated_at >= (CURRENT_DATE - ''30 days''::interval) OR fn_procurement_order_reserves_source(''SUBCONTRACT''::text, so.id))',
        '(NOT so.is_closed OR so.closed_at >= (CURRENT_DATE - ''30 days''::interval)'
        ||' OR (so.id IN (SELECT approval.order_id FROM procurement_order_approval_cases approval'
        ||' WHERE approval.order_type=''SUBCONTRACT'' AND approval.request_type=''ORDER'''
        ||' UNION ALL SELECT approval.replacement_order_id FROM procurement_order_approval_cases approval'
        ||' WHERE approval.order_type=''SUBCONTRACT'' AND approval.request_type=''CLOSE_AND_REORDER'''
        ||' AND approval.status=''APPROVED'' AND approval.replacement_order_id IS NOT NULL)'
        ||' AND fn_procurement_order_reserves_source(''SUBCONTRACT''::text, so.id)))');
    IF strpos(definition,'po.updated_at >= (CURRENT_DATE - ''30 days''::interval)')>0
       OR strpos(definition,'so.updated_at >= (CURRENT_DATE - ''30 days''::interval)')>0 THEN
        RAISE EXCEPTION 'Procurement closed-order window still reads updated_at';
    END IF;
    EXECUTE 'CREATE OR REPLACE VIEW v_procurement_decomposition_tasks AS '||definition;
END;
$$;
