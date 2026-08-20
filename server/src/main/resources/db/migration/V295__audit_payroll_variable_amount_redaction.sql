-- V295：审计日志工资变量金额脱敏补漏（2026-08-16 保密审计 H-1/M-3 修复）
--
-- 背景：fn_audit_redacted 的全局脱敏键列表只删了 payroll_batches/slips/items 的
-- gross_income/total_deduction/net_income/amount，漏掉了 payroll_variable_inputs 的
-- 7 个按人按月金额列（加班费/奖金/社保/公积金/个税/其他加项/其他减项）——持 audit_log:view
-- 的核查人员可在审计详情里看到全员逐月薪资构成明文，绕过 employee:compensation:view 体系。
-- 同时补 employee_code_snapshot（工资条审计行只删了姓名快照，工号可关联到人）。
--
-- 本迁移做两件事：
--   ① 重建 fn_audit_redacted，全局键列表新增 8 个键（对 before/after 同时生效）；
--   ② 清洗存量 audit_log：before/after 中凡含这些键的行就地删除该键（不可逆，属合规要求）。

-- ① 重建函数：与 V185 当前版本逐行一致，仅扩大两处 ARRAY 键列表。
CREATE OR REPLACE FUNCTION fn_audit_redacted() RETURNS TRIGGER AS $$
DECLARE
    v_actor UUID;
    v_action TEXT;
    v_before JSONB;
    v_after JSONB;
    v_old_row JSONB;
    v_new_row JSONB;
    v_device JSONB;
BEGIN
    v_actor := NULLIF(current_setting('app.actor_id', true), '')::UUID;
    v_action := lower(TG_OP);
    v_device := COALESCE(
        NULLIF(current_setting('app.audit_device_context', true), '')::JSONB,
        '{}'::JSONB);

    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        v_old_row := to_jsonb(OLD);
        v_before := fn_audit_redact_row(TG_TABLE_NAME, v_old_row) - ARRAY[
            'gross_income', 'total_deduction', 'net_income', 'amount',
            'total_amount', 'source_note', 'employee_name_snapshot', 'applicant_name_snapshot',
            'overtime_amount', 'bonus_amount', 'social_insurance_amount',
            'housing_fund_amount', 'tax_amount', 'other_earning_amount',
            'other_deduction_amount', 'employee_code_snapshot'
        ];
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        v_new_row := to_jsonb(NEW);
        v_after := fn_audit_redact_row(TG_TABLE_NAME, v_new_row) - ARRAY[
            'gross_income', 'total_deduction', 'net_income', 'amount',
            'total_amount', 'source_note', 'employee_name_snapshot', 'applicant_name_snapshot',
            'overtime_amount', 'bonus_amount', 'social_insurance_amount',
            'housing_fund_amount', 'tax_amount', 'other_earning_amount',
            'other_deduction_amount', 'employee_code_snapshot'
        ];
    END IF;

    IF TG_OP = 'UPDATE' AND (
        ((v_old_row ->> 'is_deleted') = 'false'
            AND (v_new_row ->> 'is_deleted') = 'true')
        OR (v_old_row ? 'deleted_at'
            AND v_new_row ? 'deleted_at'
            AND (v_old_row ->> 'deleted_at') IS NULL
            AND (v_new_row ->> 'deleted_at') IS NOT NULL)
    ) THEN
        v_action := 'delete';
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
        v_action, TG_TABLE_NAME, COALESCE(v_before ->> 'id', v_after ->> 'id'),
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

-- ② 清洗存量：凡 before/after 含敏感键的审计行，删除这些键。
UPDATE audit_log
SET before = before - ARRAY[
    'overtime_amount', 'bonus_amount', 'social_insurance_amount',
    'housing_fund_amount', 'tax_amount', 'other_earning_amount',
    'other_deduction_amount', 'employee_code_snapshot'
]
WHERE before ?| ARRAY[
    'overtime_amount', 'bonus_amount', 'social_insurance_amount',
    'housing_fund_amount', 'tax_amount', 'other_earning_amount',
    'other_deduction_amount', 'employee_code_snapshot'
];

UPDATE audit_log
SET "after" = "after" - ARRAY[
    'overtime_amount', 'bonus_amount', 'social_insurance_amount',
    'housing_fund_amount', 'tax_amount', 'other_earning_amount',
    'other_deduction_amount', 'employee_code_snapshot'
]
WHERE "after" ?| ARRAY[
    'overtime_amount', 'bonus_amount', 'social_insurance_amount',
    'housing_fund_amount', 'tax_amount', 'other_earning_amount',
    'other_deduction_amount', 'employee_code_snapshot'
];

COMMENT ON FUNCTION fn_audit_redacted() IS
    '高敏审计：额外移除金额（含 payroll_variable_inputs 逐项金额）/姓名与工号快照并保留设备关联；软删除转换记为 delete';
