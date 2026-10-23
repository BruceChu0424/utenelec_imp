-- Shared by compose_bootstrap for the owner mappers only. Current ownership
-- and historical actors have different semantics; never rewrite actor fields.
CREATE TEMP TABLE legacy_owner_custody (
 target_table text NOT NULL,target_id uuid NOT NULL,target_legacy_id int,
 source_reference text NOT NULL,original_employee_id uuid,assigned_employee_id uuid NOT NULL,
 reason text NOT NULL,PRIMARY KEY(target_table,target_id)) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.legacy_custodian_employee()
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE ids uuid[];
BEGIN
 SELECT array_agg(e.id ORDER BY e.id) INTO ids
 FROM employees e JOIN users u ON u.employee_id=e.id
 WHERE e.code='ADMIN' AND e.status='active' AND NOT e.is_deleted
 AND u.login_account='17665410007' AND u.is_super_admin AND u.status='active' AND NOT u.is_deleted;
 IF cardinality(ids) IS DISTINCT FROM 1 THEN
  RAISE EXCEPTION 'Legacy ownership custody requires the unique preserved active super-administrator';
 END IF;
 RETURN ids[1];
END $$;

CREATE OR REPLACE FUNCTION pg_temp.legacy_owner_resolution(source_reference text)
RETURNS TABLE(owner_id uuid,original_employee_id uuid,reason text)
LANGUAGE plpgsql AS $$
DECLARE source_value text:=btrim(source_reference); source_id bigint; matches uuid[]; old_status text; old_deleted boolean;
BEGIN
 IF source_value IS NULL OR source_value='' OR source_value ~ '^0+$' THEN
  owner_id:=NULL;original_employee_id:=NULL;reason:='PUBLIC_SOURCE';RETURN NEXT;RETURN;
 END IF;
 IF source_value ~ '^[0-9]{1,10}$' THEN source_id:=source_value::bigint; END IF;
 IF source_id IS NOT NULL AND source_id BETWEEN 1 AND 2147483647 THEN
  SELECT array_agg(e.id ORDER BY e.id) INTO matches FROM employees e WHERE e.legacy_id=source_id;
  IF cardinality(matches)=1 THEN
   original_employee_id:=matches[1];
   SELECT e.status,e.is_deleted INTO old_status,old_deleted FROM employees e WHERE e.id=original_employee_id;
   IF old_deleted=FALSE AND old_status IN ('active','probation','onLeave') THEN
    owner_id:=original_employee_id;reason:='CURRENT_EMPLOYEE';RETURN NEXT;RETURN;
   END IF;
   reason:=CASE WHEN old_deleted THEN 'SOURCE_EMPLOYEE_DELETED' ELSE 'SOURCE_EMPLOYEE_NOT_CURRENT' END;
  ELSE
   reason:=CASE WHEN COALESCE(cardinality(matches),0)=0 THEN 'SOURCE_EMPLOYEE_MISSING' ELSE 'SOURCE_EMPLOYEE_AMBIGUOUS' END;
  END IF;
 ELSE
  reason:='UNRESOLVED_SOURCE_REFERENCE';
 END IF;
 owner_id:=pg_temp.legacy_custodian_employee();RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.flush_legacy_owner_custody(module_name text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE claim_id uuid;claim_ids uuid[];entries jsonb;previous_entries jsonb;entry_count bigint;
BEGIN
 SELECT count(*),COALESCE(jsonb_agg(to_jsonb(c) ORDER BY target_table,target_legacy_id,target_id),'[]'::jsonb)
 INTO entry_count,entries FROM pg_temp.legacy_owner_custody c;
 claim_id:=NULLIF(current_setting('uten.bootstrap_run_id',true),'')::uuid;
 IF claim_id IS NULL THEN
  SELECT array_agg(run_id ORDER BY started_at) INTO claim_ids FROM legacy_migration_runs
  WHERE status='RUNNING' AND reconciliation_summary->>'targetDatabase'=current_database();
  IF cardinality(claim_ids)=1 THEN claim_id:=claim_ids[1]; END IF;
 END IF;
 IF claim_id IS NULL THEN RAISE EXCEPTION 'Legacy ownership custody requires its current import claim'; END IF;
 SELECT reconciliation_summary #> ARRAY['currentOwnerCustody',module_name,'entries'] INTO previous_entries
 FROM legacy_migration_runs WHERE run_id=claim_id AND status='RUNNING';
 SELECT COALESCE(jsonb_agg(merged.entry ORDER BY merged.entry->>'target_table',merged.entry->>'target_id'),'[]'::jsonb)
 INTO entries FROM (
  SELECT DISTINCT ON (entry->>'target_table',entry->>'target_id') entry
  FROM (SELECT value AS entry,0 AS priority FROM jsonb_array_elements(COALESCE(previous_entries,'[]'::jsonb))
        UNION ALL SELECT value,1 FROM jsonb_array_elements(entries)) candidates
  ORDER BY entry->>'target_table',entry->>'target_id',priority DESC
 ) merged;
 entry_count:=jsonb_array_length(entries);
 UPDATE legacy_migration_runs SET reconciliation_summary=reconciliation_summary || jsonb_build_object(
  'currentOwnerCustody',COALESCE(reconciliation_summary->'currentOwnerCustody','{}'::jsonb) || jsonb_build_object(
   module_name,jsonb_build_object('helperSha256',current_setting('uten.legacy_custody_helper_sha'),
    'pendingHandoverCount',entry_count,'entries',entries)))
 WHERE run_id=claim_id AND status='RUNNING' AND reconciliation_summary->>'targetDatabase'=current_database();
 IF NOT FOUND THEN RAISE EXCEPTION 'Legacy ownership custody import claim is not running in this database'; END IF;
 RETURN entry_count;
END $$;
