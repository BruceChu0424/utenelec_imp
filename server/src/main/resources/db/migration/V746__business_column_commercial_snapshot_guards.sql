-- Preserve applied functions and historic snapshots. Extend only the current
-- authoritative amount checks with V744's finite, ordered column calculation.
DO $migration$
DECLARE
    source TEXT;
    anchor TEXT;
    updated TEXT;
    function_name TEXT;
BEGIN
    source := pg_get_functiondef('fn_guard_procurement_finance_commercial_snapshot()'::regprocedure);
    anchor := 'amount_original<>(qty*price)';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 2 THEN
        RAISE EXCEPTION 'V746 procurement commercial guard anchor differs';
    END IF;
    EXECUTE replace(source,anchor,
        'amount_original<>fn_business_columns_amount(qty*price,extra_columns)');

    source := pg_get_functiondef('fn_is_proven_procurement_qty_revision(text,jsonb,jsonb)'::regprocedure);
    anchor := 'expected_original:=((p_new->>''qty'')::numeric*(p_old->>''price'')::numeric);';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V746 procurement quantity guard anchor differs';
    END IF;
    EXECUTE replace(source,anchor,
        'expected_original:=fn_business_columns_amount((p_new->>''qty'')::numeric*(p_old->>''price'')::numeric,p_old->''extra_columns'');');

    source := pg_get_functiondef('fn_is_proven_procurement_header_revision(text,jsonb,jsonb)'::regprocedure);
    anchor := 'r.new_qty*i.price';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 2 THEN
        RAISE EXCEPTION 'V746 procurement header guard anchor differs';
    END IF;
    EXECUTE replace(source,anchor,
        'fn_business_columns_amount(r.new_qty*i.price,i.extra_columns)');

    source := pg_get_functiondef('fn_procurement_approval_display_snapshot()'::regprocedure);
    anchor := '''remark'', item.remark, ''sourceDocNo'', item.source_doc_no,';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V746 procurement display snapshot anchor differs';
    END IF;
    updated := replace(source,anchor,anchor || E'\n                    ''extraColumns'', COALESCE(item.extra_columns,''[]''::jsonb),');
    EXECUTE updated;
END
$migration$;

-- Existing hot-table trigger WHEN clauses predate extension values. A separate
-- relevant-column gate closes the pure-text/same-amount mutation gap without
-- running expensive commercial guards on derived quantity/status refreshes.
CREATE FUNCTION fn_guard_business_column_snapshot()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
    parent_table TEXT;
    parent_id UUID;
    parent_status SMALLINT;
BEGIN
    IF NEW.extra_columns IS NOT DISTINCT FROM OLD.extra_columns THEN RETURN NEW; END IF;
    parent_table := TG_ARGV[0];
    parent_id := (to_jsonb(NEW)->>TG_ARGV[1])::uuid;
    EXECUTE format('SELECT status FROM %I WHERE id=$1 FOR SHARE',parent_table)
        INTO parent_status USING parent_id;
    IF parent_status IS NULL OR parent_status <> 0 THEN
        RAISE EXCEPTION 'Confirmed business column snapshots are immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER trg_sales_quote_business_columns_immutable
BEFORE UPDATE OF extra_columns ON sales_quote_items FOR EACH ROW
WHEN (OLD.extra_columns IS DISTINCT FROM NEW.extra_columns)
EXECUTE FUNCTION fn_guard_business_column_snapshot('sales_quotes','quote_id');
CREATE TRIGGER trg_sales_order_business_columns_immutable
BEFORE UPDATE OF extra_columns ON sales_order_items FOR EACH ROW
WHEN (OLD.extra_columns IS DISTINCT FROM NEW.extra_columns)
EXECUTE FUNCTION fn_guard_business_column_snapshot('sales_orders','order_id');
CREATE TRIGGER trg_purchase_order_business_columns_immutable
BEFORE UPDATE OF extra_columns ON purchase_order_items FOR EACH ROW
WHEN (OLD.extra_columns IS DISTINCT FROM NEW.extra_columns)
EXECUTE FUNCTION fn_guard_business_column_snapshot('purchase_orders','order_id');
CREATE TRIGGER trg_subcontract_order_business_columns_immutable
BEFORE UPDATE OF extra_columns ON subcontract_order_items FOR EACH ROW
WHEN (OLD.extra_columns IS DISTINCT FROM NEW.extra_columns)
EXECUTE FUNCTION fn_guard_business_column_snapshot('subcontract_orders','order_id');
