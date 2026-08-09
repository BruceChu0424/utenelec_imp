-- Pin each confirmed attachment to the exact OSS object version that the server
-- inspected and hashed. With Bucket Versioning enabled, repeated PUTs create new
-- current versions and x-oss-forbid-overwrite is intentionally ineffective; all
-- later download/delete operations must therefore address the confirmed version.

ALTER TABLE attachments
    ADD COLUMN storage_version VARCHAR(255),
    ADD COLUMN storage_etag VARCHAR(255);

COMMENT ON COLUMN attachments.storage_version IS
    'Exact OSS versionId inspected at confirm; null only for local/legacy storage';
COMMENT ON COLUMN attachments.storage_etag IS
    'Object-store ETag captured at confirm for audit/diagnostics; SHA-256 is authoritative';
