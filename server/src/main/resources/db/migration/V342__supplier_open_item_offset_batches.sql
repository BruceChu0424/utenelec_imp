-- V342: expose the already-audited open-item offset ledger as a reversible
-- finance operation for purchase returns, claim credits and supplier advances.

ALTER TABLE supplier_open_item_offsets
    ADD COLUMN offset_batch_id UUID;

UPDATE supplier_open_item_offsets
SET offset_batch_id = COALESCE(resolution_id, id);

ALTER TABLE supplier_open_item_offsets
    ALTER COLUMN offset_batch_id SET NOT NULL;

CREATE INDEX idx_supplier_open_item_offsets_batch
    ON supplier_open_item_offsets(offset_batch_id, created_at, id);

INSERT INTO permissions
    (code,name,module,category,sort_order,action_type,description)
VALUES
    ('supplier_open_item_offset:apply','应用供应商贷项或预付款','财税管理','供应商结算',595,
        'EXECUTE','把已确认贷项、索赔或预付款逐笔应用到同供应商同币种正应付'),
    ('supplier_open_item_offset:reverse','反转供应商贷项或预付款应用','财税管理','供应商结算',596,
        'EXECUTE','按应用批次对称恢复两边余额并保留历史记录')
ON CONFLICT (code) DO NOTHING;

INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT surface.id,permission.id
FROM permission_surfaces surface
JOIN permissions permission ON permission.code IN (
    'supplier_open_item_offset:apply','supplier_open_item_offset:reverse')
WHERE surface.surface_key='finance.ar-ap'
ON CONFLICT (surface_id,permission_id) DO NOTHING;

INSERT INTO department_permissions(department_id,permission_id)
SELECT department.id,permission.id
FROM departments department
JOIN permissions permission ON permission.code IN (
    'supplier_open_item_offset:apply','supplier_open_item_offset:reverse')
WHERE department.code='DEPT_FIN' AND COALESCE(department.is_deleted,FALSE)=FALSE
ON CONFLICT DO NOTHING;
