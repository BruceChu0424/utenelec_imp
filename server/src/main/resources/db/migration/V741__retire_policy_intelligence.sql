-- =====================================================================
-- V741 (ADR-133) 退役「政策情报」AI: 删除 official_policy_briefs 与 dashboard:finance_sensitive:view
-- =====================================================================
-- 背景(2026-09-27 用户原话): 「ai 相关的以前的代码 还有 api 在文件中都对应的删除先 之前写过
--   相关新闻之类的 ai 把那些相关的文件 代码 展示 ui 都删除 不需要那个了」。
--   V166 为工作台「政策情报」卡建了 official_policy_briefs(外部抓取的政策摘要 + 旧的
--   DeepSeek 摘要), 同时建了工作台财务敏感指标码(V677 改名为 dashboard:finance_sensitive:view,
--   唯一用途是让持有人看到财税类政策情报)。新的公共 AI 平台(V742, ADR-133)不复用这张表,
--   服务端与前端的政策情报代码、配置键和页面由同一轮改动删除。
--
-- 本迁移:
--   1. DROP TABLE official_policy_briefs(0 行即可安全删除; 有行也一并删除, 这是外部抓取的
--      展示缓存, 不是业务事实, 也不被任何表引用)。
--   2. business_data_reset() 孪生函数同步移除 ('official_policy_briefs', 'PRESERVE') 行
--      (V590/V677 同款「读已安装定义 + 单行 needle 替换」失败关闭补丁), 否则清空时
--      「策略表 vs 实存表」目录核对会失败关闭。
--   3. 退役权限码 dashboard:finance_sensitive:view: 先删页面权限面映射(外键 RESTRICT),
--      再删目录行; 部门授权、个人覆盖与负责人委派随外键级联删除(V677 第 4 节同款)。
--
-- 登记: 清库策略 REMOVED(BusinessDataResetSqlContractTest.REMOVED_RESET_TABLES)、ops 脚本
--   删行并拆分 PRESERVE 计数闸(741 → 101)、审计三清单从 FULL/master 组移除、迁移演练
--   intentionallyDropped、迁移头(README / ops 白名单)。
-- =====================================================================

DROP TABLE official_policy_briefs;

-- 清空函数孪生同步: needle 单行无换行符, 不受迁移文件 CRLF/LF 差异影响(V588 教训)。
DO $$
DECLARE
    definition TEXT;
    needle TEXT := '(''official_policy_briefs'', ''PRESERVE''),';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, needle, ''))) / length(needle) <> 1 THEN
        RAISE EXCEPTION 'V741 cannot drop retired official_policy_briefs from business_data_reset';
    END IF;
    definition := replace(definition, needle, '');
    EXECUTE definition;
END;
$$;

-- 退役工作台财务敏感指标码(只用于财税类政策情报的可见范围, 政策情报随本轮删除)。
DELETE FROM permission_surface_permissions mapping
USING permissions permission
WHERE mapping.permission_id = permission.id
  AND permission.code = 'dashboard:finance_sensitive:view';

DELETE FROM permissions
WHERE code = 'dashboard:finance_sensitive:view';
