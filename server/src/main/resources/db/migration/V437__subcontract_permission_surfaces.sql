-- V437: exact subcontract page permissions and permission-setting surfaces.
--
-- Security boundary: this migration deliberately grants none of the new
-- permissions to departments, roles or users. Permission administrators must
-- explicitly grant them after role/UAT review. This avoids silently expanding
-- the historical subcontract_receipt:price:view grant to other commercial
-- pages. Retired composites remain inactive and are never restored here.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM permissions permission
        WHERE permission.code IN (
            'subcontract_preparation:view',
            'subcontract_preparation:start',
            'subcontract_inquiry:price:view',
            'subcontract_order:price:view',
            'subcontract_return:price:view',
            'subcontract_waste:suggestion:view',
            'subcontract_report:price:view')
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
            'V437 refuses to activate pre-existing subcontract permission grants';
    END IF;
END;
$$;

INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description,
     active, assignable)
VALUES
    ('subcontract_preparation:view',
     '查看委外前置自制任务', '委外管理', '委外前置自制', 327,
     'VIEW', '查看需先完成内部自制、质检和仓库实收的委外目标件',
     TRUE, TRUE),
    ('subcontract_preparation:start',
     '启动委外前置自制', '委外管理', '委外前置自制', 328,
     'EXECUTE', '为委外目标件启动可追溯物料分析与正常自制链',
     TRUE, TRUE),
    ('subcontract_inquiry:price:view',
     '查看委外询价价格', '委外管理', '委外询价', 306,
     'VIEW', '查看委外询价的币种、单价和金额', TRUE, TRUE),
    ('subcontract_order:price:view',
     '查看委外订货价格', '委外管理', '委外订货', 329,
     'VIEW', '查看委外订货的结算方式、单价、税率和金额', TRUE, TRUE),
    ('subcontract_return:price:view',
     '查看委外成品退货价格', '委外管理', '委外退货', 356,
     'VIEW', '查看委外成品退货的结算、单价和反向应付金额', TRUE, TRUE),
    ('subcontract_waste:suggestion:view',
     '查看委外损耗建议索赔金额', '委外管理', '委外材料损耗', 376,
     'VIEW', '查看损耗页中仅供财务责任判定参考的建议索赔金额', TRUE, TRUE),
    ('subcontract_report:price:view',
     '查看委外报表商业金额', '委外管理', '委外报表', 382,
     'VIEW', '在委外明细、汇总和出入状况报表中查看单价与金额', TRUE, TRUE)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order,
    action_type = EXCLUDED.action_type,
    description = EXCLUDED.description,
    active = TRUE,
    assignable = TRUE;

INSERT INTO permission_surfaces
    (id, surface_key, name, sort_order, enabled)
VALUES
    ('43700000-0000-4000-8000-000000000001',
     'subcontract.preparation', '委外前置自制', 53, TRUE)
ON CONFLICT (surface_key) DO UPDATE
SET name = EXCLUDED.name,
    sort_order = EXCLUDED.sort_order,
    enabled = TRUE;

WITH mapping(surface_key, permission_code) AS (VALUES
    ('subcontract.preparation', 'subcontract_preparation:view'),
    ('subcontract.preparation', 'subcontract_preparation:start'),
    ('subcontract.inquiry', 'subcontract_inquiry:price:view'),
    ('subcontract.order', 'subcontract_order:price:view'),
    ('subcontract.return', 'subcontract_return:price:view'),
    ('subcontract.waste', 'subcontract_waste:suggestion:view'),
    ('subcontract.report', 'subcontract_report:price:view'),
    -- The warehouse page edits/approves the system-generated issue document.
    -- Exact associations make every required action visible and revocable from
    -- this page's settings surface; blank material-issue create is excluded.
    ('warehouse.subcontract-outbound', 'subcontract_material_issue:view'),
    ('warehouse.subcontract-outbound', 'subcontract_material_issue:edit'),
    ('warehouse.subcontract-outbound', 'subcontract_material_issue:delete'),
    ('warehouse.subcontract-outbound', 'subcontract_material_issue:approve'),
    ('warehouse.subcontract-outbound', 'subcontract_material_issue:reverse')
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
BEGIN
    SELECT string_agg(required.code, ', ' ORDER BY required.code)
    INTO missing
    FROM (VALUES
        ('subcontract_preparation:view'),
        ('subcontract_preparation:start'),
        ('subcontract_inquiry:price:view'),
        ('subcontract_order:price:view'),
        ('subcontract_receipt:price:view'),
        ('subcontract_return:price:view'),
        ('subcontract_waste:suggestion:view'),
        ('subcontract_report:price:view'),
        ('subcontract_outbound:view'),
        ('subcontract_outbound:execute'),
        ('subcontract_outbound:close')
    ) AS required(code)
    LEFT JOIN permissions permission
      ON permission.code = required.code AND permission.active = TRUE
    WHERE permission.id IS NULL;

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'V437 missing active subcontract permissions: %', missing;
    END IF;

    IF EXISTS (
        SELECT 1 FROM permissions
        WHERE code IN (
            'subcontract_outbound:handle',
            'finance_order_approval:review',
            'subcontract_application:edit'
        )
          AND (active = TRUE OR assignable = TRUE)
    ) THEN
        RAISE EXCEPTION 'V437 retired composite permission was reactivated';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM permission_surfaces surface
        JOIN permission_surface_permissions link ON link.surface_id = surface.id
        JOIN permissions permission ON permission.id = link.permission_id
        WHERE surface.surface_key = 'subcontract.preparation'
        GROUP BY surface.id
        HAVING array_agg(permission.code ORDER BY permission.code) = ARRAY[
            'subcontract_preparation:start',
            'subcontract_preparation:view'
        ]::TEXT[]
    ) THEN
        RAISE EXCEPTION 'V437 subcontract preparation surface is incomplete';
    END IF;
END;
$$;
