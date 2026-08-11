-- V238: carry forward safeguards that were designed after V236 had already run.
--
-- V236 is deployed history and must retain checksum -2024018731.  This migration
-- therefore corrects only values that can be proven to have been synthesized by
-- V236 for rows that existed before V236 was installed.  Facts posted after V236
-- are outside this repair window and are never rewritten here.

DO $$
DECLARE
    v236_conservative_cutoff TIMESTAMPTZ;
BEGIN
    -- Flyway stores installed_on without a zone.  This project supports UTC
    -- and Asia/Shanghai database sessions, so choose the earlier possible
    -- instant.  A timezone change may make this repair skip an ambiguous row,
    -- but can never enlarge the automatic-repair window.
    SELECT LEAST(
        installed_on AT TIME ZONE 'UTC',
        installed_on AT TIME ZONE 'Asia/Shanghai')
    INTO v236_conservative_cutoff
    FROM flyway_schema_history
    WHERE version = '236' AND success = TRUE;

    IF v236_conservative_cutoff IS NULL THEN
        RAISE EXCEPTION 'V238 requires a successful V236 history row';
    END IF;

    UPDATE ar_ap_ledger ledger
    SET amount_received_original = NULL,
        amount_write_off_original = NULL,
        amount_balance_original = NULL
    FROM currencies currency
    WHERE currency.id = ledger.currency_id
      -- Skip any ledger or currency master touched after the conservative
      -- V236 cutoff: their then-current facts cannot be reconstructed safely.
      AND ledger.created_at <= v236_conservative_cutoff
      AND ledger.updated_at <= v236_conservative_cutoff
      AND currency.updated_at <= v236_conservative_cutoff
      -- Exact V236 synthesis signature; do not touch later business postings.
      AND ledger.exchange_rate > 0
      AND ledger.amount_received_local = ledger.amount_settled
      AND ledger.amount_write_off_local = 0
      AND ledger.amount_received_original
            = ROUND(ledger.amount_settled / ledger.exchange_rate, 4)
      AND ledger.amount_write_off_original = 0
      AND ledger.amount_balance_original
            = ledger.amount_original
                - ROUND(ledger.amount_settled / ledger.exchange_rate, 4)
      AND (
          btrim(currency.name) = '人民币'
          OR upper(btrim(currency.code)) IN ('CNY', 'RMB')
      )
      AND ROUND(ledger.amount_original * ledger.exchange_rate, 4)
            = ledger.amount_original_local
      AND (
          currency.status IS DISTINCT FROM '使用'
          OR COALESCE(currency.is_deleted, FALSE) = TRUE
          OR ledger.exchange_rate IS DISTINCT FROM 1::NUMERIC
      );
END $$;

-- Do not rename or reparent V236-created leaves.  Only create a new active leaf
-- when finance has no active account with the required business meaning.
INSERT INTO payment_styles (
    code, name, category, parent_id, level, sort_order, path,
    is_departmental, is_receipt, is_payment, status, auto_created)
SELECT 'SYS-FIN-BANK-FEE-V238',
       '手续费',
       'EXPENSE',
       parent.id,
       COALESCE(parent.level + 1, 0),
       930,
       COALESCE(parent.path, '/') || 'SYS-FIN-BANK-FEE-V238/',
       FALSE, FALSE, TRUE, '使用', TRUE
FROM (VALUES (1)) seed(dummy)
LEFT JOIN LATERAL (
    SELECT style.id, style.level, style.path
    FROM payment_styles style
    WHERE style.path = '/043/'
      AND style.category = 'EXPENSE'
      AND style.status = '使用'
      AND COALESCE(style.is_deleted, FALSE) = FALSE
    ORDER BY style.id
    LIMIT 1
) parent ON TRUE
WHERE NOT EXISTS (
    SELECT 1
    FROM payment_styles existing
    WHERE existing.category = 'EXPENSE'
      AND existing.name = '手续费'
      AND existing.status = '使用'
      AND COALESCE(existing.is_deleted, FALSE) = FALSE
);

INSERT INTO payment_styles (
    code, name, category, parent_id, level, sort_order, path,
    is_departmental, is_receipt, is_payment, status, auto_created)
SELECT 'SYS-FIN-FX-GL-V238',
       '汇兑损益',
       'EXPENSE',
       parent.id,
       COALESCE(parent.level + 1, 0),
       931,
       COALESCE(parent.path, '/') || 'SYS-FIN-FX-GL-V238/',
       FALSE, FALSE, TRUE, '使用', TRUE
FROM (VALUES (1)) seed(dummy)
LEFT JOIN LATERAL (
    SELECT style.id, style.level, style.path
    FROM payment_styles style
    WHERE style.path = '/043/'
      AND style.category = 'EXPENSE'
      AND style.status = '使用'
      AND COALESCE(style.is_deleted, FALSE) = FALSE
    ORDER BY style.id
    LIMIT 1
) parent ON TRUE
WHERE NOT EXISTS (
    SELECT 1
    FROM payment_styles existing
    WHERE existing.category = 'EXPENSE'
      AND existing.name = '汇兑损益'
      AND existing.status = '使用'
      AND COALESCE(existing.is_deleted, FALSE) = FALSE
);
