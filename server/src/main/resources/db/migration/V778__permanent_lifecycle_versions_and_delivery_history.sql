-- Permanent lifecycle evidence, notice/provider versions and definitive SMS delivery facts.
-- Forward delta after frozen V773/V777; original/source bytes remain immutable.
DROP INDEX uq_ai_providers_name;
CREATE UNIQUE INDEX uq_ai_providers_name ON ai_providers(lower(name)) WHERE NOT is_deleted;
ALTER TABLE notice_user_states ADD COLUMN deleted_by uuid,ADD COLUMN deleted_by_name text,ADD COLUMN deleted_reason text;
ALTER TABLE visitor_sms_codes ADD COLUMN delivery_result text NOT NULL DEFAULT 'OPEN_OR_UNKNOWN',
    ADD COLUMN delivery_result_at timestamptz,ADD COLUMN delivery_actor text,ADD COLUMN delivery_reason text;
ALTER TABLE visitor_sms_codes ADD CONSTRAINT ck_sms_delivery_result CHECK(delivery_result IN('OPEN_OR_UNKNOWN','ACCEPTED','REJECTED','UNCERTAIN'));
CREATE INDEX idx_sms_delivered_phone_created ON visitor_sms_codes(phone,created_at DESC)
WHERE delivery_result<>'REJECTED';

CREATE FUNCTION fn_lifecycle_evidence_immutable() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN RAISE EXCEPTION 'Lifecycle history must be permanently retained' USING ERRCODE='55000'; END $function$;

-- Old database cleanup callers also retain the published rows. New Java archives directly.
CREATE FUNCTION fn_lifecycle_delete_archives_instead() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    EXECUTE format('UPDATE %I.%I SET archived_at=COALESCE(archived_at,clock_timestamp()),'
        || ' archived_by=COALESCE(archived_by,''legacy_cleanup''),archive_reason=COALESCE(archive_reason,''LEGACY_DELETE_INTENT_RETAINED'')'
        || ' WHERE %I=$1',TG_TABLE_SCHEMA,TG_TABLE_NAME,TG_ARGV[0]) USING (to_jsonb(OLD)->>TG_ARGV[0])::uuid;
    RETURN NULL;
END $function$;
CREATE TRIGGER trg_lifecycle_delete_archives BEFORE DELETE ON ai_jobs
FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_delete_archives_instead('id');
CREATE TRIGGER trg_lifecycle_delete_archives BEFORE DELETE ON ai_call_logs
FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_delete_archives_instead('id');
CREATE TRIGGER trg_lifecycle_delete_archives BEFORE DELETE ON sales_document_learning_receipts
FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_delete_archives_instead('id');
CREATE TRIGGER trg_lifecycle_delete_archives BEFORE DELETE ON sales_quote_template_candidates
FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_delete_archives_instead('job_id');
ALTER TABLE ai_jobs ENABLE ALWAYS TRIGGER trg_lifecycle_delete_archives;
ALTER TABLE ai_call_logs ENABLE ALWAYS TRIGGER trg_lifecycle_delete_archives;
ALTER TABLE sales_document_learning_receipts ENABLE ALWAYS TRIGGER trg_lifecycle_delete_archives;
ALTER TABLE sales_quote_template_candidates ENABLE ALWAYS TRIGGER trg_lifecycle_delete_archives;

-- A completed original result is still evidence after use; legacy UPDATE purge must not erase it.
CREATE FUNCTION fn_ai_job_keep_completed_result() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF OLD.status IN('SUCCEEDED','FAILED','CANCELLED') AND OLD.result IS NOT NULL AND NEW.result IS NULL THEN
        NEW.result:=OLD.result;NEW.result_purged_at:=OLD.result_purged_at;
        NEW.archived_at:=COALESCE(NEW.archived_at,clock_timestamp());
        NEW.archived_by:=COALESCE(NEW.archived_by,'legacy_cleanup');
        NEW.archive_reason:=COALESCE(NEW.archive_reason,'LEGACY_RESULT_CLEAR_INTENT_RETAINED');
    END IF;
    RETURN NEW;
END $function$;
CREATE TRIGGER trg_ai_job_keep_completed_result BEFORE UPDATE ON ai_jobs
FOR EACH ROW EXECUTE FUNCTION fn_ai_job_keep_completed_result();
ALTER TABLE ai_jobs ENABLE ALWAYS TRIGGER trg_ai_job_keep_completed_result;

CREATE FUNCTION fn_learning_keep_original_payload() RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE retained boolean:=false;
BEGIN
    IF OLD.evidence<>'{}'::jsonb AND COALESCE(NEW.evidence,'{}'::jsonb)='{}'::jsonb THEN
        NEW.evidence:=OLD.evidence;retained:=true;
    END IF;
    IF COALESCE(OLD.request_payload->'lines','[]'::jsonb)<>'[]'::jsonb
       AND COALESCE(NEW.request_payload->'lines','[]'::jsonb)='[]'::jsonb THEN
        NEW.request_payload:=jsonb_set(COALESCE(NEW.request_payload,'{}'::jsonb),'{lines}',OLD.request_payload->'lines',true);retained:=true;
    END IF;
    IF COALESCE(OLD.request_payload->'clientFields','{}'::jsonb)<>'{}'::jsonb
       AND COALESCE(NEW.request_payload->'clientFields','{}'::jsonb)='{}'::jsonb THEN
        NEW.request_payload:=jsonb_set(COALESCE(NEW.request_payload,'{}'::jsonb),'{clientFields}',OLD.request_payload->'clientFields',true);retained:=true;
    END IF;
    IF retained THEN
        NEW.request_payload:=OLD.request_payload;
        NEW.archived_at:=COALESCE(NEW.archived_at,clock_timestamp());NEW.archived_by:=COALESCE(NEW.archived_by,'legacy_cleanup');
        NEW.archive_reason:=COALESCE(NEW.archive_reason,'LEGACY_PAYLOAD_CLEAR_INTENT_RETAINED');
    END IF;
    RETURN NEW;
END $function$;
CREATE TRIGGER trg_learning_keep_original_payload BEFORE UPDATE ON sales_document_learning_receipts
FOR EACH ROW EXECUTE FUNCTION fn_learning_keep_original_payload();
ALTER TABLE sales_document_learning_receipts ENABLE ALWAYS TRIGGER trg_learning_keep_original_payload;

CREATE FUNCTION fn_ai_provider_delete_retains_row() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    UPDATE ai_providers SET is_deleted=true,enabled=false,is_default=false,
        deleted_at=COALESCE(deleted_at,clock_timestamp()),
        deleted_by=COALESCE(deleted_by,NULLIF(current_setting('app.actor_id',true),'')::uuid),
        deleted_reason=COALESCE(deleted_reason,'LEGACY_DELETE_INTENT_RETAINED'),updated_at=clock_timestamp()
    WHERE id=OLD.id AND NOT is_deleted;
    RETURN NULL;
END $function$;
CREATE TRIGGER trg_ai_provider_delete_retains_row BEFORE DELETE ON ai_providers
FOR EACH ROW EXECUTE FUNCTION fn_ai_provider_delete_retains_row();
ALTER TABLE ai_providers ENABLE ALWAYS TRIGGER trg_ai_provider_delete_retains_row;

CREATE TRIGGER trg_ai_jobs_no_truncate BEFORE TRUNCATE ON ai_jobs
FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER trg_ai_calls_no_truncate BEFORE TRUNCATE ON ai_call_logs
FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER trg_learning_receipts_no_truncate BEFORE TRUNCATE ON sales_document_learning_receipts
FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER trg_quote_candidates_no_truncate BEFORE TRUNCATE ON sales_quote_template_candidates
FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE ai_jobs ENABLE ALWAYS TRIGGER trg_ai_jobs_no_truncate;
ALTER TABLE ai_call_logs ENABLE ALWAYS TRIGGER trg_ai_calls_no_truncate;
ALTER TABLE sales_document_learning_receipts ENABLE ALWAYS TRIGGER trg_learning_receipts_no_truncate;
ALTER TABLE sales_quote_template_candidates ENABLE ALWAYS TRIGGER trg_quote_candidates_no_truncate;

CREATE TABLE notice_blessing_history (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,blessing_id uuid NOT NULL,notice_id uuid NOT NULL,
    payload jsonb NOT NULL,operation text NOT NULL,recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),actor_id uuid
);
CREATE INDEX idx_notice_blessing_history_notice ON notice_blessing_history(notice_id,id DESC);
CREATE FUNCTION fn_retain_notice_blessing_version() RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE snapshot jsonb; kind text;
BEGIN
    snapshot:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
    IF TG_OP='UPDATE' AND ROW(NEW.sender_name,NEW.content,NEW.is_deleted,NEW.deleted_at,NEW.deleted_by,NEW.deleted_reason)
       IS NOT DISTINCT FROM ROW(OLD.sender_name,OLD.content,OLD.is_deleted,OLD.deleted_at,OLD.deleted_by,OLD.deleted_reason) THEN RETURN NEW; END IF;
    kind:=CASE WHEN TG_OP='INSERT' THEN 'SEND' WHEN TG_OP='DELETE' OR (snapshot->>'is_deleted')::boolean THEN 'WITHDRAW'
        WHEN OLD.is_deleted THEN 'REACTIVATE' ELSE 'EDIT' END;
    INSERT INTO notice_blessing_history(blessing_id,notice_id,payload,operation,actor_id)
    VALUES((snapshot->>'id')::uuid,(snapshot->>'notice_id')::uuid,snapshot,kind,
        COALESCE(NULLIF(current_setting('app.actor_id',true),'')::uuid,(snapshot->>'user_id')::uuid));
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $function$;
CREATE TRIGGER trg_retain_notice_blessing_version AFTER INSERT OR UPDATE OR DELETE ON notice_blessings
FOR EACH ROW EXECUTE FUNCTION fn_retain_notice_blessing_version();
ALTER TABLE notice_blessings ENABLE ALWAYS TRIGGER trg_retain_notice_blessing_version;
INSERT INTO notice_blessing_history(blessing_id,notice_id,payload,operation,recorded_at,actor_id)
SELECT id,notice_id,to_jsonb(b),'LEGACY_SNAPSHOT',COALESCE(updated_at,created_at,now()),user_id FROM notice_blessings b;

CREATE TRIGGER trg_notice_blessing_history_immutable BEFORE UPDATE OR DELETE ON notice_blessing_history
FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER trg_notice_blessing_history_no_truncate BEFORE TRUNCATE ON notice_blessing_history
FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE notice_blessing_history ENABLE ALWAYS TRIGGER trg_notice_blessing_history_immutable;
ALTER TABLE notice_blessing_history ENABLE ALWAYS TRIGGER trg_notice_blessing_history_no_truncate;

CREATE TABLE ai_provider_history (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,provider_id uuid NOT NULL,
    payload jsonb NOT NULL,public_payload jsonb NOT NULL,operation text NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),actor_id uuid
);
CREATE INDEX idx_ai_provider_history_identity ON ai_provider_history(provider_id,id DESC);
CREATE FUNCTION fn_ai_provider_public_history(snapshot jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $function$
SELECT jsonb_build_object('name',snapshot->'name','preset',snapshot->'preset','region',snapshot->'region',
    'protocol',snapshot->'protocol','baseUrl',snapshot->'base_url','model',snapshot->'model',
    'jsonMode',snapshot->'json_mode','thinkingControl',snapshot->'thinking_control','sendTemperature',snapshot->'send_temperature',
    'supportsVision',snapshot->'supports_vision','maxOutputTokens',snapshot->'max_output_tokens','timeoutSeconds',snapshot->'timeout_seconds',
    'enabled',snapshot->'enabled','isDefault',snapshot->'is_default','deleted',snapshot->'is_deleted',
    'deletedAt',snapshot->'deleted_at','deletedBy',snapshot->'deleted_by','deletedReason',snapshot->'deleted_reason',
    'apiKeyConfigured',snapshot->>'secret' IS NOT NULL,'version',snapshot->'version')
$function$;
CREATE FUNCTION fn_retain_ai_provider_version() RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE snapshot jsonb;
BEGIN
    snapshot:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
    IF TG_OP='UPDATE' AND snapshot-'updated_at' IS NOT DISTINCT FROM to_jsonb(OLD)-'updated_at' THEN RETURN NEW; END IF;
    INSERT INTO ai_provider_history(provider_id,payload,public_payload,operation,actor_id)
    VALUES((snapshot->>'id')::uuid,snapshot,fn_ai_provider_public_history(snapshot),TG_OP,
        COALESCE(NULLIF(current_setting('app.actor_id',true),'')::uuid,(snapshot->>'updated_by')::uuid,(snapshot->>'created_by')::uuid));
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $function$;
CREATE TRIGGER trg_retain_ai_provider_version AFTER INSERT OR UPDATE OR DELETE ON ai_providers
FOR EACH ROW EXECUTE FUNCTION fn_retain_ai_provider_version();
ALTER TABLE ai_providers ENABLE ALWAYS TRIGGER trg_retain_ai_provider_version;
INSERT INTO ai_provider_history(provider_id,payload,public_payload,operation,recorded_at,actor_id)
SELECT id,to_jsonb(p),fn_ai_provider_public_history(to_jsonb(p)),'LEGACY_SNAPSHOT',COALESCE(updated_at,created_at,now()),updated_by FROM ai_providers p;
CREATE TRIGGER trg_ai_provider_history_immutable BEFORE UPDATE OR DELETE ON ai_provider_history
FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER trg_ai_provider_history_no_truncate BEFORE TRUNCATE ON ai_provider_history
FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE ai_provider_history ENABLE ALWAYS TRIGGER trg_ai_provider_history_immutable;
ALTER TABLE ai_provider_history ENABLE ALWAYS TRIGGER trg_ai_provider_history_no_truncate;
SELECT fn_audit_track_table('ai_provider_history','NONE','authorization',false);


CREATE TRIGGER trg_ai_original_bindings_no_truncate BEFORE TRUNCATE ON ai_input_original_bindings
FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE ai_input_original_bindings ENABLE ALWAYS TRIGGER trg_ai_original_bindings_no_truncate;
CREATE TRIGGER trg_ai_originals_no_truncate BEFORE TRUNCATE ON ai_input_originals
FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE ai_input_originals ENABLE ALWAYS TRIGGER trg_ai_originals_no_truncate;
ALTER TABLE ai_input_originals ADD CONSTRAINT ck_ai_original_permanent_available CHECK(lifecycle_state='AVAILABLE');
CREATE OR REPLACE VIEW v_private_document_storage_references AS
SELECT storage_provider,storage_key,storage_version FROM v_sales_quote_template_storage_references
UNION SELECT storage_provider,storage_key,storage_version FROM goods_cost_imports
UNION SELECT storage_provider,storage_key,storage_version FROM ai_input_originals WHERE availability='AVAILABLE'
UNION SELECT storage_provider,storage_key,storage_version FROM sales_quote_template_candidate_history
WHERE storage_provider IS NOT NULL AND storage_key IS NOT NULL;
DO $reset_policy$
DECLARE definition text; source text; anchor text := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'V778 cannot extend reset classification safely'; END IF;
    definition:=replace(definition,anchor,anchor || E',\n            (''notice_blessing_history'', ''PRESERVE''),'
        || E'\n            (''ai_provider_history'', ''PRESERVE'')');
    FOREACH source IN ARRAY ARRAY['ai_jobs','ai_call_logs','ai_providers','sales_document_learning_receipts',
            'sales_quote_template_candidates','sales_quote_template_evidence','sales_quote_customer_templates','sales_quote_template_versions',
            'notices','notice_user_states','notice_acknowledgments','notice_blessings','visitor_sms_codes'] LOOP
        definition:=regexp_replace(definition,format('[(]''%s''[[:space:]]*,[[:space:]]*''CLEAR''[)]',source),
            format('(''%s'', ''PRESERVE'')',source),'g');
    END LOOP;
    EXECUTE definition;
END $reset_policy$;

-- Keep the historical classifier/guards intact for readonly inventory, but no destructive reset can execute.
DO $permanent_reset_gate$
DECLARE definition text; marker text:=E'\nBEGIN\n';
BEGIN
    SELECT replace(pg_get_functiondef('public.business_data_reset()'::regprocedure),E'\r\n',E'\n') INTO definition;
    IF strpos(definition,marker)=0 THEN RAISE EXCEPTION 'V778 cannot locate the reset execution entry safely'; END IF;
    definition:=overlay(definition placing E'\nBEGIN\n    RAISE EXCEPTION ''PERMANENT_RETAIN prohibits business reset; use archive and authorized history management'' USING ERRCODE=''55000'';\n'
        from strpos(definition,marker) for length(marker));
    EXECUTE definition;
END $permanent_reset_gate$;

-- Definition values/formulas/sensitivity are immutable since V750; retain that same dictionary, not a second copy.
ALTER TABLE platform_column_definitions ENABLE ALWAYS TRIGGER trg_platform_column_definition_immutable;
CREATE TRIGGER trg_platform_column_definition_no_truncate BEFORE TRUNCATE ON platform_column_definitions
FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE platform_column_definitions ENABLE ALWAYS TRIGGER trg_platform_column_definition_no_truncate;
