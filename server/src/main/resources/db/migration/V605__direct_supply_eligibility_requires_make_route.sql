-- ============ 直送资格收紧：只认「自制」子件（2026-09-18 用户口径） ============
-- 用户报障：「有些任务一部分是直送料、一些是需要去领料的；不能把需要领料的也弄成
-- 直接直送——采购什么的要去仓库取货。现在领料领不了、开工开不了。」
--
-- 根因：fn_demand_direct_supply_eligible 的第一条判支只看「同车间有在做这个货品的
-- 其它工单」，不看这条需求本身怎么 sourcing——demand.supply_route 是 BUY(采购)/
-- SUBCONTRACT(委外) 的子件，只要车间恰好另有工单在做同货品，也被算成「可直送」。
-- V606 起路线在创建事务内自动识别：存在可直送子件且 WAITING → CONTINUOUS。于是
-- 带采购/委外子件的工单被自动打成持续生产；而持续生产在「部分开工」之前，
-- 领料/开工/分批/核对全部被路线门抑制(V599)，部分开工又要求**每一条**可直送子件
-- 都已经在线边仓到了一部分(V595/2026-09-17 口径)——采购子件的货永远走主仓入库，
-- 线边仓等不来 → 工单两头堵死。
--
-- 修正(ADR-089 §背景第 1 条用户原话「有子件在仓库(其他车间、采购、委外)才需要
-- 领料」的编码化)：第一条判支(同车间在做)额外要求 demand.supply_route = 'MAKE'；
-- 采购/委外口径的子件永远走仓库领料。第二条判支(已有直送行指名指向它)是既成事实
-- (货品比对过的真直送)，保持原样不受 sourcing 影响。
--
-- 影响面(全部随函数收紧自动生效，无需逐处改)：
--   · fn_auto_execution_start_route / V606 创建事务识别——纯采购/委外子件的 WAITING
--     工单不再自动落 CONTINUOUS，落 FULL_KIT 走领料-开工正轨；
--   · confirm-route 的 CONTINUOUS 校验、部分开工时的 direct_supply 冻结、
--     fn_can_start_continuous_supply 的「每种可直送子件都已到一部分」——采购/委外
--     子件不再参与直送前提，也不再被冻结成直送需求；
--   · 车间任务页 routeContinuousEligible 下拉收窄同口径。

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
                     AND producing.status IN ('WAITING', 'READY', 'DISPATCHED', 'IN_PROGRESS')
                     -- V605：采购/委外口径的子件要去仓库取货，不算直送候选；
                     -- 只有自制(MAKE)子件才谈「同车间直送」。
                     AND demand.supply_route = 'MAKE')
               OR EXISTS (
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

COMMENT ON FUNCTION fn_demand_direct_supply_eligible(UUID) IS
    '需求可否由同车间直送供给(V595/V605)：同车间有在产该货品的其它工单且本需求为自制(MAKE)口径，'
    '或已有货品比对过的直送行指向它；采购/委外子件永远走仓库领料。';

-- ============ 存量修正：自动识别打偏的持续生产路线回填 ============
-- V606 的自动识别不产生 ROUTE_CONFIRMED 事件(人工确认才记事件账)。据此把「自动
-- 识别 + 未动过 + 仍在等料」的段按收紧后的尺子重算一遍：被打偏成 CONTINUOUS 的
-- 纯采购/委外工单回到 FULL_KIT，领料/开工通道立即恢复；确属混合链(仍有 MAKE 直送
-- 子件)的保持 CONTINUOUS 不变。人工确认过(有 ROUTE_CONFIRMED 事件)与已动过/已
-- 离开 WAITING 的段一概不动——人工决定与冻结尺(V599)原样尊重，纠偏走既有
-- 「重新确认生产路线」入口。
-- 重算规则与 V606 的 fn_auto_execution_start_route 同一尺子(WAITING + 收紧后仍有
-- 可直送子件 → CONTINUOUS)；该函数 V606 才创建，这里不能引用，口径保持同步。
UPDATE production_execution_segments segment
SET start_route = CASE WHEN EXISTS (
        SELECT 1 FROM production_material_demands demand
        WHERE demand.execution_segment_id = segment.id
          AND demand.is_deleted = FALSE
          AND demand.status NOT IN ('RELEASED', 'REVERSED')
          AND fn_demand_direct_supply_eligible(demand.id))
    THEN 'CONTINUOUS' ELSE 'FULL_KIT' END
WHERE segment.start_route = 'CONTINUOUS'
  AND segment.status = 'WAITING'
  AND NOT segment.is_deleted
  AND fn_can_change_execution_route(segment.id)
  AND NOT EXISTS (SELECT 1 FROM production_execution_segment_events event
                  WHERE event.execution_segment_id = segment.id
                    AND event.action = 'ROUTE_CONFIRMED');
