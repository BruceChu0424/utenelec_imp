-- Actual bank debit and bank fee are independent facts. Historical approved V0/V1 remain unchanged.
INSERT INTO payment_styles(id,code,name,category,level,sort_order,path,is_departmental,is_receipt,is_payment,status,auto_created)
VALUES('52300000-0000-4000-8100-000000000001','SYS-PAYMENT-AP-CONTROL-V523','应付账款控制','LIABILITY',0,952,
 '/SYS-PAYMENT-AP-CONTROL-V523/',FALSE,FALSE,TRUE,'使用',TRUE) ON CONFLICT(id) DO NOTHING;
UPDATE system_posting_style_roles SET style_id='52300000-0000-4000-8100-000000000001'::uuid
 WHERE role_key='AP_CONTROL' AND style_id IS NULL;
ALTER TABLE finance_payments DROP CONSTRAINT finance_payments_amount_authority_version_chk;
ALTER TABLE finance_payments ADD CONSTRAINT finance_payments_amount_authority_version_chk CHECK(amount_authority_version IN(0,1,2));
ALTER TABLE finance_payments
  ADD COLUMN account_currency_id UUID REFERENCES currencies(id),
  ADD COLUMN account_exchange_rate NUMERIC CHECK(account_exchange_rate IS NULL OR
    (abs(account_exchange_rate)<1e12::numeric AND scale(trim_scale(account_exchange_rate))<=6)),
  ADD COLUMN account_amount NUMERIC CHECK(account_amount IS NULL OR fn_financial_amount_is_exact(account_amount)),
  ADD COLUMN account_amount_local NUMERIC CHECK(account_amount_local IS NULL OR fn_financial_book_amount_is_exact(account_amount_local)),
  ADD COLUMN bank_fee_account_amount NUMERIC CHECK(bank_fee_account_amount IS NULL OR fn_financial_amount_is_exact(bank_fee_account_amount)),
  ADD COLUMN bank_fee_local NUMERIC CHECK(bank_fee_local IS NULL OR fn_financial_book_amount_is_exact(bank_fee_local)),
  ADD COLUMN bank_reference VARCHAR(128),
  ADD COLUMN bank_booked_at TIMESTAMPTZ,
  ADD COLUMN gl_account_style_id UUID REFERENCES payment_styles(id),
  ADD COLUMN gl_ap_style_id UUID REFERENCES payment_styles(id),
  ADD COLUMN gl_fx_style_id UUID REFERENCES payment_styles(id),
  ADD COLUMN gl_bank_fee_style_id UUID REFERENCES payment_styles(id),
  ADD CONSTRAINT finance_payments_v2_shape_chk CHECK(amount_authority_version<>2 OR (
    maker_id IS NOT NULL AND supplier_id IS NOT NULL AND account_id IS NOT NULL AND currency_id IS NOT NULL
    AND account_exchange_rate IS NOT NULL AND account_amount IS NOT NULL AND account_amount_local IS NOT NULL
    AND bank_fee_account_amount IS NOT NULL AND bank_fee_local IS NOT NULL
    AND amount_original IS NOT NULL AND amount_local IS NOT NULL AND exchange_rate IS NOT NULL
    AND account_currency_id IS NOT NULL AND account_exchange_rate>0 AND account_amount>0 AND account_amount_local>0
    AND bank_fee_account_amount>=0 AND bank_fee_local>=0 AND bank_fee_account_amount<account_amount
    AND amount_original>0 AND amount_local>0 AND exchange_rate>0
    AND NULLIF(btrim(bank_reference),'') IS NOT NULL AND bank_booked_at IS NOT NULL
    AND gl_account_style_id IS NOT NULL AND gl_ap_style_id IS NOT NULL
    AND (bank_fee_local=0)=(gl_bank_fee_style_id IS NULL)
    AND account_amount_local=account_amount*account_exchange_rate
    AND bank_fee_local=bank_fee_account_amount*account_exchange_rate
    AND amount_local=account_amount_local-bank_fee_local
    AND (status=0 OR (approver_id IS NOT NULL AND approver_id<>maker_id AND NOT is_deleted
      AND ((status=1 AND reversed_at IS NULL) OR (status=-1 AND reversed_at IS NOT NULL))))));
ALTER TABLE finance_payment_lines
  ADD COLUMN bank_basis_before_original NUMERIC,
  ADD COLUMN bank_basis_before_local NUMERIC,
  ADD COLUMN bank_basis_after_original NUMERIC,
  ADD COLUMN bank_basis_after_local NUMERIC,
  ADD COLUMN book_balance_before_local NUMERIC,
  ADD COLUMN book_balance_after_local NUMERIC;

SELECT fn_migrate_financial_amount_columns('[
  {"table":"finance_payments","column":"exchange_rate"},
  {"table":"finance_payment_lines","column":"cash_rate"},
  {"table":"finance_payment_lines","column":"recognition_rate"},
  {"table":"finance_expense_items","column":"amount_original"},
  {"table":"finance_expense_items","column":"amount_local","kind":"book"},
  {"table":"finance_expense_items","column":"price","kind":"book"},
  {"table":"finance_other_income_items","column":"amount_original"},
  {"table":"finance_other_income_items","column":"amount_local","kind":"book"},
  {"table":"finance_other_income_items","column":"price","kind":"book"}
]'::jsonb);
ALTER TABLE finance_payments ADD CONSTRAINT finance_payment_quote_exact_input_chk CHECK(exchange_rate IS NULL OR
  (abs(exchange_rate)<1e12::numeric AND scale(trim_scale(exchange_rate))<=6));
ALTER TABLE finance_payment_lines
  ADD CONSTRAINT finance_payment_cash_rate_exact_input_chk CHECK(cash_rate IS NULL OR
    (abs(cash_rate)<1e12::numeric AND scale(trim_scale(cash_rate))<=6)),
  ADD CONSTRAINT finance_payment_book_rate_exact_input_chk CHECK(recognition_rate IS NULL OR
    (abs(recognition_rate)<1e12::numeric AND scale(trim_scale(recognition_rate))<=6));
ALTER TABLE finance_receipts ADD CONSTRAINT finance_receipts_v2_complete_snapshots_chk CHECK(settlement_authority_version<>2 OR
  (amount_original IS NOT NULL AND amount_local IS NOT NULL AND exchange_rate IS NOT NULL
    AND account_amount IS NOT NULL AND account_amount_local IS NOT NULL AND account_exchange_rate IS NOT NULL
    AND bank_fee_account_amount IS NOT NULL AND other_fee_account_amount IS NOT NULL
    AND bank_fee IS NOT NULL AND other_fee IS NOT NULL AND fee_account_exchange_rate IS NOT NULL));
CREATE INDEX idx_payment_v2_payable_source ON finance_payment_lines(applied_ledger_id,payment_id)
  INCLUDE(amount_original,amount_local,applied_amount_local) WHERE NOT is_deleted;

CREATE OR REPLACE FUNCTION fn_guard_payment_v2_actual_bank()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE account_row RECORD;
BEGIN
  IF NEW.amount_authority_version<>2 THEN RETURN NEW;END IF;
  SELECT a.currency_id,a.style_id,c.is_base_currency INTO account_row FROM accounts a
    JOIN currencies c ON c.id=a.currency_id WHERE a.id=NEW.account_id AND a.status='使用' AND NOT a.is_deleted
      AND c.status='使用' AND NOT c.is_deleted FOR SHARE OF a,c;
  IF NOT FOUND OR account_row.currency_id IS DISTINCT FROM NEW.account_currency_id
    OR account_row.style_id IS DISTINCT FROM NEW.gl_account_style_id
    OR (account_row.is_base_currency AND NEW.account_exchange_rate<>1)
    OR (NOT account_row.is_base_currency AND (NEW.account_currency_id<>NEW.currency_id OR NEW.account_exchange_rate<>NEW.exchange_rate))
    OR (NEW.account_currency_id=NEW.currency_id AND NEW.account_amount<>NEW.amount_original+NEW.bank_fee_account_amount)
    OR (NEW.account_currency_id=NEW.currency_id AND account_row.is_base_currency AND NEW.exchange_rate<>1)
    OR NEW.gl_ap_style_id IS DISTINCT FROM system_posting_style_id('AP_CONTROL')
    OR (NEW.bank_fee_local>0 AND NEW.gl_bank_fee_style_id IS DISTINCT FROM system_posting_style_id('BANK_FEE_EXPENSE'))
    OR (NEW.gl_fx_style_id IS NOT NULL AND NEW.gl_fx_style_id IS DISTINCT FROM system_posting_style_id('FX_GAIN_LOSS')) THEN
    RAISE EXCEPTION 'actual bank debit, supplier currency, fee or frozen GL account identity mismatch' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_payment_v2_actual_bank BEFORE INSERT OR UPDATE ON finance_payments FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_v2_actual_bank();

CREATE OR REPLACE FUNCTION fn_guard_payment_money_fact()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status NOT IN(1,-1) THEN IF TG_OP='DELETE' THEN RETURN OLD;ELSE RETURN NEW;END IF;END IF;
  IF TG_OP='DELETE' OR (to_jsonb(NEW)-ARRAY['status','reversed_at','version','updated_at','updated_by','remark'])
    IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','reversed_at','version','updated_at','updated_by','remark'])
    OR (OLD.status=1 AND NOT ((NEW.status=1 AND NEW.reversed_at IS NOT DISTINCT FROM OLD.reversed_at)
      OR (NEW.status=-1 AND NEW.reversed_at IS NOT NULL AND OLD.reversed_at IS NULL)))
    OR (OLD.status=-1 AND (NEW.status<>-1 OR NEW.reversed_at IS DISTINCT FROM OLD.reversed_at)) THEN
    RAISE EXCEPTION 'approved payment money and source snapshots are immutable; append a linked reversal' USING ERRCODE='55000';
  END IF;RETURN NEW;
END $$;
CREATE TRIGGER trg_payment_money_fact BEFORE UPDATE OR DELETE ON finance_payments FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_money_fact();
CREATE OR REPLACE FUNCTION fn_guard_payment_line_money_fact()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS(SELECT 1 FROM finance_payments WHERE id IN(NEW.payment_id,OLD.payment_id) AND status IN(1,-1))
    AND (TG_OP<>'UPDATE' OR (to_jsonb(NEW)-ARRAY['updated_at','updated_by','remark'])
      IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['updated_at','updated_by','remark'])) THEN
    RAISE EXCEPTION 'approved payment allocation snapshots are immutable' USING ERRCODE='55000';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD;ELSE RETURN NEW;END IF;
END $$;
CREATE TRIGGER trg_payment_line_money_fact BEFORE INSERT OR UPDATE OR DELETE ON finance_payment_lines FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_line_money_fact();

-- A line cannot evade its approved parent by changing the parent UUID first.
DO $$
DECLARE definition TEXT;needle TEXT:='SELECT\s+status\s+INTO\s+v_status\s+FROM\s+finance_receipts\s+WHERE\s+id\s*=\s*COALESCE\(NEW.receipt_id,\s*OLD.receipt_id\);';
BEGIN
  SELECT pg_get_functiondef('fn_guard_finance_receipt_line_money_fact()'::regprocedure) INTO definition;
  IF definition!~needle THEN RAISE EXCEPTION 'receipt parent immutability guard changed; review V523 extension';END IF;
  EXECUTE regexp_replace(definition,needle,'SELECT COALESCE((SELECT status FROM finance_receipts WHERE id IN(NEW.receipt_id,OLD.receipt_id) AND status IN(1,-1) LIMIT 1),0) INTO v_status;','g');
END $$;

CREATE OR REPLACE VIEW v_payment_v2_expected_gl_entries AS
  SELECT p.id payment_id,1 line_no,p.gl_ap_style_id style_id,1::smallint direction,
    (SELECT COALESCE(sum(l.applied_amount_local),0) FROM finance_payment_lines l WHERE l.payment_id=p.id AND NOT l.is_deleted) amount
  FROM finance_payments p WHERE p.amount_authority_version=2 AND p.status IN(1,-1) AND NOT p.is_deleted
  UNION ALL SELECT p.id,2,p.gl_account_style_id,-1::smallint,p.account_amount_local FROM finance_payments p
    WHERE p.amount_authority_version=2 AND p.status IN(1,-1) AND NOT p.is_deleted
  UNION ALL SELECT p.id,3,p.gl_fx_style_id,CASE WHEN x.amount>0 THEN 1::smallint ELSE -1::smallint END,abs(x.amount)
    FROM finance_payments p CROSS JOIN LATERAL(SELECT COALESCE(sum(l.exchange_diff),0) amount FROM finance_payment_lines l
      WHERE l.payment_id=p.id AND NOT l.is_deleted) x WHERE p.amount_authority_version=2 AND p.status IN(1,-1) AND NOT p.is_deleted AND x.amount<>0
  UNION ALL SELECT p.id,4,p.gl_bank_fee_style_id,1::smallint,p.bank_fee_local FROM finance_payments p
    WHERE p.amount_authority_version=2 AND p.status IN(1,-1) AND NOT p.is_deleted AND p.bank_fee_local>0;

CREATE OR REPLACE FUNCTION fn_guard_payment_v2_gl_voucher()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE old_owned BOOLEAN:=FALSE;new_owned BOOLEAN:=FALSE;payment_row finance_payments%ROWTYPE;v RECORD;peer RECORD;different BOOLEAN;
BEGIN
  IF TG_OP<>'INSERT' THEN SELECT EXISTS(SELECT 1 FROM finance_payments p WHERE p.id=OLD.source_doc_id AND p.amount_authority_version=2
    AND OLD.source='AUTO' AND OLD.source_type IN('PAYMENT','PAYMENT_REV')) INTO old_owned;END IF;
  IF TG_OP<>'DELETE' THEN SELECT EXISTS(SELECT 1 FROM finance_payments p WHERE p.id=NEW.source_doc_id AND p.amount_authority_version=2
    AND NEW.source='AUTO' AND NEW.source_type IN('PAYMENT','PAYMENT_REV')) INTO new_owned;END IF;
  IF NOT old_owned AND NOT new_owned THEN IF TG_OP='DELETE' THEN RETURN OLD;ELSE RETURN NEW;END IF;END IF;
  IF TG_OP='INSERT' THEN
    IF NEW.status<>0 OR NEW.reversed_by_voucher_id IS NOT NULL OR
      ((NEW.source_type='PAYMENT')<>(NEW.reversal_of_voucher_id IS NULL)) THEN
      RAISE EXCEPTION 'actual payment GL starts as an unposted draft with explicit lineage' USING ERRCODE='23514';END IF;
    RETURN NEW;
  END IF;
  IF TG_OP='DELETE' OR old_owned IS DISTINCT FROM new_owned OR NEW.source_doc_id IS DISTINCT FROM OLD.source_doc_id
    OR NEW.source_type IS DISTINCT FROM OLD.source_type OR NEW.source IS DISTINCT FROM OLD.source THEN
    RAISE EXCEPTION 'actual payment GL ownership is immutable' USING ERRCODE='55000';END IF;
  IF OLD.status=0 AND NEW.status=1 AND (to_jsonb(NEW)-ARRAY['status','updated_at','updated_by'])
    =(to_jsonb(OLD)-ARRAY['status','updated_at','updated_by']) THEN
    SELECT * INTO payment_row FROM finance_payments WHERE id=OLD.source_doc_id;
    IF payment_row.status<>1 OR payment_row.is_deleted THEN RAISE EXCEPTION 'payment GL requires its approved payment' USING ERRCODE='23514';END IF;
    SELECT count(*) n,COALESCE(sum(direction*amount),0) balance,
      count(*) FILTER(WHERE source_doc_type<>OLD.source_type OR source_doc_id<>OLD.source_doc_id
        OR source_bill_no<>payment_row.bill_no OR entry_date<>OLD.voucher_date OR period<>OLD.period OR is_deleted) invalid
    INTO v FROM gl_entries WHERE voucher_id=OLD.id;
    IF v.n<2 OR v.balance<>0 OR v.invalid<>0 THEN RAISE EXCEPTION 'payment GL entries must balance exactly with complete source identities' USING ERRCODE='23514';END IF;
    IF OLD.source_type='PAYMENT' THEN
      SELECT EXISTS((SELECT line_no,style_id,direction,amount FROM v_payment_v2_expected_gl_entries WHERE payment_id=OLD.source_doc_id
        EXCEPT ALL SELECT line_no,style_id,direction,amount FROM gl_entries WHERE voucher_id=OLD.id)
        UNION ALL (SELECT line_no,style_id,direction,amount FROM gl_entries WHERE voucher_id=OLD.id
        EXCEPT ALL SELECT line_no,style_id,direction,amount FROM v_payment_v2_expected_gl_entries WHERE payment_id=OLD.source_doc_id)) INTO different;
    ELSE
      SELECT * INTO peer FROM gl_vouchers WHERE id=OLD.reversal_of_voucher_id;
      IF peer.id IS NULL OR peer.source_type<>'PAYMENT' OR peer.source_doc_id<>OLD.source_doc_id OR peer.status<>1 OR peer.is_deleted
        OR peer.reversed_by_voucher_id IS NOT NULL THEN RAISE EXCEPTION 'payment reversal requires an unreversed original voucher' USING ERRCODE='23514';END IF;
      SELECT EXISTS((SELECT line_no,style_id,-direction,amount FROM gl_entries WHERE voucher_id=peer.id
        EXCEPT ALL SELECT line_no,style_id,direction,amount FROM gl_entries WHERE voucher_id=OLD.id)
        UNION ALL (SELECT line_no,style_id,direction,amount FROM gl_entries WHERE voucher_id=OLD.id
        EXCEPT ALL SELECT line_no,style_id,-direction,amount FROM gl_entries WHERE voucher_id=peer.id)) INTO different;
    END IF;
    IF different THEN RAISE EXCEPTION 'payment GL must equal the immutable actual-bank book snapshot multiset' USING ERRCODE='23514';END IF;
    RETURN NEW;
  END IF;
  IF OLD.status=1 AND NEW.status=1 AND OLD.source_type='PAYMENT' AND OLD.reversed_by_voucher_id IS NULL
    AND NEW.reversed_by_voucher_id IS NOT NULL AND (to_jsonb(NEW)-ARRAY['reversed_by_voucher_id','updated_at','updated_by'])
      =(to_jsonb(OLD)-ARRAY['reversed_by_voucher_id','updated_at','updated_by'])
    AND EXISTS(SELECT 1 FROM gl_vouchers WHERE id=NEW.reversed_by_voucher_id AND reversal_of_voucher_id=OLD.id
      AND source_type='PAYMENT_REV' AND source_doc_id=OLD.source_doc_id AND status=1 AND NOT is_deleted) THEN RETURN NEW;END IF;
  RAISE EXCEPTION 'posted payment GL is immutable; append one linked reversal' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_payment_v2_gl_voucher BEFORE INSERT OR UPDATE OR DELETE ON gl_vouchers FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_v2_gl_voucher();
CREATE OR REPLACE FUNCTION fn_guard_payment_v2_gl_entry()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v RECORD;
BEGIN
  IF TG_OP<>'INSERT' AND EXISTS(SELECT 1 FROM gl_vouchers voucher JOIN finance_payments p ON p.id=voucher.source_doc_id
    WHERE voucher.id=OLD.voucher_id AND voucher.source='AUTO' AND voucher.source_type IN('PAYMENT','PAYMENT_REV')
      AND p.amount_authority_version=2) THEN
    RAISE EXCEPTION 'payment GL entry cannot leave its immutable original voucher' USING ERRCODE='55000';
  END IF;
  SELECT voucher.* INTO v FROM gl_vouchers voucher JOIN finance_payments p ON p.id=voucher.source_doc_id
    WHERE voucher.id=COALESCE(NEW.voucher_id,OLD.voucher_id) AND voucher.source='AUTO'
      AND voucher.source_type IN('PAYMENT','PAYMENT_REV') AND p.amount_authority_version=2;
  IF FOUND AND (TG_OP<>'INSERT' OR v.status<>0 OR NEW.source_doc_type IS DISTINCT FROM v.source_type
    OR NEW.source_doc_id IS DISTINCT FROM v.source_doc_id OR NEW.period IS DISTINCT FROM v.period
    OR NEW.entry_date IS DISTINCT FROM v.voucher_date OR COALESCE(NEW.is_deleted,FALSE)) THEN
    RAISE EXCEPTION 'payment GL entries are immutable source snapshots' USING ERRCODE='55000';END IF;
  IF TG_OP='DELETE' THEN RETURN OLD;ELSE RETURN NEW;END IF;
END $$;
CREATE TRIGGER trg_payment_v2_gl_entry BEFORE INSERT OR UPDATE OR DELETE ON gl_entries FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_v2_gl_entry();

CREATE OR REPLACE FUNCTION fn_post_payment_v2_gl(p_payment UUID)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE p finance_payments%ROWTYPE;voucher UUID:=gen_random_uuid();
BEGIN
  SELECT * INTO p FROM finance_payments WHERE id=p_payment FOR UPDATE;
  IF NOT FOUND OR p.amount_authority_version<>2 OR p.status<>1 OR p.is_deleted THEN
    RAISE EXCEPTION 'actual-bank payment GL requires an approved V2 payment' USING ERRCODE='23514';END IF;
  IF EXISTS(SELECT 1 FROM gl_vouchers WHERE source='AUTO' AND source_type IN('PAYMENT','PAYMENT_REV')
      AND source_doc_id=p.id AND NOT is_deleted) THEN RAISE EXCEPTION 'payment already owns a GL posting' USING ERRCODE='23505';END IF;
  INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,source_doc_id,status)
    VALUES(voucher,p.bill_no,to_char(p.bill_date,'YYYY-MM'),p.bill_date,'AUTO','PAYMENT',p.id,0);
  INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,source_doc_type,source_doc_id,source_bill_no)
    SELECT voucher,e.line_no,e.style_id,e.direction,e.amount,p.bill_date,to_char(p.bill_date,'YYYY-MM'),'PAYMENT',p.id,p.bill_no
    FROM v_payment_v2_expected_gl_entries e WHERE e.payment_id=p.id;
  UPDATE gl_vouchers SET status=1 WHERE id=voucher;RETURN voucher;
END $$;
CREATE OR REPLACE FUNCTION fn_reverse_payment_v2_gl(p_payment UUID,p_reversed_at TIMESTAMPTZ)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE p finance_payments%ROWTYPE;original UUID;voucher UUID:=gen_random_uuid();reversal_date DATE;
BEGIN
  SELECT * INTO p FROM finance_payments WHERE id=p_payment FOR UPDATE;
  IF NOT FOUND OR p.amount_authority_version<>2 OR p.status<>1 OR p.is_deleted OR p_reversed_at IS NULL THEN
    RAISE EXCEPTION 'payment reversal requires an approved actual-bank payment' USING ERRCODE='23514';END IF;
  SELECT id INTO original FROM gl_vouchers WHERE source='AUTO' AND source_type='PAYMENT' AND source_doc_id=p.id
    AND status=1 AND NOT is_deleted AND reversed_by_voucher_id IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'payment original GL is missing or already reversed' USING ERRCODE='23514';END IF;
  reversal_date:=(p_reversed_at AT TIME ZONE 'Asia/Shanghai')::date;
  INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,source_doc_id,reversal_of_voucher_id,status)
    VALUES(voucher,p.bill_no||'-REV',to_char(reversal_date,'YYYY-MM'),reversal_date,'AUTO','PAYMENT_REV',p.id,original,0);
  INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,source_doc_type,source_doc_id,source_bill_no)
    SELECT voucher,e.line_no,e.style_id,-e.direction,e.amount,reversal_date,to_char(reversal_date,'YYYY-MM'),'PAYMENT_REV',p.id,p.bill_no
    FROM gl_entries e WHERE e.voucher_id=original ORDER BY line_no;
  UPDATE gl_vouchers SET status=1 WHERE id=voucher;
  UPDATE gl_vouchers SET reversed_by_voucher_id=voucher WHERE id=original;RETURN voucher;
END $$;

CREATE OR REPLACE FUNCTION fn_assert_payment_v2_terminal(p_payment UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE p finance_payments%ROWTYPE;l RECORD;t RECORD;original RECORD;reversal RECORD;posting RECORD;backflow RECORD;a NUMERIC;b NUMERIC;different BOOLEAN;
BEGIN
  SELECT * INTO p FROM finance_payments WHERE id=p_payment;
  IF NOT FOUND OR p.amount_authority_version<>2 OR p.is_deleted THEN RETURN;END IF;
  SELECT count(*) n,COALESCE(sum(amount_original),0) a,COALESCE(sum(amount_local),0) b,COALESCE(sum(exchange_diff),0) fx
    INTO t FROM finance_payment_lines WHERE payment_id=p.id AND NOT is_deleted;
  IF (t.n=0 AND p.status<>0) OR (t.n>0 AND (t.a<>p.amount_original OR t.b<>p.amount_local
    OR (t.fx=0)<>(p.gl_fx_style_id IS NULL))) THEN RAISE EXCEPTION 'payment cash, source book and FX totals do not reconcile' USING ERRCODE='23514';END IF;
  a:=p.amount_original;b:=p.amount_local;
  FOR l IN SELECT * FROM finance_payment_lines WHERE payment_id=p.id AND NOT is_deleted ORDER BY line_no,id LOOP
    IF l.supplier_id IS DISTINCT FROM p.supplier_id OR NOT EXISTS(SELECT 1 FROM ar_ap_ledger ledger
      WHERE ledger.id=l.applied_ledger_id AND ledger.direction='AP' AND ledger.status=1 AND NOT ledger.is_deleted
        AND ledger.open_item_kind='PAYABLE' AND ledger.supplier_id=p.supplier_id AND ledger.currency_id=p.currency_id
        AND ledger.exchange_rate IS NOT DISTINCT FROM l.recognition_rate) THEN
      RAISE EXCEPTION 'payment allocation crosses its payable supplier, currency or recognition snapshot' USING ERRCODE='23514';END IF;
    IF (l.bank_basis_before_original,l.bank_basis_before_local,l.bank_basis_after_original,l.bank_basis_after_local)
      IS DISTINCT FROM(a,b,a-l.amount_original,b-l.amount_local)
      OR l.amount_local<>fn_financial_book_part(l.amount_original,a,b)
      OR l.exchange_diff IS DISTINCT FROM l.amount_local-l.applied_amount_local OR l.cash_rate<>p.exchange_rate
      OR (p.status IN(1,-1) AND (l.book_balance_before_local IS NULL OR l.book_balance_after_local IS NULL
        OR l.balance_before_original IS NULL OR l.balance_after_original<>l.balance_before_original-l.amount_original
        OR l.book_balance_after_local<>l.book_balance_before_local-l.applied_amount_local
        OR l.applied_amount_local<>fn_financial_book_part(l.amount_original,l.balance_before_original,l.book_balance_before_local))) THEN
      RAISE EXCEPTION 'payment must conserve actual bank and payable book allocation basis' USING ERRCODE='23514';END IF;
    a:=l.bank_basis_after_original;b:=l.bank_basis_after_local;
    IF p.status IN(1,-1) AND EXISTS(SELECT 1 FROM ar_ap_ledger ledger
      CROSS JOIN LATERAL(SELECT COALESCE(sum(line.amount_original),0) original,
        COALESCE(sum(line.amount_local),0) cash,COALESCE(sum(line.applied_amount_local),0) book
        FROM finance_payment_lines line JOIN finance_payments payment ON payment.id=line.payment_id
        WHERE line.applied_ledger_id=ledger.id AND NOT line.is_deleted AND payment.status=1 AND NOT payment.is_deleted) used
      WHERE ledger.id=l.applied_ledger_id AND (ledger.amount_received_original IS NULL
        OR ledger.amount_received_original<used.original OR ledger.amount_received_local<used.cash OR ledger.amount_settled<used.book)) THEN
      RAISE EXCEPTION 'payable cash and book totals do not contain their active payment facts' USING ERRCODE='23514';END IF;
  END LOOP;
  IF t.n>0 AND (a<>0 OR b<>0) THEN RAISE EXCEPTION 'payment allocation discards a bank remainder' USING ERRCODE='23514';END IF;
  IF p.status=0 THEN RETURN;END IF;
  IF (SELECT count(*) FROM gl_vouchers WHERE source='AUTO' AND source_type='PAYMENT' AND source_doc_id=p.id AND status=1 AND NOT is_deleted)<>1
    OR (SELECT count(*) FROM finance_reconciliations WHERE source_doc_type='PAYMENT' AND source_doc_id=p.id AND entry_kind='POSTING' AND NOT is_deleted)<>1 THEN
    RAISE EXCEPTION 'terminal actual-bank payment requires one immutable GL and bank posting' USING ERRCODE='23514';END IF;
  SELECT * INTO original FROM gl_vouchers WHERE source='AUTO' AND source_type='PAYMENT' AND source_doc_id=p.id AND status=1 AND NOT is_deleted;
  SELECT * INTO posting FROM finance_reconciliations WHERE source_doc_type='PAYMENT' AND source_doc_id=p.id AND entry_kind='POSTING' AND NOT is_deleted;
  IF (posting.account_id,posting.account_currency_id,posting.in_amount,posting.out_amount,posting.amount_local,posting.bill_date)
    IS DISTINCT FROM(p.account_id,p.account_currency_id,0::numeric,p.account_amount,p.account_amount_local,p.bank_booked_at) THEN
    RAISE EXCEPTION 'payment bank posting differs from its actual debit snapshot' USING ERRCODE='23514';END IF;
  SELECT EXISTS((SELECT line_no,style_id,direction,amount FROM v_payment_v2_expected_gl_entries WHERE payment_id=p.id
      EXCEPT ALL SELECT line_no,style_id,direction,amount FROM gl_entries WHERE voucher_id=original.id)
    UNION ALL (SELECT line_no,style_id,direction,amount FROM gl_entries WHERE voucher_id=original.id
      EXCEPT ALL SELECT line_no,style_id,direction,amount FROM v_payment_v2_expected_gl_entries WHERE payment_id=p.id)) INTO different;
  IF different THEN RAISE EXCEPTION 'payment GL snapshot mismatch' USING ERRCODE='23514';END IF;
  IF p.status=1 THEN
    IF original.reversed_by_voucher_id IS NOT NULL OR EXISTS(SELECT 1 FROM finance_reconciliations WHERE source_doc_type='PAYMENT'
      AND source_doc_id=p.id AND entry_kind='REVERSAL' AND NOT is_deleted) THEN
      RAISE EXCEPTION 'approved payment cannot already be reversed' USING ERRCODE='23514';END IF;
  ELSE
    SELECT * INTO reversal FROM gl_vouchers WHERE id=original.reversed_by_voucher_id AND source_type='PAYMENT_REV'
      AND reversal_of_voucher_id=original.id AND source_doc_id=p.id AND status=1 AND NOT is_deleted;
    SELECT * INTO backflow FROM finance_reconciliations WHERE source_doc_type='PAYMENT' AND source_doc_id=p.id
      AND entry_kind='REVERSAL' AND reversal_of_id=posting.id AND NOT is_deleted;
    IF reversal.id IS NULL OR backflow.id IS NULL OR reversal.voucher_date<>(p.reversed_at AT TIME ZONE 'Asia/Shanghai')::date
      OR backflow.bill_date<>p.reversed_at OR (backflow.in_amount,backflow.out_amount,backflow.amount_local)
        IS DISTINCT FROM(posting.out_amount,posting.in_amount,posting.amount_local) THEN
      RAISE EXCEPTION 'payment reversal must retain original bank amounts and GL lineage' USING ERRCODE='23514';END IF;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION fn_guard_payment_v2_terminal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE id UUID;
BEGIN
  IF TG_TABLE_NAME='finance_payments' THEN id:=COALESCE(NEW.id,OLD.id);
  ELSIF TG_TABLE_NAME='finance_payment_lines' THEN id:=COALESCE(NEW.payment_id,OLD.payment_id);
  ELSIF TG_TABLE_NAME='gl_vouchers' THEN IF COALESCE(NEW.source_type,OLD.source_type) NOT IN('PAYMENT','PAYMENT_REV') THEN RETURN NULL;END IF;id:=COALESCE(NEW.source_doc_id,OLD.source_doc_id);
  ELSE IF COALESCE(NEW.source_doc_type,OLD.source_doc_type)<>'PAYMENT' THEN RETURN NULL;END IF;id:=COALESCE(NEW.source_doc_id,OLD.source_doc_id);END IF;
  PERFORM fn_assert_payment_v2_terminal(id);RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_payment_v2_header_terminal AFTER INSERT OR UPDATE ON finance_payments DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_v2_terminal();
CREATE CONSTRAINT TRIGGER trg_payment_v2_line_terminal AFTER INSERT OR UPDATE OR DELETE ON finance_payment_lines DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_v2_terminal();
CREATE CONSTRAINT TRIGGER trg_payment_v2_gl_terminal AFTER INSERT OR UPDATE OR DELETE ON gl_vouchers DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_v2_terminal();
CREATE CONSTRAINT TRIGGER trg_payment_v2_flow_terminal AFTER INSERT ON finance_reconciliations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_v2_terminal();
ALTER TABLE finance_payments ENABLE ALWAYS TRIGGER trg_payment_v2_actual_bank;
ALTER TABLE finance_payments ENABLE ALWAYS TRIGGER trg_payment_money_fact;
ALTER TABLE finance_payment_lines ENABLE ALWAYS TRIGGER trg_payment_line_money_fact;
ALTER TABLE gl_vouchers ENABLE ALWAYS TRIGGER trg_payment_v2_gl_voucher;
ALTER TABLE gl_entries ENABLE ALWAYS TRIGGER trg_payment_v2_gl_entry;
ALTER TABLE finance_payments ENABLE ALWAYS TRIGGER trg_payment_v2_header_terminal;
ALTER TABLE finance_payment_lines ENABLE ALWAYS TRIGGER trg_payment_v2_line_terminal;
ALTER TABLE gl_vouchers ENABLE ALWAYS TRIGGER trg_payment_v2_gl_terminal;
ALTER TABLE finance_reconciliations ENABLE ALWAYS TRIGGER trg_payment_v2_flow_terminal;
