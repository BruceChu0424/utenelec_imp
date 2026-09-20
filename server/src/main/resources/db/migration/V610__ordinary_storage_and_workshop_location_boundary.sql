-- V610：正常存放仓与车间在制流转位置分离。
-- V590 的入库自动学习曾把直送技术入库也学成 goods.owning_warehouse_id；
-- 只纠正仍指向线边仓的主档，不改库存流水、余额、直送、报工和已领事实。
-- 优先最新普通仓入库；无入库则取正库存最大的普通仓；无证据置空，不能猜仓。
-- 按待纠正货品点查既有 goods/date 与 goods 余额索引，避免全量排序历史库存流水。
WITH affected AS MATERIALIZED (
    SELECT goods.id
    FROM goods
    JOIN warehouses current_location ON current_location.id = goods.owning_warehouse_id
    WHERE current_location.is_line_side
), resolved AS (
    SELECT affected.id, COALESCE(inbound.warehouse_id, available.warehouse_id) AS warehouse_id
    FROM affected
    LEFT JOIN LATERAL (
        SELECT movement.warehouse_id
        FROM stock_movements movement
        JOIN warehouses warehouse ON warehouse.id = movement.warehouse_id
        WHERE movement.goods_id = affected.id
          AND movement.direction = 1
          AND NOT warehouse.is_line_side AND NOT warehouse.is_deleted
        ORDER BY movement.transaction_date DESC, movement.created_at DESC, movement.id DESC
        LIMIT 1
    ) inbound ON TRUE
    LEFT JOIN LATERAL (
        SELECT balance.warehouse_id
        FROM stock_balances balance
        JOIN warehouses warehouse ON warehouse.id = balance.warehouse_id
        WHERE inbound.warehouse_id IS NULL
          AND balance.goods_id = affected.id AND balance.qty > 0
          AND NOT warehouse.is_line_side AND NOT warehouse.is_deleted
        ORDER BY balance.qty DESC, balance.warehouse_id
        LIMIT 1
    ) available ON TRUE
)
UPDATE goods
SET owning_warehouse_id = resolved.warehouse_id
FROM resolved
WHERE goods.id = resolved.id
  AND goods.owning_warehouse_id IS DISTINCT FROM resolved.warehouse_id;

-- 所有写入口（包括旧客户端、导入和原生 SQL）都共享这个边界。
-- 锁住仓库行，避免并发将正常仓改成线边仓与货品归属写入互相穿透。
CREATE OR REPLACE FUNCTION fn_guard_goods_ordinary_owning_warehouse()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_line_side BOOLEAN;
BEGIN
    IF NEW.owning_warehouse_id IS NULL THEN RETURN NEW; END IF;
    SELECT is_line_side INTO v_line_side
    FROM warehouses WHERE id = NEW.owning_warehouse_id FOR SHARE;
    IF v_line_side THEN
        RAISE EXCEPTION 'goods owning warehouse must be ordinary storage, not a workshop transfer location'
            USING ERRCODE = '23514', CONSTRAINT = 'goods_ordinary_owning_warehouse_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_goods_ordinary_owning_warehouse
    BEFORE INSERT OR UPDATE OF owning_warehouse_id ON goods
    FOR EACH ROW EXECUTE FUNCTION fn_guard_goods_ordinary_owning_warehouse();

-- 修正 V584 的提前 RETURN：旧函数的“摘标记时有库存禁止转换”分支不可达。
-- 已发生过直送的位置身份不可改写；停用不改历史身份，仍允许正常维护名称/备注。
CREATE INDEX idx_workshop_direct_transfer_location
    ON production_workshop_direct_transfers(line_side_warehouse_id);

CREATE OR REPLACE FUNCTION fn_guard_warehouse_line_side()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.is_line_side
       AND (NOT NEW.is_line_side OR NEW.parent_id IS DISTINCT FROM OLD.parent_id
            OR NEW.workshop_department_id IS DISTINCT FROM OLD.workshop_department_id
            OR (NEW.is_deleted AND NOT OLD.is_deleted))
       AND (EXISTS (SELECT 1 FROM stock_balances balance
                    WHERE balance.warehouse_id = NEW.id AND balance.qty <> 0)
            OR EXISTS (SELECT 1 FROM production_workshop_direct_transfers transfer
                       WHERE transfer.line_side_warehouse_id = NEW.id)) THEN
        RAISE EXCEPTION 'a workshop transfer location with stock or transfer history cannot change identity'
            USING ERRCODE = '23514', CONSTRAINT = 'warehouse_line_side_shape_guard';
    END IF;

    IF NEW.parent_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM warehouses parent WHERE parent.id = NEW.parent_id AND parent.is_line_side
    ) THEN
        RAISE EXCEPTION 'a workshop transfer location must remain a leaf'
            USING ERRCODE = '23514', CONSTRAINT = 'warehouse_line_side_shape_guard';
    END IF;
    IF NOT NEW.is_line_side THEN RETURN NEW; END IF;

    IF NEW.workshop_department_id IS NULL OR NOT NEW.is_accountable OR NEW.is_defective
       OR EXISTS (SELECT 1 FROM warehouses child
                  WHERE child.parent_id = NEW.id AND NOT child.is_deleted) THEN
        RAISE EXCEPTION 'a line-side warehouse must be an accountable non-defective leaf owned by one workshop'
            USING ERRCODE = '23514', CONSTRAINT = 'warehouse_line_side_shape_guard';
    END IF;
    IF EXISTS (SELECT 1 FROM goods WHERE owning_warehouse_id = NEW.id)
       OR (TG_OP = 'UPDATE' AND NOT OLD.is_line_side AND (
           EXISTS (SELECT 1 FROM stock_movements WHERE warehouse_id = NEW.id)
           OR EXISTS (SELECT 1 FROM stock_balances WHERE warehouse_id = NEW.id AND qty <> 0)
       )) THEN
        RAISE EXCEPTION 'ordinary storage with goods ownership or stock history cannot become a workshop transfer location'
            USING ERRCODE = '23514', CONSTRAINT = 'warehouse_line_side_shape_guard';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON COLUMN goods.owning_warehouse_id IS
    '正常存放归属仓(V610)：普通仓入库自动学习，允许主仓分类；车间直送技术位置不得作为默认仓';
COMMENT ON FUNCTION fn_guard_goods_ordinary_owning_warehouse() IS
    'V610 正常存放仓边界：拒绝把货品主档归属写为车间流转位置，并与仓库身份变更互锁';
