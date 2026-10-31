-- Existing bindings keep their reviewed additive semantics until explicitly reapplied.
ALTER TABLE user_permission_template_bindings
    ADD COLUMN exact_permissions boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN user_permission_template_bindings.exact_permissions IS
    'Explicit replacement uses the live template instead of baseline/department inheritance; later individual decisions remain applicable.';
