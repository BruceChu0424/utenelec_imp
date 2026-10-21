-- Catalog removal is separate from immutable column identities and historical business values.
CREATE TABLE platform_column_definition_deletions (
    definition_id uuid PRIMARY KEY REFERENCES platform_column_definitions(id) ON DELETE RESTRICT,
    deleted_by uuid NOT NULL,
    deleted_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
SELECT fn_audit_track_table('platform_column_definition_deletions', 'FULL', 'data_change', false);

-- Resetting test business records must not make a removed shared/personal catalog entry reappear.
DO $reset_policy$
DECLARE definition text; anchor text := '(''platform_column_definitions'', ''PRESERVE'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V888 cannot extend column-deletion reset policy safely';
    END IF;
    definition := replace(definition,anchor,anchor
        || E',\n            (''platform_column_definition_deletions'', ''PRESERVE'')');
    EXECUTE definition;
END
$reset_policy$;

-- Commercial document columns use the same catalog-only removal contract.
CREATE TABLE business_column_deletions (
    column_id uuid PRIMARY KEY REFERENCES business_column_definitions(id) ON DELETE RESTRICT,
    deleted_by uuid NOT NULL,
    deleted_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
SELECT fn_audit_track_table('business_column_deletions', 'FULL', 'data_change', false);

DO $business_reset_policy$
DECLARE definition text; anchor text := '(''business_column_definitions'', ''PRESERVE'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V888 cannot extend business column-deletion reset policy safely';
    END IF;
    definition := replace(definition,anchor,anchor
        || E',\n            (''business_column_deletions'', ''PRESERVE'')');
    EXECUTE definition;
END
$business_reset_policy$;
