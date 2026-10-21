-- The reference is an explicit master-data association, never an automatic name match.
CREATE TABLE goods_market_reference_bindings (
    goods_id uuid PRIMARY KEY REFERENCES goods(id) ON DELETE RESTRICT,
    series_id text,
    identity_digest text,
    version bigint NOT NULL CHECK (version >= 1),
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid NOT NULL REFERENCES users(id),
    CONSTRAINT ck_goods_market_reference_identity CHECK (
        (series_id IS NULL AND identity_digest IS NULL) OR
        (series_id IS NOT NULL AND identity_digest IS NOT NULL
         AND series_id ~ '^[a-z0-9][a-z0-9_-]{0,63}$' AND identity_digest ~ '^[0-9a-f]{64}$'))
);
COMMENT ON TABLE goods_market_reference_bindings IS
    'Explicit goods to offline market benchmark association. Null series retains an unlink tombstone and CAS revision; identity digest prevents silent instrument replacement.';
CREATE FUNCTION fn_guard_goods_market_reference_revision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'Market reference tombstones must be retained' USING ERRCODE='23514';
    END IF;
    IF NEW.goods_id<>OLD.goods_id OR NEW.version<>OLD.version+1 THEN
        RAISE EXCEPTION 'Market reference revision must advance exactly once' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_goods_market_reference_revision BEFORE UPDATE OR DELETE ON goods_market_reference_bindings
FOR EACH ROW EXECUTE FUNCTION fn_guard_goods_market_reference_revision();
ALTER TABLE goods_market_reference_bindings ENABLE ALWAYS TRIGGER trg_goods_market_reference_revision;
SELECT fn_audit_track_table('goods_market_reference_bindings','FULL','data_change',false);

-- This association belongs to preserved goods master data, including unlink tombstones.
DO $reset_policy$
DECLARE definition text; anchor text := '(''goods'', ''PRESERVE'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V890 cannot extend market reference reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n    (''goods_market_reference_bindings'', ''PRESERVE'')');
END
$reset_policy$;
