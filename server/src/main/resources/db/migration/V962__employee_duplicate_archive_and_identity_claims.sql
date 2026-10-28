-- Keep the original records and all of their business/PII references. Only an
-- explicitly reviewed, account-free duplicate becomes a permanent identity alias.
CREATE FUNCTION fn_archive_verified_employee_duplicate(
    source_id uuid, retained_id uuid, source_version integer, retained_version integer,
    verified_reason text, evidence text, document_conflict_verified boolean DEFAULT false) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE source_row employees%ROWTYPE; retained_row employees%ROWTYPE; reviewed_evidence text;
BEGIN
    IF source_id=retained_id OR source_id IS NULL OR retained_id IS NULL
       OR source_version IS NULL OR retained_version IS NULL OR verified_reason IS NULL OR evidence IS NULL
       OR length(btrim(verified_reason)) NOT BETWEEN 5 AND 1000
       OR length(btrim(evidence)) NOT BETWEEN 1 AND 1000
       OR NULLIF(current_setting('app.actor_id',true),'') IS NULL THEN
        RAISE EXCEPTION 'Duplicate archive requires an actor, two identities and explicit verification evidence' USING ERRCODE='23514';
    END IF;
    reviewed_evidence := evidence||CASE WHEN document_conflict_verified THEN '#document-conflict-verified' ELSE '' END;
    IF length(reviewed_evidence)>1000 THEN RAISE EXCEPTION 'Verification evidence is too long' USING ERRCODE='23514'; END IF;
    -- This is the same order used by the maintenance alias guard and account creation.
    PERFORM pg_advisory_xact_lock(1431586126,937);
    PERFORM id FROM employees WHERE id IN(source_id,retained_id) ORDER BY id FOR UPDATE;
    SELECT * INTO source_row FROM employees WHERE id=source_id;
    SELECT * INTO retained_row FROM employees WHERE id=retained_id;
    IF source_row.id IS NULL OR retained_row.id IS NULL OR source_row.is_deleted OR retained_row.is_deleted
       OR source_row.version<>source_version OR retained_row.version<>retained_version
       OR retained_row.status NOT IN ('active','probation','onLeave','resigned')
       OR (retained_row.status='resigned' AND source_row.status<>'resigned')
       OR EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id IN(source_id,retained_id)
                     OR canonical_employee_id=source_id)
       OR EXISTS(SELECT 1 FROM users WHERE employee_id=source_id AND NOT is_deleted)
       OR EXISTS(SELECT 1 FROM users WHERE employee_id=retained_id AND is_super_admin AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Duplicate employee, account or verification versions changed' USING ERRCODE='23514';
    END IF;
    -- 'valid' describes document format, not verified ownership. An explicit
    -- additional review is mandatory when existing document facts disagree.
    IF EXISTS(SELECT 1 FROM employee_sensitive a JOIN employee_sensitive b ON b.employee_id=retained_id
              WHERE a.employee_id=source_id AND a.id_card_hash IS NOT NULL AND b.id_card_hash IS NOT NULL
                AND a.id_card_hash<>b.id_card_hash) AND NOT COALESCE(document_conflict_verified,false) THEN
        RAISE EXCEPTION 'The employees have different verified identity documents' USING ERRCODE='23514';
    END IF;
    UPDATE employees SET is_deleted=true,deleted_at=now(),version=version+1 WHERE id=source_id;
    PERFORM set_config('app.employee_identity_merge_evidence',reviewed_evidence,true);
    INSERT INTO employee_identity_aliases(alias_employee_id,canonical_employee_id,reason,evidence_reference,created_by)
    VALUES(source_id,retained_id,btrim(verified_reason),reviewed_evidence,NULLIF(current_setting('app.actor_id',true),'')::uuid);
    RETURN retained_id;
END $$;
REVOKE ALL ON FUNCTION fn_archive_verified_employee_duplicate(uuid,uuid,integer,integer,text,text,boolean) FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN
        GRANT EXECUTE ON FUNCTION fn_archive_verified_employee_duplicate(uuid,uuid,integer,integer,text,text,boolean) TO uten;
    END IF;
END $$;

-- Historical identifiers stay unchanged. A reviewed person's current record may
-- use their own archived identifier; unrelated identities must still be unique.
LOCK TABLE employee_sensitive IN SHARE ROW EXCLUSIVE MODE;
CREATE TABLE employee_identity_document_claims (
    document_hash text PRIMARY KEY,
    employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE RESTRICT
);
INSERT INTO employee_identity_document_claims(document_hash,employee_id)
SELECT id_card_hash,employee_id FROM employee_sensitive WHERE id_card_hash IS NOT NULL;
COMMENT ON TABLE employee_identity_document_claims IS
    'Private identity-claim lock/uniqueness projection of employee_sensitive, not independent historical evidence';
REVOKE ALL ON TABLE employee_identity_document_claims FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN
        REVOKE ALL ON TABLE employee_identity_document_claims FROM uten;
    END IF;
END $$;
DROP INDEX uk_employee_sensitive_id_card_hash;
CREATE INDEX employee_sensitive_id_card_hash_idx ON employee_sensitive(id_card_hash) WHERE id_card_hash IS NOT NULL;
CREATE FUNCTION fn_guard_employee_identity_claim() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE claimed_employee uuid;
BEGIN
    IF NEW.id_card_hash IS NULL THEN RETURN NEW; END IF;
    -- The PK/UPSERT, rather than a snapshot-sensitive SELECT, arbitrates claims.
    -- In REPEATABLE READ a concurrent winner produces a serialization failure.
    INSERT INTO employee_identity_document_claims AS claim(document_hash,employee_id)
    VALUES(NEW.id_card_hash,NEW.employee_id)
    ON CONFLICT(document_hash) DO UPDATE SET employee_id=claim.employee_id
    RETURNING claim.employee_id INTO claimed_employee;
    IF fn_canonical_employee_identity(claimed_employee)<>fn_canonical_employee_identity(NEW.employee_id) THEN
        RAISE EXCEPTION 'duplicate key value violates unique constraint "uk_employee_sensitive_id_card_hash"'
            USING ERRCODE='23505',CONSTRAINT='uk_employee_sensitive_id_card_hash';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_employee_identity_claim BEFORE INSERT OR UPDATE OF id_card_hash,employee_id ON employee_sensitive
FOR EACH ROW EXECUTE FUNCTION fn_guard_employee_identity_claim();
ALTER TABLE employee_sensitive ENABLE ALWAYS TRIGGER trg_employee_identity_claim;
CREATE FUNCTION fn_release_unused_employee_identity_claim() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF OLD.id_card_hash IS NOT NULL AND (TG_OP='DELETE' OR OLD.id_card_hash IS DISTINCT FROM NEW.id_card_hash) THEN
        DELETE FROM employee_identity_document_claims claim
        WHERE claim.document_hash=OLD.id_card_hash
          AND NOT EXISTS(SELECT 1 FROM employee_sensitive s WHERE s.id_card_hash=OLD.id_card_hash);
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_release_unused_employee_identity_claim AFTER UPDATE OF id_card_hash OR DELETE ON employee_sensitive
FOR EACH ROW EXECUTE FUNCTION fn_release_unused_employee_identity_claim();
ALTER TABLE employee_sensitive ENABLE ALWAYS TRIGGER trg_release_unused_employee_identity_claim;
