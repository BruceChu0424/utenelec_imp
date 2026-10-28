-- B3-W1: 归档审计可读（跨层一致读取）。
--
-- 现状：audit_log（在线月分区）与 audit_log_archive（冷归档月分区）逐列同形（V671），
-- 归档搬移由 fn_audit_retention_run() 整月 DETACH/ATTACH 完成，V770 后只搬不删；
-- 但审计中心只读在线表——含归档月份的查询被整体拒绝（CONFLICT/NOT_FOUND），
-- 「能归不能查」与永久保留合同冲突。
--
-- 本迁移：
--   1) 形状断言：两表逐列逐类型逐序一致，不一致则迁移失败（不静默建出错位视图）；
--   2) v_audit_log_all 视图 = 在线 UNION ALL 归档，全部审计读面跨层；
--   3) INSTEAD OF INSERT 触发器：应用写路径（AuditLog 实体/JPA）不改一行，
--      插入仍落在在线表 audit_log；V556 trg_audit_classify 继续重算风险/类型；
--   4) 运行角色授权沿用 V671 封口口径（角色存在且非特权才显式 GRANT）。
--
-- 只追加守卫不受影响：视图不可 UPDATE/DELETE，在线/归档两表的只追加触发器原样生效。

DO $shape_guard$
DECLARE
    v_divergent bigint;
BEGIN
    SELECT count(*) INTO v_divergent
    FROM (
        SELECT column_name, data_type, ordinal_position
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name IN ('audit_log', 'audit_log_archive')
        GROUP BY column_name, data_type, ordinal_position
        HAVING count(DISTINCT table_name) <> 2
    ) divergent;
    IF v_divergent <> 0 THEN
        RAISE EXCEPTION
            'audit_log 与 audit_log_archive 列形状不一致（% 处），拒绝创建统一读取视图；先补齐同形列再重放本迁移',
            v_divergent;
    END IF;
END
$shape_guard$;

CREATE VIEW public.v_audit_log_all AS
SELECT * FROM public.audit_log
UNION ALL
SELECT * FROM public.audit_log_archive;

COMMENT ON VIEW public.v_audit_log_all IS
    '审计统一读取层：在线 audit_log UNION ALL 冷归档 audit_log_archive；'
    '只读为主，INSERT 经 INSTEAD OF 触发器落在线表（分类触发器继续生效）；UPDATE/DELETE 不可用';

CREATE FUNCTION public.fn_audit_log_all_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    -- 统一视图上的 INSERT 一律落在在线表：审计写入仍是 audit_log 单通道，
    -- 分区维护、留存搬移与 V556 分类触发器语义全部保持。
    IF NEW.id IS NULL THEN
        INSERT INTO public.audit_log (
            actor_id, actor_account, session_id, action, target_type, target_id,
            "before", "after", ip, user_agent, result, created_at,
            request_id, event_source, http_method, http_path, status_code, duration_ms,
            risk_level, event_category,
            client_event_id, client_event_at, device_installation_id,
            device_name, device_manufacturer, device_model, device_platform,
            device_os_version, app_version, app_build, device_form_factor, device_browser,
            device_locale, device_time_zone, device_time_zone_offset_minutes,
            device_is_physical, device_capture_status, device_profile_hash, on_behalf_of
        ) VALUES (
            NEW.actor_id, NEW.actor_account, NEW.session_id, NEW.action,
            NEW.target_type, NEW.target_id,
            NEW."before", NEW."after", NEW.ip, NEW.user_agent, NEW.result, NEW.created_at,
            NEW.request_id, NEW.event_source, NEW.http_method, NEW.http_path,
            NEW.status_code, NEW.duration_ms,
            NEW.risk_level, NEW.event_category,
            NEW.client_event_id, NEW.client_event_at, NEW.device_installation_id,
            NEW.device_name, NEW.device_manufacturer, NEW.device_model, NEW.device_platform,
            NEW.device_os_version, NEW.app_version, NEW.app_build, NEW.device_form_factor,
            NEW.device_browser, NEW.device_locale, NEW.device_time_zone,
            NEW.device_time_zone_offset_minutes,
            NEW.device_is_physical, NEW.device_capture_status, NEW.device_profile_hash,
            NEW.on_behalf_of
        ) RETURNING id INTO NEW.id;
    ELSE
        INSERT INTO public.audit_log (
            id, actor_id, actor_account, session_id, action, target_type, target_id,
            "before", "after", ip, user_agent, result, created_at,
            request_id, event_source, http_method, http_path, status_code, duration_ms,
            risk_level, event_category,
            client_event_id, client_event_at, device_installation_id,
            device_name, device_manufacturer, device_model, device_platform,
            device_os_version, app_version, app_build, device_form_factor, device_browser,
            device_locale, device_time_zone, device_time_zone_offset_minutes,
            device_is_physical, device_capture_status, device_profile_hash, on_behalf_of
        ) VALUES (
            NEW.id, NEW.actor_id, NEW.actor_account, NEW.session_id, NEW.action,
            NEW.target_type, NEW.target_id,
            NEW."before", NEW."after", NEW.ip, NEW.user_agent, NEW.result, NEW.created_at,
            NEW.request_id, NEW.event_source, NEW.http_method, NEW.http_path,
            NEW.status_code, NEW.duration_ms,
            NEW.risk_level, NEW.event_category,
            NEW.client_event_id, NEW.client_event_at, NEW.device_installation_id,
            NEW.device_name, NEW.device_manufacturer, NEW.device_model, NEW.device_platform,
            NEW.device_os_version, NEW.app_version, NEW.app_build, NEW.device_form_factor,
            NEW.device_browser, NEW.device_locale, NEW.device_time_zone,
            NEW.device_time_zone_offset_minutes,
            NEW.device_is_physical, NEW.device_capture_status, NEW.device_profile_hash,
            NEW.on_behalf_of
        );
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_log_all_insert
    INSTEAD OF INSERT ON public.v_audit_log_all
    FOR EACH ROW EXECUTE FUNCTION public.fn_audit_log_all_insert();

COMMENT ON FUNCTION public.fn_audit_log_all_insert() IS
    '审计统一视图的写入通道：INSERT 落在线表 audit_log；id 为空走序列，risk/event 分类由 V556 触发器重算';

-- 与 V671 fn_audit_seal_privileges 相同的口径：运行角色存在且非特权才显式授权，
-- 角色不存在（测试容器 owner 直连等场景）时跳过，不阻断迁移。
DO $grant_guard$
DECLARE
    v_privileged BOOLEAN;
BEGIN
    SELECT r.rolsuper OR pg_has_role(r.oid, c.relowner, 'MEMBER')
      INTO v_privileged
      FROM pg_roles r CROSS JOIN pg_class c
     WHERE r.rolname = 'uten' AND c.oid = 'public.audit_log'::regclass;
    IF v_privileged IS NOT NULL AND NOT v_privileged THEN
        GRANT SELECT, INSERT ON TABLE public.v_audit_log_all TO uten;
        GRANT EXECUTE ON FUNCTION public.fn_audit_log_all_insert() TO uten;
    END IF;
END
$grant_guard$;
