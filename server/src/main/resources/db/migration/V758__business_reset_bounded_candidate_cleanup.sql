-- V758 restores sparse reset with the V757 candidate cleanup still active.
-- No reset runs during migration; V558/V747/V757 remain immutable.
-- Qualify the same cleanup operation and fix its lookup path before recognizing it.
CREATE OR REPLACE FUNCTION public.fn_sales_quote_template_candidates_truncate()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp
AS $function$
BEGIN
    INSERT INTO public.attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key)
    SELECT 'DELETE_FINAL',c.storage_provider,c.storage_key,c.storage_version,
        c.storage_provider || '|DELETE_FINAL|' || c.storage_key || '|' || COALESCE(c.storage_version,'<local>')
    FROM public.sales_quote_template_candidates c
    WHERE c.storage_provider IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.sales_quote_template_versions v WHERE v.storage_provider=c.storage_provider
            AND v.storage_key=c.storage_key AND v.storage_version IS NOT DISTINCT FROM c.storage_version)
    ON CONFLICT(dedupe_key) DO NOTHING;
    RETURN NULL;
END;
$function$;

DO $bounded_candidate_reset$
DECLARE
    definition TEXT;
    previous_metadata JSONB;
    old_block TEXT := $old$    -- Traditional inheritance and user TRUNCATE triggers retain the original
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
$old$;
    new_block TEXT := $new$    -- Keep the reviewed INSERT target and referenced versions stable while
    -- proving the trigger boundary and executing reset; readers remain allowed.
    IF to_regclass('public.sales_quote_template_versions') IS NOT NULL THEN
        LOCK TABLE public.attachment_object_outbox, public.sales_quote_template_versions IN SHARE ROW EXCLUSIVE MODE;
    END IF;
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
              -- V758: this exact statement only reads candidates/versions and
              -- inserts cleanup commands into a PRESERVE table. An empty
              -- candidate table has no effect, so it need not be truncated.
              -- Any drift or additional side effect restores the full fallback.
              AND NOT COALESCE((
                  trigger_row.tgrelid = to_regclass('public.sales_quote_template_candidates')
                  AND trigger_row.tgname = 'trg_quote_template_candidates_truncate'
                  AND trigger_row.tgfoid = to_regprocedure('public.fn_sales_quote_template_candidates_truncate()')
                  AND trigger_row.tgtype = 34 AND trigger_row.tgenabled = 'O'
                  AND trigger_row.tgnargs = 0 AND octet_length(trigger_row.tgargs) = 0
                  AND trigger_row.tgqual IS NULL AND trigger_row.tgconstraint = 0
                  AND NOT trigger_row.tgdeferrable AND NOT trigger_row.tginitdeferred
                  AND trigger_row.tgoldtable IS NULL AND trigger_row.tgnewtable IS NULL
                  AND EXISTS (
                      SELECT 1 FROM pg_catalog.pg_proc implementation
                      JOIN pg_catalog.pg_language language ON language.oid = implementation.prolang
                      WHERE implementation.oid = trigger_row.tgfoid
                        AND language.lanname = 'plpgsql' AND implementation.pronargs = 0
                        AND implementation.prorettype = 'pg_catalog.trigger'::regtype
                        AND NOT implementation.prosecdef AND NOT implementation.proretset
                        AND implementation.prokind = 'f' AND implementation.provolatile = 'v'
                        AND implementation.proconfig = ARRAY['search_path=pg_catalog, public, pg_temp']
                        AND replace(implementation.prosrc, E'\r\n', E'\n') = $candidate_body$
BEGIN
    INSERT INTO public.attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key)
    SELECT 'DELETE_FINAL',c.storage_provider,c.storage_key,c.storage_version,
        c.storage_provider || '|DELETE_FINAL|' || c.storage_key || '|' || COALESCE(c.storage_version,'<local>')
    FROM public.sales_quote_template_candidates c
    WHERE c.storage_provider IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.sales_quote_template_versions v WHERE v.storage_provider=c.storage_provider
            AND v.storage_key=c.storage_key AND v.storage_version IS NOT DISTINCT FROM c.storage_version)
    ON CONFLICT(dedupe_key) DO NOTHING;
    RETURN NULL;
END;
$candidate_body$
                  )
                  AND EXISTS (SELECT 1 FROM reset_business_table_policy
                              WHERE table_name = 'attachment_object_outbox' AND disposition = 'PRESERVE')
                  AND NOT EXISTS (
                      SELECT 1 FROM pg_catalog.pg_class relation
                      WHERE relation.oid IN (to_regclass('public.sales_quote_template_candidates'),
                          to_regclass('public.sales_quote_template_versions'), 'public.attachment_object_outbox'::regclass)
                        AND (relation.relkind <> 'r' OR relation.relrowsecurity OR relation.relforcerowsecurity)
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM pg_catalog.pg_inherits
                      WHERE inhrelid IN (to_regclass('public.sales_quote_template_versions'), 'public.attachment_object_outbox'::regclass)
                         OR inhparent IN (to_regclass('public.sales_quote_template_versions'), 'public.attachment_object_outbox'::regclass)
                  )
                  AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger
                      WHERE tgrelid = 'public.attachment_object_outbox'::regclass AND NOT tgisinternal)
                  AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_rewrite
                      WHERE ev_class = 'public.attachment_object_outbox'::regclass)
                  -- Even pg_catalog contains state-changing routines. Keep
                  -- CHECK and index expressions within the reviewed pure set.
                  -- CREATE TABLE and pg_dump/restore spell the same varchar-to-
                  -- text array coercion differently; accept exactly both forms.
                  AND NOT EXISTS (
                      SELECT 1 FROM pg_catalog.pg_constraint constraint_row
                      WHERE constraint_row.conrelid = 'public.attachment_object_outbox'::regclass
                        AND constraint_row.contype = 'c'
                        AND pg_catalog.pg_get_expr(constraint_row.conbin, constraint_row.conrelid) NOT IN (
                            '((operation)::text = ANY ((ARRAY[''DELETE_STAGING''::character varying, ''DELETE_FINAL''::character varying])::text[]))',
                            '((storage_provider)::text = ANY ((ARRAY[''internal''::character varying, ''oss''::character varying, ''local''::character varying, ''legacy_unknown''::character varying])::text[]))',
                            '((status)::text = ANY ((ARRAY[''PENDING''::character varying, ''PROCESSING''::character varying, ''SUCCEEDED''::character varying, ''FAILED''::character varying])::text[]))',
                            '(attempts >= 0)',
                            '((storage_key)::text ~ ''^[A-Za-z0-9._-]+$''::text)',
                            '((operation)::text = ANY (ARRAY[(''DELETE_STAGING''::character varying)::text, (''DELETE_FINAL''::character varying)::text]))',
                            '((storage_provider)::text = ANY (ARRAY[(''internal''::character varying)::text, (''oss''::character varying)::text, (''local''::character varying)::text, (''legacy_unknown''::character varying)::text]))',
                            '((status)::text = ANY (ARRAY[(''PENDING''::character varying)::text, (''PROCESSING''::character varying)::text, (''SUCCEEDED''::character varying)::text, (''FAILED''::character varying)::text]))'
                        )
                  )
                  -- No custom input/domain/default/check/index routine may
                  -- turn the bounded INSERT into writes to skipped CLEAR tables.
                  AND NOT EXISTS (
                      SELECT 1 FROM pg_catalog.pg_attribute attribute
                      JOIN pg_catalog.pg_type type_row ON type_row.oid = attribute.atttypid
                      WHERE attribute.attrelid IN (to_regclass('public.sales_quote_template_candidates'),
                          to_regclass('public.sales_quote_template_versions'), 'public.attachment_object_outbox'::regclass)
                        AND attribute.attnum > 0 AND NOT attribute.attisdropped
                        AND (type_row.typnamespace <> 'pg_catalog'::regnamespace OR attribute.attgenerated <> '' OR attribute.attidentity <> '')
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM pg_catalog.pg_attrdef default_row
                      WHERE default_row.adrelid = 'public.attachment_object_outbox'::regclass
                        AND pg_catalog.pg_get_expr(default_row.adbin, default_row.adrelid)
                            NOT IN ('gen_random_uuid()', '''PENDING''::character varying', '0', 'now()')
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM pg_catalog.pg_index index_row
                      JOIN pg_catalog.pg_class index_relation ON index_relation.oid = index_row.indexrelid
                      JOIN pg_catalog.pg_am access_method ON access_method.oid = index_relation.relam
                      WHERE index_row.indrelid = 'public.attachment_object_outbox'::regclass
                        AND (access_method.amname <> 'btree' OR index_row.indexprs IS NOT NULL
                          OR (index_row.indpred IS NOT NULL AND pg_catalog.pg_get_expr(index_row.indpred, index_row.indrelid) NOT IN ('((status)::text = ANY (ARRAY[(''PENDING''::character varying)::text, (''FAILED''::character varying)::text]))', '((status)::text = ANY ((ARRAY[''PENDING''::character varying, ''FAILED''::character varying])::text[]))'))
                          OR EXISTS (
                            SELECT 1 FROM pg_catalog.pg_opclass opclass WHERE opclass.oid = ANY(index_row.indclass)
                              AND opclass.opcnamespace <> 'pg_catalog'::regnamespace))
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM pg_catalog.pg_depend dependency
                      WHERE ((dependency.classid = 'pg_catalog.pg_attrdef'::regclass AND dependency.objid IN (
                          SELECT oid FROM pg_catalog.pg_attrdef WHERE adrelid = 'public.attachment_object_outbox'::regclass))
                        OR (dependency.classid = 'pg_catalog.pg_constraint'::regclass AND dependency.objid IN (
                          SELECT oid FROM pg_catalog.pg_constraint WHERE conrelid = 'public.attachment_object_outbox'::regclass))
                        OR (dependency.classid = 'pg_catalog.pg_class'::regclass AND dependency.objid IN (
                          SELECT indexrelid FROM pg_catalog.pg_index WHERE indrelid = 'public.attachment_object_outbox'::regclass)))
                      AND ((dependency.refclassid = 'pg_catalog.pg_proc'::regclass AND EXISTS (
                          SELECT 1 FROM pg_catalog.pg_proc routine WHERE routine.oid = dependency.refobjid
                            AND routine.pronamespace <> 'pg_catalog'::regnamespace))
                        OR (dependency.refclassid = 'pg_catalog.pg_operator'::regclass AND EXISTS (
                          SELECT 1 FROM pg_catalog.pg_operator operator_row WHERE operator_row.oid = dependency.refobjid
                            AND operator_row.oprnamespace <> 'pg_catalog'::regnamespace)))
                  )
              ), false)
        ) OR EXISTS (
            SELECT 1 FROM pg_catalog.pg_inherits inheritance
            JOIN pg_catalog.pg_class child_relation ON child_relation.oid = inheritance.inhrelid
            WHERE family.member_oid IN (inheritance.inhparent, inheritance.inhrelid)
              AND NOT child_relation.relispartition
        )
$new$;
BEGIN
    old_block := replace(old_block, E'\r\n', E'\n');
    new_block := replace(new_block, E'\r\n', E'\n');
    IF (SELECT max(version::integer) FROM public.flyway_schema_history
        WHERE success AND version ~ '^[0-9]+$') <> 757
       OR (SELECT count(*) FROM public.flyway_schema_history WHERE success AND type = 'SQL') <> 685 THEN
        RAISE EXCEPTION 'V758 requires the complete V757/685 migration catalog';
    END IF;
    SELECT jsonb_build_array(proowner, prosecdef, proconfig, proacl),
           replace(pg_catalog.pg_get_functiondef(oid), E'\r\n', E'\n')
    INTO previous_metadata, definition
    FROM pg_catalog.pg_proc WHERE oid = 'public.business_data_reset()'::regprocedure;
    IF definition IS NULL OR position(old_block IN definition) = 0
       OR (length(definition) - length(replace(definition, old_block, ''))) <> length(old_block) THEN
        RAISE EXCEPTION 'V758 reset trigger fallback anchor differs from the reviewed V757 function';
    END IF;
    EXECUTE replace(definition, old_block, new_block);
    IF previous_metadata IS DISTINCT FROM (
        SELECT jsonb_build_array(proowner, prosecdef, proconfig, proacl)
        FROM pg_catalog.pg_proc WHERE oid = 'public.business_data_reset()'::regprocedure
    ) THEN
        RAISE EXCEPTION 'V758 changed reset function ownership, security, configuration or grants';
    END IF;
END;
$bounded_candidate_reset$;
