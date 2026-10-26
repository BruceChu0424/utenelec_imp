-- Distinguish independent databases served through the same API address. The
-- historical reset generation alone can move backwards after a database switch.
-- Existing business data, authorization epochs and reset fences stay unchanged.
ALTER TABLE public.authorization_state
    ADD COLUMN business_dataset_id uuid NOT NULL DEFAULT gen_random_uuid();
-- Generate once for the existing singleton; later inserts must never silently
-- manufacture a replacement identity if the control row is missing.
ALTER TABLE public.authorization_state ALTER COLUMN business_dataset_id DROP DEFAULT;

COMMENT ON COLUMN public.authorization_state.business_dataset_id IS
    'Persistent dataset UUID for client cache/draft isolation; immutable after installation and retained by backups';

CREATE FUNCTION public.fn_guard_business_dataset_identity() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public, pg_temp AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'The business dataset identity is immutable' USING ERRCODE = '55000';
    END IF;
    IF NEW.business_dataset_id IS DISTINCT FROM OLD.business_dataset_id THEN
        RAISE EXCEPTION 'The business dataset identity is immutable' USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.fn_guard_business_dataset_identity() FROM PUBLIC;

CREATE TRIGGER trg_business_dataset_identity_guard
BEFORE UPDATE OF business_dataset_id OR DELETE ON public.authorization_state
FOR EACH ROW EXECUTE FUNCTION public.fn_guard_business_dataset_identity();
ALTER TABLE public.authorization_state ENABLE ALWAYS TRIGGER trg_business_dataset_identity_guard;

CREATE TRIGGER trg_business_dataset_identity_truncate_guard
BEFORE TRUNCATE ON public.authorization_state
FOR EACH STATEMENT EXECUTE FUNCTION public.fn_guard_business_dataset_identity();
ALTER TABLE public.authorization_state ENABLE ALWAYS TRIGGER trg_business_dataset_identity_truncate_guard;
