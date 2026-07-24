-- V24 岗位模板种子（供调试用）
-- 用途：给现有组织节点批量播种"模板岗位"，方便联调；HR 后续可在岗位管理界面自行增删改，
--       本种子不产生任何业务约束，可安全改删。
-- 设计定稿：领导层岗位挂一级部门，班组岗位挂二级班组；
--           公司 / 决策层 / 管理中心（中间层）不设岗位，不播种。
-- code 在同一部门内唯一（uk_positions_code_dept），ON CONFLICT DO NOTHING 保证可重复执行。

-- 一级部门 → 部长 / 副部长 / 主管（职级：领导层）
INSERT INTO positions (code, name, level, department_id, sort_order)
SELECT v.code, v.name, '领导层', d.id, v.sort
FROM departments d
CROSS JOIN (VALUES
    ('LEAD_1', '部长',   1),
    ('LEAD_2', '副部长', 2),
    ('LEAD_3', '主管',   3)
) AS v(code, name, sort)
WHERE d.level = '一级部门' AND d.is_deleted = false
ON CONFLICT (code, department_id) DO NOTHING;

-- 二级班组 → 组长 / 副组长 / 员工（职级：班组管理 / 员工）
INSERT INTO positions (code, name, level, department_id, sort_order)
SELECT v.code, v.name, v.level, d.id, v.sort
FROM departments d
CROSS JOIN (VALUES
    ('GRP_1', '组长',   '班组管理', 1),
    ('GRP_2', '副组长', '班组管理', 2),
    ('GRP_3', '员工',   '员工',     3)
) AS v(code, name, level, sort)
WHERE d.level = '二级班组' AND d.is_deleted = false
ON CONFLICT (code, department_id) DO NOTHING;
