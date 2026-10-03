-- V782 assembly fragment. Only explicit test reset consumes this separate queue.
-- Completion facts trust the authenticated application process. SQL does not own or verify its HMAC key.
CREATE TABLE public.business_test_object_cleanup_intents (
    id uuid PRIMARY KEY,
    purpose text NOT NULL CHECK(purpose='CLEAR_TEST_BUSINESS_WITH_HISTORY'),
    attempt_id uuid NOT NULL, generation bigint NOT NULL CHECK(generation>=0),
    actor_id uuid NOT NULL, actor_account text NOT NULL, database_name text NOT NULL,
    source_type text NOT NULL, source_id text NOT NULL, source_fingerprint text NOT NULL CHECK(source_fingerprint ~ '^[0-9a-f]{64}$'),
    object_location text NOT NULL CHECK(object_location IN('STAGING','FINAL')),
    storage_provider text NOT NULL CHECK(storage_provider IN('internal','local')),
    storage_key text NOT NULL CHECK(storage_key ~ '^[A-Za-z0-9._-]+$'), storage_version text,
    object_exists boolean NOT NULL, size_bytes bigint NOT NULL CHECK(size_bytes>=0),
    sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
    signature text NOT NULL CHECK(signature ~ '^[0-9a-f]{64}$'),
    authorized_until timestamptz NOT NULL,
    status text NOT NULL DEFAULT 'PENDING' CHECK(status IN('PENDING','PROCESSING','FAILED','SUCCEEDED')),
    claim_number bigint NOT NULL DEFAULT 0 CHECK(claim_number>=0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(), available_at timestamptz NOT NULL DEFAULT clock_timestamp(), locked_at timestamptz,
    completed_at timestamptz, last_error text,
    CHECK(status<>'SUCCEEDED' OR completed_at IS NOT NULL),
    CHECK(storage_provider<>'internal' OR NOT object_exists OR NULLIF(btrim(storage_version),'') IS NOT NULL)
);
CREATE INDEX idx_business_test_object_intents_pending ON public.business_test_object_cleanup_intents(attempt_id,generation,created_at,id)
WHERE status IN('PENDING','FAILED','PROCESSING');
CREATE INDEX idx_business_test_object_intents_proof ON public.business_test_object_cleanup_intents(generation,source_type,source_id,source_fingerprint)
WHERE status='SUCCEEDED' AND completed_at IS NOT NULL;
COMMENT ON TABLE public.business_test_object_cleanup_intents IS
'Explicit, signed test-only exact-object intents. Ordinary expiry/deletion workers never consume these. Proofs are scoped to dataset generation; no file contents or encryption keys.';

-- Metadata only: no original bytea or complete candidate payload ever leaves these queries.
CREATE VIEW public.v_business_test_object_sources AS
WITH source AS (
    SELECT 'ATTACHMENT'::text source_type,a.id::text source_id,a.owner_type::text owner_type,a.owner_id,
        a.original_name::text file_name,a.lifecycle_state::text source_state,'FINAL'::text object_location,
        a.storage_provider::text storage_provider,a.storage_key::text storage_key,a.storage_version::text storage_version,
        a.size_bytes size_bytes,a.sha256::text sha256,NULL::timestamptz wait_until,
        jsonb_build_array(a.id,a.owner_type,a.owner_id,a.storage_provider,a.storage_key,a.storage_version,a.size_bytes,a.sha256,a.lifecycle_state,extract(epoch FROM a.created_at),extract(epoch FROM a.updated_at)) identity
    FROM attachments a WHERE upper(btrim(a.owner_type)) NOT IN('GOODS','EMPLOYEE','EMPLOYEE_CONTRACT')
    UNION ALL
    SELECT 'UPLOAD_SESSION',s.id::text,s.owner_type::text,s.owner_id,s.original_name::text,s.status::text,location.kind,
        s.storage_provider::text,s.storage_key::text,CASE WHEN location.kind='STAGING' THEN s.staging_version ELSE s.final_version END::text,
        s.expected_size_bytes,s.sha256::text,s.expires_at,
        jsonb_build_array(s.id,s.owner_type,s.owner_id,s.storage_provider,s.storage_key,s.staging_version,s.final_version,s.expected_size_bytes,s.sha256,s.status,extract(epoch FROM s.expires_at),extract(epoch FROM s.created_at),extract(epoch FROM s.updated_at),location.kind)
    FROM attachment_upload_sessions s CROSS JOIN (VALUES('STAGING'::text),('FINAL'::text)) location(kind)
    WHERE upper(btrim(s.owner_type)) NOT IN('GOODS','EMPLOYEE','EMPLOYEE_CONTRACT')
    UNION ALL
    SELECT 'AI_INPUT_ORIGINAL',o.job_id::text,'AI_INPUT_ORIGINAL',NULL::uuid,o.original_name,o.lifecycle_state,'FINAL',
        o.storage_provider,o.storage_key,o.storage_version,o.storage_size,o.storage_sha256,NULL::timestamptz,
        jsonb_build_array(o.job_id,o.actor_user_id,o.availability,o.lifecycle_state,o.storage_provider,o.storage_key,o.storage_version,o.storage_size,o.storage_sha256,extract(epoch FROM o.captured_at),extract(epoch FROM o.created_at))
    FROM ai_input_originals o WHERE o.storage_key IS NOT NULL
    UNION ALL
    SELECT 'QUOTE_CANDIDATE',c.job_id::text,'QUOTE_CANDIDATE',NULL::uuid,c.source_name::text,'CANDIDATE','FINAL',
        c.storage_provider::text,c.storage_key::text,c.storage_version::text,c.storage_size,c.storage_sha256::text,NULL::timestamptz,
        jsonb_build_array(c.job_id,c.actor_user_id,c.storage_provider,c.storage_key,c.storage_version,c.storage_size,c.storage_sha256,extract(epoch FROM c.created_at))
    FROM sales_quote_template_candidates c WHERE c.storage_key IS NOT NULL
    UNION ALL
    SELECT 'QUOTE_CANDIDATE_HISTORY',h.id::text,'QUOTE_CANDIDATE',NULL::uuid,coalesce(h.payload->>'source_name','候选历史'), 'HISTORY','FINAL',
        h.storage_provider,h.storage_key,h.storage_version,
        CASE WHEN h.payload->>'storage_size' ~ '^[0-9]{1,18}$' THEN (h.payload->>'storage_size')::bigint END,
        h.payload->>'storage_sha256',NULL::timestamptz,
        jsonb_build_array(h.id,h.job_id,h.storage_provider,h.storage_key,h.storage_version,h.payload->>'storage_size',h.payload->>'storage_sha256',extract(epoch FROM h.recorded_at))
    FROM sales_quote_template_candidate_history h WHERE h.storage_key IS NOT NULL
    UNION ALL
    SELECT 'DELETE_OPERATION',o.id::text,coalesce(a.owner_type,s.owner_type,'UNKNOWN')::text,coalesce(a.owner_id,s.owner_id),
        coalesce(a.original_name,s.original_name,'文件删除任务')::text,o.status::text,
        CASE WHEN o.operation='DELETE_STAGING' THEN 'STAGING' ELSE 'FINAL' END,
        o.storage_provider::text,o.storage_key::text,o.storage_version::text,coalesce(a.size_bytes,s.expected_size_bytes),coalesce(a.sha256,s.sha256)::text,
        s.expires_at,jsonb_build_array(o.id,o.attachment_id,o.upload_session_id,o.operation,o.storage_provider,o.storage_key,o.storage_version,extract(epoch FROM o.created_at))
    FROM attachment_object_outbox o LEFT JOIN attachments a ON a.id=o.attachment_id
      LEFT JOIN attachment_upload_sessions s ON s.id=o.upload_session_id
    WHERE upper(btrim(coalesce(a.owner_type,s.owner_type,'UNKNOWN'))) NOT IN('GOODS','EMPLOYEE','EMPLOYEE_CONTRACT')
)
SELECT source_type,source_id,owner_type,owner_id,file_name,source_state,object_location,storage_provider,storage_key,storage_version,
    size_bytes,sha256,wait_until,encode(digest(identity::text,'sha256'),'hex') source_fingerprint FROM source;

CREATE FUNCTION public.fn_business_test_object_protected(p_provider text,p_location text,p_key text,p_version text)
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp AS $function$
    SELECT EXISTS(
      SELECT 1 FROM attachments a WHERE upper(btrim(a.owner_type)) IN('GOODS','EMPLOYEE','EMPLOYEE_CONTRACT')
        AND a.storage_key=p_key AND (a.storage_provider=p_provider OR a.storage_provider='legacy_unknown')
        AND (p_version IS NULL OR p_provider='local' OR a.storage_version IS NULL OR a.storage_version IS NOT DISTINCT FROM p_version)
      UNION ALL
      SELECT 1 FROM attachment_upload_sessions s WHERE upper(btrim(s.owner_type)) IN('GOODS','EMPLOYEE','EMPLOYEE_CONTRACT')
        AND s.storage_key=p_key AND (s.storage_provider=p_provider OR s.storage_provider='legacy_unknown')
      UNION ALL
      SELECT 1 FROM sales_quote_template_versions v WHERE p_location='FINAL' AND v.storage_provider=p_provider
        AND v.storage_key=p_key AND (p_version IS NULL OR p_provider='local' OR v.storage_version IS NOT DISTINCT FROM p_version)
      UNION ALL
      SELECT 1 FROM goods_cost_imports g WHERE p_location='FINAL' AND (g.storage_provider=p_provider OR g.storage_provider='legacy_unknown')
        AND g.storage_key=p_key AND (p_version IS NULL OR p_provider='local' OR g.storage_version IS NULL OR g.storage_version IS NOT DISTINCT FROM p_version)
    )
$function$;

CREATE FUNCTION public.fn_business_test_object_sources()
RETURNS SETOF public.v_business_test_object_sources
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp AS $function$
 SELECT s.* FROM public.v_business_test_object_sources s
 WHERE NOT public.fn_business_test_object_protected(s.storage_provider,s.object_location,s.storage_key,s.storage_version)
   AND NOT EXISTS(SELECT 1 FROM public.business_test_object_cleanup_intents ticket
       WHERE ticket.generation=(SELECT business_reset_generation FROM public.authorization_state WHERE singleton_id=1)
         AND ticket.source_type=s.source_type AND ticket.source_id=s.source_id AND ticket.object_location=s.object_location
         AND ticket.source_fingerprint=s.source_fingerprint AND ticket.status='SUCCEEDED' AND ticket.completed_at IS NOT NULL
         AND ticket.storage_provider=s.storage_provider AND ticket.storage_key=s.storage_key
         AND (s.storage_version IS NULL OR ticket.storage_version IS NOT DISTINCT FROM s.storage_version))
$function$;

CREATE FUNCTION public.fn_test_object_require_actor(p_actor uuid,p_attempt uuid,p_generation bigint) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp AS $function$
BEGIN
    PERFORM public.fn_require_runtime_maintenance(true);
    IF p_attempt IS NULL OR p_actor IS NULL
       OR p_actor::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',true),'')
       OR NOT EXISTS(SELECT 1 FROM public.users actor WHERE actor.id=p_actor AND actor.is_super_admin
           AND actor.status='active' AND NOT actor.is_deleted
           AND actor.login_account=current_setting('app.actor_account',true))
       OR p_generation IS DISTINCT FROM (SELECT business_reset_generation FROM public.authorization_state WHERE singleton_id=1) THEN
        RAISE EXCEPTION 'Test object cleanup actor, attempt or generation is no longer valid' USING ERRCODE='42501';
    END IF;
END $function$;

CREATE FUNCTION public.fn_test_object_lock_sources() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $function$
BEGIN
    PERFORM public.fn_require_runtime_maintenance(true);
    -- Explicit maintenance only. Serialize reference writers while one physical object is verified/deleted.
    LOCK TABLE public.attachments,public.attachment_upload_sessions,public.attachment_object_outbox,
      public.ai_input_originals,public.sales_quote_template_candidates,public.sales_quote_template_candidate_history,
      public.sales_quote_template_versions,public.goods_cost_imports IN SHARE ROW EXCLUSIVE MODE;
END $function$;

CREATE FUNCTION public.fn_test_object_prepare(p_id uuid,p_attempt uuid,p_generation bigint,p_actor uuid,p_account text,
 p_database text,p_type text,p_source text,p_fingerprint text,p_location text,p_provider text,p_key text,p_version text,
 p_exists boolean,p_size bigint,p_sha text,p_signature text,p_until timestamptz) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $function$
BEGIN
    PERFORM public.fn_test_object_require_actor(p_actor,p_attempt,p_generation);
    IF p_database IS DISTINCT FROM current_database() OR p_account IS DISTINCT FROM current_setting('app.actor_account',true)
       OR p_until<clock_timestamp() OR p_until>clock_timestamp()+interval '6 minutes'
       OR NOT EXISTS(SELECT 1 FROM public.fn_business_test_object_sources() s WHERE s.source_type=p_type
          AND s.source_id=p_source AND s.source_fingerprint=p_fingerprint AND s.object_location=p_location
          AND s.storage_provider=p_provider AND s.storage_key=p_key
          AND (s.storage_version IS NULL OR s.storage_version IS NOT DISTINCT FROM p_version)
          AND (s.wait_until IS NULL OR s.wait_until<=clock_timestamp())) THEN
        RAISE EXCEPTION 'Reviewed exact source changed or upload grant is still valid' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM public.business_test_object_cleanup_intents existing
        WHERE existing.attempt_id=p_attempt AND existing.actor_id=p_actor AND existing.generation=p_generation
          AND existing.source_type=p_type AND existing.source_id=p_source AND existing.source_fingerprint=p_fingerprint
          AND existing.object_location=p_location AND existing.status<>'SUCCEEDED'
          AND existing.authorized_until>=clock_timestamp()) THEN RETURN; END IF;
    INSERT INTO public.business_test_object_cleanup_intents(id,purpose,attempt_id,generation,actor_id,actor_account,database_name,
      source_type,source_id,source_fingerprint,object_location,storage_provider,storage_key,storage_version,
      object_exists,size_bytes,sha256,signature,authorized_until)
    VALUES(p_id,'CLEAR_TEST_BUSINESS_WITH_HISTORY',p_attempt,p_generation,p_actor,p_account,p_database,
      p_type,p_source,p_fingerprint,p_location,p_provider,p_key,p_version,p_exists,p_size,p_sha,p_signature,p_until);
END $function$;

CREATE FUNCTION public.fn_test_object_claim(p_attempt uuid,p_actor uuid,p_generation bigint)
RETURNS SETOF public.business_test_object_cleanup_intents
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $function$
DECLARE picked uuid;
BEGIN
    PERFORM public.fn_test_object_require_actor(p_actor,p_attempt,p_generation);
    SELECT id INTO picked FROM public.business_test_object_cleanup_intents
    WHERE attempt_id=p_attempt AND actor_id=p_actor AND generation=p_generation
      AND authorized_until>=clock_timestamp()
      AND ((status IN('PENDING','FAILED') AND available_at<=clock_timestamp()) OR (status='PROCESSING' AND locked_at<clock_timestamp()-interval '1 minute'))
    ORDER BY created_at,id FOR UPDATE SKIP LOCKED LIMIT 1;
    IF picked IS NULL THEN RETURN; END IF;
    RETURN QUERY UPDATE public.business_test_object_cleanup_intents SET status='PROCESSING',claim_number=claim_number+1,
      locked_at=clock_timestamp(),last_error=NULL WHERE id=picked RETURNING *;
END $function$;

CREATE FUNCTION public.fn_test_object_complete(p_id uuid,p_attempt uuid,p_actor uuid,p_generation bigint,p_claim bigint,
 p_signature text,p_success boolean,p_error text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $function$
DECLARE ticket public.business_test_object_cleanup_intents%ROWTYPE;
BEGIN
    PERFORM public.fn_test_object_require_actor(p_actor,p_attempt,p_generation);
    SELECT * INTO ticket FROM public.business_test_object_cleanup_intents WHERE id=p_id FOR UPDATE;
    IF ticket.id IS NULL OR ticket.attempt_id IS DISTINCT FROM p_attempt OR ticket.actor_id IS DISTINCT FROM p_actor OR ticket.generation IS DISTINCT FROM p_generation
       OR ticket.claim_number IS DISTINCT FROM p_claim OR ticket.status IS DISTINCT FROM 'PROCESSING' OR ticket.signature IS DISTINCT FROM p_signature THEN RETURN false; END IF;
    IF p_success AND (ticket.authorized_until<clock_timestamp()
       OR public.fn_business_test_object_protected(ticket.storage_provider,ticket.object_location,ticket.storage_key,ticket.storage_version)
       OR NOT EXISTS(SELECT 1 FROM public.v_business_test_object_sources s WHERE s.source_type=ticket.source_type
          AND s.source_id=ticket.source_id AND s.object_location=ticket.object_location
          AND s.source_fingerprint=ticket.source_fingerprint)) THEN
        RAISE EXCEPTION 'Exact test-cleanup source is no longer current' USING ERRCODE='23514';
    END IF;
    UPDATE public.business_test_object_cleanup_intents SET status=CASE WHEN p_success THEN 'SUCCEEDED' ELSE 'FAILED' END,
      completed_at=CASE WHEN p_success THEN clock_timestamp() END,locked_at=NULL,available_at=clock_timestamp()+CASE WHEN p_success THEN interval '0 seconds' ELSE interval '2 seconds' END,last_error=left(p_error,200) WHERE id=p_id;
    RETURN true;
END $function$;

CREATE FUNCTION public.fn_test_object_intent_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp AS $function$
BEGIN
    IF TG_OP IN('DELETE','TRUNCATE') AND public.fn_business_test_reset_active() THEN
      IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NULL; END IF;
    END IF;
    IF current_user IS DISTINCT FROM pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid='public.fn_test_object_prepare(uuid,uuid,bigint,uuid,text,text,text,text,text,text,text,text,text,boolean,bigint,text,text,timestamp with time zone)'::regprocedure)) THEN
      RAISE EXCEPTION 'Test cleanup intents are writable only through fixed maintenance entries' USING ERRCODE='42501';
    END IF;
    IF TG_OP IN('DELETE','TRUNCATE') THEN RAISE EXCEPTION 'Test cleanup proof is immutable outside explicit reset' USING ERRCODE='55000'; END IF;
    IF TG_OP='UPDATE' AND (to_jsonb(NEW)-'status'-'claim_number'-'locked_at'-'completed_at'-'last_error'-'available_at')
       IS DISTINCT FROM (to_jsonb(OLD)-'status'-'claim_number'-'locked_at'-'completed_at'-'last_error'-'available_at') THEN
       RAISE EXCEPTION 'Signed test-cleanup identity is immutable' USING ERRCODE='23514';
    END IF;
    IF TG_OP='UPDATE' AND OLD.status='SUCCEEDED' THEN RAISE EXCEPTION 'Completed exact test proof is immutable' USING ERRCODE='55000'; END IF;
    RETURN NEW;
END $function$;
CREATE TRIGGER trg_test_object_intent_guard BEFORE INSERT OR UPDATE OR DELETE ON public.business_test_object_cleanup_intents
FOR EACH ROW EXECUTE FUNCTION public.fn_test_object_intent_guard();
CREATE TRIGGER trg_test_object_intent_no_truncate BEFORE TRUNCATE ON public.business_test_object_cleanup_intents
FOR EACH STATEMENT EXECUTE FUNCTION public.fn_test_object_intent_guard();
ALTER TABLE public.business_test_object_cleanup_intents ENABLE ALWAYS TRIGGER trg_test_object_intent_guard;
ALTER TABLE public.business_test_object_cleanup_intents ENABLE ALWAYS TRIGGER trg_test_object_intent_no_truncate;

CREATE FUNCTION public.fn_assert_business_test_objects_cleared() RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp AS $function$
BEGIN
    IF NOT public.fn_business_test_reset_active() THEN RAISE EXCEPTION 'Explicit trusted test-reset context required' USING ERRCODE='42501'; END IF;
    PERFORM public.fn_test_object_lock_sources();
    IF EXISTS(SELECT 1 FROM public.fn_business_test_object_sources()) THEN
       RAISE EXCEPTION 'Test originals still lack exact physical completion proofs' USING ERRCODE='23514';
    END IF;
END $function$;

CREATE FUNCTION public.fn_clear_business_test_object_metadata() RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp AS $function$
BEGIN
    PERFORM public.fn_assert_business_test_objects_cleared();
    DELETE FROM public.attachment_reconciliation_findings finding
    WHERE NOT public.fn_business_test_object_protected(finding.storage_provider,finding.object_location,finding.storage_key,finding.storage_version)
      AND EXISTS(SELECT 1 FROM public.business_test_object_cleanup_intents proof
          WHERE proof.generation=(SELECT business_reset_generation FROM public.authorization_state WHERE singleton_id=1)
            AND proof.status='SUCCEEDED' AND proof.completed_at IS NOT NULL
            AND proof.storage_provider=finding.storage_provider AND proof.object_location=finding.object_location
            AND proof.storage_key=finding.storage_key AND proof.storage_version IS NOT DISTINCT FROM finding.storage_version
            AND EXISTS(SELECT 1 FROM public.v_business_test_object_sources source WHERE source.source_type=proof.source_type
                AND source.source_id=proof.source_id AND source.source_fingerprint=proof.source_fingerprint));
    DELETE FROM public.attachment_object_outbox operation WHERE EXISTS(
      SELECT 1 FROM public.v_business_test_object_sources s WHERE s.source_type='DELETE_OPERATION' AND s.source_id=operation.id::text);
    DELETE FROM public.attachment_upload_sessions WHERE upper(btrim(owner_type)) NOT IN('GOODS','EMPLOYEE','EMPLOYEE_CONTRACT');
    DELETE FROM public.attachments WHERE upper(btrim(owner_type)) NOT IN('GOODS','EMPLOYEE','EMPLOYEE_CONTRACT');
END $function$;

DO $privileges$
DECLARE signature text; owner_name text; reset_owner_name text;
BEGIN
    owner_name:=pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid='public.fn_test_object_prepare(uuid,uuid,bigint,uuid,text,text,text,text,text,text,text,text,text,boolean,bigint,text,text,timestamp with time zone)'::regprocedure));
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.fn_require_runtime_maintenance(boolean) TO %I',owner_name);
    reset_owner_name:=pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid='public.business_data_reset()'::regprocedure));
    -- V625 preserves an existing uten_owner entry while forward helpers may be owned by uten_migrator.
    -- Neither one-way membership nor superuser fixtures may hide that ABI boundary.
    EXECUTE format('GRANT SELECT,DELETE,TRUNCATE ON public.business_test_object_cleanup_intents TO %I',reset_owner_name);
    EXECUTE format('GRANT SELECT ON public.v_business_test_object_sources TO %I',reset_owner_name);
    REVOKE ALL ON public.business_test_object_cleanup_intents FROM PUBLIC;
    FOREACH signature IN ARRAY ARRAY[
      'public.fn_test_object_require_actor(uuid,uuid,bigint)','public.fn_test_object_lock_sources()',
      'public.fn_test_object_prepare(uuid,uuid,bigint,uuid,text,text,text,text,text,text,text,text,text,boolean,bigint,text,text,timestamp with time zone)',
      'public.fn_test_object_claim(uuid,uuid,bigint)',
      'public.fn_test_object_complete(uuid,uuid,uuid,bigint,bigint,text,boolean,text)',
      'public.fn_assert_business_test_objects_cleared()','public.fn_clear_business_test_object_metadata()'] LOOP
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC',signature);
      IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN EXECUTE format('REVOKE ALL ON FUNCTION %s FROM uten',signature); END IF;
    END LOOP;
    IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN
      REVOKE ALL ON public.business_test_object_cleanup_intents FROM uten;
      GRANT SELECT ON public.business_test_object_cleanup_intents TO uten;
      GRANT SELECT ON public.v_business_test_object_sources TO uten;
      GRANT EXECUTE ON FUNCTION public.fn_test_object_prepare(uuid,uuid,bigint,uuid,text,text,text,text,text,text,text,text,text,boolean,bigint,text,text,timestamp with time zone),
        public.fn_test_object_claim(uuid,uuid,bigint),public.fn_test_object_complete(uuid,uuid,uuid,bigint,bigint,text,boolean,text),
        public.fn_test_object_lock_sources() TO uten;
    END IF;
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.fn_assert_business_test_objects_cleared(),public.fn_clear_business_test_object_metadata(),public.fn_test_object_lock_sources(),public.fn_business_test_object_sources(),public.fn_business_test_object_protected(text,text,text,text) TO %I',reset_owner_name);
END $privileges$;
