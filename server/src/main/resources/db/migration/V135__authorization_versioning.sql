-- V135: immediate invalidation of access JWT permission snapshots.
--
-- Access tokens intentionally contain a permission snapshot. Short expiry
-- limits exposure, but role/permission changes must not leave an already
-- issued token authorized until expiry. A per-user version handles direct
-- grants/roles; a global epoch handles shared role/department definitions.

ALTER TABLE users
    ADD COLUMN auth_version BIGINT NOT NULL DEFAULT 0,
    ADD CONSTRAINT users_auth_version_chk CHECK (auth_version >= 0);

CREATE TABLE authorization_state (
    singleton_id SMALLINT PRIMARY KEY DEFAULT 1,
    epoch        BIGINT NOT NULL DEFAULT 0,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT authorization_state_singleton_chk CHECK (singleton_id = 1),
    CONSTRAINT authorization_state_epoch_chk CHECK (epoch >= 0)
);

INSERT INTO authorization_state(singleton_id, epoch)
VALUES (1, 0);

CREATE OR REPLACE FUNCTION fn_bump_authorization_epoch() RETURNS TRIGGER AS $$
BEGIN
    UPDATE authorization_state
    SET epoch = epoch + 1,
        updated_at = CURRENT_TIMESTAMP
    WHERE singleton_id = 1;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_bump_user_auth_version() RETURNS TRIGGER AS $$
DECLARE
    old_user_id UUID;
    new_user_id UUID;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        old_user_id := OLD.user_id;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        new_user_id := NEW.user_id;
    END IF;

    IF old_user_id IS NOT NULL THEN
        UPDATE users
        SET auth_version = auth_version + 1
        WHERE id = old_user_id;
    END IF;
    IF new_user_id IS NOT NULL
       AND new_user_id IS DISTINCT FROM old_user_id THEN
        UPDATE users
        SET auth_version = auth_version + 1
        WHERE id = new_user_id;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_bump_employee_user_auth_version() RETURNS TRIGGER AS $$
BEGIN
    UPDATE users
    SET auth_version = auth_version + 1
    WHERE employee_id = NEW.id;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_bump_user_auth_shape_version() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.is_super_admin IS DISTINCT FROM OLD.is_super_admin
       OR NEW.employee_id IS DISTINCT FROM OLD.employee_id THEN
        NEW.auth_version := OLD.auth_version + 1;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_user_roles_auth_version
AFTER INSERT OR UPDATE OR DELETE ON user_roles
FOR EACH ROW EXECUTE FUNCTION fn_bump_user_auth_version();

CREATE TRIGGER trg_user_permission_overrides_auth_version
AFTER INSERT OR UPDATE OR DELETE ON user_permission_overrides
FOR EACH ROW EXECUTE FUNCTION fn_bump_user_auth_version();

CREATE TRIGGER trg_employee_department_auth_version
AFTER UPDATE OF department_id ON employees
FOR EACH ROW
WHEN (OLD.department_id IS DISTINCT FROM NEW.department_id)
EXECUTE FUNCTION fn_bump_employee_user_auth_version();

CREATE TRIGGER trg_user_auth_shape_version
BEFORE UPDATE OF is_super_admin, employee_id ON users
FOR EACH ROW EXECUTE FUNCTION fn_bump_user_auth_shape_version();

-- These tables define permissions shared by multiple users. One epoch update
-- per SQL statement avoids O(users × permissions) mass updates.
CREATE TRIGGER trg_role_permissions_authorization_epoch
AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON role_permissions
FOR EACH STATEMENT EXECUTE FUNCTION fn_bump_authorization_epoch();

CREATE TRIGGER trg_department_roles_authorization_epoch
AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON department_roles
FOR EACH STATEMENT EXECUTE FUNCTION fn_bump_authorization_epoch();

CREATE TRIGGER trg_department_permissions_authorization_epoch
AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON department_permissions
FOR EACH STATEMENT EXECUTE FUNCTION fn_bump_authorization_epoch();

CREATE TRIGGER trg_permissions_authorization_epoch
AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON permissions
FOR EACH STATEMENT EXECUTE FUNCTION fn_bump_authorization_epoch();

CREATE TRIGGER trg_roles_authorization_epoch
AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON roles
FOR EACH STATEMENT EXECUTE FUNCTION fn_bump_authorization_epoch();

-- Effective department permissions include the ancestor chain. Moving,
-- deleting or restoring a node therefore changes authorization even when the
-- permission association rows themselves are untouched.
CREATE TRIGGER trg_department_hierarchy_authorization_epoch
AFTER UPDATE OF parent_id, is_deleted ON departments
FOR EACH STATEMENT EXECUTE FUNCTION fn_bump_authorization_epoch();

CREATE TRIGGER trg_department_membership_authorization_epoch
AFTER INSERT OR DELETE OR TRUNCATE ON departments
FOR EACH STATEMENT EXECUTE FUNCTION fn_bump_authorization_epoch();

REVOKE ALL ON authorization_state FROM PUBLIC;

COMMENT ON COLUMN users.auth_version IS
    'Copied into access JWT; direct user authorization changes increment it and invalidate old tokens.';
COMMENT ON TABLE authorization_state IS
    'Singleton global authorization epoch for shared role/department permission definitions.';
