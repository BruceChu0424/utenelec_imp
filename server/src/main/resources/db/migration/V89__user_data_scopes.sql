-- =====================================================================
-- V89：数据范围授权（按人授权的归属可见性中间档）
-- =====================================================================
-- 背景：V85/V86 落地「归属隔离」后只有两档——自己（+公共）/ 全部（*:view:all）。
--   用户要求中间档：「有时候别人也可以看 有些人的产品/客户」，在权限管理页按人配置。
-- 设计：user_data_scopes（用户 × 业务范围 × 可见归属人）：
--   可见规则升级为 owner IS NULL OR owner ∈ {本人} ∪ {授权归属人} OR 持 *:view:all。
--   scope：goods（外贸货品）/ client（客户资料），后续模块复用同表扩展。
-- =====================================================================

CREATE TABLE IF NOT EXISTS user_data_scopes (
    user_id            UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    scope              TEXT NOT NULL CHECK (scope IN ('goods', 'client')),
    owner_employee_id  UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         UUID,
    PRIMARY KEY (user_id, scope, owner_employee_id)
);
CREATE INDEX IF NOT EXISTS idx_uds_scope ON user_data_scopes(scope, owner_employee_id);
