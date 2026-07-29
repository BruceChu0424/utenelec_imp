-- =====================================================================
-- V88：业务联动——生产计划 → 生产领料单（DRAW）联动关系
-- =====================================================================
-- 与 V87 mrp_generations（计划→采购申请）同构：计划→领料单的生成留痕 + 防重复。
--   幂等规则一致：同一计划存在未删除且未红冲的生成领料单时禁止重复生成；
--   领料单被删除/红冲后可再生成（旧联动行软删，留痕可审计）。
-- =====================================================================

CREATE TABLE IF NOT EXISTS plan_draw_links (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id     UUID NOT NULL REFERENCES production_plans(id),
    draw_id     UUID NOT NULL REFERENCES stock_documents(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    is_deleted  BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_pdl_plan ON plan_draw_links(plan_id) WHERE is_deleted = FALSE;
CREATE INDEX IF NOT EXISTS idx_pdl_draw ON plan_draw_links(draw_id) WHERE is_deleted = FALSE;
