-- Explicit maintenance for a proved duplicate consisting of TWO resigned,
-- account-free records. Requires existing V937/V947; never deploys migrations.
-- Loaded by prepare_employee_resigned_duplicate.py inside one RR transaction.
CREATE OR REPLACE FUNCTION pg_temp.employee_duplicate_preservation(
    members uuid[], duplicate_id uuid, original_audit_ids bigint[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE relation record; fingerprint text; predicate text; projection text; result jsonb:='{}'::jsonb;
BEGIN
    FOR relation IN
        SELECT c.relname,string_agg(CASE WHEN a.atttypid='uuid'::regtype
                  THEN format('t.%I=ANY($1)',a.attname)
                  ELSE format('t.%I=ANY($1::text[])',a.attname) END,' OR ' ORDER BY a.attnum) AS predicate
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
        WHERE n.nspname='public' AND c.relkind IN('r','p') AND NOT c.relispartition
          AND c.relname NOT IN('employee_identity_aliases','authorization_state')
          AND (a.atttypid='uuid'::regtype OR
              (a.atttypid IN('text'::regtype,'varchar'::regtype) AND a.attname IN('owner_id','target_id')))
        GROUP BY c.relname ORDER BY c.relname
    LOOP
        predicate:='('||relation.predicate||')';
        IF relation.relname IN('audit_log','audit_log_archive') THEN
            predicate:=predicate||' AND ($2 IS NULL OR t.id=ANY($2))';
        END IF;
        projection:=CASE WHEN relation.relname='employees' THEN
            'CASE WHEN t.id=$3 THEN to_jsonb(t)-ARRAY[''is_deleted'',''deleted_at'',''version'',''updated_at'',''updated_by'',''permission_delegation_generation''] ELSE to_jsonb(t) END'
            ELSE 'to_jsonb(t)' END;
        EXECUTE format('SELECT encode(public.digest(COALESCE(jsonb_agg(row_data ORDER BY row_data::text),''[]''::jsonb)::text,''sha256''),''hex'') FROM (SELECT %s AS row_data FROM public.%I t WHERE %s) scoped',
                       projection,relation.relname,predicate)
        INTO fingerprint USING members,original_audit_ids,duplicate_id;
        result:=result||jsonb_build_object(relation.relname,fingerprint);
    END LOOP;
    RETURN result;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.apply_verified_resigned_employee_duplicate(plan jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE canonical uuid; duplicate_id uuid; members uuid[]; identity jsonb;
        canonical_row employees%ROWTYPE; duplicate_row employees%ROWTYPE;
        evidence text; actor text; old_epoch bigint; old_generation bigint;
        before_facts jsonb; after_facts jsonb; old_audits bigint[];
        responsibility record; active_count bigint; changed integer; preservation_diagnostic jsonb;
BEGIN
    IF current_setting('transaction_isolation')<>'repeatable read'
       OR plan->>'protocol' IS DISTINCT FROM 'verified-employee-resigned-duplicate-v1'
       OR NOT COALESCE((plan#>>'{backup,verified}')::boolean,false)
       OR COALESCE(plan#>>'{backup,manifest_sha256}','') !~ '^[0-9a-f]{64}$'
       OR length(COALESCE(plan#>>'{backup,reference}','')) NOT BETWEEN 1 AND 1000
       OR (plan->>'captured_at') IS NULL
       OR (plan->>'captured_at')::timestamptz<clock_timestamp()-interval '24 hours'
       OR (plan->>'captured_at')::timestamptz>clock_timestamp()+interval '5 minutes'
       OR NOT COALESCE((plan#>>'{evidence,document_equal}')::boolean,false)
       OR NOT COALESCE((plan#>>'{evidence,birth_equal}')::boolean,false)
       OR NOT COALESCE((plan#>>'{evidence,valid_resident_id}')::boolean,false)
       OR COALESCE(plan#>>'{evidence,sha256}','') !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'Missing fresh paired-backup and explicit normalized identity evidence';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM flyway_schema_history WHERE version='947' AND success
                     AND script='V947__employee_identity_account_row_lock.sql')
       OR to_regclass('public.employee_identity_aliases') IS NULL THEN
        RAISE EXCEPTION 'Reviewed V937/V947 identity schema is required';
    END IF;
    SELECT jsonb_build_object('database',current_database(),
       'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),
       'database_oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),
       'dataset_id',(SELECT business_dataset_id::text FROM authorization_state WHERE singleton_id=1),
       'generation',(SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1),
       'migration_max',(SELECT max(version::int) FROM flyway_schema_history WHERE success),
       'migration_sha256',(SELECT encode(public.digest(COALESCE(jsonb_agg(jsonb_build_array(version,checksum) ORDER BY installed_rank)::text,'[]'),'sha256'),'hex')
                            FROM flyway_schema_history WHERE success)) INTO identity;
    IF identity IS DISTINCT FROM plan->'database_identity' THEN
        RAISE EXCEPTION 'Physical database/dataset/migration identity differs from the reviewed plan';
    END IF;
    canonical:=(plan#>>'{canonical,employee_id}')::uuid;
    duplicate_id:=(plan#>>'{duplicate,employee_id}')::uuid;
    members:=ARRAY[canonical,duplicate_id];
    evidence:=(plan#>>'{evidence,reference}')||'#sha256='||(plan#>>'{evidence,sha256}'); actor:=plan->>'maintenance_actor';
    IF canonical IS NULL OR duplicate_id IS NULL OR canonical=duplicate_id
       OR length(COALESCE(actor,'')) NOT BETWEEN 1 AND 128
       OR length(COALESCE(evidence,'')) NOT BETWEEN 1 AND 1000
       OR length(COALESCE(plan#>>'{duplicate,reason}','')) NOT BETWEEN 5 AND 1000 THEN
        RAISE EXCEPTION 'Explicit distinct identities, operator and review reason are required';
    END IF;
    PERFORM set_config('lock_timeout','5s',true);
    PERFORM set_config('statement_timeout','30s',true);
    PERFORM pg_advisory_xact_lock(1431586126,937);
    PERFORM id FROM employees WHERE id=ANY(members) ORDER BY id FOR UPDATE;
    PERFORM id FROM users WHERE employee_id=ANY(members) ORDER BY id FOR UPDATE;
    -- A non-standard PII writer may bypass the parent lifecycle lock. In RR a
    -- concurrently changed sensitive row must serialize/fail before its proof is used.
    PERFORM employee_id FROM employee_sensitive WHERE employee_id=ANY(members) ORDER BY employee_id FOR UPDATE;
    PERFORM singleton_id FROM authorization_state WHERE singleton_id=1 FOR UPDATE;
    SELECT * INTO STRICT canonical_row FROM employees WHERE id=canonical;
    SELECT * INTO STRICT duplicate_row FROM employees WHERE id=duplicate_id;
    IF canonical_row.code IS DISTINCT FROM plan#>>'{canonical,code}'
       OR canonical_row.version IS DISTINCT FROM (plan#>>'{canonical,version}')::integer
       OR canonical_row.status<>'resigned' OR canonical_row.is_deleted
       OR duplicate_row.code IS DISTINCT FROM plan#>>'{duplicate,code}'
       OR duplicate_row.status<>'resigned'
       OR EXISTS(SELECT 1 FROM users WHERE employee_id=ANY(members))
       OR EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=canonical OR canonical_employee_id=duplicate_id)
       OR NOT EXISTS(SELECT 1 FROM employee_sensitive s WHERE s.employee_id=canonical AND s.id_card_hash IS NOT NULL
              AND encode(public.digest(to_jsonb(s)::text,'sha256'),'hex')=plan#>>'{evidence,canonical_sensitive_sha256}')
       OR NOT EXISTS(SELECT 1 FROM employee_sensitive s WHERE s.employee_id=duplicate_id AND s.id_card_hash IS NULL
              AND encode(public.digest(to_jsonb(s)::text,'sha256'),'hex')=plan#>>'{evidence,duplicate_sensitive_sha256}') THEN
        RAISE EXCEPTION 'Resigned/account-free identity, versions or private evidence fingerprints drifted';
    END IF;
    IF EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=duplicate_id) THEN
        IF NOT duplicate_row.is_deleted
           OR duplicate_row.version<>(plan#>>'{duplicate,version}')::integer+1
           OR NOT EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=duplicate_id
                 AND canonical_employee_id=canonical AND evidence_reference=evidence
                 AND reason=plan#>>'{duplicate,reason}') THEN
            RAISE EXCEPTION 'An existing alias does not match this exact reviewed correction';
        END IF;
        RETURN jsonb_build_object('status','ALREADY_APPLIED','canonical_employee_id',canonical,
                  'duplicate_employee_id',duplicate_id,'business_writes',0,'account_writes',0);
    END IF;
    IF duplicate_row.is_deleted OR duplicate_row.version IS DISTINCT FROM (plan#>>'{duplicate,version}')::integer THEN
        RAISE EXCEPTION 'Duplicate archive state/version differs from the reviewed live source';
    END IF;
    -- A closed historical identity cannot be hidden while it still owns live work.
    FOR responsibility IN SELECT * FROM (VALUES
       ('clients','owner_employee_id','NOT t.is_deleted'),('suppliers','owner_employee_id','NOT t.is_deleted'),
       ('goods','owner_employee_id','NOT t.is_deleted'),('moulds','keeper_id','NOT t.is_deleted'),
       ('departments','manager_id','NOT t.is_deleted'),('employees','supervisor_id','NOT t.is_deleted'),
       ('inbound_expectations','owner_employee_id',$x$t.status='OPEN'$x$),
       ('procurement_arrival_exceptions','owner_employee_id',$x$t.status NOT IN('CLOSED','CANCELED')$x$),
       ('supplier_return_tasks','owner_employee_id',$x$t.status='PENDING_RETURN'$x$),
       ('website_inquiries','assignee_employee_id',$x$t.status IN('new','following')$x$),
       ('visitor_applications','host_employee_id',$x$NOT t.is_deleted AND t.status IN('pending','hostReviewing','approved') AND t.planned_visit_at>current_timestamp$x$),
       ('rd_tasks','assignee_employee_id',$x$NOT t.is_deleted AND t.status IN('OPEN','IN_PROGRESS')$x$),
       ('production_plans','seller_id','NOT t.is_deleted AND t.status=0'),('production_plans','worker_id','NOT t.is_deleted AND t.status=0'),
       ('production_execution_segments','responsible_employee_id',$x$NOT t.is_deleted AND t.status IN('READY','WAITING','DISPATCHED','IN_PROGRESS')$x$),
       ('fixed_assets','custodian_employee_id',$x$NOT t.is_deleted AND t.lifecycle_status<>'DISPOSED'$x$),
       ('deferred_expenses','responsible_employee_id',$x$NOT t.is_deleted AND t.lifecycle_status NOT IN('COMPLETED','TERMINATED')$x$),
       ('task_claims','claimed_by','t.released_at IS NULL'),('hr_task_claims','claimed_by','t.released_at IS NULL'),
       ('profile_change_requests','employee_id',$x$t.status='pending'$x$)) r(table_name,column_name,predicate)
    LOOP
        EXECUTE format('SELECT count(*) FROM public.%I t WHERE t.%I=ANY($1) AND (%s)',responsibility.table_name,responsibility.column_name,responsibility.predicate)
        INTO active_count USING members;
        IF active_count<>0 THEN
            RAISE EXCEPTION 'Current responsibility remains on %.% (% rows); use the ordinary handover first',responsibility.table_name,responsibility.column_name,active_count;
        END IF;
    END LOOP;
    SELECT COALESCE(array_agg(id),'{}'::bigint[]) INTO old_audits FROM (
        SELECT id FROM audit_log WHERE target_id=ANY(members::text[]) OR actor_id=ANY(members)
        UNION SELECT id FROM audit_log_archive WHERE target_id=ANY(members::text[]) OR actor_id=ANY(members)) existing_audit;
    before_facts:=pg_temp.employee_duplicate_preservation(members,duplicate_id,old_audits);
    SELECT epoch INTO STRICT old_epoch FROM authorization_state WHERE singleton_id=1;
    old_generation:=duplicate_row.permission_delegation_generation;
    PERFORM set_config('app.actor_id','',true);
    PERFORM set_config('app.actor_account',actor,true);
    PERFORM set_config('app.employee_identity_merge_evidence',evidence,true);
    UPDATE employees SET is_deleted=true,deleted_at=clock_timestamp(),version=version+1 WHERE id=duplicate_id;
    GET DIAGNOSTICS changed=ROW_COUNT;
    IF changed<>1 THEN RAISE EXCEPTION 'Expected exactly one duplicate archive update'; END IF;
    INSERT INTO employee_identity_aliases(alias_employee_id,canonical_employee_id,reason,evidence_reference)
    VALUES(duplicate_id,canonical,plan#>>'{duplicate,reason}',evidence);
    after_facts:=pg_temp.employee_duplicate_preservation(members,duplicate_id,old_audits);
    IF after_facts IS DISTINCT FROM before_facts
       -- V324 invalidates the archived employee generation once; V937 adds the
       -- alias invalidation once. Both are required, independently verified events.
       OR (SELECT epoch FROM authorization_state WHERE singleton_id=1)<>old_epoch+2
       OR NOT EXISTS(SELECT 1 FROM employees WHERE id=duplicate_id AND is_deleted AND status='resigned'
              AND version=duplicate_row.version+1 AND deleted_at IS NOT NULL
              AND permission_delegation_generation=old_generation+1)
       OR NOT EXISTS(SELECT 1 FROM employees WHERE id=canonical AND NOT is_deleted AND status='resigned' AND version=canonical_row.version)
       OR fn_canonical_employee_identity(duplicate_id)<>canonical
       OR EXISTS(SELECT 1 FROM users WHERE employee_id=ANY(members)) THEN
        SELECT jsonb_build_object(
          'changed_relations',(SELECT COALESCE(jsonb_agg(key ORDER BY key),'[]'::jsonb) FROM jsonb_object_keys(before_facts) key WHERE before_facts->key IS DISTINCT FROM after_facts->key),
          'epoch_delta',(SELECT epoch-old_epoch FROM authorization_state WHERE singleton_id=1),
          'duplicate_version_delta',(SELECT version-duplicate_row.version FROM employees WHERE id=duplicate_id),
          'duplicate_generation_delta',(SELECT permission_delegation_generation-old_generation FROM employees WHERE id=duplicate_id),
          'duplicate_archived_resigned',(SELECT is_deleted AND status='resigned' AND deleted_at IS NOT NULL FROM employees WHERE id=duplicate_id),
          'canonical_unchanged',(SELECT to_jsonb(e)=to_jsonb(canonical_row) FROM employees e WHERE id=canonical),
          'canonical_retained_resigned',(SELECT NOT is_deleted AND status='resigned' FROM employees WHERE id=canonical),
          'alias_points_to_canonical',fn_canonical_employee_identity(duplicate_id)=canonical,
          'account_count',(SELECT count(*) FROM users WHERE employee_id=ANY(members))) INTO preservation_diagnostic;
        RAISE EXCEPTION 'Reference/history/account/state preservation failed; rollback required. Safe diagnostics: %',preservation_diagnostic;
    END IF;
    RETURN jsonb_build_object('status','APPLIED_IN_TRANSACTION','protocol',plan->>'protocol',
       'canonical_employee_id',canonical,'canonical_code',canonical_row.code,'canonical_status','resigned',
       'duplicate_employee_id',duplicate_id,'duplicate_code',duplicate_row.code,
       'archives_hidden',1,'aliases_inserted',1,'accounts_created',0,'account_or_credential_writes',0,
       'history_or_reference_rewrites',0,'preservation','passed','authorization_epoch_delta',2,
       'scoped_table_fingerprints',(SELECT count(*) FROM jsonb_object_keys(before_facts)),
       'backup_manifest_sha256',plan#>>'{backup,manifest_sha256}',
       'identity_evidence_sha256',plan#>>'{evidence,sha256}','evidence_reference',evidence);
END $$;
