-- V819: 资产/待摊草稿删除独立于编辑。只建立目录与页面映射，默认零授权。
-- 继承资产编辑的授权边界：仅超管显式配置，不允许负责人转授或批量默授。
INSERT INTO permissions(code, name, module, category, sort_order, action_type,
                        description, grant_policy, high_risk, baseline)
SELECT 'finance_asset:delete', '删除资产与待摊草稿', module, category, sort_order + 1,
       'DELETE', '仅删除固定资产或长期待摊草稿；编辑、新建和审核权限均不包含删除',
       ARRAY['NON_DELEGABLE', 'BULK_EXCLUDED']::text[], TRUE, FALSE
FROM permissions WHERE code = 'finance_asset:edit';

INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission ON permission.code = 'finance_asset:delete'
WHERE surface.surface_key = 'finance.asset';

DO $$
BEGIN
    IF (SELECT count(*) FROM permissions WHERE code = 'finance_asset:delete'
        AND action_type = 'DELETE' AND NOT baseline) <> 1 THEN
        RAISE EXCEPTION '资产草稿独立删除权限未正确登记';
    END IF;
END;
$$;
