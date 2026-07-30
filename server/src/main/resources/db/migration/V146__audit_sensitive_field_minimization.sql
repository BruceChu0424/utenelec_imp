-- 通用审计只保留“谁、何时、对哪个对象、哪些非敏感状态发生变化”。
-- 密文/HMAC/凭证虽然不是明文，也不应在 audit_log 再复制一份扩大暴露面。
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
        'password_hash',
        'token_hash',
        'code_hash',
        'id_card_enc',
        'id_card_hash',
        'phone_enc',
        'phone_hash',
        'bank_account_enc',
        'bank_branch_enc',
        'base_salary_enc',
        'perf_salary_enc',
        'social_insurance_base_enc',
        'housing_fund_base_enc',
        'allowance_standard_enc',
        'old_value_enc',
        'new_value_enc',
        'plate_no_enc',
        'qr_token',
        'passcode'
    ];

    IF p_table_name = 'employees' THEN
        v_row := v_row - ARRAY[
            'full_name',
            'gender',
            'id_type',
            'birth_date',
            'ethnicity',
            'political_status',
            'marital_status',
            'huji_address',
            'residence_address',
            'office_phone',
            'email',
            'paper_archive_no'
        ];
    ELSIF p_table_name = 'employee_compensation' THEN
        v_row := v_row - 'social_insurance_location';
    ELSIF p_table_name = 'emergency_contacts' THEN
        v_row := v_row - ARRAY['name', 'relationship'];
    ELSIF p_table_name = 'visitor_accounts' THEN
        v_row := v_row - 'name';
    ELSIF p_table_name = 'visitor_applications' THEN
        v_row := v_row - ARRAY[
            'visitor_name',
            'company',
            'visit_purpose',
            'plate_no',
            'reject_reason'
        ];
    ELSIF p_table_name = 'visitor_approval_steps' THEN
        v_row := v_row - 'comment';
    ELSIF p_table_name = 'profile_change_requests' THEN
        v_row := v_row - 'review_comment';
    END IF;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION fn_audit() RETURNS TRIGGER AS $$
DECLARE
    v_actor  UUID;
    v_target TEXT;
    v_before JSONB;
    v_after  JSONB;
BEGIN
    v_actor := NULLIF(current_setting('app.actor_id', true), '')::UUID;
    v_target := COALESCE(
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) ->> 'id' END,
        CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) ->> 'id' END
    );
    IF TG_OP IN ('UPDATE','DELETE') THEN
        v_before := fn_audit_redact_row(TG_TABLE_NAME, to_jsonb(OLD));
    END IF;
    IF TG_OP IN ('INSERT','UPDATE') THEN
        v_after := fn_audit_redact_row(TG_TABLE_NAME, to_jsonb(NEW));
    END IF;

    INSERT INTO audit_log (actor_id, action, target_type, target_id, before, "after")
    VALUES (
        v_actor,
        lower(TG_OP),
        TG_TABLE_NAME,
        v_target,
        v_before,
        v_after
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fn_audit IS
    '通用审计：记录对象与非敏感状态变化；密文、哈希、凭证和直接身份信息不复制到 audit_log';

-- 不在 Flyway 事务内无界重写历史 audit_log：大表会造成长事务、锁等待和表膨胀。
-- 上线前环境可清空审计测试数据；已有生产历史需由运维按主键范围分批调用
-- fn_audit_redact_row(target_type, before/"after")，每批提交并在完成后 VACUUM。
