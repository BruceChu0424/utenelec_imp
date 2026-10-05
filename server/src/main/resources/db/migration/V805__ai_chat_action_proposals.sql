-- V805 (ADR-150): AI 助手「提出动作 -> 本人确认 -> 执行」的一次性提案。
-- 提案只记录服务端渲染的确认卡内容与参数摘要, 不是授权: 执行仍走页面原按钮或原业务端点,
-- 权限、再认证、版本与状态校验照旧。一行只能从 PROPOSED 走一次到 CONFIRMED(数据库兜底一次性核销),
-- 过期、取消、身份变化作废后不能再确认。确认后客户端回写执行回执(SUCCEEDED/FAILED)。
-- 页面快照不入库: 快照只在 ai_jobs.input_bytes 里随任务结束清空。
CREATE TABLE ai_chat_action_proposals (
    id uuid PRIMARY KEY,
    actor_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    actor_auth_version bigint NOT NULL,
    authorization_epoch bigint NOT NULL,
    membership_hash char(64) NOT NULL CHECK (membership_hash ~ '^[0-9a-f]{64}$'),
    source_job_id uuid REFERENCES ai_jobs(id) ON DELETE SET NULL,
    action_type varchar(24) NOT NULL
        CHECK (action_type IN ('PAGE_ACTION', 'OPEN_GUIDED_FORM', 'PERMISSION_GRANT')),
    handler varchar(48) NOT NULL CHECK (handler ~ '^[A-Za-z][A-Za-z0-9_]{0,47}$'),
    execution varchar(8) NOT NULL CHECK (execution IN ('CLIENT', 'SERVER')),
    route varchar(240) CHECK (route IS NULL OR route ~ '^/[A-Za-z0-9/_-]*$'),
    target_type varchar(24) NOT NULL CHECK (target_type IN ('PAGE', 'USER', 'AI_JOB')),
    target_ref varchar(240),
    target_version bigint,
    args jsonb NOT NULL CHECK (jsonb_typeof(args) = 'object' AND octet_length(args::text) <= 4096),
    args_hash char(64) NOT NULL CHECK (args_hash ~ '^[0-9a-f]{64}$'),
    title varchar(80) NOT NULL CHECK (btrim(title) <> ''),
    summary jsonb NOT NULL CHECK (jsonb_typeof(summary) = 'array'
        AND jsonb_array_length(summary) BETWEEN 1 AND 16 AND octet_length(summary::text) <= 4096),
    risk varchar(8) NOT NULL CHECK (risk IN ('LOW', 'MEDIUM', 'HIGH')),
    risk_note varchar(200),
    requires_step_up boolean NOT NULL DEFAULT false,
    status varchar(12) NOT NULL DEFAULT 'PROPOSED'
        CHECK (status IN ('PROPOSED', 'CONFIRMED', 'CANCELLED', 'EXPIRED', 'FAILED')),
    outcome varchar(16) CHECK (outcome IN ('SUCCEEDED', 'FAILED', 'AUTH_CHANGED')),
    outcome_message varchar(500),
    issued_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    confirmed_at timestamptz,
    finished_at timestamptz,
    CONSTRAINT ck_ai_action_proposal_window
        CHECK (expires_at > issued_at AND expires_at <= issued_at + interval '10 minutes'),
    CONSTRAINT ck_ai_action_proposal_open
        CHECK (status <> 'PROPOSED' OR (confirmed_at IS NULL AND finished_at IS NULL AND outcome IS NULL)),
    CONSTRAINT ck_ai_action_proposal_confirmed CHECK (status <> 'CONFIRMED' OR confirmed_at IS NOT NULL),
    CONSTRAINT ck_ai_action_proposal_closed
        CHECK (status NOT IN ('CANCELLED', 'EXPIRED', 'FAILED') OR finished_at IS NOT NULL),
    CONSTRAINT ck_ai_action_proposal_outcome CHECK (outcome IS NULL OR finished_at IS NOT NULL),
    CONSTRAINT ck_ai_action_proposal_step_up CHECK (NOT requires_step_up OR execution = 'SERVER')
);
CREATE INDEX idx_ai_chat_action_proposals_actor ON ai_chat_action_proposals(actor_user_id, status, expires_at);
CREATE INDEX idx_ai_chat_action_proposals_job ON ai_chat_action_proposals(source_job_id);
COMMENT ON TABLE ai_chat_action_proposals IS
    'AI 助手确认卡的一次性提案(ADR-150): PROPOSED 只能确认一次, 过期/取消/身份变化后作废; 执行仍走页面原按钮或原业务端点';
COMMENT ON COLUMN ai_chat_action_proposals.args IS
    '服务端校验后的动作参数; 确认时原样回给客户端执行, 客户端不能另行改参数';
COMMENT ON COLUMN ai_chat_action_proposals.membership_hash IS
    '提案时本人部门归属指纹的 SHA-256; 与授权版本、全局授权 epoch 一起判定身份是否变化';

CREATE FUNCTION fn_guard_ai_chat_action_proposal() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.actor_user_id IS DISTINCT FROM OLD.actor_user_id
       OR NEW.actor_auth_version IS DISTINCT FROM OLD.actor_auth_version
       OR NEW.authorization_epoch IS DISTINCT FROM OLD.authorization_epoch
       OR NEW.membership_hash IS DISTINCT FROM OLD.membership_hash
       OR (NEW.source_job_id IS DISTINCT FROM OLD.source_job_id AND NEW.source_job_id IS NOT NULL)
       OR NEW.action_type IS DISTINCT FROM OLD.action_type OR NEW.handler IS DISTINCT FROM OLD.handler
       OR NEW.execution IS DISTINCT FROM OLD.execution OR NEW.route IS DISTINCT FROM OLD.route
       OR NEW.target_type IS DISTINCT FROM OLD.target_type OR NEW.target_ref IS DISTINCT FROM OLD.target_ref
       OR NEW.target_version IS DISTINCT FROM OLD.target_version
       OR NEW.args IS DISTINCT FROM OLD.args OR NEW.args_hash IS DISTINCT FROM OLD.args_hash
       OR NEW.title IS DISTINCT FROM OLD.title OR NEW.summary IS DISTINCT FROM OLD.summary
       OR NEW.risk IS DISTINCT FROM OLD.risk OR NEW.risk_note IS DISTINCT FROM OLD.risk_note
       OR NEW.requires_step_up IS DISTINCT FROM OLD.requires_step_up
       OR NEW.issued_at IS DISTINCT FROM OLD.issued_at OR NEW.expires_at IS DISTINCT FROM OLD.expires_at THEN
        RAISE EXCEPTION 'AI 确认卡内容不能修改，请重新提问生成新的确认卡' USING ERRCODE = '23514';
    END IF;
    IF NEW.status = OLD.status AND NEW.outcome IS NOT DISTINCT FROM OLD.outcome
       AND NEW.confirmed_at IS NOT DISTINCT FROM OLD.confirmed_at
       AND NEW.finished_at IS NOT DISTINCT FROM OLD.finished_at
       AND NEW.outcome_message IS NOT DISTINCT FROM OLD.outcome_message THEN
        RETURN NEW; -- only the job reference was released by ON DELETE SET NULL
    END IF;
    IF OLD.status = 'PROPOSED' THEN
        IF NEW.status = 'CONFIRMED' THEN
            IF now() >= OLD.expires_at THEN
                RAISE EXCEPTION 'AI 确认卡已过期，请重新提问' USING ERRCODE = '23514';
            END IF;
            RETURN NEW;
        END IF;
        IF NEW.status IN ('CANCELLED', 'EXPIRED', 'FAILED') THEN RETURN NEW; END IF;
    ELSIF OLD.status = 'CONFIRMED' AND OLD.finished_at IS NULL AND NEW.status IN ('CONFIRMED', 'FAILED')
          AND NEW.confirmed_at IS NOT DISTINCT FROM OLD.confirmed_at THEN
        RETURN NEW; -- one execution receipt after the single confirmation
    END IF;
    RAISE EXCEPTION 'AI 确认卡已经处理过，不能再次确认' USING ERRCODE = '23514';
END;
$$;
CREATE TRIGGER trg_guard_ai_chat_action_proposal BEFORE UPDATE ON ai_chat_action_proposals
FOR EACH ROW EXECUTE FUNCTION fn_guard_ai_chat_action_proposal();
SELECT fn_audit_track_table('ai_chat_action_proposals', 'NONE', 'data_change', false);

DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V805 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor, anchor || E',\n (''ai_chat_action_proposals'', ''CLEAR'')');
END;
$reset_policy$;
