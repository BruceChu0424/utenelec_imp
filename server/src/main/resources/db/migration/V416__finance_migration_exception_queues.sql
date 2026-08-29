-- V416: forward-only finance migration exception queues.
--
-- V407/V408 have already been exercised by local Flyway databases and their
-- bytes remain immutable. This migration adds read-only reconciliation queues
-- for facts that cannot be upgraded safely and tightens only future flow
-- inserts. It never rewrites a receipt, account flow, balance or GL entry.

ALTER TABLE finance_receipts
    ADD CONSTRAINT finance_receipts_v1_external_evidence_chk CHECK (
        settlement_authority_version=0 OR (
            maker_id IS NOT NULL
            AND (status=0 OR (approver_id IS NOT NULL AND approver_id<>maker_id))
            AND NULLIF(btrim(bank_reference),'') IS NOT NULL
            AND amount_original>0
            AND exchange_rate>0
            AND amount_local=ROUND(amount_original*exchange_rate,4)
            AND (
                (settlement_channel='DIRECT_ACCOUNT'
                 AND agent_statement_no IS NULL)
                OR
                (settlement_channel='TRADE_AGENT_CONVERSION'
                 AND NULLIF(btrim(agent_statement_no),'') IS NOT NULL)
            )
        )
    ) NOT VALID;
ALTER TABLE finance_receipts
    VALIDATE CONSTRAINT finance_receipts_v1_external_evidence_chk;

CREATE OR REPLACE VIEW v_receipt_v0_settlement_exceptions AS
SELECT receipt.id AS receipt_id,
       receipt.bill_no,
       receipt.bill_date,
       receipt.status,
       receipt.receipt_kind,
       receipt.client_id,
       receipt.currency_id,
       receipt.account_id,
       receipt.amount_original,
       receipt.amount_local,
       receipt.exchange_rate,
       receipt.bank_fee,
       receipt.other_fee,
       line_fact.active_line_count,
       line_fact.write_off_line_count,
       line_fact.missing_currency_or_rate_line_count,
       line_fact.missing_ar_snapshot_line_count,
       line_fact.missing_ledger_reference_line_count,
       gl.reconciliation_state AS gl_reconciliation_state,
       ARRAY_REMOVE(ARRAY[
         'V0_BANK_AND_CHANNEL_EVIDENCE_UNAVAILABLE'::TEXT,
         CASE WHEN COALESCE(receipt.bank_fee,0)<>0
                    OR COALESCE(receipt.other_fee,0)<>0
                    OR line_fact.write_off_line_count<>0
              THEN 'V0_FEE_OR_WRITEOFF_AMBIGUOUS' END,
         CASE WHEN receipt.currency_id IS NULL
                    OR receipt.exchange_rate IS NULL
                    OR receipt.exchange_rate<=0
                    OR line_fact.missing_currency_or_rate_line_count<>0
                    OR (receipt.receipt_kind='AR_SETTLEMENT'
                        AND line_fact.missing_ar_snapshot_line_count<>0)
              THEN 'V0_ORIGINAL_CURRENCY_EVIDENCE_INCOMPLETE' END,
         CASE WHEN receipt.receipt_kind='AR_SETTLEMENT'
                    AND (line_fact.active_line_count=0
                         OR line_fact.missing_ledger_reference_line_count<>0)
              THEN 'V0_AR_ALLOCATION_REFERENCE_INCOMPLETE' END,
         CASE WHEN gl.reconciliation_state IS NULL
                    OR gl.reconciliation_state<>'OK'
              THEN 'V0_GL_RECONCILIATION_REQUIRED' END
       ],NULL) AS exception_reasons
FROM finance_receipts receipt
LEFT JOIN LATERAL (
  SELECT COUNT(*) AS active_line_count,
         COUNT(*) FILTER(WHERE COALESCE(line.write_off_amount,0)<>0
                               OR COALESCE(line.write_off_local,0)<>0)
           AS write_off_line_count,
         COUNT(*) FILTER(WHERE line.currency_id IS NULL
                               OR line.exchange_rate IS NULL
                               OR line.exchange_rate<=0)
           AS missing_currency_or_rate_line_count,
         COUNT(*) FILTER(WHERE line.balance_before_original IS NULL
                               OR line.balance_after_original IS NULL
                               OR line.applied_amount_local IS NULL)
           AS missing_ar_snapshot_line_count,
         COUNT(*) FILTER(WHERE line.applied_ledger_id IS NULL)
           AS missing_ledger_reference_line_count
  FROM finance_receipt_lines line
  WHERE line.receipt_id=receipt.id
    AND COALESCE(line.is_deleted,FALSE)=FALSE
) line_fact ON TRUE
LEFT JOIN v_receipt_v0_gl_reconciliation gl
  ON gl.receipt_id=receipt.id
WHERE receipt.settlement_authority_version=0
  AND receipt.status IN(1,-1)
  AND COALESCE(receipt.is_deleted,FALSE)=FALSE;

COMMENT ON VIEW v_receipt_v0_settlement_exceptions IS
    'Terminal V0 receipt review queue; missing V1 bank/channel, fee, original-currency, allocation or GL evidence is classified but never inferred';

CREATE OR REPLACE VIEW v_account_flow_migration_exceptions AS
WITH classified AS (
  SELECT flow.id AS flow_id,
         flow.posting_seq,
         flow.source_doc_type,
         flow.source_doc_id,
         flow.bill_no,
         flow.bill_date,
         flow.account_id,
         flow.account_currency_id,
         account.currency_id AS current_account_currency_id,
         flow.in_amount,
         flow.out_amount,
         flow.amount_local,
         flow.entry_kind,
         COALESCE(flow.is_deleted,FALSE) AS legacy_soft_deleted,
         ARRAY_REMOVE(ARRAY[
           CASE WHEN COALESCE(flow.is_deleted,FALSE)
                THEN 'LEGACY_SOFT_DELETED_FLOW' END,
           CASE WHEN flow.source_doc_id IS NULL
                THEN 'SOURCE_DOC_ID_MISSING' END,
           CASE WHEN flow.account_id IS NULL
                THEN 'ACCOUNT_ID_MISSING' END,
           CASE WHEN flow.account_id IS NOT NULL AND account.id IS NULL
                THEN 'ACCOUNT_NOT_FOUND' END,
           CASE WHEN account.id IS NOT NULL
                      AND COALESCE(account.is_deleted,FALSE)
                THEN 'ACCOUNT_DELETED' END,
           CASE WHEN account.id IS NOT NULL
                      AND account.status<>'使用'
                THEN 'ACCOUNT_INACTIVE' END,
           CASE WHEN account.id IS NOT NULL AND account.currency_id IS NULL
                THEN 'ACCOUNT_CURRENCY_MISSING' END,
           CASE WHEN flow.account_currency_id IS NULL
                THEN 'FLOW_CURRENCY_SNAPSHOT_MISSING' END,
           CASE WHEN flow.account_currency_id IS NOT NULL AND currency.id IS NULL
                THEN 'FLOW_CURRENCY_NOT_FOUND' END,
           CASE WHEN currency.id IS NOT NULL
                      AND (currency.status<>'使用'
                           OR COALESCE(currency.is_deleted,FALSE))
                THEN 'FLOW_CURRENCY_INACTIVE' END,
           CASE WHEN account.currency_id IS NOT NULL
                      AND flow.account_currency_id IS NOT NULL
                      AND flow.account_currency_id IS DISTINCT FROM account.currency_id
                THEN 'ACCOUNT_FLOW_CURRENCY_MISMATCH' END,
           CASE WHEN COALESCE(flow.in_amount,0)<0
                      OR COALESCE(flow.out_amount,0)<0
                      OR ((COALESCE(flow.in_amount,0)=0)
                          =(COALESCE(flow.out_amount,0)=0))
                THEN 'SIGNED_AMOUNT_INVALID' END,
           CASE WHEN flow.amount_local<0
                THEN 'LOCAL_AMOUNT_NEGATIVE' END,
           CASE WHEN currency.is_base_currency IS TRUE
                      AND flow.amount_local IS NULL
                THEN 'BASE_LOCAL_SNAPSHOT_MISSING' END,
           CASE WHEN currency.is_base_currency IS TRUE
                      AND flow.amount_local IS NOT NULL
                      AND flow.amount_local<>COALESCE(flow.in_amount,0)
                                             +COALESCE(flow.out_amount,0)
                THEN 'BASE_LOCAL_SNAPSHOT_MISMATCH' END,
           CASE WHEN currency.is_base_currency IS FALSE
                      AND flow.amount_local IS NULL
                THEN 'FOREIGN_LOCAL_SNAPSHOT_UNPROVEN' END
         ],NULL) AS exception_reasons,
         (COALESCE(flow.is_deleted,FALSE)
          OR flow.account_id IS NULL
          OR account.id IS NULL
          OR COALESCE(account.is_deleted,FALSE)
          OR account.status<>'使用'
          OR account.currency_id IS NULL
          OR flow.account_currency_id IS NULL
          OR currency.id IS NULL
          OR currency.status<>'使用'
          OR COALESCE(currency.is_deleted,FALSE)
          OR flow.account_currency_id IS DISTINCT FROM account.currency_id
          OR COALESCE(flow.in_amount,0)<0
          OR COALESCE(flow.out_amount,0)<0
          OR ((COALESCE(flow.in_amount,0)=0)=(COALESCE(flow.out_amount,0)=0)))
           AS native_balance_blocking
  FROM finance_reconciliations flow
  LEFT JOIN accounts account ON account.id=flow.account_id
  LEFT JOIN currencies currency ON currency.id=flow.account_currency_id
)
SELECT *
FROM classified
WHERE CARDINALITY(exception_reasons)>0;

COMMENT ON VIEW v_account_flow_migration_exceptions IS
    'Pre-V408 account-flow migration review queue; structural native-balance blockers and unproven foreign functional snapshots are classified and never auto-repaired';

-- Re-declare the insert guard forward-only. Existing V408 rows remain byte-for-
-- byte untouched; every future flow needs an auditable source and a positive
-- functional snapshot, with identity value for a base-currency account.
CREATE OR REPLACE FUNCTION fn_guard_account_flow_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_currency UUID;
    v_account_active BOOLEAN;
    v_currency_active BOOLEAN;
    v_base_currency BOOLEAN;
BEGIN
    IF NEW.account_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account flow requires a real account UUID',
            CONSTRAINT='finance_reconciliations_account_identity_guard';
    END IF;
    IF NEW.source_doc_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='new account flow requires an auditable source document UUID',
            CONSTRAINT='finance_reconciliations_source_identity_guard';
    END IF;
    IF NEW.bill_date IS NULL OR COALESCE(NEW.is_deleted,FALSE) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='new account flow requires an effective timestamp and cannot start deleted',
            CONSTRAINT='finance_reconciliations_effective_time_guard';
    END IF;
    SELECT account.currency_id,
           account.status='使用' AND COALESCE(account.is_deleted,FALSE)=FALSE,
           currency.status='使用' AND COALESCE(currency.is_deleted,FALSE)=FALSE,
           currency.is_base_currency
      INTO v_currency,v_account_active,v_currency_active,v_base_currency
    FROM accounts account
    JOIN currencies currency ON currency.id=account.currency_id
    WHERE account.id=NEW.account_id
    FOR SHARE OF account,currency;
    IF v_currency IS NULL OR NOT COALESCE(v_account_active,FALSE)
       OR NOT COALESCE(v_currency_active,FALSE) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account flow requires an active account and active currency UUID',
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
    IF NEW.amount_local IS NULL OR NEW.amount_local<=0 THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account flow requires one positive functional-currency snapshot',
            CONSTRAINT='finance_reconciliations_local_amount_guard';
    END IF;
    IF COALESCE(v_base_currency,FALSE)
       AND NEW.amount_local<>COALESCE(NEW.in_amount,0)+COALESCE(NEW.out_amount,0) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='base-currency account flow native and functional amounts must match',
            CONSTRAINT='finance_reconciliations_base_amount_guard';
    END IF;
    NEW.in_amount:=COALESCE(NEW.in_amount,0);
    NEW.out_amount:=COALESCE(NEW.out_amount,0);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
