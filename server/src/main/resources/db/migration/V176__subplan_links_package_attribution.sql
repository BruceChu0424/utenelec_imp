-- subplan_links 归属列：区分"V1 执行分段确认产生"与"旧版/手动产生"的自制件子计划。
--
-- 背景：V1 confirm（generate-planning-package）现在会在事务内为 BOM 中的自制组件
-- 派生子生产计划并写 subplan_links。但 ProductionExecutionPackageCommandService
-- 的 loadLegacyExecutionFacts 原本把任何 subplan_links 都当作"旧执行事实"拒绝，
-- 导致 V1 自己产生的子计划会阻塞该计划后续的 confirm（续排/重放）。
--
-- 解法：V1 产生时写入 planning_package_id + source='EXECUTION_V1'；互斥检查排除
-- 这些记录（仅把 planning_package_id IS NULL 或 source 非 EXECUTION_V1 的视为旧事实）。
-- 旧版/手动产生的子计划语义不变，仍按旧事实拦截。

ALTER TABLE subplan_links
    ADD COLUMN IF NOT EXISTS planning_package_id UUID NULL;

ALTER TABLE subplan_links
    ADD COLUMN IF NOT EXISTS source VARCHAR(32) NULL;

CREATE INDEX IF NOT EXISTS idx_spl_package
    ON subplan_links (planning_package_id)
    WHERE is_deleted = FALSE;
