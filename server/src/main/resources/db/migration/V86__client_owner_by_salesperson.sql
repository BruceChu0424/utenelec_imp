-- =====================================================================
-- V86：客户归属授权（每个销售人员只看自己的客户资料）
-- =====================================================================
-- 背景：用户 YTDQ.txt——「客户资料 每个销售人员一般只能看到自己的客户资料」。
--   老库 B_Client.Emp_ID（业务员 → B_Worker）即归属源，已随客户主档迁入 clients.emp_id（文本）。
-- 设计（与 V85 货品外贸归属同模型，判定逻辑统一在 OwnerVisibility）：
-- ① clients.owner_employee_id：归属业务员（NULL=公共客户，全员可见）；
--    由 migrate_client_owner.sql 按 emp_id → employees.legacy_id 灌入（幂等 UPDATE）。
-- ② 新权限点 client:view:all「查看全部客户资料」：
--    默认规则 = 归属客户仅归属人本人可见；持此点者（销售管理/客服/财务等）可见全部。
--    超管恒有全部权限；默认不回填任何部门（最小授权，权限管理页按需配置）。
-- 服务端强制（ClientService.list/facets），前端零改动。
-- =====================================================================

ALTER TABLE clients
    ADD COLUMN IF NOT EXISTS owner_employee_id UUID REFERENCES employees(id);
CREATE INDEX IF NOT EXISTS idx_clients_owner ON clients(owner_employee_id) WHERE owner_employee_id IS NOT NULL;

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('client:view:all', '查看全部客户资料', '主数据', 24)
ON CONFLICT (code) DO NOTHING;
