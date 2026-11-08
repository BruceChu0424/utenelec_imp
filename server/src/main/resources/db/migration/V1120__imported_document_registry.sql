-- Imported-document provenance is a read predicate on every business list, badge
-- and count. Evaluating the V926/V933 graph walk per listed row made reads
-- traverse whole ancestor graphs (1.8ms hot / 10.6ms cold per native row).
-- This migration materializes the authoritative verdict once and keeps writes on
-- the authoritative walk. No business row, status, quantity, amount, source or
-- guard membership changes.
--
-- Registry invariant: for every row of a guarded relation with a UUID identity,
--   registered(table,id)  <=>  the V933 walk classifies the row as imported.
-- All imported rows are registered (direct legacy keys and inherited ones), so
-- reads need one indexed EXISTS for typed, identity and polymorphic callers alike.
-- (The plan sketched inherited-only registration; reads by (table,id), typed
-- polymorphic sources and Criteria entities that never map legacy_import_run_id
-- cannot see the row's own keys, and stock_movements has no legacy_id at all:
-- its imports are 100% inherited from stock documents.)
--
-- Why the registry stays exact: a runtime session can never create, modify or
-- delete an imported row (the guard rejects OLD/NEW verdicts), and a runtime
-- write that is not imported cannot change any other row's verdict. Verdicts
-- change only under the maintenance identity (fn_imported_business_document_maintenance_allowed).
-- Row-local maintenance writes keep the registry exact inside the guard below.
-- Maintenance contract: an incremental import, a DBA repair, a new FK/guard/root,
-- a scope mapping change or any write with the guard disabled can change other
-- rows' verdicts; it must run fn_refresh_imported_document_registry(<table>) for
-- every affected relation in the same transaction. The runtime account stays uten.

CREATE TABLE public.imported_document_registry (
    table_name text NOT NULL,
    row_id uuid NOT NULL,
    registered_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT imported_document_registry_pkey PRIMARY KEY (table_name, row_id)
);
COMMENT ON TABLE public.imported_document_registry IS
 'Read-side materialization of the imported-business provenance verdict (V926/V933 walk). Rebuildable by fn_refresh_imported_document_registry; writes keep the authoritative walk.';

-- Direct import credentials exactly as the walk reads them from a row image.
CREATE FUNCTION public.fn_imported_business_document_direct_key(p_row jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT p_row->>'legacy_id' IS NOT NULL OR NULLIF(p_row->>'legacy_import_run_id','') IS NOT NULL
$$;

-- Criteria/bounded read entry. Native SQL inlines the same EXISTS through
-- ImportedBusinessDocumentScope so the planner can choose an anti-join.
CREATE FUNCTION public.fn_imported_business_document_registered(p_table text,p_id uuid)
RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT EXISTS(SELECT 1 FROM public.imported_document_registry registry
                  WHERE registry.table_name=p_table AND registry.row_id=p_id)
$$;

-- Authority: (a) direct key, (b) registered verdict, (c) the unchanged V933 walk.
-- A registration is never created without the walk's proof, so (b) only
-- shortcuts an import the walk would also find; a missing registration falls
-- through to (c). The walk itself (_internal) never consults the registry.
CREATE OR REPLACE FUNCTION public.fn_imported_business_document_row(p_table text,p_row jsonb)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $row$
DECLARE identity text;
BEGIN
    IF p_row IS NULL OR p_table IS NULL OR NOT public.fn_imported_business_document_table(p_table) THEN
        RETURN false;
    END IF;
    IF public.fn_imported_business_document_direct_key(p_row) THEN RETURN true; END IF;
    identity:=p_row->>'id';
    IF identity ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        IF EXISTS(SELECT 1 FROM public.imported_document_registry registry
                  WHERE registry.table_name=p_table AND registry.row_id=identity::uuid) THEN
            RETURN true;
        END IF;
    END IF;
    RETURN public.fn_imported_business_document_row_internal(p_table,p_row,ARRAY[]::text[]);
END $row$;

-- Every input the verdict reads from the row itself: own keys, identity, the
-- eleven typed polymorphic pairs, platform field scope and every FK column that
-- references a UUID id. The FK set is read from the same catalog as the walk at
-- call time (a superset of the walk's edges), never frozen into trigger arguments,
-- so a later FK cannot be skipped. Equal inputs give OLD and NEW the same verdict.
CREATE FUNCTION public.fn_imported_business_document_judgment_changed(p_relation oid,p_old jsonb,p_new jsonb)
RETURNS boolean LANGUAGE plpgsql STABLE SET search_path=pg_catalog,public AS $changed$
DECLARE column_name text;
BEGIN
    IF p_old IS NULL OR p_new IS NULL THEN RETURN true; END IF;
    IF p_old=p_new THEN RETURN false; END IF;
    FOREACH column_name IN ARRAY ARRAY[
        'id','record_id','legacy_id','legacy_import_run_id','scope','source_document_id',
        'source_doc_type','source_doc_id','source_table','source_id','parent_table','parent_id',
        'owner_type','owner_id','document_type','document_id','record_type','family',
        'receipt_type','receipt_id','receipt_item_id','order_type','order_id','order_item_id']
    LOOP
        IF p_old->column_name IS DISTINCT FROM p_new->column_name THEN RETURN true; END IF;
    END LOOP;
    RETURN EXISTS(
        SELECT 1 FROM pg_constraint key
        CROSS JOIN LATERAL generate_subscripts(key.conkey,1) position(index)
        JOIN pg_attribute child_column ON child_column.attrelid=key.conrelid
            AND child_column.attnum=key.conkey[position.index]
        JOIN pg_attribute parent_column ON parent_column.attrelid=key.confrelid
            AND parent_column.attnum=key.confkey[position.index]
        WHERE key.contype='f' AND key.conrelid=p_relation
          AND parent_column.attname='id' AND parent_column.atttypid='uuid'::regtype
          AND p_old->(child_column.attname::text) IS DISTINCT FROM p_new->(child_column.attname::text));
END $changed$;

-- The proof used to maintain the registry: a direct key or the pure V933 walk.
-- Beyond the supported graph size/depth the authority fails closed on every
-- runtime write; the registry records only proven imports.
CREATE FUNCTION public.fn_imported_document_registry_proven(p_table text,p_row jsonb)
RETURNS boolean LANGUAGE plpgsql STABLE SET search_path=pg_catalog,public AS $proven$
BEGIN
    IF p_row IS NULL THEN RETURN false; END IF;
    IF public.fn_imported_business_document_direct_key(p_row) THEN RETURN true; END IF;
    BEGIN
        RETURN public.fn_imported_business_document_row_internal(p_table,p_row,ARRAY[]::text[]);
    EXCEPTION WHEN SQLSTATE '54001' THEN
        RETURN false;
    END;
END $proven$;

-- Registry writes for the maintenance branch of the guard. The guard decides
-- maintenance by session identity, while table privileges follow current_user
-- (a maintenance session may SET ROLE to the runtime account), so the writes run
-- as the registry owner and re-check the same session-identity rule first.
CREATE FUNCTION public.fn_imported_document_registry_sync(p_table text,p_row jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $sync$
DECLARE identity text:=p_row->>'id';
BEGIN
    IF NOT public.fn_imported_business_document_maintenance_allowed() THEN
        RAISE EXCEPTION '导入单据登记只能由维护身份写入' USING ERRCODE='42501';
    END IF;
    IF identity IS NULL OR identity !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR NOT public.fn_imported_business_document_table(p_table) THEN
        RETURN;
    END IF;
    IF public.fn_imported_document_registry_proven(p_table,p_row) THEN
        INSERT INTO public.imported_document_registry(table_name,row_id)
        VALUES(p_table,identity::uuid) ON CONFLICT DO NOTHING;
    ELSE
        DELETE FROM public.imported_document_registry
        WHERE table_name=p_table AND row_id=identity::uuid;
    END IF;
END $sync$;

-- A NULL identity retires every registration of the relation (maintenance TRUNCATE).
CREATE FUNCTION public.fn_imported_document_registry_forget(p_table text,p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $forget$
BEGIN
    IF NOT public.fn_imported_business_document_maintenance_allowed() THEN
        RAISE EXCEPTION '导入单据登记只能由维护身份写入' USING ERRCODE='42501';
    END IF;
    DELETE FROM public.imported_document_registry
    WHERE table_name=p_table AND (p_id IS NULL OR row_id=p_id);
END $forget$;

-- Runtime verdicts are unchanged: OLD for UPDATE/DELETE, NEW for INSERT/UPDATE.
-- An UPDATE that leaves every verdict input equal skips the second walk.
-- Maintenance writes keep their exception and now also keep this row's registration.
CREATE OR REPLACE FUNCTION public.fn_guard_imported_business_document_archive() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $guard$
DECLARE old_row jsonb; new_row jsonb;
BEGIN
    IF public.fn_imported_business_document_maintenance_allowed() THEN
        IF TG_OP='DELETE' THEN
            old_row:=to_jsonb(OLD);
            IF old_row->>'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
                PERFORM public.fn_imported_document_registry_forget(TG_TABLE_NAME,(old_row->>'id')::uuid);
            END IF;
            RETURN OLD;
        END IF;
        new_row:=to_jsonb(NEW);
        IF TG_OP='UPDATE' THEN
            old_row:=to_jsonb(OLD);
            IF NOT public.fn_imported_business_document_judgment_changed(TG_RELID,old_row,new_row) THEN
                RETURN NEW;
            END IF;
            IF old_row->>'id' IS DISTINCT FROM new_row->>'id'
               AND old_row->>'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
                PERFORM public.fn_imported_document_registry_forget(TG_TABLE_NAME,(old_row->>'id')::uuid);
            END IF;
        END IF;
        PERFORM public.fn_imported_document_registry_sync(TG_TABLE_NAME,new_row);
        RETURN NEW;
    END IF;
    IF TG_OP<>'INSERT' THEN
        old_row:=to_jsonb(OLD);
        IF public.fn_imported_business_document_row(TG_TABLE_NAME,old_row) THEN
            RAISE EXCEPTION '历史原始单据仅供核对，不能修改、审核、反审或用于新的业务来源'
                USING ERRCODE='55000',CONSTRAINT='imported_business_document_archive_only';
        END IF;
    END IF;
    IF TG_OP<>'DELETE' THEN
        new_row:=to_jsonb(NEW);
        IF TG_OP='INSERT' OR public.fn_imported_business_document_judgment_changed(TG_RELID,old_row,new_row) THEN
            IF public.fn_imported_business_document_row(TG_TABLE_NAME,new_row) THEN
                RAISE EXCEPTION '历史原始单据仅供核对，不能修改、审核、反审或用于新的业务来源'
                    USING ERRCODE='55000',CONSTRAINT='imported_business_document_archive_only';
            END IF;
        END IF;
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $guard$;

-- TRUNCATE fires no row guard; a maintenance truncate also retires its registrations.
CREATE OR REPLACE FUNCTION public.fn_guard_imported_business_document_truncate() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
 IF NOT public.fn_imported_business_document_maintenance_allowed() THEN
  RAISE EXCEPTION '历史原始单据仅供核对，运行账号不能整表清空业务记录'
   USING ERRCODE='55000',CONSTRAINT='imported_business_document_archive_only';
 END IF;
 PERFORM public.fn_imported_document_registry_forget(TG_TABLE_NAME,NULL);
 RETURN NULL;
END $$;

-- Maintenance-only recomputation from the pure walk (never from registrations).
-- NULL recomputes every guarded relation; returns the number of changed rows.
-- Direct keys are the walk's first test, read here from the typed columns so
-- keyed history needs no row image; only keyless rows are walked.
CREATE FUNCTION public.fn_refresh_imported_document_registry(p_table text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $refresh$
DECLARE target record; direct_key text; changed bigint:=0; affected bigint;
BEGIN
    IF NOT public.fn_imported_business_document_maintenance_allowed() THEN
        RAISE EXCEPTION '导入单据登记只能由维护身份重算' USING ERRCODE='42501';
    END IF;
    -- Registrations for relations that are no longer guarded UUID documents.
    DELETE FROM public.imported_document_registry registry
    WHERE (p_table IS NULL OR registry.table_name=p_table)
      AND NOT EXISTS(
          SELECT 1 FROM pg_trigger guard
          JOIN pg_class relation ON relation.oid=guard.tgrelid
          JOIN pg_namespace ns ON ns.oid=relation.relnamespace
          JOIN pg_attribute identity ON identity.attrelid=relation.oid AND identity.attname='id'
               AND NOT identity.attisdropped AND identity.atttypid='uuid'::regtype
          WHERE ns.nspname='public' AND relation.relname=registry.table_name
            AND guard.tgname='trg_00_imported_business_archive_only' AND NOT guard.tgisinternal);
    GET DIAGNOSTICS affected=ROW_COUNT; changed:=changed+affected;
    FOR target IN
        SELECT relation.relname::text AS table_name,
               EXISTS(SELECT 1 FROM pg_attribute key_column WHERE key_column.attrelid=relation.oid
                      AND key_column.attname='legacy_id' AND NOT key_column.attisdropped) AS has_legacy,
               EXISTS(SELECT 1 FROM pg_attribute key_column WHERE key_column.attrelid=relation.oid
                      AND key_column.attname='legacy_import_run_id' AND NOT key_column.attisdropped) AS has_run
        FROM pg_trigger guard
        JOIN pg_class relation ON relation.oid=guard.tgrelid
        JOIN pg_namespace ns ON ns.oid=relation.relnamespace
        JOIN pg_attribute identity ON identity.attrelid=relation.oid AND identity.attname='id'
             AND NOT identity.attisdropped AND identity.atttypid='uuid'::regtype
        WHERE ns.nspname='public' AND guard.tgname='trg_00_imported_business_archive_only'
          AND NOT guard.tgisinternal AND relation.relkind IN ('r','p') AND NOT relation.relispartition
          AND (p_table IS NULL OR relation.relname=p_table)
        ORDER BY 1
    LOOP
        direct_key:=concat_ws(' OR ',
            CASE WHEN target.has_legacy THEN 'row_image.legacy_id IS NOT NULL' END,
            CASE WHEN target.has_run THEN 'NULLIF(row_image.legacy_import_run_id::text,'''') IS NOT NULL' END);
        IF direct_key='' THEN direct_key:='FALSE'; END IF;
        EXECUTE format($sql$
            DELETE FROM public.imported_document_registry registry
            WHERE registry.table_name=%1$L
              AND NOT EXISTS(SELECT 1 FROM public.%1$I row_image WHERE row_image.id=registry.row_id
                  AND ((%2$s) OR public.fn_imported_document_registry_proven(%1$L,to_jsonb(row_image))))
            $sql$,target.table_name,direct_key);
        GET DIAGNOSTICS affected=ROW_COUNT; changed:=changed+affected;
        EXECUTE format($sql$
            INSERT INTO public.imported_document_registry(table_name,row_id)
            SELECT %1$L,row_image.id FROM public.%1$I row_image
            WHERE (%2$s)
              AND NOT EXISTS(SELECT 1 FROM public.imported_document_registry registry
                             WHERE registry.table_name=%1$L AND registry.row_id=row_image.id)
            ON CONFLICT DO NOTHING
            $sql$,target.table_name,direct_key);
        GET DIAGNOSTICS affected=ROW_COUNT; changed:=changed+affected;
        EXECUTE format($sql$
            INSERT INTO public.imported_document_registry(table_name,row_id)
            SELECT %1$L,row_image.id FROM public.%1$I row_image
            WHERE NOT (%2$s)
              AND NOT EXISTS(SELECT 1 FROM public.imported_document_registry registry
                             WHERE registry.table_name=%1$L AND registry.row_id=row_image.id)
              AND public.fn_imported_document_registry_proven(%1$L,to_jsonb(row_image))
            ON CONFLICT DO NOTHING
            $sql$,target.table_name,direct_key);
        GET DIAGNOSTICS affected=ROW_COUNT; changed:=changed+affected;
    END LOOP;
    RETURN changed;
END $refresh$;

COMMENT ON FUNCTION public.fn_refresh_imported_document_registry(text) IS
 'Maintenance contract: run for every relation whose imported verdicts an incremental import, repair, FK/guard/root/scope change or guard-disabled write may have changed.';

-- The runtime reads the registry and never writes it. sync/forget stay executable
-- by the trigger's current_user and refuse every non-maintenance session; the
-- proof and the recomputation remain private maintenance helpers.
REVOKE ALL ON TABLE public.imported_document_registry FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_imported_document_registry_proven(text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_refresh_imported_document_registry(text) FROM PUBLIC;
DO $registry_acl$
BEGIN
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uten') THEN
        REVOKE ALL ON TABLE public.imported_document_registry FROM uten;
        GRANT SELECT ON TABLE public.imported_document_registry TO uten;
        REVOKE ALL ON FUNCTION public.fn_imported_document_registry_proven(text,jsonb) FROM uten;
        REVOKE ALL ON FUNCTION public.fn_refresh_imported_document_registry(text) FROM uten;
    END IF;
END $registry_acl$;

-- One-time backfill under the migration (maintenance) identity.
SELECT public.fn_refresh_imported_document_registry();
ANALYZE public.imported_document_registry;
