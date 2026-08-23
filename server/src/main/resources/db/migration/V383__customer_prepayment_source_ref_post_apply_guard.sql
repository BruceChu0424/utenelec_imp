-- V383: post-apply source-ref dual-currency guard.
DO $v383$
DECLARE v_capacity TEXT; v_identity TEXT; v_immutable TEXT;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='customer_open_item_offsets'
                    AND column_name='target_ref_balance_after_local')
       OR NOT EXISTS(SELECT 1 FROM pg_constraint
                  WHERE conrelid='customer_open_item_offsets'::regclass
                    AND conname='customer_offsets_target_ref_snapshot_chk' AND convalidated)
       OR NOT EXISTS(SELECT 1 FROM pg_constraint
                  WHERE conrelid='customer_open_item_offsets'::regclass
                    AND conname='customer_offsets_rate_identity_chk' AND convalidated) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='customer prepayment target source-ref snapshot constraints are missing';
    END IF;
    SELECT pg_get_functiondef(p.oid) INTO v_capacity FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='fn_assert_ar_source_ref_capacity';
    SELECT pg_get_functiondef(p.oid) INTO v_identity FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='fn_guard_customer_open_item_offset';
    SELECT pg_get_functiondef(p.oid) INTO v_immutable FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='fn_guard_customer_offset_line_immutable';
    IF v_capacity IS NULL OR position('applied_book_local' IN v_capacity)=0
       OR position('target_amount_local' IN v_capacity)=0
       OR v_identity IS NULL OR position('target_ref_balance_before_local' IN v_identity)=0
       OR v_immutable IS NULL OR position('target_ref_balance_after_local' IN v_immutable)=0 THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='customer prepayment source-ref dual-currency guards are incomplete';
    END IF;
END
$v383$;
