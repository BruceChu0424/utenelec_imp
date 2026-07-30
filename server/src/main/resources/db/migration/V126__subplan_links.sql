-- =====================================================================
-- V126：业务联动——生产计划 → 自制件子计划 联动关系
-- =====================================================================
-- 与 V87 mrp_generations（计划→采购申请）、V88 plan_draw_links（计划→领料单）同构：
-- 父计划 MRP 展开后，对「自制件」（本身有 BOM 的组件）按净需求一键生成下层生产计划（草稿），
-- 留痕 + 防重复。幂等规则一致：存在未删除且未红冲的子计划时禁止重复生成；
-- 子计划被删除/红冲后可再生成（旧联动行软删，留痕可审计）。
-- 多层 BOM：打开子计划的 MRP 面板可继续向下生成，逐级展开。
-- =====================================================================

CREATE TABLE IF NOT EXISTS subplan_links (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id     UUID NOT NULL REFERENCES production_plans(id),
    subplan_id  UUID NOT NULL REFERENCES production_plans(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    is_deleted  BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_spl_plan ON subplan_links(plan_id) WHERE is_deleted = FALSE;
CREATE INDEX IF NOT EXISTS idx_spl_subplan ON subplan_links(subplan_id) WHERE is_deleted = FALSE;
