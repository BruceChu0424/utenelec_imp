-- V408: append-only account flows, reversal lineage and balance-integrity read model.

ALTER TABLE finance_reconciliations
    ADD COLUMN posting_seq BIGINT GENERATED ALWAYS AS IDENTITY,
    ADD COLUMN entry_kind VARCHAR(16) NOT NULL DEFAULT 'POSTING',
    ADD COLUMN reversal_of_id UUID,
    ADD COLUMN reversal_reason VARCHAR(500),
    ADD COLUMN account_currency_id UUID,
    ADD COLUMN amount_local NUMERIC(18,4),
    ADD CONSTRAINT finance_reconciliations_entry_kind_chk
        CHECK (entry_kind IN ('POSTING','REVERSAL','ADJUSTMENT')),
    ADD CONSTRAINT finance_reconciliations_reversal_shape_chk CHECK (
        (entry_kind='REVERSAL' AND reversal_of_id IS NOT NULL)
        OR (entry_kind<>'REVERSAL' AND reversal_of_id IS NULL)
    ),
    ADD CONSTRAINT finance_reconciliations_reversal_fk
        FOREIGN KEY(reversal_of_id) REFERENCES finance_reconciliations(id) ON DELETE RESTRICT NOT VALID,
    ADD CONSTRAINT finance_reconciliations_account_currency_fk
        FOREIGN KEY(account_currency_id) REFERENCES currencies(id) ON DELETE RESTRICT NOT VALID;

UPDATE finance_reconciliations flow
SET entry_kind=CASE WHEN flow.source_doc_type='BALANCE_ADJUSTMENT'
                    THEN 'ADJUSTMENT' ELSE 'POSTING' END,
    account_currency_id=account.currency_id,
    amount_local=CASE WHEN currency.is_base_currency
                      THEN COALESCE(flow.in_amount,0)+COALESCE(flow.out_amount,0)
                      ELSE NULL END
FROM accounts account
LEFT JOIN currencies currency ON currency.id=account.currency_id
WHERE account.id=flow.account_id;

ALTER TABLE finance_reconciliations VALIDATE CONSTRAINT finance_reconciliations_reversal_fk;
ALTER TABLE finance_reconciliations VALIDATE CONSTRAINT finance_reconciliations_account_currency_fk;

ALTER TABLE finance_reconciliations
    DROP CONSTRAINT finance_reconciliations_source_doc_type_chk;
ALTER TABLE finance_reconciliations
    ADD CONSTRAINT finance_reconciliations_source_doc_type_chk CHECK (
        source_doc_type IN (
            'RECEIPT','RECEIPT_FEE','PAYMENT','EXPENSE','INCOME',
            'BANK_TRANSFER','BALANCE_ADJUSTMENT','SUPPLIER_CLAIM_RECEIPT'));

DROP INDEX uq_finance_reconciliation_active_source_account;
CREATE UNIQUE INDEX uq_finance_reconciliation_active_source_account_kind
    ON finance_reconciliations(source_doc_type,source_doc_id,account_id,entry_kind)
    WHERE source_doc_id IS NOT NULL AND account_id IS NOT NULL
      AND COALESCE(is_deleted,FALSE)=FALSE;
CREATE UNIQUE INDEX uq_finance_reconciliation_reversal
    ON finance_reconciliations(reversal_of_id)
    WHERE reversal_of_id IS NOT NULL AND COALESCE(is_deleted,FALSE)=FALSE;
CREATE UNIQUE INDEX uq_finance_reconciliation_posting_seq
    ON finance_reconciliations(posting_seq);

DROP INDEX idx_frec_account_date_stable;
DROP INDEX idx_frec_account;
CREATE INDEX idx_frec_account_date_stable
    ON finance_reconciliations(account_id,bill_date,posting_seq)
    INCLUDE(in_amount,out_amount,amount_local,bill_no,check_no,counterpart_name,
            source_remark,remark,settled_date,source_doc_type,source_doc_id,
            entry_kind,reversal_of_id,account_currency_id,id)
    WHERE COALESCE(is_deleted,FALSE)=FALSE;

CREATE OR REPLACE FUNCTION fn_guard_account_flow_insert()
RETURNS TRIGGER AS $$
DECLARE v_currency UUID;
BEGIN
    IF NEW.account_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account flow requires a real account UUID',
            CONSTRAINT='finance_reconciliations_account_identity_guard';
    END IF;
    IF NEW.bill_date IS NULL OR COALESCE(NEW.is_deleted,FALSE) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='new account flow requires an effective timestamp and cannot start deleted',
            CONSTRAINT='finance_reconciliations_effective_time_guard';
    END IF;
    SELECT currency_id INTO v_currency FROM accounts
    WHERE id=NEW.account_id AND COALESCE(is_deleted,FALSE)=FALSE
    FOR SHARE;
    IF v_currency IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account flow account is missing or has no currency UUID',
            CONSTRAINT='finance_reconciliations_account_identity_guard';
    END IF;
    IF NEW.account_currency_id IS NULL THEN NEW.account_currency_id:=v_currency; END IF;
    IF NEW.account_currency_id IS DISTINCT FROM v_currency THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account flow currency snapshot does not match account currency',
            CONSTRAINT='finance_reconciliations_account_identity_guard';
    END IF;
    IF COALESCE(NEW.in_amount,0)<0 OR COALESCE(NEW.out_amount,0)<0
       OR (COALESCE(NEW.in_amount,0)=0)=(COALESCE(NEW.out_amount,0)=0) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account flow must contain exactly one positive in/out amount',
            CONSTRAINT='finance_reconciliations_signed_amount_guard';
    END IF;
    NEW.in_amount:=COALESCE(NEW.in_amount,0);
    NEW.out_amount:=COALESCE(NEW.out_amount,0);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_account_flow_insert
    BEFORE INSERT ON finance_reconciliations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_account_flow_insert();

CREATE OR REPLACE FUNCTION fn_guard_account_flow_append_only()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION USING ERRCODE='55000',
        MESSAGE='account flows are append-only; reverse with a linked REVERSAL entry',
        CONSTRAINT='finance_reconciliations_append_only_guard';
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER trg_guard_balance_adjustment_reconciliation_append_only
    ON finance_reconciliations;
CREATE TRIGGER trg_guard_account_flow_append_only
    BEFORE UPDATE OR DELETE ON finance_reconciliations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_account_flow_append_only();

CREATE OR REPLACE FUNCTION fn_guard_account_flow_reversal()
RETURNS TRIGGER AS $$
DECLARE v_original RECORD;
BEGIN
    IF NEW.entry_kind<>'REVERSAL' THEN RETURN NULL; END IF;
    SELECT * INTO v_original FROM finance_reconciliations
    WHERE id=NEW.reversal_of_id FOR SHARE;
    IF NOT FOUND OR v_original.entry_kind NOT IN ('POSTING','ADJUSTMENT')
       OR COALESCE(v_original.is_deleted,FALSE)
       OR NEW.source_doc_type IS DISTINCT FROM v_original.source_doc_type
       OR NEW.source_doc_id IS DISTINCT FROM v_original.source_doc_id
       OR NEW.account_id IS DISTINCT FROM v_original.account_id
       OR NEW.account_currency_id IS DISTINCT FROM v_original.account_currency_id
       OR COALESCE(NEW.in_amount,0)<>COALESCE(v_original.out_amount,0)
       OR COALESCE(NEW.out_amount,0)<>COALESCE(v_original.in_amount,0)
       OR NEW.amount_local IS DISTINCT FROM v_original.amount_local
       OR NEW.bill_no IS DISTINCT FROM v_original.bill_no
       OR NULLIF(btrim(NEW.reversal_reason),'') IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account reversal must mirror one immutable posting in the same account and currency',
            CONSTRAINT='finance_reconciliations_reversal_identity_guard';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
CREATE CONSTRAINT TRIGGER trg_guard_account_flow_reversal
    AFTER INSERT ON finance_reconciliations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_guard_account_flow_reversal();

-- A database-level freeze closes the direct-SQL gap left by the application
-- guard: once any money document, flow or adjustment references an account,
-- its currency, GL style and opening balance are historical authorities.
CREATE OR REPLACE FUNCTION fn_guard_account_historical_authority()
RETURNS TRIGGER AS $$
DECLARE v_has_history BOOLEAN;
BEGIN
    IF NEW.currency_id IS NOT DISTINCT FROM OLD.currency_id
       AND NEW.style_id IS NOT DISTINCT FROM OLD.style_id
       AND NEW.init_balance IS NOT DISTINCT FROM OLD.init_balance THEN
        RETURN NEW;
    END IF;
    SELECT EXISTS(SELECT 1 FROM finance_reconciliations WHERE account_id=OLD.id)
        OR EXISTS(SELECT 1 FROM account_balance_adjustment_items WHERE account_id=OLD.id)
        OR EXISTS(SELECT 1 FROM finance_receipts WHERE account_id=OLD.id AND status<>0)
        OR EXISTS(SELECT 1 FROM finance_receipts WHERE fee_payment_account_id=OLD.id AND status<>0)
        OR EXISTS(SELECT 1 FROM finance_payments WHERE account_id=OLD.id AND status<>0)
        OR EXISTS(SELECT 1 FROM finance_expenses WHERE account_id=OLD.id AND status<>0)
        OR EXISTS(SELECT 1 FROM finance_other_incomes WHERE account_id=OLD.id AND status<>0)
        OR EXISTS(SELECT 1 FROM finance_bank_transfers WHERE out_account_id=OLD.id AND status<>0)
        OR EXISTS(SELECT 1 FROM finance_bank_transfer_lines line
                  JOIN finance_bank_transfers transfer ON transfer.id=line.transfer_id
                  WHERE line.in_account_id=OLD.id AND transfer.status<>0)
      INTO v_has_history;
    IF v_has_history THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='account currency, GL style and opening balance are immutable after money history exists',
            CONSTRAINT='accounts_historical_money_authority_guard';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_guard_account_historical_authority
    BEFORE UPDATE OF currency_id,style_id,init_balance ON accounts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_account_historical_authority();

CREATE OR REPLACE VIEW v_account_balance_integrity AS
SELECT account.id AS account_id,
       account.currency_id,
       account.init_balance,
       account.receipts_total,
       account.payments_total,
       account.balance_adjustments_total,
       account.balance_current AS cached_balance,
       account.init_balance
         +COALESCE(SUM(COALESCE(flow.in_amount,0)-COALESCE(flow.out_amount,0))
                    FILTER(WHERE COALESCE(flow.is_deleted,FALSE)=FALSE),0)
           AS flow_balance,
       account.balance_current-
         (account.init_balance
          +COALESCE(SUM(COALESCE(flow.in_amount,0)-COALESCE(flow.out_amount,0))
                     FILTER(WHERE COALESCE(flow.is_deleted,FALSE)=FALSE),0))
           AS balance_difference,
       COUNT(flow.id) FILTER(WHERE COALESCE(flow.is_deleted,FALSE)=FALSE)
           AS active_flow_count,
       MAX(flow.bill_date) FILTER(WHERE COALESCE(flow.is_deleted,FALSE)=FALSE)
           AS latest_flow_at
FROM accounts account
LEFT JOIN finance_reconciliations flow ON flow.account_id=account.id
WHERE COALESCE(account.is_deleted,FALSE)=FALSE
GROUP BY account.id,account.currency_id,account.init_balance,
         account.receipts_total,account.payments_total,
         account.balance_adjustments_total,account.balance_current;

COMMENT ON VIEW v_account_balance_integrity IS
    'Rebuilds native account balance from immutable active flows and exposes cache drift; it is not a bank-statement reconciliation';
COMMENT ON COLUMN finance_reconciliations.in_amount IS
    'Positive native-currency amount entering account_currency_id';
COMMENT ON COLUMN finance_reconciliations.out_amount IS
    'Positive native-currency amount leaving account_currency_id';
COMMENT ON COLUMN finance_reconciliations.amount_local IS
    'Optional functional/base-currency snapshot of this native account movement';

CREATE OR REPLACE VIEW v_receipt_flow_integrity AS
SELECT receipt.id AS receipt_id,receipt.bill_no,receipt.status,
       CASE WHEN
         (SELECT COUNT(*) FROM finance_reconciliations flow
          WHERE flow.source_doc_type='RECEIPT'
            AND flow.source_doc_id=receipt.id
            AND COALESCE(flow.is_deleted,FALSE)=FALSE)
           =CASE WHEN receipt.status=1 THEN 1 ELSE 2 END
         AND (SELECT COUNT(*) FROM finance_reconciliations flow
              WHERE flow.source_doc_type='RECEIPT'
                AND flow.source_doc_id=receipt.id
                AND flow.entry_kind='POSTING'
                AND COALESCE(flow.is_deleted,FALSE)=FALSE)=1
         AND NOT EXISTS(
           SELECT 1 FROM finance_reconciliations flow
           WHERE flow.source_doc_type='RECEIPT'
             AND flow.source_doc_id=receipt.id
             AND flow.entry_kind='POSTING'
             AND COALESCE(flow.is_deleted,FALSE)=FALSE
             AND (flow.account_id IS DISTINCT FROM receipt.account_id
                  OR flow.account_currency_id IS DISTINCT FROM receipt.account_currency_id
                  OR flow.bill_no IS DISTINCT FROM receipt.bill_no
                  OR flow.bill_date IS DISTINCT FROM receipt.bank_booked_at
                  OR flow.in_amount IS DISTINCT FROM receipt.account_amount
                  OR COALESCE(flow.out_amount,0)<>0
                  OR flow.amount_local IS DISTINCT FROM receipt.account_amount_local))
         AND ((receipt.status=1 AND NOT EXISTS(
                SELECT 1 FROM finance_reconciliations flow
                WHERE flow.source_doc_type='RECEIPT'
                  AND flow.source_doc_id=receipt.id
                  AND flow.entry_kind='REVERSAL'
                  AND COALESCE(flow.is_deleted,FALSE)=FALSE))
              OR (receipt.status=-1
                  AND (SELECT COUNT(*) FROM finance_reconciliations flow
                       WHERE flow.source_doc_type='RECEIPT'
                         AND flow.source_doc_id=receipt.id
                         AND flow.entry_kind='REVERSAL'
                         AND COALESCE(flow.is_deleted,FALSE)=FALSE)=1
                  AND NOT EXISTS(
                    SELECT 1 FROM finance_reconciliations reversal
                    LEFT JOIN finance_reconciliations posting
                      ON posting.id=reversal.reversal_of_id
                     AND posting.source_doc_type='RECEIPT'
                     AND posting.source_doc_id=receipt.id
                     AND posting.entry_kind='POSTING'
                     AND COALESCE(posting.is_deleted,FALSE)=FALSE
                    WHERE reversal.source_doc_type='RECEIPT'
                      AND reversal.source_doc_id=receipt.id
                      AND reversal.entry_kind='REVERSAL'
                      AND COALESCE(reversal.is_deleted,FALSE)=FALSE
                      AND (posting.id IS NULL
                           OR reversal.account_id IS DISTINCT FROM posting.account_id
                           OR reversal.account_currency_id IS DISTINCT FROM posting.account_currency_id
                           OR reversal.bill_no IS DISTINCT FROM receipt.bill_no
                           OR reversal.bill_date IS DISTINCT FROM receipt.reversed_at
                           OR NULLIF(btrim(reversal.reversal_reason),'') IS NULL
                           OR reversal.in_amount IS DISTINCT FROM posting.out_amount
                           OR reversal.out_amount IS DISTINCT FROM posting.in_amount
                           OR reversal.amount_local IS DISTINCT FROM posting.amount_local))))
         AND ((receipt.fee_settlement_mode<>'PAID_SEPARATELY'
               AND NOT EXISTS(
                 SELECT 1 FROM finance_reconciliations flow
                 WHERE flow.source_doc_type='RECEIPT_FEE'
                   AND flow.source_doc_id=receipt.id
                   AND COALESCE(flow.is_deleted,FALSE)=FALSE))
              OR (receipt.fee_settlement_mode='PAID_SEPARATELY'
                  AND (SELECT COUNT(*) FROM finance_reconciliations flow
                       WHERE flow.source_doc_type='RECEIPT_FEE'
                         AND flow.source_doc_id=receipt.id
                         AND COALESCE(flow.is_deleted,FALSE)=FALSE)
                    =CASE WHEN receipt.status=1 THEN 1 ELSE 2 END
                  AND (SELECT COUNT(*) FROM finance_reconciliations flow
                       WHERE flow.source_doc_type='RECEIPT_FEE'
                         AND flow.source_doc_id=receipt.id
                         AND flow.entry_kind='POSTING'
                         AND COALESCE(flow.is_deleted,FALSE)=FALSE)=1
                  AND NOT EXISTS(
                    SELECT 1 FROM finance_reconciliations flow
                    WHERE flow.source_doc_type='RECEIPT_FEE'
                      AND flow.source_doc_id=receipt.id
                      AND flow.entry_kind='POSTING'
                      AND COALESCE(flow.is_deleted,FALSE)=FALSE
                      AND (flow.account_id IS DISTINCT FROM receipt.fee_payment_account_id
                           OR flow.account_currency_id IS DISTINCT FROM receipt.fee_account_currency_id
                           OR flow.bill_no IS DISTINCT FROM receipt.bill_no
                           OR flow.bill_date IS DISTINCT FROM receipt.bank_booked_at
                           OR COALESCE(flow.in_amount,0)<>0
                           OR flow.out_amount IS DISTINCT FROM
                              (receipt.bank_fee_account_amount+receipt.other_fee_account_amount)
                           OR flow.amount_local IS DISTINCT FROM
                              (receipt.bank_fee+receipt.other_fee)))
                  AND ((receipt.status=1 AND NOT EXISTS(
                         SELECT 1 FROM finance_reconciliations flow
                         WHERE flow.source_doc_type='RECEIPT_FEE'
                           AND flow.source_doc_id=receipt.id
                           AND flow.entry_kind='REVERSAL'
                           AND COALESCE(flow.is_deleted,FALSE)=FALSE))
                       OR (receipt.status=-1
                           AND (SELECT COUNT(*) FROM finance_reconciliations flow
                                WHERE flow.source_doc_type='RECEIPT_FEE'
                                  AND flow.source_doc_id=receipt.id
                                  AND flow.entry_kind='REVERSAL'
                                  AND COALESCE(flow.is_deleted,FALSE)=FALSE)=1
                           AND NOT EXISTS(
                             SELECT 1 FROM finance_reconciliations reversal
                             LEFT JOIN finance_reconciliations posting
                               ON posting.id=reversal.reversal_of_id
                              AND posting.source_doc_type='RECEIPT_FEE'
                              AND posting.source_doc_id=receipt.id
                              AND posting.entry_kind='POSTING'
                              AND COALESCE(posting.is_deleted,FALSE)=FALSE
                             WHERE reversal.source_doc_type='RECEIPT_FEE'
                               AND reversal.source_doc_id=receipt.id
                               AND reversal.entry_kind='REVERSAL'
                               AND COALESCE(reversal.is_deleted,FALSE)=FALSE
                               AND (posting.id IS NULL
                                    OR reversal.account_id IS DISTINCT FROM posting.account_id
                                    OR reversal.account_currency_id IS DISTINCT FROM posting.account_currency_id
                                    OR reversal.bill_no IS DISTINCT FROM receipt.bill_no
                                    OR reversal.bill_date IS DISTINCT FROM receipt.reversed_at
                                    OR NULLIF(btrim(reversal.reversal_reason),'') IS NULL
                                    OR reversal.in_amount IS DISTINCT FROM posting.out_amount
                                    OR reversal.out_amount IS DISTINCT FROM posting.in_amount
                                    OR reversal.amount_local IS DISTINCT FROM posting.amount_local))))))
       THEN TRUE ELSE FALSE END AS is_consistent
FROM finance_receipts receipt
WHERE receipt.settlement_authority_version=1
  AND receipt.status IN(1,-1)
  AND COALESCE(receipt.is_deleted,FALSE)=FALSE;

COMMENT ON VIEW v_receipt_flow_integrity IS
    'Reconciles each V1 receipt native/local account posting and optional separate-fee posting with its immutable reversal lineage';

-- The receipt header, its real-account posting and an optional separately paid
-- fee posting are one terminal fact.  Keep this deferred so the application may
-- write them in any order inside one transaction, but direct SQL cannot commit a
-- V1 approved/reversed header without the matching append-only ledger facts.
-- Historical authority-version 0 receipts deliberately retain their old rules.
CREATE OR REPLACE FUNCTION fn_assert_v1_receipt_flow_terminal(
    p_receipt_id UUID)
RETURNS VOID AS $$
DECLARE
    v_authority_version SMALLINT;
    v_status SMALLINT;
    v_is_deleted BOOLEAN;
    v_is_consistent BOOLEAN;
BEGIN
    SELECT receipt.settlement_authority_version,receipt.status,receipt.is_deleted
      INTO v_authority_version,v_status,v_is_deleted
    FROM finance_receipts receipt
    WHERE receipt.id=p_receipt_id;

    IF NOT FOUND OR v_authority_version<>1 OR v_status NOT IN(1,-1)
       OR COALESCE(v_is_deleted,FALSE) THEN
        RETURN;
    END IF;

    SELECT integrity.is_consistent INTO v_is_consistent
    FROM v_receipt_flow_integrity integrity
    WHERE integrity.receipt_id=p_receipt_id;

    IF NOT COALESCE(v_is_consistent,FALSE) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='V1 terminal receipt does not match its append-only account flows',
            CONSTRAINT='receipt_flow_terminal_guard';
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_guard_receipt_flow_terminal_from_receipt()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM fn_assert_v1_receipt_flow_terminal(NEW.id);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_guard_receipt_flow_terminal_from_receipt
    AFTER INSERT OR UPDATE OF status,reversed_at,is_deleted
    ON finance_receipts DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_flow_terminal_from_receipt();

CREATE OR REPLACE FUNCTION fn_guard_receipt_flow_terminal_from_flow()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.source_doc_type IN('RECEIPT','RECEIPT_FEE') THEN
        PERFORM fn_assert_v1_receipt_flow_terminal(NEW.source_doc_id);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_guard_receipt_flow_terminal_from_flow
    AFTER INSERT ON finance_reconciliations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_flow_terminal_from_flow();

COMMENT ON FUNCTION fn_assert_v1_receipt_flow_terminal(UUID) IS
    'Deferred commit guard: every V1 terminal receipt must equal v_receipt_flow_integrity; V0 history is exempt';

-- Rebuildable performance projection. The immutable finance_reconciliations
-- ledger remains authoritative; this table only closes whole Shanghai months.
CREATE TABLE account_flow_monthly_summaries (
    id                      UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    account_id              UUID NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
    account_currency_id     UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    month_start             DATE NOT NULL,
    in_amount               NUMERIC(18,4) NOT NULL DEFAULT 0,
    out_amount              NUMERIC(18,4) NOT NULL DEFAULT 0,
    flow_count              BIGINT NOT NULL,
    first_posting_seq       BIGINT NOT NULL,
    last_posting_seq        BIGINT NOT NULL,
    last_rebuilt_at         TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY(account_id,account_currency_id,month_start),
    CONSTRAINT account_flow_monthly_month_start_chk CHECK (
        month_start=date_trunc('month',month_start)::DATE),
    CONSTRAINT account_flow_monthly_amount_chk CHECK (
        in_amount>=0 AND out_amount>=0),
    CONSTRAINT account_flow_monthly_count_chk CHECK (
        flow_count>0 AND first_posting_seq<=last_posting_seq)
);

CREATE INDEX idx_account_flow_monthly_account_month
    ON account_flow_monthly_summaries(
        account_id,account_currency_id,month_start)
    INCLUDE(in_amount,out_amount,flow_count,
            first_posting_seq,last_posting_seq);

CREATE OR REPLACE FUNCTION fn_rebuild_account_flow_monthly_summaries(
    p_account_id UUID DEFAULT NULL)
RETURNS BIGINT AS $$
DECLARE v_rows BIGINT;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('uten:account-flow-monthly-summary',0));
    DELETE FROM account_flow_monthly_summaries summary
    WHERE p_account_id IS NULL OR summary.account_id=p_account_id;

    INSERT INTO account_flow_monthly_summaries(
        account_id,account_currency_id,month_start,
        in_amount,out_amount,flow_count,
        first_posting_seq,last_posting_seq,
        last_rebuilt_at,created_at,updated_at)
    SELECT flow.account_id,flow.account_currency_id,
           date_trunc('month',flow.bill_date AT TIME ZONE 'Asia/Shanghai')::DATE,
           SUM(COALESCE(flow.in_amount,0)),
           SUM(COALESCE(flow.out_amount,0)),COUNT(*),
           MIN(flow.posting_seq),MAX(flow.posting_seq),
           now(),now(),now()
    FROM finance_reconciliations flow
    WHERE COALESCE(flow.is_deleted,FALSE)=FALSE
      AND flow.account_id IS NOT NULL
      AND flow.account_currency_id IS NOT NULL
      AND flow.bill_date IS NOT NULL
      AND (p_account_id IS NULL OR flow.account_id=p_account_id)
    GROUP BY flow.account_id,flow.account_currency_id,
             date_trunc('month',flow.bill_date AT TIME ZONE 'Asia/Shanghai')::DATE;
    GET DIAGNOSTICS v_rows=ROW_COUNT;
    RETURN v_rows;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW v_account_flow_monthly_integrity AS
WITH ledger AS (
    SELECT flow.account_id,flow.account_currency_id,
           date_trunc('month',flow.bill_date AT TIME ZONE 'Asia/Shanghai')::DATE
               AS month_start,
           SUM(COALESCE(flow.in_amount,0)) AS in_amount,
           SUM(COALESCE(flow.out_amount,0)) AS out_amount,
           COUNT(*) AS flow_count,
           MIN(flow.posting_seq) AS first_posting_seq,
           MAX(flow.posting_seq) AS last_posting_seq
    FROM finance_reconciliations flow
    WHERE COALESCE(flow.is_deleted,FALSE)=FALSE
    GROUP BY flow.account_id,flow.account_currency_id,
             date_trunc('month',flow.bill_date AT TIME ZONE 'Asia/Shanghai')::DATE
)
SELECT COALESCE(ledger.account_id,summary.account_id) AS account_id,
       COALESCE(ledger.account_currency_id,summary.account_currency_id)
           AS account_currency_id,
       COALESCE(ledger.month_start,summary.month_start) AS month_start,
       ledger.in_amount AS ledger_in_amount,
       summary.in_amount AS summary_in_amount,
       COALESCE(summary.in_amount,0)-COALESCE(ledger.in_amount,0)
           AS in_difference,
       ledger.out_amount AS ledger_out_amount,
       summary.out_amount AS summary_out_amount,
       COALESCE(summary.out_amount,0)-COALESCE(ledger.out_amount,0)
           AS out_difference,
       ledger.flow_count AS ledger_flow_count,
       summary.flow_count AS summary_flow_count,
       ledger.first_posting_seq AS ledger_first_posting_seq,
       summary.first_posting_seq AS summary_first_posting_seq,
       ledger.last_posting_seq AS ledger_last_posting_seq,
       summary.last_posting_seq AS summary_last_posting_seq,
       ledger.account_id IS NOT NULL
       AND summary.account_id IS NOT NULL
       AND ledger.account_currency_id IS NOT DISTINCT FROM summary.account_currency_id
       AND ledger.month_start IS NOT DISTINCT FROM summary.month_start
       AND ledger.in_amount=summary.in_amount
       AND ledger.out_amount=summary.out_amount
       AND ledger.flow_count=summary.flow_count
       AND ledger.first_posting_seq=summary.first_posting_seq
       AND ledger.last_posting_seq=summary.last_posting_seq AS is_consistent
FROM ledger
FULL OUTER JOIN account_flow_monthly_summaries summary
  ON summary.account_id=ledger.account_id
 AND summary.account_currency_id=ledger.account_currency_id
 AND summary.month_start=ledger.month_start;

CREATE OR REPLACE FUNCTION fn_assert_account_flow_monthly_integrity(
    p_account_id UUID DEFAULT NULL)
RETURNS VOID AS $$
DECLARE v_invalid BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_invalid
    FROM v_account_flow_monthly_integrity integrity
    WHERE (p_account_id IS NULL OR integrity.account_id=p_account_id)
      AND NOT integrity.is_consistent;
    IF v_invalid<>0 THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE=format(
                'account flow monthly summary differs from immutable ledger in %s month(s)',
                v_invalid),
            CONSTRAINT='account_flow_monthly_integrity_guard';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Build from all active historical facts before enabling incremental upkeep.
SELECT fn_rebuild_account_flow_monthly_summaries(NULL);
SELECT fn_assert_account_flow_monthly_integrity(NULL);

CREATE TRIGGER trg_audit_account_flow_monthly_summaries
    AFTER INSERT OR UPDATE OR DELETE ON account_flow_monthly_summaries
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE FUNCTION fn_upsert_account_flow_monthly_summary()
RETURNS TRIGGER AS $$
DECLARE v_month DATE;
BEGIN
    PERFORM pg_advisory_xact_lock_shared(
        hashtextextended('uten:account-flow-monthly-summary',0));
    v_month:=date_trunc(
        'month',NEW.bill_date AT TIME ZONE 'Asia/Shanghai')::DATE;
    INSERT INTO account_flow_monthly_summaries(
        account_id,account_currency_id,month_start,
        in_amount,out_amount,flow_count,
        first_posting_seq,last_posting_seq,
        last_rebuilt_at,created_at,updated_at)
    VALUES(
        NEW.account_id,NEW.account_currency_id,v_month,
        COALESCE(NEW.in_amount,0),COALESCE(NEW.out_amount,0),1,
        NEW.posting_seq,NEW.posting_seq,
        NULL,now(),now())
    ON CONFLICT(account_id,account_currency_id,month_start) DO UPDATE
    SET in_amount=account_flow_monthly_summaries.in_amount+EXCLUDED.in_amount,
        out_amount=account_flow_monthly_summaries.out_amount+EXCLUDED.out_amount,
        flow_count=account_flow_monthly_summaries.flow_count+1,
        first_posting_seq=LEAST(
            account_flow_monthly_summaries.first_posting_seq,
            EXCLUDED.first_posting_seq),
        last_posting_seq=GREATEST(
            account_flow_monthly_summaries.last_posting_seq,
            EXCLUDED.last_posting_seq),
        updated_at=now();
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_upsert_account_flow_monthly_summary
    AFTER INSERT ON finance_reconciliations
    FOR EACH ROW EXECUTE FUNCTION fn_upsert_account_flow_monthly_summary();

COMMENT ON TABLE account_flow_monthly_summaries IS
    'Audited, rebuildable native-currency monthly projection of the immutable account ledger; Shanghai month boundaries';
COMMENT ON VIEW v_account_flow_monthly_integrity IS
    'Compares every stored account/currency/month aggregate with raw append-only finance_reconciliations facts';
COMMENT ON FUNCTION fn_rebuild_account_flow_monthly_summaries(UUID) IS
    'Rebuilds all months or one account under the same advisory lock used by incremental inserts';
