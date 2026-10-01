-- Preserve original command-user identity separately from the inspector employee snapshot.
-- No historical backfill: today's employee/account link cannot prove a past command actor.
ALTER TABLE procurement_inspection_events
    ADD COLUMN actor_user_id UUID REFERENCES users(id) ON DELETE RESTRICT;
COMMENT ON COLUMN procurement_inspection_events.actor_user_id IS
    '原质量处置命令账号身份；历史NULL为LEGACY不可推断或绑定当前账号，员工姓名仍由actor_employee_id保留';
