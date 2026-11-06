-- deviation_pct is produced by ApwPredictor, never accepted as a weighing input.
-- Retain its complete finite statistical result under the existing derived
-- numeric boundary. Actual measured kg/quantity and their input evidence keep
-- their existing 40/24 validation.
DO $migration$
DECLARE
    v_definition TEXT;
    v_selector TEXT := $selector$COALESCE(entry->>'kind',CASE WHEN attribute.attname LIKE '%local%'
            OR attribute.attname IN ('amount_balance','amount_settled') THEN 'book' ELSE 'actual' END)$selector$;
    v_derived_selector TEXT := $selector$CASE WHEN namespace.nspname='public'
            AND relation.relname='goods_weight_observations' AND attribute.attname='deviation_pct'
            AND COALESCE(entry->>'kind','actual') IN ('actual','book')
            THEN 'book' ELSE COALESCE(entry->>'kind',CASE WHEN attribute.attname LIKE '%local%'
            OR attribute.attname IN ('amount_balance','amount_settled') THEN 'book' ELSE 'actual' END) END$selector$;
    v_constraint TEXT := 'ck_financial_exact_7c0e6e2c49972ab8128dcc97';
    v_check TEXT;
BEGIN
    v_definition := pg_get_functiondef('public.fn_migrate_financial_amount_columns(jsonb)'::regprocedure);
    IF (length(v_definition)-length(replace(v_definition,v_selector,'')))/length(v_selector)<>1 THEN
        RAISE EXCEPTION 'financial numeric installer classifier differs from the reviewed source';
    END IF;
    -- This existing installer remains the single classifier for subsequent
    -- callers too, including callers carrying the old name-based actual kind.
    EXECUTE replace(v_definition,v_selector,v_derived_selector);

    LOCK TABLE public.goods_weight_observations IN ACCESS EXCLUSIVE MODE;
    SELECT pg_get_expr(check_constraint.conbin,check_constraint.conrelid)
    INTO STRICT v_check
    FROM pg_constraint check_constraint
    JOIN pg_attribute attribute ON attribute.attrelid=check_constraint.conrelid
        AND attribute.attname='deviation_pct'
    WHERE check_constraint.conrelid='public.goods_weight_observations'::regclass
      AND check_constraint.conname=v_constraint AND check_constraint.contype='c'
      AND check_constraint.convalidated AND check_constraint.conkey=ARRAY[attribute.attnum];
    IF v_check NOT IN ('fn_financial_amount_is_exact(deviation_pct)',
                      'public.fn_financial_amount_is_exact(deviation_pct)') THEN
        RAISE EXCEPTION 'weight deviation check differs from the reviewed actual-kind check: %',v_check;
    END IF;
    EXECUTE format('ALTER TABLE public.goods_weight_observations DROP CONSTRAINT %I',v_constraint);
    PERFORM public.fn_migrate_financial_amount_columns(
        '[{"schema":"public","table":"goods_weight_observations","column":"deviation_pct","kind":"book"}]'::jsonb);
END
$migration$;
