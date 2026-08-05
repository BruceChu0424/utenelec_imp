-- V222: 采购/委外收货 IQC 待检隔离——合格才进可用库存 + 唤醒生产。
--
-- 背景（SOP 01 §七-275 / §五-198 / 审计 §五 🔴）：采购/委外到货必须先进待检隔离，
-- 不得在质检结论前进入可用库存或唤醒生产（READY）。此前收货审核直接 recordMovement(DIR_IN)
-- 写 stock_balances 并立即唤醒生产——把未检品当现货，是生产放行的 P0 缺口。
--
-- 设计（镜像 V189 销售退货质检冻结的 sidecar 模式）：
--   收货审核 → 写 procurement_inspection_items 冻结行（PENDING，**不写 stock_balances**）。
--   因此三个可用量口径（warehouseAvailableBase / globalAvailableBase / v_stock_available）自然不含待检品，
--   无需各自加过滤（零改动、零口径漂移）——这是比"给 stock_balances 加 inspection_status 列"更稳的选型。
--   合格处置（PASS）才 recordMovement(DIR_IN) 进可用库存 + 唤醒生产；不合格（FAIL）只记事实，不入可用。
--
-- 自包含前向：建表 + 约束 + 追加式事件 + 权限 seed 一步到位。历史已审收货不补造质检事实
-- （其库存已按旧逻辑入库；本迁移不回填、不改历史 stock_balances）。

CREATE TABLE procurement_inspection_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_type TEXT NOT NULL,                         -- PURCHASE / SUBCONTRACT
    receipt_id UUID NOT NULL,
    receipt_item_id UUID NOT NULL,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    unit_id UUID REFERENCES units(id),
    unit_rate NUMERIC(18,6) NOT NULL,
    received_base_qty NUMERIC(18,4) NOT NULL,
    received_amount_local NUMERIC(18,4) NOT NULL DEFAULT 0,
    passed_base_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    failed_base_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'PENDING',
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    passed_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT procurement_inspection_items_item_uk UNIQUE (receipt_type, receipt_item_id),
    CONSTRAINT procurement_inspection_items_type_chk CHECK (receipt_type IN ('PURCHASE', 'SUBCONTRACT')),
    CONSTRAINT procurement_inspection_items_received_chk CHECK (received_base_qty > 0),
    CONSTRAINT procurement_inspection_items_rate_chk CHECK (unit_rate > 0),
    CONSTRAINT procurement_inspection_items_resolved_chk CHECK (
        passed_base_qty >= 0
        AND failed_base_qty >= 0
        AND passed_base_qty + failed_base_qty <= received_base_qty
    ),
    CONSTRAINT procurement_inspection_items_status_chk CHECK (
        status IN ('PENDING', 'PARTIAL', 'RESOLVED', 'REVERSED')
    ),
    CONSTRAINT procurement_inspection_items_status_projection_chk CHECK (
        (status = 'PENDING'
            AND passed_base_qty + failed_base_qty = 0)
        OR (status = 'PARTIAL'
            AND passed_base_qty + failed_base_qty > 0
            AND passed_base_qty + failed_base_qty < received_base_qty)
        OR (status = 'RESOLVED'
            AND passed_base_qty + failed_base_qty = received_base_qty)
        OR (status = 'REVERSED'
            AND passed_base_qty + failed_base_qty = 0)
    )
);

CREATE INDEX idx_procurement_inspection_items_receipt
    ON procurement_inspection_items(receipt_type, receipt_id, status, id);
CREATE INDEX idx_procurement_inspection_items_pending
    ON procurement_inspection_items(warehouse_id, goods_id, color_id, status)
    WHERE status IN ('PENDING', 'PARTIAL');

CREATE TABLE procurement_inspection_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_item_id UUID NOT NULL
        REFERENCES procurement_inspection_items(id) ON DELETE RESTRICT,
    action TEXT NOT NULL,
    base_qty NUMERIC(18,4) NOT NULL,
    reason TEXT,
    actor_employee_id UUID,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT procurement_inspection_events_action_chk CHECK (
        action IN ('RECEIVED', 'PASS', 'FAIL', 'PRODUCTION_WOKEN', 'RECEIPT_REVERSED')
    ),
    CONSTRAINT procurement_inspection_events_qty_chk CHECK (base_qty >= 0),
    CONSTRAINT procurement_inspection_events_reason_chk CHECK (
        action IN ('RECEIVED', 'PRODUCTION_WOKEN', 'RECEIPT_REVERSED')
        OR NULLIF(btrim(reason), '') IS NOT NULL
    )
);

CREATE INDEX idx_procurement_inspection_events_timeline
    ON procurement_inspection_events(inspection_item_id, occurred_at, id);

CREATE OR REPLACE FUNCTION fn_reject_procurement_inspection_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'procurement_inspection_events is append-only',
        DETAIL = 'IQC receipt and disposition evidence cannot be rewritten.',
        HINT = 'Append a new controlled event; never update or delete history.',
        CONSTRAINT = 'procurement_inspection_events_append_only_guard';
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_00_reject_procurement_inspection_event_mutation
    BEFORE UPDATE OR DELETE ON procurement_inspection_events
    FOR EACH ROW EXECUTE FUNCTION fn_reject_procurement_inspection_event_mutation();
ALTER TABLE procurement_inspection_events
    ENABLE ALWAYS TRIGGER trg_00_reject_procurement_inspection_event_mutation;

CREATE TRIGGER trg_audit_procurement_inspection_items
    AFTER INSERT OR UPDATE OR DELETE ON procurement_inspection_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_procurement_inspection_events
    AFTER INSERT OR UPDATE OR DELETE ON procurement_inspection_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('procurement_inspection:view', '查看采购委外收货待检', '库存管理', 230),
    ('procurement_inspection:handle', '处置采购委外收货待检', '库存管理', 231)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

-- 待检查看给仓库 + 品质 + PMC；处置（合格/不合格结论）给品质 + PMC。超管恒有。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'procurement_inspection:view'
WHERE d.code IN ('DEPT_PMC', 'DEPT_PROD')
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'procurement_inspection:handle'
WHERE d.code = 'DEPT_PMC'
ON CONFLICT DO NOTHING;

COMMENT ON TABLE procurement_inspection_items IS
    '采购/委外收货待检冻结投影；数量不属于 stock_balances，合格处置（PASS）后才进入可用库存并唤醒生产';
COMMENT ON TABLE procurement_inspection_events IS
    '采购/委外收货、合格、不合格、唤醒生产、收货撤销的追加式证据账；禁止 UPDATE/DELETE';
