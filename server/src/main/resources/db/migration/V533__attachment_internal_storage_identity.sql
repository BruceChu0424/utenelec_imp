-- Keep original file identity independent of the physical storage representation.
-- Before V533 only OSS supplied object versions; unversioned history is ambiguous
-- (including old OSS objects) and must never be guessed from the current provider.
ALTER TABLE attachments
    ADD COLUMN storage_provider VARCHAR(24) NOT NULL DEFAULT 'legacy_unknown',
    ADD COLUMN stored_size_bytes BIGINT,
    ADD COLUMN storage_encoding VARCHAR(16);
ALTER TABLE attachment_upload_sessions
    ADD COLUMN storage_provider VARCHAR(24) NOT NULL DEFAULT 'legacy_unknown',
    ADD COLUMN final_stored_size_bytes BIGINT,
    ADD COLUMN final_storage_encoding VARCHAR(16);
ALTER TABLE attachment_object_outbox
    ADD COLUMN storage_provider VARCHAR(24) NOT NULL DEFAULT 'legacy_unknown';
ALTER TABLE attachment_reconciliation_findings
    ADD COLUMN storage_provider VARCHAR(24) NOT NULL DEFAULT 'legacy_unknown';

UPDATE attachments
SET storage_provider = 'oss', stored_size_bytes = size_bytes, storage_encoding = 'IDENTITY'
WHERE NULLIF(btrim(storage_version), '') IS NOT NULL;
UPDATE attachment_upload_sessions
SET storage_provider = 'oss',
    final_stored_size_bytes = CASE WHEN NULLIF(btrim(final_version), '') IS NOT NULL
                                  THEN expected_size_bytes END,
    final_storage_encoding = CASE WHEN NULLIF(btrim(final_version), '') IS NOT NULL
                                  THEN 'IDENTITY' END
WHERE NULLIF(btrim(final_version), '') IS NOT NULL
   OR NULLIF(btrim(staging_version), '') IS NOT NULL;
UPDATE attachment_upload_sessions session
SET storage_provider = attachment.storage_provider
FROM attachments attachment
WHERE session.storage_key = attachment.storage_key
  AND session.storage_provider = 'legacy_unknown'
  AND attachment.storage_provider <> 'legacy_unknown';
UPDATE attachment_object_outbox
SET storage_provider = 'oss'
WHERE NULLIF(btrim(storage_version), '') IS NOT NULL;
UPDATE attachment_object_outbox operation
SET storage_provider = attachment.storage_provider
FROM attachments attachment
WHERE operation.attachment_id = attachment.id
  AND operation.storage_key = attachment.storage_key
  AND operation.storage_provider = 'legacy_unknown'
  AND attachment.storage_provider <> 'legacy_unknown';
UPDATE attachment_object_outbox operation
SET storage_provider = session.storage_provider
FROM attachment_upload_sessions session
WHERE operation.upload_session_id = session.id
  AND operation.storage_key = session.storage_key
  AND operation.storage_provider = 'legacy_unknown'
  AND session.storage_provider <> 'legacy_unknown';
UPDATE attachment_reconciliation_findings
SET storage_provider = 'oss'
WHERE NULLIF(btrim(storage_version), '') IS NOT NULL;

-- Existing dedupe keys remain identifiable; new commands use the same prefix.
UPDATE attachment_object_outbox
SET dedupe_key = storage_provider || '|' || dedupe_key;
DROP INDEX attachment_reconciliation_object_uq;
CREATE UNIQUE INDEX attachment_reconciliation_object_uq
    ON attachment_reconciliation_findings
       (storage_provider, object_location, storage_key, COALESCE(storage_version, ''));

ALTER TABLE attachments
    ADD CONSTRAINT attachments_storage_provider_chk
        CHECK (storage_provider IN ('internal', 'oss', 'local', 'legacy_unknown')),
    ADD CONSTRAINT attachments_storage_representation_chk CHECK (
        (stored_size_bytes IS NULL AND storage_encoding IS NULL)
        OR (stored_size_bytes IS NOT NULL AND storage_encoding IS NOT NULL
            AND stored_size_bytes > 0 AND storage_encoding IN ('IDENTITY', 'GZIP')
            AND (storage_provider = 'internal' OR storage_encoding <> 'IDENTITY'
                 OR stored_size_bytes = size_bytes))),
    ADD CONSTRAINT attachments_internal_identity_chk CHECK (
        storage_provider <> 'internal' OR lifecycle_state <> 'CLEAN'
        OR (NULLIF(btrim(storage_version), '') IS NOT NULL
            AND sha256 IS NOT NULL AND sha256 ~ '^[0-9a-f]{64}$'
            AND stored_size_bytes IS NOT NULL AND storage_encoding IS NOT NULL));
ALTER TABLE attachment_upload_sessions
    ADD CONSTRAINT attachment_upload_sessions_provider_chk
        CHECK (storage_provider IN ('internal', 'oss', 'local', 'legacy_unknown')),
    ADD CONSTRAINT attachment_upload_sessions_representation_chk CHECK (
        (final_stored_size_bytes IS NULL AND final_storage_encoding IS NULL)
        OR (final_stored_size_bytes IS NOT NULL AND final_storage_encoding IS NOT NULL
            AND final_stored_size_bytes > 0 AND final_storage_encoding IN ('IDENTITY', 'GZIP')
            AND (storage_provider = 'internal' OR final_storage_encoding <> 'IDENTITY'
                 OR final_stored_size_bytes = expected_size_bytes))),
    ADD CONSTRAINT attachment_upload_sessions_internal_identity_chk CHECK (
        storage_provider <> 'internal' OR status <> 'PROMOTED'
        OR (NULLIF(btrim(final_version), '') IS NOT NULL
            AND sha256 IS NOT NULL AND sha256 ~ '^[0-9a-f]{64}$'
            AND final_stored_size_bytes IS NOT NULL AND final_storage_encoding IS NOT NULL));
ALTER TABLE attachment_object_outbox
    ADD CONSTRAINT attachment_object_outbox_provider_chk
        CHECK (storage_provider IN ('internal', 'oss', 'local', 'legacy_unknown'));
ALTER TABLE attachment_reconciliation_findings
    ADD CONSTRAINT attachment_reconciliation_provider_chk
        CHECK (storage_provider IN ('internal', 'oss', 'local', 'legacy_unknown'));

-- Provider must be written explicitly for every new object/command. The migration
-- defaults only classify historical rows; omission is not an accepted new route.
ALTER TABLE attachments ALTER COLUMN storage_provider DROP DEFAULT;
ALTER TABLE attachment_upload_sessions ALTER COLUMN storage_provider DROP DEFAULT;
ALTER TABLE attachment_object_outbox ALTER COLUMN storage_provider DROP DEFAULT;
ALTER TABLE attachment_reconciliation_findings ALTER COLUMN storage_provider DROP DEFAULT;

CREATE FUNCTION fn_guard_attachment_storage_identity() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME = 'attachments' THEN
        IF OLD.lifecycle_state <> 'LEGACY_UNVERIFIED' AND (
            NEW.lifecycle_state = 'LEGACY_UNVERIFIED' OR
            ROW(NEW.owner_type, NEW.owner_id, NEW.storage_key, NEW.storage_version,
                NEW.original_name, NEW.content_type, NEW.size_bytes, NEW.sha256,
                NEW.created_by, NEW.created_at, NEW.storage_etag,
                NEW.scan_engine, NEW.scan_signature, NEW.scanned_at, NEW.promoted_at)
            IS DISTINCT FROM
            ROW(OLD.owner_type, OLD.owner_id, OLD.storage_key, OLD.storage_version,
                OLD.original_name, OLD.content_type, OLD.size_bytes, OLD.sha256,
                OLD.created_by, OLD.created_at, OLD.storage_etag,
                OLD.scan_engine, OLD.scan_signature, OLD.scanned_at, OLD.promoted_at)
            OR (OLD.storage_provider <> 'legacy_unknown' AND
                ROW(NEW.storage_provider, NEW.stored_size_bytes, NEW.storage_encoding)
                IS DISTINCT FROM
                ROW(OLD.storage_provider, OLD.stored_size_bytes, OLD.storage_encoding))) THEN
            RAISE EXCEPTION 'Confirmed attachment content and storage identity are immutable'
                USING ERRCODE = '23514', CONSTRAINT = 'attachments_storage_identity_immutable';
        END IF;
    ELSE
        IF OLD.storage_provider <> 'legacy_unknown'
           AND NEW.storage_provider IS DISTINCT FROM OLD.storage_provider THEN
            RAISE EXCEPTION 'Reserved attachment storage provider is immutable'
                USING ERRCODE = '23514', CONSTRAINT = 'attachment_session_provider_immutable';
        END IF;
        IF OLD.status = 'PROMOTED' AND (
            NEW.status <> 'PROMOTED' OR
            ROW(NEW.storage_key, NEW.owner_type, NEW.owner_id, NEW.user_id,
                NEW.expected_size_bytes, NEW.sha256, NEW.final_version, NEW.final_etag,
                NEW.original_name, NEW.content_type, NEW.staging_version, NEW.staging_etag,
                NEW.scan_engine, NEW.scan_signature, NEW.completed_at)
            IS DISTINCT FROM
            ROW(OLD.storage_key, OLD.owner_type, OLD.owner_id, OLD.user_id,
                OLD.expected_size_bytes, OLD.sha256, OLD.final_version, OLD.final_etag,
                OLD.original_name, OLD.content_type, OLD.staging_version, OLD.staging_etag,
                OLD.scan_engine, OLD.scan_signature, OLD.completed_at)
            OR (OLD.storage_provider <> 'legacy_unknown' AND
                ROW(NEW.storage_provider, NEW.final_stored_size_bytes, NEW.final_storage_encoding)
                IS DISTINCT FROM
                ROW(OLD.storage_provider, OLD.final_stored_size_bytes, OLD.final_storage_encoding))) THEN
            RAISE EXCEPTION 'Promoted attachment session identity is immutable'
                USING ERRCODE = '23514', CONSTRAINT = 'attachment_session_identity_immutable';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_attachment_storage_identity
    BEFORE UPDATE ON attachments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_attachment_storage_identity();
CREATE TRIGGER trg_attachment_session_storage_identity
    BEFORE UPDATE ON attachment_upload_sessions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_attachment_storage_identity();

COMMENT ON COLUMN attachments.size_bytes IS 'Original uncompressed bytes; unchanged by physical compression';
COMMENT ON COLUMN attachments.sha256 IS 'SHA-256 of the original scanned bytes, never compressed representation';
COMMENT ON COLUMN attachments.stored_size_bytes IS 'Physical object bytes including its storage envelope; NULL means unresolved historical representation';
COMMENT ON COLUMN attachments.storage_provider IS 'Pinned object backend; legacy_unknown requires explicit verified reconciliation';
COMMENT ON COLUMN attachments.storage_encoding IS 'Lossless physical representation; download returns original bytes';
