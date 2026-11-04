-- A known-unwritten read-only export may explicitly replace only the rejected
-- calculation key. No completed/unknown/cancelled artifact can be regenerated.
CREATE OR REPLACE FUNCTION fn_guard_report_export_precision() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE required_key text;entry record;receipt record;
BEGIN
 IF NEW.precision_choices IS NOT DISTINCT FROM OLD.precision_choices THEN RETURN NEW;END IF;
 IF OLD.status<>'WAITING_PRECISION' OR NEW.status<>'PENDING' OR OLD.cancel_requested OR NEW.cancel_requested
   OR OLD.artifact_sha256 IS NOT NULL OR coalesce(OLD.artifact_bytes,0)<>0
   OR NEW.artifact_sha256 IS NOT NULL OR coalesce(NEW.artifact_bytes,0)<>0
   OR OLD.expires_at IS NULL OR OLD.expires_at<=clock_timestamp()
   OR OLD.precision_requirement->>'notWritten' IS DISTINCT FROM 'true'
   OR (to_jsonb(NEW)-ARRAY['status','precision_choices','precision_requirement','row_count','snapshot_at','snapshot_identity','finished_at','expires_at','error_message'])
     IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','precision_choices','precision_requirement','row_count','snapshot_at','snapshot_identity','finished_at','expires_at','error_message']) THEN
  RAISE EXCEPTION '原导出不在可明确重新选择的未生成状态' USING ERRCODE='23514';END IF;
 required_key:=OLD.precision_requirement->>'calculationKey';
 IF required_key IS NULL OR length(required_key)=0 THEN RAISE EXCEPTION '原导出缺少待核计算用途' USING ERRCODE='23514';END IF;
 SELECT * INTO receipt FROM report_export_precision_resumes r WHERE r.job_id=OLD.id
  AND r.expected_attempt=OLD.attempt AND r.precision_choices=NEW.precision_choices
  AND r.actor_id=OLD.submitted_by;
 IF NOT FOUND THEN RAISE EXCEPTION '原导出精度只能经本任务原主体明确的续处理记录更新' USING ERRCODE='23514';END IF;
 FOR entry IN SELECT * FROM jsonb_each(OLD.precision_choices->'choices') LOOP
  IF (NEW.precision_choices->'choices'->entry.key) IS DISTINCT FROM entry.value
    AND NOT(entry.key=required_key AND OLD.precision_requirement->>'selectionRejected'='true') THEN
   RAISE EXCEPTION '只有本次明确被拒绝的计算可重新选择，其他原精度保留' USING ERRCODE='23514';END IF;
 END LOOP;
 IF (NEW.precision_choices->'choices'->required_key) IS NULL THEN RAISE EXCEPTION '缺少本次明确精度选择' USING ERRCODE='23514';END IF;
 RETURN NEW;
END $$;
