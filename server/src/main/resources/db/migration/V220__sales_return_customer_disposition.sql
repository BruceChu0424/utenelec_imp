-- V220: 销售退货「客户处置」权威字段 + 审批 + 追加式事件账。
--
-- 背景（SOP 06 §五 / SOP 01 §七-273 / 审计 §五）：退货审核统一按"重开替换需求"重算
-- outstanding/chain 并立红字应收，但这只是安全默认——公司尚未有"退款结案/换货/补发/
-- 维修后返还"的客户处置权威字段与审批，因此替换需求既不能自动补产，也不能自动加预留。
-- 本迁移补齐该缺口：在 sales_returns 上落地客户处置决策，并按结论对 outstanding/AR/排产
-- 产生确定影响（RESHIP/EXCHANGE 重开履约预留=BUG-S1 修复；REFUND_CLOSED/REPAIR_RETURN
-- 以 flag_qty 关闭替换需求、不补产；任何处置确认后禁止整单普通红冲，须走受控补偿）。
--
-- 自包含前向：建列 + 约束 + 事件表 + 追加式触发器 + 权限 seed 一步到位，不依赖外部步骤。
-- 历史已审退货 disposition_status 默认 'PENDING'（未决策），不补造处置事实。

ALTER TABLE sales_returns
    ADD COLUMN IF NOT EXISTS customer_disposition VARCHAR(20),
    ADD COLUMN IF NOT EXISTS disposition_status VARCHAR(12) NOT NULL DEFAULT 'PENDING',
    ADD COLUMN IF NOT EXISTS disposition_decided_by UUID,
    ADD COLUMN IF NOT EXISTS disposition_decided_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS disposition_reason TEXT,
    ADD COLUMN IF NOT EXISTS fulfilment_reopened BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE sales_returns
    DROP CONSTRAINT IF EXISTS sales_returns_customer_disposition_chk;
ALTER TABLE sales_returns
    ADD CONSTRAINT sales_returns_customer_disposition_chk CHECK (
        customer_disposition IS NULL
        OR customer_disposition IN ('REFUND_CLOSED', 'EXCHANGE', 'RESHIP', 'REPAIR_RETURN')
    );

ALTER TABLE sales_returns
    DROP CONSTRAINT IF EXISTS sales_returns_disposition_status_chk;
ALTER TABLE sales_returns
    ADD CONSTRAINT sales_returns_disposition_status_chk CHECK (
        disposition_status IN ('PENDING', 'DECIDED')
    );

-- 处置已确认时，必须同时落齐处置类型、决策人、时间。
ALTER TABLE sales_returns
    DROP CONSTRAINT IF EXISTS sales_returns_disposition_decided_chk;
ALTER TABLE sales_returns
    ADD CONSTRAINT sales_returns_disposition_decided_chk CHECK (
        (disposition_status = 'PENDING'
            AND customer_disposition IS NULL
            AND disposition_decided_by IS NULL
            AND disposition_decided_at IS NULL)
        OR (disposition_status = 'DECIDED'
            AND customer_disposition IS NOT NULL
            AND disposition_decided_by IS NOT NULL
            AND disposition_decided_at IS NOT NULL)
    );

-- 只有 RESHIP/EXCHANGE 才会把 fulfilment_reopened 置真（重开履约预留）。
ALTER TABLE sales_returns
    DROP CONSTRAINT IF EXISTS sales_returns_fulfilment_reopened_chk;
ALTER TABLE sales_returns
    ADD CONSTRAINT sales_returns_fulfilment_reopened_chk CHECK (
        NOT fulfilment_reopened
        OR customer_disposition IN ('RESHIP', 'EXCHANGE')
    );

CREATE INDEX IF NOT EXISTS idx_sales_returns_disposition_status
    ON sales_returns(disposition_status, customer_disposition);

-- 追加式客户处置事件账（镜像 V189 sales_return_quality_events；禁止 UPDATE/DELETE）。
CREATE TABLE IF NOT EXISTS sales_return_disposition_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    return_id UUID NOT NULL REFERENCES sales_returns(id) ON DELETE RESTRICT,
    action TEXT NOT NULL,
    disposition TEXT NOT NULL,
    reason TEXT,
    actor_employee_id UUID,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT sales_return_disposition_events_action_chk CHECK (
        action IN ('DISPOSITION_DECIDED')
    ),
    CONSTRAINT sales_return_disposition_events_disposition_chk CHECK (
        disposition IN ('REFUND_CLOSED', 'EXCHANGE', 'RESHIP', 'REPAIR_RETURN')
    ),
    CONSTRAINT sales_return_disposition_events_reason_chk CHECK (
        NULLIF(btrim(reason), '') IS NOT NULL
    )
);

CREATE INDEX IF NOT EXISTS idx_sales_return_disposition_events_timeline
    ON sales_return_disposition_events(return_id, occurred_at, id);

CREATE OR REPLACE FUNCTION fn_reject_sales_return_disposition_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'sales_return_disposition_events is append-only',
        DETAIL = 'Customer return disposition decisions cannot be rewritten.',
        HINT = 'Append a new controlled compensation event; never update or delete history.',
        CONSTRAINT = 'sales_return_disposition_events_append_only_guard';
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_00_reject_sales_return_disposition_event_mutation
    ON sales_return_disposition_events;
CREATE TRIGGER trg_00_reject_sales_return_disposition_event_mutation
    BEFORE UPDATE OR DELETE ON sales_return_disposition_events
    FOR EACH ROW EXECUTE FUNCTION fn_reject_sales_return_disposition_event_mutation();
ALTER TABLE sales_return_disposition_events
    ENABLE ALWAYS TRIGGER trg_00_reject_sales_return_disposition_event_mutation;

DROP TRIGGER IF EXISTS trg_audit_sales_return_disposition_events
    ON sales_return_disposition_events;
CREATE TRIGGER trg_audit_sales_return_disposition_events
    AFTER INSERT OR UPDATE OR DELETE ON sales_return_disposition_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('sales_return:disposition', '确认销售退货客户处置', '销售管理', 216)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

-- 客户处置由销售确认（退款/换货/补发/维修的客户决定归销售）；超管恒有。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'sales_return:disposition'
WHERE d.code = 'DEPT_SALES'
ON CONFLICT DO NOTHING;

COMMENT ON COLUMN sales_returns.customer_disposition IS
    '客户处置结论（REFUND_CLOSED退款结案/EXCHANGE换货/RESHIP补发/REPAIR_RETURN维修后返还）；未决策为 NULL';
COMMENT ON COLUMN sales_returns.disposition_status IS
    '客户处置状态：PENDING 未决策 / DECIDED 已确认（确认后禁止整单普通红冲，须走受控补偿）';
COMMENT ON COLUMN sales_returns.fulfilment_reopened IS
    'RESHIP/EXCHANGE 是否已重开替换履约预留（幂等标志，防止重复预留）';
COMMENT ON TABLE sales_return_disposition_events IS
    '销售退货客户处置决策的追加式证据账；禁止 UPDATE/DELETE，误判须追加补偿事件';
