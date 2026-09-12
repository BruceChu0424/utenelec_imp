-- Preserve V169 classifications while avoiding repeated regex evaluation for each audit row.
-- Only future INSERT/UPDATE rows are classified. Stored history, archive, column order,
-- all indexes, fn_audit and fn_audit_redact_row remain unchanged.
SET LOCAL search_path = pg_catalog, public, pg_temp;

LOCK TABLE public.audit_log IN ACCESS EXCLUSIVE MODE;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_class relation
        JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public' AND relation.relname = 'audit_log'
          AND relation.relkind = 'r' AND relation.relpersistence = 'p'
    ) THEN
        RAISE EXCEPTION 'V556 requires public.audit_log to be an ordinary persistent table';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc function_row
        JOIN pg_catalog.pg_namespace namespace ON namespace.oid = function_row.pronamespace
        WHERE namespace.nspname = 'public'
          AND function_row.proname IN ('fn_audit_classify', 'fn_audit_classify_row')
    ) OR EXISTS (
        SELECT 1 FROM pg_catalog.pg_trigger trigger_row
        WHERE trigger_row.tgrelid = 'public.audit_log'::regclass
          AND NOT trigger_row.tgisinternal
          AND (trigger_row.tgname = 'trg_audit_classify'
               OR ((trigger_row.tgtype & 2) <> 0 AND (trigger_row.tgtype & 20) <> 0))
    ) THEN
        RAISE EXCEPTION 'V556 audit classification function or BEFORE write trigger conflicts with existing objects';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_attribute attribute
        WHERE attribute.attrelid = 'public.audit_log'::regclass
          AND NOT attribute.attisdropped
          AND ((attribute.attname IN ('action', 'result', 'target_type', 'http_path', 'target_id')
                AND attribute.atttypid = 'text'::regtype)
               OR (attribute.attname = 'status_code' AND attribute.atttypid = 'integer'::regtype)
               OR (attribute.attname IN ('risk_level', 'event_category')
                   AND attribute.atttypid = 'text'::regtype AND attribute.attgenerated = 's')))
       <> 8 THEN
        RAISE EXCEPTION 'V556 audit input columns or stored generated classification columns have unexpected types';
    END IF;
    -- A function call derives one input collation. Mixed column collations can
    -- differ from the historical expressions' independent lower(action/result).
    IF (SELECT count(DISTINCT attribute.attcollation)
        FROM pg_catalog.pg_attribute attribute
        WHERE attribute.attrelid = 'public.audit_log'::regclass
          AND NOT attribute.attisdropped
          AND attribute.attname IN ('action', 'result', 'target_type', 'http_path', 'target_id'))
       <> 1 THEN
        RAISE EXCEPTION 'V556 requires one shared collation for all audit classification text inputs';
    END IF;
END;
$guard$;

-- Parse the historical V169 expression on THIS PostgreSQL server. Comparing its
-- canonical expression with the live columns avoids a hard-coded deparse string
-- from another server version, while rejecting unreviewed rule changes.
CREATE TEMPORARY TABLE uten_v556_expected_classification
    (LIKE public.audit_log EXCLUDING GENERATED) ON COMMIT DROP;
ALTER TABLE pg_temp.uten_v556_expected_classification
    DROP COLUMN risk_level, DROP COLUMN event_category;
ALTER TABLE pg_temp.uten_v556_expected_classification
    ADD COLUMN risk_level TEXT GENERATED ALWAYS AS (
        CASE
            WHEN lower(coalesce(action, '') || ' ' || coalesce(result, ''))
                     ~ '(refresh_reuse|reuse_detected)'
                THEN 'critical'
            WHEN lower(coalesce(action, '')) IN ('delete', 'http_delete')
              OR (
                  lower(coalesce(action, '')) <> 'http_get'
                  AND lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                            || coalesce(http_path, '') || ' ' || coalesce(target_id, ''))
                      ~ 'permission|authorization|data[-_]scopes?|system[-_]settings?|reset-password|balance-adjust|blacklist|/reverse|/offboard'
              )
                THEN 'high'
            WHEN coalesce(status_code, 0) >= 400
              OR lower(coalesce(result, ''))
                     ~ '(failure|failed|denied|bad_|not_found|locked|disabled|rate_limited|invalid|expired)'
              OR lower(coalesce(action, ''))
                     ~ '(login_failed|change_password|verify_password|^export_)'
              OR lower(coalesce(http_path, '')) LIKE '%/export%'
                THEN 'medium'
            ELSE 'low'
        END
    ) STORED,
    ADD COLUMN event_category TEXT GENERATED ALWAYS AS (
        CASE
            WHEN lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                       || coalesce(http_path, '') || ' ' || coalesce(target_id, ''))
                     ~ '(reuse|access_denied|blacklist)'
                THEN 'security'
            WHEN lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                       || coalesce(http_path, '') || ' ' || coalesce(target_id, ''))
                     ~ '(permission|authorization|role|data[-_]scope)'
                THEN 'authorization'
            WHEN lower(coalesce(action, '')) LIKE 'export_%'
              OR lower(coalesce(http_path, '')) LIKE '%/export%'
                THEN 'export'
            WHEN lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                       || coalesce(http_path, ''))
                     ~ '(login|logout|password|refresh_token|auth/)'
                THEN 'authentication'
            WHEN lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                       || coalesce(http_path, ''))
                     ~ '(system[-_]setting|user_preferences)'
                THEN 'system'
            WHEN lower(coalesce(action, '')) IN ('insert', 'update', 'delete')
                THEN 'data_change'
            ELSE 'business'
        END
    ) STORED;

DO $shape$
DECLARE
    v_name text;
    v_actual text;
    v_expected text;
BEGIN
    FOREACH v_name IN ARRAY ARRAY['risk_level', 'event_category'] LOOP
        SELECT pg_catalog.pg_get_expr(definition.adbin, definition.adrelid, false)
        INTO v_actual
        FROM pg_catalog.pg_attribute attribute
        JOIN pg_catalog.pg_attrdef definition
          ON definition.adrelid = attribute.attrelid AND definition.adnum = attribute.attnum
        WHERE attribute.attrelid = 'public.audit_log'::regclass
          AND attribute.attname = v_name AND NOT attribute.attisdropped;
        SELECT pg_catalog.pg_get_expr(definition.adbin, definition.adrelid, false)
        INTO v_expected
        FROM pg_catalog.pg_attribute attribute
        JOIN pg_catalog.pg_attrdef definition
          ON definition.adrelid = attribute.attrelid AND definition.adnum = attribute.attnum
        WHERE attribute.attrelid = 'pg_temp.uten_v556_expected_classification'::regclass
          AND attribute.attname = v_name AND NOT attribute.attisdropped;
        IF v_actual IS NULL OR v_actual IS DISTINCT FROM v_expected THEN
            RAISE EXCEPTION 'V556 requires the unchanged V169 generated expression for %', v_name;
        END IF;
    END LOOP;
END;
$shape$;
DROP TABLE pg_temp.uten_v556_expected_classification;

-- DROP EXPRESSION retains values and attribute positions; do not UPDATE existing
-- audit rows or rebuild archive classifications as part of this migration.
ALTER TABLE public.audit_log
    ALTER COLUMN risk_level DROP EXPRESSION,
    ALTER COLUMN event_category DROP EXPRESSION;

CREATE FUNCTION public.fn_audit_classify(
    p_action text, p_result text, p_target_type text, p_http_path text,
    p_target_id text, p_status_code integer,
    OUT risk_level text, OUT event_category text
) RETURNS record
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog AS $function$
DECLARE
    v_action text := lower(coalesce(p_action, ''));
    v_result text := lower(coalesce(p_result, ''));
    v_path text := lower(coalesce(p_http_path, ''));
    v_action_result text := lower(coalesce(p_action, '') || ' ' || coalesce(p_result, ''));
    v_base text := lower(coalesce(p_action, '') || ' ' || coalesce(p_target_type, '') || ' '
                         || coalesce(p_http_path, ''));
    v_full text := lower(coalesce(p_action, '') || ' ' || coalesce(p_target_type, '') || ' '
                         || coalesce(p_http_path, '') || ' ' || coalesce(p_target_id, ''));
BEGIN
    risk_level := CASE
        WHEN strpos(v_action_result, 'refresh_reuse') > 0
          OR strpos(v_action_result, 'reuse_detected') > 0 THEN 'critical'
        WHEN v_action IN ('delete', 'http_delete')
          OR (v_action <> 'http_get' AND (
              strpos(v_full, 'permission') > 0 OR strpos(v_full, 'authorization') > 0
              OR strpos(v_full, 'data-scope') > 0 OR strpos(v_full, 'data_scope') > 0
              OR strpos(v_full, 'system-setting') > 0 OR strpos(v_full, 'system_setting') > 0
              OR strpos(v_full, 'reset-password') > 0 OR strpos(v_full, 'balance-adjust') > 0
              OR strpos(v_full, 'blacklist') > 0 OR strpos(v_full, '/reverse') > 0
              OR strpos(v_full, '/offboard') > 0
          )) THEN 'high'
        WHEN coalesce(p_status_code, 0) >= 400
          OR strpos(v_result, 'failure') > 0 OR strpos(v_result, 'failed') > 0
          OR strpos(v_result, 'denied') > 0 OR strpos(v_result, 'bad_') > 0
          OR strpos(v_result, 'not_found') > 0 OR strpos(v_result, 'locked') > 0
          OR strpos(v_result, 'disabled') > 0 OR strpos(v_result, 'rate_limited') > 0
          OR strpos(v_result, 'invalid') > 0 OR strpos(v_result, 'expired') > 0
          OR strpos(v_action, 'login_failed') > 0 OR strpos(v_action, 'change_password') > 0
          OR strpos(v_action, 'verify_password') > 0 OR starts_with(v_action, 'export_')
          OR strpos(v_path, '/export') > 0 THEN 'medium'
        ELSE 'low'
    END;
    event_category := CASE
        WHEN strpos(v_full, 'reuse') > 0 OR strpos(v_full, 'access_denied') > 0
          OR strpos(v_full, 'blacklist') > 0 THEN 'security'
        WHEN strpos(v_full, 'permission') > 0 OR strpos(v_full, 'authorization') > 0
          OR strpos(v_full, 'role') > 0 OR strpos(v_full, 'data-scope') > 0
          OR strpos(v_full, 'data_scope') > 0 THEN 'authorization'
        -- Original LIKE underscore intentionally remains a one-character wildcard.
        WHEN v_action LIKE 'export_%' OR strpos(v_path, '/export') > 0 THEN 'export'
        WHEN strpos(v_base, 'login') > 0 OR strpos(v_base, 'logout') > 0
          OR strpos(v_base, 'password') > 0 OR strpos(v_base, 'refresh_token') > 0
          OR strpos(v_base, 'auth/') > 0 THEN 'authentication'
        WHEN strpos(v_base, 'system-setting') > 0 OR strpos(v_base, 'system_setting') > 0
          OR strpos(v_base, 'user_preferences') > 0 THEN 'system'
        WHEN v_action IN ('insert', 'update', 'delete') THEN 'data_change'
        ELSE 'business'
    END;
END;
$function$;

CREATE FUNCTION public.fn_audit_classify_row() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog AS $function$
BEGIN
    SELECT c.risk_level, c.event_category INTO NEW.risk_level, NEW.event_category
    FROM public.fn_audit_classify(NEW.action, NEW.result, NEW.target_type,
                                   NEW.http_path, NEW.target_id, NEW.status_code) AS c;
    RETURN NEW;
END;
$function$;

-- Every write recomputes both values, including attempts to supply only forged
-- classification columns. ALWAYS preserves the rule during replica-mode writes.
CREATE TRIGGER trg_audit_classify
BEFORE INSERT OR UPDATE ON public.audit_log
FOR EACH ROW EXECUTE FUNCTION public.fn_audit_classify_row();
ALTER TABLE public.audit_log ENABLE ALWAYS TRIGGER trg_audit_classify;

COMMENT ON FUNCTION public.fn_audit_classify(text, text, text, text, text, integer)
IS 'V169 audit risk/category rules with shared normalized text and literal substring matching; preserves NULL, priority and export LIKE semantics.';
COMMENT ON TRIGGER trg_audit_classify ON public.audit_log
IS 'Always computes risk_level/event_category for each new or updated audit row; existing history and archive snapshots are not rewritten.';
