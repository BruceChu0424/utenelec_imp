-- 复职事件类型：employment_history.event_type 检查约束加入 'rehire'
-- 配套 EmployeeCommandService.rehire（离职员工恢复在职 + 账号启用 + 任职记录）。

ALTER TABLE employment_history DROP CONSTRAINT employment_history_event_type_check;
ALTER TABLE employment_history ADD CONSTRAINT employment_history_event_type_check
    CHECK (event_type IN ('onboard', 'transfer', 'resign', 'rehire'));
