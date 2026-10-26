-- Verified identity aliases only; never infer sameness from a display name.
-- Raw employee/user/business/audit UUIDs and encrypted historical facts remain intact.
CREATE TABLE employee_identity_aliases (
    alias_employee_id uuid PRIMARY KEY REFERENCES employees(id) ON DELETE RESTRICT,
    canonical_employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    reason text NOT NULL CHECK(length(btrim(reason)) BETWEEN 1 AND 1000),
    evidence_reference text NOT NULL CHECK(length(btrim(evidence_reference)) BETWEEN 1 AND 1000),
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid REFERENCES users(id) ON DELETE RESTRICT,
    CHECK(alias_employee_id<>canonical_employee_id)
);
CREATE INDEX employee_identity_aliases_canonical_idx ON employee_identity_aliases(canonical_employee_id);

CREATE FUNCTION fn_guard_verified_employee_identity_alias() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION 'Verified employee identity aliases are append-only' USING ERRCODE='55000';
    END IF;
    IF NULLIF(current_setting('app.actor_account',true),'') IS NULL
       OR current_setting('app.employee_identity_merge_evidence',true) IS DISTINCT FROM NEW.evidence_reference THEN
        RAISE EXCEPTION 'Employee identity alias requires a verified maintenance evidence context' USING ERRCODE='42501';
    END IF;
    PERFORM pg_advisory_xact_lock(1431586126,937);
    PERFORM id FROM employees WHERE id IN(NEW.alias_employee_id,NEW.canonical_employee_id) ORDER BY id FOR UPDATE;
    IF NOT EXISTS(SELECT 1 FROM employees WHERE id=NEW.alias_employee_id AND is_deleted)
       OR NOT EXISTS(SELECT 1 FROM employees WHERE id=NEW.canonical_employee_id AND NOT is_deleted)
       OR EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=NEW.canonical_employee_id
                  OR canonical_employee_id=NEW.alias_employee_id)
       OR EXISTS(SELECT 1 FROM users WHERE employee_id=NEW.alias_employee_id AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Employee alias must be archived, account-free and point directly to one retained canonical employee'
            USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_verified_employee_identity_alias_guard
BEFORE INSERT OR UPDATE OR DELETE ON employee_identity_aliases
FOR EACH ROW EXECUTE FUNCTION fn_guard_verified_employee_identity_alias();
ALTER TABLE employee_identity_aliases ENABLE ALWAYS TRIGGER trg_verified_employee_identity_alias_guard;
CREATE TRIGGER trg_verified_employee_identity_alias_truncate_guard
BEFORE TRUNCATE ON employee_identity_aliases
FOR EACH STATEMENT EXECUTE FUNCTION fn_guard_verified_employee_identity_alias();
ALTER TABLE employee_identity_aliases ENABLE ALWAYS TRIGGER trg_verified_employee_identity_alias_truncate_guard;

CREATE FUNCTION fn_canonical_employee_identity(raw_employee_id uuid) RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT COALESCE((SELECT canonical_employee_id FROM employee_identity_aliases WHERE alias_employee_id=raw_employee_id),raw_employee_id)
$$;
CREATE FUNCTION fn_employee_identity_members(raw_employee_id uuid) RETURNS TABLE(employee_id uuid)
LANGUAGE sql STABLE PARALLEL SAFE SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT fn_canonical_employee_identity(raw_employee_id)
    UNION ALL
    SELECT alias_employee_id FROM employee_identity_aliases
    WHERE canonical_employee_id=fn_canonical_employee_identity(raw_employee_id)
$$;

CREATE FUNCTION fn_invalidate_employee_identity_alias_readers() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    UPDATE authorization_state SET epoch=epoch+1,updated_at=now() WHERE singleton_id=1;
    RETURN NULL;
END; $$;
CREATE TRIGGER trg_employee_identity_alias_read_epoch AFTER INSERT ON employee_identity_aliases
FOR EACH ROW EXECUTE FUNCTION fn_invalidate_employee_identity_alias_readers();
ALTER TABLE employee_identity_aliases ENABLE ALWAYS TRIGGER trg_employee_identity_alias_read_epoch;
SELECT fn_audit_track_table('employee_identity_aliases','FULL','authorization',false);
COMMENT ON TABLE employee_identity_aliases IS
    'PRESERVE permanent identity evidence; append-only, never rewrites raw historical facts, permissions, credentials or messages; V919 retired the business reset policy registry';

-- A verified alias cannot later become another live employee/account identity.
CREATE FUNCTION fn_guard_employee_identity_alias_lifecycle() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF NEW.is_deleted IS DISTINCT FROM OLD.is_deleted AND (
        (NOT NEW.is_deleted AND EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=NEW.id))
        OR (NEW.is_deleted AND EXISTS(SELECT 1 FROM employee_identity_aliases WHERE canonical_employee_id=NEW.id))
    ) THEN
        RAISE EXCEPTION 'Verified employee aliases stay archived and their canonical employee must be retained'
            USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_employee_identity_alias_lifecycle BEFORE UPDATE OF is_deleted ON employees
FOR EACH ROW EXECUTE FUNCTION fn_guard_employee_identity_alias_lifecycle();
ALTER TABLE employees ENABLE ALWAYS TRIGGER trg_employee_identity_alias_lifecycle;

CREATE FUNCTION fn_guard_employee_identity_alias_account() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF TG_OP='UPDATE' AND NEW.employee_id IS NOT DISTINCT FROM OLD.employee_id
       AND NEW.is_deleted IS NOT DISTINCT FROM OLD.is_deleted THEN
        RETURN NEW;
    END IF;
    IF NEW.employee_id IS NOT NULL AND NOT NEW.is_deleted THEN
        -- Alias verification locks this same employee; unrelated accounts need no shared lock.
        PERFORM id FROM public.employees WHERE id=NEW.employee_id FOR UPDATE;
        IF EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=NEW.employee_id) THEN
            RAISE EXCEPTION 'A login account must bind to the canonical employee identity'
                USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_employee_identity_alias_account BEFORE INSERT OR UPDATE OF employee_id,is_deleted ON users
FOR EACH ROW EXECUTE FUNCTION fn_guard_employee_identity_alias_account();
ALTER TABLE users ENABLE ALWAYS TRIGGER trg_employee_identity_alias_account;

-- Hardened hosts create objects as uten_owner, whose defaults grant runtime DML.
-- The application only reads identity evidence; maintenance owns explicit inserts.
REVOKE ALL ON TABLE employee_identity_aliases FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten') THEN
        REVOKE ALL ON TABLE employee_identity_aliases FROM uten;
        GRANT SELECT ON TABLE employee_identity_aliases TO uten;
        GRANT EXECUTE ON FUNCTION fn_canonical_employee_identity(uuid),fn_employee_identity_members(uuid) TO uten;
    END IF;
END $$;
