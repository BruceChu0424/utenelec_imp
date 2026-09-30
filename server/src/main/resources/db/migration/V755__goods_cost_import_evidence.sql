-- Original cost workbooks and their read-only interpretation remain private, immutable evidence.
CREATE TABLE goods_cost_imports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    goods_id uuid NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    actor_id uuid NOT NULL,
    source_name text NOT NULL CHECK(length(source_name) BETWEEN 1 AND 240),
    storage_provider text NOT NULL,
    storage_key text NOT NULL,
    storage_version text,
    storage_size bigint NOT NULL CHECK(storage_size>0 AND storage_size<=15728640),
    storage_sha256 char(64) NOT NULL,
    preview jsonb NOT NULL CHECK(jsonb_typeof(preview)='object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(goods_id,actor_id,storage_sha256)
);
CREATE INDEX idx_goods_cost_imports_object ON goods_cost_imports(storage_provider,storage_key,storage_version);
CREATE INDEX idx_goods_cost_imports_goods ON goods_cost_imports(goods_id,created_at DESC,id);
CREATE TABLE goods_cost_import_mappings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    import_id uuid NOT NULL REFERENCES goods_cost_imports(id) ON DELETE RESTRICT,
    goods_id uuid NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    actor_id uuid NOT NULL,
    block_key text NOT NULL,
    mapping_hash char(64) NOT NULL,
    mappings jsonb NOT NULL CHECK(jsonb_typeof(mappings)='array'),
    base_input jsonb NOT NULL CHECK(jsonb_typeof(base_input)='object'),
    result_input jsonb NOT NULL CHECK(jsonb_typeof(result_input)='object'),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_goods_cost_import_mappings_source ON goods_cost_import_mappings(import_id,created_at DESC,id);
CREATE INDEX idx_goods_cost_import_mappings_goods ON goods_cost_import_mappings(goods_id,created_at DESC,id);
CREATE FUNCTION fn_goods_cost_import_immutable() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN RAISE EXCEPTION 'Cost import evidence is immutable' USING ERRCODE='23514'; END
$function$;
CREATE TRIGGER trg_goods_cost_import_immutable BEFORE UPDATE OR DELETE ON goods_cost_imports
FOR EACH ROW EXECUTE FUNCTION fn_goods_cost_import_immutable();
ALTER TABLE goods_cost_imports ENABLE ALWAYS TRIGGER trg_goods_cost_import_immutable;
CREATE TRIGGER trg_goods_cost_import_mapping_immutable BEFORE UPDATE OR DELETE ON goods_cost_import_mappings
FOR EACH ROW EXECUTE FUNCTION fn_goods_cost_import_immutable();
ALTER TABLE goods_cost_import_mappings ENABLE ALWAYS TRIGGER trg_goods_cost_import_mapping_immutable;
SELECT fn_audit_track_table('goods_cost_imports','FULL','data_change',false);
SELECT fn_audit_track_table('goods_cost_import_mappings','FULL','data_change',false);

CREATE VIEW v_private_document_storage_references AS
SELECT storage_provider,storage_key,storage_version FROM v_sales_quote_template_storage_references
UNION
SELECT storage_provider,storage_key,storage_version FROM goods_cost_imports;
COMMENT ON VIEW v_private_document_storage_references IS
    'Exact private document identities retained by cost evidence and generated quote templates; no contents';

DO $reset_policy$
DECLARE definition text; anchor text := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V755 cannot extend reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor || E',\n            (''goods_cost_imports'', ''PRESERVE'')'
        || E',\n            (''goods_cost_import_mappings'', ''PRESERVE'')');
END $reset_policy$;
