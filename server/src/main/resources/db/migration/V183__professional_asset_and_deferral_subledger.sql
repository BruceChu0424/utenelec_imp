-- V183: professional fixed-asset and deferred-expense subledger.
--
-- Design invariants:
--   * V123 legacy display columns remain intact; lifecycle_status is the sole
--     workflow state used by new code.
--   * No capitalization threshold, tax incentive, useful life, residual rate,
--     account mapping, or category seed is hard-coded here.
--   * Approved account/document policy is snapshotted on the business object.
--   * Corporate and tax books, approved deferral schedules, posting previews,
--     posted runs, reversals, and period close history remain independently
--     traceable.

CREATE OR REPLACE FUNCTION fn_finance_period_is_valid(p_period TEXT)
RETURNS BOOLEAN
LANGUAGE SQL
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT p_period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$';
$$;

CREATE TABLE finance_asset_categories (
    id                         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    object_type                VARCHAR(32) NOT NULL,
    code                       VARCHAR(64) NOT NULL,
    name                       VARCHAR(160) NOT NULL,
    cost_style_id              UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    accumulated_style_id       UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    expense_style_id           UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    clearing_style_id          UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    default_method             VARCHAR(40),
    default_months             INTEGER,
    default_salvage_rate       NUMERIC(9,6),
    required_document_codes    JSONB NOT NULL DEFAULT '[]'::jsonb,
    effective_from             DATE NOT NULL,
    status                     VARCHAR(16) NOT NULL DEFAULT 'DRAFT',
    version                    INTEGER NOT NULL DEFAULT 1,
    remark                     TEXT,
    row_version                BIGINT NOT NULL DEFAULT 0,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                 UUID,
    updated_by                 UUID,
    is_deleted                 BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at                 TIMESTAMPTZ,
    deleted_by                 UUID,
    CONSTRAINT finance_asset_categories_object_type_chk
        CHECK (object_type IN ('FIXED_ASSET', 'DEFERRED_EXPENSE')),
    CONSTRAINT finance_asset_categories_method_chk
        CHECK (default_method IS NULL OR default_method IN (
            'STRAIGHT_LINE', 'UNITS_OF_PRODUCTION',
            'DOUBLE_DECLINING_BALANCE', 'SUM_OF_YEARS_DIGITS',
            'MANUAL_SCHEDULE'
        )),
    CONSTRAINT finance_asset_categories_months_chk
        CHECK (default_months IS NULL OR default_months BETWEEN 1 AND 1200),
    CONSTRAINT finance_asset_categories_salvage_chk
        CHECK (default_salvage_rate IS NULL
            OR default_salvage_rate BETWEEN 0 AND 1),
    CONSTRAINT finance_asset_categories_documents_chk
        CHECK (jsonb_typeof(required_document_codes) = 'array'),
    CONSTRAINT finance_asset_categories_status_chk
        CHECK (status IN ('DRAFT', 'ACTIVE', 'INACTIVE')),
    CONSTRAINT finance_asset_categories_version_chk
        CHECK (version >= 1),
    CONSTRAINT finance_asset_categories_row_version_chk
        CHECK (row_version >= 0),
    CONSTRAINT finance_asset_categories_text_chk
        CHECK (btrim(code) <> '' AND btrim(name) <> ''),
    CONSTRAINT finance_asset_categories_business_key_uk
        UNIQUE (object_type, code, version),
    CONSTRAINT finance_asset_categories_soft_delete_chk
        CHECK ((is_deleted = FALSE AND deleted_at IS NULL AND deleted_by IS NULL)
            OR (is_deleted = TRUE AND deleted_at IS NOT NULL))
);

CREATE UNIQUE INDEX ux_finance_asset_categories_single_active_code
    ON finance_asset_categories(object_type, code)
    WHERE status = 'ACTIVE' AND is_deleted = FALSE;
CREATE INDEX idx_finance_asset_categories_active
    ON finance_asset_categories(object_type, status, effective_from)
    WHERE is_deleted = FALSE;

ALTER TABLE finance_asset_categories
    ADD CONSTRAINT finance_asset_categories_active_policy_chk
        CHECK (status <> 'ACTIVE'
            OR (cost_style_id IS NOT NULL
                AND expense_style_id IS NOT NULL
                AND clearing_style_id IS NOT NULL
                AND (object_type = 'DEFERRED_EXPENSE'
                    OR accumulated_style_id IS NOT NULL)));

COMMENT ON TABLE finance_asset_categories IS
    'Versioned fixed-asset/deferred category policy. Accounts and policy defaults are user configuration; this migration deliberately seeds none.';
COMMENT ON COLUMN finance_asset_categories.clearing_style_id IS
    'Configured credit-side source/clearing account used when capitalizing an asset or recognizing a deferral.';
COMMENT ON COLUMN finance_asset_categories.required_document_codes IS
    'Configurable evidence checklist. Application approval must verify it and snapshot the effective list.';

ALTER TABLE fixed_assets
    ADD COLUMN category_id UUID REFERENCES finance_asset_categories(id) ON DELETE RESTRICT,
    ADD COLUMN lifecycle_status VARCHAR(32) NOT NULL DEFAULT 'DRAFT',
    ADD COLUMN source_type VARCHAR(64),
    ADD COLUMN source_id UUID,
    ADD COLUMN source_ref TEXT,
    ADD COLUMN source_line_ref TEXT,
    ADD COLUMN source_document_date DATE,
    ADD COLUMN asset_tag VARCHAR(100),
    ADD COLUMN serial_number VARCHAR(160),
    ADD COLUMN custodian_employee_id UUID REFERENCES employees(id) ON DELETE SET NULL,
    ADD COLUMN operating_status VARCHAR(32) NOT NULL DEFAULT 'PENDING_ACCEPTANCE',
    ADD COLUMN location_text VARCHAR(300),
    ADD COLUMN cost_center_code VARCHAR(100),
    ADD COLUMN acquired_on DATE,
    ADD COLUMN accepted_on DATE,
    ADD COLUMN ready_for_use_on DATE,
    ADD COLUMN capitalized_on DATE,
    ADD COLUMN disposed_on DATE,
    ADD COLUMN cost_style_snapshot_id UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    ADD COLUMN accumulated_style_snapshot_id UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    ADD COLUMN expense_style_snapshot_id UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    ADD COLUMN clearing_style_snapshot_id UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    ADD COLUMN account_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN required_document_codes_snapshot JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN category_version_snapshot INTEGER,
    ADD COLUMN submitted_at TIMESTAMPTZ,
    ADD COLUMN submitted_by UUID REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN approved_at TIMESTAMPTZ,
    ADD COLUMN approved_by UUID REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN last_rejected_at TIMESTAMPTZ,
    ADD COLUMN last_rejected_by UUID REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN last_rejection_reason TEXT,
    ADD COLUMN row_version BIGINT NOT NULL DEFAULT 0;

ALTER TABLE fixed_assets
    ADD CONSTRAINT fixed_assets_lifecycle_status_chk
        CHECK (lifecycle_status IN (
            'DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'ACTIVE',
            'DISPOSAL_PENDING', 'DISPOSED'
        )),
    ADD CONSTRAINT fixed_assets_operating_status_chk
        CHECK (operating_status IN (
            'PENDING_ACCEPTANCE', 'IN_USE', 'IDLE', 'UNDER_REPAIR',
            'LOANED', 'LOST_PENDING', 'DISPOSED'
        )),
    ADD CONSTRAINT fixed_assets_original_value_chk
        CHECK (original_value > 0),
    ADD CONSTRAINT fixed_assets_salvage_rate_chk
        CHECK (salvage_rate BETWEEN 0 AND 1),
    ADD CONSTRAINT fixed_assets_useful_months_chk
        CHECK (useful_months BETWEEN 1 AND 1200),
    ADD CONSTRAINT fixed_assets_start_period_chk
        CHECK (fn_finance_period_is_valid(start_period::TEXT)),
    ADD CONSTRAINT fixed_assets_snapshot_json_chk
        CHECK (jsonb_typeof(account_snapshot) = 'object'
            AND jsonb_typeof(required_document_codes_snapshot) = 'array'),
    ADD CONSTRAINT fixed_assets_category_version_chk
        CHECK (category_version_snapshot IS NULL OR category_version_snapshot >= 1),
    ADD CONSTRAINT fixed_assets_row_version_chk
        CHECK (row_version >= 0),
    ADD CONSTRAINT fixed_assets_date_order_chk
        CHECK ((acquired_on IS NULL OR accepted_on IS NULL OR accepted_on >= acquired_on)
            AND (acquired_on IS NULL OR ready_for_use_on IS NULL OR ready_for_use_on >= acquired_on)
            AND (ready_for_use_on IS NULL OR capitalized_on IS NULL OR capitalized_on >= ready_for_use_on)
            AND (capitalized_on IS NULL OR disposed_on IS NULL OR disposed_on >= capitalized_on)),
    ADD CONSTRAINT fixed_assets_submission_shape_chk
        CHECK (lifecycle_status <> 'PENDING_APPROVAL'
            OR (submitted_at IS NOT NULL AND submitted_by IS NOT NULL)),
    ADD CONSTRAINT fixed_assets_source_shape_chk
        CHECK (lifecycle_status = 'DRAFT'
            OR (source_type IS NOT NULL AND btrim(source_type) <> ''
                AND source_ref IS NOT NULL AND btrim(source_ref) <> ''
                AND source_line_ref IS NOT NULL AND btrim(source_line_ref) <> '')),
    ADD CONSTRAINT fixed_assets_approved_snapshot_chk
        CHECK (lifecycle_status NOT IN ('APPROVED', 'ACTIVE', 'DISPOSAL_PENDING', 'DISPOSED')
            OR (category_id IS NOT NULL
                AND category_version_snapshot IS NOT NULL
                AND cost_style_snapshot_id IS NOT NULL
                AND accumulated_style_snapshot_id IS NOT NULL
                AND expense_style_snapshot_id IS NOT NULL
                AND clearing_style_snapshot_id IS NOT NULL
                AND acquired_on IS NOT NULL
                AND accepted_on IS NOT NULL
                AND ready_for_use_on IS NOT NULL
                AND approved_at IS NOT NULL
                AND approved_by IS NOT NULL)),
    ADD CONSTRAINT fixed_assets_activation_shape_chk
        CHECK (lifecycle_status NOT IN ('ACTIVE', 'DISPOSAL_PENDING', 'DISPOSED')
            OR (ready_for_use_on IS NOT NULL AND capitalized_on IS NOT NULL)),
    ADD CONSTRAINT fixed_assets_disposal_shape_chk
        CHECK ((lifecycle_status <> 'DISPOSED'
                OR (disposed_on IS NOT NULL AND operating_status = 'DISPOSED'))
            AND (operating_status <> 'DISPOSED' OR lifecycle_status = 'DISPOSED')),
    ADD CONSTRAINT fixed_assets_soft_delete_chk
        CHECK ((is_deleted = FALSE AND deleted_at IS NULL)
            OR (is_deleted = TRUE AND deleted_at IS NOT NULL));

CREATE UNIQUE INDEX ux_fixed_assets_active_asset_tag
    ON fixed_assets(asset_tag)
    WHERE is_deleted = FALSE AND asset_tag IS NOT NULL;
CREATE UNIQUE INDEX ux_fixed_assets_active_asset_tag_normalized
    ON fixed_assets(upper(btrim(asset_tag)))
    WHERE is_deleted = FALSE AND asset_tag IS NOT NULL AND btrim(asset_tag) <> '';
CREATE UNIQUE INDEX ux_fixed_assets_active_source_line
    ON fixed_assets(source_type, source_id, source_line_ref)
    WHERE is_deleted = FALSE
      AND source_type IS NOT NULL
      AND source_id IS NOT NULL
      AND source_line_ref IS NOT NULL;
CREATE UNIQUE INDEX ux_fixed_assets_active_external_source_line
    ON fixed_assets(source_type, source_ref, source_line_ref)
    WHERE is_deleted = FALSE
      AND source_id IS NULL
      AND source_type IS NOT NULL
      AND source_ref IS NOT NULL
      AND source_line_ref IS NOT NULL;
CREATE UNIQUE INDEX ux_fixed_assets_active_source_line_normalized
    ON fixed_assets(upper(btrim(source_type)), source_id, lower(btrim(source_line_ref)))
    WHERE is_deleted = FALSE AND source_id IS NOT NULL
      AND source_type IS NOT NULL AND source_line_ref IS NOT NULL;
CREATE UNIQUE INDEX ux_fixed_assets_active_external_source_line_normalized
    ON fixed_assets(upper(btrim(source_type)), lower(btrim(source_ref)), lower(btrim(source_line_ref)))
    WHERE is_deleted = FALSE AND source_id IS NULL
      AND source_type IS NOT NULL AND source_ref IS NOT NULL AND source_line_ref IS NOT NULL;
CREATE INDEX idx_fixed_assets_professional_list
    ON fixed_assets(lifecycle_status, category_id, department_id)
    WHERE is_deleted = FALSE;

COMMENT ON COLUMN fixed_assets.status IS
    'Legacy Chinese display state retained for compatibility only. New workflow must use lifecycle_status.';
COMMENT ON COLUMN fixed_assets.expense_style_id IS
    'Legacy mutable expense account retained for compatibility. Approved posting uses the four snapshot columns.';

ALTER TABLE deferred_expenses
    ADD COLUMN category_id UUID REFERENCES finance_asset_categories(id) ON DELETE RESTRICT,
    ADD COLUMN lifecycle_status VARCHAR(32) NOT NULL DEFAULT 'DRAFT',
    ADD COLUMN source_type VARCHAR(64),
    ADD COLUMN source_id UUID,
    ADD COLUMN source_ref TEXT,
    ADD COLUMN source_line_ref TEXT,
    ADD COLUMN source_document_date DATE,
    ADD COLUMN department_id UUID REFERENCES departments(id) ON DELETE RESTRICT,
    ADD COLUMN responsible_employee_id UUID REFERENCES employees(id) ON DELETE SET NULL,
    ADD COLUMN location_text VARCHAR(300),
    ADD COLUMN cost_center_code VARCHAR(100),
    ADD COLUMN incurred_on DATE,
    ADD COLUMN service_start_on DATE,
    ADD COLUMN benefit_end_on DATE,
    ADD COLUMN recognized_on DATE,
    ADD COLUMN completed_on DATE,
    ADD COLUMN terminated_on DATE,
    ADD COLUMN cost_style_snapshot_id UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    ADD COLUMN accumulated_style_snapshot_id UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    ADD COLUMN expense_style_snapshot_id UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    ADD COLUMN clearing_style_snapshot_id UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    ADD COLUMN account_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN required_document_codes_snapshot JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN category_version_snapshot INTEGER,
    ADD COLUMN submitted_at TIMESTAMPTZ,
    ADD COLUMN submitted_by UUID REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN approved_at TIMESTAMPTZ,
    ADD COLUMN approved_by UUID REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN last_rejected_at TIMESTAMPTZ,
    ADD COLUMN last_rejected_by UUID REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN last_rejection_reason TEXT,
    ADD COLUMN row_version BIGINT NOT NULL DEFAULT 0;

ALTER TABLE deferred_expenses
    ADD CONSTRAINT deferred_expenses_lifecycle_status_chk
        CHECK (lifecycle_status IN (
            'DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'ACTIVE',
            'COMPLETED', 'TERMINATION_PENDING', 'TERMINATED'
        )),
    ADD CONSTRAINT deferred_expenses_total_amount_chk
        CHECK (total_amount > 0),
    ADD CONSTRAINT deferred_expenses_useful_months_chk
        CHECK (useful_months BETWEEN 1 AND 1200),
    ADD CONSTRAINT deferred_expenses_start_period_chk
        CHECK (fn_finance_period_is_valid(start_period::TEXT)),
    ADD CONSTRAINT deferred_expenses_snapshot_json_chk
        CHECK (jsonb_typeof(account_snapshot) = 'object'
            AND jsonb_typeof(required_document_codes_snapshot) = 'array'),
    ADD CONSTRAINT deferred_expenses_category_version_chk
        CHECK (category_version_snapshot IS NULL OR category_version_snapshot >= 1),
    ADD CONSTRAINT deferred_expenses_row_version_chk
        CHECK (row_version >= 0),
    ADD CONSTRAINT deferred_expenses_date_order_chk
        CHECK ((incurred_on IS NULL OR service_start_on IS NULL OR service_start_on >= incurred_on)
            AND (service_start_on IS NULL OR benefit_end_on IS NULL OR benefit_end_on >= service_start_on)
            AND (service_start_on IS NULL OR recognized_on IS NULL OR recognized_on >= service_start_on)
            AND (recognized_on IS NULL OR completed_on IS NULL OR completed_on >= recognized_on)
            AND (recognized_on IS NULL OR terminated_on IS NULL OR terminated_on >= recognized_on)),
    ADD CONSTRAINT deferred_expenses_submission_shape_chk
        CHECK (lifecycle_status <> 'PENDING_APPROVAL'
            OR (submitted_at IS NOT NULL AND submitted_by IS NOT NULL)),
    ADD CONSTRAINT deferred_expenses_source_shape_chk
        CHECK (lifecycle_status = 'DRAFT'
            OR (source_type IS NOT NULL AND btrim(source_type) <> ''
                AND source_ref IS NOT NULL AND btrim(source_ref) <> ''
                AND source_line_ref IS NOT NULL AND btrim(source_line_ref) <> '')),
    ADD CONSTRAINT deferred_expenses_approved_snapshot_chk
        CHECK (lifecycle_status NOT IN (
                'APPROVED', 'ACTIVE', 'COMPLETED', 'TERMINATION_PENDING', 'TERMINATED')
            OR (category_id IS NOT NULL
                AND category_version_snapshot IS NOT NULL
                AND cost_style_snapshot_id IS NOT NULL
                AND expense_style_snapshot_id IS NOT NULL
                AND clearing_style_snapshot_id IS NOT NULL
                AND service_start_on IS NOT NULL
                AND benefit_end_on IS NOT NULL
                AND approved_at IS NOT NULL
                AND approved_by IS NOT NULL)),
    ADD CONSTRAINT deferred_expenses_activation_shape_chk
        CHECK (lifecycle_status NOT IN ('ACTIVE', 'COMPLETED', 'TERMINATION_PENDING', 'TERMINATED')
            OR recognized_on IS NOT NULL),
    ADD CONSTRAINT deferred_expenses_end_shape_chk
        CHECK ((lifecycle_status <> 'COMPLETED' OR completed_on IS NOT NULL)
            AND (lifecycle_status <> 'TERMINATED' OR terminated_on IS NOT NULL)),
    ADD CONSTRAINT deferred_expenses_soft_delete_chk
        CHECK ((is_deleted = FALSE AND deleted_at IS NULL)
            OR (is_deleted = TRUE AND deleted_at IS NOT NULL));

CREATE INDEX idx_deferred_expenses_professional_list
    ON deferred_expenses(lifecycle_status, category_id, department_id)
    WHERE is_deleted = FALSE;
CREATE UNIQUE INDEX ux_deferred_expenses_active_source_line
    ON deferred_expenses(source_type, source_id, source_line_ref)
    WHERE is_deleted = FALSE
      AND source_type IS NOT NULL
      AND source_id IS NOT NULL
      AND source_line_ref IS NOT NULL;
CREATE UNIQUE INDEX ux_deferred_expenses_active_external_source_line
    ON deferred_expenses(source_type, source_ref, source_line_ref)
    WHERE is_deleted = FALSE
      AND source_id IS NULL
      AND source_type IS NOT NULL
      AND source_ref IS NOT NULL
      AND source_line_ref IS NOT NULL;
CREATE UNIQUE INDEX ux_deferred_expenses_active_source_line_normalized
    ON deferred_expenses(upper(btrim(source_type)), source_id, lower(btrim(source_line_ref)))
    WHERE is_deleted = FALSE AND source_id IS NOT NULL
      AND source_type IS NOT NULL AND source_line_ref IS NOT NULL;
CREATE UNIQUE INDEX ux_deferred_expenses_active_external_source_line_normalized
    ON deferred_expenses(upper(btrim(source_type)), lower(btrim(source_ref)), lower(btrim(source_line_ref)))
    WHERE is_deleted = FALSE AND source_id IS NULL
      AND source_type IS NOT NULL AND source_ref IS NOT NULL AND source_line_ref IS NOT NULL;

COMMENT ON COLUMN deferred_expenses.status IS
    'Legacy Chinese display state retained for compatibility only. New workflow must use lifecycle_status.';
COMMENT ON COLUMN deferred_expenses.expense_style_id IS
    'Legacy mutable expense account retained for compatibility. Approved posting uses the cost, expense and clearing snapshots; accumulated depreciation is not required for deferrals.';

-- ---------------------------------------------------------------------------
-- Fixed-asset books and versioned deferred-expense schedules.
-- ---------------------------------------------------------------------------

CREATE TABLE finance_asset_books (
    id                           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id                     UUID NOT NULL REFERENCES fixed_assets(id) ON DELETE RESTRICT,
    book_type                    VARCHAR(16) NOT NULL,
    method                       VARCHAR(40) NOT NULL,
    original_value               NUMERIC(18,4) NOT NULL,
    residual_rate                NUMERIC(9,6) NOT NULL,
    residual_amount              NUMERIC(18,4) NOT NULL,
    depreciable_amount           NUMERIC(18,4) NOT NULL,
    useful_months                INTEGER NOT NULL,
    start_period                 CHAR(7) NOT NULL,
    accumulated_amount           NUMERIC(18,4) NOT NULL DEFAULT 0,
    net_book_value               NUMERIC(18,4) NOT NULL,
    cost_style_id                UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    accumulated_style_id         UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    expense_style_id             UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    clearing_style_id            UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    policy_snapshot              JSONB NOT NULL DEFAULT '{}'::jsonb,
    status                       VARCHAR(24) NOT NULL DEFAULT 'DRAFT',
    posting_enabled              BOOLEAN NOT NULL DEFAULT FALSE,
    activated_at                 TIMESTAMPTZ,
    activated_by                 UUID REFERENCES users(id) ON DELETE SET NULL,
    closed_at                    TIMESTAMPTZ,
    row_version                  BIGINT NOT NULL DEFAULT 0,
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                   UUID,
    updated_by                   UUID,
    is_deleted                   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at                   TIMESTAMPTZ,
    deleted_by                   UUID,
    CONSTRAINT finance_asset_books_type_chk
        CHECK (book_type IN ('CORPORATE', 'TAX')),
    CONSTRAINT finance_asset_books_method_chk
        CHECK (method IN (
            'STRAIGHT_LINE', 'UNITS_OF_PRODUCTION',
            'DOUBLE_DECLINING_BALANCE', 'SUM_OF_YEARS_DIGITS',
            'MANUAL_SCHEDULE'
        )),
    CONSTRAINT finance_asset_books_amount_chk
        CHECK (original_value > 0
            AND residual_amount >= 0
            AND depreciable_amount >= 0
            AND residual_amount + depreciable_amount = original_value
            AND accumulated_amount >= 0
            AND accumulated_amount <= depreciable_amount
            AND net_book_value = original_value - accumulated_amount),
    CONSTRAINT finance_asset_books_residual_chk
        CHECK (residual_rate BETWEEN 0 AND 1),
    CONSTRAINT finance_asset_books_months_chk
        CHECK (useful_months BETWEEN 1 AND 1200),
    CONSTRAINT finance_asset_books_period_chk
        CHECK (fn_finance_period_is_valid(start_period::TEXT)),
    CONSTRAINT finance_asset_books_policy_chk
        CHECK (jsonb_typeof(policy_snapshot) = 'object'),
    CONSTRAINT finance_asset_books_status_chk
        CHECK (status IN ('DRAFT', 'ACTIVE', 'FULLY_DEPRECIATED', 'CLOSED')),
    CONSTRAINT finance_asset_books_activation_chk
        CHECK (status = 'DRAFT' OR (activated_at IS NOT NULL AND activated_by IS NOT NULL)),
    CONSTRAINT finance_asset_books_row_version_chk
        CHECK (row_version >= 0),
    CONSTRAINT finance_asset_books_soft_delete_chk
        CHECK ((is_deleted = FALSE AND deleted_at IS NULL AND deleted_by IS NULL)
            OR (is_deleted = TRUE AND deleted_at IS NOT NULL))
);

CREATE UNIQUE INDEX ux_finance_asset_books_active_type
    ON finance_asset_books(asset_id, book_type)
    WHERE is_deleted = FALSE;
CREATE INDEX idx_finance_asset_books_period
    ON finance_asset_books(book_type, start_period, status)
    WHERE is_deleted = FALSE;

COMMENT ON TABLE finance_asset_books IS
    'Independent corporate and tax books. A tax book is opt-in and never overwrites corporate accounting.';
COMMENT ON COLUMN finance_asset_books.start_period IS
    'For a CORPORATE book, the service must set the depreciation start period to the calendar month after ready_for_use_on. TAX policy remains an independently approved enterprise choice.';
COMMENT ON COLUMN finance_asset_books.policy_snapshot IS
    'Immutable-at-activation snapshot of policy inputs and evidence; no enterprise policy is seeded by V183.';

CREATE TABLE finance_deferral_schedule_versions (
    id                           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    deferred_id                  UUID NOT NULL REFERENCES deferred_expenses(id) ON DELETE RESTRICT,
    version                      INTEGER NOT NULL,
    method                       VARCHAR(40) NOT NULL,
    total_amount                 NUMERIC(18,4) NOT NULL,
    useful_months                INTEGER NOT NULL,
    start_period                 CHAR(7) NOT NULL,
    end_period                   CHAR(7) NOT NULL,
    benefit_start_on             DATE NOT NULL,
    benefit_end_on               DATE NOT NULL,
    expense_style_id             UUID NOT NULL REFERENCES payment_styles(id) ON DELETE RESTRICT,
    cost_style_id                UUID NOT NULL REFERENCES payment_styles(id) ON DELETE RESTRICT,
    clearing_style_id            UUID NOT NULL REFERENCES payment_styles(id) ON DELETE RESTRICT,
    policy_snapshot              JSONB NOT NULL DEFAULT '{}'::jsonb,
    status                       VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
    approved_at                  TIMESTAMPTZ,
    approved_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    supersedes_version_id        UUID REFERENCES finance_deferral_schedule_versions(id) ON DELETE RESTRICT,
    row_version                  BIGINT NOT NULL DEFAULT 0,
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                   UUID,
    updated_by                   UUID,
    is_deleted                   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at                   TIMESTAMPTZ,
    deleted_by                   UUID,
    CONSTRAINT finance_deferral_versions_business_key_uk
        UNIQUE (deferred_id, version),
    CONSTRAINT finance_deferral_versions_method_chk
        CHECK (method IN ('STRAIGHT_LINE', 'MANUAL_SCHEDULE')),
    CONSTRAINT finance_deferral_versions_amount_chk
        CHECK (total_amount > 0),
    CONSTRAINT finance_deferral_versions_months_chk
        CHECK (useful_months BETWEEN 1 AND 1200),
    CONSTRAINT finance_deferral_versions_period_chk
        CHECK (fn_finance_period_is_valid(start_period::TEXT)
            AND fn_finance_period_is_valid(end_period::TEXT)
            AND end_period >= start_period),
    CONSTRAINT finance_deferral_versions_date_chk
        CHECK (benefit_end_on >= benefit_start_on),
    CONSTRAINT finance_deferral_versions_policy_chk
        CHECK (jsonb_typeof(policy_snapshot) = 'object'),
    CONSTRAINT finance_deferral_versions_status_chk
        CHECK (status IN ('DRAFT', 'APPROVED', 'SUPERSEDED', 'TERMINATED')),
    CONSTRAINT finance_deferral_versions_approval_chk
        CHECK (status = 'DRAFT' OR (approved_at IS NOT NULL AND approved_by IS NOT NULL)),
    CONSTRAINT finance_deferral_versions_version_chk
        CHECK (version >= 1 AND row_version >= 0),
    CONSTRAINT finance_deferral_versions_soft_delete_chk
        CHECK ((is_deleted = FALSE AND deleted_at IS NULL AND deleted_by IS NULL)
            OR (is_deleted = TRUE AND deleted_at IS NOT NULL))
);

CREATE UNIQUE INDEX ux_finance_deferral_versions_single_approved
    ON finance_deferral_schedule_versions(deferred_id)
    WHERE status = 'APPROVED' AND is_deleted = FALSE;
CREATE INDEX idx_finance_deferral_versions_period
    ON finance_deferral_schedule_versions(start_period, end_period, status)
    WHERE is_deleted = FALSE;

CREATE TABLE finance_deferral_schedule_lines (
    id                           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    schedule_version_id          UUID NOT NULL REFERENCES finance_deferral_schedule_versions(id) ON DELETE RESTRICT,
    sequence                     INTEGER NOT NULL,
    period                       CHAR(7) NOT NULL,
    opening_balance              NUMERIC(18,4) NOT NULL,
    amount                       NUMERIC(18,4) NOT NULL,
    accumulated_amount           NUMERIC(18,4) NOT NULL,
    closing_balance              NUMERIC(18,4) NOT NULL,
    status                       VARCHAR(16) NOT NULL DEFAULT 'PLANNED',
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                   UUID,
    updated_by                   UUID,
    is_deleted                   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at                   TIMESTAMPTZ,
    deleted_by                   UUID,
    CONSTRAINT finance_deferral_lines_sequence_uk
        UNIQUE (schedule_version_id, sequence),
    CONSTRAINT finance_deferral_lines_period_uk
        UNIQUE (schedule_version_id, period),
    CONSTRAINT finance_deferral_lines_sequence_chk
        CHECK (sequence >= 1),
    CONSTRAINT finance_deferral_lines_period_chk
        CHECK (fn_finance_period_is_valid(period::TEXT)),
    CONSTRAINT finance_deferral_lines_amount_chk
        CHECK (opening_balance >= 0
            AND amount >= 0
            AND accumulated_amount >= amount
            AND closing_balance >= 0
            AND closing_balance = opening_balance - amount),
    CONSTRAINT finance_deferral_lines_status_chk
        CHECK (status IN ('PLANNED', 'POSTED', 'REVERSED')),
    CONSTRAINT finance_deferral_lines_soft_delete_chk
        CHECK ((is_deleted = FALSE AND deleted_at IS NULL AND deleted_by IS NULL)
            OR (is_deleted = TRUE AND deleted_at IS NOT NULL))
);

CREATE INDEX idx_finance_deferral_lines_period
    ON finance_deferral_schedule_lines(period, status)
    WHERE is_deleted = FALSE;

CREATE OR REPLACE FUNCTION fn_validate_deferral_schedule_approval()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_line_count INTEGER;
    v_amount NUMERIC(18,4);
    v_first_period TEXT;
    v_last_period TEXT;
    v_expected_sequence INTEGER := 0;
    v_expected_period TEXT;
    v_previous_closing NUMERIC(18,4);
    v_running_amount NUMERIC(18,4) := 0;
    v_line RECORD;
BEGIN
    IF NEW.status = 'APPROVED'
       AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'APPROVED') THEN
        SELECT COUNT(*), COALESCE(SUM(amount), 0), MIN(period), MAX(period)
          INTO v_line_count, v_amount, v_first_period, v_last_period
        FROM finance_deferral_schedule_lines
        WHERE schedule_version_id = NEW.id AND is_deleted = FALSE;

        IF v_line_count <> NEW.useful_months
           OR v_amount <> NEW.total_amount
           OR v_first_period <> NEW.start_period
           OR v_last_period <> NEW.end_period THEN
            RAISE EXCEPTION
                'Deferred schedule must contain % lines totaling % from % through %',
                NEW.useful_months, NEW.total_amount, NEW.start_period, NEW.end_period
                USING ERRCODE = '23514';
        END IF;

        v_previous_closing := NEW.total_amount;
        FOR v_line IN
            SELECT sequence, period, opening_balance, amount,
                   accumulated_amount, closing_balance
            FROM finance_deferral_schedule_lines
            WHERE schedule_version_id = NEW.id AND is_deleted = FALSE
            ORDER BY sequence
        LOOP
            v_expected_sequence := v_expected_sequence + 1;
            v_expected_period := to_char(
                to_date(NEW.start_period || '-01', 'YYYY-MM-DD')
                    + (v_expected_sequence - 1) * INTERVAL '1 month',
                'YYYY-MM');
            v_running_amount := v_running_amount + v_line.amount;
            IF v_line.sequence <> v_expected_sequence
               OR v_line.period <> v_expected_period
               OR v_line.opening_balance <> v_previous_closing
               OR v_line.accumulated_amount <> v_running_amount THEN
                RAISE EXCEPTION
                    'Deferred schedule has a sequence, continuity or accumulated-amount mismatch at line %',
                    v_line.sequence USING ERRCODE = '23514';
            END IF;
            v_previous_closing := v_line.closing_balance;
        END LOOP;
        IF v_previous_closing <> 0 THEN
            RAISE EXCEPTION 'Deferred schedule final closing balance must be zero'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_deferral_schedule_approval
    BEFORE INSERT OR UPDATE ON finance_deferral_schedule_versions
    FOR EACH ROW EXECUTE FUNCTION fn_validate_deferral_schedule_approval();

CREATE OR REPLACE FUNCTION fn_guard_approved_deferral_schedule_line()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_version_id UUID;
    v_status TEXT;
BEGIN
    v_version_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.schedule_version_id ELSE OLD.schedule_version_id END;
    SELECT status INTO v_status
    FROM finance_deferral_schedule_versions
    WHERE id = v_version_id;
    IF v_status IN ('APPROVED', 'SUPERSEDED', 'TERMINATED') THEN
        RAISE EXCEPTION 'Approved deferred schedule lines are immutable; create a later version or reversal'
            USING ERRCODE = '55000';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_approved_deferral_schedule_line
    BEFORE INSERT OR UPDATE OR DELETE ON finance_deferral_schedule_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_approved_deferral_schedule_line();

-- ---------------------------------------------------------------------------
-- Maker-checker evidence, business events and asset-subledger periods.
-- ---------------------------------------------------------------------------

CREATE TABLE finance_asset_approval_steps (
    id                           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    object_type                  VARCHAR(32) NOT NULL,
    object_id                    UUID NOT NULL,
    workflow_type                VARCHAR(32) NOT NULL,
    step_no                      INTEGER NOT NULL,
    action                       VARCHAR(24) NOT NULL,
    status                       VARCHAR(24) NOT NULL,
    actor_user_id                UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    comment                      TEXT,
    occurred_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                   UUID,
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                   UUID,
    CONSTRAINT finance_asset_approval_business_key_uk
        UNIQUE (object_type, object_id, workflow_type, step_no),
    CONSTRAINT finance_asset_approval_object_type_chk
        CHECK (object_type IN ('FIXED_ASSET', 'DEFERRED_EXPENSE', 'POSTING_RUN')),
    CONSTRAINT finance_asset_approval_workflow_chk
        CHECK (workflow_type IN ('RECOGNITION', 'DISPOSAL', 'TERMINATION', 'POSTING', 'PERIOD_REOPEN')),
    CONSTRAINT finance_asset_approval_step_chk
        CHECK (step_no >= 1),
    CONSTRAINT finance_asset_approval_action_chk
        CHECK (action IN ('SUBMIT', 'APPROVE', 'REJECT', 'CANCEL')),
    CONSTRAINT finance_asset_approval_status_chk
        CHECK (status IN ('RECORDED', 'SUPERSEDED'))
);

CREATE INDEX idx_finance_asset_approval_object
    ON finance_asset_approval_steps(object_type, object_id, occurred_at DESC);

CREATE TABLE finance_asset_events (
    id                           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    object_type                  VARCHAR(32) NOT NULL,
    object_id                    UUID NOT NULL,
    event_type                   VARCHAR(48) NOT NULL,
    title                        VARCHAR(200) NOT NULL,
    description                  TEXT,
    effective_date               DATE,
    payload                      JSONB NOT NULL DEFAULT '{}'::jsonb,
    actor_user_id                UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    occurred_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                   UUID,
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                   UUID,
    CONSTRAINT finance_asset_events_object_type_chk
        CHECK (object_type IN ('FIXED_ASSET', 'DEFERRED_EXPENSE', 'POSTING_RUN', 'ACCOUNTING_PERIOD')),
    CONSTRAINT finance_asset_events_type_chk
        CHECK (event_type IN (
            'CREATED', 'UPDATED', 'SUBMITTED', 'APPROVED', 'REJECTED',
            'ACTIVATED', 'TRANSFERRED', 'OPERATING_STATUS_CHANGED',
            'DISPOSAL_REQUESTED', 'DISPOSED', 'TERMINATION_REQUESTED', 'TERMINATED',
            'POSTING_PREVIEWED', 'POSTING_SUBMITTED', 'POSTING_APPROVED',
            'POSTED', 'REVERSED', 'PERIOD_CLOSED', 'PERIOD_REOPENED'
        )),
    CONSTRAINT finance_asset_events_payload_chk
        CHECK (jsonb_typeof(payload) = 'object'),
    CONSTRAINT finance_asset_events_title_chk
        CHECK (btrim(title) <> '')
);

CREATE INDEX idx_finance_asset_events_object
    ON finance_asset_events(object_type, object_id, occurred_at DESC);

CREATE TABLE finance_asset_accounting_periods (
    period                       CHAR(7) PRIMARY KEY,
    status                       VARCHAR(16) NOT NULL DEFAULT 'OPEN',
    depreciation_run_id          UUID,
    amortization_run_id          UUID,
    reconciliation_difference    NUMERIC(18,4) NOT NULL DEFAULT 0,
    close_count                  INTEGER NOT NULL DEFAULT 0,
    close_reason                 TEXT,
    closed_at                    TIMESTAMPTZ,
    closed_by                    UUID REFERENCES users(id) ON DELETE SET NULL,
    reopen_reason                TEXT,
    reopened_at                  TIMESTAMPTZ,
    reopened_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    row_version                  BIGINT NOT NULL DEFAULT 0,
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                   UUID,
    updated_by                   UUID,
    is_deleted                   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at                   TIMESTAMPTZ,
    deleted_by                   UUID,
    CONSTRAINT finance_asset_periods_period_chk
        CHECK (fn_finance_period_is_valid(period::TEXT)),
    CONSTRAINT finance_asset_periods_status_chk
        CHECK (status IN ('OPEN', 'CLOSED')),
    CONSTRAINT finance_asset_periods_close_chk
        CHECK (status <> 'CLOSED'
            OR (depreciation_run_id IS NOT NULL
                AND amortization_run_id IS NOT NULL
                AND closed_at IS NOT NULL AND closed_by IS NOT NULL
                AND close_reason IS NOT NULL AND btrim(close_reason) <> ''
                AND reconciliation_difference = 0)),
    CONSTRAINT finance_asset_periods_reopen_chk
        CHECK ((reopened_at IS NULL AND reopened_by IS NULL AND reopen_reason IS NULL)
            OR (reopened_at IS NOT NULL AND reopened_by IS NOT NULL
                AND reopen_reason IS NOT NULL AND btrim(reopen_reason) <> '')),
    CONSTRAINT finance_asset_periods_version_chk
        CHECK (row_version >= 0 AND close_count >= 0),
    CONSTRAINT finance_asset_periods_soft_delete_chk
        CHECK ((is_deleted = FALSE AND deleted_at IS NULL AND deleted_by IS NULL)
            OR (is_deleted = TRUE AND deleted_at IS NOT NULL))
);

COMMENT ON TABLE finance_asset_accounting_periods IS
    'Asset-subledger period gate. Closing requires both normal run types to be evidenced (including valid zero-item runs) and reconciliation difference zero; the service enforces those cross-table rules under lock.';

-- Approval steps and business events are evidence, never mutable workflow rows.
CREATE OR REPLACE FUNCTION fn_reject_update_or_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION '% is append-only; append a correcting event instead', TG_TABLE_NAME
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_append_only_finance_asset_approval_steps
    BEFORE UPDATE OR DELETE ON finance_asset_approval_steps
    FOR EACH ROW EXECUTE FUNCTION fn_reject_update_or_delete();
CREATE TRIGGER trg_append_only_finance_asset_events
    BEFORE UPDATE OR DELETE ON finance_asset_events
    FOR EACH ROW EXECUTE FUNCTION fn_reject_update_or_delete();

-- ---------------------------------------------------------------------------
-- Immutable posting runs and line-level calculation snapshots.
-- ---------------------------------------------------------------------------

CREATE TABLE finance_asset_posting_runs (
    id                           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_type                     VARCHAR(24) NOT NULL,
    book_type                    VARCHAR(16) NOT NULL,
    period                       CHAR(7) NOT NULL,
    run_kind                     VARCHAR(16) NOT NULL DEFAULT 'NORMAL',
    status                       VARCHAR(16) NOT NULL DEFAULT 'PREVIEWED',
    input_fingerprint            VARCHAR(128) NOT NULL,
    algorithm_version            VARCHAR(64) NOT NULL,
    idempotency_key              VARCHAR(160) NOT NULL,
    preview_token_hash           VARCHAR(128),
    preview_expires_at           TIMESTAMPTZ,
    item_count                   INTEGER NOT NULL DEFAULT 0,
    total_amount                 NUMERIC(18,4) NOT NULL DEFAULT 0,
    exception_snapshot           JSONB NOT NULL DEFAULT '[]'::jsonb,
    reconciliation_difference    NUMERIC(18,4) NOT NULL DEFAULT 0,
    submitted_at                 TIMESTAMPTZ,
    submitted_by                 UUID REFERENCES users(id) ON DELETE SET NULL,
    approved_at                  TIMESTAMPTZ,
    approved_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    posted_at                    TIMESTAMPTZ,
    posted_by                    UUID REFERENCES users(id) ON DELETE SET NULL,
    voucher_id                   UUID REFERENCES gl_vouchers(id) ON DELETE RESTRICT,
    reversal_of_run_id           UUID REFERENCES finance_asset_posting_runs(id) ON DELETE RESTRICT,
    reversed_by_run_id           UUID REFERENCES finance_asset_posting_runs(id) ON DELETE RESTRICT,
    reversal_reason              TEXT,
    row_version                  BIGINT NOT NULL DEFAULT 0,
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                   UUID,
    updated_by                   UUID,
    is_deleted                   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at                   TIMESTAMPTZ,
    deleted_by                   UUID,
    CONSTRAINT finance_asset_runs_type_chk
        CHECK (run_type IN ('DEPRECIATION', 'AMORTIZATION')),
    CONSTRAINT finance_asset_runs_book_chk
        CHECK (book_type IN ('CORPORATE', 'TAX')),
    CONSTRAINT finance_asset_runs_period_chk
        CHECK (fn_finance_period_is_valid(period::TEXT)),
    CONSTRAINT finance_asset_runs_kind_chk
        CHECK (run_kind IN ('NORMAL', 'REVERSAL')),
    CONSTRAINT finance_asset_runs_status_chk
        CHECK (status IN ('PREVIEWED', 'SUBMITTED', 'APPROVED', 'POSTED', 'REVERSED', 'CANCELLED', 'FAILED')),
    CONSTRAINT finance_asset_runs_fingerprint_chk
        CHECK (btrim(input_fingerprint) <> '' AND btrim(algorithm_version) <> '' AND btrim(idempotency_key) <> ''),
    CONSTRAINT finance_asset_runs_amount_chk
        CHECK (item_count >= 0 AND total_amount >= 0),
    CONSTRAINT finance_asset_runs_exception_chk
        CHECK (jsonb_typeof(exception_snapshot) = 'array'),
    CONSTRAINT finance_asset_runs_reversal_shape_chk
        CHECK ((run_kind = 'NORMAL' AND reversal_of_run_id IS NULL)
            OR (run_kind = 'REVERSAL' AND reversal_of_run_id IS NOT NULL
                AND reversal_reason IS NOT NULL AND btrim(reversal_reason) <> '')),
    CONSTRAINT finance_asset_runs_posted_shape_chk
        CHECK (status NOT IN ('POSTED', 'REVERSED')
            OR (posted_at IS NOT NULL AND posted_by IS NOT NULL
                AND (item_count = 0 OR voucher_id IS NOT NULL))),
    CONSTRAINT finance_asset_runs_approval_shape_chk
        CHECK (status NOT IN ('APPROVED', 'POSTED', 'REVERSED')
            OR (submitted_at IS NOT NULL AND submitted_by IS NOT NULL
                AND approved_at IS NOT NULL AND approved_by IS NOT NULL
                AND approved_by <> submitted_by)),
    CONSTRAINT finance_asset_runs_poster_separation_chk
        CHECK (posted_by IS NULL OR submitted_by IS NULL OR posted_by <> submitted_by),
    CONSTRAINT finance_asset_runs_self_reference_chk
        CHECK (reversal_of_run_id IS NULL OR reversal_of_run_id <> id),
    CONSTRAINT finance_asset_runs_version_chk
        CHECK (row_version >= 0),
    CONSTRAINT finance_asset_runs_idempotency_uk
        UNIQUE (idempotency_key),
    CONSTRAINT finance_asset_runs_reversal_uk
        UNIQUE (reversal_of_run_id),
    CONSTRAINT finance_asset_runs_soft_delete_chk
        CHECK ((is_deleted = FALSE AND deleted_at IS NULL AND deleted_by IS NULL)
            OR (is_deleted = TRUE AND deleted_at IS NOT NULL))
);

CREATE UNIQUE INDEX ux_finance_asset_runs_single_effective_posted
    ON finance_asset_posting_runs(run_type, book_type, period)
    WHERE run_kind = 'NORMAL' AND status = 'POSTED';
CREATE INDEX idx_finance_asset_runs_list
    ON finance_asset_posting_runs(period DESC, run_type, book_type, status);

ALTER TABLE finance_asset_accounting_periods
    ADD CONSTRAINT fk_finance_asset_period_depreciation_run
        FOREIGN KEY (depreciation_run_id) REFERENCES finance_asset_posting_runs(id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_finance_asset_period_amortization_run
        FOREIGN KEY (amortization_run_id) REFERENCES finance_asset_posting_runs(id) ON DELETE RESTRICT;

CREATE TABLE finance_asset_posting_lines (
    id                           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id                       UUID NOT NULL REFERENCES finance_asset_posting_runs(id) ON DELETE RESTRICT,
    object_type                  VARCHAR(32) NOT NULL,
    fixed_asset_id               UUID REFERENCES fixed_assets(id) ON DELETE RESTRICT,
    deferred_expense_id          UUID REFERENCES deferred_expenses(id) ON DELETE RESTRICT,
    asset_book_id                UUID REFERENCES finance_asset_books(id) ON DELETE RESTRICT,
    schedule_version_id          UUID REFERENCES finance_deferral_schedule_versions(id) ON DELETE RESTRICT,
    schedule_line_id             UUID REFERENCES finance_deferral_schedule_lines(id) ON DELETE RESTRICT,
    sequence                     INTEGER NOT NULL,
    line_kind                    VARCHAR(16) NOT NULL DEFAULT 'NORMAL',
    period                       CHAR(7) NOT NULL,
    opening_balance              NUMERIC(18,4) NOT NULL,
    amount                       NUMERIC(18,4) NOT NULL,
    accumulated_amount           NUMERIC(18,4) NOT NULL,
    closing_balance              NUMERIC(18,4) NOT NULL,
    cost_style_id                UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    accumulated_style_id         UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    expense_style_id             UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    clearing_style_id            UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    department_id_snapshot       UUID REFERENCES departments(id) ON DELETE RESTRICT,
    calculation_snapshot         JSONB NOT NULL DEFAULT '{}'::jsonb,
    status                       VARCHAR(16) NOT NULL DEFAULT 'INCLUDED',
    message                      TEXT,
    voucher_id                   UUID REFERENCES gl_vouchers(id) ON DELETE RESTRICT,
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                   UUID,
    updated_by                   UUID,
    is_deleted                   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at                   TIMESTAMPTZ,
    deleted_by                   UUID,
    CONSTRAINT finance_asset_posting_lines_object_chk
        CHECK ((object_type = 'FIXED_ASSET'
                AND fixed_asset_id IS NOT NULL AND deferred_expense_id IS NULL
                AND asset_book_id IS NOT NULL
                AND schedule_version_id IS NULL AND schedule_line_id IS NULL)
            OR (object_type = 'DEFERRED_EXPENSE'
                AND fixed_asset_id IS NULL AND deferred_expense_id IS NOT NULL
                AND asset_book_id IS NULL
                AND schedule_version_id IS NOT NULL AND schedule_line_id IS NOT NULL)),
    CONSTRAINT finance_asset_posting_lines_sequence_chk
        CHECK (sequence >= 1),
    CONSTRAINT finance_asset_posting_lines_kind_chk
        CHECK (line_kind IN ('NORMAL', 'REVERSAL')),
    CONSTRAINT finance_asset_posting_lines_period_chk
        CHECK (fn_finance_period_is_valid(period::TEXT)),
    CONSTRAINT finance_asset_posting_lines_amount_chk
        CHECK (opening_balance >= 0 AND amount >= 0
            AND accumulated_amount >= 0 AND closing_balance >= 0
            AND ((line_kind = 'NORMAL' AND closing_balance = opening_balance - amount)
                OR (line_kind = 'REVERSAL' AND closing_balance = opening_balance + amount))),
    CONSTRAINT finance_asset_posting_lines_snapshot_chk
        CHECK (jsonb_typeof(calculation_snapshot) = 'object'),
    CONSTRAINT finance_asset_posting_lines_status_chk
        CHECK (status IN ('INCLUDED', 'SKIPPED', 'POSTED', 'REVERSED')),
    CONSTRAINT finance_asset_posting_lines_account_shape_chk
        CHECK ((status = 'SKIPPED' AND message IS NOT NULL AND btrim(message) <> '')
            OR (status <> 'SKIPPED'
                AND ((object_type = 'FIXED_ASSET'
                        AND expense_style_id IS NOT NULL
                        AND accumulated_style_id IS NOT NULL)
                    OR (object_type = 'DEFERRED_EXPENSE'
                        AND expense_style_id IS NOT NULL
                        AND cost_style_id IS NOT NULL)))),
    CONSTRAINT finance_asset_posting_lines_run_sequence_uk
        UNIQUE (run_id, sequence),
    CONSTRAINT finance_asset_posting_lines_soft_delete_chk
        CHECK ((is_deleted = FALSE AND deleted_at IS NULL AND deleted_by IS NULL)
            OR (is_deleted = TRUE AND deleted_at IS NOT NULL))
);

CREATE INDEX idx_finance_asset_posting_lines_object
    ON finance_asset_posting_lines(object_type, fixed_asset_id, deferred_expense_id, period);
CREATE UNIQUE INDEX ux_finance_asset_posting_lines_run_asset
    ON finance_asset_posting_lines(run_id, fixed_asset_id)
    WHERE fixed_asset_id IS NOT NULL;
CREATE UNIQUE INDEX ux_finance_asset_posting_lines_run_schedule_line
    ON finance_asset_posting_lines(run_id, schedule_line_id)
    WHERE schedule_line_id IS NOT NULL;

CREATE OR REPLACE FUNCTION fn_guard_finance_asset_posting_run()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Posting runs are append-only; use a reversal run'
            USING ERRCODE = '55000';
    END IF;
    IF OLD.status IN ('POSTED', 'REVERSED') THEN
        IF OLD.status = 'POSTED'
           AND NEW.status = 'REVERSED'
           AND NEW.reversed_by_run_id IS NOT NULL
           AND (to_jsonb(NEW) - ARRAY[
                'status', 'reversed_by_run_id', 'row_version',
                'updated_at', 'updated_by'
           ]) = (to_jsonb(OLD) - ARRAY[
                'status', 'reversed_by_run_id', 'row_version',
                'updated_at', 'updated_by'
           ]) THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'Posted run facts are immutable; use a reversal run'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_finance_asset_posting_run
    BEFORE UPDATE OR DELETE ON finance_asset_posting_runs
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_asset_posting_run();

CREATE OR REPLACE FUNCTION fn_guard_finance_asset_posting_line()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id UUID;
    v_status TEXT;
BEGIN
    v_run_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.run_id ELSE OLD.run_id END;
    SELECT status INTO v_status FROM finance_asset_posting_runs WHERE id = v_run_id;
    IF v_status IN ('POSTED', 'REVERSED') THEN
        RAISE EXCEPTION 'Posted calculation snapshots are immutable; use a reversal run'
            USING ERRCODE = '55000';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_finance_asset_posting_line
    BEFORE INSERT OR UPDATE OR DELETE ON finance_asset_posting_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_asset_posting_line();

-- ---------------------------------------------------------------------------
-- V123 compatibility logs become run-owned, reversible facts. The old
-- delete-and-rebuild unique constraints are replaced by a single ACTIVE normal
-- fact per object and period. Existing V123 business tables are empty for this
-- rollout, so the new NOT NULL columns can be enforced without inventing data.
-- ---------------------------------------------------------------------------

ALTER TABLE fa_depreciation_log
    DROP CONSTRAINT fa_depreciation_log_asset_id_period_key,
    ADD COLUMN asset_book_id UUID NOT NULL REFERENCES finance_asset_books(id) ON DELETE RESTRICT,
    ADD COLUMN posting_run_id UUID NOT NULL REFERENCES finance_asset_posting_runs(id) ON DELETE RESTRICT,
    ADD COLUMN posting_line_id UUID NOT NULL REFERENCES finance_asset_posting_lines(id) ON DELETE RESTRICT,
    ADD COLUMN sequence INTEGER NOT NULL,
    ADD COLUMN opening_balance NUMERIC(18,4) NOT NULL,
    ADD COLUMN accumulated_amount NUMERIC(18,4) NOT NULL,
    ADD COLUMN closing_balance NUMERIC(18,4) NOT NULL,
    ADD COLUMN entry_kind VARCHAR(16) NOT NULL DEFAULT 'NORMAL',
    ADD COLUMN status VARCHAR(16) NOT NULL DEFAULT 'ACTIVE',
    ADD COLUMN reversal_of_log_id UUID REFERENCES fa_depreciation_log(id) ON DELETE RESTRICT,
    ADD COLUMN reversed_by_log_id UUID REFERENCES fa_depreciation_log(id) ON DELETE RESTRICT,
    ADD COLUMN calculation_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN deleted_by UUID;

ALTER TABLE fa_depreciation_log
    ADD CONSTRAINT fa_depreciation_log_period_chk
        CHECK (fn_finance_period_is_valid(period::TEXT)),
    ADD CONSTRAINT fa_depreciation_log_sequence_chk
        CHECK (sequence >= 1),
    ADD CONSTRAINT fa_depreciation_log_amount_chk
        CHECK (amount > 0 AND opening_balance >= 0
            AND accumulated_amount >= 0 AND closing_balance >= 0
            AND ((entry_kind = 'NORMAL'
                    AND closing_balance = opening_balance - amount
                    AND accumulated_amount >= amount)
                OR (entry_kind = 'REVERSAL'
                    AND closing_balance = opening_balance + amount))),
    ADD CONSTRAINT fa_depreciation_log_kind_chk
        CHECK ((entry_kind = 'NORMAL' AND reversal_of_log_id IS NULL)
            OR (entry_kind = 'REVERSAL' AND reversal_of_log_id IS NOT NULL)),
    ADD CONSTRAINT fa_depreciation_log_status_chk
        CHECK (status IN ('ACTIVE', 'REVERSED')),
    ADD CONSTRAINT fa_depreciation_log_self_ref_chk
        CHECK (reversal_of_log_id IS NULL OR reversal_of_log_id <> id),
    ADD CONSTRAINT fa_depreciation_log_snapshot_chk
        CHECK (jsonb_typeof(calculation_snapshot) = 'object'),
    ADD CONSTRAINT fa_depreciation_log_reversal_uk
        UNIQUE (reversal_of_log_id),
    ADD CONSTRAINT fa_depreciation_log_posting_line_uk
        UNIQUE (posting_line_id),
    ADD CONSTRAINT fa_depreciation_log_soft_delete_chk
        CHECK ((is_deleted = FALSE AND deleted_at IS NULL AND deleted_by IS NULL)
            OR (is_deleted = TRUE AND deleted_at IS NOT NULL));

CREATE UNIQUE INDEX ux_fa_depreciation_log_active_period
    ON fa_depreciation_log(asset_id, asset_book_id, period)
    WHERE entry_kind = 'NORMAL' AND status = 'ACTIVE' AND is_deleted = FALSE;
CREATE INDEX idx_fa_depreciation_log_run
    ON fa_depreciation_log(posting_run_id, sequence);

ALTER TABLE da_amortization_log
    DROP CONSTRAINT da_amortization_log_deferred_id_period_key,
    ADD COLUMN schedule_version_id UUID NOT NULL REFERENCES finance_deferral_schedule_versions(id) ON DELETE RESTRICT,
    ADD COLUMN schedule_line_id UUID NOT NULL REFERENCES finance_deferral_schedule_lines(id) ON DELETE RESTRICT,
    ADD COLUMN posting_run_id UUID NOT NULL REFERENCES finance_asset_posting_runs(id) ON DELETE RESTRICT,
    ADD COLUMN posting_line_id UUID NOT NULL REFERENCES finance_asset_posting_lines(id) ON DELETE RESTRICT,
    ADD COLUMN sequence INTEGER NOT NULL,
    ADD COLUMN opening_balance NUMERIC(18,4) NOT NULL,
    ADD COLUMN accumulated_amount NUMERIC(18,4) NOT NULL,
    ADD COLUMN closing_balance NUMERIC(18,4) NOT NULL,
    ADD COLUMN entry_kind VARCHAR(16) NOT NULL DEFAULT 'NORMAL',
    ADD COLUMN status VARCHAR(16) NOT NULL DEFAULT 'ACTIVE',
    ADD COLUMN reversal_of_log_id UUID REFERENCES da_amortization_log(id) ON DELETE RESTRICT,
    ADD COLUMN reversed_by_log_id UUID REFERENCES da_amortization_log(id) ON DELETE RESTRICT,
    ADD COLUMN calculation_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN deleted_by UUID;

ALTER TABLE da_amortization_log
    ADD CONSTRAINT da_amortization_log_period_chk
        CHECK (fn_finance_period_is_valid(period::TEXT)),
    ADD CONSTRAINT da_amortization_log_sequence_chk
        CHECK (sequence >= 1),
    ADD CONSTRAINT da_amortization_log_amount_chk
        CHECK (amount > 0 AND opening_balance >= 0
            AND accumulated_amount >= 0 AND closing_balance >= 0
            AND ((entry_kind = 'NORMAL'
                    AND closing_balance = opening_balance - amount
                    AND accumulated_amount >= amount)
                OR (entry_kind = 'REVERSAL'
                    AND closing_balance = opening_balance + amount))),
    ADD CONSTRAINT da_amortization_log_kind_chk
        CHECK ((entry_kind = 'NORMAL' AND reversal_of_log_id IS NULL)
            OR (entry_kind = 'REVERSAL' AND reversal_of_log_id IS NOT NULL)),
    ADD CONSTRAINT da_amortization_log_status_chk
        CHECK (status IN ('ACTIVE', 'REVERSED')),
    ADD CONSTRAINT da_amortization_log_self_ref_chk
        CHECK (reversal_of_log_id IS NULL OR reversal_of_log_id <> id),
    ADD CONSTRAINT da_amortization_log_snapshot_chk
        CHECK (jsonb_typeof(calculation_snapshot) = 'object'),
    ADD CONSTRAINT da_amortization_log_reversal_uk
        UNIQUE (reversal_of_log_id),
    ADD CONSTRAINT da_amortization_log_posting_line_uk
        UNIQUE (posting_line_id),
    ADD CONSTRAINT da_amortization_log_soft_delete_chk
        CHECK ((is_deleted = FALSE AND deleted_at IS NULL AND deleted_by IS NULL)
            OR (is_deleted = TRUE AND deleted_at IS NOT NULL));

CREATE UNIQUE INDEX ux_da_amortization_log_active_period
    ON da_amortization_log(deferred_id, schedule_version_id, period)
    WHERE entry_kind = 'NORMAL' AND status = 'ACTIVE' AND is_deleted = FALSE;
CREATE INDEX idx_da_amortization_log_run
    ON da_amortization_log(posting_run_id, sequence);

CREATE OR REPLACE FUNCTION fn_guard_finance_asset_ledger_fact()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION '% contains posted facts; use a reversal row', TG_TABLE_NAME
            USING ERRCODE = '55000';
    END IF;
    IF OLD.status = 'ACTIVE'
       AND NEW.status = 'REVERSED'
       AND NEW.reversed_by_log_id IS NOT NULL
       AND (to_jsonb(NEW) - ARRAY[
            'status', 'reversed_by_log_id', 'updated_at', 'updated_by'
       ]) = (to_jsonb(OLD) - ARRAY[
            'status', 'reversed_by_log_id', 'updated_at', 'updated_by'
       ]) THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION '% contains immutable posted facts; use a reversal row', TG_TABLE_NAME
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_guard_fa_depreciation_log
    BEFORE UPDATE OR DELETE ON fa_depreciation_log
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_asset_ledger_fact();
CREATE TRIGGER trg_guard_da_amortization_log
    BEFORE UPDATE OR DELETE ON da_amortization_log
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_asset_ledger_fact();

-- ---------------------------------------------------------------------------
-- General-ledger traceability. Asset-owned vouchers have explicit source and
-- idempotency references, and can only be corrected by a linked reversal.
-- ---------------------------------------------------------------------------

ALTER TABLE gl_vouchers
    ADD COLUMN source_ref TEXT,
    ADD COLUMN idempotency_key VARCHAR(160),
    ADD COLUMN reversal_of_voucher_id UUID REFERENCES gl_vouchers(id) ON DELETE RESTRICT,
    ADD COLUMN reversed_by_voucher_id UUID REFERENCES gl_vouchers(id) ON DELETE RESTRICT;

ALTER TABLE gl_vouchers
    ADD CONSTRAINT gl_vouchers_asset_source_shape_chk
        CHECK (source_type NOT IN (
                'FA_CAP', 'DA_RECOGNITION', 'FA_DEP', 'DA_AMT',
                'FA_DISPOSAL', 'DA_TERMINATION', 'FA_CAP_REV',
                'DA_RECOGNITION_REV', 'FA_DEP_REV', 'DA_AMT_REV',
                'FA_DISPOSAL_REV', 'DA_TERMINATION_REV'
            ) OR (source_ref IS NOT NULL AND btrim(source_ref) <> ''
                AND idempotency_key IS NOT NULL AND btrim(idempotency_key) <> '')),
    ADD CONSTRAINT gl_vouchers_reversal_shape_chk
        CHECK ((reversal_of_voucher_id IS NULL)
            OR (reversal_of_voucher_id <> id AND source_type LIKE '%_REV'));

CREATE UNIQUE INDEX ux_gl_vouchers_idempotency_key
    ON gl_vouchers(idempotency_key)
    WHERE idempotency_key IS NOT NULL;
CREATE UNIQUE INDEX ux_gl_vouchers_single_reversal
    ON gl_vouchers(reversal_of_voucher_id)
    WHERE reversal_of_voucher_id IS NOT NULL;
CREATE INDEX idx_gl_vouchers_source_ref
    ON gl_vouchers(source_type, source_ref)
    WHERE source_ref IS NOT NULL;

CREATE OR REPLACE FUNCTION fn_guard_asset_owned_gl_voucher()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_asset_owned BOOLEAN;
BEGIN
    v_asset_owned := OLD.source_type IN (
        'FA_CAP', 'DA_RECOGNITION', 'FA_DEP', 'DA_AMT',
        'FA_DISPOSAL', 'DA_TERMINATION', 'FA_CAP_REV',
        'DA_RECOGNITION_REV', 'FA_DEP_REV', 'DA_AMT_REV',
        'FA_DISPOSAL_REV', 'DA_TERMINATION_REV');
    IF NOT v_asset_owned THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Asset-owned GL vouchers are immutable; post a linked reversal'
            USING ERRCODE = '55000';
    END IF;
    IF OLD.status = 0
       AND NEW.status = 1
       AND NEW.reversed_by_voucher_id IS NULL
       AND (to_jsonb(NEW) - ARRAY[
            'status', 'updated_at', 'updated_by'
       ]) = (to_jsonb(OLD) - ARRAY[
            'status', 'updated_at', 'updated_by'
       ]) THEN
        RETURN NEW;
    END IF;
    IF OLD.status = 1
       AND NEW.status = -1
       AND NEW.reversed_by_voucher_id IS NOT NULL
       AND (to_jsonb(NEW) - ARRAY[
            'status', 'reversed_by_voucher_id', 'updated_at', 'updated_by'
       ]) = (to_jsonb(OLD) - ARRAY[
            'status', 'reversed_by_voucher_id', 'updated_at', 'updated_by'
       ]) THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'Asset-owned GL vouchers are immutable; post a linked reversal'
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_guard_asset_owned_gl_voucher
    BEFORE UPDATE OR DELETE ON gl_vouchers
    FOR EACH ROW EXECUTE FUNCTION fn_guard_asset_owned_gl_voucher();

CREATE OR REPLACE FUNCTION fn_guard_asset_owned_gl_entry()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_source_type TEXT;
    v_voucher_status SMALLINT;
    v_voucher_id UUID;
BEGIN
    v_voucher_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.voucher_id ELSE OLD.voucher_id END;
    SELECT source_type, status INTO v_source_type, v_voucher_status
    FROM gl_vouchers
    WHERE id = v_voucher_id;

    IF v_source_type IN (
        'FA_CAP', 'DA_RECOGNITION', 'FA_DEP', 'DA_AMT',
        'FA_DISPOSAL', 'DA_TERMINATION', 'FA_CAP_REV',
        'DA_RECOGNITION_REV', 'FA_DEP_REV', 'DA_AMT_REV',
        'FA_DISPOSAL_REV', 'DA_TERMINATION_REV') THEN
        IF TG_OP = 'INSERT' AND v_voucher_status = 0 THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'Asset-owned GL entries are immutable after voucher finalization; post a linked reversal voucher'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_asset_owned_gl_entry
    BEFORE INSERT OR UPDATE OR DELETE ON gl_entries
    FOR EACH ROW EXECUTE FUNCTION fn_guard_asset_owned_gl_entry();

-- ---------------------------------------------------------------------------
-- Server-enforced least privilege. Finance receives only view/edit by default;
-- maker-checker, posting, disposal, export and period management require an
-- explicit personal/role grant approved by an authorization administrator.
-- ---------------------------------------------------------------------------

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('finance_asset:view',          '查看资产与待摊子账',       '钱流管理', 572),
    ('finance_asset:edit',          '维护资产与待摊草稿',       '钱流管理', 573),
    ('finance_asset:approve',       '审批资产与待摊及过账批次', '钱流管理', 574),
    ('finance_asset:post',          '执行资产与待摊过账及反冲', '钱流管理', 575),
    ('finance_asset:dispose',       '处置资产或终止待摊',       '钱流管理', 576),
    ('finance_asset:export',        '导出资产与待摊敏感数据',   '钱流管理', 577),
    ('finance_asset_period:manage', '关闭或受控重开资产期间',   '钱流管理', 578)
ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
CROSS JOIN permissions p
WHERE d.code = 'DEPT_FIN'
  AND d.is_deleted = FALSE
  AND p.code IN ('finance_asset:view', 'finance_asset:edit')
ON CONFLICT DO NOTHING;

-- Defence in depth: high-risk asset permissions are never inherited merely
-- because an installation previously experimented with a department grant.
DELETE FROM department_permissions dp
USING departments d, permissions p
WHERE dp.department_id = d.id
  AND dp.permission_id = p.id
  AND d.code = 'DEPT_FIN'
  AND p.code IN (
      'finance_asset:approve', 'finance_asset:post',
      'finance_asset:dispose', 'finance_asset:export',
      'finance_asset_period:manage'
  );

-- ---------------------------------------------------------------------------
-- Audit and updated_at coverage. V169 cannot see tables created later, so V183
-- attaches explicit triggers and then performs the same reviewed missing-table
-- sweep. Immutable evidence tables intentionally have no updated_at trigger.
-- ---------------------------------------------------------------------------

CREATE TRIGGER trg_set_updated_at_finance_asset_categories
    BEFORE UPDATE ON finance_asset_categories
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_finance_asset_books
    BEFORE UPDATE ON finance_asset_books
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_finance_deferral_schedule_versions
    BEFORE UPDATE ON finance_deferral_schedule_versions
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_finance_deferral_schedule_lines
    BEFORE UPDATE ON finance_deferral_schedule_lines
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_finance_asset_approval_steps
    BEFORE UPDATE ON finance_asset_approval_steps
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_finance_asset_events
    BEFORE UPDATE ON finance_asset_events
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_finance_asset_accounting_periods
    BEFORE UPDATE ON finance_asset_accounting_periods
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_finance_asset_posting_runs
    BEFORE UPDATE ON finance_asset_posting_runs
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_finance_asset_posting_lines
    BEFORE UPDATE ON finance_asset_posting_lines
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_fixed_assets_v183
    BEFORE UPDATE ON fixed_assets
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_deferred_expenses_v183
    BEFORE UPDATE ON deferred_expenses
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_fa_depreciation_log_v183
    BEFORE UPDATE ON fa_depreciation_log
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_da_amortization_log_v183
    BEFORE UPDATE ON da_amortization_log
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_set_updated_at_gl_vouchers_v183
    BEFORE UPDATE ON gl_vouchers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_audit_finance_asset_categories
    AFTER INSERT OR UPDATE OR DELETE ON finance_asset_categories
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_asset_books
    AFTER INSERT OR UPDATE OR DELETE ON finance_asset_books
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_deferral_schedule_versions
    AFTER INSERT OR UPDATE OR DELETE ON finance_deferral_schedule_versions
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_deferral_schedule_lines
    AFTER INSERT OR UPDATE OR DELETE ON finance_deferral_schedule_lines
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_asset_approval_steps
    AFTER INSERT OR UPDATE OR DELETE ON finance_asset_approval_steps
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_asset_events
    AFTER INSERT OR UPDATE OR DELETE ON finance_asset_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_asset_accounting_periods
    AFTER INSERT OR UPDATE OR DELETE ON finance_asset_accounting_periods
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_asset_posting_runs
    AFTER INSERT OR UPDATE OR DELETE ON finance_asset_posting_runs
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_asset_posting_lines
    AFTER INSERT OR UPDATE OR DELETE ON finance_asset_posting_lines
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

DO $$
DECLARE
    table_name TEXT;
BEGIN
    FOR table_name IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND c.relname NOT IN (
              'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
              'authorization_state', 'doc_number_sequences', 'master_code_sequences',
              'report_materialized_view_refresh_state', 'password_history',
              'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
          AND c.relname NOT LIKE 'legacy_migration_%'
          AND NOT EXISTS (
              SELECT 1
              FROM pg_trigger trigger
              WHERE trigger.tgrelid = c.oid
                AND NOT trigger.tgisinternal
                AND trigger.tgname LIKE 'trg_audit%')
        ORDER BY c.relname
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_audit_%1$I AFTER INSERT OR UPDATE OR DELETE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit()',
            table_name);
    END LOOP;
END $$;

COMMENT ON TABLE finance_asset_posting_runs IS
    'Immutable preview/approval/post/reversal batch header. Same idempotency key with different payload must be rejected by the service; only one effective normal POSTED run exists per type/book/period.';
COMMENT ON TABLE finance_asset_posting_lines IS
    'Frozen line-level inputs, accounts, opening/current/closing values and algorithm snapshot used to reproduce each run.';
COMMENT ON TABLE finance_asset_approval_steps IS
    'Append-only maker-checker evidence; object integrity and self-approval rules are enforced by the service in the same transaction.';
COMMENT ON TABLE finance_asset_events IS
    'Append-only business event timeline. Corrections are later events, never edits or deletes.';
