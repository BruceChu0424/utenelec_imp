-- The same database key is held both while claiming and while importing.
-- A container-local filesystem lock alone cannot serialize different helpers.
DO $$ BEGIN
    IF NOT pg_try_advisory_xact_lock(hashtextextended('uten:legacy-bootstrap:' || current_database(), 0)) THEN
        RAISE EXCEPTION USING ERRCODE='UT703', MESSAGE='another legacy importer holds this database';
    END IF;
    IF EXISTS (SELECT 1 FROM legacy_migration_runs WHERE status='RUNNING') THEN
        RAISE EXCEPTION USING ERRCODE='UT704', MESSAGE='an unresolved legacy import claim already owns this database';
    END IF;
END; $$;
