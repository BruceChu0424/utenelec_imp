-- Payroll owns salary facts; the six original applications own approval authority.
-- These records connect those facts to one accrual and append-only actual payments.
CREATE FUNCTION fn_finance_payroll_wage_style_allowed(p_style uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM payment_styles s JOIN finance_chart_code_styles m ON m.style_id=s.id
   WHERE s.id=p_style AND s.category='LIABILITY' AND s.status='使用' AND NOT s.is_deleted
     AND NOT EXISTS(SELECT 1 FROM payment_styles child WHERE child.parent_id=s.id AND NOT child.is_deleted)
     AND(m.code LIKE '2211%' OR EXISTS(SELECT 1 FROM finance_report_line_bindings b WHERE b.line_key='BS_35' AND b.binding_kind='STYLE' AND b.style_id=s.id)));
$$;
CREATE FUNCTION fn_finance_payroll_employee_settlement_style_allowed(p_style uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM payment_styles s JOIN finance_chart_code_styles m ON m.style_id=s.id
   WHERE s.id=p_style AND s.category='ACCOUNT' AND s.status='使用' AND NOT s.is_deleted
     AND NOT EXISTS(SELECT 1 FROM payment_styles child WHERE child.parent_id=s.id AND NOT child.is_deleted)
     AND(m.code LIKE '1221%' OR EXISTS(SELECT 1 FROM finance_report_line_bindings b WHERE b.line_key='BS_8' AND b.binding_kind='STYLE' AND b.style_id=s.id)));
$$;
CREATE TABLE finance_payroll_preparations (
    application_id uuid PRIMARY KEY REFERENCES finance_applications(id),
    batch_id uuid NOT NULL REFERENCES payroll_batches(id),
    source_fingerprint text NOT NULL CHECK(source_fingerprint~'^[0-9a-f]{64}$'),
    instruction_fingerprint text NOT NULL CHECK(instruction_fingerprint~'^[0-9a-f]{64}$'),
    instruction jsonb NOT NULL,issues jsonb NOT NULL,
    prepared_by uuid NOT NULL REFERENCES users(id),prepared_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE finance_payroll_accruals (
    batch_id uuid PRIMARY KEY REFERENCES payroll_batches(id),
    application_id uuid NOT NULL REFERENCES finance_applications(id),
    source_fingerprint text NOT NULL,instruction_fingerprint text NOT NULL,
    mode text NOT NULL CHECK(mode IN('NATIVE_APPROVED_PAYROLL','EXISTING_CONFIRMED_LIABILITY')),
    voucher_id uuid REFERENCES gl_vouchers(id),wage_style_id uuid REFERENCES payment_styles(id),
    gross_amount numeric NOT NULL CHECK(gross_amount>=0 AND fn_financial_amount_is_exact(gross_amount)),
    deduction_amount numeric NOT NULL CHECK(deduction_amount>=0 AND fn_financial_amount_is_exact(deduction_amount)),
    net_amount numeric NOT NULL CHECK(net_amount>=0 AND fn_financial_amount_is_exact(net_amount)),
    source_snapshot jsonb NOT NULL,instruction_snapshot jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),created_by uuid NOT NULL REFERENCES users(id),
    CHECK(gross_amount-deduction_amount=net_amount)
);
CREATE TABLE finance_payroll_payment_attempts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid NOT NULL UNIQUE,application_id uuid NOT NULL REFERENCES finance_applications(id),
    batch_id uuid NOT NULL REFERENCES payroll_batches(id),payload_fingerprint text NOT NULL,
    source_fingerprint text NOT NULL,instruction_fingerprint text NOT NULL,
    accrual_voucher_id uuid REFERENCES gl_vouchers(id),source_snapshot jsonb NOT NULL,instruction_snapshot jsonb NOT NULL,
    account_id uuid REFERENCES accounts(id),payment_date date NOT NULL,bank_reference text,bank_booked_at timestamptz,
    net_amount numeric NOT NULL CHECK(net_amount>=0 AND fn_financial_amount_is_exact(net_amount)),
    fee_amount numeric NOT NULL CHECK(fee_amount>=0 AND fn_financial_amount_is_exact(fee_amount)),
    bank_amount numeric NOT NULL CHECK(bank_amount>=0 AND fn_financial_amount_is_exact(bank_amount)),
    fee_style_id uuid REFERENCES payment_styles(id),
    payment_voucher_id uuid UNIQUE REFERENCES gl_vouchers(id),
    non_cash_voucher_id uuid REFERENCES gl_vouchers(id),
    receipt_kind text NOT NULL DEFAULT 'BANK_PAYMENT' CHECK(receipt_kind IN('BANK_PAYMENT','NON_CASH_CLEARED','NO_FINANCIAL_EVENT')),
    source_claim_only boolean NOT NULL DEFAULT false,
    account_flow_id uuid UNIQUE REFERENCES finance_reconciliations(id),
    state text NOT NULL CHECK(state IN('POSTED_PENDING_CONFIRMATION','NON_CASH_CLEARED','NO_FINANCIAL_EVENT','CONFIRMED','REVERSED')),
    evidence_snapshot jsonb NOT NULL,paid_at timestamptz NOT NULL,paid_by uuid NOT NULL REFERENCES users(id),
    confirmed_at timestamptz,confirmed_by uuid REFERENCES users(id),
    reversal_voucher_id uuid UNIQUE REFERENCES gl_vouchers(id),reversed_at timestamptz,reversed_by uuid REFERENCES users(id),
    CHECK(net_amount+fee_amount=bank_amount),CHECK((fee_amount=0)=(fee_style_id IS NULL)),
    CHECK((state='REVERSED' AND (reversal_voucher_id IS NOT NULL OR receipt_kind='NO_FINANCIAL_EVENT' OR source_claim_only)) OR (state<>'REVERSED' AND reversal_voucher_id IS NULL)),
    CHECK((receipt_kind='BANK_PAYMENT' AND net_amount>0 AND account_id IS NOT NULL AND payment_voucher_id IS NOT NULL AND account_flow_id IS NOT NULL AND non_cash_voucher_id IS NULL AND NOT source_claim_only)
      OR (receipt_kind='NON_CASH_CLEARED' AND net_amount=0 AND fee_amount=0 AND bank_amount=0 AND account_id IS NULL AND payment_voucher_id IS NULL AND account_flow_id IS NULL AND non_cash_voucher_id IS NOT NULL)
      OR (receipt_kind='NO_FINANCIAL_EVENT' AND net_amount=0 AND fee_amount=0 AND bank_amount=0 AND account_id IS NULL AND payment_voucher_id IS NULL AND account_flow_id IS NULL AND non_cash_voucher_id IS NULL))
);
CREATE UNIQUE INDEX finance_payroll_one_live_payment ON finance_payroll_payment_attempts(batch_id) WHERE state<>'REVERSED';
CREATE UNIQUE INDEX finance_payroll_application_one_live_payment ON finance_payroll_payment_attempts(application_id) WHERE state<>'REVERSED';
CREATE UNIQUE INDEX finance_payroll_one_existing_non_cash_claim ON finance_payroll_accruals(voucher_id)
 WHERE mode='EXISTING_CONFIRMED_LIABILITY' AND net_amount=0 AND gross_amount>0
   AND instruction_snapshot->>'existingLiabilityBasis'='NET_AFTER_DEDUCTIONS';
CREATE TABLE finance_payroll_payment_actions (
    request_id uuid PRIMARY KEY,application_id uuid NOT NULL REFERENCES finance_applications(id),
    payment_request_id uuid NOT NULL REFERENCES finance_payroll_payment_attempts(request_id),
    action text NOT NULL CHECK(action IN('CONFIRM','REVERSE')),actor_id uuid NOT NULL REFERENCES users(id),
    fingerprint text NOT NULL,result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION fn_finance_payroll_bridge_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION '工资原计提及动作回执为历史事实，不能覆盖或删除' USING ERRCODE='23514';END $$;
CREATE TRIGGER finance_payroll_accrual_immutable BEFORE UPDATE OR DELETE ON finance_payroll_accruals
    FOR EACH ROW EXECUTE FUNCTION fn_finance_payroll_bridge_immutable();
CREATE TRIGGER finance_payroll_action_immutable BEFORE UPDATE OR DELETE ON finance_payroll_payment_actions
    FOR EACH ROW EXECUTE FUNCTION fn_finance_payroll_bridge_immutable();
CREATE FUNCTION fn_guard_finance_payroll_payment_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' OR (to_jsonb(NEW)-ARRAY['state','confirmed_at','confirmed_by','reversal_voucher_id','reversed_at','reversed_by'])
    IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['state','confirmed_at','confirmed_by','reversal_voucher_id','reversed_at','reversed_by']) THEN
  RAISE EXCEPTION '工资实际支付原事实不可修改' USING ERRCODE='23514';
 END IF;
 IF OLD.state='REVERSED' OR OLD.state=NEW.state
   OR NOT(OLD.state IN('POSTED_PENDING_CONFIRMATION','NON_CASH_CLEARED','NO_FINANCIAL_EVENT') AND NEW.state IN('CONFIRMED','REVERSED')
      OR OLD.state='CONFIRMED' AND NEW.state='REVERSED') THEN
  RAISE EXCEPTION '工资支付状态须按确认或原支付红冲继续' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;

-- Scope identities and reservations are metadata. Committed capacity is read from
-- actual GL allocations; no completed amount is deducted a second time.
CREATE TABLE finance_gl_settlement_scopes (
    id uuid PRIMARY KEY,style_id uuid NOT NULL REFERENCES payment_styles(id),
    account_code text NOT NULL REFERENCES finance_chart_codes(code),auxiliary_id uuid REFERENCES finance_auxiliary_items(id),
    auxiliary_role text,party_id_snapshot uuid,
    CHECK((auxiliary_id IS NULL AND auxiliary_role IS NULL AND party_id_snapshot IS NULL)
       OR (auxiliary_id IS NOT NULL AND auxiliary_role IN('EMPLOYEE','SUPPLIER','CUSTOMER','OTHER') AND party_id_snapshot IS NOT NULL)),
    accounting_currency_id uuid NOT NULL REFERENCES currencies(id),original_currency_id uuid NOT NULL REFERENCES currencies(id),
    natural_direction smallint NOT NULL CHECK(natural_direction IN(1,-1)),
    UNIQUE NULLS NOT DISTINCT(style_id,account_code,auxiliary_id,accounting_currency_id,original_currency_id,natural_direction)
);
CREATE TABLE finance_gl_settlement_reservations (
    id uuid PRIMARY KEY,request_id uuid NOT NULL UNIQUE,scope_id uuid NOT NULL REFERENCES finance_gl_settlement_scopes(id),
    owner_kind text NOT NULL CHECK(length(owner_kind) BETWEEN 1 AND 80),owner_id uuid NOT NULL,
    actor_id uuid NOT NULL REFERENCES users(id),as_of date NOT NULL,
    mode text NOT NULL CHECK(mode IN('AUXILIARY_BALANCE_POOL','EXPLICIT_GL_SOURCE','CONFIRMED_AGGREGATE_LIABILITY')),
    amount_local numeric NOT NULL CHECK(amount_local>0 AND fn_financial_book_amount_is_exact(amount_local)),
    amount_original numeric NOT NULL CHECK(amount_original>0 AND fn_financial_amount_is_exact(amount_original)),
    fingerprint text NOT NULL,source_reference text NOT NULL,
    status text NOT NULL CHECK(status IN('RESERVED','COMMITTED','RELEASED','CANCELLED')),
    created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX finance_gl_settlement_pending_scope ON finance_gl_settlement_reservations(scope_id,as_of) WHERE status='RESERVED';
CREATE TABLE finance_gl_settlement_source_parts (
    reservation_id uuid NOT NULL REFERENCES finance_gl_settlement_reservations(id),
    entry_id uuid NOT NULL,allocation_no integer NOT NULL,
    amount_local numeric NOT NULL CHECK(amount_local>0 AND fn_financial_book_amount_is_exact(amount_local)),
    amount_original numeric NOT NULL CHECK(amount_original>0 AND fn_financial_amount_is_exact(amount_original)),
    PRIMARY KEY(reservation_id,entry_id,allocation_no),
    FOREIGN KEY(entry_id,allocation_no) REFERENCES finance_gl_entry_allocations(entry_id,allocation_no)
);
CREATE TABLE finance_gl_settlement_clearings (
    reservation_id uuid NOT NULL REFERENCES finance_gl_settlement_reservations(id),line_no integer NOT NULL,
    entry_id uuid NOT NULL,allocation_no integer NOT NULL,
    source_entry_id uuid,source_allocation_no integer,
    PRIMARY KEY(reservation_id,line_no),UNIQUE(entry_id,allocation_no),
    FOREIGN KEY(entry_id,allocation_no) REFERENCES finance_gl_entry_allocations(entry_id,allocation_no),
    FOREIGN KEY(source_entry_id,source_allocation_no) REFERENCES finance_gl_entry_allocations(entry_id,allocation_no),
    CHECK((source_entry_id IS NULL)=(source_allocation_no IS NULL))
);
CREATE TABLE finance_gl_settlement_reversals (
    reservation_id uuid NOT NULL REFERENCES finance_gl_settlement_reservations(id),line_no integer NOT NULL,
    entry_id uuid NOT NULL,allocation_no integer NOT NULL,
    original_entry_id uuid NOT NULL,original_allocation_no integer NOT NULL,
    PRIMARY KEY(reservation_id,line_no),UNIQUE(entry_id,allocation_no),
    FOREIGN KEY(entry_id,allocation_no) REFERENCES finance_gl_entry_allocations(entry_id,allocation_no),
    FOREIGN KEY(original_entry_id,original_allocation_no) REFERENCES finance_gl_entry_allocations(entry_id,allocation_no)
);
CREATE TABLE finance_gl_settlement_operations (
    request_id uuid PRIMARY KEY,actor_id uuid NOT NULL REFERENCES users(id),fingerprint text NOT NULL,
    operation text NOT NULL,result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
DO $$ DECLARE table_name text;BEGIN
 FOREACH table_name IN ARRAY ARRAY['finance_gl_settlement_source_parts','finance_gl_settlement_clearings',
   'finance_gl_settlement_reversals','finance_gl_settlement_operations','finance_gl_settlement_scopes'] LOOP
  EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_reject_update_or_delete()',table_name||'_immutable',table_name);
 END LOOP;
 FOREACH table_name IN ARRAY ARRAY['finance_gl_settlement_scopes','finance_gl_settlement_reservations','finance_gl_settlement_source_parts',
   'finance_gl_settlement_clearings','finance_gl_settlement_reversals','finance_gl_settlement_operations'] LOOP
  EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_audit()',table_name||'_audit',table_name);
  EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER %I',table_name,table_name||'_audit');
  PERFORM fn_audit_track_table(table_name,'FULL','data_change',false,NULL,true,NULL);
 END LOOP;
END $$;

CREATE FUNCTION fn_finance_gl_settlement_lock_style(p_style uuid,p_dirty boolean DEFAULT true) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('finance-gl-settlement-style:'||p_style::text,0));
 IF to_regclass('pg_temp.finance_gl_settlement_dirty') IS NULL THEN
  CREATE TEMP TABLE finance_gl_settlement_dirty(style_id uuid PRIMARY KEY,generation bigint NOT NULL,checked_generation bigint NOT NULL DEFAULT -1) ON COMMIT DROP;
 END IF;
 INSERT INTO pg_temp.finance_gl_settlement_dirty(style_id,generation) VALUES(p_style,CASE WHEN p_dirty THEN 1 ELSE 0 END)
  ON CONFLICT(style_id) DO UPDATE SET generation=finance_gl_settlement_dirty.generation+CASE WHEN p_dirty THEN 1 ELSE 0 END;
END $$;
CREATE FUNCTION fn_finance_gl_settlement_scope_lock(p_id uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE style uuid;BEGIN
 SELECT style_id INTO style FROM finance_gl_settlement_scopes WHERE id=p_id;
 IF style IS NULL THEN RAISE EXCEPTION '清偿范围不存在' USING ERRCODE='23514';END IF;
 PERFORM fn_finance_gl_settlement_lock_style(style,false);
 PERFORM pg_advisory_xact_lock(hashtextextended('finance-gl-settlement:'||p_id::text,0));
END $$;
CREATE FUNCTION fn_finance_gl_settlement_floor() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s record;boundary record;local_net numeric;original_net numeric;pending_local numeric;pending_original numeric;
        styles uuid[];scope_ids uuid[];style uuid;dirty record;
BEGIN
 IF TG_TABLE_NAME='finance_gl_settlement_reservations' THEN
  scope_ids:=ARRAY[(to_jsonb(OLD)->>'scope_id')::uuid,(to_jsonb(NEW)->>'scope_id')::uuid];
 ELSIF TG_TABLE_NAME='gl_entries' THEN
  styles:=ARRAY[(to_jsonb(OLD)->>'style_id')::uuid,(to_jsonb(NEW)->>'style_id')::uuid];
 ELSIF TG_TABLE_NAME='finance_gl_entry_allocations' THEN
  SELECT array_agg(DISTINCT style_id) INTO styles FROM gl_entries WHERE id IN((to_jsonb(OLD)->>'entry_id')::uuid,(to_jsonb(NEW)->>'entry_id')::uuid);
 ELSE
  SELECT array_agg(DISTINCT style_id) INTO styles FROM gl_entries WHERE voucher_id=(COALESCE(to_jsonb(OLD),to_jsonb(NEW))->>'id')::uuid;
 END IF;
 IF scope_ids IS NOT NULL THEN
  SELECT array_agg(DISTINCT style_id) INTO styles FROM finance_gl_settlement_scopes WHERE id=ANY(scope_ids);
 END IF;
 FOR style IN SELECT DISTINCT value FROM unnest(styles) value WHERE value IS NOT NULL ORDER BY value LOOP
  PERFORM fn_finance_gl_settlement_lock_style(style,false);
  SELECT generation,checked_generation INTO dirty FROM pg_temp.finance_gl_settlement_dirty WHERE style_id=style;
  IF dirty.generation=dirty.checked_generation THEN CONTINUE;END IF;
  FOR s IN SELECT scope.* FROM finance_gl_settlement_scopes scope WHERE scope.style_id=style
    AND EXISTS(SELECT 1 FROM finance_gl_settlement_reservations r WHERE r.scope_id=scope.id AND r.status='RESERVED') ORDER BY scope.id LOOP
  PERFORM fn_finance_gl_settlement_scope_lock(s.id);
  FOR boundary IN SELECT DISTINCT as_of FROM finance_gl_settlement_reservations WHERE scope_id=s.id AND status='RESERVED'
    UNION SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date LOOP
   IF EXISTS(SELECT 1 FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id
       WHERE e.style_id=s.style_id AND NOT e.is_deleted AND NOT v.is_deleted AND fn_finance_gl_voucher_is_booked(v.id) AND e.entry_date<=boundary.as_of
       AND (NOT EXISTS(SELECT 1 FROM finance_gl_entry_allocations a WHERE a.entry_id=e.id)
         OR EXISTS(SELECT 1 FROM finance_gl_entry_allocations a WHERE a.entry_id=e.id
           AND (a.currency_id IS NULL OR (s.auxiliary_id IS NOT NULL AND a.auxiliary_id IS NULL)
             OR (a.auxiliary_id IS NOT DISTINCT FROM s.auxiliary_id AND a.currency_id=s.accounting_currency_id
               AND (a.original_currency_id IS NULL OR a.amount_original IS NULL
                 OR a.auxiliary_role IS DISTINCT FROM s.auxiliary_role OR a.party_id_snapshot IS DISTINCT FROM s.party_id_snapshot)))))) THEN
    RAISE EXCEPTION '清偿范围出现尚未明确的辅助或原币事实，请先核对原来源' USING ERRCODE='23514';
   END IF;
   SELECT COALESCE(sum(e.direction*a.amount_local*s.natural_direction),0),COALESCE(sum(e.direction*a.amount_original*s.natural_direction),0)
    INTO local_net,original_net FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id
    JOIN finance_gl_entry_allocations a ON a.entry_id=e.id
    WHERE e.style_id=s.style_id AND a.account_code=s.account_code AND a.auxiliary_id IS NOT DISTINCT FROM s.auxiliary_id
      AND a.currency_id=s.accounting_currency_id AND a.original_currency_id=s.original_currency_id
      AND NOT e.is_deleted AND NOT v.is_deleted AND fn_finance_gl_voucher_is_booked(v.id) AND e.entry_date<=boundary.as_of;
   SELECT COALESCE(sum(amount_local),0),COALESCE(sum(amount_original),0) INTO pending_local,pending_original
    FROM finance_gl_settlement_reservations WHERE scope_id=s.id AND status='RESERVED' AND as_of<=boundary.as_of;
   IF local_net<pending_local OR original_net<pending_original THEN
    RAISE EXCEPTION '实际总账余额不足以覆盖尚未完成的清偿预留，请先核对原清偿回执' USING ERRCODE='23514';
   END IF;
  END LOOP;
  END LOOP;
  UPDATE pg_temp.finance_gl_settlement_dirty SET checked_generation=generation WHERE style_id=style;
 END LOOP;
 RETURN NULL;
END $$;
CREATE FUNCTION fn_finance_gl_settlement_gl_lock() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE style uuid;BEGIN
 IF TG_TABLE_NAME='gl_entries' THEN
  FOR style IN SELECT DISTINCT value FROM unnest(ARRAY[(to_jsonb(OLD)->>'style_id')::uuid,(to_jsonb(NEW)->>'style_id')::uuid]) value WHERE value IS NOT NULL ORDER BY value LOOP
   PERFORM fn_finance_gl_settlement_lock_style(style);
  END LOOP;
 ELSIF TG_TABLE_NAME='finance_gl_entry_allocations' THEN
  FOR style IN SELECT DISTINCT e.style_id FROM gl_entries e WHERE e.id IN((to_jsonb(OLD)->>'entry_id')::uuid,(to_jsonb(NEW)->>'entry_id')::uuid) ORDER BY e.style_id LOOP
   PERFORM fn_finance_gl_settlement_lock_style(style);
  END LOOP;
 ELSE
  FOR style IN SELECT DISTINCT e.style_id FROM gl_entries e WHERE e.voucher_id=(COALESCE(to_jsonb(OLD),to_jsonb(NEW))->>'id')::uuid ORDER BY e.style_id LOOP
   PERFORM fn_finance_gl_settlement_lock_style(style);
  END LOOP;
 END IF;
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER finance_gl_settlement_entry_lock BEFORE INSERT OR UPDATE OR DELETE ON gl_entries FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_settlement_gl_lock();
CREATE TRIGGER finance_gl_settlement_allocation_lock BEFORE INSERT OR UPDATE OR DELETE ON finance_gl_entry_allocations FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_settlement_gl_lock();
CREATE TRIGGER finance_gl_settlement_voucher_lock BEFORE UPDATE OR DELETE ON gl_vouchers FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_settlement_gl_lock();
CREATE CONSTRAINT TRIGGER finance_gl_settlement_entries_floor AFTER INSERT OR UPDATE OR DELETE ON gl_entries DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_settlement_floor();
CREATE CONSTRAINT TRIGGER finance_gl_settlement_allocations_floor AFTER INSERT OR UPDATE OR DELETE ON finance_gl_entry_allocations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_settlement_floor();
CREATE CONSTRAINT TRIGGER finance_gl_settlement_vouchers_floor AFTER INSERT OR UPDATE OR DELETE ON gl_vouchers DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_settlement_floor();
CREATE CONSTRAINT TRIGGER finance_gl_settlement_reservations_floor AFTER INSERT OR UPDATE OR DELETE ON finance_gl_settlement_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_settlement_floor();
CREATE TRIGGER finance_payroll_payment_history BEFORE UPDATE OR DELETE ON finance_payroll_payment_attempts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_payroll_payment_history();

-- Publication/view timestamps remain editable; original salary contents after an
-- accounting accrual are immutable even when a later payment was reversed.
CREATE FUNCTION fn_guard_finance_payroll_accounted_source() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE batch uuid;old_fact jsonb:=to_jsonb(OLD);new_fact jsonb:=to_jsonb(NEW);source jsonb:=CASE WHEN TG_OP='INSERT' THEN to_jsonb(NEW) ELSE to_jsonb(OLD) END;
BEGIN
 IF TG_TABLE_NAME='payroll_batches' THEN batch:=(source->>'id')::uuid;
   old_fact:=old_fact-ARRAY['status','published_at','published_by','version','updated_at','updated_by'];
   new_fact:=new_fact-ARRAY['status','published_at','published_by','version','updated_at','updated_by'];
 ELSIF TG_TABLE_NAME='payroll_slips' THEN batch:=(source->>'batch_id')::uuid;
   old_fact:=old_fact-ARRAY['status','published_at','viewed_at','downloaded_at','version','updated_at','updated_by'];
   new_fact:=new_fact-ARRAY['status','published_at','viewed_at','downloaded_at','version','updated_at','updated_by'];
 ELSE SELECT batch_id INTO batch FROM payroll_slips WHERE id=(source->>'slip_id')::uuid;
   old_fact:=old_fact-ARRAY['updated_at','updated_by'];new_fact:=new_fact-ARRAY['updated_at','updated_by'];
 END IF;
 IF (EXISTS(SELECT 1 FROM finance_payroll_accruals WHERE batch_id=batch) OR EXISTS(SELECT 1 FROM finance_payroll_payment_attempts WHERE batch_id=batch AND state<>'REVERSED'))
    AND (TG_OP IN('INSERT','DELETE') OR old_fact IS DISTINCT FROM new_fact
      OR TG_TABLE_NAME='payroll_batches' AND (to_jsonb(NEW)->>'status') NOT IN('APPROVED','PUBLISHED')) THEN
   RAISE EXCEPTION '原工资已用于会计计提，不得覆盖应发、扣款、实发或来源身份' USING ERRCODE='23514';
 END IF;
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER finance_payroll_batch_source_guard BEFORE UPDATE OR DELETE ON payroll_batches
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_payroll_accounted_source();
CREATE TRIGGER finance_payroll_slip_source_guard BEFORE INSERT OR UPDATE OR DELETE ON payroll_slips
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_payroll_accounted_source();
CREATE TRIGGER finance_payroll_item_source_guard BEFORE INSERT OR UPDATE OR DELETE ON payroll_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_payroll_accounted_source();

DO $$ DECLARE definition text;BEGIN
 SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint WHERE conrelid='finance_reconciliations'::regclass
   AND conname='finance_reconciliations_source_doc_type_chk';
 IF definition IS NULL OR left(definition,7)<>'CHECK (' THEN RAISE EXCEPTION '资金来源约束锚点变化';END IF;
 EXECUTE 'ALTER TABLE finance_reconciliations DROP CONSTRAINT finance_reconciliations_source_doc_type_chk';
 EXECUTE 'ALTER TABLE finance_reconciliations ADD CONSTRAINT finance_reconciliations_source_doc_type_chk CHECK ('
   ||substring(definition FROM 8 FOR length(definition)-8)||' OR source_doc_type=''PAYROLL_PAYMENT'')';
END $$;
DO $$ DECLARE table_name text;BEGIN
 FOREACH table_name IN ARRAY ARRAY['finance_payroll_preparations','finance_payroll_accruals','finance_payroll_payment_attempts','finance_payroll_payment_actions'] LOOP
  EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_audit()',table_name||'_audit',table_name);
  EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER %I',table_name,table_name||'_audit');
  PERFORM fn_audit_track_table(table_name,'FULL','data_change',false,NULL,true,NULL);
 END LOOP;
END $$;

CREATE FUNCTION fn_guard_finance_gl_settlement_reservation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' OR (to_jsonb(NEW)-ARRAY['status','updated_at']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','updated_at'])
   OR NOT(OLD.status='RESERVED' AND NEW.status IN('COMMITTED','CANCELLED') OR OLD.status='COMMITTED' AND NEW.status='RELEASED') THEN
  RAISE EXCEPTION '清偿预留原事实不可覆盖，只能继续核对清偿或原反向事实' USING ERRCODE='23514';
 END IF;RETURN NEW;
END $$;
CREATE TRIGGER finance_gl_settlement_reservation_history BEFORE UPDATE OR DELETE ON finance_gl_settlement_reservations
 FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_gl_settlement_reservation();

CREATE FUNCTION fn_finance_gl_settlement_reservation_lock() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE style uuid;BEGIN
 FOR style IN SELECT DISTINCT s.style_id FROM finance_gl_settlement_scopes s
   WHERE s.id IN((to_jsonb(OLD)->>'scope_id')::uuid,(to_jsonb(NEW)->>'scope_id')::uuid) ORDER BY s.style_id LOOP
  PERFORM fn_finance_gl_settlement_lock_style(style);
 END LOOP;
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER finance_gl_settlement_reservation_lock BEFORE INSERT OR UPDATE OR DELETE ON finance_gl_settlement_reservations
 FOR EACH ROW EXECUTE FUNCTION fn_finance_gl_settlement_reservation_lock();

CREATE FUNCTION fn_guard_finance_gl_settlement_history() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE entry uuid;voucher uuid;used boolean;BEGIN
 IF TG_TABLE_NAME='gl_entries' THEN entry:=OLD.id;
 ELSE entry:=OLD.entry_id;END IF;
 SELECT EXISTS(SELECT 1 FROM finance_gl_settlement_source_parts WHERE entry_id=entry)
   OR EXISTS(SELECT 1 FROM finance_gl_settlement_clearings WHERE entry_id=entry OR source_entry_id=entry)
   OR EXISTS(SELECT 1 FROM finance_gl_settlement_reversals WHERE entry_id=entry OR original_entry_id=entry) INTO used;
 IF used THEN RAISE EXCEPTION '总账事实已用于清偿来源或历史，不能覆盖；须使用真实对称反向凭证' USING ERRCODE='23514';END IF;
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER finance_gl_settlement_entry_history BEFORE UPDATE OR DELETE ON gl_entries FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_gl_settlement_history();
CREATE TRIGGER finance_gl_settlement_allocation_history BEFORE UPDATE OR DELETE ON finance_gl_entry_allocations FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_gl_settlement_history();
CREATE FUNCTION fn_guard_finance_gl_settlement_source_voucher() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM gl_entries e JOIN finance_gl_settlement_source_parts p ON p.entry_id=e.id
     JOIN finance_gl_settlement_reservations r ON r.id=p.reservation_id
     WHERE e.voucher_id=OLD.id AND r.status IN('RESERVED','COMMITTED'))
    AND (TG_OP='DELETE' OR NEW.status IS DISTINCT FROM OLD.status OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted) THEN
  RAISE EXCEPTION '原GL来源仍有清偿预留或已清偿关联，须先按真实反向事实解除依赖' USING ERRCODE='23514';
 END IF;
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER finance_gl_settlement_source_voucher BEFORE UPDATE OR DELETE ON gl_vouchers FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_gl_settlement_source_voucher();
CREATE FUNCTION fn_check_finance_gl_settlement_clearing_voucher() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM finance_gl_settlement_clearings c JOIN gl_entries e ON e.id=c.entry_id
     JOIN gl_vouchers v ON v.id=e.voucher_id JOIN finance_gl_settlement_reservations r ON r.id=c.reservation_id
     WHERE e.voucher_id=(COALESCE(to_jsonb(NEW),to_jsonb(OLD))->>'id')::uuid
       AND (e.is_deleted OR v.is_deleted OR NOT fn_finance_gl_voucher_is_booked(v.id)
         OR (v.status=-1 AND (r.status<>'RELEASED' OR NOT EXISTS(SELECT 1 FROM finance_gl_settlement_reversals reversed
             JOIN gl_entries reverse_entry ON reverse_entry.id=reversed.entry_id
             WHERE reversed.reservation_id=c.reservation_id AND reversed.original_entry_id=c.entry_id
               AND reversed.original_allocation_no=c.allocation_no AND reverse_entry.voucher_id=v.reversed_by_voucher_id))))) THEN
  RAISE EXCEPTION '实际清偿已红冲，须同时核对原清偿反向GL回执，不能留下已清偿假状态' USING ERRCODE='23514';
 END IF;RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER finance_gl_settlement_clearing_voucher AFTER UPDATE OR DELETE ON gl_vouchers
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_finance_gl_settlement_clearing_voucher();

-- Cost attribution points at real GL lines; salary amounts are never copied into
-- a second cost ledger. Actual symmetric reversal chains keep their signed facts.
CREATE TABLE finance_payroll_accrual_lines (
 entry_id uuid PRIMARY KEY REFERENCES gl_entries(id),batch_id uuid NOT NULL REFERENCES finance_payroll_accruals(batch_id),
 payroll_slip_id uuid NOT NULL REFERENCES payroll_slips(id),employee_id uuid NOT NULL REFERENCES employees(id),
 department_id uuid REFERENCES departments(id),source_payroll_period char(7) NOT NULL,
 expense_style_id uuid NOT NULL REFERENCES payment_styles(id),created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
 amount_kind text NOT NULL DEFAULT 'GROSS' CHECK(amount_kind IN('GROSS','REDUCTION')),
 source_payroll_item_id uuid REFERENCES payroll_items(id),deduction_allocation_id uuid,
 CHECK((amount_kind='GROSS' AND source_payroll_item_id IS NULL AND deduction_allocation_id IS NULL)
    OR(amount_kind='REDUCTION' AND source_payroll_item_id IS NOT NULL AND deduction_allocation_id IS NOT NULL))
);
CREATE TRIGGER finance_payroll_accrual_line_immutable BEFORE UPDATE OR DELETE ON finance_payroll_accrual_lines
 FOR EACH ROW EXECUTE FUNCTION fn_reject_update_or_delete();
SELECT fn_audit_track_table('finance_payroll_accrual_lines','COLUMN_SCOPED','data_change',true,
 ARRAY['entry_id','batch_id','payroll_slip_id','employee_id','department_id','source_payroll_period','expense_style_id','amount_kind','source_payroll_item_id','deduction_allocation_id','created_by','created_at'],true,NULL);
CREATE VIEW v_finance_payroll_cost_facts AS
 WITH RECURSIVE facts AS (
  SELECT e.id AS gl_entry_id,e.voucher_id,l.employee_id,l.department_id,e.entry_date AS business_date,e.period::text AS period,
    l.source_payroll_period::text,fn_finance_manufacturing_occurrence(e.id) AS gross_cost_signed,
    (s.id IS NULL OR NOT s.active OR s.employee_id IS DISTINCT FROM l.employee_id OR s.department_id_snapshot IS DISTINCT FROM l.department_id
      OR e.style_id IS DISTINCT FROM l.expense_style_id OR e.direction<>1
      OR(l.amount_kind='GROSS' AND e.amount IS DISTINCT FROM s.gross_income)
      OR(l.amount_kind='REDUCTION' AND(item.id IS NULL OR item.slip_id<>s.id OR item.item_type<>'DEDUCTION'
        OR portion.style_id IS DISTINCT FROM e.style_id OR portion.amount IS NULL OR e.amount IS DISTINCT FROM -portion.amount))
      OR accrual.mode<>'NATIVE_APPROVED_PAYROLL' OR fn_finance_manufacturing_occurrence(e.id) IS NULL) AS pending,
    e.line_no,e.style_id,e.direction,e.amount,ARRAY[e.voucher_id] AS path
  FROM finance_payroll_accrual_lines l JOIN gl_entries e ON e.id=l.entry_id
  JOIN finance_payroll_accruals accrual ON accrual.batch_id=l.batch_id LEFT JOIN payroll_slips s ON s.id=l.payroll_slip_id
  LEFT JOIN payroll_items item ON item.id=l.source_payroll_item_id
  LEFT JOIN LATERAL(SELECT (part->>'amount')::numeric AS amount,(part->>'styleId')::uuid AS style_id
    FROM jsonb_array_elements(COALESCE(NULLIF(accrual.instruction_snapshot->'deductionAllocations'->l.source_payroll_item_id::text,'null'::jsonb),'[]'::jsonb)) part
    WHERE part->>'id'=l.deduction_allocation_id::text)portion ON true
  WHERE NOT e.is_deleted AND fn_finance_gl_voucher_is_booked(e.voucher_id)
  UNION ALL
  SELECT e.id,e.voucher_id,f.employee_id,f.department_id,e.entry_date,e.period::text,f.source_payroll_period,
    fn_finance_manufacturing_occurrence(e.id),(f.pending OR fn_finance_manufacturing_occurrence(e.id) IS NULL),
    e.line_no,e.style_id,e.direction,e.amount,f.path||e.voucher_id
  FROM facts f JOIN gl_vouchers v ON v.reversal_of_voucher_id=f.voucher_id
  JOIN gl_entries e ON e.voucher_id=v.id AND e.line_no=f.line_no
  WHERE NOT e.is_deleted AND fn_finance_gl_voucher_is_booked(v.id) AND NOT v.id=ANY(f.path)
 ) SELECT gl_entry_id,voucher_id,employee_id,department_id,business_date,period,source_payroll_period,gross_cost_signed,pending FROM facts;

-- General audit is a locator trail, not a second salary/source-document reader.
-- COLUMN_SCOPED traditionally restricted UPDATE only; the single row minimizer
-- below also applies its exact registered metadata keys to INSERT and DELETE.
DO $$ DECLARE spec record;BEGIN
 FOR spec IN SELECT * FROM (VALUES
  ('finance_payroll_preparations',ARRAY['application_id','batch_id','source_fingerprint','instruction_fingerprint','prepared_by','prepared_at']),
  ('finance_payroll_accruals',ARRAY['batch_id','application_id','source_fingerprint','instruction_fingerprint','mode','voucher_id','wage_style_id','created_at','created_by']),
  ('finance_payroll_payment_attempts',ARRAY['id','request_id','application_id','batch_id','source_fingerprint','instruction_fingerprint','account_id','payment_date','fee_style_id','payment_voucher_id','non_cash_voucher_id','receipt_kind','source_claim_only','account_flow_id','state','paid_at','paid_by','confirmed_at','confirmed_by','reversal_voucher_id','reversed_at','reversed_by']),
  ('finance_payroll_payment_actions',ARRAY['request_id','application_id','payment_request_id','action','actor_id','fingerprint','created_at']),
  ('finance_gl_settlement_scopes',ARRAY['id','style_id','account_code','auxiliary_id','auxiliary_role','party_id_snapshot','accounting_currency_id','original_currency_id','natural_direction']),
  ('finance_gl_settlement_reservations',ARRAY['id','request_id','scope_id','owner_kind','owner_id','actor_id','as_of','mode','fingerprint','status','created_at','updated_at']),
  ('finance_gl_settlement_source_parts',ARRAY['reservation_id','entry_id','allocation_no']),
  ('finance_gl_settlement_clearings',ARRAY['reservation_id','line_no','entry_id','allocation_no','source_entry_id','source_allocation_no']),
  ('finance_gl_settlement_reversals',ARRAY['reservation_id','line_no','entry_id','allocation_no','original_entry_id','original_allocation_no']),
  ('finance_gl_settlement_operations',ARRAY['request_id','actor_id','fingerprint','operation','created_at']),
  ('finance_template_sources',ARRAY['id','actor_id','template_key','period','sha256','storage_size','created_at'])
 ) AS rules(table_name,columns) LOOP
  PERFORM fn_audit_track_table(spec.table_name,'COLUMN_SCOPED','data_change',false,spec.columns,true,NULL);
 END LOOP;
END $$;

CREATE FUNCTION fn_finance_audit_metadata_columns(p_table_name text) RETURNS text[]
 LANGUAGE sql IMMUTABLE STRICT AS $$SELECT NULL::text[]$$;
CREATE FUNCTION fn_refresh_finance_audit_metadata_projection() RETURNS void
 LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE rule record;definition text:='SELECT CASE p_table_name ';
BEGIN
 -- Compile immutable projections from the existing registration. There is no
 -- policy-table query per business row and no second hand-maintained key list.
 FOR rule IN
  SELECT DISTINCT c.relname,args.values[3:cardinality(args.values)-1] AS columns
  FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
  CROSS JOIN LATERAL(SELECT string_to_array(encode(t.tgargs,'escape'),chr(92)||'000') AS values) args
  WHERE n.nspname='public' AND NOT t.tgisinternal AND t.tgfoid='public.fn_audit()'::regprocedure AND t.tgnargs>2
    AND (starts_with(c.relname,'finance_') OR c.relname IN('gl_entries','gl_vouchers','accounts','ar_ap_ledger'))
  ORDER BY c.relname
 LOOP
  definition:=definition||format('WHEN %L THEN %L::text[] ',rule.relname,rule.columns::text);
 END LOOP;
 definition:=definition||'ELSE NULL::text[] END';
 EXECUTE 'CREATE OR REPLACE FUNCTION public.fn_finance_audit_metadata_columns(p_table_name text) RETURNS text[] '
   ||'LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog,public AS '||quote_literal(definition);
END $$;
REVOKE ALL ON FUNCTION fn_refresh_finance_audit_metadata_projection() FROM PUBLIC;
SELECT fn_refresh_finance_audit_metadata_projection();

DO $private_financial_audit$
DECLARE definition text;anchor text:='RETURN v_row;';projection text;
BEGIN
 SELECT pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure) INTO definition;
 IF strpos(definition,'finance_source_payload_guard_v1')=0 THEN
  IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
   RAISE EXCEPTION 'Financial audit row minimizer anchor changed; source contents must not be exposed';
  END IF;
  projection:=$project$
    -- finance_source_payload_guard_v1: private source contents never enter general audit.
    IF p_table_name='gl_entries' AND (p_row->>'source_doc_type'='FINANCIAL_SOURCE' OR p_row->>'source_doc_type' LIKE 'PAYROLL\_%') THEN
        v_row:=v_row-ARRAY['amount','summary','source_bill_no'];
    ELSIF p_table_name='finance_gl_entry_allocations' THEN
        v_row:=v_row-ARRAY['amount_local','amount_original','exchange_rate','source_snapshot','source_account_name','source_account_path_name',
            'source_name','source_code','source_system','source_entry_id'];
    ELSIF p_table_name='finance_reconciliations' AND p_row->>'source_doc_type'='PAYROLL_PAYMENT' THEN
        v_row:=v_row-ARRAY['in_amount','out_amount','amount_local','check_no','counterpart_name','source_remark'];
    END IF;
    IF public.fn_finance_audit_metadata_columns(p_table_name) IS NOT NULL THEN
        SELECT COALESCE(jsonb_object_agg(key,value),'{}'::jsonb) INTO v_row FROM jsonb_each(v_row)
          WHERE key=ANY(public.fn_finance_audit_metadata_columns(p_table_name));
    ELSIF starts_with(p_table_name,'finance_payroll_') OR starts_with(p_table_name,'finance_gl_settlement_')
       OR p_table_name IN('finance_chart_imports','finance_chart_codes','finance_chart_code_styles','finance_chart_owned_bindings',
          'finance_chart_manual_operations','finance_accounting_import_batches','finance_accounting_review_operations',
          'finance_gl_voucher_evidence','finance_gl_auxiliary_opening_evidence','finance_gl_opening_baselines','finance_accounting_period_coverage',
          'finance_template_sources') THEN
        SELECT COALESCE(jsonb_object_agg(key,value),'{}'::jsonb) INTO v_row FROM jsonb_each(v_row)
          WHERE key=ANY(ARRAY['id','code','request_id','actor_id','actor_user_id','application_id','payment_id','batch_id','entry_id','allocation_no',
            'voucher_id','import_batch_id','source_import_id','style_id','native_style_id','line_key','account_code','auxiliary_id','auxiliary_role','party_id_snapshot',
            'currency_id','original_currency_id','kind','source_kind','source_id','status','state','operation','action','purpose','period','effective_from',
            'sha256','source_sha256','fingerprint','payload_hash','mapping_fingerprint','source_fingerprint','instruction_fingerprint','row_version','version',
            'created_at','created_by','updated_at','updated_by','submitted_at','submitted_by','approved_at','approved_by','verified_at','verified_by']);
    END IF;
    RETURN v_row;
$project$;
  EXECUTE replace(definition,anchor,projection);
 END IF;
END;
$private_financial_audit$;

-- Later financial registrations refresh the same compiled projection automatically.
DO $single_financial_audit_registration$
DECLARE definition text;reversed_anchor integer;begin_at integer;
BEGIN
 SELECT pg_get_functiondef('public.fn_audit_track_table(text,text,text,boolean,text[],boolean,text)'::regprocedure) INTO definition;
 IF strpos(definition,'fn_refresh_finance_audit_metadata_projection')=0 THEN
  reversed_anchor:=strpos(reverse(definition),';DNE');
  IF reversed_anchor=0 THEN RAISE EXCEPTION 'Canonical audit registration anchor changed';END IF;
  begin_at:=length(definition)-reversed_anchor-2;
  definition:=left(definition,begin_at-1)||E'\nIF p_policy=''COLUMN_SCOPED'' AND (starts_with(p_table,''finance_'') OR p_table IN(''gl_entries'',''gl_vouchers'',''accounts'',''ar_ap_ledger'')) THEN\n PERFORM public.fn_refresh_finance_audit_metadata_projection();\nEND IF;\n'||substring(definition FROM begin_at);
  EXECUTE definition;
 END IF;
END;
$single_financial_audit_registration$;
