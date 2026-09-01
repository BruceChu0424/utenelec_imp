-- V445: exact read-only warehouse document-history permissions and surfaces.
--
-- Additive-only migration: existing department/user grants are not removed here.
-- The warehouse history APIs are structurally non-commercial even when the caller
-- also has purchase/finance price permissions.

ALTER TABLE permissions
    ADD COLUMN IF NOT EXISTS bulk_assignable BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE permissions
    ADD COLUMN IF NOT EXISTS sensitivity TEXT NOT NULL DEFAULT 'NORMAL';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'permissions_sensitivity_chk'
          AND conrelid = 'permissions'::regclass
    ) THEN
        ALTER TABLE permissions
            ADD CONSTRAINT permissions_sensitivity_chk
            CHECK (sensitivity IN ('NORMAL', 'SENSITIVE_COMMERCIAL'));
    END IF;
END;
$$;

-- Commercial visibility permissions remain individually assignable, but the
-- permission UI must not sweep them into group/module/all bulk operations.
UPDATE permissions
SET bulk_assignable = FALSE,
    sensitivity = 'SENSITIVE_COMMERCIAL'
WHERE code LIKE '%:price:view'
   OR code IN (
       'goods:cost:view',
       'subcontract_waste:suggestion:view',
       'dashboard:finance-sensitive:view',
       'procurement_iqc_rejection:amount:view'
   );

INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description,
     active, assignable, bulk_assignable, sensitivity)
VALUES
    ('warehouse_purchase_receipt_history:view',
     '查看仓库采购收货历史', '仓库管理', '采购收货历史', 310,
     'VIEW', '仅查看采购收货的实物、数量、重量、库位、来源与质检状态；不含任何商业金额',
     TRUE, TRUE, TRUE, 'NORMAL'),
    ('warehouse_subcontract_receipt_history:view',
     '查看仓库委外进仓历史', '仓库管理', '委外进仓历史', 311,
     'VIEW', '仅查看委外进仓的实物、数量、重量、库位、来源与质检状态；不含任何商业金额',
     TRUE, TRUE, TRUE, 'NORMAL'),
    ('warehouse_subcontract_outbound_history:view',
     '查看仓库委外出仓历史', '仓库管理', '委外出仓历史', 312,
     'VIEW', '查看已执行委外出仓的实物、数量、重量、来源与退回损耗进度',
     TRUE, TRUE, TRUE, 'NORMAL'),
    ('warehouse_subcontract_finished_return_history:view',
     '查看仓库委外成品退货历史', '仓库管理', '委外成品退货历史', 313,
     'VIEW', '查看退回委外商的成品实物、数量、重量、仓库与来源；不含反向应付金额',
     TRUE, TRUE, TRUE, 'NORMAL'),
    ('warehouse_subcontract_material_return_history:view',
     '查看仓库委外材料退回历史', '仓库管理', '委外材料退回历史', 314,
     'VIEW', '查看委外商退回余料的实物、数量、重量、库位与来源',
     TRUE, TRUE, TRUE, 'NORMAL'),
    ('warehouse_subcontract_waste_history:view',
     '查看仓库委外损耗历史', '仓库管理', '委外损耗历史', 315,
     'VIEW', '查看委外材料损耗数量、重量、损耗率、原因和来源；不含建议索赔金额',
     TRUE, TRUE, TRUE, 'NORMAL'),
    ('warehouse_iqc_return:view',
     '查看仓库 IQC 不合格实物退回', '仓库管理', 'IQC 实物退回', 316,
     'VIEW', '查看采购与委外 IQC 拒收实物及退回凭证；不含金额、贷项、抵销或财务结案',
     TRUE, TRUE, TRUE, 'NORMAL')
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order,
    action_type = EXCLUDED.action_type,
    description = EXCLUDED.description,
    active = TRUE,
    assignable = TRUE,
    bulk_assignable = TRUE,
    sensitivity = 'NORMAL';

INSERT INTO permission_surfaces
    (id, surface_key, name, sort_order, enabled)
VALUES
    ('44500000-0000-4000-8000-000000000001',
     'warehouse.purchase-receipt-history', '仓库采购收货历史', 62, TRUE),
    ('44500000-0000-4000-8000-000000000002',
     'warehouse.subcontract-receipt-history', '仓库委外进仓历史', 63, TRUE),
    ('44500000-0000-4000-8000-000000000003',
     'warehouse.subcontract-outbound-history', '仓库委外出仓历史', 64, TRUE),
    ('44500000-0000-4000-8000-000000000004',
     'warehouse.subcontract-finished-return-history', '仓库委外成品退货历史', 65, TRUE),
    ('44500000-0000-4000-8000-000000000005',
     'warehouse.subcontract-material-return-history', '仓库委外材料退回历史', 66, TRUE),
    ('44500000-0000-4000-8000-000000000006',
     'warehouse.subcontract-waste-history', '仓库委外损耗历史', 67, TRUE),
    ('44500000-0000-4000-8000-000000000007',
     'warehouse.iqc-return', '仓库 IQC 不合格实物退回', 68, TRUE)
ON CONFLICT (surface_key) DO UPDATE
SET name = EXCLUDED.name,
    sort_order = EXCLUDED.sort_order,
    enabled = TRUE;

WITH mapping(surface_key, permission_code) AS (VALUES
    ('warehouse.purchase-receipt-history', 'warehouse_purchase_receipt_history:view'),
    ('warehouse.subcontract-receipt-history', 'warehouse_subcontract_receipt_history:view'),
    ('warehouse.subcontract-outbound-history', 'warehouse_subcontract_outbound_history:view'),
    ('warehouse.subcontract-finished-return-history', 'warehouse_subcontract_finished_return_history:view'),
    ('warehouse.subcontract-material-return-history', 'warehouse_subcontract_material_return_history:view'),
    ('warehouse.subcontract-waste-history', 'warehouse_subcontract_waste_history:view'),
    ('warehouse.iqc-return', 'warehouse_iqc_return:view'),
    ('warehouse.iqc-return', 'procurement_iqc_rejection:record_return')
)
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM mapping
JOIN permission_surfaces surface ON surface.surface_key = mapping.surface_key
JOIN permissions permission ON permission.code = mapping.permission_code
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- These pages are the warehouse department's normal read-only history tools.
-- Grant only the leaf department so the permission does not leak to its siblings.
INSERT INTO department_permissions (department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission ON permission.code IN (
    'warehouse_purchase_receipt_history:view',
    'warehouse_subcontract_receipt_history:view',
    'warehouse_subcontract_outbound_history:view',
    'warehouse_subcontract_finished_return_history:view',
    'warehouse_subcontract_material_return_history:view',
    'warehouse_subcontract_waste_history:view',
    'warehouse_iqc_return:view'
)
WHERE department.code = 'SUB_WH'
  AND department.is_deleted = FALSE
ON CONFLICT DO NOTHING;

DO $$
DECLARE
    missing_mapping_count INTEGER;
    unsafe_mapping_count INTEGER;
BEGIN
    SELECT count(*)
    INTO missing_mapping_count
    FROM (VALUES
        ('warehouse.purchase-receipt-history', 'warehouse_purchase_receipt_history:view'),
        ('warehouse.subcontract-receipt-history', 'warehouse_subcontract_receipt_history:view'),
        ('warehouse.subcontract-outbound-history', 'warehouse_subcontract_outbound_history:view'),
        ('warehouse.subcontract-finished-return-history', 'warehouse_subcontract_finished_return_history:view'),
        ('warehouse.subcontract-material-return-history', 'warehouse_subcontract_material_return_history:view'),
        ('warehouse.subcontract-waste-history', 'warehouse_subcontract_waste_history:view'),
        ('warehouse.iqc-return', 'warehouse_iqc_return:view'),
        ('warehouse.iqc-return', 'procurement_iqc_rejection:record_return')
    ) expected(surface_key, permission_code)
    WHERE NOT EXISTS (
        SELECT 1
        FROM permission_surfaces surface
        JOIN permission_surface_permissions link ON link.surface_id = surface.id
        JOIN permissions permission ON permission.id = link.permission_id
        WHERE surface.surface_key = expected.surface_key
          AND permission.code = expected.permission_code
    );

    IF missing_mapping_count <> 0 THEN
        RAISE EXCEPTION 'V445 missing warehouse history surface mappings: %',
            missing_mapping_count;
    END IF;

    SELECT count(*)
    INTO unsafe_mapping_count
    FROM permission_surfaces surface
    JOIN permission_surface_permissions link ON link.surface_id = surface.id
    JOIN permissions permission ON permission.id = link.permission_id
    WHERE surface.surface_key LIKE 'warehouse.%history'
      AND (
          permission.code LIKE '%:price:view'
          OR permission.code LIKE 'finance_%'
          OR permission.action_type <> 'VIEW'
      );

    IF unsafe_mapping_count <> 0 THEN
        RAISE EXCEPTION
            'V445 warehouse history surfaces contain unsafe permissions: %',
            unsafe_mapping_count;
    END IF;
END;
$$;
