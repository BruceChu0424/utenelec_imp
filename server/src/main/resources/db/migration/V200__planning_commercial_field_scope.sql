-- V200: planning demand screens must not inherit supplier or subcontract commercial data.
--
-- V44/V53/V38 granted read permissions to every department, including the DEPT_PMC parent.
-- Because current authorization resolves ancestor grants, removing only SUB_PLAN direct rows is
-- insufficient. Purchasing, warehouse and subcontract departments keep their own direct grants.

DELETE FROM department_permissions dp
USING permissions p, departments d
WHERE p.id = dp.permission_id
  AND d.id = dp.department_id
  AND d.code = 'DEPT_PMC'
  AND p.code IN (
      'subcontract_inquiry:view', 'subcontract_application:view',
      'subcontract_order:view', 'subcontract_receipt:view',
      'subcontract_material_issue:view', 'subcontract_return:view',
      'subcontract_material_return:view', 'subcontract_waste:view',
      'subcontract_report:view',
      'supplier:view', 'supplier_category:view'
  );

DELETE FROM department_permissions dp
USING permissions p, departments d
WHERE p.id = dp.permission_id
  AND d.id = dp.department_id
  AND d.code = 'SUB_PLAN'
  AND p.code IN (
      'subcontract_inquiry:view', 'subcontract_application:view',
      'subcontract_order:view', 'subcontract_receipt:view',
      'subcontract_material_issue:view', 'subcontract_return:view',
      'subcontract_material_return:view', 'subcontract_waste:view',
      'subcontract_report:view',
      'supplier:view', 'supplier_category:view'
  );

