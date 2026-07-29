-- =====================================================================
-- V125：责任制 · 制单员/审核员 ID 体系统一（users.id → employees.id）回填
-- =====================================================================
-- 背景：制单员 maker_id / 审核员 approver_id 语义为员工（报表统一按
--   employees.id JOIN 姓名），但本迁移之前服务端写入的是登录账号 users.id，
--   导致新系统单据的制单员/审核员姓名在报表里 JOIN 不到（users.id ≠ employees.id）。
-- 本次：所有已落库的 users.id 值经 users.employee_id 映射回填为 employees.id。
--   - users.employee_id 为 NOT NULL（员工账号必绑档案），访客账号不产生单据；
--   - 老库迁移行的 maker/approver 为 NULL（姓名走 *_legacy_id/*_name 遗留列），不受影响；
--   - 已是 employees.id 的行不会命中 JOIN（users.id 与 employees.id 不相交），幂等可重跑。
-- 此后服务端统一以 SecurityContextCurrentUser.requireEmployeeId() 写入。
-- =====================================================================

-- 采购 ----------------------------------------------------------------------
UPDATE purchase_orders   t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE purchase_orders   t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE purchase_receipts t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE purchase_receipts t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE purchase_requests t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE purchase_requests t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE purchase_returns  t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE purchase_returns  t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;

-- 销售 ----------------------------------------------------------------------
UPDATE sales_orders          t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE sales_orders          t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE sales_quotes          t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE sales_quotes          t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE sales_shipments       t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE sales_shipments       t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE sales_returns         t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE sales_returns         t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE sales_other_shipments t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE sales_other_shipments t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;

-- 委外 ----------------------------------------------------------------------
UPDATE subcontract_orders           t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE subcontract_orders           t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE subcontract_inquiries        t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE subcontract_inquiries        t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE subcontract_applications     t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE subcontract_applications     t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE subcontract_material_issues  t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE subcontract_material_issues  t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE subcontract_receipts         t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE subcontract_receipts         t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE subcontract_material_returns t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE subcontract_material_returns t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE subcontract_returns          t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE subcontract_returns          t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE subcontract_wastes           t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE subcontract_wastes           t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;

-- 财务 ----------------------------------------------------------------------
UPDATE finance_receipts       t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE finance_receipts       t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE finance_payments       t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE finance_payments       t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE finance_expenses       t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE finance_expenses       t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE finance_other_incomes  t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE finance_other_incomes  t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE finance_bank_transfers t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE finance_bank_transfers t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;

-- 生产 ----------------------------------------------------------------------
UPDATE production_plans         t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE production_plans         t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
UPDATE production_daily_reports t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE production_daily_reports t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;

-- 库存 ----------------------------------------------------------------------
UPDATE stock_documents t SET maker_id = u.employee_id FROM users u WHERE t.maker_id = u.id;
UPDATE stock_documents t SET approver_id = u.employee_id FROM users u WHERE t.approver_id = u.id;
