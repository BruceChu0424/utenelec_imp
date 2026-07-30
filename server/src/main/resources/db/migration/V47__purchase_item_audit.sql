-- =====================================================================
-- V47：采购明细表补审计列（created_by/updated_by）
-- =====================================================================
-- V44 建明细表时审计列不全（缺 created_by/updated_by）。明细继承 BaseEntity
-- （id + created_at/updated_at/created_by/updated_by），主表继承 SoftDeletableEntity（+ 软删）。
-- 明细随主表重建（物理删），is_deleted 列保留备用。
-- =====================================================================
ALTER TABLE purchase_request_items
    ADD COLUMN IF NOT EXISTS created_by UUID,
    ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE purchase_order_items
    ADD COLUMN IF NOT EXISTS created_by UUID,
    ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE purchase_receipt_items
    ADD COLUMN IF NOT EXISTS created_by UUID,
    ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE purchase_return_items
    ADD COLUMN IF NOT EXISTS created_by UUID,
    ADD COLUMN IF NOT EXISTS updated_by UUID;
