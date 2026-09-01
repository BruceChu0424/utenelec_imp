-- V435: auditable actual-total-weight lane for inventory movements and IQC.
--
-- Quantity remains the authoritative base-unit inventory dimension.  Weight is
-- an optional, independent actual total for one document/movement slice; it is
-- never multiplied by unit_rate and is never inferred from goods.m_weight.
-- Historical movement weight cannot be proven from the current balance, so
-- existing rows deliberately remain NULL.

ALTER TABLE stock_movements
    ADD COLUMN weight NUMERIC(18,4);

ALTER TABLE stock_movements
    ADD CONSTRAINT stock_movements_weight_non_negative_chk CHECK (
        weight IS NULL OR weight >= 0
    ) NOT VALID;

ALTER TABLE stock_movements
    VALIDATE CONSTRAINT stock_movements_weight_non_negative_chk;

COMMENT ON COLUMN stock_movements.weight IS
    '本次流水切片的实际总重量；方向沿用 direction；不乘 unit_rate；NULL=来源未提供/历史不可证明';

ALTER TABLE procurement_inspection_items
    ADD COLUMN received_weight NUMERIC(18,4);

ALTER TABLE procurement_inspection_items
    ADD CONSTRAINT procurement_inspection_received_weight_non_negative_chk CHECK (
        received_weight IS NULL OR received_weight >= 0
    ) NOT VALID;

ALTER TABLE procurement_inspection_items
    VALIDATE CONSTRAINT procurement_inspection_received_weight_non_negative_chk;

COMMENT ON COLUMN procurement_inspection_items.received_weight IS
    '收货明细冻结时的整行实际总重量；IQC PASS 按累计基本量比例分配，最后切片吸收四位小数尾差；NULL=未提供';

-- Read-only evidence view.  A dimension is reconcilable only when every
-- movement has an actual weight and the current balance has a known weight.
-- The view never presents partial historical coverage as a trustworthy drift.
CREATE OR REPLACE VIEW v_stock_weight_reconciliation AS
WITH movement_weight AS (
    SELECT warehouse_id,
           goods_id,
           color_id,
           COUNT(*) AS movement_count,
           COUNT(weight) AS weighted_movement_count,
           SUM(weight * direction) FILTER (WHERE weight IS NOT NULL)
               AS movement_weight
    FROM stock_movements
    GROUP BY warehouse_id, goods_id, color_id
)
SELECT COALESCE(balance.warehouse_id, movement.warehouse_id) AS warehouse_id,
       COALESCE(balance.goods_id, movement.goods_id) AS goods_id,
       COALESCE(balance.color_id, movement.color_id) AS color_id,
       balance.weight AS balance_weight,
       movement.movement_weight,
       COALESCE(movement.movement_count, 0) AS movement_count,
       COALESCE(movement.weighted_movement_count, 0)
           AS weighted_movement_count,
       CASE
           WHEN balance.weight IS NULL THEN 'BALANCE_WEIGHT_UNKNOWN'
           WHEN COALESCE(movement.movement_count, 0) = 0
               THEN 'NO_MOVEMENT_HISTORY'
           WHEN movement.weighted_movement_count < movement.movement_count
               THEN 'INCOMPLETE_MOVEMENT_WEIGHT'
           ELSE 'RECONCILABLE'
       END AS reconciliation_status,
       CASE
           WHEN balance.weight IS NOT NULL
                AND movement.movement_count > 0
                AND movement.weighted_movement_count = movement.movement_count
               THEN balance.weight - movement.movement_weight
           ELSE NULL
       END AS weight_difference
FROM stock_balances balance
FULL OUTER JOIN movement_weight movement
  ON movement.warehouse_id = balance.warehouse_id
 AND movement.goods_id = balance.goods_id
 AND movement.color_id IS NOT DISTINCT FROM balance.color_id;

COMMENT ON VIEW v_stock_weight_reconciliation IS
    '库存重量余额与逐笔流水的只读核对证据；历史或来源重量不完整时 difference 保持 NULL，禁止把未知当作零';
