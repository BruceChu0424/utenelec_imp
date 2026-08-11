-- V187: order-level shipment policy and auditable warehouse work.
--
-- Historical rows are deliberately not rewritten as customer confirmations
-- or warehouse execution facts. New orders/drafts use the stricter defaults.

ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS shipment_policy TEXT;
ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS partial_shipment_confirmed_at TIMESTAMPTZ;
ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS partial_shipment_confirmed_by UUID;
ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS partial_shipment_confirmation_reason TEXT;

UPDATE sales_orders
SET shipment_policy = 'LEGACY_UNSPECIFIED'
WHERE shipment_policy IS NULL;

ALTER TABLE sales_orders
    ALTER COLUMN shipment_policy SET DEFAULT 'CUSTOMER_CONFIRM',
    ALTER COLUMN shipment_policy SET NOT NULL;

ALTER TABLE sales_orders
    DROP CONSTRAINT IF EXISTS sales_orders_shipment_policy_chk;
ALTER TABLE sales_orders
    ADD CONSTRAINT sales_orders_shipment_policy_chk CHECK (
        shipment_policy IN (
            'LEGACY_UNSPECIFIED',
            'ALLOW_PARTIAL',
            'REQUIRE_COMPLETE',
            'CUSTOMER_CONFIRM'
        )
    );

COMMENT ON COLUMN sales_orders.shipment_policy IS
    'LEGACY_UNSPECIFIED=历史兼容；ALLOW_PARTIAL=允许分批；REQUIRE_COMPLETE=整单齐套；CUSTOMER_CONFIRM=分批须记录客户确认';
COMMENT ON COLUMN sales_orders.partial_shipment_confirmed_at IS
    '客户同意当前订单分批发货的业务事实时间；订单改量后清空并须重新确认';
COMMENT ON COLUMN sales_orders.partial_shipment_confirmation_reason IS
    '客户确认渠道/联系人/原因摘要，不得仅以系统默认代替';

ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS warehouse_work_status TEXT;
ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS warehouse_work_updated_at TIMESTAMPTZ;
ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS warehouse_work_updated_by UUID;
ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS picking_started_at TIMESTAMPTZ;
ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS picking_started_by UUID;
ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS picked_at TIMESTAMPTZ;
ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS picked_by UUID;
ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS handed_over_at TIMESTAMPTZ;
ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS handed_over_by UUID;
ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS warehouse_exception_reason TEXT;

UPDATE sales_shipments
SET warehouse_work_status = CASE
        WHEN COALESCE(is_deleted, FALSE) OR COALESCE(rejected, FALSE)
            THEN 'CANCELLED'
        WHEN status = 1 THEN 'SHIPPED'
        WHEN status = -1 THEN 'REVERSED'
        ELSE 'LEGACY_PENDING'
    END,
    warehouse_work_updated_at = COALESCE(updated_at, created_at, now())
WHERE warehouse_work_status IS NULL;

ALTER TABLE sales_shipments
    ALTER COLUMN warehouse_work_status SET DEFAULT 'PENDING_PICK',
    ALTER COLUMN warehouse_work_status SET NOT NULL;

ALTER TABLE sales_shipments
    DROP CONSTRAINT IF EXISTS sales_shipments_warehouse_work_status_chk;
ALTER TABLE sales_shipments
    ADD CONSTRAINT sales_shipments_warehouse_work_status_chk CHECK (
        warehouse_work_status IN (
            'LEGACY_PENDING',
            'PENDING_PICK',
            'PICKING',
            'PICKED',
            'EXCEPTION',
            'SHIPPED',
            'CANCELLED',
            'REVERSED'
        )
    );

CREATE INDEX IF NOT EXISTS idx_sales_shipments_warehouse_work
    ON sales_shipments(warehouse_work_status, warehouse_id, bill_date, id)
    WHERE COALESCE(is_deleted, FALSE) = FALSE
      AND status = 0
      AND COALESCE(rejected, FALSE) = FALSE;

COMMENT ON COLUMN sales_shipments.warehouse_work_status IS
    '仓库执行状态：新单 PENDING_PICK→PICKING→PICKED→SHIPPED；异常 EXCEPTION；历史草稿 LEGACY_PENDING 不伪造拣货事实';
COMMENT ON COLUMN sales_shipments.handed_over_at IS
    '仓库确认交接物流的时间；同事务完成库存出库、订单回写和应收立账';

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('sales_order:confirm_partial_shipment', '记录客户同意分批发货', '销售管理', 216),
    ('sales_shipment:warehouse-work', '执行销售出货仓库作业', '销售管理', 223)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'sales_order:confirm_partial_shipment'
WHERE d.code = 'DEPT_SALES'
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'sales_shipment:warehouse-work'
WHERE d.code = 'DEPT_PMC'
ON CONFLICT DO NOTHING;
