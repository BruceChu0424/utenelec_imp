-- A supplier advance is an asset with one actual PAYMENT bank/GL posting, not a negative AP.
INSERT INTO system_posting_style_roles(role_key,required_category,description)
VALUES('SUPPLIER_PREPAYMENT_ASSET','ACCOUNT','供应商实际预付资产；须财务明确对应科目') ON CONFLICT(role_key) DO NOTHING;

CREATE TABLE finance_supplier_advances (
    payment_id uuid PRIMARY KEY REFERENCES finance_payments(id),supplier_id uuid NOT NULL REFERENCES suppliers(id),
    currency_id uuid NOT NULL REFERENCES currencies(id),style_id uuid NOT NULL REFERENCES payment_styles(id),
    account_code text NOT NULL REFERENCES finance_chart_codes(code),accounting_currency_id uuid NOT NULL REFERENCES currencies(id),
    auxiliary_id uuid NOT NULL REFERENCES finance_auxiliary_items(id),auxiliary_snapshot jsonb NOT NULL,
    amount_original numeric NOT NULL CHECK(amount_original>0 AND fn_financial_amount_is_exact(amount_original)),
    amount_local numeric NOT NULL CHECK(amount_local>0 AND fn_financial_book_amount_is_exact(amount_local)),
    effective_date date NOT NULL,created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
    creation_tx xid8 NOT NULL DEFAULT pg_current_xact_id(),status text NOT NULL DEFAULT 'OPEN' CHECK(status IN('OPEN','REVERSED')),
    reversed_at timestamptz, CHECK((status='REVERSED')=(reversed_at IS NOT NULL))
);
CREATE TABLE finance_supplier_advance_parts (
    payment_id uuid NOT NULL REFERENCES finance_supplier_advances(payment_id),category text NOT NULL CHECK(category IN('GOODS','MOULD')),
    amount_original numeric NOT NULL CHECK(amount_original>=0 AND fn_financial_amount_is_exact(amount_original)),
    amount_local numeric NOT NULL CHECK(amount_local>=0 AND fn_financial_book_amount_is_exact(amount_local)),
    source_reference text NOT NULL CHECK(length(trim(source_reference)) BETWEEN 1 AND 2000),
    created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(payment_id,category)
);
CREATE TABLE finance_supplier_advance_applications (
    id uuid PRIMARY KEY,request_id uuid NOT NULL UNIQUE,payload_hash text NOT NULL,payment_id uuid NOT NULL REFERENCES finance_supplier_advances(payment_id),
    target_ledger_id uuid NOT NULL REFERENCES ar_ap_ledger(id),effective_date date NOT NULL,source_reference text NOT NULL,
    amount_original numeric NOT NULL CHECK(amount_original>0 AND fn_financial_amount_is_exact(amount_original)),
    source_local numeric NOT NULL CHECK(source_local>0 AND fn_financial_book_amount_is_exact(source_local)),
    target_local numeric NOT NULL CHECK(target_local>0 AND fn_financial_book_amount_is_exact(target_local)),
    source_category text NOT NULL CHECK(source_category IN('GOODS','MOULD')),target_category text NOT NULL CHECK(target_category IN('GOODS','MOULD')),
    target_before_original numeric NOT NULL,target_after_original numeric NOT NULL,
    target_before_local numeric NOT NULL,target_after_local numeric NOT NULL,
    voucher_id uuid NOT NULL REFERENCES gl_vouchers(id),reservation_id uuid NOT NULL REFERENCES finance_gl_settlement_reservations(id),
    status text NOT NULL CHECK(status IN('APPLIED','REVERSED')),reversal_voucher_id uuid REFERENCES gl_vouchers(id),reversed_at timestamptz,
    created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
    CHECK(target_after_original=target_before_original-amount_original),CHECK(target_after_local=target_before_local-target_local),
    CHECK((status='REVERSED')=(reversed_at IS NOT NULL AND reversal_voucher_id IS NOT NULL))
);
CREATE INDEX idx_supplier_advance_application_source ON finance_supplier_advance_applications(payment_id,status);
CREATE INDEX idx_supplier_advance_application_target ON finance_supplier_advance_applications(target_ledger_id,status);

CREATE TABLE finance_supplier_advance_refunds (
 id uuid PRIMARY KEY,request_id uuid NOT NULL UNIQUE,payload_hash text NOT NULL,payment_id uuid NOT NULL REFERENCES finance_supplier_advances(payment_id),
 source_category text NOT NULL CHECK(source_category IN('GOODS','MOULD')),source_reference text NOT NULL,
 amount_original numeric NOT NULL CHECK(amount_original>0 AND fn_financial_amount_is_exact(amount_original)),
 source_local numeric CHECK(source_local>0 AND fn_financial_book_amount_is_exact(source_local)),
 account_id uuid NOT NULL REFERENCES accounts(id),account_currency_id uuid NOT NULL REFERENCES currencies(id),bank_reference text NOT NULL,
 bank_booked_at timestamptz NOT NULL,bank_amount numeric NOT NULL CHECK(bank_amount>0 AND fn_financial_amount_is_exact(bank_amount)),
 bank_rate numeric NOT NULL CHECK(bank_rate>0 AND fn_financial_amount_is_exact(bank_rate)),
 bank_local numeric NOT NULL CHECK(bank_local>0 AND fn_financial_book_amount_is_exact(bank_local)),
 fee_amount numeric NOT NULL CHECK(fee_amount>=0 AND fn_financial_amount_is_exact(fee_amount)),
 fee_local numeric NOT NULL CHECK(fee_local>=0 AND fn_financial_book_amount_is_exact(fee_local)),
 bank_style_id uuid NOT NULL REFERENCES payment_styles(id),fee_style_id uuid REFERENCES payment_styles(id),fx_style_id uuid REFERENCES payment_styles(id),
 effective_date date,voucher_id uuid REFERENCES gl_vouchers(id),reservation_id uuid REFERENCES finance_gl_settlement_reservations(id),status text NOT NULL CHECK(status IN('DRAFT','APPROVED','REVERSED')),
 created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),approved_by uuid REFERENCES users(id),approved_at timestamptz,
 reversal_voucher_id uuid REFERENCES gl_vouchers(id),reversed_at timestamptz,
 CHECK(bank_local=bank_amount*bank_rate),CHECK(fee_local=fee_amount*bank_rate),CHECK((fee_local=0)=(fee_style_id IS NULL)),
 CHECK(approved_by IS NULL OR approved_by<>created_by),CHECK(status='DRAFT' OR (voucher_id IS NOT NULL AND source_local IS NOT NULL AND approved_by IS NOT NULL AND effective_date IS NOT NULL)),
 CHECK((status='REVERSED')=(reversal_voucher_id IS NOT NULL AND reversed_at IS NOT NULL))
);
CREATE INDEX idx_supplier_advance_refund_source ON finance_supplier_advance_refunds(payment_id,status);
DO $$ DECLARE definition text;BEGIN
 SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint WHERE conrelid='finance_reconciliations'::regclass
   AND conname='finance_reconciliations_source_doc_type_chk';
 IF definition IS NULL OR left(definition,7)<>'CHECK (' THEN RAISE EXCEPTION 'Review account-flow source constraint before supplier refund extension';END IF;
 EXECUTE 'ALTER TABLE finance_reconciliations DROP CONSTRAINT finance_reconciliations_source_doc_type_chk';
 EXECUTE 'ALTER TABLE finance_reconciliations ADD CONSTRAINT finance_reconciliations_source_doc_type_chk CHECK ('
   ||substring(definition FROM 8 FOR length(definition)-8)||' OR source_doc_type=''SUPPLIER_ADVANCE_REFUND'')';
END $$;

CREATE TABLE finance_supplier_advance_dependencies (
 application_id uuid NOT NULL REFERENCES finance_supplier_advance_applications(id),
 payment_line_id uuid REFERENCES finance_payment_lines(id),offset_id uuid REFERENCES supplier_open_item_offsets(id),
 relation text NOT NULL CHECK(relation IN('PEER_BEFORE_APPLICATION','APPLICATION_BEFORE_PEER')),
 created_by uuid NOT NULL REFERENCES users(id),created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(num_nonnulls(payment_line_id,offset_id)=1),
 UNIQUE NULLS NOT DISTINCT(application_id,payment_line_id,offset_id)
);

CREATE OR REPLACE FUNCTION fn_guard_supplier_advance_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='INSERT' THEN RETURN NEW;END IF;
 IF TG_OP='UPDATE' AND OLD.status='OPEN' AND NEW.status='REVERSED' AND NEW.reversed_at IS NOT NULL
    AND (to_jsonb(NEW)-ARRAY['status','reversed_at'])=(to_jsonb(OLD)-ARRAY['status','reversed_at']) THEN RETURN NEW;END IF;
 RAISE EXCEPTION 'supplier advance source is immutable; reverse its actual payment after applications/refunds' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_supplier_advance_snapshot BEFORE UPDATE OR DELETE ON finance_supplier_advances FOR EACH ROW EXECUTE FUNCTION fn_guard_supplier_advance_snapshot();

-- Preserve the original actual-bank ledger and its complete terminal constraints.
-- The only extra debit shape is a real positive advance asset with no AP payment lines.
CREATE OR REPLACE VIEW v_payment_v2_expected_gl_entries AS
 SELECT p.id payment_id,1 line_no,p.gl_ap_style_id style_id,1::smallint direction,
   CASE WHEN EXISTS(SELECT 1 FROM finance_supplier_advances a WHERE a.payment_id=p.id)
     THEN p.amount_local ELSE (SELECT COALESCE(sum(l.applied_amount_local),0) FROM finance_payment_lines l WHERE l.payment_id=p.id AND NOT l.is_deleted) END amount
 FROM finance_payments p WHERE p.amount_authority_version=2 AND p.status IN(1,-1) AND NOT p.is_deleted
 UNION ALL SELECT p.id,2,p.gl_account_style_id,-1::smallint,p.account_amount_local FROM finance_payments p
 WHERE p.amount_authority_version=2 AND p.status IN(1,-1) AND NOT p.is_deleted
 UNION ALL SELECT p.id,3,p.gl_fx_style_id,CASE WHEN x.amount>0 THEN 1::smallint ELSE -1::smallint END,abs(x.amount)
 FROM finance_payments p CROSS JOIN LATERAL(SELECT COALESCE(sum(l.exchange_diff),0) amount FROM finance_payment_lines l WHERE l.payment_id=p.id AND NOT l.is_deleted)x
 WHERE p.amount_authority_version=2 AND p.status IN(1,-1) AND NOT p.is_deleted AND x.amount<>0
 UNION ALL SELECT p.id,4,p.gl_bank_fee_style_id,1::smallint,p.bank_fee_local FROM finance_payments p
 WHERE p.amount_authority_version=2 AND p.status IN(1,-1) AND NOT p.is_deleted AND p.bank_fee_local>0;

DO $$
DECLARE definition text;needle text;
BEGIN
 SELECT pg_get_functiondef('fn_guard_payment_v2_actual_bank()'::regprocedure) INTO definition;
 needle:='NEW.gl_ap_style_id IS DISTINCT FROM system_posting_style_id(''AP_CONTROL'')';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review actual payment bank account guard before adding advance shape';END IF;
 EXECUTE replace(definition,needle,'NEW.gl_ap_style_id IS DISTINCT FROM system_posting_style_id(CASE WHEN EXISTS(SELECT 1 FROM finance_payment_lines WHERE payment_id=NEW.id AND NOT is_deleted) THEN ''AP_CONTROL'' ELSE ''SUPPLIER_PREPAYMENT_ASSET'' END)');
 SELECT pg_get_functiondef('fn_assert_payment_v2_terminal(uuid)'::regprocedure) INTO definition;
 needle:='(t.n=0 AND p.status<>0)';
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'Review actual payment terminal guard before adding advance shape';END IF;
 EXECUTE replace(definition,needle,'(t.n=0 AND p.status<>0 AND NOT EXISTS(SELECT 1 FROM finance_supplier_advances WHERE payment_id=p.id))');
END $$;

CREATE FUNCTION fn_assert_supplier_advance(p_id uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE a finance_supplier_advances%ROWTYPE;p finance_payments%ROWTYPE;t record;parts record;
BEGIN
 SELECT * INTO a FROM finance_supplier_advances WHERE payment_id=p_id;IF NOT FOUND THEN RETURN;END IF;
 SELECT * INTO p FROM finance_payments WHERE id=p_id;
 IF p.amount_authority_version<>2 OR p.is_deleted OR p.status NOT IN(1,-1)
  OR (a.supplier_id,a.currency_id,a.style_id,a.amount_original,a.amount_local,a.effective_date)
    IS DISTINCT FROM(p.supplier_id,p.currency_id,p.gl_ap_style_id,p.amount_original,p.amount_local,p.bill_date)
  OR EXISTS(SELECT 1 FROM finance_payment_lines WHERE payment_id=p.id AND NOT is_deleted)
  OR (a.status='REVERSED')<>(p.status=-1) THEN
  RAISE EXCEPTION 'advance must match its real actual-bank payment and asset account, without AP payment allocations' USING ERRCODE='23514';END IF;
 SELECT COALESCE(sum(amount_original),0) original,COALESCE(sum(source_local),0) local INTO t FROM (
   SELECT amount_original,source_local FROM finance_supplier_advance_applications WHERE payment_id=p_id AND status='APPLIED'
   UNION ALL SELECT amount_original,source_local FROM finance_supplier_advance_refunds WHERE payment_id=p_id AND status='APPROVED') consumed;
 IF t.original>a.amount_original OR t.local>a.amount_local OR (a.status='REVERSED' AND (t.original<>0 OR t.local<>0)) THEN
  RAISE EXCEPTION 'supplier advance cannot be consumed twice or reversed while an application remains' USING ERRCODE='23514';END IF;
 SELECT count(*) n,sum(amount_original) original,sum(amount_local) local INTO parts FROM finance_supplier_advance_parts WHERE payment_id=p_id;
 IF parts.n>0 AND (parts.original<>a.amount_original OR parts.local<>a.amount_local) THEN
  RAISE EXCEPTION 'supplier advance categories must preserve both original and local asset amounts' USING ERRCODE='23514';END IF;
END $$;
CREATE FUNCTION fn_guard_supplier_advance_terminal() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN PERFORM fn_assert_supplier_advance(COALESCE(NEW.payment_id,OLD.payment_id));RETURN NULL;END $$;
CREATE CONSTRAINT TRIGGER trg_supplier_advance_terminal AFTER INSERT OR UPDATE OR DELETE ON finance_supplier_advances DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_supplier_advance_terminal();
CREATE CONSTRAINT TRIGGER trg_supplier_advance_parts_terminal AFTER INSERT OR UPDATE OR DELETE ON finance_supplier_advance_parts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_supplier_advance_terminal();
CREATE CONSTRAINT TRIGGER trg_supplier_advance_application_terminal AFTER INSERT OR UPDATE OR DELETE ON finance_supplier_advance_applications DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_supplier_advance_terminal();
CREATE CONSTRAINT TRIGGER trg_supplier_advance_refund_terminal AFTER INSERT OR UPDATE OR DELETE ON finance_supplier_advance_refunds DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_supplier_advance_terminal();

CREATE FUNCTION fn_guard_supplier_advance_parts_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'supplier advance categories retain their confirmed source; no overwrite' USING ERRCODE='55000';END IF;
 IF EXISTS(SELECT 1 FROM finance_supplier_advance_applications WHERE payment_id=NEW.payment_id) OR EXISTS(SELECT 1 FROM finance_supplier_advance_refunds WHERE payment_id=NEW.payment_id AND status<>'DRAFT') THEN
 RAISE EXCEPTION 'supplier advance categories cannot be added after settlement facts exist' USING ERRCODE='55000';END IF;RETURN NEW;
END $$;
CREATE TRIGGER trg_supplier_advance_parts_immutable BEFORE INSERT OR UPDATE OR DELETE ON finance_supplier_advance_parts FOR EACH ROW EXECUTE FUNCTION fn_guard_supplier_advance_parts_immutable();
CREATE FUNCTION fn_guard_supplier_advance_settlement_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'supplier advance settlements cannot be deleted' USING ERRCODE='55000';END IF;
 IF TG_OP='INSERT' THEN RETURN NEW;END IF;
 IF OLD.status='DRAFT' AND NEW.status='APPROVED'
   AND (to_jsonb(NEW)-ARRAY['status','source_local','fx_style_id','effective_date','voucher_id','reservation_id','approved_by','approved_at'])
     =(to_jsonb(OLD)-ARRAY['status','source_local','fx_style_id','effective_date','voucher_id','reservation_id','approved_by','approved_at']) THEN RETURN NEW;END IF;
 IF OLD.status IN('APPLIED','APPROVED') AND NEW.status='REVERSED'
   AND (to_jsonb(NEW)-ARRAY['status','reversal_voucher_id','reversed_at'])=(to_jsonb(OLD)-ARRAY['status','reversal_voucher_id','reversed_at']) THEN RETURN NEW;END IF;
 RAISE EXCEPTION 'supplier advance settlement snapshots are immutable; append symmetric reversal' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_supplier_advance_application_immutable BEFORE INSERT OR UPDATE OR DELETE ON finance_supplier_advance_applications FOR EACH ROW EXECUTE FUNCTION fn_guard_supplier_advance_settlement_immutable();
CREATE TRIGGER trg_supplier_advance_refund_immutable BEFORE INSERT OR UPDATE OR DELETE ON finance_supplier_advance_refunds FOR EACH ROW EXECUTE FUNCTION fn_guard_supplier_advance_settlement_immutable();

CREATE TRIGGER trg_audit_finance_supplier_advances AFTER INSERT OR UPDATE OR DELETE ON finance_supplier_advances FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_supplier_advance_parts AFTER INSERT OR UPDATE OR DELETE ON finance_supplier_advance_parts FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_supplier_advance_applications AFTER INSERT OR UPDATE OR DELETE ON finance_supplier_advance_applications FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_supplier_advance_refunds AFTER INSERT OR UPDATE OR DELETE ON finance_supplier_advance_refunds FOR EACH ROW EXECUTE FUNCTION fn_audit();
