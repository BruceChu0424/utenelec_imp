-- Resolve the exact quoted relation through the catalog's name cache first.
-- The old text/name join could repeatedly scan the complete trigger catalog
-- inside ancestry and polymorphic-source lookups. Membership still requires
-- the same real, non-internal archive guard on the public relation.
CREATE OR REPLACE FUNCTION public.fn_imported_business_document_table(p_table text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
    SELECT CASE
        WHEN p_table IS NULL OR p_table='' OR
            octet_length(p_table)>current_setting('max_identifier_length')::integer THEN false
        ELSE EXISTS (
            SELECT 1 FROM pg_trigger trigger_row
            WHERE trigger_row.tgrelid=to_regclass(format('public.%I',p_table))
              AND trigger_row.tgname='trg_00_imported_business_archive_only'
              AND NOT trigger_row.tgisinternal
        )
    END
$$;
