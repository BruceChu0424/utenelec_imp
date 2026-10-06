-- V809 (临时号, 合并时按 main 迁移头重排): 委外申请物料齐套才解锁下单(ADR-156)。
--
-- 用户口径(2026-10-05): 委外加工价每天不一样, 直属物料不齐时委外申请锁住, 不给生成委外订货单;
-- 等现有物料够做一部分或全部时才解锁, 而且只能按现有物料够做的套数下单; 下单后照 ADR-143 领料、
-- 仓库发料、分批回厂。没齐的那部分继续锁着, 物料再到才再解锁。
--
-- 唯一一处计算(Java 只读不复算, 任务中心、下单预填、建单 / 改单 / 送审 / 批准 / 批准后加量都读这里):
--   * 物料池: 每张委外申请明细的「专属批次」(物料分析分给它的委外节点的直属子节点的库存权益) +
--     公共可用库存(v_stock_available, 可用仓)。
--   * 已占用: 还在办的委外订货单(草稿、在审、财务退回、已批准未结案)每种直属物料「还要领的量」——
--     已批准的按领料计划行(需领 - 已发 - 已提交未发), 未批准的按 BOM 整单 f(数量, 单耗)。
--     有来源申请的部分先占该申请的专属批次, 不够的部分与手工行一起占公共库存。
--   * 申请可下单套数 = MIN 各直属物料 TRUNC4((专属剩余 + 公共剩余) / 每套用量)。
--   * 订货单是否齐套 = 本单每种物料扣掉本单所属申请的专属剩余后, 剩下的需要 <= 公共剩余(不含本单)。
-- 所有份额按 4 位小数分摊(逐来源累计取整求差), 让「可下单 N」下出的单恰好通过齐套检查。
--
-- 段落: 0 前置检查  1 通知水位表  2 读函数  3 清空业务数据策略  4 自检

-- ---------------------------------------------------------------------
-- 0. 前置检查: 依赖 V798 的领料函数与库存权益视图
-- ---------------------------------------------------------------------
DO $v809_preconditions$
BEGIN
    IF to_regprocedure('fn_subcontract_draw_edges(uuid)') IS NULL
       OR to_regprocedure('fn_subcontract_draw_f(numeric,numeric)') IS NULL
       OR to_regprocedure('fn_subcontract_draw_sets(numeric,numeric)') IS NULL
       OR to_regprocedure('fn_subcontract_draw_needed_qty(uuid,numeric,numeric)') IS NULL
       OR to_regprocedure('fn_warehouse_counts_as_usable(uuid)') IS NULL
       OR to_regclass('v_preplan_stock_entitlement_lot_balance') IS NULL
       OR to_regclass('v_stock_available') IS NULL
       OR to_regclass('subcontract_draw_notice_marks') IS NULL THEN
        RAISE EXCEPTION 'V809 requires the V798 subcontract draw functions, stock entitlement lots and v_stock_available';
    END IF;
END;
$v809_preconditions$;

-- ---------------------------------------------------------------------
-- 1. 「委外申请可下单」通知的高水位(与 V798 可领料水位同一做法)
-- ---------------------------------------------------------------------
CREATE TABLE subcontract_application_kit_notice_marks (
    application_item_id UUID PRIMARY KEY REFERENCES subcontract_application_items(id) ON DELETE CASCADE,
    notified_orderable NUMERIC(18,4) NOT NULL DEFAULT 0,
    epoch INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT subcontract_application_kit_notice_mark_values_chk CHECK (notified_orderable >= 0 AND epoch >= 0)
);
COMMENT ON TABLE subcontract_application_kit_notice_marks IS
    'V809(ADR-156): 委外申请可下单通知的高水位(每个申请明细一行). 可下单 > 水位才提醒并抬高水位; 可下单 < 水位时降水位并 epoch+1, 降到 0 撤卡. 系统协调状态, 不挂行级审计, 清空业务数据时清空';

-- ---------------------------------------------------------------------
-- 2. 读函数
-- ---------------------------------------------------------------------

-- 2.1 一张委外申请明细在某种直属物料上的专属批次余量(可用仓)。专属批次 = 物料分析给这张申请的
--     委外节点的直属子节点(同货品同颜色)的库存权益批次, 口径与 fn_subcontract_component_entitled_lots 相同。
CREATE FUNCTION fn_subcontract_application_exact_qty(p_application_item UUID, p_goods UUID, p_color UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $function$
    WITH application AS (
        SELECT item.id, item.application_id, item.goods_id, item.color_id
        FROM subcontract_application_items item
        WHERE item.id = p_application_item AND NOT item.is_deleted
    ), parents AS (
        SELECT DISTINCT allocation.analysis_material_id AS parent_material_id
        FROM application
        JOIN preplan_supply_actions action ON action.external_document_type = 'SUBCONTRACT_APPLICATION'
         AND action.external_document_id = application.application_id
         AND action.route = 'SUBCONTRACT' AND action.operation_type = 'SUPPLY' AND action.status <> 'CANCELLED'
        JOIN preplan_supply_action_allocations allocation ON allocation.action_id = action.id
         AND allocation.analysis_id = action.analysis_id AND allocation.allocated_qty > 0
         AND (allocation.external_item_id = application.id OR action.public_surplus_external_item_id = application.id)
    ), children AS (
        SELECT DISTINCT child.id, child.analysis_id
        FROM parents
        CROSS JOIN application
        JOIN production_material_analysis_materials parent ON parent.id = parents.parent_material_id
         AND parent.active
         AND parent.goods_id = application.goods_id AND parent.color_id IS NOT DISTINCT FROM application.color_id
        JOIN production_material_analysis_materials child ON child.analysis_id = parent.analysis_id
         AND child.analysis_item_id = parent.analysis_item_id AND child.active
         AND ((parent.node_role = 'ROOT_SUPPLY' AND child.depth = 1 AND child.parent_node_key IS NULL)
              OR (parent.node_role <> 'ROOT_SUPPLY' AND child.parent_node_key = parent.node_key))
        WHERE child.goods_id = p_goods AND child.color_id IS NOT DISTINCT FROM p_color
    ), lots AS (
        SELECT DISTINCT ON (lot.entitlement_event_id)
               LEAST(lot.remaining_qty, reservation.qty - reservation.consumed_qty - reservation.released_qty) AS lot_qty
        FROM children
        JOIN v_preplan_stock_entitlement_lot_balance lot ON lot.beneficiary_analysis_id = children.analysis_id
         AND lot.beneficiary_analysis_material_id = children.id AND lot.remaining_qty > 0
        JOIN stock_reservations reservation ON reservation.id = lot.stock_reservation_id
         AND reservation.owner_type = 'PREPLAN_ANALYSIS' AND reservation.status = 0 AND NOT reservation.is_deleted
         AND reservation.goods_id = p_goods AND reservation.color_id IS NOT DISTINCT FROM p_color
         AND reservation.qty - reservation.consumed_qty - reservation.released_qty > 0
        JOIN warehouses warehouse ON warehouse.id = reservation.warehouse_id
         AND NOT warehouse.is_deleted AND NOT warehouse.is_defective AND NOT warehouse.is_line_side
         AND fn_warehouse_counts_as_usable(warehouse.id)
        ORDER BY lot.entitlement_event_id
    )
    SELECT COALESCE(SUM(lots.lot_qty), 0) FROM lots
$function$;

-- 2.2 一条还在办的委外订货明细对某种直属物料「还要领的量」。
--     已批准: 领料计划开着的行 MAX(需领 - 已发净量 - 已提交未发, 0)(已提交未发的草稿已占住库存);
--     草稿 / 在审 / 财务退回: 按 BOM 整单 f(数量, 订货单位单耗); 红冲、删除、已结案: 0。
CREATE FUNCTION fn_subcontract_order_item_component_need(p_order_item UUID, p_goods UUID, p_color UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE((
        SELECT CASE
            WHEN header.status = 1 THEN COALESCE((
                SELECT SUM(GREATEST(fn_subcontract_draw_needed_qty(line.order_item_id, line.planned_qty, line.bom_unit_qty)
                                    - line.issued_qty
                                    - COALESCE((SELECT SUM(draft_item.qty)
                                                FROM subcontract_material_issue_items draft_item
                                                JOIN subcontract_material_issues draft ON draft.id = draft_item.issue_id
                                                 AND draft.status = 0 AND NOT draft.is_deleted
                                                WHERE draft_item.plan_item_id = line.id AND NOT draft_item.is_deleted), 0), 0))
                FROM subcontract_material_plan_items line
                JOIN subcontract_material_plans plan ON plan.id = line.plan_id
                 AND plan.status = 'OPEN' AND NOT plan.is_deleted
                WHERE line.order_item_id = item.id AND NOT line.is_deleted AND line.draw_closed_at IS NULL
                  AND line.goods_id = p_goods AND line.color_id IS NOT DISTINCT FROM p_color), 0)
            ELSE COALESCE((
                SELECT SUM(fn_subcontract_draw_f(item.qty, ROUND(COALESCE(item.unit_rate, 1) * edge.edge_qty, 6)))
                FROM fn_subcontract_draw_edges(item.goods_id) edge
                WHERE edge.component_goods_id = p_goods AND edge.color_id IS NOT DISTINCT FROM p_color), 0)
        END
        FROM subcontract_order_items item
        JOIN subcontract_orders header ON header.id = item.order_id
        WHERE item.id = p_order_item AND NOT item.is_deleted AND COALESCE(item.qty, 0) > 0
          AND NOT header.is_deleted AND header.status IN (0, 1) AND NOT COALESCE(header.is_closed, FALSE)
    ), 0)
$function$;

-- 2.3 某种物料被还在办的委外订货单占用的量, 按物料池分开: 有来源申请的按订货明细来源份额拆到各申请
--     (逐来源累计取 4 位求差, 合计恰好等于本行需要), 没有来源(手工行)的部分记在 NULL 池。
--     p_exclude_order: 检查某张订货单自己时把它排除在外。
CREATE FUNCTION fn_subcontract_component_pool_demands(p_goods UUID, p_color UUID, p_exclude_order UUID)
RETURNS TABLE(application_item_id UUID, demand_qty NUMERIC)
LANGUAGE sql
STABLE
AS $function$
    WITH needs AS (
        SELECT item.id AS order_item_id, item.qty,
               fn_subcontract_order_item_component_need(item.id, p_goods, p_color) AS need
        FROM subcontract_order_items item
        JOIN subcontract_orders header ON header.id = item.order_id
         AND NOT header.is_deleted AND header.status IN (0, 1) AND NOT COALESCE(header.is_closed, FALSE)
        WHERE NOT item.is_deleted AND COALESCE(item.qty, 0) > 0
          AND header.id IS DISTINCT FROM p_exclude_order
          AND (EXISTS (SELECT 1 FROM subcontract_material_plan_items line
                       WHERE line.order_item_id = item.id AND NOT line.is_deleted
                         AND line.goods_id = p_goods AND line.color_id IS NOT DISTINCT FROM p_color)
               OR EXISTS (SELECT 1 FROM goods_bom_items edge
                          WHERE edge.goods_id = item.goods_id AND edge.component_goods_id = p_goods
                            AND NOT edge.is_deleted))
    ), positive AS (
        SELECT needs.* FROM needs WHERE needs.need > 0
    ), sourced AS (
        SELECT source.application_item_id, positive.need, positive.qty,
               SUM(source.alloc_qty) OVER (PARTITION BY positive.order_item_id
                                           ORDER BY source.line_no, source.id) AS cumulative_alloc,
               source.alloc_qty
        FROM positive
        JOIN subcontract_order_item_sources source ON source.order_item_id = positive.order_item_id
         AND source.alloc_qty > 0
    ), shares AS (
        SELECT sourced.application_item_id,
               ROUND(sourced.need * LEAST(sourced.cumulative_alloc, sourced.qty) / sourced.qty, 4)
               - ROUND(sourced.need * LEAST(sourced.cumulative_alloc - sourced.alloc_qty, sourced.qty) / sourced.qty, 4)
                   AS share
        FROM sourced
    ), unsourced AS (
        SELECT positive.need - ROUND(positive.need * LEAST(COALESCE(allocated.total, 0), positive.qty) / positive.qty, 4)
                   AS share
        FROM positive
        LEFT JOIN LATERAL (
            SELECT SUM(source.alloc_qty) AS total
            FROM subcontract_order_item_sources source
            WHERE source.order_item_id = positive.order_item_id AND source.alloc_qty > 0
        ) allocated ON TRUE
    )
    SELECT shares.application_item_id, SUM(shares.share)
    FROM shares
    GROUP BY shares.application_item_id
    HAVING SUM(shares.share) > 0
    UNION ALL
    SELECT NULL::uuid, SUM(unsourced.share)
    FROM unsourced
    HAVING SUM(unsourced.share) > 0
$function$;

-- 2.4 某种物料的公共可用库存(可用仓, 与领料页 fn_subcontract_draw_line_stock 的公共部分同口径)。
CREATE FUNCTION fn_subcontract_component_public_qty(p_goods UUID, p_color UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(SUM(GREATEST(stock.available_qty, 0)), 0)
    FROM v_stock_available stock
    WHERE stock.goods_id = p_goods AND stock.color_id IS NOT DISTINCT FROM p_color
      AND fn_warehouse_counts_as_usable(stock.warehouse_id)
$function$;

-- 2.5 公共库存: 现有、被占(各申请专属批次不够的部分 + 手工行)、剩余。
CREATE FUNCTION fn_subcontract_component_public_free(p_goods UUID, p_color UUID, p_exclude_order UUID)
RETURNS TABLE(public_qty NUMERIC, claimed_qty NUMERIC, free_qty NUMERIC)
LANGUAGE sql
STABLE
AS $function$
    WITH pools AS (
        SELECT demand.application_item_id, SUM(demand.demand_qty) AS demand_qty
        FROM fn_subcontract_component_pool_demands(p_goods, p_color, p_exclude_order) demand
        GROUP BY demand.application_item_id
    ), claimed AS (
        SELECT COALESCE(SUM(CASE WHEN pools.application_item_id IS NULL THEN pools.demand_qty
                                 ELSE GREATEST(pools.demand_qty - fn_subcontract_application_exact_qty(
                                          pools.application_item_id, p_goods, p_color), 0) END), 0) AS qty
        FROM pools
    ), available AS (
        SELECT fn_subcontract_component_public_qty(p_goods, p_color) AS qty
    )
    SELECT available.qty, claimed.qty, GREATEST(available.qty - claimed.qty, 0)
    FROM available CROSS JOIN claimed
$function$;

-- 2.6 一张委外申请明细逐种直属物料的齐套事实(任务中心「物料齐套情况」与可下单套数的唯一来源)。
--     每套用量 = 申请单位换算率 x BOM 单耗(与领料计划冻结口径一致)。
CREATE FUNCTION fn_subcontract_application_kit_facts(p_application_item UUID, p_exclude_order UUID)
RETURNS TABLE(edge_id UUID, component_goods_id UUID, color_id UUID, sort_order INTEGER, bom_unit_qty NUMERIC,
              exact_qty NUMERIC, exact_claimed_qty NUMERIC, exact_free_qty NUMERIC,
              public_qty NUMERIC, public_claimed_qty NUMERIC, public_free_qty NUMERIC,
              free_qty NUMERIC, kit_qty NUMERIC)
LANGUAGE sql
STABLE
AS $function$
    SELECT edge.edge_id, edge.component_goods_id, edge.color_id, edge.sort_order, unit_qty.qty,
           exact.qty, own.qty, GREATEST(exact.qty - own.qty, 0),
           public_side.public_qty, public_side.claimed_qty, public_side.free_qty,
           GREATEST(exact.qty - own.qty, 0) + public_side.free_qty,
           COALESCE(fn_subcontract_draw_sets(GREATEST(exact.qty - own.qty, 0) + public_side.free_qty, unit_qty.qty), 0)
    FROM subcontract_application_items application
    CROSS JOIN LATERAL fn_subcontract_draw_edges(application.goods_id) edge
    CROSS JOIN LATERAL (SELECT ROUND(COALESCE(application.unit_rate, 1) * edge.edge_qty, 6) AS qty) unit_qty
    CROSS JOIN LATERAL (
        SELECT fn_subcontract_application_exact_qty(application.id, edge.component_goods_id, edge.color_id) AS qty
    ) exact
    CROSS JOIN LATERAL (
        SELECT COALESCE(SUM(demand.demand_qty), 0) AS qty
        FROM fn_subcontract_component_pool_demands(edge.component_goods_id, edge.color_id, p_exclude_order) demand
        WHERE demand.application_item_id = application.id
    ) own
    CROSS JOIN LATERAL fn_subcontract_component_public_free(edge.component_goods_id, edge.color_id, p_exclude_order) public_side
    WHERE application.id = p_application_item AND NOT application.is_deleted
    ORDER BY edge.sort_order, edge.edge_id
$function$;

-- 2.7 委外申请明细按现有物料能做的套数(不封顶申请剩余量: 超委外的部分同样要物料)。没有可发外直属物料
--     (缺 BOM)时为 0, 缺 BOM 由 ADR-143 §二.3 单独锁住。
CREATE FUNCTION fn_subcontract_application_kit_qty(p_application_item UUID, p_exclude_order UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(MIN(fact.kit_qty), 0)
    FROM fn_subcontract_application_kit_facts(p_application_item, p_exclude_order) fact
$function$;

-- 2.8 委外申请明细剩余未下单数量: 申请数量 - 已下单(财务批准回写) - 在审订货单占用(与任务中心
--     v_procurement_decomposition_tasks 的 open_qty 同口径); 申请不是已审核未结案、或明细已删除时为 0。
CREATE FUNCTION fn_subcontract_application_open_qty(p_application_item UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE((
        SELECT GREATEST(COALESCE(item.qty, 0) - COALESCE(item.ordered_qty, 0) - COALESCE((
                   SELECT SUM(COALESCE(source.alloc_qty, 0))
                   FROM subcontract_order_item_sources source
                   JOIN subcontract_order_items pending_item ON pending_item.id = source.order_item_id
                    AND NOT pending_item.is_deleted
                   JOIN subcontract_orders pending_order ON pending_order.id = pending_item.order_id
                    AND pending_order.status = 0 AND NOT pending_order.is_deleted
                   WHERE source.application_item_id = item.id
                     AND EXISTS (SELECT 1 FROM procurement_order_approval_cases approval
                                 WHERE approval.order_type = 'SUBCONTRACT'
                                   AND approval.order_id = pending_order.id
                                   AND approval.status = 'PENDING')), 0), 0)
        FROM subcontract_application_items item
        JOIN subcontract_applications application ON application.id = item.application_id
        WHERE item.id = p_application_item AND NOT item.is_deleted
          AND application.status = 1 AND NOT application.is_deleted AND NOT application.is_closed
    ), 0)
$function$;

-- 2.9 委外申请明细这次能下单的数量 = MIN(剩余未下单, 现有物料够做的套数); 0 = 锁住(等物料齐套)。
CREATE FUNCTION fn_subcontract_application_orderable_qty(p_application_item UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE WHEN open_side.qty > 0
                THEN LEAST(open_side.qty, fn_subcontract_application_kit_qty(p_application_item, NULL))
                ELSE 0 END
    FROM (SELECT fn_subcontract_application_open_qty(p_application_item) AS qty) open_side
$function$;

-- 2.10 订货单齐套检查:返回本单不够的直属物料(空 = 齐套)。本单每种物料的需要按来源拆进各申请的物料池,
--     先用该池扣掉其它订货单之后的专属剩余, 剩下的(连同手工行)必须 <= 其它订货单之后的公共剩余。
CREATE FUNCTION fn_subcontract_order_kit_shortages(p_order UUID)
RETURNS TABLE(goods_id UUID, color_id UUID, need_qty NUMERIC, exact_free_qty NUMERIC, public_need_qty NUMERIC,
              public_free_qty NUMERIC)
LANGUAGE sql
STABLE
AS $function$
    WITH items AS (
        SELECT item.id, item.qty, item.goods_id
        FROM subcontract_order_items item
        WHERE item.order_id = p_order AND NOT item.is_deleted AND COALESCE(item.qty, 0) > 0
    ), components AS (
        SELECT DISTINCT edge.component_goods_id AS goods_id, edge.color_id
        FROM items
        CROSS JOIN LATERAL fn_subcontract_draw_edges(items.goods_id) edge
        UNION
        SELECT line.goods_id, line.color_id
        FROM items
        JOIN subcontract_material_plan_items line ON line.order_item_id = items.id AND NOT line.is_deleted
    ), needs AS (
        SELECT component.goods_id, component.color_id, items.id AS order_item_id, items.qty,
               fn_subcontract_order_item_component_need(items.id, component.goods_id, component.color_id) AS need
        FROM components component
        CROSS JOIN items
    ), positive AS (
        SELECT needs.* FROM needs WHERE needs.need > 0
    ), sourced AS (
        SELECT positive.goods_id, positive.color_id, source.application_item_id, positive.need, positive.qty,
               SUM(source.alloc_qty) OVER (PARTITION BY positive.goods_id, positive.color_id, positive.order_item_id
                                           ORDER BY source.line_no, source.id) AS cumulative_alloc,
               source.alloc_qty
        FROM positive
        JOIN subcontract_order_item_sources source ON source.order_item_id = positive.order_item_id
         AND source.alloc_qty > 0
    ), pooled AS (
        SELECT sourced.goods_id, sourced.color_id, sourced.application_item_id,
               SUM(ROUND(sourced.need * LEAST(sourced.cumulative_alloc, sourced.qty) / sourced.qty, 4)
                   - ROUND(sourced.need * LEAST(sourced.cumulative_alloc - sourced.alloc_qty, sourced.qty) / sourced.qty, 4))
                   AS demand
        FROM sourced
        GROUP BY sourced.goods_id, sourced.color_id, sourced.application_item_id
        UNION ALL
        SELECT positive.goods_id, positive.color_id, NULL::uuid,
               SUM(positive.need - ROUND(positive.need * LEAST(COALESCE(allocated.total, 0), positive.qty) / positive.qty, 4))
        FROM positive
        LEFT JOIN LATERAL (
            SELECT SUM(source.alloc_qty) AS total
            FROM subcontract_order_item_sources source
            WHERE source.order_item_id = positive.order_item_id AND source.alloc_qty > 0
        ) allocated ON TRUE
        GROUP BY positive.goods_id, positive.color_id
    ), pool_free AS (
        SELECT pooled.goods_id, pooled.color_id, pooled.application_item_id, pooled.demand,
               CASE WHEN pooled.application_item_id IS NULL THEN 0
                    ELSE GREATEST(fn_subcontract_application_exact_qty(pooled.application_item_id, pooled.goods_id, pooled.color_id)
                                  - COALESCE((SELECT SUM(other.demand_qty)
                                              FROM fn_subcontract_component_pool_demands(pooled.goods_id, pooled.color_id, p_order) other
                                              WHERE other.application_item_id = pooled.application_item_id), 0), 0) END AS free
        FROM pooled
        WHERE pooled.demand > 0
    ), totals AS (
        SELECT pool_free.goods_id, pool_free.color_id,
               SUM(pool_free.demand) AS need_qty,
               SUM(LEAST(pool_free.demand, pool_free.free)) AS exact_free_qty,
               SUM(GREATEST(pool_free.demand - pool_free.free, 0)) AS public_need_qty
        FROM pool_free
        GROUP BY pool_free.goods_id, pool_free.color_id
    )
    SELECT totals.goods_id, totals.color_id, totals.need_qty, totals.exact_free_qty, totals.public_need_qty,
           public_side.free_qty
    FROM totals
    CROSS JOIN LATERAL fn_subcontract_component_public_free(totals.goods_id, totals.color_id, p_order) public_side
    WHERE totals.public_need_qty > public_side.free_qty
    ORDER BY totals.goods_id, totals.color_id NULLS FIRST
$function$;

COMMENT ON FUNCTION fn_subcontract_application_kit_facts(uuid, uuid) IS
    'V809(ADR-156): 委外申请明细逐种直属物料的齐套事实(专属批次/公共库存的现有、被占、剩余与可做套数); 任务中心与下单预填的唯一来源';
COMMENT ON FUNCTION fn_subcontract_application_orderable_qty(uuid) IS
    'V809(ADR-156): 委外申请明细这次能下单的数量 = MIN(剩余未下单, 现有物料够做的套数); 0 = 等物料齐套(锁住)';
COMMENT ON FUNCTION fn_subcontract_order_kit_shortages(uuid) IS
    'V809(ADR-156): 订货单齐套检查, 返回不够的直属物料; 建单、改单、送审、批准与批准后加量共用';

-- ---------------------------------------------------------------------
-- 3. 清空业务数据: 可下单通知水位随业务清空(V798 同款锚点插入, needle 单行无换行)
-- ---------------------------------------------------------------------
DO $reset_policy$
DECLARE
    definition TEXT;
    anchor TEXT := '(''subcontract_draw_notice_marks'', ''CLEAR''),';
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure), chr(13), '') INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1
       OR position('subcontract_application_kit_notice_marks' IN definition) > 0 THEN
        RAISE EXCEPTION 'V809 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor,
        anchor || E'\n            (''subcontract_application_kit_notice_marks'', ''CLEAR''),');
END;
$reset_policy$;

-- ---------------------------------------------------------------------
-- 4. 自检
-- ---------------------------------------------------------------------
DO $v809_self_check$
BEGIN
    IF position('(''subcontract_application_kit_notice_marks'', ''CLEAR'')'
                IN pg_get_functiondef('business_data_reset()'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'V809 business_data_reset must clear subcontract_application_kit_notice_marks';
    END IF;
    IF to_regprocedure('fn_subcontract_application_kit_qty(uuid,uuid)') IS NULL
       OR to_regprocedure('fn_subcontract_order_kit_shortages(uuid)') IS NULL THEN
        RAISE EXCEPTION 'V809 kit functions missing';
    END IF;
END;
$v809_self_check$;
