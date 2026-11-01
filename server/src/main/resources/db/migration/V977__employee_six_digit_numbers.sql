-- BEGIN CANONICAL EMPLOYEE SEALED OWNER-DEFAULT ACL RESTORE
-- Canonical, owner-invoked restore finalization for the fixed V964/V965 sealed catalogs.
-- No persistent function, SECURITY DEFINER, role grant, or seal rewrite is installed.
-- pg_dump omits an explicit ACL equal to the owner-only default; pg_restore leaves NULL.
-- Recreate that representation only when the full candidate exactly matches each original seal.
DO $employee_sealed_owner_default_acl$
DECLARE
 original_search_path text := current_setting('search_path');
 expected_owner text;
 code_payload_sha constant text := 'c28f2c94393c7eeb62873958393591a6692f87cb85911713c539df959110c4ec';
 merge_payload_sha constant text := 'd82c874cbe07b7133e97fda76e8684987c6415eff26adae71eeae6a84c5155c7';
 code_query constant text := $code_catalog$SELECT jsonb_build_object(
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
    )$code_catalog$;
 merge_query constant text := $merge_catalog$SELECT jsonb_build_object(
        'tables',(SELECT jsonb_agg(jsonb_build_array(c.relname,pg_get_userbyid(c.relowner),c.relacl::text) ORDER BY c.relname)
          FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'
            AND c.relname IN('employee_identity_merges','employee_identity_merge_payloads','employee_legacy_identity_aliases','employee_identity_historical_claims','employee_identity_user_tombstones','employee_identity_legacy_roles','employee_identity_review_certificates','employee_identity_merge_installation')),
        'columns',(SELECT jsonb_agg(jsonb_build_array(c.relname,a.attname,a.atttypid::regtype::text,a.atttypmod,a.attnotnull,a.attidentity,a.attgenerated,pg_get_expr(d.adbin,d.adrelid)) ORDER BY c.relname,a.attnum)
          FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
          LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum
          WHERE n.nspname='public' AND c.relname IN('employee_identity_merges','employee_identity_merge_payloads','employee_legacy_identity_aliases','employee_identity_historical_claims','employee_identity_user_tombstones','employee_identity_legacy_roles','employee_identity_review_certificates','employee_identity_merge_installation')),
        'functions',(SELECT jsonb_agg(jsonb_build_array(pg_get_functiondef(p.oid),pg_get_userbyid(p.proowner),p.proacl::text) ORDER BY p.proname,p.oid::regprocedure::text)
          FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND
            (p.proname LIKE 'fn_employee_merge_%' OR p.proname IN('fn_merge_employee_identity','fn_employee_identity_from_legacy_worker'))),
        'constraints',(SELECT jsonb_agg(jsonb_build_array(c.relname,k.conname,k.convalidated,pg_get_constraintdef(k.oid)) ORDER BY c.relname,k.conname)
          FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='public' AND c.relname IN('employee_identity_merges','employee_identity_merge_payloads','employee_legacy_identity_aliases','employee_identity_historical_claims','employee_identity_user_tombstones','employee_identity_legacy_roles','employee_identity_review_certificates','employee_identity_merge_installation','employee_identity_aliases')),
        'indexes',(SELECT jsonb_agg(pg_get_indexdef(i.indexrelid) ORDER BY c.relname,i.indexrelid::regclass::text)
          FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'
            AND c.relname IN('employee_identity_merges','employee_identity_merge_payloads','employee_legacy_identity_aliases','employee_identity_historical_claims','employee_identity_user_tombstones','employee_identity_legacy_roles','employee_identity_review_certificates','employee_identity_merge_installation')),
        'legacy_roles',(SELECT jsonb_agg(to_jsonb(r) ORDER BY source_table,uuid_column) FROM public.employee_identity_legacy_roles r),
        'triggers',(SELECT jsonb_agg(jsonb_build_array(c.relname,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid)) ORDER BY c.relname,t.tgname)
          FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='public' AND NOT t.tgisinternal AND t.tgname LIKE 'trg_employee_merge_%')
      )$merge_catalog$;
 fixed_tables constant text[] := ARRAY[
   'employee_code_reuse_claims','employee_code_reuse_installation','employee_code_reuse_releases',
   'employee_identity_legacy_roles','employee_identity_merge_installation','employee_identity_merge_payloads',
   'employee_identity_review_certificates','employee_identity_user_tombstones'];
 code_tables constant text[] := ARRAY['employee_code_reuse_claims','employee_code_reuse_installation','employee_code_reuse_releases'];
 fixed_functions constant text[] := ARRAY['fn_employee_code_reuse_evidence_immutable()',
   'fn_finish_employee_code_reuse_claim()','fn_guard_employee_code_claim_insert()',
   'fn_guard_employee_code_release_insert()','fn_guard_employee_code_reuse_legacy_import()'];
 code_seal jsonb; merge_seal jsonb; code_catalog jsonb; merge_catalog jsonb;
 code_candidate jsonb; merge_candidate jsonb; entry record; relation record;
 materialize text[] := ARRAY[]::text[];
 materialize_functions text[] := ARRAY[]::text[];
 privileges_before jsonb; privileges_after jsonb; privilege_query text;
 function_privileges_before jsonb; function_privileges_after jsonb; function_privilege_query text;
BEGIN
 PERFORM set_config('search_path','pg_catalog,public,pg_temp',true);
 SELECT pg_get_userbyid(relowner) INTO STRICT expected_owner FROM pg_class WHERE oid='public.employees'::regclass;
 IF current_user IS DISTINCT FROM expected_owner THEN
   RAISE EXCEPTION 'Sealed employee catalogs require the existing employees owner; forward adoption refused';
 END IF;
 IF (SELECT count(*) FROM pg_class c WHERE c.relnamespace='public'::regnamespace
     AND c.relname=ANY(fixed_tables) AND c.relkind='r' AND NOT c.relrowsecurity AND NOT c.relforcerowsecurity
     AND pg_get_userbyid(c.relowner)=expected_owner)<>8
    OR EXISTS(SELECT 1 FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
      WHERE c.relnamespace='public'::regnamespace AND c.relname=ANY(fixed_tables)
        AND a.attnum>0 AND NOT a.attisdropped AND a.attacl IS NOT NULL) THEN
   RAISE EXCEPTION 'Sealed employee table ownership/shape differs; forward adoption refused';
 END IF;
 IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.oid::regprocedure::text=ANY(fixed_functions)
       AND p.pronargs=0 AND p.prorettype='pg_catalog.trigger'::regtype AND p.prokind='f'
       AND pg_get_userbyid(p.proowner)=expected_owner)<>5 THEN
   RAISE EXCEPTION 'Sealed employee trigger-function ownership/signature differs; forward adoption refused';
 END IF;
 LOCK TABLE public.employee_code_reuse_claims,public.employee_code_reuse_installation,public.employee_code_reuse_releases,
   public.employee_identity_legacy_roles,public.employee_identity_merge_installation,public.employee_identity_merge_payloads,
   public.employee_identity_review_certificates,public.employee_identity_user_tombstones IN SHARE ROW EXCLUSIVE MODE;
 SELECT to_jsonb(i) INTO STRICT code_seal FROM public.employee_code_reuse_installation i WHERE singleton;
 SELECT to_jsonb(i) INTO STRICT merge_seal FROM public.employee_identity_merge_installation i WHERE version='v1';
 IF code_seal->>'payload_sha256' IS DISTINCT FROM code_payload_sha
    OR merge_seal->>'payload_sha256' IS DISTINCT FROM merge_payload_sha THEN
   RAISE EXCEPTION 'Sealed employee installer payload differs; forward adoption refused';
 END IF;
 EXECUTE code_query INTO code_catalog;
 EXECUTE merge_query INTO merge_catalog;
 code_candidate:=code_catalog; merge_candidate:=merge_catalog;
 IF encode(public.digest(convert_to(code_catalog::text,'UTF8'),'sha256'),'hex') IS DISTINCT FROM code_seal->>'catalog_sha256' THEN
   FOR entry IN SELECT value,ordinality-1 AS position FROM jsonb_array_elements(code_catalog->'tables') WITH ORDINALITY LOOP
     IF entry.value->>'name'=ANY(code_tables) AND entry.value->'acl'='null'::jsonb THEN
       SELECT c.oid,c.relowner,c.relname INTO STRICT relation FROM pg_class c
         WHERE c.relnamespace='public'::regnamespace AND c.relname=entry.value->>'name';
       code_candidate:=jsonb_set(code_candidate,ARRAY['tables',entry.position::text,'acl'],to_jsonb(acldefault('r',relation.relowner)));
       materialize:=array_append(materialize,relation.relname);
     END IF;
   END LOOP;
   FOR entry IN SELECT value,ordinality-1 AS position FROM jsonb_array_elements(code_catalog->'functions') WITH ORDINALITY LOOP
     IF entry.value->>'signature'=ANY(fixed_functions) AND entry.value->'acl'='null'::jsonb THEN
       SELECT p.oid,p.proowner INTO STRICT relation FROM pg_proc p
         WHERE p.oid::regprocedure::text=entry.value->>'signature';
       code_candidate:=jsonb_set(code_candidate,ARRAY['functions',entry.position::text,'acl'],to_jsonb(acldefault('f',relation.proowner)));
       materialize_functions:=array_append(materialize_functions,entry.value->>'signature');
     END IF;
   END LOOP;
 END IF;
 IF encode(public.digest(convert_to(merge_catalog::text,'UTF8'),'sha256'),'hex') IS DISTINCT FROM merge_seal->>'catalog_sha256' THEN
   FOR entry IN SELECT value,ordinality-1 AS position FROM jsonb_array_elements(merge_catalog->'tables') WITH ORDINALITY LOOP
     IF entry.value->>0=ANY(fixed_tables) AND NOT entry.value->>0=ANY(code_tables) AND entry.value->2='null'::jsonb THEN
       SELECT c.oid,c.relowner,c.relname INTO STRICT relation FROM pg_class c
         WHERE c.relnamespace='public'::regnamespace AND c.relname=entry.value->>0;
       merge_candidate:=jsonb_set(merge_candidate,ARRAY['tables',entry.position::text,'2'],to_jsonb(acldefault('r',relation.relowner)::text));
       materialize:=array_append(materialize,relation.relname);
     END IF;
   END LOOP;
 END IF;
 IF encode(public.digest(convert_to(code_candidate::text,'UTF8'),'sha256'),'hex') IS DISTINCT FROM code_seal->>'catalog_sha256'
    OR encode(public.digest(convert_to(merge_candidate::text,'UTF8'),'sha256'),'hex') IS DISTINCT FROM merge_seal->>'catalog_sha256' THEN
   RAISE EXCEPTION 'Sealed employee catalog has an unreviewed difference; forward adoption refused';
 END IF;
 IF cardinality(materialize)=0 AND cardinality(materialize_functions)=0 THEN
   PERFORM set_config('search_path',original_search_path,true);
   RETURN;
 END IF;
 privilege_query:=$privileges$
   SELECT jsonb_agg(jsonb_build_array(c.relname,r.rolname,p.privilege,has_table_privilege(r.oid,c.oid,p.privilege))
                    ORDER BY c.relname,r.rolname,p.privilege)
   FROM pg_class c CROSS JOIN pg_roles r CROSS JOIN unnest(ARRAY[
     'SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER',
     'SELECT WITH GRANT OPTION','INSERT WITH GRANT OPTION','UPDATE WITH GRANT OPTION','DELETE WITH GRANT OPTION',
     'TRUNCATE WITH GRANT OPTION','REFERENCES WITH GRANT OPTION','TRIGGER WITH GRANT OPTION']) p(privilege)
   WHERE c.relnamespace='public'::regnamespace AND c.relname=ANY($1)
 $privileges$;
 EXECUTE privilege_query INTO privileges_before USING fixed_tables;
 function_privilege_query:=$function_privileges$
   SELECT jsonb_agg(jsonb_build_array(p.oid::regprocedure::text,r.rolname,a.privilege,has_function_privilege(r.oid,p.oid,a.privilege))
                    ORDER BY p.oid::regprocedure::text,r.rolname,a.privilege)
   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace CROSS JOIN pg_roles r
     CROSS JOIN unnest(ARRAY['EXECUTE','EXECUTE WITH GRANT OPTION']) a(privilege)
   WHERE n.nspname='public' AND p.oid::regprocedure::text=ANY($1)
 $function_privileges$;
 EXECUTE function_privilege_query INTO function_privileges_before USING fixed_functions;
 FOR relation IN SELECT c.relname FROM pg_class c WHERE c.relnamespace='public'::regnamespace
                 AND c.relname=ANY(materialize) ORDER BY c.relname LOOP
   EXECUTE format('GRANT ALL PRIVILEGES ON TABLE public.%I TO %I',relation.relname,expected_owner);
 END LOOP;
 FOR relation IN SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public' AND p.oid::regprocedure::text=ANY(materialize_functions) ORDER BY p.proname LOOP
   EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I() TO %I',relation.proname,expected_owner);
 END LOOP;
 EXECUTE code_query INTO code_candidate;
 EXECUTE merge_query INTO merge_candidate;
 EXECUTE privilege_query INTO privileges_after USING fixed_tables;
 EXECUTE function_privilege_query INTO function_privileges_after USING fixed_functions;
 IF code_seal IS DISTINCT FROM (SELECT to_jsonb(i) FROM public.employee_code_reuse_installation i WHERE singleton)
    OR merge_seal IS DISTINCT FROM (SELECT to_jsonb(i) FROM public.employee_identity_merge_installation i WHERE version='v1')
    OR privileges_before IS DISTINCT FROM privileges_after
    OR function_privileges_before IS DISTINCT FROM function_privileges_after
    OR encode(public.digest(convert_to(code_candidate::text,'UTF8'),'sha256'),'hex') IS DISTINCT FROM code_seal->>'catalog_sha256'
    OR encode(public.digest(convert_to(merge_candidate::text,'UTF8'),'sha256'),'hex') IS DISTINCT FROM merge_seal->>'catalog_sha256' THEN
   RAISE EXCEPTION 'Owner-default ACL materialization changed authority or seal identity; forward adoption refused';
 END IF;
 PERFORM set_config('search_path',original_search_path,true);
END;
$employee_sealed_owner_default_acl$;
-- END CANONICAL EMPLOYEE SEALED OWNER-DEFAULT ACL RESTORE

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
