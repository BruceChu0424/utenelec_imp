-- Durable, bounded report work. Task identity and request survive artifact expiry.
-- No business fact, original or historical receipt is deleted by this queue.
CREATE TABLE report_export_jobs (
    id uuid PRIMARY KEY,
    submitted_by uuid NOT NULL REFERENCES users(id),
    submitted_auth_version bigint NOT NULL,
    submitted_auth_epoch bigint NOT NULL,
    request jsonb NOT NULL,
    read_contract text NOT NULL,
    build_identity text NOT NULL,
    status text NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','RUNNING','SUCCEEDED','FAILED','CANCELLED','EXPIRED')),
    attempt integer NOT NULL DEFAULT 0 CHECK (attempt >= 0),
    cancel_requested boolean NOT NULL DEFAULT false,
    row_count integer NOT NULL DEFAULT 0 CHECK (row_count >= 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    started_at timestamptz,
    finished_at timestamptz,
    snapshot_at timestamptz,
    snapshot_identity text,
    lease_until timestamptz,
    artifact_bytes bigint,
    artifact_sha256 text,
    expires_at timestamptz,
    error_message text,
    CONSTRAINT report_export_request_size CHECK (octet_length(request::text) <= 65536),
    CONSTRAINT report_export_completed_artifact CHECK
        (status <> 'SUCCEEDED' OR (artifact_bytes > 0 AND length(artifact_sha256)=64 AND expires_at IS NOT NULL))
);
CREATE INDEX report_export_jobs_claim_idx ON report_export_jobs(created_at,id) WHERE status='PENDING';
CREATE INDEX report_export_jobs_user_idx ON report_export_jobs(submitted_by,created_at DESC,id);
CREATE INDEX report_export_jobs_lease_idx ON report_export_jobs(lease_until) WHERE status='RUNNING';
CREATE INDEX report_export_jobs_expiry_idx ON report_export_jobs(expires_at) WHERE status='SUCCEEDED';
SELECT fn_audit_track_table('report_export_jobs','COLUMN_SCOPED','data_change',false,
    ARRAY['status','snapshot_at','snapshot_identity','finished_at','artifact_sha256','error_message'],true);

CREATE FUNCTION fn_guard_report_export_identity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'Export task identities and requests are retained' USING ERRCODE='23514';
    END IF;
    IF OLD.id IS DISTINCT FROM NEW.id OR OLD.submitted_by IS DISTINCT FROM NEW.submitted_by
       OR OLD.submitted_auth_version IS DISTINCT FROM NEW.submitted_auth_version
       OR OLD.submitted_auth_epoch IS DISTINCT FROM NEW.submitted_auth_epoch
       OR OLD.read_contract IS DISTINCT FROM NEW.read_contract OR OLD.build_identity IS DISTINCT FROM NEW.build_identity
       OR OLD.request IS DISTINCT FROM NEW.request OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
        RAISE EXCEPTION 'Export task identity and request are immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_report_export_identity BEFORE UPDATE OR DELETE ON report_export_jobs
    FOR EACH ROW EXECUTE FUNCTION fn_guard_report_export_identity();
ALTER TABLE report_export_jobs ENABLE ALWAYS TRIGGER trg_guard_report_export_identity;
CREATE TRIGGER trg_report_export_jobs_no_truncate BEFORE TRUNCATE ON report_export_jobs
    FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
ALTER TABLE report_export_jobs ENABLE ALWAYS TRIGGER trg_report_export_jobs_no_truncate;
COMMENT ON TABLE report_export_jobs IS 'Permanent export request identities; XLSX files are expiring reproducible copies';
