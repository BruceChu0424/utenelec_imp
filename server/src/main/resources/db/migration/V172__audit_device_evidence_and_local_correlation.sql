-- 审计设备证据：保留服务端 request_id，同时加入客户端操作 ID、脱敏设备快照和本机时间。
--
-- 设备字段全部是客户端声明，不能替代 IP、服务端时间、授权校验或平台设备证明。
-- device_installation_id 是应用首次运行生成的随机 UUID，不采集 IMEI/MAC/硬件序列号。

ALTER TABLE audit_log
    ADD COLUMN IF NOT EXISTS client_event_id UUID,
    ADD COLUMN IF NOT EXISTS device_installation_id UUID,
    ADD COLUMN IF NOT EXISTS device_name VARCHAR(200),
    ADD COLUMN IF NOT EXISTS device_manufacturer VARCHAR(120),
    ADD COLUMN IF NOT EXISTS device_model VARCHAR(160),
    ADD COLUMN IF NOT EXISTS device_platform VARCHAR(32),
    ADD COLUMN IF NOT EXISTS device_os_version VARCHAR(200),
    ADD COLUMN IF NOT EXISTS app_version VARCHAR(64),
    ADD COLUMN IF NOT EXISTS app_build VARCHAR(64),
    ADD COLUMN IF NOT EXISTS device_form_factor VARCHAR(32),
    ADD COLUMN IF NOT EXISTS device_browser VARCHAR(80),
    ADD COLUMN IF NOT EXISTS device_locale VARCHAR(64),
    ADD COLUMN IF NOT EXISTS device_time_zone VARCHAR(80),
    ADD COLUMN IF NOT EXISTS device_time_zone_offset_minutes INTEGER,
    ADD COLUMN IF NOT EXISTS device_is_physical BOOLEAN,
    ADD COLUMN IF NOT EXISTS client_event_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS device_capture_status VARCHAR(16)
        NOT NULL DEFAULT 'legacy',
    ADD COLUMN IF NOT EXISTS device_profile_hash VARCHAR(64);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'audit_log_device_capture_status_chk'
    ) THEN
        ALTER TABLE audit_log
            ADD CONSTRAINT audit_log_device_capture_status_chk
            CHECK (device_capture_status IN (
                'present', 'partial', 'invalid', 'missing', 'legacy'
            ));
    END IF;
END $$;

-- 归档表必须与热表以相同顺序追加字段，兼容人工脚本和迁移测试的 SELECT *。
ALTER TABLE audit_log_archive
    ADD COLUMN IF NOT EXISTS client_event_id UUID,
    ADD COLUMN IF NOT EXISTS device_installation_id UUID,
    ADD COLUMN IF NOT EXISTS device_name VARCHAR(200),
    ADD COLUMN IF NOT EXISTS device_manufacturer VARCHAR(120),
    ADD COLUMN IF NOT EXISTS device_model VARCHAR(160),
    ADD COLUMN IF NOT EXISTS device_platform VARCHAR(32),
    ADD COLUMN IF NOT EXISTS device_os_version VARCHAR(200),
    ADD COLUMN IF NOT EXISTS app_version VARCHAR(64),
    ADD COLUMN IF NOT EXISTS app_build VARCHAR(64),
    ADD COLUMN IF NOT EXISTS device_form_factor VARCHAR(32),
    ADD COLUMN IF NOT EXISTS device_browser VARCHAR(80),
    ADD COLUMN IF NOT EXISTS device_locale VARCHAR(64),
    ADD COLUMN IF NOT EXISTS device_time_zone VARCHAR(80),
    ADD COLUMN IF NOT EXISTS device_time_zone_offset_minutes INTEGER,
    ADD COLUMN IF NOT EXISTS device_is_physical BOOLEAN,
    ADD COLUMN IF NOT EXISTS client_event_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS device_capture_status VARCHAR(16)
        NOT NULL DEFAULT 'legacy',
    ADD COLUMN IF NOT EXISTS device_profile_hash VARCHAR(64);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'audit_log_archive_device_capture_status_chk'
    ) THEN
        ALTER TABLE audit_log_archive
            ADD CONSTRAINT audit_log_archive_device_capture_status_chk
            CHECK (device_capture_status IN (
                'present', 'partial', 'invalid', 'missing', 'legacy'
            ));
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_audit_client_event_id
    ON audit_log (client_event_id)
    WHERE client_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_device_created
    ON audit_log (device_installation_id, created_at DESC)
    WHERE device_installation_id IS NOT NULL;

-- TxSessionVars 只传一个经过后端白名单清洗的 JSON 会话变量，避免每个字段一次数据库往返。
CREATE OR REPLACE FUNCTION fn_audit() RETURNS TRIGGER AS $$
DECLARE
    v_actor UUID;
    v_actor_account TEXT;
    v_request_id UUID;
    v_target TEXT;
    v_before JSONB;
    v_after JSONB;
    v_identity JSONB;
    v_device JSONB;
BEGIN
    v_actor := NULLIF(current_setting('app.actor_id', true), '')::UUID;
    v_actor_account := NULLIF(current_setting('app.actor_account', true), '');
    v_request_id := NULLIF(current_setting('app.audit_request_id', true), '')::UUID;
    v_device := COALESCE(
        NULLIF(current_setting('app.audit_device_context', true), '')::JSONB,
        '{}'::JSONB);
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
        before, "after", ip, user_agent, result, request_id, event_source,
        client_event_id, device_installation_id, device_name,
        device_manufacturer, device_model, device_platform,
        device_os_version, app_version, app_build, device_form_factor,
        device_browser, device_locale, device_time_zone,
        device_time_zone_offset_minutes, device_is_physical, client_event_at,
        device_capture_status, device_profile_hash)
    VALUES (
        v_actor, v_actor_account, lower(TG_OP), TG_TABLE_NAME, v_target,
        v_before, v_after,
        NULLIF(current_setting('app.audit_ip', true), ''),
        NULLIF(current_setting('app.audit_user_agent', true), ''),
        'success', v_request_id, 'database',
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
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_audit_redacted() RETURNS TRIGGER AS $$
DECLARE
    v_actor UUID;
    v_before JSONB;
    v_after JSONB;
    v_device JSONB;
BEGIN
    v_actor := NULLIF(current_setting('app.actor_id', true), '')::UUID;
    v_device := COALESCE(
        NULLIF(current_setting('app.audit_device_context', true), '')::JSONB,
        '{}'::JSONB);
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
        before, "after", ip, user_agent, result, request_id, event_source,
        client_event_id, device_installation_id, device_name,
        device_manufacturer, device_model, device_platform,
        device_os_version, app_version, app_build, device_form_factor,
        device_browser, device_locale, device_time_zone,
        device_time_zone_offset_minutes, device_is_physical, client_event_at,
        device_capture_status, device_profile_hash)
    VALUES (
        v_actor,
        NULLIF(current_setting('app.actor_account', true), ''),
        lower(TG_OP), TG_TABLE_NAME, COALESCE(v_before ->> 'id', v_after ->> 'id'),
        v_before, v_after,
        NULLIF(current_setting('app.audit_ip', true), ''),
        NULLIF(current_setting('app.audit_user_agent', true), ''),
        'success',
        NULLIF(current_setting('app.audit_request_id', true), '')::UUID,
        'database',
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
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

COMMENT ON COLUMN audit_log.client_event_id IS
    '客户端为一次逻辑请求生成的 UUID；重试可复用，不是服务端权威 request_id';
COMMENT ON COLUMN audit_log.device_installation_id IS
    '应用安装实例随机 UUID；非 IMEI、MAC、硬件序列号或平台设备证明';
COMMENT ON COLUMN audit_log.device_profile_hash IS
    '服务端对清洗后设备快照的 SHA-256 摘要，仅用于一致性核对，不代表设备认证';
COMMENT ON COLUMN audit_log.device_capture_status IS
    'present/partial/invalid/missing/legacy；设备信息均为客户端声明';
