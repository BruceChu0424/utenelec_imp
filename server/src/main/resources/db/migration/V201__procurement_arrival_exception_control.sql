-- V201: fail-closed control for procurement arrivals above the financially
-- approved order capacity.
--
-- A warehouse receipt remains a draft while an exception is open.  The
-- exception is assigned to the configured eligible finance reviewer. Any
-- quantity which finance does not accept becomes a durable supplier-return
-- task for the original active order-maker account. Approval never posts
-- inventory or AP by itself; warehouse must re-approve the adjusted receipt.

ALTER TABLE purchase_order_items
    ADD COLUMN arrival_overage_posted_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (arrival_overage_posted_qty >= 0);
ALTER TABLE subcontract_order_items
    ADD COLUMN arrival_overage_posted_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (arrival_overage_posted_qty >= 0);

CREATE TABLE procurement_arrival_exceptions (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_type                      TEXT NOT NULL CHECK (order_type IN ('PURCHASE', 'SUBCONTRACT')),
    receipt_id                      UUID NOT NULL,
    receipt_item_id                 UUID NOT NULL,
    receipt_bill_no_snapshot        TEXT NOT NULL,
    order_id                        UUID NOT NULL,
    order_item_id                   UUID NOT NULL,
    order_bill_no_snapshot          TEXT NOT NULL,
    expectation_id                  UUID REFERENCES inbound_expectations(id) ON DELETE RESTRICT,
    expectation_item_id             UUID REFERENCES inbound_expectation_items(id) ON DELETE RESTRICT,
    supplier_id                     UUID REFERENCES suppliers(id) ON DELETE RESTRICT,
    warehouse_id                    UUID REFERENCES warehouses(id) ON DELETE RESTRICT,
    goods_id                        UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    color_id                        UUID REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id                         UUID REFERENCES units(id) ON DELETE RESTRICT,
    declared_qty                    NUMERIC(18,4) NOT NULL CHECK (declared_qty > 0),
    unit_price_snapshot             NUMERIC(18,4),
    declared_amount_original_snapshot NUMERIC(18,4),
    declared_amount_local_snapshot  NUMERIC(18,4),
    excess_amount_local_snapshot    NUMERIC(18,4),
    approved_remaining_qty          NUMERIC(18,4) NOT NULL CHECK (approved_remaining_qty >= 0),
    approved_excess_qty             NUMERIC(18,4) CHECK (approved_excess_qty >= 0),
    accepted_qty                    NUMERIC(18,4) CHECK (accepted_qty >= 0),
    unaccepted_qty                  NUMERIC(18,4) CHECK (unaccepted_qty >= 0),
    owner_user_id                   UUID REFERENCES users(id) ON DELETE RESTRICT,
    owner_employee_id               UUID REFERENCES employees(id) ON DELETE RESTRICT,
    owner_name_snapshot             TEXT,
    finance_assignee_user_id        UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    finance_assignee_employee_id    UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    finance_assignee_name_snapshot  TEXT NOT NULL,
    status                          TEXT NOT NULL CHECK (status IN (
        'PENDING_FINANCE', 'RECEIPT_ADJUSTED', 'RETURN_REQUIRED',
        'RECEIPT_POSTED', 'CLOSED', 'CANCELED'
    )),
    decision                        TEXT CHECK (decision IN (
        'APPROVE_ALL', 'APPROVE_CUSTOM', 'REJECT_EXCESS'
    )),
    finance_reason                  TEXT CHECK (char_length(finance_reason) <= 1000),
    version                         BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    detected_by_user_id             UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    detected_by_employee_id         UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    decided_by_user_id              UUID REFERENCES users(id) ON DELETE RESTRICT,
    decided_by_employee_id          UUID REFERENCES employees(id) ON DELETE RESTRICT,
    detected_at                     TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_at                      TIMESTAMPTZ,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (order_type, receipt_item_id),
    CHECK (approved_excess_qty IS NULL
           OR approved_excess_qty
              <= GREATEST(declared_qty - approved_remaining_qty, 0)),
    CHECK (accepted_qty IS NULL OR accepted_qty <= declared_qty),
    CHECK (unaccepted_qty IS NULL OR unaccepted_qty <= declared_qty),
    CHECK (accepted_qty IS NULL OR unaccepted_qty IS NULL
           OR accepted_qty + unaccepted_qty = declared_qty),
    CHECK (decision IS NULL OR (
        approved_excess_qty IS NOT NULL
        AND accepted_qty = LEAST(
            declared_qty,
            approved_remaining_qty + approved_excess_qty)
        AND (
            (decision = 'APPROVE_ALL'
             AND approved_excess_qty =
                 GREATEST(declared_qty - approved_remaining_qty, 0))
            OR
            (decision = 'APPROVE_CUSTOM'
             AND approved_excess_qty > 0
             AND approved_excess_qty
                 < GREATEST(declared_qty - approved_remaining_qty, 0))
            OR
            (decision = 'REJECT_EXCESS' AND approved_excess_qty = 0)
        )
    )),
    CHECK (decision IS NULL OR decision = 'REJECT_EXCESS'
           OR NULLIF(btrim(finance_reason), '') IS NOT NULL),
    CHECK ((decision IS NULL) = (decided_at IS NULL)),
    CHECK ((decision IS NULL) = (decided_by_user_id IS NULL)),
    CHECK ((decision IS NULL) = (decided_by_employee_id IS NULL))
);

CREATE INDEX idx_procurement_arrival_exception_finance
    ON procurement_arrival_exceptions(finance_assignee_user_id, status, detected_at, id);
CREATE INDEX idx_procurement_arrival_exception_owner
    ON procurement_arrival_exceptions(owner_user_id, status, detected_at, id);
CREATE INDEX idx_procurement_arrival_exception_warehouse
    ON procurement_arrival_exceptions(warehouse_id, status, detected_at, id);
CREATE INDEX idx_procurement_arrival_exception_receipt
    ON procurement_arrival_exceptions(order_type, receipt_id, receipt_item_id);

CREATE TABLE supplier_return_tasks (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    arrival_exception_id            UUID NOT NULL UNIQUE
                                    REFERENCES procurement_arrival_exceptions(id) ON DELETE RESTRICT,
    order_type                      TEXT NOT NULL CHECK (order_type IN ('PURCHASE', 'SUBCONTRACT')),
    order_id                        UUID NOT NULL,
    order_item_id                   UUID NOT NULL,
    receipt_id                      UUID NOT NULL,
    receipt_item_id                 UUID NOT NULL,
    owner_user_id                   UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    owner_employee_id               UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    qty                             NUMERIC(18,4) NOT NULL CHECK (qty > 0),
    status                          TEXT NOT NULL CHECK (status IN (
        'PENDING_RETURN', 'COMPLETED', 'CANCELED'
    )),
    completion_note                 TEXT,
    version                         BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at                    TIMESTAMPTZ,
    completed_by_user_id            UUID REFERENCES users(id) ON DELETE RESTRICT,
    completed_by_employee_id        UUID REFERENCES employees(id) ON DELETE RESTRICT,
    CHECK ((status = 'COMPLETED') = (completed_at IS NOT NULL)),
    CHECK ((status = 'COMPLETED') = (completed_by_user_id IS NOT NULL)),
    CHECK ((status = 'COMPLETED') = (completed_by_employee_id IS NOT NULL))
);

CREATE INDEX idx_supplier_return_task_owner
    ON supplier_return_tasks(owner_user_id, status, created_at, id);

CREATE TABLE procurement_arrival_exception_events (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    arrival_exception_id            UUID NOT NULL
                                    REFERENCES procurement_arrival_exceptions(id) ON DELETE RESTRICT,
    event_type                      TEXT NOT NULL CHECK (event_type IN (
        'DETECTED', 'REDETECTED', 'FINANCE_DECIDED',
        'RECEIPT_POSTED', 'RECEIPT_REVERSED', 'RETURN_COMPLETED'
    )),
    actor_user_id                   UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    actor_employee_id               UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    event_snapshot                  JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_procurement_arrival_exception_event
    ON procurement_arrival_exception_events(arrival_exception_id, created_at, id);

CREATE OR REPLACE FUNCTION fn_reject_procurement_arrival_event_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'procurement_arrival_exception_events is append-only'
        USING ERRCODE = '55000';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_procurement_arrival_events_append_only
BEFORE UPDATE OR DELETE ON procurement_arrival_exception_events
FOR EACH ROW EXECUTE FUNCTION fn_reject_procurement_arrival_event_mutation();

-- Once the approval attempt has produced a finance task, warehouse users may
-- not edit/delete that receipt line to bypass finance review. The controlled
-- finance decision sets this transaction-local flag before it narrows or
-- removes the draft line.
CREATE OR REPLACE FUNCTION fn_guard_arrival_exception_receipt_item_mutation()
RETURNS TRIGGER AS $$
DECLARE
    v_item_id UUID := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;
BEGIN
    IF current_setting('app.procurement_arrival_decision', TRUE) = 'on' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'UPDATE'
       AND (to_jsonb(NEW) - ARRAY['returned_qty', 'updated_at'])
           IS NOT DISTINCT FROM
           (to_jsonb(OLD) - ARRAY['returned_qty', 'updated_at']) THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM procurement_arrival_exceptions exception
        WHERE exception.order_type = TG_ARGV[0]
          AND exception.receipt_item_id = v_item_id
          AND exception.status NOT IN ('CLOSED', 'CANCELED')
    ) THEN
        RAISE EXCEPTION 'arrival exception must be decided by its assigned finance reviewer'
            USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_purchase_receipt_item_arrival_decision
BEFORE UPDATE OR DELETE ON purchase_receipt_items
FOR EACH ROW EXECUTE FUNCTION fn_guard_arrival_exception_receipt_item_mutation('PURCHASE');

CREATE TRIGGER trg_subcontract_receipt_item_arrival_decision
BEFORE UPDATE OR DELETE ON subcontract_receipt_items
FOR EACH ROW EXECUTE FUNCTION fn_guard_arrival_exception_receipt_item_mutation('SUBCONTRACT');

CREATE OR REPLACE FUNCTION fn_guard_arrival_exception_receipt_mutation()
RETURNS TRIGGER AS $$
DECLARE
    v_receipt_id UUID := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;
BEGIN
    IF current_setting('app.procurement_arrival_decision', TRUE) = 'on' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'UPDATE'
       AND (to_jsonb(NEW) - ARRAY[
            'status', 'approver_id', 'ap_posted', 'is_closed',
            'updated_at', 'updated_by'])
           IS NOT DISTINCT FROM
           (to_jsonb(OLD) - ARRAY[
            'status', 'approver_id', 'ap_posted', 'is_closed',
            'updated_at', 'updated_by']) THEN
        RETURN NEW;
    END IF;
    IF EXISTS (
        SELECT 1 FROM procurement_arrival_exceptions exception
        WHERE exception.order_type = TG_ARGV[0]
          AND exception.receipt_id = v_receipt_id
          AND exception.status NOT IN ('CLOSED', 'CANCELED')
    ) THEN
        RAISE EXCEPTION 'receipt with an open arrival exception cannot be deleted'
            USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_purchase_receipt_arrival_decision
BEFORE UPDATE OR DELETE ON purchase_receipts
FOR EACH ROW EXECUTE FUNCTION fn_guard_arrival_exception_receipt_mutation('PURCHASE');
CREATE TRIGGER trg_subcontract_receipt_arrival_decision
BEFORE UPDATE OR DELETE ON subcontract_receipts
FOR EACH ROW EXECUTE FUNCTION fn_guard_arrival_exception_receipt_mutation('SUBCONTRACT');

-- V132 stays immutable. Replace only its two received-capacity triggers so a
-- receipt may use posted allowance plus its own receipt-bound finance decision.
CREATE OR REPLACE FUNCTION fn_guard_procurement_received_with_arrival_allowance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_old_received NUMERIC;
    v_new_received NUMERIC := COALESCE(NEW.received_qty, 0);
    v_capacity NUMERIC := COALESCE(NEW.qty, 0)
        + COALESCE(NEW.returned_qty, 0)
        + COALESCE(NEW.arrival_overage_posted_qty, 0);
    v_current_receipt TEXT := current_setting('app.procurement_arrival_receipt_id', TRUE);
    v_current_type TEXT := current_setting('app.procurement_arrival_order_type', TRUE);
    v_receipt_extra NUMERIC := 0;
BEGIN
    v_old_received := CASE WHEN TG_OP = 'INSERT' THEN 0
                           ELSE COALESCE(OLD.received_qty, 0) END;
    IF v_new_received < 0 THEN
        RAISE EXCEPTION 'received_qty cannot be negative'
            USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
    END IF;
    IF v_current_receipt IS NOT NULL AND v_current_receipt <> ''
       AND v_current_type = TG_ARGV[0] THEN
        SELECT COALESCE(SUM(exception.approved_excess_qty), 0)
        INTO v_receipt_extra
        FROM procurement_arrival_exceptions exception
        WHERE exception.order_type = TG_ARGV[0]
          AND exception.receipt_id = v_current_receipt::UUID
          AND exception.order_item_id = NEW.id
          AND exception.status = 'RECEIPT_ADJUSTED';
    END IF;
    IF v_new_received > v_old_received
       AND v_new_received > v_capacity + v_receipt_extra THEN
        RAISE EXCEPTION 'received_qty exceeds finance-approved arrival capacity'
            USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER trg_purchase_order_received_guard ON purchase_order_items;
CREATE TRIGGER trg_purchase_order_received_guard
    BEFORE INSERT OR UPDATE OF received_qty ON purchase_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_received_with_arrival_allowance('PURCHASE');
DROP TRIGGER trg_subcontract_order_received_guard ON subcontract_order_items;
CREATE TRIGGER trg_subcontract_order_received_guard
    BEFORE INSERT OR UPDATE OF received_qty ON subcontract_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_received_with_arrival_allowance('SUBCONTRACT');

INSERT INTO permissions(code, name, category, sort_order) VALUES
    ('supplier_return_task:handle', '处理本人供应商退回任务', '采购管理', 127)
ON CONFLICT (code) DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission
  ON permission.code = 'supplier_return_task:handle'
WHERE department.code IN ('SUB_PURCHASE', 'DEPT_SALES')
  AND department.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- Physical subcontract receipt entry is warehouse-owned. The subcontract
-- department keeps read access but cannot create, edit, approve, or reverse it.
DELETE FROM department_permissions assignment
USING permissions permission, departments department
WHERE assignment.permission_id = permission.id
  AND assignment.department_id = department.id
  AND permission.code = 'subcontract_receipt:edit'
  AND department.code = 'DEPT_SALES';

-- Warehouse owns physical receipt entry for both approved order types.  It
-- receives only the dedicated inbound projection; full subcontract-order read
-- permission is intentionally not granted here.
INSERT INTO department_permissions(department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission
  ON permission.code IN ('subcontract_receipt:view', 'subcontract_receipt:edit')
WHERE department.code = 'SUB_WH'
  AND department.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- Finance task cards navigate to the existing read-only order details. Finance
-- receives view only; exact-assignee checks still protect every decision.
INSERT INTO department_permissions(department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission
  ON permission.code IN ('purchase_order:view', 'subcontract_order:view')
WHERE department.code = 'DEPT_FIN'
  AND department.is_deleted = FALSE
ON CONFLICT DO NOTHING;

COMMENT ON TABLE procurement_arrival_exceptions IS
    'Over-arrival finance task; open rows block receipt posting until the exact assigned finance reviewer decides.';
COMMENT ON TABLE supplier_return_tasks IS
    'Durable exact-owner work for quantities which finance did not accept into stock.';
COMMENT ON TABLE procurement_arrival_exception_events IS
    'Append-only decision and completion evidence for procurement arrival exceptions.';
