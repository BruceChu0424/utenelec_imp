-- =====================================================================
-- V465：ordered_qty 数据库守卫与「放开超采」对齐（ADR-068/ADR-069）
-- =====================================================================
-- 背景：V144 在 purchase_request_items / subcontract_application_items 上挂的
-- trg_*_ordered_guard（V132 fn_guard_processed_quantity）会在 ordered_qty 超过
-- 申请 qty 时抛 23514「exceeds remaining source quantity」。2026-09 业务已放开
-- 超采/超委外（ADR-068：订货数量允许超过申请剩余量，剩余量夹 0、申请照常结案；
-- Java 侧容量校验已移除），该上限守卫与业务口径冲突：
--   * 单行超采订货单在**财务批准**回写 ordered_qty 时被数据库拒绝
--    （草稿/送审都成功，批准 500，用户观感是「卡死在审批」）；
--   * V463 合并行的末位来源吸收超额同样会撞上限。
--
-- 决策：保留「ordered_qty 不能为负」不变量（红冲对称性防线），取消上限。
-- 双重审批/重复回写由应用层状态机防（仅草稿可审批、仅已审可红冲、
-- approval case CAS），负数仍由数据库兜底。
--
-- 本迁移不新增表、不修改任何业务数据；触发器沿用原名
-- （InventoryTransactionalIntegrityPostgresTest 按名计数 6 不变）。
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_guard_ordered_qty_non_negative()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.ordered_qty < 0 THEN
        RAISE EXCEPTION 'ordered_qty cannot be negative'
            USING ERRCODE = '23514',
                  CONSTRAINT = TG_NAME;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER trg_purchase_request_ordered_guard ON purchase_request_items;
DROP TRIGGER trg_subcontract_application_ordered_guard
    ON subcontract_application_items;

-- 沿用原触发器名（BEFORE INSERT OR UPDATE OF ordered_qty）：只禁负数。
CREATE TRIGGER trg_purchase_request_ordered_guard
    BEFORE INSERT OR UPDATE OF ordered_qty
    ON purchase_request_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_ordered_qty_non_negative();

CREATE TRIGGER trg_subcontract_application_ordered_guard
    BEFORE INSERT OR UPDATE OF ordered_qty
    ON subcontract_application_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_ordered_qty_non_negative();

COMMENT ON FUNCTION fn_guard_ordered_qty_non_negative() IS
    'V465：ordered_qty 只禁负数（红冲对称性兜底）。2026-09 起订货允许超过申请量'
    '（超采/超委外备货，ADR-068/069：剩余量夹 0、申请照常结案），原 V144 上限守卫退役；'
    '重复回写由应用层审批状态机与 approval case CAS 防护。';
