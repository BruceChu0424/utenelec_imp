-- V484: runtime reset extension for the V482 sales-order quantity-change fact
-- ledger. V482 stays immutable; this patch reads the installed business_data_reset()
-- definition and inserts the CLEAR row fail-closed (same mechanism as V474/V478).
DO $$
DECLARE definition TEXT; needle TEXT := '(''preplan_root_output_events'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN
        RAISE EXCEPTION 'V484 cannot extend business_data_reset policy safely';
    END IF;
    definition := replace(definition,needle,
      '(''sales_order_qty_change_logs'', ''CLEAR''), '||needle);
    EXECUTE definition;
END;
$$;
