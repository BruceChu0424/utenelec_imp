-- V588 物料分析销售顶层超量下达：一张计划 + 销售分摊只认归需求量
--
-- 背景：V577/V580 让「销售订单来源顶层行」超量下达拆成两张计划单
-- （单 A 销售行 + 单 B 无销售来源的公共备货行），动机是保住
-- execution_segment_sales_allocations 的「分摊合计 = 计划数量」断言。
-- 2026-09-15 用户口径「多余的不要单独列一张单，直接合并」：不再拆单，
-- 一张计划的数量 = 归需求量 + 公共备货产出量（analysis plan link 的
-- submitted_qty + public_surplus_qty），Java 侧审核分摊（plan_order_item_links
-- 容量、订单侧 planned_qty）只认 submitted_qty。
--
-- 本迁移同步放宽 fn_assert_execution_segment_sales_allocation：当计划明细
-- 挂着的分析计划关联行带公共备货产出（public_surplus_qty > 0）时，
-- 「Σ段分摊 = 段计划量」放宽为「计划件级 Σ有效段分摊 = min(Σ有效段计划量,
-- link 容量合计)，且单段分摊不超过本段计划量」。不带公共备货的计划件
-- （包括全部历史计划）逐段相等口径一个字节不改。
--
-- 补丁方式沿用 V580 的形状断言纪律：先取函数定义、找不到锚点宁可失败；
-- 行尾统一归一为 LF（历史函数体 CRLF/LF 混杂，锚点匹配必须与行尾无关）。

DO $patch$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    anchor TEXT := E'    IF v_active_link_count > 0\n       AND v_allocated IS DISTINCT FROM v_segment.planned_qty THEN\n        RAISE EXCEPTION\n            ''sales execution segment must be allocated exactly to planned quantity''\n            USING ERRCODE = ''23514'',\n                  CONSTRAINT =\n                      ''execution_segment_sales_allocation_total_guard'';\n    END IF;';
    replacement TEXT := E'    IF v_active_link_count > 0\n       AND v_allocated IS DISTINCT FROM v_segment.planned_qty THEN\n        -- V588（2026-09-15）：分析计划超量下达后一张计划明细的数量 = 归需求量\n        -- + 公共备货产出（analysis plan link 的 public_surplus_qty），销售分摊\n        -- 只覆盖归需求量（plan_order_item_links 容量合计）。这类计划件放宽为\n        -- 「计划件级：Σ有效段分摊 = min(Σ有效段计划量, link 容量合计)，且单段\n        -- 分摊不超过本段计划量」；其余计划件维持逐段相等原口径，一字不改。\n        IF NOT EXISTS (\n                SELECT 1\n                FROM production_plan_items surplus_item\n                JOIN production_plans surplus_plan\n                  ON surplus_plan.id = surplus_item.plan_id\n                JOIN production_material_analysis_plan_links analysis_link\n                  ON analysis_link.plan_id = surplus_plan.id\n                 AND analysis_link.analysis_id = surplus_plan.material_analysis_id\n                 AND analysis_link.analysis_item_id =\n                     surplus_plan.material_analysis_item_id\n                WHERE surplus_item.id = v_segment.source_plan_item_id\n                  AND COALESCE(analysis_link.public_surplus_qty, 0) > 0) THEN\n            RAISE EXCEPTION\n                ''sales execution segment must be allocated exactly to planned quantity''\n                USING ERRCODE = ''23514'',\n                      CONSTRAINT =\n                          ''execution_segment_sales_allocation_total_guard'';\n        ELSE\n            IF v_allocated > v_segment.planned_qty THEN\n                RAISE EXCEPTION\n                    ''sales execution segment allocation exceeds its planned quantity''\n                    USING ERRCODE = ''23514'',\n                      CONSTRAINT =\n                          ''execution_segment_sales_allocation_segment_cap_guard'';\n            END IF;\n            SELECT COALESCE(SUM(allocation.allocated_qty), 0)\n              INTO v_partial_allocated\n              FROM execution_segment_sales_allocations allocation\n              JOIN production_execution_segments live_segment\n                ON live_segment.id = allocation.execution_segment_id\n               AND live_segment.is_deleted = FALSE\n               AND live_segment.status NOT IN (''CANCELLED'', ''REVERSED'')\n             WHERE live_segment.source_plan_item_id =\n                   v_segment.source_plan_item_id;\n            IF v_partial_allocated IS DISTINCT FROM LEAST(\n                   COALESCE((\n                       SELECT SUM(live_segment.planned_qty)\n                       FROM production_execution_segments live_segment\n                       WHERE live_segment.source_plan_item_id =\n                             v_segment.source_plan_item_id\n                         AND live_segment.is_deleted = FALSE\n                         AND live_segment.status NOT IN\n                             (''CANCELLED'', ''REVERSED'')), 0),\n                   COALESCE((\n                       SELECT SUM(link.allocated_qty)\n                       FROM plan_order_item_links link\n                       WHERE link.plan_item_id = v_segment.source_plan_item_id\n                         AND link.is_deleted = FALSE), 0)) THEN\n                RAISE EXCEPTION\n                    ''sales execution segment allocations must cover the sales-bound quantity exactly''\n                    USING ERRCODE = ''23514'',\n                      CONSTRAINT =\n                          ''execution_segment_sales_allocation_partial_total_guard'';\n            END IF;\n        END IF;\n    END IF;';
BEGIN
    SELECT pg_get_functiondef(
        'fn_assert_execution_segment_sales_allocation(uuid)'::regprocedure)
    INTO definition;

    IF definition IS NULL
       OR position('v_over_link BIGINT;' IN definition) = 0
       OR position(anchor IN replace(definition, E'\r\n', E'\n')) = 0 THEN
        RAISE EXCEPTION 'V588 execution sales allocation assert shape changed'
            USING ERRCODE = '23514';
    END IF;

    normalized := replace(definition, E'\r\n', E'\n');
    patched := replace(normalized, anchor, replacement);
    patched := replace(
        patched,
        '    v_over_link BIGINT;',
        '    v_over_link BIGINT;' || E'\n' || '    v_partial_allocated NUMERIC(18,4);');

    IF patched IS NOT DISTINCT FROM normalized THEN
        RAISE EXCEPTION 'V588 cannot relax the execution sales allocation assert safely'
            USING ERRCODE = '23514';
    END IF;

    EXECUTE patched;
END;
$patch$;

-- 同批第二刀：fn_guard_preplan_public_surplus_shape 允许「合并明细」形态。
-- 2026-09-15 起需求片与公共超量片合成同一条申请明细（用户口径「直接显示
-- 下达 5000，不是 1000 一条 4000 一条」），该明细数量 = requested_qty +
-- public_surplus_qty。原守卫只认「明细数量 == public_surplus_qty」的独立
-- 公共备货行（allocation 的 external_item_id 由外部化握手守卫强制晚于
-- action 写入，共享识别在写入时序上永远来不及），补一个「明细数量 ==
-- 归需求量 + 公共备货量」的合法分支；其余校验（路由、叶子委外、单据/
-- 货品/颜色/单位身份）原样。
DO $patch2$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    anchor TEXT := E'IF NOT COALESCE(item_valid,FALSE)\n       OR (NOT shared_with_demand\n           AND item_qty IS DISTINCT FROM NEW.public_surplus_qty) THEN';
    replacement TEXT := E'IF NOT COALESCE(item_valid,FALSE)\n       OR (NOT shared_with_demand\n           AND item_qty IS DISTINCT FROM NEW.public_surplus_qty\n           AND item_qty IS DISTINCT FROM\n               (NEW.requested_qty + NEW.public_surplus_qty)) THEN';
BEGIN
    SELECT pg_get_functiondef(
        'fn_guard_preplan_public_surplus_shape()'::regprocedure)
    INTO definition;

    IF definition IS NULL
       OR position(anchor IN replace(definition, E'\r\n', E'\n')) = 0 THEN
        RAISE EXCEPTION 'V588 public surplus shape guard shape changed'
            USING ERRCODE = '23514';
    END IF;

    normalized := replace(definition, E'\r\n', E'\n');
    patched := replace(normalized, anchor, replacement);

    IF patched IS NOT DISTINCT FROM normalized THEN
        RAISE EXCEPTION 'V588 cannot relax the public surplus shape guard safely'
            USING ERRCODE = '23514';
    END IF;

    EXECUTE patched;
END;
$patch2$;
