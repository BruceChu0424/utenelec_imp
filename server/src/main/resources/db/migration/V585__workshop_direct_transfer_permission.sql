-- =====================================================================
-- V585：车间直送的接收需求列 + 审核权限 production_direct_transfer:approve
-- =====================================================================
-- 背景(2026-09-15 用户口径「既然是车间内流转，步骤能简化就简化，比如不需要领料、
-- 自动解锁」)：带「转下一道工序」的报工，主管点一次审核就自动做完四件事——
--   ① 记一条班组自检放行(production_fqc_inspections，kind=WORKSHOP_SELF)
--   ② 料进本车间线边仓(FINISHED_IN 确认，B 的完工量与成本才算数)
--   ③ 重算上层工单齐套并形成线边仓领料单
--   ④ 把料投给上层工单那条需求(不用再点领料、不惊动仓库)
-- =====================================================================

-- ⓪ 草稿期记住「这一行投给哪个上层工单」。
-- 直送事实(production_workshop_direct_transfer_items)是追加式的，审核才写；
-- 但车间填报工草稿时就要选好接收工单，而草稿会被反复编辑(update 是整批删明细再重建)，
-- 所以这个选择只能落在报工行自己身上。
ALTER TABLE production_daily_report_items
    ADD COLUMN direct_transfer_demand_id UUID REFERENCES production_material_demands(id);

-- 去向与接收需求同进同出：选了转送车间就必须指明投给谁，没选就不许挂。
ALTER TABLE production_daily_report_items
    ADD CONSTRAINT production_daily_report_item_direct_transfer_chk
        CHECK ((destination = 'WORKSHOP') = (direct_transfer_demand_id IS NOT NULL));

CREATE INDEX idx_daily_report_item_direct_transfer_demand
    ON production_daily_report_items(direct_transfer_demand_id)
    WHERE direct_transfer_demand_id IS NOT NULL;

COMMENT ON COLUMN production_daily_report_items.direct_transfer_demand_id IS
    '车间直送的接收需求(V585)：这一行的产出投给同车间哪条上层物料需求；destination=WORKSHOP 时必填';

-- ① 审核权限点。
-- 为什么要单独一个码，而不是靠 production_daily_report:approve 顺带：
--   上面那条链在正常流程里分别需要 production_quality_inspection:approve(品质部 + QA 组织范围)、
--   stock_doc:approve(仓库 + SUB_WH 部门子树)、stock_doc:issue 三个码。把它们隐式塞进
--   「日报审核」等于一次看不见的提权——谁有报工审核权，谁就能写品质放行和库存事实。
--   独立一个码让这份授权是显式的、可回收的、审计时看得见的。
--   持有本码**不等于**获得那三个码：它只允许在「同车间直送」这条被 V584 守卫钉死的窄路径上
--   写那几笔事实(两段与线边仓必须同车间、同主仓、同货品同颜色、不得超过收料需求量)。
-- 幂等：ON CONFLICT，重跑安全。
INSERT INTO permissions (code, name, module, category, sort_order, action_type, description,
                         active, assignable, bulk_assignable, sensitivity)
VALUES ('production_direct_transfer:approve', '审核车间直送报工', '生产管理', '车间执行', 40, 'APPROVE',
        '审核带「转下一道工序」的报工：同事务完成班组自检放行、料进本车间线边仓、重算上层工单齐套并投入。'
        || '仅限子件工单与上层工单同属一个车间；跨车间仍走仓库送检登记与品质部检验',
        TRUE, TRUE, FALSE, 'NORMAL')
ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name, module = EXCLUDED.module, category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order, action_type = EXCLUDED.action_type,
    description = EXCLUDED.description, active = EXCLUDED.active,
    assignable = EXCLUDED.assignable, bulk_assignable = EXCLUDED.bulk_assignable,
    sensitivity = EXCLUDED.sensitivity;

-- ② 默认授予生产部与 6 个车间(与 V543 的车间默认包同一集合：DEPT_PROD / MFG_CENTER / WS_*)。
--    车间主管本来就持有 production_daily_report:approve，本码只是把「审核时连带写的那几笔
--    事实」显式化；超管可在权限管理页按部门或个人回收。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'production_direct_transfer:approve'
WHERE d.is_deleted = FALSE
  AND (d.code = 'DEPT_PROD' OR d.code = 'MFG_CENTER' OR d.code LIKE 'WS\_%')
ON CONFLICT DO NOTHING;

-- ③ 登记到报工页与车间任务页的权限面，让「权限管理」页的委派候选与按钮一致。
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code = 'production_direct_transfer:approve'
 AND permission.active = TRUE
WHERE surface.surface_key IN ('production.daily-report', 'production.workshop-tasks')
ON CONFLICT (surface_id, permission_id) DO NOTHING;
