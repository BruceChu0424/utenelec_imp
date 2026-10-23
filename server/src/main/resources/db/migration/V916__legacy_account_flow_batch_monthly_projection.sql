-- Historical signed cash snapshots are authoritative V626 source facts.
-- V408 monthly CHECKs constrain the final projection, not an individual delta.
-- The first proven source INSERT schedules one physical-origin-bound deferred
-- completion check; no session setting can declare the projection complete.
ALTER TABLE public.legacy_migration_runs
 ADD COLUMN legacy_account_flow_import_txid bigint,
 ADD COLUMN legacy_account_flow_origin_system_identifier text,
 ADD COLUMN legacy_account_flow_origin_database_oid oid,
 ADD CONSTRAINT legacy_account_flow_import_origin_complete CHECK (
  (legacy_account_flow_import_txid IS NULL AND legacy_account_flow_origin_system_identifier IS NULL
   AND legacy_account_flow_origin_database_oid IS NULL)
  OR (legacy_account_flow_import_txid IS NOT NULL AND legacy_account_flow_import_txid>0
   AND legacy_account_flow_origin_system_identifier IS NOT NULL
   AND legacy_account_flow_origin_system_identifier ~ '^[0-9]+$'
   AND legacy_account_flow_origin_database_oid IS NOT NULL));

COMMENT ON COLUMN public.legacy_migration_runs.legacy_account_flow_import_txid IS
 'Read-only first ACCOUNT_FLOW source transaction, bound to cluster and physical database; not a done/approval flag. Deferred native integrity is mandatory.';

CREATE FUNCTION public.fn_legacy_account_flow_batch_bound_fields() RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT array_agg(field ORDER BY field) FROM unnest(ARRAY[
  'account_currency_id','account_id','amount_local','bill_date','bill_no','check_no','counterpart_name',
  'entry_kind','id','in_amount','legacy_bstyle','legacy_id','legacy_import_run_id','out_amount',
  'remark','settled_date','source_doc_id','source_doc_type','source_remark']) field
$$;

CREATE FUNCTION public.fn_guard_legacy_account_flow_run_origin() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE mapping text;
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.legacy_account_flow_import_txid IS NOT NULL OR NEW.legacy_account_flow_origin_system_identifier IS NOT NULL
   OR NEW.legacy_account_flow_origin_database_oid IS NOT NULL THEN
   RAISE EXCEPTION 'account-flow origin must be issued by a proven first source INSERT' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
 END IF;
 IF (NEW.legacy_account_flow_import_txid,NEW.legacy_account_flow_origin_system_identifier,NEW.legacy_account_flow_origin_database_oid)
   IS NOT DISTINCT FROM
   (OLD.legacy_account_flow_import_txid,OLD.legacy_account_flow_origin_system_identifier,OLD.legacy_account_flow_origin_database_oid) THEN
  IF OLD.legacy_account_flow_import_txid=txid_current()
   AND OLD.legacy_account_flow_origin_system_identifier=(SELECT system_identifier::text FROM pg_control_system())
   AND OLD.legacy_account_flow_origin_database_oid=(SELECT oid FROM pg_database WHERE datname=current_database())
   AND OLD.status='SUCCESS' AND OLD.reconciliation_status='PASSED'
   AND (NEW.status IS DISTINCT FROM OLD.status OR NEW.reconciliation_status IS DISTINCT FROM OLD.reconciliation_status) THEN
   RAISE EXCEPTION 'finished source transaction cannot downgrade its completion state' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
 END IF;
 IF OLD.legacy_account_flow_import_txid IS NOT NULL THEN
  RAISE EXCEPTION 'account-flow first source origin is immutable' USING ERRCODE='55000';
 END IF;
 PERFORM public.fn_require_legacy_bootstrap(NEW.run_id,'m_allcheck.csv');
 mapping:=NEW.mapping_version;
 IF mapping !~ '^bootstrap-v[1-9][0-9]*$' OR substring(mapping FROM 12)::integer<19
  OR NEW.legacy_account_flow_import_txid IS DISTINCT FROM txid_current()
  OR NEW.legacy_account_flow_origin_system_identifier IS DISTINCT FROM (SELECT system_identifier::text FROM pg_control_system())
  OR NEW.legacy_account_flow_origin_database_oid IS DISTINCT FROM (SELECT oid FROM pg_database WHERE datname=current_database())
  OR NOT EXISTS(SELECT 1 FROM public.legacy_finance_import_sources proof
    JOIN public.finance_reconciliations flow ON flow.id=proof.target_id AND flow.legacy_import_run_id=proof.run_id
      AND flow.legacy_id=proof.source_legacy_id AND flow.entry_kind='LEGACY_SNAPSHOT'
    WHERE proof.run_id=NEW.run_id AND proof.source_kind='ACCOUNT_FLOW' AND proof.target_table='finance_reconciliations'
      AND proof.source_file='m_allcheck.csv' AND proof.issued_txid=txid_current()) THEN
  RAISE EXCEPTION 'account-flow origin lacks its actual same-transaction source target' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_legacy_account_flow_run_origin BEFORE INSERT OR UPDATE ON public.legacy_migration_runs
 FOR EACH ROW EXECUTE FUNCTION public.fn_guard_legacy_account_flow_run_origin();
ALTER TABLE public.legacy_migration_runs ENABLE ALWAYS TRIGGER trg_guard_legacy_account_flow_run_origin;

CREATE FUNCTION public.fn_finish_legacy_account_flow_monthly_projection() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE run public.legacy_migration_runs%ROWTYPE; lock_key bigint; snapshot_at jsonb;
BEGIN
 SELECT * INTO STRICT run FROM public.legacy_migration_runs WHERE run_id=NEW.run_id;
 lock_key:=hashtextextended('uten:legacy-bootstrap:'||current_database(),0);
 snapshot_at:=run.reconciliation_summary->'sourceSnapshotAsOfUtc';
 IF run.legacy_account_flow_import_txid IS DISTINCT FROM txid_current()
  OR run.legacy_account_flow_origin_system_identifier IS DISTINCT FROM (SELECT system_identifier::text FROM pg_control_system())
  OR run.legacy_account_flow_origin_database_oid IS DISTINCT FROM (SELECT oid FROM pg_database WHERE datname=current_database())
  OR run.target IS DISTINCT FROM '--bootstrap-all' OR run.migration_mode IS DISTINCT FROM 'BOOTSTRAP'
  OR run.status IS DISTINCT FROM 'SUCCESS' OR run.reconciliation_status IS DISTINCT FROM 'PASSED'
  OR run.finished_at IS NULL OR run.exit_code IS DISTINCT FROM 0
  OR run.database_user IS DISTINCT FROM current_user
  OR run.mapping_version !~ '^bootstrap-v[1-9][0-9]*$' OR substring(run.mapping_version FROM 12)::integer<19
  OR current_setting('uten.bootstrap_run_id',true) IS DISTINCT FROM run.run_id::text
  OR current_setting('uten.bootstrap_mapping_version',true) IS DISTINCT FROM run.mapping_version
  OR current_setting('uten.bootstrap_repository_commit',true) IS DISTINCT FROM run.migration_repository_commit
  OR current_setting('uten.bootstrap_manifest_sha',true) IS DISTINCT FROM run.export_manifest_sha256::text
  OR snapshot_at IS NULL
  OR NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=session_user AND (rolsuper OR (rolname='uten_migrator' AND rolcanlogin)))
  OR NOT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND pid=pg_backend_pid() AND granted
    AND mode='ExclusiveLock' AND objsubid=1 AND classid=((lock_key>>32)&4294967295)::oid AND objid=(lock_key&4294967295)::oid)
  OR NOT EXISTS(SELECT 1 FROM public.legacy_finance_import_sources proof WHERE proof.run_id=run.run_id
      AND proof.source_kind='ACCOUNT_FLOW' AND proof.issued_txid=txid_current())
  OR EXISTS(SELECT 1 FROM public.legacy_finance_import_sources proof
    LEFT JOIN public.finance_reconciliations flow ON flow.id=proof.target_id AND flow.legacy_import_run_id=proof.run_id
       AND flow.legacy_id=proof.source_legacy_id AND flow.entry_kind='LEGACY_SNAPSHOT'
    LEFT JOIN public.legacy_migration_run_files file ON file.run_id=proof.run_id AND file.file_name=proof.source_file
    WHERE proof.run_id=run.run_id AND proof.source_kind='ACCOUNT_FLOW'
      AND (proof.issued_txid<>txid_current() OR proof.target_table<>'finance_reconciliations'
        OR proof.target_fields IS DISTINCT FROM public.fn_legacy_account_flow_batch_bound_fields()
        OR proof.source_file<>'m_allcheck.csv' OR proof.source_file_sha256 IS DISTINCT FROM file.sha256
        OR proof.initial_state->'sourceSnapshotAsOfUtc' IS DISTINCT FROM snapshot_at
        OR flow.id IS NULL OR proof.target_snapshot_sha256 IS DISTINCT FROM
          encode(public.digest(public.fn_legacy_finance_snapshot(to_jsonb(flow),proof.target_fields)::text,'sha256'),'hex')))
  OR EXISTS(SELECT 1 FROM public.finance_reconciliations flow
    LEFT JOIN public.legacy_finance_import_sources proof ON proof.run_id=flow.legacy_import_run_id AND proof.target_id=flow.id
      AND proof.source_kind='ACCOUNT_FLOW' AND proof.source_legacy_id=flow.legacy_id
    WHERE flow.legacy_import_run_id=run.run_id AND proof.id IS NULL) THEN
  RAISE EXCEPTION 'account-flow bootstrap completion differs from its actual source transaction' USING ERRCODE='23514';
 END IF;
 -- One whole-ledger check at the source transaction boundary, never per flow.
 PERFORM public.fn_assert_account_flow_monthly_integrity(NULL);
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_finish_legacy_account_flow_monthly_projection
 AFTER UPDATE ON public.legacy_migration_runs DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW WHEN(OLD.legacy_account_flow_import_txid IS NULL AND NEW.legacy_account_flow_import_txid IS NOT NULL)
 EXECUTE FUNCTION public.fn_finish_legacy_account_flow_monthly_projection();

CREATE FUNCTION public.fn_guard_finished_legacy_account_flow_monthly_write() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 -- Read only origin metadata with the function owner's authority. Ordinary
 -- runtime posting needs no migration-table or pg_control_system privilege.
 -- Physical origin is mandatory: restored old txid numbers must never freeze
 -- ordinary posting in another cluster/database. Renaming keeps physical OID.
 IF EXISTS(SELECT 1 FROM public.legacy_migration_runs run
    WHERE run.legacy_account_flow_import_txid=txid_current()
      AND run.legacy_account_flow_origin_system_identifier=(SELECT system_identifier::text FROM pg_control_system())
      AND run.legacy_account_flow_origin_database_oid=(SELECT oid FROM pg_database WHERE datname=current_database())
      AND run.status='SUCCESS' AND run.reconciliation_status='PASSED') THEN
  RAISE EXCEPTION 'finished source transaction cannot change its validated monthly projection' USING ERRCODE='23514';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_finished_legacy_account_flow_monthly_write
 BEFORE INSERT OR UPDATE OR DELETE ON public.account_flow_monthly_summaries
 FOR EACH ROW EXECUTE FUNCTION public.fn_guard_finished_legacy_account_flow_monthly_write();
ALTER TABLE public.account_flow_monthly_summaries ENABLE ALWAYS TRIGGER trg_guard_finished_legacy_account_flow_monthly_write;
CREATE TRIGGER trg_guard_finished_legacy_account_flow_monthly_truncate
 BEFORE TRUNCATE ON public.account_flow_monthly_summaries
 FOR EACH STATEMENT EXECUTE FUNCTION public.fn_guard_finished_legacy_account_flow_monthly_write();
ALTER TABLE public.account_flow_monthly_summaries ENABLE ALWAYS TRIGGER trg_guard_finished_legacy_account_flow_monthly_truncate;

-- Preserve the ordinary V408 increment bytes. Only a newly inserted, fully
-- proven V626 source snapshot takes the first-import batch projection branch.
DO $forward$
DECLARE definition text; anchor text:=E'BEGIN\n    PERFORM pg_advisory_xact_lock_shared(';
 replacement text:=E'BEGIN\n    IF TG_OP=''INSERT'' AND NEW.entry_kind=''LEGACY_SNAPSHOT'' THEN\n'
  ||E'        PERFORM public.fn_assert_legacy_finance_import(''finance_reconciliations'',to_jsonb(NEW));\n'
  ||E'        IF NOT EXISTS(SELECT 1 FROM public.legacy_finance_import_sources proof\n'
  ||E'          WHERE proof.run_id=NEW.legacy_import_run_id AND proof.target_id=NEW.id\n'
  ||E'            AND proof.source_legacy_id=NEW.legacy_id AND proof.source_kind=''ACCOUNT_FLOW''\n'
  ||E'            AND proof.source_file=''m_allcheck.csv'' AND proof.target_table=''finance_reconciliations''\n'
  ||E'            AND proof.target_fields=public.fn_legacy_account_flow_batch_bound_fields()\n'
  ||E'            AND proof.issued_txid=txid_current()) THEN\n'
  ||E'          RAISE EXCEPTION ''account-flow monthly batch requires its exact first source proof'' USING ERRCODE=''23514'';\n'
  ||E'        END IF;\n'
  ||E'        UPDATE public.legacy_migration_runs SET legacy_account_flow_import_txid=txid_current(),\n'
  ||E'          legacy_account_flow_origin_system_identifier=(SELECT system_identifier::text FROM pg_control_system()),\n'
  ||E'          legacy_account_flow_origin_database_oid=(SELECT oid FROM pg_database WHERE datname=current_database())\n'
  ||E'        WHERE run_id=NEW.legacy_import_run_id AND legacy_account_flow_import_txid IS NULL;\n'
  ||E'        IF NOT EXISTS(SELECT 1 FROM public.legacy_migration_runs run WHERE run.run_id=NEW.legacy_import_run_id\n'
  ||E'          AND run.legacy_account_flow_import_txid=txid_current()\n'
  ||E'          AND run.legacy_account_flow_origin_system_identifier=(SELECT system_identifier::text FROM pg_control_system())\n'
  ||E'          AND run.legacy_account_flow_origin_database_oid=(SELECT oid FROM pg_database WHERE datname=current_database())) THEN\n'
  ||E'          RAISE EXCEPTION ''account-flow batch origin differs from first source execution'' USING ERRCODE=''23514'';\n'
  ||E'        END IF;\n        RETURN NULL;\n    END IF;\n'
  ||E'    PERFORM pg_advisory_xact_lock_shared(';
BEGIN
 definition:=pg_get_functiondef('public.fn_upsert_account_flow_monthly_summary()'::regprocedure);
 IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
  RAISE EXCEPTION 'V916 native monthly upsert function oracle changed';
 END IF;
 EXECUTE replace(definition,anchor,replacement);
END $forward$;
