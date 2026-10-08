-- V830: 500 来源规模物料分析写入路径三处收口(ADR-107 事务预算 40s)。
--
-- 根因(2026-10-08 压测栈): 首次分析 preview 事务里, 快照 upsert 约 49,500 行后,
-- autoConfirmDecisiveRoutes 的批量路线 UPDATE 触发 ~49,500 次行级审计触发器
-- (每次 2x 整行 to_jsonb + 逐列 jsonb diff + 单行 INSERT audit_log), 再加每行
-- route_confirmed_by 的 RI 事件, 40 秒预算在单条 UPDATE 内被耗尽。
--
-- 本迁移不改任何审计语义: 每条真实变更仍落一行 audit_log, 内容(前后值)与通用
-- 版本逐字段一致(有金样等值测试钉死)。审计触发器仍逐行执行, 但从通用 fn_audit
-- (每行 2x 整行 to_jsonb + 全列 jsonb diff + 3x minimize + 主档改号分支, 成本随
-- 表宽增长——本表 45+ 列)换成专用窄投影函数 fn_audit_route_columns(只比 3 个
-- 审计列、只构造变化键的 jsonb, 成本与表宽无关)。
-- 实测取舍(50k 行 UPDATE, PostgreSQL 16, 45 列宽表, 生产形索引): 通用 fn_audit
-- ~26s, 语句级 transition-table 批量 ~14s(窄表上也仅与通用持平——tuplestore 物化
-- +逐行相关子查询抵消了收益), 窄函数 ~6s(成本与表宽无关)。语句级批量方案已实证
-- 不优, 弃用; 窄函数是既有"审计窄投影"原型的可测化落地, 配金样等值测试钉死语义。
--
-- 另两处: plan_links 补 analysis_id 领头索引(路线冲突检查 CTE 按分析过滤原先
-- 只能顺扫); exact-peg 校验函数加"本行没有任何精确归属"的提前返回探测, 探测
-- 对齐 idx_preplan_exact_peg_beneficiary 领头列(原函数只按 material_id 探测,
-- 用不上索引领头列), 首次分析的 49,500 行 INSERT 在提交期不再逐行跑完整函数。

-- ---------------------------------------------------------------------------
-- 1. plan_links: 分析级领头索引。
--    RouteBatchWriter 冲突检查/已下来源 CTE 均按 analysis_id + allocation_status
--    过滤; 原唯一可用索引 (analysis_item_id, allocation_status, plan_id) 领头列
--    不匹配, 只能顺扫。
-- ---------------------------------------------------------------------------
CREATE INDEX idx_production_material_analysis_plan_link_analysis
    ON production_material_analysis_plan_links(analysis_id, allocation_status);

-- ---------------------------------------------------------------------------
-- 2. exact-peg 端点校验: 无归属先返回。
--    受益复合外键 (beneficiary_analysis_id, beneficiary_analysis_material_id)
--    引用 materials(analysis_id, id), 因此 beneficiary_analysis_material_id =
--    NEW.id 的 peg 必然有 beneficiary_analysis_id = NEW.analysis_id; 探测带上
--    领头列即可走 idx_preplan_exact_peg_beneficiary。常规刷新/首建的行没有
--    任何指向自己的精确归属, 单次索引探测即返回, 不再进原四表 EXISTS。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_validate_pma_material_exact_peg_endpoint()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM preplan_analysis_stock_exact_pegs peg
        WHERE peg.beneficiary_analysis_id = NEW.analysis_id
          AND peg.beneficiary_analysis_material_id = NEW.id
    ) THEN
        RETURN NEW;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM preplan_analysis_stock_exact_pegs peg
        JOIN stock_reservations reservation
          ON reservation.id = peg.stock_reservation_id
         AND reservation.is_deleted = FALSE
         AND reservation.status = 0
        JOIN procurement_inspection_events event
          ON event.id = peg.source_disposition_event_id
        JOIN procurement_inspection_items inspection
          ON inspection.id = event.inspection_item_id
        LEFT JOIN production_material_analysis_materials beneficiary
          ON beneficiary.id = peg.beneficiary_analysis_material_id
         AND beneficiary.analysis_id = peg.beneficiary_analysis_id
        WHERE peg.beneficiary_analysis_material_id = NEW.id
          AND (
              beneficiary.id IS NULL
              OR beneficiary.active IS DISTINCT FROM TRUE
              OR beneficiary.goods_id IS DISTINCT FROM reservation.goods_id
              OR beneficiary.color_id IS DISTINCT FROM reservation.color_id
              OR beneficiary.unit_id IS DISTINCT FROM inspection.unit_id
          )
    ) THEN
        RAISE EXCEPTION 'effective preplan exact stock peg requires an active matching material endpoint'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. 路线三列的专用窄投影审计函数。
--    与 fn_audit('data_change','plain','confirmed_route','route_reason',
--    'route_confirmed_by') 在本表上逐字段等值:
--      - before/after 只含真正变化的审计列(通用版 scope 过滤后的同一集合);
--      - 本表没有定位键列(bill_no/code/name/... 均不存在), locator 恒为 '{}';
--      - 三列不在 fn_audit_redact_row 的敏感清单内且本表 plain, minimize 为
--        恒等(等值测试钉死); 也没有 is_deleted/deleted_at 软删翻转分支;
--      - 不属于主档改号四表, master_code 分支恒不进入。
--    差异只有执行方式: 通用版先把整行(45+ 列)做两次 to_jsonb 再全列 diff;
--    本函数直接比较 3 列、只序列化变化键。target_id 直接取 NEW.id(本表有 id 列)。
--    审计上下文(actor/ip/ua/request/device)与通用版同一套 current_setting。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_audit_route_columns() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    v_before jsonb := '{}'::jsonb;
    v_after  jsonb := '{}'::jsonb;
    v_device jsonb;
BEGIN
    IF current_setting('app.legacy_import', true) = 'on' THEN
        RETURN NULL;
    END IF;
    IF OLD.confirmed_route IS DISTINCT FROM NEW.confirmed_route THEN
        v_before := v_before || jsonb_build_object('confirmed_route', to_jsonb(OLD.confirmed_route));
        v_after  := v_after  || jsonb_build_object('confirmed_route', to_jsonb(NEW.confirmed_route));
    END IF;
    IF OLD.route_reason IS DISTINCT FROM NEW.route_reason THEN
        v_before := v_before || jsonb_build_object('route_reason', to_jsonb(OLD.route_reason));
        v_after  := v_after  || jsonb_build_object('route_reason', to_jsonb(NEW.route_reason));
    END IF;
    IF OLD.route_confirmed_by IS DISTINCT FROM NEW.route_confirmed_by THEN
        v_before := v_before || jsonb_build_object('route_confirmed_by', to_jsonb(OLD.route_confirmed_by));
        v_after  := v_after  || jsonb_build_object('route_confirmed_by', to_jsonb(NEW.route_confirmed_by));
    END IF;
    IF v_after = '{}'::jsonb THEN
        RETURN NULL;
    END IF;
    v_device := COALESCE(
        NULLIF(current_setting('app.audit_device_context', true), '')::JSONB,
        '{}'::JSONB);
    INSERT INTO public.audit_log (
        actor_id, actor_account, action, target_type, target_id,
        before, "after", ip, user_agent, result, request_id, event_source,
        risk_level, event_category,
        client_event_id, device_installation_id, device_name,
        device_manufacturer, device_model, device_platform,
        device_os_version, app_version, app_build, device_form_factor,
        device_browser, device_locale, device_time_zone,
        device_time_zone_offset_minutes, device_is_physical, client_event_at,
        device_capture_status, device_profile_hash)
    VALUES (
        NULLIF(current_setting('app.actor_id', true), '')::UUID,
        public.fn_audit_mask_account(NULLIF(current_setting('app.actor_account', true), '')),
        'update', TG_TABLE_NAME, NEW.id,
        v_before, v_after,
        NULLIF(current_setting('app.audit_ip', true), ''),
        NULLIF(current_setting('app.audit_user_agent', true), ''),
        'success',
        NULLIF(current_setting('app.audit_request_id', true), '')::UUID,
        'database', 'low', 'data_change',
        NULLIF(v_device ->> 'clientEventId', '')::UUID,
        NULLIF(v_device ->> 'installationId', '')::UUID,
        NULLIF(v_device ->> 'deviceName', ''),
        NULLIF(v_device ->> 'manufacturer', ''),
        NULLIF(v_device ->> 'model', ''),
        NULLIF(v_device ->> 'platform', ''),
        NULLIF(v_device ->> 'osVersion', ''),
        NULLIF(v_device ->> 'appVersion', ''),
        NULLIF(v_device ->> 'appBuild', ''),
        NULLIF(v_device ->> 'formFactor', ''),
        NULLIF(v_device ->> 'browserName', ''),
        NULLIF(v_device ->> 'locale', ''),
        NULLIF(v_device ->> 'timeZone', ''),
        NULLIF(v_device ->> 'timeZoneOffsetMinutes', '')::INTEGER,
        NULLIF(v_device ->> 'physicalDevice', '')::BOOLEAN,
        NULLIF(v_device ->> 'clientEventAt', '')::TIMESTAMPTZ,
        COALESCE(NULLIF(v_device ->> 'captureStatus', ''), 'missing'),
        NULLIF(v_device ->> 'profileHash', ''));
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.fn_audit_route_columns() IS
    'production_material_analysis_materials 路线三列的窄投影行级审计; 与通用 fn_audit 在该表逐字段等值(金样等值测试钉死), 见 V830';

-- ---------------------------------------------------------------------------
-- 4. 登记入口增加 p_update_fn: COLUMN_SCOPED 表可把 UPDATE 审计指到专用窄函数。
--    触发器形态(UPDATE OF <列> + WHEN(任一列变化) + ENABLE ALWAYS)与通用路径
--    完全一致, 只是 EXECUTE FUNCTION 换成给定函数; 窄函数不读 TG_ARGV, 列清单
--    由本处的 UPDATE OF/WHEN 承载。其余策略(FULL/NONE、插入/删除行级触发器)不变。
--
--    注意: CREATE OR REPLACE 只替换同参个数签名, 加 p_update_fn 是新增重载——
--    必须先 DROP V670 的 6 参旧签名, 否则 2..6 参调用(既有 11 个迁移与守护
--    测试的登记惯例)在两个候选间无法裁决, 直接 42725 is not unique。
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.fn_audit_track_table(text, text, text, boolean, text[], boolean);
CREATE OR REPLACE FUNCTION public.fn_audit_track_table(
    p_table text,
    p_policy text,
    p_category text DEFAULT 'data_change',
    p_redacted boolean DEFAULT false,
    p_columns text[] DEFAULT NULL,
    p_insert_delete boolean DEFAULT true,
    p_update_fn text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    v_relid OID;
    v_trigger RECORD;
    v_args TEXT;
    v_when TEXT;
    v_columns TEXT;
    v_missing TEXT;
    v_update_fn TEXT;
    v_row_name TEXT := left('trg_audit_' || p_table, 63);
    v_update_name TEXT := left('trg_audit_upd_' || p_table, 63);
BEGIN
    SELECT c.oid INTO v_relid
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = p_table
      AND c.relkind IN ('r', 'p') AND NOT c.relispartition;
    IF v_relid IS NULL THEN
        RAISE EXCEPTION 'audit policy table public.% does not exist', p_table USING ERRCODE = '42P01';
    END IF;
    IF p_policy IS NULL OR p_policy NOT IN ('FULL', 'COLUMN_SCOPED', 'NONE') THEN
        RAISE EXCEPTION 'audit policy for % must be FULL, COLUMN_SCOPED or NONE', p_table USING ERRCODE = '22023';
    END IF;
    IF p_category IS NULL OR p_category NOT IN ('data_change', 'authorization', 'system') THEN
        RAISE EXCEPTION 'audit category for % is not registered', p_table USING ERRCODE = '22023';
    END IF;
    IF p_table IN ('audit_log', 'audit_log_archive') AND p_policy <> 'NONE' THEN
        RAISE EXCEPTION 'the audit sink cannot audit itself' USING ERRCODE = '22023';
    END IF;
    IF p_update_fn IS NOT NULL AND p_policy <> 'COLUMN_SCOPED' THEN
        RAISE EXCEPTION 'custom UPDATE audit function of % requires COLUMN_SCOPED policy', p_table USING ERRCODE = '22023';
    END IF;
    -- 归一成不带括号的规范名, 登记处统一以 fn(args) 形态拼触发器。
    v_update_fn := regexp_replace(COALESCE(p_update_fn, 'public.fn_audit()'), '\(\)\s*$', '');
    IF to_regprocedure(v_update_fn || '()') IS NULL THEN
        RAISE EXCEPTION 'UPDATE audit function % does not exist', v_update_fn USING ERRCODE = '42883';
    END IF;

    -- 拆除按 OID 直比(与 V670 同式, 不受 search_path 同名歧义影响); to_regprocedure
    -- 为 NULL 的元素永不等于任何 tgfoid, 不会误拆。
    FOR v_trigger IN
        SELECT t.tgname FROM pg_trigger t
        WHERE t.tgrelid = v_relid AND NOT t.tgisinternal AND t.tgparentid = 0
          AND t.tgfoid = ANY (ARRAY[
                  to_regprocedure('public.fn_audit()'),
                  to_regprocedure('public.fn_audit_route_columns()')])
    LOOP
        EXECUTE format('DROP TRIGGER %I ON public.%I', v_trigger.tgname, p_table);
    END LOOP;
    IF p_policy = 'NONE' THEN
        RETURN;
    END IF;

    v_args := quote_literal(p_category) || ', '
        || quote_literal(CASE WHEN p_redacted THEN 'redacted' ELSE 'plain' END);
    IF p_policy = 'FULL' THEN
        IF p_columns IS NOT NULL THEN
            RAISE EXCEPTION 'FULL audit of % must not carry a column list', p_table USING ERRCODE = '22023';
        END IF;
        EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR DELETE ON public.%I '
                       'FOR EACH ROW EXECUTE FUNCTION public.fn_audit(%s)', v_row_name, p_table, v_args);
        EXECUTE format('CREATE TRIGGER %I AFTER UPDATE ON public.%I '
                       'FOR EACH ROW WHEN (OLD.* IS DISTINCT FROM NEW.*) '
                       'EXECUTE FUNCTION public.fn_audit(%s)', v_update_name, p_table, v_args);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I', p_table, v_row_name);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I', p_table, v_update_name);
        RETURN;
    END IF;

    IF p_columns IS NULL OR cardinality(p_columns) = 0 THEN
        RAISE EXCEPTION 'COLUMN_SCOPED audit of % needs a column list', p_table USING ERRCODE = '22023';
    END IF;
    SELECT string_agg(c, ', ') INTO v_missing
    FROM unnest(p_columns) AS c
    WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
                      WHERE a.attrelid = v_relid AND a.attname = c
                        AND a.attnum > 0 AND NOT a.attisdropped);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'COLUMN_SCOPED audit of % names unknown columns: %', p_table, v_missing
            USING ERRCODE = '42703';
    END IF;
    SELECT string_agg(quote_ident(c), ', ' ORDER BY ord),
           string_agg(format('OLD.%1$I IS DISTINCT FROM NEW.%1$I', c), ' OR ' ORDER BY ord),
           v_args || ', ' || string_agg(quote_literal(c), ', ' ORDER BY ord)
      INTO v_columns, v_when, v_args
      FROM unnest(p_columns) WITH ORDINALITY AS scoped(c, ord);
    EXECUTE format('CREATE TRIGGER %I AFTER UPDATE OF %s ON public.%I '
                   'FOR EACH ROW WHEN (%s) EXECUTE FUNCTION %s(%s)',
                   v_update_name, v_columns, p_table, v_when, v_update_fn,
                   CASE WHEN p_update_fn IS NULL THEN v_args ELSE '' END);
    IF p_insert_delete THEN
        EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR DELETE ON public.%I '
                       'FOR EACH ROW EXECUTE FUNCTION public.fn_audit(%s)', v_row_name, p_table, v_args);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I', p_table, v_row_name);
    END IF;
    EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I', p_table, v_update_name);
END;
$$;
REVOKE ALL ON FUNCTION public.fn_audit_track_table(text, text, text, boolean, text[], boolean, text) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 5. 物料行路线审计切到窄函数; 列清单/类别/不审插入删除均不变。
-- ---------------------------------------------------------------------------
SELECT public.fn_audit_track_table('production_material_analysis_materials', 'COLUMN_SCOPED', 'data_change', false,
    ARRAY['confirmed_route', 'route_reason', 'route_confirmed_by'], false, 'public.fn_audit_route_columns()');
