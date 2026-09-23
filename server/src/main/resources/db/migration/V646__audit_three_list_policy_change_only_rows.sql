-- V646 (ADR-105) 行级审计改为显式三清单: FULL 整行 / COLUMN_SCOPED 只审关键列 / NONE 不审。
--
-- 取代 V169 起「除技术白名单外全表必审、审计触发器不许带 WHEN/列清单」的规则
-- (V184/V530/V572 的全表补挂 sweep 从此不再有后继)。三张清单与每条理由的唯一登记处是
-- AuditTriggerCoverageMigrationContractTest; 本迁移只按清单挂/拆触发器, 新表建表时必须
-- 归入其中一类, 需要审计的表由建表迁移调用 fn_audit_track_table 登记。
--
-- 同时:
--   1. fn_audit 改为: INSERT/DELETE 存整行; UPDATE 只存变化键(外加单号/编码/名称等定位键),
--      忽略 updated_at/version/last_login_at 等易变列, 忽略后没有变化就不写。
--   2. app.legacy_import='on' 时不写行审计(遗留导入每次运行只由 migrate.sh 写一条汇总事件)。
--   3. 分类只算一次: 删掉 trg_audit_classify/fn_audit_classify, 数据库行事件按清单登记的
--      事件类型直接赋值, 其余事件由 Java 侧 AuditClassifier 在写入时赋值。
--   4. 审计里的登录账号只存脱敏值(保留后 4 位), 行快照里的 login_account 同样脱敏。
-- 已有审计行不改写(V647 迁表时一次性脱敏账号)。

-- ---------------------------------------------------------------------------
-- 账号脱敏: 形如手机号/证件号的账号只保留后 4 位; 系统任务名等非号码原样保留。
-- 与 Java 侧 AuditAccountMask 同一口径。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_audit_mask_account(p_account text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog AS $$
    SELECT CASE
        WHEN p_account IS NULL OR btrim(p_account) = '' THEN NULL
        WHEN btrim(p_account) ~ '^\+?[0-9*][0-9* -]{5,}[0-9]$'
             AND length(regexp_replace(btrim(p_account), '[^0-9]', '', 'g')) >= 4
            THEN repeat('*', greatest(length(btrim(p_account)) - 4, 3)) || right(btrim(p_account), 4)
        ELSE p_account
    END;
$$;

-- ---------------------------------------------------------------------------
-- 行快照最小化: 在 V626 的剔除清单上增加 login_account 脱敏(不再存完整手机号),
-- 并补上 FULL 表里仍会带出的联系方式与证照号: 客户/供应商手机与传真、往来单位联系方式的值、
-- 员工车牌、员工证照号、官网询盘联系人姓名。变了只记列名(_redacted_changes), 不记内容。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_audit_redact_row(p_table_name text, p_row jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_row JSONB;
BEGIN
    IF p_row IS NULL THEN
        RETURN NULL;
    END IF;

    v_row := p_row - ARRAY[
        'password_hash', 'token_hash', 'preview_token_hash', 'code_hash', 'secret',
        'id_card_enc', 'id_card_hash', 'phone_enc', 'phone_hash',
        'phone', 'phone2', 'link_phone', 'office_phone', 'email', 'mobile', 'fax',
        'plate_no', 'plate_norm', 'cert_no',
        'address', 'ship_address', 'huji_address', 'residence_address',
        'bank_account_enc', 'bank_branch_enc', 'bank_account', 'bank_account_no',
        'base_salary_enc', 'perf_salary_enc', 'social_insurance_base_enc',
        'housing_fund_base_enc', 'allowance_standard_enc',
        'old_value_enc', 'new_value_enc', 'plate_no_enc', 'qr_token', 'passcode',
        'content', 'body', 'message', 'description', 'remark', 'remarks',
        'note', 'comment', 'reject_reason', 'last_rejection_reason',
        'close_reason', 'reopen_reason', 'reversal_reason', 'location_text',
        'payload', 'exception_snapshot', 'calculation_snapshot',
        'required_document_codes', 'required_document_codes_snapshot',
        'source_ref', 'source_line_ref', 'linkman', 'legal_person',
        'ground_graph', 'product_graph1', 'product_graph2', 'product_graph3',
        'product_graph4', 'product_graph5', 'product_graph6', 'budget_graph'
    ];

    IF p_table_name = 'legacy_finance_import_sources' THEN
        v_row := v_row - 'initial_state';
    ELSIF p_table_name = 'employees' THEN
        v_row := v_row - ARRAY[
            'full_name', 'gender', 'id_type', 'birth_date', 'ethnicity',
            'political_status', 'marital_status', 'paper_archive_no'
        ];
    ELSIF p_table_name = 'employee_compensation' THEN
        v_row := v_row - 'social_insurance_location';
    ELSIF p_table_name = 'emergency_contacts' THEN
        v_row := v_row - ARRAY['name', 'relationship'];
    ELSIF p_table_name = 'visitor_accounts' THEN
        v_row := v_row - 'name';
    ELSIF p_table_name = 'visitor_applications' THEN
        v_row := v_row - ARRAY['visitor_name', 'company', 'visit_purpose'];
    ELSIF p_table_name = 'party_contact_methods' THEN
        -- 客户/供应商联系方式的值(电话、邮箱、微信等); 只保留种类与是否首选。
        v_row := v_row - 'value';
    ELSIF p_table_name = 'website_inquiries' THEN
        v_row := v_row - 'name';
    ELSIF p_table_name = 'profile_change_requests' THEN
        v_row := v_row - 'review_comment';
    ELSIF p_table_name = 'employee_data_handovers' THEN
        v_row := v_row - 'reason';
    ELSIF p_table_name = 'employee_offboarding_events' THEN
        v_row := v_row - ARRAY['reason', 'handover_reason'];
    END IF;

    IF v_row ? 'login_account' AND jsonb_typeof(v_row -> 'login_account') = 'string' THEN
        v_row := jsonb_set(v_row, '{login_account}',
            COALESCE(to_jsonb(public.fn_audit_mask_account(v_row ->> 'login_account')), 'null'::jsonb));
    END IF;

    v_row := v_row - ARRAY['request_payload', 'input_snapshot', 'output_snapshot', 'before_balance',
        'original_balance', 'original_pool', 'approval_evidence'];
    RETURN v_row;
END;
$$;

-- 工资/报销类(清单里标 redacted)额外去掉金额与姓名快照; 原 fn_audit_redacted 的剔除清单。
CREATE OR REPLACE FUNCTION public.fn_audit_minimize(p_table_name text, p_row jsonb, p_redacted boolean)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public AS $$
    SELECT CASE WHEN p_redacted THEN
        public.fn_audit_redact_row(p_table_name, p_row) - ARRAY[
            'gross_income', 'total_deduction', 'net_income', 'amount',
            'total_amount', 'source_note', 'employee_name_snapshot', 'applicant_name_snapshot',
            'overtime_amount', 'bonus_amount', 'social_insurance_amount',
            'housing_fund_amount', 'tax_amount', 'other_earning_amount',
            'other_deduction_amount', 'employee_code_snapshot']
    ELSE public.fn_audit_redact_row(p_table_name, p_row) END;
$$;

-- ---------------------------------------------------------------------------
-- 拆掉旧的全表触发器与写入期分类触发器。分区子表上的克隆触发器随父表一起删除。
-- ---------------------------------------------------------------------------
DO $drop_legacy_audit$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT c.relname, t.tgname
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND NOT t.tgisinternal
          AND t.tgparentid = 0
          AND NOT c.relispartition
          AND t.tgfoid IN ('public.fn_audit()'::regprocedure,
                           'public.fn_audit_redacted()'::regprocedure,
                           'public.fn_audit_classify_row()'::regprocedure)
    LOOP
        EXECUTE format('DROP TRIGGER %I ON public.%I', r.tgname, r.relname);
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_trigger t
               WHERE NOT t.tgisinternal
                 AND t.tgfoid IN ('public.fn_audit()'::regprocedure,
                                  'public.fn_audit_redacted()'::regprocedure,
                                  'public.fn_audit_classify_row()'::regprocedure)) THEN
        RAISE EXCEPTION 'V646 could not remove every legacy audit trigger' USING ERRCODE = '55000';
    END IF;
END;
$drop_legacy_audit$;

DROP FUNCTION public.fn_audit_redacted();
DROP FUNCTION public.fn_audit_classify_row();
DROP FUNCTION public.fn_audit_classify(text, text, text, text, text, integer);

-- ---------------------------------------------------------------------------
-- 行级审计函数。触发器参数: [0] 事件类型 data_change/authorization/system,
-- [1] plain/redacted, [2..] COLUMN_SCOPED 时只审计的列。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_audit() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    v_category TEXT;
    v_redacted BOOLEAN;
    v_scope TEXT[];
    v_action TEXT := lower(TG_OP);
    v_old JSONB;
    v_new JSONB;
    v_identity JSONB;
    v_locator JSONB;
    v_before JSONB;
    v_after JSONB;
    v_minimized JSONB;
    v_redacted_keys TEXT[];
    v_device JSONB;
    v_batch_id UUID;
    v_batch_old_code TEXT;
    v_index INTEGER;
BEGIN
    -- 遗留数据离线导入: 每次运行只写一条汇总事件(migrate.sh), 不逐行复制历史数据。
    IF current_setting('app.legacy_import', true) = 'on' THEN
        RETURN NULL;
    END IF;
    -- 主档批量改号的临时编号阶段不留痕, 最终阶段只记旧号 -> 新号。
    IF TG_TABLE_NAME IN ('goods', 'moulds', 'clients', 'suppliers')
       AND NULLIF(current_setting('app.master_code_batch_id', true), '') IS NOT NULL
       AND current_setting('app.master_code_audit_stage', true) = 'temporary' THEN
        RETURN NULL;
    END IF;

    v_category := COALESCE(NULLIF(TG_ARGV[0], ''), 'data_change');
    IF v_category NOT IN ('data_change', 'authorization', 'system') THEN
        v_category := 'data_change';
    END IF;
    v_redacted := TG_NARGS > 1 AND TG_ARGV[1] = 'redacted';
    IF TG_NARGS > 2 THEN
        v_scope := ARRAY[]::TEXT[];
        FOR v_index IN 2 .. TG_NARGS - 1 LOOP
            v_scope := v_scope || TG_ARGV[v_index];
        END LOOP;
    END IF;

    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        v_old := to_jsonb(OLD);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        v_new := to_jsonb(NEW);
    END IF;
    v_identity := COALESCE(v_new, v_old);

    IF TG_OP = 'UPDATE' THEN
        IF TG_TABLE_NAME IN ('goods', 'moulds', 'clients', 'suppliers')
           AND NULLIF(current_setting('app.master_code_batch_id', true), '') IS NOT NULL
           AND current_setting('app.master_code_audit_stage', true) = 'final' THEN
            v_batch_id := current_setting('app.master_code_batch_id', true)::UUID;
            SELECT h.old_code INTO v_batch_old_code
            FROM public.master_code_history h
            WHERE h.batch_id = v_batch_id AND h.entity_id = (v_old ->> 'id')::UUID;
            v_old := jsonb_set(v_old, '{code}', COALESCE(to_jsonb(v_batch_old_code), 'null'::jsonb));
        END IF;

        IF ((v_old ->> 'is_deleted') = 'false' AND (v_new ->> 'is_deleted') = 'true')
           OR (v_old ? 'deleted_at' AND v_new ? 'deleted_at'
               AND (v_old ->> 'deleted_at') IS NULL AND (v_new ->> 'deleted_at') IS NOT NULL) THEN
            v_action := 'delete';
        END IF;

        SELECT COALESCE(jsonb_object_agg(n.key, o.value), '{}'::jsonb),
               COALESCE(jsonb_object_agg(n.key, n.value), '{}'::jsonb)
          INTO v_before, v_after
          FROM jsonb_each(v_new) AS n
          JOIN jsonb_each(v_old) AS o ON o.key = n.key
         WHERE n.value IS DISTINCT FROM o.value
           AND n.key <> ALL (ARRAY['updated_at', 'updated_by', 'version', 'lock_version', 'row_version',
                                   'last_login_at', 'last_used_at', 'last_seen_at', 'last_heartbeat',
                                   'failed_attempts', 'quantity_unit_locked', 'last_selected_at',
                                   'last_selected_by'])
           AND (v_scope IS NULL OR n.key = ANY (v_scope));
        IF v_after = '{}'::jsonb THEN
            RETURN NULL;
        END IF;

        -- 定位键(单号/编码/名称)两边都带上, 列表摘要才能写出「修改销售订单 SO-001」。
        SELECT COALESCE(jsonb_object_agg(o.key, o.value), '{}'::jsonb)
          INTO v_locator
          FROM jsonb_each(v_old) AS o
         WHERE o.key = ANY (ARRAY['bill_no', 'code', 'name', 'title', 'doc_no', 'voucher_no',
                                  'plan_no', 'order_no', 'request_no', 'slip_no', 'legacy_id'])
           AND o.value <> 'null'::jsonb
           AND NOT v_after ? o.key;

        v_minimized := public.fn_audit_minimize(TG_TABLE_NAME, v_after, v_redacted);
        v_redacted_keys := ARRAY(SELECT k FROM jsonb_object_keys(v_after) AS k
                                 WHERE NOT v_minimized ? k ORDER BY k);
        v_after := public.fn_audit_minimize(TG_TABLE_NAME, v_locator, v_redacted) || v_minimized;
        v_before := public.fn_audit_minimize(TG_TABLE_NAME, v_locator, v_redacted)
            || public.fn_audit_minimize(TG_TABLE_NAME, v_before, v_redacted);
        IF cardinality(v_redacted_keys) > 0 THEN
            -- 敏感列变了只记列名, 不记内容。
            v_after := v_after || jsonb_build_object('_redacted_changes', to_jsonb(v_redacted_keys));
        END IF;
    ELSIF TG_OP = 'INSERT' THEN
        v_after := public.fn_audit_minimize(TG_TABLE_NAME, v_new, v_redacted);
    ELSE
        v_before := public.fn_audit_minimize(TG_TABLE_NAME, v_old, v_redacted);
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
        v_action, TG_TABLE_NAME,
        COALESCE(v_identity ->> 'id', v_identity ->> 'bill_no', v_identity ->> 'code',
                 v_identity ->> 'key', v_identity ->> 'period', v_identity ->> 'user_id',
                 v_identity ->> 'employee_id', public.fn_audit_primary_key_identity(TG_RELID, v_identity)),
        v_before, v_after,
        NULLIF(current_setting('app.audit_ip', true), ''),
        NULLIF(current_setting('app.audit_user_agent', true), ''),
        'success',
        NULLIF(current_setting('app.audit_request_id', true), '')::UUID,
        'database',
        CASE WHEN v_action = 'delete' OR v_category IN ('authorization', 'system')
             THEN 'high' ELSE 'low' END,
        v_category,
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

-- ---------------------------------------------------------------------------
-- 清单登记入口: 建表迁移调用它挂/拆审计触发器, 不再手写 CREATE TRIGGER。
--   FULL          AFTER INSERT OR DELETE + AFTER UPDATE WHEN (OLD.* IS DISTINCT FROM NEW.*)
--   COLUMN_SCOPED [AFTER INSERT OR DELETE] + AFTER UPDATE OF <列> WHEN (<任一列变化>)
--   NONE          不挂审计触发器
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_audit_track_table(
    p_table text,
    p_policy text,
    p_category text DEFAULT 'data_change',
    p_redacted boolean DEFAULT false,
    p_columns text[] DEFAULT NULL,
    p_insert_delete boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    v_relid OID;
    v_trigger RECORD;
    v_args TEXT;
    v_when TEXT;
    v_columns TEXT;
    v_missing TEXT;
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

    FOR v_trigger IN
        SELECT t.tgname FROM pg_trigger t
        WHERE t.tgrelid = v_relid AND NOT t.tgisinternal AND t.tgparentid = 0
          AND t.tgfoid = 'public.fn_audit()'::regprocedure
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
    IF p_insert_delete THEN
        EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR DELETE ON public.%I '
                       'FOR EACH ROW EXECUTE FUNCTION public.fn_audit(%s)', v_row_name, p_table, v_args);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I', p_table, v_row_name);
    END IF;
    EXECUTE format('CREATE TRIGGER %I AFTER UPDATE OF %s ON public.%I '
                   'FOR EACH ROW WHEN (%s) EXECUTE FUNCTION public.fn_audit(%s)',
                   v_update_name, v_columns, p_table, v_when, v_args);
    EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I', p_table, v_update_name);
END;
$$;
REVOKE ALL ON FUNCTION public.fn_audit_track_table(text, text, text, boolean, text[], boolean) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 按清单挂触发器。未出现在 FULL/COLUMN_SCOPED 里的表即 NONE(上面已拆掉旧触发器)。
-- ---------------------------------------------------------------------------
DO $apply_audit_lists$
BEGIN
    -- FULL/authorization: 账号、角色、权限点、授权覆盖与数据范围: 谁能做什么的唯一事实, 每次变化都要能还原前后值
    PERFORM public.fn_audit_track_table(t, 'FULL', 'authorization', false)
    FROM unnest(ARRAY[
        'client_visibility_grants', 'department_permissions', 'department_roles',
        'manager_permission_delegations', 'organization_permission_leader_assignments',
        'permission_surface_permissions', 'permission_surfaces', 'permissions', 'role_permissions',
        'roles', 'user_data_scopes', 'user_permission_overrides', 'user_roles', 'users']) AS t;
    -- FULL/system: 系统设置与全局配置: 改动影响全平台运行口径
    PERFORM public.fn_audit_track_table(t, 'FULL', 'system', false)
    FROM unnest(ARRAY[
        'business_identifier_namespaces', 'expense_claim_settings', 'measurement_capture_profiles',
        'system_master_category_registry', 'system_posting_style_roles', 'system_settings',
        'unit_measurement_profiles']) AS t;
    -- FULL/master: 基础资料主档: 人工维护, 被所有单据引用
    PERFORM public.fn_audit_track_table(t, 'FULL', 'data_change', false)
    FROM unnest(ARRAY[
        'accounts', 'client_categories', 'client_ship_addresses', 'clients', 'colors', 'currencies',
        'finance_payment_methods', 'goods', 'goods_bom_items', 'goods_import_batches',
        'goods_import_creations', 'master_code_change_batches', 'material_categories',
        'mould_categories', 'moulds', 'official_policy_briefs', 'party_activity_records',
        'party_addresses', 'party_contact_methods', 'payment_styles', 'settlement_methods',
        'supplier_categories', 'suppliers', 'units', 'warehouses']) AS t;
    -- FULL/org_hr: 组织、人事与访客资料: 人工维护的敏感资料, 由脱敏函数去掉证件/联系方式/自由文本后整行审计
    PERFORM public.fn_audit_track_table(t, 'FULL', 'data_change', false)
    FROM unnest(ARRAY[
        'attachments', 'departments', 'emergency_contacts', 'employee_compensation',
        'employee_contracts', 'employee_credentials', 'employee_data_handover_scopes',
        'employee_data_handovers', 'employee_education', 'employee_phones',
        'employee_secondary_departments', 'employee_sensitive', 'employee_vehicles', 'employees',
        'employment_history', 'positions', 'profile_change_requests', 'rd_task_forwarders', 'rd_tasks',
        'suggestion_replies', 'suggestions', 'visitor_accounts', 'visitor_applications',
        'visitor_approval_steps', 'website_inquiries']) AS t;
    -- FULL/payroll: 工资与报销: 额外去掉金额与姓名快照后整行审计
    PERFORM public.fn_audit_track_table(t, 'FULL', 'data_change', true)
    FROM unnest(ARRAY[
        'expense_claim_items', 'expense_claims', 'payroll_batches', 'payroll_items', 'payroll_slips',
        'payroll_variable_inputs']) AS t;
    -- FULL/sales_docs: 销售单据头与明细: 人工录入并审核的业务单据
    PERFORM public.fn_audit_track_table(t, 'FULL', 'data_change', false)
    FROM unnest(ARRAY[
        'sales_order_cost_items', 'sales_order_items', 'sales_orders', 'sales_other_shipment_items',
        'sales_other_shipments', 'sales_quote_items', 'sales_quotes', 'sales_return_items',
        'sales_return_quality_items', 'sales_returns', 'sales_shipment_items', 'sales_shipments']) AS t;
    -- FULL/purchase_docs: 采购单据、财务审批案与供应商结算: 人工录入并审核的业务单据
    PERFORM public.fn_audit_track_table(t, 'FULL', 'data_change', false)
    FROM unnest(ARRAY[
        'procurement_arrival_exceptions', 'procurement_iqc_rejection_cases',
        'procurement_order_approval_cases', 'purchase_order_items', 'purchase_orders',
        'purchase_receipt_items', 'purchase_receipts', 'purchase_request_items', 'purchase_requests',
        'purchase_return_items', 'purchase_returns', 'supplier_claim_cash_receipts',
        'supplier_claim_receivables', 'supplier_open_item_offsets', 'supplier_return_tasks',
        'supplier_settlement_batch_lines', 'supplier_settlement_batches']) AS t;
    -- FULL/subcontract_docs: 委外单据头与明细: 人工录入并审核的业务单据
    PERFORM public.fn_audit_track_table(t, 'FULL', 'data_change', false)
    FROM unnest(ARRAY[
        'subcontract_application_items', 'subcontract_applications', 'subcontract_inquiries',
        'subcontract_inquiry_items', 'subcontract_loss_case_lines', 'subcontract_loss_cases',
        'subcontract_loss_resolutions', 'subcontract_material_issue_items',
        'subcontract_material_issues', 'subcontract_material_plan_items', 'subcontract_material_plans',
        'subcontract_material_return_items', 'subcontract_material_returns',
        'subcontract_order_cost_items', 'subcontract_order_items', 'subcontract_orders',
        'subcontract_receipt_items', 'subcontract_receipts', 'subcontract_return_items',
        'subcontract_returns', 'subcontract_short_delivery_cases', 'subcontract_waste_items',
        'subcontract_wastes']) AS t;
    -- FULL/stock_docs: 库存单据、预留与调整申请: 人工录入并审核的业务单据
    PERFORM public.fn_audit_track_table(t, 'FULL', 'data_change', false)
    FROM unnest(ARRAY[
        'stock_balance_adjustment_requests', 'stock_document_items', 'stock_documents',
        'stock_reservations']) AS t;
    -- FULL/production_docs: 生产计划、日报、执行段、退料、点收、质检与直送单据: 人工录入并审核的业务单据
    PERFORM public.fn_audit_track_table(t, 'FULL', 'data_change', false)
    FROM unnest(ARRAY[
        'production_daily_report_items', 'production_daily_report_material_usages',
        'production_daily_report_workers', 'production_daily_reports', 'production_execution_segments',
        'production_finished_arrival_registration_items', 'production_finished_arrival_registrations',
        'production_finished_in_confirmation_items', 'production_finished_in_confirmations',
        'production_fqc_inspection_sheet_items', 'production_fqc_inspection_sheets',
        'production_fqc_inspections', 'production_material_analysis_borrows',
        'production_material_return_request_items', 'production_material_return_requests',
        'production_plan_items', 'production_plans', 'production_workshop_direct_transfer_items',
        'production_workshop_direct_transfers']) AS t;
    -- FULL/finance_docs: 财务单据、凭证、往来台账与资产: 人工录入并审核的财务事实
    PERFORM public.fn_audit_track_table(t, 'FULL', 'data_change', false)
    FROM unnest(ARRAY[
        'ar_ap_ledger', 'customer_open_item_offset_batches', 'customer_open_item_offsets',
        'deferred_expenses', 'expense_claim_invoices', 'finance_asset_accounting_periods',
        'finance_asset_books', 'finance_asset_categories', 'finance_asset_posting_lines',
        'finance_asset_posting_runs', 'finance_bank_transfer_lines', 'finance_bank_transfers',
        'finance_check_register', 'finance_deferral_schedule_lines',
        'finance_deferral_schedule_versions', 'finance_expense_items', 'finance_expenses',
        'finance_other_income_items', 'finance_other_incomes', 'finance_payment_lines',
        'finance_payments', 'finance_receipt_lines', 'finance_receipt_source_allocations',
        'finance_receipts', 'finance_reconciliations', 'fixed_assets', 'gl_entries', 'gl_vouchers']) AS t;
    -- COLUMN_SCOPED: 物料分析表头: 只记新建/删除与状态、取消、仓库、制单人这些人为决定, 版本号和指纹每次刷新都会变, 不记
    PERFORM public.fn_audit_track_table('production_material_analyses', 'COLUMN_SCOPED', 'data_change', false,
        ARRAY['status', 'cancelled_by', 'cancelled_at', 'cancellation_reason', 'is_deleted', 'deleted_at', 'warehouse_id', 'participating_warehouse_ids', 'maker_id'], true);
    -- COLUMN_SCOPED: 物料分析物料行是每次刷新重算的投影: 只记人工确认路线与理由, 需求/可用/缺口等派生数量不记
    PERFORM public.fn_audit_track_table('production_material_analysis_materials', 'COLUMN_SCOPED', 'data_change', false,
        ARRAY['confirmed_route', 'route_reason', 'route_confirmed_by'], false);
    -- COLUMN_SCOPED: 物料分析来源行: 只记人工改的需求数量、交期、优先级、原因和删除, 就绪量等派生数量不记
    PERFORM public.fn_audit_track_table('production_material_analysis_items', 'COLUMN_SCOPED', 'data_change', false,
        ARRAY['requested_qty', 'delivery_date', 'line_priority', 'source_reason', 'is_deleted'], false);
    -- COLUMN_SCOPED: 物料改挪记录: 新建时行内已带发起人与原因, 之后会被人工撤回/取消、随优先履约推进状态: 只记状态与关闭人、关闭时间、关闭原因
    PERFORM public.fn_audit_track_table('preplan_material_reallocations', 'COLUMN_SCOPED', 'data_change', false,
        ARRAY['status', 'closed_by', 'closed_at', 'close_reason'], false);
END;
$apply_audit_lists$;

-- 失败关闭: FULL 表恰好一对触发器(行事件 + 带 WHEN 的更新), COLUMN_SCOPED 表的更新触发器
-- 必须带列清单与 WHEN; 审计函数只能由登记入口挂上, 不许出现别的名字。
DO $verify_audit_lists$
DECLARE
    v_bad TEXT;
BEGIN
    SELECT string_agg(c.relname || ':' || t.tgname, ', ') INTO v_bad
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    WHERE NOT t.tgisinternal AND t.tgparentid = 0
      AND t.tgfoid = 'public.fn_audit()'::regprocedure
      AND (t.tgname NOT IN (left('trg_audit_' || c.relname, 63), left('trg_audit_upd_' || c.relname, 63))
           OR t.tgenabled <> 'A'
           OR (t.tgname = left('trg_audit_upd_' || c.relname, 63) AND t.tgqual IS NULL));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'V646 audit triggers have an unexpected shape: %', v_bad USING ERRCODE = '55000';
    END IF;
    IF (SELECT count(DISTINCT t.tgrelid) FROM pg_trigger t
        WHERE NOT t.tgisinternal AND t.tgparentid = 0
          AND t.tgfoid = 'public.fn_audit()'::regprocedure) <> 184 THEN
        RAISE EXCEPTION 'V646 expected 180 FULL + 4 COLUMN_SCOPED audited tables' USING ERRCODE = '55000';
    END IF;
END;
$verify_audit_lists$;
