-- #13 计划部「自底向上、最深层优先」重设计：production_plans 加两列（纯加法，零行为变化）。
--   bom_depth     —— MAKE 树距根深度（0=根，1=直层 MAKE 子…）。NULL=非 orchestrator 计划/旧行。
--                    驱动傻瓜式 UI「最深层可开工优先」排序；深度上限由 orchestrator 调
--                    MrpService.preview→validateBomGraph 在查询时强制（≤10、防环），此处不加 CHECK。
--   auto_generated —— 标记 BottomUpPlanOrchestrator 自动建的子计划：级联回退只冲自动子、
--                     UI 隐藏「待审核」、审计区分。
-- 幂等（IF NOT EXISTS）；可逆（drop 两列+两索引，深度/标志均可由 BOM 重算）。

ALTER TABLE production_plans
    ADD COLUMN IF NOT EXISTS bom_depth INT NULL;

COMMENT ON COLUMN production_plans.bom_depth IS
    'MAKE 树距根深度（0=根，1=直层 MAKE 子…）；NULL 为非 orchestrator 计划。驱动 UI 最深层可开工优先排序。';

ALTER TABLE production_plans
    ADD COLUMN IF NOT EXISTS auto_generated BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN production_plans.auto_generated IS
    'TRUE=由自底向上 orchestrator 自动创建的子计划（审核等状态由服务端翻转，无人工介入）。';

CREATE INDEX IF NOT EXISTS idx_pp_bom_depth
    ON production_plans (bom_depth) WHERE is_deleted = FALSE AND bom_depth IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_pp_auto_generated
    ON production_plans (auto_generated) WHERE is_deleted = FALSE AND auto_generated = TRUE;
