-- New template assignments are independent authorization sources. Existing V957 writes
-- cannot be distinguished from manual grants: retain them and their legacy assignment
-- records without guessing or deleting any existing authorization.
CREATE TABLE user_permission_template_bindings (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    template_id uuid NOT NULL REFERENCES permission_templates(id),
    bound_by uuid NOT NULL REFERENCES users(id),
    bound_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE department_permission_template_bindings (
    department_id uuid PRIMARY KEY REFERENCES departments(id) ON DELETE CASCADE,
    template_id uuid NOT NULL REFERENCES permission_templates(id),
    bound_by uuid NOT NULL REFERENCES users(id),
    bound_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX user_permission_template_bindings_template_idx ON user_permission_template_bindings(template_id);
CREATE INDEX department_permission_template_bindings_template_idx ON department_permission_template_bindings(template_id);
COMMENT ON TABLE permission_template_applies IS 'Legacy V957 snapshot applications; existing personal grants remain untouched. Reapply a template to establish an independent live source.';

CREATE VIEW authorization_user_template_permission_sources AS
SELECT binding.user_id, permission.id AS permission_id, permission.code
FROM user_permission_template_bindings binding
JOIN permission_templates template ON template.id=binding.template_id AND NOT template.is_deleted
CROSS JOIN LATERAL jsonb_array_elements_text(template.permission_codes) code(value)
JOIN permissions permission ON permission.code=code.value
WHERE NOT ('SUPERADMIN_ONLY'=ANY(permission.grant_policy));

CREATE VIEW authorization_department_permission_sources AS
SELECT allocation.department_id, allocation.permission_id
FROM department_permissions allocation
UNION
SELECT binding.department_id, permission.id
FROM department_permission_template_bindings binding
JOIN permission_templates template ON template.id=binding.template_id AND NOT template.is_deleted
CROSS JOIN LATERAL jsonb_array_elements_text(template.permission_codes) code(value)
JOIN permissions permission ON permission.code=code.value
WHERE NOT (permission.grant_policy && ARRAY['SUPERADMIN_ONLY','INDIVIDUAL_ONLY']::text[]);

CREATE TRIGGER trg_user_permission_template_auth_version
AFTER INSERT OR UPDATE OR DELETE ON user_permission_template_bindings
FOR EACH ROW EXECUTE FUNCTION fn_bump_user_auth_version();
CREATE TRIGGER trg_department_permission_template_epoch
AFTER INSERT OR UPDATE OR DELETE ON department_permission_template_bindings
FOR EACH ROW EXECUTE FUNCTION fn_bump_authorization_epoch();
CREATE TRIGGER trg_department_permission_template_truncate_epoch
AFTER TRUNCATE ON department_permission_template_bindings
FOR EACH STATEMENT EXECUTE FUNCTION fn_bump_authorization_epoch();

CREATE FUNCTION fn_bump_linked_permission_template_epoch() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.permission_codes IS DISTINCT FROM NEW.permission_codes
       OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted THEN
        IF EXISTS(SELECT 1 FROM user_permission_template_bindings WHERE template_id=NEW.id)
           OR EXISTS(SELECT 1 FROM department_permission_template_bindings WHERE template_id=NEW.id) THEN
            UPDATE authorization_state SET epoch=epoch+1,updated_at=now() WHERE singleton_id=1;
        END IF;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_linked_permission_template_epoch AFTER UPDATE ON permission_templates
FOR EACH ROW EXECUTE FUNCTION fn_bump_linked_permission_template_epoch();
ALTER TABLE user_permission_template_bindings ENABLE ALWAYS TRIGGER trg_user_permission_template_auth_version;
ALTER TABLE department_permission_template_bindings ENABLE ALWAYS TRIGGER trg_department_permission_template_epoch;
ALTER TABLE permission_templates ENABLE ALWAYS TRIGGER trg_linked_permission_template_epoch;
SELECT fn_audit_track_table('user_permission_template_bindings','FULL','authorization',false);
SELECT fn_audit_track_table('department_permission_template_bindings','FULL','authorization',false);
