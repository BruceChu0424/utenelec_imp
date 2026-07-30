-- V133: real payroll and employee expense-claim domains.
--
-- Payroll is an immutable monthly snapshot. Variable amounts are exact inputs;
-- tax/social-insurance formulas are intentionally not guessed by application
-- code. Expense payment links one claim to exactly one approved finance expense.

INSERT INTO permissions(code, name, category, sort_order)
VALUES ('expense:pay', '报销打款', '员工报销', 221)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

INSERT INTO role_permissions(role_id, permission_id)
SELECT r.id, p.id
FROM roles r
JOIN permissions p ON p.code = 'expense:pay'
WHERE r.code IN ('finance', 'admin')
ON CONFLICT DO NOTHING;

-- V75 historically seeded an eight-hour access JWT. Preserve explicit
-- operator changes, but bring untouched installations back to the 15-minute
-- security baseline used by application.yml.
UPDATE system_settings
SET value = '15',
    updated_at = CURRENT_TIMESTAMP
WHERE key = 'jwt_access_ttl_minutes'
  AND value = '480';

CREATE TABLE payroll_batches (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payroll_year             SMALLINT NOT NULL,
    payroll_month            SMALLINT NOT NULL,
    department_id            UUID REFERENCES departments(id) ON DELETE RESTRICT,
    department_name_snapshot TEXT,
    status                   TEXT NOT NULL DEFAULT 'DRAFT',
    include_overtime         BOOLEAN NOT NULL DEFAULT TRUE,
    include_bonus            BOOLEAN NOT NULL DEFAULT TRUE,
    include_social_insurance BOOLEAN NOT NULL DEFAULT TRUE,
    include_tax              BOOLEAN NOT NULL DEFAULT TRUE,
    headcount                INTEGER NOT NULL DEFAULT 0,
    gross_income             NUMERIC(18,2) NOT NULL DEFAULT 0,
    total_deduction          NUMERIC(18,2) NOT NULL DEFAULT 0,
    net_income               NUMERIC(18,2) NOT NULL DEFAULT 0,
    generated_by             UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    submitted_by             UUID REFERENCES employees(id) ON DELETE RESTRICT,
    approved_by              UUID REFERENCES employees(id) ON DELETE RESTRICT,
    published_by             UUID REFERENCES employees(id) ON DELETE RESTRICT,
    submitted_at             TIMESTAMPTZ,
    approved_at              TIMESTAMPTZ,
    published_at             TIMESTAMPTZ,
    rejected_at              TIMESTAMPTZ,
    reject_reason            TEXT,
    version                  BIGINT NOT NULL DEFAULT 0,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by               UUID,
    updated_by               UUID,
    CONSTRAINT payroll_batches_period_chk
        CHECK (payroll_year BETWEEN 2000 AND 2200 AND payroll_month BETWEEN 1 AND 12),
    CONSTRAINT payroll_batches_status_chk
        CHECK (status IN ('DRAFT', 'SUBMITTED', 'APPROVED', 'REJECTED', 'PUBLISHED')),
    CONSTRAINT payroll_batches_totals_chk
        CHECK (
            headcount >= 0
            AND gross_income >= 0
            AND total_deduction >= 0
            AND net_income = gross_income - total_deduction
        ),
    CONSTRAINT payroll_batches_reject_reason_len_chk
        CHECK (reject_reason IS NULL OR char_length(reject_reason) <= 1000)
);

-- A rejected batch remains immutable audit history, while a corrected batch
-- may be generated for the same scope and period.
CREATE UNIQUE INDEX uq_payroll_batches_active_scope_period
    ON payroll_batches (
        payroll_year,
        payroll_month,
        COALESCE(department_id, '00000000-0000-0000-0000-000000000000'::UUID)
    )
    WHERE status <> 'REJECTED';

CREATE INDEX idx_payroll_batches_period_status
    ON payroll_batches (payroll_year DESC, payroll_month DESC, status);

CREATE TABLE payroll_slips (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id                 UUID NOT NULL
                             REFERENCES payroll_batches(id) ON DELETE RESTRICT,
    employee_id              UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    employee_code_snapshot   TEXT NOT NULL,
    employee_name_snapshot   TEXT NOT NULL,
    department_id_snapshot   UUID,
    department_name_snapshot TEXT,
    payroll_year             SMALLINT NOT NULL,
    payroll_month            SMALLINT NOT NULL,
    status                   TEXT NOT NULL DEFAULT 'PENDING',
    gross_income             NUMERIC(18,2) NOT NULL,
    total_deduction          NUMERIC(18,2) NOT NULL,
    net_income               NUMERIC(18,2) NOT NULL,
    active                   BOOLEAN NOT NULL DEFAULT TRUE,
    published_at             TIMESTAMPTZ,
    viewed_at                TIMESTAMPTZ,
    downloaded_at            TIMESTAMPTZ,
    remark                   TEXT,
    version                  BIGINT NOT NULL DEFAULT 0,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by               UUID,
    updated_by               UUID,
    CONSTRAINT payroll_slips_period_chk
        CHECK (payroll_year BETWEEN 2000 AND 2200 AND payroll_month BETWEEN 1 AND 12),
    CONSTRAINT payroll_slips_status_chk
        CHECK (status IN ('PENDING', 'PUBLISHED')),
    CONSTRAINT payroll_slips_totals_chk
        CHECK (
            gross_income >= 0
            AND total_deduction >= 0
            AND net_income = gross_income - total_deduction
        ),
    CONSTRAINT payroll_slips_remark_len_chk
        CHECK (remark IS NULL OR char_length(remark) <= 1000)
);

-- Prevent global and department batches from paying one employee twice in one
-- month. Rejecting a batch deactivates its slips before regeneration.
CREATE UNIQUE INDEX uq_payroll_slips_employee_active_period
    ON payroll_slips (employee_id, payroll_year, payroll_month)
    WHERE active = TRUE;
CREATE INDEX idx_payroll_slips_employee_period
    ON payroll_slips (employee_id, payroll_year DESC, payroll_month DESC)
    WHERE active = TRUE;
CREATE INDEX idx_payroll_slips_batch
    ON payroll_slips (batch_id);

CREATE TABLE payroll_items (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slip_id     UUID NOT NULL REFERENCES payroll_slips(id) ON DELETE RESTRICT,
    line_no     INTEGER NOT NULL,
    item_code   TEXT NOT NULL,
    name        TEXT NOT NULL,
    item_type   TEXT NOT NULL,
    amount      NUMERIC(18,2) NOT NULL,
    source_type TEXT NOT NULL,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  UUID,
    updated_by  UUID,
    CONSTRAINT payroll_items_line_uk UNIQUE (slip_id, line_no),
    CONSTRAINT payroll_items_code_uk UNIQUE (slip_id, item_code),
    CONSTRAINT payroll_items_line_chk CHECK (line_no > 0),
    CONSTRAINT payroll_items_type_chk CHECK (item_type IN ('EARNING', 'DEDUCTION')),
    CONSTRAINT payroll_items_amount_chk CHECK (amount >= 0),
    CONSTRAINT payroll_items_source_chk
        CHECK (source_type IN ('COMPENSATION_SNAPSHOT', 'VARIABLE_INPUT')),
    CONSTRAINT payroll_items_text_len_chk
        CHECK (
            char_length(item_code) BETWEEN 1 AND 50
            AND char_length(name) BETWEEN 1 AND 100
            AND (description IS NULL OR char_length(description) <= 500)
        )
);

CREATE INDEX idx_payroll_items_slip
    ON payroll_items (slip_id, line_no);

-- Exact period adjustments imported or entered by an authorized payroll
-- process. Bases in employee_compensation are not silently treated as payable
-- deductions because their rates depend on policy, location and effective date.
CREATE TABLE payroll_variable_inputs (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id              UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    payroll_year             SMALLINT NOT NULL,
    payroll_month            SMALLINT NOT NULL,
    overtime_amount          NUMERIC(18,2) NOT NULL DEFAULT 0,
    bonus_amount             NUMERIC(18,2) NOT NULL DEFAULT 0,
    social_insurance_amount  NUMERIC(18,2) NOT NULL DEFAULT 0,
    housing_fund_amount      NUMERIC(18,2) NOT NULL DEFAULT 0,
    tax_amount               NUMERIC(18,2) NOT NULL DEFAULT 0,
    other_earning_amount     NUMERIC(18,2) NOT NULL DEFAULT 0,
    other_deduction_amount   NUMERIC(18,2) NOT NULL DEFAULT 0,
    source_note              TEXT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by               UUID,
    updated_by               UUID,
    CONSTRAINT payroll_variable_inputs_employee_period_uk
        UNIQUE (employee_id, payroll_year, payroll_month),
    CONSTRAINT payroll_variable_inputs_period_chk
        CHECK (payroll_year BETWEEN 2000 AND 2200 AND payroll_month BETWEEN 1 AND 12),
    CONSTRAINT payroll_variable_inputs_amounts_chk
        CHECK (
            overtime_amount >= 0
            AND bonus_amount >= 0
            AND social_insurance_amount >= 0
            AND housing_fund_amount >= 0
            AND tax_amount >= 0
            AND other_earning_amount >= 0
            AND other_deduction_amount >= 0
        ),
    CONSTRAINT payroll_variable_inputs_note_len_chk
        CHECK (source_note IS NULL OR char_length(source_note) <= 1000)
);

CREATE INDEX idx_payroll_variable_inputs_period
    ON payroll_variable_inputs (payroll_year, payroll_month, employee_id);

CREATE TABLE expense_claims (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    applicant_id             UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    applicant_name_snapshot  TEXT NOT NULL,
    applicant_department_id  UUID REFERENCES departments(id) ON DELETE RESTRICT,
    title                    TEXT NOT NULL,
    total_amount             NUMERIC(18,2) NOT NULL,
    status                   TEXT NOT NULL DEFAULT 'DRAFT',
    remark                   TEXT,
    reject_reason            TEXT,
    submitted_by             UUID REFERENCES employees(id) ON DELETE RESTRICT,
    approved_by              UUID REFERENCES employees(id) ON DELETE RESTRICT,
    rejected_by              UUID REFERENCES employees(id) ON DELETE RESTRICT,
    paid_by                  UUID REFERENCES employees(id) ON DELETE RESTRICT,
    submitted_at             TIMESTAMPTZ,
    approved_at              TIMESTAMPTZ,
    rejected_at              TIMESTAMPTZ,
    paid_at                  TIMESTAMPTZ,
    payment_date             DATE,
    payment_account_id       UUID REFERENCES accounts(id) ON DELETE RESTRICT,
    payment_expense_style_id UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    finance_expense_id       UUID UNIQUE REFERENCES finance_expenses(id) ON DELETE RESTRICT,
    version                  BIGINT NOT NULL DEFAULT 0,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by               UUID,
    updated_by               UUID,
    CONSTRAINT expense_claims_status_chk
        CHECK (status IN ('DRAFT', 'SUBMITTED', 'REVIEWING', 'APPROVED', 'REJECTED', 'PAID')),
    CONSTRAINT expense_claims_amount_chk CHECK (total_amount > 0),
    CONSTRAINT expense_claims_text_chk
        CHECK (
            char_length(title) BETWEEN 1 AND 200
            AND (remark IS NULL OR char_length(remark) <= 2000)
            AND (reject_reason IS NULL OR char_length(reject_reason) <= 1000)
        ),
    CONSTRAINT expense_claims_payment_shape_chk
        CHECK (
            (
                status = 'PAID'
                AND paid_at IS NOT NULL
                AND payment_date IS NOT NULL
                AND payment_account_id IS NOT NULL
                AND payment_expense_style_id IS NOT NULL
                AND finance_expense_id IS NOT NULL
            )
            OR
            (
                status <> 'PAID'
                AND paid_at IS NULL
                AND payment_date IS NULL
                AND payment_account_id IS NULL
                AND payment_expense_style_id IS NULL
                AND finance_expense_id IS NULL
            )
        )
);

CREATE INDEX idx_expense_claims_applicant_created
    ON expense_claims (applicant_id, created_at DESC);
CREATE INDEX idx_expense_claims_status_created
    ON expense_claims (status, created_at)
    WHERE status IN ('SUBMITTED', 'REVIEWING', 'APPROVED');
CREATE INDEX idx_expense_claims_created_brin
    ON expense_claims USING BRIN (created_at);

CREATE TABLE expense_claim_items (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id    UUID NOT NULL REFERENCES expense_claims(id) ON DELETE RESTRICT,
    line_no     INTEGER NOT NULL,
    category    TEXT NOT NULL,
    amount      NUMERIC(18,2) NOT NULL,
    expense_date DATE NOT NULL,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  UUID,
    updated_by  UUID,
    CONSTRAINT expense_claim_items_line_uk UNIQUE (claim_id, line_no),
    CONSTRAINT expense_claim_items_line_chk CHECK (line_no > 0),
    CONSTRAINT expense_claim_items_category_chk
        CHECK (
            category IN (
                'TRANSPORT',
                'TRAVEL',
                'MEAL',
                'OFFICE',
                'COMMUNICATION',
                'ENTERTAINMENT',
                'TRAINING',
                'OTHER'
            )
        ),
    CONSTRAINT expense_claim_items_amount_chk CHECK (amount > 0),
    CONSTRAINT expense_claim_items_description_len_chk
        CHECK (description IS NULL OR char_length(description) <= 1000)
);

CREATE INDEX idx_expense_claim_items_claim
    ON expense_claim_items (claim_id, line_no);
CREATE INDEX idx_expense_claim_items_date_category
    ON expense_claim_items (expense_date, category);

CREATE OR REPLACE FUNCTION fn_audit_redacted() RETURNS TRIGGER AS $$
DECLARE
    v_actor UUID;
    v_before JSONB;
    v_after JSONB;
BEGIN
    v_actor := NULLIF(current_setting('app.actor_id', true), '')::UUID;
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        v_before := to_jsonb(OLD) - ARRAY[
            'gross_income', 'total_deduction', 'net_income', 'amount',
            'total_amount', 'description', 'remark', 'reject_reason',
            'source_note', 'employee_name_snapshot', 'applicant_name_snapshot'
        ];
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        v_after := to_jsonb(NEW) - ARRAY[
            'gross_income', 'total_deduction', 'net_income', 'amount',
            'total_amount', 'description', 'remark', 'reject_reason',
            'source_note', 'employee_name_snapshot', 'applicant_name_snapshot'
        ];
    END IF;
    INSERT INTO audit_log(actor_id, action, target_type, target_id, before, "after")
    VALUES (
        v_actor,
        lower(TG_OP),
        TG_TABLE_NAME,
        COALESCE(v_before ->> 'id', v_after ->> 'id'),
        v_before,
        v_after
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    table_name TEXT;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'payroll_batches',
        'payroll_slips',
        'payroll_items',
        'payroll_variable_inputs',
        'expense_claims',
        'expense_claim_items'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_audit_redacted_%1$I '
            'AFTER INSERT OR UPDATE OR DELETE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit_redacted()',
            table_name
        );
        EXECUTE format(
            'CREATE TRIGGER trg_updated_at_%1$I '
            'BEFORE UPDATE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at()',
            table_name
        );
    END LOOP;
END
$$;

COMMENT ON TABLE payroll_batches IS
    'Monthly payroll generation/review/publish workflow; rejected batches remain immutable history.';
COMMENT ON TABLE payroll_slips IS
    'Employee payroll snapshots. active=false only when the parent batch is rejected.';
COMMENT ON TABLE payroll_variable_inputs IS
    'Exact period amounts; application code never derives policy-dependent deductions from contribution bases.';
COMMENT ON TABLE expense_claims IS
    'Employee reimbursement workflow; PAID rows have exactly one approved finance_expenses link.';
COMMENT ON COLUMN expense_claims.finance_expense_id IS
    'Idempotency and accounting link created in the same transaction as claim payment.';
