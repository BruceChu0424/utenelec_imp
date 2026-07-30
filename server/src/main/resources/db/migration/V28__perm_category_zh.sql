-- V28：权限目录分组名中文化
-- 背景：权限管理页的权限目录按 permissions.category 分组展示，
-- 历史种子（V06/V12/V13/V19/V25）的 category 是英文模块 key（employee/payroll/...），
-- 中文模式下分组标题显示为英文。统一改为中文模块名。
-- name 列历次种子已是中文，无需调整；code 为技术标识保持不变。
-- 注：未实现模块（采购/客户/供应商/账户/基础资料）不登记权限点，
-- 待功能落地时随对应迁移一并加入（含其中文 category）。

UPDATE permissions SET category = '员工档案'      WHERE category = 'employee';
UPDATE permissions SET category = '部门管理'      WHERE category = 'department';
UPDATE permissions SET category = '账号管理'      WHERE category = 'user';
UPDATE permissions SET category = '工资条'        WHERE category = 'payroll';
UPDATE permissions SET category = '报销'          WHERE category = 'expense';
UPDATE permissions SET category = '通知'          WHERE category = 'notice';
UPDATE permissions SET category = '意见箱'        WHERE category = 'suggestion';
UPDATE permissions SET category = '检测记录'      WHERE category = 'lab';
UPDATE permissions SET category = '生产'          WHERE category = 'production';
UPDATE permissions SET category = '库存'          WHERE category = 'inventory';
UPDATE permissions SET category = '系统'          WHERE category = 'system';
UPDATE permissions SET category = '访客'          WHERE category = 'visitor';
UPDATE permissions SET category = '个人信息'      WHERE category = 'profile';
UPDATE permissions SET category = '决策支持'      WHERE category = 'analytics';
