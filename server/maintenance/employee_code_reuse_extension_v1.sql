-- Explicit V948-compatible maintenance extension. No startup hook or Flyway
-- history change. The future V965 migration ships these exact installer bytes.
DO $employee_code_reuse_install$
DECLARE
    payload text := $employee_code_reuse_payload$
CREATE TABLE public.employee_code_reuse_installation (
    singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
    payload_sha256 text NOT NULL CHECK(payload_sha256~'^[0-9a-f]{64}$'),
    catalog_sha256 text NOT NULL CHECK(catalog_sha256~'^[0-9a-f]{64}$'),
    installed_by text NOT NULL DEFAULT current_user,
    installed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE public.employee_code_reuse_releases (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_employee_id uuid NOT NULL UNIQUE REFERENCES public.employee_identity_merges(source_employee_id) ON DELETE RESTRICT,
    canonical_employee_id uuid NOT NULL,
    source_code_snapshot text NOT NULL,
    normalized_code text NOT NULL CHECK(normalized_code=upper(btrim(source_code_snapshot))
        AND normalized_code~'^UT[0-9]{4}$' AND normalized_code<>'UT0000'),
    dataset_id uuid NOT NULL,
    released_by text NOT NULL DEFAULT current_user,
    released_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX employee_code_reuse_releases_code ON public.employee_code_reuse_releases(normalized_code,released_at,id);
CREATE TABLE public.employee_code_reuse_claims (
    release_id uuid PRIMARY KEY REFERENCES public.employee_code_reuse_releases(id) ON DELETE RESTRICT,
    new_employee_id uuid NOT NULL UNIQUE,
    normalized_code text NOT NULL,
    dataset_id uuid NOT NULL,
    transaction_id bigint NOT NULL DEFAULT txid_current(),
    actor_id uuid NOT NULL DEFAULT NULLIF(current_setting('app.actor_id',true),'')::uuid,
    claimed_by text NOT NULL DEFAULT session_user,
    claimed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX employee_code_reuse_claims_code ON public.employee_code_reuse_claims(normalized_code,new_employee_id);
REVOKE ALL ON TABLE public.employee_code_reuse_installation,public.employee_code_reuse_releases,public.employee_code_reuse_claims FROM PUBLIC;

CREATE FUNCTION public.fn_employee_code_reuse_evidence_immutable() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $body$
BEGIN RAISE EXCEPTION 'Employee code release and claim evidence is append-only' USING ERRCODE='55000'; END;
$body$;
CREATE TRIGGER trg_employee_code_installation_immutable BEFORE UPDATE OR DELETE ON public.employee_code_reuse_installation
FOR EACH ROW EXECUTE FUNCTION public.fn_employee_code_reuse_evidence_immutable();
CREATE TRIGGER trg_employee_code_installation_no_truncate BEFORE TRUNCATE ON public.employee_code_reuse_installation
FOR EACH STATEMENT EXECUTE FUNCTION public.fn_employee_code_reuse_evidence_immutable();
CREATE TRIGGER trg_employee_code_release_immutable BEFORE UPDATE OR DELETE ON public.employee_code_reuse_releases
FOR EACH ROW EXECUTE FUNCTION public.fn_employee_code_reuse_evidence_immutable();
CREATE TRIGGER trg_employee_code_release_no_truncate BEFORE TRUNCATE ON public.employee_code_reuse_releases
FOR EACH STATEMENT EXECUTE FUNCTION public.fn_employee_code_reuse_evidence_immutable();
CREATE TRIGGER trg_employee_code_claim_immutable BEFORE UPDATE OR DELETE ON public.employee_code_reuse_claims
FOR EACH ROW EXECUTE FUNCTION public.fn_employee_code_reuse_evidence_immutable();
CREATE TRIGGER trg_employee_code_claim_no_truncate BEFORE TRUNCATE ON public.employee_code_reuse_claims
FOR EACH STATEMENT EXECUTE FUNCTION public.fn_employee_code_reuse_evidence_immutable();

CREATE FUNCTION public.fn_guard_employee_code_release_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
DECLARE realm uuid; global_count bigint; domain_count bigint;
BEGIN
    SELECT business_dataset_id INTO realm FROM public.authorization_state WHERE singleton_id=1;
    IF NEW.dataset_id IS DISTINCT FROM realm OR NEW.source_employee_id=NEW.canonical_employee_id
       OR public.fn_employee_merge_completed(NEW.source_employee_id,NEW.canonical_employee_id,NEW.source_code_snapshot) IS DISTINCT FROM true
       OR EXISTS(SELECT 1 FROM public.employees e WHERE upper(btrim(e.code))=NEW.normalized_code)
       OR NOT EXISTS(SELECT 1 FROM public.business_identifier_namespaces WHERE namespace_key='MASTER_EMPLOYEE'
            AND source_table='employees' AND identifier_column='code' AND fixed_prefix='UT') THEN
        RAISE EXCEPTION 'Only a completed employee merge may release its retired employee number' USING ERRCODE='23514';
    END IF;
    -- Existing allocation locks global identity before the per-domain identity.
    PERFORM 1 FROM public.business_identifier_reservations WHERE normalized_identifier=NEW.normalized_code FOR UPDATE;
    PERFORM 1 FROM public.master_code_reservations WHERE master_domain='EMPLOYEE' AND normalized_code=NEW.normalized_code FOR UPDATE;
    SELECT count(*) INTO global_count FROM public.business_identifier_reservation_members m
    WHERE m.normalized_identifier=NEW.normalized_code
      AND NOT (m.owner_domain='EMPLOYEE' AND m.source_table IN('employees','master_code_reservation_members')
          AND EXISTS(SELECT 1 FROM public.employee_code_reuse_releases retired
              WHERE retired.normalized_code=m.normalized_identifier AND retired.source_employee_id=m.entity_id
                AND retired.dataset_id=realm AND public.fn_employee_merge_completed(
                    retired.source_employee_id,retired.canonical_employee_id,retired.source_code_snapshot)));
    SELECT count(*) INTO domain_count FROM public.master_code_reservation_members m
    WHERE m.master_domain='EMPLOYEE' AND m.normalized_code=NEW.normalized_code
      AND NOT EXISTS(SELECT 1 FROM public.employee_code_reuse_releases retired
          WHERE retired.normalized_code=m.normalized_code AND retired.source_employee_id=m.entity_id
            AND retired.dataset_id=realm AND public.fn_employee_merge_completed(
                retired.source_employee_id,retired.canonical_employee_id,retired.source_code_snapshot));
    IF global_count<>1 OR domain_count<>1
       OR NOT EXISTS(SELECT 1 FROM public.business_identifier_reservation_members m
          WHERE m.normalized_identifier=NEW.normalized_code AND m.owner_domain='EMPLOYEE'
            AND m.source_table IN('employees','master_code_reservation_members') AND m.entity_id=NEW.source_employee_id)
       OR NOT EXISTS(SELECT 1 FROM public.master_code_reservation_members m
          WHERE m.master_domain='EMPLOYEE' AND m.normalized_code=NEW.normalized_code AND m.entity_id=NEW.source_employee_id)
       OR EXISTS(SELECT 1 FROM public.employee_code_reuse_releases prior
          WHERE prior.normalized_code=NEW.normalized_code AND NOT EXISTS(
              SELECT 1 FROM public.employee_code_reuse_claims claim WHERE claim.release_id=prior.id)) THEN
        RAISE EXCEPTION 'Employee code ownership is shared, incomplete or already released' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$body$;
CREATE TRIGGER trg_employee_code_release_insert BEFORE INSERT ON public.employee_code_reuse_releases
FOR EACH ROW EXECUTE FUNCTION public.fn_guard_employee_code_release_insert();

CREATE FUNCTION public.fn_release_merged_employee_code(p_source uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
DECLARE certificate record; existing public.employee_code_reuse_releases%ROWTYPE; realm uuid; released uuid;
BEGIN
    SELECT source_employee_id,canonical_employee_id,source_code INTO certificate
    FROM public.employee_identity_merges WHERE source_employee_id=p_source;
    IF NOT FOUND OR public.fn_employee_merge_completed(certificate.source_employee_id,
            certificate.canonical_employee_id,certificate.source_code) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'The employee merge certificate is absent or incomplete' USING ERRCODE='23514';
    END IF;
    -- AUTH/ADMIN and other internal labels are historical evidence, not ordinary UT numbers.
    IF upper(btrim(certificate.source_code))!~'^UT[0-9]{4}$' OR upper(btrim(certificate.source_code))='UT0000' THEN
        RETURN NULL;
    END IF;
    -- Serialize same-code registrations, including retries, before inspecting the pool.
    PERFORM 1 FROM public.business_identifier_reservations WHERE normalized_identifier=upper(btrim(certificate.source_code)) FOR UPDATE;
    SELECT business_dataset_id INTO realm FROM public.authorization_state WHERE singleton_id=1;
    SELECT * INTO existing FROM public.employee_code_reuse_releases WHERE source_employee_id=p_source;
    IF FOUND THEN
        IF existing.canonical_employee_id<>certificate.canonical_employee_id
           OR existing.source_code_snapshot<>certificate.source_code OR existing.dataset_id IS DISTINCT FROM realm THEN
            RAISE EXCEPTION 'Employee release evidence differs from the merge certificate' USING ERRCODE='23514';
        END IF;
        RETURN existing.id;
    END IF;
    INSERT INTO public.employee_code_reuse_releases(source_employee_id,canonical_employee_id,source_code_snapshot,normalized_code,dataset_id)
    VALUES(p_source,certificate.canonical_employee_id,certificate.source_code,upper(btrim(certificate.source_code)),realm)
    RETURNING id INTO released;
    RETURN released;
END;
$body$;
REVOKE ALL ON FUNCTION public.fn_release_merged_employee_code(uuid) FROM PUBLIC;

CREATE FUNCTION public.fn_employee_code_reuse_actor() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    SELECT u.id FROM public.users u JOIN public.employees e ON e.id=u.employee_id
    WHERE u.id=NULLIF(current_setting('app.actor_id',true),'')::uuid AND NOT u.is_deleted
      AND u.status='active' AND NOT u.must_change_password AND (u.locked_until IS NULL OR u.locked_until<=now())
      AND NOT e.is_deleted AND e.status IN('active','probation','onLeave')
$body$;
REVOKE ALL ON FUNCTION public.fn_employee_code_reuse_actor() FROM PUBLIC;

CREATE FUNCTION public.fn_guard_employee_code_claim_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
DECLARE released public.employee_code_reuse_releases%ROWTYPE; realm uuid;
BEGIN
    SELECT * INTO released FROM public.employee_code_reuse_releases WHERE id=NEW.release_id FOR UPDATE;
    SELECT business_dataset_id INTO realm FROM public.authorization_state WHERE singleton_id=1;
    IF released.id IS NULL OR public.fn_employee_code_reuse_actor() IS NULL
       OR NEW.actor_id IS DISTINCT FROM public.fn_employee_code_reuse_actor()
       OR NEW.transaction_id<>txid_current() OR NEW.dataset_id IS DISTINCT FROM realm
       OR NEW.dataset_id IS DISTINCT FROM released.dataset_id OR NEW.normalized_code<>released.normalized_code
       OR NEW.new_employee_id IN(released.source_employee_id,released.canonical_employee_id)
       OR EXISTS(SELECT 1 FROM public.employees WHERE id=NEW.new_employee_id)
       OR EXISTS(SELECT 1 FROM public.employee_identity_merges WHERE source_employee_id=NEW.new_employee_id)
       OR EXISTS(SELECT 1 FROM public.master_code_reservation_members WHERE master_domain='EMPLOYEE' AND entity_id=NEW.new_employee_id)
       OR EXISTS(SELECT 1 FROM public.business_identifier_reservation_members WHERE owner_domain='EMPLOYEE' AND entity_id=NEW.new_employee_id)
       OR EXISTS(SELECT 1 FROM public.employees WHERE upper(btrim(code))=released.normalized_code)
       OR public.fn_employee_merge_completed(released.source_employee_id,released.canonical_employee_id,released.source_code_snapshot) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'A released employee number must be claimed by a new employee UUID in its creation transaction' USING ERRCODE='23514';
    END IF;
    PERFORM 1 FROM public.business_identifier_reservations WHERE normalized_identifier=released.normalized_code FOR UPDATE;
    PERFORM 1 FROM public.master_code_reservations WHERE master_domain='EMPLOYEE' AND normalized_code=released.normalized_code FOR UPDATE;
    IF EXISTS(SELECT 1 FROM public.business_identifier_reservation_members m
        WHERE m.normalized_identifier=released.normalized_code AND NOT (
            m.owner_domain='EMPLOYEE' AND m.source_table IN('employees','master_code_reservation_members')
            AND EXISTS(SELECT 1 FROM public.employee_code_reuse_releases retired
                WHERE retired.normalized_code=m.normalized_identifier AND retired.source_employee_id=m.entity_id
                  AND retired.dataset_id=realm AND public.fn_employee_merge_completed(
                      retired.source_employee_id,retired.canonical_employee_id,retired.source_code_snapshot))))
       OR EXISTS(SELECT 1 FROM public.master_code_reservation_members m
        WHERE m.master_domain='EMPLOYEE' AND m.normalized_code=released.normalized_code
          AND NOT EXISTS(SELECT 1 FROM public.employee_code_reuse_releases retired
            WHERE retired.normalized_code=m.normalized_code AND retired.source_employee_id=m.entity_id
              AND retired.dataset_id=realm AND public.fn_employee_merge_completed(
                  retired.source_employee_id,retired.canonical_employee_id,retired.source_code_snapshot))) THEN
        RAISE EXCEPTION 'A released employee number acquired another historical owner' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$body$;
CREATE TRIGGER trg_employee_code_claim_insert BEFORE INSERT ON public.employee_code_reuse_claims
FOR EACH ROW EXECUTE FUNCTION public.fn_guard_employee_code_claim_insert();

CREATE FUNCTION public.fn_claim_next_released_employee_code(p_new_employee uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
DECLARE released public.employee_code_reuse_releases%ROWTYPE; existing public.employee_code_reuse_claims%ROWTYPE; realm uuid;
BEGIN
    IF public.fn_employee_code_reuse_actor() IS NULL THEN
        RAISE EXCEPTION 'Employee code allocation requires an active current employee actor' USING ERRCODE='23514';
    END IF;
    IF p_new_employee IS NULL OR EXISTS(SELECT 1 FROM public.employees WHERE id=p_new_employee)
       OR EXISTS(SELECT 1 FROM public.employee_identity_merges WHERE source_employee_id=p_new_employee) THEN
        RAISE EXCEPTION 'Employee number allocation requires a new UUID' USING ERRCODE='23514';
    END IF;
    SELECT * INTO existing FROM public.employee_code_reuse_claims WHERE new_employee_id=p_new_employee;
    IF FOUND THEN
        IF existing.transaction_id<>txid_current() THEN RAISE EXCEPTION 'Employee number claim belongs to a different transaction' USING ERRCODE='23514'; END IF;
        RETURN existing.normalized_code;
    END IF;
    IF EXISTS(SELECT 1 FROM public.master_code_reservation_members WHERE master_domain='EMPLOYEE' AND entity_id=p_new_employee)
       OR EXISTS(SELECT 1 FROM public.business_identifier_reservation_members WHERE owner_domain='EMPLOYEE' AND entity_id=p_new_employee) THEN
        RAISE EXCEPTION 'A historical employee UUID cannot become a new employee allocation' USING ERRCODE='23514';
    END IF;
    SELECT business_dataset_id INTO realm FROM public.authorization_state WHERE singleton_id=1;
    SELECT r.* INTO released FROM public.employee_code_reuse_releases r
    WHERE r.dataset_id=realm AND NOT EXISTS(SELECT 1 FROM public.employee_code_reuse_claims c WHERE c.release_id=r.id)
      AND public.fn_employee_merge_completed(r.source_employee_id,r.canonical_employee_id,r.source_code_snapshot)
    ORDER BY r.normalized_code,r.released_at,r.id LIMIT 1 FOR UPDATE OF r SKIP LOCKED;
    IF NOT FOUND THEN RETURN NULL; END IF;
    INSERT INTO public.employee_code_reuse_claims(release_id,new_employee_id,normalized_code,dataset_id)
    VALUES(released.id,p_new_employee,released.normalized_code,realm);
    RETURN released.normalized_code;
END;
$body$;
REVOKE ALL ON FUNCTION public.fn_claim_next_released_employee_code(uuid) FROM PUBLIC;

CREATE FUNCTION public.fn_employee_code_requires_identity_mapping(p_code text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    SELECT EXISTS(SELECT 1 FROM public.employee_code_reuse_releases WHERE normalized_code=upper(btrim(p_code)))
        OR EXISTS(SELECT 1 FROM public.employee_identity_merges WHERE upper(btrim(source_code))=upper(btrim(p_code)))
$body$;
REVOKE ALL ON FUNCTION public.fn_employee_code_requires_identity_mapping(text) FROM PUBLIC;

-- This boolean is used by both existing claim oracles. Only an employee INSERT
-- in the claimant's transaction may disregard the retired EMPLOYEE members.
CREATE FUNCTION public.fn_employee_code_reuse_claim_authorizes(p_code text,p_new uuid,p_old uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
    SELECT EXISTS(SELECT 1 FROM public.employee_code_reuse_claims claim
        JOIN public.employee_code_reuse_releases selected ON selected.id=claim.release_id
        JOIN public.employee_code_reuse_releases retired ON retired.normalized_code=claim.normalized_code
        JOIN public.authorization_state realm ON realm.singleton_id=1
        WHERE claim.transaction_id=txid_current() AND claim.new_employee_id=p_new
          AND claim.normalized_code=upper(btrim(p_code)) AND retired.source_employee_id=p_old
          AND claim.dataset_id=realm.business_dataset_id AND retired.dataset_id=realm.business_dataset_id
          AND NOT EXISTS(SELECT 1 FROM public.employees WHERE id=p_new)
          AND public.fn_employee_merge_completed(selected.source_employee_id,selected.canonical_employee_id,selected.source_code_snapshot)
          AND public.fn_employee_merge_completed(retired.source_employee_id,retired.canonical_employee_id,retired.source_code_snapshot))
$body$;
REVOKE ALL ON FUNCTION public.fn_employee_code_reuse_claim_authorizes(text,uuid,uuid) FROM PUBLIC;

CREATE FUNCTION public.fn_finish_employee_code_reuse_claim() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
BEGIN
    IF NEW.transaction_id<>txid_current() OR public.fn_employee_code_reuse_actor() IS NULL
       OR NEW.actor_id IS DISTINCT FROM public.fn_employee_code_reuse_actor()
       OR NOT EXISTS(SELECT 1 FROM public.employees WHERE id=NEW.new_employee_id AND NOT is_deleted AND upper(btrim(code))=NEW.normalized_code)
       OR NOT EXISTS(SELECT 1 FROM public.master_code_reservation_members WHERE master_domain='EMPLOYEE'
            AND normalized_code=NEW.normalized_code AND entity_id=NEW.new_employee_id)
       OR NOT EXISTS(SELECT 1 FROM public.business_identifier_reservation_members WHERE owner_domain='EMPLOYEE'
            AND source_table='employees' AND normalized_identifier=NEW.normalized_code AND entity_id=NEW.new_employee_id) THEN
        RAISE EXCEPTION 'Employee code claim did not complete its new employee and both reservation memberships' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$body$;
CREATE CONSTRAINT TRIGGER trg_finish_employee_code_reuse_claim AFTER INSERT ON public.employee_code_reuse_claims
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.fn_finish_employee_code_reuse_claim();

CREATE FUNCTION public.fn_guard_employee_code_reuse_legacy_import() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $body$
DECLARE new_code text; old_code text;
BEGIN
    IF lower(COALESCE(current_setting('app.business_identifier_legacy_import',true),'off')) IN('on','true','1')
       OR COALESCE(current_setting('uten.legacy_reference_import',true),'')<>'' THEN
        IF TG_TABLE_NAME='employees' THEN
            new_code:=NEW.code;
            IF TG_OP='UPDATE' THEN old_code:=OLD.code; END IF;
        ELSIF TG_TABLE_NAME='employee_sensitive' THEN
            SELECT code INTO new_code FROM public.employees WHERE id=NEW.employee_id;
            IF TG_OP='UPDATE' THEN SELECT code INTO old_code FROM public.employees WHERE id=OLD.employee_id; END IF;
        ELSE
            RAISE EXCEPTION 'Unsupported employee code import guard relation' USING ERRCODE='23514';
        END IF;
        IF EXISTS(SELECT 1 FROM public.employee_code_reuse_releases released
            WHERE released.normalized_code=upper(btrim(new_code)) OR released.normalized_code=upper(btrim(old_code))) THEN
            RAISE EXCEPTION 'A released employee number cannot identify a person in a legacy code-only import; verify the employee UUID and identity first'
                USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$body$;
CREATE TRIGGER trg_employee_code_reuse_legacy_import BEFORE INSERT OR UPDATE ON public.employees
FOR EACH ROW EXECUTE FUNCTION public.fn_guard_employee_code_reuse_legacy_import();
ALTER TABLE public.employees ENABLE ALWAYS TRIGGER trg_employee_code_reuse_legacy_import;
CREATE TRIGGER trg_employee_code_reuse_legacy_sensitive_import BEFORE INSERT OR UPDATE ON public.employee_sensitive
FOR EACH ROW EXECUTE FUNCTION public.fn_guard_employee_code_reuse_legacy_import();
ALTER TABLE public.employee_sensitive ENABLE ALWAYS TRIGGER trg_employee_code_reuse_legacy_sensitive_import;

DO $claims$
DECLARE definition text; anchor text;
BEGIN
    definition:=pg_get_functiondef('public.fn_reserve_master_code()'::regprocedure);
    anchor:='WHERE member.master_domain = v_domain';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>4 THEN
        RAISE EXCEPTION 'Employee code extension refuses an unknown master claim oracle';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E'\n AND NOT (v_domain=''EMPLOYEE'' AND TG_TABLE_NAME=''employees'' AND public.fn_employee_code_reuse_claim_authorizes(v_normalized_code,v_entity_id,member.entity_id))');
    definition:=pg_get_functiondef('public.fn_claim_global_business_identifier(text,text,uuid,text,text,text,boolean,boolean)'::regprocedure);
    anchor:='WHERE member.normalized_identifier = normalized_value';
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>4 THEN
        RAISE EXCEPTION 'Employee code extension refuses an unknown global claim oracle';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E'\n AND NOT (p_owner_domain=''EMPLOYEE'' AND p_source_table=''employees'' AND member.owner_domain=''EMPLOYEE'' AND member.source_table IN(''employees'',''master_code_reservation_members'') AND public.fn_employee_code_reuse_claim_authorizes(normalized_value,p_entity_id,member.entity_id))');
END;
$claims$;

DO $permissions$
DECLARE rel text; trigger_row record;
BEGIN
    FOREACH rel IN ARRAY ARRAY['employee_code_reuse_installation','employee_code_reuse_releases','employee_code_reuse_claims'] LOOP
        FOR trigger_row IN SELECT tgname FROM pg_trigger WHERE tgrelid=('public.'||rel)::regclass AND NOT tgisinternal LOOP
            EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I',rel,trigger_row.tgname);
        END LOOP;
    END LOOP;
    IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN
        REVOKE ALL ON public.employee_code_reuse_installation,public.employee_code_reuse_releases,public.employee_code_reuse_claims FROM uten;
        -- A site's migrator default privileges may grant runtime EXECUTE even
        -- after PUBLIC is revoked. Release and private helpers remain owner-only.
        REVOKE ALL ON FUNCTION public.fn_employee_code_reuse_evidence_immutable(),public.fn_guard_employee_code_release_insert(),
            public.fn_release_merged_employee_code(uuid),public.fn_employee_code_reuse_actor(),public.fn_guard_employee_code_claim_insert(),
            public.fn_claim_next_released_employee_code(uuid),public.fn_employee_code_requires_identity_mapping(text),
            public.fn_employee_code_reuse_claim_authorizes(text,uuid,uuid),public.fn_finish_employee_code_reuse_claim(),
            public.fn_guard_employee_code_reuse_legacy_import() FROM uten;
        GRANT EXECUTE ON FUNCTION public.fn_claim_next_released_employee_code(uuid),public.fn_employee_code_reuse_claim_authorizes(text,uuid,uuid),
            public.fn_employee_code_requires_identity_mapping(text) TO uten;
    END IF;
END;
$permissions$;
SELECT public.fn_audit_track_table('employee_code_reuse_releases','FULL','authorization',false);
SELECT public.fn_audit_track_table('employee_code_reuse_claims','FULL','data_change',false);
COMMENT ON TABLE public.employee_code_reuse_releases IS 'Retired employee number evidence after an approved physical identity merge; original reservation history is preserved';
COMMENT ON TABLE public.employee_code_reuse_claims IS 'Append-only new-UUID employee allocations; never redirects historical UUIDs, credentials, names or code snapshots to a later person';
$employee_code_reuse_payload$;
    expected_sha text;
    installed boolean;
    actual_catalog text;
    recorded record;
    original_search_path text := current_setting('search_path');
BEGIN
    PERFORM set_config('search_path','pg_catalog,public,pg_temp',true);
    IF to_regclass('public.employee_identity_merges') IS NULL
       OR to_regprocedure('public.fn_employee_merge_completed(uuid,uuid,text)') IS NULL THEN
        RAISE EXCEPTION 'Install the reviewed employee merge certificate extension first';
    END IF;
    expected_sha:=encode(public.digest(convert_to(payload,'UTF8'),'sha256'),'hex');
    installed:=to_regclass('public.employee_code_reuse_installation') IS NOT NULL;
    IF NOT installed THEN
        IF to_regclass('public.employee_code_reuse_releases') IS NOT NULL
           OR to_regclass('public.employee_code_reuse_claims') IS NOT NULL
           OR to_regprocedure('public.fn_claim_next_released_employee_code(uuid)') IS NOT NULL
           OR position('fn_employee_code_reuse_claim_authorizes' IN pg_get_functiondef('public.fn_reserve_master_code()'::regprocedure))>0 THEN
            RAISE EXCEPTION 'Employee code reuse extension is partially installed; refusing to replace evidence or guards';
        END IF;
        EXECUTE payload;
    END IF;
    -- Recompute from the real catalog, not an installed helper which could be
    -- changed to report its own stale fingerprint. Future adoption performs no DDL.
    SELECT encode(public.digest(convert_to(jsonb_build_object(
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
    )::text,'UTF8'),'sha256'),'hex') INTO actual_catalog;
    IF installed THEN
        SELECT * INTO recorded FROM public.employee_code_reuse_installation WHERE singleton;
        IF NOT FOUND OR recorded.payload_sha256<>expected_sha OR recorded.catalog_sha256<>actual_catalog THEN
            RAISE EXCEPTION 'Installed employee code reuse payload or catalog differs; explicit review is required';
        END IF;
    ELSE
        INSERT INTO public.employee_code_reuse_installation(payload_sha256,catalog_sha256) VALUES(expected_sha,actual_catalog);
    END IF;
    PERFORM set_config('search_path',original_search_path,true);
END;
$employee_code_reuse_install$;
