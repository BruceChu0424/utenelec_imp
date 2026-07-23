-- 访客预约管理系统（visitor）
-- 访客独立于员工 users 表（users.employee_id NOT NULL UNIQUE，访客非员工）。
-- 访客走 手机号 + 短信验证码 注册登录；JWT 加 typ=visitor claim 区分主体（见 JwtService / JwtAuthFilter）。

-- 1) 访客账号
CREATE TABLE visitor_accounts (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_enc     TEXT NOT NULL,                 -- pgp_sym_encrypt(手机号)
    phone_hash    TEXT NOT NULL UNIQUE,          -- HMAC-SHA256(手机号)，登录/查重
    name          TEXT NOT NULL,                 -- 访客姓名
    visitor_no    TEXT NOT NULL UNIQUE,          -- 访客编号 V + 手机尾4 + 随机2位
    avatar_seed   TEXT,                          -- 头像种子（首字母/底色）
    status        TEXT NOT NULL CHECK (status IN ('active','blocked')) DEFAULT 'active',
    last_login_at TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID,
    updated_by    UUID
);
COMMENT ON TABLE visitor_accounts IS '访客账号（手机号验证码注册，独立于员工 users）';

-- 2) 短信验证码（哈希入库；短期表，过期清理）
CREATE TABLE visitor_sms_codes (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone       TEXT NOT NULL,                   -- 明文手机号（发送用；短期表，过期清理）
    code_hash   TEXT NOT NULL,                   -- sha256(验证码)
    scene       TEXT NOT NULL CHECK (scene IN ('login','apply')),
    attempts    INT  NOT NULL DEFAULT 0,
    expires_at  TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_visitor_sms_phone ON visitor_sms_codes(phone, expires_at);

-- 3) 访客刷新令牌（独立于员工 refresh_tokens；轮换 + 重用检测）
CREATE TABLE visitor_refresh_tokens (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    visitor_account_id  UUID NOT NULL REFERENCES visitor_accounts(id) ON DELETE CASCADE,
    token_hash          TEXT NOT NULL UNIQUE,
    device_info         TEXT,
    issued_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ NOT NULL,
    revoked_at          TIMESTAMPTZ,
    replaced_by         UUID REFERENCES visitor_refresh_tokens(id) ON DELETE SET NULL
);
CREATE INDEX idx_visitor_refresh_account ON visitor_refresh_tokens(visitor_account_id);
CREATE INDEX idx_visitor_refresh_expires ON visitor_refresh_tokens(expires_at);

-- 4) 访客来访申请
CREATE TABLE visitor_applications (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    visitor_account_id  UUID REFERENCES visitor_accounts(id) ON DELETE SET NULL,
    visitor_name        TEXT NOT NULL,
    phone_enc           TEXT,                     -- pgp_sym_encrypt(手机号)
    id_card_enc         TEXT,                     -- pgp_sym_encrypt(身份证)
    id_card_last4       TEXT,                     -- 明文尾4（非敏感）
    company             TEXT,                     -- 来访单位
    visit_purpose       TEXT NOT NULL,            -- 来访事由
    has_vehicle         BOOLEAN NOT NULL DEFAULT FALSE,
    plate_no            TEXT,                     -- 车牌号（has_vehicle=true 时填）
    host_employee_id    UUID REFERENCES employees(id) ON DELETE SET NULL,   -- 接待人（被访人）
    host_department_id  UUID REFERENCES departments(id) ON DELETE SET NULL,
    planned_visit_at    TIMESTAMPTZ NOT NULL,
    planned_leave_at    TIMESTAMPTZ,
    status              TEXT NOT NULL CHECK (status IN ('pending','hostReviewing','approved','rejected','checkedIn','cancelled')) DEFAULT 'pending',
    applied_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_by         UUID,
    approved_at         TIMESTAMPTZ,
    reject_reason       TEXT,
    host_confirmed      BOOLEAN,                  -- 被访人确认（两级审批可选）：null=未走该环节 true=同意 false=拒绝
    check_in_at         TIMESTAMPTZ,
    qr_token            TEXT UNIQUE,              -- 入场凭证（HMAC 签名，防伪造）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);
CREATE INDEX idx_visitor_app_account ON visitor_applications(visitor_account_id);
CREATE INDEX idx_visitor_app_host    ON visitor_applications(host_employee_id);
CREATE INDEX idx_visitor_app_status  ON visitor_applications(status);
COMMENT ON COLUMN visitor_applications.host_confirmed IS '被访人确认（两级审批可选）：null=未走该环节，true=同意，false=拒绝';
COMMENT ON COLUMN visitor_applications.qr_token IS 'HR 批准后签发的入场二维码凭证（HMAC 签名，防伪造）';

-- 5) 审批轨迹（提交/转被访人/被访人确认/批准/拒绝/签到）
CREATE TABLE visitor_approval_steps (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    application_id UUID NOT NULL REFERENCES visitor_applications(id) ON DELETE CASCADE,
    actor_type     TEXT CHECK (actor_type IN ('visitor','staff')),
    actor_id       UUID,                          -- visitor_accounts.id 或 users.id
    action         TEXT NOT NULL CHECK (action IN ('submit','forward','hostConfirm','hostReject','approve','reject','checkIn')),
    comment        TEXT,
    acted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by     UUID,
    updated_by     UUID
);
CREATE INDEX idx_visitor_approval_app ON visitor_approval_steps(application_id);

-- 审计触发器（复用 V05 的 fn_audit，只挂触发器不重写函数）
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'visitor_accounts','visitor_applications','visitor_approval_steps'
    ] LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_audit_%1$I ON %1$I;'
            'CREATE TRIGGER trg_audit_%1$I AFTER INSERT OR UPDATE OR DELETE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit();', t);
    END LOOP;
END $$;

-- updated_at 自动维护（这些表均有 updated_at）
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'visitor_accounts','visitor_applications','visitor_approval_steps'
    ] LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_set_updated_at ON %1$I;'
            'CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();', t);
    END LOOP;
END $$;

-- ========== RBAC 种子：security 角色 + visitor 权限点 ==========

INSERT INTO roles (code, name, description, is_system)
VALUES ('security', '保安', '门岗访客核验/签到/黑名单', TRUE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO permissions (code, name, category) VALUES
    ('visitor:apply',     '申请访客',     'visitor'),
    ('visitor:view',      '查看访客',     'visitor'),
    ('visitor:approve',   '审批访客',     'visitor'),
    ('visitor:check-in',  '访客签到核验', 'visitor'),
    ('visitor:blacklist', '访客黑名单',   'visitor')
ON CONFLICT (code) DO NOTHING;

-- 保安：核验/签到/查看/黑名单
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code='security' AND p.code IN ('visitor:view','visitor:check-in','visitor:blacklist')
ON CONFLICT DO NOTHING;

-- 普通员工：作为被访人查看/确认自己名下的访客申请
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code='employee' AND p.code IN ('visitor:view','visitor:approve')
ON CONFLICT DO NOTHING;

-- HR：访客审批全权
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code='hr' AND p.code IN ('visitor:view','visitor:approve','visitor:check-in','visitor:blacklist')
ON CONFLICT DO NOTHING;

-- admin：V06 的 admin 全量映射是历史快照，新增 visitor 权限需显式补
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code='admin' AND p.code IN ('visitor:apply','visitor:view','visitor:approve','visitor:check-in','visitor:blacklist')
ON CONFLICT DO NOTHING;
