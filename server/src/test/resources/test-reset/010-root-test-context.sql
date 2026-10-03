-- Explicit testing-only exception requested by the user. Ordinary record deletion
-- and scheduled expiry still retain history. Existing V625 caller/actor checks,
-- application feature flag, super-admin step-up, confirmation and drain remain.
ALTER TABLE public.authorization_state
    ADD COLUMN business_reset_generation bigint NOT NULL DEFAULT 0
    CHECK(business_reset_generation>=0);
COMMENT ON COLUMN public.authorization_state.business_reset_generation IS
    'Only an explicit test business reset advances this generation; late external AI results must not repopulate the old test dataset';

CREATE FUNCTION public.fn_business_test_reset_active() RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp AS $function$
    SELECT COALESCE(current_setting('app.test_business_reset',true),'')='CLEAR_TEST_BUSINESS_WITH_HISTORY'
       AND EXISTS(SELECT 1 FROM pg_catalog.pg_roles actor WHERE actor.rolname=current_user
           AND (actor.rolsuper OR actor.oid=(SELECT proowner FROM pg_catalog.pg_proc
               WHERE oid='public.business_data_reset()'::regprocedure)))
$function$;
GRANT EXECUTE ON FUNCTION public.fn_business_test_reset_active() TO PUBLIC;
COMMENT ON FUNCTION public.fn_business_test_reset_active() IS
    'A transaction flag alone grants nothing: only the reset function owner or an existing database superuser can use the explicit test-maintenance exception';

CREATE FUNCTION public.fn_guard_business_reset_generation() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp AS $function$
BEGIN
    IF NEW.business_reset_generation IS DISTINCT FROM OLD.business_reset_generation
       AND (NOT public.fn_business_test_reset_active()
            OR NEW.business_reset_generation<>OLD.business_reset_generation+1) THEN
        RAISE EXCEPTION 'Only an explicit test reset can advance the business reset generation' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END $function$;
CREATE TRIGGER trg_business_reset_generation_guard
BEFORE UPDATE OF business_reset_generation ON public.authorization_state
FOR EACH ROW EXECUTE FUNCTION public.fn_guard_business_reset_generation();
ALTER TABLE public.authorization_state ENABLE ALWAYS TRIGGER trg_business_reset_generation_guard;
