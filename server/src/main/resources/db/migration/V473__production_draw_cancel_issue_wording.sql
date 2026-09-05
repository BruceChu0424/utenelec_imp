-- V473: align the stock_doc:reverse_issue permission catalog with the current
-- production DRAW UI. This is a wording-only forward migration: the immutable
-- issue/reversal ledgers, grants, permission code and API compatibility path do
-- not change.

UPDATE permissions
SET name = '取消生产领料出库',
    description = '首次报工前按原生产领料出库行对称恢复库存与物料占用；必须填写原因并保留原出库和取消流水'
WHERE code = 'stock_doc:reverse_issue';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM permissions
        WHERE code = 'stock_doc:reverse_issue'
          AND name = '取消生产领料出库'
          AND description LIKE '%保留原出库和取消流水%'
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'production DRAW cancellation permission wording is not aligned';
    END IF;
END $$;
