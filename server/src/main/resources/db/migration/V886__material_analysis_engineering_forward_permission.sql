-- Material-analysis diagnostics report invalid master/BOM data independently of plan release.
-- The plan-era production_plan:forward_rd permission remains retired (V423/V455).
-- Register a new explicit action on the existing analysis surface, with no default grants.
INSERT INTO permissions(id,code,name,module,category,sort_order,action_type,description,grant_policy,baseline,high_risk)
VALUES ('88200000-0000-4000-8000-000000000001',
        'production_material_analysis:forward_rd','转工程核对物料资料','生产管理','物料分析',579,
        'EXECUTE','将当前物料分析校验发现的问题批量转工程任务；须同时具有物料分析查看权，不放宽正式分析和下达校验。',
        ARRAY['NORMAL']::text[],FALSE,FALSE)
ON CONFLICT(code) DO NOTHING;

INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT surface.id,permission.id
FROM permission_surfaces surface JOIN permissions permission
    ON permission.code='production_material_analysis:forward_rd'
WHERE surface.surface_key='production.material-analysis'
ON CONFLICT(surface_id,permission_id) DO NOTHING;
