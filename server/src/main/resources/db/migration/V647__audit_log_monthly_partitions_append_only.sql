-- V647 (ADR-105) 审计表按月分区、只追加, 留存改为分区 DDL。
--
-- audit_log 与 audit_log_archive 改为 PARTITION BY RANGE(created_at) 的按月分区表(北京时间月界),
-- 主键含 created_at。在线期满的月分区整区 DETACH 后 ATTACH 到归档表, 归档期满整区 DROP,
-- 不再 5000 行一批 INSERT+DELETE。留存只能经 fn_audit_retention_run() 以表所有者身份执行;
-- 运行账号对审计表没有 UPDATE/DELETE/TRUNCATE, 行级守卫触发器也拒绝任何改删。
-- 保留期读系统设置, 但函数自带法定下限(在线 + 归档合计不少于 6 个月): 运行账号即使改了设置,
-- 也不能借留存函数提前删掉 6 个月内的审计。分区 DDL 一律带 5 秒锁等待上限, 拿不到锁就放弃、
-- 次日重试, 不会让业务写入排在它后面长时间等待。
-- 索引精简到审计页、会话时间线与留存真正用到的几条。
--
-- 迁表时一次性把 actor_account 与行快照里的 login_account 脱敏(保留后 4 位); 未认证登录失败里
-- 不像号码的原始输入(可能是误输的密码)直接置空。其余历史内容原样搬迁。

-- ---------------------------------------------------------------------------
-- 1. 旧表让位, 新建分区父表(列、默认值、CHECK 照抄旧表)
-- ---------------------------------------------------------------------------
ALTER SEQUENCE public.audit_log_id_seq OWNED BY NONE;
ALTER TABLE public.audit_log RENAME TO audit_log_v646;
ALTER TABLE public.audit_log_archive RENAME TO audit_log_archive_v646;

CREATE TABLE public.audit_log (LIKE public.audit_log_v646 INCLUDING DEFAULTS INCLUDING CONSTRAINTS)
    PARTITION BY RANGE (created_at);
ALTER TABLE public.audit_log ADD CONSTRAINT audit_log_pk PRIMARY KEY (id, created_at);
-- 模拟身份期间被模拟的账号; actor_id 始终是真实操作人(security-12)。
ALTER TABLE public.audit_log ADD COLUMN on_behalf_of UUID;
ALTER TABLE public.audit_log ALTER COLUMN risk_level SET NOT NULL;
ALTER TABLE public.audit_log ALTER COLUMN event_category SET NOT NULL;
ALTER TABLE public.audit_log ADD CONSTRAINT audit_log_risk_level_chk
    CHECK (risk_level IN ('critical', 'high', 'medium', 'low'));
ALTER TABLE public.audit_log ADD CONSTRAINT audit_log_event_category_chk
    CHECK (event_category IN ('security', 'authorization', 'authentication', 'export',
                              'data_change', 'system', 'business'));
ALTER TABLE public.audit_log ADD CONSTRAINT audit_log_event_source_chk
    CHECK (event_source IN ('database', 'request', 'business', 'security', 'system'));
ALTER SEQUENCE public.audit_log_id_seq OWNED BY public.audit_log.id;

-- 归档表与在线表逐列、逐约束同形, 月分区才能整区 ATTACH。
CREATE TABLE public.audit_log_archive (LIKE public.audit_log INCLUDING DEFAULTS INCLUDING CONSTRAINTS)
    PARTITION BY RANGE (created_at);
ALTER TABLE public.audit_log_archive ADD CONSTRAINT audit_log_archive_pk PRIMARY KEY (id, created_at);

-- 审计页按时间倒序翻页、按对象/请求/会话/人员核查, 各一条; 其余低选择性索引不再维护。
CREATE INDEX idx_audit_log_created ON public.audit_log (created_at, id);
CREATE INDEX idx_audit_log_target ON public.audit_log (target_type, target_id);
CREATE INDEX idx_audit_log_request ON public.audit_log (request_id) WHERE request_id IS NOT NULL;
CREATE INDEX idx_audit_log_session ON public.audit_log (session_id, created_at DESC, id DESC)
    WHERE session_id IS NOT NULL;
CREATE INDEX idx_audit_log_actor ON public.audit_log (actor_id, created_at DESC) WHERE actor_id IS NOT NULL;
CREATE INDEX idx_audit_archive_created ON public.audit_log_archive (created_at, id);
CREATE INDEX idx_audit_archive_target ON public.audit_log_archive (target_type, target_id);
CREATE INDEX idx_audit_archive_request ON public.audit_log_archive (request_id) WHERE request_id IS NOT NULL;
CREATE INDEX idx_audit_archive_session ON public.audit_log_archive (session_id, created_at DESC, id DESC)
    WHERE session_id IS NOT NULL;
CREATE INDEX idx_audit_archive_actor ON public.audit_log_archive (actor_id, created_at DESC)
    WHERE actor_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. 只追加守卫
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.fn_guard_audit_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
    RAISE EXCEPTION '审计记录只能追加, 不能修改或删除; 过期记录由留存任务按月整批归档和清理'
        USING ERRCODE = '42501';
END;
$$;

CREATE TRIGGER trg_guard_audit_log_append_only BEFORE UPDATE OR DELETE ON public.audit_log
    FOR EACH ROW EXECUTE FUNCTION public.fn_guard_audit_append_only();
CREATE TRIGGER trg_guard_audit_log_no_truncate BEFORE TRUNCATE ON public.audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION public.fn_guard_audit_append_only();
CREATE TRIGGER trg_guard_audit_log_archive_append_only BEFORE UPDATE OR DELETE ON public.audit_log_archive
    FOR EACH ROW EXECUTE FUNCTION public.fn_guard_audit_append_only();
CREATE TRIGGER trg_guard_audit_log_archive_no_truncate BEFORE TRUNCATE ON public.audit_log_archive
    FOR EACH STATEMENT EXECUTE FUNCTION public.fn_guard_audit_append_only();
ALTER TABLE public.audit_log ENABLE ALWAYS TRIGGER trg_guard_audit_log_append_only;
ALTER TABLE public.audit_log ENABLE ALWAYS TRIGGER trg_guard_audit_log_no_truncate;
ALTER TABLE public.audit_log_archive ENABLE ALWAYS TRIGGER trg_guard_audit_log_archive_append_only;
ALTER TABLE public.audit_log_archive ENABLE ALWAYS TRIGGER trg_guard_audit_log_archive_no_truncate;

-- ---------------------------------------------------------------------------
-- 3. 权限封口: 运行账号只能读和追加; 分区只经父表访问。部署加固脚本在通用授权之后再调一次。
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.fn_audit_seal_privileges(p_runtime_role text DEFAULT 'uten') RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    v_partition RECORD;
    v_runtime_is_privileged BOOLEAN;
BEGIN
    EXECUTE 'REVOKE UPDATE, DELETE, TRUNCATE ON TABLE public.audit_log, public.audit_log_archive FROM PUBLIC';
    SELECT r.rolsuper OR pg_has_role(r.oid, c.relowner, 'MEMBER')
      INTO v_runtime_is_privileged
      FROM pg_roles r CROSS JOIN pg_class c
     WHERE r.rolname = p_runtime_role AND c.oid = 'public.audit_log'::regclass;
    IF v_runtime_is_privileged IS NOT NULL AND NOT v_runtime_is_privileged THEN
        EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON TABLE public.audit_log, public.audit_log_archive FROM %I',
                       p_runtime_role);
        EXECUTE format('GRANT SELECT, INSERT ON TABLE public.audit_log TO %I', p_runtime_role);
        EXECUTE format('GRANT SELECT ON TABLE public.audit_log_archive TO %I', p_runtime_role);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.fn_audit_retention_run() TO %I', p_runtime_role);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.fn_audit_ensure_partition(text, date) TO %I',
                       p_runtime_role);
    END IF;
    FOR v_partition IN
        SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent IN ('public.audit_log'::regclass, 'public.audit_log_archive'::regclass)
    LOOP
        EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC', v_partition.relname);
        IF v_runtime_is_privileged IS NOT NULL AND NOT v_runtime_is_privileged THEN
            EXECUTE format('REVOKE ALL ON TABLE public.%I FROM %I', v_partition.relname, p_runtime_role);
        END IF;
    END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_audit_seal_privileges(text) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 4. 月分区: 北京时间月初为界, 命名 <父表>_pYYYYMM。以表所有者身份建, 建完即封口。
-- ---------------------------------------------------------------------------
-- 建分区要短暂独占父表: 最多等 5 秒, 等不到就报错(启动时/次日再建, 提前 3 个月预建, 有余量)。
CREATE FUNCTION public.fn_audit_ensure_partition(p_parent text, p_month date) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
SET lock_timeout = '5s' AS $$
DECLARE
    v_start DATE := date_trunc('month', p_month)::DATE;
    v_suffix TEXT := 'p' || to_char(date_trunc('month', p_month), 'YYYYMM');
    v_name TEXT;
    v_runtime_is_privileged BOOLEAN;
BEGIN
    IF p_parent IS NULL OR p_parent NOT IN ('audit_log', 'audit_log_archive') OR p_month IS NULL THEN
        RAISE EXCEPTION 'audit partition parent must be audit_log or audit_log_archive' USING ERRCODE = '22023';
    END IF;
    IF v_start > (now() AT TIME ZONE 'Asia/Shanghai')::DATE + 366 THEN
        RAISE EXCEPTION 'audit partitions are created at most one year ahead' USING ERRCODE = '22023';
    END IF;
    -- 当月及以后只能在线; 归档分区只收已经过去的月份, 防止抢占在线月份。
    IF p_parent = 'audit_log_archive'
       AND v_start >= date_trunc('month', now() AT TIME ZONE 'Asia/Shanghai')::DATE THEN
        RAISE EXCEPTION 'archive partitions only hold past months' USING ERRCODE = '22023';
    END IF;
    v_name := p_parent || '_' || v_suffix;
    IF to_regclass('public.' || v_name) IS NOT NULL THEN
        RETURN NULL;
    END IF;
    -- 一个月只能在在线或归档其中一边; 已归档的月份不再在线重建。
    IF p_parent = 'audit_log' AND to_regclass('public.audit_log_archive_' || v_suffix) IS NOT NULL THEN
        RAISE EXCEPTION 'audit month % is already archived', to_char(v_start, 'YYYY-MM') USING ERRCODE = '55000';
    END IF;
    IF p_parent = 'audit_log_archive' AND to_regclass('public.audit_log_' || v_suffix) IS NOT NULL THEN
        RAISE EXCEPTION 'audit month % is still online', to_char(v_start, 'YYYY-MM') USING ERRCODE = '55000';
    END IF;
    EXECUTE format('CREATE TABLE public.%I PARTITION OF public.%I FOR VALUES FROM (%L) TO (%L)',
                   v_name, p_parent,
                   (v_start::TIMESTAMP AT TIME ZONE 'Asia/Shanghai'),
                   ((v_start + INTERVAL '1 month')::TIMESTAMP AT TIME ZONE 'Asia/Shanghai'));
    -- 语句级守卫不会从父表继承; 直接截断某个分区同样拒绝。
    EXECUTE format('CREATE TRIGGER trg_guard_audit_partition_no_truncate BEFORE TRUNCATE ON public.%I '
                   'FOR EACH STATEMENT EXECUTE FUNCTION public.fn_guard_audit_append_only()', v_name);
    EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER trg_guard_audit_partition_no_truncate', v_name);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC', v_name);
    SELECT r.rolsuper OR pg_has_role(r.oid, c.relowner, 'MEMBER')
      INTO v_runtime_is_privileged
      FROM pg_roles r CROSS JOIN pg_class c
     WHERE r.rolname = 'uten' AND c.oid = format('public.%I', v_name)::regclass;
    IF v_runtime_is_privileged IS NOT NULL AND NOT v_runtime_is_privileged THEN
        EXECUTE format('REVOKE ALL ON TABLE public.%I FROM uten', v_name);
    END IF;
    RETURN v_name;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_audit_ensure_partition(text, date) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 5. 留存: 保留期从系统设置读取(与审计中心同一口径), 每次运行在同一事务里写一条完成事件。
--    在线表按月整区移入归档(整月都早于在线截止点才移), 归档整月都早于最终截止点才删除。
--    法定下限: 在线 + 归档合计不足 6 个月时按 6 个月算(《网络安全法》第二十一条: 网络日志留存
--    不少于六个月)。下限是函数常量, 只有表所有者改函数才能动, 运行账号改设置压不破它。
--    锁: 先做全部整表扫描(计行数、给待移分区补上与月界一致的 CHECK 并校验, 只占分区上的共享类锁),
--    再集中做 DETACH/ATTACH/DROP; ATTACH 靠已校验的 CHECK 免扫描, 独占父表期间只剩元数据操作;
--    每条 DDL 最多等锁 5 秒, 等不到整次放弃(事务回滚, 次日重试)。
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.fn_audit_retention_run()
RETURNS TABLE(
    hot_months INTEGER,
    archive_months INTEGER,
    hot_cutoff TIMESTAMPTZ,
    archive_cutoff TIMESTAMPTZ,
    archived_partitions TEXT[],
    archived_rows BIGINT,
    dropped_partitions TEXT[],
    dropped_rows BIGINT,
    created_partitions TEXT[],
    completion_event_id BIGINT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
SET lock_timeout = '5s' AS $$
DECLARE
    c_min_total_months CONSTANT INTEGER := 6;
    v_configured_hot INTEGER;
    v_configured_archive INTEGER;
    v_floor_applied BOOLEAN := FALSE;
    v_partition RECORD;
    v_lower TIMESTAMPTZ;
    v_upper TIMESTAMPTZ;
    v_rows BIGINT;
    v_target TEXT;
    v_created TEXT;
    v_offset INTEGER;
    v_index INTEGER;
    v_setting TEXT;
    v_move_names TEXT[] := ARRAY[]::TEXT[];
    v_move_targets TEXT[] := ARRAY[]::TEXT[];
    v_move_lower TIMESTAMPTZ[] := ARRAY[]::TIMESTAMPTZ[];
    v_move_upper TIMESTAMPTZ[] := ARRAY[]::TIMESTAMPTZ[];
    v_move_rows BIGINT[] := ARRAY[]::BIGINT[];
    v_drop_names TEXT[] := ARRAY[]::TEXT[];
    v_drop_rows BIGINT[] := ARRAY[]::BIGINT[];
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('uten.audit.retention'));

    SELECT s.value INTO v_setting FROM public.system_settings s WHERE s.key = 'audit_hot_retention_months';
    v_configured_hot := COALESCE(NULLIF(btrim(v_setting), '')::INTEGER, 6);
    SELECT s.value INTO v_setting FROM public.system_settings s WHERE s.key = 'audit_archive_retention_months';
    v_configured_archive := COALESCE(NULLIF(btrim(v_setting), '')::INTEGER, 30);
    IF v_configured_hot NOT BETWEEN 1 AND 120 OR v_configured_archive NOT BETWEEN 0 AND 240 THEN
        RAISE EXCEPTION 'audit retention months out of range: hot=%, archive=%',
            v_configured_hot, v_configured_archive USING ERRCODE = '22023';
    END IF;
    hot_months := v_configured_hot;
    archive_months := v_configured_archive;
    IF hot_months + archive_months < c_min_total_months THEN
        archive_months := c_min_total_months - hot_months;
        v_floor_applied := TRUE;
    END IF;
    hot_cutoff := now() - make_interval(months => hot_months);
    archive_cutoff := now() - make_interval(months => hot_months + archive_months);
    archived_partitions := ARRAY[]::TEXT[];
    dropped_partitions := ARRAY[]::TEXT[];
    created_partitions := ARRAY[]::TEXT[];
    archived_rows := 0;
    dropped_rows := 0;

    -- 阶段一: 扫描。只占旧月分区上的共享类锁, 业务写入(只写当月分区)不受影响。
    FOR v_partition IN
        SELECT c.relname, pg_get_expr(c.relpartbound, c.oid) AS bound
        FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'public.audit_log'::regclass
        ORDER BY c.relname
    LOOP
        v_lower := substring(v_partition.bound FROM 'FROM \(''([^'']+)''\)')::TIMESTAMPTZ;
        v_upper := substring(v_partition.bound FROM 'TO \(''([^'']+)''\)')::TIMESTAMPTZ;
        CONTINUE WHEN v_lower IS NULL OR v_upper IS NULL OR v_upper > hot_cutoff;
        v_target := 'audit_log_archive_' || substring(v_partition.relname FROM '(p[0-9]{6})$');
        IF v_target IS NULL OR to_regclass('public.' || v_target) IS NOT NULL THEN
            RAISE EXCEPTION 'audit partition % cannot be archived as %', v_partition.relname, v_target
                USING ERRCODE = '55000';
        END IF;
        EXECUTE format('SELECT count(*) FROM public.%I', v_partition.relname) INTO v_rows;
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conrelid = format('public.%I', v_partition.relname)::regclass
                         AND conname = 'audit_month_bound') THEN
            EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT audit_month_bound '
                           'CHECK (created_at IS NOT NULL AND created_at >= %L AND created_at < %L) NOT VALID',
                           v_partition.relname, v_lower, v_upper);
        END IF;
        EXECUTE format('ALTER TABLE public.%I VALIDATE CONSTRAINT audit_month_bound', v_partition.relname);
        v_move_names := v_move_names || v_partition.relname::TEXT;
        v_move_targets := v_move_targets || v_target;
        v_move_lower := v_move_lower || v_lower;
        v_move_upper := v_move_upper || v_upper;
        v_move_rows := v_move_rows || v_rows;
    END LOOP;

    FOR v_partition IN
        SELECT c.relname, pg_get_expr(c.relpartbound, c.oid) AS bound
        FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'public.audit_log_archive'::regclass
        ORDER BY c.relname
    LOOP
        v_upper := substring(v_partition.bound FROM 'TO \(''([^'']+)''\)')::TIMESTAMPTZ;
        CONTINUE WHEN v_upper IS NULL OR v_upper > archive_cutoff;
        EXECUTE format('SELECT count(*) FROM public.%I', v_partition.relname) INTO v_rows;
        v_drop_names := v_drop_names || v_partition.relname::TEXT;
        v_drop_rows := v_drop_rows || v_rows;
    END LOOP;

    -- 阶段二: 只剩元数据操作。整月移入归档; 移入后同样已过最终期限的(长时间停机)随后一并删除。
    FOR v_index IN 1 .. coalesce(array_length(v_move_names, 1), 0) LOOP
        EXECUTE format('ALTER TABLE public.audit_log DETACH PARTITION public.%I', v_move_names[v_index]);
        EXECUTE format('ALTER TABLE public.%I RENAME TO %I', v_move_names[v_index], v_move_targets[v_index]);
        EXECUTE format('ALTER TABLE public.audit_log_archive ATTACH PARTITION public.%I FOR VALUES FROM (%L) TO (%L)',
                       v_move_targets[v_index], v_move_lower[v_index], v_move_upper[v_index]);
        archived_partitions := archived_partitions || v_move_targets[v_index];
        archived_rows := archived_rows + v_move_rows[v_index];
        IF v_move_upper[v_index] <= archive_cutoff THEN
            v_drop_names := v_drop_names || v_move_targets[v_index];
            v_drop_rows := v_drop_rows || v_move_rows[v_index];
        END IF;
    END LOOP;

    FOR v_index IN 1 .. coalesce(array_length(v_drop_names, 1), 0) LOOP
        EXECUTE format('DROP TABLE public.%I', v_drop_names[v_index]);
        dropped_partitions := dropped_partitions || v_drop_names[v_index];
        dropped_rows := dropped_rows + v_drop_rows[v_index];
    END LOOP;

    FOR v_offset IN 0 .. 3 LOOP
        v_created := public.fn_audit_ensure_partition('audit_log',
            (date_trunc('month', now() AT TIME ZONE 'Asia/Shanghai') + make_interval(months => v_offset))::DATE);
        IF v_created IS NOT NULL THEN
            created_partitions := created_partitions || v_created;
        END IF;
    END LOOP;

    INSERT INTO public.audit_log (
        actor_account, action, target_type, target_id, "after", result,
        event_source, risk_level, event_category, device_capture_status)
    VALUES (
        'system', 'audit_retention_completed', 'audit_retention',
        to_char(now() AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD'),
        jsonb_build_object(
            'hot_months', hot_months,
            'archive_months', archive_months,
            'configured_hot_months', v_configured_hot,
            'configured_archive_months', v_configured_archive,
            'minimum_total_months', c_min_total_months,
            'floor_applied', v_floor_applied,
            'hot_cutoff', hot_cutoff,
            'archive_cutoff', archive_cutoff,
            'archived_partitions', to_jsonb(archived_partitions),
            'archived_rows', archived_rows,
            'dropped_partitions', to_jsonb(dropped_partitions),
            'dropped_rows', dropped_rows,
            'created_partitions', to_jsonb(created_partitions)),
        'success', 'system', 'low', 'system', 'missing')
    RETURNING id INTO completion_event_id;
    RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_audit_retention_run() FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 6. 搬迁历史: 旧在线/旧归档里出现过的月份, 只要在线还有该月记录, 整月都留在线上
--    (旧任务按行截断, 同一个月可能被拆在两边); 只出现在旧归档里的月份进归档。
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE audit_v647_months ON COMMIT DROP AS
SELECT month, bool_or(online) AS online
FROM (
    SELECT DISTINCT date_trunc('month', created_at AT TIME ZONE 'Asia/Shanghai')::DATE AS month, TRUE AS online
    FROM public.audit_log_v646
    UNION ALL
    SELECT DISTINCT date_trunc('month', created_at AT TIME ZONE 'Asia/Shanghai')::DATE, FALSE
    FROM public.audit_log_archive_v646
) months
GROUP BY month;

DO $create_partitions$
DECLARE
    v_month DATE;
    v_offset INTEGER;
BEGIN
    FOR v_month IN SELECT month FROM audit_v647_months WHERE online ORDER BY month LOOP
        PERFORM public.fn_audit_ensure_partition('audit_log', v_month);
    END LOOP;
    FOR v_offset IN 0 .. 3 LOOP
        PERFORM public.fn_audit_ensure_partition('audit_log',
            (date_trunc('month', now() AT TIME ZONE 'Asia/Shanghai') + make_interval(months => v_offset))::DATE);
    END LOOP;
    FOR v_month IN SELECT month FROM audit_v647_months WHERE NOT online ORDER BY month LOOP
        PERFORM public.fn_audit_ensure_partition('audit_log_archive', v_month);
    END LOOP;
END;
$create_partitions$;

CREATE FUNCTION pg_temp.audit_v647_mask_snapshot(p_row JSONB) RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_row ? 'login_account' AND jsonb_typeof(p_row -> 'login_account') = 'string'
        THEN jsonb_set(p_row, '{login_account}',
                       COALESCE(to_jsonb(public.fn_audit_mask_account(p_row ->> 'login_account')), 'null'::jsonb))
        ELSE p_row END;
$$;

CREATE FUNCTION pg_temp.audit_v647_mask_actor(p_actor_id UUID, p_action TEXT, p_account TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_actor_id IS NULL AND p_action LIKE '%login_failed%'
             AND public.fn_audit_mask_account(p_account) IS NOT DISTINCT FROM p_account THEN NULL
        ELSE public.fn_audit_mask_account(p_account) END;
$$;

INSERT INTO public.audit_log (
    id, actor_id, actor_account, action, target_type, target_id, "before", "after", ip, user_agent,
    result, created_at, request_id, event_source, http_method, http_path, status_code, duration_ms,
    risk_level, event_category, client_event_id, device_installation_id, device_name,
    device_manufacturer, device_model, device_platform, device_os_version, app_version, app_build,
    device_form_factor, device_browser, device_locale, device_time_zone,
    device_time_zone_offset_minutes, device_is_physical, client_event_at, device_capture_status,
    device_profile_hash, session_id)
SELECT source.id, source.actor_id,
       pg_temp.audit_v647_mask_actor(source.actor_id, source.action, source.actor_account),
       source.action, source.target_type, source.target_id,
       pg_temp.audit_v647_mask_snapshot(source."before"), pg_temp.audit_v647_mask_snapshot(source."after"),
       source.ip, source.user_agent, source.result, source.created_at, source.request_id,
       source.event_source, source.http_method, source.http_path, source.status_code, source.duration_ms,
       COALESCE(source.risk_level, 'low'), COALESCE(source.event_category, 'business'),
       source.client_event_id, source.device_installation_id, source.device_name,
       source.device_manufacturer, source.device_model, source.device_platform, source.device_os_version,
       source.app_version, source.app_build, source.device_form_factor, source.device_browser,
       source.device_locale, source.device_time_zone, source.device_time_zone_offset_minutes,
       source.device_is_physical, source.client_event_at, source.device_capture_status,
       source.device_profile_hash, source.session_id
FROM (
    SELECT id, actor_id, actor_account, action, target_type, target_id, "before", "after", ip, user_agent,
           result, created_at, request_id, event_source, http_method, http_path, status_code, duration_ms,
           risk_level, event_category, client_event_id, device_installation_id, device_name,
           device_manufacturer, device_model, device_platform, device_os_version, app_version, app_build,
           device_form_factor, device_browser, device_locale, device_time_zone,
           device_time_zone_offset_minutes, device_is_physical, client_event_at, device_capture_status,
           device_profile_hash, session_id
    FROM public.audit_log_v646
    UNION ALL
    SELECT archived.id, actor_id, actor_account, action, target_type, target_id, "before", "after", ip, user_agent,
           result, created_at, request_id, event_source, http_method, http_path, status_code, duration_ms,
           risk_level, event_category, client_event_id, device_installation_id, device_name,
           device_manufacturer, device_model, device_platform, device_os_version, app_version, app_build,
           device_form_factor, device_browser, device_locale, device_time_zone,
           device_time_zone_offset_minutes, device_is_physical, client_event_at, device_capture_status,
           device_profile_hash, session_id
    FROM public.audit_log_archive_v646 archived
    JOIN audit_v647_months m
      ON m.month = date_trunc('month', archived.created_at AT TIME ZONE 'Asia/Shanghai')::DATE AND m.online
) source;

INSERT INTO public.audit_log_archive (
    id, actor_id, actor_account, action, target_type, target_id, "before", "after", ip, user_agent,
    result, created_at, request_id, event_source, http_method, http_path, status_code, duration_ms,
    risk_level, event_category, client_event_id, device_installation_id, device_name,
    device_manufacturer, device_model, device_platform, device_os_version, app_version, app_build,
    device_form_factor, device_browser, device_locale, device_time_zone,
    device_time_zone_offset_minutes, device_is_physical, client_event_at, device_capture_status,
    device_profile_hash, session_id)
SELECT archived.id, archived.actor_id,
       pg_temp.audit_v647_mask_actor(archived.actor_id, archived.action, archived.actor_account),
       archived.action, archived.target_type, archived.target_id,
       pg_temp.audit_v647_mask_snapshot(archived."before"), pg_temp.audit_v647_mask_snapshot(archived."after"),
       archived.ip, archived.user_agent, archived.result, archived.created_at, archived.request_id,
       archived.event_source, archived.http_method, archived.http_path, archived.status_code,
       archived.duration_ms, COALESCE(archived.risk_level, 'low'), COALESCE(archived.event_category, 'business'),
       archived.client_event_id, archived.device_installation_id, archived.device_name,
       archived.device_manufacturer, archived.device_model, archived.device_platform,
       archived.device_os_version, archived.app_version, archived.app_build, archived.device_form_factor,
       archived.device_browser, archived.device_locale, archived.device_time_zone,
       archived.device_time_zone_offset_minutes, archived.device_is_physical, archived.client_event_at,
       archived.device_capture_status, archived.device_profile_hash, archived.session_id
FROM public.audit_log_archive_v646 archived
JOIN audit_v647_months m
  ON m.month = date_trunc('month', archived.created_at AT TIME ZONE 'Asia/Shanghai')::DATE AND NOT m.online;

DO $verify_copy$
BEGIN
    IF (SELECT count(*) FROM public.audit_log) + (SELECT count(*) FROM public.audit_log_archive)
       <> (SELECT count(*) FROM public.audit_log_v646) + (SELECT count(*) FROM public.audit_log_archive_v646) THEN
        RAISE EXCEPTION 'V647 audit history copy lost rows' USING ERRCODE = '55000';
    END IF;
END;
$verify_copy$;

DROP TABLE public.audit_log_v646;
DROP TABLE public.audit_log_archive_v646;

SELECT public.fn_audit_seal_privileges('uten');
