-- Read-only inventory. Use an approved read-only database session; no keys,
-- filenames, object locations, credentials or document contents are returned.
-- A zero count is necessary, not sufficient, to retire a directory: paired
-- backup retention and restore requirements must also have been satisfied.
BEGIN TRANSACTION READ ONLY;

WITH retained_refs AS (
    SELECT 'attachments_including_retained_history'::text AS source,storage_provider,storage_key,storage_version
    FROM attachments WHERE storage_key IS NOT NULL
    UNION ALL
    SELECT 'private_documents_including_versions',storage_provider,storage_key,storage_version
    FROM v_private_document_storage_references WHERE storage_key IS NOT NULL
    UNION ALL
    SELECT 'unfinished_object_jobs',storage_provider,storage_key,storage_version
    FROM attachment_object_outbox WHERE status NOT IN ('SUCCEEDED','RETAINED_HISTORY')
)
SELECT source,storage_provider,count(*) AS reference_count,
       count(DISTINCT (storage_key,storage_version)) AS exact_objects,
       count(*) FILTER (WHERE storage_provider='oss' AND storage_version IS NULL) AS unpinned_oss_objects
FROM retained_refs
WHERE storage_provider IN ('local','oss','legacy_unknown') OR storage_provider IS NULL
GROUP BY source,storage_provider ORDER BY source,storage_provider;

COMMIT;
