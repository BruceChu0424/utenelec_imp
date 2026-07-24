-- =====================================================================
-- 审计覆盖扩展（对应审计报告 5.18）
-- 给 department_roles / user_permission_overrides / emergency_contacts 补 AFTER 审计触发器，
-- 逐字复用 V05/V09 的通用 fn_audit()（actor 取 app.actor_id 会话变量，before/after 为 to_jsonb 整行，
-- password_hash 列剔除逻辑对这三张表无影响）。
-- 注：department_roles / user_permission_overrides 为复合主键表（无 id 列），
--     fn_audit 的 target_id 将为 NULL，完整行内容仍在 before/after JSONB 中。
-- =====================================================================
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'department_roles','user_permission_overrides','emergency_contacts'
    ] LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_audit_%1$I ON %1$I;'
            'CREATE TRIGGER trg_audit_%1$I AFTER INSERT OR UPDATE OR DELETE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit();', t);
    END LOOP;
END $$;
