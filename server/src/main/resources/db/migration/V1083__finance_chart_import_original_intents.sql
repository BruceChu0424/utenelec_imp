-- Keep original uploads, literal previews and successful receipts in their
-- original table. A deliberate review may reuse the immutable file reference;
-- retrying an upload still resolves exactly one actor/content root.
ALTER TABLE finance_chart_imports
    ADD COLUMN parent_import_id uuid REFERENCES finance_chart_imports(id),
    ADD COLUMN review_request_id uuid UNIQUE REFERENCES finance_chart_manual_operations(request_id) DEFERRABLE INITIALLY DEFERRED,
    ADD COLUMN apply_receipt jsonb,
    ADD COLUMN cancelled_at timestamptz,
    ADD COLUMN cancellation_result jsonb;
ALTER TABLE finance_chart_imports DROP CONSTRAINT finance_chart_imports_actor_id_sha256_key;
CREATE UNIQUE INDEX uq_finance_chart_import_root_content ON finance_chart_imports(actor_id,sha256)
    WHERE parent_import_id IS NULL;
CREATE INDEX idx_finance_chart_import_actor_recent ON finance_chart_imports(actor_id,created_at DESC,id);
ALTER TABLE finance_chart_imports
    ADD CONSTRAINT ck_finance_chart_review_lineage CHECK((parent_import_id IS NULL)=(review_request_id IS NULL)),
    ADD CONSTRAINT ck_finance_chart_apply_stop CHECK((cancelled_at IS NULL)=(cancellation_result IS NULL)
        AND NOT(applied_at IS NOT NULL AND cancelled_at IS NOT NULL)
        AND (apply_receipt IS NULL OR applied_at IS NOT NULL));

CREATE FUNCTION fn_guard_finance_chart_import_intent() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE parent finance_chart_imports%ROWTYPE; literal_new jsonb; literal_old jsonb; item jsonb; current_version bigint; receipt jsonb;
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'Original chart files, previews and receipts are retained' USING ERRCODE='23514';
    END IF;
    IF TG_OP='UPDATE' THEN
        IF (NEW.id,NEW.actor_id,NEW.source_name,NEW.sha256,NEW.storage_provider,NEW.storage_key,NEW.storage_version,
            NEW.storage_size,NEW.preview,NEW.created_at,NEW.parent_import_id,NEW.review_request_id)
            IS DISTINCT FROM (OLD.id,OLD.actor_id,OLD.source_name,OLD.sha256,OLD.storage_provider,OLD.storage_key,OLD.storage_version,
            OLD.storage_size,OLD.preview,OLD.created_at,OLD.parent_import_id,OLD.review_request_id) THEN
            RAISE EXCEPTION 'Original chart file identity, literal preview and review lineage are immutable' USING ERRCODE='23514';
        END IF;
        IF (OLD.applied_at IS NOT NULL OR OLD.cancelled_at IS NOT NULL) AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN
            RAISE EXCEPTION 'Terminal chart import receipts cannot be rewritten or revived' USING ERRCODE='23514';
        END IF;
        IF OLD.applied_at IS NULL AND OLD.cancelled_at IS NULL AND NEW.applied_at IS NOT NULL THEN
            IF NEW.apply_receipt IS NULL OR NEW.applied_result->>'importId' IS DISTINCT FROM NEW.id::text
                OR NEW.applied_result->>'status' IS DISTINCT FROM 'APPLIED'
                OR jsonb_typeof(NEW.preview->'rows') IS DISTINCT FROM 'array' THEN
                RAISE EXCEPTION 'A new chart success requires its bound original apply receipt' USING ERRCODE='23514';
            END IF;
            IF jsonb_array_length(NEW.preview->'rows')=0
                OR NEW.applied_result->'imported' IS DISTINCT FROM to_jsonb(jsonb_array_length(NEW.preview->'rows')) THEN
                RAISE EXCEPTION 'A chart success must prove its complete nonempty original preview' USING ERRCODE='23514';
            END IF;
        END IF;
    ELSE
        -- Existing pre1083 successes may retain their original NULL proof.
        -- No new root or child may impersonate that historical format.
        IF NEW.applied_at IS NOT NULL OR NEW.applied_result IS NOT NULL OR NEW.apply_receipt IS NOT NULL
                OR NEW.cancelled_at IS NOT NULL OR NEW.cancellation_result IS NOT NULL THEN
            RAISE EXCEPTION 'A new chart import starts as one unapplied preview without a terminal receipt' USING ERRCODE='23514';
        END IF;
    END IF;
    IF TG_OP='INSERT' AND NEW.parent_import_id IS NOT NULL THEN
        IF NEW.id=NEW.parent_import_id THEN
            RAISE EXCEPTION 'A deliberate chart review requires a distinct retained parent' USING ERRCODE='23514';
        END IF;
        SELECT * INTO parent FROM finance_chart_imports WHERE id=NEW.parent_import_id FOR SHARE;
        IF NOT FOUND OR (NEW.actor_id,NEW.source_name,NEW.sha256,NEW.storage_provider,NEW.storage_key,NEW.storage_version,NEW.storage_size)
                IS DISTINCT FROM (parent.actor_id,parent.source_name,parent.sha256,parent.storage_provider,parent.storage_key,parent.storage_version,parent.storage_size) THEN
            RAISE EXCEPTION 'A chart review must retain its own original source file reference' USING ERRCODE='23514';
        END IF;
        IF jsonb_typeof(NEW.preview->'rows') IS DISTINCT FROM 'array'
                OR jsonb_typeof(parent.preview->'rows') IS DISTINCT FROM 'array'
                OR NEW.preview->>'importId' IS DISTINCT FROM NEW.id::text
                OR (NEW.preview-'importId'-'rows') IS DISTINCT FROM (parent.preview-'importId'-'rows') THEN
            RAISE EXCEPTION 'A chart review cannot replace literal source fields' USING ERRCODE='23514';
        END IF;
        SELECT coalesce(jsonb_agg(value-'existingVersion' ORDER BY ord),'[]'::jsonb) INTO literal_new
            FROM jsonb_array_elements(NEW.preview->'rows') WITH ORDINALITY source(value,ord);
        SELECT coalesce(jsonb_agg(value-'existingVersion' ORDER BY ord),'[]'::jsonb) INTO literal_old
            FROM jsonb_array_elements(parent.preview->'rows') WITH ORDINALITY source(value,ord);
        IF literal_new IS DISTINCT FROM literal_old THEN
            RAISE EXCEPTION 'A chart review must preserve all source rows and their original order' USING ERRCODE='23514';
        END IF;
        FOR item IN SELECT value FROM jsonb_array_elements(NEW.preview->'rows') LOOP
            SELECT row_version INTO current_version FROM finance_chart_codes WHERE code=item->>'code';
            IF item->'existingVersion' IS DISTINCT FROM coalesce(to_jsonb(current_version),'null'::jsonb) THEN
                RAISE EXCEPTION 'Chart review versions must match the actual current directory' USING ERRCODE='23514';
            END IF;
        END LOOP;
    END IF;
    receipt:=coalesce(NEW.cancellation_result,NEW.apply_receipt);
    IF receipt IS NOT NULL THEN
        IF receipt->>'requestId' IS DISTINCT FROM NEW.id::text OR receipt->>'actorId' IS DISTINCT FROM NEW.actor_id::text
            OR receipt->>'operation' IS DISTINCT FROM 'CHART_IMPORT_APPLY' OR receipt->>'method' IS DISTINCT FROM 'POST'
            OR receipt->>'path' IS DISTINCT FROM '/finance/chart/import-apply'
            OR receipt->'found' IS DISTINCT FROM 'true'::jsonb
            OR receipt->'requestBody' IS DISTINCT FROM jsonb_build_object('importId',NEW.id::text) THEN
            RAISE EXCEPTION 'Chart apply receipts must prove their original actor, key and body' USING ERRCODE='23514';
        END IF;
        IF NEW.cancellation_result IS NOT NULL THEN
            IF receipt->>'outcome' IS DISTINCT FROM 'CANCELLED_UNWRITTEN' OR receipt#>'{result,cancelled}' IS DISTINCT FROM 'true'::jsonb THEN
                RAISE EXCEPTION 'Chart stop receipts must be an explicit unwritten terminal result' USING ERRCODE='23514';
            END IF;
        ELSIF receipt->>'outcome' IS DISTINCT FROM 'SUCCEEDED' OR receipt->'result' IS DISTINCT FROM NEW.applied_result THEN
            RAISE EXCEPTION 'Chart success proof must retain the original applied result' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_finance_chart_import_intent BEFORE INSERT OR UPDATE OR DELETE ON finance_chart_imports
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_chart_import_intent();
ALTER TABLE finance_chart_imports ENABLE ALWAYS TRIGGER trg_finance_chart_import_intent;

CREATE FUNCTION fn_guard_finance_chart_review_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE stored finance_chart_manual_operations%ROWTYPE; root_id uuid; path text; body jsonb; expected_hash text;
BEGIN
    IF NEW.parent_import_id IS NULL THEN RETURN NULL; END IF;
    SELECT * INTO stored FROM finance_chart_manual_operations WHERE request_id=NEW.review_request_id;
    WITH RECURSIVE source AS (
        SELECT id,parent_import_id,ARRAY[id] AS visited FROM finance_chart_imports WHERE id=NEW.parent_import_id
        UNION ALL SELECT p.id,p.parent_import_id,s.visited||p.id FROM source s JOIN finance_chart_imports p ON p.id=s.parent_import_id
            WHERE NOT p.id=ANY(s.visited)
    ) SELECT id INTO root_id FROM source WHERE parent_import_id IS NULL;
    path:='/finance/chart/imports/'||NEW.parent_import_id::text||'/repreview';
    body:=jsonb_build_object('requestId',NEW.review_request_id::text);
    expected_hash:=encode(digest('CHART_IMPORT_REPREVIEW:'||path||':'||
        encode(digest('{"requestId":"'||NEW.review_request_id::text||'"}','sha256'),'hex'),'sha256'),'hex');
    IF root_id IS NULL OR stored.actor_id IS DISTINCT FROM NEW.actor_id OR stored.fingerprint IS DISTINCT FROM expected_hash
        OR stored.result->>'requestId' IS DISTINCT FROM NEW.review_request_id::text
        OR stored.result->>'actorId' IS DISTINCT FROM NEW.actor_id::text
        OR stored.result->>'operation' IS DISTINCT FROM 'CHART_IMPORT_REPREVIEW'
        OR stored.result->>'method' IS DISTINCT FROM 'POST' OR stored.result->>'path' IS DISTINCT FROM path
        OR stored.result->>'outcome' IS DISTINCT FROM 'SUCCEEDED' OR stored.result->'found' IS DISTINCT FROM 'true'::jsonb
        OR stored.result->'requestBody' IS DISTINCT FROM body
        OR stored.result#>>'{result,status}' IS DISTINCT FROM 'PREVIEWED'
        OR stored.result#>>'{result,requestId}' IS DISTINCT FROM NEW.review_request_id::text
        OR stored.result#>>'{result,importId}' IS DISTINCT FROM NEW.id::text
        OR stored.result#>>'{result,parentImportId}' IS DISTINCT FROM NEW.parent_import_id::text
        OR stored.result#>>'{result,sourceImportId}' IS DISTINCT FROM root_id::text
        OR stored.result#>>'{result,sha256}' IS DISTINCT FROM NEW.sha256 THEN
        RAISE EXCEPTION 'A deliberate chart preview requires its exact immutable original request receipt' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_finance_chart_review_receipt AFTER INSERT ON finance_chart_imports
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_chart_review_receipt();
ALTER TABLE finance_chart_imports ENABLE ALWAYS TRIGGER trg_finance_chart_review_receipt;

-- Only source identity/terminal metadata is public audit material. File names,
-- literal previews, original bodies and both result payloads remain private.
SELECT public.fn_audit_track_table('finance_chart_imports','COLUMN_SCOPED','data_change',false,
    ARRAY['id','actor_id','sha256','applied_at','created_at','parent_import_id','review_request_id','cancelled_at'],true,NULL);
SELECT public.fn_refresh_finance_audit_metadata_projection();
