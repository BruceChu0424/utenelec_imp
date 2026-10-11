-- V837 (ADR-173) 车间内流转免预开通内料仓
-- ---------------------------------------------------------------------------
-- 用户口径(2026-10-10): 车间内流转像领料一样是车间自己的事, 不该为了流转先走一遍
-- 「车间内料仓」开通流程——直送承接在制的内料仓始终是空的, 上层工单直接领用。
-- ADR-147(V802) 把「第一次直送自动建仓」改成「必须预先人工开通」, 解决的是开通
-- 真源治理, 不是直送本身的需要; V837 把直送的开通门槛拆掉:
--   * fn_workshop_direct_targets 不再因收料车间没开通内料仓而判不可送
--     (删除 stated CTE 的 WORKSHOP_BIN_NOT_OPEN 分支);
--   * 审核直送时(服务层 ensureOpenedBinOf)按需建内料仓并写 workshop_bins 开通行,
--     单一真源、发料来源仓置空(=按货品所属仓库)全部保留;
--   * 整批领料(颗粒散料)仍必须显式开通+开启(fn_guard_workshop_material_settings
--     不变), 不被波及;
--   * 原因码 WORKSHOP_BIN_NOT_OPEN 不再产生, 但 fn_workshop_direct_reason_text/
--     rank 的文案与 check 约束保留——历史报工行的送仓原因仍要能回看。
-- 历史行级守卫 fn_guard_workshop_direct_transfer_item 不变: 直送明细的内料仓仍必须
-- 是收料车间开通行指的那一个, 手工 SQL 依然绕不过。
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_workshop_direct_targets(
    p_producing UUID, p_demand UUID DEFAULT NULL, p_base_qty NUMERIC DEFAULT NULL)
RETURNS TABLE(
    demand_id UUID, receiving_segment_id UUID, receiving_segment_code TEXT, receiving_status TEXT,
    receiving_continuous BOOLEAN, receiving_plan_id UUID, receiving_plan_no TEXT,
    receiving_product_goods_id UUID, receiving_workshop_id UUID,
    demand_warehouse_id UUID, package_warehouse_id UUID,
    required_qty NUMERIC, covered_qty NUMERIC, receiver_shortfall_qty NUMERIC, remaining_qty NUMERIC,
    receiver_open BOOLEAN, eligible BOOLEAN, reason_code TEXT, reason_text TEXT, reason_rank INTEGER,
    sort_order INTEGER, receiver_label TEXT)
LANGUAGE sql STABLE AS $$
WITH producing AS MATERIALIZED (
    -- 与 fn_workshop_direct_relation_code 的 SOURCE_INVALID 同一口径(工单或其计划已删即失效)。
    SELECT segment.id, segment.product_goods_id, segment.plan_id, segment.source_plan_item_id
    FROM production_execution_segments segment
    JOIN production_plans plan ON plan.id = segment.plan_id
    WHERE segment.id = p_producing AND NOT segment.is_deleted AND NOT plan.is_deleted
), scope AS MATERIALIZED (
    SELECT p_demand AS demand_id WHERE p_demand IS NOT NULL
    UNION
    SELECT linked.demand_id
    FROM fn_workshop_direct_linked_demands(p_producing) linked
    WHERE p_demand IS NULL AND NOT linked.receiving_plan_canceled
), structured AS MATERIALIZED (
    SELECT scope.demand_id,
           demand.status AS demand_status, demand.required_qty AS demand_required,
           demand.warehouse_id AS demand_warehouse, demand.need_date, demand.goods_id AS demand_goods,
           receiving.id AS receiving_id, receiving.segment_code, receiving.status AS segment_status,
           COALESCE(receiving.continuous_supply, FALSE) AS continuous,
           receiving.workshop_department_id AS receiving_workshop, receiving.product_goods_id AS receiving_product,
           plan.id AS plan_id, plan.bill_no, plan.status AS plan_status, plan.is_deleted AS plan_deleted,
           plan.is_stopped, plan.is_closed, plan.is_canceled, plan.delivery_date AS plan_delivery,
           package.id AS package_id, package.status AS package_status, package.is_deleted AS package_deleted,
           package.warehouse_id AS package_warehouse,
           item.line_priority, item.delivery_date AS item_delivery,
           fn_workshop_direct_relation_code(p_producing, scope.demand_id) AS structure_code
    FROM scope
    LEFT JOIN production_material_demands demand ON demand.id = scope.demand_id
    LEFT JOIN production_execution_segments receiving ON receiving.id = demand.execution_segment_id
    LEFT JOIN production_plans plan ON plan.id = receiving.plan_id
    LEFT JOIN production_planning_packages package
      ON package.id = receiving.package_id AND package.plan_id = plan.id
    LEFT JOIN production_material_analysis_items item ON item.id = plan.material_analysis_item_id
), stated AS MATERIALIZED (
    -- V837(ADR-173): 收料车间没开通内料仓不再是不可送原因——审核直送时按需开通。
    SELECT structured.*,
           COALESCE(structure_code, CASE
               WHEN plan_deleted OR is_canceled OR is_closed OR is_stopped
                    OR plan_status IS DISTINCT FROM 1 THEN 'PLAN_NOT_ACTIVE'
               WHEN package_id IS NULL OR package_deleted
                    OR package_status IS DISTINCT FROM 'CONFIRMED' THEN 'PACKAGE_NOT_CONFIRMED'
               WHEN NOT COALESCE(segment_status IN ('WAITING', 'READY', 'DISPATCHED')
                                 OR (segment_status = 'IN_PROGRESS' AND continuous), FALSE) THEN 'RECEIVER_STATUS'
               WHEN demand_status IN ('RELEASED', 'REVERSED') THEN 'DEMAND_CLOSED'
           END) AS state_code
    FROM structured
), measured AS MATERIALIZED (
    SELECT stated.*,
           CASE WHEN state_code IS NULL THEN fn_workshop_direct_covered_base_qty(stated.demand_id) END AS covered,
           CASE WHEN state_code IS NULL THEN fn_workshop_direct_remaining_for_source(p_producing, stated.demand_id) END AS remaining
    FROM stated
), coded AS (
    SELECT measured.*,
           '上层工单' || COALESCE(' ' || measured.segment_code, '') AS receiver_label,
           COALESCE(state_code, CASE
               WHEN demand_status = 'FULFILLED' OR demand_required - covered <= 0 THEN 'DEMAND_ALREADY_COVERED'
               WHEN remaining <= 0 THEN 'SOURCE_SHARE_USED_UP'
               WHEN p_base_qty IS NOT NULL AND p_base_qty > remaining THEN 'QTY_EXCEEDS_REMAINING'
           END) AS code
    FROM measured
), described AS (
    SELECT coded.*,
           row_number() OVER (ORDER BY coded.line_priority NULLS LAST,
                                       COALESCE(coded.item_delivery, coded.need_date, coded.plan_delivery) NULLS LAST,
                                       coded.bill_no NULLS LAST, coded.segment_code NULLS LAST,
                                       coded.demand_id::text)::INTEGER AS ordinal,
           fn_workshop_direct_reason_text(coded.code, coded.receiver_label,
               COALESCE(NULLIF(goods.code, ''), NULLIF(goods.name, ''), '这个货品'),
               COALESCE(workshop.name, '其它车间'),
               CASE coded.code
                   WHEN 'PLAN_NOT_ACTIVE' THEN CASE
                       WHEN coded.plan_deleted OR coded.is_canceled THEN '已取消'
                       WHEN coded.is_closed THEN '已结案'
                       WHEN coded.is_stopped THEN '已暂停'
                       ELSE '未审核' END
                   WHEN 'RECEIVER_STATUS' THEN CASE coded.segment_status
                       WHEN 'IN_PROGRESS' THEN '已按齐套开工'
                       WHEN 'COMPLETED' THEN '已完工'
                       ELSE '已取消' END
               END,
               p_base_qty, coded.remaining) AS text
    FROM coded
    LEFT JOIN goods ON goods.id = COALESCE(coded.demand_goods,
        (SELECT product_goods_id FROM production_execution_segments WHERE id = p_producing))
    LEFT JOIN departments workshop ON workshop.id = coded.receiving_workshop
), listed AS (
    SELECT described.demand_id, described.receiving_id, described.segment_code, described.segment_status,
           described.continuous, described.plan_id, described.bill_no, described.receiving_product,
           described.receiving_workshop, described.demand_warehouse, described.package_warehouse,
           described.demand_required, described.covered,
           CASE WHEN described.covered IS NULL THEN NULL
                ELSE GREATEST(described.demand_required - described.covered, 0) END AS shortfall,
           GREATEST(COALESCE(described.remaining, 0), 0) AS source_remaining,
           described.state_code IS NULL AS open, described.code IS NULL AS allowed, described.code, described.text,
           fn_workshop_direct_reason_rank(described.code) AS code_rank, described.ordinal,
           described.receiver_label
    FROM described
    -- 列表只列结构上的上层(可送，或说得出它现在为什么不能收)。不是上层的行(没有父子关系、本身无效)
    -- 不列，也就不会挡住哨兵、不会被当成不可转原因；单条校验照常返回那一行与它的原因。
    WHERE p_demand IS NOT NULL
       OR described.code IS NULL
       OR described.code NOT IN ('NO_PARENT_RELATION', 'SELF', 'GOODS_MISMATCH', 'SOURCE_INVALID', 'TARGET_INVALID')
)
SELECT * FROM listed
UNION ALL
SELECT NULL::UUID, NULL::UUID, NULL::TEXT, NULL::TEXT, FALSE, NULL::UUID, NULL::TEXT, NULL::UUID, NULL::UUID,
       NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, 0::NUMERIC,
       FALSE, FALSE, sentinel.code,
       fn_workshop_direct_reason_text(sentinel.code, NULL, sentinel.goods_label, NULL, NULL, NULL, NULL),
       fn_workshop_direct_reason_rank(sentinel.code), 1, NULL::TEXT
FROM (
    SELECT CASE
               WHEN NOT EXISTS (SELECT 1 FROM producing) THEN 'SOURCE_INVALID'
               WHEN EXISTS (
                       SELECT 1 FROM producing
                       JOIN production_plans plan ON plan.id = producing.plan_id
                       JOIN production_material_analysis_items item
                         ON item.id = plan.material_analysis_item_id
                        AND item.analysis_id = plan.material_analysis_id AND NOT item.is_deleted
                       WHERE item.source_type IN ('MAKE_COMPONENT', 'AGGREGATE_MAKE'))
                    OR EXISTS (
                       SELECT 1 FROM producing JOIN subplan_links link
                         ON link.subplan_id = producing.plan_id AND NOT link.is_deleted)
                    OR EXISTS (
                       SELECT 1 FROM producing JOIN production_material_supply_pegs peg
                         ON peg.supply_type = 'PRODUCTION_PLAN_ITEM'
                        AND peg.supply_item_id = producing.source_plan_item_id
                        AND peg.status <> 'REVERSED') THEN 'NO_RECEIVER_ISSUED_YET'
               ELSE 'NOT_A_COMPONENT'
           END AS code,
           (SELECT COALESCE(NULLIF(goods.code, ''), NULLIF(goods.name, ''), '这个货品')
            FROM producing JOIN goods ON goods.id = producing.product_goods_id) AS goods_label
) sentinel
-- 没有一条结构上的上层时才出哨兵(上面已把不是上层的行剔除)。V798(ADR-143)起生产侧不再有委外前置自制,
-- 委外原因只来自上层是委外件(fn_workshop_direct_relation_code)。
WHERE p_demand IS NULL AND NOT EXISTS (SELECT 1 FROM listed)
ORDER BY 21
$$;
COMMENT ON FUNCTION fn_workshop_direct_targets(UUID, UUID, NUMERIC) IS
    'V736 车间直送候选与单条校验唯一入口; V802 起收料车间没开通内料仓时原因码 WORKSHOP_BIN_NOT_OPEN; V837(ADR-173) 起开通门槛拆除, 审核直送时按需开通内料仓';
