-- =====================================================================
-- 员工个人信息修改申请（Phase 6）
-- =====================================================================
-- 设计要点：
--   * 一次提交多字段共用一个 batch_id，HR 整批通过/驳回
--   * status: pending → (approved | rejected | cancelled | applied)
--   * employee_version: 提交时员工表 version 的快照；审批时再校验，
--     不一致则 409（防止员工档案在申请期间被 HR 改过）
--   * idem_key: 客户端幂等键，唯一约束防重复提交
--   * old_value/new_value: 走 pgcrypto 字段级加密（敏感 PII 字段）
--   * 所有写动作通过 ProfileChangeService 显式落 audit_log
-- =====================================================================

ALTER TABLE employees
    ADD COLUMN IF NOT EXISTS version INT NOT NULL DEFAULT 0;

CREATE TABLE profile_change_requests (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id      UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    batch_id         UUID NOT NULL,
    field_code       VARCHAR(64)  NOT NULL,
    field_label      VARCHAR(128) NOT NULL,
    field_group      VARCHAR(32)  NOT NULL,
    old_value_enc    TEXT,
    new_value_enc    TEXT NOT NULL,
    status           VARCHAR(16)  NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','approved','rejected','cancelled','applied')),
    submitted_by     UUID NOT NULL REFERENCES employees(id),
    submitted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    reviewed_by      UUID REFERENCES employees(id),
    reviewed_at      TIMESTAMPTZ,
    review_comment   TEXT,
    employee_version INT NOT NULL,
    idem_key         VARCHAR(64) NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (idem_key)
);

CREATE INDEX pcr_employee_status_idx ON profile_change_requests (employee_id, status);
CREATE INDEX pcr_batch_idx           ON profile_change_requests (batch_id);
CREATE INDEX pcr_submitted_at_idx    ON profile_change_requests (submitted_at DESC);

COMMENT ON TABLE profile_change_requests IS
    '员工个人信息修改申请。一次提交多字段共用 batch_id；employee_version 做乐观锁；idem_key 防重放。';
COMMENT ON COLUMN profile_change_requests.field_code  IS '字段机器码（phone/fullName/hujiAddress/emergencyContact.0.phone…）';
COMMENT ON COLUMN profile_change_requests.field_group IS '字段分组：identity / contact / address / emergency / compensation';
COMMENT ON COLUMN profile_change_requests.old_value_enc IS '旧值快照；敏感字段 pgcrypto 加密，普通字段可明文';
COMMENT ON COLUMN profile_change_requests.new_value_enc IS '新值；同字段加密策略';
COMMENT ON COLUMN profile_change_requests.employee_version IS '提交时 employees.version 快照；审批时再校验';
COMMENT ON COLUMN profile_change_requests.idem_key IS '客户端幂等键，唯一约束防重复提交';

-- 给 profile_change_requests 加审计触发器（与 employees 一致）
CREATE OR REPLACE FUNCTION audit_profile_change_requests() RETURNS TRIGGER AS $$
DECLARE
    v_actor UUID;
BEGIN
    BEGIN
        v_actor := current_setting('app.actor_id', true)::UUID;
    EXCEPTION WHEN OTHERS THEN
        v_actor := NULL;
    END;

    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (actor_id, action, target_type, target_id, after_jsonb, ip, user_agent, result)
        VALUES (v_actor, 'INSERT', 'profileChangeRequest', NEW.id,
                to_jsonb(NEW), NULL, NULL, 'success');
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_log (actor_id, action, target_type, target_id, before_jsonb, after_jsonb, ip, user_agent, result)
        VALUES (v_actor, 'UPDATE', 'profileChangeRequest', NEW.id,
                to_jsonb(OLD), to_jsonb(NEW), NULL, NULL, 'success');
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO audit_log (actor_id, action, target_type, target_id, before_jsonb, ip, user_agent, result)
        VALUES (v_actor, 'DELETE', 'profileChangeRequest', OLD.id,
                to_jsonb(OLD), NULL, NULL, 'success');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_audit_profile_change_requests ON profile_change_requests;
CREATE TRIGGER trg_audit_profile_change_requests
    AFTER INSERT OR UPDATE OR DELETE ON profile_change_requests
    FOR EACH ROW EXECUTE FUNCTION audit_profile_change_requests();