-- Make the existing independent cost permission discoverable from both inventory hosts.
-- Association only: this migration grants no employee, role or template any permission.
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
CROSS JOIN permissions permission
WHERE surface.surface_key IN ('warehouse.instant-inventory', 'basic.warehouse')
  AND permission.code = 'goods:cost:view'
ON CONFLICT (surface_id, permission_id) DO NOTHING;
