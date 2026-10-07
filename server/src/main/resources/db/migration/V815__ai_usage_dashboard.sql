-- V815 (ADR-164): AI 用量看板与按人限额/停用。
--
-- 两张表:
--   ai_user_limits  管理员对单个账号的 AI 限额与停用开关。空限额=跟随全局默认(uten.ai.daily-token-budget /
--                   max-jobs-per-user-per-day); disabled 由管理员设置, 任务提交与调用前强制。配置随账号,
--                   业务清空按 PRESERVE 保留(与 user_preferences 同口径)。乐观锁 row_version 供管理界面并发保存。
--   ai_usage_daily  用量按人按日汇总, 由定时任务(AiJobHousekeeping)从 ai_call_logs 归档汇总, 支撑日/月/年视图。
--                   之所以要 rollup: ai_call_logs 只留 180 天技术记录, 年视图需要更长历史; 汇总行只含计数,
--                   不含问题与回复。用户删除后行保留(无 FK), 展示名回退「已删除员工」; 属于用量统计,
--                   业务清空按 CLEAR 清掉(与 ai_call_logs 同口径)。
--
-- 迁移内一次性把存量 ai_call_logs 回填成日汇总(上海时区, 与 todayTokens 口径一致)。
-- ai_call_logs 归档是软删(archived_at), 行仍在, 回填不区分归档与否。
CREATE TABLE ai_user_limits (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    disabled boolean NOT NULL DEFAULT false,
    daily_token_limit bigint CHECK (daily_token_limit IS NULL OR daily_token_limit > 0),
    daily_job_limit int CHECK (daily_job_limit IS NULL OR daily_job_limit > 0),
    row_version bigint NOT NULL DEFAULT 0,
    updated_by uuid,
    updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ai_user_limits IS
    'AI 助手按人限额与停用(ADR-164): 空限额=跟随全局默认; disabled 由管理员设置, 提交与调用前强制; 乐观锁 row_version';
COMMENT ON COLUMN ai_user_limits.daily_token_limit IS
    '该账号每日 token 上限(上海时区); NULL=跟随全局每日预算 uten.ai.daily-token-budget';
COMMENT ON COLUMN ai_user_limits.daily_job_limit IS
    '该账号每日 AI 任务数上限(上海时区); NULL=跟随全局 uten.ai.max-jobs-per-user-per-day';
-- 谁改了谁的限额属于授权面变化, 照 user_permission_overrides 先例挂 FULL/authorization;
-- save 走 CAS + 显式审计事件, 触发器兜底行级前后值。
SELECT fn_audit_track_table('ai_user_limits', 'FULL', 'authorization', false);

CREATE TABLE ai_usage_daily (
    user_id uuid NOT NULL,
    usage_date date NOT NULL,
    calls int NOT NULL DEFAULT 0,
    ok_calls int NOT NULL DEFAULT 0,
    input_tokens bigint NOT NULL DEFAULT 0,
    output_tokens bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, usage_date),
    CONSTRAINT ck_ai_usage_daily_nonneg CHECK (calls >= 0 AND ok_calls >= 0 AND input_tokens >= 0 AND output_tokens >= 0)
);
CREATE INDEX idx_ai_usage_daily_date ON ai_usage_daily(usage_date);
COMMENT ON TABLE ai_usage_daily IS
    'AI 用量按人按日汇总(ADR-164): 由定时任务从 ai_call_logs 归档汇总, 支撑日/月/年视图; 用户删除后行保留, 展示名回退「已删除员工」';
-- 纯计数汇总, 不挂行级审计(登记审计 NONE); 每次实际使用仍由 ai_call_logs 与业务审计事件记录。
SELECT fn_audit_track_table('ai_usage_daily', 'NONE', 'data_change', false);

-- 存量回填: 全量按上海时区分组, 幂等(重跑不重复插入)。
INSERT INTO ai_usage_daily (user_id, usage_date, calls, ok_calls, input_tokens, output_tokens)
SELECT user_id,
       (created_at AT TIME ZONE 'Asia/Shanghai')::date,
       count(*),
       count(*) FILTER (WHERE ok),
       coalesce(sum(input_tokens), 0),
       coalesce(sum(output_tokens), 0)
FROM ai_call_logs
GROUP BY 1, 2
ON CONFLICT DO NOTHING;

-- 业务清空登记: ai_user_limits 随账号保留(PRESERVE), 锚点 user_preferences 是 PRESERVE 段里
-- 全库唯一行(V462 首建后仅 V464 重建过一次该函数, 追加法迁移都没碰过它); 计数==1 与已存在双重守卫。
DO $reset_preserve$
DECLARE definition TEXT; anchor TEXT := '(''user_preferences'', ''PRESERVE'')';
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure), chr(13), '') INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1
       OR position('ai_user_limits' IN definition) > 0 THEN
        RAISE EXCEPTION 'V815 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor, anchor || E',\n (''ai_user_limits'', ''PRESERVE'')');
END;
$reset_preserve$;

-- 业务清空登记: ai_usage_daily 是用量统计, 跟随 ai_call_logs 按 CLEAR 清空; 锚点 ('ai_call_logs','CLEAR')
-- 由 V742 追加过一次, 此后无人再碰(V814 锚点在 ai_chat_action_proposals), 当前定义中唯一。
DO $reset_clear$
DECLARE definition TEXT; anchor TEXT := '(''ai_call_logs'', ''CLEAR'')';
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure), chr(13), '') INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1
       OR position('ai_usage_daily' IN definition) > 0 THEN
        RAISE EXCEPTION 'V815 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor, anchor || E',\n (''ai_usage_daily'', ''CLEAR'')');
END;
$reset_clear$;

DO $v814_self_check$
DECLARE definition TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure), chr(13), '') INTO definition;
    IF position('(''ai_user_limits'', ''PRESERVE'')' IN definition) = 0
       OR position('(''ai_usage_daily'', ''CLEAR'')' IN definition) = 0
       OR to_regclass('ai_user_limits') IS NULL
       OR to_regclass('ai_usage_daily') IS NULL THEN
        RAISE EXCEPTION 'V815 usage dashboard tables or reset registrations missing';
    END IF;
END;
$v814_self_check$;
