-- V683 ADR-111 主档删除引用保护：数据库兜底
--
-- 背景(2026-09-22 事故)：超管在货品资料里删除了组件 V40001-dy，而它仍是 V4ZJ005 有效
-- BOM 行的组件；货品删除只做 is_deleted=TRUE、不查引用，结果所有 BOM 树里含它的成品在
-- 物料分析准备页一律 409。V181 起 goods_bom_items 已挡住「有效 BOM 行指向已删货品」的
-- 新增/改写(guard_goods_bom_operational_goods)，但反方向——删掉一个仍被有效 BOM 用着的
-- 货品——没有任何闸。
--
-- 友好原因由服务端 MasterReferenceGuard 在写之前先查(有效 BOM、未结案单据、库存、预留、
-- 进行中的物料分析……)；这里的触发器只防绕过服务的旁路写入，范围取最硬的三条：
--   1) 货品仍是「有效父件」的「有效 BOM 行」组件时不能软删；
--   2) 颜色仍被有效货品(货品颜色、默认采购价/委外价的颜色)、或有效父件的有效 BOM 行指定时
--      不能软删；
--   3) 单位仍被有效货品当作基本单位/厚度单位/重量单位/默认采购价或委外价的单位时不能软删。
-- 服务端删父件时先在同一事务里软删它自己的 BOM 行，所以「父件和组件同批一起删」不会被
-- 1) 误拦(不论同一条 UPDATE 里行的处理顺序)。
--
-- 只新增函数与触发器，不改任何已有对象；只在 is_deleted 由 FALSE 变 TRUE 时触发。

CREATE OR REPLACE FUNCTION fn_guard_goods_soft_delete_bom_component()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_parent_code TEXT;
BEGIN
    SELECT parent.code INTO v_parent_code
    FROM goods_bom_items bom
    JOIN goods parent ON parent.id = bom.goods_id
    WHERE bom.component_goods_id = NEW.id
      AND bom.is_deleted = FALSE
      AND parent.is_deleted = FALSE
      AND parent.id <> NEW.id
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            CONSTRAINT = 'goods_soft_delete_bom_component',
            MESSAGE = 'goods is still a component of an active BOM and cannot be soft-deleted',
            DETAIL = format('goods %s is used by active BOM parent %s', NEW.id, COALESCE(v_parent_code, '?'));
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_guard_goods_soft_delete_bom_component() IS
    'ADR-111: a goods row referenced as component by an active BOM row of an active parent cannot be soft-deleted.';

CREATE TRIGGER trg_goods_guard_bom_component_soft_delete
    BEFORE UPDATE OF is_deleted ON goods
    FOR EACH ROW
    WHEN (NEW.is_deleted AND NOT OLD.is_deleted)
    EXECUTE FUNCTION fn_guard_goods_soft_delete_bom_component();

CREATE OR REPLACE FUNCTION fn_guard_color_soft_delete_in_use()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM goods g
        WHERE g.is_deleted = FALSE
          AND (g.color_id = NEW.id
               OR g.default_purchase_price_color_id = NEW.id
               OR g.default_subcontract_price_color_id = NEW.id)
    ) OR EXISTS (
        SELECT 1
        FROM goods_bom_items bom
        JOIN goods parent ON parent.id = bom.goods_id
        WHERE bom.color_id = NEW.id
          AND bom.is_deleted = FALSE
          AND parent.is_deleted = FALSE
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            CONSTRAINT = 'color_soft_delete_in_use',
            MESSAGE = 'color is still used by an active goods row or active BOM row and cannot be soft-deleted',
            DETAIL = format('color %s', NEW.id);
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_guard_color_soft_delete_in_use() IS
    'ADR-111: a color used by an active goods row or by an active BOM row of an active parent cannot be soft-deleted.';

CREATE TRIGGER trg_colors_guard_in_use_soft_delete
    BEFORE UPDATE OF is_deleted ON colors
    FOR EACH ROW
    WHEN (NEW.is_deleted AND NOT OLD.is_deleted)
    EXECUTE FUNCTION fn_guard_color_soft_delete_in_use();

CREATE OR REPLACE FUNCTION fn_guard_unit_soft_delete_in_use()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM goods g
        WHERE g.is_deleted = FALSE
          AND (g.unit_id = NEW.id OR g.thickness_unit_id = NEW.id OR g.m_weight_unit_id = NEW.id
               OR g.default_purchase_price_unit_id = NEW.id
               OR g.default_subcontract_price_unit_id = NEW.id)
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            CONSTRAINT = 'unit_soft_delete_in_use',
            MESSAGE = 'unit is still used by an active goods row and cannot be soft-deleted',
            DETAIL = format('unit %s', NEW.id);
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_guard_unit_soft_delete_in_use() IS
    'ADR-111: a unit used by an active goods row as base, thickness, weight or default price unit cannot be soft-deleted.';

CREATE TRIGGER trg_units_guard_in_use_soft_delete
    BEFORE UPDATE OF is_deleted ON units
    FOR EACH ROW
    WHEN (NEW.is_deleted AND NOT OLD.is_deleted)
    EXECUTE FUNCTION fn_guard_unit_soft_delete_in_use();
