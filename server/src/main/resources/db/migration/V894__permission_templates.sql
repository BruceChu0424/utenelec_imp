-- Saved snapshots only: no role membership and no automatic change to applied accounts.
CREATE TABLE permission_templates (
    id uuid PRIMARY KEY,
    name varchar(80) NOT NULL CHECK (length(btrim(name)) > 0),
    description varchar(1000) NOT NULL DEFAULT '',
    permission_codes jsonb NOT NULL CHECK (jsonb_typeof(permission_codes) = 'array' AND jsonb_array_length(permission_codes) <= 3000),
    row_version bigint NOT NULL DEFAULT 0 CHECK (row_version >= 0),
    is_deleted boolean NOT NULL DEFAULT false,
    created_by uuid NOT NULL REFERENCES users(id),
    updated_by uuid NOT NULL REFERENCES users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX permission_templates_name_active_uq ON permission_templates(lower(btrim(name))) WHERE NOT is_deleted;
COMMENT ON TABLE permission_templates IS 'Super-admin saved permission snapshots; application writes reviewed central personal overrides, never role memberships';

CREATE FUNCTION fn_guard_permission_template_revision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'Permission template history must be retained' USING ERRCODE='23514';
    END IF;
    IF NEW.id<>OLD.id OR NEW.row_version<>OLD.row_version+1 OR OLD.is_deleted THEN
        RAISE EXCEPTION 'Permission template revision must advance once and deleted templates cannot be restored' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_permission_template_revision BEFORE UPDATE OR DELETE ON permission_templates
FOR EACH ROW EXECUTE FUNCTION fn_guard_permission_template_revision();
ALTER TABLE permission_templates ENABLE ALWAYS TRIGGER trg_permission_template_revision;
SELECT fn_audit_track_table('permission_templates','FULL','authorization',false);

-- Templates are authorization configuration and must survive clearing business transactions.
DO $reset_policy$
DECLARE definition text; anchor text := '(''user_permission_overrides'', ''PRESERVE'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V894 cannot extend permission template reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n    (''permission_templates'', ''PRESERVE'')');
END
$reset_policy$;
