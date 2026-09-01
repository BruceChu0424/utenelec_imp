-- V443: all-customer shipment finance release, client payment labels and
-- receivable credit-floor authority.
--
-- No historical shipment is fabricated as finance-approved. Existing
-- in-progress/terminal shipments retain gate version 0; every draft still at
-- PENDING_PICK uses version 1 regardless of legacy identity and must carry a
-- real finance audit before any physical warehouse state.

-- ======================== client payment label ========================

ALTER TABLE clients
    ADD COLUMN sales_payment_type VARCHAR(20);

ALTER TABLE clients
    ADD CONSTRAINT clients_sales_payment_type_chk CHECK (
        sales_payment_type IS NULL
        OR sales_payment_type IN ('MONTHLY', 'CASH', 'DEPOSIT'));

-- V330 already establishes the deterministic MONTHLY system role under its
-- controlled maintenance window. V443 consumes that immutable authority, so
-- fail fast on dependency drift rather than repeating the role mutation or
-- rediscovering it from a mutable Chinese name/legacy code.
DO $$
BEGIN
    IF (SELECT count(*) FROM settlement_methods WHERE system_role = 'MONTHLY') <> 1
       OR NOT EXISTS (
           SELECT 1
           FROM settlement_methods
           WHERE id = '27300000-0000-4000-8100-000000000006'::UUID
             AND legacy_id = 6
             AND system_role = 'MONTHLY'
             AND status = '使用'
             AND COALESCE(is_deleted, FALSE) = FALSE
       ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'V443 cannot verify the unique active MONTHLY settlement UUID role';
    END IF;
END
$$;

-- Only immutable system roles are safe to infer.  Do not guess DEPOSIT from
-- legacy order.deposit or customer prepayments: both are order/payment facts,
-- not a durable customer classification.
UPDATE clients client
SET sales_payment_type = CASE method.system_role
        WHEN 'CASH' THEN 'CASH'
        WHEN 'MONTHLY' THEN 'MONTHLY'
    END
FROM settlement_methods method
WHERE method.id = client.default_settlement_method_id
  AND method.system_role IN ('CASH', 'MONTHLY')
  AND method.status = '使用'
  AND COALESCE(method.is_deleted, FALSE) = FALSE
  AND client.sales_payment_type IS NULL;

CREATE INDEX idx_clients_sales_payment_type
    ON clients(sales_payment_type, code)
    WHERE COALESCE(is_deleted, FALSE) = FALSE;

CREATE VIEW v_client_sales_payment_type_migration_issues AS
SELECT client.id AS client_id,
       client.legacy_id,
       client.price_style AS legacy_price_style,
       client.default_settlement_method_id,
       method.system_role AS settlement_system_role,
       CASE
           WHEN client.default_settlement_method_id IS NULL
               THEN 'MISSING_SETTLEMENT_UUID'
           WHEN method.id IS NULL
               THEN 'INVALID_SETTLEMENT_UUID'
           ELSE 'REQUIRES_MANUAL_CLASSIFICATION'
       END AS issue_code
FROM clients client
LEFT JOIN settlement_methods method
  ON method.id = client.default_settlement_method_id
WHERE COALESCE(client.is_deleted, FALSE) = FALSE
  AND client.sales_payment_type IS NULL;

COMMENT ON COLUMN clients.sales_payment_type IS
    'Manual customer label MONTHLY/CASH/DEPOSIT; informational only and never proof of receipt or permission to bypass shipment finance review.';
COMMENT ON VIEW v_client_sales_payment_type_migration_issues IS
    'Non-deleted clients whose three-way sales payment label cannot be safely inferred and requires staff classification.';

-- ======================== credit floor ========================

-- The legacy B_Client.Credit values are the amounts shown as credit floor in
-- the supplied legacy receivable report.  Preserve an already-maintained
-- credit_floor, otherwise copy that source only for legacy-linked clients.
UPDATE clients
SET credit_floor = COALESCE(credit_floor, credit, 0)
WHERE legacy_id IS NOT NULL
  AND credit_floor IS NULL;

UPDATE clients
SET credit_floor = 0
WHERE credit_floor IS NULL;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM clients WHERE credit_floor < 0) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'V443 cannot establish non-negative client credit floors';
    END IF;
END
$$;

ALTER TABLE clients
    ALTER COLUMN credit_floor SET DEFAULT 0,
    ALTER COLUMN credit_floor SET NOT NULL;

ALTER TABLE clients
    ADD CONSTRAINT clients_credit_floor_nonnegative_chk
        CHECK (credit_floor >= 0);

COMMENT ON COLUMN clients.credit_floor IS
    'Customer credit floor; defaults to zero. Receivable display after floor is full AR balance minus this amount and may be negative.';

-- Existing rows may remain unclassified until the migration issue queue is
-- signed off. New online rows (legacy_id IS NULL) must not create more
-- unclassified customers; legacy bootstrap imports retain their explicit
-- reconciliation path. Add this only after V443's own client backfills:
-- NOT VALID avoids scanning/fabricating existing online values, but PostgreSQL
-- still enforces it for every later INSERT or UPDATE.
ALTER TABLE clients
    ADD CONSTRAINT clients_online_sales_payment_type_required_chk CHECK (
        legacy_id IS NOT NULL OR sales_payment_type IS NOT NULL
    ) NOT VALID;

-- Dedicated permission-setting surfaces expose only each page's effective
-- action. They do not create permissions or grant anything to a department,
-- role or user.
INSERT INTO permission_surfaces
    (id, surface_key, name, sort_order, enabled)
VALUES
    ('44300000-0000-4000-8000-000000000001',
     'finance.sales-shipment-audit', '销售发货财务审核', 86, TRUE),
    ('44300000-0000-4000-8000-000000000002',
     'warehouse.sales-outbound', '销售出库任务', 70, TRUE)
ON CONFLICT (surface_key) DO UPDATE
SET name = EXCLUDED.name,
    sort_order = EXCLUDED.sort_order,
    enabled = TRUE;

WITH mapping(surface_key, permission_code) AS (VALUES
    ('finance.sales-shipment-audit', 'finance_shipment_audit'),
    ('warehouse.sales-outbound', 'sales_shipment:warehouse-work')
)
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM mapping
JOIN permission_surfaces surface
  ON surface.surface_key = mapping.surface_key
JOIN permissions permission
  ON permission.code = mapping.permission_code
ON CONFLICT (surface_id, permission_id) DO NOTHING;

DO $$
BEGIN
    IF (
        SELECT count(*)
        FROM permission_surface_permissions link
        JOIN permission_surfaces surface ON surface.id = link.surface_id
        JOIN permissions permission ON permission.id = link.permission_id
        WHERE (surface.id, surface.surface_key, permission.code) IN (
            ('44300000-0000-4000-8000-000000000001'::UUID,
             'finance.sales-shipment-audit', 'finance_shipment_audit'),
            ('44300000-0000-4000-8000-000000000002'::UUID,
             'warehouse.sales-outbound', 'sales_shipment:warehouse-work'))
    ) <> 2 OR EXISTS (
        SELECT 1
        FROM permission_surface_permissions link
        JOIN permission_surfaces surface ON surface.id = link.surface_id
        JOIN permissions permission ON permission.id = link.permission_id
        WHERE surface.surface_key IN (
            'finance.sales-shipment-audit', 'warehouse.sales-outbound')
          AND (surface.surface_key, permission.code) NOT IN (
            ('finance.sales-shipment-audit', 'finance_shipment_audit'),
            ('warehouse.sales-outbound', 'sales_shipment:warehouse-work'))
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'V443 sales shipment permission surfaces are incomplete or over-broad';
    END IF;
END
$$;

-- ======================== shipment finance gate ========================

ALTER TABLE sales_shipments
    ADD COLUMN finance_gate_version SMALLINT NOT NULL DEFAULT 1;

-- Preserve unknown historical facts without inventing an auditor.  Drafts
-- that have not started physical work are deliberately upgraded to V1 so they
-- must be manually reviewed before picking.
UPDATE sales_shipments
SET finance_gate_version = 0
WHERE status <> 0
   OR warehouse_work_status IS DISTINCT FROM 'PENDING_PICK';

ALTER TABLE sales_shipments
    ADD CONSTRAINT sales_shipments_finance_gate_version_chk
        CHECK (finance_gate_version IN (0, 1));

ALTER TABLE sales_shipments
    ADD CONSTRAINT sales_shipments_v1_finance_fact_chk CHECK (
        finance_gate_version = 0
        OR (finance_audit = 0
            AND finance_auditor_id IS NULL
            AND finance_audited_at IS NULL)
        OR (finance_audit = 1
            AND finance_auditor_id IS NOT NULL
            AND finance_audited_at IS NOT NULL)
    ) NOT VALID;

ALTER TABLE sales_shipments
    VALIDATE CONSTRAINT sales_shipments_v1_finance_fact_chk;

ALTER TABLE sales_shipments
    ADD CONSTRAINT sales_shipments_v1_shipped_terminal_chk CHECK (
        finance_gate_version = 0
        OR status <> 1
        OR (finance_audit = 1 AND warehouse_work_status = 'SHIPPED')
    ) NOT VALID;

ALTER TABLE sales_shipments
    VALIDATE CONSTRAINT sales_shipments_v1_shipped_terminal_chk;

CREATE OR REPLACE FUNCTION fn_guard_sales_shipment_finance_release()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'UPDATE'
       AND OLD.finance_gate_version = 0
       AND OLD.status = 0
       AND OLD.warehouse_work_status = 'LEGACY_PENDING'
       AND (NEW.status IS DISTINCT FROM OLD.status
            OR NEW.finance_gate_version IS DISTINCT FROM OLD.finance_gate_version
            OR NEW.finance_audit IS DISTINCT FROM OLD.finance_audit
            OR NEW.finance_auditor_id IS DISTINCT FROM OLD.finance_auditor_id
            OR NEW.finance_audited_at IS DISTINCT FROM OLD.finance_audited_at
            OR NEW.warehouse_work_status IS DISTINCT FROM OLD.warehouse_work_status) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'legacy pending sales shipment is read-only and must be manually rebuilt';
    END IF;

    IF TG_OP = 'INSERT'
       AND NEW.finance_gate_version = 0
       AND COALESCE(current_setting('uten.legacy_reference_import', TRUE), '') = '' THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'new sales shipments must use finance gate version 1';
    END IF;

    IF TG_OP = 'UPDATE'
       AND OLD.finance_gate_version = 1
       AND NEW.finance_gate_version IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'sales shipment finance gate version cannot be downgraded';
    END IF;

    IF NEW.finance_gate_version = 1 THEN
        IF NEW.finance_audit NOT IN (0, 1)
           OR (NEW.finance_audit = 0
               AND (NEW.finance_auditor_id IS NOT NULL
                    OR NEW.finance_audited_at IS NOT NULL))
           OR (NEW.finance_audit = 1
               AND (NEW.finance_auditor_id IS NULL
                    OR NEW.finance_audited_at IS NULL)) THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'sales shipment finance audit facts are incomplete';
        END IF;

        IF NEW.warehouse_work_status IN ('PICKING', 'PICKED', 'SHIPPED')
           AND NEW.finance_audit <> 1 THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'finance approval is required before warehouse picking or shipment';
        END IF;
    END IF;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_sales_shipment_finance_release
    BEFORE INSERT OR UPDATE OF status, finance_gate_version, finance_audit,
        finance_auditor_id, finance_audited_at, warehouse_work_status
    ON sales_shipments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_shipment_finance_release();

CREATE INDEX idx_sales_shipments_finance_release_pending
    ON sales_shipments(finance_audit, bill_date, id)
    WHERE status = 0
      AND COALESCE(is_deleted, FALSE) = FALSE
      AND COALESCE(rejected, FALSE) = FALSE
      AND finance_gate_version = 1
      AND warehouse_work_status = 'PENDING_PICK';

CREATE VIEW v_sales_shipment_finance_gate_migration_exceptions AS
SELECT id AS shipment_id,
       legacy_id,
       bill_no,
       status,
       warehouse_work_status,
       finance_audit,
       finance_gate_version
FROM sales_shipments
WHERE COALESCE(is_deleted, FALSE) = FALSE
  AND finance_gate_version = 0
  AND status = 0
  AND warehouse_work_status IN (
      'LEGACY_PENDING', 'PENDING_PICK', 'PICKING', 'PICKED', 'EXCEPTION');

COMMENT ON COLUMN sales_shipments.finance_gate_version IS
    '0=historical compatibility without fabricated approval; 1=all customers require finance release before physical warehouse work.';
COMMENT ON VIEW v_sales_shipment_finance_gate_migration_exceptions IS
    'Non-deleted historical drafts with unknown finance-release facts; LEGACY_PENDING is read-only and must be manually rebuilt into the current order-linked workflow.';

-- ======================== finance release event ledger ========================

CREATE TABLE sales_shipment_finance_release_events (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id                     UUID NOT NULL REFERENCES sales_shipments(id) ON DELETE RESTRICT,
    event_type                      VARCHAR(20) NOT NULL,
    actor_user_id                   UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    occurred_at                     TIMESTAMPTZ NOT NULL,
    client_id                       UUID NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
    client_name                     TEXT NOT NULL,
    currency_id                     UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    sales_payment_type              VARCHAR(20),
    settlement_method_id            UUID REFERENCES settlement_methods(id) ON DELETE RESTRICT,
    shipment_total_original         NUMERIC(18,4) NOT NULL,
    formal_ar_outstanding_local     NUMERIC(18,4) NOT NULL,
    credit_floor_local              NUMERIC(18,4) NOT NULL,
    over_floor_local                NUMERIC(18,4) NOT NULL,
    available_prepayment_original   NUMERIC(18,4) NOT NULL,
    available_prepayment_local      NUMERIC(18,4) NOT NULL,
    CONSTRAINT sales_shipment_finance_release_event_type_chk
        CHECK (event_type IN ('RELEASED', 'REVOKED')),
    CONSTRAINT sales_shipment_finance_release_event_payment_type_chk
        CHECK (sales_payment_type IS NULL
               OR sales_payment_type IN ('MONTHLY', 'CASH', 'DEPOSIT')),
    CONSTRAINT sales_shipment_finance_release_event_released_type_chk
        CHECK (event_type <> 'RELEASED' OR sales_payment_type IS NOT NULL),
    CONSTRAINT sales_shipment_finance_release_event_money_chk CHECK (
        shipment_total_original >= 0
        AND credit_floor_local >= 0
        AND available_prepayment_original >= 0
        AND available_prepayment_local >= 0
        AND over_floor_local = formal_ar_outstanding_local - credit_floor_local)
);

CREATE INDEX idx_sales_shipment_finance_release_events_shipment
    ON sales_shipment_finance_release_events(shipment_id, occurred_at, id);

CREATE OR REPLACE FUNCTION fn_guard_sales_shipment_finance_release_event_append_only()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION USING ERRCODE = '23514',
        MESSAGE = 'sales shipment finance release events are append-only';
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_sales_shipment_finance_release_event_append_only
    BEFORE UPDATE OR DELETE ON sales_shipment_finance_release_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_shipment_finance_release_event_append_only();

ALTER TABLE sales_shipment_finance_release_events
    ENABLE ALWAYS TRIGGER trg_guard_sales_shipment_finance_release_event_append_only;

CREATE TRIGGER trg_audit_sales_shipment_finance_release_events
    AFTER INSERT OR UPDATE OR DELETE ON sales_shipment_finance_release_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE sales_shipment_finance_release_events IS
    'Append-only RELEASED/REVOKED decision snapshots; historical shipments are not backfilled.';
