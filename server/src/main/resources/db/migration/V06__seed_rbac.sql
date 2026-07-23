-- 角色（7 个系统角色）
INSERT INTO roles (code, name, description, is_system) VALUES
    ('employee',  '员工',       '普通员工：看自己工资条/提报销/收通知/提建议', TRUE),
    ('hr',        '人事',       '员工档案/部门/入离职/工资条生成/通知发布',    TRUE),
    ('finance',   '财务',       '报销审批/工资条审核/报表',                    TRUE),
    ('lab',       '实验室',     '检测数据上传与报告',                          TRUE),
    ('production','车间',       '流水线/产量/库存',                            TRUE),
    ('manager',   '管理层',     '只读全公司 + 决策辅助',                       TRUE),
    ('admin',     '管理员',     '全部权限 + 系统管理',                         TRUE);

-- 权限目录
INSERT INTO permissions (code, name, category) VALUES
    ('employee:view',     '查看员工档案',     'employee'),
    ('employee:create',   '创建员工',         'employee'),
    ('employee:edit',     '编辑员工',         'employee'),
    ('employee:delete',   '删除员工',         'employee'),
    ('department:view',   '查看部门',         'department'),
    ('department:edit',   '编辑部门',         'department'),
    ('user:manage',       '账号管理(锁定/角色/重置密码)', 'user'),
    ('payroll:view:self', '查看本人工资条',   'payroll'),
    ('payroll:view:all',  '查看全员工资条',   'payroll'),
    ('payroll:generate',  '生成工资条',       'payroll'),
    ('payroll:review',    '审核工资条',       'payroll'),
    ('payroll:publish',   '发布工资条',       'payroll'),
    ('payroll:export',    '导出工资条',       'payroll'),
    ('expense:apply',     '申请报销',         'expense'),
    ('expense:approve',   '审批报销',         'expense'),
    ('notice:read',       '阅读通知',         'notice'),
    ('notice:publish',    '发布通知',         'notice'),
    ('suggestion:submit', '提交建议',         'suggestion'),
    ('suggestion:reply',  '回复建议',         'suggestion'),
    ('lab:test:view',     '查看检测',         'lab'),
    ('lab:test:upload',   '上传检测',         'lab'),
    ('production:view',   '查看生产',         'production'),
    ('inventory:view',    '查看库存',         'inventory'),
    ('viewcontext:scoped','管理视角切换',     'system');

-- 角色 ↔ 权限映射
-- employee
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code='employee' AND p.code IN
    ('payroll:view:self','expense:apply','notice:read','suggestion:submit');

-- hr
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code='hr' AND p.code IN
    ('employee:view','employee:create','employee:edit','employee:delete',
     'department:view','department:edit','user:manage',
     'payroll:generate','payroll:publish','notice:publish','suggestion:reply',
     'viewcontext:scoped');

-- finance
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code='finance' AND p.code IN
    ('expense:approve','payroll:review','payroll:view:all','payroll:export','viewcontext:scoped');

-- lab
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code='lab' AND p.code IN ('lab:test:view','lab:test:upload');

-- production
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code='production' AND p.code IN ('production:view','inventory:view');

-- manager（只读为主）
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code='manager' AND p.code IN
    ('employee:view','department:view','payroll:view:all','expense:approve','viewcontext:scoped');

-- admin = 全部权限（应用层另有通配，这里显式映射保证即便无通配也齐全）
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p WHERE r.code='admin';
