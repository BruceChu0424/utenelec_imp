-- Runs after BEGIN and before any business DML on the same actual connection.
DO $$ BEGIN
    IF NOT pg_try_advisory_xact_lock(hashtextextended('uten:legacy-bootstrap:' || current_database(), 0)) THEN
        RAISE EXCEPTION USING ERRCODE='UT703', MESSAGE='another legacy importer holds this database';
    END IF;
    PERFORM 1 FROM legacy_migration_runs run
        WHERE run.run_id=current_setting('uten.bootstrap_run_id')::uuid
          AND run.status='RUNNING' AND run.target='--bootstrap-all' AND run.migration_mode='BOOTSTRAP'
          AND run.mapping_version=current_setting('uten.bootstrap_mapping_version')
          AND run.migration_repository_commit=current_setting('uten.bootstrap_repository_commit')
          AND run.export_manifest_sha256=current_setting('uten.bootstrap_manifest_sha')
          AND run.reconciliation_summary->>'targetDatabase'=current_database()
          AND run.reconciliation_summary->>'targetSystemIdentifier'=(SELECT system_identifier::text FROM pg_control_system())
          AND run.reconciliation_summary->>'importAtomicity'='single-transaction-v1'
        FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE='UT705', MESSAGE='this transaction does not own the reviewed bootstrap claim';
    END IF;
END; $$;
