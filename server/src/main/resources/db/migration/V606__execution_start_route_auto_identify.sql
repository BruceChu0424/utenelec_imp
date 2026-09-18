-- ============ 开工路线自动识别（2026-09-18 用户口径：删除「确认生产路线」步骤） ============
-- 取代 V599 的手工确认门（ADR-091 §2.1「先定路线再卡流程」的显式确认动作退役）：
--   1. 路线在创建事务内按工单事实自动识别——存在可由本车间直送供给的子件且段在
--      WAITING → CONTINUOUS（保住「部分开工 · 持续生产」入口不被齐套自动提升顶掉，
--      V595 竞态口径不变）；否则 → FULL_KIT（零料段 / 下达即齐套 / 纯仓库供料）。
--   2. 分批生产不由创建时识别：点「分批领料」本身就是选择分批——拆批后根段取消、
--      批次段落生即 FULL_KIT、剩余段继承 BATCH（V599 谱系不变）。
--   3. 「部分开工 · 持续生产」同为动作驱动：未动过的工单开工时同事务把路线切到
--      CONTINUOUS（应用层 UPDATE，见 ProductionExecutionSegmentService）。
--   4. 手工改路线通道保留（confirm-route 端点，仅 WAITING 且未动过，fn_can_change
--      口径不变）——自动识别错边时的人工纠偏出口。
-- 路线冻结尺（动过即冻结）、fn_execution_route_allows_auto_promote 的抑制矩阵、
-- ROUTE_CONFIRMED 事件、到货进展卡全部保留，本迁移零行为冲突。

-- 自动识别函数（单一事实源）：创建事务与存量回填共用。
CREATE OR REPLACE FUNCTION fn_auto_execution_start_route(p_segment UUID)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM production_execution_segments segment
        WHERE segment.id = p_segment
          AND segment.status = 'WAITING'
          AND NOT segment.is_deleted
          AND EXISTS (SELECT 1 FROM production_material_demands demand
                      WHERE demand.execution_segment_id = segment.id
                        AND demand.is_deleted = FALSE
                        AND demand.status NOT IN ('RELEASED', 'REVERSED')
                        AND fn_demand_direct_supply_eligible(demand.id)))
        THEN 'CONTINUOUS' ELSE 'FULL_KIT' END
$$;

COMMENT ON FUNCTION fn_auto_execution_start_route(UUID) IS
    '开工路线自动识别(V606)：WAITING 且存在可直送子件→CONTINUOUS，否则 FULL_KIT；'
    '创建事务内赋值与存量 NULL 回填共用。分批路线不入此函数——点「分批领料」即选择分批。';

-- 存量 NULL 路线（V599 部署后创建、尚未人工确认的段）按同一规则一次性回填；
-- 终态段（非 WAITING）恒回填 FULL_KIT。升级后没有任何在途单被路线门锁住。
UPDATE production_execution_segments segment
SET start_route = fn_auto_execution_start_route(segment.id),
    route_confirmed_at = COALESCE(route_confirmed_at, now())
WHERE segment.start_route IS NULL
  AND NOT segment.is_deleted;

-- 自动识别不是人的决定，不产生 ROUTE_CONFIRMED 事件；段的创建 / 拆批 /
-- 持续开工事件本身已可追溯路线来源。无结构、约束与索引变化。
