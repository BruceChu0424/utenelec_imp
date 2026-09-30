-- V747 is already applied with checksum 910583300. Keep its original bytes immutable.
-- Install the later candidate cleanup as a forward migration for both fresh and existing databases.
-- Business-data reset uses TRUNCATE, which does not fire row DELETE triggers.
-- Template versions are preserved; release only staging candidates not adopted by such a version.
CREATE FUNCTION fn_sales_quote_template_candidates_truncate() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key)
    SELECT 'DELETE_FINAL',c.storage_provider,c.storage_key,c.storage_version,
        c.storage_provider || '|DELETE_FINAL|' || c.storage_key || '|' || COALESCE(c.storage_version,'<local>')
    FROM sales_quote_template_candidates c
    WHERE c.storage_provider IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM sales_quote_template_versions v WHERE v.storage_provider=c.storage_provider
            AND v.storage_key=c.storage_key AND v.storage_version IS NOT DISTINCT FROM c.storage_version)
    ON CONFLICT(dedupe_key) DO NOTHING;
    RETURN NULL;
END;
$function$;
CREATE TRIGGER trg_quote_template_candidates_truncate BEFORE TRUNCATE ON sales_quote_template_candidates
FOR EACH STATEMENT EXECUTE FUNCTION fn_sales_quote_template_candidates_truncate();
