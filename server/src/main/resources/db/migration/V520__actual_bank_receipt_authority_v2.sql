-- V2 accepts actual bank receipts independently from an indicative conversion quote.
-- V0/V1 approved amounts and original reversal snapshots are retained unchanged.
ALTER TABLE finance_receipts DROP CONSTRAINT finance_receipts_settlement_authority_version_chk;
ALTER TABLE finance_receipts ADD CONSTRAINT finance_receipts_settlement_authority_version_chk
    CHECK(settlement_authority_version IN(0,1,2));

-- V515 supplied the nullable snapshot columns; V519 widened and guarded them
-- together with the other financial facts. Do not migrate the same columns twice.
DO $$
BEGIN
    IF (SELECT count(*) FROM pg_attribute WHERE attrelid='finance_receipt_lines'::regclass
            AND NOT attisdropped AND atttypid='numeric'::regtype AND atttypmod=-1
            AND attname IN ('bank_basis_before_original','bank_basis_after_original',
                'bank_basis_before_local','bank_basis_after_local',
                'book_balance_before_local','book_balance_after_local')) <> 6 THEN
        RAISE EXCEPTION 'V2 bank and book snapshots require the exact V519 amount schema';
    END IF;
END $$;
CREATE OR REPLACE FUNCTION fn_guard_customer_actual_book_source()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE source_row ar_ap_ledger%ROWTYPE;receipt_version SMALLINT;before_a NUMERIC;before_b NUMERIC;
BEGIN
    SELECT * INTO source_row FROM ar_ap_ledger WHERE id=NEW.source_ledger_id FOR UPDATE;
    SELECT settlement_authority_version INTO receipt_version FROM finance_receipts WHERE id=source_row.source_doc_id;
    IF receipt_version=2 AND NEW.book_allocation_version<>1 THEN
        RAISE EXCEPTION 'actual-bank prepayment requires an actual-source book allocation' USING ERRCODE='23514';
    END IF;
    IF NEW.book_allocation_version<>1 THEN RETURN NEW;END IF;
    SELECT -source_row.amount_received_original+COALESCE(sum(o.amount_original),0),
      -source_row.amount_received_local+COALESCE(sum(o.source_amount_local),0)
    INTO before_a,before_b FROM customer_open_item_offsets o WHERE o.source_ledger_id=NEW.source_ledger_id AND o.status='APPLIED';
    IF before_a IS NULL OR before_b IS NULL OR (NEW.source_balance_before_original,NEW.source_balance_before_local)
      IS DISTINCT FROM (before_a,before_b) THEN
      RAISE EXCEPTION 'prepayment allocation differs from its original actual source or already allocated balance' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_customer_actual_book_source BEFORE INSERT ON customer_open_item_offsets
FOR EACH ROW EXECUTE FUNCTION fn_guard_customer_actual_book_source();
ALTER TABLE customer_open_item_offsets ENABLE ALWAYS TRIGGER trg_customer_actual_book_source;

DO $$
DECLARE v RECORD;d TEXT;
BEGIN
    FOR v IN SELECT conname,pg_get_constraintdef(oid) definition FROM pg_constraint
        WHERE conrelid='finance_receipts'::regclass AND conname IN
            ('finance_receipts_prepayment_money_chk','finance_receipts_v1_external_evidence_chk')
    LOOP
        d:=regexp_replace(v.definition,'settlement_authority_version\s*=\s*1','settlement_authority_version IN(1,2)','g');
        IF v.conname='finance_receipts_v1_external_evidence_chk' THEN
            d:=replace(d,'(amount_local = round((amount_original * exchange_rate), 4))',
                '(settlement_authority_version=2 OR amount_local=round(amount_original*exchange_rate,4))');
            IF d=v.definition THEN RAISE EXCEPTION 'V416 external-evidence guard definition changed; review V516 forward replacement';END IF;
        END IF;
        EXECUTE format('ALTER TABLE finance_receipts DROP CONSTRAINT %I',v.conname);
        EXECUTE format('ALTER TABLE finance_receipts ADD CONSTRAINT %I %s',v.conname,d);
    END LOOP;
    -- These installed functions and views already protect immutable posting and
    -- reversal identity. Extend their version selector; preserve every other branch.
    FOR v IN SELECT p.oid,p.proname,pg_get_functiondef(p.oid) definition FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f'
        AND p.proname LIKE '%receipt%' AND p.proname<>'fn_assert_finance_receipt_v1_lines'
    LOOP
        d:=regexp_replace(v.definition,'(settlement_authority_version|v_authority_version)\s*=\s*1','\1 IN(1,2)','g');
        d:=regexp_replace(d,'(settlement_authority_version|v_authority_version)\s*<>\s*1','\1 NOT IN(1,2)','g');
        IF d<>v.definition THEN EXECUTE d;END IF;
    END LOOP;
    FOR v IN SELECT c.oid,c.relname,pg_get_viewdef(c.oid,TRUE) definition FROM pg_class c
        JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='v'
        AND c.relname LIKE 'v_receipt%'
    LOOP
        d:=regexp_replace(v.definition,'settlement_authority_version\s*=\s*1','settlement_authority_version IN(1,2)','g');
        IF d<>v.definition THEN EXECUTE format('CREATE OR REPLACE VIEW public.%I AS %s',v.relname,d);END IF;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION fn_guard_receipt_v2_actual_bank()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE is_base BOOLEAN;native_fees NUMERIC;local_fees NUMERIC;
BEGIN
    IF NEW.settlement_authority_version<>2 THEN RETURN NEW;END IF;
    SELECT is_base_currency INTO is_base FROM currencies WHERE id=NEW.account_currency_id;
    native_fees:=CASE WHEN NEW.fee_settlement_mode='DEDUCTED_FROM_PROCEEDS'
        THEN COALESCE(NEW.bank_fee_account_amount,0)+COALESCE(NEW.other_fee_account_amount,0) ELSE 0 END;
    local_fees:=CASE WHEN NEW.fee_settlement_mode='DEDUCTED_FROM_PROCEEDS'
        THEN COALESCE(NEW.bank_fee,0)+COALESCE(NEW.other_fee,0) ELSE 0 END;
    IF NEW.account_amount_local IS DISTINCT FROM NEW.account_amount*NEW.account_exchange_rate
        OR NEW.amount_local IS DISTINCT FROM NEW.account_amount_local+local_fees
        OR COALESCE(NEW.bank_fee,0)<>COALESCE(NEW.bank_fee_account_amount,0)*NEW.fee_account_exchange_rate
        OR COALESCE(NEW.other_fee,0)<>COALESCE(NEW.other_fee_account_amount,0)*NEW.fee_account_exchange_rate
        OR (NEW.account_currency_id=NEW.currency_id AND NEW.amount_original<>NEW.account_amount+native_fees)
        OR (NEW.account_currency_id=NEW.currency_id AND is_base AND NEW.exchange_rate<>1)
        OR NOT fn_financial_amount_is_exact(NEW.account_amount)
        OR NOT fn_financial_amount_is_exact(NEW.amount_original)
        OR NOT fn_financial_amount_is_exact(COALESCE(NEW.bank_fee_account_amount,0))
        OR NOT fn_financial_amount_is_exact(COALESCE(NEW.other_fee_account_amount,0))
        OR NOT fn_financial_book_amount_is_exact(NEW.amount_local)
        OR NOT fn_financial_book_amount_is_exact(NEW.account_amount_local) THEN
        RAISE EXCEPTION 'actual bank native amount, fee facts and frozen book product do not reconcile'
            USING ERRCODE='23514',CONSTRAINT='finance_receipts_v2_actual_bank_guard';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_receipt_v2_actual_bank BEFORE INSERT OR UPDATE ON finance_receipts
FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_v2_actual_bank();

CREATE OR REPLACE FUNCTION fn_assert_finance_receipt_v1_lines(v_receipt_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE r finance_receipts%ROWTYPE;l RECORD;t RECORD;bank_a NUMERIC;bank_b NUMERIC;
BEGIN
    SELECT * INTO r FROM finance_receipts WHERE id=v_receipt_id;
    IF NOT FOUND OR r.settlement_authority_version NOT IN(1,2) THEN RETURN;END IF;
    SELECT count(*) n,count(DISTINCT currency_id) currencies,count(DISTINCT exchange_rate) rates,
        COALESCE(sum(amount_original),0) a,COALESCE(sum(amount_local),0) b,
        COALESCE(sum(abs(COALESCE(write_off_amount,0))+abs(COALESCE(write_off_local,0))),0) wo,
        COALESCE(sum(exchange_diff),0) fx
    INTO t FROM finance_receipt_lines WHERE receipt_id=r.id AND NOT COALESCE(is_deleted,FALSE);
    IF r.receipt_kind='CUSTOMER_PREPAYMENT' THEN
        IF t.n<>0 THEN RAISE EXCEPTION 'customer prepayment cannot contain AR allocation lines' USING ERRCODE='23514';END IF;
        RETURN;
    END IF;
    IF t.n=0 OR t.currencies<>1 OR t.rates<>1 OR t.a<>r.amount_original OR t.b<>r.amount_local
        OR t.wo<>0 OR (t.fx=0)<>(r.gl_fx_style_id IS NULL) THEN
        RAISE EXCEPTION 'receipt original, book and FX totals must match its frozen lines' USING ERRCODE='23514';
    END IF;
    bank_a:=r.amount_original;bank_b:=r.amount_local;
    FOR l IN SELECT * FROM finance_receipt_lines WHERE receipt_id=r.id AND NOT COALESCE(is_deleted,FALSE) ORDER BY line_no,id LOOP
        IF l.currency_id IS DISTINCT FROM r.currency_id OR l.exchange_rate IS DISTINCT FROM r.exchange_rate
          OR (r.settlement_authority_version=1 AND l.amount_local<>round(l.amount_original*l.exchange_rate,4)) THEN
          RAISE EXCEPTION 'receipt line currency/rate differs from its header authority' USING ERRCODE='23514';
        END IF;
        IF r.settlement_authority_version=2 THEN
            IF (l.bank_basis_before_original,l.bank_basis_before_local,l.bank_basis_after_original,l.bank_basis_after_local)
              IS DISTINCT FROM (bank_a,bank_b,bank_a-l.amount_original,bank_b-l.amount_local)
              OR l.amount_local<>fn_financial_book_part(l.amount_original,bank_a,bank_b)
              OR l.exchange_diff IS DISTINCT FROM l.amount_local-l.applied_amount_local
              OR (r.status IN(1,-1) AND (
                l.book_balance_before_local IS NULL OR l.book_balance_after_local IS NULL
                OR l.balance_before_original IS NULL OR l.balance_after_original IS NULL
                OR l.balance_after_original<>l.balance_before_original-l.amount_original
                OR l.book_balance_after_local<>l.book_balance_before_local-l.applied_amount_local
                OR (NOT EXISTS(SELECT 1 FROM ar_ap_source_refs ref WHERE ref.ledger_id=l.applied_ledger_id)
                  AND l.applied_amount_local<>fn_financial_book_part(l.amount_original,l.balance_before_original,l.book_balance_before_local)))) THEN
              RAISE EXCEPTION 'V2 receipt allocation loses its actual bank or original book source ratio/remainder' USING ERRCODE='23514';
            END IF;
            bank_a:=l.bank_basis_after_original;bank_b:=l.bank_basis_after_local;
        END IF;
    END LOOP;
    IF r.settlement_authority_version=2 AND (bank_a<>0 OR bank_b<>0) THEN
        RAISE EXCEPTION 'receipt allocation cannot discard a bank remainder' USING ERRCODE='23514';
    END IF;
END $$;

ALTER TABLE finance_receipt_source_allocations
    ADD COLUMN book_basis_before_original NUMERIC,
    ADD COLUMN book_basis_before_local NUMERIC,
    ADD COLUMN book_basis_after_original NUMERIC,
    ADD COLUMN book_basis_after_local NUMERIC;

CREATE OR REPLACE FUNCTION fn_guard_receipt_v2_source_book_basis()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE version SMALLINT;before_a NUMERIC;before_b NUMERIC;allocated NUMERIC;
BEGIN
    IF TG_OP='UPDATE' THEN
      IF (NEW.book_basis_before_original,NEW.book_basis_before_local,NEW.book_basis_after_original,NEW.book_basis_after_local)
        IS DISTINCT FROM (OLD.book_basis_before_original,OLD.book_basis_before_local,OLD.book_basis_after_original,OLD.book_basis_after_local) THEN
        RAISE EXCEPTION 'receipt source book basis is immutable' USING ERRCODE='55000';
      END IF;
      RETURN NEW;
    END IF;
    SELECT settlement_authority_version INTO version FROM finance_receipts WHERE id=NEW.receipt_id;
    IF version<>2 THEN RETURN NEW;END IF;
    SELECT ref.amount_original-COALESCE((SELECT sum(a.cash_original+a.write_off_original) FROM finance_receipt_source_allocations a
        WHERE a.source_ref_id=ref.id AND a.status='APPLIED'),0)-COALESCE((SELECT sum(o.amount_original) FROM customer_open_item_offsets o
        WHERE o.target_source_ref_id=ref.id AND o.status='APPLIED'),0),
      ref.amount_local-COALESCE((SELECT sum(a.applied_book_local) FROM finance_receipt_source_allocations a
        WHERE a.source_ref_id=ref.id AND a.status='APPLIED'),0)-COALESCE((SELECT sum(o.target_amount_local) FROM customer_open_item_offsets o
        WHERE o.target_source_ref_id=ref.id AND o.status='APPLIED'),0)
    INTO before_a,before_b FROM ar_ap_source_refs ref WHERE ref.id=NEW.source_ref_id FOR UPDATE;
    allocated:=NEW.cash_original+NEW.write_off_original;
    IF (NEW.book_basis_before_original,NEW.book_basis_before_local,NEW.book_basis_after_original,NEW.book_basis_after_local)
      IS DISTINCT FROM (before_a,before_b,before_a-allocated,before_b-NEW.applied_book_local)
      OR NEW.applied_book_local<>fn_financial_book_part(allocated,before_a,before_b) THEN
      RAISE EXCEPTION 'receipt source book allocation must conserve the original order ratio and remainder' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_receipt_v2_source_book_basis BEFORE INSERT OR UPDATE ON finance_receipt_source_allocations
FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_v2_source_book_basis();
ALTER TABLE finance_receipt_source_allocations ENABLE ALWAYS TRIGGER trg_receipt_v2_source_book_basis;

CREATE OR REPLACE FUNCTION fn_guard_receipt_v2_basis_immutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM finance_receipts WHERE id=OLD.receipt_id AND status IN(1,-1)) AND
        (NEW.bank_basis_before_original,NEW.bank_basis_before_local,NEW.bank_basis_after_original,NEW.bank_basis_after_local,
         NEW.book_balance_before_local,NEW.book_balance_after_local) IS DISTINCT FROM
        (OLD.bank_basis_before_original,OLD.bank_basis_before_local,OLD.bank_basis_after_original,OLD.bank_basis_after_local,
         OLD.book_balance_before_local,OLD.book_balance_after_local) THEN
        RAISE EXCEPTION 'approved receipt source allocation basis is immutable' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_receipt_v2_basis_immutable BEFORE UPDATE ON finance_receipt_lines
FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_v2_basis_immutable();

ALTER TABLE finance_receipts ENABLE ALWAYS TRIGGER trg_receipt_v2_actual_bank;
ALTER TABLE finance_receipt_lines ENABLE ALWAYS TRIGGER trg_receipt_v2_basis_immutable;
COMMENT ON COLUMN finance_receipts.settlement_authority_version IS
    '0 legacy; 1 reviewed quote-based history; 2 actual bank net plus actual deducted fees, conserving frozen source allocations';

-- Existing confirmed applications keep their original quote-era snapshots.
-- New applications of a V2 bank fact use its actual remaining book balance.
ALTER TABLE customer_open_item_offsets ADD COLUMN book_allocation_version SMALLINT NOT NULL DEFAULT 0
    CHECK(book_allocation_version IN(0,1));
DO $$
DECLARE old_check TEXT;definition TEXT;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO old_check FROM pg_constraint
      WHERE conrelid='customer_open_item_offsets'::regclass AND conname='customer_offsets_rate_identity_chk';
    IF old_check IS NULL THEN RAISE EXCEPTION 'customer source allocation history guard is missing';END IF;
    ALTER TABLE customer_open_item_offsets DROP CONSTRAINT customer_offsets_rate_identity_chk;
    EXECUTE 'ALTER TABLE customer_open_item_offsets ADD CONSTRAINT customer_offsets_rate_identity_chk CHECK('
        ||'(book_allocation_version=0 AND ('||substring(old_check FROM 7)||')) OR '
        ||'(book_allocation_version=1 AND '
        ||'source_amount_local=fn_financial_book_part(amount_original,abs(source_balance_before_original),abs(source_balance_before_local)) AND '
        ||'target_amount_local=fn_financial_book_part(amount_original,target_ref_balance_before_original,target_ref_balance_before_local)))';
    SELECT pg_get_functiondef('fn_guard_customer_offset_line_immutable()'::regprocedure) INTO definition;
    IF position('OR NEW.exchange_difference IS DISTINCT FROM OLD.exchange_difference' IN definition)=0 THEN
        RAISE EXCEPTION 'customer source allocation immutable guard changed; review book-version extension';
    END IF;
    EXECUTE replace(definition,'OR NEW.exchange_difference IS DISTINCT FROM OLD.exchange_difference',
        'OR NEW.book_allocation_version IS DISTINCT FROM OLD.book_allocation_version OR NEW.exchange_difference IS DISTINCT FROM OLD.exchange_difference');
END $$;
