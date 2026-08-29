-- V400: privileged account-balance reconciliation with immutable evidence and GL ownership.
--
-- A balance correction is never a master-data overwrite.  The posted batch and
-- its per-account snapshots are append-only; account totals, the bank register,
-- and the regenerable general-ledger projection move in the same business model.
-- This migration posts only the reviewed correction delta. It does not infer or
-- manufacture a historical GL opening entry for pre-existing init_balance.

-- Fail closed before changing the invariant.  V142 should already enforce this,
-- but the explicit check also protects databases whose old constraint was left
-- NOT VALID or was removed by unsupported maintenance.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM accounts
        WHERE balance_current
              IS DISTINCT FROM init_balance + receipts_total - payments_total
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'existing account balances violate the pre-V400 invariant';
    END IF;
END $$;

-- Reviewed legacy-only currency bridge. The old finance source uses a stable
-- split: OFFSHORE accounts are USD (currencies.legacy_id=3); every other legacy
-- account is RMB (legacy_id=1). Apply it only to legacy identities whose UUID is
-- still NULL. Existing UUIDs and online/manual accounts are never inferred.
DO $$
DECLARE
    v_rmb_currency_id UUID;
    v_offshore_currency_id UUID;
    v_match_count BIGINT;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('PAYMENT_STYLE_HIERARCHY',0));
    PERFORM pg_advisory_xact_lock(
        hashtextextended('ACCOUNT_MASTER_POPULATION',0));
    PERFORM 1
      FROM currencies
     WHERE legacy_id IN (1,3)
        OR id IN (
            SELECT account.currency_id
            FROM accounts account
            WHERE account.status='使用'
              AND COALESCE(account.is_deleted,FALSE)=FALSE
              AND account.currency_id IS NOT NULL)
     ORDER BY id
     FOR SHARE;
    PERFORM 1
      FROM accounts
     WHERE currency_id IS NULL AND legacy_id IS NOT NULL
     ORDER BY id
     FOR UPDATE;

    IF EXISTS (
        SELECT 1 FROM accounts
        WHERE currency_id IS NULL AND legacy_id IS NOT NULL
          AND account_type<>'OFFSHORE'
    ) THEN
        SELECT COUNT(*),MIN(id::TEXT)::UUID
          INTO v_match_count,v_rmb_currency_id
          FROM currencies
         WHERE legacy_id=1 AND status='使用'
           AND COALESCE(is_deleted,FALSE)=FALSE;
        IF v_match_count<>1 THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE=format(
                    'legacy RMB account currency mapping requires exactly one active currencies.legacy_id=1 row; found %s',
                    v_match_count);
        END IF;
    END IF;

    IF EXISTS (
        SELECT 1 FROM accounts
        WHERE currency_id IS NULL AND legacy_id IS NOT NULL
          AND account_type='OFFSHORE'
    ) THEN
        SELECT COUNT(*),MIN(id::TEXT)::UUID
          INTO v_match_count,v_offshore_currency_id
          FROM currencies
         WHERE legacy_id=3 AND status='使用'
           AND COALESCE(is_deleted,FALSE)=FALSE;
        IF v_match_count<>1 THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE=format(
                    'legacy OFFSHORE account currency mapping requires exactly one active currencies.legacy_id=3 row; found %s',
                    v_match_count);
        END IF;
    END IF;

    UPDATE accounts
       SET currency_id=CASE
               WHEN account_type='OFFSHORE' THEN v_offshore_currency_id
               ELSE v_rmb_currency_id
           END,
           updated_at=now()
     WHERE currency_id IS NULL
       AND legacy_id IS NOT NULL;
END $$;

-- An active account without an explicit, active currency cannot be reconciled
-- or converted to local currency without guessing. The bridge above handles
-- only the proven legacy split; manual, dangling and disabled mappings remain
-- fail-closed here.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM accounts account
        LEFT JOIN currencies currency ON currency.id=account.currency_id
        WHERE account.status='使用'
          AND COALESCE(account.is_deleted,FALSE)=FALSE
          AND (
              account.currency_id IS NULL
              OR currency.id IS NULL
              OR currency.status IS DISTINCT FROM '使用'
              OR COALESCE(currency.is_deleted,FALSE))
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'active accounts have missing, disabled, or deleted currency UUIDs; complete a reviewed pre-V400 currency mapping first';
    END IF;
END $$;

ALTER TABLE accounts
    ADD COLUMN balance_adjustments_total NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN balance_floor NUMERIC(18,4);

ALTER TABLE accounts
    ADD CONSTRAINT ck_accounts_active_currency_uuid CHECK (
        status <> '使用' OR COALESCE(is_deleted,FALSE) OR currency_id IS NOT NULL
    ) NOT VALID;
ALTER TABLE accounts VALIDATE CONSTRAINT ck_accounts_active_currency_uuid;

ALTER TABLE accounts DROP CONSTRAINT accounts_balance_consistency_chk;
ALTER TABLE accounts
    ADD CONSTRAINT accounts_balance_consistency_chk CHECK (
        balance_current
            = init_balance + receipts_total - payments_total
              + balance_adjustments_total
    );

COMMENT ON COLUMN accounts.balance_adjustments_total IS
    'Immutable posted balance-reconciliation deltas; never ordinary receipts or payments';
COMMENT ON COLUMN accounts.balance_floor IS
    'Optional warning floor in the account currency; informational and never an overdraft authorization';
COMMENT ON CONSTRAINT accounts_balance_consistency_chk ON accounts IS
    'Current balance equals opening plus receipts minus payments plus posted balance adjustments';

CREATE OR REPLACE FUNCTION fn_guard_active_account_currency()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status='使用' AND NOT COALESCE(NEW.is_deleted,FALSE) THEN
        IF NEW.currency_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM currencies currency
            WHERE currency.id=NEW.currency_id
              AND currency.status='使用'
              AND COALESCE(currency.is_deleted,FALSE)=FALSE
            FOR SHARE
        ) THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='active account requires an explicit active currency UUID';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_active_account_currency
    BEFORE INSERT OR UPDATE OF currency_id,status,is_deleted ON accounts
    FOR EACH ROW EXECUTE FUNCTION fn_guard_active_account_currency();

CREATE OR REPLACE FUNCTION fn_guard_currency_with_active_accounts()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        IF EXISTS (
            SELECT 1 FROM accounts account
            WHERE account.currency_id=OLD.id
              AND account.status='使用'
              AND COALESCE(account.is_deleted,FALSE)=FALSE
        ) THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='currency is referenced by active accounts and cannot be disabled or deleted';
        END IF;
        RETURN OLD;
    END IF;
    IF NEW.status IS DISTINCT FROM '使用'
       OR COALESCE(NEW.is_deleted,FALSE) THEN
        IF EXISTS (
            SELECT 1 FROM accounts account
            WHERE account.currency_id=OLD.id
              AND account.status='使用'
              AND COALESCE(account.is_deleted,FALSE)=FALSE
        ) THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='currency is referenced by active accounts and cannot be disabled or deleted';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_currency_with_active_accounts
    BEFORE UPDATE OF status,is_deleted OR DELETE ON currencies
    FOR EACH ROW EXECUTE FUNCTION fn_guard_currency_with_active_accounts();

-- Recheck after both write guards exist. CREATE TRIGGER holds its table lock
-- until commit, so a raw SQL write that raced the initial row locks cannot
-- leave an invalid active account behind.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM accounts account
        LEFT JOIN currencies currency ON currency.id=account.currency_id
        WHERE account.status='使用'
          AND COALESCE(account.is_deleted,FALSE)=FALSE
          AND (
              account.currency_id IS NULL
              OR currency.id IS NULL
              OR currency.status IS DISTINCT FROM '使用'
              OR COALESCE(currency.is_deleted,FALSE))
    ) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='active account currency authority changed during V400; retry in a maintenance window';
    END IF;
END $$;

-- One reviewed EQUITY leaf is the balancing side of go-live account corrections.
-- The stable UUID is the runtime identity; code/name/path are display snapshots.
INSERT INTO payment_styles(
    id, code, name, category, level, sort_order, path,
    is_receipt, is_payment, status, auto_created)
VALUES(
    '40000000-0000-4000-8100-000000000001',
    'SYS-ACCOUNT-BALANCE-CLEARING', '账户余额调整清算', 'EQUITY', 0, 950,
    '/SYS-ACCOUNT-BALANCE-CLEARING/', FALSE, FALSE, '使用', TRUE)
ON CONFLICT(id) DO NOTHING;

INSERT INTO system_posting_style_roles(
    role_key, style_id, required_category, description)
VALUES(
    'ACCOUNT_BALANCE_CLEARING',
    '40000000-0000-4000-8100-000000000001',
    'EQUITY',
    '上线账户余额核对差额的权益清算科目；只能由不可变余额调整批次使用')
ON CONFLICT(role_key) DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM system_posting_style_roles role
        JOIN payment_styles style ON style.id = role.style_id
        WHERE role.role_key = 'ACCOUNT_BALANCE_CLEARING'
          AND role.style_id = '40000000-0000-4000-8100-000000000001'::UUID
          AND role.required_category = 'EQUITY'
          AND style.category = 'EQUITY'
          AND style.status = '使用'
          AND COALESCE(style.is_deleted, FALSE) = FALSE
          AND NOT EXISTS (
              SELECT 1 FROM payment_styles child
              WHERE child.parent_id = style.id
                AND COALESCE(child.is_deleted, FALSE) = FALSE)
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'account balance clearing role is missing or not mapped to the reviewed EQUITY leaf';
    END IF;
END $$;

-- Every mapped system posting role is an immutable accounting identity.  The
-- earlier guard protected status/category/deletion; V400 also protects code,
-- name and hierarchy so a later GL regeneration cannot silently change meaning.
CREATE OR REPLACE FUNCTION fn_guard_mapped_system_posting_style()
RETURNS TRIGGER AS $$
DECLARE
    v_style_id UUID := OLD.id;
BEGIN
    IF EXISTS (
        SELECT 1 FROM system_posting_style_roles role
        WHERE role.style_id = v_style_id
    ) THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'payment style is mapped to a system posting role and cannot be deleted';
        END IF;
        IF NEW.status <> '使用'
           OR COALESCE(NEW.is_deleted, FALSE)
           OR NEW.category IS DISTINCT FROM OLD.category
           OR NEW.code IS DISTINCT FROM OLD.code
           OR NEW.name IS DISTINCT FROM OLD.name
           OR NEW.parent_id IS DISTINCT FROM OLD.parent_id THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'payment style mapped to a system posting role cannot be renamed, moved, disabled, deleted, or recategorized';
        END IF;
    END IF;
    IF TG_OP='DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_guard_mapped_system_posting_style ON payment_styles;
CREATE TRIGGER trg_guard_mapped_system_posting_style
    BEFORE UPDATE OF status, is_deleted, category, code, name, parent_id OR DELETE
    ON payment_styles
    FOR EACH ROW EXECUTE FUNCTION fn_guard_mapped_system_posting_style();

CREATE TABLE account_balance_adjustment_batches (
    id                  UUID PRIMARY KEY,
    batch_no            TEXT NOT NULL UNIQUE,
    adjustment_scope    TEXT NOT NULL,
    effective_date      DATE NOT NULL,
    reason              TEXT NOT NULL,
    idempotency_key     TEXT NOT NULL UNIQUE,
    request_hash        CHAR(64) NOT NULL,
    clearing_style_id   UUID NOT NULL REFERENCES payment_styles(id) ON DELETE RESTRICT,
    actor_id            UUID NOT NULL
        REFERENCES employees(id) ON DELETE RESTRICT,
    expected_item_count INTEGER NOT NULL,
    changed_item_count  INTEGER NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID,
    CONSTRAINT account_balance_adjustment_batches_scope_chk
        CHECK (adjustment_scope IN ('FULL', 'SELECTED')),
    CONSTRAINT account_balance_adjustment_batches_reason_chk
        CHECK (btrim(reason) <> '' AND char_length(reason) <= 500),
    CONSTRAINT account_balance_adjustment_batches_key_chk
        CHECK (char_length(idempotency_key) BETWEEN 8 AND 128
               AND idempotency_key ~ '^[A-Za-z0-9._:-]+$'),
    CONSTRAINT account_balance_adjustment_batches_hash_chk
        CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT account_balance_adjustment_batches_counts_chk
        CHECK (expected_item_count BETWEEN 1 AND 2000
               AND changed_item_count BETWEEN 0 AND expected_item_count)
);

CREATE TABLE account_balance_adjustment_items (
    id                         UUID PRIMARY KEY,
    batch_id                   UUID NOT NULL
        REFERENCES account_balance_adjustment_batches(id) ON DELETE RESTRICT,
    line_no                    INTEGER NOT NULL,
    account_id                 UUID NOT NULL
        REFERENCES accounts(id) ON DELETE RESTRICT,
    account_code_snapshot      TEXT NOT NULL,
    account_name_snapshot      TEXT NOT NULL,
    currency_id                UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    currency_code_snapshot     TEXT NOT NULL,
    currency_name_snapshot     TEXT NOT NULL,
    exchange_rate_snapshot     NUMERIC(18,6) NOT NULL,
    account_style_id_snapshot  UUID NOT NULL REFERENCES payment_styles(id) ON DELETE RESTRICT,
    expected_balance           NUMERIC(18,4) NOT NULL,
    target_balance             NUMERIC(18,4) NOT NULL,
    delta_balance              NUMERIC(18,4) NOT NULL,
    delta_local                NUMERIC(18,4) NOT NULL,
    verified                   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                 UUID,
    CONSTRAINT account_balance_adjustment_items_batch_account_uq
        UNIQUE(batch_id, account_id),
    CONSTRAINT account_balance_adjustment_items_batch_line_uq
        UNIQUE(batch_id, line_no),
    CONSTRAINT account_balance_adjustment_items_line_chk
        CHECK (line_no BETWEEN 1 AND 2000),
    CONSTRAINT account_balance_adjustment_items_rate_chk CHECK (exchange_rate_snapshot > 0),
    CONSTRAINT account_balance_adjustment_items_snapshots_chk CHECK (
        btrim(account_code_snapshot) <> ''
        AND btrim(account_name_snapshot) <> ''
        AND btrim(currency_code_snapshot) <> ''
        AND btrim(currency_name_snapshot) <> ''),
    CONSTRAINT account_balance_adjustment_items_delta_chk
        CHECK (delta_balance = target_balance - expected_balance),
    CONSTRAINT account_balance_adjustment_items_local_chk
        CHECK (delta_local = round(delta_balance * exchange_rate_snapshot, 4)),
    CONSTRAINT account_balance_adjustment_items_verified_chk CHECK (verified)
);

CREATE INDEX idx_account_balance_adjustment_batches_effective
    ON account_balance_adjustment_batches(effective_date DESC, created_at DESC);
CREATE INDEX idx_account_balance_adjustment_items_account
    ON account_balance_adjustment_items(account_id, created_at DESC);

CREATE TRIGGER trg_psref_account_balance_batch_clearing
    BEFORE INSERT ON account_balance_adjustment_batches
    FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference(
        'clearing_style_id', 'EQUITY', 'true', 'true', 'false', 'true');
CREATE TRIGGER trg_psref_account_balance_item_account
    BEFORE INSERT ON account_balance_adjustment_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference(
        'account_style_id_snapshot', 'ACCOUNT', 'true', 'true', 'false', 'true');

CREATE OR REPLACE FUNCTION fn_guard_balance_adjustment_clearing_snapshot()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM account_balance_adjustment_batches batch
        WHERE batch.clearing_style_id=OLD.id
    ) THEN
        IF TG_OP='DELETE'
           OR NEW.code IS DISTINCT FROM OLD.code
           OR NEW.name IS DISTINCT FROM OLD.name
           OR NEW.category IS DISTINCT FROM OLD.category
           OR NEW.parent_id IS DISTINCT FROM OLD.parent_id
           OR COALESCE(NEW.is_deleted,FALSE) THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='payment style is a frozen account-balance clearing snapshot and cannot change identity';
        END IF;
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_balance_adjustment_clearing_snapshot
    BEFORE UPDATE OF code,name,category,parent_id,is_deleted OR DELETE ON payment_styles
    FOR EACH ROW EXECUTE FUNCTION fn_guard_balance_adjustment_clearing_snapshot();

CREATE OR REPLACE FUNCTION fn_guard_balance_adjustment_clearing_leaf()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.parent_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM account_balance_adjustment_batches batch
        WHERE batch.clearing_style_id=NEW.parent_id
    ) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account-balance clearing snapshot must remain a leaf';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_balance_adjustment_clearing_leaf
    BEFORE INSERT OR UPDATE OF parent_id ON payment_styles
    FOR EACH ROW EXECUTE FUNCTION fn_guard_balance_adjustment_clearing_leaf();

CREATE OR REPLACE FUNCTION fn_guard_account_balance_adjustment_append_only()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = TG_TABLE_NAME || ' is append-only; correct it with a new balance-adjustment batch';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_account_balance_adjustment_batches_append_only
    BEFORE UPDATE OR DELETE ON account_balance_adjustment_batches
    FOR EACH ROW EXECUTE FUNCTION fn_guard_account_balance_adjustment_append_only();
CREATE TRIGGER trg_guard_account_balance_adjustment_items_append_only
    BEFORE UPDATE OR DELETE ON account_balance_adjustment_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_account_balance_adjustment_append_only();

CREATE OR REPLACE FUNCTION fn_validate_account_balance_adjustment_batch_shape()
RETURNS TRIGGER AS $$
DECLARE
    v_batch_id UUID;
    v_expected INTEGER;
    v_changed INTEGER;
    v_actual INTEGER;
    v_actual_changed INTEGER;
BEGIN
    IF TG_TABLE_NAME='account_balance_adjustment_batches' THEN
        v_batch_id := NEW.id;
    ELSE
        v_batch_id := NEW.batch_id;
    END IF;

    SELECT expected_item_count,changed_item_count
      INTO v_expected,v_changed
      FROM account_balance_adjustment_batches
     WHERE id=v_batch_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='account balance adjustment batch header is missing';
    END IF;

    SELECT COUNT(*),COUNT(*) FILTER(WHERE delta_balance<>0)
      INTO v_actual,v_actual_changed
      FROM account_balance_adjustment_items
     WHERE batch_id=v_batch_id;
    IF v_actual<>v_expected OR v_actual_changed<>v_changed THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE=format(
                'account balance adjustment batch shape mismatch: expected=%s/%s actual=%s/%s',
                v_expected,v_changed,v_actual,v_actual_changed);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_validate_account_balance_adjustment_batch_header
    AFTER INSERT OR UPDATE OF expected_item_count,changed_item_count
    ON account_balance_adjustment_batches
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_account_balance_adjustment_batch_shape();
CREATE CONSTRAINT TRIGGER trg_validate_account_balance_adjustment_batch_items
    AFTER INSERT OR UPDATE OR DELETE ON account_balance_adjustment_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_account_balance_adjustment_batch_shape();

CREATE TRIGGER trg_audit_account_balance_adjustment_batches
    AFTER INSERT OR UPDATE OR DELETE ON account_balance_adjustment_batches
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_account_balance_adjustment_items
    AFTER INSERT OR UPDATE OR DELETE ON account_balance_adjustment_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- Register a globally unique, lifetime-reserved human-readable batch number.
INSERT INTO business_identifier_namespaces(
    namespace_key, identifier_family, fixed_prefix,
    source_table, identifier_column, discriminator_value)
VALUES ('FIN_ACCOUNT_BALANCE_ADJUSTMENT', 'DOCUMENT', 'TZ',
    'account_balance_adjustment_batches', 'batch_no', NULL);

CREATE TRIGGER trg_business_document_account_balance_adjustment_batches
    BEFORE INSERT OR UPDATE OF batch_no ON account_balance_adjustment_batches
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier(
        'FIN_ACCOUNT_BALANCE_ADJUSTMENT', 'batch_no', '');

-- The bank register remains the single account-flow authority.
ALTER TABLE finance_reconciliations
    DROP CONSTRAINT finance_reconciliations_source_doc_type_chk;
ALTER TABLE finance_reconciliations
    ADD CONSTRAINT finance_reconciliations_source_doc_type_chk CHECK (
        source_doc_type IN (
            'RECEIPT', 'PAYMENT', 'EXPENSE', 'INCOME', 'BANK_TRANSFER',
            'BALANCE_ADJUSTMENT'));

CREATE OR REPLACE FUNCTION fn_guard_balance_adjustment_reconciliation_append_only()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.source_doc_type='BALANCE_ADJUSTMENT'
       OR (TG_OP='UPDATE' AND NEW.source_doc_type='BALANCE_ADJUSTMENT') THEN
        RAISE EXCEPTION USING ERRCODE='55000',
            MESSAGE='BALANCE_ADJUSTMENT account flows are append-only; correct them with a new adjustment batch';
    END IF;
    IF TG_OP='DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_balance_adjustment_reconciliation_append_only
    BEFORE UPDATE OR DELETE ON finance_reconciliations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_balance_adjustment_reconciliation_append_only();

CREATE INDEX idx_frec_account_date_stable
    ON finance_reconciliations(account_id, bill_date DESC, created_at DESC, id DESC)
    WHERE COALESCE(is_deleted, FALSE) = FALSE;

COMMENT ON TABLE account_balance_adjustment_batches IS
    'Immutable privileged account-balance reconciliation commands; UUID is the source identity and idempotency_key is retry metadata';
COMMENT ON TABLE account_balance_adjustment_items IS
    'Immutable per-account before/target/delta, currency/rate/local amount and display snapshots; zero-delta rows prove verification';

-- AUTO GL vouchers for this new source must also carry their UUID owner.
ALTER TABLE gl_vouchers
    DROP CONSTRAINT gl_vouchers_regenerated_source_doc_required_chk;
ALTER TABLE gl_vouchers
    ADD CONSTRAINT gl_vouchers_regenerated_source_doc_required_chk CHECK (
        source <> 'AUTO'
        OR source_type NOT IN (
            'AR_POST', 'AP_POST', 'RECEIPT', 'PAYMENT',
            'EXPENSE', 'INCOME', 'COST_CARRY', 'BANK_TRANSFER',
            'BALANCE_ADJUSTMENT')
        OR source_doc_id IS NOT NULL
    ) NOT VALID;

-- Fine-grained account permissions.  Balance adjustment is deliberately not
-- granted to any department here; the global permission page must grant it.
INSERT INTO permissions(
    code, name, module, category, sort_order, action_type, description,
    active, assignable)
VALUES
    ('account:balance:view', '查看账户余额', '基础资料', '账户资料', 105,
     'VIEW', '查看账户余额、余额汇总和警戒状态', TRUE, TRUE),
    ('account:flow:view', '查看账户流水', '基础资料', '账户资料', 106,
     'VIEW', '查看账户完整资金流水和滚动余额', TRUE, TRUE),
    ('account:warning:manage', '配置账户余额警戒线', '基础资料', '账户资料', 107,
     'CONFIGURE', '配置账户币种口径的余额警戒线，不构成透支授权', TRUE, TRUE),
    ('account:balance:adjust', '执行账户余额校准', '基础资料', '账户资料', 108,
     'EXECUTE', '按幂等批次、期望余额和不可变流水校准账户余额', TRUE, TRUE)
ON CONFLICT(code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order,
    action_type = EXCLUDED.action_type,
    description = EXCLUDED.description,
    active = TRUE,
    assignable = TRUE;

INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission ON permission.code IN (
    'account:balance:view', 'account:flow:view',
    'account:warning:manage', 'account:balance:adjust')
WHERE surface.surface_key = 'basic.account'
ON CONFLICT(surface_id, permission_id) DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission ON permission.code IN (
    'account:balance:view', 'account:flow:view', 'account:warning:manage')
WHERE department.code = 'DEPT_FIN'
  AND COALESCE(department.is_deleted, FALSE) = FALSE
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission ON permission.code IN (
    'account:balance:view', 'account:flow:view')
WHERE department.code = 'GM'
  AND COALESCE(department.is_deleted, FALSE) = FALSE
ON CONFLICT DO NOTHING;

-- The high-risk adjustment capability is personal-only even for direct SQL.
DELETE FROM department_permissions assignment
USING permissions permission
WHERE assignment.permission_id = permission.id
  AND permission.code = 'account:balance:adjust';

CREATE OR REPLACE FUNCTION fn_guard_department_account_balance_adjustment()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM permissions permission
        WHERE permission.id = NEW.permission_id
          AND permission.code = 'account:balance:adjust'
    ) THEN
        RAISE EXCEPTION '账户余额校准权限仅允许全局权限页逐人授权'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_department_account_balance_adjustment
    BEFORE INSERT OR UPDATE ON department_permissions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_department_account_balance_adjustment();
