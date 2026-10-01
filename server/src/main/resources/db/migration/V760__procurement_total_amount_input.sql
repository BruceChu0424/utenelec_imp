-- Preserve original agreed line totals; reference prices must never replace their consideration.
-- Existing rows stay in unit-price mode and no historical amounts/snapshots are rewritten.
ALTER TABLE purchase_order_items ADD COLUMN total_amount_input numeric,
    ADD CONSTRAINT purchase_order_total_amount_input_exact CHECK
        (total_amount_input IS NULL OR (total_amount_input >= 0 AND fn_financial_amount_is_exact(total_amount_input)));
ALTER TABLE subcontract_order_items ADD COLUMN total_amount_input numeric,
    ADD CONSTRAINT subcontract_order_total_amount_input_exact CHECK
        (total_amount_input IS NULL OR (total_amount_input >= 0 AND fn_financial_amount_is_exact(total_amount_input)));

CREATE FUNCTION fn_procurement_reference_price(total numeric, qty numeric) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
    IF qty <= 0 OR total < 0 THEN RAISE EXCEPTION 'Invalid total-price quantity' USING ERRCODE='23514'; END IF;
    -- Integer div avoids numeric division's implicit significant-digit rounding.
    RETURN (trim_scale(div(total*1e10::numeric,qty))::text || 'e-10')::numeric;
END;
$$;

CREATE FUNCTION fn_procurement_revised_total_input(total numeric, old_qty numeric, new_qty numeric) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE result numeric;
BEGIN
    IF old_qty <= 0 OR new_qty <= 0 THEN RAISE EXCEPTION 'Invalid total-price quantity revision' USING ERRCODE='23514'; END IF;
    -- Reuse exact finite division; repeating results are rejected, never rounded into a new fact.
    result := fn_business_columns_amount(total*new_qty,
        jsonb_build_array(jsonb_build_object('operation','DIVIDE','type','NUMBER','value',trim_scale(old_qty)::text)));
    IF NOT fn_financial_amount_is_exact(result) THEN
        RAISE EXCEPTION 'Revised agreed total exceeds exact amount range' USING ERRCODE='23514';
    END IF;
    RETURN result;
END;
$$;

CREATE FUNCTION fn_procurement_revised_original(old_item jsonb, new_qty numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT fn_business_columns_amount(
        CASE WHEN old_item->>'total_amount_input' IS NULL
            THEN new_qty*(old_item->>'price')::numeric
            ELSE fn_procurement_revised_total_input((old_item->>'total_amount_input')::numeric,
                (old_item->>'qty')::numeric,new_qty) END,
        old_item->'extra_columns')
$$;

DO $migration$
DECLARE source text; anchor text;
BEGIN
    source := pg_get_functiondef('fn_guard_procurement_finance_commercial_snapshot()'::regprocedure);
    anchor := 'amount_original<>fn_business_columns_amount(qty*price,extra_columns)';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 2 THEN
        RAISE EXCEPTION 'V760 commercial amount guard anchor differs';
    END IF;
    EXECUTE replace(source,anchor,
        'amount_original<>fn_business_columns_amount(COALESCE(total_amount_input,qty*price),extra_columns)
                 OR (total_amount_input IS NOT NULL AND price<>fn_procurement_reference_price(total_amount_input,qty))');

    source := pg_get_functiondef('fn_is_proven_procurement_qty_revision(text,jsonb,jsonb)'::regprocedure);
    anchor := '''qty'',''amount_original'',''amount_local'',''updated_at'',''updated_by''';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 2 THEN
        RAISE EXCEPTION 'V760 quantity mutation whitelist anchor differs';
    END IF;
    source := replace(source,anchor,'''qty'',''amount_original'',''amount_local'',''total_amount_input'',''updated_at'',''updated_by''');
    anchor := 'expected_original:=fn_business_columns_amount((p_new->>''qty'')::numeric*(p_old->>''price'')::numeric,p_old->''extra_columns'');';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V760 quantity amount guard anchor differs';
    END IF;
    source := replace(source,anchor,
        'IF (p_new->>''total_amount_input'')::numeric IS DISTINCT FROM
            fn_procurement_revised_total_input((p_old->>''total_amount_input'')::numeric,
                (p_old->>''qty'')::numeric,(p_new->>''qty'')::numeric) THEN RETURN FALSE; END IF;
    expected_original:=fn_procurement_revised_original(p_old,(p_new->>''qty'')::numeric);');
    EXECUTE source;

    source := pg_get_functiondef('fn_is_proven_procurement_header_revision(text,jsonb,jsonb)'::regprocedure);
    anchor := 'fn_business_columns_amount(r.new_qty*i.price,i.extra_columns)';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 2 THEN
        RAISE EXCEPTION 'V760 header amount guard anchor differs';
    END IF;
    EXECUTE replace(source,anchor,'fn_procurement_revised_original(r.before_item,r.new_qty)');

    source := pg_get_functiondef('fn_procurement_approval_display_snapshot()'::regprocedure);
    anchor := '''extraColumns'', COALESCE(item.extra_columns,''[]''::jsonb),';
    IF (length(source)-length(replace(source,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V760 display snapshot anchor differs';
    END IF;
    EXECUTE replace(source,anchor,anchor || E'\n                    ''totalAmountInput'',trim_scale(item.total_amount_input)::text,');
END;
$migration$;

-- Existing hot-table UPDATE gates do not mention the new source fact.
CREATE FUNCTION fn_guard_procurement_total_input() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE parent_status smallint;
BEGIN
    IF NEW.total_amount_input IS NOT DISTINCT FROM OLD.total_amount_input THEN RETURN NEW; END IF;
    IF fn_is_proven_procurement_qty_revision(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW)) THEN RETURN NEW; END IF;
    EXECUTE format('SELECT status FROM %I WHERE id=$1 FOR SHARE',
        CASE TG_ARGV[0] WHEN 'PURCHASE' THEN 'purchase_orders' ELSE 'subcontract_orders' END)
        INTO parent_status USING OLD.order_id;
    IF parent_status IS DISTINCT FROM 0 OR procurement_order_commercial_locked(TG_ARGV[0],OLD.order_id)
       OR procurement_order_commercial_locked(TG_ARGV[0],NEW.order_id) THEN
        RAISE EXCEPTION 'Submitted or confirmed total amount inputs are immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_purchase_order_total_input_frozen BEFORE UPDATE OF total_amount_input
ON purchase_order_items FOR EACH ROW WHEN (OLD.total_amount_input IS DISTINCT FROM NEW.total_amount_input)
EXECUTE FUNCTION fn_guard_procurement_total_input('PURCHASE');
CREATE TRIGGER trg_subcontract_order_total_input_frozen BEFORE UPDATE OF total_amount_input
ON subcontract_order_items FOR EACH ROW WHEN (OLD.total_amount_input IS DISTINCT FROM NEW.total_amount_input)
EXECUTE FUNCTION fn_guard_procurement_total_input('SUBCONTRACT');
