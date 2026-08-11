-- 访客申请长期数据分页索引。
-- 三类列表均使用 created_at DESC, id DESC 稳定排序，并只读取未删除记录。
CREATE INDEX IF NOT EXISTS idx_visitor_app_account_created_active
    ON visitor_applications(visitor_account_id, created_at DESC, id DESC)
    INCLUDE (status)
    WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_visitor_app_account_status_created_active
    ON visitor_applications(visitor_account_id, status, created_at DESC, id DESC)
    WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_visitor_app_status_created_active
    ON visitor_applications(status, created_at DESC, id DESC)
    WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_visitor_app_host_status_created_active
    ON visitor_applications(host_employee_id, status, created_at DESC, id DESC)
    WHERE is_deleted = FALSE;
