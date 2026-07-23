-- 审计日志（bigserial，高追加量）
CREATE TABLE audit_log (
    id            BIGSERIAL PRIMARY KEY,
    actor_id      UUID,                       -- 操作人（app.actor_id 会话变量）
    actor_account TEXT,
    action        TEXT NOT NULL,              -- insert/update/delete/login/login_failed/...
    target_type   TEXT,                       -- 表名 / 业务对象类型
    target_id     TEXT,                       -- 业务对象主键
    before        JSONB,                      -- 变更前（敏感列已为密文，不含明文 PII）
    after         JSONB,                      -- 变更后
    ip            TEXT,
    user_agent    TEXT,
    result        TEXT,                       -- success / failure
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_actor   ON audit_log(actor_id);
CREATE INDEX idx_audit_target  ON audit_log(target_type, target_id);
CREATE INDEX idx_audit_action  ON audit_log(action);
CREATE INDEX idx_audit_created ON audit_log(created_at);
COMMENT ON TABLE audit_log IS '通用审计日志（触发器写数据变更；登录/改密由 AuthService 显式写）';
-- 注：employees/employee_sensitive/employee_compensation 的加密列在 to_jsonb 中为密文，
-- 审计表天然不含明文 PII；employee_sensitive.id_card_last4 为尾4（非敏感）。

-- 通用审计触发器：before/after 由 to_jsonb(OLD/NEW) 构建；actor 取 app.actor_id 会话变量
CREATE OR REPLACE FUNCTION fn_audit() RETURNS TRIGGER AS $$
DECLARE
    v_actor UUID;
BEGIN
    v_actor := NULLIF(current_setting('app.actor_id', true), '')::UUID;
    INSERT INTO audit_log (actor_id, action, target_type, target_id, before, "after")
    VALUES (
        v_actor,
        lower(TG_OP),
        TG_TABLE_NAME,
        COALESCE(
            CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) ->> 'id' END,
            CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) ->> 'id' END
        ),
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- 在敏感/关键表上挂审计触发器
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'employees','employee_sensitive','employee_compensation',
        'departments','users','user_roles','roles','permissions','role_permissions'
    ] LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_audit_%1$I ON %1$I;'
            'CREATE TRIGGER trg_audit_%1$I AFTER INSERT OR UPDATE OR DELETE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit();', t);
    END LOOP;
END $$;

-- updated_at 自动维护函数（BEFORE UPDATE）
CREATE OR REPLACE FUNCTION fn_set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 给所有带 updated_at 的业务表挂触发器
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'departments','positions','employees','employee_sensitive','employee_compensation',
        'emergency_contacts','employee_contracts','employee_education','employee_credentials',
        'employment_history','users'
    ] LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_set_updated_at ON %1$I;'
            'CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();', t);
    END LOOP;
END $$;
