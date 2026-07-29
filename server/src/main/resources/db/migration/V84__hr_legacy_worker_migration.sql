-- =====================================================================
-- V84：人事老库迁移（B_Worker → employees 全量试迁）
-- =====================================================================
-- 背景：老库 B_Worker（72 人）含部门（ParentID → SystemItem ItemclassID=5）、
--   工种（Emp_Style，老库 Post/Duty 全空）、生日/性别/身份证/手机/入职日期等。
--   人事正式录入前，先把老库人事全量迁入做测试数据；正式录入后重新对表，
--   老库有而新库没有的人=离职，保留并标注「老数据中有用」。
-- 本迁移：
-- ① legacy_departments 加 department_id：老库部门 → 新库 departments 的映射位
--   （映射内容在 migrate_hr_workers.sql 中集中维护，HR 可 review 调整）。
-- 员工/职位/敏感信息均用既有表（employees / positions / employee_sensitive），不加列。
-- =====================================================================

ALTER TABLE legacy_departments
    ADD COLUMN IF NOT EXISTS department_id UUID REFERENCES departments(id);
