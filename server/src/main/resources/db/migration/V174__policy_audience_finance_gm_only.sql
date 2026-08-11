-- V174：政策与监管动态受众收敛（2026-07-31 决策）。
--
-- 该版块不再面向全员：
--   * 财税类（TAX/SUBSIDY/EXPORT）→ FINANCE（财税部）+ GM（总经办直属）；
--   * 检查类（INSPECTION/SAFETY/QUALITY）与其他 → 仅 GM（总经办直属）。
--
-- 说明：
--   * DashboardOverviewService 自本版本起按 category 权威映射过滤，
--     不再信任库存 audience_tags；本迁移仅做数据归一化，保持表里数据与
--     服务端语义一致，并覆盖 V166 初始快照中 QA/HR/PRODUCTION/SECURITY 等宽受众。
--   * GM 标签只授予「直接在总经办」的人员（部门链 depth=0），
--     总经办下级部门员工不经祖先链继承。

UPDATE official_policy_briefs
SET audience_tags = CASE
        WHEN category IN ('TAX', 'SUBSIDY', 'EXPORT')
            THEN '["FINANCE","GM"]'::jsonb
        ELSE '["GM"]'::jsonb
    END,
    updated_at = now();

COMMENT ON COLUMN official_policy_briefs.audience_tags IS
    '受众标签由 category 权威映射决定：财税类=FINANCE+GM，检查类及其他=仅GM；服务端过滤不信任本列，仅作数据快照';
