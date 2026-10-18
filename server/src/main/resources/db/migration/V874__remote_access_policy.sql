-- Runtime access policy is deliberately disabled until the local administrator
-- verifies the tunnel, end-to-end TLS, MFA and negative network tests.
CREATE TABLE remote_access_policy (
    singleton_id integer PRIMARY KEY CHECK (singleton_id = 1),
    enabled boolean NOT NULL DEFAULT false,
    max_users integer NOT NULL DEFAULT 5 CHECK (max_users BETWEEN 1 AND 10000),
    version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid REFERENCES users(id)
);
INSERT INTO remote_access_policy(singleton_id, enabled, max_users)
SELECT 1, false, greatest(5, count(*)::integer)
FROM users WHERE remote_access AND NOT is_deleted;

CREATE FUNCTION fn_guard_remote_access_policy_revision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Remote access policy must never be deleted' USING ERRCODE='23514';
    END IF;
    IF NEW.singleton_id <> OLD.singleton_id OR NEW.version <> OLD.version + 1 THEN
        RAISE EXCEPTION 'Remote access policy revision must advance exactly once' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_remote_access_policy_revision BEFORE UPDATE OR DELETE ON remote_access_policy
FOR EACH ROW EXECUTE FUNCTION fn_guard_remote_access_policy_revision();
ALTER TABLE remote_access_policy ENABLE ALWAYS TRIGGER trg_guard_remote_access_policy_revision;

SELECT public.fn_audit_track_table('remote_access_policy','COLUMN_SCOPED','system',false,
    ARRAY['enabled','max_users','version'],false,NULL::text);
COMMENT ON TABLE remote_access_policy IS 'Company remote access boundary, preserved during business reset; not a database failover switch';

DO $remote_reset_policy$
DECLARE definition text; anchor text := '(''system_settings'', ''PRESERVE'')';
BEGIN
    SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V874 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''remote_access_policy'', ''PRESERVE'')');
END $remote_reset_policy$;
