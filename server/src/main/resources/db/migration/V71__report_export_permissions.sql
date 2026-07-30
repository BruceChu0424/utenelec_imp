-- V71：报表加密导出独立权限点（*_report:export）
-- --------------------------------------------------------------------------------
-- 背景：Phase 3 加密导出（POST /export）此前复用 *_report:view 鉴权。安全加固（用户铁律：
-- 敏感操作独立权限点，后端 @PreAuthorize 不信前端）拆出 *_report:export，使「能看」≠「能导出」。
-- 导出涉及整表数据外发（加密 Excel），应比查看更严格、可单独审计/回收。
--
-- 策略：
--   ① 6 个模块各新增 *_report:export 权限点（sort_order 紧随对应 :view，同 category）。
--   ② 回填：把 :export 授予所有已持有对应 :view 的部门（导出跟随查看，避免现有用户断权）。
--      用 department_permissions 自连接 + REPLACE(':view'→':export') 关联，只覆盖显式赋过 view 的部门。
--
-- 注意：权限在 JWT claim，本迁移上线后用户须重登，新 token 才带 *_report:export（旧 token 导出会 403）。
-- 超管恒有全部权限（SecurityConfig 硬编码 ROLE_SUPER_ADMIN 放行），不受影响。

-- ① 6 个导出权限点
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('purchase_report:export',    '导出采购报表', '采购管理', 141),
    ('sales_report:export',       '导出销售报表', '销售报表', 281),
    ('subcontract_report:export', '导出委外报表', '委外报表', 381),
    ('stock_report:export',       '导出仓库报表', '库存管理', 213),
    ('production_report:export',  '导出生产报表', '生产报表', 451),
    ('finance_report:export',     '导出钱流报表', '钱流报表', 581)
ON CONFLICT (code) DO NOTHING;

-- ② 回填：导出跟随查看（所有持有 *_report:view 的部门自动获得对应 *_report:export）
INSERT INTO department_permissions (department_id, permission_id)
SELECT dp.department_id, p_export.id
FROM department_permissions dp
JOIN permissions p_view  ON p_view.id  = dp.permission_id
JOIN permissions p_export ON p_export.code = REPLACE(p_view.code, ':view', ':export')
WHERE p_view.code IN ('purchase_report:view','sales_report:view','subcontract_report:view',
                      'stock_report:view','production_report:view','finance_report:view')
  AND p_export.code IN ('purchase_report:export','sales_report:export','subcontract_report:export',
                        'stock_report:export','production_report:export','finance_report:export')
ON CONFLICT DO NOTHING;

-- ③ 主档导出独立权限（与报表 :export 对称：货品/客户/供应商含 PII，币种/账户为财务主数据；
--    同为整表加密外发，须与查看权限分离）
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('goods:export',    '导出货品',   '主数据', 21),
    ('client:export',   '导出客户',   '主数据', 43),
    ('supplier:export', '导出供应商', '主数据', 53),
    ('currency:export', '导出币种',   '主数据', 81),
    ('account:export',  '导出账户',   '基础资料', 101)
ON CONFLICT (code) DO NOTHING;

-- ④ 回填：主档导出跟随主档查看（所有持有 *_view:view 的部门自动获得对应 *_view:export）
INSERT INTO department_permissions (department_id, permission_id)
SELECT dp.department_id, p_export.id
FROM department_permissions dp
JOIN permissions p_view  ON p_view.id  = dp.permission_id
JOIN permissions p_export ON p_export.code = REPLACE(p_view.code, ':view', ':export')
WHERE p_view.code IN ('goods:view','client:view','supplier:view','currency:view','account:view')
  AND p_export.code IN ('goods:export','client:export','supplier:export','currency:export','account:export')
ON CONFLICT DO NOTHING;
