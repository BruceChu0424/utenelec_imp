-- V482 销售订单改量事实账（2026-09-05 用户口径：财务确认后的订单允许改量，
-- 但改完自动回到「待财务确认」；财务确认页按「上次确认时间之后」展示
-- 修改清单——每行 以前数量 → 现在数量）。
-- 仅已审订单的 changeQty 写入；确认后（was finance_confirmed）的修改会把
-- finance_confirmed 置回 FALSE 重新进入财务队列，并按本表在队列/审核页
-- 标注「改后待确认 · N 处」。重新确认后 finance_confirmed_at 前进，
-- 旧清单自然隐藏（表本身 append-only 保留审计轨迹）。

CREATE TABLE sales_order_qty_change_logs (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id               UUID NOT NULL
        REFERENCES sales_orders(id) ON DELETE RESTRICT,
    order_item_id          UUID NOT NULL
        REFERENCES sales_order_items(id) ON DELETE RESTRICT,
    old_qty                NUMERIC(18,4) NOT NULL CHECK (old_qty > 0),
    new_qty                NUMERIC(18,4) NOT NULL CHECK (new_qty > 0),
    changed_by_employee_id UUID
        REFERENCES employees(id) ON DELETE SET NULL,
    changed_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_sales_order_qty_change_logs_order
    ON sales_order_qty_change_logs(order_id, changed_at DESC);

COMMENT ON TABLE sales_order_qty_change_logs IS
    '已审销售订单改量事实账：每行一次数量修改（old→new）；财务确认页展示'
    '「上次确认时间之后」的行作为修改清单，确认后自动隐藏历史行（表 append-only 保留审计）。';
