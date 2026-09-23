-- V658 服务端会话 + 敏感操作再认证 (ADR-110; security-04/05/09, audit-retention-settings-02)
--
-- 背景: 「自动退出登录」只在前端计时, 登出不作废 access token, refresh 滑动续期没有上限;
-- 二次密码确认是独立的「对/错」接口, 无限次可试。会话的权威状态不在服务端。
--
-- 本迁移:
--   1) auth_sessions: 每次登录一行 (员工或访客二选一)。JwtAuthFilter 在查账号状态的同一条 SQL
--      里连带查会话: 已吊销 / 空闲超过 session_idle_timeout_minutes / 超过绝对期限一律 401。
--      last_seen_at 只由人为请求更新且最多 60 秒一次; absolute_expires_at 从登录时刻起算
--      (jwt_refresh_ttl_days), refresh 轮换不再延长。
--      step_up_token_hash/step_up_expires_at: 本会话当前有效的一次性再认证凭证 (只存哈希,
--      5 分钟, 用一次即清空)。
--   2) auth_step_up_states: 按员工账号累计再认证失败次数与暂停时间 (与改密旧密码、进入切换人共享)。
--   3) 存量刷新令牌全部作废: 旧令牌没有会话行, 发版后所有人重新登录一次 (平台未上线, 不做兼容)。
--   4) 两张表登记进 business_data_reset() 的清空清单 (CLEAR): 清空业务数据本就让全员下线。
--
-- 两张表都是凭证/会话机制数据, 不挂行级审计 (与 refresh_tokens 同口径); 登录、登出、
-- 再认证成功/失败、会话吊销另有显式安全事件。

CREATE TABLE auth_sessions (
    sid                 UUID PRIMARY KEY,
    user_id             UUID REFERENCES users(id) ON DELETE CASCADE,
    visitor_id          UUID REFERENCES visitor_accounts(id) ON DELETE CASCADE,
    created_at          TIMESTAMPTZ NOT NULL,
    last_seen_at        TIMESTAMPTZ NOT NULL,
    absolute_expires_at TIMESTAMPTZ NOT NULL,
    revoked_at          TIMESTAMPTZ,
    revoked_reason      TEXT,
    step_up_token_hash  TEXT,
    step_up_expires_at  TIMESTAMPTZ,
    CONSTRAINT ck_auth_sessions_one_subject
        CHECK (num_nonnulls(user_id, visitor_id) = 1),
    CONSTRAINT ck_auth_sessions_expiry_after_start
        CHECK (absolute_expires_at > created_at AND last_seen_at >= created_at),
    CONSTRAINT ck_auth_sessions_revocation_pair
        CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL)),
    CONSTRAINT ck_auth_sessions_revoked_reason
        CHECK (revoked_reason IS NULL OR revoked_reason IN (
            'logout', 'idle_timeout', 'password_changed', 'account_status_changed',
            'password_reset', 'remote_access_changed', 'refresh_reuse', 'step_up_locked',
            'login_account_changed')),
    CONSTRAINT ck_auth_sessions_step_up_pair
        CHECK ((step_up_token_hash IS NULL) = (step_up_expires_at IS NULL))
);

CREATE INDEX idx_auth_sessions_user_open
    ON auth_sessions (user_id) WHERE revoked_at IS NULL AND user_id IS NOT NULL;
CREATE INDEX idx_auth_sessions_visitor_open
    ON auth_sessions (visitor_id) WHERE revoked_at IS NULL AND visitor_id IS NOT NULL;

COMMENT ON TABLE auth_sessions IS
    '服务端登录会话 (员工或访客): 吊销、空闲超时与绝对期限的唯一权威; 访问令牌 sid 指向本表';
COMMENT ON COLUMN auth_sessions.last_seen_at IS
    '最后一次人为请求的时间 (最多 60 秒更新一次; 角标/计数类自动请求不更新)';
COMMENT ON COLUMN auth_sessions.absolute_expires_at IS
    '从登录时刻起算的绝对期限 (jwt_refresh_ttl_days), 刷新令牌轮换不延长';
COMMENT ON COLUMN auth_sessions.step_up_token_hash IS
    '当前有效的一次性再认证凭证 sha256; 使用一次即清空';

CREATE TABLE auth_step_up_states (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    failed_attempts INTEGER NOT NULL DEFAULT 0 CHECK (failed_attempts >= 0),
    locked_until    TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE auth_step_up_states IS
    '敏感操作再认证的连续失败计数与暂停截止 (与改密原密码、进入切换人共享)';

-- 旧刷新令牌没有会话行, 无法再轮换; 显式作废, 避免留下「看似有效」的行。
UPDATE refresh_tokens SET revoked_at = now() WHERE revoked_at IS NULL;
UPDATE visitor_refresh_tokens SET revoked_at = now() WHERE revoked_at IS NULL;

-- business_data_reset() 是 fail-closed 的: 新表必须登记分类, 否则清库直接拒绝执行。
-- 沿用 V474 起的「读取已安装函数定义 + 锚点替换」补丁方式, 锚点不存在或表已分类即失败关闭。
DO $reset_policy$
DECLARE
    definition TEXT;
    needle TEXT := '(''stock_movements'', ''CLEAR'')';
    addition TEXT := E',\n            (''auth_sessions'', ''CLEAR'')'
        || E',\n            (''auth_step_up_states'', ''CLEAR'')';
    table_name TEXT;
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle) <> 1 THEN
        RAISE EXCEPTION 'V658 cannot extend business_data_reset policy safely';
    END IF;
    FOREACH table_name IN ARRAY ARRAY['auth_sessions', 'auth_step_up_states'] LOOP
        IF to_regclass(format('public.%I',table_name)) IS NULL
           OR position(format('(%L, %L)',table_name,'CLEAR') IN definition)>0
           OR position(format('(%L, %L)',table_name,'PRESERVE') IN definition)>0 THEN
            RAISE EXCEPTION 'V658 reset policy source missing or already classified: %', table_name;
        END IF;
    END LOOP;
    EXECUTE replace(definition,needle,needle || addition);
END;
$reset_policy$;
