-- V382: exact per-SALES_ORDER source balances for multi-order AR tail absorption.
DO $v382$
BEGIN
    IF EXISTS(SELECT 1 FROM customer_open_item_offsets) THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='V382 requires customer_open_item_offsets to be empty; the feature was not deployable before source-ref snapshots existed';
    END IF;
END
$v382$;

ALTER TABLE customer_open_item_offsets
    ADD COLUMN target_ref_balance_before_original NUMERIC(18,4) NOT NULL,
    ADD COLUMN target_ref_balance_after_original NUMERIC(18,4) NOT NULL,
    ADD COLUMN target_ref_balance_before_local NUMERIC(18,4) NOT NULL,
    ADD COLUMN target_ref_balance_after_local NUMERIC(18,4) NOT NULL,
    ADD CONSTRAINT customer_offsets_target_ref_snapshot_chk CHECK(
        target_ref_balance_before_original>0
        AND target_ref_balance_after_original>=0
        AND target_ref_balance_after_original
            =target_ref_balance_before_original-amount_original
        AND target_ref_balance_before_local>0
        AND target_ref_balance_after_local>=0
        AND target_ref_balance_after_local
            =target_ref_balance_before_local-target_amount_local);

ALTER TABLE customer_open_item_offsets
    DROP CONSTRAINT customer_offsets_rate_identity_chk;
ALTER TABLE customer_open_item_offsets
    ADD CONSTRAINT customer_offsets_rate_identity_chk CHECK(
        (source_amount_local=ROUND(amount_original*source_rate,4)
         OR (source_balance_after_original=0 AND source_balance_after_local=0
             AND source_amount_local=ABS(source_balance_before_local)))
        AND
        (target_amount_local=ROUND(amount_original*target_rate,4)
         OR (target_ref_balance_after_original=0 AND target_ref_balance_after_local=0
             AND target_amount_local=target_ref_balance_before_local)));

CREATE OR REPLACE FUNCTION fn_guard_customer_open_item_offset()
RETURNS TRIGGER AS $v382$
DECLARE
    v_batch_client UUID; v_batch_currency UUID; v_batch_date DATE; v_batch_status TEXT;
    v_source_client UUID; v_source_currency UUID; v_source_kind TEXT; v_source_type TEXT;
    v_source_status SMALLINT; v_source_deleted BOOLEAN; v_source_direction TEXT; v_source_rate NUMERIC(18,6);
    v_target_client UUID; v_target_currency UUID; v_target_kind TEXT;
    v_target_status SMALLINT; v_target_deleted BOOLEAN; v_target_direction TEXT; v_target_rate NUMERIC(18,6);
    v_ref_ledger UUID; v_ref_type TEXT; v_ref_order UUID;
    v_bound_order UUID; v_receipt_kind TEXT; v_receipt_status SMALLINT; v_receipt_deleted BOOLEAN;
    v_order_client UUID; v_order_currency UUID;
    v_ref_before_original NUMERIC(18,4); v_ref_before_local NUMERIC(18,4);
BEGIN
    SELECT client_id,currency_id,effective_date,status
      INTO v_batch_client,v_batch_currency,v_batch_date,v_batch_status
    FROM customer_open_item_offset_batches WHERE id=NEW.offset_batch_id;
    SELECT client_id,currency_id,open_item_kind,source_doc_type,status,is_deleted,direction,exchange_rate
      INTO v_source_client,v_source_currency,v_source_kind,v_source_type,
           v_source_status,v_source_deleted,v_source_direction,v_source_rate
    FROM ar_ap_ledger WHERE id=NEW.source_ledger_id;
    SELECT client_id,currency_id,open_item_kind,status,is_deleted,direction,exchange_rate
      INTO v_target_client,v_target_currency,v_target_kind,
           v_target_status,v_target_deleted,v_target_direction,v_target_rate
    FROM ar_ap_ledger WHERE id=NEW.target_ledger_id;
    SELECT ledger_id,source_type,source_id
      INTO v_ref_ledger,v_ref_type,v_ref_order
    FROM ar_ap_source_refs WHERE id=NEW.target_source_ref_id;
    SELECT receipt.sales_order_id,receipt.receipt_kind,receipt.status,receipt.is_deleted
      INTO v_bound_order,v_receipt_kind,v_receipt_status,v_receipt_deleted
    FROM ar_ap_ledger ledger JOIN finance_receipts receipt ON receipt.id=ledger.source_doc_id
    WHERE ledger.id=NEW.source_ledger_id AND ledger.source_doc_type='DIRECT_RECEIPT';
    SELECT client_id,currency_id INTO v_order_client,v_order_currency
    FROM sales_orders WHERE id=NEW.sales_order_id;
    IF v_batch_client IS NULL OR v_batch_currency IS NULL OR v_batch_status<>'APPLIED'
       OR NEW.client_id<>v_batch_client OR NEW.currency_id<>v_batch_currency
       OR NEW.effective_date<>v_batch_date
       OR v_source_client<>NEW.client_id OR v_target_client<>NEW.client_id
       OR v_source_currency<>NEW.currency_id OR v_target_currency<>NEW.currency_id
       OR v_source_kind<>'CUSTOMER_PREPAYMENT' OR v_source_type<>'DIRECT_RECEIPT'
       OR v_source_status<>1 OR COALESCE(v_source_deleted,FALSE) OR v_source_direction<>'AR'
       OR v_source_rate IS DISTINCT FROM NEW.source_rate
       OR v_receipt_kind<>'CUSTOMER_PREPAYMENT' OR v_receipt_status<>1
       OR COALESCE(v_receipt_deleted,FALSE)
       OR v_target_kind<>'RECEIVABLE' OR v_target_status<>1
       OR COALESCE(v_target_deleted,FALSE) OR v_target_direction<>'AR'
       OR v_target_rate IS DISTINCT FROM NEW.target_rate
       OR v_ref_ledger<>NEW.target_ledger_id OR v_ref_type<>'SALES_ORDER'
       OR v_ref_order<>NEW.sales_order_id
       OR v_order_client<>NEW.client_id OR v_order_currency IS DISTINCT FROM NEW.currency_id
       OR (v_bound_order IS NOT NULL AND v_bound_order<>NEW.sales_order_id) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='customer prepayment offset crosses active client, currency, order, rate, or AR identities',
            CONSTRAINT='customer_open_item_offsets_identity_guard';
    END IF;
    IF TG_OP='INSERT' THEN
        SELECT ref.amount_original
                   -COALESCE((SELECT SUM(a.cash_original+a.write_off_original)
                              FROM finance_receipt_source_allocations a
                              WHERE a.source_ref_id=ref.id AND a.status='APPLIED'),0)
                   -COALESCE((SELECT SUM(o.amount_original)
                              FROM customer_open_item_offsets o
                              WHERE o.target_source_ref_id=ref.id AND o.status='APPLIED'),0),
               ref.amount_local
                   -COALESCE((SELECT SUM(a.applied_book_local)
                              FROM finance_receipt_source_allocations a
                              WHERE a.source_ref_id=ref.id AND a.status='APPLIED'),0)
                   -COALESCE((SELECT SUM(o.target_amount_local)
                              FROM customer_open_item_offsets o
                              WHERE o.target_source_ref_id=ref.id AND o.status='APPLIED'),0)
          INTO v_ref_before_original,v_ref_before_local
        FROM ar_ap_source_refs ref WHERE ref.id=NEW.target_source_ref_id;
        IF NEW.target_ref_balance_before_original IS DISTINCT FROM v_ref_before_original
           OR NEW.target_ref_balance_before_local IS DISTINCT FROM v_ref_before_local THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='customer prepayment target source-ref before balances do not match current authoritative capacity',
                CONSTRAINT='customer_open_item_offsets_source_ref_snapshot_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$v382$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_guard_customer_offset_line_immutable()
RETURNS TRIGGER AS $v382$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='customer prepayment offset line is immutable; append a reversal';
    END IF;
    IF NEW.offset_batch_id IS DISTINCT FROM OLD.offset_batch_id
       OR NEW.line_sequence IS DISTINCT FROM OLD.line_sequence
       OR NEW.client_id IS DISTINCT FROM OLD.client_id
       OR NEW.currency_id IS DISTINCT FROM OLD.currency_id
       OR NEW.source_ledger_id IS DISTINCT FROM OLD.source_ledger_id
       OR NEW.target_ledger_id IS DISTINCT FROM OLD.target_ledger_id
       OR NEW.target_source_ref_id IS DISTINCT FROM OLD.target_source_ref_id
       OR NEW.sales_order_id IS DISTINCT FROM OLD.sales_order_id
       OR NEW.amount_original IS DISTINCT FROM OLD.amount_original
       OR NEW.source_amount_local IS DISTINCT FROM OLD.source_amount_local
       OR NEW.target_amount_local IS DISTINCT FROM OLD.target_amount_local
       OR NEW.exchange_difference IS DISTINCT FROM OLD.exchange_difference
       OR NEW.source_rate IS DISTINCT FROM OLD.source_rate
       OR NEW.target_rate IS DISTINCT FROM OLD.target_rate
       OR NEW.source_balance_before_original IS DISTINCT FROM OLD.source_balance_before_original
       OR NEW.source_balance_after_original IS DISTINCT FROM OLD.source_balance_after_original
       OR NEW.target_balance_before_original IS DISTINCT FROM OLD.target_balance_before_original
       OR NEW.target_balance_after_original IS DISTINCT FROM OLD.target_balance_after_original
       OR NEW.source_balance_before_local IS DISTINCT FROM OLD.source_balance_before_local
       OR NEW.source_balance_after_local IS DISTINCT FROM OLD.source_balance_after_local
       OR NEW.target_balance_before_local IS DISTINCT FROM OLD.target_balance_before_local
       OR NEW.target_balance_after_local IS DISTINCT FROM OLD.target_balance_after_local
       OR NEW.target_ref_balance_before_original IS DISTINCT FROM OLD.target_ref_balance_before_original
       OR NEW.target_ref_balance_after_original IS DISTINCT FROM OLD.target_ref_balance_after_original
       OR NEW.target_ref_balance_before_local IS DISTINCT FROM OLD.target_ref_balance_before_local
       OR NEW.target_ref_balance_after_local IS DISTINCT FROM OLD.target_ref_balance_after_local
       OR NEW.effective_date IS DISTINCT FROM OLD.effective_date
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='customer prepayment offset monetary and creation snapshots are immutable',
            CONSTRAINT='customer_offset_line_immutable_guard';
    END IF;
    IF OLD.status='APPLIED' AND NEW.status='REVERSED' THEN
        IF OLD.reversed_at IS NOT NULL OR OLD.reversed_by IS NOT NULL
           OR NEW.reversed_at IS NULL OR NEW.reversed_by IS NULL
           OR NEW.row_version<>OLD.row_version+1 THEN
            RAISE EXCEPTION USING ERRCODE='55000',
                MESSAGE='customer prepayment offset line reversal must be a single versioned transition';
        END IF;
    ELSIF OLD.status=NEW.status THEN
        IF NEW.row_version<>OLD.row_version
           OR NEW.reversed_at IS DISTINCT FROM OLD.reversed_at
           OR NEW.reversed_by IS DISTINCT FROM OLD.reversed_by THEN
            RAISE EXCEPTION USING ERRCODE='55000',
                MESSAGE='customer prepayment offset line reversal facts cannot be rewritten';
        END IF;
    ELSE
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='customer prepayment offset line status transition is not allowed';
    END IF;
    RETURN NEW;
END;
$v382$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_assert_ar_source_ref_capacity(v_source_ref_id UUID)
RETURNS VOID AS $v382$
DECLARE
    v_authorized_original NUMERIC(18,4); v_consumed_original NUMERIC(18,4);
    v_authorized_local NUMERIC(18,4); v_consumed_local NUMERIC(18,4);
BEGIN
    SELECT amount_original,amount_local
      INTO v_authorized_original,v_authorized_local
    FROM ar_ap_source_refs WHERE id=v_source_ref_id AND source_type='SALES_ORDER';
    IF v_authorized_original IS NULL OR v_authorized_local IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='sales-order AR source reference is missing';
    END IF;
    SELECT COALESCE((SELECT SUM(cash_original+write_off_original)
                     FROM finance_receipt_source_allocations
                     WHERE source_ref_id=v_source_ref_id AND status='APPLIED'),0)
         + COALESCE((SELECT SUM(amount_original) FROM customer_open_item_offsets
                     WHERE target_source_ref_id=v_source_ref_id AND status='APPLIED'),0),
           COALESCE((SELECT SUM(applied_book_local)
                     FROM finance_receipt_source_allocations
                     WHERE source_ref_id=v_source_ref_id AND status='APPLIED'),0)
         + COALESCE((SELECT SUM(target_amount_local) FROM customer_open_item_offsets
                     WHERE target_source_ref_id=v_source_ref_id AND status='APPLIED'),0)
      INTO v_consumed_original,v_consumed_local;
    IF v_authorized_original<0 OR v_authorized_local<0
       OR v_consumed_original>v_authorized_original
       OR v_consumed_local>v_authorized_local THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='cash, write-off and prepayment applications exceed immutable sales-order AR source original/local amounts',
            CONSTRAINT='ar_source_ref_application_capacity_guard';
    END IF;
END;
$v382$ LANGUAGE plpgsql;
