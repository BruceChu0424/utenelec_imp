-- The original report request/reader/access identity remains immutable.
ALTER TABLE report_export_jobs DROP CONSTRAINT report_export_jobs_status_check;
ALTER TABLE report_export_jobs ADD CONSTRAINT report_export_jobs_status_check
  CHECK(status IN('PENDING','RUNNING','WAITING_PRECISION','SUCCEEDED','FAILED','CANCELLED','EXPIRED'));
ALTER TABLE report_export_jobs ADD COLUMN precision_choices jsonb NOT NULL DEFAULT '{"version":1,"choices":{}}';
ALTER TABLE report_export_jobs ADD COLUMN precision_requirement jsonb;
ALTER TABLE report_export_jobs ADD CONSTRAINT report_export_precision_snapshot CHECK(
  jsonb_typeof(precision_choices)='object' AND precision_choices->>'version'='1'
  AND jsonb_typeof(precision_choices->'choices')='object' AND octet_length(precision_choices::text)<=16384);
ALTER TABLE report_export_jobs ADD CONSTRAINT report_export_waiting_has_no_artifact CHECK(
  status<>'WAITING_PRECISION' OR (artifact_sha256 IS NULL AND COALESCE(artifact_bytes,0)=0
  AND precision_requirement IS NOT NULL AND precision_requirement->>'notWritten'='true' AND expires_at IS NOT NULL));

CREATE TABLE report_export_precision_resumes(
  request_id uuid PRIMARY KEY,job_id uuid NOT NULL REFERENCES report_export_jobs(id),
  actor_id uuid NOT NULL REFERENCES users(id),expected_attempt integer NOT NULL CHECK(expected_attempt>=1),
  precision_choices jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK(jsonb_typeof(precision_choices)='object' AND octet_length(precision_choices::text)<=16384)
);
CREATE TRIGGER report_export_precision_resumes_immutable BEFORE UPDATE OR DELETE ON report_export_precision_resumes
  FOR EACH ROW EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
CREATE TRIGGER report_export_precision_resumes_no_truncate BEFORE TRUNCATE ON report_export_precision_resumes
  FOR EACH STATEMENT EXECUTE FUNCTION fn_lifecycle_evidence_immutable();
SELECT fn_audit_track_table('report_export_precision_resumes','COLUMN_SCOPED','data_change',false,
  ARRAY['request_id','job_id','actor_id','expected_attempt','created_at'],true);
CREATE INDEX report_export_waiting_expiry_idx ON report_export_jobs(expires_at) WHERE status='WAITING_PRECISION';

CREATE FUNCTION fn_guard_report_export_precision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.precision_choices IS DISTINCT FROM OLD.precision_choices AND
     NOT(OLD.status='WAITING_PRECISION' AND NEW.status='PENDING' AND EXISTS(
       SELECT 1 FROM report_export_precision_resumes r WHERE r.job_id=OLD.id AND r.expected_attempt=OLD.attempt AND r.precision_choices=NEW.precision_choices)) THEN
    RAISE EXCEPTION '原导出精度只能经本任务明确的续处理记录更新' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER report_export_precision_guard BEFORE UPDATE ON report_export_jobs
  FOR EACH ROW EXECUTE FUNCTION fn_guard_report_export_precision();
