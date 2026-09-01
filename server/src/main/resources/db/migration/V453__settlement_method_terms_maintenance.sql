-- V453: settlement-method payment-terms maintenance page permissions.
--
-- settlement_methods 的账期策略列（terms_base/due_rule/default_due_days/
-- fixed_day_of_month/months_ahead，V330/ADR-047）此前只能 DBA 改 SQL；
-- 在线新建的结算方式一律落到「收货日当天到期」，无法表达 月结60/月末+15天/固定日
-- 等账期。本迁移只登记专属页面权限与权限面，不给任何部门/个人授予权限；
-- 系统角色（CASH/MONTHLY）的口径仍由 V285/V330 锁定，不允许在线改写。

INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description,
     active, assignable)
VALUES
    ('settlement_method:view',
     '查看结算方式', '基础资料', '收付款类别', 117,
     'VIEW', '查看结算方式字典、系统角色与账期策略（采购/委外到期日规则）',
     TRUE, TRUE),
    ('settlement_method:edit',
     '维护结算方式账期', '基础资料', '收付款类别', 118,
     'EDIT', '维护结算方式名称与账期策略；系统角色(CASH/MONTHLY)口径锁定不可在线修改',
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

INSERT INTO permission_surfaces
    (id, surface_key, name, sort_order, enabled)
VALUES
    ('45300000-0000-4000-8000-000000000091',
     'basic.settlement-method', '结算方式', 91, TRUE)
ON CONFLICT (surface_key) DO NOTHING;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code IN (
      'settlement_method:view',
      'settlement_method:create',
      'settlement_method:edit')
WHERE surface.surface_key = 'basic.settlement-method'
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- 目录完整性守卫：任一登记码缺失即中止，不允许半套权限面上线。
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM permission_surfaces surface
        WHERE surface.surface_key = 'basic.settlement-method'
          AND NOT EXISTS (
              SELECT 1
              FROM permission_surface_permissions link
              WHERE link.surface_id = surface.id
          )
    ) THEN
        RAISE EXCEPTION
            'V453 surface basic.settlement-method registered without any permission link';
    END IF;
END;
$$;
