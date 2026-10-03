-- User policy: logical deletion retains records, original contents and associations permanently.
ALTER TABLE attachments DROP CONSTRAINT attachments_lifecycle_state_chk;
ALTER TABLE attachments ADD CONSTRAINT attachments_lifecycle_state_chk CHECK(lifecycle_state IN(
    'LEGACY_UNVERIFIED','CLEAN','DELETE_PENDING','DELETE_FAILED','DELETED','RETAINED_HISTORY'));
ALTER TABLE attachments DROP CONSTRAINT attachments_clean_scan_chk;
ALTER TABLE attachments ADD CONSTRAINT attachments_clean_scan_chk CHECK(
    lifecycle_state IN('LEGACY_UNVERIFIED','DELETE_PENDING','DELETE_FAILED','DELETED')
    OR (lifecycle_state IN('CLEAN','RETAINED_HISTORY') AND scan_engine IS NOT NULL AND scanned_at IS NOT NULL AND promoted_at IS NOT NULL));
ALTER TABLE attachments ADD COLUMN delete_reason text;
ALTER TABLE attachment_object_outbox DROP CONSTRAINT attachment_object_outbox_status_chk;
ALTER TABLE attachment_object_outbox ADD CONSTRAINT attachment_object_outbox_status_chk
CHECK(status IN('PENDING','PROCESSING','SUCCEEDED','FAILED','RETAINED_HISTORY'));
COMMENT ON COLUMN attachment_object_outbox.status IS 'SUCCEEDED proves physical staging cleanup; RETAINED_HISTORY is a non-destructive final retention outcome and never deletion proof';
CREATE INDEX idx_attachments_owner_history ON attachments(owner_type,owner_id,created_at,id)
WHERE lifecycle_state IN('RETAINED_HISTORY','DELETED','DELETE_PENDING','DELETE_FAILED');

-- Recognize actual physical loss as unavailable history; never pretend those bytes were retained.
UPDATE attachments SET delete_reason='LEGACY_PHYSICAL_DELETION'
WHERE lifecycle_state='DELETED' AND delete_reason IS NULL;

CREATE FUNCTION fn_attachment_retained_identity_guard() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Attachment records and original identity must be retained' USING ERRCODE='23514'; END IF;
    IF OLD.lifecycle_state IN('CLEAN','RETAINED_HISTORY','DELETED','DELETE_PENDING','DELETE_FAILED')
       AND ROW(NEW.id,NEW.owner_type,NEW.owner_id,NEW.storage_provider,NEW.storage_key,NEW.storage_version,
           NEW.original_name,NEW.content_type,NEW.size_bytes,NEW.sha256,NEW.stored_size_bytes,NEW.storage_encoding,
           NEW.scan_engine,NEW.scan_signature,NEW.scanned_at,NEW.promoted_at)
       IS DISTINCT FROM ROW(OLD.id,OLD.owner_type,OLD.owner_id,OLD.storage_provider,OLD.storage_key,OLD.storage_version,
           OLD.original_name,OLD.content_type,OLD.size_bytes,OLD.sha256,OLD.stored_size_bytes,OLD.storage_encoding,
           OLD.scan_engine,OLD.scan_signature,OLD.scanned_at,OLD.promoted_at) THEN
        RAISE EXCEPTION 'Attachment original bytes and owner identity are immutable' USING ERRCODE='23514';
    END IF;
    IF OLD.lifecycle_state='RETAINED_HISTORY' AND
       (to_jsonb(NEW)-'updated_at'-'updated_by') IS DISTINCT FROM (to_jsonb(OLD)-'updated_at'-'updated_by') THEN
        RAISE EXCEPTION 'Deleted attachment history is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $function$;
CREATE TRIGGER trg_attachment_retained_identity_guard BEFORE UPDATE OR DELETE ON attachments
FOR EACH ROW EXECUTE FUNCTION fn_attachment_retained_identity_guard();
ALTER TABLE attachments ENABLE ALWAYS TRIGGER trg_attachment_retained_identity_guard;
CREATE FUNCTION fn_attachment_no_truncate() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    RAISE EXCEPTION 'Attachment records and original identity must be retained' USING ERRCODE='23514';
END $function$;
CREATE TRIGGER trg_attachment_no_truncate BEFORE TRUNCATE ON attachments
FOR EACH STATEMENT EXECUTE FUNCTION fn_attachment_no_truncate();
ALTER TABLE attachments ENABLE ALWAYS TRIGGER trg_attachment_no_truncate;

-- A retained source is a distinct completion outcome, not proof of physical deletion.
-- The source row and every upload/object identity remain PRESERVE through an explicit reset.
DO $retained_reset_proof$
DECLARE definition text; anchor text;
BEGIN
    SELECT pg_get_functiondef('fn_business_attachment_reset_blockers()'::regprocedure) INTO definition;
    anchor:='WHERE attachment.lifecycle_state=''DELETED''';
    IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'V777 cannot extend attachment reset proof safely'; END IF;
    definition:=replace(definition,anchor,'WHERE attachment.lifecycle_state IN (''DELETED'',''RETAINED_HISTORY'')');
    anchor:='AND operation.status=''SUCCEEDED'' AND operation.completed_at IS NOT NULL)';
    IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'V777 cannot match exact attachment completion proof'; END IF;
    definition:=replace(definition,anchor,'AND ((attachment.lifecycle_state=''DELETED'' AND operation.status=''SUCCEEDED'')'
        || ' OR (attachment.lifecycle_state=''RETAINED_HISTORY'' AND operation.status=''RETAINED_HISTORY''))'
        || ' AND operation.completed_at IS NOT NULL)');
    -- An abandoned promoted final object is kept via its permanently preserved upload identity.
    definition:=replace(definition,'operation.status=''SUCCEEDED'' AND operation.completed_at>=session.expires_at))',
        'operation.status IN (''SUCCEEDED'',''RETAINED_HISTORY'') AND operation.completed_at>=session.expires_at))');
    definition:=replace(definition,'operation.status<>''SUCCEEDED'' OR operation.completed_at IS NULL',
        'operation.status NOT IN (''SUCCEEDED'',''RETAINED_HISTORY'') OR operation.completed_at IS NULL');
    EXECUTE definition;
END $retained_reset_proof$;

DO $reset_policy$
DECLARE definition text;
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    definition:=replace(definition,'(''attachments'', ''CLEAR'')','(''attachments'', ''PRESERVE'')');
    definition:=replace(definition,'(''attachment_upload_sessions'', ''CLEAR'')','(''attachment_upload_sessions'', ''PRESERVE'')');
    definition:=replace(definition,'(''attachment_object_outbox'', ''CLEAR'')','(''attachment_object_outbox'', ''PRESERVE'')');
    definition:=replace(definition,'(''attachment_reconciliation_findings'', ''CLEAR'')','(''attachment_reconciliation_findings'', ''PRESERVE'')');
    EXECUTE definition;
END $reset_policy$;

-- V770 already archives without destroying a partition; publish the permanent policy explicitly.
CREATE OR REPLACE FUNCTION fn_audit_retention_purge_mode() RETURNS text
LANGUAGE sql STABLE AS $$ SELECT 'PERMANENT_RETAIN'::text $$;
