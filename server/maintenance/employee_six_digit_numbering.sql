-- Load in one maintenance connection after V977. Temporary functions never run
-- themselves. Review the preview, then apply that EXACT JSON in a transaction.
CREATE OR REPLACE FUNCTION pg_temp.employee_numbering_plan(
    founder_one uuid, founder_two uuid,
    owner_login text DEFAULT '17665410007', owner_hire_date date DEFAULT DATE '2026-10-31')
RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE owner_employee uuid; realm uuid; entries jsonb; excluded jsonb; accounts jsonb;
        owner_history jsonb; issues jsonb := '[]'::jsonb; bootstrap_confirmation boolean;
BEGIN
    SELECT business_dataset_id INTO STRICT realm FROM public.authorization_state WHERE singleton_id=1;
    SELECT employee_id INTO STRICT owner_employee FROM public.users
    WHERE login_account=owner_login AND NOT is_deleted;
    IF owner_login IS DISTINCT FROM '17665410007' OR owner_hire_date IS DISTINCT FROM DATE '2026-10-31' THEN
        RAISE EXCEPTION 'This request fixes account 17665410007 and hire date 2026-10-31';
    END IF;
    IF founder_one IS NULL OR founder_two IS NULL OR owner_employee IS NULL
       OR founder_one=founder_two OR owner_employee IN(founder_one,founder_two) THEN
        RAISE EXCEPTION 'Three distinct verified employee identities are required';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.employees WHERE id=founder_one AND full_name='朱德洪' AND NOT is_deleted)
       OR NOT EXISTS(SELECT 1 FROM public.employees WHERE id=founder_two AND full_name='王少春' AND NOT is_deleted)
       OR NOT EXISTS(SELECT 1 FROM public.employees WHERE id=owner_employee AND NOT is_deleted)
       OR EXISTS(SELECT 1 FROM public.employee_identity_aliases
                 WHERE alias_employee_id IN(founder_one,founder_two,owner_employee)) THEN
        RAISE EXCEPTION 'Founders and owner must be verified retained employee records';
    END IF;
    IF EXISTS(SELECT 1 FROM public.employees e
              WHERE NOT e.is_deleted AND e.full_name IN('朱德洪','王少春')
                AND NOT EXISTS(SELECT 1 FROM public.employee_identity_aliases a WHERE a.alias_employee_id=e.id)
              GROUP BY e.full_name HAVING count(*)<>1) THEN
        RAISE EXCEPTION 'Founder names are ambiguous; resolve identity before numbering';
    END IF;
    -- V08's ADMIN seed used 2026-01-01; V213 copied that placeholder into
    -- confirmed_at. Treat this precise bootstrap default as the requested same-day
    -- regular onboarding, with both old/new dates visible in the reviewed plan.
    SELECT code='ADMIN' AND hire_date=DATE '2026-01-01' AND confirmed_at=hire_date
        AND NOT EXISTS(SELECT 1 FROM public.employment_history h WHERE h.employee_id=owner_employee
                       AND h.event_type NOT IN('onboard','hire_date_correction'))
    INTO bootstrap_confirmation FROM public.employees WHERE id=owner_employee;
    WITH roster AS (
        SELECT e.*, row_number() OVER(ORDER BY
            CASE WHEN e.id=founder_one THEN 0 WHEN e.id=founder_two THEN 1
                 WHEN e.id=owner_employee THEN 3 ELSE 2 END,
            e.hire_date NULLS LAST,e.created_at,e.id) AS ordinal
        FROM public.employees e WHERE NOT e.is_deleted
          AND (e.code<>'ADMIN' OR e.id IN(founder_one,founder_two,owner_employee))
          AND NOT EXISTS(SELECT 1 FROM public.employee_identity_aliases a WHERE a.alias_employee_id=e.id)
    )
    SELECT jsonb_agg(jsonb_build_object(
        'employeeId',id,'name',full_name,'oldCode',code,
        'newCode',CASE WHEN ordinal<=999999 THEN lpad(ordinal::text,6,'0') ELSE ordinal::text END,
        'oldHireDate',hire_date,'newHireDate',CASE WHEN id=owner_employee THEN owner_hire_date ELSE hire_date END,
        'confirmedAt',confirmed_at,
        'newConfirmedAt',CASE WHEN id=owner_employee AND bootstrap_confirmation THEN owner_hire_date ELSE confirmed_at END,
        'version',version,'status',status,
        'createdAt',created_at,'generation',permission_delegation_generation) ORDER BY ordinal)
    INTO entries FROM roster;
    IF jsonb_array_length(entries)>999999 THEN RAISE EXCEPTION 'Six-digit employee number capacity exceeded'; END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(entries) e WHERE e->>'oldHireDate' IS NULL) THEN
        issues:=issues||jsonb_build_array('存在缺失入职日期的员工，请先核对');
    END IF;
    -- Existing lifetime ownership is never bypassed, deleted, or transferred.
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(entries) e
        JOIN public.business_identifier_reservations r ON r.normalized_identifier=e->>'newCode'
        WHERE NOT EXISTS(SELECT 1 FROM public.business_identifier_reservation_members m
            WHERE m.normalized_identifier=r.normalized_identifier AND m.owner_domain='EMPLOYEE'
              AND m.source_table='employees' AND m.entity_id=(e->>'employeeId')::uuid)
           OR EXISTS(SELECT 1 FROM public.business_identifier_reservation_members m
            WHERE m.normalized_identifier=r.normalized_identifier AND
              (m.owner_domain<>'EMPLOYEE' OR m.source_table<>'employees' OR m.entity_id<>(e->>'employeeId')::uuid)))
       OR EXISTS(SELECT 1 FROM jsonb_array_elements(entries) e
        JOIN public.master_code_reservation_members m ON m.master_domain='EMPLOYEE' AND m.normalized_code=e->>'newCode'
        WHERE m.entity_id<>(e->>'employeeId')::uuid) THEN
        issues:=issues||jsonb_build_array('目标工号已有其他身份或业务占用，禁止覆盖历史预约');
    END IF;
    IF EXISTS(SELECT 1 FROM public.employees WHERE id=owner_employee AND hire_date<>owner_hire_date
              AND confirmed_at<owner_hire_date AND NOT COALESCE(bootstrap_confirmation,false))
       OR (SELECT count(*) FROM public.employment_history WHERE employee_id=owner_employee AND event_type='onboard')>1
       OR EXISTS(SELECT 1 FROM public.employment_history WHERE employee_id=owner_employee
                 AND event_type NOT IN('onboard','hire_date_correction') AND event_date<owner_hire_date) THEN
        issues:=issues||jsonb_build_array('本人入职日期与现有转正或任职历史冲突，须先核对原始记录');
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('employeeId',e.id,'code',e.code,
        'reason',CASE WHEN e.is_deleted THEN 'deleted' WHEN a.alias_employee_id IS NOT NULL THEN 'verified alias'
                      ELSE 'separate bootstrap identity' END) ORDER BY e.id),'[]'::jsonb)
    INTO excluded FROM public.employees e LEFT JOIN public.employee_identity_aliases a ON a.alias_employee_id=e.id
    WHERE e.is_deleted OR a.alias_employee_id IS NOT NULL
       OR (e.code='ADMIN' AND e.id NOT IN(founder_one,founder_two,owner_employee));
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id',u.id,'employeeId',u.employee_id,
        'loginAccount',u.login_account,'deleted',u.is_deleted,'status',u.status,'authVersion',u.auth_version)
        ORDER BY u.id),'[]'::jsonb) INTO accounts FROM public.users u;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id',h.id,'type',h.event_type,'date',h.event_date,
        'correctsHistoryId',h.corrects_history_id) ORDER BY h.id),'[]'::jsonb)
    INTO owner_history FROM public.employment_history h WHERE h.employee_id=owner_employee;
    RETURN jsonb_build_object('protocol','employee-six-digit-v1','database',current_database(),
        'datasetId',realm,'founderOne',founder_one,'founderTwo',founder_two,
        'ownerEmployeeId',owner_employee,'ownerLogin',owner_login,'ownerHireDate',owner_hire_date,
        'entries',entries,'excluded',excluded,'accounts',accounts,'ownerHistory',owner_history,'issues',issues);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.apply_employee_numbering(plan jsonb,evidence text)
RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE actual jsonb; receipt public.employee_code_numbering_receipts%ROWTYPE;
        realm uuid; plan_hash text; owner_employee uuid; owner_date date; original_onboard uuid; changed bigint;
BEGIN
    IF plan IS NULL OR plan->>'protocol' IS DISTINCT FROM 'employee-six-digit-v1'
       OR evidence IS NULL OR length(btrim(evidence)) NOT BETWEEN 1 AND 1000 THEN
        RAISE EXCEPTION 'An exact reviewed plan and evidence reference are required';
    END IF;
    LOCK TABLE public.employees,public.users,public.employee_identity_aliases,public.employment_history
        IN SHARE ROW EXCLUSIVE MODE;
    SELECT business_dataset_id INTO STRICT realm FROM public.authorization_state WHERE singleton_id=1;
    IF (plan->>'datasetId')::uuid IS DISTINCT FROM realm OR plan->>'database' IS DISTINCT FROM current_database() THEN
        RAISE EXCEPTION 'Numbering plan belongs to a different database or business dataset';
    END IF;
    plan_hash:=encode(public.digest(plan::text,'sha256'),'hex');
    SELECT * INTO receipt FROM public.employee_code_numbering_receipts WHERE dataset_id=realm;
    IF FOUND THEN
        IF receipt.plan_sha256<>plan_hash THEN RAISE EXCEPTION 'Initial numbering is already complete; employee numbers are fixed'; END IF;
        RETURN jsonb_build_object('alreadyApplied',true,'planSha256',plan_hash,'count',jsonb_array_length(plan->'entries'));
    END IF;
    actual:=pg_temp.employee_numbering_plan((plan->>'founderOne')::uuid,(plan->>'founderTwo')::uuid,
        plan->>'ownerLogin',(plan->>'ownerHireDate')::date);
    IF actual IS DISTINCT FROM plan THEN RAISE EXCEPTION 'Numbering preview is stale; regenerate and review'; END IF;
    IF jsonb_array_length(actual->'issues')<>0 THEN RAISE EXCEPTION 'Numbering preflight failed: %',actual->'issues'; END IF;
    IF lower(COALESCE(current_setting('app.business_identifier_legacy_import',true),'off')) IN('on','true','1')
       OR COALESCE(current_setting('uten.legacy_reference_import',true),'')<>'' THEN
        RAISE EXCEPTION 'Numbering must not bypass identifier ownership with legacy import mode';
    END IF;
    owner_employee:=(plan->>'ownerEmployeeId')::uuid;
    owner_date:=(plan->>'ownerHireDate')::date;
    PERFORM set_config('app.actor_account','employee-numbering-maintenance',true);
    IF EXISTS(SELECT 1 FROM public.employees WHERE id=owner_employee AND hire_date<>owner_date) THEN
        SELECT id INTO original_onboard FROM public.employment_history
        WHERE employee_id=owner_employee AND event_type='onboard';
        INSERT INTO public.employment_history(employee_id,event_type,event_date,corrects_history_id,remark)
        SELECT owner_employee,'hire_date_correction',owner_date,original_onboard,
            '用户要求按2026-10-31入职；原日期：'||hire_date::text||'；证据：'||evidence
        FROM public.employees WHERE id=owner_employee;
    END IF;
    UPDATE public.employees e SET code=p->>'newCode',hire_date=(p->>'newHireDate')::date,
        confirmed_at=(p->>'newConfirmedAt')::date,version=e.version+1
    FROM jsonb_array_elements(plan->'entries') p WHERE e.id=(p->>'employeeId')::uuid
      AND (e.code IS DISTINCT FROM p->>'newCode' OR e.hire_date IS DISTINCT FROM (p->>'newHireDate')::date
           OR e.confirmed_at IS DISTINCT FROM (p->>'newConfirmedAt')::date);
    GET DIAGNOSTICS changed=ROW_COUNT;
    INSERT INTO public.master_code_sequences(prefix,last_seq)
    VALUES('',GREATEST(2,jsonb_array_length(plan->'entries')))
    -- This one-time reviewed initial numbering establishes the new sequence.
    -- Old numeric imports may have arbitrarily high codes. Lifetime reservations
    -- still exclude every retired value; subsequent online allocations only grow.
    ON CONFLICT(prefix) DO UPDATE SET last_seq=EXCLUDED.last_seq;
    INSERT INTO public.employee_code_numbering_receipts(dataset_id,plan_sha256,plan,evidence_reference)
    VALUES(realm,plan_hash,plan,evidence);
    RETURN jsonb_build_object('alreadyApplied',false,'planSha256',plan_hash,
        'count',jsonb_array_length(plan->'entries'),'changed',changed);
END;
$$;
