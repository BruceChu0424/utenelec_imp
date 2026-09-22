-- V641 我方供料的委外件也能超量下达：放开公共超量备货的两道数据库闸
--
-- 背景(2026-09-21 用户口径)：「我把采购超量下单后，委外甚至是车间那里下单
-- 就不能超量下单，必须是正常数值才能下单」。实测被拦的是「V4开关面板(喷油)」
-- ——一个我方供料、只有一颗叶子子件的委外件(ADR-085 单一子件直接外发)。
--
-- 原先禁它的理由写在 V472/V589 里：多下的量会凭空多出一份**无人负责**的子件
-- 需求(多喷 500 片面板，就要多发 500 片素面板给委外商，而计划表上没人算这
-- 500)。这条理由 2026-09-21 起不再成立：ADR-099 修订把「层级表上每一行填的
-- 数量」做成了服务端事实，多下的量按计划产出量如实带大它的子件需求，就在同
-- 一张「父件 + 下层一起下单」页里一并下单。既然有人负责了，就不该再拦。
--
-- 本迁移只放开两处，都是**去掉一条拒绝**，不建表、不动触发器、不改数据：
--   1. fn_guard_preplan_public_surplus_shape：删掉「SUBCONTRACT 公共超量必须
--      不是单一叶子子件件」那一段(V589 留下的最后半条)。其余形状校验
--      (只能 BUY/SUBCONTRACT 供货行动、公共明细锚的身份与数量)一个字节不动。
--   2. fn_preplan_direct_overorder_capacity：删掉「委外件有 BOM 就恒返 0」那一
--      条。它是订货审核时登记公共在途(preplan_public_supply_events)的容量上限。
--      **注意**：今天这一处放开是**预备性的**，不是在修一个正在发生的故障——
--      唯一往 preplan_public_supply_events 写数据的
--      PreplanPublicSupplyCaptureService.candidates 在 Java 侧也按「委外件有活动
--      BOM 就排除」过滤，候选集为空，所以这类件根本走不到那道触发器，放开前后
--      都不会撞 23514。之所以仍然改，是不想让同一口径的三份拷贝(客户端、服务端、
--      数据库)里留下一份与另外两份相反的；真要让这类件的公共量登记成可认领的
--      公共在途，还得连那处 Java 过滤一起放开，那是认领侧的产品决策，不在本迁移。
--
-- 补丁方式沿用 V580/V588/V589 纪律：取函数定义、行尾归一 LF、锚点不中宁可失败。

DO $patch$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    leaf_anchor TEXT := E'IF NEW.route = ''SUBCONTRACT''\n       AND fn_subcontract_sole_component_goods(NEW.goods_id) THEN\n        RAISE EXCEPTION ''subcontract public surplus requires a leaf goods item''\n            USING ERRCODE = ''23514'',\n                  CONSTRAINT = ''preplan_public_surplus_subcontract_leaf_guard'';\n    END IF;';
    leaf_replacement TEXT := E'-- V641：我方供料的委外件(含 ADR-085 单一子件件)同样可以创建公共超量备货。\n    -- 多下的量按计划产出量带大它的子件需求(ADR-099 修订)，在「父件 + 下层一起\n    -- 下单」页里一并下单，不再是无人负责的需求。\n    NULL;';
BEGIN
    SELECT pg_get_functiondef('fn_guard_preplan_public_surplus_shape()'::regprocedure)
    INTO definition;

    IF definition IS NULL THEN
        RAISE EXCEPTION 'V641 public surplus shape guard missing'
            USING ERRCODE = '23514';
    END IF;

    normalized := replace(definition, E'\r\n', E'\n');
    IF position(leaf_anchor IN normalized) = 0 THEN
        RAISE EXCEPTION 'V641 public surplus shape guard shape changed'
            USING ERRCODE = '23514';
    END IF;

    patched := replace(normalized, leaf_anchor, leaf_replacement);

    IF patched IS NOT DISTINCT FROM normalized THEN
        RAISE EXCEPTION 'V641 cannot relax the public surplus shape guard safely'
            USING ERRCODE = '23514';
    END IF;

    EXECUTE patched;
END;
$patch$;

COMMENT ON FUNCTION fn_guard_preplan_public_surplus_shape() IS
    '公共超量形态守卫：BUY/SUBCONTRACT 供货行动可带公共量(V641 起委外件不论有无 BOM 都放行——多下的量按计划产出量带大子件需求，同页一起下单)；'
    '独立公共明细数量须等于公共量、合并明细数量须等于归需求量+公共量(V588)；'
    'SUBCONTRACT_MAKE_TASK 外部化允许公共明细锚为空(V589：通知批再落明细)。';

DO $patch$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    bom_anchor TEXT := E'OR (source_action.route=''SUBCONTRACT'' AND EXISTS (\n           SELECT 1 FROM goods_bom_items bom\n           WHERE bom.goods_id=source_action.goods_id\n             AND bom.is_deleted=FALSE)) THEN';
    bom_replacement TEXT := E'THEN';
BEGIN
    SELECT pg_get_functiondef('fn_preplan_direct_overorder_capacity(uuid,uuid)'::regprocedure)
    INTO definition;

    IF definition IS NULL THEN
        RAISE EXCEPTION 'V641 direct overorder capacity function missing'
            USING ERRCODE = '23514';
    END IF;

    normalized := replace(definition, E'\r\n', E'\n');
    IF position(bom_anchor IN normalized) = 0 THEN
        RAISE EXCEPTION 'V641 direct overorder capacity shape changed'
            USING ERRCODE = '23514';
    END IF;

    patched := replace(normalized, bom_anchor, bom_replacement);

    IF patched IS NOT DISTINCT FROM normalized THEN
        RAISE EXCEPTION 'V641 cannot relax the direct overorder capacity safely'
            USING ERRCODE = '23514';
    END IF;

    EXECUTE patched;
END;
$patch$;

COMMENT ON FUNCTION fn_preplan_direct_overorder_capacity(uuid,uuid) IS
    '运行时公共在途容量：直接外发的 BUY/SUBCONTRACT 供货行动按其订货批准量授予公共在途；'
    'V641 起委外件有 BOM 不再恒返 0(公共超量已对委外件放开，容量要跟着放开，否则订货审核撞 23514)。';
