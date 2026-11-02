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
ROLLBACK;
