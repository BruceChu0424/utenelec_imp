-- Finance chooses STILL_OWED/RELEASED for each actual document. No automatic rounding or bank cash.
DO $$ DECLARE definition text;BEGIN
 SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint WHERE conrelid='ar_ap_ledger'::regclass AND conname='ar_ap_ledger_source_doc_type_chk';
 IF definition IS NULL OR left(definition,7)<>'CHECK (' THEN RAISE EXCEPTION 'Review payable source type contract before extending document credits';END IF;
 ALTER TABLE ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_source_doc_type_chk;
 EXECUTE 'ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_source_doc_type_chk CHECK ('||substring(definition FROM 8 FOR length(definition)-8)||' OR source_doc_type=''PAYABLE_STATEMENT_CREDIT'')';
END $$;
CREATE TABLE finance_payable_statement_adjustments (
 id uuid PRIMARY KEY,request_id uuid NOT NULL UNIQUE,payload_hash text NOT NULL CHECK(payload_hash~'^[0-9a-f]{64}$'),
 statement_review_id uuid NOT NULL REFERENCES finance_statement_document_reviews(id),
 source_fingerprint text NOT NULL CHECK(source_fingerprint~'^[0-9a-f]{64}$'),document_sha256 text NOT NULL,
 supplier_id uuid NOT NULL REFERENCES suppliers(id),currency_id uuid NOT NULL REFERENCES currencies(id),
 effective_date date NOT NULL,period_amount_original numeric NOT NULL CHECK(fn_financial_amount_is_exact(period_amount_original)),
 released_original numeric NOT NULL CHECK(released_original>=0 AND fn_financial_amount_is_exact(released_original)),
 released_local numeric NOT NULL CHECK(released_local>=0 AND fn_financial_book_amount_is_exact(released_local)),
 plan_hash text NOT NULL CHECK(plan_hash~'^[0-9a-f]{64}$'),plan jsonb NOT NULL,precision_choices jsonb NOT NULL,
 source_reference text NOT NULL CHECK(length(trim(source_reference)) BETWEEN 1 AND 2000),
 status text NOT NULL DEFAULT 'DRAFT' CHECK(status IN('DRAFT','APPROVED','REVERSED')),
 created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
 approved_by uuid REFERENCES users(id),approved_at timestamptz,reversed_by uuid REFERENCES users(id),reversed_at timestamptz,reverse_reason text,
 CHECK(approved_by IS NULL OR approved_by<>created_by),
 CHECK((status<>'DRAFT')=(approved_by IS NOT NULL AND approved_at IS NOT NULL)),
 CHECK((status='REVERSED')=(reversed_by IS NOT NULL AND reversed_at IS NOT NULL AND length(trim(reverse_reason)) BETWEEN 1 AND 2000))
);
CREATE INDEX idx_payable_statement_adjustment_original ON finance_payable_statement_adjustments(statement_review_id,status);
CREATE FUNCTION fn_guard_statement_original_active_debt_decision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF (TG_OP='DELETE' OR NEW.status NOT IN('INTERNAL_CONFIRMED','BOTH_CONFIRMED'))
  AND EXISTS(SELECT 1 FROM finance_payable_statement_adjustments actual WHERE actual.statement_review_id=OLD.id AND actual.status='APPROVED' AND actual.released_original>0) THEN
  RAISE EXCEPTION 'Original statement has active document debt decisions; reverse their actual descendants before cancelling it' USING ERRCODE='55000';END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_statement_original_active_debt_decision BEFORE UPDATE OR DELETE ON finance_statement_document_reviews FOR EACH ROW EXECUTE FUNCTION fn_guard_statement_original_active_debt_decision();
CREATE TABLE finance_payable_statement_adjustment_lines (
 id uuid PRIMARY KEY,adjustment_id uuid NOT NULL REFERENCES finance_payable_statement_adjustments(id),line_no integer NOT NULL CHECK(line_no>0),
 target_ledger_id uuid NOT NULL REFERENCES ar_ap_ledger(id),target_fingerprint text NOT NULL,
 decision text NOT NULL CHECK(decision IN('STILL_OWED','RELEASED')),fee_kind text NOT NULL CHECK(fee_kind IN('HANDLING_FEE','ROUNDING')),
 category text NOT NULL CHECK(category IN('GOODS','MOULD')),
 amount_original numeric NOT NULL CHECK(amount_original>0 AND fn_financial_amount_is_exact(amount_original)),
 amount_local numeric NOT NULL CHECK(amount_local>=0 AND fn_financial_book_amount_is_exact(amount_local)),
 target_before_original numeric NOT NULL,target_after_original numeric NOT NULL,target_before_local numeric NOT NULL,target_after_local numeric NOT NULL,
 debt_account jsonb,counterpart_account jsonb,
 counterpart_style_id uuid REFERENCES payment_styles(id),counterpart_auxiliary_id uuid REFERENCES finance_auxiliary_items(id),
 attribution_reference text NOT NULL CHECK(length(trim(attribution_reference)) BETWEEN 1 AND 2000),
 source_reference text NOT NULL CHECK(length(trim(source_reference)) BETWEEN 1 AND 2000),
 credit_ledger_id uuid REFERENCES ar_ap_ledger(id),offset_batch_id uuid,voucher_id uuid REFERENCES gl_vouchers(id),
 reversal_voucher_id uuid REFERENCES gl_vouchers(id),
 UNIQUE(adjustment_id,line_no),UNIQUE(adjustment_id,target_ledger_id,fee_kind),
 CHECK(target_after_original=target_before_original-CASE WHEN decision='RELEASED' THEN amount_original ELSE 0 END),
 CHECK(target_after_local=target_before_local-CASE WHEN decision='RELEASED' THEN amount_local ELSE 0 END),
 CHECK((decision='RELEASED')=(counterpart_style_id IS NOT NULL AND counterpart_account IS NOT NULL)),
 CHECK(decision<>'RELEASED' OR debt_account IS NOT NULL),
 CHECK(decision='RELEASED' OR (credit_ledger_id IS NULL AND offset_batch_id IS NULL AND voucher_id IS NULL AND reversal_voucher_id IS NULL)),
 CHECK((credit_ledger_id IS NULL)=(offset_batch_id IS NULL)),
 CHECK(credit_ledger_id IS NULL AND voucher_id IS NULL OR credit_ledger_id IS NOT NULL AND ((amount_local>0)=(voucher_id IS NOT NULL)))
);
CREATE INDEX idx_payable_statement_adjustment_target ON finance_payable_statement_adjustment_lines(target_ledger_id);
CREATE FUNCTION fn_guard_payable_statement_adjustment() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.status='DRAFT' AND NEW.status='APPROVED'
   AND (to_jsonb(NEW)-ARRAY['status','approved_by','approved_at'])=(to_jsonb(OLD)-ARRAY['status','approved_by','approved_at']) THEN RETURN NEW;END IF;
 IF TG_OP='UPDATE' AND OLD.status='APPROVED' AND NEW.status='REVERSED'
   AND (to_jsonb(NEW)-ARRAY['status','reversed_by','reversed_at','reverse_reason'])=(to_jsonb(OLD)-ARRAY['status','reversed_by','reversed_at','reverse_reason']) THEN RETURN NEW;END IF;
 RAISE EXCEPTION 'Document debt decision is immutable; approve independently or append symmetric reversal' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_payable_statement_adjustment_immutable BEFORE UPDATE OR DELETE ON finance_payable_statement_adjustments FOR EACH ROW EXECUTE FUNCTION fn_guard_payable_statement_adjustment();
CREATE FUNCTION fn_guard_payable_statement_adjustment_line() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE owner_status text;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Document debt decision lines cannot be deleted' USING ERRCODE='55000';END IF;
 SELECT status INTO owner_status FROM finance_payable_statement_adjustments WHERE id=NEW.adjustment_id;
 IF owner_status<>'DRAFT' THEN
   IF TG_OP='UPDATE' AND owner_status='APPROVED' AND OLD.reversal_voucher_id IS NULL AND NEW.reversal_voucher_id IS NOT NULL
     AND (to_jsonb(NEW)-'reversal_voucher_id')=(to_jsonb(OLD)-'reversal_voucher_id') THEN RETURN NEW;END IF;
   RAISE EXCEPTION 'Approved decision lines cannot be rewritten' USING ERRCODE='55000';END IF;
 IF TG_OP='INSERT' THEN RETURN NEW;END IF;
 IF OLD.credit_ledger_id IS NULL AND NEW.credit_ledger_id IS NOT NULL
   AND (to_jsonb(NEW)-ARRAY['credit_ledger_id','offset_batch_id','voucher_id'])=(to_jsonb(OLD)-ARRAY['credit_ledger_id','offset_batch_id','voucher_id']) THEN RETURN NEW;END IF;
 RAISE EXCEPTION 'Decision inputs retain their exact source snapshot' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_payable_statement_adjustment_line_immutable BEFORE INSERT OR UPDATE OR DELETE ON finance_payable_statement_adjustment_lines FOR EACH ROW EXECUTE FUNCTION fn_guard_payable_statement_adjustment_line();

-- Extend the native-only settlement partition through this exact owned source protocol.
DO $$ DECLARE definition text;BEGIN
 SELECT pg_get_viewdef('v_finance_native_managed_gl_allocations'::regclass,true) INTO definition;
 definition:=regexp_replace(definition,';\s*$','');
 EXECUTE 'CREATE OR REPLACE VIEW v_finance_native_managed_gl_allocations AS '||definition||
 ' UNION SELECT allocation.entry_id,allocation.allocation_no FROM finance_gl_entry_allocations allocation
   JOIN gl_entries entry ON entry.id=allocation.entry_id JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id
   JOIN ar_ap_ledger credit ON credit.id=entry.source_doc_id AND credit.source_doc_type=''PAYABLE_STATEMENT_CREDIT''
   JOIN finance_payable_statement_adjustment_lines decision ON decision.id=credit.source_doc_id AND decision.decision=''RELEASED''
   WHERE voucher.source=''AUTO'' AND ((voucher.source_type=''PAYABLE_STATEMENT_CREDIT'' AND entry.source_doc_type=''PAYABLE_STATEMENT_CREDIT_LINE'')
    OR (voucher.source_type=''PAYABLE_STATEMENT_CREDIT_REV'' AND entry.source_doc_type=''PAYABLE_STATEMENT_CREDIT_REV''))';
END $$;

CREATE FUNCTION fn_assert_payable_statement_adjustment(p_id uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE owner finance_payable_statement_adjustments%ROWTYPE;line record;credit ar_ap_ledger%ROWTYPE;total_original numeric;total_local numeric;
BEGIN
 SELECT * INTO owner FROM finance_payable_statement_adjustments WHERE id=p_id;IF NOT FOUND THEN RETURN;END IF;
 SELECT COALESCE(sum(amount_original) FILTER(WHERE decision='RELEASED'),0),COALESCE(sum(amount_local) FILTER(WHERE decision='RELEASED'),0)
 INTO total_original,total_local FROM finance_payable_statement_adjustment_lines WHERE adjustment_id=p_id;
 IF total_original<>owner.released_original OR total_local<>owner.released_local THEN RAISE EXCEPTION 'Decision lines must preserve original and local totals' USING ERRCODE='23514';END IF;
 FOR line IN SELECT * FROM finance_payable_statement_adjustment_lines WHERE adjustment_id=p_id LOOP
   IF owner.status='DRAFT' AND line.credit_ledger_id IS NOT NULL THEN RAISE EXCEPTION 'Draft decisions cannot reduce debt' USING ERRCODE='23514';END IF;
   IF owner.status='DRAFT' OR line.decision='STILL_OWED' THEN CONTINUE;END IF;
   SELECT * INTO credit FROM ar_ap_ledger WHERE id=line.credit_ledger_id;
   IF NOT FOUND OR (credit.source_doc_type,credit.source_doc_id,credit.direction,credit.open_item_kind,credit.supplier_id,credit.currency_id,
       credit.amount_original,credit.amount_original_local) IS DISTINCT FROM
       ('PAYABLE_STATEMENT_CREDIT'::text,line.id,'AP'::text,'CREDIT'::text,owner.supplier_id,owner.currency_id,-line.amount_original,-line.amount_local)
     OR line.amount_local>0 AND NOT EXISTS(SELECT 1 FROM finance_native_debt_entry_refs frozen JOIN gl_entries entry ON entry.id=frozen.entry_id
       WHERE frozen.ledger_id=credit.id AND frozen.voucher_id=line.voucher_id AND frozen.owner_reverses_journal
        AND entry.style_id=(line.debt_account->>'styleId')::uuid AND entry.direction=1 AND entry.amount=line.amount_local)
     OR NOT EXISTS(SELECT 1 FROM supplier_open_item_offsets offset_row WHERE offset_row.offset_batch_id=line.offset_batch_id
       AND offset_row.source_ledger_id=credit.id AND offset_row.target_ledger_id=line.target_ledger_id AND offset_row.amount_original=line.amount_original
       AND offset_row.source_amount_local=line.amount_local AND offset_row.target_amount_local=line.amount_local
       AND offset_row.status=CASE owner.status WHEN 'APPROVED' THEN 'APPLIED' ELSE 'REVERSED' END)
     OR credit.status<>(CASE owner.status WHEN 'APPROVED' THEN 1 ELSE -1 END) THEN
    RAISE EXCEPTION 'Released debt must have its exact credit, frozen original account and native offset' USING ERRCODE='23514';END IF;
   IF owner.status='APPROVED' AND (credit.amount_balance_original<>0 OR credit.amount_balance<>0
      OR credit.amount_offset_original<>-line.amount_original OR credit.amount_offset_local<>-line.amount_local
      OR line.amount_local>0 AND NOT EXISTS(SELECT 1 FROM gl_vouchers original WHERE original.id=line.voucher_id AND original.status=1 AND original.reversed_by_voucher_id IS NULL)
      OR line.reversal_voucher_id IS NOT NULL OR credit.is_deleted)
    OR owner.status='REVERSED' AND (NOT credit.is_deleted OR line.amount_local>0 AND (line.reversal_voucher_id IS NULL
     OR NOT EXISTS(SELECT 1 FROM gl_vouchers reversed WHERE reversed.id=line.reversal_voucher_id AND reversed.reversal_of_voucher_id=line.voucher_id AND reversed.status=1))) THEN
    RAISE EXCEPTION 'Debt decision requires its original journal or actual symmetric reversal' USING ERRCODE='23514';END IF;
 END LOOP;
END $$;
CREATE FUNCTION fn_guard_payable_statement_adjustment_terminal() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_TABLE_NAME='finance_payable_statement_adjustments' THEN PERFORM fn_assert_payable_statement_adjustment(COALESCE(NEW.id,OLD.id));
 ELSE PERFORM fn_assert_payable_statement_adjustment(COALESCE(NEW.adjustment_id,OLD.adjustment_id));END IF;RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_payable_statement_adjustment_terminal AFTER INSERT OR UPDATE OR DELETE ON finance_payable_statement_adjustments DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_payable_statement_adjustment_terminal();
CREATE CONSTRAINT TRIGGER trg_payable_statement_adjustment_line_terminal AFTER INSERT OR UPDATE OR DELETE ON finance_payable_statement_adjustment_lines DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_payable_statement_adjustment_terminal();
CREATE FUNCTION fn_guard_statement_credit_owned_fact() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE owner_id uuid;BEGIN
 IF TG_TABLE_NAME='supplier_open_item_offsets' THEN
   FOR owner_id IN SELECT adjustment_id FROM finance_payable_statement_adjustment_lines WHERE offset_batch_id=COALESCE(NEW.offset_batch_id,OLD.offset_batch_id)
    LOOP PERFORM fn_assert_payable_statement_adjustment(owner_id);END LOOP;
 ELSIF TG_TABLE_NAME='ar_ap_ledger' THEN
   IF COALESCE(NEW.source_doc_type,OLD.source_doc_type)='PAYABLE_STATEMENT_CREDIT' THEN
    FOR owner_id IN SELECT adjustment_id FROM finance_payable_statement_adjustment_lines WHERE credit_ledger_id=COALESCE(NEW.id,OLD.id)
     LOOP PERFORM fn_assert_payable_statement_adjustment(owner_id);END LOOP;
   END IF;
 ELSE
   FOR owner_id IN SELECT adjustment_id FROM finance_payable_statement_adjustment_lines WHERE voucher_id=COALESCE(NEW.id,OLD.id) OR reversal_voucher_id=COALESCE(NEW.id,OLD.id)
    LOOP PERFORM fn_assert_payable_statement_adjustment(owner_id);END LOOP;
 END IF;RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_statement_credit_owned_offset AFTER INSERT OR UPDATE OR DELETE ON supplier_open_item_offsets DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_statement_credit_owned_fact();
CREATE CONSTRAINT TRIGGER trg_statement_credit_owned_ledger AFTER INSERT OR UPDATE OR DELETE ON ar_ap_ledger DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_statement_credit_owned_fact();
CREATE CONSTRAINT TRIGGER trg_statement_credit_owned_voucher AFTER INSERT OR UPDATE OR DELETE ON gl_vouchers DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_statement_credit_owned_fact();
CREATE TRIGGER trg_audit_payable_statement_adjustment AFTER INSERT OR UPDATE OR DELETE ON finance_payable_statement_adjustments FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_payable_statement_adjustment_line AFTER INSERT OR UPDATE OR DELETE ON finance_payable_statement_adjustment_lines FOR EACH ROW EXECUTE FUNCTION fn_audit();
