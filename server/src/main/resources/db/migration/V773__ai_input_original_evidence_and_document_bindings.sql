-- Original recognition inputs are independent evidence, never AI result caches.
-- Forward-compatible with V742: terminal ai_jobs.input_bytes must still be NULL.
CREATE TABLE ai_input_originals (
    job_id uuid PRIMARY KEY,
    actor_user_id uuid NOT NULL,
    original_name text NOT NULL,
    input_kind varchar(24) NOT NULL,
    content_type text NOT NULL,
    declared_size bigint,
    declared_sha256 text,
    availability varchar(24) NOT NULL CHECK(availability IN('AVAILABLE','LEGACY_DB','LEGACY_CONFLICT','LEGACY_UNAVAILABLE')),
    storage_provider text,
    storage_key text,
    storage_version text,
    storage_size bigint,
    storage_sha256 text,
    legacy_bytes bytea,
    captured_at timestamptz,
    temporary_until timestamptz,
    archived_at timestamptz,
    archived_by text,
    archive_reason text,
    lifecycle_state varchar(24) NOT NULL DEFAULT 'AVAILABLE' CHECK(lifecycle_state IN('AVAILABLE','DELETE_PENDING','DELETED')),
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK(availability<>'AVAILABLE' OR (storage_provider IS NOT NULL AND storage_provider IN('internal','local')
        AND storage_key IS NOT NULL AND length(btrim(storage_key))>0 AND storage_size IS NOT NULL
        AND storage_size BETWEEN 1 AND 15728640 AND storage_sha256 IS NOT NULL AND storage_sha256 ~ '^[0-9a-f]{64}$'
        AND declared_size IS NOT NULL AND declared_sha256 IS NOT NULL AND declared_size=storage_size AND declared_sha256=storage_sha256
        AND captured_at IS NOT NULL
        AND (storage_provider<>'internal' OR (storage_version IS NOT NULL AND length(btrim(storage_version))>0)) AND legacy_bytes IS NULL)),
    CHECK(lifecycle_state<>'AVAILABLE' OR availability NOT IN('LEGACY_DB','LEGACY_CONFLICT') OR
        (legacy_bytes IS NOT NULL AND storage_size IS NOT NULL AND storage_sha256 IS NOT NULL AND storage_size=octet_length(legacy_bytes)
         AND storage_sha256=encode(digest(legacy_bytes,'sha256'),'hex'))),
    CHECK(availability<>'LEGACY_DB' OR (storage_size IS NOT NULL AND storage_sha256 IS NOT NULL AND declared_size IS NOT NULL
        AND declared_sha256 IS NOT NULL AND storage_size BETWEEN 1 AND 15728640
        AND storage_size=declared_size AND storage_sha256=declared_sha256))
);
CREATE INDEX idx_ai_input_originals_object ON ai_input_originals(storage_provider,storage_key,storage_version);
CREATE INDEX idx_ai_input_originals_expiry ON ai_input_originals(temporary_until,job_id)
WHERE lifecycle_state='AVAILABLE' AND availability IN('AVAILABLE','LEGACY_DB') AND temporary_until IS NOT NULL AND archived_at IS NULL;

-- All persisted records and original contents remain queryable. Expiry marks an archive, never destruction.
ALTER TABLE ai_jobs ADD COLUMN archived_at timestamptz,ADD COLUMN archived_by text,ADD COLUMN archive_reason text;
ALTER TABLE ai_call_logs ADD COLUMN archived_at timestamptz,ADD COLUMN archived_by text,ADD COLUMN archive_reason text;
ALTER TABLE sales_document_learning_receipts ADD COLUMN archived_at timestamptz,ADD COLUMN archived_by text,ADD COLUMN archive_reason text;
ALTER TABLE sales_quote_template_candidates ADD COLUMN archived_at timestamptz,ADD COLUMN archived_by text,ADD COLUMN archive_reason text;
ALTER TABLE ai_providers ADD COLUMN is_deleted boolean NOT NULL DEFAULT false,ADD COLUMN deleted_at timestamptz,
    ADD COLUMN deleted_by uuid,ADD COLUMN deleted_reason text;
ALTER TABLE notice_blessings ADD COLUMN is_deleted boolean NOT NULL DEFAULT false,ADD COLUMN deleted_at timestamptz,
    ADD COLUMN deleted_by uuid,ADD COLUMN deleted_reason text;

-- Every persisted candidate revision keeps its exact original row and private-object identity.
CREATE TABLE sales_quote_template_candidate_history (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_id uuid NOT NULL,
    payload jsonb NOT NULL,
    storage_provider text,storage_key text,storage_version text,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    actor_id uuid,
    operation text NOT NULL CHECK(operation IN('UPDATE','DELETE'))
);
CREATE INDEX idx_quote_candidate_history_job ON sales_quote_template_candidate_history(job_id,id DESC);
CREATE FUNCTION fn_retain_quote_candidate_revision() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_OP='UPDATE' AND ROW(NEW.actor_user_id,NEW.source_name,NEW.fingerprint,NEW.workbook_bytes,NEW.mapping,NEW.features,
        NEW.storage_provider,NEW.storage_key,NEW.storage_version,NEW.storage_size,NEW.storage_sha256)
      IS NOT DISTINCT FROM ROW(OLD.actor_user_id,OLD.source_name,OLD.fingerprint,OLD.workbook_bytes,OLD.mapping,OLD.features,
        OLD.storage_provider,OLD.storage_key,OLD.storage_version,OLD.storage_size,OLD.storage_sha256) THEN RETURN NEW; END IF;
    INSERT INTO sales_quote_template_candidate_history(job_id,payload,storage_provider,storage_key,storage_version,actor_id,operation)
    VALUES(OLD.job_id,to_jsonb(OLD),OLD.storage_provider,OLD.storage_key,OLD.storage_version,
        NULLIF(current_setting('app.actor_id',true),'')::uuid,TG_OP);
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $function$;
CREATE TRIGGER trg_retain_quote_candidate_revision BEFORE UPDATE OR DELETE ON sales_quote_template_candidates
FOR EACH ROW EXECUTE FUNCTION fn_retain_quote_candidate_revision();
CREATE FUNCTION fn_quote_candidate_history_immutable() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN RAISE EXCEPTION 'Candidate history is permanent' USING ERRCODE='55000'; END $function$;
CREATE TRIGGER trg_quote_candidate_history_immutable BEFORE UPDATE OR DELETE ON sales_quote_template_candidate_history
FOR EACH ROW EXECUTE FUNCTION fn_quote_candidate_history_immutable();
CREATE TRIGGER trg_quote_candidate_history_no_truncate BEFORE TRUNCATE ON sales_quote_template_candidate_history
FOR EACH STATEMENT EXECUTE FUNCTION fn_quote_candidate_history_immutable();
ALTER TABLE sales_quote_template_candidate_history ENABLE ALWAYS TRIGGER trg_quote_candidate_history_immutable;
ALTER TABLE sales_quote_template_candidate_history ENABLE ALWAYS TRIGGER trg_quote_candidate_history_no_truncate;

CREATE TABLE ai_input_original_bindings (
    job_id uuid NOT NULL REFERENCES ai_input_originals(job_id) ON DELETE RESTRICT,
    doc_type varchar(16) NOT NULL CHECK(doc_type IN('quote','order')),
    doc_id uuid NOT NULL,
    source_doc_type varchar(16) NOT NULL CHECK(source_doc_type IN('quote','order')),
    source_doc_id uuid NOT NULL,
    bound_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(job_id,doc_type,doc_id)
);
CREATE INDEX idx_ai_input_original_bindings_doc ON ai_input_original_bindings(doc_type,doc_id,job_id);
COMMENT ON TABLE ai_input_originals IS 'Exact original bytes/references; no FK cascade from disposable ai_jobs; legacy claims and actual digest stay separate';
COMMENT ON TABLE ai_input_original_bindings IS 'Append-only formal source lineage; AI result single-use stays unchanged; quote conversion inherits original evidence';

CREATE FUNCTION fn_capture_legacy_ai_original(source ai_jobs) RETURNS void LANGUAGE plpgsql AS $function$
DECLARE actual_size bigint; actual_sha text; quality text;
BEGIN
    IF source.kind<>'SALES_DOCUMENT_INTAKE' OR EXISTS(SELECT 1 FROM ai_input_originals WHERE job_id=source.id) THEN RETURN; END IF;
    actual_size:=octet_length(source.input_bytes);
    actual_sha:=CASE WHEN source.input_bytes IS NOT NULL THEN encode(digest(source.input_bytes,'sha256'),'hex') END;
    quality:=CASE WHEN source.input_bytes IS NULL THEN 'LEGACY_UNAVAILABLE'
        WHEN actual_size BETWEEN 1 AND 15728640 AND actual_size=source.input_size AND actual_sha=source.input_sha256 THEN 'LEGACY_DB'
        ELSE 'LEGACY_CONFLICT' END;
    INSERT INTO ai_input_originals(job_id,actor_user_id,original_name,input_kind,content_type,declared_size,declared_sha256,
        availability,storage_size,storage_sha256,legacy_bytes,captured_at,temporary_until)
    VALUES(source.id,source.submitted_by_user,source.input_name,source.input_kind,source.input_content_type,source.input_size,source.input_sha256,
        quality,actual_size,actual_sha,source.input_bytes,CASE WHEN source.input_bytes IS NOT NULL THEN now() END,
        CASE WHEN source.status IN('SUCCEEDED','FAILED','CANCELLED') AND source.finished_at>=source.created_at AND source.finished_at<=now()
            THEN source.finished_at+interval '7 days' END)
    ON CONFLICT(job_id) DO NOTHING;
END $function$;

-- Preserve still-present inputs before deployment, and explicitly mark truly lost history.
SELECT fn_capture_legacy_ai_original(job) FROM ai_jobs job WHERE job.kind='SALES_DOCUMENT_INTAKE';

-- A retained learning command can name a source whose job was already expired.
-- Keep an explicit unavailable placeholder, never manufacture bytes/hash/size.
CREATE TEMP TABLE ai_original_missing_receipt_refs ON COMMIT DROP AS
SELECT DISTINCT receipt.doc_type,receipt.doc_id,receipt.actor_user_id,checked.job_id
FROM sales_document_learning_receipts receipt CROSS JOIN LATERAL (
    SELECT receipt.request_payload->>'intakeJobId' AS value
    UNION ALL SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(receipt.request_payload->'additionalIntakeJobIds')='array'
        THEN receipt.request_payload->'additionalIntakeJobIds' ELSE '[]'::jsonb END)
) reference
CROSS JOIN LATERAL(SELECT CASE WHEN reference.value ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    THEN reference.value::uuid END AS job_id) checked
WHERE checked.job_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM ai_jobs job WHERE job.id=checked.job_id);
INSERT INTO ai_input_originals(job_id,actor_user_id,original_name,input_kind,content_type,availability)
SELECT DISTINCT ON(job_id) job_id,actor_user_id,'原识别文件（历史信息缺失）','UNKNOWN','application/octet-stream','LEGACY_UNAVAILABLE'
FROM ai_original_missing_receipt_refs ORDER BY job_id,actor_user_id ON CONFLICT DO NOTHING;
INSERT INTO ai_input_original_bindings(job_id,doc_type,doc_id,source_doc_type,source_doc_id)
SELECT refs.job_id,refs.doc_type,refs.doc_id,refs.doc_type,refs.doc_id FROM ai_original_missing_receipt_refs refs
JOIN ai_input_originals original ON original.job_id=refs.job_id AND original.actor_user_id=refs.actor_user_id
WHERE original.availability='LEGACY_UNAVAILABLE' ON CONFLICT DO NOTHING;

CREATE FUNCTION fn_ai_original_rolling_capture() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_OP='INSERT' THEN PERFORM fn_capture_legacy_ai_original(NEW);
    ELSE PERFORM fn_capture_legacy_ai_original(OLD); END IF;
    IF NEW.kind='SALES_DOCUMENT_INTAKE' AND NEW.status IN('SUCCEEDED','FAILED','CANCELLED')
       AND NEW.finished_at>=NEW.created_at AND NEW.finished_at<=now() THEN
        UPDATE ai_input_originals SET temporary_until=GREATEST(temporary_until,NEW.finished_at+interval '7 days')
        WHERE job_id=NEW.id AND NOT EXISTS(SELECT 1 FROM ai_input_original_bindings WHERE job_id=NEW.id);
    END IF;
    -- An old application node may reserve/consume the result after this migration.
    -- Bind in the same transaction as its verified destination marker, before expiry can win.
    IF NEW.kind='SALES_DOCUMENT_INTAKE' AND NEW.status='SUCCEEDED' AND NEW.used_doc_id IS NOT NULL
       AND ((NEW.used_doc_type='quote' AND EXISTS(SELECT 1 FROM sales_quotes WHERE id=NEW.used_doc_id))
            OR (NEW.used_doc_type='order' AND EXISTS(SELECT 1 FROM sales_orders WHERE id=NEW.used_doc_id))) THEN
        INSERT INTO ai_input_original_bindings(job_id,doc_type,doc_id,source_doc_type,source_doc_id)
        VALUES(NEW.id,NEW.used_doc_type,NEW.used_doc_id,NEW.used_doc_type,NEW.used_doc_id) ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END $function$;
CREATE TRIGGER trg_ai_original_rolling_capture BEFORE INSERT OR UPDATE ON ai_jobs
FOR EACH ROW EXECUTE FUNCTION fn_ai_original_rolling_capture();

-- Known historical adoption is a relationship, even where the original had already disappeared.
INSERT INTO ai_input_original_bindings(job_id,doc_type,doc_id,source_doc_type,source_doc_id)
SELECT id,used_doc_type,used_doc_id,used_doc_type,used_doc_id FROM ai_jobs
WHERE kind='SALES_DOCUMENT_INTAKE' AND used_doc_type IN('quote','order') AND used_doc_id IS NOT NULL
ON CONFLICT DO NOTHING;

CREATE FUNCTION fn_ai_original_inherit_quote() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.source_quote_id IS NOT NULL THEN
        INSERT INTO ai_input_original_bindings(job_id,doc_type,doc_id,source_doc_type,source_doc_id)
        SELECT job_id,'order',NEW.id,'quote',NEW.source_quote_id FROM ai_input_original_bindings
        WHERE doc_type='quote' AND doc_id=NEW.source_quote_id ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END $function$;
CREATE TRIGGER trg_ai_original_inherit_quote AFTER INSERT OR UPDATE OF source_quote_id ON sales_orders
FOR EACH ROW EXECUTE FUNCTION fn_ai_original_inherit_quote();
INSERT INTO ai_input_original_bindings(job_id,doc_type,doc_id,source_doc_type,source_doc_id)
SELECT binding.job_id,'order',orders.id,'quote',orders.source_quote_id
FROM sales_orders orders JOIN ai_input_original_bindings binding ON binding.doc_type='quote' AND binding.doc_id=orders.source_quote_id
ON CONFLICT DO NOTHING;

CREATE FUNCTION fn_ai_original_binding_immutable() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN RAISE EXCEPTION 'Formal input-original bindings are append-only' USING ERRCODE='23514'; END $function$;
CREATE TRIGGER trg_ai_original_binding_immutable BEFORE UPDATE OR DELETE ON ai_input_original_bindings
FOR EACH ROW EXECUTE FUNCTION fn_ai_original_binding_immutable();
ALTER TABLE ai_input_original_bindings ENABLE ALWAYS TRIGGER trg_ai_original_binding_immutable;

CREATE FUNCTION fn_ai_original_identity_immutable() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Original identity is retained' USING ERRCODE='23514'; END IF;
    IF ROW(NEW.job_id,NEW.actor_user_id,NEW.original_name,NEW.input_kind,NEW.content_type,NEW.declared_size,NEW.declared_sha256,
           NEW.availability,NEW.storage_provider,NEW.storage_key,NEW.storage_version,NEW.storage_size,NEW.storage_sha256,NEW.captured_at)
       IS DISTINCT FROM ROW(OLD.job_id,OLD.actor_user_id,OLD.original_name,OLD.input_kind,OLD.content_type,OLD.declared_size,OLD.declared_sha256,
           OLD.availability,OLD.storage_provider,OLD.storage_key,OLD.storage_version,OLD.storage_size,OLD.storage_sha256,OLD.captured_at)
       OR NEW.legacy_bytes IS DISTINCT FROM OLD.legacy_bytes THEN
        RAISE EXCEPTION 'Original bytes and identity are immutable' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM ai_input_original_bindings WHERE job_id=OLD.job_id)
       AND NEW.lifecycle_state IS DISTINCT FROM OLD.lifecycle_state THEN
        RAISE EXCEPTION 'Formal input original cannot expire' USING ERRCODE='23514';
    END IF;
    IF OLD.availability IN('LEGACY_CONFLICT','LEGACY_UNAVAILABLE') AND NEW.lifecycle_state IS DISTINCT FROM OLD.lifecycle_state THEN
        RAISE EXCEPTION 'Uncertain historical evidence requires explicit investigation' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $function$;
CREATE TRIGGER trg_ai_original_identity_immutable BEFORE UPDATE OR DELETE ON ai_input_originals
FOR EACH ROW EXECUTE FUNCTION fn_ai_original_identity_immutable();
ALTER TABLE ai_input_originals ENABLE ALWAYS TRIGGER trg_ai_original_identity_immutable;

CREATE FUNCTION fn_ai_original_binding_guard() RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE state text; quality text;
BEGIN
    SELECT lifecycle_state,availability INTO state,quality FROM ai_input_originals WHERE job_id=NEW.job_id FOR UPDATE;
    IF state IS DISTINCT FROM 'AVAILABLE' THEN RAISE EXCEPTION 'Expired original cannot acquire a formal binding' USING ERRCODE='23514'; END IF;
    IF quality NOT IN('AVAILABLE','LEGACY_DB') AND NOT EXISTS(
        SELECT 1 FROM ai_input_original_bindings binding WHERE binding.job_id=NEW.job_id
          AND ((binding.doc_type=NEW.doc_type AND binding.doc_id=NEW.doc_id)
            OR (NEW.source_doc_type='quote' AND binding.doc_type='quote' AND binding.doc_id=NEW.source_doc_id))) THEN
        RAISE EXCEPTION 'Historical original is unavailable or conflicting; upload a verified source' USING ERRCODE='23514';
    END IF;
    -- Formal originals leave the expiry candidate range permanently.
    UPDATE ai_input_originals SET temporary_until=NULL WHERE job_id=NEW.job_id AND temporary_until IS NOT NULL;
    RETURN NEW;
END $function$;
CREATE TRIGGER trg_ai_original_binding_guard BEFORE INSERT ON ai_input_original_bindings
FOR EACH ROW EXECUTE FUNCTION fn_ai_original_binding_guard();
UPDATE ai_input_originals original SET temporary_until=NULL
WHERE EXISTS(SELECT 1 FROM ai_input_original_bindings binding WHERE binding.job_id=original.job_id);

-- Payload-only candidates prevent repeated scans over permanently retained empty receipt shells.
CREATE INDEX idx_sales_learning_receipts_payload_expiry ON sales_document_learning_receipts(retry_until,id)
WHERE archived_at IS NULL AND (evidence<>'{}'::jsonb OR request_payload->'lines'<>'[]'::jsonb OR request_payload->'clientFields'<>'{}'::jsonb);
CREATE INDEX idx_ai_jobs_result_expiry ON ai_jobs(finished_at,id)
WHERE archived_at IS NULL AND status IN('SUCCEEDED','FAILED','CANCELLED') AND result IS NOT NULL AND finished_at>=created_at;
CREATE INDEX idx_ai_jobs_finished_cleanup ON ai_jobs(finished_at,id)
WHERE archived_at IS NULL AND status IN('SUCCEEDED','FAILED','CANCELLED') AND result IS NULL AND finished_at>=created_at;
CREATE INDEX idx_ai_call_logs_archive ON ai_call_logs(created_at,id) WHERE archived_at IS NULL;
CREATE INDEX idx_sales_quote_template_candidates_archive ON sales_quote_template_candidates(expires_at,job_id) WHERE archived_at IS NULL;

CREATE OR REPLACE VIEW v_private_document_storage_references AS
SELECT storage_provider,storage_key,storage_version FROM v_sales_quote_template_storage_references
UNION SELECT storage_provider,storage_key,storage_version FROM goods_cost_imports
UNION SELECT storage_provider,storage_key,storage_version FROM ai_input_originals
WHERE availability='AVAILABLE' AND lifecycle_state='AVAILABLE'
UNION SELECT storage_provider,storage_key,storage_version FROM sales_quote_template_candidate_history
WHERE storage_provider IS NOT NULL AND storage_key IS NOT NULL;
-- Private bytes are deliberately not copied into row-audit records.
SELECT fn_audit_track_table('ai_input_originals','NONE','data_change',false);
SELECT fn_audit_track_table('ai_input_original_bindings','FULL','data_change',false);
DO $reset_policy$
DECLARE definition text; anchor text := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V773 cannot extend reset policy safely'; END IF;
    EXECUTE replace(definition,anchor,anchor || E',\n            (''ai_input_originals'', ''PRESERVE''),'
        || E'\n            (''ai_input_original_bindings'', ''PRESERVE''),'
        || E'\n            (''sales_quote_template_candidate_history'', ''PRESERVE'')');
END $reset_policy$;
