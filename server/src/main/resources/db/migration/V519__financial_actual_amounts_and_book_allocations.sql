-- Actual inputs retain 24 fractional digits; derived book amounts retain 30.
-- V510 owns the dependency/owner/ACL preserving NUMERIC migration helper.
DO $$
DECLARE definition TEXT;needle TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF position('(''sales_shipment_submission_events'', ''CLEAR'')' IN definition)=0 THEN
        IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1
          OR to_regclass('public.sales_shipment_submission_events') IS NULL THEN
          RAISE EXCEPTION 'V515 cannot safely register sales shipment submission event reset policy';
        END IF;
        EXECUTE replace(definition,needle,needle||', (''sales_shipment_submission_events'', ''CLEAR'')');
    END IF;
END $$;

DO $$
DECLARE v_targets JSONB;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('table',c.relname,'column',a.attname,
        'kind',CASE WHEN a.attname LIKE '%local%' OR a.attname IN
            ('amount','amount_balance','amount_settled','exchange_diff','exchange_difference','bank_fee','other_fee')
            THEN 'book' ELSE 'actual' END) ORDER BY c.relname,a.attnum)
    INTO v_targets FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
    WHERE n.nspname='public' AND c.relkind='r' AND a.atttypid='numeric'::regtype
      AND c.relname=ANY(ARRAY['accounts','account_balance_adjustment_items','account_flow_monthly_summaries',
        'ar_ap_ledger','ar_ap_source_refs','customer_open_item_offsets',
        'finance_receipts','finance_receipt_lines','finance_receipt_source_allocations',
        'finance_payments','finance_payment_lines','finance_reconciliations','gl_entries',
        'finance_bank_transfers','finance_bank_transfer_lines','finance_expenses','finance_expense_lines',
        'finance_other_incomes','finance_other_income_lines','supplier_open_item_offsets',
        'supplier_settlement_batches','supplier_settlement_lines',
        'sales_orders','sales_order_items','sales_shipments','sales_shipment_items','sales_returns','sales_return_items',
        'purchase_returns','purchase_return_items','subcontract_returns','subcontract_return_items'])
      AND (a.attname LIKE '%amount%' OR a.attname LIKE '%balance%' OR a.attname LIKE '%original%'
        OR a.attname LIKE '%local%' OR a.attname IN ('receipts_total','payments_total','bank_fee','other_fee',
          'exchange_diff','exchange_difference','write_off_amount','price','unit_price'))
      AND a.attname NOT LIKE '%rate%';
    PERFORM fn_migrate_financial_amount_columns(v_targets);
END $$;

-- Internal declarations and casts must not reduce the widened column values.
-- Preserve each currently installed function, including V511 DIRECT_CUSTOMER branches.
DO $$
DECLARE v_function RECORD; v_definition TEXT;
BEGIN
    FOR v_function IN SELECT p.oid,pg_get_functiondef(p.oid) definition FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f'
        AND (p.proname LIKE '%receipt%' OR p.proname LIKE '%payment%' OR p.proname LIKE '%supplier%'
          OR p.proname LIKE '%customer_offset%' OR p.proname LIKE '%customer_open_item%'
          OR p.proname LIKE '%ar_source_ref%' OR p.proname LIKE '%account_flow%'
          OR p.proname LIKE '%ar_ap%' OR p.proname LIKE '%gl_%')
    LOOP
        v_definition:=regexp_replace(v_function.definition,'numeric\s*\(\s*[0-9]+\s*,\s*4\s*\)','numeric','gi');
        IF v_definition<>v_function.definition THEN EXECUTE v_definition; END IF;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION fn_financial_book_part(p_amount NUMERIC,p_before_original NUMERIC,p_before_local NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
    IF p_amount<0 OR p_before_original<=0 OR p_amount>p_before_original OR p_before_local<0 THEN
        RAISE EXCEPTION 'invalid finite book allocation basis' USING ERRCODE='23514';
    END IF;
    IF p_amount=p_before_original THEN RETURN p_before_local; END IF;
    -- div is an exact integer quotient. Normal numeric division may round before truncation.
    RETURN div(p_before_local*p_amount*1e30::numeric,p_before_original)*1e-30::numeric;
END $$;

-- Every ordinary return line keeps its own receipt/AP attribution. A partially
-- consumed multi-source legacy credit with no matching source offset needs reconciliation.
CREATE OR REPLACE FUNCTION fn_procurement_source_credit_parts(p_source UUID)
RETURNS TABLE(credit_ledger_id UUID,amount_original NUMERIC,amount_local NUMERIC,
    reserved_original NUMERIC,reserved_local NUMERIC)
LANGUAGE plpgsql AS $$
DECLARE v_source ar_ap_ledger%ROWTYPE; v_row RECORD; v_used RECORD;
BEGIN
    SELECT * INTO v_source FROM ar_ap_ledger WHERE id=p_source;
    FOR v_row IN
      WITH attributed AS (
        SELECT ledger.id,ledger.amount_original ledger_original,ledger.amount_original_local ledger_local,
          ledger.amount_balance_original balance_original,ledger.amount_balance balance_local,
          document.amount_original original,document.amount_local local
        FROM procurement_iqc_credit_documents document JOIN ar_ap_ledger ledger
          ON ledger.source_doc_id=document.id AND ledger.source_doc_type IN ('PURCHASE_IQC_CREDIT','SUBCONTRACT_IQC_CREDIT')
          AND ledger.direction='AP' AND ledger.status=1 AND NOT ledger.is_deleted
        WHERE document.source_ap_ledger_id=p_source
        UNION ALL
        SELECT ledger.id,ledger.amount_original,ledger.amount_original_local,ledger.amount_balance_original,ledger.amount_balance,
          abs(ledger.amount_original),abs(ledger.amount_original_local)
        FROM procurement_iqc_rejection_cases rejection JOIN ar_ap_ledger ledger
          ON ledger.id=rejection.credit_ledger_id AND ledger.source_doc_id=rejection.id
          AND ledger.status=1 AND NOT ledger.is_deleted
        WHERE rejection.source_ap_ledger_id=p_source
        UNION ALL
        SELECT ledger.id,ledger.amount_original,ledger.amount_original_local,ledger.amount_balance_original,ledger.amount_balance,
          sum(item.amount_original),sum(item.amount_local)
        FROM purchase_return_items item JOIN purchase_receipt_items receipt_item ON receipt_item.id=item.receipt_item_id
        JOIN purchase_returns document ON document.id=item.return_id AND document.status=1 AND NOT document.is_deleted
        JOIN ar_ap_ledger ledger ON ledger.source_doc_id=document.id AND ledger.source_doc_type='PURCHASE_RETURN'
          AND ledger.direction='AP' AND ledger.status=1 AND NOT ledger.is_deleted
        WHERE v_source.source_doc_type='PURCHASE_RECEIPT' AND receipt_item.receipt_id=v_source.source_doc_id
          AND NOT item.is_deleted GROUP BY ledger.id
        UNION ALL
        SELECT ledger.id,ledger.amount_original,ledger.amount_original_local,ledger.amount_balance_original,ledger.amount_balance,
          sum(item.amount_original),sum(item.amount_local)
        FROM subcontract_return_items item JOIN subcontract_receipt_items receipt_item ON receipt_item.id=item.receipt_item_id
        JOIN subcontract_returns document ON document.id=item.return_id AND document.status=1 AND NOT document.is_deleted
        JOIN ar_ap_ledger ledger ON ledger.source_doc_id=document.id AND ledger.source_doc_type='SUBCONTRACT_RETURN'
          AND ledger.direction='AP' AND ledger.status=1 AND NOT ledger.is_deleted
        WHERE v_source.source_doc_type='SUBCONTRACT_RECEIPT' AND receipt_item.receipt_id=v_source.source_doc_id
          AND NOT item.is_deleted GROUP BY ledger.id
      ) SELECT * FROM attributed ORDER BY id
    LOOP
      IF v_row.ledger_original>=0 OR v_row.ledger_local>0 OR v_row.balance_original IS NULL
        OR v_row.balance_original>0 OR v_row.balance_local>0 OR v_row.original<0 OR v_row.local<0 THEN
        RAISE EXCEPTION 'source credit has unmapped or invalid actual/book balances' USING ERRCODE='23514';
      END IF;
      credit_ledger_id:=v_row.id;amount_original:=v_row.original;amount_local:=v_row.local;
      IF v_row.original=abs(v_row.ledger_original) AND v_row.local=abs(v_row.ledger_local) THEN
        reserved_original:=abs(v_row.balance_original);reserved_local:=abs(v_row.balance_local);
      ELSIF v_row.balance_original=0 AND v_row.balance_local=0 THEN
        reserved_original:=0;reserved_local:=0;
      ELSE
        SELECT COALESCE(sum(o.amount_original),0) original,COALESCE(sum(o.source_amount_local),0) local,
          COALESCE(sum(o.amount_original) FILTER(WHERE target_ledger_id=p_source),0) source_original,
          COALESCE(sum(o.source_amount_local) FILTER(WHERE target_ledger_id=p_source),0) source_local
        INTO v_used FROM supplier_open_item_offsets o WHERE o.source_ledger_id=v_row.id AND o.status='APPLIED';
        IF v_used.original<>abs(v_row.ledger_original)-abs(v_row.balance_original)
          OR v_used.local<>abs(v_row.ledger_local)-abs(v_row.balance_local)
          OR v_used.source_original>v_row.original OR v_used.source_local>v_row.local THEN
          RAISE EXCEPTION 'multi-source credit requires explicit source reconciliation' USING ERRCODE='23514';
        END IF;
        reserved_original:=v_row.original-v_used.source_original;reserved_local:=v_row.local-v_used.source_local;
      END IF;
      RETURN NEXT;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION fn_plan_procurement_credit_book(p_source UUID,p_actual NUMERIC)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE s ar_ap_ledger%ROWTYPE; c RECORD; prior_a NUMERIC:=0;prior_b NUMERIC:=0;
    unpaid_a NUMERIC;unpaid_b NUMERIC;available_a NUMERIC;available_b NUMERIC;
    remaining_a NUMERIC;remaining_b NUMERIC;offset_a NUMERIC;offset_b NUMERIC;
    credit_a NUMERIC;credit_b NUMERIC;paid_a NUMERIC;paid_b NUMERIC;reserve_a NUMERIC;reserve_b NUMERIC;
    basis JSONB:='[]'::jsonb;
BEGIN
    SELECT * INTO s FROM ar_ap_ledger WHERE id=p_source FOR UPDATE;
    IF NOT FOUND OR s.direction<>'AP' OR s.status<>1 OR s.is_deleted OR s.open_item_kind<>'PAYABLE'
      OR s.source_doc_type NOT IN('PURCHASE_RECEIPT','SUBCONTRACT_RECEIPT')
      OR s.amount_original<=0 OR s.amount_original_local<0 OR s.amount_balance_original IS NULL
      OR s.amount_balance_original<0 OR s.amount_balance<0
      OR NOT fn_financial_amount_is_exact(p_actual) OR p_actual<=0 THEN
      RAISE EXCEPTION 'actual credit requires verified original payable balances' USING ERRCODE='23514';
    END IF;
    unpaid_a:=s.amount_balance_original;unpaid_b:=s.amount_balance;
    available_a:=unpaid_a;available_b:=unpaid_b;
    FOR c IN SELECT * FROM fn_procurement_source_credit_parts(p_source) LOOP
      prior_a:=prior_a+c.amount_original;prior_b:=prior_b+c.amount_local;
      reserve_a:=least(available_a,c.reserved_original);
      reserve_b:=CASE WHEN reserve_a=0 THEN 0 ELSE fn_financial_book_part(reserve_a,c.reserved_original,c.reserved_local) END;
      IF reserve_b>available_b THEN
        RAISE EXCEPTION 'existing source credit reservation exceeds unpaid book balance' USING ERRCODE='23514';
      END IF;
      available_a:=available_a-reserve_a;available_b:=available_b-reserve_b;
    END LOOP;
    remaining_a:=s.amount_original-prior_a;remaining_b:=s.amount_original_local-prior_b;
    paid_a:=remaining_a-available_a;paid_b:=remaining_b-available_b;
    IF p_actual>remaining_a OR remaining_b<0 OR paid_a<0 OR paid_b<0
      OR (available_a=0 AND available_b<>0) OR (paid_a=0 AND paid_b<>0) THEN
      RAISE EXCEPTION 'source actual/book entitlement needs reconciliation or credit exceeds remaining source' USING ERRCODE='23514';
    END IF;
    offset_a:=least(p_actual,available_a);
    offset_b:=CASE WHEN offset_a=0 THEN 0 ELSE fn_financial_book_part(offset_a,available_a,available_b) END;
    credit_a:=p_actual-offset_a;
    credit_b:=CASE WHEN credit_a=0 THEN 0 ELSE fn_financial_book_part(credit_a,paid_a,paid_b) END;
    IF offset_a>0 THEN basis:=basis||jsonb_build_array(jsonb_build_object(
      'sourceKind','UNPAID_AP','sourceId',p_source,'sourceAmountOriginal',s.amount_original,'sourceAmountLocal',s.amount_original_local,
      'beforeOriginal',available_a,'beforeLocal',available_b,'allocatedOriginal',offset_a,'allocatedLocal',offset_b,
      'afterOriginal',available_a-offset_a,'afterLocal',available_b-offset_b)); END IF;
    IF credit_a>0 THEN basis:=basis||jsonb_build_array(jsonb_build_object(
      'sourceKind','SETTLED_SOURCE','sourceId',p_source,'sourceAmountOriginal',s.amount_original,'sourceAmountLocal',s.amount_original_local,
      'beforeOriginal',paid_a,'beforeLocal',paid_b,'allocatedOriginal',credit_a,'allocatedLocal',credit_b,
      'afterOriginal',paid_a-credit_a,'afterLocal',paid_b-credit_b)); END IF;
    RETURN jsonb_build_object('sourceApLedgerId',p_source,'amountOriginal',p_actual,'amountLocal',offset_b+credit_b,
      'offsetOriginal',offset_a,'offsetLocal',offset_b,'creditRemainingOriginal',credit_a,'creditRemainingLocal',credit_b,
      'sourceBeforeOriginal',unpaid_a,'sourceBeforeLocal',unpaid_b,
      'sourceAfterOriginal',unpaid_a-offset_a,'sourceAfterLocal',unpaid_b-offset_b,'basis',basis);
END $$;

CREATE OR REPLACE FUNCTION fn_guard_procurement_credit_book_plan_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.book_allocation_plan IS DISTINCT FROM fn_plan_procurement_credit_book(NEW.source_ap_ledger_id,NEW.amount_original)
      OR NEW.amount_local IS DISTINCT FROM (NEW.book_allocation_plan->>'amountLocal')::numeric THEN
      RAISE EXCEPTION 'credit document book plan is stale or differs from its exact source' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_procurement_credit_book_plan_insert BEFORE INSERT ON procurement_iqc_credit_documents
FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_credit_book_plan_insert();

-- A valid finite original balance can have zero book value (historical precision).
ALTER TABLE supplier_open_item_offsets DROP CONSTRAINT supplier_open_item_offsets_source_amount_local_check;
ALTER TABLE supplier_open_item_offsets DROP CONSTRAINT supplier_open_item_offsets_target_amount_local_check;
ALTER TABLE supplier_open_item_offsets ADD CONSTRAINT supplier_open_item_offsets_source_amount_local_check CHECK(source_amount_local>=0);
ALTER TABLE supplier_open_item_offsets ADD CONSTRAINT supplier_open_item_offsets_target_amount_local_check CHECK(target_amount_local>=0);

CREATE OR REPLACE FUNCTION fn_apply_procurement_credit_book_offset(p_case UUID,p_document UUID,p_ledger UUID,
    p_plan JSONB,p_date DATE,p_reason TEXT)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE d procurement_iqc_credit_documents%ROWTYPE;s ar_ap_ledger%ROWTYPE;c ar_ap_ledger%ROWTYPE;
    a NUMERIC;b NUMERIC;result UUID;actor UUID;
BEGIN
    SELECT * INTO d FROM procurement_iqc_credit_documents WHERE id=p_document;
    IF NOT FOUND OR d.case_id<>p_case OR d.effective_date<>p_date OR d.book_allocation_plan IS DISTINCT FROM p_plan
      OR nullif(btrim(p_reason),'') IS NULL THEN
      RAISE EXCEPTION 'offset must consume its confirmed source book plan' USING ERRCODE='23514';
    END IF;
    PERFORM id FROM ar_ap_ledger WHERE id IN(d.source_ap_ledger_id,p_ledger) ORDER BY id FOR UPDATE;
    SELECT * INTO s FROM ar_ap_ledger WHERE id=d.source_ap_ledger_id;
    SELECT * INTO c FROM ar_ap_ledger WHERE id=p_ledger;
    IF c.id IS NULL OR c.source_doc_id<>p_document OR c.direction<>'AP' OR c.status<>1 OR c.is_deleted
      OR c.supplier_id IS DISTINCT FROM s.supplier_id OR c.currency_id IS DISTINCT FROM s.currency_id
      OR c.amount_original<>-d.amount_original OR c.amount_original_local<>-d.amount_local THEN
      RAISE EXCEPTION 'credit ledger differs from confirmed document' USING ERRCODE='23514';
    END IF;
    SELECT id INTO result FROM supplier_open_item_offsets WHERE offset_batch_id=p_document AND status='APPLIED';
    IF FOUND THEN PERFORM fn_assert_procurement_credit_book_plan(p_document);RETURN result; END IF;
    a:=(p_plan->>'offsetOriginal')::numeric;b:=(p_plan->>'offsetLocal')::numeric;
    IF (s.amount_balance_original,s.amount_balance) IS DISTINCT FROM
       ((p_plan->>'sourceBeforeOriginal')::numeric,(p_plan->>'sourceBeforeLocal')::numeric)
       OR (c.amount_balance_original,c.amount_balance) IS DISTINCT FROM (-d.amount_original,-d.amount_local) THEN
      RAISE EXCEPTION 'credit source was consumed after plan confirmation' USING ERRCODE='23514';
    END IF;
    IF a=0 THEN RETURN NULL; END IF;
    IF NOT fn_procurement_iqc_slice_offset_authorized(p_case,p_ledger,s.id) THEN
      RAISE EXCEPTION 'credit plan is not authorized for this IQC source' USING ERRCODE='23514';
    END IF;
    PERFORM set_config('app.iqc_offset_case_id',p_case::text,TRUE);
    actor:=nullif(current_setting('app.actor_id',TRUE),'')::uuid;
    UPDATE ar_ap_ledger SET amount_offset_original=amount_offset_original+a,amount_offset_local=amount_offset_local+b,
      amount_balance_original=amount_balance_original-a,amount_balance=amount_balance-b,
      is_settled=(amount_balance_original=a AND amount_balance=b),
      settled_date=CASE WHEN amount_balance_original=a AND amount_balance=b THEN p_date ELSE NULL END,updated_at=now()
      WHERE id=s.id;
    UPDATE ar_ap_ledger SET amount_offset_original=amount_offset_original-a,amount_offset_local=amount_offset_local-b,
      amount_balance_original=amount_balance_original+a,amount_balance=amount_balance+b,
      is_settled=(amount_balance_original=-a AND amount_balance=-b),
      settled_date=CASE WHEN amount_balance_original=-a AND amount_balance=-b THEN p_date ELSE NULL END,updated_at=now()
      WHERE id=c.id;
    result:=gen_random_uuid();
    INSERT INTO supplier_open_item_offsets(id,supplier_id,currency_id,source_ledger_id,target_ledger_id,
      offset_batch_id,line_sequence,amount_original,source_amount_local,target_amount_local,
      source_balance_before_original,source_balance_after_original,target_balance_before_original,target_balance_after_original,
      effective_date,status,reason,applied_by,source_rate,target_rate,created_by,updated_by)
    VALUES(result,s.supplier_id,s.currency_id,c.id,s.id,p_document,1,a,b,b,
      -d.amount_original,-(p_plan->>'creditRemainingOriginal')::numeric,
      s.amount_balance_original,(p_plan->>'sourceAfterOriginal')::numeric,p_date,'APPLIED',p_reason,actor,c.exchange_rate,s.exchange_rate,actor,actor);
    RETURN result;
END $$;

CREATE OR REPLACE FUNCTION fn_assert_procurement_credit_book_plan(p_document UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE d procurement_iqc_credit_documents%ROWTYPE;p JSONB;v RECORD;b JSONB;
    allocated_a NUMERIC:=0;allocated_b NUMERIC:=0;live BOOLEAN;
BEGIN
    SELECT * INTO d FROM procurement_iqc_credit_documents WHERE id=p_document;
    IF NOT FOUND THEN RETURN; END IF;p:=d.book_allocation_plan;
    IF d.amount_original<>(p->>'offsetOriginal')::numeric+(p->>'creditRemainingOriginal')::numeric
      OR d.amount_local<>(p->>'offsetLocal')::numeric+(p->>'creditRemainingLocal')::numeric
      OR (p->>'sourceAfterOriginal')::numeric<>(p->>'sourceBeforeOriginal')::numeric-(p->>'offsetOriginal')::numeric
      OR (p->>'sourceAfterLocal')::numeric<>(p->>'sourceBeforeLocal')::numeric-(p->>'offsetLocal')::numeric THEN
      RAISE EXCEPTION 'source book plan does not conserve its original and local balances' USING ERRCODE='23514';
    END IF;
    FOR b IN SELECT value FROM jsonb_array_elements(p->'basis') LOOP
      IF (b->>'sourceId')::uuid<>d.source_ap_ledger_id
        OR (b->>'allocatedLocal')::numeric<>fn_financial_book_part((b->>'allocatedOriginal')::numeric,(b->>'beforeOriginal')::numeric,(b->>'beforeLocal')::numeric)
        OR (b->>'afterOriginal')::numeric<>(b->>'beforeOriginal')::numeric-(b->>'allocatedOriginal')::numeric
        OR (b->>'afterLocal')::numeric<>(b->>'beforeLocal')::numeric-(b->>'allocatedLocal')::numeric THEN
        RAISE EXCEPTION 'book allocation loses its exact source ratio or remainder' USING ERRCODE='23514';
      END IF;
      allocated_a:=allocated_a+(b->>'allocatedOriginal')::numeric;allocated_b:=allocated_b+(b->>'allocatedLocal')::numeric;
    END LOOP;
    IF allocated_a<>d.amount_original OR allocated_b<>d.amount_local THEN
      RAISE EXCEPTION 'book basis total differs from confirmed credit' USING ERRCODE='23514';
    END IF;
    SELECT EXISTS(SELECT 1 FROM procurement_iqc_credit_slices slice WHERE slice.credit_document_id=p_document
      AND fn_procurement_consideration_active('CREDIT',slice.id)) INTO live;
    SELECT count(*) n,COALESCE(sum(o.amount_original),0) a,COALESCE(sum(o.source_amount_local),0) sb,
      COALESCE(sum(o.target_amount_local),0) tb,
      COALESCE(bool_and(o.target_ledger_id=d.source_ap_ledger_id AND l.source_doc_id=p_document),TRUE) identity_matches
    INTO v FROM supplier_open_item_offsets o JOIN ar_ap_ledger l ON l.id=o.source_ledger_id
      WHERE o.offset_batch_id=p_document AND o.status='APPLIED';
    IF (live AND (v.a<>(p->>'offsetOriginal')::numeric OR v.sb<>(p->>'offsetLocal')::numeric OR v.tb<>v.sb
      OR NOT v.identity_matches OR v.n<>CASE WHEN v.a=0 THEN 0 ELSE 1 END)) OR (NOT live AND v.n<>0) THEN
      RAISE EXCEPTION 'both sides must consume the one frozen book allocation' USING ERRCODE='23514';
    END IF;
    SELECT sum(parts.amount_original) a,sum(parts.amount_local) b INTO v FROM fn_procurement_source_credit_parts(d.source_ap_ledger_id) parts;
    IF EXISTS(SELECT 1 FROM ar_ap_ledger source WHERE source.id=d.source_ap_ledger_id
      AND (v.a>source.amount_original OR v.b>source.amount_original_local)) THEN
      RAISE EXCEPTION 'active credits exceed the original source actual or book value' USING ERRCODE='23514';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION fn_guard_procurement_credit_book_plan_terminal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE document_id UUID;
BEGIN
    IF TG_TABLE_NAME='procurement_iqc_credit_documents' THEN document_id:=COALESCE(NEW.id,OLD.id);
    ELSIF TG_TABLE_NAME='supplier_open_item_offsets' THEN document_id:=COALESCE(NEW.offset_batch_id,OLD.offset_batch_id);
    ELSE document_id:=COALESCE(NEW.credit_document_id,OLD.credit_document_id); END IF;
    PERFORM fn_assert_procurement_credit_book_plan(document_id);RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_credit_book_document_terminal AFTER INSERT OR UPDATE ON procurement_iqc_credit_documents
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_credit_book_plan_terminal();
CREATE CONSTRAINT TRIGGER trg_credit_book_offset_terminal AFTER INSERT OR UPDATE OR DELETE ON supplier_open_item_offsets
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_credit_book_plan_terminal();
CREATE CONSTRAINT TRIGGER trg_credit_book_slice_terminal AFTER INSERT OR UPDATE OR DELETE ON procurement_iqc_credit_slices
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_credit_book_plan_terminal();
ALTER TABLE procurement_iqc_credit_documents ENABLE ALWAYS TRIGGER trg_procurement_credit_book_plan_insert;
ALTER TABLE procurement_iqc_credit_documents ENABLE ALWAYS TRIGGER trg_credit_book_document_terminal;
ALTER TABLE supplier_open_item_offsets ENABLE ALWAYS TRIGGER trg_credit_book_offset_terminal;
ALTER TABLE procurement_iqc_credit_slices ENABLE ALWAYS TRIGGER trg_credit_book_slice_terminal;
