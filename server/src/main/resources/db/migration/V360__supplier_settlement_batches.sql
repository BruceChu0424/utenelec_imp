-- V337: frozen supplier monthly statements. A statement is a reproducible
-- as-of snapshot, never a replacement for receipt/AP/payment source facts.

CREATE SEQUENCE supplier_settlement_batch_no_seq START WITH 1 INCREMENT BY 1;

CREATE TABLE supplier_settlement_batches (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_no                    TEXT NOT NULL UNIQUE DEFAULT (
        'YFJS' || to_char(CURRENT_DATE, 'YYMM')
        || lpad(nextval('supplier_settlement_batch_no_seq')::TEXT, 8, '0')),
    supplier_id                 UUID NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    currency_id                 UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    settlement_method_id        UUID REFERENCES settlement_methods(id) ON DELETE RESTRICT,
    period_start                DATE NOT NULL,
    period_end                  DATE NOT NULL,
    due_date                    DATE,
    status                      TEXT NOT NULL DEFAULT 'FROZEN' CHECK (status IN (
        'FROZEN', 'SUPPLIER_CONFIRMED', 'INTERNAL_CONFIRMED',
        'BOTH_CONFIRMED', 'DISPUTED', 'CLOSED', 'REVERSED')),
    opening_balance_original    NUMERIC(18,4) NOT NULL,
    period_posted_original      NUMERIC(18,4) NOT NULL,
    period_paid_original        NUMERIC(18,4) NOT NULL,
    period_offset_original      NUMERIC(18,4) NOT NULL,
    closing_balance_original    NUMERIC(18,4) NOT NULL,
    opening_balance_local       NUMERIC(18,4) NOT NULL,
    period_posted_local         NUMERIC(18,4) NOT NULL,
    period_paid_local           NUMERIC(18,4) NOT NULL,
    period_offset_local         NUMERIC(18,4) NOT NULL,
    closing_balance_local       NUMERIC(18,4) NOT NULL,
    snapshot_hash               TEXT NOT NULL CHECK (snapshot_hash ~ '^[0-9a-f]{64}$'),
    line_count                  INTEGER NOT NULL CHECK (line_count >= 0),
    supplier_confirmation_ref   TEXT,
    supplier_confirmed_by       UUID REFERENCES users(id) ON DELETE SET NULL,
    supplier_confirmed_at       TIMESTAMPTZ,
    internal_confirmed_by       UUID REFERENCES users(id) ON DELETE SET NULL,
    internal_confirmed_at       TIMESTAMPTZ,
    dispute_reason              TEXT,
    reversed_by                 UUID REFERENCES users(id) ON DELETE SET NULL,
    reversed_at                 TIMESTAMPTZ,
    reverse_reason              TEXT,
    row_version                 BIGINT NOT NULL DEFAULT 0 CHECK (row_version >= 0),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    is_deleted                  BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at                  TIMESTAMPTZ,
    CONSTRAINT supplier_settlement_batches_period_chk CHECK (
        period_start <= period_end
        AND period_start = date_trunc('month', period_start)::DATE
        AND period_end = (date_trunc('month', period_start) + INTERVAL '1 month - 1 day')::DATE),
    CONSTRAINT supplier_settlement_batches_original_identity_chk CHECK (
        closing_balance_original = opening_balance_original
            + period_posted_original - period_paid_original - period_offset_original),
    CONSTRAINT supplier_settlement_batches_local_identity_chk CHECK (
        closing_balance_local = opening_balance_local
            + period_posted_local - period_paid_local - period_offset_local),
    CONSTRAINT supplier_settlement_batches_supplier_confirm_chk CHECK (
        (supplier_confirmed_at IS NULL AND supplier_confirmed_by IS NULL)
        OR supplier_confirmed_at IS NOT NULL),
    CONSTRAINT supplier_settlement_batches_internal_confirm_chk CHECK (
        (internal_confirmed_at IS NULL AND internal_confirmed_by IS NULL)
        OR internal_confirmed_at IS NOT NULL),
    CONSTRAINT supplier_settlement_batches_reverse_chk CHECK (
        (status = 'REVERSED' AND reversed_at IS NOT NULL AND reverse_reason IS NOT NULL)
        OR status <> 'REVERSED')
);

CREATE TABLE supplier_settlement_batch_lines (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id                    UUID NOT NULL REFERENCES supplier_settlement_batches(id) ON DELETE RESTRICT,
    ledger_id                   UUID NOT NULL REFERENCES ar_ap_ledger(id) ON DELETE RESTRICT,
    business_type               TEXT NOT NULL,
    open_item_kind              TEXT NOT NULL,
    source_doc_type             TEXT NOT NULL,
    source_doc_id               UUID,
    source_doc_no               TEXT,
    bill_date                   DATE NOT NULL,
    due_date                    DATE,
    booking_rate                NUMERIC(18,6) NOT NULL CHECK (booking_rate > 0),
    opening_balance_original    NUMERIC(18,4) NOT NULL,
    period_posted_original      NUMERIC(18,4) NOT NULL,
    period_paid_original        NUMERIC(18,4) NOT NULL,
    period_offset_original      NUMERIC(18,4) NOT NULL,
    closing_balance_original    NUMERIC(18,4) NOT NULL,
    opening_balance_local       NUMERIC(18,4) NOT NULL,
    period_posted_local         NUMERIC(18,4) NOT NULL,
    period_paid_local           NUMERIC(18,4) NOT NULL,
    period_offset_local         NUMERIC(18,4) NOT NULL,
    closing_balance_local       NUMERIC(18,4) NOT NULL,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT supplier_settlement_batch_lines_uk UNIQUE (batch_id, ledger_id),
    CONSTRAINT supplier_settlement_batch_lines_original_identity_chk CHECK (
        closing_balance_original = opening_balance_original
            + period_posted_original - period_paid_original - period_offset_original),
    CONSTRAINT supplier_settlement_batch_lines_local_identity_chk CHECK (
        closing_balance_local = opening_balance_local
            + period_posted_local - period_paid_local - period_offset_local)
);

CREATE TABLE supplier_settlement_batch_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id        UUID NOT NULL REFERENCES supplier_settlement_batches(id) ON DELETE RESTRICT,
    event_type      TEXT NOT NULL,
    actor_user_id   UUID REFERENCES users(id) ON DELETE SET NULL,
    reason          TEXT,
    payload         JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX ux_supplier_settlement_active_period
    ON supplier_settlement_batches(supplier_id, currency_id, period_start)
    WHERE status <> 'REVERSED' AND is_deleted = FALSE;
CREATE INDEX idx_supplier_settlement_batches_workbench
    ON supplier_settlement_batches(period_start DESC, status, supplier_id)
    WHERE is_deleted = FALSE;
CREATE INDEX idx_supplier_settlement_batch_lines_batch
    ON supplier_settlement_batch_lines(batch_id, bill_date, ledger_id);
CREATE INDEX idx_supplier_settlement_batch_events_batch
    ON supplier_settlement_batch_events(batch_id, created_at, id);

CREATE OR REPLACE FUNCTION fn_guard_supplier_settlement_event_append_only()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = 'supplier_settlement_batch_events is append-only; append a correcting event',
        CONSTRAINT = 'supplier_settlement_batch_events_append_only_guard';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_supplier_settlement_batch_events_append_only
    BEFORE UPDATE OR DELETE ON supplier_settlement_batch_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_supplier_settlement_event_append_only();

COMMENT ON TABLE supplier_settlement_batches IS
    'Frozen monthly supplier statement; later payments, returns and adjustments belong to later facts and never rewrite this snapshot';

INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description)
VALUES
    ('supplier_settlement:view', '查看供应商月结对账', '财税管理', '供应商结算', 590,
        'VIEW', '查看冻结的供应商月结对账批次与逐笔快照'),
    ('supplier_settlement:create', '生成供应商月结对账', '财税管理', '供应商结算', 591,
        'CREATE', '按截止日生成不可变供应商月结快照'),
    ('supplier_settlement:confirm', '确认供应商月结对账', '财税管理', '供应商结算', 592,
        'APPROVE', '登记供应商确认并执行公司内部确认'),
    ('supplier_settlement:dispute', '登记供应商月结争议', '财税管理', '供应商结算', 593,
        'EXECUTE', '登记对账争议且不改写来源应付'),
    ('supplier_settlement:reverse', '反转供应商月结批次', '财税管理', '供应商结算', 594,
        'EXECUTE', '反转错误快照并保留事件证据')
ON CONFLICT (code) DO NOTHING;

INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission ON permission.code IN (
    'supplier_settlement:view', 'supplier_settlement:create',
    'supplier_settlement:confirm', 'supplier_settlement:dispute',
    'supplier_settlement:reverse')
WHERE surface.surface_key='finance.ar-ap'
ON CONFLICT (surface_id,permission_id) DO NOTHING;

INSERT INTO department_permissions(department_id,permission_id)
SELECT department.id,permission.id
FROM departments department
JOIN permissions permission ON permission.code IN (
    'supplier_settlement:view', 'supplier_settlement:create',
    'supplier_settlement:confirm', 'supplier_settlement:dispute',
    'supplier_settlement:reverse')
WHERE department.code='DEPT_FIN' AND COALESCE(department.is_deleted,FALSE)=FALSE
ON CONFLICT DO NOTHING;
