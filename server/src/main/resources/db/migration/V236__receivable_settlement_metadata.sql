-- V236: professional receivable settlement metadata and immutable source snapshots.
--
-- Existing Flyway migrations are immutable. This additive migration keeps the
-- legacy/local settlement columns for compatibility while introducing an
-- explicit cash/write-off split and original-currency balance fields for new
-- postings. Historical foreign-currency rates are not authoritative: no
-- original-currency receipt or balance is inferred from them.

ALTER TABLE ar_ap_ledger
    ADD COLUMN amount_received_original NUMERIC(18,4),
    ADD COLUMN amount_received_local NUMERIC(18,4),
    ADD COLUMN amount_write_off_original NUMERIC(18,4),
    ADD COLUMN amount_write_off_local NUMERIC(18,4),
    ADD COLUMN amount_balance_original NUMERIC(18,4);

-- amount_settled is an authoritative local-currency cumulative fact. Preserve
-- that fact as the pre-V236 cash component; historic fee allocation does not
-- exist, so this migration deliberately does not invent a write-off split.
UPDATE ar_ap_ledger
SET amount_received_local = amount_settled,
    amount_write_off_local = 0;

-- A narrow, provably single-currency subset can retain original-currency
-- continuity: only the explicit RMB master plus the exact stored amount/rate
-- identity qualifies. NULL currency and every foreign currency remain NULL;
-- the widespread legacy foreign rate=1 defect must never be treated as proof.
UPDATE ar_ap_ledger ledger
SET amount_received_original = ROUND(ledger.amount_settled / ledger.exchange_rate, 4),
    amount_write_off_original = 0,
    amount_balance_original = ledger.amount_original
        - ROUND(ledger.amount_settled / ledger.exchange_rate, 4)
FROM currencies currency
WHERE currency.id = ledger.currency_id
  AND (
      btrim(currency.name) = '人民币'
      OR upper(btrim(currency.code)) IN ('CNY', 'RMB')
  )
  AND ledger.exchange_rate > 0
  AND ROUND(ledger.amount_original * ledger.exchange_rate, 4)
        = ledger.amount_original_local;

ALTER TABLE ar_ap_ledger
    ALTER COLUMN amount_received_local SET DEFAULT 0,
    ALTER COLUMN amount_received_local SET NOT NULL,
    ALTER COLUMN amount_write_off_local SET DEFAULT 0,
    ALTER COLUMN amount_write_off_local SET NOT NULL,
    ADD CONSTRAINT ar_ap_ledger_original_breakdown_chk
        CHECK (
            (amount_received_original IS NULL
                AND amount_write_off_original IS NULL
                AND amount_balance_original IS NULL)
            OR
            (amount_received_original IS NOT NULL
                AND amount_write_off_original IS NOT NULL
                AND amount_balance_original IS NOT NULL
                AND amount_balance_original
                    = amount_original
                        - amount_received_original
                        - amount_write_off_original)
        );

COMMENT ON COLUMN ar_ap_ledger.amount_received_original IS
    '累计到账原币；V236 前且汇率质量未核验的行保持 NULL，不按历史汇率反推';
COMMENT ON COLUMN ar_ap_ledger.amount_received_local IS
    '累计到账本币；V236 以前按既有 amount_settled 保守回填';
COMMENT ON COLUMN ar_ap_ledger.amount_write_off_original IS
    '累计费用冲销原币；V236 前无可靠分摊事实的行保持 NULL';
COMMENT ON COLUMN ar_ap_ledger.amount_write_off_local IS
    '累计费用冲销本币；V236 前无显式分摊，保守回填为 0';
COMMENT ON COLUMN ar_ap_ledger.amount_balance_original IS
    '未收原币 = 原币应收 - 原币到账 - 原币冲销；历史汇率未核验时保持 NULL';

ALTER TABLE finance_receipt_lines
    ADD COLUMN currency_id UUID REFERENCES currencies(id),
    ADD COLUMN exchange_rate NUMERIC(18,6),
    ADD COLUMN write_off_amount NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN write_off_local NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN applied_amount_local NUMERIC(18,4),
    ADD COLUMN balance_before_original NUMERIC(18,4),
    ADD COLUMN balance_after_original NUMERIC(18,4),
    ADD CONSTRAINT finance_receipt_lines_exchange_rate_chk
        CHECK (exchange_rate IS NULL OR exchange_rate > 0),
    ADD CONSTRAINT finance_receipt_lines_balance_snapshot_pair_chk
        CHECK ((balance_before_original IS NULL) = (balance_after_original IS NULL));

-- The former model stored currency/rate only on the receipt header. Copy that
-- exact snapshot when valid; do not repair zero/dirty legacy rates or infer an
-- original-currency balance. amount_local itself is the only authoritative
-- pre-V236 applied-local fact.
UPDATE finance_receipt_lines line
SET currency_id = receipt.currency_id,
    exchange_rate = CASE
        WHEN receipt.exchange_rate > 0 THEN receipt.exchange_rate
        ELSE NULL
    END,
    applied_amount_local = line.amount_local
FROM finance_receipts receipt
WHERE receipt.id = line.receipt_id;

CREATE UNIQUE INDEX uq_finance_receipt_line_active_ledger
    ON finance_receipt_lines (receipt_id, applied_ledger_id)
    WHERE applied_ledger_id IS NOT NULL AND is_deleted = FALSE;
CREATE INDEX idx_finance_receipt_line_currency
    ON finance_receipt_lines (currency_id);

COMMENT ON COLUMN finance_receipt_lines.currency_id IS
    '本次到账币别快照；V236 以前从收款单头原样复制';
COMMENT ON COLUMN finance_receipt_lines.exchange_rate IS
    '本次到账汇率；无效或未核验历史汇率保持 NULL';
COMMENT ON COLUMN finance_receipt_lines.write_off_amount IS
    '本次费用冲销原币金额';
COMMENT ON COLUMN finance_receipt_lines.write_off_local IS
    '本次费用冲销本币金额';
COMMENT ON COLUMN finance_receipt_lines.applied_amount_local IS
    '本次冲减应收的开账本币账面金额，含到账与费用冲销并按立账汇率计量';
COMMENT ON COLUMN finance_receipt_lines.balance_before_original IS
    '审核前应收原币余额快照；历史分配无法可靠重建时为 NULL';
COMMENT ON COLUMN finance_receipt_lines.balance_after_original IS
    '审核后应收原币余额快照；历史分配无法可靠重建时为 NULL';

-- GL balancing leaves for receipt fees and FX differences. Reuse an existing
-- active EXPENSE style by name when finance already configured one. Otherwise
-- create a system seed below the active /043/ root when present, falling back
-- to an independent root-level leaf. Existing account rows are never renamed,
-- reparented or otherwise rewritten.
INSERT INTO payment_styles (
    code, name, category, parent_id, level, sort_order, path,
    is_departmental, is_receipt, is_payment, status, auto_created)
SELECT 'SYS-FIN-BANK-FEE',
       '手续费',
       'EXPENSE',
       parent.id,
       COALESCE(parent.level + 1, 0),
       930,
       COALESCE(parent.path, '/') || 'SYS-FIN-BANK-FEE/',
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
      AND COALESCE(existing.is_deleted, FALSE) = FALSE
);

INSERT INTO payment_styles (
    code, name, category, parent_id, level, sort_order, path,
    is_departmental, is_receipt, is_payment, status, auto_created)
SELECT 'SYS-FIN-FX-GL',
       '汇兑损益',
       'EXPENSE',
       parent.id,
       COALESCE(parent.level + 1, 0),
       931,
       COALESCE(parent.path, '/') || 'SYS-FIN-FX-GL/',
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
      AND COALESCE(existing.is_deleted, FALSE) = FALSE
);

CREATE TABLE ar_ap_source_refs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ledger_id       UUID NOT NULL REFERENCES ar_ap_ledger(id) ON DELETE CASCADE,
    source_type     TEXT NOT NULL,
    source_id       UUID NOT NULL,
    source_no       TEXT NOT NULL,
    amount_original NUMERIC(18,4) NOT NULL DEFAULT 0,
    amount_local    NUMERIC(18,4) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID,
    CONSTRAINT ar_ap_source_refs_type_chk
        CHECK (source_type = 'SALES_ORDER'),
    CONSTRAINT ar_ap_source_refs_source_no_chk
        CHECK (btrim(source_no) <> ''),
    CONSTRAINT uq_ar_ap_source_refs_source
        UNIQUE (ledger_id, source_type, source_id)
);

CREATE INDEX idx_ar_ap_source_refs_lookup
    ON ar_ap_source_refs (source_type, source_no);

COMMENT ON TABLE ar_ap_source_refs IS
    'AR/AP 立账的一对多不可变业务来源快照；当前 SALES_ORDER 来源只从明确 order_item_id 链生成';
COMMENT ON COLUMN ar_ap_source_refs.amount_original IS
    '该来源在本次立账中的原币金额快照，取销售发运行金额而非回查订单现值';
COMMENT ON COLUMN ar_ap_source_refs.amount_local IS
    '该来源在本次立账中的本币金额快照，取销售发运行金额而非回查订单现值';

-- Conservative backfill: only the persisted shipment -> order item -> order
-- UUID chain is accepted. There is intentionally no bill-number, customer or
-- date heuristic for legacy rows.
INSERT INTO ar_ap_source_refs (
    ledger_id, source_type, source_id, source_no,
    amount_original, amount_local, created_at, updated_at)
SELECT ledger.id,
       'SALES_ORDER',
       sales_order.id,
       sales_order.bill_no,
       COALESCE(SUM(shipment_item.amount_original), 0),
       COALESCE(SUM(shipment_item.amount_local), 0),
       now(),
       now()
FROM ar_ap_ledger ledger
JOIN sales_shipment_items shipment_item
  ON shipment_item.shipment_id = ledger.source_doc_id
 AND shipment_item.order_item_id IS NOT NULL
 AND COALESCE(shipment_item.is_deleted, FALSE) = FALSE
JOIN sales_order_items order_item
  ON order_item.id = shipment_item.order_item_id
 AND COALESCE(order_item.is_deleted, FALSE) = FALSE
JOIN sales_orders sales_order
  ON sales_order.id = order_item.order_id
 AND COALESCE(sales_order.is_deleted, FALSE) = FALSE
WHERE ledger.source_doc_type = 'SALES_SHIPMENT'
  AND ledger.source_doc_id IS NOT NULL
  AND COALESCE(ledger.is_deleted, FALSE) = FALSE
GROUP BY ledger.id, sales_order.id, sales_order.bill_no
ON CONFLICT (ledger_id, source_type, source_id) DO NOTHING;
