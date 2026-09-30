-- Extension values are business records, never user-preference payloads.
-- Resource registration and row authorization live in explicit domain adapters.
CREATE TABLE platform_column_definitions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    scope varchar(100) NOT NULL CHECK (scope ~ '^[a-z][a-z0-9_]{0,99}$'),
    -- Zero denotes the shared business dictionary; personal report scopes use the actor UUID.
    owner_user_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
    name varchar(80) NOT NULL,
    normalized_name text NOT NULL,
    value_type text NOT NULL CHECK (value_type IN ('TEXT','NUMBER','CALCULATED')),
    price_protected boolean NOT NULL DEFAULT false,
    formula jsonb,
    definition_fingerprint varchar(64) NOT NULL,
    usage_count bigint NOT NULL DEFAULT 0 CHECK (usage_count >= 0),
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,
    CHECK ((value_type = 'CALCULATED') = (formula IS NOT NULL)),
    CHECK (formula IS NULL OR jsonb_typeof(formula) = 'object'),
    UNIQUE(scope, owner_user_id, definition_fingerprint)
);
CREATE TABLE platform_record_fields (
    scope varchar(100) NOT NULL CHECK (scope ~ '^[a-z][a-z0-9_]{0,99}$'),
    record_id uuid NOT NULL,
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    cells jsonb NOT NULL DEFAULT '[]'::jsonb,
    retain_on_reset boolean NOT NULL DEFAULT false,
    source_document_id uuid,
    source_line_index integer CHECK (source_line_index >= 0),
    source_fields_version bigint CHECK (source_fields_version >= 0),
    created_by uuid NOT NULL,
    updated_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(scope,record_id),
    CHECK (jsonb_typeof(cells) = 'array' AND jsonb_array_length(cells) <= 32),
    CHECK ((source_document_id IS NULL AND source_line_index IS NULL AND source_fields_version IS NULL)
        OR (source_document_id IS NOT NULL AND source_line_index IS NOT NULL AND source_fields_version IS NOT NULL))
);
CREATE TABLE platform_column_usage (
    user_id uuid NOT NULL,
    definition_id uuid NOT NULL REFERENCES platform_column_definitions(id) ON DELETE RESTRICT,
    usage_count bigint NOT NULL DEFAULT 1 CHECK (usage_count > 0),
    last_used_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(user_id,definition_id)
);

CREATE FUNCTION fn_guard_platform_column_definition()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_OP='DELETE' OR (to_jsonb(NEW)-ARRAY['usage_count','last_used_at'])
        IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['usage_count','last_used_at']) THEN
        RAISE EXCEPTION 'Platform column definitions are immutable; create a new definition' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END
$function$;
CREATE TRIGGER trg_platform_column_definition_immutable
BEFORE UPDATE OR DELETE ON platform_column_definitions FOR EACH ROW
EXECUTE FUNCTION fn_guard_platform_column_definition();

SELECT fn_audit_track_table('platform_column_definitions', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('platform_record_fields', 'FULL', 'data_change', false);
-- Derived per-user ranking contains no field values and is not a business decision.
SELECT fn_audit_track_table('platform_column_usage', 'NONE', 'data_change', false);

-- Only a server-registered master adapter can mark values for retention.
-- Selectively delete commercial rows before collecting PRESERVE counts.
DO $reset_policy$
DECLARE definition text; anchor text := '(''stock_movements'', ''CLEAR'')';
        cleanup_anchor text := '    CREATE TEMP TABLE reset_business_preserve_counts (';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V750 cannot extend business-data reset policy safely';
    END IF;
    definition := replace(definition,anchor,anchor
        || E',\n            (''platform_column_definitions'', ''PRESERVE'')'
        || E',\n            (''platform_record_fields'', ''PRESERVE'')'
        || E',\n            (''platform_column_usage'', ''PRESERVE'')');
    IF (length(definition)-length(replace(definition,cleanup_anchor,'')))/length(cleanup_anchor) <> 1 THEN
        RAISE EXCEPTION 'V750 cannot add scoped annotation cleanup safely';
    END IF;
    definition := replace(definition,cleanup_anchor,
        E'    LOCK TABLE public.platform_record_fields IN ACCESS EXCLUSIVE MODE;\n'
        || E'    DELETE FROM public.platform_record_fields WHERE NOT retain_on_reset;\n'
        || E'    GET DIAGNOSTICS n = ROW_COUNT;\n'
        || E'    cleared_rows_total := cleared_rows_total + n;\n'
        || E'    UPDATE reset_business_summary SET cleared_rows=cleared_rows_total;\n\n' || cleanup_anchor);
    EXECUTE definition;
END
$reset_policy$;
