-- =====================================================================
-- V677：权限目录单一事实源(ADR-109)
-- =====================================================================
-- 背景(2026-09-23 全平台整改 permissions-01/02/03/05/06/07/09/11/12/14)：
--   「一个码能怎么授」此前写了 5 份：permissions.assignable / bulk_assignable、
--   后端 INDIVIDUAL_ONLY 常量、PermissionDelegationPolicy 硬编码名单、前端
--   authorize_all_excluded、前端超管兜底清单；再加两条只认个别码的数据库守卫。
--   几份互相矛盾：supplier_return_task 两个码既「仅允许点名授权」又「不可分配」，
--   结果谁都办不了；财务部 / 总经办 / 人事部持有「不可分配」码，部门矩阵保存必失败。
--   角色体系名义下线，实际仍给全员基础包、通知受众和入职接口供数。
--
-- 本迁移一次收口：
--   1) permissions.grant_policy text[]：授权策略唯一事实源，取值
--      NORMAL / BULK_EXCLUDED / INDIVIDUAL_ONLY / NON_DELEGABLE / SUPERADMIN_ONLY，
--      NORMAL 只能单独出现；服务端三种授权入口与数据库守卫都只读这一列。
--   2) permissions.baseline：全员基础包(原 roles.code='employee' 的权限包)，管理页可编辑。
--   3) 停用即删除：16 个停用码、只在前端生效或没有任何入口的码(批量审核/删除计划、
--      对账查看、打印花名册、资产导出、访客申请/查看)连同授权行、页面权限面映射一起删除；删除后
--      active / assignable / bulk_assignable 三列一并删除，目录里不再有「软停用」码。
--   4) 动作拆分与命名统一：finance_shipment_audit 拆成 sales_shipment_finance:view/
--      approve/reject/reverse；sales_shipment:warehouse-work 拆成
--      warehouse_sales_outbound:view/execute；连字符/驼峰/view_all 统一成
--      resource:action[:qualifier] 小写下划线，并加 CHECK。
--   5) 三条卡死链路给默认岗位(退回供应商任务、IQC 不合格闭环、官网询盘)，
--      并补结算方式查看/维护、模具分类维护、订货改量与提交财务同口径。
--   6) 页面权限面只允许指向「至少有一种人能在页面上授」的码(非 SUPERADMIN_ONLY)，
--      补挂 goods:price:view / purchase_order:cancel / production_execution:dispatch。
--   7) 删除 roles / user_roles / role_permissions / department_roles 四张表。
--   8) 新增超管专属码 system:business_data_reset(清空业务数据，管理页可见、可审计)。
--   9) 两条只认个别码的部门授权守卫换成一个按 grant_policy 判定的通用守卫，
--      同时守住个人加授、负责人委派与页面权限面。
-- 平台未上线：不留别名、不做存量兼容；授权行按原持有者平移到新码。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. 前置断言：全员基础包的来源角色必须存在(否则基础包无从平移)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM roles WHERE code = 'employee') THEN
        RAISE EXCEPTION 'V677 requires the legacy employee role to seed permissions.baseline';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- 1. 新列：授权策略 + 全员基础包
-- ---------------------------------------------------------------------
ALTER TABLE permissions
    ADD COLUMN grant_policy TEXT[] NOT NULL DEFAULT ARRAY['NORMAL']::TEXT[],
    ADD COLUMN baseline BOOLEAN NOT NULL DEFAULT FALSE;

-- ---------------------------------------------------------------------
-- 2. 命名统一(原地改码，授权行按 permission_id 自动跟随)
-- ---------------------------------------------------------------------
UPDATE permissions SET code = 'visitor:check_in' WHERE code = 'visitor:check-in';
UPDATE permissions SET code = 'visitor:host_confirm' WHERE code = 'visitor:host-confirm';
UPDATE permissions SET code = 'dashboard:finance_sensitive:view'
WHERE code = 'dashboard:finance-sensitive:view';
UPDATE permissions SET code = 'procurement_iqc_rejection:view:all'
WHERE code = 'procurement_iqc_rejection:view_all';

-- ---------------------------------------------------------------------
-- 3. 动作拆分：出货财审 / 仓库销售出库(原码改名为 view，新增动作码并平移授权)
-- ---------------------------------------------------------------------
UPDATE permissions
SET code = 'sales_shipment_finance:view',
    name = '查看出货财务审核',
    module = '财税管理',
    category = '发运审核',
    action_type = 'VIEW',
    sort_order = 574,
    description = '查看待财务放行的客户出货单、放行核对信息与出货财审待办'
WHERE code = 'finance_shipment_audit';

UPDATE permissions
SET code = 'warehouse_sales_outbound:view',
    name = '查看仓库销售出库任务',
    module = '仓库管理',
    category = '销售出库',
    action_type = 'VIEW',
    sort_order = 223,
    description = '查看财务已放行、等待仓库出库的销售出货任务与出库历史'
WHERE code = 'sales_shipment:warehouse-work';

INSERT INTO permissions (code, name, module, category, sort_order, action_type, description)
VALUES
    ('sales_shipment_finance:approve', '出货财务放行', '财税管理', '发运审核', 575, 'APPROVE',
     '财务放行客户出货单(含批量放行)；放行后仓库才收到出库任务'),
    ('sales_shipment_finance:reject', '出货财务退回', '财税管理', '发运审核', 576, 'APPROVE',
     '财务退回客户出货单(含批量退回)，必须填写退回原因'),
    ('sales_shipment_finance:reverse', '出货财务反审', '财税管理', '发运审核', 577, 'EXECUTE',
     '仓库开始拣货前撤回财务放行，或撤回财务退回'),
    ('warehouse_sales_outbound:execute', '执行仓库销售出库', '仓库管理', '销售出库', 224, 'EXECUTE',
     '推进销售出货拣货状态并确认出库'),
    ('system:business_data_reset', '清空业务数据', '系统管理', '系统测试', 900, 'EXECUTE',
     '系统测试工具：清空业务单据与库存金额(保留主档、人事与权限)；仅超级管理员且须输入本人密码确认');

WITH split(source_code, target_code) AS (VALUES
    ('sales_shipment_finance:view', 'sales_shipment_finance:approve'),
    ('sales_shipment_finance:view', 'sales_shipment_finance:reject'),
    ('sales_shipment_finance:view', 'sales_shipment_finance:reverse'),
    ('warehouse_sales_outbound:view', 'warehouse_sales_outbound:execute')
)
INSERT INTO department_permissions (department_id, permission_id, created_by)
SELECT grant_row.department_id, target.id, grant_row.created_by
FROM split
JOIN permissions source ON source.code = split.source_code
JOIN permissions target ON target.code = split.target_code
JOIN department_permissions grant_row ON grant_row.permission_id = source.id
ON CONFLICT DO NOTHING;

WITH split(source_code, target_code) AS (VALUES
    ('sales_shipment_finance:view', 'sales_shipment_finance:approve'),
    ('sales_shipment_finance:view', 'sales_shipment_finance:reject'),
    ('sales_shipment_finance:view', 'sales_shipment_finance:reverse'),
    ('warehouse_sales_outbound:view', 'warehouse_sales_outbound:execute')
)
INSERT INTO user_permission_overrides
    (user_id, permission_id, effect, authority_source, source_actor_user_id, row_version, active)
SELECT override_row.user_id, target.id, override_row.effect, override_row.authority_source,
       override_row.source_actor_user_id, 1, override_row.active
FROM split
JOIN permissions source ON source.code = split.source_code
JOIN permissions target ON target.code = split.target_code
JOIN user_permission_overrides override_row ON override_row.permission_id = source.id
ON CONFLICT DO NOTHING;

WITH split(source_code, target_code) AS (VALUES
    ('sales_shipment_finance:view', 'sales_shipment_finance:approve'),
    ('sales_shipment_finance:view', 'sales_shipment_finance:reject'),
    ('sales_shipment_finance:view', 'sales_shipment_finance:reverse'),
    ('warehouse_sales_outbound:view', 'warehouse_sales_outbound:execute')
)
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT mapping.surface_id, target.id
FROM split
JOIN permissions source ON source.code = split.source_code
JOIN permissions target ON target.code = split.target_code
JOIN permission_surface_permissions mapping ON mapping.permission_id = source.id
ON CONFLICT DO NOTHING;

-- 负责人页面委派同样按原持有者平移：委派过原财审/出库码的员工拿到对应的全部动作码，
-- 委派人、范围、代际快照照抄(新码是普通码，可以委派)，不会在迁移后悄悄丢掉放行/出库能力。
WITH split(source_code, target_code) AS (VALUES
    ('sales_shipment_finance:view', 'sales_shipment_finance:approve'),
    ('sales_shipment_finance:view', 'sales_shipment_finance:reject'),
    ('sales_shipment_finance:view', 'sales_shipment_finance:reverse'),
    ('warehouse_sales_outbound:view', 'warehouse_sales_outbound:execute')
)
INSERT INTO manager_permission_delegations
    (user_id, permission_id, department_id, enabled, surface_key, granted_by_user_id, row_version,
     created_by, updated_by, target_user_generation, target_employee_generation,
     target_department_generation, grantor_user_generation, grantor_employee_generation,
     grantor_auth_version, grantor_authorization_epoch, scope_source, scope_department_id,
     scope_generation, scope_assignment_id, scope_assignment_version)
SELECT delegation.user_id, target.id, delegation.department_id, delegation.enabled,
       delegation.surface_key, delegation.granted_by_user_id, 1,
       delegation.created_by, delegation.updated_by, delegation.target_user_generation,
       delegation.target_employee_generation, delegation.target_department_generation,
       delegation.grantor_user_generation, delegation.grantor_employee_generation,
       delegation.grantor_auth_version, delegation.grantor_authorization_epoch,
       delegation.scope_source, delegation.scope_department_id, delegation.scope_generation,
       delegation.scope_assignment_id, delegation.scope_assignment_version
FROM split
JOIN permissions source ON source.code = split.source_code
JOIN permissions target ON target.code = split.target_code
JOIN manager_permission_delegations delegation ON delegation.permission_id = source.id
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- 4. 停用即删除 + 只在前端生效的码删除
--    (页面权限面外键是 RESTRICT，先删映射；其余授权行随外键级联删除)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE v655_retired_codes ON COMMIT DROP AS
SELECT id, code FROM permissions
WHERE NOT active
   OR code IN (
       'production_plan:batchApprove',
       'production_plan:batchDelete',
       'finance_reconciliation:view',
       'employee:export',
       'finance_asset:export',
       'visitor:apply',
       'visitor:view');

DELETE FROM permission_surface_permissions mapping
USING v655_retired_codes retired
WHERE mapping.permission_id = retired.id;

DELETE FROM permissions permission
USING v655_retired_codes retired
WHERE permission.id = retired.id;

-- ---------------------------------------------------------------------
-- 5. 链路可达：给没人持有的执行/审批码定默认岗位(permissions-01)
-- ---------------------------------------------------------------------
WITH defaults(department_code, permission_code) AS (VALUES
    -- 超量到货退回供应商任务：采购与综合营销事业部(原 handle 码的持有部门)
    ('SUB_PURCHASE', 'supplier_return_task:view'),
    ('SUB_PURCHASE', 'supplier_return_task:complete'),
    ('DEPT_SALES', 'supplier_return_task:view'),
    ('DEPT_SALES', 'supplier_return_task:complete'),
    -- IQC 不合格闭环：仓储部登记实物退回；财务部确认贷项 / 无贷项关闭 / 红冲 / 看金额
    ('SUB_WH', 'procurement_iqc_rejection:record_return'),
    ('DEPT_FIN', 'procurement_iqc_rejection:view'),
    ('DEPT_FIN', 'procurement_iqc_rejection:confirm_credit'),
    ('DEPT_FIN', 'procurement_iqc_rejection:close_no_credit'),
    ('DEPT_FIN', 'procurement_iqc_rejection:reverse'),
    ('DEPT_FIN', 'procurement_iqc_rejection:amount:view'),
    -- 官网询盘：综合营销事业部
    ('DEPT_SALES', 'webinquiry:view'),
    ('DEPT_SALES', 'webinquiry:claim'),
    ('DEPT_SALES', 'webinquiry:close'),
    ('DEPT_SALES', 'webinquiry:convert_client'),
    -- 结算方式：财务部原来只有新增、进不去页面
    ('DEPT_FIN', 'settlement_method:view'),
    ('DEPT_FIN', 'settlement_method:edit'),
    -- 模具分类维护：工程研发部(已持有模具与模具分类查看)
    ('DEPT_ENG', 'mould_category:create'),
    ('DEPT_ENG', 'mould_category:edit'),
    ('DEPT_ENG', 'mould_category:delete'),
    ('DEPT_ENG', 'mould_category:move'),
    ('DEPT_ENG', 'mould_category:reorder')
)
INSERT INTO department_permissions (department_id, permission_id)
SELECT department.id, permission.id
FROM defaults
JOIN departments department ON department.code = defaults.department_code AND NOT department.is_deleted
JOIN permissions permission ON permission.code = defaults.permission_code
ON CONFLICT DO NOTHING;

-- 批准后改量与提交财务同口径：能提交财务的部门就能在批准后改量。
WITH pairs(submit_code, change_code) AS (VALUES
    ('purchase_order:submit_finance', 'purchase_order:change_qty'),
    ('subcontract_order:submit_finance', 'subcontract_order:change_qty')
)
INSERT INTO department_permissions (department_id, permission_id)
SELECT grant_row.department_id, change_permission.id
FROM pairs
JOIN permissions submit_permission ON submit_permission.code = pairs.submit_code
JOIN permissions change_permission ON change_permission.code = pairs.change_code
JOIN department_permissions grant_row ON grant_row.permission_id = submit_permission.id
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- 6. 授权策略：把原先 5 份名单合并进 grant_policy
-- ---------------------------------------------------------------------
CREATE TEMP TABLE v655_policy (code TEXT PRIMARY KEY, policy TEXT[] NOT NULL) ON COMMIT DROP;
INSERT INTO v655_policy (code, policy) VALUES
    -- 超管专属：任何授权入口都不能授出，只随超级管理员身份生效
    ('authorization:manage', ARRAY['SUPERADMIN_ONLY']),
    ('attachment:reconcile:view', ARRAY['SUPERADMIN_ONLY']),
    ('attachment:reconcile:approve_delete', ARRAY['SUPERADMIN_ONLY']),
    ('system:business_data_reset', ARRAY['SUPERADMIN_ONLY']),
    -- 个人专属：只能由超级管理员逐人授予，不进部门矩阵、不可委派、不随批量
    ('audit_log:view', ARRAY['INDIVIDUAL_ONLY']),
    ('audit_log:export', ARRAY['INDIVIDUAL_ONLY']),
    ('account:balance:adjust', ARRAY['INDIVIDUAL_ONLY']),
    ('stock:balance:adjust', ARRAY['INDIVIDUAL_ONLY']),
    ('finance_asset:approve', ARRAY['INDIVIDUAL_ONLY']),
    ('finance_asset:post', ARRAY['INDIVIDUAL_ONLY']),
    ('finance_asset:dispose', ARRAY['INDIVIDUAL_ONLY']),
    ('finance_asset_period:manage', ARRAY['INDIVIDUAL_ONLY']),
    ('sales_order:priority', ARRAY['INDIVIDUAL_ONLY']),
    ('sales_order:reallocate', ARRAY['INDIVIDUAL_ONLY']),
    -- 不可由负责人转授(超管可按部门 / 个人显式授予)
    ('account:support', ARRAY['NON_DELEGABLE', 'BULK_EXCLUDED']),
    ('payroll:export', ARRAY['NON_DELEGABLE']),
    ('production_material_analysis:view', ARRAY['NON_DELEGABLE']),
    ('production_material_analysis:cross_reallocate', ARRAY['NON_DELEGABLE', 'BULK_EXCLUDED']),
    ('supplier_return_task:view', ARRAY['NON_DELEGABLE', 'BULK_EXCLUDED']),
    ('supplier_return_task:complete', ARRAY['NON_DELEGABLE', 'BULK_EXCLUDED']),
    ('dashboard:finance_sensitive:view', ARRAY['NON_DELEGABLE', 'BULK_EXCLUDED']),
    ('finance_asset:edit', ARRAY['NON_DELEGABLE', 'BULK_EXCLUDED']),
    ('server_status:view', ARRAY['NON_DELEGABLE']),
    ('server_status:alert:receive', ARRAY['NON_DELEGABLE']),
    -- 敏感商务信息：不随「全部授权」发放
    ('goods:price:view', ARRAY['BULK_EXCLUDED']);

UPDATE permissions permission
SET grant_policy = merged.policy
FROM (
    SELECT permission.id,
           ARRAY(
               SELECT DISTINCT flag
               FROM unnest(
                   COALESCE(explicit.policy, ARRAY[]::TEXT[])
                   || CASE WHEN permission.code LIKE '%:view:all'
                           THEN ARRAY['BULK_EXCLUDED', 'NON_DELEGABLE'] ELSE ARRAY[]::TEXT[] END
                   || CASE WHEN NOT permission.bulk_assignable
                           THEN ARRAY['BULK_EXCLUDED'] ELSE ARRAY[]::TEXT[] END
               ) AS flag
               ORDER BY flag
           ) AS flags
    FROM permissions permission
    LEFT JOIN v655_policy explicit ON explicit.code = permission.code
) calculated
CROSS JOIN LATERAL (
    SELECT CASE WHEN cardinality(calculated.flags) = 0
                THEN ARRAY['NORMAL']::TEXT[]
                ELSE calculated.flags END AS policy
) merged
WHERE permission.id = calculated.id;

-- 个人专属 / 超管专属的码不得再挂在部门矩阵上(历史守卫已保证审计与余额调整为空，
-- 其余新归类码逐一核对后同样为零；失败关闭，不静默删除任何部门授权)。
DO $$
DECLARE conflicting TEXT;
BEGIN
    SELECT string_agg(department.code || ':' || permission.code, ', ' ORDER BY department.code, permission.code)
    INTO conflicting
    FROM department_permissions grant_row
    JOIN permissions permission ON permission.id = grant_row.permission_id
    JOIN departments department ON department.id = grant_row.department_id
    WHERE permission.grant_policy && ARRAY['INDIVIDUAL_ONLY', 'SUPERADMIN_ONLY']::TEXT[];
    IF conflicting IS NOT NULL THEN
        RAISE EXCEPTION 'V677 department matrix still holds individual-only/super-admin-only codes: %', conflicting;
    END IF;
END;
$$;

-- 超管专属码的个人加授没有意义(超管本来就全量)：清掉，避免目录里留下永远不能再授的行。
DELETE FROM user_permission_overrides override_row
USING permissions permission
WHERE permission.id = override_row.permission_id
  AND 'SUPERADMIN_ONLY' = ANY(permission.grant_policy)
  AND override_row.effect = 'grant';

-- ---------------------------------------------------------------------
-- 7. 全员基础包：原 employee 角色权限包平移到 permissions.baseline
-- ---------------------------------------------------------------------
UPDATE permissions permission
SET baseline = TRUE
FROM role_permissions allocation
JOIN roles role ON role.id = allocation.role_id AND role.code = 'employee'
WHERE allocation.permission_id = permission.id;

-- ---------------------------------------------------------------------
-- 8. 页面权限面：超管专属码不挂任何页面；补挂可委派却无处可授的码
-- ---------------------------------------------------------------------
DELETE FROM permission_surface_permissions mapping
USING permissions permission
WHERE permission.id = mapping.permission_id
  AND 'SUPERADMIN_ONLY' = ANY(permission.grant_policy);

-- 只挂了超管专属码的页面权限面(系统设置页只有授权管理码)摘完后没有可授的码，
-- 一并停用：停用面不装载、不出现页面内授权入口。
UPDATE permission_surfaces surface
SET enabled = FALSE
WHERE surface.enabled
  AND NOT EXISTS (
      SELECT 1 FROM permission_surface_permissions mapping
      WHERE mapping.surface_id = surface.id);

WITH mapping(surface_key, permission_code) AS (VALUES
    ('basic.goods', 'goods:price:view'),
    ('purchase.order', 'purchase_order:cancel'),
    ('operations.purchase', 'purchase_order:cancel'),
    ('production.plan', 'production_execution:dispatch')
)
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM mapping
JOIN permission_surfaces surface ON surface.surface_key = mapping.surface_key AND surface.enabled
JOIN permissions permission ON permission.code = mapping.permission_code
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- 9. 角色体系彻底下线：四张表删除(基础包已平移，通知受众改按部门子树 + 权限码)
-- ---------------------------------------------------------------------
DROP TABLE department_roles;
DROP TABLE user_roles;
DROP TABLE role_permissions;
DROP TABLE roles;

-- ---------------------------------------------------------------------
-- 10. 删除被 grant_policy 取代的三列(停用码已删除，不再有软停用)
-- ---------------------------------------------------------------------
DROP INDEX IF EXISTS idx_permissions_active_assignable;
DROP INDEX IF EXISTS idx_permissions_active_catalog;
ALTER TABLE permissions
    DROP COLUMN active,
    DROP COLUMN assignable,
    DROP COLUMN bulk_assignable;

-- ---------------------------------------------------------------------
-- 11. 约束：码命名、授权策略取值、基础包资格
-- ---------------------------------------------------------------------
ALTER TABLE permissions
    ADD CONSTRAINT permissions_code_format_chk
        CHECK (code ~ '^[a-z][a-z_]*(:[a-z][a-z_]*){1,2}$'),
    ADD CONSTRAINT permissions_grant_policy_chk
        CHECK (cardinality(grant_policy) >= 1
               AND grant_policy <@ ARRAY['NORMAL', 'BULK_EXCLUDED', 'INDIVIDUAL_ONLY',
                                         'NON_DELEGABLE', 'SUPERADMIN_ONLY']::TEXT[]
               AND (grant_policy = ARRAY['NORMAL']::TEXT[] OR NOT ('NORMAL' = ANY(grant_policy)))),
    ADD CONSTRAINT permissions_baseline_policy_chk
        CHECK (NOT baseline
               OR NOT (grant_policy && ARRAY['BULK_EXCLUDED', 'INDIVIDUAL_ONLY', 'SUPERADMIN_ONLY']::TEXT[]));

COMMENT ON COLUMN permissions.grant_policy IS
    '授权策略(唯一事实源)：NORMAL 普通 / BULK_EXCLUDED 不随全部授权 / INDIVIDUAL_ONLY 只能逐人授予 / NON_DELEGABLE 负责人不可转授 / SUPERADMIN_ONLY 只随超管身份生效；NORMAL 只能单独出现';
COMMENT ON COLUMN permissions.baseline IS
    '全员基础包：TRUE 表示每个在职员工都隐式持有(管理页可编辑；个人收回仍优先)';

-- ---------------------------------------------------------------------
-- 12. 数据库守卫：按 grant_policy 统一判定(替换两条只认个别码的旧守卫)
-- ---------------------------------------------------------------------
DROP TRIGGER trg_guard_department_account_balance_adjustment ON department_permissions;
DROP TRIGGER trg_guard_department_audit_permissions ON department_permissions;
DROP FUNCTION fn_guard_department_account_balance_adjustment();
DROP FUNCTION fn_guard_department_audit_permissions();

CREATE FUNCTION fn_guard_permission_grant_policy() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    policy TEXT[];
BEGIN
    SELECT permission.grant_policy INTO policy
    FROM permissions permission
    WHERE permission.id = NEW.permission_id;
    IF policy IS NULL THEN
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME = 'department_permissions' THEN
        IF policy && ARRAY['INDIVIDUAL_ONLY', 'SUPERADMIN_ONLY']::TEXT[] THEN
            RAISE EXCEPTION '该权限只能逐人授予，不能配置给整个部门'
                USING ERRCODE = '23514';
        END IF;
    ELSIF TG_TABLE_NAME = 'user_permission_overrides' THEN
        IF NEW.active AND NEW.effect = 'grant'
           AND 'SUPERADMIN_ONLY' = ANY(policy)
           AND (TG_OP = 'INSERT' OR NOT (OLD.active AND OLD.effect = 'grant')) THEN
            RAISE EXCEPTION '该权限只随超级管理员身份生效，不能单独授予'
                USING ERRCODE = '23514';
        END IF;
    ELSIF TG_TABLE_NAME = 'manager_permission_delegations' THEN
        IF NEW.enabled
           AND policy && ARRAY['NON_DELEGABLE', 'INDIVIDUAL_ONLY', 'SUPERADMIN_ONLY']::TEXT[]
           AND (TG_OP = 'INSERT' OR NOT OLD.enabled) THEN
            RAISE EXCEPTION '该权限不能由负责人转授'
                USING ERRCODE = '23514';
        END IF;
    ELSIF TG_TABLE_NAME = 'permission_surface_permissions' THEN
        IF 'SUPERADMIN_ONLY' = ANY(policy) THEN
            RAISE EXCEPTION '超管专属权限不挂在页面权限面上'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_department_permission_grant_policy
    BEFORE INSERT OR UPDATE ON department_permissions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_permission_grant_policy();
CREATE TRIGGER trg_guard_override_permission_grant_policy
    BEFORE INSERT OR UPDATE ON user_permission_overrides
    FOR EACH ROW EXECUTE FUNCTION fn_guard_permission_grant_policy();
CREATE TRIGGER trg_guard_delegation_permission_grant_policy
    BEFORE INSERT OR UPDATE ON manager_permission_delegations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_permission_grant_policy();
CREATE TRIGGER trg_guard_surface_permission_grant_policy
    BEFORE INSERT OR UPDATE ON permission_surface_permissions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_permission_grant_policy();

-- ---------------------------------------------------------------------
-- 13. 清空函数孪生同步(V590 同款「读已安装定义 + 单行 needle 替换」失败关闭补丁)：
--     四张角色表已删，business_data_reset 策略清单里的 PRESERVE 行必须一并移除，
--     否则清空时「策略表 vs 实存表」目录核对失败关闭、拒绝执行。
-- ---------------------------------------------------------------------
DO $$
DECLARE
    definition TEXT;
    needle TEXT;
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    FOREACH needle IN ARRAY ARRAY[
        '(''department_roles'', ''PRESERVE''),',
        '(''role_permissions'', ''PRESERVE''),',
        '(''roles'', ''PRESERVE''),',
        '(''user_roles'', ''PRESERVE''),'] LOOP
        IF position(needle IN definition) = 0 THEN
            RAISE EXCEPTION 'V677 cannot drop retired role policy row % from business_data_reset', needle;
        END IF;
        definition := replace(definition, needle, '');
    END LOOP;
    EXECUTE definition;
END;
$$;

-- ---------------------------------------------------------------------
-- 14. 失败关闭的终检
-- ---------------------------------------------------------------------
DO $$
DECLARE
    offending TEXT;
BEGIN
    SELECT string_agg(code, ', ' ORDER BY code) INTO offending
    FROM permissions
    WHERE code LIKE '%:view:all'
      AND NOT (grant_policy @> ARRAY['BULK_EXCLUDED', 'NON_DELEGABLE']::TEXT[]);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'V677 company-wide scope codes must be bulk-excluded and non-delegable: %', offending;
    END IF;

    SELECT string_agg(code, ', ' ORDER BY code) INTO offending
    FROM permissions
    WHERE code IN ('finance_shipment_audit', 'sales_shipment:warehouse-work',
                   'production_plan:batchApprove', 'production_plan:batchDelete',
                   'finance_reconciliation:view', 'employee:export', 'finance_asset:export',
                   'visitor:apply', 'visitor:view',
                   'visitor:check-in', 'visitor:host-confirm', 'procurement_iqc_rejection:view_all');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'V677 retired or renamed codes still present: %', offending;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM permissions WHERE baseline) THEN
        RAISE EXCEPTION 'V677 baseline package must not be empty';
    END IF;
END;
$$;
