-- 审计加固：fn_audit 写 before/after 时剔除 password_hash（避免把 Argon2 哈希复制到 audit_log）。
-- 业务表无 password_hash 列，- 'password_hash' 仅对 users 表生效（其他表无影响）。
CREATE OR REPLACE FUNCTION fn_audit() RETURNS TRIGGER AS $$
DECLARE
    v_actor  UUID;
    v_target TEXT;
BEGIN
    v_actor := NULLIF(current_setting('app.actor_id', true), '')::UUID;
    v_target := COALESCE(
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) ->> 'id' END,
        CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) ->> 'id' END
    );
    INSERT INTO audit_log (actor_id, action, target_type, target_id, before, "after")
    VALUES (
        v_actor,
        lower(TG_OP),
        TG_TABLE_NAME,
        v_target,
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) - 'password_hash' END,
        CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) - 'password_hash' END
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION fn_audit IS '通用审计：记录 before/after，剔除 password_hash';
