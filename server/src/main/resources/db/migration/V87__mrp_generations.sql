-- =====================================================================
-- V87：业务联动——生产计划物料需求（MRP-lite）→ 采购申请
-- =====================================================================
-- 背景：用户 YTDQ.txt——「添加了个生产计划 那么会不会自动搭配物料 就是给物料下单」。
--   设计：生产计划按 BOM 展开物料毛需求，扣即时库存与在途订货得净需求，
--   一键生成采购申请（草稿，采购员审核后走正常采购流程）。
-- 本迁移：mrp_generations 联动关系表（计划 ↔ 生成的申请，可追溯 + 防重复生成）。
--   幂等规则：同一计划存在未删除且未红冲的生成申请时禁止重复生成；
--   申请被删除/红冲后可再生成（旧联动行软删，留痕可审计）。
-- =====================================================================

CREATE TABLE IF NOT EXISTS mrp_generations (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id     UUID NOT NULL REFERENCES production_plans(id),
    request_id  UUID NOT NULL REFERENCES purchase_requests(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    is_deleted  BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_mrp_gen_plan    ON mrp_generations(plan_id)    WHERE is_deleted = FALSE;
CREATE INDEX IF NOT EXISTS idx_mrp_gen_request ON mrp_generations(request_id) WHERE is_deleted = FALSE;
