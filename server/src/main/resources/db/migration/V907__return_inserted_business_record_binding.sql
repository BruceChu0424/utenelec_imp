-- Preserve the immutable child-to-parent binding without looking up every new
-- identity again. An initially empty binding table can otherwise retain a
-- cached sequential-scan plan throughout a large atomic legacy import.
CREATE OR REPLACE FUNCTION fn_bind_business_record_identity(p_source text,p_id text,p_parent text,p_parent_id text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE bound_parent text; bound_id text;
BEGIN
    INSERT INTO business_record_identities(source_table,source_id,parent_table,parent_id)
    VALUES(p_source,p_id,p_parent,p_parent_id)
    ON CONFLICT(source_table,source_id) DO NOTHING
    RETURNING parent_table,parent_id INTO bound_parent,bound_id;
    IF NOT FOUND THEN
        SELECT parent_table,parent_id INTO bound_parent,bound_id FROM business_record_identities
        WHERE source_table=p_source AND source_id=p_id;
        -- A repeatable-read transaction that cannot see a concurrent binding
        -- must fail closed rather than accept an identity as unbound.
        IF NOT FOUND THEN RAISE EXCEPTION 'Retained identity changed concurrently' USING ERRCODE='40001'; END IF;
    END IF;
    IF bound_parent IS DISTINCT FROM p_parent OR bound_id IS DISTINCT FROM p_parent_id THEN
        RAISE EXCEPTION 'A retained record identity cannot move to another parent; create a new identity' USING ERRCODE='23514';
    END IF;
END;
$$;
