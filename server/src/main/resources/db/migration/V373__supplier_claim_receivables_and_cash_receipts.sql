-- V373: supplier compensation is an asset until legally offset or collected.
-- It is not a negative AP and never silently changes inventory value.

INSERT INTO payment_styles(
    id,code,name,category,level,sort_order,path,is_receipt,is_payment,status,auto_created)
VALUES
    ('37300000-0000-4000-8100-000000000001','SYS-CLAIM-AR','供应商索赔应收',
        'ACCOUNT',0,910,'/SYS-CLAIM-AR/',FALSE,FALSE,'使用',TRUE),
    ('37300000-0000-4000-8100-000000000002','SYS-CLAIM-RECOVERY','委外异常损失追回',
        'INCOME',0,920,'/SYS-CLAIM-RECOVERY/',FALSE,FALSE,'使用',TRUE)
ON CONFLICT(id) DO NOTHING;

INSERT INTO system_posting_style_roles(role_key,style_id,required_category,description)
VALUES
    ('SUPPLIER_CLAIM_RECEIVABLE','37300000-0000-4000-8100-000000000001','ACCOUNT',
        '供应商赔偿、索赔和现金追回的其它应收控制科目'),
    ('SUBCONTRACT_LOSS_RECOVERY','37300000-0000-4000-8100-000000000002','INCOME',
        '已确认委外异常损失赔偿的追回科目')
ON CONFLICT(role_key) DO NOTHING;

CREATE TABLE supplier_claim_receivables(
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resolution_id       UUID NOT NULL REFERENCES subcontract_loss_resolutions(id) ON DELETE RESTRICT,
    case_id             UUID NOT NULL REFERENCES subcontract_loss_cases(id) ON DELETE RESTRICT,
    supplier_id         UUID NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    currency_id         UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    bill_no             TEXT NOT NULL UNIQUE,
    claim_date          DATE NOT NULL,
    due_date            DATE,
    amount_original     NUMERIC(18,4) NOT NULL CHECK(amount_original>0),
    exchange_rate       NUMERIC(18,6) NOT NULL CHECK(exchange_rate>0),
    amount_local        NUMERIC(18,4) NOT NULL CHECK(amount_local>0),
    settled_original    NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(settled_original>=0),
    settled_local       NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(settled_local>=0),
    balance_original    NUMERIC(18,4) NOT NULL CHECK(balance_original>=0),
    balance_local       NUMERIC(18,4) NOT NULL CHECK(balance_local>=0),
    status              TEXT NOT NULL DEFAULT 'OPEN'
        CHECK(status IN('OPEN','PARTIAL','SETTLED','REVERSED')),
    settled_date        DATE,
    row_version         BIGINT NOT NULL DEFAULT 0 CHECK(row_version>=0),
    reversed_by         UUID REFERENCES users(id) ON DELETE SET NULL,
    reversed_at         TIMESTAMPTZ,
    reverse_reason      TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by          UUID REFERENCES users(id) ON DELETE SET NULL,
    is_deleted          BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at          TIMESTAMPTZ,
    CONSTRAINT supplier_claim_receivables_resolution_uk UNIQUE(resolution_id),
    CONSTRAINT supplier_claim_receivables_amount_identity_chk CHECK(
        amount_local=ROUND(amount_original*exchange_rate,4)
        AND balance_original=amount_original-settled_original
        AND balance_local=amount_local-settled_local),
    CONSTRAINT supplier_claim_receivables_status_shape_chk CHECK(
        (status='OPEN' AND settled_original=0 AND balance_original>0)
        OR (status='PARTIAL' AND settled_original>0 AND balance_original>0)
        OR (status='SETTLED' AND balance_original=0 AND balance_local=0 AND settled_date IS NOT NULL)
        OR (status='REVERSED' AND reversed_at IS NOT NULL AND reverse_reason IS NOT NULL))
);

ALTER TABLE subcontract_loss_resolutions
    ADD COLUMN claim_receivable_id UUID REFERENCES supplier_claim_receivables(id) ON DELETE RESTRICT;

CREATE TABLE supplier_claim_cash_receipts(
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_receivable_id     UUID NOT NULL REFERENCES supplier_claim_receivables(id) ON DELETE RESTRICT,
    resolution_id           UUID NOT NULL REFERENCES subcontract_loss_resolutions(id) ON DELETE RESTRICT,
    case_id                 UUID NOT NULL REFERENCES subcontract_loss_cases(id) ON DELETE RESTRICT,
    supplier_id             UUID NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    account_id              UUID NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
    currency_id             UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    bill_no                 TEXT NOT NULL UNIQUE,
    receipt_date            DATE NOT NULL,
    amount_original         NUMERIC(18,4) NOT NULL CHECK(amount_original>0),
    exchange_rate           NUMERIC(18,6) NOT NULL CHECK(exchange_rate>0),
    amount_local            NUMERIC(18,4) NOT NULL CHECK(amount_local>0),
    book_applied_local      NUMERIC(18,4) NOT NULL CHECK(book_applied_local>0),
    exchange_difference     NUMERIC(18,4) NOT NULL,
    reconciliation_id       UUID NOT NULL REFERENCES finance_reconciliations(id) ON DELETE RESTRICT,
    status                  TEXT NOT NULL DEFAULT 'APPROVED' CHECK(status IN('APPROVED','REVERSED')),
    row_version             BIGINT NOT NULL DEFAULT 0 CHECK(row_version>=0),
    reversed_by             UUID REFERENCES users(id) ON DELETE SET NULL,
    reversed_at             TIMESTAMPTZ,
    reverse_reason          TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by              UUID REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT supplier_claim_cash_receipts_resolution_uk UNIQUE(resolution_id),
    CONSTRAINT supplier_claim_cash_receipts_amount_chk CHECK(
        amount_local=ROUND(amount_original*exchange_rate,4)
        AND exchange_difference=amount_local-book_applied_local),
    CONSTRAINT supplier_claim_cash_receipts_reverse_shape_chk CHECK(
        (status='APPROVED' AND reversed_at IS NULL AND reversed_by IS NULL)
        OR (status='REVERSED' AND reversed_at IS NOT NULL AND reverse_reason IS NOT NULL))
);

CREATE INDEX idx_supplier_claim_receivables_open
    ON supplier_claim_receivables(supplier_id,due_date,claim_date)
    WHERE status IN('OPEN','PARTIAL') AND is_deleted=FALSE;
CREATE INDEX idx_supplier_claim_cash_receipts_period
    ON supplier_claim_cash_receipts(receipt_date,supplier_id)
    WHERE status='APPROVED';

COMMENT ON TABLE supplier_claim_receivables IS
    'Supplier compensation asset; separate from AP unless a documented offset allocation clears it';
COMMENT ON TABLE supplier_claim_cash_receipts IS
    'Bank-backed settlement of supplier claim receivable; evidence text alone cannot create this fact';
