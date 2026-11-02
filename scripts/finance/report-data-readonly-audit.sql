-- Read-only evidence for an explicitly selected local database snapshot.
-- Does not refresh projections, heal balances, or modify business records.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '30s';

SELECT jsonb_build_object(
    'database', current_database(),
    'transactionReadOnly', current_setting('transaction_read_only'),
    'latestMigration', (SELECT version FROM flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1),
    'accounts', (SELECT count(*) FROM accounts WHERE NOT coalesce(is_deleted,false)),
    'accountFlowRows', (SELECT count(*) FROM finance_reconciliations WHERE NOT coalesce(is_deleted,false)),
    'arApRows', (SELECT count(*) FROM ar_ap_ledger WHERE NOT coalesce(is_deleted,false)),
    'nativeArApRows', (SELECT count(*) FROM ar_ap_ledger WHERE status=1 AND NOT coalesce(is_deleted,false) AND legacy_import_run_id IS NULL),
    'bankTransfers', (SELECT count(*) FROM finance_bank_transfers WHERE NOT coalesce(is_deleted,false)),
    'glEntries', (SELECT count(*) FROM gl_entries WHERE NOT coalesce(is_deleted,false)),
    'latestAccountFlowDate', (SELECT max(bill_date) FROM finance_reconciliations WHERE NOT coalesce(is_deleted,false))
) AS snapshot_coverage;

WITH source_run AS (
    SELECT reconciliation_summary
      FROM legacy_migration_runs
     WHERE reconciliation_summary ? 'financeMasterSources'
     ORDER BY finished_at DESC NULLS LAST LIMIT 1
), source_accounts AS (
    SELECT entry.key::integer AS legacy_id,entry.value->'typed_source' AS original
      FROM source_run
      CROSS JOIN LATERAL jsonb_each(reconciliation_summary#>'{financeMasterSources,accounts}') entry
)
SELECT jsonb_build_object(
    'sourceAccounts', (SELECT count(*) FROM source_accounts),
    'accountAmountsChangedSinceImportedSource', (
        SELECT count(*) FROM source_accounts s LEFT JOIN accounts a USING(legacy_id)
         WHERE a.id IS NULL
            OR a.init_balance IS DISTINCT FROM (s.original->>'init_balance')::numeric
            OR a.receipts_total IS DISTINCT FROM (s.original->>'receipts_total')::numeric
            OR a.payments_total IS DISTINCT FROM (s.original->>'payments_total')::numeric
            OR a.balance_current IS DISTINCT FROM (s.original->>'balance_current')::numeric
    ),
    'masterBalanceConservationDifferences', (
        SELECT count(*) FROM accounts
         WHERE NOT coalesce(is_deleted,false)
           AND balance_current IS DISTINCT FROM coalesce(init_balance,0)+coalesce(receipts_total,0)
                -coalesce(payments_total,0)+coalesce(balance_adjustments_total,0)
    )
) AS imported_master_preservation;

WITH replay AS (
    SELECT a.id, a.balance_current,
           coalesce(a.init_balance,0) + coalesce(sum(coalesce(f.in_amount,0)-coalesce(f.out_amount,0)),0) AS expected
      FROM accounts a
      LEFT JOIN finance_reconciliations f ON f.account_id=a.id AND NOT coalesce(f.is_deleted,false)
     WHERE NOT coalesce(a.is_deleted,false)
     GROUP BY a.id
), native_arap AS (
    SELECT amount_balance, amount_original_local-coalesce(amount_settled,0)-coalesce(amount_offset_local,0) AS expected
      FROM ar_ap_ledger
     WHERE status=1 AND NOT coalesce(is_deleted,false) AND legacy_import_run_id IS NULL
), bank AS (
    SELECT t.id,t.amount_original,t.amount_local,
           sum(l.amount_original) AS line_original,sum(l.amount_local) AS line_local
      FROM finance_bank_transfers t
      LEFT JOIN finance_bank_transfer_lines l ON l.transfer_id=t.id AND NOT coalesce(l.is_deleted,false)
     WHERE t.status=1 AND NOT coalesce(t.is_deleted,false)
     GROUP BY t.id
)
SELECT jsonb_build_object(
    'accountBalanceReplayDifferences', (SELECT count(*) FROM replay WHERE balance_current IS DISTINCT FROM expected),
    'nativeArApBalanceDifferences', (SELECT count(*) FROM native_arap WHERE amount_balance IS DISTINCT FROM expected),
    'bankHeaderLineDifferences', (SELECT count(*) FROM bank WHERE amount_original IS DISTINCT FROM line_original OR amount_local IS DISTINCT FROM line_local),
    'orphanFlowAccounts', (SELECT count(*) FROM finance_reconciliations f LEFT JOIN accounts a ON a.id=f.account_id WHERE NOT coalesce(f.is_deleted,false) AND a.id IS NULL),
    'missingFlowCurrency', (SELECT count(*) FROM finance_reconciliations WHERE NOT coalesce(is_deleted,false) AND account_currency_id IS NULL),
    'duplicatePostingSequenceGroups', (SELECT count(*) FROM (SELECT posting_seq FROM finance_reconciliations WHERE NOT coalesce(is_deleted,false) AND posting_seq IS NOT NULL GROUP BY posting_seq HAVING count(*)>1) d)
) AS balance_and_integrity;

WITH expected AS (
    SELECT account_id,account_currency_id,date_trunc('month',bill_date AT TIME ZONE 'Asia/Shanghai')::date AS month_start,
           sum(coalesce(in_amount,0)) AS in_amount,sum(coalesce(out_amount,0)) AS out_amount,count(*) AS flow_count,
           min(posting_seq) AS first_posting_seq,max(posting_seq) AS last_posting_seq
      FROM finance_reconciliations WHERE NOT coalesce(is_deleted,false)
     GROUP BY account_id,account_currency_id,date_trunc('month',bill_date AT TIME ZONE 'Asia/Shanghai')::date
), actual AS (
    SELECT account_id,account_currency_id,month_start,in_amount,out_amount,flow_count,first_posting_seq,last_posting_seq
      FROM account_flow_monthly_summaries
), drift AS (
    (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
    UNION ALL
    (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
)
SELECT jsonb_build_object('expectedMonthlyGroups',(SELECT count(*) FROM expected),
                          'actualMonthlyGroups',(SELECT count(*) FROM actual),
                          'symmetricDifferenceRows',(SELECT count(*) FROM drift)) AS monthly_projection;

-- Independently reconcile the imported opening-only fixture. Native cash,
-- native ledgers, reversals or offsets make this partial-source comparison
-- inapplicable; a NULL difference in that case is not a verified zero.
WITH eligibility AS (
    SELECT NOT EXISTS(SELECT 1 FROM ar_ap_ledger WHERE legacy_import_run_id IS NULL
                      OR status<>1 OR coalesce(is_deleted,false))
       AND NOT EXISTS(SELECT 1 FROM finance_receipts WHERE legacy_id IS NULL AND legacy_import_run_id IS NULL
                       AND status IN(1,-1) AND NOT coalesce(is_deleted,false))
       AND NOT EXISTS(SELECT 1 FROM finance_payments WHERE legacy_id IS NULL AND legacy_import_run_id IS NULL
                       AND status IN(1,-1) AND NOT coalesce(is_deleted,false))
       AND NOT EXISTS(SELECT 1 FROM customer_open_item_offsets)
       AND NOT EXISTS(SELECT 1 FROM supplier_open_item_offsets) AS applicable
), expected AS (
    SELECT ledger.direction AS side,
           CASE WHEN ledger.direction='AR' THEN ledger.client_id ELSE ledger.supplier_id END AS party_id,
           ledger.currency_id,
           date_trunc('month',(ledger.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz
                       AT TIME ZONE 'Asia/Shanghai')::date AS month_start,
           sum((proof.initial_state->>'amount_balance_original')::numeric) AS net_original,
           sum((proof.initial_state->>'amount_balance')::numeric) AS posted_local_sum,
           0::numeric AS settled_local_sum,
           sum((proof.initial_state->>'amount_balance')::numeric) AS net_local,
           count(*) AS event_count,
           count(*) FILTER(WHERE proof.initial_state->>'amount_balance_original' IS NULL
                              OR ledger.currency_id IS NULL) AS null_original_count
      FROM ar_ap_ledger ledger
      JOIN legacy_finance_import_sources proof ON proof.run_id=ledger.legacy_import_run_id
           AND proof.target_id=ledger.id AND proof.target_table='ar_ap_ledger'
     WHERE ledger.status=1 AND NOT coalesce(ledger.is_deleted,false)
       AND ledger.legacy_import_run_id IS NOT NULL
     GROUP BY ledger.direction,
              CASE WHEN ledger.direction='AR' THEN ledger.client_id ELSE ledger.supplier_id END,
              ledger.currency_id,
              date_trunc('month',(ledger.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz
                          AT TIME ZONE 'Asia/Shanghai')::date
), actual AS (
    SELECT side,party_id,currency_id,month_start,net_original,posted_local_sum,settled_local_sum,
           net_local,event_count,null_original_count FROM party_monthly_summaries
), drift AS (
    (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
    UNION ALL
    (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
)
SELECT jsonb_build_object(
    'applicableOpeningOnlySnapshot',(SELECT applicable FROM eligibility),
    'expectedGroups',(SELECT count(*) FROM expected),
    'actualGroups',(SELECT count(*) FROM actual),
    'symmetricDifferenceRows',CASE WHEN (SELECT applicable FROM eligibility) THEN (SELECT count(*) FROM drift) END,
    'unknownOriginalEvents',(SELECT sum(null_original_count) FROM expected)
) AS historical_opening_monthly;

-- This diagnostic view also classifies preserved legacy signed amounts and
-- absent native document links. These are conditions to interpret, not an
-- assertion that each historical row has an incorrect monetary amount.
SELECT jsonb_build_object('reason',reason,'rows',count(*)) AS legacy_condition
  FROM v_account_flow_migration_exceptions
  CROSS JOIN LATERAL unnest(exception_reasons) reason
 GROUP BY reason ORDER BY reason;
ROLLBACK;
