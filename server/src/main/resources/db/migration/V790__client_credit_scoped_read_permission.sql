-- A narrow, individually granted credit summary does not grant company-wide finance access.
INSERT INTO permissions(code, name, module, category, sort_order, action_type, description,
                        grant_policy, high_risk, baseline, sensitivity)
VALUES ('client:credit:view', '查看客户信用汇总', '基础资料', '客户资料', 39, 'VIEW',
        '仅查看本人已有客户范围的应收、逾期与已登记收款汇总；不授予全公司财务、导出或修改权限',
        ARRAY['INDIVIDUAL_ONLY']::text[], TRUE, FALSE, 'SENSITIVE_COMMERCIAL');

INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id FROM permission_surfaces surface CROSS JOIN permissions permission
WHERE surface.surface_key = 'basic.client' AND permission.code = 'client:credit:view';
