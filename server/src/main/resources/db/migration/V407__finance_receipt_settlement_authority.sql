-- V407: finance-authoritative receipt settlement facts.
--
-- Historical receipts remain authority version 0 and retain their exact bytes and
-- accounting semantics. New application writes use version 1, which separates:
--   * AR settlement/original currency and gross functional-currency value;
--   * the real account currency and bank-posted amount;
--   * fees deducted from proceeds or paid from a separate real account;
--   * channel, rate direction/source/time and external evidence references.

-- V278 intentionally left ambiguous name-based fee/FX role mappings NULL.
-- V407 needs deterministic receipt approval posting, so add dedicated fixed
-- leaves and bind them only where the role is still unmapped. Existing reviewed
-- UUID mappings are never overwritten.
INSERT INTO payment_styles(
    id,code,name,category,level,sort_order,path,
    is_departmental,is_receipt,is_payment,status,auto_created)
VALUES
    ('40700000-0000-4000-8100-000000000001',
     'SYS-RECEIPT-BANK-FEE-V407','收款银行手续费','EXPENSE',0,947,
     '/SYS-RECEIPT-BANK-FEE-V407/',FALSE,TRUE,FALSE,'使用',TRUE),
    ('40700000-0000-4000-8100-000000000002',
     'SYS-RECEIPT-FX-V407','收款汇兑损益','EXPENSE',0,948,
     '/SYS-RECEIPT-FX-V407/',FALSE,TRUE,FALSE,'使用',TRUE),
    ('40700000-0000-4000-8100-000000000003',
     'SYS-RECEIPT-AR-CONTROL-V407','应收账款控制','ACCOUNT',0,949,
     '/SYS-RECEIPT-AR-CONTROL-V407/',FALSE,TRUE,FALSE,'使用',TRUE)
ON CONFLICT(id) DO NOTHING;

UPDATE system_posting_style_roles
SET style_id=CASE role_key
    WHEN 'BANK_FEE_EXPENSE' THEN '40700000-0000-4000-8100-000000000001'::UUID
    WHEN 'FX_GAIN_LOSS' THEN '40700000-0000-4000-8100-000000000002'::UUID
    WHEN 'AR_CONTROL' THEN '40700000-0000-4000-8100-000000000003'::UUID
    ELSE style_id END
WHERE role_key IN('BANK_FEE_EXPENSE','FX_GAIN_LOSS','AR_CONTROL')
  AND style_id IS NULL;

ALTER TABLE finance_receipts
    ADD COLUMN version BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN settlement_authority_version SMALLINT NOT NULL DEFAULT 0,
    ADD COLUMN create_idempotency_key VARCHAR(128),
    ADD COLUMN create_request_hash VARCHAR(64),
    ADD COLUMN settlement_channel VARCHAR(40),
    ADD COLUMN settlement_agent_supplier_id UUID,
    ADD COLUMN settlement_agent_name_snapshot VARCHAR(200),
    ADD COLUMN settlement_rate_quote_direction VARCHAR(32),
    ADD COLUMN exchange_rate_source VARCHAR(40),
    ADD COLUMN exchange_rate_effective_at TIMESTAMPTZ,
    ADD COLUMN bank_booked_at TIMESTAMPTZ,
    ADD COLUMN bank_reference VARCHAR(128),
    ADD COLUMN agent_statement_no VARCHAR(128),
    ADD COLUMN account_currency_id UUID,
    ADD COLUMN account_exchange_rate NUMERIC(18,6),
    ADD COLUMN account_exchange_rate_source VARCHAR(40),
    ADD COLUMN account_amount NUMERIC(18,4),
    ADD COLUMN account_amount_local NUMERIC(18,4),
    ADD COLUMN bank_fee_account_amount NUMERIC(18,4),
    ADD COLUMN other_fee_account_amount NUMERIC(18,4),
    ADD COLUMN fee_settlement_mode VARCHAR(32),
    ADD COLUMN fee_bearer VARCHAR(24),
    ADD COLUMN fee_payment_account_id UUID,
    ADD COLUMN fee_account_currency_id UUID,
    ADD COLUMN fee_account_exchange_rate NUMERIC(18,6),
    ADD COLUMN gl_account_style_id UUID,
    ADD COLUMN gl_counter_style_id UUID,
    ADD COLUMN gl_bank_fee_style_id UUID,
    ADD COLUMN gl_fx_style_id UUID,
    ADD COLUMN gl_fee_payment_style_id UUID;

ALTER TABLE finance_receipts
    ADD CONSTRAINT finance_receipts_settlement_authority_version_chk
        CHECK (settlement_authority_version IN (0,1)),
    ADD CONSTRAINT finance_receipts_settlement_agent_fk
        FOREIGN KEY(settlement_agent_supplier_id) REFERENCES suppliers(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT finance_receipts_settlement_account_currency_fk
        FOREIGN KEY(account_currency_id) REFERENCES currencies(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT finance_receipts_fee_payment_account_fk
        FOREIGN KEY(fee_payment_account_id) REFERENCES accounts(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT finance_receipts_fee_account_currency_fk
        FOREIGN KEY(fee_account_currency_id) REFERENCES currencies(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT finance_receipts_gl_account_style_fk
        FOREIGN KEY(gl_account_style_id) REFERENCES payment_styles(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT finance_receipts_gl_counter_style_fk
        FOREIGN KEY(gl_counter_style_id) REFERENCES payment_styles(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT finance_receipts_gl_bank_fee_style_fk
        FOREIGN KEY(gl_bank_fee_style_id) REFERENCES payment_styles(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT finance_receipts_gl_fx_style_fk
        FOREIGN KEY(gl_fx_style_id) REFERENCES payment_styles(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT finance_receipts_gl_fee_payment_style_fk
        FOREIGN KEY(gl_fee_payment_style_id) REFERENCES payment_styles(id) ON DELETE RESTRICT NOT VALID;

ALTER TABLE finance_receipts VALIDATE CONSTRAINT finance_receipts_settlement_agent_fk;
ALTER TABLE finance_receipts VALIDATE CONSTRAINT finance_receipts_settlement_account_currency_fk;
ALTER TABLE finance_receipts VALIDATE CONSTRAINT finance_receipts_fee_payment_account_fk;
ALTER TABLE finance_receipts VALIDATE CONSTRAINT finance_receipts_fee_account_currency_fk;
ALTER TABLE finance_receipts VALIDATE CONSTRAINT finance_receipts_gl_account_style_fk;
ALTER TABLE finance_receipts VALIDATE CONSTRAINT finance_receipts_gl_counter_style_fk;
ALTER TABLE finance_receipts VALIDATE CONSTRAINT finance_receipts_gl_bank_fee_style_fk;
ALTER TABLE finance_receipts VALIDATE CONSTRAINT finance_receipts_gl_fx_style_fk;
ALTER TABLE finance_receipts VALIDATE CONSTRAINT finance_receipts_gl_fee_payment_style_fk;

CREATE UNIQUE INDEX uq_finance_receipts_create_idempotency
    ON finance_receipts(maker_id,create_idempotency_key)
    WHERE create_idempotency_key IS NOT NULL;

ALTER TABLE finance_receipts
    ADD CONSTRAINT finance_receipts_v1_shape_chk CHECK (
        settlement_authority_version=0 OR (
            create_idempotency_key IS NOT NULL
            AND char_length(btrim(create_idempotency_key)) BETWEEN 8 AND 128
            AND create_request_hash IS NOT NULL
            AND create_request_hash ~ '^[0-9a-f]{64}$'
            AND settlement_channel IN ('DIRECT_ACCOUNT','TRADE_AGENT_CONVERSION')
            AND settlement_rate_quote_direction='BASE_PER_SETTLEMENT'
            AND exchange_rate_source IN ('BANK_STATEMENT','TRADE_AGENT_STATEMENT')
            AND exchange_rate_effective_at IS NOT NULL
            AND bank_booked_at IS NOT NULL
            AND account_currency_id IS NOT NULL
            AND account_exchange_rate>0
            AND account_exchange_rate_source IN (
                'BASE_CURRENCY_IDENTITY','SETTLEMENT_RATE')
            AND account_amount>0
            AND account_amount_local>0
            AND COALESCE(bank_fee_account_amount,0)>=0
            AND COALESCE(other_fee_account_amount,0)>=0
            AND COALESCE(bank_fee,0)>=0
            AND COALESCE(other_fee,0)>=0
            AND fee_settlement_mode IN (
                'NONE','DEDUCTED_FROM_PROCEEDS','PAID_SEPARATELY')
            AND fee_bearer IN ('NONE','COMPANY')
            AND fee_account_currency_id IS NOT NULL
            AND fee_account_exchange_rate>0
            AND gl_account_style_id IS NOT NULL
            AND gl_counter_style_id IS NOT NULL
            AND ((COALESCE(bank_fee,0)=0 AND gl_bank_fee_style_id IS NULL)
                 OR (COALESCE(bank_fee,0)>0 AND gl_bank_fee_style_id IS NOT NULL))
            AND ((COALESCE(other_fee,0)=0 AND other_fee_style_id IS NULL)
                 OR (COALESCE(other_fee,0)>0 AND other_fee_style_id IS NOT NULL))
            AND (
                (fee_settlement_mode='NONE'
                 AND fee_bearer='NONE'
                 AND COALESCE(bank_fee_account_amount,0)=0
                 AND COALESCE(other_fee_account_amount,0)=0
                 AND COALESCE(bank_fee,0)=0
                 AND COALESCE(other_fee,0)=0
                 AND fee_payment_account_id IS NULL
                 AND gl_fee_payment_style_id IS NULL)
                OR
                (fee_settlement_mode='DEDUCTED_FROM_PROCEEDS'
                 AND fee_bearer='COMPANY'
                 AND COALESCE(bank_fee_account_amount,0)
                 + COALESCE(other_fee_account_amount,0)>0
                 AND fee_payment_account_id IS NULL
                 AND gl_fee_payment_style_id IS NULL
                 AND account_amount_local
                     + COALESCE(bank_fee,0)+COALESCE(other_fee,0)=amount_local)
                OR
                (fee_settlement_mode='PAID_SEPARATELY'
                 AND fee_bearer='COMPANY'
                 AND COALESCE(bank_fee_account_amount,0)
                 + COALESCE(other_fee_account_amount,0)>0
                 AND fee_payment_account_id IS NOT NULL
                 AND gl_fee_payment_style_id IS NOT NULL
                 AND account_amount_local=amount_local)
            )
        )
    ) NOT VALID;
ALTER TABLE finance_receipts VALIDATE CONSTRAINT finance_receipts_v1_shape_chk;

ALTER TABLE finance_receipts
    ADD CONSTRAINT finance_receipts_v1_lifecycle_chk CHECK (
        settlement_authority_version=0 OR (
            (status=0)
            OR (status=1 AND reversed_at IS NULL
                AND COALESCE(is_deleted,FALSE)=FALSE AND deleted_at IS NULL)
            OR (status=-1 AND reversed_at IS NOT NULL
                AND COALESCE(is_deleted,FALSE)=FALSE AND deleted_at IS NULL)
        )
    ) NOT VALID;
ALTER TABLE finance_receipts
    VALIDATE CONSTRAINT finance_receipts_v1_lifecycle_chk;

-- V379 prohibited all prepayment fees. V1 can post fee expense while keeping
-- the customer-advance liability at the gross settlement value. Legacy rows
-- remain unchanged and no historical fee is inferred.
ALTER TABLE finance_receipts DROP CONSTRAINT finance_receipts_prepayment_money_chk;
ALTER TABLE finance_receipts
    ADD CONSTRAINT finance_receipts_prepayment_money_chk CHECK (
        receipt_kind<>'CUSTOMER_PREPAYMENT'
        OR settlement_authority_version=0
        OR (amount_original>0 AND amount_local>0 AND exchange_rate>0
            AND settlement_authority_version=1)
    ) NOT VALID;

CREATE OR REPLACE FUNCTION fn_guard_finance_receipt_v1_account_identity()
RETURNS TRIGGER AS $$
DECLARE
    v_account_currency UUID;
    v_account_base BOOLEAN;
    v_account_style UUID;
    v_fee_currency UUID;
    v_fee_base BOOLEAN;
    v_fee_style UUID;
    v_agent_name TEXT;
BEGIN
    IF NEW.settlement_authority_version<>1 THEN RETURN NEW; END IF;

    SELECT account.currency_id,currency.is_base_currency,account.style_id
      INTO v_account_currency,v_account_base,v_account_style
    FROM accounts account
    JOIN currencies currency ON currency.id=account.currency_id
    WHERE account.id=NEW.account_id
      AND account.status='使用' AND COALESCE(account.is_deleted,FALSE)=FALSE
      AND currency.status='使用' AND COALESCE(currency.is_deleted,FALSE)=FALSE
    FOR SHARE OF account,currency;
    IF v_account_currency IS NULL
       OR v_account_currency IS DISTINCT FROM NEW.account_currency_id THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='receipt account currency snapshot does not match the active account',
            CONSTRAINT='finance_receipts_v1_account_currency_guard';
    END IF;
    IF v_account_style IS NULL
       OR v_account_style IS DISTINCT FROM NEW.gl_account_style_id THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='receipt GL account style snapshot does not match the real account',
            CONSTRAINT='finance_receipts_v1_gl_style_guard';
    END IF;

    IF COALESCE(v_account_base,FALSE) THEN
        IF NEW.account_exchange_rate<>1
           OR NEW.account_exchange_rate_source<>'BASE_CURRENCY_IDENTITY'
           OR NEW.account_amount_local<>NEW.account_amount THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='base-currency receipt account must use identity rate and equal native/local amount',
                CONSTRAINT='finance_receipts_v1_base_account_guard';
        END IF;
    ELSIF NEW.account_currency_id IS DISTINCT FROM NEW.currency_id
          OR NEW.account_exchange_rate IS DISTINCT FROM NEW.exchange_rate
          OR NEW.account_exchange_rate_source<>'SETTLEMENT_RATE'
          OR ABS(ROUND(NEW.account_amount*NEW.account_exchange_rate,4)
                     -NEW.account_amount_local)>0.0001 THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='foreign receipt account must match settlement currency and freeze the settlement rate',
            CONSTRAINT='finance_receipts_v1_foreign_account_guard';
    END IF;

    IF NEW.settlement_channel='TRADE_AGENT_CONVERSION' THEN
        IF NOT COALESCE(v_account_base,FALSE)
           OR NEW.exchange_rate_source<>'TRADE_AGENT_STATEMENT'
           OR NEW.settlement_agent_supplier_id IS NULL
           OR NULLIF(btrim(NEW.settlement_agent_name_snapshot),'') IS NULL THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='trade-agent conversion requires a base-currency account, agent and agent statement rate',
                CONSTRAINT='finance_receipts_v1_trade_agent_guard';
        END IF;
        SELECT supplier.name INTO v_agent_name
        FROM suppliers supplier
        WHERE supplier.id=NEW.settlement_agent_supplier_id
          AND supplier.status='使用' AND COALESCE(supplier.is_deleted,FALSE)=FALSE
        FOR SHARE;
        IF v_agent_name IS NULL
           OR v_agent_name IS DISTINCT FROM NEW.settlement_agent_name_snapshot THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='trade-agent identity snapshot does not match an active supplier',
                CONSTRAINT='finance_receipts_v1_trade_agent_identity_guard';
        END IF;
    ELSIF NEW.settlement_agent_supplier_id IS NOT NULL
          OR NEW.settlement_agent_name_snapshot IS NOT NULL
          OR NEW.exchange_rate_source<>'BANK_STATEMENT'
          OR (NOT COALESCE(v_account_base,FALSE)
              AND NEW.account_currency_id IS DISTINCT FROM NEW.currency_id) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='direct receipt cannot carry a trade agent and must enter the base or original-currency account',
            CONSTRAINT='finance_receipts_v1_direct_account_guard';
    END IF;

    IF NEW.fee_settlement_mode='DEDUCTED_FROM_PROCEEDS' THEN
        v_fee_currency:=v_account_currency;
        v_fee_base:=v_account_base;
        v_fee_style:=v_account_style;
    ELSIF NEW.fee_settlement_mode='PAID_SEPARATELY' THEN
        SELECT account.currency_id,currency.is_base_currency,account.style_id
          INTO v_fee_currency,v_fee_base,v_fee_style
        FROM accounts account
        JOIN currencies currency ON currency.id=account.currency_id
        WHERE account.id=NEW.fee_payment_account_id
          AND account.status='使用' AND COALESCE(account.is_deleted,FALSE)=FALSE
          AND currency.status='使用' AND COALESCE(currency.is_deleted,FALSE)=FALSE
        FOR SHARE OF account,currency;
    ELSE
        v_fee_currency:=v_account_currency;
        v_fee_base:=v_account_base;
        v_fee_style:=v_account_style;
    END IF;

    IF v_fee_currency IS NULL
       OR v_fee_currency IS DISTINCT FROM NEW.fee_account_currency_id THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='receipt fee currency snapshot does not match its real funding account',
            CONSTRAINT='finance_receipts_v1_fee_currency_guard';
    END IF;
    IF NEW.gl_counter_style_id IS DISTINCT FROM system_posting_style_id(
           CASE WHEN NEW.receipt_kind='CUSTOMER_PREPAYMENT'
                THEN 'CUSTOMER_ADVANCE' ELSE 'AR_CONTROL' END)
       OR (COALESCE(NEW.bank_fee,0)>0 AND NEW.gl_bank_fee_style_id
           IS DISTINCT FROM system_posting_style_id('BANK_FEE_EXPENSE'))
       OR (NEW.gl_fx_style_id IS NOT NULL AND NEW.gl_fx_style_id
           IS DISTINCT FROM system_posting_style_id('FX_GAIN_LOSS'))
       OR (NEW.fee_settlement_mode='PAID_SEPARATELY'
           AND NEW.gl_fee_payment_style_id IS DISTINCT FROM v_fee_style) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='receipt frozen GL style snapshots do not match active role/account authorities',
            CONSTRAINT='finance_receipts_v1_gl_style_guard';
    END IF;
    IF COALESCE(NEW.other_fee,0)>0 AND NOT EXISTS(
        SELECT 1 FROM payment_styles style
        WHERE style.id=NEW.other_fee_style_id AND style.category='EXPENSE'
          AND style.status='使用' AND COALESCE(style.is_deleted,FALSE)=FALSE
          AND NOT EXISTS(SELECT 1 FROM payment_styles child
                         WHERE child.parent_id=style.id
                           AND COALESCE(child.is_deleted,FALSE)=FALSE)) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='receipt other-fee style must be one active expense leaf',
            CONSTRAINT='finance_receipts_v1_gl_style_guard';
    END IF;
    IF COALESCE(v_fee_base,FALSE) THEN
        IF NEW.fee_account_exchange_rate<>1 THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='base-currency receipt fees must use identity rate',
                CONSTRAINT='finance_receipts_v1_fee_rate_guard';
        END IF;
    ELSIF v_fee_currency IS DISTINCT FROM NEW.currency_id
          OR NEW.fee_account_exchange_rate IS DISTINCT FROM NEW.exchange_rate THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='foreign receipt fees must be funded in the settlement currency',
            CONSTRAINT='finance_receipts_v1_fee_rate_guard';
    END IF;

    IF ABS(ROUND(COALESCE(NEW.bank_fee_account_amount,0)
                         *NEW.fee_account_exchange_rate,4)
               -COALESCE(NEW.bank_fee,0))>0.0001
       OR ABS(ROUND(COALESCE(NEW.other_fee_account_amount,0)
                            *NEW.fee_account_exchange_rate,4)
                  -COALESCE(NEW.other_fee,0))>0.0001 THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='receipt fee native and functional-currency snapshots do not reconcile',
            CONSTRAINT='finance_receipts_v1_fee_amount_guard';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_finance_receipt_v1_account_identity
    BEFORE INSERT OR UPDATE OF
        settlement_authority_version,settlement_channel,
        settlement_agent_supplier_id,settlement_agent_name_snapshot,
        exchange_rate_source,account_id,currency_id,exchange_rate,
        account_currency_id,account_exchange_rate,account_exchange_rate_source,
        account_amount,account_amount_local,bank_fee,other_fee,
        bank_fee_account_amount,other_fee_account_amount,fee_settlement_mode,fee_bearer,
        fee_payment_account_id,fee_account_currency_id,fee_account_exchange_rate,
        gl_account_style_id,gl_counter_style_id,gl_bank_fee_style_id,
        gl_fx_style_id,gl_fee_payment_style_id
    ON finance_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_receipt_v1_account_identity();

CREATE OR REPLACE FUNCTION fn_assert_finance_receipt_v1_lines(v_receipt_id UUID)
RETURNS VOID AS $$
DECLARE
    v_receipt RECORD;
    v_count BIGINT;
    v_currency_count BIGINT;
    v_rate_count BIGINT;
    v_original NUMERIC(18,4);
    v_local NUMERIC(18,4);
    v_write_off NUMERIC(18,4);
    v_exchange_diff NUMERIC(18,4);
BEGIN
    SELECT * INTO v_receipt FROM finance_receipts WHERE id=v_receipt_id;
    IF NOT FOUND OR v_receipt.settlement_authority_version<>1 THEN RETURN; END IF;
    SELECT COUNT(*),COUNT(DISTINCT currency_id),COUNT(DISTINCT exchange_rate),
           COALESCE(SUM(amount_original),0),COALESCE(SUM(amount_local),0),
           COALESCE(SUM(ABS(COALESCE(write_off_amount,0))
                        +ABS(COALESCE(write_off_local,0))),0),
           COALESCE(SUM(exchange_diff),0)
      INTO v_count,v_currency_count,v_rate_count,v_original,v_local,v_write_off,
           v_exchange_diff
    FROM finance_receipt_lines
    WHERE receipt_id=v_receipt_id AND COALESCE(is_deleted,FALSE)=FALSE;

    IF v_receipt.receipt_kind='CUSTOMER_PREPAYMENT' THEN
        IF v_count<>0 THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='customer prepayment cannot contain AR allocation lines',
                CONSTRAINT='finance_receipts_v1_line_shape_guard';
        END IF;
        RETURN;
    END IF;
    IF v_count=0 OR v_currency_count<>1 OR v_rate_count<>1
       OR v_write_off<>0 OR v_original<>v_receipt.amount_original
       OR v_local<>v_receipt.amount_local
       OR (v_exchange_diff=0)<>(v_receipt.gl_fx_style_id IS NULL)
       OR EXISTS(SELECT 1 FROM finance_receipt_lines line
                 WHERE line.receipt_id=v_receipt_id
                   AND COALESCE(line.is_deleted,FALSE)=FALSE
                   AND (line.currency_id IS DISTINCT FROM v_receipt.currency_id
                        OR line.exchange_rate IS DISTINCT FROM v_receipt.exchange_rate
                        OR line.amount_local<>ROUND(line.amount_original*line.exchange_rate,4))) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='v1 receipt lines must conserve one original currency/rate and cannot mix fee write-off with cash settlement',
            CONSTRAINT='finance_receipts_v1_line_shape_guard';
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_guard_finance_receipt_v1_lines()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM fn_assert_finance_receipt_v1_lines(COALESCE(NEW.receipt_id,OLD.receipt_id));
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_finance_receipt_v1_lines
    AFTER INSERT OR UPDATE OR DELETE ON finance_receipt_lines
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_guard_finance_receipt_v1_lines();

CREATE OR REPLACE FUNCTION fn_guard_finance_receipt_v1_header_lines()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM fn_assert_finance_receipt_v1_lines(NEW.id);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
CREATE CONSTRAINT TRIGGER trg_finance_receipt_v1_header_lines
    AFTER INSERT OR UPDATE OF status,receipt_kind,amount_original,amount_local,
        currency_id,exchange_rate,settlement_authority_version,gl_fx_style_id
    ON finance_receipts
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_guard_finance_receipt_v1_header_lines();

CREATE OR REPLACE FUNCTION fn_guard_finance_receipt_line_money_fact()
RETURNS TRIGGER AS $$
DECLARE v_status SMALLINT;
BEGIN
    SELECT status INTO v_status FROM finance_receipts
    WHERE id=COALESCE(NEW.receipt_id,OLD.receipt_id);
    IF v_status NOT IN(1,-1) THEN
        IF TG_OP='DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    IF TG_OP='INSERT' THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='approved or reversed finance receipt cannot accept new lines',
            CONSTRAINT='finance_receipt_lines_money_fact_immutable_guard';
    END IF;
    IF TG_OP='DELETE'
       OR NEW.receipt_id IS DISTINCT FROM OLD.receipt_id
       OR NEW.applied_ledger_id IS DISTINCT FROM OLD.applied_ledger_id
       OR NEW.client_id IS DISTINCT FROM OLD.client_id
       OR NEW.currency_id IS DISTINCT FROM OLD.currency_id
       OR NEW.exchange_rate IS DISTINCT FROM OLD.exchange_rate
       OR NEW.amount_original IS DISTINCT FROM OLD.amount_original
       OR NEW.amount_local IS DISTINCT FROM OLD.amount_local
       OR NEW.write_off_amount IS DISTINCT FROM OLD.write_off_amount
       OR NEW.write_off_local IS DISTINCT FROM OLD.write_off_local
       OR NEW.applied_amount_local IS DISTINCT FROM OLD.applied_amount_local
       OR NEW.balance_before_original IS DISTINCT FROM OLD.balance_before_original
       OR NEW.balance_after_original IS DISTINCT FROM OLD.balance_after_original
       OR NEW.exchange_diff IS DISTINCT FROM OLD.exchange_diff THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='approved or reversed finance receipt line money snapshots are immutable',
            CONSTRAINT='finance_receipt_lines_money_fact_immutable_guard';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_finance_receipt_line_money_fact
    BEFORE INSERT OR UPDATE OR DELETE ON finance_receipt_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_receipt_line_money_fact();

-- Replace the V379 function in place so its existing trigger also freezes all
-- V1 authority fields after approval. This is a forward function definition;
-- V379 itself remains byte-for-byte unchanged.
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
       OR NEW.settlement_authority_version IS DISTINCT FROM OLD.settlement_authority_version
       OR NEW.create_idempotency_key IS DISTINCT FROM OLD.create_idempotency_key
       OR NEW.create_request_hash IS DISTINCT FROM OLD.create_request_hash
       OR NEW.settlement_channel IS DISTINCT FROM OLD.settlement_channel
       OR NEW.settlement_agent_supplier_id IS DISTINCT FROM OLD.settlement_agent_supplier_id
       OR NEW.settlement_agent_name_snapshot IS DISTINCT FROM OLD.settlement_agent_name_snapshot
       OR NEW.settlement_rate_quote_direction IS DISTINCT FROM OLD.settlement_rate_quote_direction
       OR NEW.exchange_rate_source IS DISTINCT FROM OLD.exchange_rate_source
       OR NEW.exchange_rate_effective_at IS DISTINCT FROM OLD.exchange_rate_effective_at
       OR NEW.bank_booked_at IS DISTINCT FROM OLD.bank_booked_at
       OR NEW.bank_reference IS DISTINCT FROM OLD.bank_reference
       OR NEW.agent_statement_no IS DISTINCT FROM OLD.agent_statement_no
       OR NEW.account_currency_id IS DISTINCT FROM OLD.account_currency_id
       OR NEW.account_exchange_rate IS DISTINCT FROM OLD.account_exchange_rate
       OR NEW.account_exchange_rate_source IS DISTINCT FROM OLD.account_exchange_rate_source
       OR NEW.account_amount IS DISTINCT FROM OLD.account_amount
       OR NEW.account_amount_local IS DISTINCT FROM OLD.account_amount_local
       OR NEW.bank_fee_account_amount IS DISTINCT FROM OLD.bank_fee_account_amount
       OR NEW.other_fee_account_amount IS DISTINCT FROM OLD.other_fee_account_amount
       OR NEW.fee_settlement_mode IS DISTINCT FROM OLD.fee_settlement_mode
       OR NEW.fee_bearer IS DISTINCT FROM OLD.fee_bearer
       OR NEW.fee_payment_account_id IS DISTINCT FROM OLD.fee_payment_account_id
       OR NEW.fee_account_currency_id IS DISTINCT FROM OLD.fee_account_currency_id
       OR NEW.fee_account_exchange_rate IS DISTINCT FROM OLD.fee_account_exchange_rate
       OR NEW.gl_account_style_id IS DISTINCT FROM OLD.gl_account_style_id
       OR NEW.gl_counter_style_id IS DISTINCT FROM OLD.gl_counter_style_id
       OR NEW.gl_bank_fee_style_id IS DISTINCT FROM OLD.gl_bank_fee_style_id
       OR NEW.gl_fx_style_id IS DISTINCT FROM OLD.gl_fx_style_id
       OR NEW.gl_fee_payment_style_id IS DISTINCT FROM OLD.gl_fee_payment_style_id
       OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
       OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at
       OR (OLD.status=1 AND NEW.status=1
           AND NEW.reversed_at IS DISTINCT FROM OLD.reversed_at)
       OR (OLD.status=1 AND NEW.status=-1
           AND (OLD.reversed_at IS NOT NULL OR NEW.reversed_at IS NULL))
       OR (OLD.status=-1
           AND NEW.reversed_at IS DISTINCT FROM OLD.reversed_at)
       OR (OLD.status=1 AND NEW.status NOT IN(1,-1))
       OR (OLD.status=-1 AND NEW.status<>-1) THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='approved or reversed finance receipt identity and money snapshots are immutable',
            CONSTRAINT='finance_receipts_money_fact_immutable_guard';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON COLUMN finance_receipts.amount_original IS
    'Gross customer settlement in the AR/original currency; V1 never subtracts bank or agent fees';
COMMENT ON COLUMN finance_receipts.amount_local IS
    'Gross settlement in functional/base currency at the frozen batch rate; not the bank-posted account amount';
COMMENT ON COLUMN finance_receipts.account_amount IS
    'Actual amount posted to the selected receiving account in that account native currency';
COMMENT ON COLUMN finance_receipts.account_amount_local IS
    'Functional-currency snapshot of the actual receiving-account posting';
COMMENT ON COLUMN finance_receipts.bank_fee IS
    'Bank fee functional-currency snapshot; V1 source amount is bank_fee_account_amount';
COMMENT ON COLUMN finance_receipts.other_fee IS
    'Agent or other settlement fee functional-currency snapshot';
COMMENT ON COLUMN finance_receipts.fee_bearer IS
    'NONE or COMPANY. Customer/agent-borne deductions require a separate receivable or claim and cannot be booked as company expense';
COMMENT ON COLUMN finance_receipts.gl_account_style_id IS
    'Frozen receiving-account GL style UUID used by the immutable receipt voucher';
COMMENT ON COLUMN finance_receipts.gl_counter_style_id IS
    'Frozen AR-control or customer-advance GL style UUID';
COMMENT ON COLUMN finance_receipts.gl_bank_fee_style_id IS
    'Frozen bank-fee expense style UUID when bank_fee is nonzero';
COMMENT ON COLUMN finance_receipts.gl_fx_style_id IS
    'Frozen FX gain/loss style UUID when receipt exchange difference is nonzero';
COMMENT ON COLUMN finance_receipts.gl_fee_payment_style_id IS
    'Frozen separate fee-payment account GL style UUID';
COMMENT ON COLUMN finance_receipt_lines.currency_id IS
    'AR settlement/original currency snapshot; it is not necessarily the receiving-account currency';
COMMENT ON COLUMN finance_receipt_lines.write_off_amount IS
    'Legacy commercial/fee write-off in AR currency; V1 receipts require zero and model settlement fees separately';

CREATE OR REPLACE VIEW v_receipt_expected_gl_entries AS
SELECT receipt.id AS receipt_id,1 AS line_no,
       receipt.gl_account_style_id AS style_id,1::SMALLINT AS direction,
       receipt.account_amount_local AS amount
FROM finance_receipts receipt
WHERE receipt.settlement_authority_version=1
  AND receipt.status IN(1,-1) AND COALESCE(receipt.is_deleted,FALSE)=FALSE
UNION ALL
SELECT receipt.id,2,receipt.gl_counter_style_id,-1::SMALLINT,
       CASE WHEN EXISTS(
              SELECT 1 FROM finance_receipt_lines line
              WHERE line.receipt_id=receipt.id AND COALESCE(line.is_deleted,FALSE)=FALSE)
            THEN (SELECT COALESCE(SUM(line.applied_amount_local),0)
                  FROM finance_receipt_lines line
                  WHERE line.receipt_id=receipt.id AND COALESCE(line.is_deleted,FALSE)=FALSE)
            ELSE receipt.amount_local END
FROM finance_receipts receipt
WHERE receipt.settlement_authority_version=1
  AND receipt.status IN(1,-1) AND COALESCE(receipt.is_deleted,FALSE)=FALSE
UNION ALL
SELECT receipt.id,3,receipt.gl_bank_fee_style_id,1::SMALLINT,receipt.bank_fee
FROM finance_receipts receipt
WHERE receipt.settlement_authority_version=1
  AND receipt.status IN(1,-1) AND COALESCE(receipt.is_deleted,FALSE)=FALSE
  AND COALESCE(receipt.bank_fee,0)<>0
UNION ALL
SELECT receipt.id,4,receipt.other_fee_style_id,1::SMALLINT,receipt.other_fee
FROM finance_receipts receipt
WHERE receipt.settlement_authority_version=1
  AND receipt.status IN(1,-1) AND COALESCE(receipt.is_deleted,FALSE)=FALSE
  AND COALESCE(receipt.other_fee,0)<>0
UNION ALL
SELECT receipt.id,5,receipt.gl_fx_style_id,
       CASE WHEN difference.amount>0 THEN -1::SMALLINT ELSE 1::SMALLINT END,
       ABS(difference.amount)
FROM finance_receipts receipt
JOIN LATERAL(
  SELECT COALESCE(SUM(line.exchange_diff),0) AS amount
  FROM finance_receipt_lines line
  WHERE line.receipt_id=receipt.id AND COALESCE(line.is_deleted,FALSE)=FALSE
) difference ON TRUE
WHERE receipt.settlement_authority_version=1
  AND receipt.status IN(1,-1) AND COALESCE(receipt.is_deleted,FALSE)=FALSE
  AND difference.amount<>0
UNION ALL
SELECT receipt.id,6,receipt.gl_fee_payment_style_id,-1::SMALLINT,
       receipt.bank_fee+receipt.other_fee
FROM finance_receipts receipt
WHERE receipt.settlement_authority_version=1
  AND receipt.status IN(1,-1) AND COALESCE(receipt.is_deleted,FALSE)=FALSE
  AND receipt.fee_settlement_mode='PAID_SEPARATELY'
  AND COALESCE(receipt.bank_fee,0)+COALESCE(receipt.other_fee,0)>0;

COMMENT ON VIEW v_receipt_expected_gl_entries IS
    'Expected immutable V1 receipt GL multiset derived only from frozen money and style UUID snapshots';

-- Receipt GL is no longer a disposable period projection. Approval creates one
-- immutable RECEIPT voucher; reversal keeps it and appends one linked
-- RECEIPT_REV voucher in the current business period.
ALTER TABLE gl_vouchers
    ADD CONSTRAINT gl_vouchers_receipt_reversal_shape_chk CHECK (
        source<>'AUTO' OR source_type NOT IN ('RECEIPT','RECEIPT_REV') OR (
            source_doc_id IS NOT NULL
            AND ((source_type='RECEIPT' AND reversal_of_voucher_id IS NULL)
                 OR (source_type='RECEIPT_REV' AND reversal_of_voucher_id IS NOT NULL))
        )
    ) NOT VALID;

CREATE OR REPLACE FUNCTION fn_guard_receipt_gl_voucher_fact()
RETURNS TRIGGER AS $$
DECLARE
    v_old_owned BOOLEAN:=FALSE;
    v_new_owned BOOLEAN:=FALSE;
    v_entry_count BIGINT;
    v_balance NUMERIC(18,4);
    v_invalid BIGINT;
    v_mismatch BOOLEAN;
    v_peer RECORD;
    v_receipt RECORD;
BEGIN
    IF TG_OP<>'INSERT' THEN
        v_old_owned:=OLD.source='AUTO'
            AND OLD.source_type IN ('RECEIPT','RECEIPT_REV');
    END IF;
    IF TG_OP<>'DELETE' THEN
        v_new_owned:=NEW.source='AUTO'
            AND NEW.source_type IN ('RECEIPT','RECEIPT_REV');
    END IF;

    IF TG_OP='INSERT' THEN
        IF v_new_owned AND (NEW.status<>0
           OR (NEW.source_type='RECEIPT'
               AND (NEW.reversal_of_voucher_id IS NOT NULL
                    OR NEW.reversed_by_voucher_id IS NOT NULL))
           OR (NEW.source_type='RECEIPT_REV'
               AND NEW.reversed_by_voucher_id IS NOT NULL)) THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='new receipt GL voucher must start as draft status 0',
                CONSTRAINT='receipt_gl_voucher_draft_guard';
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP='DELETE' THEN
        IF v_old_owned THEN
            RAISE EXCEPTION USING ERRCODE='55000',
                MESSAGE='receipt GL vouchers are immutable; append a linked reversal',
                CONSTRAINT='receipt_gl_voucher_immutable_guard';
        END IF;
        RETURN OLD;
    END IF;

    IF NOT v_old_owned AND NOT v_new_owned THEN RETURN NEW; END IF;
    IF v_old_owned IS DISTINCT FROM v_new_owned
       OR NEW.source_type IS DISTINCT FROM OLD.source_type
       OR NEW.source_doc_id IS DISTINCT FROM OLD.source_doc_id THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='voucher cannot enter or leave receipt GL ownership by update',
            CONSTRAINT='receipt_gl_voucher_immutable_guard';
    END IF;

    IF OLD.status=0 AND NEW.status=1
       AND (to_jsonb(NEW)-ARRAY['status','updated_at','updated_by'])
           =(to_jsonb(OLD)-ARRAY['status','updated_at','updated_by']) THEN
        SELECT * INTO v_receipt FROM finance_receipts
        WHERE id=OLD.source_doc_id FOR SHARE;
        IF NOT FOUND OR v_receipt.status<>1
           OR COALESCE(v_receipt.is_deleted,FALSE) THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='receipt GL draft can finalize only for one active approved receipt',
                CONSTRAINT='receipt_gl_voucher_finalize_guard';
        END IF;
        SELECT COUNT(*),COALESCE(SUM(entry.direction*entry.amount),0),
               COUNT(*) FILTER(WHERE
                   entry.source_doc_type IS DISTINCT FROM OLD.source_type
                   OR entry.source_doc_id IS DISTINCT FROM OLD.source_doc_id
                   OR entry.source_bill_no IS DISTINCT FROM receipt.bill_no
                   OR entry.entry_date IS DISTINCT FROM OLD.voucher_date
                   OR entry.period IS DISTINCT FROM OLD.period
                   OR COALESCE(entry.is_deleted,FALSE))
          INTO v_entry_count,v_balance,v_invalid
        FROM gl_entries entry
        JOIN finance_receipts receipt ON receipt.id=OLD.source_doc_id
        WHERE entry.voucher_id=OLD.id;
        IF v_entry_count<2 OR v_balance<>0 OR v_invalid<>0 THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='receipt GL draft must contain complete balanced source-consistent entries before finalization',
                CONSTRAINT='receipt_gl_voucher_finalize_guard';
        END IF;
        IF OLD.source_type='RECEIPT' THEN
            IF v_receipt.settlement_authority_version<>1
               OR OLD.reversed_by_voucher_id IS NOT NULL THEN
                RAISE EXCEPTION USING ERRCODE='23514',
                    MESSAGE='only a V1 approved receipt can finalize a new original voucher',
                    CONSTRAINT='receipt_gl_voucher_finalize_guard';
            END IF;
            SELECT EXISTS(
              (SELECT expected.line_no,expected.style_id,expected.direction,expected.amount
               FROM v_receipt_expected_gl_entries expected
               WHERE expected.receipt_id=OLD.source_doc_id
               EXCEPT ALL
               SELECT actual.line_no,actual.style_id,actual.direction,actual.amount
               FROM gl_entries actual
               WHERE actual.voucher_id=OLD.id AND COALESCE(actual.is_deleted,FALSE)=FALSE)
              UNION ALL
              (SELECT actual.line_no,actual.style_id,actual.direction,actual.amount
               FROM gl_entries actual
               WHERE actual.voucher_id=OLD.id AND COALESCE(actual.is_deleted,FALSE)=FALSE
               EXCEPT ALL
               SELECT expected.line_no,expected.style_id,expected.direction,expected.amount
               FROM v_receipt_expected_gl_entries expected
               WHERE expected.receipt_id=OLD.source_doc_id)
            ) INTO v_mismatch;
            IF v_mismatch THEN
                RAISE EXCEPTION USING ERRCODE='23514',
                    MESSAGE='receipt GL draft does not equal the frozen expected accounting multiset',
                    CONSTRAINT='receipt_gl_voucher_expected_entries_guard';
            END IF;
        ELSE
            SELECT * INTO v_peer FROM gl_vouchers
            WHERE id=OLD.reversal_of_voucher_id FOR SHARE;
            IF NOT FOUND OR v_peer.source<>'AUTO'
               OR v_peer.source_type<>'RECEIPT'
               OR v_peer.source_doc_id IS DISTINCT FROM OLD.source_doc_id
               OR v_peer.status<>1 OR COALESCE(v_peer.is_deleted,FALSE)
               OR v_peer.reversed_by_voucher_id IS NOT NULL THEN
                RAISE EXCEPTION USING ERRCODE='23514',
                    MESSAGE='receipt reversal draft must reference one unreversed active original voucher',
                    CONSTRAINT='receipt_gl_voucher_reversal_link_guard';
            END IF;
            SELECT EXISTS(
              (SELECT original_entry.line_no,original_entry.style_id,
                      original_entry.direction,original_entry.amount
               FROM gl_entries original_entry
               WHERE original_entry.voucher_id=v_peer.id
                 AND COALESCE(original_entry.is_deleted,FALSE)=FALSE
               EXCEPT ALL
               SELECT reversal_entry.line_no,reversal_entry.style_id,
                      -reversal_entry.direction,reversal_entry.amount
               FROM gl_entries reversal_entry
               WHERE reversal_entry.voucher_id=OLD.id
                 AND COALESCE(reversal_entry.is_deleted,FALSE)=FALSE)
              UNION ALL
              (SELECT reversal_entry.line_no,reversal_entry.style_id,
                      -reversal_entry.direction,reversal_entry.amount
               FROM gl_entries reversal_entry
               WHERE reversal_entry.voucher_id=OLD.id
                 AND COALESCE(reversal_entry.is_deleted,FALSE)=FALSE
               EXCEPT ALL
               SELECT original_entry.line_no,original_entry.style_id,
                      original_entry.direction,original_entry.amount
               FROM gl_entries original_entry
               WHERE original_entry.voucher_id=v_peer.id
                 AND COALESCE(original_entry.is_deleted,FALSE)=FALSE)
            ) INTO v_mismatch;
            IF v_mismatch THEN
                RAISE EXCEPTION USING ERRCODE='23514',
                    MESSAGE='receipt reversal draft must be the exact inverse multiset of its original voucher',
                    CONSTRAINT='receipt_gl_voucher_expected_entries_guard';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    IF OLD.status=1 AND NEW.status=1
       AND OLD.source_type='RECEIPT'
       AND OLD.reversed_by_voucher_id IS NULL
       AND NEW.reversed_by_voucher_id IS NOT NULL
       AND (to_jsonb(NEW)-ARRAY['reversed_by_voucher_id','updated_at','updated_by'])
           =(to_jsonb(OLD)-ARRAY['reversed_by_voucher_id','updated_at','updated_by']) THEN
        SELECT * INTO v_peer FROM gl_vouchers
        WHERE id=NEW.reversed_by_voucher_id FOR SHARE;
        IF NOT FOUND OR v_peer.source<>'AUTO'
           OR v_peer.source_type<>'RECEIPT_REV'
           OR v_peer.source_doc_id IS DISTINCT FROM OLD.source_doc_id
           OR v_peer.reversal_of_voucher_id IS DISTINCT FROM OLD.id
           OR v_peer.status<>1 OR COALESCE(v_peer.is_deleted,FALSE) THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='receipt original must link to its finalized same-source reversal voucher',
                CONSTRAINT='receipt_gl_voucher_reversal_link_guard';
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION USING ERRCODE='55000',
        MESSAGE='finalized receipt GL vouchers are immutable',
        CONSTRAINT='receipt_gl_voucher_immutable_guard';
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_receipt_gl_voucher_fact
    BEFORE INSERT OR UPDATE OR DELETE ON gl_vouchers
    FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_gl_voucher_fact();

CREATE OR REPLACE FUNCTION fn_guard_receipt_gl_entry_fact()
RETURNS TRIGGER AS $$
DECLARE
    v_old_source_type TEXT;
    v_new_source_type TEXT;
    v_new_status SMALLINT;
    v_new_source_doc_id UUID;
    v_new_period CHAR(7);
    v_new_date DATE;
    v_receipt_bill_no TEXT;
BEGIN
    IF TG_OP<>'INSERT' THEN
        SELECT source_type INTO v_old_source_type FROM gl_vouchers
        WHERE id=OLD.voucher_id;
    END IF;
    IF TG_OP<>'DELETE' THEN
        SELECT voucher.source_type,voucher.status,voucher.source_doc_id,
               voucher.period,voucher.voucher_date,receipt.bill_no
          INTO v_new_source_type,v_new_status,v_new_source_doc_id,
               v_new_period,v_new_date,v_receipt_bill_no
        FROM gl_vouchers voucher
        LEFT JOIN finance_receipts receipt ON receipt.id=voucher.source_doc_id
        WHERE voucher.id=NEW.voucher_id;
    END IF;

    IF TG_OP='INSERT' AND v_new_source_type IN ('RECEIPT','RECEIPT_REV') THEN
        IF v_new_status<>0
           OR NEW.source_doc_type IS DISTINCT FROM v_new_source_type
           OR NEW.source_doc_id IS DISTINCT FROM v_new_source_doc_id
           OR NEW.source_bill_no IS DISTINCT FROM v_receipt_bill_no
           OR NEW.entry_date IS DISTINCT FROM v_new_date
           OR NEW.period IS DISTINCT FROM v_new_period
           OR COALESCE(NEW.is_deleted,FALSE) THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='receipt GL entries can only be inserted into a matching draft voucher',
                CONSTRAINT='receipt_gl_entry_draft_guard';
        END IF;
        RETURN NEW;
    END IF;

    IF v_old_source_type IN ('RECEIPT','RECEIPT_REV')
       OR v_new_source_type IN ('RECEIPT','RECEIPT_REV') THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='receipt GL entries cannot be updated, moved or deleted',
            CONSTRAINT='receipt_gl_entry_immutable_guard';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_receipt_gl_entry_fact
    BEFORE INSERT OR UPDATE OR DELETE ON gl_entries
    FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_gl_entry_fact();

CREATE OR REPLACE FUNCTION fn_assert_receipt_gl_terminal_link(v_receipt_id UUID)
RETURNS VOID AS $$
DECLARE
    v_receipt RECORD;
    v_original RECORD;
    v_reversal RECORD;
    v_original_count BIGINT;
    v_reversal_count BIGINT;
BEGIN
    SELECT * INTO v_receipt FROM finance_receipts WHERE id=v_receipt_id;
    IF NOT FOUND OR v_receipt.status NOT IN(1,-1)
       OR COALESCE(v_receipt.is_deleted,FALSE) THEN RETURN; END IF;
    SELECT COUNT(*) INTO v_original_count FROM gl_vouchers voucher
    WHERE voucher.source='AUTO' AND voucher.source_type='RECEIPT'
      AND voucher.source_doc_id=v_receipt_id AND voucher.status=1
      AND COALESCE(voucher.is_deleted,FALSE)=FALSE;
    SELECT * INTO v_original FROM gl_vouchers voucher
    WHERE voucher.source='AUTO' AND voucher.source_type='RECEIPT'
      AND voucher.source_doc_id=v_receipt_id AND voucher.status=1
      AND COALESCE(voucher.is_deleted,FALSE)=FALSE
    ORDER BY voucher.created_at,voucher.id LIMIT 1;
    SELECT COUNT(*) INTO v_reversal_count FROM gl_vouchers voucher
    WHERE voucher.source='AUTO' AND voucher.source_type='RECEIPT_REV'
      AND voucher.source_doc_id=v_receipt_id AND voucher.status=1
      AND COALESCE(voucher.is_deleted,FALSE)=FALSE;
    SELECT * INTO v_reversal FROM gl_vouchers voucher
    WHERE voucher.source='AUTO' AND voucher.source_type='RECEIPT_REV'
      AND voucher.source_doc_id=v_receipt_id AND voucher.status=1
      AND COALESCE(voucher.is_deleted,FALSE)=FALSE
    ORDER BY voucher.created_at,voucher.id LIMIT 1;

    IF v_receipt.status=1 THEN
        IF (v_receipt.settlement_authority_version=1 AND v_original_count<>1)
           OR v_original_count>1 OR v_reversal_count<>0
           OR (v_original_count=1 AND v_original.reversed_by_voucher_id IS NOT NULL) THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='approved receipt must have one unreversed original GL voucher and no reversal',
                CONSTRAINT='receipt_gl_terminal_link_guard';
        END IF;
    ELSIF v_original_count<>1 OR v_reversal_count<>1
       OR v_original.reversed_by_voucher_id IS DISTINCT FROM v_reversal.id
       OR v_reversal.reversal_of_voucher_id IS DISTINCT FROM v_original.id THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='reversed receipt must have one bidirectionally linked original and reversal GL voucher',
            CONSTRAINT='receipt_gl_terminal_link_guard';
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_guard_receipt_gl_terminal_from_voucher()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.source='AUTO' AND NEW.source_type IN('RECEIPT','RECEIPT_REV') THEN
        PERFORM fn_assert_receipt_gl_terminal_link(NEW.source_doc_id);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
CREATE CONSTRAINT TRIGGER trg_guard_receipt_gl_terminal_from_voucher
    AFTER INSERT OR UPDATE OF status,reversed_by_voucher_id,reversal_of_voucher_id
    ON gl_vouchers DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_gl_terminal_from_voucher();

CREATE OR REPLACE FUNCTION fn_guard_receipt_gl_terminal_from_receipt()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM fn_assert_receipt_gl_terminal_link(NEW.id);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
CREATE CONSTRAINT TRIGGER trg_guard_receipt_gl_terminal_from_receipt
    AFTER INSERT OR UPDATE OF status,reversed_at,is_deleted
    ON finance_receipts DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_gl_terminal_from_receipt();

CREATE OR REPLACE VIEW v_receipt_gl_integrity AS
SELECT receipt.id AS receipt_id,
       receipt.bill_no,
       receipt.status AS receipt_status,
       to_char(receipt.bill_date,'YYYY-MM') AS receipt_period,
       original.id AS original_voucher_id,
       reversal.id AS reversal_voucher_id,
       original.period AS original_period,
       reversal.period AS reversal_period,
       original.voucher_date AS original_voucher_date,
       reversal.voucher_date AS reversal_voucher_date,
       COALESCE(original_totals.entry_count,0) AS original_entry_count,
       COALESCE(reversal_totals.entry_count,0) AS reversal_entry_count,
       COALESCE(original_totals.balance,0) AS original_balance,
       COALESCE(reversal_totals.balance,0) AS reversal_balance,
       CASE
         WHEN receipt.status=1 THEN
           original.id IS NOT NULL AND reversal.id IS NULL
           AND original.reversed_by_voucher_id IS NULL
           AND original.voucher_date=receipt.bill_date
           AND original.period=to_char(receipt.bill_date,'YYYY-MM')
           AND COALESCE(original_totals.entry_count,0)>=2
           AND COALESCE(original_totals.balance,0)=0
           AND COALESCE(original_totals.invalid_entry_count,0)=0
           AND NOT expected_check.mismatch
         WHEN receipt.status=-1 THEN
           original.id IS NOT NULL AND reversal.id IS NOT NULL
           AND original.reversed_by_voucher_id=reversal.id
           AND reversal.reversal_of_voucher_id=original.id
           AND original.voucher_date=receipt.bill_date
           AND original.period=to_char(receipt.bill_date,'YYYY-MM')
           AND reversal.voucher_date=
               (receipt.reversed_at AT TIME ZONE 'Asia/Shanghai')::date
           AND reversal.period=to_char(
               receipt.reversed_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM')
           AND COALESCE(original_totals.entry_count,0)>=2
           AND original_totals.entry_count=reversal_totals.entry_count
           AND COALESCE(original_totals.balance,0)=0
           AND COALESCE(reversal_totals.balance,0)=0
           AND COALESCE(original_totals.invalid_entry_count,0)=0
           AND COALESCE(reversal_totals.invalid_entry_count,0)=0
           AND NOT expected_check.mismatch
           AND NOT EXISTS(
             SELECT original_entry.line_no,original_entry.style_id,
                    original_entry.direction,original_entry.amount,
                    original_entry.source_doc_id,original_entry.source_bill_no
             FROM gl_entries original_entry
             WHERE original_entry.voucher_id=original.id
               AND COALESCE(original_entry.is_deleted,FALSE)=FALSE
             EXCEPT ALL
             SELECT reversal_entry.line_no,reversal_entry.style_id,
                    -reversal_entry.direction,reversal_entry.amount,
                    reversal_entry.source_doc_id,reversal_entry.source_bill_no
             FROM gl_entries reversal_entry
             WHERE reversal_entry.voucher_id=reversal.id
               AND COALESCE(reversal_entry.is_deleted,FALSE)=FALSE)
           AND NOT EXISTS(
             SELECT reversal_entry.line_no,reversal_entry.style_id,
                    -reversal_entry.direction,reversal_entry.amount,
                    reversal_entry.source_doc_id,reversal_entry.source_bill_no
             FROM gl_entries reversal_entry
             WHERE reversal_entry.voucher_id=reversal.id
               AND COALESCE(reversal_entry.is_deleted,FALSE)=FALSE
             EXCEPT ALL
             SELECT original_entry.line_no,original_entry.style_id,
                    original_entry.direction,original_entry.amount,
                    original_entry.source_doc_id,original_entry.source_bill_no
             FROM gl_entries original_entry
             WHERE original_entry.voucher_id=original.id
               AND COALESCE(original_entry.is_deleted,FALSE)=FALSE)
         ELSE FALSE
       END AS is_consistent
FROM finance_receipts receipt
LEFT JOIN gl_vouchers original
  ON original.source='AUTO' AND original.source_type='RECEIPT'
 AND original.source_doc_id=receipt.id AND original.status=1
 AND COALESCE(original.is_deleted,FALSE)=FALSE
LEFT JOIN gl_vouchers reversal
  ON reversal.source='AUTO' AND reversal.source_type='RECEIPT_REV'
 AND reversal.source_doc_id=receipt.id AND reversal.status=1
 AND COALESCE(reversal.is_deleted,FALSE)=FALSE
LEFT JOIN LATERAL(
  SELECT COUNT(*) AS entry_count,COALESCE(SUM(direction*amount),0) AS balance,
         COUNT(*) FILTER(WHERE
             entry.source_doc_type IS DISTINCT FROM 'RECEIPT'
             OR entry.source_doc_id IS DISTINCT FROM receipt.id
             OR entry.source_bill_no IS DISTINCT FROM receipt.bill_no
             OR entry.entry_date IS DISTINCT FROM receipt.bill_date
             OR entry.period IS DISTINCT FROM original.period)
           AS invalid_entry_count
  FROM gl_entries entry
  WHERE entry.voucher_id=original.id AND COALESCE(entry.is_deleted,FALSE)=FALSE
) original_totals ON TRUE
LEFT JOIN LATERAL(
  SELECT COUNT(*) AS entry_count,COALESCE(SUM(direction*amount),0) AS balance,
         COUNT(*) FILTER(WHERE
             entry.source_doc_type IS DISTINCT FROM 'RECEIPT_REV'
             OR entry.source_doc_id IS DISTINCT FROM receipt.id
             OR entry.source_bill_no IS DISTINCT FROM receipt.bill_no
             OR entry.entry_date IS DISTINCT FROM reversal.voucher_date
             OR entry.period IS DISTINCT FROM reversal.period)
           AS invalid_entry_count
  FROM gl_entries entry
  WHERE entry.voucher_id=reversal.id AND COALESCE(entry.is_deleted,FALSE)=FALSE
) reversal_totals ON TRUE
LEFT JOIN LATERAL(
  SELECT EXISTS(
    (SELECT expected.line_no,expected.style_id,expected.direction,expected.amount
     FROM v_receipt_expected_gl_entries expected
     WHERE expected.receipt_id=receipt.id
     EXCEPT ALL
     SELECT actual.line_no,actual.style_id,actual.direction,actual.amount
     FROM gl_entries actual
     WHERE actual.voucher_id=original.id AND COALESCE(actual.is_deleted,FALSE)=FALSE)
    UNION ALL
    (SELECT actual.line_no,actual.style_id,actual.direction,actual.amount
     FROM gl_entries actual
     WHERE actual.voucher_id=original.id AND COALESCE(actual.is_deleted,FALSE)=FALSE
     EXCEPT ALL
     SELECT expected.line_no,expected.style_id,expected.direction,expected.amount
     FROM v_receipt_expected_gl_entries expected
     WHERE expected.receipt_id=receipt.id)
  ) AS mismatch
) expected_check ON TRUE
WHERE receipt.settlement_authority_version=1
  AND receipt.status IN (1,-1)
  AND COALESCE(receipt.is_deleted,FALSE)=FALSE;

COMMENT ON VIEW v_receipt_gl_integrity IS
    'V1 receipt-to-GL projection integrity; inconsistent rows are reconciliation exceptions, never auto-repaired';

CREATE OR REPLACE VIEW v_receipt_v0_gl_reconciliation AS
SELECT receipt.id AS receipt_id,receipt.bill_no,receipt.bill_date,
       COALESCE(proof.voucher_count,0) AS voucher_count,
       COALESCE(proof.entry_count,0) AS entry_count,
       COALESCE(proof.balance,0) AS voucher_balance,
       COALESCE(proof.invalid_entry_count,0) AS invalid_entry_count,
       COALESCE(proof.linked_original_count,0) AS linked_original_count,
       (SELECT COUNT(*) FROM gl_vouchers reversal
        WHERE reversal.source='AUTO' AND reversal.source_type='RECEIPT_REV'
          AND reversal.source_doc_id=receipt.id AND reversal.status=1
          AND COALESCE(reversal.is_deleted,FALSE)=FALSE) AS reversal_count,
       CASE
         WHEN COALESCE(proof.voucher_count,0)=0 THEN 'MISSING'
         WHEN proof.voucher_count<>1 THEN 'AMBIGUOUS'
         WHEN proof.entry_count<2 OR proof.balance<>0
              OR proof.invalid_entry_count<>0
              OR proof.linked_original_count<>0
              OR EXISTS(SELECT 1 FROM gl_vouchers reversal
                        WHERE reversal.source='AUTO'
                          AND reversal.source_type='RECEIPT_REV'
                          AND reversal.source_doc_id=receipt.id
                          AND reversal.status=1
                          AND COALESCE(reversal.is_deleted,FALSE)=FALSE)
              THEN 'INVALID'
         ELSE 'OK'
       END AS reconciliation_state
FROM finance_receipts receipt
LEFT JOIN LATERAL(
  SELECT COUNT(DISTINCT voucher.id) AS voucher_count,
         COUNT(entry.id) AS entry_count,
         COALESCE(SUM(entry.direction*entry.amount),0) AS balance,
         COUNT(DISTINCT voucher.id) FILTER(
             WHERE voucher.reversed_by_voucher_id IS NOT NULL)
           AS linked_original_count,
         COUNT(entry.id) FILTER(WHERE
             entry.source_doc_type IS DISTINCT FROM 'RECEIPT'
             OR entry.source_doc_id IS DISTINCT FROM receipt.id
             OR entry.source_bill_no IS DISTINCT FROM receipt.bill_no
             OR entry.entry_date IS DISTINCT FROM receipt.bill_date
             OR entry.period IS DISTINCT FROM voucher.period
             OR voucher.voucher_date IS DISTINCT FROM receipt.bill_date
             OR voucher.period IS DISTINCT FROM to_char(receipt.bill_date,'YYYY-MM'))
           AS invalid_entry_count
  FROM gl_vouchers voucher
  LEFT JOIN gl_entries entry ON entry.voucher_id=voucher.id
    AND COALESCE(entry.is_deleted,FALSE)=FALSE
  WHERE voucher.source='AUTO' AND voucher.source_type='RECEIPT'
    AND voucher.source_doc_id=receipt.id AND voucher.status=1
    AND COALESCE(voucher.is_deleted,FALSE)=FALSE
) proof ON TRUE
WHERE receipt.settlement_authority_version=0
  AND receipt.status=1 AND COALESCE(receipt.is_deleted,FALSE)=FALSE;

COMMENT ON VIEW v_receipt_v0_gl_reconciliation IS
    'Historical V0 approved receipt GL exception queue; MISSING/AMBIGUOUS/INVALID rows require reviewed reconciliation and are never guessed';
