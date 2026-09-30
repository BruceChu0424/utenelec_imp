-- V745 is immutable. Retain its bytea payloads for compatibility; new sanitized workbooks live in
-- the private immutable object store (ADR-074), pinned by provider/key/version/size/SHA-256.
ALTER TABLE sales_quote_template_candidates
    ALTER COLUMN workbook_bytes DROP NOT NULL,
    ADD COLUMN storage_provider varchar(24),
    ADD COLUMN storage_key varchar(255),
    ADD COLUMN storage_version varchar(255),
    ADD COLUMN storage_size bigint,
    ADD COLUMN storage_sha256 varchar(64),
    ADD CONSTRAINT sales_quote_candidate_payload_chk CHECK (
        (workbook_bytes IS NOT NULL AND storage_provider IS NULL AND storage_key IS NULL
            AND storage_version IS NULL AND storage_size IS NULL AND storage_sha256 IS NULL)
        OR (workbook_bytes IS NULL AND storage_provider IN ('internal','local') AND storage_provider IS NOT NULL
            AND storage_key IS NOT NULL AND storage_key ~ '^[A-Za-z0-9._-]+$'
            AND storage_size IS NOT NULL AND storage_size BETWEEN 1 AND 15728640
            AND storage_sha256 IS NOT NULL AND storage_sha256 ~ '^[0-9a-f]{64}$'
            AND (storage_provider <> 'internal' OR storage_version IS NOT NULL)));
ALTER TABLE sales_quote_template_versions
    ALTER COLUMN workbook_bytes DROP NOT NULL,
    ADD COLUMN storage_provider varchar(24),
    ADD COLUMN storage_key varchar(255),
    ADD COLUMN storage_version varchar(255),
    ADD COLUMN storage_size bigint,
    ADD COLUMN storage_sha256 varchar(64),
    ADD CONSTRAINT sales_quote_version_payload_chk CHECK (
        (workbook_bytes IS NOT NULL AND storage_provider IS NULL AND storage_key IS NULL
            AND storage_version IS NULL AND storage_size IS NULL AND storage_sha256 IS NULL)
        OR (workbook_bytes IS NULL AND storage_provider IN ('internal','local') AND storage_provider IS NOT NULL
            AND storage_key IS NOT NULL AND storage_key ~ '^[A-Za-z0-9._-]+$'
            AND storage_size IS NOT NULL AND storage_size BETWEEN 1 AND 15728640
            AND storage_sha256 IS NOT NULL AND storage_sha256 ~ '^[0-9a-f]{64}$'
            AND payload_sha256=storage_sha256
            AND (storage_provider <> 'internal' OR storage_version IS NOT NULL)));
CREATE INDEX idx_quote_template_candidate_object ON sales_quote_template_candidates(storage_provider,storage_key,storage_version)
    WHERE storage_provider IS NOT NULL;
CREATE INDEX idx_quote_template_version_object ON sales_quote_template_versions(storage_provider,storage_key,storage_version)
    WHERE storage_provider IS NOT NULL;

CREATE VIEW v_sales_quote_template_storage_references AS
SELECT storage_provider,storage_key,storage_version FROM sales_quote_template_candidates WHERE storage_provider IS NOT NULL
UNION
SELECT storage_provider,storage_key,storage_version FROM sales_quote_template_versions WHERE storage_provider IS NOT NULL;
COMMENT ON VIEW v_sales_quote_template_storage_references IS
    'Private generated workbook references consumed by the shared exact-object orphan reconciliation; no workbook contents';

CREATE FUNCTION fn_sales_quote_template_release_object() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF OLD.storage_provider IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM v_sales_quote_template_storage_references ref
        WHERE ref.storage_provider=OLD.storage_provider AND ref.storage_key=OLD.storage_key
          AND ref.storage_version IS NOT DISTINCT FROM OLD.storage_version
    ) THEN
        INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key)
        VALUES ('DELETE_FINAL',OLD.storage_provider,OLD.storage_key,OLD.storage_version,
            OLD.storage_provider || '|DELETE_FINAL|' || OLD.storage_key || '|' || COALESCE(OLD.storage_version,'<local>'))
        ON CONFLICT(dedupe_key) DO NOTHING;
    END IF;
    RETURN NULL;
END;
$function$;
CREATE TRIGGER trg_quote_template_candidate_release
AFTER DELETE ON sales_quote_template_candidates FOR EACH ROW EXECUTE FUNCTION fn_sales_quote_template_release_object();
CREATE TRIGGER trg_quote_template_candidate_release_upd
AFTER UPDATE OF storage_provider,storage_key,storage_version ON sales_quote_template_candidates
FOR EACH ROW WHEN ((OLD.storage_provider,OLD.storage_key,OLD.storage_version)
    IS DISTINCT FROM (NEW.storage_provider,NEW.storage_key,NEW.storage_version))
EXECUTE FUNCTION fn_sales_quote_template_release_object();
CREATE TRIGGER trg_quote_template_version_release
AFTER DELETE ON sales_quote_template_versions FOR EACH ROW EXECUTE FUNCTION fn_sales_quote_template_release_object();

CREATE FUNCTION fn_sales_quote_template_version_immutable() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    RAISE EXCEPTION '已保存的客户报价模板版本不可覆盖，请新增版本' USING ERRCODE='23514';
END;
$function$;
CREATE TRIGGER trg_quote_template_version_immutable BEFORE UPDATE ON sales_quote_template_versions
FOR EACH ROW EXECUTE FUNCTION fn_sales_quote_template_version_immutable();
ALTER TABLE sales_quote_template_versions ENABLE ALWAYS TRIGGER trg_quote_template_version_immutable;
COMMENT ON COLUMN sales_quote_template_versions.workbook_bytes IS
    'Read-only compatibility for V745 payloads; new presentation versions use private immutable storage objects';
COMMENT ON COLUMN sales_quote_template_candidates.storage_sha256 IS
    'Server-computed sanitized workbook digest, verified on every template read; never a digest trusted from a request';
