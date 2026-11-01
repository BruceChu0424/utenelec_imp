-- New allocations use the empty-prefix six-digit sequence. UT namespace,
-- release certificates and all historical reservations remain immutable.
-- Historical renumbering is an explicit reviewed maintenance transaction, NOT
-- inferred from names or applied on application startup.
INSERT INTO master_code_sequences(prefix,last_seq)
SELECT '', GREATEST(2, COALESCE(MAX(code::integer),0))
FROM employees WHERE code ~ '^[0-9]{6}$'
ON CONFLICT(prefix) DO UPDATE
SET last_seq=GREATEST(master_code_sequences.last_seq,EXCLUDED.last_seq);

CREATE FUNCTION fn_sync_employee_numeric_sequence() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF NEW.code ~ '^[0-9]{6}$' THEN
        INSERT INTO public.master_code_sequences(prefix,last_seq)
        VALUES ('',GREATEST(2,NEW.code::integer))
        ON CONFLICT(prefix) DO UPDATE
        SET last_seq=GREATEST(master_code_sequences.last_seq,EXCLUDED.last_seq);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_sync_employee_numeric_sequence AFTER INSERT OR UPDATE OF code ON employees
FOR EACH ROW EXECUTE FUNCTION fn_sync_employee_numeric_sequence();

-- One immutable receipt per business dataset. The plan contains only reviewed
-- identity/code/date snapshots, never credentials or encrypted personnel data.
CREATE TABLE employee_code_numbering_receipts (
    dataset_id uuid PRIMARY KEY,
    plan_sha256 text NOT NULL CHECK(plan_sha256 ~ '^[0-9a-f]{64}$'),
    plan jsonb NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    applied_by text NOT NULL DEFAULT session_user,
    evidence_reference text NOT NULL CHECK(length(btrim(evidence_reference)) BETWEEN 1 AND 1000)
);
CREATE TRIGGER trg_employee_code_numbering_receipt_immutable
BEFORE UPDATE OR DELETE ON employee_code_numbering_receipts
FOR EACH ROW EXECUTE FUNCTION fn_guard_business_identifier_append_only();
CREATE TRIGGER trg_employee_code_numbering_receipt_no_truncate
BEFORE TRUNCATE ON employee_code_numbering_receipts
FOR EACH STATEMENT EXECUTE FUNCTION fn_guard_business_identifier_append_only();
REVOKE ALL ON employee_code_numbering_receipts FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN
        REVOKE ALL ON employee_code_numbering_receipts FROM uten;
    END IF;
END $$;
-- The immutable private receipt is the retained decision journal. Employee/date
-- mutations have their own FULL row audit; duplicating its nested personnel plan
-- into general audit JSON would bypass the receipt table's restricted readers.
SELECT fn_audit_track_table('employee_code_numbering_receipts','NONE','data_change',false);

-- Old code-only permission imports must require explicit identity mapping after
-- renumbering too. Never reinterpret old snapshots as a different person.
-- V965 seals this function together with every code-reuse guard and ACL.
-- Verify that complete old seal before changing it, then permit exactly this
-- reviewed definition delta. Keep the original installer payload/identity and
-- all other catalog fields, so its unchanged adoption check remains strict.
DO $numbering_code_reuse_forward$
DECLARE
    original_search_path text := current_setting('search_path');
    reviewed_payload_sha constant text := 'c28f2c94393c7eeb62873958393591a6692f87cb85911713c539df959110c4ec';
    catalog_query constant text := $reuse_catalog$
SELECT jsonb_build_object(
      'functions',(SELECT jsonb_agg(jsonb_build_object('signature',p.oid::regprocedure::text,
          'definition',pg_get_functiondef(p.oid),'owner',pg_get_userbyid(p.proowner),'acl',p.proacl)
          ORDER BY p.oid::regprocedure::text) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname='public' AND p.proname=ANY(ARRAY[
            'fn_employee_code_reuse_evidence_immutable','fn_guard_employee_code_release_insert','fn_release_merged_employee_code',
            'fn_guard_employee_code_claim_insert','fn_claim_next_released_employee_code','fn_employee_code_reuse_actor','fn_employee_code_reuse_claim_authorizes',
            'fn_finish_employee_code_reuse_claim','fn_guard_employee_code_reuse_legacy_import','fn_employee_code_requires_identity_mapping','fn_reserve_master_code',
            'fn_claim_global_business_identifier','fn_employee_merge_completed'])),
      'employeeImportTriggers',(SELECT jsonb_agg(jsonb_build_array(c.relname,t.tgname,pg_get_triggerdef(t.oid,true),t.tgenabled) ORDER BY t.tgname)
          FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
          WHERE t.tgrelid IN('public.employees'::regclass,'public.employee_sensitive'::regclass)
            AND t.tgname IN('trg_employee_code_reuse_legacy_import','trg_employee_code_reuse_legacy_sensitive_import')),
      'tables',(SELECT jsonb_agg(jsonb_build_object('name',r.relname,'owner',pg_get_userbyid(r.relowner),'acl',r.relacl,
          'columns',(SELECT jsonb_agg(jsonb_build_array(a.attname,format_type(a.atttypid,a.atttypmod),a.attnotnull,
              pg_get_expr(d.adbin,d.adrelid)) ORDER BY a.attnum) FROM pg_attribute a LEFT JOIN pg_attrdef d
                ON d.adrelid=a.attrelid AND d.adnum=a.attnum WHERE a.attrelid=r.oid AND a.attnum>0 AND NOT a.attisdropped),
          'constraints',(SELECT jsonb_agg(jsonb_build_array(c.conname,pg_get_constraintdef(c.oid,true)) ORDER BY c.conname)
              FROM pg_constraint c WHERE c.conrelid=r.oid),
          'indexes',(SELECT jsonb_agg(pg_get_indexdef(i.indexrelid) ORDER BY i.indexrelid::regclass::text)
              FROM pg_index i WHERE i.indrelid=r.oid),
          'triggers',(SELECT jsonb_agg(jsonb_build_array(t.tgname,pg_get_triggerdef(t.oid,true),t.tgenabled)
              ORDER BY t.tgname) FROM pg_trigger t WHERE t.tgrelid=r.oid AND NOT t.tgisinternal)) ORDER BY r.relname)
          FROM pg_class r JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname='public'
            AND r.relname IN('employee_code_reuse_installation','employee_code_reuse_releases','employee_code_reuse_claims'))
    )
$reuse_catalog$;
    installed jsonb;
    before_catalog jsonb;
    after_catalog jsonb;
    expected_catalog jsonb;
    definition_index integer;
    definition_count integer;
    immutable_enabled "char";
    new_catalog_sha text;
    affected integer;
BEGIN
    PERFORM set_config('search_path','pg_catalog,public,pg_temp',true);
    LOCK TABLE public.employee_code_reuse_installation IN ACCESS EXCLUSIVE MODE;
    SELECT to_jsonb(receipt) INTO STRICT installed
    FROM public.employee_code_reuse_installation receipt WHERE singleton;
    EXECUTE catalog_query INTO before_catalog;
    IF installed->>'payload_sha256' IS DISTINCT FROM reviewed_payload_sha
       OR installed->>'catalog_sha256' IS DISTINCT FROM
          encode(public.digest(convert_to(before_catalog::text,'UTF8'),'sha256'),'hex') THEN
        RAISE EXCEPTION 'Employee numbering requires the exact sealed V965 payload/catalog; forward adoption refused';
    END IF;
    SELECT count(*),min(position-1)::integer INTO definition_count,definition_index
    FROM jsonb_array_elements(before_catalog->'functions') WITH ORDINALITY AS entry(value,position)
    WHERE value->>'signature'='fn_employee_code_requires_identity_mapping(text)';
    SELECT tgenabled INTO STRICT immutable_enabled FROM pg_trigger
    WHERE tgrelid='public.employee_code_reuse_installation'::regclass
      AND tgname='trg_employee_code_installation_immutable' AND NOT tgisinternal;
    IF definition_count<>1 OR immutable_enabled NOT IN ('O','A') THEN
        RAISE EXCEPTION 'Employee code reuse sealed definition/immutable guard is not the reviewed V965 shape';
    END IF;
    EXECUTE $numbering_definition$
CREATE OR REPLACE FUNCTION public.fn_employee_code_requires_identity_mapping(p_code text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
    SELECT EXISTS(SELECT 1 FROM public.employee_code_reuse_releases WHERE normalized_code=upper(btrim(p_code)))
        OR EXISTS(SELECT 1 FROM public.employee_identity_merges WHERE upper(btrim(source_code))=upper(btrim(p_code)))
        OR EXISTS(SELECT 1 FROM public.employee_code_numbering_receipts receipt,
                       jsonb_array_elements(receipt.plan->'entries') entry
                  WHERE upper(btrim(entry->>'oldCode'))=upper(btrim(p_code))
                    AND entry->>'oldCode' IS DISTINCT FROM entry->>'newCode')
$$;
$numbering_definition$;
    EXECUTE catalog_query INTO after_catalog;
    expected_catalog:=jsonb_set(before_catalog,
        ARRAY['functions',definition_index::text,'definition'],
        to_jsonb(pg_get_functiondef('public.fn_employee_code_requires_identity_mapping(text)'::regprocedure)));
    IF after_catalog IS DISTINCT FROM expected_catalog THEN
        RAISE EXCEPTION 'Employee numbering changed an unreviewed code-reuse catalog field';
    END IF;
    new_catalog_sha:=encode(public.digest(convert_to(after_catalog::text,'UTF8'),'sha256'),'hex');
    -- Only the migration owner can perform this bounded catalog-receipt CAS.
    -- Never disable other evidence guards or use session_replication_role.
    ALTER TABLE public.employee_code_reuse_installation DISABLE TRIGGER trg_employee_code_installation_immutable;
    UPDATE public.employee_code_reuse_installation SET catalog_sha256=new_catalog_sha
    WHERE singleton AND to_jsonb(employee_code_reuse_installation)=installed;
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF immutable_enabled='A' THEN
        ALTER TABLE public.employee_code_reuse_installation ENABLE ALWAYS TRIGGER trg_employee_code_installation_immutable;
    ELSE
        ALTER TABLE public.employee_code_reuse_installation ENABLE TRIGGER trg_employee_code_installation_immutable;
    END IF;
    EXECUTE catalog_query INTO after_catalog;
    IF affected<>1 OR after_catalog IS DISTINCT FROM expected_catalog
       OR NOT EXISTS(SELECT 1 FROM public.employee_code_reuse_installation receipt
          WHERE to_jsonb(receipt)-'catalog_sha256'=installed-'catalog_sha256'
            AND receipt.catalog_sha256=new_catalog_sha) THEN
        RAISE EXCEPTION 'Employee numbering catalog receipt CAS or immutable-guard restoration failed';
    END IF;
    PERFORM set_config('search_path',original_search_path,true);
END;
$numbering_code_reuse_forward$;

CREATE FUNCTION fn_guard_employee_fixed_numeric_code() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM public.employee_code_numbering_receipts receipt
              JOIN public.authorization_state state ON state.business_dataset_id=receipt.dataset_id
              WHERE state.singleton_id=1) THEN
        IF TG_OP='INSERT' THEN
            IF NEW.code !~ '^[0-9]{6}$' OR NEW.code<'000003' THEN
                RAISE EXCEPTION 'New employees require a six-digit number after the reserved founders' USING ERRCODE='23514';
            END IF;
        ELSIF NEW.code IS DISTINCT FROM OLD.code THEN
            RAISE EXCEPTION 'Assigned employee numbers are fixed after initial numbering' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_employee_fixed_numeric_code BEFORE INSERT OR UPDATE OF code ON employees
FOR EACH ROW EXECUTE FUNCTION fn_guard_employee_fixed_numeric_code();
ALTER TABLE employees ENABLE ALWAYS TRIGGER trg_employee_fixed_numeric_code;
