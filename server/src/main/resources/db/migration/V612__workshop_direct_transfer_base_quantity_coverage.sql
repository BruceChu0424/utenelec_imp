-- V612：直送数量统一用基础单位计算，普通仓与直送覆盖相加，线边预留不重复计。
-- 历史 transfer_items.qty 仍是来源日报单位，不能改写；每次从冻结 unit_rate 换算。
CREATE OR REPLACE FUNCTION fn_workshop_direct_received_base_qty(p_demand UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(round(transfer.qty * COALESCE(source.unit_rate, 1), 4)), 0)
    FROM production_workshop_direct_transfer_items transfer
    JOIN production_daily_report_items source ON source.id = transfer.source_report_item_id
    WHERE transfer.to_demand_id = p_demand AND transfer.reversal_id IS NULL;
$$;

-- 原始需求上的直送在 V561 拆批后供整个需求谱系使用；已由兄弟子批领走的量必须扣除。
-- 直接指名子批的新直送先抵该子批预留，剩下的线边预留才消耗根需求的共享直送料。
CREATE INDEX idx_material_demand_direct_transfer_family
    ON production_material_demands((COALESCE(split_root_demand_id, id)));

CREATE OR REPLACE FUNCTION fn_workshop_direct_covered_base_qty(p_demand UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH root AS (
        SELECT COALESCE(split_root_demand_id, id) AS id
        FROM production_material_demands WHERE id = p_demand
    ), family AS (
        SELECT demand.id,
               fn_workshop_direct_received_base_qty(demand.id) AS direct_qty,
               COALESCE(SUM(reservation.qty - reservation.released_qty)
                   FILTER (WHERE NOT warehouse.is_line_side), 0) AS ordinary_qty,
               COALESCE(SUM(reservation.qty - reservation.released_qty)
                   FILTER (WHERE warehouse.is_line_side), 0) AS line_qty
        FROM production_material_demands demand
        JOIN root ON root.id = COALESCE(demand.split_root_demand_id, demand.id)
        LEFT JOIN stock_reservations reservation
          ON reservation.demand_id = demand.id AND NOT reservation.is_deleted
        LEFT JOIN warehouses warehouse ON warehouse.id = reservation.warehouse_id
        GROUP BY demand.id
    )
    SELECT COALESCE((
        SELECT current.ordinary_qty + GREATEST(current.line_qty,
            CASE WHEN current.id = root.id THEN 0 ELSE current.direct_qty END
            + GREATEST(root_supply.direct_qty - COALESCE((
                SELECT SUM(GREATEST(sibling.line_qty -
                    CASE WHEN sibling.id = root.id THEN 0 ELSE sibling.direct_qty END, 0))
                FROM family sibling WHERE sibling.id <> current.id
            ), 0), 0))
        FROM family current CROSS JOIN root
        JOIN family root_supply ON root_supply.id = root.id
        WHERE current.id = p_demand
    ), 0);
$$;

-- 保留 V584 的追加式事实、原单位镜像、同车间/同主仓/同货品等所有守卫。
-- 替换超送判定并复核接收活跃状态；锁当前需求串行累计检查，不在已持有子需求锁后追加根行锁。
DO $migration$
DECLARE
    definition TEXT;
    source_anchor TEXT := '    -- 去向必须真的是「转送车间」，数量必须等于该报工行的申报量(V1 不做行内拆量)。';
    receiver_guard TEXT := $receiver$
    -- 只在 INSERT 新增直送时检查；UPDATE 撤回仍在上方按追加式守卫提前返回。
    -- 锁定接收计划/计划包/工单，防止候选选中后停产、关闭或取消的状态穿透。
    IF NOT EXISTS (
        SELECT 1
        FROM production_material_demands demand
        JOIN production_execution_segments receiving ON receiving.id = demand.execution_segment_id
        JOIN production_plans plan ON plan.id = receiving.plan_id
        JOIN production_planning_packages package ON package.id = receiving.package_id AND package.plan_id = plan.id
        WHERE demand.id = NEW.to_demand_id AND NOT demand.is_deleted
          AND demand.status NOT IN ('RELEASED', 'REVERSED', 'FULFILLED')
          AND receiving.id = NEW.to_execution_segment_id AND NOT receiving.is_deleted
          AND (receiving.status IN ('WAITING', 'READY', 'DISPATCHED')
               OR (receiving.status = 'IN_PROGRESS' AND receiving.continuous_supply))
          AND plan.status = 1 AND NOT plan.is_deleted
          AND NOT plan.is_stopped AND NOT plan.is_closed AND NOT plan.is_canceled
          AND package.status = 'CONFIRMED' AND NOT package.is_deleted
        FOR SHARE OF plan, package, receiving
    ) THEN
        RAISE EXCEPTION 'workshop direct transfer requires an active receiving plan, package and execution task'
            USING ERRCODE='23514', CONSTRAINT='workshop_direct_transfer_receiving_state_guard';
    END IF;

$receiver$;
    old_block TEXT := $old$
    IF (SELECT COALESCE(SUM(existing.qty), 0) + NEW.qty
        FROM production_workshop_direct_transfer_items existing
        WHERE existing.to_demand_id = NEW.to_demand_id
          AND existing.reversal_id IS NULL)
       > (SELECT demand.required_qty FROM production_material_demands demand
          WHERE demand.id = NEW.to_demand_id) THEN
$old$;
    new_block TEXT := $new$
    PERFORM 1 FROM production_material_demands
    WHERE id = NEW.to_demand_id
    FOR UPDATE;
    IF fn_workshop_direct_covered_base_qty(NEW.to_demand_id)
       + (SELECT round(NEW.qty * COALESCE(unit_rate, 1), 4)
          FROM production_daily_report_items WHERE id = NEW.source_report_item_id)
       > (SELECT required_qty FROM production_material_demands WHERE id = NEW.to_demand_id) THEN
$new$;
BEGIN
    SELECT replace(pg_get_functiondef('fn_guard_workshop_direct_transfer_item()'::regprocedure),
                   E'\r\n', E'\n') INTO definition;
    IF position(old_block IN definition) = 0 THEN
        RAISE EXCEPTION 'V612 direct-transfer quantity guard no longer matches the expected V584 shape';
    END IF;
    IF position(source_anchor IN definition) = 0 THEN
        RAISE EXCEPTION 'V612 direct-transfer insert-only receiving-state anchor missing';
    END IF;
    definition := replace(definition, source_anchor, receiver_guard || source_anchor);
    EXECUTE replace(definition, old_block, new_block);
END;
$migration$;

COMMENT ON FUNCTION fn_workshop_direct_received_base_qty(UUID) IS
    'V612 有效直送基础量：保留历史日报单位 qty，按来源冻结 unit_rate 逐行折算，撤回不计';
COMMENT ON FUNCTION fn_workshop_direct_covered_base_qty(UUID) IS
    'V612 直送收料覆盖量：普通仓预留加直送，线边预留去重，扣除拆批谱系兄弟已占用根直送量';
