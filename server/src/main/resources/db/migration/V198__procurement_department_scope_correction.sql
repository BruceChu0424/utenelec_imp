-- V198: separate planning, purchasing and warehouse capabilities after the V196 workflow.
--
-- Department permissions are resolved from the employee's department plus every ancestor.
-- The historical DEPT_PMC parent grants would therefore keep leaking commercial purchase
-- fields and write actions to SUB_PLAN even after removing SUB_PLAN's direct grant.

DELETE FROM department_permissions dp
USING permissions p, departments d
WHERE p.id = dp.permission_id
  AND d.id = dp.department_id
  AND d.code = 'DEPT_PMC'
  AND p.code IN (
      'purchase_request:view', 'purchase_request:edit',
      'purchase_order:view', 'purchase_order:edit',
      'purchase_receipt:view', 'purchase_receipt:edit',
      'purchase_return:view', 'purchase_return:edit',
      'purchase_report:view',
      'purchase_order:submit_finance', 'warehouse_inbound:view'
  );

-- Purchasing receives planning demand read-only and owns order/commercial handling.
INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'purchase_request:view',
    'purchase_order:view', 'purchase_order:edit', 'purchase_order:submit_finance',
    'purchase_receipt:view',
    'purchase_return:view', 'purchase_return:edit',
    'purchase_report:view'
)
WHERE d.code = 'SUB_PURCHASE' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- Warehouse owns physical receipt entry. It does not gain supplier/order editing authority.
INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'warehouse_inbound:view',
    'purchase_receipt:view', 'purchase_receipt:edit',
    'purchase_return:view'
)
WHERE d.code = 'SUB_WH' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- Planning sees only the demand projection. Full request/order endpoints expose legacy
-- commercial fields and therefore stay unavailable to SUB_PLAN.
DELETE FROM department_permissions dp
USING permissions p, departments d
WHERE p.id = dp.permission_id
  AND d.id = dp.department_id
  AND d.code = 'SUB_PLAN'
  AND p.code IN (
      'purchase_request:view', 'purchase_request:edit',
      'purchase_order:view', 'purchase_order:edit', 'purchase_order:submit_finance',
      'purchase_receipt:view', 'purchase_receipt:edit',
      'purchase_return:view', 'purchase_return:edit', 'purchase_report:view',
      'subcontract_application:view', 'subcontract_application:edit',
      'subcontract_order:view', 'subcontract_order:edit',
      'subcontract_receipt:view', 'subcontract_receipt:edit',
      'subcontract_return:view', 'subcontract_return:edit',
      'subcontract_report:view'
  );

