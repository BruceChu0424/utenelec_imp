-- =====================================================================
-- V212：业务部门默认权限矩阵（权威来源）
-- =====================================================================
-- 背景：department_permissions 此前由 V29/V31-57/V99/V130/V183/V196/V198/V200/V204
--   等多个迁移零散累加，2026-08-03 dev 库 TRUNCATE 业务表后这些种子不再重跑，
--   导致部门权限页全空。本迁移把 15 个业务部门的默认权限收敛为「单一权威来源」。
--
-- 策略（受控重置）：
--   * 对下方每个业务部门：先 DELETE 该部门的全部权限，再 INSERT 矩阵授予集。
--     - dev 库（当前空）：直接灌入。
--     - 全新 bootstrap：盖掉散落在 V29-V211 的历史授权，本迁移成为这 15 个节点
--       的权威来源（含 V198/V200 已收窄的 PMC 商业字段，本矩阵以叶子部门为准）。
--   * 只动这 15 个业务节点；3 个管理中心 / 公司节点 / 未列出的二级班组保持空白，
--     避免在父节点堆权限导致越权下传。
--   * 部门权限向上递归继承（PermissionResolver 沿 parent_id 取祖先并集）：
--     挂在父部门（如 DEPT_SALES）的权限自动对其子部门（销售一~四组）员工生效，
--     故写权限尽量下沉到叶子部门。
--
-- 高危/个人-only 权限（任何部门都不授予，需逐条个人点名）：
--   audit_log:view, audit_log:export, authorization:manage, user:manage,
--   stock:balance:adjust, finance_asset:approve/post/dispose/export,
--   finance_asset_period:manage, workflow_assignment:manage
--
-- 全员基础权限（employee 角色包，role_permissions，不在本迁移）：
--   profile:edit:self, expense:apply, notice:read, suggestion:submit,
--   visitor:apply, visitor:host-confirm, payroll:view:self
-- =====================================================================

-- ---------------------------------------------------------------------
-- GM 总经办：全公司只读 + 管理视角；唯一例外 sales_order:change_planned
-- （管理层改量/取消已排产订单，不挂生产部以免下传 6 车间）
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'GM');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'viewcontext:scoped',
    'employee:view', 'department:view',
    'goods:view', 'material_category:view', 'mould:view', 'mould_category:view',
    'client:view', 'client_category:view', 'supplier:view', 'supplier_category:view',
    'color:view', 'unit:view', 'currency:view', 'warehouse:view',
    'account:view', 'payment_style:view',
    'purchase_request:view', 'purchase_order:view', 'purchase_receipt:view',
    'purchase_return:view', 'purchase_report:view',
    'sales_quote:view', 'sales_order:view', 'sales_shipment:view',
    'sales_other_shipment:view', 'sales_return:view', 'sales_report:view',
    'subcontract_inquiry:view', 'subcontract_application:view', 'subcontract_order:view',
    'subcontract_receipt:view', 'subcontract_material_issue:view', 'subcontract_return:view',
    'subcontract_material_return:view', 'subcontract_waste:view', 'subcontract_report:view',
    'production_plan:view', 'production_plan_cost:view', 'production_daily_report:view',
    'production_report:view', 'production_where_used:view',
    'stock:view', 'inventory:view', 'stock_doc:view', 'stock_report:view',
    'finance_receipt:view', 'finance_payment:view', 'finance_expense:view',
    'finance_other_income:view', 'finance_bank_transfer:view', 'finance_reconciliation:view',
    'ar_ap_ledger:view', 'finance_asset:view', 'finance_report:view',
    'planning_supply_request:view', 'warehouse_inbound:view', 'finance_order_approval:view',
    'sales_order:change_planned'
)
WHERE d.code = 'GM' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DEPT_HR 行政与人力资源部（→ 人力资源组/优腾行政组/园区行政组继承）
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'DEPT_HR');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'employee:view', 'employee:create', 'employee:edit', 'employee:delete',
    'employee:pii:view', 'employee:pii:edit',
    'employee:compensation:view', 'employee:compensation:edit',
    'employee:export',
    'department:view', 'department:edit',
    'account:support',
    'notice:publish', 'suggestion:reply', 'profile:review',
    'payroll:generate', 'payroll:review', 'payroll:publish', 'payroll:view:all', 'payroll:export',
    'visitor:view', 'visitor:approve', 'visitor:blacklist'
)
WHERE d.code = 'DEPT_HR' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DEPT_FIN 财务部
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'DEPT_FIN');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'account:view', 'account:edit', 'account:export',
    'payment_style:view', 'payment_style:edit',
    'currency:view', 'currency:edit', 'currency:export',
    'finance_receipt:view', 'finance_receipt:edit',
    'finance_payment:view', 'finance_payment:edit',
    'finance_expense:view', 'finance_expense:edit',
    'finance_other_income:view', 'finance_other_income:edit',
    'finance_bank_transfer:view', 'finance_bank_transfer:edit',
    'finance_reconciliation:view', 'ar_ap_ledger:view',
    'finance_asset:view', 'finance_asset:edit',
    'finance_post:execute', 'finance_shipment_audit',
    'finance_order_approval:view', 'finance_order_approval:review',
    'expense:pay', 'expense:approve',
    'dashboard:finance-sensitive:view',
    'finance_report:view', 'finance_report:export',
    'supplier:view', 'client:view', 'goods:view', 'material_category:view',
    'purchase_request:view', 'purchase_order:view', 'purchase_receipt:view',
    'purchase_return:view', 'purchase_report:view',
    'sales_quote:view', 'sales_order:view', 'sales_shipment:view',
    'sales_other_shipment:view', 'sales_return:view', 'sales_report:view',
    'subcontract_order:view', 'subcontract_receipt:view', 'subcontract_report:view',
    'stock:view', 'inventory:view', 'stock_doc:view', 'stock_report:view',
    'employee:view', 'department:view'
)
WHERE d.code = 'DEPT_FIN' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DEPT_PROD 生产部（→ 注塑/五金铜铸/机械加工/装配/ESD/轨道装配 6 车间继承）
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'DEPT_PROD');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'production_plan:view', 'production_plan:edit', 'production_plan:forward_rd',
    'production_plan_cost:view',
    'production_daily_report:view', 'production_daily_report:edit',
    'production_report:view', 'production_report:export', 'production_where_used:view',
    'mould:view', 'mould:edit', 'mould_category:view', 'mould_category:edit',
    'goods:view', 'material_category:view',
    'stock:view', 'inventory:view', 'stock_doc:view',
    'planning_supply_request:view',
    'employee:view'
)
WHERE d.code = 'DEPT_PROD' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DEPT_ENG 工程研发部（→ PE 工程组/研发工程组继承）
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'DEPT_ENG');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'rd_task:view', 'rd_task:edit', 'rd_task:resolve',
    'production_plan:forward_rd', 'production_where_used:view',
    'production_plan:view', 'production_plan_cost:view', 'production_report:view',
    'goods:view', 'goods:edit', 'material_category:view', 'material_category:edit',
    'mould:view', 'mould:edit', 'mould_category:view',
    'stock:view', 'inventory:view',
    'employee:view'
)
WHERE d.code = 'DEPT_ENG' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DEPT_PMC PMC运营部（→ 计划/采购/物控/仓储 4 子部门继承；本节点只放全体 PMC 共有）
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'DEPT_PMC');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'goods:view', 'goods:edit', 'material_category:view',
    'supplier:view', 'supplier_category:view',
    'client:view', 'client_category:view',
    'color:view', 'unit:view', 'currency:view', 'warehouse:view',
    'stock:view', 'inventory:view', 'stock_doc:view', 'stock_report:view',
    'planning_supply_request:view',
    'purchase_request:view', 'purchase_order:view', 'purchase_receipt:view',
    'purchase_return:view', 'purchase_report:view',
    'subcontract_order:view',
    'warehouse_inbound:view',
    'production_plan:view',
    'employee:view', 'department:view'
)
WHERE d.code = 'DEPT_PMC' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- SUB_PLAN PMC运营计划部（叶子）：计划/MRP/缺料/下达需求
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'SUB_PLAN');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'production_plan:edit', 'production_plan:forward_rd', 'production_plan_cost:view',
    'production_report:view', 'production_daily_report:view',
    'planning_supply_request:view',
    'purchase_request:view',
    'sales_order:change_planned'
)
WHERE d.code = 'SUB_PLAN' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- SUB_PURCHASE PMC运营采购部（叶子）：采购单据 + 主档维护
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'SUB_PURCHASE');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'purchase_request:edit', 'purchase_order:edit', 'purchase_receipt:edit', 'purchase_return:edit',
    'purchase_order:submit_finance',
    'purchase_report:view', 'purchase_report:export',
    'supplier:edit', 'supplier_category:edit',
    'goods:edit', 'material_category:edit',
    'color:edit', 'unit:edit',
    'warehouse_inbound:view'
)
WHERE d.code = 'SUB_PURCHASE' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- SUB_WL 物料控制部（叶子）：物料分类/齐套/缺料（库存等只读由父 DEPT_PMC 提供）
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'SUB_WL');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'material_category:view', 'material_category:edit',
    'goods:view',
    'planning_supply_request:view',
    'purchase_request:view',
    'production_plan_cost:view', 'production_plan:view'
)
WHERE d.code = 'SUB_WL' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- SUB_WH PMC运营仓储部（叶子）：库存/出入库/退货质检/出货仓库作业
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'SUB_WH');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'stock:edit', 'stock_doc:edit',
    'stock_report:view', 'stock_report:export',
    'warehouse:edit',
    'warehouse_inbound:view',
    'sales_shipment:warehouse-work',
    'sales_return_quality:view', 'sales_return_quality:handle',
    'goods:view', 'inventory:view'
)
WHERE d.code = 'SUB_WH' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DEPT_SALES 综合营销事业部（→ 销售 1~4 组继承）：客户/销售单据/委外跟单/报表
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'DEPT_SALES');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'client:view', 'client:edit', 'client:export', 'client:view:all',
    'client_category:view', 'client_category:edit',
    'sales_quote:view', 'sales_quote:edit',
    'sales_order:view', 'sales_order:edit', 'sales_order:price:view', 'sales_order:confirm_partial_shipment',
    'sales_shipment:view', 'sales_shipment:edit', 'sales_shipment:reject',
    'sales_other_shipment:view', 'sales_other_shipment:edit',
    'sales_return:view', 'sales_return:edit', 'sales_return_quality:view',
    'sales_report:view', 'sales_report:export', 'sales:view:all',
    'subcontract_inquiry:view', 'subcontract_inquiry:edit',
    'subcontract_application:view', 'subcontract_application:edit',
    'subcontract_order:view', 'subcontract_order:edit', 'subcontract_order:submit_finance',
    'subcontract_receipt:view', 'subcontract_receipt:edit',
    'subcontract_material_issue:view', 'subcontract_material_issue:edit',
    'subcontract_return:view', 'subcontract_return:edit',
    'subcontract_material_return:view', 'subcontract_material_return:edit',
    'subcontract_waste:view', 'subcontract_waste:edit',
    'subcontract_report:view', 'subcontract_report:export',
    'goods:view', 'material_category:view',
    'employee:view', 'department:view'
)
WHERE d.code = 'DEPT_SALES' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DEPT_RAIL 轨道事业部（→ 慕朵/智谦轨道销售组继承）：平行销售线，同 DEPT_SALES 集
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'DEPT_RAIL');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'client:view', 'client:edit', 'client:export', 'client:view:all',
    'client_category:view', 'client_category:edit',
    'sales_quote:view', 'sales_quote:edit',
    'sales_order:view', 'sales_order:edit', 'sales_order:price:view', 'sales_order:confirm_partial_shipment',
    'sales_shipment:view', 'sales_shipment:edit', 'sales_shipment:reject',
    'sales_other_shipment:view', 'sales_other_shipment:edit',
    'sales_return:view', 'sales_return:edit', 'sales_return_quality:view',
    'sales_report:view', 'sales_report:export', 'sales:view:all',
    'subcontract_inquiry:view', 'subcontract_inquiry:edit',
    'subcontract_application:view', 'subcontract_application:edit',
    'subcontract_order:view', 'subcontract_order:edit', 'subcontract_order:submit_finance',
    'subcontract_receipt:view', 'subcontract_receipt:edit',
    'subcontract_material_issue:view', 'subcontract_material_issue:edit',
    'subcontract_return:view', 'subcontract_return:edit',
    'subcontract_material_return:view', 'subcontract_material_return:edit',
    'subcontract_waste:view', 'subcontract_waste:edit',
    'subcontract_report:view', 'subcontract_report:export',
    'goods:view', 'material_category:view',
    'employee:view', 'department:view'
)
WHERE d.code = 'DEPT_RAIL' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DEPT_NEWMEDIA 新媒体事业部：营销/线上获客（保守销售子集）
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'DEPT_NEWMEDIA');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'client:view', 'client:edit',
    'sales_quote:view', 'sales_quote:edit',
    'sales_order:view', 'sales_order:edit',
    'goods:view', 'sales_report:view',
    'employee:view'
)
WHERE d.code = 'DEPT_NEWMEDIA' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DEPT_QA 品质管理部（→ 检验检测室/质量与认证室/外协工作组继承）
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'DEPT_QA');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'lab:test:view', 'lab:test:upload',
    'sales_return_quality:view', 'sales_return_quality:handle',
    'goods:view', 'material_category:view', 'mould:view',
    'production_report:view', 'production_plan:view',
    'purchase_receipt:view', 'purchase_return:view',
    'subcontract_receipt:view', 'subcontract_return:view',
    'stock:view', 'inventory:view',
    'employee:view'
)
WHERE d.code = 'DEPT_QA' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DEPT_SECURITY 保安部：访客门岗（最窄）
-- ---------------------------------------------------------------------
DELETE FROM department_permissions
WHERE department_id = (SELECT id FROM departments WHERE code = 'DEPT_SECURITY');

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'visitor:view', 'visitor:approve', 'visitor:check-in', 'visitor:blacklist'
)
WHERE d.code = 'DEPT_SECURITY' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;
