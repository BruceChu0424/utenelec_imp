-- The exact permission-qualified pool keeps its existing fallback. A genuine
-- designated supervisor also receives child-warehouse work, alongside the
-- eligible child keepers. Implicit super-admin status is not responsibility.
DO $warehouse_notice_union$
DECLARE
    function_oid oid := 'public.fn_warehouse_notice_recipients(uuid[],uuid[])'::regprocedure;
    definition text;
    previous_source text;
    attributes_before jsonb;
    attributes_after jsonb;
    occurrences integer;
    canonical_source constant text := $v892_body$
    WITH pool AS MATERIALIZED (
        SELECT DISTINCT unnest(COALESCE(p_pool, ARRAY[]::uuid[])) AS id
    ), keeper_ids AS MATERIALIZED (
        SELECT fn_warehouse_keeper_user_ids(
            array_remove(COALESCE(p_warehouse_ids, ARRAY[]::uuid[]), NULL)) AS ids
    ), keepers AS MATERIALIZED (
        SELECT pool.id FROM pool CROSS JOIN keeper_ids WHERE pool.id = ANY(keeper_ids.ids)
    ), supervisor_ids AS MATERIALIZED (
        SELECT fn_warehouse_designated_supervisor_user_ids() AS ids
    ), supervisors AS MATERIALIZED (
        SELECT pool.id FROM pool CROSS JOIN supervisor_ids WHERE pool.id = ANY(supervisor_ids.ids)
    )
    SELECT COALESCE(
        CASE WHEN EXISTS (SELECT 1 FROM keepers) THEN ARRAY(SELECT id FROM keepers ORDER BY id)
             WHEN EXISTS (SELECT 1 FROM supervisors) THEN ARRAY(SELECT id FROM supervisors ORDER BY id)
             ELSE ARRAY(SELECT id FROM pool ORDER BY id) END,
        ARRAY[]::uuid[]);
    $v892_body$;
    replacement_source constant text := $union_body$
    WITH pool AS MATERIALIZED (
        SELECT DISTINCT unnest(COALESCE(p_pool, ARRAY[]::uuid[])) AS id
    ), keeper_ids AS MATERIALIZED (
        SELECT fn_warehouse_keeper_user_ids(
            array_remove(COALESCE(p_warehouse_ids, ARRAY[]::uuid[]), NULL)) AS ids
    ), keepers AS MATERIALIZED (
        SELECT pool.id FROM pool CROSS JOIN keeper_ids WHERE pool.id = ANY(keeper_ids.ids)
    ), supervisor_ids AS MATERIALIZED (
        SELECT fn_warehouse_designated_supervisor_user_ids() AS ids
    ), supervisors AS MATERIALIZED (
        SELECT pool.id FROM pool CROSS JOIN supervisor_ids WHERE pool.id = ANY(supervisor_ids.ids)
    ), responsible AS MATERIALIZED (
        SELECT id FROM keepers UNION SELECT id FROM supervisors
    )
    SELECT COALESCE(
        CASE WHEN EXISTS (SELECT 1 FROM responsible) THEN ARRAY(SELECT id FROM responsible ORDER BY id)
             ELSE ARRAY(SELECT id FROM pool ORDER BY id) END,
        ARRAY[]::uuid[]);
    $union_body$;
BEGIN
    SELECT pg_catalog.pg_get_functiondef(function_oid),p.prosrc,
           to_jsonb(p)-'prosrc'-'prosqlbody'
      INTO definition,previous_source,attributes_before
      FROM pg_catalog.pg_proc p WHERE p.oid=function_oid;
    IF regexp_replace(previous_source,'[[:space:]]+','','g') IS DISTINCT FROM
       regexp_replace(canonical_source,'[[:space:]]+','','g') THEN
        RAISE EXCEPTION 'V982 warehouse notice predecessor is not the canonical V892 body';
    END IF;
    occurrences := (length(definition)-length(replace(definition,previous_source,'')))/length(previous_source);
    IF occurrences<>1 THEN
        RAISE EXCEPTION 'V982 expected exactly one warehouse notice function body, found %',occurrences;
    END IF;
    -- Retain identity, owner, execution grants and all configured execution
    -- attributes; no broad CREATE OR REPLACE declaration resets their values.
    EXECUTE replace(definition,previous_source,replacement_source);
    SELECT to_jsonb(p)-'prosrc'-'prosqlbody' INTO attributes_after
      FROM pg_catalog.pg_proc p WHERE p.oid=function_oid;
    IF attributes_before IS DISTINCT FROM attributes_after THEN
        RAISE EXCEPTION 'V982 changed warehouse notice attributes beyond its body';
    END IF;
END $warehouse_notice_union$;
