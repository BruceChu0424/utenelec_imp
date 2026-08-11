-- V175：组织树拍平——总经办独立成可选部门，三中心提到公司下（方案A）。
-- 背景：V07 把三个管理中心挂在「总经办(GM,决策层骨架)」下。所有者要求拍平这一层：
--       公司(UTEN)下平级 4 个单位，总经办降为「一级部门」可选（可挂人/岗位），
--       三中心保持「管理中心」骨架分组，所有子部门 level 不变。
-- 实现说明：
--   * 不走 DepartmentService.update —— 那会触发 relevelSubtree，按「公司→一级部门」
--     把三中心及其整棵子树强制级联降级（中心→一级部门、生产部等→二级班组、车间→三级科室），
--     破坏方案A。故直接 SQL 改 parent_id/level，子部门 level 原样保留。
--   * path 由 trg_dept_path 触发器维护，但 UPDATE parent_id 只重算当前行、不级联后代，
--     故第 3 步用递归 CTE 重算全表 path，去掉三中心后代里残留的 /GM/ 段。
--   * CHECK 约束 level 值域含「一级部门」「管理中心」，改动合法。

-- 1) 三中心 reparent 到公司（触发器自动重算中心自身 path）；重排 sortOrder。
UPDATE departments d
SET parent_id = ut.id,
    sort_order = v.so
FROM (VALUES
    ('MFG_CENTER', 2),
    ('MKT_CENTER', 3),
    ('FIN_CENTER', 4)
) AS v(code, so)
CROSS JOIN (SELECT id FROM departments WHERE code = 'UTEN') ut
WHERE d.code = v.code;

-- 2) 总经办降为「一级部门」（可选，可挂人/岗位）；parent 仍为 UTEN。
UPDATE departments SET level = '一级部门', sort_order = 1
WHERE code = 'GM';

-- 3) 级联重算全表 path（修正三中心后代去掉 /GM/ 段）。
--    findSubtree 用 parent_id 递归取后代，但 ORDER BY path；detail 也把 path 返给前端，
--    故后代 path 必须与 parent_id 一致。更新 path 列不触发 trg_dept_path（仅 parent_id/code 触发）。
WITH RECURSIVE dept_path AS (
    SELECT id, parent_id, code, '/' || code || '/' AS new_path
    FROM departments WHERE parent_id IS NULL
    UNION ALL
    SELECT d.id, d.parent_id, d.code, dp.new_path || d.code || '/'
    FROM departments d JOIN dept_path dp ON d.parent_id = dp.id
)
UPDATE departments d
SET path = dp.new_path
FROM dept_path dp
WHERE d.id = dp.id AND d.path IS DISTINCT FROM dp.new_path;

-- 注：总经办升为一级部门后未补标准岗位模板——该节点已有 HR 手工维护的高管岗位
-- （董事长/副厂长），总经办属高管层而非"部长制"，强补 LEAD_* 反而冗余且语义不符。
-- GM 变可选后沿用现有岗位即可；如需标准模板由 HR 在岗位管理页自行添加。
