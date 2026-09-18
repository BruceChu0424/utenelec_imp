-- V595 车间直送 v2：持续生产(同车间直送子件分次到料)、线边仓退出公共可用量、线边仓自动配置。
--
-- 背景(2026-09-16 用户口径)：
--   「同车间转送给父层级应该不用领料；子件还缺就是等待物料，子件齐了就是可开工；可以分批。
--     部分开工·持续生产：物料只准备了 20% 也可以先开工，后面物料源源不断来了不用再开工，
--     来物料了就继续做，数量最后交付的时候再算，不是再开个生产单。」
--   「创建一个这种仓库总觉得不对，明明现实中没有，要么就做个虚拟的、不算在现实的。」
--
-- 本迁移只加两列、替换一段守卫、改写一个视图的一列、新增三个只读判定函数与一条索引；
-- 不新增业务表、不改任何既有业务行、不新增过账类型。
--
-- ============ ① 持续生产模式的两个事实 ============
-- 段级开关：continuous_supply = 本工单按「持续生产」开工——同车间直送供给的子件可以分次到料，
-- 到一批投一批；仓库物料仍必须一次领齐(用户口径「有物料在仓库的才需要领料」)。
ALTER TABLE production_execution_segments
    ADD COLUMN continuous_supply BOOLEAN NOT NULL DEFAULT FALSE;

-- 需求级标记：direct_supply = 这条物料需求由同车间直送供给(下层工单在本车间生产它)，
-- 在持续生产工单上允许部分到料。只在开工那一刻由服务端按「同车间有在产它的工单 /
-- 已有直送指向它」判定并冻结，此后不再改动；非持续生产工单上该列恒为 FALSE。
ALTER TABLE production_material_demands
    ADD COLUMN direct_supply BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX idx_production_material_demand_direct_supply
    ON production_material_demands(execution_segment_id)
    WHERE direct_supply AND is_deleted = FALSE;

-- 候选上层工单按「同车间 + 同货品」定位(报工页「转下一道工序」下拉、持续生产资格判定)。
CREATE INDEX idx_production_execution_segment_workshop_product
    ON production_execution_segments(workshop_department_id, product_goods_id, status)
    WHERE is_deleted = FALSE;

-- ============ ② 完整性守卫：持续生产段的直送需求允许部分到料 ============
-- V249/V159/V561 层层锚点替换后的现行函数体是 fn_assert_execution_segment_integrity_before_v561
-- (V561 把它包了一层)。这里只改两处：coverage CTE 多算一列 direct_partial，
-- READY/IN_PROGRESS 的「每条需求必须足额预留+足额领料单」放宽为「直送需求可以部分」。
-- 其余四道闸(超预留/超领料、WAITING 不许持有部分库存、齐套必须提升、完工必须结清)一字不动。
DO $migration$
DECLARE
    v_definition TEXT;
    v_updated TEXT;
    v_old_coverage TEXT := $old$
    WITH coverage AS (
        SELECT d.id,
               d.required_qty,
               COALESCE(($old$;
    v_new_coverage TEXT := $new$
    WITH coverage AS (
        SELECT d.id,
               d.required_qty,
               (v_segment.continuous_supply AND d.direct_supply) AS direct_partial,
               COALESCE(($new$;
    v_old_ready TEXT := $old$
    SELECT COUNT(*) FILTER (
               WHERE stock_backed >= required_qty
                 AND draw_backed >= required_qty
           ),$old$;
    v_new_ready TEXT := $new$
    SELECT COUNT(*) FILTER (
               WHERE direct_partial
                  OR (stock_backed >= required_qty
                      AND draw_backed >= required_qty)
           ),$new$;
BEGIN
    SELECT pg_get_functiondef(
        'fn_assert_execution_segment_integrity_before_v561(uuid)'::regprocedure)
    INTO v_definition;
    IF v_definition IS NULL THEN
        RAISE EXCEPTION 'V595 expects fn_assert_execution_segment_integrity_before_v561 (V561 shape)';
    END IF;
    IF position('direct_partial' IN v_definition) > 0 THEN
        RAISE EXCEPTION 'V595 already applied to fn_assert_execution_segment_integrity_before_v561';
    END IF;

    v_updated := replace(v_definition, v_old_coverage, v_new_coverage);
    IF v_updated = v_definition THEN
        RAISE EXCEPTION 'V595 could not find the coverage CTE anchor in the execution segment integrity guard';
    END IF;
    v_definition := v_updated;

    -- 只替换第一处：第一处是 v_ready_count(READY 判定)，第二处是 v_fully_backed_count
    --(WAITING 必须提升的判定)，后者必须保持严格。
    IF position(v_old_ready IN v_definition) = 0 THEN
        RAISE EXCEPTION 'V595 could not find the readiness anchor in the execution segment integrity guard';
    END IF;
    v_updated := overlay(v_definition
        PLACING v_new_ready
        FROM position(v_old_ready IN v_definition)
        FOR length(v_old_ready));
    EXECUTE v_updated;
END;
$migration$;

-- ============ ③ 物料视图：直送需求在持续生产段上视为「就绪」 ============
-- v_production_execution_segments.material_ready = bool_and(ready)，派工/开工前置都看它。
-- 持续生产段的直送需求不参与齐套判定(来一批投一批)，所以 ready 恒真；
-- 其余需求口径不变。列表末尾追加两列，既有列名/类型/顺序原样保留(CREATE OR REPLACE 的硬要求)。
CREATE OR REPLACE VIEW v_production_execution_segment_materials AS
 SELECT s.id AS execution_segment_id,
    s.package_id,
    s.plan_id,
    s.source_plan_item_id,
    s.status AS segment_status,
    d.id AS demand_id,
    d.goods_id,
    d.color_id,
    d.unit_id,
    d.per_product_qty,
    d.required_qty,
    d.need_date,
    d.supply_route,
    d.status AS demand_status,
    COALESCE(stock.stock_backed, 0::numeric)::numeric(18,4) AS stock_backed_qty,
    COALESCE(supply.supply_backed, 0::numeric)::numeric(18,4) AS supply_backed_qty,
    COALESCE(draw.draw_backed, 0::numeric)::numeric(18,4) AS draw_backed_qty,
    GREATEST(d.required_qty - COALESCE(stock.stock_backed, 0::numeric), 0::numeric)::numeric(18,4) AS stock_shortage_qty,
    ((s.continuous_supply AND d.direct_supply)
     OR (COALESCE(stock.stock_backed, 0::numeric) >= d.required_qty
         AND COALESCE(draw.draw_backed, 0::numeric) >= d.required_qty)) AS ready,
    d.direct_supply,
    s.continuous_supply
   FROM production_execution_segments s
     JOIN production_material_demands d ON d.execution_segment_id = s.id AND d.is_deleted = false
     LEFT JOIN LATERAL ( SELECT sum(r.qty - r.released_qty) AS stock_backed
           FROM stock_reservations r
          WHERE r.demand_id = d.id AND r.is_deleted = false) stock ON true
     LEFT JOIN LATERAL ( SELECT sum(p.allocated_qty - p.consumed_qty - p.released_qty) AS supply_backed
           FROM production_material_supply_pegs p
          WHERE p.demand_id = d.id AND p.status <> 'REVERSED'::text) supply ON true
     LEFT JOIN LATERAL ( SELECT sum(COALESCE(i.base_qty, i.qty * COALESCE(i.unit_rate, 1::numeric))) AS draw_backed
           FROM production_planning_package_document_items m
             JOIN stock_documents h ON h.id = m.document_id AND h.is_deleted = false AND h.status <> '-1'::integer
             JOIN stock_document_items i ON i.id = m.document_item_id AND i.doc_id = m.document_id
          WHERE m.demand_id = d.id AND m.document_type = 'DRAW'::text) draw ON true
  WHERE s.is_deleted = false;

-- ============ ④ 只读判定函数(服务端与视图共用一把尺子) ============
-- 线边仓里的料只属于「直送指名的那条需求」：本函数是线边仓退出公共可用量的唯一口径。
-- 谱系匹配：直送行指向原需求；V561 分批后子需求挂 split_root_demand_id；再或者直送行的收料段
-- 就是这条需求的段(对账提升等历史路径)。三者任一成立即视为「这批线边仓料是给它的」。
CREATE OR REPLACE FUNCTION fn_line_side_stock_targets_demand(p_line_side UUID, p_demand UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM production_material_demands demand
        JOIN production_workshop_direct_transfer_items transfer_item
          ON transfer_item.reversal_id IS NULL
         AND (transfer_item.to_demand_id = demand.id
              OR transfer_item.to_demand_id = demand.split_root_demand_id
              OR transfer_item.to_execution_segment_id = demand.execution_segment_id)
        -- 直送的货品必须就是这条需求要的货品：段级匹配(V561 分批谱系的兜底)不带货品比对时，
        -- 「往这个段送过任何一种料」会把线边仓里**别的**货品也算给本段的其它需求，
        -- 等于把另一个父件指名的料算进来(用户口径「该不算的地方不能算进去」)。
        JOIN production_daily_report_items source_item
          ON source_item.id = transfer_item.source_report_item_id
         AND source_item.goods_id = demand.goods_id
         AND source_item.color_id IS NOT DISTINCT FROM demand.color_id
        JOIN production_workshop_direct_transfers transfer
          ON transfer.id = transfer_item.transfer_id
         AND transfer.line_side_warehouse_id = p_line_side
        WHERE demand.id = p_demand);
$$;

-- 一条需求能否按「同车间直送」供给：同车间有正在做这个货品的其它工单，或已经有直送指向它。
CREATE OR REPLACE FUNCTION fn_demand_direct_supply_eligible(p_demand UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM production_material_demands demand
        JOIN production_execution_segments receiving
          ON receiving.id = demand.execution_segment_id
        WHERE demand.id = p_demand
          AND demand.is_deleted = FALSE
          AND receiving.workshop_department_id IS NOT NULL
          AND (EXISTS (
                   SELECT 1 FROM production_execution_segments producing
                   WHERE producing.workshop_department_id = receiving.workshop_department_id
                     AND producing.id <> receiving.id
                     AND producing.is_deleted = FALSE
                     AND producing.product_goods_id = demand.goods_id
                     AND producing.product_color_id IS NOT DISTINCT FROM demand.color_id
                     AND producing.status IN ('WAITING', 'READY', 'DISPATCHED', 'IN_PROGRESS'))
               OR EXISTS (
                   -- 同样要比对货品：否则「本段收过一笔直送」会把同段的采购子件也
                   -- 算成直送供给，仓库那条需求从此等一笔永远不会来的直送。
                   SELECT 1 FROM production_workshop_direct_transfer_items transfer_item
                   JOIN production_daily_report_items source_item
                     ON source_item.id = transfer_item.source_report_item_id
                    AND source_item.goods_id = demand.goods_id
                    AND source_item.color_id IS NOT DISTINCT FROM demand.color_id
                   WHERE transfer_item.reversal_id IS NULL
                     AND (transfer_item.to_demand_id = demand.id
                          OR transfer_item.to_demand_id = demand.split_root_demand_id
                          OR transfer_item.to_execution_segment_id = receiving.id))));
$$;

-- 一条直送需求「是不是已经到了一部分」：本车间线边仓里确有指名给它的料。
-- 用户口径(2026-09-17)：「持续开工的前提是已经有一部分的料，子层级每一种料都有一部分了，
-- 至少能开始生产了。」空料架开工会让工单在零物料支撑下进入在产，随后仓库还替它发别的料。
CREATE OR REPLACE FUNCTION fn_demand_has_direct_supply_on_hand(p_demand UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM production_material_demands demand
        JOIN production_execution_segments receiving
          ON receiving.id = demand.execution_segment_id
        JOIN warehouses line_side
          ON line_side.is_line_side
         AND line_side.is_deleted = FALSE
         AND line_side.workshop_department_id = receiving.workshop_department_id
         AND fn_warehouse_same_main(line_side.id, demand.warehouse_id)
        JOIN stock_balances balance
          ON balance.warehouse_id = line_side.id
         AND balance.goods_id = demand.goods_id
         AND balance.color_id IS NOT DISTINCT FROM demand.color_id
         AND balance.qty > 0
        WHERE demand.id = p_demand
          AND demand.is_deleted = FALSE
          AND fn_line_side_stock_targets_demand(line_side.id, demand.id));
$$;

-- 一个等待物料的工单能否按「部分开工 · 持续生产」开工：
-- 与分批领料(fn_can_split_execution_batch)同样要求「还没被动过」——没有领料单映射、没有预留、
-- 没有拆批；至少一条需求可由同车间直送供给，否则与普通开工没有区别；并且**每一条**可直送的
-- 需求都已经到了一部分(线边仓里有指名给它的料)——一件没到的工单不是「部分开工」，是空开工。
CREATE OR REPLACE FUNCTION fn_can_start_continuous_supply(p_segment UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM production_execution_segments segment
        JOIN production_plans plan ON plan.id = segment.plan_id
        JOIN production_planning_packages package ON package.id = segment.package_id
        WHERE segment.id = p_segment
          AND segment.status = 'WAITING'
          AND segment.auto_promote_when_ready
          AND segment.is_deleted = FALSE
          AND segment.continuous_supply = FALSE
          AND segment.material_requirement_mode = 'DEMANDED'
          AND segment.workshop_department_id IS NOT NULL
          AND plan.status = 1 AND plan.is_deleted = FALSE
          AND plan.is_closed = FALSE AND plan.is_canceled = FALSE AND plan.is_stopped = FALSE
          AND package.status = 'CONFIRMED' AND package.is_deleted = FALSE
          AND NOT EXISTS (SELECT 1 FROM production_execution_segment_splits split
                          WHERE split.source_segment_id = segment.id)
          AND NOT EXISTS (SELECT 1 FROM production_planning_package_documents document
                          WHERE document.execution_segment_id = segment.id)
          AND NOT EXISTS (SELECT 1 FROM production_material_demands demand
                          JOIN stock_reservations reservation ON reservation.demand_id = demand.id
                          WHERE demand.execution_segment_id = segment.id
                            AND reservation.is_deleted = FALSE)
          AND EXISTS (SELECT 1 FROM production_material_demands demand
                      WHERE demand.execution_segment_id = segment.id
                        AND demand.is_deleted = FALSE
                        AND demand.status NOT IN ('RELEASED', 'REVERSED')
                        AND fn_demand_direct_supply_eligible(demand.id))
          AND NOT EXISTS (SELECT 1 FROM production_material_demands demand
                          WHERE demand.execution_segment_id = segment.id
                            AND demand.is_deleted = FALSE
                            AND demand.status NOT IN ('RELEASED', 'REVERSED')
                            AND fn_demand_direct_supply_eligible(demand.id)
                            AND NOT fn_demand_has_direct_supply_on_hand(demand.id)));
$$;

-- ============ ⑤ 执行段事件：新增「部分开工 · 持续生产」动作 ============
-- 与 V470 同法整条重建 CHECK(动作清单是白名单)；既有事件行一个字节不动。
ALTER TABLE production_execution_segment_events
    DROP CONSTRAINT production_execution_segment_events_action_check,
    ADD CONSTRAINT production_execution_segment_events_action_check
        CHECK (action IN (
            'ASSIGNMENT', 'DISPATCH', 'START', 'CANCEL', 'REVERSE',
            'REOPEN_COMPLETION', 'RELEASE_DEFER',
            'AUTO_START_ON_REPORT', 'RECHECK_MATERIAL', 'DRAW_REQUEST',
            'START_CONTINUOUS'
        ));

COMMENT ON COLUMN production_execution_segments.continuous_supply IS
    '持续生产(V595)：同车间直送供给的子件允许分次到料、到一批投一批；仓库物料仍须一次领齐。开工时冻结';
COMMENT ON COLUMN production_material_demands.direct_supply IS
    '同车间直送供给(V595)：持续生产工单上允许部分到料的需求；开工时由服务端判定并冻结，非持续生产工单恒为 FALSE';
COMMENT ON FUNCTION fn_line_side_stock_targets_demand(UUID, UUID) IS
    '线边仓退出公共可用量的唯一口径(V595)：线边仓里的料只算给直送指名的那条需求(含 V561 分批谱系与原段级匹配)';
COMMENT ON FUNCTION fn_demand_direct_supply_eligible(UUID) IS
    '需求可否由同车间直送供给(V595)：同车间有在产该货品的其它工单，或已有直送指向它';
COMMENT ON FUNCTION fn_demand_has_direct_supply_on_hand(UUID) IS
    '这条直送需求是否已经到了一部分(V595)：本车间线边仓里有指名给它的料，是部分开工的前提';
COMMENT ON FUNCTION fn_can_start_continuous_supply(UUID) IS
    '等待物料工单可否按部分开工·持续生产开工(V595)：未被动过 + 至少一条需求可直送 + 每条可直送需求都已到一部分';

-- ============ ⑥ 正式预留：「一需求一供给一行」只约束尚未动过的行 ============
-- V150 的 uq_stock_reservation_demand_supply 把「一条需求对一份供给只有一行」当成不变量。持续生产的
-- 直送需求会被多笔直送逐次补投，而分析权益的 FORMALIZE 桥接(V313)只许挂在未消耗、未释放的有效正式
-- 预留上——上一笔补投已经出库消耗的行不能再追加。于是同一需求对同一线边仓余额允许多行，但任一时刻
-- 仍只能有一行「未动过」的有效行(分配器新建前先追加到它)，幂等重放与并发的护栏不变；既有行不动。
DROP INDEX IF EXISTS uq_stock_reservation_demand_supply;
CREATE UNIQUE INDEX uq_stock_reservation_demand_supply
    ON stock_reservations(demand_id, supply_id)
    WHERE is_deleted = FALSE
      AND owner_type = 'PRODUCTION_MATERIAL_DEMAND'
      AND status = 0
      AND consumed_qty = 0
      AND released_qty = 0;
COMMENT ON INDEX uq_stock_reservation_demand_supply IS
    '一条需求对一份供给同一时刻只有一行未动过的有效正式预留(V595 放宽：已消耗/已释放的行不再挡住持续生产的逐次补投)';
