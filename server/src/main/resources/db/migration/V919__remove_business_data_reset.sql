-- Permanently retire the workbench business-data clear capability.
-- Forward-only: historical migrations are unchanged and no business data is cleared.
-- Remove its exceptions from shared retention guards before dropping the entries.
DO $remove_reset_exceptions$
DECLARE
    change text[];
    definition text;
    anchor text;
BEGIN
    FOREACH change SLICE 1 IN ARRAY ARRAY[
        ARRAY['public.fn_business_history_immutable()', 'IF TG_OP=''TRUNCATE'' AND public.fn_business_test_reset_active() THEN RETURN NULL; END IF;'],
        ARRAY['public.fn_quote_candidate_history_immutable()', 'IF TG_OP=''TRUNCATE'' AND public.fn_business_test_reset_active() THEN RETURN NULL; END IF;'],
        ARRAY['public.fn_lifecycle_evidence_immutable()', 'IF TG_OP=''TRUNCATE'' AND public.fn_business_test_reset_active() THEN RETURN NULL; END IF;'],
        ARRAY['public.fn_guard_audit_append_only()', 'IF TG_OP=''TRUNCATE'' AND public.fn_business_test_reset_active() THEN RETURN NULL; END IF;'],
        ARRAY['public.fn_guard_production_daily_report_command()', 'IF TG_OP=''TRUNCATE'' AND public.fn_business_test_reset_active() THEN RETURN NULL; END IF;'],
        ARRAY['public.fn_retain_business_records_before_truncate()', 'IF public.fn_business_test_reset_active() THEN RETURN NULL; END IF;'],
        ARRAY['public.fn_retain_business_record()', 'IF public.fn_business_test_reset_active() THEN RETURN CASE WHEN TG_OP=''DELETE'' THEN OLD ELSE NEW END; END IF;'],
        ARRAY['public.fn_platform_fields_keep_version()', 'IF TG_OP=''DELETE'' AND public.fn_business_test_reset_active() THEN RETURN OLD; END IF;'],
        ARRAY['public.fn_sales_quote_template_candidates_truncate()', 'IF public.fn_business_test_reset_active() THEN RETURN NULL; END IF;'],
        ARRAY['public.fn_sales_order_requotation_fence()', 'IF public.fn_business_test_reset_active() THEN RETURN NEW; END IF;'],
        ARRAY['public.fn_guard_website_inquiry_events()', E'IF TG_OP IN (''DELETE'',''TRUNCATE'') AND public.fn_business_test_reset_active() THEN\n  IF TG_OP=''DELETE'' THEN RETURN OLD; ELSE RETURN NULL; END IF;\n END IF;'],
        ARRAY['public.fn_attachment_retained_identity_guard()', E'IF TG_OP=''DELETE'' AND public.fn_business_test_reset_active() THEN\n        IF upper(btrim(OLD.owner_type)) IN(''GOODS'',''EMPLOYEE'',''EMPLOYEE_CONTRACT'') THEN\n            RAISE EXCEPTION ''Protected master attachment cannot be cleared'' USING ERRCODE=''23514'';\n        END IF;\n        IF NULLIF(current_setting(''app.business_test_reset_verified'', true), '''') IS NULL THEN\n            RAISE EXCEPTION ''Business attachment rows can be cleared only after the test file list is verified'' USING ERRCODE=''23514'';\n        END IF;\n        RETURN OLD;\n    END IF;']
    ] LOOP
        SELECT replace(pg_get_functiondef(change[1]::regprocedure), E'\r\n', E'\n') INTO definition;
        anchor := change[2];
        IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1 THEN
            RAISE EXCEPTION 'V919 cannot safely remove the retired reset exception from %', change[1];
        END IF;
        definition := replace(definition, anchor, '');
        IF strpos(definition, 'fn_business_test_reset_active') > 0 THEN
            RAISE EXCEPTION 'V919 found an unreviewed reset exception in %', change[1];
        END IF;
        EXECUTE definition; -- CREATE OR REPLACE preserves each existing owner and ACL.
    END LOOP;
END;
$remove_reset_exceptions$;

-- Keep the persisted generation for already-created AI jobs and restored datasets.
-- It has no application write path after retirement; old transaction flags cannot advance it.
CREATE OR REPLACE FUNCTION public.fn_guard_business_reset_generation() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public, pg_temp AS $function$
BEGIN
    IF NEW.business_reset_generation IS DISTINCT FROM OLD.business_reset_generation THEN
        RAISE EXCEPTION 'The retired business dataset generation is immutable' USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$function$;
COMMENT ON COLUMN public.authorization_state.business_reset_generation IS
    'Historical dataset generation retained to fence results created before a database recovery; no application reset capability exists';

-- Materialized-view refresh must continue to work after the old reset owner anchor disappears.
-- This helper authorizes refresh only. It does not accept the former reset boolean or actor context.
CREATE FUNCTION public.fn_require_runtime_refresh() RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public, pg_temp AS $function$
DECLARE owner_id oid; is_administrator boolean;
BEGIN
    SELECT proowner INTO STRICT owner_id FROM pg_catalog.pg_proc
      WHERE oid = 'public.refresh_finance_ar_ap_mv()'::regprocedure;
    SELECT rolsuper INTO is_administrator FROM pg_catalog.pg_roles WHERE rolname = session_user;
    IF NOT COALESCE(is_administrator, false) AND session_user <> 'uten'
       AND NOT pg_catalog.pg_has_role(session_user, owner_id, 'MEMBER') THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'runtime maintenance caller is not authorized';
    END IF;
END;
$function$;
REVOKE ALL ON FUNCTION public.fn_require_runtime_refresh() FROM PUBLIC;

DO $refresh_boundary$
DECLARE signature text; definition text; owner_name text;
    anchor constant text := 'PERFORM public.fn_require_runtime_maintenance(false);';
BEGIN
    FOREACH signature IN ARRAY ARRAY[
        'public.refresh_finance_ar_ap_mv()', 'public.refresh_production_monthly_mv()',
        'public.refresh_purchase_monthly_mv()', 'public.refresh_sales_monthly_mv()',
        'public.refresh_stock_monthly_mv()', 'public.refresh_subcontract_monthly_mv()'
    ] LOOP
        SELECT pg_get_functiondef(signature::regprocedure), pg_get_userbyid(proowner)
          INTO definition, owner_name FROM pg_catalog.pg_proc WHERE oid = signature::regprocedure;
        IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1 THEN
            RAISE EXCEPTION 'V919 cannot preserve the refresh boundary for %', signature;
        END IF;
        EXECUTE replace(definition, anchor, 'PERFORM public.fn_require_runtime_refresh();');
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.fn_require_runtime_refresh() TO %I', owner_name);
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'uten') THEN
        REVOKE ALL ON FUNCTION public.fn_require_runtime_refresh() FROM uten;
    END IF;
END;
$refresh_boundary$;

-- Explicit drops without CASCADE: an unknown dependency blocks the update.
DROP FUNCTION public.business_data_reset();
DROP FUNCTION public.fn_business_data_reset_refusals();
DROP FUNCTION public.fn_business_reset_table_policy();
DROP FUNCTION public.fn_clear_business_test_object_metadata();
DROP FUNCTION public.fn_business_test_reset_verify_purged();
DROP FUNCTION public.fn_business_test_reset_object_fingerprint();
DROP FUNCTION public.fn_business_test_reset_objects();
DROP FUNCTION public.fn_business_test_object_protected(text, text, text, text);
DROP FUNCTION public.fn_business_test_reset_require_caller();
DROP FUNCTION public.fn_business_test_reset_lock_sources();
DROP FUNCTION public.fn_business_test_reset_active();
DROP FUNCTION public.fn_require_runtime_maintenance(boolean);

-- The dedicated permission is removed from every current grant surface. Historical audit stays.
-- Removing a catalog row advances the global authorization epoch. Preserve only snapshots that
-- were current before this locked change; an already-stale delegation must never be revived.
LOCK TABLE public.permissions, public.permission_surface_permissions, public.department_permissions,
    public.user_permission_overrides, public.manager_permission_delegations, public.users,
    public.authorization_state IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE v919_authorization_before ON COMMIT DROP AS
SELECT account.id, account.auth_version, account.permission_delegation_generation, state.epoch
FROM public.users account CROSS JOIN public.authorization_state state WHERE state.singleton_id = 1;

DELETE FROM public.permission_surface_permissions
 WHERE permission_id IN (SELECT id FROM public.permissions WHERE code = 'system:business_data_reset');
DELETE FROM public.permissions WHERE code = 'system:business_data_reset';

-- Old tokens still expire through the advanced epoch. Suppress only the recursive per-recipient
-- auth-version bump while rebasing these reviewed snapshots, as in V896; audit triggers stay on.
ALTER TABLE public.manager_permission_delegations DISABLE TRIGGER trg_manager_permission_delegations_auth_version;
UPDATE public.manager_permission_delegations delegation
SET grantor_auth_version = grantor.auth_version, grantor_authorization_epoch = state.epoch,
    grantor_user_generation = CASE
        WHEN delegation.grantor_user_generation = previous.permission_delegation_generation
        THEN grantor.permission_delegation_generation ELSE delegation.grantor_user_generation END,
    target_user_generation = CASE
        WHEN delegation.target_user_generation = target_previous.permission_delegation_generation
        THEN target_account.permission_delegation_generation ELSE delegation.target_user_generation END,
    row_version = delegation.row_version + 1
FROM v919_authorization_before previous JOIN public.users grantor ON grantor.id = previous.id
CROSS JOIN v919_authorization_before target_previous JOIN public.users target_account ON target_account.id = target_previous.id
CROSS JOIN public.authorization_state state
WHERE delegation.granted_by_user_id = previous.id AND delegation.user_id = target_previous.id
  AND delegation.grantor_auth_version = previous.auth_version
  AND delegation.grantor_authorization_epoch = previous.epoch AND state.singleton_id = 1;
ALTER TABLE public.manager_permission_delegations ENABLE TRIGGER trg_manager_permission_delegations_auth_version;

DO $verify_retirement$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.prokind IN ('f', 'p')
          AND (p.proname = 'business_data_reset' OR p.proname LIKE 'fn_business_test_reset%'
               OR p.prosrc ~ '(fn_business_test_reset_active|app[.]test_business_reset|app[.]business_test_reset|business_data_reset\(\))')
    ) THEN
        RAISE EXCEPTION 'V919 found a remaining executable business reset entry or exception';
    END IF;
END;
$verify_retirement$;
