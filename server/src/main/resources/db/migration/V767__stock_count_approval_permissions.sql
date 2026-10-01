-- V767: 盘点模式与审核均由超管逐人授权。录入只送审，审核才过账。
-- 旧周期盘点仅保留点名授予的草稿录入，提交过账转由仓库审核码；不把部门成员迁成个人授权。
DELETE FROM department_permissions granted USING permissions permission
WHERE granted.permission_id = permission.id AND permission.code = 'workshop_material:count';
DELETE FROM manager_permission_delegations granted USING permissions permission
WHERE granted.permission_id = permission.id AND permission.code = 'workshop_material:count';
UPDATE permissions SET grant_policy = ARRAY['INDIVIDUAL_ONLY']::text[], baseline = FALSE,
    description = '开始和录入车间周期盘点草稿、更正草稿；仅超管逐人授权，提交过账须仓库盘点审核权限'
WHERE code = 'workshop_material:count';
INSERT INTO permissions(code, name, module, category, sort_order, action_type, description, grant_policy, high_risk, baseline)
VALUES
    ('stock:count:submit', '录入盘点并提交审核', '仓库管理', '盘点审批', 327, 'CREATE',
     '在即时库存或车间内料仓录入目标数量与重量并提交审核；提交不修改库存',
     ARRAY['INDIVIDUAL_ONLY']::text[], FALSE, FALSE),
    ('stock:count:finance_review', '财务审核普通仓盘点', '财税管理', '盘点审批', 328, 'APPROVE',
     '审核普通仓盘点，批准后按申请目标数量与重量过账；不能审核车间内料仓盘点',
     ARRAY['INDIVIDUAL_ONLY']::text[], TRUE, FALSE),
    ('stock:count:warehouse_review', '仓库审核车间内料仓盘点', '仓库管理', '盘点审批', 329, 'APPROVE',
     '审核车间内料仓盘点，批准后按申请目标数量与重量过账；不能审核普通仓盘点',
     ARRAY['INDIVIDUAL_ONLY']::text[], TRUE, FALSE);

INSERT INTO permission_surfaces(id, surface_key, name, sort_order, enabled) VALUES
    ('76700000-0000-4000-8000-000000000001', 'warehouse.stock-count-review', '车间内料仓盘点审核', 283, TRUE),
    ('76700000-0000-4000-8000-000000000002', 'finance.stock-count-review', '普通仓盘点财务审核', 284, TRUE);

WITH mapping(surface_key, permission_code) AS (VALUES
    ('warehouse.stock-balance', 'stock:count:submit'),
    ('warehouse.stock-item', 'stock:count:submit'),
    ('production.workshop-material', 'stock:count:submit'),
    ('warehouse.workshop-material', 'stock:count:submit'),
    ('warehouse.stock-count-review', 'stock:count:warehouse_review'),
    ('warehouse.workshop-material', 'stock:count:warehouse_review'),
    ('finance.stock-count-review', 'stock:count:finance_review'))
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id FROM mapping
JOIN permission_surfaces surface ON surface.surface_key = mapping.surface_key
JOIN permissions permission ON permission.code = mapping.permission_code;

DO $$
BEGIN
    IF (SELECT count(*) FROM permissions WHERE code IN (
            'stock:count:submit', 'stock:count:finance_review', 'stock:count:warehouse_review')
        AND grant_policy = ARRAY['INDIVIDUAL_ONLY']::text[] AND NOT baseline) <> 3 THEN
        RAISE EXCEPTION 'Stock count approval permissions must be individual-only and excluded from the baseline';
    END IF;
    IF EXISTS (SELECT 1 FROM department_permissions granted JOIN permissions permission ON permission.id = granted.permission_id
               WHERE permission.code IN ('stock:count:submit', 'stock:count:finance_review', 'stock:count:warehouse_review')) THEN
        RAISE EXCEPTION 'Stock count approval permissions must not be granted to departments';
    END IF;
END;
$$;
