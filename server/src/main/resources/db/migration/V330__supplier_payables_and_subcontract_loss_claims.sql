-- V330: procurement/subcontract payables, structured terms and excess-loss claims.
--
-- The four facts remain separate:
--   * purchase/subcontract receipts create payable open items;
--   * company-owned material at a subcontractor is inventory, never AP;
--   * payments settle positive AP rows;
--   * an excess-loss claim affects AP only after a recorded finance decision.

-- ======================== payment-term authority ========================

ALTER TABLE settlement_methods
    ADD COLUMN terms_base TEXT NOT NULL DEFAULT 'RECEIPT_DATE',
    ADD COLUMN due_rule TEXT NOT NULL DEFAULT 'NET_DAYS',
    ADD COLUMN default_due_days INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN fixed_day_of_month INTEGER,
    ADD COLUMN months_ahead INTEGER NOT NULL DEFAULT 0;

ALTER TABLE settlement_methods
    ADD CONSTRAINT settlement_methods_terms_base_chk CHECK (terms_base IN (
        'RECEIPT_DATE', 'QC_ACCEPTANCE_DATE', 'STATEMENT_END',
        'STATEMENT_CONFIRM_DATE', 'INVOICE_DATE')),
    ADD CONSTRAINT settlement_methods_due_rule_chk CHECK (due_rule IN (
        'NET_DAYS', 'EOM_PLUS_DAYS', 'FIXED_DAY_OF_MONTH')),
    ADD CONSTRAINT settlement_methods_due_days_chk CHECK (
        default_due_days BETWEEN 0 AND 3650),
    ADD CONSTRAINT settlement_methods_fixed_day_chk CHECK (
        fixed_day_of_month IS NULL OR fixed_day_of_month BETWEEN 1 AND 31),
    ADD CONSTRAINT settlement_methods_months_ahead_chk CHECK (
        months_ahead BETWEEN 0 AND 120),
    ADD CONSTRAINT settlement_methods_due_shape_chk CHECK (
        (due_rule = 'FIXED_DAY_OF_MONTH' AND fixed_day_of_month IS NOT NULL)
        OR (due_rule <> 'FIXED_DAY_OF_MONTH' AND fixed_day_of_month IS NULL));

-- Stable roles are assigned once from the deterministic V273 UUIDs. Runtime
-- never rediscovers these meanings from mutable names or legacy numbers.
UPDATE settlement_methods
SET terms_base = 'RECEIPT_DATE', due_rule = 'NET_DAYS',
    default_due_days = 0, fixed_day_of_month = NULL, months_ahead = 0
WHERE id = '27300000-0000-4000-8100-000000000001'::UUID
  AND system_role = 'CASH';

SELECT set_config('uten.system_settlement_role_maintenance','on',TRUE);

UPDATE settlement_methods
SET system_role = 'MONTHLY', terms_base = 'STATEMENT_END',
    due_rule = 'NET_DAYS', default_due_days = 30,
    fixed_day_of_month = NULL, months_ahead = 0
WHERE id = '27300000-0000-4000-8100-000000000006'::UUID
  AND legacy_id = 6
  AND system_role IS NULL;
SELECT set_config('uten.system_settlement_role_maintenance','off',TRUE);


DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM settlement_methods
        WHERE id = '27300000-0000-4000-8100-000000000006'::UUID
          AND system_role = 'MONTHLY'
          AND terms_base = 'STATEMENT_END'
          AND due_rule = 'NET_DAYS'
          AND status = '使用'
          AND COALESCE(is_deleted, FALSE) = FALSE
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'V330 cannot establish the active MONTHLY settlement role';
    END IF;
END
$$;

COMMENT ON COLUMN settlement_methods.terms_base IS
    'Payment-term base event; receipt posting can calculate only RECEIPT_DATE and STATEMENT_END';
COMMENT ON COLUMN settlement_methods.due_rule IS
    'NET_DAYS, EOM_PLUS_DAYS or FIXED_DAY_OF_MONTH; persisted UUID terms are the authority';

-- ======================== payable open-item metadata ========================

ALTER TABLE ar_ap_ledger
    ADD COLUMN business_type TEXT,
    ADD COLUMN open_item_kind TEXT,
    ADD COLUMN amount_offset_original NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN amount_offset_local NUMERIC(18,4) NOT NULL DEFAULT 0;

UPDATE ar_ap_ledger
SET business_type = CASE
        WHEN direction = 'AR' THEN 'SALES'
        WHEN source_doc_type IN ('PURCHASE_RECEIPT', 'PURCHASE_RETURN') THEN 'PURCHASE'
        WHEN source_doc_type IN ('SUBCONTRACT_RECEIPT', 'SUBCONTRACT_RETURN', 'SUBCONTRACT_WASTE')
            THEN 'SUBCONTRACT'
        ELSE 'DIRECT'
    END,
    open_item_kind = CASE
        WHEN direction = 'AR' THEN 'RECEIVABLE'
        WHEN source_doc_type = 'DIRECT_PAYMENT' THEN 'PREPAYMENT'
        WHEN source_doc_type = 'SUBCONTRACT_WASTE' THEN 'CLAIM_CREDIT'
        WHEN amount_original_local < 0 THEN 'CREDIT'
        ELSE 'PAYABLE'
    END;

ALTER TABLE ar_ap_ledger
    ALTER COLUMN business_type SET NOT NULL,
    ALTER COLUMN open_item_kind SET NOT NULL,
    ADD CONSTRAINT ar_ap_ledger_business_type_chk CHECK (
        business_type IN ('SALES', 'PURCHASE', 'SUBCONTRACT', 'DIRECT')),
    ADD CONSTRAINT ar_ap_ledger_open_item_kind_chk CHECK (
        open_item_kind IN (
            'RECEIVABLE', 'PAYABLE', 'CREDIT', 'CLAIM_CREDIT', 'PREPAYMENT')),
    ADD CONSTRAINT ar_ap_ledger_open_item_direction_chk CHECK (
        (direction = 'AR' AND open_item_kind = 'RECEIVABLE')
        OR (direction = 'AP' AND open_item_kind <> 'RECEIVABLE')),
    ADD CONSTRAINT ar_ap_ledger_offset_sign_chk CHECK (
        (open_item_kind IN ('PAYABLE', 'RECEIVABLE')
            AND amount_offset_original >= 0 AND amount_offset_local >= 0)
        OR (open_item_kind IN ('CREDIT', 'CLAIM_CREDIT', 'PREPAYMENT')
            AND amount_offset_original <= 0 AND amount_offset_local <= 0));

ALTER TABLE ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_original_breakdown_chk;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_original_breakdown_chk CHECK (
    (amount_received_original IS NULL
        AND amount_write_off_original IS NULL
        AND amount_balance_original IS NULL)
    OR
    (amount_received_original IS NOT NULL
        AND amount_write_off_original IS NOT NULL
        AND amount_balance_original IS NOT NULL
        AND amount_balance_original = amount_original
            - amount_received_original
            - amount_write_off_original
            - amount_offset_original));

ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_local_balance_chk
    CHECK (amount_balance = amount_original_local
        - amount_settled - amount_offset_local) NOT VALID;
ALTER TABLE ar_ap_ledger VALIDATE CONSTRAINT ar_ap_ledger_local_balance_chk;

ALTER TABLE ar_ap_ledger DROP CONSTRAINT IF EXISTS ar_ap_ledger_source_doc_type_chk;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_source_doc_type_chk
    CHECK (source_doc_type = ANY (ARRAY[
        'SALES_SHIPMENT', 'SALES_RETURN', 'PURCHASE_RECEIPT', 'PURCHASE_RETURN',
        'SUBCONTRACT_RECEIPT', 'SUBCONTRACT_RETURN', 'SUBCONTRACT_WASTE',
        'SUBCONTRACT_LOSS_OFFSET', 'DIRECT_RECEIPT', 'DIRECT_PAYMENT']));

CREATE INDEX idx_ar_ap_payables_workbench
    ON ar_ap_ledger (business_type, is_settled, due_date, bill_date DESC, supplier_id)
    WHERE direction = 'AP' AND status = 1 AND is_deleted = FALSE;
CREATE INDEX idx_ar_ap_supplier_open_item
    ON ar_ap_ledger (supplier_id, currency_id, open_item_kind, bill_date, id)
    WHERE direction = 'AP' AND status = 1 AND is_deleted = FALSE;

COMMENT ON COLUMN ar_ap_ledger.open_item_kind IS
    'PAYABLE debt, CREDIT supplier credit, CLAIM_CREDIT accepted claim, PREPAYMENT supplier advance; do not net silently';
COMMENT ON COLUMN ar_ap_ledger.amount_offset_local IS
    'Approved non-cash offset in book currency; payment cash remains amount_received/amount_settled';

-- Payment rows keep the exact server-side cash/book split and before/after
-- snapshots. Historical rows remain explicitly unverified where reconstruction
-- is impossible.
ALTER TABLE finance_payment_lines
    ADD COLUMN cash_rate NUMERIC(18,6),
    ADD COLUMN recognition_rate NUMERIC(18,6),
    ADD COLUMN applied_amount_local NUMERIC(18,4),
    ADD COLUMN balance_before_original NUMERIC(18,4),
    ADD COLUMN balance_after_original NUMERIC(18,4),
    ADD CONSTRAINT finance_payment_lines_cash_rate_chk CHECK (
        cash_rate IS NULL OR cash_rate > 0),
    ADD CONSTRAINT finance_payment_lines_recognition_rate_chk CHECK (
        recognition_rate IS NULL OR recognition_rate > 0),
    ADD CONSTRAINT finance_payment_lines_balance_snapshot_pair_chk CHECK (
        (balance_before_original IS NULL) = (balance_after_original IS NULL));

UPDATE finance_payment_lines line
SET cash_rate = payment.exchange_rate,
    recognition_rate = (
        SELECT ledger.exchange_rate
        FROM ar_ap_ledger ledger
        WHERE ledger.id = line.applied_ledger_id),
    applied_amount_local = line.amount_local - COALESCE(line.exchange_diff, 0)
FROM finance_payments payment
WHERE payment.id = line.payment_id;

-- ======================== subcontract excess-loss claim ========================

CREATE TABLE subcontract_loss_cases (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    waste_id                UUID NOT NULL REFERENCES subcontract_wastes(id) ON DELETE RESTRICT,
    waste_bill_no           TEXT NOT NULL,
    supplier_id             UUID NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    status                  TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN (
        'OPEN', 'ACCEPTED', 'DISPUTED', 'AWAITING_FULFILLMENT',
        'RESOLVED', 'WAIVED', 'CANCELED', 'REVERSED')),
    actual_loss_qty         NUMERIC(18,4) NOT NULL CHECK (actual_loss_qty >= 0),
    allowed_loss_qty        NUMERIC(18,4) NOT NULL CHECK (allowed_loss_qty >= 0),
    excess_loss_qty         NUMERIC(18,4) NOT NULL CHECK (excess_loss_qty >= 0),
    loss_book_value_local   NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (loss_book_value_local >= 0),
    claim_amount_local      NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (claim_amount_local >= 0),
    currency_id             UUID REFERENCES currencies(id) ON DELETE RESTRICT,
    decision_reason         TEXT,
    dispute_reason          TEXT,
    row_version             BIGINT NOT NULL DEFAULT 0 CHECK (row_version >= 0),
    decided_by              UUID REFERENCES users(id) ON DELETE SET NULL,
    decided_at              TIMESTAMPTZ,
    resolved_by             UUID REFERENCES users(id) ON DELETE SET NULL,
    resolved_at             TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by              UUID REFERENCES users(id) ON DELETE SET NULL,
    is_deleted              BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at              TIMESTAMPTZ,
    CONSTRAINT subcontract_loss_cases_waste_uk UNIQUE (waste_id),
    CONSTRAINT subcontract_loss_cases_qty_identity_chk CHECK (
        actual_loss_qty = allowed_loss_qty + excess_loss_qty),
    CONSTRAINT subcontract_loss_cases_decision_shape_chk CHECK (
        (status = 'OPEN' AND decided_at IS NULL)
        OR status <> 'OPEN')
);

CREATE TABLE subcontract_loss_case_lines (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id                 UUID NOT NULL REFERENCES subcontract_loss_cases(id) ON DELETE RESTRICT,
    waste_item_id           UUID NOT NULL REFERENCES subcontract_waste_items(id) ON DELETE RESTRICT,
    material_issue_item_id  UUID REFERENCES subcontract_material_issue_items(id) ON DELETE RESTRICT,
    order_item_id           UUID REFERENCES subcontract_order_items(id) ON DELETE RESTRICT,
    goods_id                UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    color_id                UUID REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id                 UUID REFERENCES units(id) ON DELETE RESTRICT,
    actual_loss_qty         NUMERIC(18,4) NOT NULL CHECK (actual_loss_qty > 0),
    allowed_loss_qty        NUMERIC(18,4) NOT NULL CHECK (allowed_loss_qty >= 0),
    excess_loss_qty         NUMERIC(18,4) NOT NULL CHECK (excess_loss_qty >= 0),
    unit_book_value_local   NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (unit_book_value_local >= 0),
    loss_book_value_local   NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (loss_book_value_local >= 0),
    valuation_status        TEXT NOT NULL CHECK (valuation_status IN ('VALUED', 'MISSING_COST')),
    goods_code_snapshot     TEXT,
    goods_name_snapshot     TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by              UUID REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT subcontract_loss_case_lines_item_uk UNIQUE (waste_item_id),
    CONSTRAINT subcontract_loss_case_lines_qty_identity_chk CHECK (
        actual_loss_qty = allowed_loss_qty + excess_loss_qty)
);

CREATE TABLE subcontract_loss_resolutions (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id                 UUID NOT NULL REFERENCES subcontract_loss_cases(id) ON DELETE RESTRICT,
    case_line_id            UUID REFERENCES subcontract_loss_case_lines(id) ON DELETE RESTRICT,
    resolution_type         TEXT NOT NULL CHECK (resolution_type IN (
        'COMPANY_BEAR', 'SERVICE_PRICE_REDUCTION', 'CASH_COMPENSATION',
        'AP_OFFSET', 'MATERIAL_REPLACEMENT', 'OUTPUT_REPLACEMENT',
        'SCRAP_RETURN', 'WAIVER')),
    quantity                NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    amount_local            NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (amount_local >= 0),
    due_date                DATE,
    status                  TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN (
        'PENDING', 'FULFILLED', 'REVERSED')),
    note                    TEXT,
    evidence_reference      TEXT,
    fulfillment_doc_type    TEXT,
    fulfillment_doc_id      UUID,
    fulfillment_doc_no      TEXT,
    offset_ledger_id        UUID REFERENCES ar_ap_ledger(id) ON DELETE RESTRICT,
    fulfilled_by            UUID REFERENCES users(id) ON DELETE SET NULL,
    fulfilled_at            TIMESTAMPTZ,
    reversed_by             UUID REFERENCES users(id) ON DELETE SET NULL,
    reversed_at             TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by              UUID REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT subcontract_loss_resolution_money_chk CHECK (
        (resolution_type IN ('SERVICE_PRICE_REDUCTION', 'CASH_COMPENSATION', 'AP_OFFSET')
            AND amount_local > 0)
        OR resolution_type NOT IN ('SERVICE_PRICE_REDUCTION', 'CASH_COMPENSATION', 'AP_OFFSET')),
    CONSTRAINT subcontract_loss_resolution_fulfilled_chk CHECK (
        (status = 'FULFILLED' AND fulfilled_at IS NOT NULL)
        OR (status <> 'FULFILLED'))
);

CREATE TABLE subcontract_loss_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id         UUID NOT NULL REFERENCES subcontract_loss_cases(id) ON DELETE RESTRICT,
    event_type      TEXT NOT NULL,
    actor_user_id   UUID REFERENCES users(id) ON DELETE SET NULL,
    reason          TEXT,
    payload         JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_subcontract_loss_cases_workbench
    ON subcontract_loss_cases(status, created_at DESC, supplier_id)
    WHERE is_deleted = FALSE;
CREATE INDEX idx_subcontract_loss_case_lines_case
    ON subcontract_loss_case_lines(case_id, id);
CREATE INDEX idx_subcontract_loss_resolutions_case
    ON subcontract_loss_resolutions(case_id, status, id);
CREATE INDEX idx_subcontract_loss_events_case
    ON subcontract_loss_events(case_id, created_at, id);

CREATE OR REPLACE FUNCTION fn_guard_subcontract_loss_event_append_only()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = 'subcontract_loss_events is append-only; append a correcting event',
        CONSTRAINT = 'subcontract_loss_events_append_only_guard';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_subcontract_loss_events_append_only
    BEFORE UPDATE OR DELETE ON subcontract_loss_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_loss_event_append_only();

-- Old V304 deductions remain readable/reversible. New finance decisions post a
-- separate source row per accepted resolution and never overwrite waste cost.
COMMENT ON TABLE subcontract_loss_cases IS
    'Finance responsibility case opened from an approved subcontract waste fact; physical loss is immutable and separate';
COMMENT ON TABLE subcontract_loss_resolutions IS
    'Mixed claim outcomes; only accepted AP_OFFSET/SERVICE_PRICE_REDUCTION rows create negative AP';

-- ======================== explicit permissions/catalog ========================

INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description)
VALUES
    ('subcontract_loss_claim:view', '查看委外超耗责任单', '财税管理', '委外超耗', 580,
        'VIEW', '查看委外超耗、责任、索赔与履约明细'),
    ('subcontract_loss_claim:review', '决定委外超耗责任', '财税管理', '委外超耗', 581,
        'APPROVE', '确认公司承担、争议、索赔、折让或应付抵销方案'),
    ('subcontract_loss_claim:fulfill', '登记委外超耗补偿履约', '财税管理', '委外超耗', 582,
        'EXECUTE', '登记现金、补料、补货、重作或废料返还的履约证据'),
    ('subcontract_loss_claim:reverse', '反转委外超耗责任决定', '财税管理', '委外超耗', 583,
        'EXECUTE', '在没有不可逆下游时反转责任决定并追加纠错事件')
ON CONFLICT (code) DO NOTHING;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission ON permission.code IN (
    'subcontract_loss_claim:view', 'subcontract_loss_claim:review',
    'subcontract_loss_claim:fulfill', 'subcontract_loss_claim:reverse')
WHERE surface.surface_key = 'finance.ar-ap'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission ON permission.code IN (
    'subcontract_loss_claim:view', 'subcontract_loss_claim:review',
    'subcontract_loss_claim:fulfill', 'subcontract_loss_claim:reverse')
WHERE department.code = 'DEPT_FIN'
  AND COALESCE(department.is_deleted, FALSE) = FALSE
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission ON permission.code IN (
    'subcontract_loss_claim:view', 'subcontract_loss_claim:fulfill')
WHERE department.code = 'SUB_WH'
  AND COALESCE(department.is_deleted, FALSE) = FALSE
ON CONFLICT DO NOTHING;
