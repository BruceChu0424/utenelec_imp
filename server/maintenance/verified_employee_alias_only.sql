-- Explicit, reviewed maintenance only. No startup/Flyway hook and no account repair.
-- Load within BEGIN ISOLATION LEVEL REPEATABLE READ; call the temporary function;
-- inspect its safe receipt, then COMMIT or ROLLBACK on this same connection.
CREATE OR REPLACE FUNCTION pg_temp.employee_alias_preservation(members uuid[], retained_user uuid, audit_ids bigint[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE result jsonb := '{}'::jsonb; relation record; rows jsonb;
BEGIN
    -- Capture actual scoped rows, including credentials, grant/revoke provenance,
    -- messages/read state, sessions and HR history, only inside this connection.
    -- Do not export or log this private return value.
    FOR relation IN
        SELECT c.relname,
               bool_or(a.attname='employee_id') AS employee_owned,
               bool_or(a.attname='user_id') AS user_owned
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
        WHERE n.nspname='public' AND c.relkind IN('r','p')
          AND a.attname IN('employee_id','user_id')
        GROUP BY c.relname ORDER BY c.relname
    LOOP
        EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),''[]''::jsonb) FROM public.%I t WHERE %s',
            relation.relname,
            CASE WHEN relation.employee_owned THEN 'employee_id=ANY($1)' ELSE 'false' END
            || ' OR ' || CASE WHEN relation.user_owned THEN 'user_id=$2' ELSE 'false' END)
        INTO rows USING members,retained_user;
        result := result || jsonb_build_object(relation.relname,rows);
    END LOOP;
    SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.id),'[]'::jsonb) INTO rows
        FROM employees e WHERE id=ANY(members);
    result := result || jsonb_build_object('employees',rows);
    SELECT COALESCE(jsonb_agg(to_jsonb(u) ORDER BY u.id),'[]'::jsonb) INTO rows
        FROM users u WHERE id=retained_user OR employee_id=ANY(members);
    result := result || jsonb_build_object('users',rows);
    SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.id),'[]'::jsonb) INTO rows
        FROM audit_log a WHERE (actor_id=retained_user OR target_id=ANY(members::text[]))
            AND (audit_ids IS NULL OR id=ANY(audit_ids));
    result := result || jsonb_build_object('raw_audit',rows);
    SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.id),'[]'::jsonb) INTO rows
        FROM audit_log_archive a WHERE (actor_id=retained_user OR target_id=ANY(members::text[]))
            AND (audit_ids IS NULL OR id=ANY(audit_ids));
    result := result || jsonb_build_object('raw_audit_archive',rows);
    SELECT COALESCE(jsonb_agg(to_jsonb(n) ORDER BY n.id),'[]'::jsonb) INTO rows
        FROM notices n WHERE created_by=retained_user
          OR id IN(SELECT notice_id FROM notice_user_states WHERE user_id=retained_user);
    RETURN result || jsonb_build_object('notice_contents',rows);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.apply_verified_employee_alias_only(plan jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE canonical uuid; retained_user uuid; members uuid[]; item jsonb;
        identity jsonb; before_facts jsonb; old_epoch bigint; inserted integer := 0;
        affected integer; evidence text; actor text; existing_evidence text; original_audit_ids bigint[];
BEGIN
    IF current_setting('transaction_isolation')<>'repeatable read' THEN
        RAISE EXCEPTION 'Alias maintenance requires an explicit repeatable-read transaction';
    END IF;
    IF plan->>'protocol' IS DISTINCT FROM 'verified-employee-alias-only-v1'
       OR jsonb_typeof(plan->'aliases') IS DISTINCT FROM 'array'
       OR jsonb_array_length(plan->'aliases') NOT BETWEEN 1 AND 20
       OR NOT COALESCE((plan#>>'{backup,verified}')::boolean,false)
       OR COALESCE(plan#>>'{backup,manifest_sha256}','') !~ '^[0-9a-f]{64}$'
       OR length(COALESCE(plan#>>'{backup,reference}','')) NOT BETWEEN 1 AND 1000
       OR plan->>'captured_at' IS NULL
       OR (plan->>'captured_at')::timestamptz < clock_timestamp()-interval '24 hours'
       OR (plan->>'captured_at')::timestamptz > clock_timestamp()+interval '5 minutes' THEN
        RAISE EXCEPTION 'Missing, expired or invalid reviewed alias/backup evidence';
    END IF;
    IF to_regclass('public.employee_identity_aliases') IS NULL
       OR to_regprocedure('public.fn_employee_identity_members(uuid)') IS NULL
       OR NOT EXISTS(SELECT 1 FROM flyway_schema_history WHERE version='947' AND success
           AND script='V947__employee_identity_account_row_lock.sql') THEN
        RAISE EXCEPTION 'Deploy the reviewed identity-alias schema before maintenance';
    END IF;
    SELECT jsonb_build_object(
        'database',current_database(),
        'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),
        'database_oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),
        'dataset_id',(SELECT business_dataset_id::text FROM authorization_state WHERE singleton_id=1),
        'generation',(SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1),
        'migration_max',(SELECT max(version::int) FROM flyway_schema_history WHERE success),
        'migration_sha256',(SELECT encode(public.digest(
            COALESCE(jsonb_agg(jsonb_build_array(version,checksum) ORDER BY installed_rank)::text,'[]'),'sha256'),'hex')
            FROM flyway_schema_history WHERE success)) INTO identity;
    IF identity IS DISTINCT FROM plan->'database_identity' THEN
        RAISE EXCEPTION 'Physical database, dataset or reviewed migration identity drifted';
    END IF;
    canonical := (plan#>>'{canonical,employee_id}')::uuid;
    retained_user := (plan#>>'{retained_user,user_id}')::uuid;
    evidence := plan->>'evidence_reference'; actor := plan->>'maintenance_actor';
    IF length(COALESCE(evidence,'')) NOT BETWEEN 1 AND 1000
       OR length(COALESCE(actor,'')) NOT BETWEEN 1 AND 128
       OR (plan#>>'{canonical,code}') IS NULL
       OR (plan#>>'{canonical,version}') IS NULL
       OR (plan#>>'{retained_user,version}') IS NULL
       OR (plan#>>'{retained_user,auth_version}') IS NULL THEN
        RAISE EXCEPTION 'Explicit restored employee/account and evidence preconditions are required';
    END IF;
    SELECT array_prepend(canonical,array_agg((v->>'employee_id')::uuid ORDER BY v->>'employee_id'))
        INTO members FROM jsonb_array_elements(plan->'aliases') v;
    IF canonical=ANY(members[2:]) OR cardinality(members)<>(SELECT count(DISTINCT id) FROM unnest(members) id) THEN
        RAISE EXCEPTION 'Alias identities must be distinct from each other and the canonical identity';
    END IF;
    PERFORM set_config('lock_timeout','5s',true);
    PERFORM set_config('statement_timeout','30s',true);
    PERFORM pg_advisory_xact_lock(1431586126,937);
    PERFORM id FROM employees WHERE id=ANY(members) ORDER BY id FOR UPDATE;
    PERFORM id FROM users WHERE id=retained_user OR employee_id=ANY(members) ORDER BY id FOR UPDATE;
    PERFORM singleton_id FROM authorization_state WHERE singleton_id=1 FOR UPDATE;
    IF NOT EXISTS(SELECT 1 FROM employees WHERE id=canonical
           AND code=plan#>>'{canonical,code}' AND version=(plan#>>'{canonical,version}')::bigint
           AND NOT is_deleted AND status IN('active','probation','onLeave'))
       OR NOT EXISTS(SELECT 1 FROM users WHERE id=retained_user AND employee_id=canonical
           AND NOT is_deleted AND status='active' AND NOT must_change_password
           AND temp_password_expires_at IS NULL AND NULLIF(btrim(password_hash),'') IS NOT NULL
           AND (locked_until IS NULL OR locked_until<=clock_timestamp())
           AND version=(plan#>>'{retained_user,version}')::bigint
           AND auth_version=(plan#>>'{retained_user,auth_version}')::bigint)
       OR EXISTS(SELECT 1 FROM users WHERE employee_id=ANY(members) AND id<>retained_user AND NOT is_deleted)
       OR EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=canonical
                     OR canonical_employee_id=ANY(members[2:])) THEN
        RAISE EXCEPTION 'Current restored employee/account binding or alias preconditions drifted';
    END IF;
    FOR item IN SELECT value FROM jsonb_array_elements(plan->'aliases') LOOP
        IF NOT EXISTS(SELECT 1 FROM employees WHERE id=(item->>'employee_id')::uuid
               AND code=item->>'code' AND version=(item->>'version')::bigint AND is_deleted)
           OR length(COALESCE(item->>'reason','')) NOT BETWEEN 1 AND 1000 THEN
            RAISE EXCEPTION 'An archived alias identity/version or its verified reason drifted';
        END IF;
        SELECT evidence_reference INTO existing_evidence FROM employee_identity_aliases
            WHERE alias_employee_id=(item->>'employee_id')::uuid;
        IF FOUND AND (existing_evidence<>evidence OR NOT EXISTS(
            SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=(item->>'employee_id')::uuid
                AND canonical_employee_id=canonical AND reason=item->>'reason')) THEN
            RAISE EXCEPTION 'Existing alias has different canonical identity or evidence';
        END IF;
    END LOOP;
    before_facts := pg_temp.employee_alias_preservation(members,retained_user);
    SELECT COALESCE(array_agg((row->>'id')::bigint),'{}'::bigint[]) INTO original_audit_ids
        FROM jsonb_array_elements((before_facts->'raw_audit')||(before_facts->'raw_audit_archive')) row;
    SELECT epoch INTO STRICT old_epoch FROM authorization_state WHERE singleton_id=1;
    PERFORM set_config('app.actor_id','',true);
    PERFORM set_config('app.actor_account',actor,true);
    PERFORM set_config('app.employee_identity_merge_evidence',evidence,true);
    FOR item IN SELECT value FROM jsonb_array_elements(plan->'aliases') LOOP
        INSERT INTO employee_identity_aliases(alias_employee_id,canonical_employee_id,reason,evidence_reference)
        SELECT (item->>'employee_id')::uuid,canonical,item->>'reason',evidence
        WHERE NOT EXISTS(SELECT 1 FROM employee_identity_aliases WHERE alias_employee_id=(item->>'employee_id')::uuid);
        GET DIAGNOSTICS affected=ROW_COUNT; inserted := inserted+affected;
    END LOOP;
    IF pg_temp.employee_alias_preservation(members,retained_user,original_audit_ids) IS DISTINCT FROM before_facts
       OR (SELECT epoch FROM authorization_state WHERE singleton_id=1)<>old_epoch+inserted
       OR EXISTS(SELECT 1 FROM unnest(members) id WHERE NOT EXISTS(
           SELECT 1 FROM fn_employee_identity_members(canonical) m WHERE m.employee_id=id)) THEN
        RAISE EXCEPTION 'Alias preservation or history-membership verification failed; rollback required';
    END IF;
    RETURN jsonb_build_object('protocol','verified-employee-alias-only-v1',
        'inserted_aliases',inserted,'already_present',jsonb_array_length(plan->'aliases')-inserted,
        'canonical_employee_id',canonical,'retained_user_id',retained_user,
        'preservation','passed','raw_history_rewritten',false,
        'account_or_credential_writes',0,'authorization_epoch_delta',inserted,
        'backup_manifest_sha256',plan#>>'{backup,manifest_sha256}',
        'evidence_reference',evidence);
END $$;
