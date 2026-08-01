-- V189: customer returns are received into a quality quarantine, not directly
-- into saleable stock. Historical approved returns are deliberately not
-- backfilled: they were already posted to stock and no inspection fact exists.

CREATE TABLE sales_return_quality_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    return_id UUID NOT NULL REFERENCES sales_returns(id) ON DELETE RESTRICT,
    return_item_id UUID NOT NULL REFERENCES sales_return_items(id) ON DELETE RESTRICT,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    unit_id UUID REFERENCES units(id),
    unit_rate NUMERIC(18,6) NOT NULL,
    received_base_qty NUMERIC(18,4) NOT NULL,
    released_base_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    scrapped_base_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    rework_base_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'PENDING',
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT sales_return_quality_items_return_item_uk UNIQUE (return_item_id),
    CONSTRAINT sales_return_quality_items_received_chk CHECK (received_base_qty > 0),
    CONSTRAINT sales_return_quality_items_rate_chk CHECK (unit_rate > 0),
    CONSTRAINT sales_return_quality_items_disposed_chk CHECK (
        released_base_qty >= 0
        AND scrapped_base_qty >= 0
        AND rework_base_qty >= 0
        AND released_base_qty + scrapped_base_qty + rework_base_qty <= received_base_qty
    ),
    CONSTRAINT sales_return_quality_items_status_chk CHECK (
        status IN ('PENDING', 'PARTIAL', 'DISPOSED', 'REVERSED')
    ),
    CONSTRAINT sales_return_quality_items_status_projection_chk CHECK (
        (status = 'PENDING'
            AND released_base_qty + scrapped_base_qty + rework_base_qty = 0)
        OR (status = 'PARTIAL'
            AND released_base_qty + scrapped_base_qty + rework_base_qty > 0
            AND released_base_qty + scrapped_base_qty + rework_base_qty < received_base_qty)
        OR (status = 'DISPOSED'
            AND released_base_qty + scrapped_base_qty + rework_base_qty = received_base_qty)
        OR (status = 'REVERSED'
            AND released_base_qty + scrapped_base_qty + rework_base_qty = 0)
    )
);

CREATE INDEX idx_sales_return_quality_items_return
    ON sales_return_quality_items(return_id, status, id);
CREATE INDEX idx_sales_return_quality_items_pending
    ON sales_return_quality_items(warehouse_id, goods_id, color_id, status)
    WHERE status IN ('PENDING', 'PARTIAL');

CREATE TABLE sales_return_quality_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    quality_item_id UUID NOT NULL
        REFERENCES sales_return_quality_items(id) ON DELETE RESTRICT,
    action TEXT NOT NULL,
    base_qty NUMERIC(18,4) NOT NULL,
    reason TEXT,
    actor_employee_id UUID,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT sales_return_quality_events_action_chk CHECK (
        action IN ('RECEIVED', 'GOOD_RELEASE', 'SCRAP', 'REWORK', 'RECEIPT_REVERSED')
    ),
    CONSTRAINT sales_return_quality_events_qty_chk CHECK (base_qty > 0),
    CONSTRAINT sales_return_quality_events_reason_chk CHECK (
        action IN ('RECEIVED', 'RECEIPT_REVERSED')
        OR NULLIF(btrim(reason), '') IS NOT NULL
    )
);

CREATE INDEX idx_sales_return_quality_events_timeline
    ON sales_return_quality_events(quality_item_id, occurred_at, id);

CREATE OR REPLACE FUNCTION fn_reject_sales_return_quality_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'sales_return_quality_events is append-only',
        DETAIL = 'Accepted return inspection and disposition evidence cannot be rewritten.',
        HINT = 'Append a new controlled event; never update or delete history.',
        CONSTRAINT = 'sales_return_quality_events_append_only_guard';
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_00_reject_sales_return_quality_event_mutation
    BEFORE UPDATE OR DELETE ON sales_return_quality_events
    FOR EACH ROW EXECUTE FUNCTION fn_reject_sales_return_quality_event_mutation();
ALTER TABLE sales_return_quality_events
    ENABLE ALWAYS TRIGGER trg_00_reject_sales_return_quality_event_mutation;

CREATE TRIGGER trg_audit_sales_return_quality_items
    AFTER INSERT OR UPDATE OR DELETE ON sales_return_quality_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_sales_return_quality_events
    AFTER INSERT OR UPDATE OR DELETE ON sales_return_quality_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('sales_return_quality:view', '查看销售退货质检冻结', '库存管理', 214),
    ('sales_return_quality:handle', '处置销售退货质检冻结', '库存管理', 215)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'sales_return_quality:view'
WHERE d.code IN ('DEPT_SALES', 'DEPT_PMC')
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'sales_return_quality:handle'
WHERE d.code = 'DEPT_PMC'
ON CONFLICT DO NOTHING;

COMMENT ON TABLE sales_return_quality_items IS
    '销售退货质量冻结当前投影；数量不属于 stock_balances，良品释放后才进入可售库存';
COMMENT ON TABLE sales_return_quality_events IS
    '销售退货收货、良品释放、报废、返工、收货撤销的追加式证据账；历史退货不补造质检事实';
