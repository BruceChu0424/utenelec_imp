-- 审计中心：可解释风险、请求关联、可读上下文与业务表变更覆盖。
-- 原则：所有认证写请求至少有一条 request 事件；业务表触发器补充脱敏 before/after。

ALTER TABLE audit_log
    ADD COLUMN IF NOT EXISTS request_id UUID,
    ADD COLUMN IF NOT EXISTS event_source TEXT NOT NULL DEFAULT 'database',
    ADD COLUMN IF NOT EXISTS http_method VARCHAR(10),
    ADD COLUMN IF NOT EXISTS http_path TEXT,
    ADD COLUMN IF NOT EXISTS status_code INTEGER,
    ADD COLUMN IF NOT EXISTS duration_ms BIGINT;

UPDATE audit_log
SET event_source = CASE
    WHEN action LIKE 'http_%' THEN 'request'
    WHEN action IN ('insert', 'update', 'delete') THEN 'database'
    ELSE 'business'
END
WHERE event_source = 'database';

UPDATE audit_log
SET result = 'success'
WHERE result IS NULL
  AND action IN ('insert', 'update', 'delete');

-- 历史触发器行尽量补回账号，避免页面只显示 UUID/系统。
UPDATE audit_log audit
SET actor_account = users.login_account
FROM users
WHERE audit.actor_account IS NULL
  AND audit.actor_id = users.id;

UPDATE audit_log audit
SET actor_account = visitors.visitor_no
FROM visitor_accounts visitors
WHERE audit.actor_account IS NULL
  AND audit.actor_id = visitors.id;

ALTER TABLE audit_log
    ADD COLUMN IF NOT EXISTS risk_level TEXT GENERATED ALWAYS AS (
        CASE
            WHEN lower(coalesce(action, '') || ' ' || coalesce(result, ''))
                     ~ '(refresh_reuse|reuse_detected)'
                THEN 'critical'
            WHEN lower(coalesce(action, '')) IN ('delete', 'http_delete')
              OR (
                  lower(coalesce(action, '')) <> 'http_get'
                  AND lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                            || coalesce(http_path, '') || ' ' || coalesce(target_id, ''))
                      ~ 'permission|authorization|data[-_]scopes?|system[-_]settings?|reset-password|balance-adjust|blacklist|/reverse|/offboard'
              )
                THEN 'high'
            WHEN coalesce(status_code, 0) >= 400
              OR lower(coalesce(result, ''))
                     ~ '(failure|failed|denied|bad_|not_found|locked|disabled|rate_limited|invalid|expired)'
              OR lower(coalesce(action, ''))
                     ~ '(login_failed|change_password|verify_password|^export_)'
              OR lower(coalesce(http_path, '')) LIKE '%/export%'
                THEN 'medium'
            ELSE 'low'
        END
    ) STORED,
    ADD COLUMN IF NOT EXISTS event_category TEXT GENERATED ALWAYS AS (
        CASE
            WHEN lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                       || coalesce(http_path, '') || ' ' || coalesce(target_id, ''))
                     ~ '(reuse|access_denied|blacklist)'
                THEN 'security'
            WHEN lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                       || coalesce(http_path, '') || ' ' || coalesce(target_id, ''))
                     ~ '(permission|authorization|role|data[-_]scope)'
                THEN 'authorization'
            WHEN lower(coalesce(action, '')) LIKE 'export_%'
              OR lower(coalesce(http_path, '')) LIKE '%/export%'
                THEN 'export'
            WHEN lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                       || coalesce(http_path, ''))
                     ~ '(login|logout|password|refresh_token|auth/)'
                THEN 'authentication'
            WHEN lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                       || coalesce(http_path, ''))
                     ~ '(system[-_]setting|user_preferences)'
                THEN 'system'
            WHEN lower(coalesce(action, '')) IN ('insert', 'update', 'delete')
                THEN 'data_change'
            ELSE 'business'
        END
    ) STORED;

-- 兼容已经执行过保留脚本的环境：旧归档表必须与热表保持同列顺序。
-- 归档中的风险/分类是写入时快照，使用普通列，避免规则变化改写历史结论。
DO $$
BEGIN
    IF to_regclass('public.audit_log_archive') IS NOT NULL THEN
        ALTER TABLE audit_log_archive
            ADD COLUMN IF NOT EXISTS request_id UUID,
            ADD COLUMN IF NOT EXISTS event_source TEXT NOT NULL DEFAULT 'database',
            ADD COLUMN IF NOT EXISTS http_method VARCHAR(10),
            ADD COLUMN IF NOT EXISTS http_path TEXT,
            ADD COLUMN IF NOT EXISTS status_code INTEGER,
            ADD COLUMN IF NOT EXISTS duration_ms BIGINT,
            ADD COLUMN IF NOT EXISTS risk_level TEXT,
            ADD COLUMN IF NOT EXISTS event_category TEXT;

        UPDATE audit_log_archive
        SET event_source = CASE
            WHEN action LIKE 'http_%' THEN 'request'
            WHEN action IN ('insert', 'update', 'delete') THEN 'database'
            ELSE 'business'
        END;

        UPDATE audit_log_archive
        SET risk_level = CASE
                WHEN lower(coalesce(action, '') || ' ' || coalesce(result, ''))
                           ~ '(refresh_reuse|reuse_detected)'
                    THEN 'critical'
                WHEN lower(coalesce(action, '')) IN ('delete', 'http_delete')
                  OR (
                      lower(coalesce(action, '')) <> 'http_get'
                      AND lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                                || coalesce(http_path, '') || ' ' || coalesce(target_id, ''))
                          ~ 'permission|authorization|data[-_]scopes?|system[-_]settings?|reset-password|balance-adjust|blacklist|/reverse|/offboard'
                  )
                    THEN 'high'
                WHEN coalesce(status_code, 0) >= 400
                  OR lower(coalesce(result, ''))
                         ~ '(failure|failed|denied|bad_|not_found|locked|disabled|rate_limited|invalid|expired)'
                  OR lower(coalesce(action, ''))
                         ~ '(login_failed|change_password|verify_password|^export_)'
                  OR lower(coalesce(http_path, '')) LIKE '%/export%'
                    THEN 'medium'
                ELSE 'low'
            END,
            event_category = CASE
                WHEN lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                           || coalesce(http_path, '') || ' ' || coalesce(target_id, ''))
                         ~ '(reuse|access_denied|blacklist)'
                    THEN 'security'
                WHEN lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                           || coalesce(http_path, '') || ' ' || coalesce(target_id, ''))
                         ~ '(permission|authorization|role|data[-_]scope)'
                    THEN 'authorization'
                WHEN lower(coalesce(action, '')) LIKE 'export_%'
                  OR lower(coalesce(http_path, '')) LIKE '%/export%'
                    THEN 'export'
                WHEN lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                           || coalesce(http_path, ''))
                         ~ '(login|logout|password|refresh_token|auth/)'
                    THEN 'authentication'
                WHEN lower(coalesce(action, '') || ' ' || coalesce(target_type, '') || ' '
                           || coalesce(http_path, ''))
                         ~ '(system[-_]setting|user_preferences)'
                    THEN 'system'
                WHEN lower(coalesce(action, '')) IN ('insert', 'update', 'delete')
                    THEN 'data_change'
                ELSE 'business'
            END;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_audit_risk_created
    ON audit_log (risk_level, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_category_created
    ON audit_log (event_category, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_request_id
    ON audit_log (request_id) WHERE request_id IS NOT NULL;

-- 在原 V146 基础上继续缩小审计副本：客户/供应商/销售联系人、银行账号和自由文本不复制。
CREATE OR REPLACE FUNCTION fn_audit_redact_row(
    p_table_name TEXT,
    p_row JSONB
) RETURNS JSONB AS $$
DECLARE
    v_row JSONB;
BEGIN
    IF p_row IS NULL THEN
        RETURN NULL;
    END IF;

    v_row := p_row - ARRAY[
        'password_hash', 'token_hash', 'code_hash', 'secret',
        'id_card_enc', 'id_card_hash', 'phone_enc', 'phone_hash',
        'phone', 'phone2', 'link_phone', 'office_phone', 'email',
        'address', 'ship_address', 'huji_address', 'residence_address',
        'bank_account_enc', 'bank_branch_enc', 'bank_account', 'bank_account_no',
        'base_salary_enc', 'perf_salary_enc', 'social_insurance_base_enc',
        'housing_fund_base_enc', 'allowance_standard_enc',
        'old_value_enc', 'new_value_enc', 'plate_no_enc', 'qr_token', 'passcode',
        'content', 'body', 'message', 'description', 'remark', 'remarks',
        'note', 'comment', 'reject_reason', 'linkman', 'legal_person'
    ];

    IF p_table_name = 'employees' THEN
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
        v_row := v_row - ARRAY['visitor_name', 'company', 'visit_purpose', 'plate_no'];
    ELSIF p_table_name = 'profile_change_requests' THEN
        v_row := v_row - 'review_comment';
    END IF;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION fn_audit() RETURNS TRIGGER AS $$
DECLARE
    v_actor UUID;
    v_actor_account TEXT;
    v_request_id UUID;
    v_target TEXT;
    v_before JSONB;
    v_after JSONB;
    v_identity JSONB;
BEGIN
    v_actor := NULLIF(current_setting('app.actor_id', true), '')::UUID;
    v_actor_account := NULLIF(current_setting('app.actor_account', true), '');
    v_request_id := NULLIF(current_setting('app.audit_request_id', true), '')::UUID;
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        v_before := fn_audit_redact_row(TG_TABLE_NAME, to_jsonb(OLD));
        v_identity := to_jsonb(OLD);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        v_after := fn_audit_redact_row(TG_TABLE_NAME, to_jsonb(NEW));
        v_identity := to_jsonb(NEW);
    END IF;
    v_target := COALESCE(
        v_identity ->> 'id', v_identity ->> 'bill_no', v_identity ->> 'code',
        v_identity ->> 'key', v_identity ->> 'user_id', v_identity ->> 'employee_id');

    INSERT INTO audit_log (
        actor_id, actor_account, action, target_type, target_id,
        before, "after", ip, user_agent, result, request_id, event_source)
    VALUES (
        v_actor, v_actor_account, lower(TG_OP), TG_TABLE_NAME, v_target,
        v_before, v_after,
        NULLIF(current_setting('app.audit_ip', true), ''),
        NULLIF(current_setting('app.audit_user_agent', true), ''),
        'success', v_request_id, 'database');
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_audit IS
    '通用审计：请求关联 + 操作人上下文 + 脱敏 before/after；不复制凭证、PII 与自由文本';

-- 工资/报销沿用更严格的金额与姓名快照剔除规则，同时补齐请求上下文。
CREATE OR REPLACE FUNCTION fn_audit_redacted() RETURNS TRIGGER AS $$
DECLARE
    v_actor UUID;
    v_before JSONB;
    v_after JSONB;
BEGIN
    v_actor := NULLIF(current_setting('app.actor_id', true), '')::UUID;
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        v_before := fn_audit_redact_row(TG_TABLE_NAME, to_jsonb(OLD)) - ARRAY[
            'gross_income', 'total_deduction', 'net_income', 'amount',
            'total_amount', 'source_note', 'employee_name_snapshot', 'applicant_name_snapshot'
        ];
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        v_after := fn_audit_redact_row(TG_TABLE_NAME, to_jsonb(NEW)) - ARRAY[
            'gross_income', 'total_deduction', 'net_income', 'amount',
            'total_amount', 'source_note', 'employee_name_snapshot', 'applicant_name_snapshot'
        ];
    END IF;
    INSERT INTO audit_log (
        actor_id, actor_account, action, target_type, target_id,
        before, "after", ip, user_agent, result, request_id, event_source)
    VALUES (
        v_actor,
        NULLIF(current_setting('app.actor_account', true), ''),
        lower(TG_OP), TG_TABLE_NAME, COALESCE(v_before ->> 'id', v_after ->> 'id'),
        v_before, v_after,
        NULLIF(current_setting('app.audit_ip', true), ''),
        NULLIF(current_setting('app.audit_user_agent', true), ''),
        'success',
        NULLIF(current_setting('app.audit_request_id', true), '')::UUID,
        'database');
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- 为尚无审计触发器的用户可见业务表补齐 before/after。凭证、令牌、短信码、
-- Flyway/空间扩展、序号与迁移运行元数据只保留请求/显式事件，不复制行内容。
DO $$
DECLARE
    table_name TEXT;
BEGIN
    FOR table_name IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND c.relname NOT IN (
              'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
              'authorization_state', 'doc_number_sequences',
              'report_materialized_view_refresh_state', 'password_history',
              'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
          AND c.relname NOT LIKE 'legacy_migration_%'
          AND NOT EXISTS (
              SELECT 1
              FROM pg_trigger trigger
              WHERE trigger.tgrelid = c.oid
                AND NOT trigger.tgisinternal
                AND trigger.tgname LIKE 'trg_audit%')
        ORDER BY c.relname
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_audit_%1$I AFTER INSERT OR UPDATE OR DELETE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit()',
            table_name);
    END LOOP;
END $$;

COMMENT ON COLUMN audit_log.request_id IS
    '同一次 HTTP 操作与其数据库触发器明细的关联 ID；不含用户输入';
COMMENT ON COLUMN audit_log.risk_level IS
    '可解释规则分级：low/medium/high/critical；非机器学习结论';
