-- BusinessTime.ZONE is Asia/Shanghai. The month of a stock movement must not
-- change when a JDBC, psql or scheduled refresh uses another session timezone.
-- Keep the existing TIMESTAMPTZ interface and every primary stock fact.
SET LOCAL search_path = pg_catalog, public, pg_temp;
SET LOCAL max_parallel_workers_per_gather = 0;
SET LOCAL jit = off;

DO $stock_business_calendar$
DECLARE
    saved RECORD;
    index_rows JSONB;
    column_rows JSONB;
    old_acl JSONB;
    current_acl JSONB;
    item JSONB;
    grantee_id OID;
    statement TEXT;
    initial_role TEXT := current_user;
    initial_tablespace TEXT := current_setting('default_tablespace');
    switched_role BOOLEAN := FALSE;
    old_columns TEXT[];
    expected_columns TEXT[];
BEGIN
    SELECT c.oid, c.relowner, pg_get_userbyid(c.relowner) AS owner_name,
           c.reloptions, c.relispopulated,
           (SELECT spcname FROM pg_tablespace WHERE oid = c.reltablespace) AS tablespace_name,
           obj_description(c.oid, 'pg_class') AS comment_text,
           pg_get_viewdef(c.oid, TRUE) AS definition
      INTO STRICT saved
      FROM pg_class c
      WHERE c.oid = to_regclass('public.stock_monthly_mv') AND c.relkind = 'm';

    -- A delegated grantor/column ACL needs its own reviewed preservation path;
    -- never silently replace such access rules with migration-owner grants.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'grantor', a.grantor, 'grantee', a.grantee,
               'privilege', a.privilege_type, 'grantable', a.is_grantable)
               ORDER BY a.grantee, a.privilege_type, a.is_grantable), '[]'::jsonb)
      INTO old_acl
      FROM pg_class c,
           LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
      WHERE c.oid = saved.oid;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(old_acl) a
               WHERE (a->>'grantor')::oid <> saved.relowner)
       OR EXISTS (SELECT 1 FROM pg_attribute
                  WHERE attrelid = saved.oid AND attnum > 0 AND NOT attisdropped
                    AND attacl IS NOT NULL) THEN
        RAISE EXCEPTION 'stock month calendar requires an explicit delegated/column ACL preservation plan';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_index
               WHERE indrelid = saved.oid AND (NOT indisvalid OR NOT indisready OR indisreplident)) THEN
        RAISE EXCEPTION 'stock month calendar refuses an invalid or replica-identity index';
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'definition', pg_get_indexdef(i.indexrelid),
               'name', ic.relname, 'comment', obj_description(ic.oid, 'pg_class'),
               'clustered', i.indisclustered) ORDER BY i.indexrelid), '[]'::jsonb)
      INTO index_rows
      FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
      WHERE i.indrelid = saved.oid;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'name', a.attname, 'comment', col_description(a.attrelid, a.attnum),
               'statistics', a.attstattarget, 'options', a.attoptions)
               ORDER BY a.attnum), '[]'::jsonb)
      INTO column_rows FROM pg_attribute a
      WHERE a.attrelid = saved.oid AND a.attnum > 0 AND NOT a.attisdropped;
    SELECT array_agg(format('%s:%s:%s:%s', attname, atttypid, atttypmod, attcollation)
                     ORDER BY attnum)
      INTO old_columns FROM pg_attribute
      WHERE attrelid = saved.oid AND attnum > 0 AND NOT attisdropped;

    IF current_user <> saved.owner_name THEN
        EXECUTE format('SET LOCAL ROLE %I', saved.owner_name);
        switched_role := TRUE;
    END IF;
    -- reltablespace=0 means the database default, not the caller's configured
    -- default_tablespace. Recreate default-space objects in that same default.
    -- Explicit prior view/index tablespaces are preserved by their own DDL.
    PERFORM set_config('default_tablespace', '', TRUE);
    LOCK TABLE public.stock_movements IN SHARE MODE;

    -- Deparse the known prior query with this PostgreSQL version instead of
    -- relying on whitespace, implicit casts or the caller's search_path.
    CREATE TEMP VIEW v921_expected_stock_monthly_legacy AS
      SELECT date_trunc('month', transaction_date) AS ym, movement_type,
             goods_id, warehouse_id, color_id, SUM(qty) AS qty_sum,
             SUM(amount_local) AS amt_local, COUNT(*) AS line_cnt
      FROM public.stock_movements GROUP BY 1,2,3,4,5;
    CREATE TEMP VIEW v921_expected_stock_monthly_fixed AS
      SELECT date_trunc('month', transaction_date, 'Asia/Shanghai') AS ym, movement_type,
             goods_id, warehouse_id, color_id, SUM(qty) AS qty_sum,
             SUM(amount_local) AS amt_local, COUNT(*) AS line_cnt
      FROM public.stock_movements GROUP BY 1,2,3,4,5;
    IF saved.definition IS DISTINCT FROM pg_get_viewdef('pg_temp.v921_expected_stock_monthly_legacy'::regclass, TRUE)
       AND saved.definition IS DISTINCT FROM pg_get_viewdef('pg_temp.v921_expected_stock_monthly_fixed'::regclass, TRUE) THEN
        RAISE EXCEPTION 'stock month calendar found an unexpected existing projection definition';
    END IF;
    SELECT array_agg(format('%s:%s:%s:%s', attname, atttypid, atttypmod, attcollation)
                     ORDER BY attnum)
      INTO expected_columns FROM pg_attribute
      WHERE attrelid = 'pg_temp.v921_expected_stock_monthly_fixed'::regclass
        AND attnum > 0 AND NOT attisdropped;
    IF old_columns IS DISTINCT FROM expected_columns THEN
        RAISE EXCEPTION 'stock month calendar cannot change the projection column interface';
    END IF;

    -- No CASCADE: an unexpected dependent object must reject the transaction.
    DROP MATERIALIZED VIEW public.stock_monthly_mv;
    statement := 'CREATE MATERIALIZED VIEW public.stock_monthly_mv';
    IF COALESCE(array_length(saved.reloptions, 1), 0) > 0 THEN
        statement := statement || ' WITH (' || array_to_string(saved.reloptions, ',') || ')';
    END IF;
    IF saved.tablespace_name IS NOT NULL THEN
        statement := statement || format(' TABLESPACE %I', saved.tablespace_name);
    END IF;
    statement := statement || ' AS SELECT date_trunc(''month'', transaction_date, ''Asia/Shanghai'') AS ym,'
        || ' movement_type, goods_id, warehouse_id, color_id, SUM(qty) AS qty_sum,'
        || ' SUM(amount_local) AS amt_local, COUNT(*) AS line_cnt'
        || ' FROM public.stock_movements GROUP BY 1,2,3,4,5'
        || CASE WHEN saved.relispopulated THEN ' WITH DATA' ELSE ' WITH NO DATA' END;
    EXECUTE statement;
    FOR item IN SELECT value FROM jsonb_array_elements(index_rows) LOOP
        EXECUTE item->>'definition';
        EXECUTE format('COMMENT ON INDEX public.%I IS %L', item->>'name', item->>'comment');
        IF (item->>'clustered')::boolean THEN
            EXECUTE format('ALTER MATERIALIZED VIEW public.stock_monthly_mv CLUSTER ON %I', item->>'name');
        END IF;
    END LOOP;
    EXECUTE format('COMMENT ON MATERIALIZED VIEW public.stock_monthly_mv IS %L', saved.comment_text);
    FOR item IN SELECT value FROM jsonb_array_elements(column_rows) LOOP
        EXECUTE format('COMMENT ON COLUMN public.stock_monthly_mv.%I IS %L', item->>'name', item->>'comment');
        IF (item->>'statistics')::integer >= 0 THEN
            EXECUTE format('ALTER MATERIALIZED VIEW public.stock_monthly_mv ALTER COLUMN %I SET STATISTICS %s',
                           item->>'name', (item->>'statistics')::integer);
        END IF;
        IF jsonb_typeof(item->'options') = 'array' THEN
            SELECT string_agg(value, ',') INTO statement
              FROM jsonb_array_elements_text(item->'options');
            IF statement IS NOT NULL THEN
                EXECUTE format('ALTER MATERIALIZED VIEW public.stock_monthly_mv ALTER COLUMN %I SET (%s)',
                               item->>'name', statement);
            END IF;
        END IF;
    END LOOP;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'grantor', a.grantor, 'grantee', a.grantee,
               'privilege', a.privilege_type, 'grantable', a.is_grantable)
               ORDER BY a.grantee, a.privilege_type, a.is_grantable), '[]'::jsonb)
      INTO current_acl FROM pg_class c,
           LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
      WHERE c.oid = 'public.stock_monthly_mv'::regclass;
    IF current_acl IS DISTINCT FROM old_acl THEN
        FOR grantee_id IN SELECT DISTINCT a.grantee FROM pg_class c,
                 LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
                 WHERE c.oid = 'public.stock_monthly_mv'::regclass LOOP
            EXECUTE 'REVOKE ALL PRIVILEGES ON TABLE public.stock_monthly_mv FROM '
                 || CASE WHEN grantee_id = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(grantee_id)) END
                 || ' CASCADE';
        END LOOP;
        FOR item IN SELECT value FROM jsonb_array_elements(old_acl) LOOP
            EXECUTE 'GRANT ' || (item->>'privilege') || ' ON TABLE public.stock_monthly_mv TO '
                 || CASE WHEN (item->>'grantee')::oid = 0 THEN 'PUBLIC'
                         ELSE quote_ident(pg_get_userbyid((item->>'grantee')::oid)) END
                 || CASE WHEN (item->>'grantable')::boolean THEN ' WITH GRANT OPTION' ELSE '' END;
        END LOOP;
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'grantor', a.grantor, 'grantee', a.grantee,
               'privilege', a.privilege_type, 'grantable', a.is_grantable)
               ORDER BY a.grantee, a.privilege_type, a.is_grantable), '[]'::jsonb)
      INTO current_acl FROM pg_class c,
           LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
      WHERE c.oid = 'public.stock_monthly_mv'::regclass;
    IF current_acl IS DISTINCT FROM old_acl
       OR (SELECT relowner FROM pg_class WHERE oid = 'public.stock_monthly_mv'::regclass) <> saved.relowner
       OR (SELECT relispopulated FROM pg_class WHERE oid = 'public.stock_monthly_mv'::regclass)
            IS DISTINCT FROM saved.relispopulated THEN
        RAISE EXCEPTION 'stock month calendar failed owner/ACL/population preservation';
    END IF;
    DROP VIEW pg_temp.v921_expected_stock_monthly_legacy;
    DROP VIEW pg_temp.v921_expected_stock_monthly_fixed;
    IF switched_role THEN
        EXECUTE format('SET LOCAL ROLE %I', initial_role);
    END IF;
    PERFORM set_config('default_tablespace', initial_tablespace, TRUE);
END;
$stock_business_calendar$;
