-- =====================================================================
-- 修复 V18 的坏审计触发器（profile_change_requests）
--
-- 问题：V18 自建的 audit_profile_change_requests() 向 audit_log 插入
--       before_jsonb / after_jsonb 两列，但 audit_log 的列结构以 V05 建表
--       （+ V09 fn_audit 重写）为准，只有 before / "after"，全仓无任何迁移
--       添加过 before_jsonb/after_jsonb；V20 只补了 profile_change_requests
--       的 created_by/updated_by，未补救 audit_log。
--       后果：触发器函数体内的 INSERT 在首次执行时即报
--       "column after_jsonb of relation audit_log does not exist"，
--       使 profile_change_requests 上的 INSERT/UPDATE/DELETE 整体回滚。
--
-- 修复：DROP 坏触发器与坏函数，改用 V05/V09 通用 fn_audit()
--       （V12/V22 同款模式）重新挂触发器。既有迁移文件一律不改。
-- =====================================================================
DROP TRIGGER IF EXISTS trg_audit_profile_change_requests ON profile_change_requests;
DROP FUNCTION IF EXISTS audit_profile_change_requests();

CREATE TRIGGER trg_audit_profile_change_requests
    AFTER INSERT OR UPDATE OR DELETE ON profile_change_requests
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
