-- Candidate only: publish after the service, guards and real PostgreSQL matrix pass.
-- Commercial consideration is separate from physical inventory custody value.
-- No historic payable, receipt amount or unclassified allocation is rewritten.

-- Validation only. No typmod, rounding, trimming or replacement of the value.
CREATE OR REPLACE FUNCTION fn_financial_amount_is_exact(p_value NUMERIC)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT CASE WHEN p_value IN ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)
        THEN FALSE
        ELSE abs(p_value)<1e40::numeric AND scale(trim_scale(p_value))<=24 END
$$;

CREATE OR REPLACE FUNCTION fn_financial_book_amount_is_exact(p_value NUMERIC)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT CASE WHEN p_value IN ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)
        THEN FALSE ELSE abs(p_value)<1e40::numeric AND scale(trim_scale(p_value))<=30 END
$$;

CREATE OR REPLACE FUNCTION fn_migrate_financial_amount_columns(p_targets JSONB)
RETURNS JSONB LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp
AS $$
DECLARE
    v_target RECORD;
    v_view RECORD;
    v_column RECORD;
    v_acl RECORD;
    v_index RECORD;
    v_trigger RECORD;
    v_name TEXT;
    v_sql TEXT;
    v_options TEXT;
    v_check_option TEXT;
    v_columns TEXT;
    v_constraint TEXT;
    v_original_role TEXT:=current_setting('role');
    v_current_acl JSONB;
    v_result JSONB;
    v_updated INTEGER;
BEGIN
    IF p_targets IS NULL OR jsonb_typeof(p_targets)<>'array'
       OR jsonb_array_length(p_targets) NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'financial amount migration requires 1..200 explicit column targets' USING ERRCODE='22023';
    END IF;
    CREATE TEMP TABLE IF NOT EXISTS pg_temp.financial_exact_targets(
        relid OID NOT NULL,attnum SMALLINT NOT NULL,schema_name TEXT NOT NULL,
        table_name TEXT NOT NULL,column_name TEXT NOT NULL,amount_kind TEXT NOT NULL,PRIMARY KEY(relid,attnum)) ON COMMIT DROP;
    CREATE TEMP TABLE IF NOT EXISTS pg_temp.financial_exact_views(
        relid OID PRIMARY KEY,schema_name TEXT NOT NULL,view_name TEXT NOT NULL,
        kind "char" NOT NULL,depth INTEGER NOT NULL,definition TEXT NOT NULL,
        owner_name TEXT NOT NULL,owner_oid OID NOT NULL,options TEXT[],populated BOOLEAN NOT NULL,
        tablespace_name TEXT,access_method TEXT,description TEXT,effective_acl JSONB NOT NULL) ON COMMIT DROP;
    CREATE TEMP TABLE IF NOT EXISTS pg_temp.financial_exact_view_columns(
        relid OID NOT NULL,ordinal SMALLINT NOT NULL,column_name TEXT NOT NULL,description TEXT,
        PRIMARY KEY(relid,ordinal)) ON COMMIT DROP;
    CREATE TEMP TABLE IF NOT EXISTS pg_temp.financial_exact_view_indexes(
        relid OID NOT NULL,index_oid OID NOT NULL,index_name TEXT NOT NULL,
        definition TEXT NOT NULL,description TEXT,clustered BOOLEAN NOT NULL,PRIMARY KEY(index_oid)) ON COMMIT DROP;
    CREATE TEMP TABLE IF NOT EXISTS pg_temp.financial_exact_base_triggers(
        trigger_oid OID PRIMARY KEY,schema_name TEXT NOT NULL,table_name TEXT NOT NULL,trigger_name TEXT NOT NULL,
        definition TEXT NOT NULL,enabled "char" NOT NULL,description TEXT) ON COMMIT DROP;
    TRUNCATE pg_temp.financial_exact_targets,pg_temp.financial_exact_views,
        pg_temp.financial_exact_view_columns,pg_temp.financial_exact_view_indexes,pg_temp.financial_exact_base_triggers;

    INSERT INTO pg_temp.financial_exact_targets
    SELECT relation.oid,attribute.attnum,namespace.nspname,relation.relname,attribute.attname,
        COALESCE(entry->>'kind',CASE WHEN attribute.attname LIKE '%local%'
            OR attribute.attname IN ('amount_balance','amount_settled') THEN 'book' ELSE 'actual' END)
    FROM jsonb_array_elements(p_targets) entry
    JOIN pg_namespace namespace ON namespace.nspname=COALESCE(entry->>'schema','public')
    JOIN pg_class relation ON relation.relnamespace=namespace.oid AND relation.relname=entry->>'table'
      AND relation.relkind IN ('r','p')
    JOIN pg_attribute attribute ON attribute.attrelid=relation.oid AND attribute.attname=entry->>'column'
      AND attribute.attnum>0 AND NOT attribute.attisdropped AND attribute.atttypid='numeric'::regtype;
    IF (SELECT COUNT(*) FROM pg_temp.financial_exact_targets)<>jsonb_array_length(p_targets) THEN
        RAISE EXCEPTION 'financial amount target is missing, duplicated or not a numeric table column' USING ERRCODE='22023';
    END IF;
    IF EXISTS(SELECT 1 FROM pg_temp.financial_exact_targets WHERE amount_kind NOT IN ('actual','book')) THEN
        RAISE EXCEPTION 'financial amount kind must be actual or book' USING ERRCODE='22023';
    END IF;

    -- Lock the explicitly selected sources before discovering their dependent views.
    FOR v_target IN SELECT DISTINCT schema_name,table_name FROM pg_temp.financial_exact_targets
        ORDER BY schema_name,table_name
    LOOP
        EXECUTE format('LOCK TABLE %I.%I IN ACCESS EXCLUSIVE MODE',v_target.schema_name,v_target.table_name);
    END LOOP;

    IF EXISTS(SELECT 1 FROM pg_depend dependency
        JOIN pg_temp.financial_exact_targets target ON dependency.refobjid=target.relid AND dependency.refobjsubid=target.attnum
        JOIN pg_trigger trigger ON dependency.classid='pg_trigger'::regclass AND dependency.objid=trigger.oid
        WHERE trigger.tgisinternal OR trigger.tgparentid<>0 OR trigger.tgenabled='D') THEN
        RAISE EXCEPTION 'financial amount migration refuses internal, inherited or disabled column-dependent triggers' USING ERRCODE='0A000';
    END IF;
    INSERT INTO pg_temp.financial_exact_base_triggers
    SELECT DISTINCT trigger.oid,namespace.nspname,relation.relname,trigger.tgname,
        pg_get_triggerdef(trigger.oid,TRUE),trigger.tgenabled,obj_description(trigger.oid,'pg_trigger')
    FROM pg_depend dependency
    JOIN pg_temp.financial_exact_targets target ON dependency.refobjid=target.relid AND dependency.refobjsubid=target.attnum
    JOIN pg_trigger trigger ON dependency.classid='pg_trigger'::regclass AND dependency.objid=trigger.oid
    JOIN pg_class relation ON relation.oid=trigger.tgrelid
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace;

    WITH RECURSIVE dependents(relid) AS (
        SELECT rewrite.ev_class
        FROM pg_depend dependency
        JOIN pg_temp.financial_exact_targets target ON dependency.refobjid=target.relid
          AND dependency.refobjsubid=target.attnum
        JOIN pg_rewrite rewrite ON dependency.classid='pg_rewrite'::regclass AND dependency.objid=rewrite.oid
        JOIN pg_class view_relation ON view_relation.oid=rewrite.ev_class AND view_relation.relkind IN ('v','m')
        WHERE rewrite.ev_class<>target.relid
        UNION
        SELECT rewrite.ev_class
        FROM dependents parent
        JOIN pg_depend dependency ON dependency.refclassid='pg_class'::regclass AND dependency.refobjid=parent.relid
        JOIN pg_rewrite rewrite ON dependency.classid='pg_rewrite'::regclass AND dependency.objid=rewrite.oid
        JOIN pg_class view_relation ON view_relation.oid=rewrite.ev_class AND view_relation.relkind IN ('v','m')
        WHERE rewrite.ev_class<>parent.relid
    )
    INSERT INTO pg_temp.financial_exact_views
    SELECT relation.oid,namespace.nspname,relation.relname,relation.relkind,0,
           pg_get_viewdef(relation.oid,TRUE),pg_get_userbyid(relation.relowner),relation.relowner,
           relation.reloptions,relation.relispopulated,tablespace.spcname,access_method.amname,
           obj_description(relation.oid,'pg_class'),
           COALESCE((SELECT jsonb_agg(jsonb_build_object('grantor',acl.grantor,'grantee',acl.grantee,
               'privilege',acl.privilege_type,'grantable',acl.is_grantable)
               ORDER BY acl.grantor,acl.grantee,acl.privilege_type,acl.is_grantable)
               FROM aclexplode(COALESCE(relation.relacl,acldefault('r',relation.relowner))) acl),'[]'::jsonb)
    FROM dependents JOIN pg_class relation ON relation.oid=dependents.relid
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    LEFT JOIN pg_tablespace tablespace ON tablespace.oid=relation.reltablespace
    LEFT JOIN pg_am access_method ON access_method.oid=relation.relam;

    LOOP
        WITH ready AS (
            SELECT child.relid,1+COALESCE(MAX(parent.depth),0) depth
            FROM pg_temp.financial_exact_views child
            LEFT JOIN pg_rewrite rewrite ON rewrite.ev_class=child.relid
            LEFT JOIN pg_depend dependency ON dependency.classid='pg_rewrite'::regclass AND dependency.objid=rewrite.oid
            LEFT JOIN pg_temp.financial_exact_views parent ON parent.relid=dependency.refobjid AND parent.relid<>child.relid
            WHERE child.depth=0 GROUP BY child.relid
            HAVING COALESCE(BOOL_AND(parent.depth>0) FILTER(WHERE parent.relid IS NOT NULL),TRUE)
        ) UPDATE pg_temp.financial_exact_views child SET depth=ready.depth FROM ready WHERE child.relid=ready.relid;
        GET DIAGNOSTICS v_updated=ROW_COUNT;
        EXIT WHEN v_updated=0;
    END LOOP;
    IF EXISTS(SELECT 1 FROM pg_temp.financial_exact_views WHERE depth=0) THEN
        RAISE EXCEPTION 'financial amount migration refuses a cyclic view dependency graph' USING ERRCODE='0A000';
    END IF;

    FOR v_view IN SELECT * FROM pg_temp.financial_exact_views ORDER BY schema_name,view_name
    LOOP
        IF v_view.kind='m' THEN
            -- PostgreSQL does not support LOCK TABLE on materialized views.
            -- Moving to the current schema is a no-op DDL taking the same lock.
            EXECUTE format('ALTER MATERIALIZED VIEW %I.%I SET SCHEMA %I',
                v_view.schema_name,v_view.view_name,v_view.schema_name);
        ELSE
            EXECUTE format('LOCK TABLE %I.%I IN ACCESS EXCLUSIVE MODE',v_view.schema_name,v_view.view_name);
        END IF;
        IF format('%I.%I',v_view.schema_name,v_view.view_name)::regclass::oid<>v_view.relid
           OR NOT EXISTS(SELECT 1 FROM pg_locks WHERE pid=pg_backend_pid() AND relation=v_view.relid
                AND granted AND mode='AccessExclusiveLock') THEN
            RAISE EXCEPTION 'dependent view identity or lock changed during amount migration' USING ERRCODE='40001';
        END IF;
        UPDATE pg_temp.financial_exact_views saved SET definition=pg_get_viewdef(relation.oid,TRUE),
            owner_name=pg_get_userbyid(relation.relowner),owner_oid=relation.relowner,
            options=relation.reloptions,populated=relation.relispopulated,
            description=obj_description(relation.oid,'pg_class'),
            effective_acl=COALESCE((SELECT jsonb_agg(jsonb_build_object('grantor',acl.grantor,'grantee',acl.grantee,
                'privilege',acl.privilege_type,'grantable',acl.is_grantable)
                ORDER BY acl.grantor,acl.grantee,acl.privilege_type,acl.is_grantable)
                FROM aclexplode(COALESCE(relation.relacl,acldefault('r',relation.relowner))) acl),'[]'::jsonb)
        FROM pg_class relation WHERE saved.relid=v_view.relid AND relation.oid=saved.relid;
        SELECT * INTO v_view FROM pg_temp.financial_exact_views WHERE relid=v_view.relid;
        IF EXISTS(SELECT 1 FROM pg_rewrite WHERE ev_class=v_view.relid AND rulename<>'_RETURN')
           OR EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=v_view.relid AND NOT tgisinternal)
           OR EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=v_view.relid AND attnum>0
                AND (attacl IS NOT NULL OR attoptions IS NOT NULL OR attfdwoptions IS NOT NULL
                     OR attisdropped OR attstattarget<>-1))
           OR EXISTS(SELECT 1 FROM pg_seclabel WHERE classoid='pg_class'::regclass AND objoid=v_view.relid) THEN
            RAISE EXCEPTION 'financial amount migration refuses unsupported rule, trigger, column ACL/options/statistics or security label on %.%',
                v_view.schema_name,v_view.view_name USING ERRCODE='0A000';
        END IF;
        IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_view.effective_acl) acl
            WHERE (acl->>'grantor')::oid<>v_view.owner_oid) THEN
            RAISE EXCEPTION 'financial amount migration refuses delegated ACL grantors on %.%; explicitly migrate that grant chain first',
                v_view.schema_name,v_view.view_name USING ERRCODE='0A000';
        END IF;
        IF EXISTS(SELECT 1 FROM pg_class WHERE oid=v_view.relid AND (relrowsecurity OR relforcerowsecurity)) THEN
            RAISE EXCEPTION 'financial amount migration refuses unhandled row security on %.%',
                v_view.schema_name,v_view.view_name USING ERRCODE='0A000';
        END IF;
        IF v_view.kind='m' AND EXISTS(SELECT 1 FROM pg_index WHERE indrelid=v_view.relid
            AND (NOT indisvalid OR NOT indisready OR indisreplident)) THEN
            RAISE EXCEPTION 'financial amount migration refuses incomplete or replica-identity indexes on %.%',
                v_view.schema_name,v_view.view_name USING ERRCODE='0A000';
        END IF;
        IF EXISTS(SELECT 1 FROM pg_options_to_table(v_view.options)
            WHERE option_name!~'^[a-zA-Z_][a-zA-Z_0-9.]*$'
               OR (v_view.kind='v' AND option_name NOT IN ('check_option','security_barrier','security_invoker'))
               OR (option_name='check_option' AND option_value NOT IN ('local','cascaded'))) THEN
            RAISE EXCEPTION 'financial amount migration refuses unsupported view options on %.%',
                v_view.schema_name,v_view.view_name USING ERRCODE='0A000';
        END IF;
        INSERT INTO pg_temp.financial_exact_view_columns
        SELECT v_view.relid,attnum,attname,col_description(v_view.relid,attnum)
        FROM pg_attribute WHERE attrelid=v_view.relid AND attnum>0 AND NOT attisdropped;
        INSERT INTO pg_temp.financial_exact_view_indexes
        SELECT v_view.relid,index_relation.oid,index_relation.relname,pg_get_indexdef(index_relation.oid),
               obj_description(index_relation.oid,'pg_class'),index_definition.indisclustered
        FROM pg_index index_definition JOIN pg_class index_relation ON index_relation.oid=index_definition.indexrelid
        WHERE index_definition.indrelid=v_view.relid;
    END LOOP;

    -- Reject any cycle before dropping; a ready node depends only on earlier depths.
    IF EXISTS(SELECT 1 FROM pg_temp.financial_exact_views child
        JOIN pg_rewrite rewrite ON rewrite.ev_class=child.relid
        JOIN pg_depend dependency ON dependency.classid='pg_rewrite'::regclass AND dependency.objid=rewrite.oid
        JOIN pg_temp.financial_exact_views parent ON parent.relid=dependency.refobjid
        WHERE parent.relid<>child.relid AND parent.depth>=child.depth) THEN
        RAISE EXCEPTION 'financial amount migration refuses a cyclic view dependency graph' USING ERRCODE='0A000';
    END IF;

    SELECT jsonb_build_object('columns',(SELECT jsonb_agg(jsonb_build_object(
            'schema',schema_name,'table',table_name,'column',column_name) ORDER BY schema_name,table_name,column_name)
        FROM pg_temp.financial_exact_targets),'views',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'schema',schema_name,'name',view_name,'kind',kind,'depth',depth) ORDER BY depth,schema_name,view_name)
        FROM pg_temp.financial_exact_views),'[]'::jsonb),'columnTriggers',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'schema',schema_name,'table',table_name,'name',trigger_name,'enabled',enabled)
            ORDER BY schema_name,table_name,trigger_name) FROM pg_temp.financial_exact_base_triggers),'[]'::jsonb)) INTO v_result;

    FOR v_view IN SELECT * FROM pg_temp.financial_exact_views ORDER BY depth DESC,schema_name,view_name
    LOOP
        EXECUTE format('DROP %s %I.%I RESTRICT',CASE WHEN v_view.kind='m' THEN 'MATERIALIZED VIEW' ELSE 'VIEW' END,
            v_view.schema_name,v_view.view_name);
    END LOOP;
    FOR v_trigger IN SELECT * FROM pg_temp.financial_exact_base_triggers ORDER BY schema_name,table_name,trigger_name
    LOOP
        EXECUTE format('DROP TRIGGER %I ON %I.%I RESTRICT',v_trigger.trigger_name,v_trigger.schema_name,v_trigger.table_name);
    END LOOP;
    FOR v_target IN SELECT * FROM pg_temp.financial_exact_targets ORDER BY schema_name,table_name,column_name
    LOOP
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I TYPE NUMERIC',
            v_target.schema_name,v_target.table_name,v_target.column_name);
        v_constraint:='ck_financial_exact_'||substr(md5(v_target.schema_name||'.'||v_target.table_name||'.'||v_target.column_name),1,24);
        EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (public.%I(%I))',
            v_target.schema_name,v_target.table_name,v_constraint,
            CASE v_target.amount_kind WHEN 'book' THEN 'fn_financial_book_amount_is_exact' ELSE 'fn_financial_amount_is_exact' END,
            v_target.column_name);
    END LOOP;

    -- Restore every original row guard before any materialized view is populated.
    -- There are no business-row INSERT/UPDATE/DELETE operations in this window.
    FOR v_trigger IN SELECT * FROM pg_temp.financial_exact_base_triggers ORDER BY schema_name,table_name,trigger_name
    LOOP
        EXECUTE v_trigger.definition;
        IF v_trigger.enabled='A' THEN
            EXECUTE format('ALTER TABLE %I.%I ENABLE ALWAYS TRIGGER %I',v_trigger.schema_name,v_trigger.table_name,v_trigger.trigger_name);
        ELSIF v_trigger.enabled='R' THEN
            EXECUTE format('ALTER TABLE %I.%I ENABLE REPLICA TRIGGER %I',v_trigger.schema_name,v_trigger.table_name,v_trigger.trigger_name);
        ELSIF v_trigger.enabled<>'O' THEN
            RAISE EXCEPTION 'unsupported trigger enable mode' USING ERRCODE='0A000';
        END IF;
        EXECUTE format('COMMENT ON TRIGGER %I ON %I.%I IS %L',v_trigger.trigger_name,v_trigger.schema_name,v_trigger.table_name,v_trigger.description);
    END LOOP;

    FOR v_view IN SELECT * FROM pg_temp.financial_exact_views ORDER BY depth,schema_name,view_name
    LOOP
        SELECT string_agg(format('%I',column_name),',' ORDER BY ordinal) INTO v_columns
        FROM pg_temp.financial_exact_view_columns WHERE relid=v_view.relid;
        SELECT string_agg(format('%s=%L',option_name,option_value),',' ORDER BY option_name),
               MAX(option_value) FILTER(WHERE option_name='check_option')
        INTO v_options,v_check_option
        FROM pg_options_to_table(v_view.options) WHERE option_name<>'check_option';
        SELECT option_value INTO v_check_option FROM pg_options_to_table(v_view.options) WHERE option_name='check_option';
        IF EXISTS(SELECT 1 FROM pg_options_to_table(v_view.options)
            WHERE option_name!~'^[a-zA-Z_][a-zA-Z_0-9.]*$') THEN
            RAISE EXCEPTION 'unsupported view storage option on %.%',v_view.schema_name,v_view.view_name USING ERRCODE='0A000';
        END IF;
        v_sql:=format('CREATE %s %I.%I (%s)',CASE WHEN v_view.kind='m' THEN 'MATERIALIZED VIEW' ELSE 'VIEW' END,
            v_view.schema_name,v_view.view_name,v_columns);
        IF v_view.kind='m' AND v_view.access_method IS NOT NULL THEN
            v_sql:=v_sql||format(' USING %I',v_view.access_method);
        END IF;
        IF v_options IS NOT NULL THEN v_sql:=v_sql||' WITH ('||v_options||')'; END IF;
        IF v_view.kind='m' AND v_view.tablespace_name IS NOT NULL THEN
            v_sql:=v_sql||format(' TABLESPACE %I',v_view.tablespace_name);
        END IF;
        v_sql:=v_sql||' AS '||regexp_replace(v_view.definition,';[[:space:]]*$','');
        IF v_view.kind='m' THEN v_sql:=v_sql||CASE WHEN v_view.populated THEN ' WITH DATA' ELSE ' WITH NO DATA' END;
        ELSIF v_check_option IS NOT NULL THEN
            IF v_check_option NOT IN ('local','cascaded') THEN
                RAISE EXCEPTION 'unsupported view check option on %.%',v_view.schema_name,v_view.view_name USING ERRCODE='0A000';
            END IF;
            v_sql:=v_sql||' WITH '||upper(v_check_option)||' CHECK OPTION';
        END IF;
        EXECUTE v_sql;
        EXECUTE format('ALTER %s %I.%I OWNER TO %I',CASE WHEN v_view.kind='m' THEN 'MATERIALIZED VIEW' ELSE 'VIEW' END,
            v_view.schema_name,v_view.view_name,v_view.owner_name);
        EXECUTE format('COMMENT ON %s %I.%I IS %L',CASE WHEN v_view.kind='m' THEN 'MATERIALIZED VIEW' ELSE 'VIEW' END,
            v_view.schema_name,v_view.view_name,v_view.description);
        FOR v_column IN SELECT * FROM pg_temp.financial_exact_view_columns WHERE relid=v_view.relid ORDER BY ordinal
        LOOP
            EXECUTE format('COMMENT ON COLUMN %I.%I.%I IS %L',v_view.schema_name,v_view.view_name,
                v_column.column_name,v_column.description);
        END LOOP;
        FOR v_index IN SELECT * FROM pg_temp.financial_exact_view_indexes WHERE relid=v_view.relid ORDER BY index_name
        LOOP
            EXECUTE v_index.definition;
            EXECUTE format('COMMENT ON INDEX %I.%I IS %L',v_view.schema_name,v_index.index_name,v_index.description);
            IF v_index.clustered THEN EXECUTE format('ALTER MATERIALIZED VIEW %I.%I CLUSTER ON %I',
                v_view.schema_name,v_view.view_name,v_index.index_name); END IF;
        END LOOP;

        SELECT COALESCE(jsonb_agg(jsonb_build_object('grantor',acl.grantor,'grantee',acl.grantee,
            'privilege',acl.privilege_type,'grantable',acl.is_grantable)
            ORDER BY acl.grantor,acl.grantee,acl.privilege_type,acl.is_grantable),'[]'::jsonb)
        INTO v_current_acl FROM pg_class relation
        CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl,acldefault('r',relation.relowner))) acl
        WHERE relation.oid=format('%I.%I',v_view.schema_name,v_view.view_name)::regclass;
        IF v_current_acl IS DISTINCT FROM v_view.effective_acl THEN
            -- Only owner-granted ACLs are admitted above, so no grant provenance is invented.
            EXECUTE format('SET LOCAL ROLE %I',v_view.owner_name);
            FOR v_acl IN SELECT DISTINCT acl->>'grantee' grantee FROM jsonb_array_elements(v_current_acl) acl
            LOOP
                v_name:=CASE WHEN v_acl.grantee::oid=0 THEN 'PUBLIC' ELSE format('%I',pg_get_userbyid(v_acl.grantee::oid)) END;
                EXECUTE format('REVOKE ALL PRIVILEGES ON TABLE %I.%I FROM %s RESTRICT',v_view.schema_name,v_view.view_name,v_name);
            END LOOP;
            FOR v_acl IN SELECT acl->>'grantee' grantee,acl->>'privilege' privilege,(acl->>'grantable')::boolean grantable
                FROM jsonb_array_elements(v_view.effective_acl) acl
            LOOP
                IF v_acl.privilege NOT IN ('SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN') THEN
                    RAISE EXCEPTION 'unsupported view privilege %',v_acl.privilege USING ERRCODE='0A000';
                END IF;
                v_name:=CASE WHEN v_acl.grantee::oid=0 THEN 'PUBLIC' ELSE format('%I',pg_get_userbyid(v_acl.grantee::oid)) END;
                EXECUTE format('GRANT %s ON TABLE %I.%I TO %s%s',v_acl.privilege,v_view.schema_name,v_view.view_name,v_name,
                    CASE WHEN v_acl.grantable THEN ' WITH GRANT OPTION' ELSE '' END);
            END LOOP;
            IF v_original_role='none' THEN EXECUTE 'SET LOCAL ROLE NONE';
            ELSE EXECUTE format('SET LOCAL ROLE %I',v_original_role); END IF;
        END IF;
    END LOOP;
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION fn_migrate_financial_amount_columns(JSONB) FROM PUBLIC;

-- Explicit financial columns only; quantities, price and rate input definitions remain.
SELECT fn_migrate_financial_amount_columns('[
 {"table":"purchase_orders","column":"total_original"},
 {"table":"purchase_orders","column":"total_local"},
 {"table":"subcontract_orders","column":"total_original"},
 {"table":"subcontract_orders","column":"total_local"},
 {"table":"purchase_receipts","column":"total_original"},
 {"table":"purchase_receipts","column":"total_local"},
 {"table":"subcontract_receipts","column":"total_original"},
 {"table":"subcontract_receipts","column":"total_local"},
 {"table":"purchase_order_items","column":"amount_original"},
 {"table":"purchase_order_items","column":"amount_local"},
 {"table":"subcontract_order_items","column":"amount_original"},
 {"table":"subcontract_order_items","column":"amount_local"},
 {"table":"purchase_receipt_items","column":"amount_original"},
 {"table":"purchase_receipt_items","column":"amount_local"},
 {"table":"subcontract_receipt_items","column":"amount_original"},
 {"table":"subcontract_receipt_items","column":"amount_local"},
 {"table":"procurement_order_approval_cases","column":"amount_snapshot"},
 {"table":"purchase_order_items","column":"price"},
 {"table":"subcontract_order_items","column":"price"},
 {"table":"purchase_receipt_items","column":"price"},
 {"table":"subcontract_receipt_items","column":"price"}
]'::jsonb);

-- Existing IQC nominal projections retain their values. Future non-finite
-- shares are NULL with their receipt/failure/quantity basis, never rounded zero.
SELECT fn_migrate_financial_amount_columns('[
 {"table":"procurement_iqc_rejection_cases","column":"received_amount_original"},
 {"table":"procurement_iqc_rejection_cases","column":"received_amount_local"},
 {"table":"procurement_iqc_rejection_cases","column":"failed_amount_original"},
 {"table":"procurement_iqc_rejection_cases","column":"failed_amount_local"},
 {"table":"procurement_iqc_replacement_allocations","column":"allocated_amount_original"},
 {"table":"procurement_iqc_replacement_allocations","column":"allocated_amount_local"}
]'::jsonb);
ALTER TABLE procurement_iqc_rejection_cases ALTER COLUMN failed_amount_original DROP NOT NULL,
    ALTER COLUMN failed_amount_local DROP NOT NULL;
ALTER TABLE procurement_iqc_rejection_cases ADD CONSTRAINT iqc_nonfinite_is_not_zero_credit
    CHECK (status<>'CLOSED_NO_CREDIT' OR (failed_amount_original IS NOT NULL AND failed_amount_local IS NOT NULL));
ALTER TABLE procurement_iqc_replacement_allocations ALTER COLUMN allocated_amount_original DROP NOT NULL,
    ALTER COLUMN allocated_amount_local DROP NOT NULL;

DO $$
DECLARE v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['purchase_order_items','subcontract_order_items','purchase_receipt_items','subcontract_receipt_items']
    LOOP
        EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I CHECK (abs(price)<1e14::numeric AND scale(trim_scale(price))<=10)',
            v_table,v_table||'_price_exact_input');
    END LOOP;
END;
$$;
CREATE TABLE procurement_receipt_consideration_parts (
    id UUID PRIMARY KEY,
    receipt_type VARCHAR(20) NOT NULL CHECK (receipt_type IN ('PURCHASE','SUBCONTRACT')),
    receipt_id UUID NOT NULL,
    receipt_item_id UUID NOT NULL,
    billing_mode VARCHAR(24) NOT NULL CHECK (billing_mode IN ('STANDARD','NO_CHARGE','CREDIT_REPURCHASE')),
    replacement_allocation_id UUID REFERENCES procurement_iqc_replacement_allocations(id) ON DELETE RESTRICT,
    funding_slice_id UUID,
    credit_slice_id UUID,
    base_qty NUMERIC(18,4) NOT NULL CHECK (base_qty>0),
    nominal_original NUMERIC CHECK (nominal_original>=0),
    nominal_local NUMERIC CHECK (nominal_local>=0),
    payable_original NUMERIC NOT NULL CHECK (payable_original>=0 AND payable_original<=nominal_original),
    payable_local NUMERIC NOT NULL CHECK (payable_local>=0 AND payable_local<=nominal_local),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CHECK ((billing_mode='STANDARD' AND replacement_allocation_id IS NULL
              AND funding_slice_id IS NULL AND credit_slice_id IS NULL
              AND nominal_original IS NOT NULL AND nominal_local IS NOT NULL
              AND payable_original=nominal_original AND payable_local=nominal_local)
        OR (billing_mode='NO_CHARGE' AND replacement_allocation_id IS NOT NULL
              AND funding_slice_id IS NOT NULL AND credit_slice_id IS NULL
              AND payable_original=0 AND payable_local=0)
        OR (billing_mode='CREDIT_REPURCHASE' AND replacement_allocation_id IS NOT NULL
              AND funding_slice_id IS NOT NULL AND credit_slice_id IS NOT NULL
              AND nominal_original IS NOT NULL AND nominal_local IS NOT NULL
              AND payable_original=nominal_original AND payable_local=nominal_local))
);
CREATE INDEX idx_procurement_consideration_receipt
    ON procurement_receipt_consideration_parts(receipt_type,receipt_id,receipt_item_id,id);
CREATE INDEX idx_procurement_consideration_funding
    ON procurement_receipt_consideration_parts(funding_slice_id,id) WHERE funding_slice_id IS NOT NULL;
CREATE INDEX idx_procurement_consideration_allocation
    ON procurement_receipt_consideration_parts(replacement_allocation_id,id) WHERE replacement_allocation_id IS NOT NULL;

CREATE TABLE procurement_iqc_quality_consideration_parts (
    id UUID PRIMARY KEY,
    inspection_event_id UUID NOT NULL REFERENCES procurement_inspection_events(id) ON DELETE RESTRICT,
    consideration_part_id UUID NOT NULL REFERENCES procurement_receipt_consideration_parts(id) ON DELETE RESTRICT,
    base_qty NUMERIC(18,4) NOT NULL CHECK (base_qty>0),
    amount_original NUMERIC CHECK (amount_original>=0),
    amount_local NUMERIC CHECK (amount_local>=0),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(inspection_event_id,consideration_part_id)
);
CREATE INDEX idx_procurement_quality_consideration_part
    ON procurement_iqc_quality_consideration_parts(consideration_part_id,inspection_event_id,id);

CREATE TABLE procurement_iqc_funding_slices (
    id UUID PRIMARY KEY,
    case_id UUID NOT NULL REFERENCES procurement_iqc_rejection_cases(id) ON DELETE RESTRICT,
    quality_part_id UUID NOT NULL UNIQUE REFERENCES procurement_iqc_quality_consideration_parts(id) ON DELETE RESTRICT,
    parent_funding_slice_id UUID REFERENCES procurement_iqc_funding_slices(id) ON DELETE RESTRICT,
    root_funding_slice_id UUID NOT NULL REFERENCES procurement_iqc_funding_slices(id) DEFERRABLE INITIALLY DEFERRED,
    root_case_id UUID NOT NULL REFERENCES procurement_iqc_rejection_cases(id) ON DELETE RESTRICT,
    root_receipt_item_id UUID NOT NULL,
    source_ap_ledger_id UUID REFERENCES ar_ap_ledger(id) ON DELETE RESTRICT,
    base_qty NUMERIC(18,4) NOT NULL CHECK (base_qty>0),
    amount_original NUMERIC CHECK (amount_original>=0),
    amount_local NUMERIC CHECK (amount_local>=0),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CHECK ((parent_funding_slice_id IS NULL AND root_funding_slice_id=id AND root_case_id=case_id)
        OR (parent_funding_slice_id IS NOT NULL AND parent_funding_slice_id<>id AND root_funding_slice_id<>id))
);
CREATE INDEX idx_procurement_iqc_funding_case ON procurement_iqc_funding_slices(case_id,id);
CREATE INDEX idx_procurement_iqc_funding_root ON procurement_iqc_funding_slices(root_funding_slice_id,id);
CREATE INDEX idx_procurement_iqc_funding_ap ON procurement_iqc_funding_slices(source_ap_ledger_id,id)
    WHERE source_ap_ledger_id IS NOT NULL;

CREATE TABLE procurement_iqc_credit_documents (
    id UUID PRIMARY KEY,
    command_id UUID NOT NULL,
    case_id UUID NOT NULL REFERENCES procurement_iqc_rejection_cases(id) ON DELETE RESTRICT,
    case_version BIGINT NOT NULL CHECK (case_version>0),
    source_ap_ledger_id UUID NOT NULL REFERENCES ar_ap_ledger(id) ON DELETE RESTRICT,
    document_kind VARCHAR(24) NOT NULL CHECK (document_kind='SUPPLIER_CREDIT'),
    approved_source_version VARCHAR(100) NOT NULL CHECK (btrim(approved_source_version)<>''),
    approved_source_hash CHAR(64) NOT NULL CHECK (approved_source_hash~'^[0-9a-f]{64}$'),
    book_allocation_plan JSONB NOT NULL CHECK (jsonb_typeof(book_allocation_plan)='object'),
    base_qty NUMERIC(18,4) NOT NULL CHECK (base_qty>0),
    amount_original NUMERIC NOT NULL CHECK (amount_original>=0),
    amount_local NUMERIC NOT NULL CHECK (amount_local>=0),
    effective_date DATE NOT NULL,
    credit_reference VARCHAR(200) NOT NULL CHECK (btrim(credit_reference)<>''),
    reason VARCHAR(2000) NOT NULL CHECK (btrim(reason)<>''),
    approved_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    approved_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(command_id,source_ap_ledger_id),
    CHECK (amount_original>0 AND fn_financial_amount_is_exact(amount_original)
        AND fn_financial_book_amount_is_exact(amount_local))
);
CREATE INDEX idx_procurement_iqc_credit_document_case ON procurement_iqc_credit_documents(case_id,id);

-- Actual supplier-document allocations are explicit per case. Internal funding
-- partitions refer to this immutable amount and an exact quantity ratio.
CREATE TABLE procurement_iqc_credit_case_allocations (
    id UUID PRIMARY KEY,
    credit_document_id UUID NOT NULL REFERENCES procurement_iqc_credit_documents(id) ON DELETE RESTRICT,
    case_id UUID NOT NULL REFERENCES procurement_iqc_rejection_cases(id) ON DELETE RESTRICT,
    case_version BIGINT NOT NULL CHECK (case_version>0),
    base_qty NUMERIC(18,4) NOT NULL CHECK (base_qty>0),
    amount_original NUMERIC NOT NULL CHECK (amount_original>0 AND fn_financial_amount_is_exact(amount_original)),
    amount_local NUMERIC NOT NULL CHECK (amount_local>=0 AND fn_financial_book_amount_is_exact(amount_local)),
    book_before_original NUMERIC NOT NULL CHECK (book_before_original>0),
    book_before_local NUMERIC NOT NULL CHECK (book_before_local>=0),
    book_after_original NUMERIC NOT NULL CHECK (book_after_original>=0),
    book_after_local NUMERIC NOT NULL CHECK (book_after_local>=0),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(credit_document_id,case_id)
);
CREATE INDEX idx_iqc_credit_case_allocation_case ON procurement_iqc_credit_case_allocations(case_id,credit_document_id);

CREATE TABLE procurement_iqc_credit_slices (
    id UUID PRIMARY KEY,
    command_id UUID NOT NULL,
    case_id UUID NOT NULL REFERENCES procurement_iqc_rejection_cases(id) ON DELETE RESTRICT,
    funding_slice_id UUID NOT NULL REFERENCES procurement_iqc_funding_slices(id) ON DELETE RESTRICT,
    credit_document_id UUID NOT NULL REFERENCES procurement_iqc_credit_documents(id) ON DELETE RESTRICT,
    case_allocation_id UUID NOT NULL REFERENCES procurement_iqc_credit_case_allocations(id) ON DELETE RESTRICT,
    base_qty NUMERIC(18,4) NOT NULL CHECK (base_qty>0),
    amount_original NUMERIC CHECK (amount_original>=0 AND fn_financial_amount_is_exact(amount_original)),
    amount_local NUMERIC CHECK (amount_local>=0 AND fn_financial_book_amount_is_exact(amount_local)),
    credit_reference VARCHAR(200) NOT NULL CHECK (btrim(credit_reference)<>''),
    credit_date DATE NOT NULL,
    reason VARCHAR(2000) NOT NULL CHECK (btrim(reason)<>''),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(command_id,funding_slice_id)
);
CREATE INDEX idx_procurement_iqc_credit_case ON procurement_iqc_credit_slices(case_id,id);
CREATE INDEX idx_procurement_iqc_credit_funding ON procurement_iqc_credit_slices(funding_slice_id,id);
CREATE INDEX idx_procurement_iqc_credit_document ON procurement_iqc_credit_slices(credit_document_id,id);

CREATE TABLE procurement_iqc_stock_consideration_parts (
    id UUID PRIMARY KEY,
    stock_in_item_id UUID NOT NULL REFERENCES procurement_iqc_stock_in_batch_items(id) ON DELETE RESTRICT,
    quality_part_id UUID NOT NULL REFERENCES procurement_iqc_quality_consideration_parts(id) ON DELETE RESTRICT,
    base_qty NUMERIC(18,4) NOT NULL CHECK (base_qty>0),
    amount_original NUMERIC CHECK (amount_original>=0),
    amount_local NUMERIC CHECK (amount_local>=0),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(stock_in_item_id,quality_part_id)
);
CREATE INDEX idx_procurement_iqc_stock_consideration_quality
    ON procurement_iqc_stock_consideration_parts(quality_part_id,id);

ALTER TABLE procurement_receipt_consideration_parts ADD CONSTRAINT procurement_consideration_funding_fk
    FOREIGN KEY(funding_slice_id) REFERENCES procurement_iqc_funding_slices(id) ON DELETE RESTRICT;
ALTER TABLE procurement_receipt_consideration_parts ADD CONSTRAINT procurement_consideration_credit_fk
    FOREIGN KEY(credit_slice_id) REFERENCES procurement_iqc_credit_slices(id) ON DELETE RESTRICT;

-- One terminal fact is recorded for the current funding slice and every ancestor.
-- This closes the original obligation without creating a second financial root.
CREATE TABLE procurement_iqc_funding_settlements (
    id UUID PRIMARY KEY,
    funding_slice_id UUID NOT NULL REFERENCES procurement_iqc_funding_slices(id) ON DELETE RESTRICT,
    terminal_funding_slice_id UUID NOT NULL REFERENCES procurement_iqc_funding_slices(id) ON DELETE RESTRICT,
    source_kind VARCHAR(12) NOT NULL CHECK (source_kind IN ('STOCK_IN','CREDIT')),
    source_id UUID NOT NULL,
    consideration_part_id UUID REFERENCES procurement_receipt_consideration_parts(id) ON DELETE RESTRICT,
    base_qty NUMERIC(18,4) NOT NULL CHECK (base_qty>0),
    amount_original NUMERIC CHECK (amount_original>=0),
    amount_local NUMERIC CHECK (amount_local>=0),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(funding_slice_id,terminal_funding_slice_id,source_kind,source_id,consideration_part_id),
    CHECK ((source_kind='STOCK_IN' AND consideration_part_id IS NOT NULL)
        OR (source_kind='CREDIT' AND consideration_part_id IS NULL))
);
CREATE INDEX idx_procurement_iqc_settlement_source ON procurement_iqc_funding_settlements(source_kind,source_id,id);
CREATE INDEX idx_procurement_iqc_settlement_funding ON procurement_iqc_funding_settlements(funding_slice_id,id);
CREATE UNIQUE INDEX uq_procurement_iqc_credit_settlement
    ON procurement_iqc_funding_settlements(funding_slice_id,source_id) WHERE source_kind='CREDIT';

CREATE TABLE procurement_iqc_consideration_reversals (
    id UUID PRIMARY KEY,
    target_kind VARCHAR(20) NOT NULL CHECK (target_kind IN ('CONSIDERATION','QUALITY','FUNDING','CREDIT','STOCK','SETTLEMENT')),
    target_id UUID NOT NULL,
    command_id UUID NOT NULL,
    reason VARCHAR(2000) NOT NULL CHECK (btrim(reason)<>''),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(target_kind,target_id)
);

CREATE TABLE procurement_iqc_consideration_review_approvals (
    id UUID PRIMARY KEY,
    review_version BIGINT NOT NULL CHECK (review_version>0),
    evidence_fingerprint CHAR(64) NOT NULL CHECK (evidence_fingerprint~'^[0-9a-f]{64}$'),
    receipt_type VARCHAR(20) NOT NULL CHECK (receipt_type IN ('PURCHASE','SUBCONTRACT')),
    receipt_id UUID NOT NULL,
    erroneous_ap_ledger_id UUID NOT NULL REFERENCES ar_ap_ledger(id) ON DELETE RESTRICT,
    supplier_id UUID NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    currency_id UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    exchange_rate NUMERIC(18,6) NOT NULL CHECK (exchange_rate>0),
    settlement_method_id UUID NOT NULL REFERENCES settlement_methods(id) ON DELETE RESTRICT,
    effective_date DATE NOT NULL,
    amount_original NUMERIC NOT NULL CHECK (amount_original>=0),
    amount_local NUMERIC NOT NULL CHECK (amount_local>=0),
    components JSONB NOT NULL CHECK (jsonb_typeof(components)='array' AND jsonb_array_length(components)>0),
    reason VARCHAR(2000) NOT NULL CHECK (btrim(reason)<>''),
    approved_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    approved_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX idx_procurement_iqc_consideration_review_ap
    ON procurement_iqc_consideration_review_approvals(erroneous_ap_ledger_id,id);

DO $$
DECLARE v_column RECORD;
BEGIN
    FOR v_column IN SELECT table_name,column_name FROM information_schema.columns
        WHERE table_schema='public' AND table_name IN (
            'procurement_receipt_consideration_parts','procurement_iqc_quality_consideration_parts',
            'procurement_iqc_funding_slices','procurement_iqc_credit_documents','procurement_iqc_credit_case_allocations',
            'procurement_iqc_credit_slices','procurement_iqc_stock_consideration_parts',
            'procurement_iqc_funding_settlements','procurement_iqc_consideration_review_approvals')
          AND column_name IN ('amount_original','amount_local','nominal_original','nominal_local','payable_original','payable_local',
              'book_before_original','book_before_local','book_after_original','book_after_local')
    LOOP
        EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IS NULL OR %I(%I))',
            v_column.table_name,'iqc_exact_'||substr(md5(v_column.table_name||'.'||v_column.column_name),1,24),
            v_column.column_name,CASE WHEN v_column.column_name LIKE '%local%' THEN 'fn_financial_book_amount_is_exact'
                ELSE 'fn_financial_amount_is_exact' END,v_column.column_name);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION fn_procurement_consideration_active(p_kind TEXT,p_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS(SELECT 1 FROM procurement_iqc_consideration_reversals
        WHERE target_kind=p_kind AND target_id=p_id)
$$;

CREATE OR REPLACE FUNCTION fn_guard_procurement_consideration_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'procurement consideration history is immutable; append a reversal'
        USING ERRCODE='23514',CONSTRAINT=TG_NAME;
END;
$$;

DO $$
DECLARE v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'procurement_receipt_consideration_parts','procurement_iqc_quality_consideration_parts',
        'procurement_iqc_funding_slices','procurement_iqc_credit_documents','procurement_iqc_credit_case_allocations','procurement_iqc_credit_slices','procurement_iqc_stock_consideration_parts',
        'procurement_iqc_funding_settlements','procurement_iqc_consideration_reversals',
        'procurement_iqc_consideration_review_approvals']
    LOOP
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_consideration_immutable()',
            'trg_'||v_table||'_immutable',v_table);
        EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_audit()',
            'trg_audit_'||v_table,v_table);
        EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER %I',v_table,'trg_'||v_table||'_immutable');
        EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER %I',v_table,'trg_audit_'||v_table);
    END LOOP;
END;
$$;

ALTER TABLE purchase_receipts ADD COLUMN consideration_required BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE subcontract_receipts ADD COLUMN consideration_required BOOLEAN NOT NULL DEFAULT FALSE;
-- V516 already introduced the nullable intent field. Add the missing domain
-- guard without changing any already-applied migration or guessing old intent.
ALTER TABLE purchase_receipt_items ADD CONSTRAINT purchase_receipt_replacement_intent_value_chk
    CHECK (replacement_intent IN ('NORMAL','RETURN_REPLACEMENT'));
ALTER TABLE subcontract_receipt_items ADD CONSTRAINT subcontract_receipt_replacement_intent_value_chk
    CHECK (replacement_intent IN ('NORMAL','RETURN_REPLACEMENT'));
CREATE INDEX idx_procurement_iqc_replacement_fifo
    ON procurement_iqc_rejection_cases(receipt_type,order_item_id,return_date,id)
    WHERE is_deleted=FALSE AND return_recorded_at IS NOT NULL;
ALTER TABLE procurement_iqc_rejection_cases
    DROP CONSTRAINT procurement_iqc_rejection_cases_credit_shape_chk;
ALTER TABLE procurement_iqc_rejection_cases ADD CONSTRAINT procurement_iqc_rejection_cases_credit_shape_chk CHECK (
    (status='CREDIT_CONFIRMED' AND (failed_amount_original>0 OR failed_amount_local>0)
        AND credit_source_id IS NOT NULL AND credit_ledger_id IS NOT NULL
        AND NULLIF(btrim(credit_reference),'') IS NOT NULL AND credit_date IS NOT NULL
        AND NULLIF(btrim(credit_reason),'') IS NOT NULL
        AND credit_confirmed_by IS NOT NULL AND credit_confirmed_at IS NOT NULL)
    OR status<>'CREDIT_CONFIRMED');

CREATE OR REPLACE FUNCTION fn_mark_procurement_consideration_required()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' OR (NEW.status=1 AND OLD.status IS DISTINCT FROM 1) THEN
        NEW.consideration_required:=TRUE;
    ELSIF OLD.consideration_required AND NOT NEW.consideration_required THEN
        RAISE EXCEPTION 'receipt consideration requirement cannot be removed'
            USING ERRCODE='23514',CONSTRAINT=TG_NAME;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_purchase_receipt_consideration_required BEFORE INSERT OR UPDATE ON purchase_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_mark_procurement_consideration_required();
CREATE TRIGGER trg_subcontract_receipt_consideration_required BEFORE INSERT OR UPDATE ON subcontract_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_mark_procurement_consideration_required();
ALTER TABLE purchase_receipts ENABLE ALWAYS TRIGGER trg_purchase_receipt_consideration_required;
ALTER TABLE subcontract_receipts ENABLE ALWAYS TRIGGER trg_subcontract_receipt_consideration_required;

CREATE OR REPLACE FUNCTION fn_assert_procurement_consideration_receipt(p_type TEXT,p_receipt UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_header RECORD;
    v_item RECORD;
    v_total RECORD;
    v_ap RECORD;
    v_table TEXT;
BEGIN
    IF p_receipt IS NULL THEN RETURN; END IF;
    IF p_type NOT IN ('PURCHASE','SUBCONTRACT') THEN
        RAISE EXCEPTION 'unknown consideration receipt type' USING ERRCODE='23514';
    END IF;
    v_table:=CASE p_type WHEN 'PURCHASE' THEN 'purchase_receipts' ELSE 'subcontract_receipts' END;
    EXECUTE format('SELECT status,is_deleted,consideration_required,supplier_id,currency_id,exchange_rate,
        settlement_method_id FROM %I WHERE id=$1 FOR UPDATE',v_table) INTO v_header USING p_receipt;
    IF v_header.status IS NULL THEN
        RAISE EXCEPTION 'consideration source receipt is missing' USING ERRCODE='23514';
    END IF;
    IF v_header.status<>1 OR v_header.is_deleted THEN
        IF EXISTS(SELECT 1 FROM procurement_receipt_consideration_parts
            WHERE receipt_type=p_type AND receipt_id=p_receipt
              AND fn_procurement_consideration_active('CONSIDERATION',id)) THEN
            RAISE EXCEPTION 'active consideration requires an approved receipt' USING ERRCODE='23514';
        END IF;
        RETURN;
    END IF;
    IF NOT v_header.consideration_required THEN RETURN; END IF;
    v_table:=CASE p_type WHEN 'PURCHASE' THEN 'purchase_receipt_items' ELSE 'subcontract_receipt_items' END;
    FOR v_item IN EXECUTE format('SELECT id,qty*unit_rate base_qty,amount_original,amount_local,replacement_intent
        FROM %I WHERE receipt_id=$1 AND is_deleted=FALSE ORDER BY id',v_table) USING p_receipt
    LOOP
        SELECT COUNT(*) n,COALESCE(SUM(base_qty),0) qty,
               COALESCE(SUM(nominal_original),0) original,COALESCE(SUM(nominal_local),0) local
        INTO v_total FROM procurement_receipt_consideration_parts
        WHERE receipt_type=p_type AND receipt_id=p_receipt AND receipt_item_id=v_item.id
          AND fn_procurement_consideration_active('CONSIDERATION',id);
        IF v_item.replacement_intent IS NULL OR v_total.n=0 OR v_total.qty<>v_item.base_qty
           OR EXISTS(SELECT 1 FROM procurement_receipt_consideration_parts part
               WHERE part.receipt_type=p_type AND part.receipt_id=p_receipt AND part.receipt_item_id=v_item.id
                 AND fn_procurement_consideration_active('CONSIDERATION',part.id)
                 AND ((part.nominal_original IS NOT NULL
                       AND part.nominal_original*v_item.base_qty<>v_item.amount_original*part.base_qty)
                      OR (part.nominal_local IS NOT NULL
                       AND part.nominal_local*v_item.base_qty<>v_item.amount_local*part.base_qty))) THEN
            RAISE EXCEPTION 'receipt consideration quantity or nominal amount is not conserved'
                USING ERRCODE='23514',CONSTRAINT='procurement_receipt_consideration_capacity';
        END IF;
        IF (v_item.replacement_intent='NORMAL')=EXISTS(
            SELECT 1 FROM procurement_receipt_consideration_parts
            WHERE receipt_type=p_type AND receipt_item_id=v_item.id AND billing_mode<>'STANDARD'
              AND fn_procurement_consideration_active('CONSIDERATION',id)) THEN
            RAISE EXCEPTION 'receipt consideration differs from its confirmed arrival intent' USING ERRCODE='23514';
        END IF;
    END LOOP;
    SELECT COALESCE(SUM(payable_original),0) original,COALESCE(SUM(payable_local),0) local
    INTO v_total FROM procurement_receipt_consideration_parts
    WHERE receipt_type=p_type AND receipt_id=p_receipt
      AND fn_procurement_consideration_active('CONSIDERATION',id);
    SELECT COUNT(*) n,COALESCE(SUM(amount_original),0) original,
           COALESCE(SUM(amount_original_local),0) local,
           COALESCE(BOOL_AND(supplier_id=v_header.supplier_id AND currency_id=v_header.currency_id
               AND exchange_rate=v_header.exchange_rate
               AND settlement_type_id IS NOT DISTINCT FROM v_header.settlement_method_id),TRUE) identity_matches
    INTO v_ap FROM ar_ap_ledger WHERE source_doc_type=p_type||'_RECEIPT' AND source_doc_id=p_receipt
        AND direction='AP' AND status=1 AND is_deleted=FALSE;
    IF v_ap.n<>(CASE WHEN v_total.original=0 AND v_total.local=0 THEN 0 ELSE 1 END)
        OR NOT v_ap.identity_matches OR (v_ap.original,v_ap.local) IS DISTINCT FROM (v_total.original,v_total.local) THEN
        RAISE EXCEPTION 'receipt payable must equal chargeable consideration only'
            USING ERRCODE='23514',CONSTRAINT='procurement_receipt_consideration_payable';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_procurement_replacement_intent()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_status SMALLINT;
BEGIN
    IF NEW.replacement_intent IS NOT DISTINCT FROM OLD.replacement_intent THEN RETURN NEW; END IF;
    IF TG_TABLE_NAME='purchase_receipt_items' THEN
        SELECT status INTO v_status FROM purchase_receipts WHERE id=OLD.receipt_id;
    ELSE
        SELECT status INTO v_status FROM subcontract_receipts WHERE id=OLD.receipt_id;
    END IF;
    IF v_status IS DISTINCT FROM 0::smallint THEN
        RAISE EXCEPTION 'approved receipt arrival intent is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_purchase_receipt_intent BEFORE UPDATE ON purchase_receipt_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_replacement_intent();
CREATE TRIGGER trg_subcontract_receipt_intent BEFORE UPDATE ON subcontract_receipt_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_replacement_intent();
ALTER TABLE purchase_receipt_items ENABLE ALWAYS TRIGGER trg_purchase_receipt_intent;
ALTER TABLE subcontract_receipt_items ENABLE ALWAYS TRIGGER trg_subcontract_receipt_intent;

CREATE OR REPLACE FUNCTION fn_assert_procurement_iqc_funding(p_id UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_fund RECORD;
    v_source RECORD;
    v_used RECORD;
    v_settled RECORD;
BEGIN
    IF p_id IS NULL THEN RETURN; END IF;
    SELECT * INTO v_fund FROM procurement_iqc_funding_slices WHERE id=p_id FOR UPDATE;
    IF NOT FOUND OR NOT fn_procurement_consideration_active('FUNDING',p_id) THEN RETURN; END IF;
    IF NOT EXISTS(WITH RECURSIVE ancestors AS (
        SELECT id,parent_funding_slice_id,ARRAY[id] path FROM procurement_iqc_funding_slices WHERE id=p_id
        UNION ALL SELECT parent.id,parent.parent_funding_slice_id,child.path||parent.id
        FROM procurement_iqc_funding_slices parent JOIN ancestors child ON child.parent_funding_slice_id=parent.id
        WHERE NOT parent.id=ANY(child.path))
        SELECT 1 FROM ancestors WHERE id=v_fund.root_funding_slice_id AND parent_funding_slice_id IS NULL) THEN
        RAISE EXCEPTION 'funding ancestry is cyclic or disconnected from its original root' USING ERRCODE='23514';
    END IF;
    SELECT quality.base_qty,quality.amount_original,quality.amount_local,event.action,
           event.inspection_item_id,part.billing_mode,part.funding_slice_id,
           part.receipt_type,part.receipt_id,part.receipt_item_id,
           rejection.inspection_item_id case_inspection,
           parent.root_funding_slice_id parent_root,parent.root_case_id parent_root_case,
           parent.root_receipt_item_id parent_root_item,parent.source_ap_ledger_id parent_ap,
           ledger.id own_ap
    INTO v_source
    FROM procurement_iqc_quality_consideration_parts quality
    JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
    JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
    JOIN procurement_iqc_rejection_cases rejection ON rejection.id=v_fund.case_id
    LEFT JOIN procurement_iqc_funding_slices parent ON parent.id=part.funding_slice_id
    LEFT JOIN ar_ap_ledger ledger ON ledger.source_doc_id=part.receipt_id
      AND ledger.source_doc_type=part.receipt_type||'_RECEIPT'
      AND ledger.direction='AP' AND ledger.status=1 AND ledger.is_deleted=FALSE
    WHERE quality.id=v_fund.quality_part_id
      AND fn_procurement_consideration_active('QUALITY',quality.id)
      AND fn_procurement_consideration_active('CONSIDERATION',part.id);
    IF NOT FOUND OR v_source.action<>'FAIL' OR v_source.case_inspection<>v_source.inspection_item_id
       OR (v_fund.base_qty,v_fund.amount_original,v_fund.amount_local)
          IS DISTINCT FROM (v_source.base_qty,v_source.amount_original,v_source.amount_local) THEN
        RAISE EXCEPTION 'funding slice lacks its exact physical failure' USING ERRCODE='23514';
    END IF;
    IF v_source.billing_mode='NO_CHARGE' THEN
        IF (v_fund.parent_funding_slice_id,v_fund.root_funding_slice_id,v_fund.root_case_id,
            v_fund.root_receipt_item_id,v_fund.source_ap_ledger_id)
           IS DISTINCT FROM (v_source.funding_slice_id,v_source.parent_root,v_source.parent_root_case,
            v_source.parent_root_item,v_source.parent_ap) THEN
            RAISE EXCEPTION 'free replacement must carry its original funding root' USING ERRCODE='23514';
        END IF;
    ELSIF v_fund.parent_funding_slice_id IS NOT NULL OR v_fund.root_funding_slice_id<>v_fund.id
       OR v_fund.root_case_id<>v_fund.case_id OR v_fund.root_receipt_item_id<>v_source.receipt_item_id
       OR v_fund.source_ap_ledger_id IS DISTINCT FROM v_source.own_ap
       OR (v_fund.source_ap_ledger_id IS NULL AND (v_fund.amount_original<>0 OR v_fund.amount_local<>0)) THEN
        RAISE EXCEPTION 'paid failure must use its own receipt funding' USING ERRCODE='23514';
    END IF;
    SELECT COALESCE(SUM(qty),0) qty,COALESCE(SUM(original),0) original,COALESCE(SUM(local),0) local
    INTO v_used FROM (
        SELECT base_qty qty,nominal_original original,nominal_local local
        FROM procurement_receipt_consideration_parts WHERE funding_slice_id=p_id AND billing_mode='NO_CHARGE'
          AND fn_procurement_consideration_active('CONSIDERATION',id)
        UNION ALL
        SELECT base_qty,amount_original,amount_local FROM procurement_iqc_credit_slices
        WHERE funding_slice_id=p_id AND fn_procurement_consideration_active('CREDIT',id)
    ) usage;
    IF v_used.qty>v_fund.base_qty THEN
        RAISE EXCEPTION 'free replacement and credit exceed the same funding slice'
            USING ERRCODE='23514',CONSTRAINT='procurement_iqc_funding_capacity';
    END IF;
    SELECT COALESCE(SUM(base_qty),0) qty,COALESCE(SUM(amount_original),0) original,
           COALESCE(SUM(amount_local),0) local INTO v_settled
    FROM procurement_iqc_funding_settlements
    WHERE funding_slice_id=p_id AND fn_procurement_consideration_active('SETTLEMENT',id);
    IF v_settled.qty>v_fund.base_qty THEN
        RAISE EXCEPTION 'funding is settled more than once across replacement generations'
            USING ERRCODE='23514',CONSTRAINT='procurement_iqc_funding_settlement_capacity';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_procurement_consideration_part(p_id UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_part RECORD; v_source RECORD; v_total RECORD; v_receipt_id UUID;
BEGIN
    SELECT * INTO v_part FROM procurement_receipt_consideration_parts WHERE id=p_id;
    IF NOT FOUND THEN RETURN; END IF;
    PERFORM fn_assert_procurement_consideration_receipt(v_part.receipt_type,v_part.receipt_id);
    PERFORM fn_assert_procurement_iqc_funding(v_part.funding_slice_id);
    IF NOT fn_procurement_consideration_active('CONSIDERATION',p_id) THEN RETURN; END IF;
    IF v_part.receipt_type='PURCHASE' THEN
        SELECT receipt_id INTO v_receipt_id FROM purchase_receipt_items
        WHERE id=v_part.receipt_item_id AND is_deleted=FALSE;
    ELSE
        SELECT receipt_id INTO v_receipt_id FROM subcontract_receipt_items
        WHERE id=v_part.receipt_item_id AND is_deleted=FALSE;
    END IF;
    IF v_receipt_id IS DISTINCT FROM v_part.receipt_id THEN
        RAISE EXCEPTION 'consideration receipt item belongs to a different source' USING ERRCODE='23514';
    END IF;
    IF v_part.billing_mode='STANDARD' THEN RETURN; END IF;
    SELECT allocation.replacement_receipt_type,allocation.replacement_receipt_id,
           allocation.replacement_receipt_item_id,allocation.status allocation_status,
           allocation.allocated_base_qty,allocation.allocated_amount_original,allocation.allocated_amount_local,
           rejection.id case_id,rejection.return_recorded_at,rejection.status case_status,
           funding.case_id funding_case
    INTO v_source FROM procurement_iqc_replacement_allocations allocation
    JOIN procurement_iqc_rejection_cases rejection ON rejection.id=allocation.case_id
    JOIN procurement_iqc_funding_slices funding ON funding.id=v_part.funding_slice_id
    WHERE allocation.id=v_part.replacement_allocation_id;
    IF NOT FOUND OR v_source.allocation_status<>'ACTIVE' OR v_source.return_recorded_at IS NULL
       OR v_source.case_status='REVERSED' OR v_source.case_id<>v_source.funding_case
       OR (v_part.receipt_type,v_part.receipt_id,v_part.receipt_item_id) IS DISTINCT FROM
          (v_source.replacement_receipt_type,v_source.replacement_receipt_id,v_source.replacement_receipt_item_id) THEN
        RAISE EXCEPTION 'replacement consideration lacks its exact returned generation' USING ERRCODE='23514';
    END IF;
    SELECT SUM(base_qty) qty,SUM(nominal_original) original,SUM(nominal_local) local INTO v_total
    FROM procurement_receipt_consideration_parts
    WHERE replacement_allocation_id=v_part.replacement_allocation_id
      AND fn_procurement_consideration_active('CONSIDERATION',id);
    IF v_total.qty IS DISTINCT FROM v_source.allocated_base_qty THEN
        RAISE EXCEPTION 'replacement consideration does not partition its physical allocation' USING ERRCODE='23514';
    END IF;
    IF v_part.credit_slice_id IS NOT NULL THEN
        SELECT credit.base_qty,credit.amount_original,credit.amount_local,credit.funding_slice_id
        INTO v_source FROM procurement_iqc_credit_slices credit WHERE id=v_part.credit_slice_id
          AND fn_procurement_consideration_active('CREDIT',id);
        SELECT SUM(base_qty) qty,SUM(nominal_original) original,SUM(nominal_local) local INTO v_total
        FROM procurement_receipt_consideration_parts WHERE credit_slice_id=v_part.credit_slice_id
          AND fn_procurement_consideration_active('CONSIDERATION',id);
        IF v_source.funding_slice_id IS NULL OR v_source.funding_slice_id<>v_part.funding_slice_id
           OR v_total.qty>v_source.base_qty THEN
            RAISE EXCEPTION 'repurchase exceeds its exact credited funding share' USING ERRCODE='23514';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_procurement_quality_consideration(p_event UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_event RECORD; v_part RECORD; v_total RECORD; v_before NUMERIC;
BEGIN
    SELECT event.id,event.action,event.base_qty,inspection.receipt_type,inspection.receipt_id,
           inspection.receipt_item_id,inspection.status inspection_status
    INTO v_event FROM procurement_inspection_events event
    JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id
    WHERE event.id=p_event;
    IF NOT FOUND OR v_event.action NOT IN ('PASS','FAIL') THEN RETURN; END IF;
    IF NOT EXISTS(SELECT 1 FROM procurement_receipt_consideration_parts
        WHERE receipt_type=v_event.receipt_type AND receipt_item_id=v_event.receipt_item_id) THEN RETURN; END IF;
    SELECT COALESCE(SUM(base_qty),0) qty INTO v_total FROM procurement_iqc_quality_consideration_parts
    WHERE inspection_event_id=p_event AND fn_procurement_consideration_active('QUALITY',id);
    IF v_total.qty<>(CASE WHEN v_event.inspection_status='REVERSED' THEN 0 ELSE v_event.base_qty END) THEN
        RAISE EXCEPTION 'quality event consideration is not conserved' USING ERRCODE='23514';
    END IF;
    FOR v_part IN
        SELECT quality.*,part.base_qty capacity,part.nominal_original,part.nominal_local,
               part.receipt_type,part.receipt_item_id,event.occurred_at
        FROM procurement_iqc_quality_consideration_parts quality
        JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
        JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
        WHERE quality.inspection_event_id=p_event AND fn_procurement_consideration_active('QUALITY',quality.id)
    LOOP
        IF (v_part.receipt_type,v_part.receipt_item_id) IS DISTINCT FROM
           (v_event.receipt_type,v_event.receipt_item_id) THEN
            RAISE EXCEPTION 'quality consideration has a different receipt source' USING ERRCODE='23514';
        END IF;
        SELECT COALESCE(SUM(prior.base_qty),0) INTO v_before
        FROM procurement_iqc_quality_consideration_parts prior
        JOIN procurement_inspection_events event ON event.id=prior.inspection_event_id
        WHERE prior.consideration_part_id=v_part.consideration_part_id
          AND (event.occurred_at,event.id)<(v_part.occurred_at,p_event)
          AND fn_procurement_consideration_active('QUALITY',prior.id);
        IF v_before+v_part.base_qty>v_part.capacity
           OR (v_part.amount_original IS NOT NULL AND v_part.amount_original*v_part.capacity
                IS DISTINCT FROM v_part.nominal_original*v_part.base_qty)
           OR (v_part.amount_local IS NOT NULL AND v_part.amount_local*v_part.capacity
                IS DISTINCT FROM v_part.nominal_local*v_part.base_qty) THEN
            RAISE EXCEPTION 'quality consideration exceeds its cumulative quantity or amount slice' USING ERRCODE='23514';
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_procurement_stock_consideration(p_stock_item UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_stock RECORD; v_part RECORD; v_total NUMERIC; v_before NUMERIC;
BEGIN
    SELECT stock.*,inspection.status inspection_status INTO v_stock
    FROM procurement_iqc_stock_in_batch_items stock
    JOIN procurement_inspection_items inspection ON inspection.id=stock.inspection_item_id
    WHERE stock.id=p_stock_item;
    IF NOT FOUND THEN RETURN; END IF;
    IF NOT EXISTS(SELECT 1 FROM procurement_iqc_quality_consideration_parts
        WHERE inspection_event_id=v_stock.pass_event_id) THEN RETURN; END IF;
    SELECT COALESCE(SUM(base_qty),0) INTO v_total FROM procurement_iqc_stock_consideration_parts
    WHERE stock_in_item_id=p_stock_item AND fn_procurement_consideration_active('STOCK',id);
    IF v_total<>(CASE WHEN v_stock.inspection_status='REVERSED' THEN 0 ELSE v_stock.base_qty END) THEN
        RAISE EXCEPTION 'warehouse stock-in consideration is not conserved' USING ERRCODE='23514';
    END IF;
    FOR v_part IN
        SELECT stock.*,quality.base_qty capacity,quality.amount_original nominal_original,
               quality.amount_local nominal_local,quality.inspection_event_id,event.action
        FROM procurement_iqc_stock_consideration_parts stock
        JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=stock.quality_part_id
        JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
        WHERE stock.stock_in_item_id=p_stock_item AND fn_procurement_consideration_active('STOCK',stock.id)
    LOOP
        IF v_part.action<>'PASS' OR v_part.inspection_event_id<>v_stock.pass_event_id THEN
            RAISE EXCEPTION 'warehouse stock-in must use its exact passed consideration' USING ERRCODE='23514';
        END IF;
        SELECT COALESCE(SUM(prior.base_qty),0) INTO v_before
        FROM procurement_iqc_stock_consideration_parts prior
        JOIN procurement_iqc_stock_in_batch_items item ON item.id=prior.stock_in_item_id
        WHERE prior.quality_part_id=v_part.quality_part_id
          AND (item.created_at,item.id)<(v_stock.created_at,v_stock.id)
          AND fn_procurement_consideration_active('STOCK',prior.id);
        IF v_before+v_part.base_qty>v_part.capacity
           OR (v_part.amount_original IS NOT NULL AND v_part.amount_original*v_part.capacity
                IS DISTINCT FROM v_part.nominal_original*v_part.base_qty)
           OR (v_part.amount_local IS NOT NULL AND v_part.amount_local*v_part.capacity
                IS DISTINCT FROM v_part.nominal_local*v_part.base_qty) THEN
            RAISE EXCEPTION 'warehouse consideration exceeds its cumulative passed slice' USING ERRCODE='23514';
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_procurement_credit_consideration(p_document UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_total RECORD; v_ap RECORD; v_slice RECORD; v_document RECORD; v_allocation RECORD; v_source RECORD;
    v_original_left NUMERIC; v_local_left NUMERIC; v_remainder NUMERIC;
BEGIN
    IF p_document IS NULL THEN RETURN; END IF;
    SELECT * INTO v_document FROM procurement_iqc_credit_documents WHERE id=p_document;
    IF NOT FOUND THEN RAISE EXCEPTION 'credit document is missing' USING ERRCODE='23514'; END IF;
    SELECT COUNT(*) n,COALESCE(SUM(credit.base_qty),0) qty,
           MIN(rejection.receipt_type) receipt_type,MIN(rejection.supplier_id::text)::uuid supplier_id,
           MIN(rejection.currency_id::text)::uuid currency_id,MIN(rejection.exchange_rate) exchange_rate
    INTO v_total FROM procurement_iqc_credit_slices credit
    JOIN procurement_iqc_rejection_cases rejection ON rejection.id=credit.case_id
    WHERE credit.credit_document_id=p_document AND fn_procurement_consideration_active('CREDIT',credit.id);
    SELECT COUNT(*) n,COALESCE(SUM(amount_original),0) original,
           COALESCE(SUM(amount_original_local),0) local,
           COALESCE(BOOL_AND(source_doc_type=v_total.receipt_type||'_IQC_CREDIT'
               AND supplier_id=v_total.supplier_id AND currency_id=v_total.currency_id
               AND exchange_rate=v_total.exchange_rate),TRUE) identity_matches
    INTO v_ap FROM ar_ap_ledger WHERE source_doc_id=p_document AND direction='AP'
        AND source_doc_type IN ('PURCHASE_IQC_CREDIT','SUBCONTRACT_IQC_CREDIT') AND status=1 AND is_deleted=FALSE;
    SELECT * INTO v_source FROM ar_ap_ledger WHERE id=v_document.source_ap_ledger_id FOR UPDATE;
    IF v_total.n>0 AND (v_source.status<>1 OR v_source.is_deleted OR v_source.direction<>'AP'
        OR v_source.amount_original<=0 OR v_document.amount_original>v_source.amount_original) THEN
        RAISE EXCEPTION 'actual credit requires a valid original payable source' USING ERRCODE='23514';
    END IF;
    IF (v_document.book_allocation_plan->>'sourceApLedgerId')::uuid IS DISTINCT FROM v_document.source_ap_ledger_id
       OR (v_document.book_allocation_plan->>'amountOriginal')::numeric IS DISTINCT FROM v_document.amount_original
       OR (v_document.book_allocation_plan->>'amountLocal')::numeric IS DISTINCT FROM v_document.amount_local
       OR jsonb_typeof(v_document.book_allocation_plan->'basis') IS DISTINCT FROM 'array'
       OR jsonb_array_length(v_document.book_allocation_plan->'basis')=0 THEN
        RAISE EXCEPTION 'actual credit must freeze its common source-aware book allocation plan' USING ERRCODE='23514';
    END IF;
    IF v_ap.n<>(CASE WHEN v_total.n=0 THEN 0 ELSE 1 END)
       OR NOT v_ap.identity_matches
       OR (v_total.n>0 AND (v_ap.original,v_ap.local) IS DISTINCT FROM
            (-v_document.amount_original,-v_document.amount_local)) THEN
        RAISE EXCEPTION 'credit payable must equal the actual supplier credit document' USING ERRCODE='23514';
    END IF;
    IF (SELECT SUM(amount_original) FROM procurement_iqc_credit_case_allocations WHERE credit_document_id=p_document)
        IS DISTINCT FROM v_document.amount_original
       OR (SELECT SUM(amount_local) FROM procurement_iqc_credit_case_allocations WHERE credit_document_id=p_document)
        IS DISTINCT FROM v_document.amount_local
       OR (SELECT SUM(base_qty) FROM procurement_iqc_credit_case_allocations WHERE credit_document_id=p_document)
        IS DISTINCT FROM v_document.base_qty THEN
        RAISE EXCEPTION 'explicit case allocations must exhaust the actual supplier document' USING ERRCODE='23514';
    END IF;
    IF v_total.n>0 AND (v_total.qty<>v_document.base_qty OR
        (SELECT SUM(document.amount_original) FROM procurement_iqc_credit_documents document
            WHERE document.source_ap_ledger_id=v_document.source_ap_ledger_id AND EXISTS(
                SELECT 1 FROM procurement_iqc_credit_slices active WHERE active.credit_document_id=document.id
                  AND fn_procurement_consideration_active('CREDIT',active.id)))>v_source.amount_original) THEN
        RAISE EXCEPTION 'active actual supplier credits exceed their original payable' USING ERRCODE='23514';
    END IF;
    v_original_left:=v_document.amount_original;v_local_left:=v_document.amount_local;
    FOR v_allocation IN SELECT * FROM procurement_iqc_credit_case_allocations WHERE credit_document_id=p_document ORDER BY case_id
    LOOP
        IF (v_allocation.book_before_original,v_allocation.book_before_local,v_allocation.book_after_original,v_allocation.book_after_local)
            IS DISTINCT FROM (v_original_left,v_local_left,v_original_left-v_allocation.amount_original,v_local_left-v_allocation.amount_local) THEN
            RAISE EXCEPTION 'case book allocation loses its prior or remaining source balance' USING ERRCODE='23514';
        END IF;
        v_remainder:=v_local_left*v_allocation.amount_original-v_allocation.amount_local*v_original_left;
        IF (v_allocation.amount_original=v_original_left AND v_allocation.amount_local<>v_local_left)
            OR v_remainder<0 OR v_remainder>=v_original_left*1e-30::numeric THEN
            RAISE EXCEPTION 'case book allocation must preserve its exact share and all residual money' USING ERRCODE='23514';
        END IF;
        v_original_left:=v_allocation.book_after_original;v_local_left:=v_allocation.book_after_local;
        IF (SELECT COALESCE(SUM(base_qty),0) FROM procurement_iqc_credit_slices
                WHERE case_allocation_id=v_allocation.id AND fn_procurement_consideration_active('CREDIT',id))
            <>(CASE WHEN v_total.n>0 THEN v_allocation.base_qty ELSE 0 END) THEN
            RAISE EXCEPTION 'case allocation quantity differs from its exact funding partitions' USING ERRCODE='23514';
        END IF;
    END LOOP;
    FOR v_slice IN
        SELECT credit.*,rejection.return_recorded_at,rejection.status case_status,
               rejection.receipt_type,rejection.supplier_id,rejection.currency_id,rejection.exchange_rate,
               funding.case_id funding_case,funding.source_ap_ledger_id
        FROM procurement_iqc_credit_slices credit
        JOIN procurement_iqc_rejection_cases rejection ON rejection.id=credit.case_id
        JOIN procurement_iqc_funding_slices funding ON funding.id=credit.funding_slice_id
        WHERE credit.credit_document_id=p_document AND fn_procurement_consideration_active('CREDIT',credit.id)
    LOOP
        IF v_slice.return_recorded_at IS NULL OR v_slice.case_status='REVERSED'
           OR v_slice.case_id<>v_slice.funding_case
           OR v_slice.command_id<>v_document.command_id
           OR v_slice.source_ap_ledger_id<>v_document.source_ap_ledger_id
           OR (v_slice.receipt_type,v_slice.supplier_id,v_slice.currency_id,v_slice.exchange_rate)
                IS DISTINCT FROM (v_total.receipt_type,v_total.supplier_id,v_total.currency_id,v_total.exchange_rate)
           OR NOT EXISTS(SELECT 1 FROM ar_ap_ledger WHERE id=v_slice.source_ap_ledger_id
                AND direction='AP' AND status=1 AND is_deleted=FALSE AND amount_original>0) THEN
            RAISE EXCEPTION 'credit requires its own returned generation and valid original funding' USING ERRCODE='23514';
        END IF;
        SELECT * INTO v_allocation FROM procurement_iqc_credit_case_allocations WHERE id=v_slice.case_allocation_id;
        IF (v_allocation.credit_document_id,v_allocation.case_id) IS DISTINCT FROM (p_document,v_slice.case_id)
           OR (v_slice.amount_original IS NOT NULL
               AND v_slice.amount_original*v_allocation.base_qty<>v_allocation.amount_original*v_slice.base_qty)
           OR (v_slice.amount_local IS NOT NULL AND v_slice.amount_local*v_allocation.base_qty
               <>v_allocation.amount_local*v_slice.base_qty) THEN
            RAISE EXCEPTION 'funding credit has a different explicit case amount or quantity basis' USING ERRCODE='23514';
        END IF;
        PERFORM fn_assert_procurement_iqc_funding(v_slice.funding_slice_id);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_procurement_funding_settlement(p_id UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_settlement RECORD; v_source RECORD;
BEGIN
    SELECT * INTO v_settlement FROM procurement_iqc_funding_settlements WHERE id=p_id;
    IF NOT FOUND THEN RETURN; END IF;
    PERFORM fn_assert_procurement_iqc_funding(v_settlement.funding_slice_id);
    IF NOT fn_procurement_consideration_active('SETTLEMENT',p_id) THEN RETURN; END IF;
    IF NOT EXISTS(WITH RECURSIVE ancestors AS (
        SELECT id,parent_funding_slice_id FROM procurement_iqc_funding_slices WHERE id=v_settlement.terminal_funding_slice_id
        UNION ALL SELECT parent.id,parent.parent_funding_slice_id FROM procurement_iqc_funding_slices parent
        JOIN ancestors child ON child.parent_funding_slice_id=parent.id)
        SELECT 1 FROM ancestors WHERE id=v_settlement.funding_slice_id) THEN
        RAISE EXCEPTION 'settlement cannot cross a funding family' USING ERRCODE='23514';
    END IF;
    IF v_settlement.source_kind='CREDIT' THEN
        SELECT funding_slice_id,base_qty,amount_original,amount_local INTO v_source
        FROM procurement_iqc_credit_slices WHERE id=v_settlement.source_id
          AND fn_procurement_consideration_active('CREDIT',id);
    ELSE
        SELECT part.funding_slice_id,stock.base_qty,stock.amount_original,stock.amount_local INTO v_source
        FROM procurement_iqc_stock_consideration_parts stock
        JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=stock.quality_part_id
        JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
        WHERE stock.id=v_settlement.source_id AND part.id=v_settlement.consideration_part_id
          AND part.billing_mode='NO_CHARGE' AND fn_procurement_consideration_active('STOCK',stock.id);
    END IF;
    IF NOT FOUND OR (v_source.funding_slice_id,v_source.base_qty,v_source.amount_original,v_source.amount_local)
        IS DISTINCT FROM (v_settlement.terminal_funding_slice_id,v_settlement.base_qty,
            v_settlement.amount_original,v_settlement.amount_local) THEN
        RAISE EXCEPTION 'settlement lacks its exact credit or actual stock-in share' USING ERRCODE='23514';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_procurement_iqc_funding_unresolved(p_funding UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT GREATEST(funding.base_qty-COALESCE((SELECT SUM(base_qty)
        FROM procurement_iqc_funding_settlements WHERE funding_slice_id=funding.id
          AND fn_procurement_consideration_active('SETTLEMENT',id)),0),0)
    FROM procurement_iqc_funding_slices funding WHERE id=p_funding
      AND fn_procurement_consideration_active('FUNDING',id)
$$;

CREATE OR REPLACE FUNCTION fn_procurement_iqc_slice_offset_authorized(
    p_case UUID,p_credit_ledger UUID,p_target_ledger UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(
        SELECT 1 FROM procurement_iqc_credit_slices slice
        JOIN procurement_iqc_rejection_cases rejection ON rejection.id=slice.case_id
        JOIN procurement_iqc_funding_slices funding ON funding.id=slice.funding_slice_id
        JOIN ar_ap_ledger credit ON credit.source_doc_id=slice.credit_document_id
          AND credit.source_doc_type=rejection.receipt_type||'_IQC_CREDIT'
          AND credit.direction='AP' AND credit.status=1 AND credit.is_deleted=FALSE
        WHERE slice.case_id=p_case AND credit.id=p_credit_ledger
          AND funding.source_ap_ledger_id=p_target_ledger
          AND rejection.return_recorded_at IS NOT NULL AND rejection.status<>'REVERSED'
          AND fn_procurement_consideration_active('CREDIT',slice.id)
          AND fn_procurement_consideration_active('FUNDING',funding.id))
$$;

CREATE OR REPLACE FUNCTION fn_procurement_iqc_ap_hold_reason(
    p_ledger_id UUID,p_allowed_case_id UUID DEFAULT NULL)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    WITH source AS (
        SELECT id,source_doc_id,source_doc_type FROM ar_ap_ledger WHERE id=p_ledger_id
          AND direction='AP' AND status=1 AND is_deleted=FALSE
          AND source_doc_type IN ('PURCHASE_RECEIPT','SUBCONTRACT_RECEIPT')
    ), linked AS (
        SELECT inspection.*,rejection.id case_id,rejection.status case_status,
               rejection.source_ap_ledger_id
        FROM source JOIN procurement_inspection_items inspection
          ON inspection.receipt_id=source.source_doc_id
         AND inspection.receipt_type||'_RECEIPT'=source.source_doc_type
         AND inspection.status<>'REVERSED'
        LEFT JOIN procurement_iqc_rejection_cases rejection
          ON rejection.inspection_item_id=inspection.id AND rejection.is_deleted=FALSE
    ), allowed AS (
        SELECT TRUE ok FROM procurement_iqc_rejection_cases rejection
        JOIN ar_ap_ledger credit ON credit.source_doc_id=rejection.id
          AND credit.source_doc_type=rejection.receipt_type||'_IQC_CREDIT'
          AND credit.direction='AP' AND credit.status=1 AND credit.is_deleted=FALSE
        WHERE rejection.id=p_allowed_case_id AND rejection.status='RETURN_RECORDED'
          AND rejection.source_ap_ledger_id=p_ledger_id
        UNION ALL
        SELECT TRUE FROM procurement_iqc_credit_slices slice
        JOIN procurement_iqc_rejection_cases rejection ON rejection.id=slice.case_id
        JOIN procurement_iqc_funding_slices funding ON funding.id=slice.funding_slice_id
        JOIN ar_ap_ledger credit ON credit.source_doc_id=slice.credit_document_id
          AND credit.source_doc_type=rejection.receipt_type||'_IQC_CREDIT'
          AND credit.direction='AP' AND credit.status=1 AND credit.is_deleted=FALSE
        WHERE slice.case_id=p_allowed_case_id AND funding.source_ap_ledger_id=p_ledger_id
          AND rejection.return_recorded_at IS NOT NULL AND rejection.status<>'REVERSED'
          AND fn_procurement_consideration_active('CREDIT',slice.id)
          AND fn_procurement_consideration_active('FUNDING',funding.id)
    )
    SELECT CASE
        WHEN NOT EXISTS(SELECT 1 FROM source) THEN NULL
        WHEN p_allowed_case_id IS NOT NULL AND EXISTS(SELECT 1 FROM allowed) THEN NULL
        WHEN EXISTS(SELECT 1 FROM linked WHERE status IN ('PENDING','PARTIAL'))
          THEN 'IQC待检或部分处置尚未结案'
        WHEN EXISTS(SELECT 1 FROM linked WHERE failed_base_qty>0
            AND COALESCE(case_status,'') NOT IN ('CREDIT_CONFIRMED','CLOSED_NO_CREDIT','REVERSED')
            AND NOT EXISTS(SELECT 1 FROM procurement_iqc_funding_slices
                WHERE case_id=linked.case_id AND fn_procurement_consideration_active('FUNDING',id)))
          THEN 'IQC不合格历史资金来源或供应商处理尚未闭环'
        WHEN EXISTS(SELECT 1 FROM procurement_iqc_funding_slices funding
            JOIN procurement_iqc_rejection_cases rejection ON rejection.id=funding.case_id
            WHERE funding.source_ap_ledger_id=p_ledger_id AND funding.parent_funding_slice_id IS NULL
              AND rejection.status<>'CLOSED_NO_CREDIT'
              AND fn_procurement_consideration_active('FUNDING',funding.id)
              AND fn_procurement_iqc_funding_unresolved(funding.id)>0)
          THEN 'IQC不合格尚未完成实际合格补回入库或退货减款'
        ELSE NULL
    END
$$;

-- Historical rows remain intact and must be explicitly reviewed before any new
-- classification or correcting finance document is accepted.
CREATE VIEW v_procurement_iqc_unclassified_consideration AS
SELECT allocation.id replacement_allocation_id,allocation.case_id,
       allocation.replacement_receipt_type receipt_type,allocation.replacement_receipt_id receipt_id,
       allocation.replacement_receipt_item_id receipt_item_id,allocation.allocated_base_qty,
       allocation.allocated_amount_original,allocation.allocated_amount_local,
       rejection.status case_status,rejection.credit_ledger_id,
       ledger.id replacement_ap_ledger_id,ledger.amount_original replacement_ap_original,
       ledger.amount_original_local replacement_ap_local
FROM procurement_iqc_replacement_allocations allocation
JOIN procurement_iqc_rejection_cases rejection ON rejection.id=allocation.case_id
LEFT JOIN ar_ap_ledger ledger ON ledger.source_doc_id=allocation.replacement_receipt_id
  AND ledger.source_doc_type=allocation.replacement_receipt_type||'_RECEIPT'
  AND ledger.direction='AP' AND ledger.status=1 AND ledger.is_deleted=FALSE
WHERE allocation.status='ACTIVE' AND NOT EXISTS(
    SELECT 1 FROM procurement_receipt_consideration_parts WHERE replacement_allocation_id=allocation.id);

CREATE OR REPLACE FUNCTION fn_assert_procurement_consideration_case(p_case UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_case RECORD; v_total RECORD; v_id UUID;
BEGIN
    SELECT * INTO v_case FROM procurement_iqc_rejection_cases WHERE id=p_case;
    IF NOT FOUND THEN RETURN; END IF;
    IF NOT EXISTS(SELECT 1 FROM procurement_iqc_funding_slices WHERE case_id=p_case) THEN RETURN; END IF;
    SELECT COALESCE(SUM(base_qty),0) qty,COALESCE(SUM(amount_original),0) original,
           COALESCE(SUM(amount_local),0) local INTO v_total
    FROM procurement_iqc_funding_slices WHERE case_id=p_case AND fn_procurement_consideration_active('FUNDING',id);
    IF v_case.status='REVERSED' THEN
        IF v_total.qty<>0 THEN RAISE EXCEPTION 'reversed failure retains active funding' USING ERRCODE='23514'; END IF;
    ELSIF v_total.qty IS DISTINCT FROM v_case.failed_base_qty THEN
        RAISE EXCEPTION 'failure generation and funding slices are not conserved' USING ERRCODE='23514';
    END IF;
    FOR v_id IN SELECT id FROM procurement_iqc_funding_slices WHERE case_id=p_case ORDER BY id
    LOOP PERFORM fn_assert_procurement_iqc_funding(v_id); END LOOP;
    FOR v_id IN SELECT part.id FROM procurement_receipt_consideration_parts part
        JOIN procurement_iqc_funding_slices funding ON funding.id=part.funding_slice_id
        WHERE funding.case_id=p_case ORDER BY part.id
    LOOP PERFORM fn_assert_procurement_consideration_part(v_id); END LOOP;
    FOR v_id IN SELECT DISTINCT credit_document_id FROM procurement_iqc_credit_slices WHERE case_id=p_case
    LOOP PERFORM fn_assert_procurement_credit_consideration(v_id); END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_procurement_consideration_target(p_kind TEXT,p_id UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_row RECORD; v_id UUID;
BEGIN
    CASE p_kind
    WHEN 'CONSIDERATION' THEN PERFORM fn_assert_procurement_consideration_part(p_id);
    WHEN 'QUALITY' THEN
        SELECT inspection_event_id INTO v_id FROM procurement_iqc_quality_consideration_parts WHERE id=p_id;
        PERFORM fn_assert_procurement_quality_consideration(v_id);
    WHEN 'FUNDING' THEN
        PERFORM fn_assert_procurement_iqc_funding(p_id);
        SELECT case_id INTO v_id FROM procurement_iqc_funding_slices WHERE id=p_id;
        PERFORM fn_assert_procurement_consideration_case(v_id);
    WHEN 'CREDIT' THEN
        SELECT credit_document_id INTO v_id FROM procurement_iqc_credit_slices WHERE id=p_id;
        PERFORM fn_assert_procurement_credit_consideration(v_id);
    WHEN 'STOCK' THEN
        SELECT stock_in_item_id INTO v_id FROM procurement_iqc_stock_consideration_parts WHERE id=p_id;
        PERFORM fn_assert_procurement_stock_consideration(v_id);
    WHEN 'SETTLEMENT' THEN PERFORM fn_assert_procurement_funding_settlement(p_id);
    ELSE RAISE EXCEPTION 'unknown consideration evidence type' USING ERRCODE='23514';
    END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_procurement_consideration_reversal(p_id UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_reversal RECORD; v_source RECORD; v_table TEXT; v_type TEXT; v_receipt UUID; v_status SMALLINT;
BEGIN
    SELECT * INTO v_reversal FROM procurement_iqc_consideration_reversals WHERE id=p_id;
    CASE v_reversal.target_kind
    WHEN 'CONSIDERATION' THEN
        SELECT receipt_type,receipt_id INTO v_source FROM procurement_receipt_consideration_parts WHERE id=v_reversal.target_id;
        v_type:=v_source.receipt_type; v_receipt:=v_source.receipt_id;
        IF EXISTS(SELECT 1 FROM procurement_iqc_quality_consideration_parts WHERE consideration_part_id=v_reversal.target_id
            AND fn_procurement_consideration_active('QUALITY',id)) THEN
            RAISE EXCEPTION 'consideration reversal retains quality shares' USING ERRCODE='23514';
        END IF;
    WHEN 'QUALITY' THEN
        SELECT inspection.status,inspection.receipt_type,inspection.receipt_id INTO v_source
        FROM procurement_iqc_quality_consideration_parts quality
        JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
        JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id
        WHERE quality.id=v_reversal.target_id;
        v_type:=v_source.receipt_type; v_receipt:=v_source.receipt_id;
        IF v_source.status IS DISTINCT FROM 'REVERSED'
           OR EXISTS(SELECT 1 FROM procurement_iqc_funding_slices WHERE quality_part_id=v_reversal.target_id
                AND fn_procurement_consideration_active('FUNDING',id))
           OR EXISTS(SELECT 1 FROM procurement_iqc_stock_consideration_parts WHERE quality_part_id=v_reversal.target_id
                AND fn_procurement_consideration_active('STOCK',id)) THEN
            RAISE EXCEPTION 'quality share reversal requires physical reversal and no descendants' USING ERRCODE='23514';
        END IF;
    WHEN 'FUNDING' THEN
        SELECT rejection.status,rejection.receipt_type,rejection.receipt_id INTO v_source
        FROM procurement_iqc_funding_slices funding
        JOIN procurement_iqc_rejection_cases rejection ON rejection.id=funding.case_id WHERE funding.id=v_reversal.target_id;
        v_type:=v_source.receipt_type; v_receipt:=v_source.receipt_id;
        IF v_source.status IS DISTINCT FROM 'REVERSED'
           OR EXISTS(SELECT 1 FROM procurement_receipt_consideration_parts WHERE funding_slice_id=v_reversal.target_id
                AND fn_procurement_consideration_active('CONSIDERATION',id))
           OR EXISTS(SELECT 1 FROM procurement_iqc_credit_slices WHERE funding_slice_id=v_reversal.target_id
                AND fn_procurement_consideration_active('CREDIT',id))
           OR EXISTS(SELECT 1 FROM procurement_iqc_funding_settlements WHERE funding_slice_id=v_reversal.target_id
                AND fn_procurement_consideration_active('SETTLEMENT',id)) THEN
            RAISE EXCEPTION 'funding reversal requires a reversed source and no active descendants' USING ERRCODE='23514';
        END IF;
    WHEN 'CREDIT' THEN
        SELECT credit_document_id INTO v_source FROM procurement_iqc_credit_slices WHERE id=v_reversal.target_id;
        IF v_source.credit_document_id IS NULL
           OR EXISTS(SELECT 1 FROM ar_ap_ledger WHERE source_doc_id=v_source.credit_document_id AND direction='AP'
                AND source_doc_type IN ('PURCHASE_IQC_CREDIT','SUBCONTRACT_IQC_CREDIT') AND status=1 AND is_deleted=FALSE)
           OR EXISTS(SELECT 1 FROM procurement_receipt_consideration_parts WHERE credit_slice_id=v_reversal.target_id
                AND fn_procurement_consideration_active('CONSIDERATION',id))
           OR EXISTS(SELECT 1 FROM procurement_iqc_funding_settlements WHERE source_kind='CREDIT' AND source_id=v_reversal.target_id
                AND fn_procurement_consideration_active('SETTLEMENT',id)) THEN
            RAISE EXCEPTION 'credit reversal requires its payable reversal and no repurchased descendants' USING ERRCODE='23514';
        END IF;
    WHEN 'STOCK' THEN
        SELECT inspection.status,inspection.receipt_type,inspection.receipt_id INTO v_source
        FROM procurement_iqc_stock_consideration_parts stock
        JOIN procurement_iqc_stock_in_batch_items item ON item.id=stock.stock_in_item_id
        JOIN procurement_inspection_items inspection ON inspection.id=item.inspection_item_id WHERE stock.id=v_reversal.target_id;
        v_type:=v_source.receipt_type; v_receipt:=v_source.receipt_id;
        IF v_source.status IS DISTINCT FROM 'REVERSED'
           OR EXISTS(SELECT 1 FROM procurement_iqc_funding_settlements WHERE source_kind='STOCK_IN'
                AND source_id=v_reversal.target_id AND fn_procurement_consideration_active('SETTLEMENT',id)) THEN
            RAISE EXCEPTION 'stock consideration reversal requires actual warehouse reversal' USING ERRCODE='23514';
        END IF;
    WHEN 'SETTLEMENT' THEN
        SELECT source_kind,source_id INTO v_source FROM procurement_iqc_funding_settlements WHERE id=v_reversal.target_id;
        IF v_source.source_id IS NULL OR fn_procurement_consideration_active(
            CASE v_source.source_kind WHEN 'CREDIT' THEN 'CREDIT' ELSE 'STOCK' END,v_source.source_id) THEN
            RAISE EXCEPTION 'settlement reversal requires reversal of its exact terminal fact' USING ERRCODE='23514';
        END IF;
    END CASE;
    IF v_reversal.target_kind NOT IN ('CREDIT','SETTLEMENT') THEN
        IF v_receipt IS NULL THEN RAISE EXCEPTION 'consideration reversal source is missing' USING ERRCODE='23514'; END IF;
        v_table:=CASE v_type WHEN 'PURCHASE' THEN 'purchase_receipts' ELSE 'subcontract_receipts' END;
        EXECUTE format('SELECT status FROM %I WHERE id=$1',v_table) INTO v_status USING v_receipt;
        IF v_status IS DISTINCT FROM -1::smallint THEN
            RAISE EXCEPTION 'consideration reversal must follow its actual source receipt reversal' USING ERRCODE='23514';
        END IF;
    END IF;
    PERFORM fn_assert_procurement_consideration_target(v_reversal.target_kind,v_reversal.target_id);
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_procurement_consideration()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_id UUID; v_type TEXT; v_receipt UUID; v_row JSONB;
BEGIN
    v_row:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
    CASE TG_TABLE_NAME
    WHEN 'procurement_receipt_consideration_parts' THEN PERFORM fn_assert_procurement_consideration_part(NEW.id);
    WHEN 'procurement_iqc_quality_consideration_parts' THEN PERFORM fn_assert_procurement_quality_consideration(NEW.inspection_event_id);
    WHEN 'procurement_iqc_funding_slices' THEN PERFORM fn_assert_procurement_consideration_case(NEW.case_id);
    WHEN 'procurement_iqc_credit_slices' THEN PERFORM fn_assert_procurement_credit_consideration(NEW.credit_document_id);
    WHEN 'procurement_iqc_credit_documents' THEN PERFORM fn_assert_procurement_credit_consideration(NEW.id);
    WHEN 'procurement_iqc_credit_case_allocations' THEN PERFORM fn_assert_procurement_credit_consideration(NEW.credit_document_id);
    WHEN 'procurement_iqc_stock_consideration_parts' THEN PERFORM fn_assert_procurement_stock_consideration(NEW.stock_in_item_id);
    WHEN 'procurement_iqc_funding_settlements' THEN PERFORM fn_assert_procurement_funding_settlement(NEW.id);
    WHEN 'procurement_iqc_consideration_reversals' THEN PERFORM fn_assert_procurement_consideration_reversal(NEW.id);
    WHEN 'procurement_iqc_rejection_cases' THEN PERFORM fn_assert_procurement_consideration_case((v_row->>'id')::uuid);
    WHEN 'procurement_iqc_replacement_allocations' THEN
        FOR v_id IN SELECT id FROM procurement_receipt_consideration_parts
            WHERE replacement_allocation_id=(v_row->>'id')::uuid ORDER BY id
        LOOP PERFORM fn_assert_procurement_consideration_part(v_id); END LOOP;
    WHEN 'procurement_inspection_events' THEN PERFORM fn_assert_procurement_quality_consideration((v_row->>'id')::uuid);
    WHEN 'procurement_inspection_items' THEN
        FOR v_id IN SELECT id FROM procurement_inspection_events WHERE inspection_item_id=(v_row->>'id')::uuid
        LOOP PERFORM fn_assert_procurement_quality_consideration(v_id); END LOOP;
        FOR v_id IN SELECT id FROM procurement_iqc_stock_in_batch_items WHERE inspection_item_id=(v_row->>'id')::uuid
        LOOP PERFORM fn_assert_procurement_stock_consideration(v_id); END LOOP;
    WHEN 'procurement_iqc_stock_in_batch_items' THEN PERFORM fn_assert_procurement_stock_consideration((v_row->>'id')::uuid);
    WHEN 'ar_ap_ledger' THEN
        IF v_row->>'source_doc_type' IN ('PURCHASE_RECEIPT','SUBCONTRACT_RECEIPT') THEN
            v_type:=replace(v_row->>'source_doc_type','_RECEIPT',''); v_receipt:=(v_row->>'source_doc_id')::uuid;
        ELSIF v_row->>'source_doc_type' IN ('PURCHASE_IQC_CREDIT','SUBCONTRACT_IQC_CREDIT')
            AND EXISTS(SELECT 1 FROM procurement_iqc_credit_slices WHERE credit_document_id=(v_row->>'source_doc_id')::uuid) THEN
            PERFORM fn_assert_procurement_credit_consideration((v_row->>'source_doc_id')::uuid);
        END IF;
    ELSE
        v_type:=CASE WHEN TG_TABLE_NAME LIKE 'purchase_%' THEN 'PURCHASE' ELSE 'SUBCONTRACT' END;
        v_receipt:=CASE WHEN TG_TABLE_NAME LIKE '%_items' THEN (v_row->>'receipt_id')::uuid ELSE (v_row->>'id')::uuid END;
    END CASE;
    IF v_receipt IS NOT NULL THEN PERFORM fn_assert_procurement_consideration_receipt(v_type,v_receipt); END IF;
    RETURN NULL;
END;
$$;

DO $$
DECLARE v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'procurement_receipt_consideration_parts','procurement_iqc_quality_consideration_parts',
        'procurement_iqc_funding_slices','procurement_iqc_credit_documents','procurement_iqc_credit_case_allocations','procurement_iqc_credit_slices','procurement_iqc_stock_consideration_parts',
        'procurement_iqc_funding_settlements','procurement_iqc_consideration_reversals',
        'purchase_receipts','purchase_receipt_items','subcontract_receipts','subcontract_receipt_items',
        'procurement_iqc_rejection_cases','procurement_iqc_replacement_allocations','ar_ap_ledger',
        'procurement_inspection_events','procurement_inspection_items','procurement_iqc_stock_in_batch_items']
    LOOP
        EXECUTE format('CREATE CONSTRAINT TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I
            DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_procurement_consideration()',
            'trg_'||v_table||'_consideration',v_table);
        EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER %I',v_table,'trg_'||v_table||'_consideration');
    END LOOP;
END;
$$;

-- Controlled historical correction and real service acceptance are still pending.
-- This file remains a staged candidate until those paths have passed.

-- Only an unused exact V510 credit share can be reversed beside other active replacements.
CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_rejection_case_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.row_version <> OLD.row_version + 1 THEN
        RAISE EXCEPTION USING ERRCODE='40001',
            MESSAGE='IQC rejection case version must advance exactly once',
            CONSTRAINT='procurement_iqc_rejection_case_cas_guard';
    END IF;
    IF (NEW.receipt_type,NEW.receipt_id,NEW.receipt_item_id,
        NEW.inspection_item_id,NEW.order_item_id,NEW.receipt_bill_no,
        NEW.order_bill_no,NEW.owner_user_id,
        NEW.supplier_id,NEW.currency_id,NEW.exchange_rate,NEW.tax_rate,
        NEW.settlement_method_id,NEW.goods_id,NEW.color_id,NEW.unit_id,
        NEW.unit_rate,NEW.received_base_qty,NEW.received_qty,
        NEW.received_amount_original,NEW.received_amount_local)
       IS DISTINCT FROM
       (OLD.receipt_type,OLD.receipt_id,OLD.receipt_item_id,
        OLD.inspection_item_id,OLD.order_item_id,OLD.receipt_bill_no,
        OLD.order_bill_no,OLD.owner_user_id,
        OLD.supplier_id,OLD.currency_id,OLD.exchange_rate,OLD.tax_rate,
        OLD.settlement_method_id,OLD.goods_id,OLD.color_id,OLD.unit_id,
        OLD.unit_rate,OLD.received_base_qty,OLD.received_qty,
        OLD.received_amount_original,OLD.received_amount_local) THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='IQC rejection commercial/source snapshot is immutable',
            CONSTRAINT='procurement_iqc_rejection_snapshot_guard';
    END IF;
    IF (NEW.failed_base_qty,NEW.failed_qty,
        NEW.failed_amount_original,NEW.failed_amount_local)
       IS DISTINCT FROM
       (OLD.failed_base_qty,OLD.failed_qty,
        OLD.failed_amount_original,OLD.failed_amount_local)
       AND NOT (
           OLD.status IN('PENDING_RETURN','FINANCE_EXCEPTION')
           AND NEW.status IN('PENDING_RETURN','FINANCE_EXCEPTION')
           AND OLD.return_recorded_at IS NULL
           AND NEW.return_recorded_at IS NULL
       ) THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='IQC rejection amount/AP snapshot is frozen after physical return',
            CONSTRAINT='procurement_iqc_rejection_amount_stage_guard';
    END IF;
    IF NEW.source_ap_ledger_id IS DISTINCT FROM OLD.source_ap_ledger_id
       AND NOT (
           OLD.status='FINANCE_EXCEPTION'
           AND NEW.status IN(
               'FINANCE_EXCEPTION','PENDING_RETURN','RETURN_RECORDED')
       ) THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='IQC rejection source AP can change only during finance exception repair',
            CONSTRAINT='procurement_iqc_rejection_source_ap_stage_guard';
    END IF;
    IF EXISTS(
        SELECT 1 FROM procurement_iqc_replacement_allocations allocation
        WHERE allocation.case_id=OLD.id AND allocation.status='ACTIVE')
       AND (
           (OLD.return_recorded_at IS NOT NULL
            AND NEW.return_recorded_at IS NULL)
           OR NEW.status='REVERSED'
           OR (OLD.status IN('CREDIT_CONFIRMED','CLOSED_NO_CREDIT')
               AND NEW.status IS DISTINCT FROM OLD.status
               AND NOT (OLD.status='CREDIT_CONFIRMED' AND NEW.status='RETURN_RECORDED'
                   AND EXISTS(SELECT 1 FROM procurement_iqc_consideration_reversals reversal
                       JOIN procurement_iqc_credit_slices credit ON credit.id=reversal.target_id
                       WHERE reversal.target_kind='CREDIT' AND credit.case_id=OLD.id
                         AND reversal.xmin::text::bigint=(pg_current_xact_id()::text::numeric%4294967296)::bigint)
                   AND NOT EXISTS(SELECT 1 FROM procurement_receipt_consideration_parts part
                       JOIN procurement_iqc_credit_slices credit ON credit.id=part.credit_slice_id
                       WHERE credit.case_id=OLD.id AND NOT fn_procurement_consideration_active('CREDIT',credit.id)
                         AND fn_procurement_consideration_active('CONSIDERATION',part.id))))
       ) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='active replacement receipt must be reversed before IQC case reversal',
            CONSTRAINT='procurement_iqc_rejection_active_replacement_guard';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- Exact finite products for future approval and same-transaction quantity revisions.
CREATE OR REPLACE FUNCTION fn_guard_procurement_finance_commercial_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_currency UUID;
    v_rate NUMERIC;
    v_tax NUMERIC;
    v_settlement UUID;
    v_total_original NUMERIC;
    v_total_local NUMERIC;
    v_item_original NUMERIC;
    v_item_local NUMERIC;
    v_item_count BIGINT;
    v_invalid_items BIGINT;
    v_order_found BOOLEAN:=FALSE;
    v_currency_active BOOLEAN;
    v_settlement_active BOOLEAN;
BEGIN
    IF NEW.status NOT IN ('PENDING', 'APPROVED') THEN RETURN NEW; END IF;
    IF NEW.order_type='PURCHASE' THEN
        SELECT currency_id,exchange_rate,tax_rate,settlement_method_id,
               total_original,total_local
          INTO v_currency,v_rate,v_tax,v_settlement,v_total_original,v_total_local
          FROM purchase_orders
         WHERE id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE
         FOR UPDATE;
        v_order_found:=FOUND;
        PERFORM 1 FROM purchase_order_items
         WHERE order_id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE
         ORDER BY id FOR UPDATE;
        SELECT COUNT(*),COALESCE(SUM(amount_original),0),COALESCE(SUM(amount_local),0),
               COUNT(*) FILTER(WHERE qty IS NULL OR qty<=0 OR price IS NULL OR price<0
                 OR amount_original IS NULL OR amount_original<0
                 OR amount_local IS NULL OR amount_local<0
                 OR amount_original<>(qty*price)
                 OR amount_local<>(amount_original*v_rate))
          INTO v_item_count,v_item_original,v_item_local,v_invalid_items
          FROM purchase_order_items
         WHERE order_id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE;
    ELSIF NEW.order_type='SUBCONTRACT' THEN
        SELECT currency_id,exchange_rate,tax_rate,settlement_method_id,
               total_original,total_local
          INTO v_currency,v_rate,v_tax,v_settlement,v_total_original,v_total_local
          FROM subcontract_orders
         WHERE id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE
         FOR UPDATE;
        v_order_found:=FOUND;
        PERFORM 1 FROM subcontract_order_items
         WHERE order_id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE
         ORDER BY id FOR UPDATE;
        SELECT COUNT(*),COALESCE(SUM(amount_original),0),COALESCE(SUM(amount_local),0),
               COUNT(*) FILTER(WHERE qty IS NULL OR qty<=0 OR price IS NULL OR price<0
                 OR amount_original IS NULL OR amount_original<0
                 OR amount_local IS NULL OR amount_local<0
                 OR amount_original<>(qty*price)
                 OR amount_local<>(amount_original*v_rate))
          INTO v_item_count,v_item_original,v_item_local,v_invalid_items
          FROM subcontract_order_items
         WHERE order_id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE;
    ELSE
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='unsupported procurement finance order type',
            CONSTRAINT='procurement_finance_commercial_snapshot_guard';
    END IF;
    IF NOT v_order_found THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='procurement finance source order is missing',
            CONSTRAINT='procurement_finance_commercial_snapshot_guard';
    END IF;
    SELECT EXISTS(SELECT 1 FROM currencies
        WHERE id=v_currency AND status='使用' AND COALESCE(is_deleted,FALSE)=FALSE)
      INTO v_currency_active;
    SELECT EXISTS(SELECT 1 FROM settlement_methods
        WHERE id=v_settlement AND status='使用' AND COALESCE(is_deleted,FALSE)=FALSE)
      INTO v_settlement_active;
    IF v_currency IS NULL OR NOT COALESCE(v_currency_active,FALSE)
       OR v_rate IS NULL OR v_rate<=0
       OR v_tax IS NULL OR v_tax<0 OR v_tax>100
       OR v_settlement IS NULL OR NOT COALESCE(v_settlement_active,FALSE) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance review requires active currency, positive rate, 0..100 tax and active settlement method',
            CONSTRAINT='procurement_finance_commercial_snapshot_guard';
    END IF;
    IF v_item_count=0 OR v_invalid_items<>0
       OR v_total_original IS DISTINCT FROM v_item_original
       OR v_total_local IS DISTINCT FROM v_item_local
       OR NEW.amount_snapshot IS DISTINCT FROM v_total_local THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='procurement finance snapshot amount or locked item set is incomplete/inconsistent',
            CONSTRAINT='procurement_finance_commercial_snapshot_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_is_proven_procurement_qty_revision(p_table TEXT,p_old JSONB,p_new JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE prefix TEXT; kind TEXT; exchange NUMERIC; expected_original NUMERIC; expected_local NUMERIC;
BEGIN
    IF p_table NOT IN ('purchase_order_items','subcontract_order_items') THEN RETURN FALSE; END IF;
    prefix:=CASE p_table WHEN 'purchase_order_items' THEN 'purchase' ELSE 'subcontract' END;
    kind:=CASE prefix WHEN 'purchase' THEN 'PURCHASE' ELSE 'SUBCONTRACT' END;
    IF (p_old-ARRAY['qty','amount_original','amount_local','updated_at','updated_by'])
         IS DISTINCT FROM (p_new-ARRAY['qty','amount_original','amount_local','updated_at','updated_by']) THEN RETURN FALSE; END IF;
    IF NOT EXISTS(SELECT 1 FROM procurement_order_source_revisions r WHERE r.created_txid=txid_current()
        AND r.order_type=kind AND r.order_id=(p_old->>'order_id')::uuid AND r.order_item_id=(p_old->>'id')::uuid
        AND r.old_qty=(p_old->>'qty')::numeric AND r.new_qty=(p_new->>'qty')::numeric
        AND (r.before_item-ARRAY['updated_at','updated_by'])=(p_old-ARRAY['updated_at','updated_by'])) THEN RETURN FALSE; END IF;
    EXECUTE format('SELECT exchange_rate FROM %I WHERE id=$1 AND status=1 AND is_deleted=FALSE',prefix||'_orders')
        INTO exchange USING (p_old->>'order_id')::uuid;
    IF exchange IS NULL OR exchange<=0 THEN RETURN FALSE; END IF;
    expected_original:=((p_new->>'qty')::numeric*(p_old->>'price')::numeric);
    expected_local:=(expected_original*exchange);
    RETURN expected_original IS NOT NULL AND expected_original=(p_new->>'amount_original')::numeric
        AND expected_local=(p_new->>'amount_local')::numeric;
END;
$$;

CREATE OR REPLACE FUNCTION fn_is_proven_procurement_header_revision(p_kind TEXT,p_old JSONB,p_new JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE expected_original NUMERIC; expected_local NUMERIC; prefix TEXT;
BEGIN
    IF (p_old-ARRAY['total_original','total_local','updated_at','updated_by'])
        IS DISTINCT FROM (p_new-ARRAY['total_original','total_local','updated_at','updated_by']) THEN RETURN FALSE; END IF;
    IF NOT EXISTS(SELECT 1 FROM procurement_order_source_revisions WHERE created_txid=txid_current()
        AND order_type=p_kind AND order_id=(p_old->>'id')::uuid) THEN RETURN FALSE; END IF;
    prefix:=CASE p_kind WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END;
    -- Hibernate may flush the header before its modified items; prove the prepared final amounts.
    EXECUTE format('SELECT COALESCE(SUM(CASE WHEN r.id IS NULL THEN i.amount_original ELSE (r.new_qty*i.price) END),0),
        COALESCE(SUM(CASE WHEN r.id IS NULL THEN i.amount_local ELSE (r.new_qty*i.price*$2) END),0)
        FROM %I i LEFT JOIN procurement_order_source_revisions r ON r.order_item_id=i.id AND r.order_type=$3
            AND r.created_txid=txid_current() WHERE i.order_id=$1 AND i.is_deleted=FALSE',prefix||'_order_items')
        INTO expected_original,expected_local USING (p_old->>'id')::uuid,(p_old->>'exchange_rate')::numeric,p_kind;
    RETURN expected_original=(p_new->>'total_original')::numeric AND expected_local=(p_new->>'total_local')::numeric;
END;
$$;

-- Physical replacement entitlement is quantity; commercial projections never consume its funding balance.
CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_replacement_identity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_case RECORD;
    v_receipt_id UUID;
    v_order_item_id UUID;
    v_goods_id UUID;
    v_color_id UUID;
    v_unit_id UUID;
    v_unit_rate NUMERIC(18,6);
    v_receipt_qty NUMERIC(18,4);
    v_receipt_original NUMERIC;
    v_receipt_local NUMERIC;
    v_case_qty NUMERIC(18,4);
    v_case_base NUMERIC(18,4);
    v_case_original NUMERIC;
    v_case_local NUMERIC;
    v_item_qty NUMERIC(18,4);
    v_item_base NUMERIC(18,4);
    v_item_original NUMERIC;
    v_item_local NUMERIC;
BEGIN
    SELECT receipt_type,order_item_id,goods_id,color_id,unit_id,unit_rate,
           failed_qty,failed_base_qty,failed_amount_original,
           failed_amount_local,return_recorded_at,status
      INTO v_case
    FROM procurement_iqc_rejection_cases
    WHERE id=NEW.case_id AND is_deleted=FALSE
    FOR UPDATE;
    IF NOT FOUND OR v_case.return_recorded_at IS NULL
       OR v_case.status NOT IN(
           'RETURN_RECORDED','CREDIT_CONFIRMED',
           'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
       OR v_case.receipt_type<>NEW.replacement_receipt_type THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='replacement allocation requires an active physically returned IQC case',
            CONSTRAINT='procurement_iqc_replacement_case_guard';
    END IF;

    IF NEW.replacement_receipt_type='PURCHASE' THEN
        SELECT item.receipt_id,item.order_item_id,item.goods_id,item.color_id,
               item.unit_id,item.unit_rate,item.qty,item.amount_original,
               item.amount_local
          INTO v_receipt_id,v_order_item_id,v_goods_id,v_color_id,
               v_unit_id,v_unit_rate,v_receipt_qty,v_receipt_original,
               v_receipt_local
        FROM purchase_receipt_items item
        JOIN purchase_receipts receipt ON receipt.id=item.receipt_id
        WHERE item.id=NEW.replacement_receipt_item_id
          AND receipt.id=NEW.replacement_receipt_id
          AND receipt.status IN(0,1)
          AND item.is_deleted=FALSE AND receipt.is_deleted=FALSE;
    ELSE
        SELECT item.receipt_id,item.order_item_id,item.goods_id,item.color_id,
               item.unit_id,item.unit_rate,item.qty,item.amount_original,
               item.amount_local
          INTO v_receipt_id,v_order_item_id,v_goods_id,v_color_id,
               v_unit_id,v_unit_rate,v_receipt_qty,v_receipt_original,
               v_receipt_local
        FROM subcontract_receipt_items item
        JOIN subcontract_receipts receipt ON receipt.id=item.receipt_id
        WHERE item.id=NEW.replacement_receipt_item_id
          AND receipt.id=NEW.replacement_receipt_id
          AND receipt.status IN(0,1)
          AND item.is_deleted=FALSE AND receipt.is_deleted=FALSE;
    END IF;
    IF v_receipt_id IS NULL
       OR v_order_item_id<>v_case.order_item_id
       OR v_goods_id<>v_case.goods_id
       OR v_color_id IS DISTINCT FROM v_case.color_id
       OR v_unit_id IS DISTINCT FROM v_case.unit_id
       OR v_unit_rate IS DISTINCT FROM v_case.unit_rate THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='replacement receipt item differs from the returned IQC source identity',
            CONSTRAINT='procurement_iqc_replacement_receipt_identity_guard';
    END IF;

    IF NEW.status='ACTIVE' THEN
        SELECT COALESCE(SUM(allocated_qty),0),
               COALESCE(SUM(allocated_base_qty),0),
               COALESCE(SUM(allocated_amount_original),0),
               COALESCE(SUM(allocated_amount_local),0)
          INTO v_case_qty,v_case_base,v_case_original,v_case_local
        FROM procurement_iqc_replacement_allocations
        WHERE case_id=NEW.case_id AND status='ACTIVE'
          AND id<>NEW.id;
        v_case_qty:=v_case_qty+NEW.allocated_qty;
        v_case_base:=v_case_base+NEW.allocated_base_qty;
        v_case_original:=v_case_original+NEW.allocated_amount_original;
        v_case_local:=v_case_local+NEW.allocated_amount_local;
        IF v_case_qty>v_case.failed_qty
           OR v_case_base>v_case.failed_base_qty THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='replacement allocation exceeds the returned IQC failure slice',
                CONSTRAINT='procurement_iqc_replacement_case_capacity_guard';
        END IF;

        SELECT COALESCE(SUM(allocated_qty),0),
               COALESCE(SUM(allocated_base_qty),0),
               COALESCE(SUM(allocated_amount_original),0),
               COALESCE(SUM(allocated_amount_local),0)
          INTO v_item_qty,v_item_base,v_item_original,v_item_local
        FROM procurement_iqc_replacement_allocations
        WHERE replacement_receipt_item_id=NEW.replacement_receipt_item_id
          AND status='ACTIVE' AND id<>NEW.id;
        v_item_qty:=v_item_qty+NEW.allocated_qty;
        v_item_base:=v_item_base+NEW.allocated_base_qty;
        v_item_original:=v_item_original+NEW.allocated_amount_original;
        v_item_local:=v_item_local+NEW.allocated_amount_local;
        IF v_item_qty>v_receipt_qty
           OR v_item_base>round(v_receipt_qty*v_unit_rate,4) THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='replacement allocations exceed the authoritative receipt item',
                CONSTRAINT='procurement_iqc_replacement_item_capacity_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DO $reset$
DECLARE definition TEXT;needle TEXT:='(''stock_value_postings'', ''CLEAR'')';v_table TEXT; additions TEXT:='';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'V510 cannot safely register procurement consideration reset policy';
    END IF;
    FOREACH v_table IN ARRAY ARRAY[
        'procurement_receipt_consideration_parts','procurement_iqc_quality_consideration_parts',
        'procurement_iqc_funding_slices','procurement_iqc_credit_documents','procurement_iqc_credit_case_allocations',
        'procurement_iqc_credit_slices','procurement_iqc_stock_consideration_parts','procurement_iqc_funding_settlements',
        'procurement_iqc_consideration_reversals','procurement_iqc_consideration_review_approvals']
    LOOP
        IF position(format('(%L,',v_table) IN definition)>0 THEN
            RAISE EXCEPTION 'V510 consideration reset table already registered: %',v_table;
        END IF;
        additions:=additions||format(E',\n            (%L, ''CLEAR'')',v_table);
    END LOOP;
    EXECUTE replace(definition,needle,needle||additions);
END;
$reset$;
