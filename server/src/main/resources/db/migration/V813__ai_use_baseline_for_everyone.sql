-- V813: AI 对话与文件识别对全体员工默认开放(2026-10-06 用户拍板)。
--
-- ai:use 原是 V742(ADR-133/134) 按需授权的码：聊天悬浮入口、客户文件 AI 识别
-- 都查它，普通员工默认没有，入口直接不显示。现在翻进全员基础包——每个在职
-- 员工默认可见可用(含销售侧报价/形式发票识别与附件卡识别)，无需任何授权设置；
-- 访客、强制改密、模拟登录仍被 AiChatAccessPolicy 挡住，个别滥用者仍可按人收回
-- (revoke 恒优先)。名称与归类同步改为全局语义(原「使用 AI 识别客户文件」挂在
-- 销售管理下是当时只有销售在用的历史口径)。
UPDATE permissions SET
    baseline = TRUE,
    name = '使用 AI 助手（对话与文件识别）',
    module = '系统管理',
    category = 'AI 助手',
    description = 'AI 对话、客户文件与附件的 AI 识别；全员默认拥有，个别人员可按人收回'
WHERE code = 'ai:use';

-- V742 给部分部门/个人授过 ai:use：全员基础包后这些行成为冗余(留着无害，
-- 收回口径 revoke 优先不受影响)，不做数据清洗以保持差量最小。

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM permissions
        WHERE code = 'ai:use' AND baseline
          AND NOT (grant_policy && ARRAY['BULK_EXCLUDED', 'INDIVIDUAL_ONLY',
                                         'SUPERADMIN_ONLY']::text[])) THEN
        RAISE EXCEPTION 'ai:use 必须翻进全员基础包且策略允许 baseline';
    END IF;
END;
$$;
