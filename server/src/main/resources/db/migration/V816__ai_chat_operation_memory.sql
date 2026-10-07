-- V816 (ADR-163): AI 助手个人操作记忆。
--
-- 记住的是「本人怎么问 -> 服务端怎么解答」: question_key 是 NFKC+小写+去空白标点后的原话
-- (Java 侧生成截 160, DB 不猜), resolution 只允许 OPEN_FORM(打开表单) 与 TOOL(查询工具) 两类。
-- 同一问法重复出现累加 hit_count 并刷新 last_used_at; 换了解法则覆盖 resolution 并把 hit_count 归 1;
-- 每人只保留最近 50 行(LRU, Java 侧写后收整)。
--
-- 行内容只是问法与工具/表单名的统计, 不是业务单据, 因此不挂行级审计(登记审计 NONE):
-- 用户的每次实际操作仍由确认卡与业务审计事件记录。仅本人可见: 每个读写都以 user_id 本人过滤,
-- 用户删除时随 users 级联删除; 属于对话数据, 业务清空按 CLEAR 清掉(与 ai_chat_action_proposals 同口径)。
CREATE TABLE ai_chat_operation_memory (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    question_key varchar(160) NOT NULL
        CHECK (btrim(question_key) <> '' AND length(question_key) <= 160),
    resolution jsonb NOT NULL CHECK (jsonb_typeof(resolution) = 'object' AND octet_length(resolution::text) <= 512
        AND (resolution->>'kind') IN ('OPEN_FORM', 'TOOL')),
    hit_count int NOT NULL DEFAULT 1 CHECK (hit_count >= 1),
    last_used_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, question_key)
);
CREATE INDEX idx_ai_chat_operation_memory_recent ON ai_chat_operation_memory(user_id, last_used_at DESC);
COMMENT ON TABLE ai_chat_operation_memory IS
    'AI 助手个人操作记忆(ADR-163): 同一问法重复使用只累加计数, 换解法覆盖重计, 每人最近 50 行; 仅本人可见, 用户随时可自行清除, 业务清空按 CLEAR 清掉; 不挂行级审计(登记审计 NONE)';
COMMENT ON COLUMN ai_chat_operation_memory.question_key IS
    'NFKC+小写+去空白标点后的用户原话(Java 侧生成截 160), 同一问法只存一行';
COMMENT ON COLUMN ai_chat_operation_memory.resolution IS
    '服务端当时给出的解法 {"kind": OPEN_FORM|TOOL, "target": 表单或工具名}; 内容不含业务数据';
SELECT fn_audit_track_table('ai_chat_operation_memory', 'NONE', 'data_change', false);

DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''ai_chat_action_proposals'', ''CLEAR'')';
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure), chr(13), '') INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1
       OR position('ai_chat_operation_memory' IN definition) > 0 THEN
        RAISE EXCEPTION 'V816 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor, anchor || E',\n (''ai_chat_operation_memory'', ''CLEAR'')');
END;
$reset_policy$;

DO $v812_self_check$
DECLARE definition TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure), chr(13), '') INTO definition;
    IF position('(''ai_chat_operation_memory'', ''CLEAR'')' IN definition) = 0
       OR to_regclass('ai_chat_operation_memory') IS NULL THEN
        RAISE EXCEPTION 'V816 operation memory table or its CLEAR registration missing';
    END IF;
END;
$v812_self_check$;
