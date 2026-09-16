-- V589 委外前置自制跟量：台账承接车间超量下达的公共备货产出
--
-- 背景：2026-09-15 用户口径「顶层要做 5000、委外件是他的子层级，那委外件就
-- 需要 5000，不然不够生产 5000 个」。V588 单计划超量后，前置自制的车间计划
-- 可以是 5000（link submitted=1000 + surplus=4000），但委外台账 required 仍只
-- 认需求 1000——超产的 4000 颗不加工就无法用于装配顶层，等于死料。
--
-- 本批让委外链跟量：ARRANGE action 记 requested=归需求量(锁) + public_surplus=
-- 超量；make task required=两者之和；通知批的 action/申请明细同口径分账。
-- 数据库侧需要两处放宽（fn_guard_preplan_public_surplus_shape）：
--   1. 「SUBCONTRACT 公共超量必须叶子货品」改为只拒 ADR-085 的单一叶子子件件
--      （我方供料件，多下的量会凭空产生无人负责的子件需求）；前置自制件
--      （有 ≥2 子层）的公共量由车间腿与级联下单背书，放行。
--   2. 外部化公共量必须锚申请明细——前置自制台账（SUBCONTRACT_MAKE_TASK）
--      外部化时还没有申请，公共量随后续通知批的 action 落到真实明细上；
--      仅这一种外部化形态允许 public_surplus_external_item_id 为空。
--
-- 补丁方式沿用 V580/V588 纪律：取函数定义、行尾归一 LF、锚点不中宁可失败。

DO $patch$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    leaf_anchor TEXT := E'IF NEW.route = ''SUBCONTRACT'' AND EXISTS (\n        SELECT 1 FROM goods_bom_items bom\n        WHERE bom.goods_id = NEW.goods_id\n          AND bom.is_deleted = FALSE) THEN';
    leaf_replacement TEXT := E'IF NEW.route = ''SUBCONTRACT''\n       AND fn_subcontract_sole_component_goods(NEW.goods_id) THEN';
    item_anchor TEXT := E'IF NEW.public_surplus_external_item_id IS NULL THEN\n        RAISE EXCEPTION ''externalized public surplus must reference its public item''\n            USING ERRCODE = ''23514'';\n    END IF;';
    item_replacement TEXT := E'IF NEW.public_surplus_external_item_id IS NULL THEN\n        -- V589：前置自制台账（SUBCONTRACT_MAKE_TASK）外部化时还没有申请明细，\n        -- 公共量随后续通知批的 action 落到真实申请明细上；其余外部化形态仍\n        -- 必须给出公共明细锚。\n        IF NEW.external_document_type IS DISTINCT FROM ''SUBCONTRACT_MAKE_TASK'' THEN\n            RAISE EXCEPTION ''externalized public surplus must reference its public item''\n                USING ERRCODE = ''23514'';\n        END IF;\n        RETURN NEW;\n    END IF;';
BEGIN
    SELECT pg_get_functiondef('fn_guard_preplan_public_surplus_shape()'::regprocedure)
    INTO definition;

    IF definition IS NULL THEN
        RAISE EXCEPTION 'V589 public surplus shape guard missing'
            USING ERRCODE = '23514';
    END IF;

    normalized := replace(definition, E'\r\n', E'\n');
    IF position(leaf_anchor IN normalized) = 0
       OR position(item_anchor IN normalized) = 0 THEN
        RAISE EXCEPTION 'V589 public surplus shape guard shape changed'
            USING ERRCODE = '23514';
    END IF;

    patched := replace(normalized, leaf_anchor, leaf_replacement);
    patched := replace(patched, item_anchor, item_replacement);

    IF patched IS NOT DISTINCT FROM normalized THEN
        RAISE EXCEPTION 'V589 cannot relax the public surplus shape guard safely'
            USING ERRCODE = '23514';
    END IF;

    EXECUTE patched;
END;
$patch$;

COMMENT ON FUNCTION fn_guard_preplan_public_surplus_shape() IS
    '公共超量形态守卫：BUY/SUBCONTRACT 供货行动可带公共量；SUBCONTRACT 仅拒 ADR-085 单一叶子子件件（V589 放宽：前置自制件的公共量随车间超量下达产生）；'
    '独立公共明细数量须等于公共量、合并明细数量须等于归需求量+公共量（V588）；'
    'SUBCONTRACT_MAKE_TASK 外部化允许公共明细锚为空（V589：通知批再落明细）。';

-- 纯公共批（归需求量已通知完，本批全是公共备货）没有可建的需求 allocation
-- （allocated_qty 有 >0 CHECK），批次行的 allocation 锚放开可空。守卫与账本
-- 对账只看 notify_qty，无人读该列。
ALTER TABLE preplan_subcontract_make_task_batches
    ALTER COLUMN allocation_id DROP NOT NULL;
