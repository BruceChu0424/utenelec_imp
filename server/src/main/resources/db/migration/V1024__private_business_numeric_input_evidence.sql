-- Immutable numeric provenance only: no business balances, credentials or full requests.
CREATE TABLE business_numeric_input_evidence(
 id uuid PRIMARY KEY,owner_kind text NOT NULL CHECK(owner_kind~'^[A-Z][A-Z0-9_]{0,79}$'),owner_id uuid NOT NULL,
 source_row_id uuid NOT NULL,field_key text NOT NULL CHECK(field_key~'^[A-Za-z][A-Za-z0-9_.]{0,79}$'),
 owner_version text NOT NULL CHECK(length(owner_version) BETWEEN 1 AND 128),source_action_id text NOT NULL,
 original_decimal text NOT NULL CHECK(length(original_decimal)<=1100 AND original_decimal~'^-?[0-9]+([.][0-9]+)?$'),
 original_unit jsonb NOT NULL CHECK(jsonb_typeof(original_unit)='object' AND (original_unit->>'kind') IS NOT NULL AND (original_unit->>'kind')~'^[A-Z][A-Z0-9_]{0,39}$' AND original_unit-ARRAY['kind','code','referenceId']='{}'::jsonb AND octet_length(original_unit::text)<=2048),
 recorded_decimal text NOT NULL CHECK(length(recorded_decimal)<=100 AND recorded_decimal~'^-?[0-9]+([.][0-9]+)?$' AND fn_financial_book_amount_is_exact(recorded_decimal::numeric)),
 recorded_unit jsonb NOT NULL CHECK(jsonb_typeof(recorded_unit)='object' AND (recorded_unit->>'kind') IS NOT NULL AND (recorded_unit->>'kind')~'^[A-Z][A-Z0-9_]{0,39}$' AND recorded_unit-ARRAY['kind','code','referenceId']='{}'::jsonb AND octet_length(recorded_unit::text)<=2048),
 precision_policy jsonb NOT NULL CHECK(jsonb_typeof(precision_policy)='object' AND (precision_policy->>'version') IS NOT DISTINCT FROM '1' AND jsonb_typeof(precision_policy->'choices') IS NOT DISTINCT FROM 'object' AND precision_policy-ARRAY['version','choices']='{}'::jsonb AND octet_length(precision_policy::text)<=16384),
 actor_id uuid NOT NULL REFERENCES users(id),request_id uuid,fingerprint text NOT NULL CHECK(fingerprint~'^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(owner_kind,owner_id,source_row_id,field_key,source_action_id)
);
CREATE INDEX business_numeric_input_owner_idx ON business_numeric_input_evidence(owner_kind,owner_id,source_row_id,created_at);
CREATE FUNCTION fn_guard_business_numeric_input_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.source_action_id<>pg_current_xact_id()::text OR NEW.actor_id IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'')::uuid
  OR NEW.request_id IS DISTINCT FROM NULLIF(current_setting('app.audit_request_id',true),'')::uuid THEN
  RAISE EXCEPTION 'Numeric provenance must belong to the actual same transaction actor/action/request' USING ERRCODE='23514';END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each(NEW.precision_policy->'choices') selected
  WHERE selected.value IS DISTINCT FROM fn_business_precision_snapshot()->'choices'->selected.key) THEN
  RAISE EXCEPTION 'Numeric provenance cannot invent a precision choice' USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER business_numeric_input_intake BEFORE INSERT ON business_numeric_input_evidence FOR EACH ROW EXECUTE FUNCTION fn_guard_business_numeric_input_evidence();
CREATE TRIGGER business_numeric_input_immutable BEFORE UPDATE OR DELETE ON business_numeric_input_evidence FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER business_numeric_input_no_truncate BEFORE TRUNCATE ON business_numeric_input_evidence FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE business_numeric_input_evidence ENABLE ALWAYS TRIGGER business_numeric_input_intake;
ALTER TABLE business_numeric_input_evidence ENABLE ALWAYS TRIGGER business_numeric_input_immutable;
ALTER TABLE business_numeric_input_evidence ENABLE ALWAYS TRIGGER business_numeric_input_no_truncate;

-- Extend the one compiled metadata projection, not another redaction algorithm.
DO $numeric_audit_scope$
DECLARE definition text;signature text;
 old_names text:=$names$'gl_entries','gl_vouchers','accounts','ar_ap_ledger'$names$;
BEGIN
 FOREACH signature IN ARRAY ARRAY['fn_refresh_finance_audit_metadata_projection()','fn_audit_track_table(text,text,text,boolean,text[],boolean,text)'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO definition;
  IF position('business_numeric_input_evidence' IN definition)=0 THEN
   IF position(old_names IN definition)=0 THEN RAISE EXCEPTION 'Review numeric input audit projection scope: %',signature;END IF;
   EXECUTE replace(definition,old_names,old_names||$extra$,'business_numeric_input_evidence'$extra$);
  END IF;
 END LOOP;
END $numeric_audit_scope$;
SELECT fn_audit_track_table('business_numeric_input_evidence','COLUMN_SCOPED','data_change',false,
 ARRAY['id','owner_kind','owner_id','source_row_id','field_key','owner_version','source_action_id','actor_id','request_id','fingerprint','created_at'],true,NULL);
SELECT fn_refresh_finance_audit_metadata_projection();
