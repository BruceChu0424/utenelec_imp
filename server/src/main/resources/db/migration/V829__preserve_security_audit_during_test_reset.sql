-- Business test reset may remove business history, never authentication or security evidence.
DO $$
DECLARE definition text; before_attributes record; after_attributes record;
        needle text := E'      WHERE event_source=''business'' AND target_type=''system_test''\n';
BEGIN
    SELECT proowner,proacl,prosecdef,proconfig INTO before_attributes
      FROM pg_proc WHERE oid='public.business_data_reset()'::regprocedure;
    SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>2 THEN
        RAISE EXCEPTION 'V829 cannot locate both audit retention predicates';
    END IF;
    -- AND binds before OR: reset receipts retain their original predicate, while
    -- each security category survives regardless of action or event source.
    definition := replace(definition,needle,
        E'      WHERE event_category IN (''authentication'',''authorization'',''security'',''system'')\n'
        ||E'         OR event_source=''business'' AND target_type=''system_test''\n');
    EXECUTE definition;
    SELECT proowner,proacl,prosecdef,proconfig INTO after_attributes
      FROM pg_proc WHERE oid='public.business_data_reset()'::regprocedure;
    IF before_attributes IS DISTINCT FROM after_attributes THEN
        RAISE EXCEPTION 'V829 changed reset execution privileges';
    END IF;
END $$;

CREATE INDEX idx_audit_login_failure_window ON public.audit_log(created_at,ip)
    WHERE action='login_failed';
