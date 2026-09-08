-- INCLUDE attributes are index payload, not part of a row's primary-key identity.
-- Preserve V530's fallback result format and all existing audit/row history.
CREATE OR REPLACE FUNCTION public.fn_audit_primary_key_identity(p_relation OID,p_row JSONB)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN count(*)=1 THEN min(p_row->>attribute.attname)
                WHEN count(*)>1 THEN jsonb_object_agg(attribute.attname,p_row->attribute.attname ORDER BY key.ordinality)::text END
    FROM pg_index index_row
    CROSS JOIN LATERAL unnest(index_row.indkey) WITH ORDINALITY AS key(attnum,ordinality)
    JOIN pg_attribute attribute ON attribute.attrelid=index_row.indrelid AND attribute.attnum=key.attnum
    WHERE index_row.indrelid=p_relation AND index_row.indisprimary
      AND key.ordinality<=index_row.indnkeyatts;
$$;
