-- =====================================================================
-- V833：个人通知弹窗开关（ADR-172）
-- =====================================================================
-- 用户口径（2026-10-09）：工作台右上角「通知设置」入口，列出本人当前会收到的
-- 弹窗提醒类别，可逐类关闭；关闭后不再弹（居中行动卡与顶部到达条都不再出现）。
-- 边界：
--   · 只抑制「弹窗」这一层——通知仍正常落库，通知中心列表、未读徽章、办结撤回、
--     V825 式补发与去重口径全部不变（个人静音不等于业务事实消失）；
--   · 范围 = ReviewNoticeCatalog 注册的可行动事件；人事打卡（acknowledge）与
--     运维/账号安全告警面向强制动作或超管本身，不开放关闭；
--   · 部门共享任务卡其他人照常收到——这是个人偏好，不是任务改派。
-- =====================================================================

CREATE TABLE notice_popup_preferences (
    user_id uuid NOT NULL,
    source_event text NOT NULL,
    disabled_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, source_event),
    CONSTRAINT notice_popup_preferences_user_fk
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

COMMENT ON TABLE notice_popup_preferences IS
    '个人通知弹窗开关(V833/ADR-172)：存在行=该用户已关闭该 source_event 的弹窗提醒；通知本身仍落库并在通知中心可见';

-- 个人账号配置而非业务数据：清空业务数据时与 user_preferences 同款 PRESERVE。
-- reset_business_table_policy 是 business_data_reset() 体内的会话级临时表(V462)，
-- 迁移期不存在、不能直接 INSERT——按 V815 范式锚点改写函数体完成登记。
-- 锚点 user_preferences 在 V815 追加 ai_user_limits 后仍是函数体中唯一行。
DO $reset_preserve$
DECLARE definition TEXT; anchor TEXT := '(''user_preferences'', ''PRESERVE'')';
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure), chr(13), '') INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1
       OR position('notice_popup_preferences' IN definition) > 0 THEN
        RAISE EXCEPTION 'V833 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor, anchor || E',\n (''notice_popup_preferences'', ''PRESERVE'')');
END;
$reset_preserve$;

DO $v833_self_check$
DECLARE definition TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure), chr(13), '') INTO definition;
    IF position('(''notice_popup_preferences'', ''PRESERVE'')' IN definition) = 0
       OR to_regclass('notice_popup_preferences') IS NULL THEN
        RAISE EXCEPTION 'V833 popup preferences table or reset registration missing';
    END IF;
END;
$v833_self_check$;
