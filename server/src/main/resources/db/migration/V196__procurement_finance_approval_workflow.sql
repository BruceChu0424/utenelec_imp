-- V196: planning demand -> purchase/subcontract decomposition -> assigned finance approval.
--
-- Historical status=1 orders remain effective exactly as migrated.  This migration does not
-- invent approval history and never replays order approval side effects.  The new approval
-- ledger applies only when a native draft is explicitly submitted after V196.

CREATE TABLE workflow_responsibility_assignments (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    behavior_code               TEXT NOT NULL UNIQUE CHECK (behavior_code IN (
        'PURCHASE_ORDER_FINANCE_APPROVAL',
        'SUBCONTRACT_ORDER_FINANCE_APPROVAL'
    )),
    assignee_user_id            UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    assignee_employee_id        UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    assignee_name_snapshot      TEXT NOT NULL,
    version                     BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by                  UUID REFERENCES users(id) ON DELETE SET NULL
);

COMMENT ON TABLE workflow_responsibility_assignments IS
    '高风险流程默认负责人；只影响未来提交，在途任务保留提交时负责人快照';
COMMENT ON COLUMN workflow_responsibility_assignments.behavior_code IS
    '固定行为码；每个行为同一时刻只有一个主负责人，未配置时提交失败关闭';

CREATE TABLE procurement_order_approval_cases (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_type                  TEXT NOT NULL CHECK (order_type IN ('PURCHASE', 'SUBCONTRACT')),
    order_id                    UUID NOT NULL,
    attempt                     INTEGER NOT NULL CHECK (attempt > 0),
    bill_no_snapshot            TEXT NOT NULL,
    amount_snapshot             NUMERIC(18,4) NOT NULL DEFAULT 0,
    submission_snapshot         JSONB NOT NULL,
    snapshot_hash               TEXT NOT NULL,
    submitted_by_user_id        UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    submitted_by_employee_id    UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    assignee_user_id            UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    assignee_employee_id        UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    assignee_name_snapshot      TEXT NOT NULL,
    status                      TEXT NOT NULL CHECK (status IN (
        'PENDING', 'APPROVED', 'REJECTED', 'CANCELED'
    )),
    rejection_reason            TEXT,
    decided_by_user_id          UUID REFERENCES users(id) ON DELETE RESTRICT,
    decided_by_employee_id      UUID REFERENCES employees(id) ON DELETE RESTRICT,
    submitted_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_at                  TIMESTAMPTZ,
    version                     BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (order_type, order_id, attempt),
    CHECK ((status = 'REJECTED') = (rejection_reason IS NOT NULL)),
    CHECK ((status IN ('APPROVED', 'REJECTED')) = (decided_at IS NOT NULL)),
    CHECK ((status IN ('APPROVED', 'REJECTED')) = (decided_by_user_id IS NOT NULL)),
    CHECK ((status IN ('APPROVED', 'REJECTED')) = (decided_by_employee_id IS NOT NULL))
);

CREATE UNIQUE INDEX uk_procurement_order_approval_pending
    ON procurement_order_approval_cases(order_type, order_id)
    WHERE status = 'PENDING';
CREATE INDEX idx_procurement_order_approval_assignee
    ON procurement_order_approval_cases(assignee_user_id, status, submitted_at DESC);
CREATE INDEX idx_procurement_order_approval_order
    ON procurement_order_approval_cases(order_type, order_id, attempt DESC);

COMMENT ON TABLE procurement_order_approval_cases IS
    '采购/委外订货财务审批实例；status=1 仍是订单唯一业务生效点';
COMMENT ON COLUMN procurement_order_approval_cases.submission_snapshot IS
    '提交时订单头行不可变快照，用于审核证据；修改后重提必须新建 attempt';

CREATE TABLE procurement_order_approval_events (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id                     UUID NOT NULL REFERENCES procurement_order_approval_cases(id) ON DELETE RESTRICT,
    event_type                  TEXT NOT NULL CHECK (event_type IN (
        'SUBMITTED', 'APPROVED', 'REJECTED', 'CANCELED', 'REASSIGNED'
    )),
    actor_user_id               UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    actor_employee_id           UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    from_assignee_user_id       UUID REFERENCES users(id) ON DELETE RESTRICT,
    to_assignee_user_id         UUID REFERENCES users(id) ON DELETE RESTRICT,
    reason                      TEXT,
    event_snapshot              JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_procurement_order_approval_events_case
    ON procurement_order_approval_events(case_id, created_at, id);

CREATE OR REPLACE FUNCTION fn_reject_procurement_approval_event_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'procurement_order_approval_events is append-only'
        USING ERRCODE = '55000';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_procurement_approval_events_append_only
BEFORE UPDATE OR DELETE ON procurement_order_approval_events
FOR EACH ROW EXECUTE FUNCTION fn_reject_procurement_approval_event_mutation();

COMMENT ON TABLE procurement_order_approval_events IS
    '审批追加式事件；禁止 UPDATE/DELETE，纠错通过后续补偿事件表达';

CREATE TABLE inbound_expectations (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_type                  TEXT NOT NULL CHECK (order_type IN ('PURCHASE', 'SUBCONTRACT')),
    order_id                    UUID NOT NULL,
    approval_case_id            UUID NOT NULL REFERENCES procurement_order_approval_cases(id) ON DELETE RESTRICT,
    bill_no_snapshot            TEXT NOT NULL,
    supplier_id                 UUID REFERENCES suppliers(id) ON DELETE RESTRICT,
    warehouse_id                UUID REFERENCES warehouses(id) ON DELETE RESTRICT,
    expected_date               DATE,
    owner_employee_id           UUID REFERENCES employees(id) ON DELETE RESTRICT,
    status                      TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'CLOSED', 'CANCELED')),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    UNIQUE (order_type, order_id)
);

CREATE TABLE inbound_expectation_items (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    expectation_id              UUID NOT NULL REFERENCES inbound_expectations(id) ON DELETE RESTRICT,
    order_item_id               UUID NOT NULL,
    line_no                     INTEGER,
    goods_id                    UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    color_id                    UUID REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id                     UUID REFERENCES units(id) ON DELETE RESTRICT,
    unit_rate                   NUMERIC(18,6) NOT NULL DEFAULT 1 CHECK (unit_rate > 0),
    ordered_qty                 NUMERIC(18,4) NOT NULL CHECK (ordered_qty > 0),
    accepted_qty                NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (accepted_qty >= 0),
    expected_date               DATE,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (expectation_id, order_item_id),
    CHECK (accepted_qty <= ordered_qty)
);

CREATE INDEX idx_inbound_expectations_status_date
    ON inbound_expectations(status, expected_date, created_at);
CREATE INDEX idx_inbound_expectation_items_open
    ON inbound_expectation_items(expectation_id, goods_id);

COMMENT ON TABLE inbound_expectations IS
    '财务通过后生成的仓库预计到货权威任务；通知仅作提醒，不替代本台账';
COMMENT ON TABLE inbound_expectation_items IS
    '预计到货行快照；只记录正式验收累计，实际到货/隔离事实由到货登记台账承载';

-- Independent action permissions.  Configuration is intentionally not granted to any
-- department; super-admin can bootstrap a specifically authorized finance owner.
INSERT INTO permissions(code, name, category, sort_order) VALUES
    ('planning_supply_request:view',       '查看本人计划缺料申请', '生产计划', 286),
    ('purchase_order:submit_finance',      '采购订货提交财务',     '采购管理', 112),
    ('subcontract_order:submit_finance',   '委外订货提交财务',     '委外管理', 322),
    ('finance_order_approval:view',        '查看订货审批任务',     '钱流管理', 592),
    ('finance_order_approval:review',      '处理订货财务审批',     '钱流管理', 593),
    ('workflow_assignment:manage',         '配置审批负责人',       '钱流管理', 594),
    ('warehouse_inbound:view',             '查看预计到货任务',     '库存管理', 248)
ON CONFLICT (code) DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'planning_supply_request:view'
WHERE d.code = 'SUB_PLAN' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'purchase_order:submit_finance'
WHERE d.code IN ('DEPT_PMC', 'SUB_PURCHASE') AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'subcontract_order:submit_finance'
WHERE d.code = 'DEPT_SALES' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN ('finance_order_approval:view', 'finance_order_approval:review')
WHERE d.code = 'DEPT_FIN' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'warehouse_inbound:view'
WHERE d.code IN ('DEPT_PMC', 'SUB_WH') AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- Purchase/subcontract applications are now planning-owned demand facts.  Purchasing may
-- view and decompose them, but may no longer create/edit/approve those applications.
DELETE FROM department_permissions dp
USING permissions p
WHERE p.id = dp.permission_id
  AND p.code IN ('purchase_request:edit', 'subcontract_application:edit');

-- Planning receives a demand-only projection and must not reach full purchase/subcontract
-- documents which contain supplier and commercial fields.
DELETE FROM department_permissions dp
USING permissions p, departments d
WHERE p.id = dp.permission_id
  AND d.id = dp.department_id
  AND d.code = 'SUB_PLAN'
  AND p.code IN (
      'purchase_request:view', 'purchase_order:view', 'purchase_receipt:view',
      'purchase_return:view', 'purchase_report:view',
      'subcontract_application:view', 'subcontract_order:view',
      'subcontract_receipt:view', 'subcontract_return:view', 'subcontract_report:view'
  );

-- Explicitly keep the receiving departments capable of reading demand and generated orders.
INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN ('purchase_request:view', 'purchase_order:view', 'purchase_order:edit')
WHERE d.code IN ('DEPT_PMC', 'SUB_PURCHASE') AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN ('subcontract_application:view', 'subcontract_order:view', 'subcontract_order:edit')
WHERE d.code = 'DEPT_SALES' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

