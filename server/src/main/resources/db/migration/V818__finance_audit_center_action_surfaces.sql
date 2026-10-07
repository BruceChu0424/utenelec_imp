-- V818: 业务审核中心内嵌队列没有自己的顶栏；中心及钱流父页须能配置真实审核动作。
-- 只补权限面目录，不新增权限码、不改 grant_policy、不写任何部门/个人/委派授权。
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT target.id, source_link.permission_id
FROM permission_surfaces target
CROSS JOIN permission_surfaces source
JOIN permission_surface_permissions source_link ON source_link.surface_id = source.id
WHERE target.surface_key = 'finance.audit-center'
  AND source.surface_key IN ('finance.order-approval', 'finance.sales-order-confirmation',
                            'finance.sales-shipment-audit')
ON CONFLICT(surface_id, permission_id) DO NOTHING;

-- IQC 分段在审核中心办理供应商贷项；实物退回仍属于仓库，不混入财务动作集合。
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission ON permission.code IN (
    'procurement_iqc_rejection:view:all', 'procurement_iqc_rejection:amount:view',
    'procurement_iqc_rejection:confirm_credit', 'procurement_iqc_rejection:close_no_credit',
    'procurement_iqc_rejection:reverse')
WHERE surface.surface_key = 'finance.audit-center'
ON CONFLICT(surface_id, permission_id) DO NOTHING;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM permission_surfaces source
        JOIN permission_surface_permissions link ON link.surface_id = source.id
        WHERE source.surface_key IN ('finance.order-approval', 'finance.sales-order-confirmation',
                                     'finance.sales-shipment-audit')
          AND NOT EXISTS (
              SELECT 1 FROM permission_surfaces target
              JOIN permission_surface_permissions covered ON covered.surface_id = target.id
              WHERE target.surface_key = 'finance.audit-center'
                AND covered.permission_id = link.permission_id)) THEN
        RAISE EXCEPTION '业务审核中心未完整覆盖内嵌审核队列权限';
    END IF;
END;
$$;
