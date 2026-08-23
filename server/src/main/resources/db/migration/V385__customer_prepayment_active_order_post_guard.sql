-- V385: post-apply active-order guard.
DO $v385$
DECLARE v_definition TEXT;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_definition
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='fn_guard_finance_receipt_order';
    IF v_definition IS NULL
       OR position('is_stopped' IN v_definition)=0
       OR position('is_closed' IN v_definition)=0 THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='bound customer prepayment active-order guard is incomplete';
    END IF;
END
$v385$;
