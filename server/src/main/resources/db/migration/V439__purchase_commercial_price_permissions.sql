-- V439: split purchase commercial visibility by the page that exposes it.
--
-- Security boundary: this migration registers catalog metadata and exact page
-- associations only. It does not copy purchase_receipt:price:view and writes no
-- department, role, user, or manager grant. Permission administrators must
-- explicitly authorize the new codes after real-account/UAT review.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM permissions permission
        WHERE permission.code IN (
            'purchase_order:price:view',
            'purchase_return:price:view',
            'purchase_report:price:view')
          AND (
              EXISTS (SELECT 1 FROM department_permissions source
                      WHERE source.permission_id = permission.id)
              OR EXISTS (SELECT 1 FROM role_permissions source
                         WHERE source.permission_id = permission.id)
              OR EXISTS (SELECT 1 FROM user_permission_overrides source
                         WHERE source.permission_id = permission.id)
              OR EXISTS (SELECT 1 FROM manager_permission_delegations source
                         WHERE source.permission_id = permission.id)
          )
    ) THEN
        RAISE EXCEPTION
            'V439 refuses to activate pre-existing purchase price grants';
    END IF;
END;
$$;

INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description,
     active, assignable)
VALUES
    ('purchase_order:price:view',
     '查看采购订货价格', '采购管理', '采购订货', 117,
     'VIEW', '查看采购订货的结算方式、单价、税率和金额',
     TRUE, TRUE),
    ('purchase_return:price:view',
     '查看采购退货价格', '采购管理', '采购退货', 136,
     'VIEW', '查看采购退货的结算、单价和反向应付金额',
     TRUE, TRUE),
    ('purchase_report:price:view',
     '查看采购报表商业金额', '采购管理', '采购报表', 142,
     'VIEW', '在采购明细、汇总和催料报表中查看单价与金额',
     TRUE, TRUE)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order,
    action_type = EXCLUDED.action_type,
    description = EXCLUDED.description,
    active = TRUE,
    assignable = TRUE;

WITH mapping(surface_key, permission_code) AS (VALUES
    ('purchase.order', 'purchase_order:price:view'),
    ('purchase.return', 'purchase_return:price:view'),
    ('purchase.report', 'purchase_report:price:view')
)
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM mapping
JOIN permission_surfaces surface ON surface.surface_key = mapping.surface_key
JOIN permissions permission ON permission.code = mapping.permission_code
ON CONFLICT (surface_id, permission_id) DO NOTHING;

DO $$
DECLARE
    missing TEXT;
    unexpected_grants BIGINT;
BEGIN
    SELECT string_agg(required.code, ', ' ORDER BY required.code)
    INTO missing
    FROM (VALUES
        ('purchase_order:price:view'),
        ('purchase_receipt:price:view'),
        ('purchase_return:price:view'),
        ('purchase_report:price:view')
    ) AS required(code)
    LEFT JOIN permissions permission
      ON permission.code = required.code
     AND permission.active = TRUE
     AND permission.assignable = TRUE
    WHERE permission.id IS NULL;

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'V439 missing active purchase price permissions: %',
            missing;
    END IF;

    SELECT count(*)
    INTO unexpected_grants
    FROM (
        SELECT permission_id FROM department_permissions
        UNION ALL SELECT permission_id FROM role_permissions
        UNION ALL SELECT permission_id FROM user_permission_overrides
        UNION ALL SELECT permission_id FROM manager_permission_delegations
    ) source
    JOIN permissions permission ON permission.id = source.permission_id
    WHERE permission.code IN (
        'purchase_order:price:view',
        'purchase_return:price:view',
        'purchase_report:price:view');

    IF unexpected_grants <> 0 THEN
        RAISE EXCEPTION 'V439 purchase price permissions must start with zero grants';
    END IF;

    IF (
        SELECT count(*)
        FROM permission_surface_permissions link
        JOIN permission_surfaces surface ON surface.id = link.surface_id
        JOIN permissions permission ON permission.id = link.permission_id
        WHERE (surface.surface_key, permission.code) IN (
            ('purchase.order', 'purchase_order:price:view'),
            ('purchase.return', 'purchase_return:price:view'),
            ('purchase.report', 'purchase_report:price:view'))
    ) <> 3 THEN
        RAISE EXCEPTION 'V439 purchase price page associations are incomplete';
    END IF;
END;
$$;
