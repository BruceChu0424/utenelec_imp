-- V185: make soft deletes explicit and extend audit-row minimization.
--
-- V169 is already applied and remains byte-for-byte immutable. Replacing these
-- functions changes only audit rows produced after V185; existing rows are not
-- rewritten or backfilled. The read side recognizes historical soft-delete
-- UPDATE snapshots so investigators can still find them with operationKind=delete.

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
        'password_hash', 'token_hash', 'preview_token_hash', 'code_hash', 'secret',
        'id_card_enc', 'id_card_hash', 'phone_enc', 'phone_hash',
        'phone', 'phone2', 'link_phone', 'office_phone', 'email',
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
        'source_ref', 'source_line_ref',
        'linkman', 'legal_person'
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
    v_action TEXT;
    v_target TEXT;
    v_before JSONB;
    v_after JSONB;
    v_identity JSONB;
    v_old_row JSONB;
    v_new_row JSONB;
    v_device JSONB;
BEGIN
    v_actor := NULLIF(current_setting('app.actor_id', true), '')::UUID;
    v_actor_account := NULLIF(current_setting('app.actor_account', true), '');
    v_request_id := NULLIF(current_setting('app.audit_request_id', true), '')::UUID;
    v_action := lower(TG_OP);
    v_device := COALESCE(
        NULLIF(current_setting('app.audit_device_context', true), '')::JSONB,
        '{}'::JSONB);

    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        v_old_row := to_jsonb(OLD);
        v_before := fn_audit_redact_row(TG_TABLE_NAME, v_old_row);
        v_identity := v_old_row;
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        v_new_row := to_jsonb(NEW);
        v_after := fn_audit_redact_row(TG_TABLE_NAME, v_new_row);
        v_identity := v_new_row;
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

    v_target := COALESCE(
        v_identity ->> 'id', v_identity ->> 'bill_no', v_identity ->> 'code',
        v_identity ->> 'key', v_identity ->> 'period',
        v_identity ->> 'user_id', v_identity ->> 'employee_id');

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
        v_actor, v_actor_account, v_action, TG_TABLE_NAME, v_target,
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
            'total_amount', 'source_note', 'employee_name_snapshot', 'applicant_name_snapshot'
        ];
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        v_new_row := to_jsonb(NEW);
        v_after := fn_audit_redact_row(TG_TABLE_NAME, v_new_row) - ARRAY[
            'gross_income', 'total_deduction', 'net_income', 'amount',
            'total_amount', 'source_note', 'employee_name_snapshot', 'applicant_name_snapshot'
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

COMMENT ON FUNCTION fn_audit_redact_row(TEXT, JSONB) IS
    '审计行最小化：剔除凭证、PII、列明的原因备注类敏感文本及大型嵌套 JSON 快照';
COMMENT ON FUNCTION fn_audit() IS
    '通用审计：请求关联、操作人、脱敏 before/after；软删除转换记为 delete';
COMMENT ON FUNCTION fn_audit_redacted() IS
    '高敏审计：额外移除金额/姓名快照并保留设备关联；软删除转换记为 delete';
