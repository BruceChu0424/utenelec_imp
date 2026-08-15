-- Persist automated structural reconciliation for one reviewed full bootstrap.
-- These checks do not replace amount, quantity, lineage, restore, or business
-- sign-off. They make silent source-row loss and stale UUID relationships block
-- the bootstrap before it can be considered a cutover candidate.

BEGIN;

UPDATE legacy_migration_runs
SET reconciliation_status = 'RUNNING'
WHERE run_id = :'run_id'::uuid
  AND status = 'RUNNING';

DELETE FROM legacy_migration_reconciliation_items
WHERE run_id = :'run_id'::uuid;

INSERT INTO legacy_migration_reconciliation_items (
    run_id, source_entity, target_entity, metric,
    expected_value, actual_value, passed, detail
)
SELECT :'run_id'::uuid, 'goods_categories.csv', 'material_categories',
       'legacy_row_count', :'expected_material_categories'::bigint, count(*),
       count(*) = :'expected_material_categories'::bigint,
       'Counts imported legacy identities; the protected system root is excluded.'
FROM material_categories WHERE legacy_id IS NOT NULL AND legacy_id <> -1
UNION ALL
SELECT :'run_id'::uuid, 'mould_categories.csv', 'mould_categories',
       'legacy_row_count', :'expected_mould_categories'::bigint, count(*),
       count(*) = :'expected_mould_categories'::bigint,
       'Counts imported legacy identities; the protected system root is excluded.'
FROM mould_categories WHERE legacy_id IS NOT NULL AND legacy_id <> -1
UNION ALL
SELECT :'run_id'::uuid, 'client_categories.csv', 'client_categories',
       'legacy_row_count', :'expected_client_categories'::bigint, count(*),
       count(*) = :'expected_client_categories'::bigint,
       'Counts imported legacy identities; the protected system root is excluded.'
FROM client_categories WHERE legacy_id IS NOT NULL AND legacy_id <> -1
UNION ALL
SELECT :'run_id'::uuid, 'supplier_categories.csv', 'supplier_categories',
       'legacy_row_count', :'expected_supplier_categories'::bigint, count(*),
       count(*) = :'expected_supplier_categories'::bigint,
       'Counts imported legacy identities; the protected system root is excluded.'
FROM supplier_categories WHERE legacy_id IS NOT NULL AND legacy_id <> -1
UNION ALL
SELECT :'run_id'::uuid, 'color.csv', 'colors', 'legacy_row_count',
       :'expected_colors'::bigint, count(*),
       count(*) = :'expected_colors'::bigint,
       'Counts rows retaining the reviewed legacy primary key.'
FROM colors WHERE legacy_id IS NOT NULL
UNION ALL
SELECT :'run_id'::uuid, 'unit.csv', 'units', 'legacy_row_count',
       :'expected_units'::bigint, count(*),
       count(*) = :'expected_units'::bigint,
       'Counts rows retaining the reviewed legacy primary key.'
FROM units WHERE legacy_id IS NOT NULL
UNION ALL
SELECT :'run_id'::uuid, 'currency.csv', 'currencies', 'legacy_row_count',
       :'expected_currencies'::bigint, count(*),
       count(*) = :'expected_currencies'::bigint,
       'Counts rows retaining the reviewed legacy primary key.'
FROM currencies WHERE legacy_id IS NOT NULL
UNION ALL
SELECT :'run_id'::uuid, 'warehouse.csv', 'warehouses', 'legacy_row_count',
       :'expected_warehouses'::bigint, count(*),
       count(*) = :'expected_warehouses'::bigint,
       'Counts rows retaining the reviewed legacy primary key.'
FROM warehouses WHERE legacy_id IS NOT NULL
UNION ALL
SELECT :'run_id'::uuid, 'mould.csv', 'moulds', 'legacy_row_count',
       :'expected_moulds'::bigint, count(*),
       count(*) = :'expected_moulds'::bigint,
       'Counts rows retaining the reviewed legacy primary key.'
FROM moulds WHERE legacy_id IS NOT NULL
UNION ALL
SELECT :'run_id'::uuid, 'client.csv', 'clients', 'legacy_row_count',
       :'expected_clients'::bigint, count(*),
       count(*) = :'expected_clients'::bigint,
       'Counts rows retaining the reviewed legacy primary key.'
FROM clients WHERE legacy_id IS NOT NULL
UNION ALL
SELECT :'run_id'::uuid, 'supplier.csv', 'suppliers', 'legacy_row_count',
       :'expected_suppliers'::bigint, count(*),
       count(*) = :'expected_suppliers'::bigint,
       'Counts rows retaining the reviewed legacy primary key.'
FROM suppliers WHERE legacy_id IS NOT NULL
UNION ALL
SELECT :'run_id'::uuid, 'goods.csv', 'goods', 'legacy_row_count',
       :'expected_goods'::bigint, count(*),
       count(*) = :'expected_goods'::bigint,
       'Historical FK anchors have no legacy primary key and are excluded.'
FROM goods WHERE legacy_id IS NOT NULL
UNION ALL
SELECT :'run_id'::uuid, 'export_manifest.json', 'legacy_migration_run_files',
       'consumed_csv_inventory', :'expected_csv_files'::bigint, count(*),
       count(*) = :'expected_csv_files'::bigint,
       'Every CSV in the reviewed target=All manifest must be consumed.'
FROM legacy_migration_run_files
WHERE run_id = :'run_id'::uuid AND file_name LIKE '%.csv'
UNION ALL
SELECT :'run_id'::uuid, 'V272/V275 system roots',
       'system_master_category_registry', 'exact_authority_rows', 1, count(*),
       count(*) = 1,
       'The singleton registry must still bind all four protected legacy_id=-1 roots.'
FROM system_master_category_registry registry
JOIN material_categories material
  ON material.id = registry.material_category_id
 AND material.legacy_id = -1
 AND material.legacy_code_snapshot = 'LEGACY_ORPHAN'
 AND material.is_deleted = FALSE
JOIN client_categories client
  ON client.id = registry.client_category_id
 AND client.legacy_id = -1
 AND client.code = 'SYS_UNCATEGORIZED_CLIENT'
 AND client.is_deleted = FALSE
JOIN mould_categories mould
  ON mould.id = registry.mould_category_id
 AND mould.legacy_id = -1
 AND mould.code = 'SYS_UNCATEGORIZED_MOULD'
 AND mould.is_deleted = FALSE
JOIN supplier_categories supplier
  ON supplier.id = registry.supplier_category_id
 AND supplier.legacy_id = -1
 AND supplier.code = 'SYS_UNCATEGORIZED_SUPPLIER'
 AND supplier.is_deleted = FALSE
WHERE registry.id = '27500000-0000-4000-8000-000000000001'::uuid
UNION ALL
SELECT :'run_id'::uuid, 'B_Goods legacy references', 'goods UUID relations',
       'unresolved_current_uuid_relations', 0, count(*), count(*) = 0,
       'Every non-zero legacy master reference on an imported active good must match its UUID.'
FROM goods goods
WHERE goods.legacy_id IS NOT NULL
  AND goods.is_deleted = FALSE
  AND goods.auto_created = FALSE
  AND (
      (goods.unit_legacy_id IS NOT NULL AND goods.unit_legacy_id <> 0
       AND NOT EXISTS (SELECT 1 FROM units master
                       WHERE master.legacy_id = goods.unit_legacy_id
                         AND master.id = goods.unit_id))
   OR (goods.color_legacy_id IS NOT NULL AND goods.color_legacy_id <> 0
       AND NOT EXISTS (SELECT 1 FROM colors master
                       WHERE master.legacy_id = goods.color_legacy_id
                         AND master.id = goods.color_id))
   OR (goods.mould_legacy_id IS NOT NULL AND goods.mould_legacy_id <> 0
       AND NOT EXISTS (SELECT 1 FROM moulds master
                       WHERE master.legacy_id = goods.mould_legacy_id
                         AND master.id = goods.mould_id))
   OR (goods.client_legacy_id IS NOT NULL AND goods.client_legacy_id <> 0
       AND NOT EXISTS (SELECT 1 FROM clients master
                       WHERE master.legacy_id = goods.client_legacy_id
                         AND master.id = goods.client_id))
   OR (goods.vend_legacy_id IS NOT NULL AND goods.vend_legacy_id <> 0
       AND NOT EXISTS (SELECT 1 FROM suppliers master
                       WHERE master.legacy_id = goods.vend_legacy_id
                         AND master.id = goods.default_supplier_id))
   OR (goods.vend2_legacy_id IS NOT NULL AND goods.vend2_legacy_id <> 0
       AND NOT EXISTS (SELECT 1 FROM suppliers master
                       WHERE master.legacy_id = goods.vend2_legacy_id
                         AND master.id = goods.secondary_supplier_id))
  )
UNION ALL
SELECT :'run_id'::uuid, 'B_Client.PStyle', 'clients.default_settlement_method_id',
       'unresolved_default_settlement_methods', 0, count(*), count(*) = 0,
       'A non-null legacy default requires one exact active settlement UUID before cutover.'
FROM clients client
WHERE client.legacy_id IS NOT NULL
  AND client.is_deleted = FALSE
  AND client.price_style IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM settlement_methods method
      WHERE method.legacy_id = client.price_style
        AND method.id = client.default_settlement_method_id
        AND method.status = '使用'
        AND method.is_deleted = FALSE
  )
UNION ALL
SELECT :'run_id'::uuid, 'reviewed warehouse/workshop links',
       'warehouses.workshop_department_id', 'mismatched_explicit_links',
       0, count(*), count(*) = 0,
       'Only an explicit reviewed warehouse legacy-id mapping may establish the live workshop UUID.'
FROM legacy_warehouse_workshop_links link
LEFT JOIN warehouses warehouse
  ON warehouse.legacy_id = link.warehouse_legacy_id
 AND warehouse.workshop_department_id = link.workshop_department_id
 AND warehouse.is_deleted = FALSE
WHERE warehouse.id IS NULL
UNION ALL
SELECT :'run_id'::uuid, 'legacy BOM', 'goods_bom_items',
       'active_placeholder_or_deleted_goods_edges', 0, count(*), count(*) = 0,
       'Operational BOM edges may reference only active non-placeholder goods.'
FROM goods_bom_items item
JOIN goods parent_goods ON parent_goods.id = item.goods_id
JOIN goods component_goods ON component_goods.id = item.component_goods_id
WHERE item.is_deleted = FALSE
  AND (parent_goods.auto_created OR parent_goods.is_deleted
       OR component_goods.auto_created OR component_goods.is_deleted)
UNION ALL
SELECT :'run_id'::uuid, 'bootstrap rejects', 'legacy_migration_rejects',
       'unresolved_reject_rows', 0, count(*), count(*) = 0,
       'Any rejected source identity requires reviewed resolution before cutover.'
FROM legacy_migration_rejects
WHERE run_id = :'run_id'::uuid
UNION ALL
SELECT :'run_id'::uuid, 'historical orphan references', 'goods',
       'retained_fk_anchor_goods', NULL, count(*), TRUE,
       'Informational: retained auto-created goods are historical FK anchors and remain excluded from live BOM/MRP.'
FROM goods WHERE auto_created = TRUE;

COMMIT;
