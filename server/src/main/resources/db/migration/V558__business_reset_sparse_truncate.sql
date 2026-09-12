-- V558 avoids recreating empty business-table/index files during a reset.
-- The complete CLEAR policy remains locked and counted exactly; FK closure,
-- TRUNCATE triggers, owned sequences and all final business guards are retained.
-- No reset executes during migration. V462/V464 and applied patches stay immutable.
DO $sparse_reset$
DECLARE
    definition TEXT;
    previous_metadata JSONB;
    old_block TEXT := $old$    FOR t IN
        SELECT table_name
        FROM reset_business_table_policy
        WHERE disposition = 'CLEAR'
        ORDER BY table_name
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t.table_name) INTO n;
        cleared_rows_total := cleared_rows_total + n;
    END LOOP;

    INSERT INTO reset_business_summary(cleared_rows)
    VALUES (cleared_rows_total);

    SELECT string_agg(
               format('public.%I', table_name),
               ', '
               ORDER BY table_name
           )
    INTO clear_tables
    FROM reset_business_table_policy
    WHERE disposition = 'CLEAR';

    IF clear_tables IS NULL THEN
        RAISE EXCEPTION 'CLEAR 白名单为空';
    END IF;

    EXECUTE 'TRUNCATE TABLE ' || clear_tables || ' RESTART IDENTITY';$old$;
    new_block TEXT := $new$    -- V558 sparse reset: lock the complete policy before observing exact row counts.
    SELECT string_agg(format('public.%I', table_name), ', ' ORDER BY table_name)
    INTO clear_tables
    FROM reset_business_table_policy WHERE disposition = 'CLEAR';
    IF clear_tables IS NULL THEN
        RAISE EXCEPTION 'CLEAR 白名单为空';
    END IF;
    EXECUTE 'LOCK TABLE ' || clear_tables || ' IN ACCESS EXCLUSIVE MODE';

    DROP TABLE IF EXISTS pg_temp.reset_business_clear_work;
    CREATE TEMP TABLE reset_business_clear_work (
        table_name TEXT PRIMARY KEY,
        table_oid OID NOT NULL UNIQUE,
        row_count BIGINT NOT NULL DEFAULT 0,
        truncate_required BOOLEAN NOT NULL DEFAULT FALSE
    ) ON COMMIT DROP;
    INSERT INTO reset_business_clear_work(table_name, table_oid)
    SELECT policy.table_name, relation.oid
    FROM reset_business_table_policy policy
    JOIN pg_catalog.pg_namespace namespace ON namespace.nspname = 'public'
    JOIN pg_catalog.pg_class relation
      ON relation.relnamespace = namespace.oid AND relation.relname = policy.table_name
    WHERE policy.disposition = 'CLEAR';

    -- LOCK privileges do not replace the original TRUNCATE check. PostgreSQL
    -- checks explicitly listed roots, not recursively included descendants.
    IF EXISTS (SELECT 1 FROM reset_business_clear_work work
               WHERE NOT pg_catalog.has_table_privilege(work.table_oid, 'TRUNCATE')) THEN
        RAISE EXCEPTION '清空范围内存在无 TRUNCATE 权限的业务表' USING ERRCODE = '42501';
    END IF;

    DROP TABLE IF EXISTS pg_temp.reset_business_clear_family;
    CREATE TEMP TABLE reset_business_clear_family (
        root_oid OID NOT NULL,
        member_oid OID NOT NULL,
        PRIMARY KEY(root_oid, member_oid)
    ) ON COMMIT DROP;
    WITH RECURSIVE family(root_oid, member_oid) AS (
        SELECT table_oid, table_oid FROM reset_business_clear_work
        UNION
        SELECT family.root_oid, inheritance.inhrelid FROM family
        JOIN pg_catalog.pg_inherits inheritance ON inheritance.inhparent = family.member_oid
    )
    INSERT INTO reset_business_clear_family SELECT root_oid, member_oid FROM family;
    CREATE INDEX ON reset_business_clear_family(member_oid);

    -- Retain full TRUNCATE RESTRICT even when a referenced table is empty:
    -- external schemas and references to individual partitions also count.
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint foreign_key
        WHERE foreign_key.contype = 'f'
          AND EXISTS (SELECT 1 FROM reset_business_clear_family family
                      WHERE family.member_oid = foreign_key.confrelid)
          AND NOT EXISTS (SELECT 1 FROM reset_business_clear_family family
                          WHERE family.member_oid = foreign_key.conrelid)
    ) THEN
        RAISE EXCEPTION '清空范围外的表仍引用待清业务表或分区，禁止清空' USING ERRCODE = 'UT900';
    END IF;

    FOR t IN SELECT table_name FROM reset_business_clear_work ORDER BY table_name LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', t.table_name) INTO n;
        cleared_rows_total := cleared_rows_total + n;
        UPDATE reset_business_clear_work SET row_count = n WHERE table_name = t.table_name;
    END LOOP;

    -- Traditional inheritance and user TRUNCATE triggers retain the original
    -- full TRUNCATE semantics: a BEFORE trigger may write another empty table.
    -- Partition roots always retain their complete TRUNCATE subtree. Map FK
    -- references on any partition back to its classified root before closure.
    -- Higher isolation can retain an empty snapshot despite a newly committed
    -- row before these locks. Only a full TRUNCATE preserves that old behavior.
    IF current_setting('transaction_isolation') NOT IN ('read committed', 'read uncommitted') OR EXISTS (
        SELECT 1 FROM reset_business_clear_family family WHERE EXISTS (
            SELECT 1 FROM pg_catalog.pg_trigger trigger_row
            WHERE trigger_row.tgrelid = family.member_oid AND NOT trigger_row.tgisinternal
              AND (trigger_row.tgtype & 32) <> 0
        ) OR EXISTS (
            SELECT 1 FROM pg_catalog.pg_inherits inheritance
            JOIN pg_catalog.pg_class child_relation ON child_relation.oid = inheritance.inhrelid
            WHERE family.member_oid IN (inheritance.inhparent, inheritance.inhrelid)
              AND NOT child_relation.relispartition
        )
    ) THEN
        UPDATE reset_business_clear_work SET truncate_required = TRUE;
    ELSE
        WITH RECURSIVE truncate_scope(table_oid) AS (
            SELECT work.table_oid FROM reset_business_clear_work work
            WHERE work.row_count > 0 OR pg_catalog.row_security_active(work.table_oid) OR EXISTS (
                SELECT 1 FROM reset_business_clear_family family
                WHERE family.root_oid = work.table_oid AND family.member_oid <> family.root_oid
            )
            UNION
            SELECT child.root_oid
            FROM truncate_scope parent
            JOIN reset_business_clear_family parent_family ON parent_family.root_oid = parent.table_oid
            JOIN pg_catalog.pg_constraint foreign_key
              ON foreign_key.confrelid = parent_family.member_oid AND foreign_key.contype = 'f'
            JOIN reset_business_clear_family child ON child.member_oid = foreign_key.conrelid
        )
        UPDATE reset_business_clear_work work SET truncate_required = TRUE
        WHERE work.table_oid IN (SELECT table_oid FROM truncate_scope);
    END IF;

    SELECT string_agg(format('public.%I', table_name), ', ' ORDER BY table_name)
    INTO clear_tables FROM reset_business_clear_work WHERE truncate_required;
    IF clear_tables IS NOT NULL THEN
        EXECUTE 'TRUNCATE TABLE ' || clear_tables || ' RESTART IDENTITY';
    END IF;

    -- An empty table can still own an advanced sequence. RESTART (without a
    -- literal start value) preserves seqstart and rolls back with this reset.
    FOR t IN
        SELECT namespace.nspname AS sequence_schema, sequence.relname AS sequence_name
        FROM reset_business_clear_work work
        JOIN pg_catalog.pg_depend dependency
          ON dependency.refobjid = work.table_oid AND dependency.refobjsubid > 0
         AND dependency.classid = 'pg_catalog.pg_class'::regclass
         AND dependency.refclassid = 'pg_catalog.pg_class'::regclass
         AND dependency.deptype IN ('a', 'i')
        JOIN pg_catalog.pg_class sequence
          ON sequence.oid = dependency.objid AND sequence.relkind = 'S'
        JOIN pg_catalog.pg_namespace namespace ON namespace.oid = sequence.relnamespace
        WHERE NOT work.truncate_required
        ORDER BY namespace.nspname, sequence.relname
    LOOP
        EXECUTE format('ALTER SEQUENCE %I.%I RESTART', t.sequence_schema, t.sequence_name);
    END LOOP;
    -- End V558 sparse reset.

    INSERT INTO reset_business_summary(cleared_rows) VALUES (cleared_rows_total);$new$;
BEGIN
    -- Source checkouts may use CRLF; normalize both sides of the exact anchor.
    old_block := replace(old_block, E'\r\n', E'\n');
    new_block := replace(new_block, E'\r\n', E'\n');
    IF (SELECT max(version::integer) FROM public.flyway_schema_history
        WHERE success AND version ~ '^[0-9]+$') <> 557
       OR (SELECT count(*) FROM public.flyway_schema_history WHERE success AND type = 'SQL') <> 515 THEN
        RAISE EXCEPTION 'V558 requires the complete V557/515 migration catalog';
    END IF;
    SELECT jsonb_build_array(proowner, prosecdef, proconfig, proacl),
           replace(pg_catalog.pg_get_functiondef(oid), E'\r\n', E'\n')
    INTO previous_metadata, definition
    FROM pg_catalog.pg_proc WHERE oid = 'public.business_data_reset()'::regprocedure;
    IF definition IS NULL OR position(old_block IN definition) = 0
       OR (length(definition) - length(replace(definition, old_block, ''))) <> length(old_block) THEN
        RAISE EXCEPTION 'V558 reset count/truncate anchor differs from the reviewed V557 function';
    END IF;
    EXECUTE replace(definition, old_block, new_block);
    IF previous_metadata IS DISTINCT FROM (
        SELECT jsonb_build_array(proowner, prosecdef, proconfig, proacl)
        FROM pg_catalog.pg_proc WHERE oid = 'public.business_data_reset()'::regprocedure
    ) THEN
        RAISE EXCEPTION 'V558 changed reset function ownership, security, configuration or grants';
    END IF;
END;
$sparse_reset$;
