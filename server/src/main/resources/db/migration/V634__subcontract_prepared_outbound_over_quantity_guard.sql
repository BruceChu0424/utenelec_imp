-- ============ 委外前置自制超量后的订货批准谱系守卫 (2026-09-21 用户实测) ============
-- 现象: 物料分析下达车间时对委外前置自制候选行超量下达(V589 公共备货: 归需求量 1000 +
-- 公共超量 4000, 台账 required_qty=5000), 自制 5000 入库满批自动通知委外 5000, 委外部按
-- 申请明细下单 5000 并提交财务, 财务「批量通过」整批 409「数据已被其他操作更新」——
-- Postgres 日志: COMMIT 时 DEFERRED 触发器 trg_subcontract_preparation_source_guard 抛
-- "subcontract prepared-outbound lineage is inconsistent"(fn_assert_subcontract_preparation_source_before_v535)。
--
-- 根因: V458 为 PREPARED_OUTBOUND 行写的谱系守卫要求
--   analysis_item.requested_qty >= plan_item.planned_qty
-- 其中 analysis_item 是原分析里的 SUBCONTRACT_MAKE 行, requested_qty 只记「归需求量」(1000);
-- V589 之后前置自制台账 preplan_subcontract_make_tasks.required_qty = 归需求量 + 公共备货产出
-- (5000), 通知批次 notify_qty 与委外申请/订货明细都按台账整批走, 守卫仍拿 1000 卡 5000 的
-- 订货行, 财务批准在提交时一定被拒。把订货拆成几张小单也只是各自与 1000 比, 拆到刚好
-- <= 1000 的单才能过, 与 V589「顶层做 5000 委外件就要加工 5000」的口径矛盾。
--
-- 本迁移: 只 CREATE OR REPLACE 一个函数(fn_assert_subcontract_preparation_source_before_v535,
-- V535 的包装函数 fn_assert_subcontract_preparation_source 仍然调用它), 把 PREPARED_OUTBOUND 分支
-- 的数量上限从「分析行归需求量」改为「台账 required_qty」——它才是 V589 后前置自制真正承诺
-- 的产出上限(归需求量 + 公共备货), 且 notified_qty <= required_qty 由台账 CHECK 与批次守恒守卫
-- (fn_assert_subcontract_make_task_batches)兜底。批次 notify_qty >= planned_qty 与货品/颜色/单位
-- 一致性校验、MAKE_THEN_OUTBOUND 分支全部原样保留。不加表、不加列、不改行、不动触发器。
--
-- 影响范围: 只放宽「同一前置自制任务、同一通知批次」下 planned_qty 落在 (归需求量, 台账
-- required_qty] 区间的订货行; 超过台账或超过批次通知量的订货行仍被拒绝。

CREATE OR REPLACE FUNCTION fn_assert_subcontract_preparation_source_before_v535(
    p_plan_item_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM subcontract_material_plan_items plan_item
        WHERE plan_item.id = p_plan_item_id
          AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
          AND plan_item.preparation_analysis_id IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM production_material_analysis_items analysis_item
              WHERE analysis_item.analysis_id = plan_item.preparation_analysis_id
                AND analysis_item.id = plan_item.preparation_analysis_item_id
                AND analysis_item.is_deleted = FALSE
                AND analysis_item.source_type = 'SUBCONTRACT_PREPARATION'
                AND analysis_item.source_ref =
                    'SC-PREP:' || plan_item.order_item_id::text
                AND analysis_item.goods_id = plan_item.goods_id
                AND analysis_item.color_id IS NOT DISTINCT FROM plan_item.color_id
                AND analysis_item.unit_id = plan_item.unit_id
                AND analysis_item.requested_qty = plan_item.planned_qty
          )
    ) THEN
        RAISE EXCEPTION
            'subcontract preparation analysis lineage is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_preparation_analysis_lineage_guard';
    END IF;

    -- V634: PREPARED_OUTBOUND 行的数量上限看台账 required_qty(归需求量 + V589 公共备货产出),
    -- 不再看原分析 SUBCONTRACT_MAKE 行的 requested_qty(只记归需求量)。
    IF EXISTS (
        SELECT 1
        FROM subcontract_material_plan_items plan_item
        WHERE plan_item.id = p_plan_item_id
          AND plan_item.flow_mode = 'PREPARED_OUTBOUND'
          AND NOT EXISTS (
              SELECT 1
              FROM subcontract_order_items order_item
              JOIN subcontract_application_items application_item
                ON application_item.id = order_item.application_item_id
               AND application_item.is_deleted = FALSE
              JOIN preplan_subcontract_make_task_batches batch
                ON batch.application_item_id = application_item.id
              JOIN preplan_subcontract_make_tasks task
                ON task.id = batch.task_id
               AND task.status = 'ACTIVE'
               AND task.analysis_id = plan_item.preparation_analysis_id
               AND task.preparation_item_id =
                   plan_item.preparation_analysis_item_id
               AND task.required_qty >= plan_item.planned_qty
              JOIN production_material_analysis_items analysis_item
                ON analysis_item.analysis_id = task.analysis_id
               AND analysis_item.id = task.preparation_item_id
               AND analysis_item.is_deleted = FALSE
               AND analysis_item.source_type = 'SUBCONTRACT_MAKE'
               AND analysis_item.goods_id = plan_item.goods_id
               AND analysis_item.color_id IS NOT DISTINCT FROM plan_item.color_id
               AND analysis_item.unit_id = plan_item.unit_id
              WHERE order_item.id = plan_item.order_item_id
                AND order_item.is_deleted = FALSE
                AND batch.notify_qty >= plan_item.planned_qty
          )
    ) THEN
        RAISE EXCEPTION
            'subcontract prepared-outbound lineage is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_prepared_outbound_lineage_guard';
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_assert_subcontract_preparation_source_before_v535(UUID) IS
    'V458 委外准备来源谱系断言(V535 包装函数仍调用); V634: PREPARED_OUTBOUND 行数量上限改看前置自制台账 required_qty(归需求量+V589 公共备货产出), 不再看分析行 requested_qty';
