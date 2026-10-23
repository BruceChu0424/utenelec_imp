-- A goods identity may be updated by many imports. Its UUID cannot identify
-- which reversible operation belongs to one import receipt.
ALTER TABLE goods_import_batches
    ADD COLUMN operation_id uuid REFERENCES goods_operation_history(id);

CREATE UNIQUE INDEX idx_goods_import_batches_operation
    ON goods_import_batches(operation_id) WHERE operation_id IS NOT NULL;

COMMENT ON COLUMN goods_import_batches.operation_id IS
    'Exact history operation captured for this batch transaction; null legacy batches require unambiguous recovery';
