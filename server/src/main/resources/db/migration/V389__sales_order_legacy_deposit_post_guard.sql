-- V389: post-apply legacy-deposit guard.
DO $v389$
DECLARE v_definition TEXT;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_definition
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='fn_guard_sales_order_legacy_deposit';
    IF v_definition IS NULL OR position('legacy snapshot' IN v_definition)=0
       OR NOT EXISTS(SELECT 1 FROM pg_trigger
                     WHERE tgrelid='sales_orders'::regclass
                       AND tgname='trg_guard_sales_order_legacy_deposit'
                       AND tgenabled IN('O','A')) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='sales-order legacy deposit immutability guard is incomplete';
    END IF;
END
$v389$;
