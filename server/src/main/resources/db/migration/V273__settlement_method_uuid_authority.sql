-- Stable UUID authorities for two independent legacy dictionaries:
--   B_PStyle -> settlement_methods (sales/purchase/subcontract/AR-AP terms)
--   RecStyle -> finance_payment_methods (receipt/payment instrument)
-- Integer columns are retained only as immutable legacy snapshots.

CREATE TABLE settlement_methods (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id   INT UNIQUE,
    code        VARCHAR(50) NOT NULL UNIQUE,
    legacy_code VARCHAR(50),
    name        VARCHAR(100) NOT NULL,
    status      VARCHAR(20) NOT NULL DEFAULT '使用',
    sort_order  INT NOT NULL DEFAULT 0,
    remark      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    updated_by  UUID,
    is_deleted  BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at  TIMESTAMPTZ,
    CONSTRAINT settlement_methods_status_chk CHECK (status IN ('使用', '禁用'))
);

CREATE TABLE finance_payment_methods (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legacy_id             INT UNIQUE,
    code                  VARCHAR(50) NOT NULL UNIQUE,
    name                  VARCHAR(100) NOT NULL,
    is_receipt            BOOLEAN NOT NULL DEFAULT TRUE,
    is_payment            BOOLEAN NOT NULL DEFAULT TRUE,
    legacy_name_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
    status                VARCHAR(20) NOT NULL DEFAULT '使用',
    sort_order            INT NOT NULL DEFAULT 0,
    remark                TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            UUID,
    updated_by            UUID,
    is_deleted            BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at            TIMESTAMPTZ,
    CONSTRAINT finance_payment_methods_status_chk CHECK (status IN ('使用', '禁用'))
);

-- B_PStyle.Number is not a key: legacy ids 6 and 7 both use Number=006.
-- The canonical codes therefore derive from the true legacy primary key.
INSERT INTO settlement_methods
    (id, legacy_id, code, legacy_code, name, status, sort_order, remark)
VALUES
    ('27300000-0000-4000-8100-000000000001',  1, 'BPS-0001', '001', '现金', '使用',  10, NULL),
    ('27300000-0000-4000-8100-000000000002',  2, 'BPS-0002', '002', '提货', '使用',  20, NULL),
    ('27300000-0000-4000-8100-000000000003',  3, 'BPS-0003', '003', '代付', '使用',  30, NULL),
    ('27300000-0000-4000-8100-000000000004',  4, 'BPS-0004', '004', '支票', '使用',  40, NULL),
    ('27300000-0000-4000-8100-000000000006',  6, 'BPS-0006', '006', '月结', '使用',  60, NULL),
    ('27300000-0000-4000-8100-000000000007',  7, 'BPS-0007', '006', '垫付', '使用',  70, '托运部垫付'),
    ('27300000-0000-4000-8100-000000000008',  8, 'BPS-0008', '007', '汇款', '使用',  80, NULL),
    ('27300000-0000-4000-8100-000000000010', 10, 'BPS-0010', '008', '代收', '使用', 100, NULL);

-- RecStyle is a three-row shared receipt/payment dictionary, independent of
-- M_Style/payment_styles. Exact legacy names are overwritten by the bootstrap
-- import from recstyle.csv; placeholders are intentionally explicit for
-- already-migrated installations whose source database is offline.
INSERT INTO finance_payment_methods
    (id, legacy_id, code, name, is_receipt, is_payment,
     legacy_name_confirmed, status, sort_order)
VALUES
    ('27300000-0000-4000-8200-000000000001', 1, 'REC-0001', '旧库收付款方式 1（待同步名称）', TRUE, TRUE, FALSE, '使用', 10),
    ('27300000-0000-4000-8200-000000000002', 2, 'REC-0002', '旧库收付款方式 2（待同步名称）', TRUE, TRUE, FALSE, '使用', 20),
    ('27300000-0000-4000-8200-000000000003', 3, 'REC-0003', '旧库收付款方式 3（待同步名称）', TRUE, TRUE, FALSE, '使用', 30);

ALTER TABLE sales_orders          ADD COLUMN settlement_method_id UUID;
ALTER TABLE sales_shipments       ADD COLUMN settlement_method_id UUID;
ALTER TABLE sales_other_shipments ADD COLUMN settlement_method_id UUID;
ALTER TABLE sales_returns         ADD COLUMN settlement_method_id UUID;
ALTER TABLE purchase_orders       ADD COLUMN settlement_method_id UUID;
ALTER TABLE purchase_receipts     ADD COLUMN settlement_method_id UUID;
ALTER TABLE purchase_returns      ADD COLUMN settlement_method_id UUID;
ALTER TABLE subcontract_receipts  ADD COLUMN settlement_method_id UUID;
ALTER TABLE subcontract_returns   ADD COLUMN settlement_method_id UUID;
ALTER TABLE finance_expenses      ADD COLUMN payment_method_id UUID;
ALTER TABLE finance_expenses      ADD COLUMN payment_method_legacy_id INT;

-- Existing snapshots are mapped only when the old dictionary key is exact.
UPDATE sales_orders d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.payment_style_id;
UPDATE sales_shipments d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.payment_style_id;
UPDATE sales_other_shipments d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.payment_style_id;
UPDATE sales_returns d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.payment_style_id;
UPDATE purchase_orders d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.settlement_style_legacy;
UPDATE purchase_receipts d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.settlement_style_legacy;
UPDATE purchase_returns d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.settlement_style_legacy;
UPDATE subcontract_receipts d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.settlement_style_legacy;
UPDATE subcontract_returns d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.settlement_style_legacy;
UPDATE ar_ap_ledger d SET settlement_type_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.settlement_style_legacy;

-- Replace any pre-V273 experimental method UUID only when the authoritative
-- RecStyle integer snapshot can prove the mapping. Unknown non-null UUIDs fail
-- below instead of being guessed against the unrelated M_Style tree.
UPDATE finance_receipts d SET receipt_method_id = m.id
FROM finance_payment_methods m WHERE m.legacy_id = d.receipt_method_legacy_id;
UPDATE finance_payments d SET payment_method_id = m.id
FROM finance_payment_methods m WHERE m.legacy_id = d.payment_method_legacy_id;
UPDATE finance_other_incomes d SET receipt_method_id = m.id
FROM finance_payment_methods m WHERE m.legacy_id = d.receipt_method_legacy_id;

DO $$
DECLARE broken_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO broken_count
    FROM ar_ap_ledger d
    LEFT JOIN settlement_methods m ON m.id = d.settlement_type_id
    WHERE d.settlement_type_id IS NOT NULL AND m.id IS NULL;
    IF broken_count <> 0 THEN
        RAISE EXCEPTION USING ERRCODE = '23503',
            MESSAGE = format('ar_ap_ledger has %s unprovable pre-V273 settlement UUID values', broken_count);
    END IF;

    SELECT COUNT(*) INTO broken_count
    FROM (
        SELECT receipt_method_id AS method_id FROM finance_receipts
        UNION ALL SELECT payment_method_id FROM finance_payments
        UNION ALL SELECT payment_method_id FROM finance_expenses
        UNION ALL SELECT receipt_method_id FROM finance_other_incomes
    ) d
    LEFT JOIN finance_payment_methods m ON m.id = d.method_id
    WHERE d.method_id IS NOT NULL AND m.id IS NULL;
    IF broken_count <> 0 THEN
        RAISE EXCEPTION USING ERRCODE = '23503',
            MESSAGE = format('finance documents have %s unprovable pre-V273 method UUID values', broken_count);
    END IF;
END
$$;

ALTER TABLE sales_orders ADD CONSTRAINT fk_sales_orders_settlement_method
    FOREIGN KEY (settlement_method_id) REFERENCES settlement_methods(id) ON DELETE RESTRICT;
ALTER TABLE sales_shipments ADD CONSTRAINT fk_sales_shipments_settlement_method
    FOREIGN KEY (settlement_method_id) REFERENCES settlement_methods(id) ON DELETE RESTRICT;
ALTER TABLE sales_other_shipments ADD CONSTRAINT fk_sales_other_shipments_settlement_method
    FOREIGN KEY (settlement_method_id) REFERENCES settlement_methods(id) ON DELETE RESTRICT;
ALTER TABLE sales_returns ADD CONSTRAINT fk_sales_returns_settlement_method
    FOREIGN KEY (settlement_method_id) REFERENCES settlement_methods(id) ON DELETE RESTRICT;
ALTER TABLE purchase_orders ADD CONSTRAINT fk_purchase_orders_settlement_method
    FOREIGN KEY (settlement_method_id) REFERENCES settlement_methods(id) ON DELETE RESTRICT;
ALTER TABLE purchase_receipts ADD CONSTRAINT fk_purchase_receipts_settlement_method
    FOREIGN KEY (settlement_method_id) REFERENCES settlement_methods(id) ON DELETE RESTRICT;
ALTER TABLE purchase_returns ADD CONSTRAINT fk_purchase_returns_settlement_method
    FOREIGN KEY (settlement_method_id) REFERENCES settlement_methods(id) ON DELETE RESTRICT;
ALTER TABLE subcontract_receipts ADD CONSTRAINT fk_subcontract_receipts_settlement_method
    FOREIGN KEY (settlement_method_id) REFERENCES settlement_methods(id) ON DELETE RESTRICT;
ALTER TABLE subcontract_returns ADD CONSTRAINT fk_subcontract_returns_settlement_method
    FOREIGN KEY (settlement_method_id) REFERENCES settlement_methods(id) ON DELETE RESTRICT;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT fk_ar_ap_ledger_settlement_method
    FOREIGN KEY (settlement_type_id) REFERENCES settlement_methods(id) ON DELETE RESTRICT;
ALTER TABLE finance_receipts ADD CONSTRAINT fk_finance_receipts_method
    FOREIGN KEY (receipt_method_id) REFERENCES finance_payment_methods(id) ON DELETE RESTRICT;
ALTER TABLE finance_payments ADD CONSTRAINT fk_finance_payments_method
    FOREIGN KEY (payment_method_id) REFERENCES finance_payment_methods(id) ON DELETE RESTRICT;
ALTER TABLE finance_expenses ADD CONSTRAINT fk_finance_expenses_method
    FOREIGN KEY (payment_method_id) REFERENCES finance_payment_methods(id) ON DELETE RESTRICT;
ALTER TABLE finance_other_incomes ADD CONSTRAINT fk_finance_other_incomes_method
    FOREIGN KEY (receipt_method_id) REFERENCES finance_payment_methods(id) ON DELETE RESTRICT;

CREATE INDEX idx_sales_orders_settlement_method ON sales_orders(settlement_method_id);
CREATE INDEX idx_sales_shipments_settlement_method ON sales_shipments(settlement_method_id);
CREATE INDEX idx_sales_other_shipments_settlement_method ON sales_other_shipments(settlement_method_id);
CREATE INDEX idx_sales_returns_settlement_method ON sales_returns(settlement_method_id);
CREATE INDEX idx_purchase_orders_settlement_method ON purchase_orders(settlement_method_id);
CREATE INDEX idx_purchase_receipts_settlement_method ON purchase_receipts(settlement_method_id);
CREATE INDEX idx_purchase_returns_settlement_method ON purchase_returns(settlement_method_id);
CREATE INDEX idx_subcontract_receipts_settlement_method ON subcontract_receipts(settlement_method_id);
CREATE INDEX idx_subcontract_returns_settlement_method ON subcontract_returns(settlement_method_id);
CREATE INDEX idx_ar_ap_ledger_settlement_method ON ar_ap_ledger(settlement_type_id);
CREATE INDEX idx_finance_receipts_method ON finance_receipts(receipt_method_id);
CREATE INDEX idx_finance_payments_method ON finance_payments(payment_method_id);
CREATE INDEX idx_finance_expenses_method ON finance_expenses(payment_method_id);
CREATE INDEX idx_finance_other_incomes_method ON finance_other_incomes(receipt_method_id);

-- UUID is the write truth. The integer shadow is accepted without a UUID only
-- in an explicitly marked legacy-bootstrap transaction; otherwise old clients
-- must be resolved to a UUID by the service before persistence.
CREATE OR REPLACE FUNCTION fn_sync_settlement_method_reference()
RETURNS TRIGGER AS $$
DECLARE
    uuid_column TEXT := TG_ARGV[0];
    legacy_column TEXT := TG_ARGV[1];
    method_id UUID;
    supplied_legacy INT;
    canonical_legacy INT;
    previous_id UUID;
    previous_legacy INT;
BEGIN
    method_id := NULLIF(to_jsonb(NEW)->>uuid_column, '')::UUID;
    supplied_legacy := NULLIF(to_jsonb(NEW)->>legacy_column, '')::INT;
    IF method_id IS NULL THEN
        IF supplied_legacy IS NOT NULL
           AND COALESCE(current_setting('uten.legacy_reference_import', TRUE), '') = '' THEN
            IF TG_OP = 'UPDATE' THEN
                previous_id := NULLIF(to_jsonb(OLD)->>uuid_column, '')::UUID;
                previous_legacy := NULLIF(to_jsonb(OLD)->>legacy_column, '')::INT;
                IF previous_id IS NULL AND previous_legacy IS NOT DISTINCT FROM supplied_legacy THEN
                    RETURN NEW; -- untouched historical snapshot with no provable UUID mapping
                END IF;
            END IF;
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = TG_TABLE_NAME || '.' || uuid_column || ' is required for a settlement method write';
        END IF;
        RETURN NEW;
    END IF;

    SELECT legacy_id INTO canonical_legacy
    FROM settlement_methods
    WHERE id = method_id AND status = '使用' AND is_deleted = FALSE;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'settlement method UUID is missing, disabled, or deleted';
    END IF;
    IF supplied_legacy IS NOT NULL AND supplied_legacy IS DISTINCT FROM canonical_legacy THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'settlement method UUID conflicts with the legacy snapshot';
    END IF;
    NEW := jsonb_populate_record(NEW, jsonb_build_object(legacy_column, canonical_legacy));
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_sync_finance_payment_method_reference()
RETURNS TRIGGER AS $$
DECLARE
    uuid_column TEXT := TG_ARGV[0];
    legacy_column TEXT := TG_ARGV[1];
    required_direction TEXT := TG_ARGV[2];
    method_id UUID;
    supplied_legacy INT;
    canonical_legacy INT;
    previous_id UUID;
    previous_legacy INT;
BEGIN
    method_id := NULLIF(to_jsonb(NEW)->>uuid_column, '')::UUID;
    supplied_legacy := NULLIF(to_jsonb(NEW)->>legacy_column, '')::INT;
    IF method_id IS NULL THEN
        IF supplied_legacy IS NOT NULL
           AND COALESCE(current_setting('uten.legacy_reference_import', TRUE), '') = '' THEN
            IF TG_OP = 'UPDATE' THEN
                previous_id := NULLIF(to_jsonb(OLD)->>uuid_column, '')::UUID;
                previous_legacy := NULLIF(to_jsonb(OLD)->>legacy_column, '')::INT;
                IF previous_id IS NULL AND previous_legacy IS NOT DISTINCT FROM supplied_legacy THEN
                    RETURN NEW; -- untouched historical snapshot with no confirmed UUID mapping
                END IF;
            END IF;
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = TG_TABLE_NAME || '.' || uuid_column || ' is required for a finance method write';
        END IF;
        RETURN NEW;
    END IF;

    SELECT legacy_id INTO canonical_legacy
    FROM finance_payment_methods
    WHERE id = method_id
      AND status = '使用'
      AND is_deleted = FALSE
      AND (legacy_name_confirmed
           OR COALESCE(current_setting('uten.legacy_reference_import', TRUE), '') <> '')
      AND (required_direction <> 'RECEIPT' OR is_receipt)
      AND (required_direction <> 'PAYMENT' OR is_payment);
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'finance method UUID is missing, disabled, deleted, or invalid for this direction';
    END IF;
    IF supplied_legacy IS NOT NULL AND supplied_legacy IS DISTINCT FROM canonical_legacy THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'finance method UUID conflicts with the legacy snapshot';
    END IF;
    NEW := jsonb_populate_record(NEW, jsonb_build_object(legacy_column, canonical_legacy));
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_settlement_ref_sales_orders
    BEFORE INSERT OR UPDATE OF settlement_method_id, payment_style_id ON sales_orders
    FOR EACH ROW EXECUTE FUNCTION fn_sync_settlement_method_reference('settlement_method_id', 'payment_style_id');
CREATE TRIGGER trg_settlement_ref_sales_shipments
    BEFORE INSERT OR UPDATE OF settlement_method_id, payment_style_id ON sales_shipments
    FOR EACH ROW EXECUTE FUNCTION fn_sync_settlement_method_reference('settlement_method_id', 'payment_style_id');
CREATE TRIGGER trg_settlement_ref_sales_other_shipments
    BEFORE INSERT OR UPDATE OF settlement_method_id, payment_style_id ON sales_other_shipments
    FOR EACH ROW EXECUTE FUNCTION fn_sync_settlement_method_reference('settlement_method_id', 'payment_style_id');
CREATE TRIGGER trg_settlement_ref_sales_returns
    BEFORE INSERT OR UPDATE OF settlement_method_id, payment_style_id ON sales_returns
    FOR EACH ROW EXECUTE FUNCTION fn_sync_settlement_method_reference('settlement_method_id', 'payment_style_id');
CREATE TRIGGER trg_settlement_ref_purchase_orders
    BEFORE INSERT OR UPDATE OF settlement_method_id, settlement_style_legacy ON purchase_orders
    FOR EACH ROW EXECUTE FUNCTION fn_sync_settlement_method_reference('settlement_method_id', 'settlement_style_legacy');
CREATE TRIGGER trg_settlement_ref_purchase_receipts
    BEFORE INSERT OR UPDATE OF settlement_method_id, settlement_style_legacy ON purchase_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_sync_settlement_method_reference('settlement_method_id', 'settlement_style_legacy');
CREATE TRIGGER trg_settlement_ref_purchase_returns
    BEFORE INSERT OR UPDATE OF settlement_method_id, settlement_style_legacy ON purchase_returns
    FOR EACH ROW EXECUTE FUNCTION fn_sync_settlement_method_reference('settlement_method_id', 'settlement_style_legacy');
CREATE TRIGGER trg_settlement_ref_subcontract_receipts
    BEFORE INSERT OR UPDATE OF settlement_method_id, settlement_style_legacy ON subcontract_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_sync_settlement_method_reference('settlement_method_id', 'settlement_style_legacy');
CREATE TRIGGER trg_settlement_ref_subcontract_returns
    BEFORE INSERT OR UPDATE OF settlement_method_id, settlement_style_legacy ON subcontract_returns
    FOR EACH ROW EXECUTE FUNCTION fn_sync_settlement_method_reference('settlement_method_id', 'settlement_style_legacy');
CREATE TRIGGER trg_settlement_ref_ar_ap_ledger
    BEFORE INSERT OR UPDATE OF settlement_type_id, settlement_style_legacy ON ar_ap_ledger
    FOR EACH ROW EXECUTE FUNCTION fn_sync_settlement_method_reference('settlement_type_id', 'settlement_style_legacy');

CREATE TRIGGER trg_finance_method_ref_receipts
    BEFORE INSERT OR UPDATE OF receipt_method_id, receipt_method_legacy_id ON finance_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_sync_finance_payment_method_reference('receipt_method_id', 'receipt_method_legacy_id', 'RECEIPT');
CREATE TRIGGER trg_finance_method_ref_payments
    BEFORE INSERT OR UPDATE OF payment_method_id, payment_method_legacy_id ON finance_payments
    FOR EACH ROW EXECUTE FUNCTION fn_sync_finance_payment_method_reference('payment_method_id', 'payment_method_legacy_id', 'PAYMENT');
CREATE TRIGGER trg_finance_method_ref_expenses
    BEFORE INSERT OR UPDATE OF payment_method_id, payment_method_legacy_id ON finance_expenses
    FOR EACH ROW EXECUTE FUNCTION fn_sync_finance_payment_method_reference('payment_method_id', 'payment_method_legacy_id', 'PAYMENT');
CREATE TRIGGER trg_finance_method_ref_other_incomes
    BEFORE INSERT OR UPDATE OF receipt_method_id, receipt_method_legacy_id ON finance_other_incomes
    FOR EACH ROW EXECUTE FUNCTION fn_sync_finance_payment_method_reference('receipt_method_id', 'receipt_method_legacy_id', 'RECEIPT');

CREATE TRIGGER trg_audit_settlement_methods
    AFTER INSERT OR UPDATE OR DELETE ON settlement_methods
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_payment_methods
    AFTER INSERT OR UPDATE OR DELETE ON finance_payment_methods
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE settlement_methods IS
    'Stable UUID master for legacy B_PStyle; integer document fields are snapshots only.';
COMMENT ON TABLE finance_payment_methods IS
    'Stable UUID master for legacy RecStyle shared by receipt and payment documents; independent of payment_styles.';
COMMENT ON COLUMN settlement_methods.legacy_code IS
    'Legacy B_PStyle.Number snapshot; not unique (legacy ids 6 and 7 both used 006).';
COMMENT ON COLUMN finance_payment_methods.legacy_name_confirmed IS
    'True only after the exact RecStyle.Name has been imported from the legacy dictionary.';
