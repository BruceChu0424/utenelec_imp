-- V379: finance-owned customer advances and exact order allocation facts.

INSERT INTO payment_styles(
    id,code,name,category,level,sort_order,path,is_receipt,is_payment,status,auto_created)
VALUES(
    '37900000-0000-4000-8100-000000000001','SYS-CUSTOMER-ADVANCE','客户预收款',
    'LIABILITY',0,940,'/SYS-CUSTOMER-ADVANCE/',TRUE,FALSE,'使用',TRUE)
ON CONFLICT(id) DO NOTHING;

INSERT INTO system_posting_style_roles(role_key,style_id,required_category,description)
VALUES(
    'CUSTOMER_ADVANCE','37900000-0000-4000-8100-000000000001','LIABILITY',
    '客户预收现金负债；只有显式转销才可借记并冲减正式应收')
ON CONFLICT(role_key) DO NOTHING;

ALTER TABLE finance_receipts
    ADD COLUMN receipt_kind TEXT,
    ADD COLUMN sales_order_id UUID;

UPDATE finance_receipts receipt
SET receipt_kind=CASE WHEN EXISTS(
        SELECT 1 FROM finance_receipt_lines line
        WHERE line.receipt_id=receipt.id AND COALESCE(line.is_deleted,FALSE)=FALSE)
    THEN 'AR_SETTLEMENT' ELSE 'CUSTOMER_PREPAYMENT' END;

ALTER TABLE finance_receipts
    ALTER COLUMN receipt_kind SET NOT NULL,
    ADD CONSTRAINT finance_receipts_kind_chk CHECK(
        receipt_kind IN('AR_SETTLEMENT','CUSTOMER_PREPAYMENT')),
    ADD CONSTRAINT finance_receipts_order_kind_chk CHECK(
        sales_order_id IS NULL OR receipt_kind='CUSTOMER_PREPAYMENT'),
    ADD CONSTRAINT finance_receipts_prepayment_money_chk CHECK(
        receipt_kind<>'CUSTOMER_PREPAYMENT'
        OR (amount_original>0 AND amount_local>0 AND exchange_rate>0
            AND COALESCE(bank_fee,0)=0 AND COALESCE(other_fee,0)=0)) NOT VALID;

ALTER TABLE finance_receipts
    ADD CONSTRAINT fk_finance_receipts_sales_order
    FOREIGN KEY(sales_order_id) REFERENCES sales_orders(id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE finance_receipts VALIDATE CONSTRAINT fk_finance_receipts_sales_order;

CREATE INDEX idx_finance_receipts_sales_order
    ON finance_receipts(sales_order_id,bill_date,id)
    WHERE sales_order_id IS NOT NULL;
CREATE INDEX idx_finance_receipts_prepayment
    ON finance_receipts(client_id,currency_id,bill_date,id)
    WHERE receipt_kind='CUSTOMER_PREPAYMENT' AND status=1 AND is_deleted=FALSE;

CREATE OR REPLACE FUNCTION fn_guard_finance_receipt_order()
RETURNS TRIGGER AS $$
DECLARE v_client UUID; v_currency UUID; v_status SMALLINT; v_deleted BOOLEAN;
BEGIN
    IF NEW.sales_order_id IS NULL THEN RETURN NEW; END IF;
    SELECT client_id,currency_id,status,is_deleted
      INTO v_client,v_currency,v_status,v_deleted
    FROM sales_orders WHERE id=NEW.sales_order_id;
    IF v_client IS NULL OR COALESCE(v_deleted,FALSE) OR v_status<>1
       OR v_client<>NEW.client_id OR v_currency IS DISTINCT FROM NEW.currency_id THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='bound customer prepayment requires an active approved sales order with the same client and currency',
            CONSTRAINT='finance_receipts_sales_order_identity_guard';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_finance_receipt_order
    BEFORE INSERT OR UPDATE OF sales_order_id,client_id,currency_id,receipt_kind
    ON finance_receipts FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_receipt_order();

CREATE OR REPLACE FUNCTION fn_guard_finance_receipt_kind_lines()
RETURNS TRIGGER AS $$
DECLARE v_receipt_id UUID; v_kind TEXT; v_line_count BIGINT;
BEGIN
    IF TG_TABLE_NAME='finance_receipts' THEN
        v_receipt_id:=COALESCE(
            NULLIF(to_jsonb(NEW)->>'id','')::UUID,
            NULLIF(to_jsonb(OLD)->>'id','')::UUID);
    ELSE
        v_receipt_id:=COALESCE(
            NULLIF(to_jsonb(NEW)->>'receipt_id','')::UUID,
            NULLIF(to_jsonb(OLD)->>'receipt_id','')::UUID);
    END IF;
    SELECT receipt_kind INTO v_kind FROM finance_receipts WHERE id=v_receipt_id;
    IF v_kind IS NULL THEN RETURN NULL; END IF;
    SELECT COUNT(*) INTO v_line_count FROM finance_receipt_lines
    WHERE receipt_id=v_receipt_id AND COALESCE(is_deleted,FALSE)=FALSE;
    IF (v_kind='AR_SETTLEMENT' AND v_line_count=0)
       OR (v_kind='CUSTOMER_PREPAYMENT' AND v_line_count<>0) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance receipt kind does not match its active settlement lines',
            CONSTRAINT='finance_receipts_kind_lines_guard';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
CREATE CONSTRAINT TRIGGER trg_finance_receipts_kind_lines
    AFTER INSERT OR UPDATE OF receipt_kind ON finance_receipts
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_guard_finance_receipt_kind_lines();
CREATE CONSTRAINT TRIGGER trg_finance_receipt_lines_kind
    AFTER INSERT OR UPDATE OR DELETE ON finance_receipt_lines
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_guard_finance_receipt_kind_lines();

CREATE OR REPLACE FUNCTION fn_guard_finance_receipt_money_fact()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status NOT IN(1,-1) THEN RETURN NEW; END IF;
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='approved or reversed finance receipt is an immutable money fact';
    END IF;
    IF NEW.receipt_kind IS DISTINCT FROM OLD.receipt_kind
       OR NEW.sales_order_id IS DISTINCT FROM OLD.sales_order_id
       OR NEW.client_id IS DISTINCT FROM OLD.client_id
       OR NEW.currency_id IS DISTINCT FROM OLD.currency_id
       OR NEW.exchange_rate IS DISTINCT FROM OLD.exchange_rate
       OR NEW.amount_original IS DISTINCT FROM OLD.amount_original
       OR NEW.amount_local IS DISTINCT FROM OLD.amount_local
       OR NEW.bill_no IS DISTINCT FROM OLD.bill_no
       OR NEW.bill_date IS DISTINCT FROM OLD.bill_date
       OR NEW.account_id IS DISTINCT FROM OLD.account_id
       OR NEW.counterpart_account_id IS DISTINCT FROM OLD.counterpart_account_id
       OR NEW.bank_fee IS DISTINCT FROM OLD.bank_fee
       OR NEW.other_fee IS DISTINCT FROM OLD.other_fee
       OR NEW.other_fee_style_id IS DISTINCT FROM OLD.other_fee_style_id
       OR NEW.receipt_method_id IS DISTINCT FROM OLD.receipt_method_id
       OR NEW.receipt_method_legacy_id IS DISTINCT FROM OLD.receipt_method_legacy_id
       OR NEW.invoice_no IS DISTINCT FROM OLD.invoice_no
       OR (OLD.status=1 AND NEW.status NOT IN(1,-1))
       OR (OLD.status=-1 AND NEW.status<>-1) THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='approved or reversed finance receipt identity and money snapshots are immutable',
            CONSTRAINT='finance_receipts_money_fact_immutable_guard';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_finance_receipt_money_fact
    BEFORE UPDATE OR DELETE ON finance_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_receipt_money_fact();

ALTER TABLE ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_open_item_kind_chk;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_open_item_kind_chk CHECK(
    open_item_kind IN(
        'RECEIVABLE','CUSTOMER_PREPAYMENT','PAYABLE','CREDIT','CLAIM_CREDIT','PREPAYMENT'));

ALTER TABLE ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_open_item_direction_chk;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_open_item_direction_chk CHECK(
    (direction='AR' AND open_item_kind IN('RECEIVABLE','CUSTOMER_PREPAYMENT'))
    OR (direction='AP' AND open_item_kind NOT IN('RECEIVABLE','CUSTOMER_PREPAYMENT')));

ALTER TABLE ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_offset_sign_chk;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_offset_sign_chk CHECK(
    (open_item_kind IN('PAYABLE','RECEIVABLE')
        AND amount_offset_original>=0 AND amount_offset_local>=0)
    OR (open_item_kind IN('CREDIT','CLAIM_CREDIT','PREPAYMENT','CUSTOMER_PREPAYMENT')
        AND amount_offset_original<=0 AND amount_offset_local<=0));

CREATE OR REPLACE FUNCTION fn_derive_ar_ap_open_item_metadata()
RETURNS TRIGGER AS $$
BEGIN
    NEW.business_type := CASE
        WHEN NEW.direction='AR' THEN 'SALES'
        WHEN NEW.source_doc_type IN('PURCHASE_RECEIPT','PURCHASE_RETURN') THEN 'PURCHASE'
        WHEN NEW.source_doc_type IN(
            'SUBCONTRACT_RECEIPT','SUBCONTRACT_RETURN','SUBCONTRACT_WASTE',
            'SUBCONTRACT_LOSS_OFFSET') THEN 'SUBCONTRACT'
        ELSE 'DIRECT'
    END;
    NEW.open_item_kind := CASE
        WHEN NEW.direction='AR' AND NEW.source_doc_type='DIRECT_RECEIPT'
            THEN 'CUSTOMER_PREPAYMENT'
        WHEN NEW.direction='AR' THEN 'RECEIVABLE'
        WHEN NEW.source_doc_type='DIRECT_PAYMENT' THEN 'PREPAYMENT'
        WHEN NEW.source_doc_type IN('SUBCONTRACT_WASTE','SUBCONTRACT_LOSS_OFFSET')
            THEN 'CLAIM_CREDIT'
        WHEN COALESCE(NEW.amount_original_local,0)<0 THEN 'CREDIT'
        ELSE 'PAYABLE'
    END;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

UPDATE ar_ap_ledger SET open_item_kind=open_item_kind
WHERE direction='AR' AND source_doc_type='DIRECT_RECEIPT';

ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_customer_prepayment_shape_chk CHECK(
    direction<>'AR' OR open_item_kind<>'CUSTOMER_PREPAYMENT' OR (
        source_doc_type='DIRECT_RECEIPT'
        AND amount_original_local=0 AND amount_original=0
        AND amount_received_original IS NOT NULL AND amount_received_original>0
        AND amount_received_local IS NOT NULL AND amount_received_local>0
        AND amount_write_off_original=0 AND amount_write_off_local=0
        AND amount_balance_original<=0 AND amount_balance<=0)) NOT VALID;

CREATE INDEX idx_ar_ap_customer_prepayment
    ON ar_ap_ledger(client_id,currency_id,bill_date,id)
    WHERE direction='AR' AND open_item_kind='CUSTOMER_PREPAYMENT'
      AND status=1 AND is_deleted=FALSE;

ALTER TABLE ar_ap_source_refs ADD COLUMN source_sequence INTEGER;
WITH ranked AS(
    SELECT id,ROW_NUMBER() OVER(
        PARTITION BY ledger_id ORDER BY source_no,source_id,id)::INTEGER seq
    FROM ar_ap_source_refs)
UPDATE ar_ap_source_refs ref SET source_sequence=ranked.seq
FROM ranked WHERE ranked.id=ref.id;
ALTER TABLE ar_ap_source_refs
    ALTER COLUMN source_sequence SET NOT NULL,
    ADD CONSTRAINT ar_ap_source_refs_sequence_chk CHECK(source_sequence>0),
    ADD CONSTRAINT ar_ap_source_refs_ledger_sequence_uk UNIQUE(ledger_id,source_sequence);

CREATE TABLE customer_open_item_offset_batches(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
    currency_id UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    effective_date DATE NOT NULL,
    status TEXT NOT NULL DEFAULT 'APPLIED' CHECK(status IN('APPLIED','REVERSED')),
    row_version BIGINT NOT NULL DEFAULT 0 CHECK(row_version>=0),
    idempotency_key TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    reason TEXT NOT NULL,
    reverse_reason TEXT,
    applied_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    reversed_by UUID REFERENCES users(id) ON DELETE RESTRICT,
    reversed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by UUID REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT customer_offset_batches_idempotency_uk UNIQUE(idempotency_key),
    CONSTRAINT customer_offset_batches_idempotency_key_chk CHECK(btrim(idempotency_key)<>''),
    CONSTRAINT customer_offset_batches_status_shape_chk CHECK(
        (status='APPLIED' AND reversed_at IS NULL AND reversed_by IS NULL
            AND reverse_reason IS NULL)
        OR (status='REVERSED' AND reversed_at IS NOT NULL AND reversed_by IS NOT NULL
            AND btrim(reverse_reason)<>'')),
    CONSTRAINT customer_offset_batches_reason_chk CHECK(btrim(reason)<>''),
    CONSTRAINT customer_offset_batches_hash_chk CHECK(btrim(request_hash)<>'')
);

CREATE OR REPLACE FUNCTION fn_guard_customer_offset_batch_immutable()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='customer prepayment offset batch is immutable; append a reversal';
    END IF;
    IF NEW.client_id IS DISTINCT FROM OLD.client_id
       OR NEW.currency_id IS DISTINCT FROM OLD.currency_id
       OR NEW.effective_date IS DISTINCT FROM OLD.effective_date
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
       OR NEW.request_hash IS DISTINCT FROM OLD.request_hash
       OR NEW.reason IS DISTINCT FROM OLD.reason
       OR NEW.applied_by IS DISTINCT FROM OLD.applied_by
       OR NEW.applied_at IS DISTINCT FROM OLD.applied_at
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='customer prepayment offset batch identity and creation facts are immutable',
            CONSTRAINT='customer_offset_batch_immutable_guard';
    END IF;
    IF OLD.status='APPLIED' AND NEW.status='REVERSED' THEN
        IF OLD.reversed_at IS NOT NULL OR OLD.reversed_by IS NOT NULL OR OLD.reverse_reason IS NOT NULL
           OR NEW.reversed_at IS NULL OR NEW.reversed_by IS NULL
           OR NEW.reverse_reason IS NULL OR btrim(NEW.reverse_reason)=''
           OR NEW.row_version<>OLD.row_version+1 THEN
            RAISE EXCEPTION USING ERRCODE='55000',
                MESSAGE='customer prepayment offset reversal must be a single versioned transition';
        END IF;
    ELSIF OLD.status=NEW.status THEN
        IF NEW.row_version<>OLD.row_version
           OR NEW.reversed_at IS DISTINCT FROM OLD.reversed_at
           OR NEW.reversed_by IS DISTINCT FROM OLD.reversed_by
           OR NEW.reverse_reason IS DISTINCT FROM OLD.reverse_reason THEN
            RAISE EXCEPTION USING ERRCODE='55000',
                MESSAGE='customer prepayment offset reversal facts cannot be rewritten';
        END IF;
    ELSE
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='customer prepayment offset status transition is not allowed';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_customer_offset_batch_immutable
    BEFORE UPDATE OR DELETE ON customer_open_item_offset_batches
    FOR EACH ROW EXECUTE FUNCTION fn_guard_customer_offset_batch_immutable();

CREATE TABLE customer_open_item_offsets(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    offset_batch_id UUID NOT NULL REFERENCES customer_open_item_offset_batches(id) ON DELETE RESTRICT,
    line_sequence INTEGER NOT NULL CHECK(line_sequence>0),
    client_id UUID NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
    currency_id UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    source_ledger_id UUID NOT NULL REFERENCES ar_ap_ledger(id) ON DELETE RESTRICT,
    target_ledger_id UUID NOT NULL REFERENCES ar_ap_ledger(id) ON DELETE RESTRICT,
    target_source_ref_id UUID NOT NULL REFERENCES ar_ap_source_refs(id) ON DELETE RESTRICT,
    sales_order_id UUID NOT NULL REFERENCES sales_orders(id) ON DELETE RESTRICT,
    amount_original NUMERIC(18,4) NOT NULL CHECK(amount_original>0),
    source_amount_local NUMERIC(18,4) NOT NULL CHECK(source_amount_local>0),
    target_amount_local NUMERIC(18,4) NOT NULL CHECK(target_amount_local>0),
    exchange_difference NUMERIC(18,4) NOT NULL,
    source_rate NUMERIC(18,6) NOT NULL CHECK(source_rate>0),
    target_rate NUMERIC(18,6) NOT NULL CHECK(target_rate>0),
    source_balance_before_original NUMERIC(18,4) NOT NULL,
    source_balance_after_original NUMERIC(18,4) NOT NULL,
    target_balance_before_original NUMERIC(18,4) NOT NULL,
    target_balance_after_original NUMERIC(18,4) NOT NULL,
    source_balance_before_local NUMERIC(18,4) NOT NULL,
    source_balance_after_local NUMERIC(18,4) NOT NULL,
    target_balance_before_local NUMERIC(18,4) NOT NULL,
    target_balance_after_local NUMERIC(18,4) NOT NULL,
    effective_date DATE NOT NULL,
    status TEXT NOT NULL DEFAULT 'APPLIED' CHECK(status IN('APPLIED','REVERSED')),
    row_version BIGINT NOT NULL DEFAULT 0 CHECK(row_version>=0),
    reversed_by UUID REFERENCES users(id) ON DELETE RESTRICT,
    reversed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by UUID REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT customer_offsets_batch_sequence_uk UNIQUE(offset_batch_id,line_sequence),
    CONSTRAINT customer_offsets_batch_target_source_uk UNIQUE(offset_batch_id,target_ledger_id,target_source_ref_id),
    CONSTRAINT customer_offsets_distinct_ledger_chk CHECK(source_ledger_id<>target_ledger_id),
    CONSTRAINT customer_offsets_rate_identity_chk CHECK(
        (source_amount_local=ROUND(amount_original*source_rate,4)
         OR (source_balance_after_original=0 AND source_balance_after_local=0
             AND source_amount_local=ABS(source_balance_before_local)))
        AND
        (target_amount_local=ROUND(amount_original*target_rate,4)
         OR (target_balance_after_original=0 AND target_balance_after_local=0
             AND target_amount_local=target_balance_before_local))),
    CONSTRAINT customer_offsets_fx_identity_chk CHECK(
        exchange_difference=source_amount_local-target_amount_local),
    CONSTRAINT customer_offsets_original_snapshot_chk CHECK(
        source_balance_before_original<0 AND source_balance_after_original<=0
        AND source_balance_after_original=source_balance_before_original+amount_original
        AND target_balance_before_original>0 AND target_balance_after_original>=0
        AND target_balance_after_original=target_balance_before_original-amount_original),
    CONSTRAINT customer_offsets_local_snapshot_chk CHECK(
        source_balance_before_local<0 AND source_balance_after_local<=0
        AND source_balance_after_local=source_balance_before_local+source_amount_local
        AND target_balance_before_local>0 AND target_balance_after_local>=0
        AND target_balance_after_local=target_balance_before_local-target_amount_local),
    CONSTRAINT customer_offsets_status_shape_chk CHECK(
        (status='APPLIED' AND reversed_at IS NULL AND reversed_by IS NULL)
        OR (status='REVERSED' AND reversed_at IS NOT NULL AND reversed_by IS NOT NULL))
);
CREATE INDEX idx_customer_offsets_source
    ON customer_open_item_offsets(source_ledger_id,status,line_sequence);
CREATE INDEX idx_customer_offsets_target
    ON customer_open_item_offsets(target_ledger_id,target_source_ref_id,status);
CREATE INDEX idx_customer_offsets_order
    ON customer_open_item_offsets(sales_order_id,effective_date,status);

CREATE OR REPLACE FUNCTION fn_guard_customer_open_item_offset()
RETURNS TRIGGER AS $$
DECLARE
    v_batch_client UUID; v_batch_currency UUID; v_batch_date DATE; v_batch_status TEXT;
    v_source_client UUID; v_source_currency UUID; v_source_kind TEXT; v_source_type TEXT;
    v_source_status SMALLINT; v_source_deleted BOOLEAN; v_source_direction TEXT; v_source_rate NUMERIC(18,6);
    v_target_client UUID; v_target_currency UUID; v_target_kind TEXT;
    v_target_status SMALLINT; v_target_deleted BOOLEAN; v_target_direction TEXT; v_target_rate NUMERIC(18,6);
    v_ref_ledger UUID; v_ref_type TEXT; v_ref_order UUID;
    v_bound_order UUID; v_receipt_kind TEXT; v_receipt_status SMALLINT; v_receipt_deleted BOOLEAN;
    v_order_client UUID; v_order_currency UUID;
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
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_customer_open_item_offset
    BEFORE INSERT OR UPDATE ON customer_open_item_offsets
    FOR EACH ROW EXECUTE FUNCTION fn_guard_customer_open_item_offset();

CREATE OR REPLACE FUNCTION fn_guard_customer_offset_line_immutable()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_customer_offset_line_immutable
    BEFORE UPDATE OR DELETE ON customer_open_item_offsets
    FOR EACH ROW EXECUTE FUNCTION fn_guard_customer_offset_line_immutable();

CREATE TABLE finance_receipt_source_allocations(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_id UUID NOT NULL REFERENCES finance_receipts(id) ON DELETE RESTRICT,
    receipt_line_id UUID NOT NULL REFERENCES finance_receipt_lines(id) ON DELETE RESTRICT,
    ledger_id UUID NOT NULL REFERENCES ar_ap_ledger(id) ON DELETE RESTRICT,
    source_ref_id UUID NOT NULL REFERENCES ar_ap_source_refs(id) ON DELETE RESTRICT,
    sales_order_id UUID NOT NULL REFERENCES sales_orders(id) ON DELETE RESTRICT,
    line_sequence INTEGER NOT NULL CHECK(line_sequence>0),
    source_sequence INTEGER NOT NULL CHECK(source_sequence>0),
    cash_original NUMERIC(18,4) NOT NULL CHECK(cash_original>=0),
    cash_local NUMERIC(18,4) NOT NULL CHECK(cash_local>=0),
    write_off_original NUMERIC(18,4) NOT NULL CHECK(write_off_original>=0),
    write_off_local NUMERIC(18,4) NOT NULL CHECK(write_off_local>=0),
    applied_book_local NUMERIC(18,4) NOT NULL CHECK(applied_book_local>=0),
    exchange_difference NUMERIC(18,4) NOT NULL,
    effective_date DATE NOT NULL,
    status TEXT NOT NULL DEFAULT 'APPLIED' CHECK(status IN('APPLIED','REVERSED')),
    reversed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by UUID REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT receipt_source_alloc_line_source_uk UNIQUE(receipt_line_id,source_ref_id),
    CONSTRAINT receipt_source_alloc_line_sequence_uk UNIQUE(receipt_line_id,line_sequence),
    CONSTRAINT receipt_source_alloc_money_chk CHECK(cash_original+write_off_original>0),
    CONSTRAINT receipt_source_alloc_fx_identity_chk CHECK(
        exchange_difference=cash_local+write_off_local-applied_book_local),
    CONSTRAINT receipt_source_alloc_status_shape_chk CHECK(
        (status='APPLIED' AND reversed_at IS NULL)
        OR (status='REVERSED' AND reversed_at IS NOT NULL))
);
CREATE INDEX idx_receipt_source_alloc_order
    ON finance_receipt_source_allocations(sales_order_id,effective_date,status);
CREATE INDEX idx_receipt_source_alloc_ledger
    ON finance_receipt_source_allocations(ledger_id,source_ref_id,status);

CREATE OR REPLACE FUNCTION fn_guard_receipt_source_allocation_identity()
RETURNS TRIGGER AS $$
DECLARE
    v_line_receipt UUID; v_line_ledger UUID; v_line_deleted BOOLEAN;
    v_ref_ledger UUID; v_ref_order UUID; v_ref_seq INTEGER;
    v_receipt_kind TEXT; v_receipt_status SMALLINT; v_receipt_deleted BOOLEAN; v_receipt_date DATE;
    v_ledger_client UUID; v_ledger_currency UUID; v_ledger_kind TEXT;
    v_ledger_status SMALLINT; v_ledger_deleted BOOLEAN; v_ledger_direction TEXT;
    v_order_client UUID; v_order_currency UUID;
BEGIN
    SELECT receipt_id,applied_ledger_id,is_deleted
      INTO v_line_receipt,v_line_ledger,v_line_deleted
    FROM finance_receipt_lines WHERE id=NEW.receipt_line_id;
    SELECT ledger_id,source_id,source_sequence INTO v_ref_ledger,v_ref_order,v_ref_seq
    FROM ar_ap_source_refs WHERE id=NEW.source_ref_id AND source_type='SALES_ORDER';
    SELECT receipt_kind,status,is_deleted,bill_date
      INTO v_receipt_kind,v_receipt_status,v_receipt_deleted,v_receipt_date
    FROM finance_receipts WHERE id=NEW.receipt_id;
    SELECT client_id,currency_id,open_item_kind,status,is_deleted,direction
      INTO v_ledger_client,v_ledger_currency,v_ledger_kind,
           v_ledger_status,v_ledger_deleted,v_ledger_direction
    FROM ar_ap_ledger WHERE id=NEW.ledger_id;
    SELECT client_id,currency_id INTO v_order_client,v_order_currency
    FROM sales_orders WHERE id=NEW.sales_order_id;
    IF v_line_receipt<>NEW.receipt_id OR v_line_ledger<>NEW.ledger_id
       OR COALESCE(v_line_deleted,FALSE) OR COALESCE(v_receipt_deleted,FALSE)
       OR v_receipt_kind<>'AR_SETTLEMENT'
       OR NOT ((NEW.status='APPLIED' AND v_receipt_status=1)
               OR (NEW.status='REVERSED' AND v_receipt_status=-1))
       OR NEW.effective_date<>v_receipt_date
       OR v_ledger_direction<>'AR' OR v_ledger_kind<>'RECEIVABLE'
       OR v_ledger_status<>1 OR COALESCE(v_ledger_deleted,FALSE)
       OR v_ref_ledger<>NEW.ledger_id OR v_ref_order<>NEW.sales_order_id
       OR v_ref_seq<>NEW.source_sequence
       OR v_order_client<>v_ledger_client OR v_order_currency IS DISTINCT FROM v_ledger_currency THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance receipt source allocation does not match active receipt, AR, order, or source identities',
            CONSTRAINT='finance_receipt_source_allocation_identity_guard';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_receipt_source_allocation_identity
    BEFORE INSERT OR UPDATE ON finance_receipt_source_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_source_allocation_identity();

CREATE OR REPLACE FUNCTION fn_guard_receipt_source_allocation_immutable()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='finance receipt source allocation is immutable; append a reversal';
    END IF;
    IF NEW.receipt_id IS DISTINCT FROM OLD.receipt_id
       OR NEW.receipt_line_id IS DISTINCT FROM OLD.receipt_line_id
       OR NEW.ledger_id IS DISTINCT FROM OLD.ledger_id
       OR NEW.source_ref_id IS DISTINCT FROM OLD.source_ref_id
       OR NEW.sales_order_id IS DISTINCT FROM OLD.sales_order_id
       OR NEW.line_sequence IS DISTINCT FROM OLD.line_sequence
       OR NEW.source_sequence IS DISTINCT FROM OLD.source_sequence
       OR NEW.cash_original IS DISTINCT FROM OLD.cash_original
       OR NEW.cash_local IS DISTINCT FROM OLD.cash_local
       OR NEW.write_off_original IS DISTINCT FROM OLD.write_off_original
       OR NEW.write_off_local IS DISTINCT FROM OLD.write_off_local
       OR NEW.applied_book_local IS DISTINCT FROM OLD.applied_book_local
       OR NEW.exchange_difference IS DISTINCT FROM OLD.exchange_difference
       OR NEW.effective_date IS DISTINCT FROM OLD.effective_date
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='finance receipt source monetary and creation snapshots are immutable',
            CONSTRAINT='finance_receipt_source_allocation_immutable_guard';
    END IF;
    IF OLD.status='APPLIED' AND NEW.status='REVERSED' THEN
        IF OLD.reversed_at IS NOT NULL OR NEW.reversed_at IS NULL THEN
            RAISE EXCEPTION USING ERRCODE='55000',
                MESSAGE='finance receipt source allocation reversal must be a single transition';
        END IF;
    ELSIF OLD.status=NEW.status THEN
        IF NEW.reversed_at IS DISTINCT FROM OLD.reversed_at THEN
            RAISE EXCEPTION USING ERRCODE='55000',
                MESSAGE='finance receipt source allocation reversal facts cannot be rewritten';
        END IF;
    ELSE
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='finance receipt source allocation status transition is not allowed';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_receipt_source_allocation_immutable
    BEFORE UPDATE OR DELETE ON finance_receipt_source_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_source_allocation_immutable();

CREATE OR REPLACE FUNCTION fn_assert_receipt_source_conservation(v_line_id UUID)
RETURNS VOID AS $$
DECLARE v_cash NUMERIC(18,4); v_writeoff NUMERIC(18,4); v_book NUMERIC(18,4);
        v_alloc_cash NUMERIC(18,4); v_alloc_writeoff NUMERIC(18,4); v_alloc_book NUMERIC(18,4);
BEGIN
    SELECT line.amount_original,line.write_off_amount,line.applied_amount_local
      INTO v_cash,v_writeoff,v_book
    FROM finance_receipt_lines line JOIN finance_receipts receipt ON receipt.id=line.receipt_id
    WHERE line.id=v_line_id AND receipt.status=1 AND receipt.receipt_kind='AR_SETTLEMENT';
    IF v_cash IS NULL THEN RETURN; END IF;
    SELECT COALESCE(SUM(cash_original),0),COALESCE(SUM(write_off_original),0),
           COALESCE(SUM(applied_book_local),0)
      INTO v_alloc_cash,v_alloc_writeoff,v_alloc_book
    FROM finance_receipt_source_allocations
    WHERE receipt_line_id=v_line_id AND status='APPLIED';
    IF v_alloc_cash<>v_cash OR v_alloc_writeoff<>v_writeoff OR v_alloc_book<>v_book THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance receipt source allocations do not conserve the approved line snapshots',
            CONSTRAINT='finance_receipt_source_allocation_conservation_guard';
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_guard_receipt_source_allocation_conservation()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM fn_assert_receipt_source_conservation(COALESCE(NEW.receipt_line_id,OLD.receipt_line_id));
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
CREATE CONSTRAINT TRIGGER trg_receipt_source_allocation_conservation
    AFTER INSERT OR UPDATE OR DELETE ON finance_receipt_source_allocations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_guard_receipt_source_allocation_conservation();

CREATE OR REPLACE FUNCTION fn_guard_receipt_all_lines_allocated()
RETURNS TRIGGER AS $$
DECLARE line_row RECORD;
BEGIN
    IF NEW.status=1 AND NEW.receipt_kind='AR_SETTLEMENT' THEN
        FOR line_row IN SELECT id FROM finance_receipt_lines
                        WHERE receipt_id=NEW.id AND COALESCE(is_deleted,FALSE)=FALSE
        LOOP
            PERFORM fn_assert_receipt_source_conservation(line_row.id);
        END LOOP;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
CREATE CONSTRAINT TRIGGER trg_receipt_all_lines_allocated
    AFTER INSERT OR UPDATE OF status,receipt_kind ON finance_receipts
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_guard_receipt_all_lines_allocated();

CREATE OR REPLACE FUNCTION fn_assert_ar_source_ref_capacity(v_source_ref_id UUID)
RETURNS VOID AS $$
DECLARE v_authorized NUMERIC(18,4); v_consumed NUMERIC(18,4);
BEGIN
    SELECT amount_original INTO v_authorized FROM ar_ap_source_refs
    WHERE id=v_source_ref_id AND source_type='SALES_ORDER';
    IF v_authorized IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='sales-order AR source reference is missing';
    END IF;
    SELECT COALESCE((SELECT SUM(cash_original+write_off_original)
                     FROM finance_receipt_source_allocations
                     WHERE source_ref_id=v_source_ref_id AND status='APPLIED'),0)
         + COALESCE((SELECT SUM(amount_original) FROM customer_open_item_offsets
                     WHERE target_source_ref_id=v_source_ref_id AND status='APPLIED'),0)
      INTO v_consumed;
    IF v_authorized<0 OR v_consumed>v_authorized THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='cash, write-off and prepayment applications exceed the immutable sales-order AR source amount',
            CONSTRAINT='ar_source_ref_application_capacity_guard';
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_guard_receipt_source_ref_capacity()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM fn_assert_ar_source_ref_capacity(COALESCE(
        NULLIF(to_jsonb(NEW)->>'source_ref_id','')::UUID,
        NULLIF(to_jsonb(OLD)->>'source_ref_id','')::UUID));
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
CREATE CONSTRAINT TRIGGER trg_receipt_source_ref_capacity
    AFTER INSERT OR UPDATE OR DELETE ON finance_receipt_source_allocations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_guard_receipt_source_ref_capacity();

CREATE OR REPLACE FUNCTION fn_guard_customer_offset_source_ref_capacity()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM fn_assert_ar_source_ref_capacity(COALESCE(
        NULLIF(to_jsonb(NEW)->>'target_source_ref_id','')::UUID,
        NULLIF(to_jsonb(OLD)->>'target_source_ref_id','')::UUID));
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
CREATE CONSTRAINT TRIGGER trg_customer_offset_source_ref_capacity
    AFTER INSERT OR UPDATE OR DELETE ON customer_open_item_offsets
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_guard_customer_offset_source_ref_capacity();

INSERT INTO finance_receipt_source_allocations(
    receipt_id,receipt_line_id,ledger_id,source_ref_id,sales_order_id,
    line_sequence,source_sequence,cash_original,cash_local,
    write_off_original,write_off_local,applied_book_local,exchange_difference,
    effective_date,status,reversed_at,created_at,updated_at)
SELECT receipt.id,line.id,line.applied_ledger_id,ref.id,ref.source_id,
       1,ref.source_sequence,line.amount_original,line.amount_local,
       COALESCE(line.write_off_amount,0),COALESCE(line.write_off_local,0),
       COALESCE(line.applied_amount_local,line.amount_local),COALESCE(line.exchange_diff,0),
       receipt.bill_date,CASE WHEN receipt.status=1 THEN 'APPLIED' ELSE 'REVERSED' END,
       CASE WHEN receipt.status=-1 THEN receipt.updated_at ELSE NULL END,
       COALESCE(line.created_at,now()),COALESCE(line.updated_at,now())
FROM finance_receipt_lines line
JOIN finance_receipts receipt ON receipt.id=line.receipt_id
JOIN LATERAL(
    SELECT single_ref.* FROM ar_ap_source_refs single_ref
    WHERE single_ref.ledger_id=line.applied_ledger_id
      AND single_ref.source_type='SALES_ORDER'
      AND (SELECT COUNT(*) FROM ar_ap_source_refs count_ref
           WHERE count_ref.ledger_id=line.applied_ledger_id
             AND count_ref.source_type='SALES_ORDER')=1
) ref ON TRUE
WHERE receipt.receipt_kind='AR_SETTLEMENT' AND receipt.status IN(1,-1)
  AND COALESCE(receipt.is_deleted,FALSE)=FALSE
  AND COALESCE(line.is_deleted,FALSE)=FALSE
  AND line.applied_ledger_id IS NOT NULL
  AND line.amount_original>=0 AND COALESCE(line.write_off_amount,0)>=0
  AND COALESCE(line.applied_amount_local,line.amount_local)>=0
ON CONFLICT(receipt_line_id,source_ref_id) DO NOTHING;

INSERT INTO permissions(code,name,module,category,sort_order,action_type,description)
VALUES
 ('customer_prepayment:view','查看客户预收款','财税管理','客户预收',610,'VIEW','查看客户预收余额、订单资金汇总与精确来源分配'),
 ('customer_prepayment:apply','应用客户预收款','财税管理','客户预收',611,'EXECUTE','把客户预收逐笔转销到同客户同币种销售单正式应收'),
 ('customer_prepayment:reverse','反转客户预收应用','财税管理','客户预收',612,'EXECUTE','按稳定批次和快照后进先出反转客户预收转销')
ON CONFLICT(code) DO NOTHING;

INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT surface.id,permission.id FROM permission_surfaces surface
JOIN permissions permission ON permission.code IN(
    'customer_prepayment:view','customer_prepayment:apply','customer_prepayment:reverse')
WHERE surface.surface_key='finance.ar-ap'
ON CONFLICT(surface_id,permission_id) DO NOTHING;

INSERT INTO department_permissions(department_id,permission_id)
SELECT department.id,permission.id FROM departments department
JOIN permissions permission ON permission.code IN(
    'customer_prepayment:view','customer_prepayment:apply','customer_prepayment:reverse')
WHERE department.code='DEPT_FIN' AND COALESCE(department.is_deleted,FALSE)=FALSE
ON CONFLICT DO NOTHING;

COMMENT ON COLUMN sales_orders.deposit IS
    'Legacy commercial snapshot only; ignored on new sales writes and never a receipt/prepayment fact';
COMMENT ON TABLE customer_open_item_offsets IS
    'Immutable customer-prepayment-to-order-AR applications with both booking-rate local snapshots and reversible history';
COMMENT ON TABLE finance_receipt_source_allocations IS
    'Server FIFO allocation of ordinary approved receipt cash/writeoff/book amount to immutable SALES_ORDER source refs; never proportionally infer history';
