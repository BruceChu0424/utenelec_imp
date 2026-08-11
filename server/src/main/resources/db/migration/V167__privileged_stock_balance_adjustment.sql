-- V167: 高权限库存余额直接调整。
--
-- 该权限不会默认授予任何部门。超级管理员可通过现有权限管理页，
-- 按个人或部门明确授予领导/仓库负责人；撤销后按 V135 auth_version 机制即时失效。
INSERT INTO permissions (code, name, category, sort_order)
VALUES ('stock:balance:adjust', '授权调整库存余额', '库存管理', 202)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

CREATE UNIQUE INDEX IF NOT EXISTS ux_stock_documents_authorized_balance_adjustment_source
    ON stock_documents (source_doc_no)
    WHERE is_deleted = FALSE
      AND source_doc_no LIKE 'AUTHORIZED_BALANCE_ADJUSTMENT:%';

COMMENT ON COLUMN stock_movements.created_by IS
    '库存流水创建账号 users.id；授权余额调整同时由 CHECK 盘点单保留制单人、审核人、前后数量与原因';
