-- 公司/部门人员概况聚合查询索引。只增加查询索引，不改变既有业务数据。
CREATE INDEX IF NOT EXISTS idx_employees_department_status_current
    ON employees(department_id, status)
    WHERE is_deleted = false;

CREATE INDEX IF NOT EXISTS idx_history_event_date_type
    ON employment_history(event_date, event_type);

CREATE INDEX IF NOT EXISTS idx_history_from_dept_date
    ON employment_history(from_dept_id, event_date)
    WHERE from_dept_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_history_to_dept_date
    ON employment_history(to_dept_id, event_date)
    WHERE to_dept_id IS NOT NULL;
