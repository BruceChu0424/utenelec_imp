-- Explicit V948-compatible installation. The caller supplies this file's SHA256
-- in app.employee_identity_merge_install_sha inside a reviewed transaction.
-- V964 embeds these identical payload bytes and performs a strict adoption.
DO $employee_identity_merge_install$
DECLARE expected_sha text:=current_setting('app.employee_identity_merge_install_sha',true);
        installed record; source_fk record; expected_catalog_body text; own_function record;
BEGIN
  IF COALESCE(expected_sha,'') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Reviewed employee merge installer SHA256 is required';
  END IF;
  IF current_user IS DISTINCT FROM (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid='public.employees'::regclass) THEN
    RAISE EXCEPTION 'Install as the existing employees owner, never an unrelated privileged definer';
  END IF;
  PERFORM pg_advisory_xact_lock(1431586126,964);
  IF to_regclass('public.employee_identity_merge_installation') IS NOT NULL THEN
    EXECUTE 'SELECT payload_sha256,catalog_sha256 FROM public.employee_identity_merge_installation WHERE version=''v1''' INTO installed;
    expected_catalog_body:=(regexp_match(current_query(),
      'CREATE FUNCTION public.fn_employee_merge_catalog_sha\(\)[\s\S]*?AS \$body\$([\s\S]*?)\$body\$'))[1];
    IF expected_catalog_body IS NULL OR NOT EXISTS(SELECT 1 FROM pg_proc p
       WHERE p.oid=to_regprocedure('public.fn_employee_merge_catalog_sha()')
         AND p.prosrc=expected_catalog_body AND p.prosecdef AND p.provolatile='s'
         AND regexp_replace(array_to_string(p.proconfig,','),'\s','','g')='search_path=pg_catalog,public,pg_temp') THEN
      RAISE EXCEPTION 'Catalog verifier definition/attributes drifted; independent adoption check refused';
    END IF;
    IF installed.payload_sha256 IS NULL OR installed.payload_sha256<>expected_sha
       OR to_regprocedure('public.fn_employee_merge_catalog_sha()') IS NULL
       OR public.fn_employee_merge_catalog_sha()<>installed.catalog_sha256 THEN
      RAISE EXCEPTION 'Existing employee merge extension differs from the reviewed source/catalog; adoption refused';
    END IF;
    RETURN;
  END IF;
  IF to_regclass('public.employee_identity_merges') IS NOT NULL
     OR to_regclass('public.employee_identity_merge_payloads') IS NOT NULL
     OR NOT EXISTS(SELECT 1 FROM public.flyway_schema_history WHERE version='947' AND success) THEN
    RAISE EXCEPTION 'Partial extension or missing V937/V947 prerequisite';
  END IF;
  CREATE TABLE public.employee_identity_merge_installation(
    version text PRIMARY KEY,payload_sha256 text NOT NULL,catalog_sha256 text NOT NULL,
    installed_at timestamptz NOT NULL DEFAULT clock_timestamp(),installed_by text NOT NULL DEFAULT current_user);
  CREATE TABLE public.employee_identity_merges(
    source_employee_id uuid PRIMARY KEY,canonical_employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
    source_code text NOT NULL,source_legacy_id integer,merged_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    merged_by text NOT NULL,evidence_reference text NOT NULL,evidence_sha256 text NOT NULL CHECK(evidence_sha256~'^[0-9a-f]{64}$'),
    preservation_reference text NOT NULL,preservation_sha256 text NOT NULL CHECK(preservation_sha256~'^[0-9a-f]{64}$'),
    reference_manifest jsonb NOT NULL,payload_sha256 text NOT NULL CHECK(payload_sha256~'^[0-9a-f]{64}$'),
    CHECK(source_employee_id<>canonical_employee_id),CHECK(length(btrim(source_code)) BETWEEN 1 AND 128));
  CREATE INDEX employee_identity_merges_canonical_idx ON public.employee_identity_merges(canonical_employee_id);
  CREATE TABLE public.employee_identity_merge_payloads(
    source_employee_id uuid PRIMARY KEY,snapshot_enc text NOT NULL,scope_sha256 text NOT NULL CHECK(scope_sha256~'^[0-9a-f]{64}$'),
    ciphertext_sha256 text NOT NULL CHECK(ciphertext_sha256~'^[0-9a-f]{64}$'),created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY(source_employee_id) REFERENCES public.employee_identity_merges(source_employee_id) DEFERRABLE INITIALLY DEFERRED);
  CREATE TABLE public.employee_legacy_identity_aliases(
    namespace_key text NOT NULL CHECK(namespace_key='B_WORKER'),legacy_id integer NOT NULL CHECK(legacy_id>0),
    canonical_employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
    source_employee_id uuid NOT NULL REFERENCES public.employee_identity_merges(source_employee_id) ON DELETE RESTRICT,
    evidence_reference text NOT NULL,PRIMARY KEY(namespace_key,legacy_id));
  CREATE TABLE public.employee_identity_historical_claims(
    source_employee_id uuid NOT NULL REFERENCES public.employee_identity_merges(source_employee_id) ON DELETE RESTRICT,
    canonical_employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
    claim_kind text NOT NULL CHECK(claim_kind IN('DOCUMENT','PHONE')),claim_hash text NOT NULL CHECK(claim_hash~'^[0-9a-f]{64}$'),
    ownership_verified boolean NOT NULL,normalization_version integer NOT NULL CHECK(normalization_version=1),
    evidence_reference text NOT NULL,PRIMARY KEY(source_employee_id,claim_kind,claim_hash));
  CREATE INDEX employee_identity_historical_claim_idx ON public.employee_identity_historical_claims(claim_kind,claim_hash);
  CREATE TABLE public.employee_identity_user_tombstones(
    source_user_id uuid PRIMARY KEY,source_employee_id uuid NOT NULL REFERENCES public.employee_identity_merges(source_employee_id),
    canonical_employee_id uuid NOT NULL REFERENCES public.employees(id),retained_user_id uuid REFERENCES public.users(id),
    evidence_reference text NOT NULL);
  CREATE TABLE public.employee_identity_legacy_roles(
    source_table text NOT NULL,uuid_column text NOT NULL,legacy_column text NOT NULL,
    namespace_key text NOT NULL CHECK(namespace_key='B_WORKER'),PRIMARY KEY(source_table,uuid_column));
  INSERT INTO public.employee_identity_legacy_roles VALUES
    ('purchase_requests','applicant_id','applicant_legacy_id','B_WORKER'),('purchase_orders','purchaser_id','purchaser_legacy_id','B_WORKER'),
    ('purchase_receipts','sender_id','sender_legacy_id','B_WORKER'),('purchase_receipts','receiver_id','receiver_legacy_id','B_WORKER'),
    ('purchase_receipts','purchaser_id','purchaser_legacy_id','B_WORKER'),('sales_orders','seller_id','seller_legacy_id','B_WORKER'),
    ('sales_shipments','seller_id','seller_legacy_id','B_WORKER'),('sales_shipments','sender_id','sender_legacy_id','B_WORKER'),
    ('sales_other_shipments','seller_id','seller_legacy_id','B_WORKER'),('sales_other_shipments','sender_id','sender_legacy_id','B_WORKER'),
    ('sales_returns','seller_id','seller_legacy_id','B_WORKER'),('finance_receipts','operator_id','operator_legacy_id','B_WORKER'),
    ('finance_payments','operator_id','operator_legacy_id','B_WORKER'),('finance_expenses','operator_id','operator_legacy_id','B_WORKER'),
    ('finance_other_incomes','operator_id','operator_legacy_id','B_WORKER'),('stock_documents','worker_id','worker_legacy_id','B_WORKER'),
    ('subcontract_material_issues','worker_id','operator_legacy_id','B_WORKER'),('subcontract_material_returns','worker_id','operator_legacy_id','B_WORKER'),
    ('subcontract_receipts','sender_id','receiver_legacy_id','B_WORKER');
  CREATE TABLE public.employee_identity_review_certificates(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),review_kind text NOT NULL CHECK(review_kind IN('NAME_DISTINCT','IDENTIFIER')),
    new_employee_id uuid NOT NULL,normalized_name text,new_document_hash text,existing_snapshot_sha256 text,
    claim_kind text CHECK(claim_kind IN('DOCUMENT','PHONE')),claim_hash text,reviewed_claim_sources uuid[] NOT NULL DEFAULT '{}',
    evidence_reference text NOT NULL,evidence_sha256 text NOT NULL CHECK(evidence_sha256~'^[0-9a-f]{64}$'),
    reviewed_by text NOT NULL,reviewed_at timestamptz NOT NULL DEFAULT clock_timestamp(),expires_at timestamptz NOT NULL,
    CHECK(expires_at>reviewed_at AND expires_at<=reviewed_at+interval '24 hours'),
    CHECK(CASE WHEN review_kind='NAME_DISTINCT' THEN COALESCE(length(btrim(normalized_name))>0 AND new_document_hash~'^[0-9a-f]{64}$' AND existing_snapshot_sha256~'^[0-9a-f]{64}$',false)
       ELSE COALESCE(claim_kind IN('DOCUMENT','PHONE') AND claim_hash~'^[0-9a-f]{64}$' AND cardinality(reviewed_claim_sources)>0,false) END));
  CREATE INDEX employee_identity_reviews_employee_idx ON public.employee_identity_review_certificates(new_employee_id,review_kind);
  COMMENT ON TABLE public.employee_identity_merges IS 'Permanent exact physical employee merge certificates; removed UUIDs never identify a new person';
  COMMENT ON TABLE public.employee_identity_merge_payloads IS 'Private encrypted source preimages; never exposed through generic audit or archive payload APIs';

  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_document_dependencies(document_ids uuid[],own_table text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    DECLARE relation record; result jsonb:='{}'::jsonb; fingerprint text;
    BEGIN
      IF cardinality(document_ids)=0 THEN RETURN result;END IF;
      FOR relation IN SELECT c.relname,string_agg(format('t.%I=ANY($1)',a.attname),' OR ' ORDER BY a.attnum) AS predicate,
          bool_or(a.attname='id') FILTER(WHERE a.atttypid='uuid'::regtype) AS uuid_id
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
        WHERE n.nspname='public' AND c.relkind IN('r','p') AND NOT c.relispartition AND a.atttypid='uuid'::regtype
          AND (a.attname~'(document|doc|parent|owner|record|source|origin)_id$'
            OR EXISTS(SELECT 1 FROM pg_constraint fk WHERE fk.conrelid=c.oid AND fk.contype='f' AND a.attnum=ANY(fk.conkey)
                 AND fk.confrelid IN('public.stock_documents'::regclass,'public.purchase_requests'::regclass)))
          AND c.relname NOT IN('employee_identity_merges','employee_identity_merge_payloads','employee_identity_historical_claims','employee_identity_user_tombstones','employee_legacy_identity_aliases')
        GROUP BY c.relname ORDER BY c.relname
      LOOP
        EXECUTE format('SELECT encode(public.digest(COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),''[]''::jsonb)::text,''sha256''),''hex'') FROM public.%I t WHERE (%s)%s',relation.relname,relation.predicate,
            CASE WHEN relation.relname=own_table THEN ' AND NOT(t.id=ANY($1))' ELSE '' END)
          INTO fingerprint USING document_ids;
        result:=result||jsonb_build_object(relation.relname,fingerprint);
      END LOOP;
      RETURN result;
    END $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_foreign_key_references(target_table regclass,target_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    DECLARE edge record; n bigint; result jsonb:='[]'::jsonb;
    BEGIN
      FOR edge IN SELECT ns.nspname,c.relname,a.attname FROM pg_constraint fk
        JOIN pg_class c ON c.oid=fk.conrelid JOIN pg_namespace ns ON ns.oid=c.relnamespace
        JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=fk.conkey[1]
        JOIN pg_attribute target ON target.attrelid=fk.confrelid AND target.attnum=fk.confkey[1]
        WHERE fk.contype='f' AND fk.confrelid=target_table AND array_length(fk.conkey,1)=1 AND target.attname='id'
        ORDER BY ns.nspname,c.relname,a.attname
      LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I WHERE %I=$1',edge.nspname,edge.relname,edge.attname) INTO n USING target_id;
        IF n>0 THEN result:=result||jsonb_build_array(jsonb_build_object('schema',edge.nspname,'table',edge.relname,'column',edge.attname,'count',n));END IF;
      END LOOP;
      RETURN result;
    END $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_source_fingerprint(source_id uuid) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    BEGIN RETURN encode(public.digest(public.fn_employee_merge_source_snapshot($1)::text,'sha256'),'hex');END
    $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_completed(source_id uuid,retained_id uuid,released_code text)
    RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
      SELECT EXISTS(SELECT 1 FROM public.employee_identity_merges m JOIN public.employees retained ON retained.id=m.canonical_employee_id
        WHERE m.source_employee_id=source_id AND m.canonical_employee_id=retained_id
          AND upper(btrim(m.source_code))=upper(btrim(released_code)) AND NOT retained.is_deleted
          AND NOT EXISTS(SELECT 1 FROM public.employees old WHERE old.id=source_id))
    $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_evidence_immutable() RETURNS trigger
    LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $body$
    BEGIN RAISE EXCEPTION 'Employee merge evidence is permanent and append-only' USING ERRCODE='55000';END $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_retired_uuid_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    BEGIN
      IF EXISTS(SELECT 1 FROM public.employee_identity_merges WHERE source_employee_id=NEW.id) THEN
        RAISE EXCEPTION 'A retired employee UUID cannot be recreated for any code' USING ERRCODE='23514';
      END IF;
      RETURN NEW;
    END $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_deleted_source_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    BEGIN
      IF current_setting('app.employee_merge_source',true) IS DISTINCT FROM OLD.id::text
         OR NOT EXISTS(SELECT 1 FROM public.employee_identity_merge_payloads WHERE source_employee_id=OLD.id) THEN
        RAISE EXCEPTION 'Physical employee removal requires the dedicated encrypted merge transaction' USING ERRCODE='42501';
      END IF;
      RETURN OLD;
    END $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_source_completion_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    BEGIN
      IF NOT EXISTS(SELECT 1 FROM public.employee_identity_merges m
          WHERE m.source_employee_id=OLD.id AND public.fn_employee_merge_completed(OLD.id,m.canonical_employee_id,OLD.code)) THEN
        RAISE EXCEPTION 'Removed employee is missing its exact completed merge certificate' USING ERRCODE='23514';
      END IF;
      RETURN NULL;
    END $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_alias_tombstone_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    BEGIN
      IF NOT EXISTS(SELECT 1 FROM public.employees WHERE id=NEW.alias_employee_id)
         AND NOT EXISTS(SELECT 1 FROM public.employee_identity_merges m
           WHERE m.source_employee_id=NEW.alias_employee_id AND m.canonical_employee_id=NEW.canonical_employee_id
             AND public.fn_employee_merge_completed(m.source_employee_id,m.canonical_employee_id,m.source_code)) THEN
        RAISE EXCEPTION 'Alias source must exist or have its exact physical merge certificate' USING ERRCODE='23514';
      END IF;
      RETURN NULL;
    END $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_identity_from_legacy_worker(legacy_worker_id integer) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
      SELECT COALESCE((SELECT id FROM public.employees WHERE legacy_id=legacy_worker_id),
        (SELECT canonical_employee_id FROM public.employee_legacy_identity_aliases WHERE namespace_key='B_WORKER' AND legacy_id=legacy_worker_id))
    $body$
  $definition$;
  CREATE TRIGGER trg_employee_merge_retired_uuid BEFORE INSERT ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.fn_employee_merge_retired_uuid_guard();
  CREATE TRIGGER trg_employee_merge_physical_delete BEFORE DELETE ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.fn_employee_merge_deleted_source_guard();
  CREATE CONSTRAINT TRIGGER trg_employee_merge_source_completion AFTER DELETE ON public.employees
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.fn_employee_merge_source_completion_guard();
  CREATE CONSTRAINT TRIGGER trg_employee_merge_alias_tombstone AFTER INSERT ON public.employee_identity_aliases
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.fn_employee_merge_alias_tombstone_guard();
  ALTER TABLE public.employees ENABLE ALWAYS TRIGGER trg_employee_merge_retired_uuid;
  ALTER TABLE public.employees ENABLE ALWAYS TRIGGER trg_employee_merge_physical_delete;
  ALTER TABLE public.employees ENABLE ALWAYS TRIGGER trg_employee_merge_source_completion;
  ALTER TABLE public.employee_identity_aliases ENABLE ALWAYS TRIGGER trg_employee_merge_alias_tombstone;
  FOR source_fk IN SELECT c.conname FROM pg_constraint c JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=c.conkey[1]
    WHERE c.contype='f' AND c.conrelid='public.employee_identity_aliases'::regclass
      AND c.confrelid='public.employees'::regclass AND array_length(c.conkey,1)=1 AND a.attname='alias_employee_id'
  LOOP EXECUTE format('ALTER TABLE public.employee_identity_aliases DROP CONSTRAINT %I',source_fk.conname);END LOOP;
  IF NOT FOUND THEN RAISE EXCEPTION 'Expected original alias source FK was not found';END IF;

  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_database_identity() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
      SELECT jsonb_build_object('database',current_database(),'database_oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),
        'dataset_id',business_dataset_id::text,'generation',business_reset_generation,
        'migration_max',(SELECT max(version::int) FROM flyway_schema_history WHERE success),
        'migration_sha256',(SELECT encode(public.digest(COALESCE(jsonb_agg(jsonb_build_array(version,checksum) ORDER BY installed_rank)::text,'[]'),'sha256'),'hex') FROM flyway_schema_history WHERE success))
      FROM authorization_state WHERE singleton_id=1
    $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_source_snapshot(p_source_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    DECLARE result jsonb; legacy_number integer; role record; projection jsonb; projections jsonb:='[]'::jsonb;
    BEGIN
      SELECT legacy_id INTO legacy_number FROM employees WHERE id=p_source_id;
      SELECT jsonb_build_object(
        'employee',(SELECT to_jsonb(e) FROM employees e WHERE id=p_source_id),
        'sensitive',(SELECT to_jsonb(s) FROM employee_sensitive s WHERE employee_id=p_source_id),
        'education',(SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM employee_education e WHERE employee_id=p_source_id),
        'users',(SELECT COALESCE(jsonb_agg(to_jsonb(u) ORDER BY id),'[]'::jsonb) FROM users u WHERE employee_id=p_source_id),
        'stock_documents',(SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY id),'[]'::jsonb) FROM stock_documents s WHERE worker_id=p_source_id),
        'aliases',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY alias_employee_id),'[]'::jsonb) FROM employee_identity_aliases a WHERE alias_employee_id=p_source_id OR canonical_employee_id=p_source_id),
        'master_reservations',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY normalized_code),'[]'::jsonb) FROM master_code_reservations r WHERE first_entity_id=p_source_id),
        'master_members',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY normalized_code),'[]'::jsonb) FROM master_code_reservation_members r WHERE entity_id=p_source_id),
        'identifier_reservations',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY normalized_identifier),'[]'::jsonb) FROM business_identifier_reservations r WHERE first_entity_id=p_source_id),
        'identifier_members',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY normalized_identifier),'[]'::jsonb) FROM business_identifier_reservation_members r WHERE entity_id=p_source_id)) INTO result;
      IF legacy_number IS NOT NULL THEN
        FOR role IN SELECT * FROM employee_identity_legacy_roles ORDER BY source_table,uuid_column LOOP
          EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),''[]''::jsonb) FROM public.%I t WHERE %I=$1 AND (%I IS NULL OR %I=$2)',
             role.source_table,role.legacy_column,role.uuid_column,role.uuid_column) INTO projection USING legacy_number,p_source_id;
          IF jsonb_array_length(projection)>0 THEN projections:=projections||jsonb_build_array(jsonb_build_object(
            'table',role.source_table,'column',role.uuid_column,'legacy_column',role.legacy_column,'legacy_id',legacy_number,'rows',projection));END IF;
        END LOOP;
      END IF;
      RETURN result||jsonb_build_object('typed_legacy_projections',projections);
    END
    $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_uuid_references(source_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    DECLARE field record; n bigint; result jsonb:='[]'::jsonb;
    BEGIN
      FOR field IN SELECT c.relname,a.attname,a.atttypid FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
        WHERE n.nspname='public' AND c.relkind IN('r','p') AND NOT c.relispartition AND a.attname<>'id'
          AND a.atttypid IN('uuid'::regtype,'uuid[]'::regtype)
          AND c.relname NOT IN('employee_identity_merges','employee_identity_merge_payloads','employee_identity_historical_claims','employee_identity_user_tombstones','employee_legacy_identity_aliases')
        ORDER BY c.relname,a.attname
      LOOP
        EXECUTE format('SELECT count(*) FROM public.%I WHERE %s',field.relname,
          CASE WHEN field.atttypid='uuid'::regtype THEN format('%I=$1',field.attname) ELSE format('$1=ANY(%I)',field.attname) END) INTO n USING source_id;
        IF n>0 THEN result:=result||jsonb_build_array(jsonb_build_object('table',field.relname,'column',field.attname,'count',n));END IF;
      END LOOP;
      RETURN result;
    END $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_user_retired_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    BEGIN
      IF EXISTS(SELECT 1 FROM employee_identity_user_tombstones WHERE source_user_id=NEW.id) THEN
        RAISE EXCEPTION 'A retired user UUID cannot be recreated or reenabled' USING ERRCODE='23514';
      END IF;
      RETURN NEW;
    END $body$
  $definition$;
  CREATE TRIGGER trg_employee_merge_retired_user BEFORE INSERT ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.fn_employee_merge_user_retired_guard();
  ALTER TABLE public.users ENABLE ALWAYS TRIGGER trg_employee_merge_retired_user;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_legacy_retired_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    BEGIN
      IF NEW.legacy_id IS NOT NULL AND EXISTS(SELECT 1 FROM employee_legacy_identity_aliases
          WHERE namespace_key='B_WORKER' AND legacy_id=NEW.legacy_id AND canonical_employee_id<>NEW.id) THEN
        RAISE EXCEPTION 'Historical B_WORKER identity cannot be reassigned to a new person' USING ERRCODE='23514';
      END IF;
      RETURN NEW;
    END $body$
  $definition$;
  CREATE TRIGGER trg_employee_merge_retired_legacy BEFORE INSERT OR UPDATE OF legacy_id ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.fn_employee_merge_legacy_retired_guard();
  ALTER TABLE public.employees ENABLE ALWAYS TRIGGER trg_employee_merge_retired_legacy;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_name_snapshot_sha(full_name text,excluded_employee uuid DEFAULT NULL) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
      SELECT encode(public.digest(COALESCE(jsonb_agg(jsonb_build_array(e.id,e.version,e.id_type,s.id_card_hash,s.id_card_check,
        encode(public.digest(s.id_card_enc,'sha256'),'hex')) ORDER BY e.id),'[]'::jsonb)::text,'sha256'),'hex')
      FROM employees e LEFT JOIN employee_sensitive s ON s.employee_id=e.id
      WHERE NOT e.is_deleted AND e.id IS DISTINCT FROM $2 AND btrim(e.full_name)=btrim($1) AND fn_canonical_employee_identity(e.id)=e.id
    $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_new_name_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    BEGIN
      PERFORM pg_advisory_xact_lock(hashtextextended('employee-new-name:'||btrim(NEW.full_name),0));
      IF EXISTS(SELECT 1 FROM employees e WHERE NOT e.is_deleted AND btrim(e.full_name)=btrim(NEW.full_name)
           AND fn_canonical_employee_identity(e.id)=e.id)
         AND NOT EXISTS(SELECT 1 FROM employee_identity_review_certificates r WHERE r.review_kind='NAME_DISTINCT'
           AND r.new_employee_id=NEW.id AND r.normalized_name=btrim(NEW.full_name) AND r.expires_at>clock_timestamp()
           AND r.existing_snapshot_sha256=fn_employee_merge_name_snapshot_sha(NEW.full_name)) THEN
        RAISE EXCEPTION '已有同名人员，请使用原档案；确为不同人员需管理员签发不同有效身份核验凭证' USING ERRCODE='23514';
      END IF;
      RETURN NEW;
    END $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_name_review_completion() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    DECLARE review employee_identity_review_certificates%ROWTYPE; document_hash text;
    BEGIN
      IF NOT EXISTS(SELECT 1 FROM employees e WHERE e.id<>NEW.id AND NOT e.is_deleted
          AND btrim(e.full_name)=btrim(NEW.full_name) AND fn_canonical_employee_identity(e.id)=e.id) THEN RETURN NULL;END IF;
      SELECT * INTO review FROM employee_identity_review_certificates r WHERE r.review_kind='NAME_DISTINCT'
        AND r.new_employee_id=NEW.id AND r.normalized_name=btrim(NEW.full_name) AND r.expires_at>clock_timestamp() ORDER BY reviewed_at DESC LIMIT 1;
      SELECT id_card_hash INTO document_hash FROM employee_sensitive WHERE employee_id=NEW.id AND id_card_check='valid';
      IF review.id IS NULL OR NEW.id_type<>'身份证' OR document_hash IS NULL OR document_hash IS DISTINCT FROM review.new_document_hash
         OR review.existing_snapshot_sha256 IS DISTINCT FROM fn_employee_merge_name_snapshot_sha(NEW.full_name,NEW.id)
         OR EXISTS(SELECT 1 FROM employees e LEFT JOIN employee_sensitive s ON s.employee_id=e.id
           WHERE e.id<>NEW.id AND NOT e.is_deleted AND btrim(e.full_name)=btrim(NEW.full_name)
             AND fn_canonical_employee_identity(e.id)=e.id AND (s.id_card_hash IS NULL OR s.id_card_check<>'valid' OR s.id_card_hash=document_hash)) THEN
        RAISE EXCEPTION '同名新增未完成双方不同完整有效身份核验；整笔入职回滚' USING ERRCODE='23514';
      END IF;
      RETURN NULL;
    END $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_identifier_reviewed(employee_id uuid,kind text,value_hash text,claim_source uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
      SELECT EXISTS(SELECT 1 FROM employee_identity_review_certificates r WHERE r.review_kind='IDENTIFIER'
        AND r.new_employee_id=$1 AND r.claim_kind=$2 AND r.claim_hash=$3 AND $4=ANY(r.reviewed_claim_sources) AND r.expires_at>clock_timestamp())
    $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_historical_sensitive_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    DECLARE old_claim record; canonical uuid:=fn_canonical_employee_identity(NEW.employee_id);
    BEGIN
      IF NEW.id_card_enc IS NOT NULL AND NEW.id_card_hash IS NULL
         AND (TG_OP='INSERT' OR NEW.id_card_enc IS DISTINCT FROM OLD.id_card_enc OR OLD.id_card_hash IS NOT NULL) THEN
        RAISE EXCEPTION '证件新录入或更正必须生成规范防重指纹，不能以空HMAC绕过身份核验' USING ERRCODE='23514';
      END IF;
      IF NEW.phone_enc IS NOT NULL AND NEW.phone_hash IS NULL
         AND (TG_OP='INSERT' OR NEW.phone_enc IS DISTINCT FROM OLD.phone_enc OR OLD.phone_hash IS NOT NULL) THEN
        RAISE EXCEPTION '主手机号新录入或更正必须生成规范防重指纹' USING ERRCODE='23514';
      END IF;
      FOR old_claim IN SELECT * FROM employee_identity_historical_claims c WHERE c.canonical_employee_id<>canonical
        AND ((c.claim_kind='DOCUMENT' AND c.claim_hash=NEW.id_card_hash) OR (c.claim_kind='PHONE' AND c.claim_hash=NEW.phone_hash)) LOOP
        IF (NOT old_claim.ownership_verified OR old_claim.claim_kind='PHONE')
           AND fn_employee_merge_identifier_reviewed(NEW.employee_id,old_claim.claim_kind,old_claim.claim_hash,old_claim.source_employee_id) THEN CONTINUE;END IF;
        IF old_claim.ownership_verified THEN
          RAISE EXCEPTION '该身份信息已归属保留人员档案，请核对原档案，不能另建同人副档' USING ERRCODE='23505',CONSTRAINT='employee_historical_identity_claim';
        ELSE
          RAISE EXCEPTION '旧档相同身份字段存在待核验冲突，请管理员明确核验，不自动绑定或另建' USING ERRCODE='23514';
        END IF;
      END LOOP;
      RETURN NEW;
    END $body$
  $definition$;
  CREATE TRIGGER trg_employee_merge_new_name BEFORE INSERT ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.fn_employee_merge_new_name_guard();
  CREATE CONSTRAINT TRIGGER trg_employee_merge_name_review AFTER INSERT ON public.employees DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.fn_employee_merge_name_review_completion();
  CREATE TRIGGER trg_employee_merge_historical_sensitive BEFORE INSERT OR UPDATE OF id_card_enc,id_card_hash,phone_enc,phone_hash ON public.employee_sensitive
    FOR EACH ROW EXECUTE FUNCTION public.fn_employee_merge_historical_sensitive_guard();
  ALTER TABLE public.employees ENABLE ALWAYS TRIGGER trg_employee_merge_new_name;
  ALTER TABLE public.employees ENABLE ALWAYS TRIGGER trg_employee_merge_name_review;
  ALTER TABLE public.employee_sensitive ENABLE ALWAYS TRIGGER trg_employee_merge_historical_sensitive;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_historical_claim_owner_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    BEGIN
      IF NEW.ownership_verified AND (
        EXISTS(SELECT 1 FROM employee_identity_historical_claims h WHERE h.claim_kind=NEW.claim_kind AND h.claim_hash=NEW.claim_hash
             AND h.ownership_verified AND h.canonical_employee_id<>NEW.canonical_employee_id)
        OR EXISTS(SELECT 1 FROM employee_sensitive s WHERE
             ((NEW.claim_kind='DOCUMENT' AND s.id_card_hash=NEW.claim_hash) OR (NEW.claim_kind='PHONE' AND s.phone_hash=NEW.claim_hash))
             AND fn_canonical_employee_identity(s.employee_id)<>NEW.canonical_employee_id)) THEN
        RAISE EXCEPTION 'Verified historical identity claim conflicts with another retained person; review the source ownership' USING ERRCODE='23505';
      END IF;
      RETURN NEW;
    END $body$
  $definition$;
  CREATE TRIGGER trg_employee_merge_historical_claim_owner BEFORE INSERT ON public.employee_identity_historical_claims
    FOR EACH ROW EXECUTE FUNCTION public.fn_employee_merge_historical_claim_owner_guard();
  ALTER TABLE public.employee_identity_historical_claims ENABLE ALWAYS TRIGGER trg_employee_merge_historical_claim_owner;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_retained_user(source_user_id uuid) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
      SELECT COALESCE((SELECT id FROM users WHERE id=$1 AND NOT is_deleted AND status='active'),
        (SELECT u.id FROM employee_identity_user_tombstones t JOIN users u ON u.employee_id=t.canonical_employee_id
         WHERE t.source_user_id=$1 AND NOT u.is_deleted AND u.status='active'))
    $body$
  $definition$;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_merge_employee_identity(plan jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    DECLARE source_id uuid:=(plan->>'source_employee_id')::uuid; retained_id uuid:=(plan->>'canonical_employee_id')::uuid;
      source_row employees%ROWTYPE; retained_row employees%ROWTYPE; scope_snapshot jsonb; scope_sha text;
      encryption text:=plan->>'snapshot_enc'; cipher_sha text; evidence text; operator_name text;
      source_user record; education record; existing_education uuid; new_education uuid; role record;
      education_map jsonb:='[]'::jsonb; worker_map jsonb:='[]'::jsonb; user_map jsonb:='[]'::jsonb;
      refs jsonb; reference jsonb; claim jsonb; patch jsonb:=COALESCE(plan->'canonical_patch','{}'::jsonb);
      retained_user uuid; old_epoch bigint; worker_count integer; expected_workers integer;
      legacy_filled boolean:=false; canonical_changed boolean:=false;
      canonical_accounts_before text; nonperson_sha text; changed_rows integer; expected_projection integer;
      projection_rows jsonb; projection_record jsonb; expected_row jsonb; actual_row jsonb; legacy_map jsonb:='[]'::jsonb;
      dependent_before jsonb; dependent_after jsonb; document_ids uuid[];
    BEGIN
      IF plan->>'protocol' IS DISTINCT FROM 'employee-identity-merge-v1'
         OR NOT COALESCE((plan->>'human_same_person_confirmed')::boolean,false)
         OR NOT COALESCE((plan->>'preservation_verified')::boolean,false)
         OR source_id IS NULL OR retained_id IS NULL OR source_id=retained_id
         OR COALESCE(plan->>'evidence_sha256','') !~ '^[0-9a-f]{64}$'
         OR COALESCE(plan->>'preservation_sha256','') !~ '^[0-9a-f]{64}$'
         OR NOT COALESCE((plan->>'paired_backup_verified')::boolean,false)
         OR COALESCE(plan->>'paired_backup_manifest_sha256','') !~ '^[0-9a-f]{64}$'
         OR length(COALESCE(plan->>'paired_backup_reference','')) NOT BETWEEN 1 AND 1000
         OR (plan->>'captured_at') IS NULL
         OR (plan->>'captured_at')::timestamptz<clock_timestamp()-interval '24 hours'
         OR (plan->>'captured_at')::timestamptz>clock_timestamp()+interval '5 minutes'
         OR length(COALESCE(plan->>'reason','')) NOT BETWEEN 5 AND 1000 THEN
        RAISE EXCEPTION 'Explicit identity confirmation, preserved encrypted evidence and reviewed reason are required';
      END IF;
      IF plan->'database_identity' IS DISTINCT FROM fn_employee_merge_database_identity() THEN
        RAISE EXCEPTION 'Reviewed database/dataset/migration identity differs';
      END IF;
      IF EXISTS(SELECT 1 FROM employee_identity_merges WHERE source_employee_id=source_id) THEN
        IF NOT EXISTS(SELECT 1 FROM employee_identity_merges WHERE source_employee_id=source_id AND canonical_employee_id=retained_id
          AND evidence_sha256=plan->>'evidence_sha256' AND payload_sha256=plan->>'snapshot_ciphertext_sha256') THEN
          RAISE EXCEPTION 'Existing merge certificate belongs to another reviewed request';
        END IF;
        RETURN jsonb_build_object('status','ALREADY_MERGED','source_employee_id',source_id,'canonical_employee_id',retained_id);
      END IF;
      PERFORM pg_advisory_xact_lock(1431586126,937);
      PERFORM id FROM employees WHERE id IN(source_id,retained_id) ORDER BY id FOR UPDATE;
      PERFORM id FROM users WHERE employee_id IN(source_id,retained_id) ORDER BY id FOR UPDATE;
      PERFORM employee_id FROM employee_sensitive WHERE employee_id IN(source_id,retained_id) ORDER BY employee_id FOR UPDATE;
      PERFORM id FROM employee_education WHERE employee_id IN(source_id,retained_id) ORDER BY id FOR UPDATE;
      PERFORM id FROM stock_documents WHERE worker_id=source_id ORDER BY id FOR UPDATE;
      PERFORM singleton_id FROM authorization_state WHERE singleton_id=1 FOR UPDATE;
      SELECT * INTO STRICT source_row FROM employees WHERE id=source_id;
      SELECT * INTO STRICT retained_row FROM employees WHERE id=retained_id;
      IF NOT source_row.is_deleted AND source_row.status IN('active','probation','onLeave') AND retained_row.status='resigned' THEN
        RAISE EXCEPTION 'A current employment cannot be merged into a resigned master';
      END IF;
      IF source_row.legacy_id IS NOT NULL THEN
        FOR role IN SELECT * FROM employee_identity_legacy_roles ORDER BY source_table,uuid_column LOOP
          EXECUTE format('SELECT id FROM public.%I WHERE %I=$1 AND %I IS NULL ORDER BY id FOR UPDATE',role.source_table,role.legacy_column,role.uuid_column)
            USING source_row.legacy_id;
        END LOOP;
      END IF;
      IF source_row.code IS DISTINCT FROM plan->>'source_code'
         OR source_row.version IS DISTINCT FROM (plan->>'source_version')::integer
         OR retained_row.version IS DISTINCT FROM (plan->>'canonical_version')::integer
         OR retained_row.is_deleted
         OR encode(public.digest(to_jsonb(retained_row)::text,'sha256'),'hex') IS DISTINCT FROM plan->>'canonical_row_sha256'
         OR EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=retained_id OR canonical_employee_id=source_id) THEN
        RAISE EXCEPTION 'Employee identity, versions or retained master fingerprint drifted';
      END IF;
      IF patch<>'{}'::jsonb AND encode(public.digest(COALESCE((SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=retained_id),'null'),'sha256'),'hex')
          IS DISTINCT FROM plan->>'canonical_sensitive_sha256' THEN
        RAISE EXCEPTION 'Retained sensitive preimage differs from the approved field correction';
      END IF;
      scope_snapshot:=fn_employee_merge_source_snapshot(source_id);
      SELECT encode(public.digest(COALESCE(jsonb_agg(to_jsonb(u) ORDER BY id),'[]'::jsonb)::text,'sha256'),'hex')
        INTO canonical_accounts_before FROM users u WHERE employee_id=retained_id;
      scope_sha:=encode(public.digest(scope_snapshot::text,'sha256'),'hex');
      cipher_sha:=encode(public.digest(encryption,'sha256'),'hex');
      IF scope_sha IS DISTINCT FROM plan->>'source_scope_sha256'
         OR cipher_sha IS DISTINCT FROM plan->>'snapshot_ciphertext_sha256'
         OR length(COALESCE(encryption,''))<40
         OR length(COALESCE(plan->>'preservation_reference','')) NOT BETWEEN 1 AND 1000 THEN
        RAISE EXCEPTION 'Complete source snapshot, encrypted envelope or preservation fingerprint differs';
      END IF;
      operator_name:=plan->>'actor';
      evidence:=(plan->>'evidence_reference')||'#sha256='||(plan->>'evidence_sha256');
      IF length(COALESCE(operator_name,'')) NOT BETWEEN 1 AND 128 OR length(COALESCE(evidence,'')) NOT BETWEEN 1 AND 1000 THEN
        RAISE EXCEPTION 'Explicit maintenance actor and durable evidence reference are required';
      END IF;
      refs:=fn_employee_merge_uuid_references(source_id);
      FOR reference IN SELECT value FROM jsonb_array_elements(refs) LOOP
        IF NOT ((reference->>'table',reference->>'column') IN(
          ('employee_sensitive','employee_id'),('employee_education','employee_id'),('users','employee_id'),('stock_documents','worker_id'),
          ('employee_identity_aliases','alias_employee_id'),('master_code_reservations','first_entity_id'),('master_code_reservation_members','entity_id'),
          ('business_identifier_reservations','first_entity_id'),('business_identifier_reservation_members','entity_id'),
          ('employee_identity_document_claims','employee_id'))) THEN
          RAISE EXCEPTION 'Unreviewed source reference remains: %.% (% rows)',reference->>'table',reference->>'column',reference->>'count';
        END IF;
      END LOOP;
      SELECT epoch INTO old_epoch FROM authorization_state WHERE singleton_id=1;
      PERFORM set_config('app.actor_account',operator_name,true);
      PERFORM set_config('app.employee_identity_merge_evidence',evidence,true);
      INSERT INTO employee_identity_merge_payloads(source_employee_id,snapshot_enc,scope_sha256,ciphertext_sha256)
      VALUES(source_id,encryption,scope_sha,cipher_sha);
      SELECT id INTO retained_user FROM users WHERE employee_id=retained_id AND NOT is_deleted;
      FOR source_user IN SELECT * FROM users WHERE employee_id=source_id LOOP
        IF NOT source_user.is_deleted OR source_user.status<>'disabled'
           OR jsonb_array_length(fn_employee_merge_uuid_references(source_user.id))<>0
           OR jsonb_array_length(fn_employee_merge_foreign_key_references('public.users'::regclass,source_user.id))<>0 THEN
          RAISE EXCEPTION 'Source account is current or referenced; complete explicit account consolidation first';
        END IF;
        user_map:=user_map||jsonb_build_array(jsonb_build_object('source_user_id',source_user.id,'retained_user_id',retained_user));
        DELETE FROM users WHERE id=source_user.id;
      END LOOP;
      FOR education IN SELECT * FROM employee_education WHERE employee_id=source_id ORDER BY id LOOP
        IF jsonb_array_length(fn_employee_merge_uuid_references(education.id))<>0
           OR jsonb_array_length(fn_employee_merge_foreign_key_references('public.employee_education'::regclass,education.id))<>0 THEN
          RAISE EXCEPTION 'Education has active dependents/attachment ownership; explicit child migration is required';
        END IF;
        SELECT e.id INTO existing_education FROM employee_education e WHERE e.employee_id=retained_id
          AND to_jsonb(e)-ARRAY['id','employee_id','created_at','updated_at','created_by','updated_by']
              =to_jsonb(education)-ARRAY['id','employee_id','created_at','updated_at','created_by','updated_by'] ORDER BY id LIMIT 1;
        new_education:=COALESCE(existing_education,gen_random_uuid());
        IF existing_education IS NULL THEN
          INSERT INTO employee_education SELECT (jsonb_populate_record(NULL::employee_education,
            to_jsonb(education)||jsonb_build_object('id',new_education,'employee_id',retained_id))).*;
        END IF;
        IF NOT EXISTS(SELECT 1 FROM employee_education e WHERE e.id=new_education AND e.employee_id=retained_id
          AND to_jsonb(e)-ARRAY['id','employee_id','created_at','updated_at','created_by','updated_by']
              =to_jsonb(education)-ARRAY['id','employee_id','created_at','updated_at','created_by','updated_by']) THEN
          RAISE EXCEPTION 'Education business fields changed while consolidating';
        END IF;
        education_map:=education_map||jsonb_build_array(jsonb_build_object('source_id',education.id,'retained_id',new_education,'deduplicated',existing_education IS NOT NULL));
        DELETE FROM employee_education WHERE id=education.id;
      END LOOP;
      expected_workers:=COALESCE((plan->>'expected_stock_worker_count')::integer,0);
      SELECT COALESCE(array_agg(id),'{}'::uuid[]) INTO document_ids FROM stock_documents WHERE worker_id=source_id;
      dependent_before:=fn_employee_merge_document_dependencies(document_ids,'stock_documents');
      SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'before_sha256',encode(public.digest(to_jsonb(s)::text,'sha256'),'hex'),
          'nonperson_sha256',encode(public.digest((to_jsonb(s)-ARRAY['worker_id','updated_at','updated_by','version','row_version','lock_version'])::text,'sha256'),'hex')) ORDER BY id),'[]'::jsonb)
        INTO worker_map FROM stock_documents s WHERE worker_id=source_id;
      UPDATE stock_documents SET worker_id=retained_id WHERE worker_id=source_id;
      GET DIAGNOSTICS worker_count=ROW_COUNT;
      IF worker_count<>expected_workers THEN RAISE EXCEPTION 'Expected stock worker reference count drifted';END IF;
      FOR expected_row IN SELECT value FROM jsonb_array_elements(scope_snapshot->'stock_documents') LOOP
        SELECT to_jsonb(s) INTO actual_row FROM stock_documents s WHERE id=(expected_row->>'id')::uuid;
        IF actual_row IS NULL OR actual_row->>'worker_id'<>retained_id::text
           OR encode(public.digest((actual_row-ARRAY['worker_id','updated_at','updated_by','version','row_version','lock_version'])::text,'sha256'),'hex')
              IS DISTINCT FROM encode(public.digest((expected_row-ARRAY['worker_id','updated_at','updated_by','version','row_version','lock_version'])::text,'sha256'),'hex') THEN
          RAISE EXCEPTION 'Stock document non-person quantities/amounts/status or source integer changed';
        END IF;
      END LOOP;
      dependent_after:=fn_employee_merge_document_dependencies(document_ids,'stock_documents');
      IF dependent_after IS DISTINCT FROM dependent_before THEN
        RAISE EXCEPTION 'Stock child/quantity/value/ledger dependencies changed: %',
          (SELECT jsonb_agg(key) FROM jsonb_object_keys(dependent_before) key WHERE dependent_before->key IS DISTINCT FROM dependent_after->key);
      END IF;
      IF source_row.legacy_id IS NOT NULL THEN
        FOR role IN SELECT * FROM employee_identity_legacy_roles ORDER BY source_table,uuid_column LOOP
          SELECT COALESCE((p->>'expected_null_count')::integer,0) INTO expected_projection
            FROM jsonb_array_elements(COALESCE(plan->'legacy_projections','[]'::jsonb)) p
            WHERE p->>'table'=role.source_table AND p->>'column'=role.uuid_column;
          expected_projection:=COALESCE(expected_projection,0);
          EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),''[]''::jsonb) FROM public.%I t WHERE %I=$1 AND %I IS NULL',
            role.source_table,role.legacy_column,role.uuid_column) INTO projection_rows USING source_row.legacy_id;
          IF jsonb_array_length(projection_rows)<>expected_projection THEN
            RAISE EXCEPTION 'Typed B_WORKER projection count differs for %.%',role.source_table,role.uuid_column;
          END IF;
          IF expected_projection=0 THEN CONTINUE;END IF;
          SELECT COALESCE(array_agg((v->>'id')::uuid),'{}'::uuid[]) INTO document_ids FROM jsonb_array_elements(projection_rows) v;
          dependent_before:=fn_employee_merge_document_dependencies(document_ids,role.source_table);
          EXECUTE format('UPDATE public.%I SET %I=$1 WHERE %I=$2 AND %I IS NULL',role.source_table,role.uuid_column,role.legacy_column,role.uuid_column)
            USING retained_id,source_row.legacy_id;
          GET DIAGNOSTICS changed_rows=ROW_COUNT;
          IF changed_rows<>expected_projection THEN RAISE EXCEPTION 'Typed projection update row count differs';END IF;
          FOR expected_row IN SELECT value FROM jsonb_array_elements(projection_rows) LOOP
            EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE id=$1',role.source_table) INTO actual_row USING (expected_row->>'id')::uuid;
            IF actual_row IS NULL OR actual_row->>role.uuid_column<>retained_id::text
               OR encode(public.digest((actual_row-ARRAY[role.uuid_column,'updated_at','updated_by','version','row_version','lock_version'])::text,'sha256'),'hex')
                  IS DISTINCT FROM encode(public.digest((expected_row-ARRAY[role.uuid_column,'updated_at','updated_by','version','row_version','lock_version'])::text,'sha256'),'hex') THEN
              RAISE EXCEPTION 'Typed B_WORKER projection changed non-person business fields for %.%',role.source_table,role.uuid_column;
            END IF;
            nonperson_sha:=encode(public.digest((expected_row-ARRAY[role.uuid_column,'updated_at','updated_by','version','row_version','lock_version'])::text,'sha256'),'hex');
            legacy_map:=legacy_map||jsonb_build_array(jsonb_build_object('table',role.source_table,'column',role.uuid_column,
                'id',expected_row->>'id','legacy_id',source_row.legacy_id,'nonperson_sha256',nonperson_sha));
          END LOOP;
          dependent_after:=fn_employee_merge_document_dependencies(document_ids,role.source_table);
          IF dependent_after IS DISTINCT FROM dependent_before THEN
            RAISE EXCEPTION 'Typed projection child/value/ledger dependencies changed for %.%: %',role.source_table,role.uuid_column,
              (SELECT jsonb_agg(key) FROM jsonb_object_keys(dependent_before) key WHERE dependent_before->key IS DISTINCT FROM dependent_after->key);
          END IF;
        END LOOP;
      END IF;
      DELETE FROM employee_sensitive WHERE employee_id=source_id;
      IF to_regclass('public.employee_identity_document_claims') IS NOT NULL THEN
        EXECUTE 'UPDATE public.employee_identity_document_claims SET employee_id=$1 WHERE employee_id=$2' USING retained_id,source_id;
      END IF;
      IF NOT source_row.is_deleted THEN UPDATE employees SET is_deleted=true,deleted_at=clock_timestamp(),version=version+1 WHERE id=source_id;END IF;
      IF NOT EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=source_id) THEN
        INSERT INTO employee_identity_aliases(alias_employee_id,canonical_employee_id,reason,evidence_reference)
        VALUES(source_id,retained_id,plan->>'reason',evidence);
      ELSIF NOT EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=source_id AND canonical_employee_id=retained_id) THEN
        RAISE EXCEPTION 'Source alias points to another retained person';
      END IF;
      PERFORM set_config('app.employee_merge_source',source_id::text,true);
      DELETE FROM employees WHERE id=source_id;
      IF retained_row.legacy_id IS NULL AND source_row.legacy_id IS NOT NULL AND COALESCE((plan->>'fill_missing_legacy')::boolean,false) THEN
        UPDATE employees SET legacy_id=source_row.legacy_id WHERE id=retained_id AND legacy_id IS NULL;
        legacy_filled:=true;canonical_changed:=true;
      END IF;
      IF patch<>'{}'::jsonb THEN
        IF EXISTS(SELECT 1 FROM jsonb_object_keys(patch) key WHERE key NOT IN('id_type','id_card_enc','id_card_hash','id_card_last4','id_card_check','birth_date_enc','birth_month_day','gender'))
           OR NOT COALESCE((plan->>'canonical_patch_reviewed')::boolean,false) THEN
          RAISE EXCEPTION 'Unreviewed retained master field override';
        END IF;
        IF patch?'id_card_enc' AND EXISTS(SELECT 1 FROM employee_sensitive WHERE employee_id=retained_id AND id_card_check='valid') THEN
          RAISE EXCEPTION 'A valid retained document cannot be silently overwritten';
        END IF;
        UPDATE employees SET id_type=COALESCE(patch->>'id_type',id_type),gender=COALESCE(patch->>'gender',gender),
          birth_month_day=COALESCE(patch->>'birth_month_day',birth_month_day) WHERE id=retained_id;
        INSERT INTO employee_sensitive(employee_id) VALUES(retained_id) ON CONFLICT(employee_id) DO NOTHING;
        UPDATE employee_sensitive SET id_card_enc=COALESCE(patch->>'id_card_enc',id_card_enc),id_card_hash=COALESCE(patch->>'id_card_hash',id_card_hash),
          id_card_last4=COALESCE(patch->>'id_card_last4',id_card_last4),id_card_check=COALESCE(patch->>'id_card_check',id_card_check),
          birth_date_enc=COALESCE(patch->>'birth_date_enc',birth_date_enc) WHERE employee_id=retained_id;
        canonical_changed:=true;
      END IF;
      IF canonical_changed THEN UPDATE employees SET version=version+1 WHERE id=retained_id;END IF;
      INSERT INTO employee_identity_merges(source_employee_id,canonical_employee_id,source_code,source_legacy_id,merged_by,evidence_reference,evidence_sha256,
        preservation_reference,preservation_sha256,reference_manifest,payload_sha256)
      VALUES(source_id,retained_id,source_row.code,source_row.legacy_id,operator_name,evidence,plan->>'evidence_sha256',plan->>'preservation_reference',plan->>'preservation_sha256',
        jsonb_build_object('education',education_map,'stock_workers',worker_map,'legacy_projections',legacy_map,'retired_users',user_map,'legacy_filled',legacy_filled,'canonical_changed',canonical_changed),cipher_sha);
      IF source_row.legacy_id IS NOT NULL THEN
        INSERT INTO employee_legacy_identity_aliases(namespace_key,legacy_id,canonical_employee_id,source_employee_id,evidence_reference)
        VALUES('B_WORKER',source_row.legacy_id,retained_id,source_id,evidence);
      END IF;
      FOR claim IN SELECT value FROM jsonb_array_elements(COALESCE(plan->'claims','[]'::jsonb)) LOOP
        INSERT INTO employee_identity_historical_claims(source_employee_id,canonical_employee_id,claim_kind,claim_hash,ownership_verified,normalization_version,evidence_reference)
        VALUES(source_id,retained_id,claim->>'kind',claim->>'hash',COALESCE((claim->>'ownership_verified')::boolean,false),1,evidence);
      END LOOP;
      FOR source_user IN SELECT value FROM jsonb_array_elements(user_map) LOOP
        INSERT INTO employee_identity_user_tombstones(source_user_id,source_employee_id,canonical_employee_id,retained_user_id,evidence_reference)
        VALUES((source_user.value->>'source_user_id')::uuid,source_id,retained_id,(source_user.value->>'retained_user_id')::uuid,evidence);
      END LOOP;
      UPDATE authorization_state SET epoch=epoch+1,updated_at=clock_timestamp() WHERE singleton_id=1;
      IF NOT fn_employee_merge_completed(source_id,retained_id,source_row.code)
         OR EXISTS(SELECT 1 FROM employee_sensitive WHERE employee_id=source_id)
         OR EXISTS(SELECT 1 FROM employee_education WHERE employee_id=source_id)
         OR EXISTS(SELECT 1 FROM users WHERE employee_id=source_id)
         OR EXISTS(SELECT 1 FROM stock_documents WHERE worker_id=source_id) THEN
        RAISE EXCEPTION 'Physical merge reference completion failed';
      END IF;
      IF canonical_accounts_before IS DISTINCT FROM (SELECT encode(public.digest(COALESCE(jsonb_agg(to_jsonb(u) ORDER BY id),'[]'::jsonb)::text,'sha256'),'hex') FROM users u WHERE employee_id=retained_id) THEN
        RAISE EXCEPTION 'Retained account identity, credentials or lifecycle changed';
      END IF;
      IF EXISTS(SELECT 1 FROM employees e WHERE e.id=retained_id AND (
        e.status IS DISTINCT FROM retained_row.status OR e.department_id IS DISTINCT FROM retained_row.department_id
        OR e.code IS DISTINCT FROM retained_row.code OR e.is_deleted IS DISTINCT FROM retained_row.is_deleted)) THEN
        RAISE EXCEPTION 'Retained employment status, department or code changed';
      END IF;
      IF plan?'expected_epoch_delta' AND (SELECT epoch-old_epoch FROM authorization_state WHERE singleton_id=1)<>(plan->>'expected_epoch_delta')::bigint THEN
        RAISE EXCEPTION 'Reviewed authorization epoch delta differs';
      END IF;
      RETURN jsonb_build_object('status','MERGED','source_employee_id',source_id,'canonical_employee_id',retained_id,'source_code',source_row.code,
        'source_removed',true,'education_mapping',education_map,'stock_worker_rows',worker_count,'retired_user_count',jsonb_array_length(user_map),
        'legacy_projection_rows',jsonb_array_length(legacy_map),'legacy_filled',legacy_filled,'canonical_changed',canonical_changed,
        'non_person_business_fields','verified_equal','retained_accounts','unchanged',
        'authorization_epoch_delta',(SELECT epoch-old_epoch FROM authorization_state WHERE singleton_id=1));
    END $body$
  $definition$;

  PERFORM public.fn_audit_track_table('employee_identity_merges','FULL','authorization',false);
  PERFORM public.fn_audit_track_table('employee_identity_merge_payloads','NONE','system',true);
  PERFORM public.fn_audit_track_table('employee_legacy_identity_aliases','FULL','authorization',false);
  PERFORM public.fn_audit_track_table('employee_identity_historical_claims','NONE','system',true);
  PERFORM public.fn_audit_track_table('employee_identity_user_tombstones','FULL','authorization',false);
  PERFORM public.fn_audit_track_table('employee_identity_legacy_roles','NONE','system',true);
  PERFORM public.fn_audit_track_table('employee_identity_review_certificates','FULL','authorization',true);
  PERFORM public.fn_audit_track_table('employee_identity_merge_installation','NONE','system',true);
  DECLARE evidence_table text;
  BEGIN
    FOREACH evidence_table IN ARRAY ARRAY['employee_identity_merges','employee_identity_merge_payloads','employee_legacy_identity_aliases','employee_identity_historical_claims','employee_identity_user_tombstones','employee_identity_legacy_roles','employee_identity_review_certificates','employee_identity_merge_installation'] LOOP
      EXECUTE format('CREATE TRIGGER trg_employee_merge_immutable BEFORE UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.fn_employee_merge_evidence_immutable()',evidence_table);
      EXECUTE format('CREATE TRIGGER trg_employee_merge_no_truncate BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION public.fn_employee_merge_evidence_immutable()',evidence_table);
      EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_employee_merge_immutable',evidence_table);
      EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_employee_merge_no_truncate',evidence_table);
      EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC',evidence_table);
      IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN EXECUTE format('REVOKE ALL ON TABLE public.%I FROM uten',evidence_table);END IF;
    END LOOP;
  END;
  EXECUTE $definition$
    CREATE FUNCTION public.fn_employee_merge_catalog_sha() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
      SELECT encode(public.digest(jsonb_build_object(
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
      )::text,'sha256'),'hex')
    $body$
  $definition$;
  FOR own_function IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND (p.proname LIKE 'fn_employee_merge_%' OR p.proname IN('fn_merge_employee_identity','fn_employee_identity_from_legacy_worker'))
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC',own_function.signature);
    IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN EXECUTE format('REVOKE ALL ON FUNCTION %s FROM uten',own_function.signature);END IF;
  END LOOP;
  IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN
    GRANT SELECT ON public.employee_identity_merges,public.employee_identity_historical_claims,public.employee_legacy_identity_aliases TO uten;
    GRANT EXECUTE ON FUNCTION public.fn_employee_merge_completed(uuid,uuid,text),public.fn_employee_identity_from_legacy_worker(integer),public.fn_employee_merge_retained_user(uuid),
      public.fn_employee_merge_database_identity() TO uten;
    GRANT EXECUTE ON FUNCTION public.fn_employee_merge_source_fingerprint(uuid) TO uten;
    GRANT EXECUTE ON FUNCTION public.fn_employee_merge_identifier_reviewed(uuid,text,text,uuid) TO uten;
  END IF;
  INSERT INTO public.employee_identity_merge_installation(version,payload_sha256,catalog_sha256)
  VALUES('v1',expected_sha,public.fn_employee_merge_catalog_sha());
END $employee_identity_merge_install$;
