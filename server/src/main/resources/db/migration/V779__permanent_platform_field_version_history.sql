-- V750 definition identity/formula/sensitivity are immutable. Keep value versions against that same dictionary.
CREATE TABLE platform_record_field_versions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope varchar(100) NOT NULL,record_id uuid NOT NULL,version bigint NOT NULL,cells jsonb NOT NULL,
    payload jsonb NOT NULL,recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),actor_id uuid,
    operation text NOT NULL CHECK(operation IN('LEGACY_SNAPSHOT','INSERT','UPDATE','DELETE')),
    CHECK(version>0)
);
CREATE INDEX idx_platform_field_history_record ON platform_record_field_versions(scope,record_id,id DESC);
CREATE FUNCTION fn_platform_fields_keep_version() RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE snapshot jsonb; v_scope text; v_id uuid; v_version bigint;
BEGIN
    snapshot:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
    IF TG_OP='UPDATE' AND NEW.version=OLD.version AND NEW.cells IS NOT DISTINCT FROM OLD.cells THEN RETURN NEW; END IF;
    v_scope:=snapshot->>'scope';v_id:=(snapshot->>'record_id')::uuid;v_version:=(snapshot->>'version')::bigint;
    IF TG_OP='UPDATE' AND NEW.version<=OLD.version THEN
        RAISE EXCEPTION 'A retained field update requires a new version' USING ERRCODE='23514';
    END IF;
    INSERT INTO platform_record_field_versions(scope,record_id,version,cells,payload,actor_id,operation)
    VALUES(v_scope,v_id,v_version,snapshot->'cells',snapshot,
        NULLIF(current_setting('app.actor_id',true),'')::uuid,TG_OP);
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $function$;
CREATE TRIGGER trg_platform_fields_keep_version AFTER INSERT OR UPDATE OR DELETE ON platform_record_fields
FOR EACH ROW EXECUTE FUNCTION fn_platform_fields_keep_version();
ALTER TABLE platform_record_fields ENABLE ALWAYS TRIGGER trg_platform_fields_keep_version;
INSERT INTO platform_record_field_versions(scope,record_id,version,cells,payload,recorded_at,actor_id,operation)
SELECT scope,record_id,version,cells,to_jsonb(f),updated_at,updated_by,'LEGACY_SNAPSHOT' FROM platform_record_fields f;
CREATE TRIGGER trg_platform_field_versions_immutable BEFORE UPDATE OR DELETE ON platform_record_field_versions
FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER trg_platform_field_versions_no_truncate BEFORE TRUNCATE ON platform_record_field_versions
FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE platform_record_field_versions ENABLE ALWAYS TRIGGER trg_platform_field_versions_immutable;
ALTER TABLE platform_record_field_versions ENABLE ALWAYS TRIGGER trg_platform_field_versions_no_truncate;
-- Preserve the original private rows; ordinary audit carries only change identity/version metadata.
-- Existing audit rows are not rewritten. The HTTP DTO also projects old FULL snapshots safely.
DO $field_audit_metadata$
DECLARE definition text; anchor text:='    RETURN v_row;';
BEGIN
    SELECT pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure) INTO definition;
    IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'V779 cannot safely extend field audit projection'; END IF;
    definition:=replace(definition,anchor,
        E'    IF p_table_name IN (''platform_record_fields'',''platform_record_field_versions'',''platform_column_definitions'') THEN\n'
        || E'        v_row:=v_row-ARRAY[''cells'',''payload'',''formula'',''name'',''normalized_name'',''definition_fingerprint''];\n'
        || E'    END IF;\n' || anchor);
    EXECUTE definition;
END $field_audit_metadata$;
SELECT fn_audit_track_table('platform_record_fields','NONE','data_change',false);
SELECT fn_audit_track_table('platform_record_field_versions','FULL','data_change',false);
SELECT fn_audit_track_table('platform_column_definitions','COLUMN_SCOPED','data_change',false,
    ARRAY['scope','owner_user_id','value_type','price_protected'],true);
DO $reset_policy$
DECLARE definition text; anchor text:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'V779 cannot extend readonly reset inventory safely'; END IF;
    EXECUTE replace(definition,anchor,anchor || E',\n            (''platform_record_field_versions'', ''PRESERVE'')');
END $reset_policy$;
