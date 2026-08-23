-- V328: explicit permission action taxonomy, split button-level authorities,
-- and a migration-owned page/surface catalog.
--
-- V315-V327 are applied candidate history and remain byte-for-byte immutable.
-- This migration is deliberately forward-only.  It preserves every effective
-- old grant/revoke before retiring obsolete composite catalog entries.

-- Capture only delegations whose database authority snapshots are valid at the
-- V327 boundary. Permission catalog writes advance the shared epoch, so reading
-- these rows later would make every otherwise-current source look stale. Stale
-- enabled rows are deliberately not rebased or revived.
CREATE TEMP TABLE v328_effective_manager_delegation_source
ON COMMIT DROP AS
SELECT delegation.*
FROM manager_permission_delegations delegation
JOIN users target_user
  ON target_user.id = delegation.user_id
JOIN employees target_employee
  ON target_employee.id = target_user.employee_id
JOIN departments target_department
  ON target_department.id = delegation.department_id
 AND target_department.id = target_employee.department_id
JOIN users grantor_user
  ON grantor_user.id = delegation.granted_by_user_id
LEFT JOIN employees grantor_employee
  ON grantor_employee.id = grantor_user.employee_id
CROSS JOIN authorization_state auth_state
LEFT JOIN departments scope_department
  ON scope_department.id = delegation.scope_department_id
WHERE delegation.enabled = TRUE
  AND target_user.status = 'active'
  AND target_user.is_deleted = FALSE
  AND target_employee.status IN ('active', 'probation', 'onLeave')
  AND target_employee.is_deleted = FALSE
  AND target_department.is_deleted = FALSE
  AND delegation.target_user_generation =
      target_user.permission_delegation_generation
  AND delegation.target_employee_generation =
      target_employee.permission_delegation_generation
  AND delegation.target_department_generation =
      target_department.permission_delegation_generation
  AND grantor_user.status = 'active'
  AND grantor_user.is_deleted = FALSE
  AND delegation.grantor_user_generation =
      grantor_user.permission_delegation_generation
  AND delegation.grantor_auth_version = grantor_user.auth_version
  AND auth_state.singleton_id = 1
  AND delegation.grantor_authorization_epoch = auth_state.epoch
  AND (
        (
            delegation.scope_source = 'SUPER_ADMIN'
            AND grantor_user.is_super_admin = TRUE
            AND delegation.grantor_employee_generation IS NULL
            AND delegation.scope_department_id IS NULL
            AND delegation.scope_generation IS NULL
            AND delegation.scope_assignment_id IS NULL
            AND delegation.scope_assignment_version IS NULL
        )
        OR (
            delegation.scope_source = 'DEPARTMENT_MANAGER'
            AND grantor_employee.id IS NOT NULL
            AND grantor_employee.status IN ('active', 'probation', 'onLeave')
            AND grantor_employee.is_deleted = FALSE
            AND delegation.grantor_employee_generation =
                grantor_employee.permission_delegation_generation
            AND scope_department.is_deleted = FALSE
            AND scope_department.manager_id = grantor_employee.id
            AND delegation.scope_generation =
                scope_department.permission_delegation_generation
            AND delegation.scope_assignment_id IS NULL
            AND delegation.scope_assignment_version IS NULL
            AND EXISTS (
                WITH RECURSIVE target_ancestors(id, parent_id, visited) AS (
                    SELECT target_department.id,
                           target_department.parent_id,
                           ARRAY[target_department.id]
                    UNION ALL
                    SELECT parent.id,
                           parent.parent_id,
                           ancestor.visited || parent.id
                    FROM departments parent
                    JOIN target_ancestors ancestor
                      ON parent.id = ancestor.parent_id
                    WHERE NOT parent.id = ANY(ancestor.visited)
                )
                SELECT 1
                FROM target_ancestors ancestor
                WHERE ancestor.id = delegation.scope_department_id
            )
        )
  );

ALTER TABLE permissions
    ADD COLUMN action_type TEXT,
    ADD COLUMN description TEXT,
    ADD COLUMN active BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN assignable BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE permissions
    ADD CONSTRAINT permissions_action_type_chk
        CHECK (action_type IN (
            'VIEW', 'CREATE', 'EDIT', 'DELETE', 'APPROVE',
            'IMPORT', 'EXPORT', 'EXECUTE', 'CONFIGURE', 'ASSIGN'
        )) NOT VALID;

COMMENT ON COLUMN permissions.action_type IS
    'Authoritative UI action group; never inferred from a code suffix at runtime';
COMMENT ON COLUMN permissions.description IS
    'Plain-language business effect shown beside the permission name';
COMMENT ON COLUMN permissions.active IS
    'FALSE retires a historical code from runtime catalogs without deleting authorization provenance';
COMMENT ON COLUMN permissions.assignable IS
    'FALSE prevents the code from being newly granted; effective-history handling remains source-specific';

-- New permissions are inserted before old grants are expanded. Existing :edit
-- codes remain the narrow edit authority; create/delete/approve/reverse/status
-- buttons receive their own codes below.
INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description)
VALUES
    -- Basic-data category trees.
    ('material_category:create', '新增物料分类', '基础资料', '物料分类', 12, 'CREATE', '新增物料分类节点'),
    ('material_category:delete', '删除物料分类（保留历史）', '基础资料', '物料分类', 13, 'DELETE', '删除未受保护的物料分类并保留历史记录'),
    ('material_category:move', '移动物料分类', '基础资料', '物料分类', 14, 'EXECUTE', '把物料分类移动到新的父分类'),
    ('material_category:reorder', '调整物料分类顺序', '基础资料', '物料分类', 15, 'EXECUTE', '调整同级物料分类的显示顺序'),
    ('mould_category:create', '新增模具分类', '基础资料', '模具分类', 34, 'CREATE', '新增模具分类节点'),
    ('mould_category:delete', '删除模具分类（保留历史）', '基础资料', '模具分类', 35, 'DELETE', '删除未受保护的模具分类并保留历史记录'),
    ('mould_category:move', '移动模具分类', '基础资料', '模具分类', 36, 'EXECUTE', '把模具分类移动到新的父分类'),
    ('mould_category:reorder', '调整模具分类顺序', '基础资料', '模具分类', 37, 'EXECUTE', '调整同级模具分类的显示顺序'),
    ('client_category:create', '新增客户分类', '基础资料', '客户分类', 44, 'CREATE', '新增客户分类节点'),
    ('client_category:delete', '删除客户分类（保留历史）', '基础资料', '客户分类', 45, 'DELETE', '删除未受保护的客户分类并保留历史记录'),
    ('client_category:move', '移动客户分类', '基础资料', '客户分类', 46, 'EXECUTE', '把客户分类移动到新的父分类'),
    ('client_category:reorder', '调整客户分类顺序', '基础资料', '客户分类', 47, 'EXECUTE', '调整同级客户分类的显示顺序'),
    ('supplier_category:create', '新增供应商分类', '基础资料', '供应商分类', 54, 'CREATE', '新增供应商分类节点'),
    ('supplier_category:delete', '删除供应商分类（保留历史）', '基础资料', '供应商分类', 55, 'DELETE', '删除未受保护的供应商分类并保留历史记录'),
    ('supplier_category:move', '移动供应商分类', '基础资料', '供应商分类', 56, 'EXECUTE', '把供应商分类移动到新的父分类'),
    ('supplier_category:reorder', '调整供应商分类顺序', '基础资料', '供应商分类', 57, 'EXECUTE', '调整同级供应商分类的显示顺序'),
    -- Basic-data entities.
    ('goods:create', '新增货品资料', '基础资料', '货品资料', 26, 'CREATE', '新增货品主档'),
    ('goods:delete', '删除货品资料（保留历史）', '基础资料', '货品资料', 27, 'DELETE', '删除货品主档并保留历史引用'),
    ('goods:status', '启用或停用货品', '基础资料', '货品资料', 28, 'EXECUTE', '变更货品启用状态，不等同于删除'),
    ('goods:bom:create', '新增货品组装明细', '基础资料', '货品资料', 29, 'CREATE', '向货品组装树新增组件'),
    ('goods:bom:edit', '编辑货品组装明细', '基础资料', '货品资料', 30, 'EDIT', '编辑既有货品组装组件'),
    ('goods:bom:delete', '删除货品组装明细（保留历史）', '基础资料', '货品资料', 31, 'DELETE', '删除组装组件并保留审计历史'),
    ('mould:create', '新增模具资料', '基础资料', '模具', 38, 'CREATE', '新增模具主档'),
    ('mould:delete', '删除模具资料（保留历史）', '基础资料', '模具', 39, 'DELETE', '删除模具主档并保留历史引用'),
    ('mould:status', '启用或停用模具', '基础资料', '模具', 40, 'EXECUTE', '变更模具启用状态，不等同于删除'),
    ('client:create', '新增客户资料', '基础资料', '客户资料', 48, 'CREATE', '新增客户主档'),
    ('client:delete', '删除客户资料（保留历史）', '基础资料', '客户资料', 49, 'DELETE', '删除客户主档并保留历史引用'),
    ('client:status', '启用或停用客户', '基础资料', '客户资料', 50, 'EXECUTE', '变更客户启用状态，不等同于删除'),
    ('client_address:create', '新增客户收货地址', '基础资料', '客户资料', 597, 'CREATE', '新增客户收货地址'),
    ('supplier:create', '新增供应商资料', '基础资料', '供应商资料', 58, 'CREATE', '新增供应商主档'),
    ('supplier:delete', '删除供应商资料（保留历史）', '基础资料', '供应商资料', 59, 'DELETE', '删除供应商主档并保留历史引用'),
    ('supplier:status', '启用或停用供应商', '基础资料', '供应商资料', 60, 'EXECUTE', '变更供应商启用状态，不等同于删除'),
    ('color:create', '新增颜色资料', '基础资料', '颜色', 62, 'CREATE', '新增颜色主档'),
    ('color:delete', '删除颜色资料（保留历史）', '基础资料', '颜色', 63, 'DELETE', '删除颜色主档并保留历史引用'),
    ('color:status', '启用或停用颜色', '基础资料', '颜色', 64, 'EXECUTE', '变更颜色启用状态，不等同于删除'),
    ('unit:create', '新增单位资料', '基础资料', '单位', 72, 'CREATE', '新增基本单位主档'),
    ('unit:delete', '删除单位资料（保留历史）', '基础资料', '单位', 73, 'DELETE', '删除单位主档并保留历史引用'),
    ('unit:status', '启用或停用单位', '基础资料', '单位', 74, 'EXECUTE', '变更单位启用状态，不等同于删除'),
    ('currency:create', '新增币种资料', '基础资料', '币种', 82, 'CREATE', '新增币种主档'),
    ('currency:delete', '删除币种资料（保留历史）', '基础资料', '币种', 83, 'DELETE', '删除币种主档并保留历史引用'),
    ('currency:status', '启用或停用币种', '基础资料', '币种', 84, 'EXECUTE', '变更币种启用状态，不等同于删除'),
    ('warehouse:create', '新增仓库资料', '基础资料', '仓库', 92, 'CREATE', '新增仓库主档'),
    ('warehouse:delete', '删除仓库资料（保留历史）', '基础资料', '仓库', 93, 'DELETE', '删除仓库主档并保留历史引用'),
    ('warehouse:status', '启用或停用仓库', '基础资料', '仓库', 94, 'EXECUTE', '变更仓库启用状态，不等同于删除'),
    ('account:create', '新增账户资料', '基础资料', '账户资料', 102, 'CREATE', '新增财务账户主档'),
    ('account:delete', '删除账户资料（保留历史）', '基础资料', '账户资料', 103, 'DELETE', '删除账户主档并保留历史引用'),
    ('account:status', '启用或停用账户', '基础资料', '账户资料', 104, 'EXECUTE', '变更账户启用状态，不等同于删除'),
    ('payment_style:create', '新增收付款类别', '基础资料', '收付款类别', 112, 'CREATE', '新增收付款类别节点'),
    ('payment_style:status', '启用或停用收付款类别', '基础资料', '收付款类别', 113, 'EXECUTE', '变更收付款类别状态；不提供删除能力'),
    ('payment_style:move', '移动收付款类别', '基础资料', '收付款类别', 114, 'EXECUTE', '把收付款类别移动到新的父类别'),
    ('payment_style:reorder', '调整收付款类别顺序', '基础资料', '收付款类别', 115, 'EXECUTE', '调整同级收付款类别的显示顺序'),
    ('settlement_method:create', '新增结算方式', '基础资料', '收付款类别', 116, 'CREATE', '新增独立结算方式主档')
ON CONFLICT (code) DO NOTHING;

-- Additional split permissions are appended below in business-module batches.


-- Sales, purchase, stock and finance workflows use one permission per visible
-- button/action. Existing :edit remains the narrow draft-edit authority.
INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description)
VALUES
    ('sales_quote:create', '新增销售报价单', '销售管理', '销售报价', 202, 'CREATE', '新增销售报价草稿'),
    ('sales_quote:delete', '删除销售报价草稿（保留历史）', '销售管理', '销售报价', 203, 'DELETE', '软删除销售报价草稿并保留审计历史'),
    ('sales_quote:approve', '审核销售报价单', '销售管理', '销售报价', 204, 'APPROVE', '审核销售报价单'),
    ('sales_quote:reverse', '红冲销售报价单', '销售管理', '销售报价', 205, 'EXECUTE', '红冲已审核销售报价单'),
    ('sales_quote:convert', '将销售报价转为销售订货', '销售管理', '销售报价', 206, 'EXECUTE', '从已审核报价生成销售订货草稿'),
    ('sales_order:create', '新增销售订货单', '销售管理', '销售订货', 217, 'CREATE', '新增销售订货草稿'),
    ('sales_order:delete', '删除销售订货草稿（保留历史）', '销售管理', '销售订货', 218, 'DELETE', '软删除销售订货草稿并保留审计历史'),
    ('sales_order:approve', '审核销售订货单', '销售管理', '销售订货', 219, 'APPROVE', '审核销售订货单并推进库存与排产检查'),
    ('sales_order:reverse', '红冲销售订货单', '销售管理', '销售订货', 220, 'EXECUTE', '红冲已审核销售订货单'),
    ('sales_order:stop', '启用或中止销售订货单', '销售管理', '销售订货', 221, 'EXECUTE', '切换销售订货单中止状态'),
    ('sales_order:change_qty', '修改销售订货数量', '销售管理', '销售订货', 222, 'EDIT', '修改已审核销售订货数量；已排产时仍需额外权限'),
    ('sales_order:cancel', '取消销售订货单', '销售管理', '销售订货', 223, 'EXECUTE', '取消未发货订单并释放相关资源'),
    ('sales_shipment:create', '新增销售出货单', '销售管理', '销售出货', 224, 'CREATE', '新增销售出货草稿'),
    ('sales_shipment:delete', '删除销售出货草稿（保留历史）', '销售管理', '销售出货', 225, 'DELETE', '软删除销售出货草稿并保留审计历史'),
    ('sales_shipment:approve', '审核销售出货单', '销售管理', '销售出货', 226, 'APPROVE', '审核销售出货并推进出库'),
    ('sales_shipment:reverse', '红冲销售出货单', '销售管理', '销售出货', 227, 'EXECUTE', '红冲已审核销售出货单'),
    ('sales_other_shipment:create', '新增其他出货单', '销售管理', '其他出货', 232, 'CREATE', '新增其他出货草稿'),
    ('sales_other_shipment:delete', '删除其他出货草稿（保留历史）', '销售管理', '其他出货', 233, 'DELETE', '软删除其他出货草稿并保留审计历史'),
    ('sales_other_shipment:approve', '审核其他出货单', '销售管理', '其他出货', 234, 'APPROVE', '审核其他出货单'),
    ('sales_other_shipment:reverse', '红冲其他出货单', '销售管理', '其他出货', 235, 'EXECUTE', '红冲已审核其他出货单'),
    ('sales_return:create', '新增销售退货单', '销售管理', '销售退货', 242, 'CREATE', '新增销售退货草稿'),
    ('sales_return:delete', '删除销售退货草稿（保留历史）', '销售管理', '销售退货', 243, 'DELETE', '软删除销售退货草稿并保留审计历史'),
    ('sales_return:approve', '审核销售退货单', '销售管理', '销售退货', 244, 'APPROVE', '审核销售退货单'),
    ('sales_return:reverse', '红冲销售退货单', '销售管理', '销售退货', 245, 'EXECUTE', '红冲已审核销售退货单'),
    ('purchase_order:create', '新增采购订货单', '采购管理', '采购订货', 113, 'CREATE', '新增采购订货草稿'),
    ('purchase_order:delete', '删除采购订货草稿（保留历史）', '采购管理', '采购订货', 114, 'DELETE', '软删除采购订货草稿并保留审计历史'),
    ('purchase_order:reverse', '红冲采购订货单', '采购管理', '采购订货', 115, 'EXECUTE', '红冲已完成财务流程的采购订货单'),
    ('purchase_order:decompose', '将采购申请分解为采购订货', '采购管理', '采购订货', 116, 'EXECUTE', '从只读采购申请生成采购订货草稿'),
    ('purchase_receipt:create', '新增采购收货单', '采购管理', '采购收货', 122, 'CREATE', '新增采购收货草稿'),
    ('purchase_receipt:delete', '删除采购收货草稿（保留历史）', '采购管理', '采购收货', 123, 'DELETE', '软删除采购收货草稿并保留审计历史'),
    ('purchase_receipt:approve', '审核采购收货单', '采购管理', '采购收货', 124, 'APPROVE', '审核采购收货并推进质检或入库'),
    ('purchase_receipt:reverse', '红冲采购收货单', '采购管理', '采购收货', 125, 'EXECUTE', '红冲已审核采购收货单'),
    ('purchase_return:create', '新增采购退货单', '采购管理', '采购退货', 132, 'CREATE', '新增采购退货草稿'),
    ('purchase_return:delete', '删除采购退货草稿（保留历史）', '采购管理', '采购退货', 133, 'DELETE', '软删除采购退货草稿并保留审计历史'),
    ('purchase_return:approve', '审核采购退货单', '采购管理', '采购退货', 134, 'APPROVE', '审核采购退货并推进出库'),
    ('purchase_return:reverse', '红冲采购退货单', '采购管理', '采购退货', 135, 'EXECUTE', '红冲已审核采购退货单'),
    ('finance_order_approval:approve', '批准采购、委外订货及到货异常', '财税管理', '订货审批', 594, 'APPROVE', '批准采购、委外订货或到货异常审批任务'),
    ('finance_order_approval:reject', '驳回采购、委外订货及到货异常', '财税管理', '订货审批', 595, 'APPROVE', '驳回采购、委外订货或到货异常审批任务'),
    ('stock_doc:create', '新增仓库单据', '仓库管理', '仓库单据', 214, 'CREATE', '新增仓库单据草稿'),
    ('stock_doc:delete', '删除仓库单据草稿（保留历史）', '仓库管理', '仓库单据', 215, 'DELETE', '软删除仓库单据草稿并保留审计历史'),
    ('stock_doc:approve', '审核仓库单据', '仓库管理', '仓库单据', 216, 'APPROVE', '审核仓库单据'),
    ('stock_doc:reverse', '红冲仓库单据', '仓库管理', '仓库单据', 217, 'EXECUTE', '红冲已审核仓库单据'),
    ('stock_doc:issue', '执行仓库单据发料', '仓库管理', '仓库单据', 218, 'EXECUTE', '执行生产或委外发料'),
    ('stock_doc:reverse_issue', '红冲仓库单据发料', '仓库管理', '仓库单据', 219, 'EXECUTE', '红冲已执行的发料'),
    ('production_daily_report:create', '新增生产日报', '生产管理', '生产日报', 422, 'CREATE', '新增生产日报草稿'),
    ('production_daily_report:delete', '删除生产日报草稿（保留历史）', '生产管理', '生产日报', 423, 'DELETE', '软删除生产日报草稿并保留审计历史'),
    ('production_daily_report:approve', '审核生产日报', '生产管理', '生产日报', 424, 'APPROVE', '审核生产日报并推进业务记账'),
    ('production_daily_report:reverse', '红冲生产日报', '生产管理', '生产日报', 425, 'EXECUTE', '红冲已审核生产日报'),
    ('production_plan:delete', '删除生产计划草稿（保留历史）', '生产管理', '生产计划', 403, 'DELETE', '软删除生产计划草稿并保留审计历史'),
    ('production_plan:reverse', '红冲生产计划', '生产管理', '生产计划', 404, 'EXECUTE', '红冲已审核生产计划'),
    ('production_plan:flags', '更新生产计划业务标记', '生产管理', '生产计划', 405, 'EDIT', '更新生产计划中止、结案或完成标记'),
    ('goods:import:undo', '撤回最近一次货品导入', '基础资料', '货品资料', 32, 'EXECUTE', '在安全边界内撤回最近一次货品导入')
ON CONFLICT (code) DO NOTHING;

-- Subcontract and finance documents follow the same explicit lifecycle.
INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description)
VALUES
    ('subcontract_inquiry:create', '新增委外询价单', '委外管理', '委外询价', 302, 'CREATE', '新增委外询价草稿'),
    ('subcontract_inquiry:delete', '删除委外询价草稿（保留历史）', '委外管理', '委外询价', 303, 'DELETE', '软删除委外询价草稿并保留审计历史'),
    ('subcontract_inquiry:approve', '审核委外询价单', '委外管理', '委外询价', 304, 'APPROVE', '审核委外询价单'),
    ('subcontract_inquiry:reverse', '红冲委外询价单', '委外管理', '委外询价', 305, 'EXECUTE', '红冲已审核委外询价单'),
    ('subcontract_order:create', '新增委外订货单', '委外管理', '委外订货', 323, 'CREATE', '新增委外订货草稿'),
    ('subcontract_order:delete', '删除委外订货草稿（保留历史）', '委外管理', '委外订货', 324, 'DELETE', '软删除委外订货草稿并保留审计历史'),
    ('subcontract_order:reverse', '红冲委外订货单', '委外管理', '委外订货', 325, 'EXECUTE', '红冲已完成财务流程的委外订货单'),
    ('subcontract_order:decompose', '将委外申请分解为委外订货', '委外管理', '委外订货', 326, 'EXECUTE', '从只读委外申请生成委外订货草稿'),
    ('subcontract_receipt:create', '新增委外进仓单', '委外管理', '委外进仓', 332, 'CREATE', '新增委外进仓草稿'),
    ('subcontract_receipt:delete', '删除委外进仓草稿（保留历史）', '委外管理', '委外进仓', 333, 'DELETE', '软删除委外进仓草稿并保留审计历史'),
    ('subcontract_receipt:approve', '审核委外进仓单', '委外管理', '委外进仓', 334, 'APPROVE', '审核委外进仓并推进质检或入库'),
    ('subcontract_receipt:reverse', '红冲委外进仓单', '委外管理', '委外进仓', 335, 'EXECUTE', '红冲已审核委外进仓单'),
    ('subcontract_material_issue:create', '新增委外材料出仓单', '委外管理', '委外材料出仓', 342, 'CREATE', '新增委外材料出仓草稿'),
    ('subcontract_material_issue:delete', '删除委外材料出仓草稿（保留历史）', '委外管理', '委外材料出仓', 343, 'DELETE', '软删除委外材料出仓草稿并保留审计历史'),
    ('subcontract_material_issue:approve', '审核委外材料出仓单', '委外管理', '委外材料出仓', 344, 'APPROVE', '审核委外材料出仓单'),
    ('subcontract_material_issue:reverse', '红冲委外材料出仓单', '委外管理', '委外材料出仓', 345, 'EXECUTE', '红冲已审核委外材料出仓单'),
    ('subcontract_return:create', '新增委外退货单', '委外管理', '委外退货', 352, 'CREATE', '新增委外退货草稿'),
    ('subcontract_return:delete', '删除委外退货草稿（保留历史）', '委外管理', '委外退货', 353, 'DELETE', '软删除委外退货草稿并保留审计历史'),
    ('subcontract_return:approve', '审核委外退货单', '委外管理', '委外退货', 354, 'APPROVE', '审核委外退货单'),
    ('subcontract_return:reverse', '红冲委外退货单', '委外管理', '委外退货', 355, 'EXECUTE', '红冲已审核委外退货单'),
    ('subcontract_material_return:create', '新增委外材料退货单', '委外管理', '委外材料退货', 362, 'CREATE', '新增委外材料退货草稿'),
    ('subcontract_material_return:delete', '删除委外材料退货草稿（保留历史）', '委外管理', '委外材料退货', 363, 'DELETE', '软删除委外材料退货草稿并保留审计历史'),
    ('subcontract_material_return:approve', '审核委外材料退货单', '委外管理', '委外材料退货', 364, 'APPROVE', '审核委外材料退货单'),
    ('subcontract_material_return:reverse', '红冲委外材料退货单', '委外管理', '委外材料退货', 365, 'EXECUTE', '红冲已审核委外材料退货单'),
    ('subcontract_waste:create', '新增委外材料损耗单', '委外管理', '委外材料损耗', 372, 'CREATE', '新增委外材料损耗草稿'),
    ('subcontract_waste:delete', '删除委外材料损耗草稿（保留历史）', '委外管理', '委外材料损耗', 373, 'DELETE', '软删除委外材料损耗草稿并保留审计历史'),
    ('subcontract_waste:approve', '审核委外材料损耗单', '委外管理', '委外材料损耗', 374, 'APPROVE', '审核委外材料损耗单'),
    ('subcontract_waste:reverse', '红冲委外材料损耗单', '委外管理', '委外材料损耗', 375, 'EXECUTE', '红冲已审核委外材料损耗单'),
    ('finance_receipt:create', '新增销售收款单', '财税管理', '销售收款', 512, 'CREATE', '新增销售收款草稿'),
    ('finance_receipt:delete', '删除销售收款草稿（保留历史）', '财税管理', '销售收款', 513, 'DELETE', '软删除销售收款草稿并保留审计历史'),
    ('finance_receipt:approve', '审核销售收款单', '财税管理', '销售收款', 514, 'APPROVE', '审核收款并核销应收、更新账户流水'),
    ('finance_receipt:reverse', '红冲销售收款单', '财税管理', '销售收款', 515, 'EXECUTE', '红冲已审核销售收款单及其账务影响'),
    ('finance_payment:create', '新增采购付款单', '财税管理', '采购付款', 522, 'CREATE', '新增采购付款草稿'),
    ('finance_payment:delete', '删除采购付款草稿（保留历史）', '财税管理', '采购付款', 523, 'DELETE', '软删除采购付款草稿并保留审计历史'),
    ('finance_payment:approve', '审核采购付款单', '财税管理', '采购付款', 524, 'APPROVE', '审核付款并核销应付、更新账户流水'),
    ('finance_payment:reverse', '红冲采购付款单', '财税管理', '采购付款', 525, 'EXECUTE', '红冲已审核采购付款单及其账务影响'),
    ('finance_expense:create', '新增一般费用单', '财税管理', '一般费用', 532, 'CREATE', '新增一般费用草稿'),
    ('finance_expense:delete', '删除一般费用草稿（保留历史）', '财税管理', '一般费用', 533, 'DELETE', '软删除一般费用草稿并保留审计历史'),
    ('finance_expense:approve', '审核一般费用单', '财税管理', '一般费用', 534, 'APPROVE', '审核一般费用并更新账户流水'),
    ('finance_expense:reverse', '红冲一般费用单', '财税管理', '一般费用', 535, 'EXECUTE', '红冲已审核一般费用单及其账务影响'),
    ('finance_expense:gl_confirm', '确认一般费用总账入账', '财税管理', '一般费用', 536, 'EXECUTE', '确认一般费用总账入账状态'),
    ('finance_other_income:create', '新增其他收入单', '财税管理', '其他收入', 542, 'CREATE', '新增其他收入草稿'),
    ('finance_other_income:delete', '删除其他收入草稿（保留历史）', '财税管理', '其他收入', 543, 'DELETE', '软删除其他收入草稿并保留审计历史'),
    ('finance_other_income:approve', '审核其他收入单', '财税管理', '其他收入', 544, 'APPROVE', '审核其他收入并更新账户流水'),
    ('finance_other_income:reverse', '红冲其他收入单', '财税管理', '其他收入', 545, 'EXECUTE', '红冲已审核其他收入单及其账务影响'),
    ('finance_bank_transfer:create', '新增银行存取单', '财税管理', '银行存取', 552, 'CREATE', '新增银行存取草稿'),
    ('finance_bank_transfer:delete', '删除银行存取草稿（保留历史）', '财税管理', '银行存取', 553, 'DELETE', '软删除银行存取草稿并保留审计历史'),
    ('finance_bank_transfer:approve', '审核银行存取单', '财税管理', '银行存取', 554, 'APPROVE', '审核银行存取单'),
    ('finance_bank_transfer:reverse', '红冲银行存取单', '财税管理', '银行存取', 555, 'EXECUTE', '红冲已审核银行存取单')
ON CONFLICT (code) DO NOTHING;

-- Organization, people, attachments and specialist business workflows.
INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description, assignable)
VALUES
    ('department:create', '新增部门', '人事行政', '部门', 2, 'CREATE', '新增部门或组织节点', TRUE),
    ('department:delete', '删除部门（保留历史）', '人事行政', '部门', 3, 'DELETE', '删除空组织节点并保留历史引用', TRUE),
    ('department:move', '移动部门', '人事行政', '部门', 4, 'EXECUTE', '调整部门上级并安全重建子树层级', TRUE),
    ('department:manager_assign', '设置部门负责人', '人事行政', '部门', 5, 'ASSIGN', '设置或清除部门直属在岗负责人', TRUE),
    ('position:create', '新增岗位', '人事行政', '部门', 4, 'CREATE', '在部门下新增岗位', TRUE),
    ('position:edit', '编辑岗位', '人事行政', '部门', 5, 'EDIT', '编辑岗位资料', TRUE),
    ('position:delete', '删除岗位（保留历史）', '人事行政', '部门', 6, 'DELETE', '删除未被引用的岗位并保留历史', TRUE),
    ('employee:transfer', '办理员工调岗', '人事行政', '员工档案', 63, 'ASSIGN', '变更员工所属部门或岗位并记录任职轨迹', TRUE),
    ('employee:offboard', '办理员工离职', '人事行政', '员工档案', 64, 'EXECUTE', '办理离职、停用账号并永久保留员工档案', TRUE),
    ('employee:confirm', '办理员工转正', '人事行政', '员工档案', 65, 'APPROVE', '确认试用员工转正', TRUE),
    ('employee:rehire', '办理员工复职', '人事行政', '员工档案', 66, 'EXECUTE', '恢复离职员工任职并记录复职轨迹', TRUE),
    ('employee:contract_renew', '续签或补录员工合同', '人事行政', '员工档案', 67, 'EXECUTE', '新增员工合同记录', TRUE),
    ('employee:avatar_edit', '更新员工头像', '人事行政', '员工档案', 68, 'EDIT', '更新员工头像引用', TRUE),
    ('employee:task_takeover', '接管人事任务', '人事行政', '员工档案', 69, 'ASSIGN', '接管其他处理人的人事任务', TRUE),
    ('attachment:download', '下载附件', '人事行政', '附件', 234, 'EXPORT', '下载已获对象访问授权的附件内容', TRUE),
    ('attachment:upload', '上传附件', '人事行政', '附件', 235, 'IMPORT', '上传并确认业务附件', TRUE),
    ('attachment:delete', '删除附件（保留审计）', '人事行政', '附件', 236, 'DELETE', '删除附件对象并保留删除审计', TRUE),
    -- Global-only governance permissions intentionally have no business
    -- surface relation. They remain visible only in the central catalog;
    -- migrated historical grants are preserved, but new assignment and
    -- manager delegation are forbidden.
    ('attachment:reconcile:view', '查看附件孤儿记录', '人事行政', '附件', 237, 'VIEW', '查看附件与业务对象的孤儿对账记录', FALSE),
    ('attachment:reconcile:approve_delete', '批准删除附件孤儿记录', '人事行政', '附件', 238, 'APPROVE', '批准清理已确认的附件孤儿对象', FALSE),
    ('rd_task:create', '新增研发任务', '工程研发', '研发任务', 13, 'CREATE', '新增研发任务', TRUE),
    ('rd_task:assign', '分配研发任务', '工程研发', '研发任务', 14, 'ASSIGN', '把研发任务分配给执行员工', TRUE),
    ('production_material_analysis:create', '新建生产物料分析', '生产管理', '物料分析', 219, 'CREATE', '从销售需求新建生产物料分析', TRUE),
    ('production_material_analysis:refresh', '刷新生产物料分析', '生产管理', '物料分析', 220, 'EXECUTE', '按当前库存与供给事实刷新分析', TRUE),
    ('production_material_analysis:cancel', '取消生产物料分析', '生产管理', '物料分析', 221, 'EXECUTE', '取消尚可安全撤销的生产物料分析', TRUE),
    ('production_execution:assign', '调整生产执行段分配', '生产管理', '执行分段', 222, 'ASSIGN', '调整执行段的车间、班组、负责人和计划日期', TRUE),
    ('production_execution:release_defer', '解除生产执行段人工暂缓', '生产管理', '执行分段', 223, 'EXECUTE', '解除执行段人工暂缓并重新检查物料齐套', TRUE),
    ('production_execution:dispatch', '派工生产执行段', '生产管理', '执行分段', 224, 'ASSIGN', '把已齐套的生产执行段正式派工', TRUE),
    ('production_execution:start', '确认生产执行段开工', '生产管理', '执行分段', 225, 'EXECUTE', '确认已派工执行段进入生产中状态', TRUE),
    ('production_execution:cancel', '取消生产执行段', '生产管理', '执行分段', 226, 'EXECUTE', '取消尚未形成不可逆生产事实的执行段', TRUE),
    ('production_execution:reverse', '冲销生产执行段', '生产管理', '执行分段', 227, 'EXECUTE', '冲销执行段及其可安全回退的生产事实', TRUE),
    ('production_mrp:generate_purchase', '生成缺料采购申请', '生产管理', '物料需求', 228, 'EXECUTE', '按生产物料净需求生成采购申请草稿', TRUE),
    ('production_mrp:generate_draw', '生成生产领料单', '生产管理', '物料需求', 229, 'EXECUTE', '按生产 BOM 毛需求生成领料单草稿', TRUE),
    ('production_mrp:generate_finished_in', '生成成品入库单', '生产管理', '物料需求', 230, 'EXECUTE', '按生产计划剩余数量生成成品入库单草稿', TRUE),
    ('production_planning_package:generate', '正式下达生产计划包', '生产管理', '计划包', 231, 'EXECUTE', '原子生成执行分段、物料占用和适用的下游单据', TRUE),
    ('production_planning_package:draft_edit', '编辑生产预排草案', '生产管理', '计划包', 232, 'EDIT', '新增或覆盖本生产计划的预排草案', TRUE),
    ('production_planning_package:cancel', '取消生产计划包', '生产管理', '计划包', 233, 'EXECUTE', '取消仍可安全撤销的生产计划包', TRUE),
    ('production_planning_package:reverse', '冲销生产计划包', '生产管理', '计划包', 234, 'EXECUTE', '冲销生产计划包及其可回退的下游事实', TRUE),
    ('production_material:settle', '提交生产材料结清', '生产管理', '材料结清', 235, 'EXECUTE', '登记生产材料实耗、批准损耗或在制占用', TRUE),
    ('production_material:reverse', '冲销生产材料结清', '生产管理', '材料结清', 236, 'EXECUTE', '按原记录冲销错误的生产材料结清数量', TRUE),
    ('production_material:close', '关闭已结清生产任务', '生产管理', '材料结清', 237, 'EXECUTE', '在成品和材料全部平衡后关闭生产任务', TRUE),
    ('webinquiry:claim', '认领官网询盘', '销售管理', '官网询盘', 92, 'ASSIGN', '认领待跟进的官网询盘', TRUE),
    ('webinquiry:close', '关闭官网询盘', '销售管理', '官网询盘', 93, 'EXECUTE', '关闭已处理或无效的官网询盘', TRUE),
    ('webinquiry:convert_client', '将官网询盘转为客户', '销售管理', '官网询盘', 94, 'EXECUTE', '把官网询盘转换为客户主档', TRUE),
    ('sales_return_quality:correct', '修正销售退货质检结果', '销售管理', '销售退货质检', 216, 'EDIT', '修正尚未终结的销售退货质检结果', TRUE),
    ('sales_return_quality:dispose', '确认销售退货质检处置', '销售管理', '销售退货质检', 217, 'EXECUTE', '确认销售退货质检冻结的处置结果', TRUE),
    ('supplier_return_task:view', '查看本人供应商退回任务', '采购管理', '到货异常', 128, 'VIEW', '查看分配给本人的供应商退回任务', FALSE),
    ('supplier_return_task:complete', '完成供应商退回任务', '采购管理', '到货异常', 129, 'EXECUTE', '登记供应商退回任务完成结果', FALSE),
    ('visitor:verify', '核验访客二维码', '人事行政', '访客', 10, 'VIEW', '核验访客二维码与通行状态', TRUE),
    ('subcontract_outbound:execute', '执行委外出仓计划', '仓库管理', '委外出仓', 250, 'EXECUTE', '生成或补齐委外出仓草稿并执行计划关联发料', TRUE),
    ('subcontract_outbound:close', '关闭委外出仓计划', '仓库管理', '委外出仓', 251, 'EXECUTE', '填写原因并关闭不再执行的委外出仓余量', TRUE),
    ('warehouse_inbound:stock_in', '确认到货异常入库', '仓库管理', '预计到货', 252, 'EXECUTE', '按已确认处置把到货异常货品登记入库', TRUE)
ON CONFLICT (code) DO NOTHING;
-- These compatibility endpoints have no legal staff-page button: direct MRP
-- generation was replaced by atomic planning-package confirmation, while a
-- segment cancel/reverse has no reachable UI window because package lifecycle
-- changes every eligible segment in the same transaction. Keep the codes only
-- for historical grant provenance and super-admin recovery; never offer them.
UPDATE permissions
SET active = FALSE,
    assignable = FALSE,
    name = CASE code
        WHEN 'production_execution:cancel' THEN '历史生产执行段取消接口（已停用）'
        WHEN 'production_execution:reverse' THEN '历史生产执行段冲销接口（已停用）'
        WHEN 'production_mrp:generate_purchase' THEN '历史缺料采购申请生成接口（已停用）'
        WHEN 'production_mrp:generate_draw' THEN '历史生产领料单生成接口（已停用）'
        WHEN 'production_mrp:generate_finished_in' THEN '历史成品入库单生成接口（已停用）'
    END,
    description = CASE code
        WHEN 'production_execution:cancel' THEN
            '计划包取消会在同一事务终结全部合格执行段，本端点没有合法页面调用窗口'
        WHEN 'production_execution:reverse' THEN
            '计划包冲销会在同一事务终结全部合格执行段，本端点没有合法页面调用窗口'
        ELSE '已由正式下达生产计划包的原子下游单据生成取代'
    END
WHERE code IN (
    'production_execution:cancel',
    'production_execution:reverse',
    'production_mrp:generate_purchase',
    'production_mrp:generate_draw',
    'production_mrp:generate_finished_in'
);


-- Clear names for the pre-V328 catalog. Retired composite/zombie rows stay as
-- provenance but are hidden and cannot be newly assigned.
CREATE TEMP TABLE v328_permission_metadata (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    module TEXT,
    category TEXT,
    action_type TEXT NOT NULL,
    description TEXT NOT NULL,
    active BOOLEAN NOT NULL,
    assignable BOOLEAN NOT NULL
) ON COMMIT DROP;

INSERT INTO v328_permission_metadata VALUES
    ('account:edit', '编辑账户资料', NULL, NULL, 'EDIT', '编辑既有账户资料', TRUE, TRUE),
    ('client_category:edit', '编辑客户分类', NULL, NULL, 'EDIT', '编辑既有客户分类', TRUE, TRUE),
    ('client:edit', '编辑客户资料', NULL, NULL, 'EDIT', '编辑既有客户资料', TRUE, TRUE),
    ('color:edit', '编辑颜色资料', NULL, NULL, 'EDIT', '编辑既有颜色资料', TRUE, TRUE),
    ('currency:edit', '编辑币种资料', NULL, NULL, 'EDIT', '编辑既有币种资料', TRUE, TRUE),
    ('goods:edit', '编辑货品资料', NULL, NULL, 'EDIT', '编辑既有货品资料；新增、删除、状态和组装明细使用独立权限', TRUE, TRUE),
    ('material_category:edit', '编辑物料分类', NULL, NULL, 'EDIT', '编辑既有物料分类资料', TRUE, TRUE),
    ('mould_category:edit', '编辑模具分类', NULL, NULL, 'EDIT', '编辑既有模具分类资料', TRUE, TRUE),
    ('mould:edit', '编辑模具资料', NULL, NULL, 'EDIT', '编辑既有模具资料', TRUE, TRUE),
    ('payment_style:edit', '编辑收付款类别', NULL, NULL, 'EDIT', '编辑既有收付款类别；不包含删除', TRUE, TRUE),
    ('supplier_category:edit', '编辑供应商分类', NULL, NULL, 'EDIT', '编辑既有供应商分类资料', TRUE, TRUE),
    ('supplier:edit', '编辑供应商资料', NULL, NULL, 'EDIT', '编辑既有供应商资料', TRUE, TRUE),
    ('unit:edit', '编辑单位资料', NULL, NULL, 'EDIT', '编辑既有单位资料', TRUE, TRUE),
    ('warehouse:edit', '编辑仓库资料', NULL, NULL, 'EDIT', '编辑既有仓库资料', TRUE, TRUE),
    ('finance_asset:edit', '新增、编辑、删除、提交和调拨资产与待摊', NULL, NULL, 'EDIT', '资产与待摊复合草稿权限；本轮未扩大为可转授细权限', TRUE, FALSE),
    ('finance_bank_transfer:edit', '编辑银行存取单草稿', NULL, NULL, 'EDIT', '编辑既有银行存取单草稿', TRUE, TRUE),
    ('finance_expense:edit', '编辑一般费用单草稿', NULL, NULL, 'EDIT', '编辑既有一般费用单草稿', TRUE, TRUE),
    ('finance_other_income:edit', '编辑其他收入单草稿', '财税管理', '其他收入', 'EDIT', '编辑既有其他收入单草稿', TRUE, TRUE),
    ('finance_payment:edit', '编辑采购付款单草稿', NULL, NULL, 'EDIT', '编辑既有采购付款单草稿', TRUE, TRUE),
    ('finance_receipt:edit', '编辑销售收款单草稿', NULL, NULL, 'EDIT', '编辑既有销售收款单草稿', TRUE, TRUE),
    ('production_daily_report:edit', '编辑生产日报草稿', NULL, NULL, 'EDIT', '编辑既有生产日报草稿', TRUE, TRUE),
    ('production_plan:edit', '编辑生产计划草稿', NULL, NULL, 'EDIT', '编辑既有生产计划草稿', TRUE, TRUE),
    ('purchase_order:edit', '编辑采购订货单草稿', NULL, NULL, 'EDIT', '编辑既有采购订货单草稿', TRUE, TRUE),
    ('purchase_receipt:edit', '编辑采购收货单草稿', NULL, NULL, 'EDIT', '编辑既有采购收货单草稿', TRUE, TRUE),
    ('purchase_return:edit', '编辑采购退货单草稿', NULL, NULL, 'EDIT', '编辑既有采购退货单草稿', TRUE, TRUE),
    ('sales_order:edit', '编辑销售订货单草稿', NULL, NULL, 'EDIT', '编辑既有销售订货单草稿', TRUE, TRUE),
    ('sales_other_shipment:edit', '编辑其他出货单草稿', '销售管理', '其他出货', 'EDIT', '编辑既有其他出货单草稿', TRUE, TRUE),
    ('sales_quote:edit', '编辑销售报价单草稿', NULL, NULL, 'EDIT', '编辑既有销售报价单草稿', TRUE, TRUE),
    ('sales_return:edit', '编辑销售退货单草稿', NULL, NULL, 'EDIT', '编辑既有销售退货单草稿', TRUE, TRUE),
    ('sales_shipment:edit', '编辑销售出货单草稿', NULL, NULL, 'EDIT', '编辑既有销售出货单草稿', TRUE, TRUE),
    ('stock_doc:edit', '编辑仓库单据草稿', NULL, NULL, 'EDIT', '编辑既有仓库单据草稿', TRUE, TRUE),
    ('subcontract_inquiry:edit', '编辑委外询价单草稿', NULL, NULL, 'EDIT', '编辑既有委外询价单草稿', TRUE, TRUE),
    ('subcontract_material_issue:edit', '编辑委外材料出仓单草稿', NULL, NULL, 'EDIT', '编辑既有委外材料出仓单草稿', TRUE, TRUE),
    ('subcontract_material_return:edit', '编辑委外材料退货单草稿', NULL, NULL, 'EDIT', '编辑既有委外材料退货单草稿', TRUE, TRUE),
    ('subcontract_order:edit', '编辑委外订货单草稿', NULL, NULL, 'EDIT', '编辑既有委外订货单草稿', TRUE, TRUE),
    ('subcontract_receipt:edit', '编辑委外进仓单草稿', NULL, NULL, 'EDIT', '编辑既有委外进仓单草稿', TRUE, TRUE),
    ('subcontract_return:edit', '编辑委外退货单草稿', NULL, NULL, 'EDIT', '编辑既有委外退货单草稿', TRUE, TRUE),
    ('subcontract_waste:edit', '编辑委外材料损耗单草稿', NULL, NULL, 'EDIT', '编辑既有委外材料损耗单草稿', TRUE, TRUE),
    ('attachment:manage', '历史附件上传删除复合权限（已停用）', NULL, NULL, 'CONFIGURE', '由附件上传和附件删除权限替代', FALSE, FALSE),
    ('attachment:reconcile', '历史附件孤儿对账复合权限（已停用）', NULL, NULL, 'APPROVE', '由查看附件孤儿记录和批准删除权限替代', FALSE, FALSE),
    ('authorization:manage', '配置权限与系统安全策略', NULL, NULL, 'CONFIGURE', '仅超级管理员配置权限、数据范围和系统安全策略', TRUE, FALSE),
    ('finance_asset_period:manage', '关闭或重新打开资产会计期间', NULL, NULL, 'EXECUTE', '关闭或受控重新打开资产会计期间', TRUE, FALSE),
    ('finance_order_approval:review', '历史订货财务审批复合权限（已停用）', NULL, NULL, 'APPROVE', '由批准和驳回订货财务审批权限替代', FALSE, FALSE),
    ('production_material_analysis:manage', '历史物料分析新建刷新复合权限（已停用）', NULL, NULL, 'EXECUTE', '由新建、刷新和取消物料分析权限替代', FALSE, FALSE),
    ('rd_task:edit', '历史研发任务复合权限（已停用）', NULL, NULL, 'ASSIGN', '由新增研发任务和分配研发任务权限替代', FALSE, FALSE),
    ('sales_return_quality:handle', '历史销售退货质检复合权限（已停用）', NULL, NULL, 'EXECUTE', '由修正质检结果和确认质检处置权限替代', FALSE, FALSE),
    ('subcontract_outbound:handle', '历史委外出仓复合权限（已停用）', '仓库管理', '委外出仓', 'EXECUTE', '由执行和关闭委外出仓计划权限替代', FALSE, FALSE),
    ('supplier_return_task:handle', '历史供应商退回任务复合权限（已停用）', NULL, NULL, 'EXECUTE', '由查看和完成供应商退回任务权限替代', FALSE, FALSE),
    ('webinquiry:manage', '历史官网询盘复合权限（已停用）', NULL, NULL, 'EXECUTE', '由认领、关闭和转客户权限替代', FALSE, FALSE),
    ('account:support', '查看、开通、锁定、启停及重置登录账号', NULL, NULL, 'EXECUTE', '账号支持复合权限；仅全局超级管理员可配置', TRUE, FALSE),
    ('finance_asset:approve', '审批资产、待摊、类别及过账批次', NULL, NULL, 'APPROVE', '资产审批复合权限；本轮未扩大为可转授细权限', TRUE, FALSE),
    ('finance_asset:dispose', '发起并审批资产处置或待摊终止', NULL, NULL, 'EXECUTE', '资产处置复合权限；本轮未扩大为可转授细权限', TRUE, FALSE),
    ('finance_asset:post', '启用、过账或红冲资产与待摊', NULL, NULL, 'EXECUTE', '资产过账复合权限；本轮未扩大为可转授细权限', TRUE, FALSE),
    ('finance:view:all', '查看全部财务单据', '财税管理', '数据范围', 'VIEW', '查看公司范围内全部财务单据', TRUE, FALSE),
    ('procurement_inspection:handle', '判定采购或委外待检货品合格或不合格', NULL, NULL, 'EXECUTE', '记录采购或委外收货质检处置结果', TRUE, TRUE),
    ('visitor:blacklist', '将访客加入黑名单', NULL, NULL, 'EXECUTE', '将访客列入黑名单并阻止后续访问', TRUE, TRUE),
    ('visitor:check-in', '办理访客签到', '人事行政', '访客', 'EXECUTE', '把已批准访客登记为已签到', TRUE, TRUE),
    ('goods:bom:audit', '标记或取消组装明细已核对', NULL, NULL, 'APPROVE', '标记或取消货品组装明细的已核对状态', TRUE, TRUE),
    ('stock:balance:adjust', '调整库存余额', NULL, NULL, 'EXECUTE', '以受审计命令调整库存余额', TRUE, FALSE),
    ('lab:test:view', '查看检测记录', NULL, NULL, 'VIEW', '查看品质检测记录', TRUE, TRUE),
    ('lab:test:upload', '上传检测记录', NULL, NULL, 'IMPORT', '上传品质检测记录', TRUE, TRUE),
    ('employee:create', '办理员工入职', NULL, NULL, 'CREATE', '办理员工入职并建立员工档案', TRUE, TRUE),
    ('employee:export', '打印或导出员工资料（花名册、架构图）', NULL, NULL, 'EXPORT', '打印或导出花名册和部门架构图', TRUE, TRUE),
    ('expense:apply', '提交报销申请', NULL, NULL, 'EXECUTE', '提交本人报销申请', TRUE, TRUE),
    ('visitor:approve', '审批访客申请', NULL, NULL, 'APPROVE', '批准或驳回访客申请', TRUE, TRUE),
    ('visitor:host-confirm', '被访人确认访客申请', NULL, NULL, 'APPROVE', '由被访人确认访客申请', TRUE, TRUE),
    ('sales_shipment:warehouse-work', '推进销售出货拣货状态', NULL, NULL, 'EXECUTE', '开始、完成或登记销售出货拣货异常', TRUE, TRUE),
    ('finance_shipment_audit', '财务审核或驳回销售出货单', NULL, NULL, 'APPROVE', '财务审核或驳回销售出货单', TRUE, TRUE),
    ('sales_order:change_planned', '确认修改数量或取消已排产订单', NULL, NULL, 'APPROVE', '确认涉及已排产订单的改量或取消', TRUE, TRUE),
    ('production_plan_cost:view', '查看生产计划 BOM 展开', NULL, NULL, 'VIEW', '查看生产计划的 BOM 展开结果', TRUE, TRUE),
    ('attachment:view', '查看附件列表', NULL, NULL, 'VIEW', '查看有权访问的附件列表；下载使用独立权限', TRUE, TRUE),
    ('webinquiry:view', '查看官网询盘', NULL, NULL, 'VIEW', '查看官网询盘列表和详情', TRUE, TRUE),
    ('stock:view', '查看库存余额、即时库存及出入库流水', NULL, NULL, 'VIEW', '查看库存余额、即时库存和出入库流水', TRUE, TRUE),
    ('user:manage', '历史账号复合权限（已停用）', NULL, NULL, 'CONFIGURE', '历史角色权限，已由现行账号支持和授权策略替代', FALSE, FALSE),
    ('viewcontext:scoped', '历史视角切换权限（已停用）', NULL, NULL, 'CONFIGURE', '当前运行时没有消费者', FALSE, FALSE),
    ('inventory:view', '历史库存查看权限（已停用）', NULL, NULL, 'VIEW', '由 stock:view 替代', FALSE, FALSE),
    ('stock:edit', '历史库存编辑权限（已停用）', NULL, NULL, 'EDIT', '当前运行时没有消费者', FALSE, FALSE),
    ('purchase_request:edit', '历史采购申请编辑权限（已停用）', NULL, NULL, 'EDIT', '采购申请当前为计划下达的只读事实', FALSE, FALSE),
    ('subcontract_application:edit', '历史委外申请编辑权限（已停用）', NULL, NULL, 'EDIT', '委外申请当前为计划下达的只读事实', FALSE, FALSE),
    ('production:view', '历史宽泛生产查看权限（已停用）', '生产管理', '生产计划', 'VIEW', '由具体生产页面查看权限替代', FALSE, FALSE);

UPDATE permissions permission
SET name = patch.name,
    module = COALESCE(patch.module, permission.module),
    category = COALESCE(patch.category, permission.category),
    action_type = patch.action_type,
    description = patch.description,
    active = patch.active,
    assignable = patch.assignable,
    updated_at = now()
FROM v328_permission_metadata patch
WHERE permission.code = patch.code;

UPDATE permissions
SET module = '仓库管理',
    category = '委外出仓'
WHERE code IN ('subcontract_outbound:view', 'subcontract_outbound:handle');

UPDATE permissions
SET category = '其他出货'
WHERE category = '其它出货';

UPDATE permissions
SET category = '其他收入'
WHERE category = '其它收入';

-- Every pre-V328 catalog code is classified explicitly. Unknown target-only
-- codes fail closed instead of being guessed from a suffix.
CREATE TEMP TABLE v328_explicit_action_type (
    code TEXT PRIMARY KEY,
    action_type TEXT NOT NULL
) ON COMMIT DROP;

INSERT INTO v328_explicit_action_type (code, action_type) VALUES
    ('account:edit', 'EDIT'),
    ('account:export', 'EXPORT'),
    ('account:support', 'EXECUTE'),
    ('account:view', 'VIEW'),
    ('ar_ap_ledger:view', 'VIEW'),
    ('attachment:manage', 'CONFIGURE'),
    ('attachment:reconcile', 'EXECUTE'),
    ('attachment:view', 'VIEW'),
    ('audit_log:export', 'EXPORT'),
    ('audit_log:view', 'VIEW'),
    ('authorization:manage', 'CONFIGURE'),
    ('client_address:delete', 'DELETE'),
    ('client_category:edit', 'EDIT'),
    ('client_category:view', 'VIEW'),
    ('client:edit', 'EDIT'),
    ('client:export', 'EXPORT'),
    ('client:view', 'VIEW'),
    ('client:view:all', 'VIEW'),
    ('color:edit', 'EDIT'),
    ('color:view', 'VIEW'),
    ('currency:edit', 'EDIT'),
    ('currency:export', 'EXPORT'),
    ('currency:view', 'VIEW'),
    ('dashboard:finance-sensitive:view', 'VIEW'),
    ('department:edit', 'EDIT'),
    ('department:view', 'VIEW'),
    ('employee:compensation:edit', 'EDIT'),
    ('employee:compensation:view', 'VIEW'),
    ('employee:create', 'CREATE'),
    ('employee:edit', 'EDIT'),
    ('employee:export', 'EXPORT'),
    ('employee:pii:edit', 'EDIT'),
    ('employee:pii:view', 'VIEW'),
    ('employee:view', 'VIEW'),
    ('expense:apply', 'EXECUTE'),
    ('expense:approve', 'APPROVE'),
    ('expense:pay', 'EXECUTE'),
    ('finance_asset_period:manage', 'EXECUTE'),
    ('finance_asset:approve', 'APPROVE'),
    ('finance_asset:dispose', 'EXECUTE'),
    ('finance_asset:edit', 'EDIT'),
    ('finance_asset:export', 'EXPORT'),
    ('finance_asset:post', 'EXECUTE'),
    ('finance_asset:view', 'VIEW'),
    ('finance_bank_transfer:edit', 'EDIT'),
    ('finance_bank_transfer:view', 'VIEW'),
    ('finance_expense:edit', 'EDIT'),
    ('finance_expense:view', 'VIEW'),
    ('finance_order_approval:review', 'APPROVE'),
    ('finance_order_approval:view', 'VIEW'),
    ('finance_other_income:edit', 'EDIT'),
    ('finance_other_income:view', 'VIEW'),
    ('finance_payment:edit', 'EDIT'),
    ('finance_payment:view', 'VIEW'),
    ('finance_post:execute', 'EXECUTE'),
    ('finance_receipt:edit', 'EDIT'),
    ('finance_receipt:view', 'VIEW'),
    ('finance_reconciliation:view', 'VIEW'),
    ('finance_report:export', 'EXPORT'),
    ('finance_report:view', 'VIEW'),
    ('finance_shipment_audit', 'APPROVE'),
    ('finance:view:all', 'VIEW'),
    ('goods:bom:audit', 'APPROVE'),
    ('goods:cost:view', 'VIEW'),
    ('goods:discount:view', 'VIEW'),
    ('goods:edit', 'EDIT'),
    ('goods:export', 'EXPORT'),
    ('goods:import', 'IMPORT'),
    ('goods:price:edit', 'EDIT'),
    ('goods:view', 'VIEW'),
    ('goods:view:all', 'VIEW'),
    ('inventory:view', 'VIEW'),
    ('lab:test:upload', 'IMPORT'),
    ('lab:test:view', 'VIEW'),
    ('material_category:edit', 'EDIT'),
    ('material_category:view', 'VIEW'),
    ('mould_category:edit', 'EDIT'),
    ('mould_category:view', 'VIEW'),
    ('mould:edit', 'EDIT'),
    ('mould:view', 'VIEW'),
    ('notice:publish', 'EXECUTE'),
    ('notice:read', 'VIEW'),
    ('payment_style:edit', 'EDIT'),
    ('payment_style:view', 'VIEW'),
    ('payroll:export', 'EXPORT'),
    ('payroll:generate', 'EXECUTE'),
    ('payroll:publish', 'EXECUTE'),
    ('payroll:review', 'APPROVE'),
    ('payroll:view:all', 'VIEW'),
    ('payroll:view:self', 'VIEW'),
    ('planning_supply_request:view', 'VIEW'),
    ('procurement_inspection:handle', 'EXECUTE'),
    ('procurement_inspection:view', 'VIEW'),
    ('production_daily_report:edit', 'EDIT'),
    ('production_daily_report:view', 'VIEW'),
    ('production_material_analysis:bom_override', 'EXECUTE'),
    ('production_material_analysis:cross_reallocate', 'EXECUTE'),
    ('production_material_analysis:generate', 'EXECUTE'),
    ('production_material_analysis:manage', 'EXECUTE'),
    ('production_material_analysis:notify', 'EXECUTE'),
    ('production_material_analysis:reallocate', 'EXECUTE'),
    ('production_material_analysis:route', 'EXECUTE'),
    ('production_material_analysis:view', 'VIEW'),
    ('production_plan_cost:view', 'VIEW'),
    ('production_plan:approve', 'APPROVE'),
    ('production_plan:batchApprove', 'APPROVE'),
    ('production_plan:batchDelete', 'DELETE'),
    ('production_plan:edit', 'EDIT'),
    ('production_plan:forward_rd', 'EXECUTE'),
    ('production_plan:view', 'VIEW'),
    ('production_plan:view:all', 'VIEW'),
    ('production_report:export', 'EXPORT'),
    ('production_report:view', 'VIEW'),
    ('production_where_used:view', 'VIEW'),
    ('production:view', 'VIEW'),
    ('profile:edit:self', 'EDIT'),
    ('profile:review', 'APPROVE'),
    ('purchase_order:edit', 'EDIT'),
    ('purchase_order:submit_finance', 'EXECUTE'),
    ('purchase_order:view', 'VIEW'),
    ('purchase_receipt:edit', 'EDIT'),
    ('purchase_receipt:price:view', 'VIEW'),
    ('purchase_receipt:view', 'VIEW'),
    ('purchase_report:export', 'EXPORT'),
    ('purchase_report:view', 'VIEW'),
    ('purchase_request:edit', 'EDIT'),
    ('purchase_request:view', 'VIEW'),
    ('purchase_return:edit', 'EDIT'),
    ('purchase_return:view', 'VIEW'),
    ('purchase:view:all', 'VIEW'),
    ('rd_task:edit', 'ASSIGN'),
    ('rd_task:resolve', 'EXECUTE'),
    ('rd_task:view', 'VIEW'),
    ('sales_order_finance:confirm', 'APPROVE'),
    ('sales_order_finance:view', 'VIEW'),
    ('sales_order:change_planned', 'APPROVE'),
    ('sales_order:confirm_partial_shipment', 'EXECUTE'),
    ('sales_order:edit', 'EDIT'),
    ('sales_order:price:view', 'VIEW'),
    ('sales_order:priority', 'EXECUTE'),
    ('sales_order:reallocate', 'EXECUTE'),
    ('sales_order:view', 'VIEW'),
    ('sales_other_shipment:edit', 'EDIT'),
    ('sales_other_shipment:view', 'VIEW'),
    ('sales_quote:edit', 'EDIT'),
    ('sales_quote:view', 'VIEW'),
    ('sales_report:export', 'EXPORT'),
    ('sales_report:view', 'VIEW'),
    ('sales_return_quality:handle', 'EXECUTE'),
    ('sales_return_quality:view', 'VIEW'),
    ('sales_return:disposition', 'EXECUTE'),
    ('sales_return:edit', 'EDIT'),
    ('sales_return:view', 'VIEW'),
    ('sales_shipment:edit', 'EDIT'),
    ('sales_shipment:reject', 'EXECUTE'),
    ('sales_shipment:view', 'VIEW'),
    ('sales_shipment:warehouse-work', 'EXECUTE'),
    ('sales:view:all', 'VIEW'),
    ('stock_doc:edit', 'EDIT'),
    ('stock_doc:view', 'VIEW'),
    ('stock_doc:view:all', 'VIEW'),
    ('stock_report:export', 'EXPORT'),
    ('stock_report:view', 'VIEW'),
    ('stock:balance:adjust', 'EXECUTE'),
    ('stock:edit', 'EDIT'),
    ('stock:view', 'VIEW'),
    ('subcontract_application:edit', 'EDIT'),
    ('subcontract_application:view', 'VIEW'),
    ('subcontract_inquiry:edit', 'EDIT'),
    ('subcontract_inquiry:view', 'VIEW'),
    ('subcontract_material_issue:edit', 'EDIT'),
    ('subcontract_material_issue:view', 'VIEW'),
    ('subcontract_material_return:edit', 'EDIT'),
    ('subcontract_material_return:view', 'VIEW'),
    ('subcontract_order:edit', 'EDIT'),
    ('subcontract_order:submit_finance', 'EXECUTE'),
    ('subcontract_order:view', 'VIEW'),
    ('subcontract_outbound:handle', 'EXECUTE'),
    ('subcontract_outbound:view', 'VIEW'),
    ('subcontract_receipt:edit', 'EDIT'),
    ('subcontract_receipt:price:view', 'VIEW'),
    ('subcontract_receipt:view', 'VIEW'),
    ('subcontract_report:export', 'EXPORT'),
    ('subcontract_report:view', 'VIEW'),
    ('subcontract_return:edit', 'EDIT'),
    ('subcontract_return:view', 'VIEW'),
    ('subcontract_waste:edit', 'EDIT'),
    ('subcontract_waste:view', 'VIEW'),
    ('subcontract:view:all', 'VIEW'),
    ('suggestion:reply', 'EXECUTE'),
    ('suggestion:submit', 'EXECUTE'),
    ('supplier_category:edit', 'EDIT'),
    ('supplier_category:view', 'VIEW'),
    ('supplier_return_task:handle', 'EXECUTE'),
    ('supplier:edit', 'EDIT'),
    ('supplier:export', 'EXPORT'),
    ('supplier:view', 'VIEW'),
    ('unit:edit', 'EDIT'),
    ('unit:view', 'VIEW'),
    ('user:manage', 'CONFIGURE'),
    ('viewcontext:scoped', 'CONFIGURE'),
    ('visitor:apply', 'EXECUTE'),
    ('visitor:approve', 'APPROVE'),
    ('visitor:blacklist', 'EXECUTE'),
    ('visitor:check-in', 'EXECUTE'),
    ('visitor:host-confirm', 'APPROVE'),
    ('visitor:view', 'VIEW'),
    ('warehouse_inbound:view', 'VIEW'),
    ('warehouse:edit', 'EDIT'),
    ('warehouse:view', 'VIEW'),
    ('webinquiry:manage', 'EXECUTE'),
    ('webinquiry:view', 'VIEW');

UPDATE permissions permission
SET action_type = classification.action_type
FROM v328_explicit_action_type classification
WHERE permission.code = classification.code
  AND permission.action_type IS NULL;

UPDATE permissions
SET description = '允许：' || name
WHERE description IS NULL;

UPDATE permissions
SET active = FALSE,
    assignable = FALSE,
    description = '当前运行时没有消费者；保留目录行仅供迁移与审计追溯'
WHERE code IN (
    'lab:test:view',
    'lab:test:upload',
    'planning_supply_request:view',
    'production_plan_cost:view',
    'rd_task:create',
    'rd_task:assign'
);

DO $$
DECLARE
    missing_codes TEXT;
BEGIN
    SELECT string_agg(code, ', ' ORDER BY code)
    INTO missing_codes
    FROM permissions
    WHERE action_type IS NULL OR description IS NULL;

    IF missing_codes IS NOT NULL THEN
        RAISE EXCEPTION
            'V328 permission catalog contains unclassified codes: %',
            missing_codes;
    END IF;
END;
$$;

ALTER TABLE permissions
    ALTER COLUMN action_type SET NOT NULL,
    ALTER COLUMN description SET NOT NULL;

ALTER TABLE permissions
    VALIDATE CONSTRAINT permissions_action_type_chk;

CREATE INDEX idx_permissions_active_catalog
    ON permissions(module, category, sort_order, code)
    WHERE active = TRUE;
CREATE INDEX idx_permissions_active_assignable
    ON permissions(assignable, code)
    WHERE active = TRUE;

-- Explicit compatibility matrix. A row means that every active authorization
-- source for old_code represented all capabilities now guarded by new_code.
-- Mutable names, modules and suffix heuristics are intentionally not used.
CREATE TEMP TABLE v328_permission_expansion (
    old_code TEXT NOT NULL,
    new_code TEXT NOT NULL,
    PRIMARY KEY (old_code, new_code)
) ON COMMIT DROP;

INSERT INTO v328_permission_expansion (old_code, new_code) VALUES
    -- Basic-data category trees.
    ('material_category:edit', 'material_category:create'),
    ('material_category:edit', 'material_category:delete'),
    ('material_category:edit', 'material_category:move'),
    ('material_category:edit', 'material_category:reorder'),
    ('mould_category:edit', 'mould_category:create'),
    ('mould_category:edit', 'mould_category:delete'),
    ('mould_category:edit', 'mould_category:move'),
    ('mould_category:edit', 'mould_category:reorder'),
    ('client_category:edit', 'client_category:create'),
    ('client_category:edit', 'client_category:delete'),
    ('client_category:edit', 'client_category:move'),
    ('client_category:edit', 'client_category:reorder'),
    ('supplier_category:edit', 'supplier_category:create'),
    ('supplier_category:edit', 'supplier_category:delete'),
    ('supplier_category:edit', 'supplier_category:move'),
    ('supplier_category:edit', 'supplier_category:reorder'),

    -- Basic-data entities and inline dictionaries.
    ('goods:edit', 'goods:create'),
    ('goods:edit', 'goods:delete'),
    ('goods:edit', 'goods:status'),
    ('goods:edit', 'goods:bom:create'),
    ('goods:edit', 'goods:bom:edit'),
    ('goods:edit', 'goods:bom:delete'),
    ('goods:import', 'goods:import:undo'),
    ('mould:edit', 'mould:create'),
    ('mould:edit', 'mould:delete'),
    ('mould:edit', 'mould:status'),
    ('client:edit', 'client:create'),
    ('client:edit', 'client:delete'),
    ('client:edit', 'client:status'),
    ('client:edit', 'client_address:create'),
    ('sales_shipment:edit', 'client_address:create'),
    ('sales_other_shipment:edit', 'client_address:create'),
    ('supplier:edit', 'supplier:create'),
    ('supplier:edit', 'supplier:delete'),
    ('supplier:edit', 'supplier:status'),
    ('color:edit', 'color:create'),
    ('color:edit', 'color:delete'),
    ('color:edit', 'color:status'),
    ('unit:edit', 'unit:create'),
    ('unit:edit', 'unit:delete'),
    ('unit:edit', 'unit:status'),
    ('currency:edit', 'currency:create'),
    ('currency:edit', 'currency:delete'),
    ('currency:edit', 'currency:status'),
    ('warehouse:edit', 'warehouse:create'),
    ('warehouse:edit', 'warehouse:delete'),
    ('warehouse:edit', 'warehouse:status'),
    ('account:edit', 'account:create'),
    ('account:edit', 'account:delete'),
    ('account:edit', 'account:status'),
    ('payment_style:edit', 'payment_style:create'),
    ('payment_style:edit', 'payment_style:status'),
    ('payment_style:edit', 'payment_style:move'),
    ('payment_style:edit', 'payment_style:reorder'),
    ('payment_style:edit', 'settlement_method:create'),

    -- Sales, purchase, warehouse and production documents.
    ('sales_quote:edit', 'sales_quote:create'),
    ('sales_quote:edit', 'sales_quote:delete'),
    ('sales_quote:edit', 'sales_quote:approve'),
    ('sales_quote:edit', 'sales_quote:reverse'),
    ('sales_quote:edit', 'sales_quote:convert'),
    ('sales_order:edit', 'sales_order:create'),
    ('sales_order:edit', 'sales_order:delete'),
    ('sales_order:edit', 'sales_order:approve'),
    ('sales_order:edit', 'sales_order:reverse'),
    ('sales_order:edit', 'sales_order:stop'),
    ('sales_order:edit', 'sales_order:change_qty'),
    ('sales_order:edit', 'sales_order:cancel'),
    ('sales_shipment:edit', 'sales_shipment:create'),
    ('sales_shipment:edit', 'sales_shipment:delete'),
    ('sales_shipment:edit', 'sales_shipment:approve'),
    ('sales_shipment:edit', 'sales_shipment:reverse'),
    ('sales_other_shipment:edit', 'sales_other_shipment:create'),
    ('sales_other_shipment:edit', 'sales_other_shipment:delete'),
    ('sales_other_shipment:edit', 'sales_other_shipment:approve'),
    ('sales_other_shipment:edit', 'sales_other_shipment:reverse'),
    ('sales_return:edit', 'sales_return:create'),
    ('sales_return:edit', 'sales_return:delete'),
    ('sales_return:edit', 'sales_return:approve'),
    ('sales_return:edit', 'sales_return:reverse'),
    ('purchase_order:edit', 'purchase_order:create'),
    ('purchase_order:edit', 'purchase_order:delete'),
    ('purchase_order:edit', 'purchase_order:reverse'),
    ('purchase_order:edit', 'purchase_order:decompose'),
    ('purchase_receipt:edit', 'purchase_receipt:create'),
    ('purchase_receipt:edit', 'purchase_receipt:delete'),
    ('purchase_receipt:edit', 'purchase_receipt:approve'),
    ('purchase_receipt:edit', 'purchase_receipt:reverse'),
    ('purchase_return:edit', 'purchase_return:create'),
    ('purchase_return:edit', 'purchase_return:delete'),
    ('purchase_return:edit', 'purchase_return:approve'),
    ('purchase_return:edit', 'purchase_return:reverse'),
    ('stock_doc:edit', 'stock_doc:create'),
    ('stock_doc:edit', 'stock_doc:delete'),
    ('stock_doc:edit', 'stock_doc:approve'),
    ('stock_doc:edit', 'stock_doc:reverse'),
    ('stock_doc:edit', 'stock_doc:issue'),
    ('stock_doc:edit', 'stock_doc:reverse_issue'),
    ('production_daily_report:edit', 'production_daily_report:create'),
    ('production_daily_report:edit', 'production_daily_report:delete'),
    ('production_daily_report:edit', 'production_daily_report:approve'),
    ('production_daily_report:edit', 'production_daily_report:reverse'),
    ('production_plan:edit', 'production_plan:delete'),
    ('production_plan:edit', 'production_plan:reverse'),
    ('production_plan:edit', 'production_plan:flags'),
    ('production_plan:edit', 'production_execution:assign'),
    ('production_plan:edit', 'production_execution:release_defer'),
    ('production_plan:edit', 'production_execution:dispatch'),
    ('production_plan:edit', 'production_execution:start'),
    ('production_plan:edit', 'production_execution:cancel'),
    ('production_plan:edit', 'production_execution:reverse'),
    ('production_plan:edit', 'production_mrp:generate_purchase'),
    ('production_plan:edit', 'production_mrp:generate_draw'),
    ('production_plan:edit', 'production_mrp:generate_finished_in'),
    ('production_plan:edit', 'production_planning_package:generate'),
    ('production_plan:edit', 'production_planning_package:draft_edit'),
    ('production_plan:edit', 'production_planning_package:cancel'),
    ('production_plan:edit', 'production_planning_package:reverse'),
    ('production_plan:edit', 'production_material:settle'),
    ('production_plan:edit', 'production_material:reverse'),
    ('production_plan:edit', 'production_material:close'),

    -- Subcontract and finance documents.
    ('subcontract_inquiry:edit', 'subcontract_inquiry:create'),
    ('subcontract_inquiry:edit', 'subcontract_inquiry:delete'),
    ('subcontract_inquiry:edit', 'subcontract_inquiry:approve'),
    ('subcontract_inquiry:edit', 'subcontract_inquiry:reverse'),
    ('subcontract_order:edit', 'subcontract_order:create'),
    ('subcontract_order:edit', 'subcontract_order:delete'),
    ('subcontract_order:edit', 'subcontract_order:reverse'),
    ('subcontract_order:edit', 'subcontract_order:decompose'),
    ('subcontract_receipt:edit', 'subcontract_receipt:create'),
    ('subcontract_receipt:edit', 'subcontract_receipt:delete'),
    ('subcontract_receipt:edit', 'subcontract_receipt:approve'),
    ('subcontract_receipt:edit', 'subcontract_receipt:reverse'),
    ('subcontract_material_issue:edit', 'subcontract_material_issue:create'),
    ('subcontract_material_issue:edit', 'subcontract_material_issue:delete'),
    ('subcontract_material_issue:edit', 'subcontract_material_issue:approve'),
    ('subcontract_material_issue:edit', 'subcontract_material_issue:reverse'),
    ('subcontract_return:edit', 'subcontract_return:create'),
    ('subcontract_return:edit', 'subcontract_return:delete'),
    ('subcontract_return:edit', 'subcontract_return:approve'),
    ('subcontract_return:edit', 'subcontract_return:reverse'),
    ('subcontract_material_return:edit', 'subcontract_material_return:create'),
    ('subcontract_material_return:edit', 'subcontract_material_return:delete'),
    ('subcontract_material_return:edit', 'subcontract_material_return:approve'),
    ('subcontract_material_return:edit', 'subcontract_material_return:reverse'),
    ('subcontract_waste:edit', 'subcontract_waste:create'),
    ('subcontract_waste:edit', 'subcontract_waste:delete'),
    ('subcontract_waste:edit', 'subcontract_waste:approve'),
    ('subcontract_waste:edit', 'subcontract_waste:reverse'),
    ('finance_receipt:edit', 'finance_receipt:create'),
    ('finance_receipt:edit', 'finance_receipt:delete'),
    ('finance_receipt:edit', 'finance_receipt:approve'),
    ('finance_receipt:edit', 'finance_receipt:reverse'),
    ('finance_payment:edit', 'finance_payment:create'),
    ('finance_payment:edit', 'finance_payment:delete'),
    ('finance_payment:edit', 'finance_payment:approve'),
    ('finance_payment:edit', 'finance_payment:reverse'),
    ('finance_expense:edit', 'finance_expense:create'),
    ('finance_expense:edit', 'finance_expense:delete'),
    ('finance_expense:edit', 'finance_expense:approve'),
    ('finance_expense:edit', 'finance_expense:reverse'),
    ('finance_expense:edit', 'finance_expense:gl_confirm'),
    ('finance_other_income:edit', 'finance_other_income:create'),
    ('finance_other_income:edit', 'finance_other_income:delete'),
    ('finance_other_income:edit', 'finance_other_income:approve'),
    ('finance_other_income:edit', 'finance_other_income:reverse'),
    ('finance_bank_transfer:edit', 'finance_bank_transfer:create'),
    ('finance_bank_transfer:edit', 'finance_bank_transfer:delete'),
    ('finance_bank_transfer:edit', 'finance_bank_transfer:approve'),
    ('finance_bank_transfer:edit', 'finance_bank_transfer:reverse'),

    -- Organization and previously composite specialist actions.
    ('department:edit', 'department:create'),
    ('department:edit', 'department:delete'),
    ('department:edit', 'department:move'),
    ('department:edit', 'department:manager_assign'),
    ('department:edit', 'position:create'),
    ('department:edit', 'position:edit'),
    ('department:edit', 'position:delete'),
    ('employee:edit', 'employee:transfer'),
    ('employee:edit', 'employee:offboard'),
    ('employee:edit', 'employee:confirm'),
    ('employee:edit', 'employee:rehire'),
    ('employee:edit', 'employee:contract_renew'),
    ('employee:edit', 'employee:avatar_edit'),
    ('employee:edit', 'employee:task_takeover'),
    ('attachment:view', 'attachment:download'),
    ('attachment:manage', 'attachment:upload'),
    ('attachment:manage', 'attachment:delete'),
    ('attachment:reconcile', 'attachment:reconcile:view'),
    ('attachment:reconcile', 'attachment:reconcile:approve_delete'),
    ('finance_order_approval:review', 'finance_order_approval:approve'),
    ('finance_order_approval:review', 'finance_order_approval:reject'),
    ('production_material_analysis:manage', 'production_material_analysis:create'),
    ('production_material_analysis:manage', 'production_material_analysis:refresh'),
    ('production_material_analysis:manage', 'production_material_analysis:cancel'),
    ('rd_task:edit', 'rd_task:create'),
    ('rd_task:edit', 'rd_task:assign'),
    ('sales_return_quality:handle', 'sales_return_quality:correct'),
    ('sales_return_quality:handle', 'sales_return_quality:dispose'),
    ('subcontract_outbound:handle', 'subcontract_outbound:execute'),
    ('subcontract_outbound:handle', 'subcontract_outbound:close'),
    ('supplier_return_task:handle', 'supplier_return_task:view'),
    ('supplier_return_task:handle', 'supplier_return_task:complete'),
    ('webinquiry:manage', 'webinquiry:claim'),
    ('webinquiry:manage', 'webinquiry:close'),
    ('webinquiry:manage', 'webinquiry:convert_client'),
    ('visitor:check-in', 'visitor:verify'),
    ('warehouse_inbound:view', 'warehouse_inbound:stock_in'),
    ('inventory:view', 'stock:view');

-- 1/4: role grants. Duplicate target grants are already equivalent.
INSERT INTO role_permissions (role_id, permission_id)
SELECT DISTINCT source.role_id, target_permission.id
FROM role_permissions source
JOIN permissions old_permission
  ON old_permission.id = source.permission_id
JOIN v328_permission_expansion expansion
  ON expansion.old_code = old_permission.code
JOIN permissions target_permission
  ON target_permission.code = expansion.new_code
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- 2/4: department grants, retaining the original actor/time provenance when a
-- target row is absent. A pre-existing target row wins on a PK collision.
INSERT INTO department_permissions (
    department_id, permission_id, created_at, created_by
)
SELECT DISTINCT ON (source.department_id, target_permission.id)
       source.department_id,
       target_permission.id,
       source.created_at,
       source.created_by
FROM department_permissions source
JOIN permissions old_permission
  ON old_permission.id = source.permission_id
JOIN v328_permission_expansion expansion
  ON expansion.old_code = old_permission.code
JOIN permissions target_permission
  ON target_permission.code = expansion.new_code
ORDER BY source.department_id,
         target_permission.id,
         source.created_at,
         old_permission.code
ON CONFLICT (department_id, permission_id) DO NOTHING;

-- Rank active central sources once per target. revoke wins over grant; within
-- the same effect, confirmed central provenance and the highest CAS version win.
-- Inactive V327 tombstones are neutral and never become grants or revokes.
CREATE TEMP TABLE v328_override_expansion
ON COMMIT DROP AS
SELECT DISTINCT ON (source.user_id, target_permission.id)
       source.user_id,
       target_permission.id AS permission_id,
       source.effect,
       source.authority_source,
       source.source_actor_user_id,
       source.row_version
FROM user_permission_overrides source
JOIN permissions old_permission
  ON old_permission.id = source.permission_id
JOIN v328_permission_expansion expansion
  ON expansion.old_code = old_permission.code
JOIN permissions target_permission
  ON target_permission.code = expansion.new_code
WHERE source.active = TRUE
ORDER BY source.user_id,
         target_permission.id,
         CASE source.effect WHEN 'revoke' THEN 0 ELSE 1 END,
         CASE source.authority_source
             WHEN 'SUPER_ADMIN_CONFIRMED' THEN 0 ELSE 1
         END,
         source.row_version DESC,
         old_permission.code;

-- 3/4: active personal grant/revoke. Existing active target decisions win,
-- except that a migrated revoke must replace an active grant. An inactive
-- target tombstone is reactivated with a monotonic version advance.
INSERT INTO user_permission_overrides AS target (
    user_id,
    permission_id,
    effect,
    authority_source,
    source_actor_user_id,
    row_version,
    active
)
SELECT source.user_id,
       source.permission_id,
       source.effect,
       source.authority_source,
       source.source_actor_user_id,
       source.row_version,
       TRUE
FROM v328_override_expansion source
ON CONFLICT (user_id, permission_id) DO UPDATE
SET effect = EXCLUDED.effect,
    authority_source = EXCLUDED.authority_source,
    source_actor_user_id = EXCLUDED.source_actor_user_id,
    row_version = GREATEST(target.row_version, EXCLUDED.row_version) + 1,
    active = TRUE
WHERE target.active = FALSE
   OR (target.effect = 'grant' AND EXCLUDED.effect = 'revoke');

-- Shared definitions and direct decisions have changed. The epoch invalidates
-- every access-token authorization snapshot; the per-user version advance and
-- refresh-token family revocation follow the existing administrative session
-- invalidation mechanism. A taxonomy migration is intentionally a global
-- reauthentication boundary rather than trying to infer every role/department
-- descendant affected by a historical composite code.
UPDATE authorization_state
SET epoch = epoch + 1,
    updated_at = CURRENT_TIMESTAMP
WHERE singleton_id = 1;

UPDATE users
SET auth_version = auth_version + 1;

UPDATE refresh_tokens
SET revoked_at = CURRENT_TIMESTAMP
WHERE revoked_at IS NULL;

-- Choose one deterministic, formerly-effective source when several old codes
-- collapse onto the same delegation PK. Existing target rows (including
-- disabled history) win and are never overwritten or reactivated.
CREATE TEMP TABLE v328_manager_delegation_expansion
ON COMMIT DROP AS
SELECT DISTINCT ON (
           source.user_id,
           target_permission.id,
           source.department_id
       )
       source.user_id,
       target_permission.id AS permission_id,
       source.department_id,
       source.surface_key,
       source.granted_by_user_id,
       source.row_version,
       source.created_at,
       source.updated_at,
       source.created_by,
       source.updated_by,
       source.target_employee_generation,
       source.target_department_generation,
       source.grantor_employee_generation,
       source.scope_source,
       source.scope_department_id,
       source.scope_generation,
       source.scope_assignment_id,
       source.scope_assignment_version
FROM v328_effective_manager_delegation_source source
JOIN permissions old_permission
  ON old_permission.id = source.permission_id
JOIN v328_permission_expansion expansion
  ON expansion.old_code = old_permission.code
JOIN permissions target_permission
  ON target_permission.code = expansion.new_code
WHERE NOT EXISTS (
    SELECT 1
    FROM manager_permission_delegations existing
    WHERE existing.user_id = source.user_id
      AND existing.permission_id = target_permission.id
      AND existing.department_id = source.department_id
)
ORDER BY source.user_id,
         target_permission.id,
         source.department_id,
         source.row_version DESC,
         source.updated_at DESC,
         old_permission.code;

-- 4/4: manager grants. Employee/department/scope snapshots are copied exactly.
-- User generations, grantor auth_version and the shared epoch are rebased to
-- this migration's equivalent authorization state so copied grants stay valid.
-- incoming.auth_bumps predicts the row trigger increments when a grantor is
-- also the target of one or more copied delegations in this same statement.
WITH incoming AS (
    SELECT user_id, count(*)::BIGINT AS auth_bumps
    FROM v328_manager_delegation_expansion
    GROUP BY user_id
)
INSERT INTO manager_permission_delegations (
    user_id,
    permission_id,
    department_id,
    enabled,
    surface_key,
    granted_by_user_id,
    row_version,
    created_at,
    updated_at,
    created_by,
    updated_by,
    target_user_generation,
    target_employee_generation,
    target_department_generation,
    grantor_user_generation,
    grantor_employee_generation,
    grantor_auth_version,
    grantor_authorization_epoch,
    scope_source,
    scope_department_id,
    scope_generation,
    scope_assignment_id,
    scope_assignment_version
)
SELECT source.user_id,
       source.permission_id,
       source.department_id,
       TRUE,
       source.surface_key,
       source.granted_by_user_id,
       source.row_version,
       source.created_at,
       source.updated_at,
       source.created_by,
       source.updated_by,
       target_user.permission_delegation_generation,
       source.target_employee_generation,
       source.target_department_generation,
       grantor_user.permission_delegation_generation,
       source.grantor_employee_generation,
       grantor_user.auth_version + COALESCE(grantor_incoming.auth_bumps, 0),
       auth_state.epoch,
       source.scope_source,
       source.scope_department_id,
       source.scope_generation,
       source.scope_assignment_id,
       source.scope_assignment_version
FROM v328_manager_delegation_expansion source
JOIN users target_user
  ON target_user.id = source.user_id
JOIN users grantor_user
  ON grantor_user.id = source.granted_by_user_id
LEFT JOIN incoming grantor_incoming
  ON grantor_incoming.user_id = source.granted_by_user_id
CROSS JOIN authorization_state auth_state
WHERE auth_state.singleton_id = 1
ON CONFLICT (user_id, permission_id, department_id) DO NOTHING;
-- The page-permission directory is persisted after the action catalog is
-- complete so every legacy exact/prefix rule can be expanded once against the
-- final V328 code set. Runtime code must read only the exact junction rows.
CREATE TABLE permission_surfaces (
    id          UUID PRIMARY KEY,
    surface_key VARCHAR(128) NOT NULL,
    name        VARCHAR(100) NOT NULL,
    enabled     BOOLEAN NOT NULL DEFAULT TRUE,
    sort_order  INTEGER NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    updated_by  UUID,
    CONSTRAINT permission_surfaces_key_uk UNIQUE (surface_key),
    CONSTRAINT permission_surfaces_key_chk CHECK (
        surface_key ~ '^[a-z][a-z0-9]*(.[a-z0-9][a-z0-9-]*)+$'
    ),
    CONSTRAINT permission_surfaces_name_chk CHECK (
        btrim(name) <> '' AND name = btrim(name)
    ),
    CONSTRAINT permission_surfaces_sort_order_chk CHECK (sort_order >= 0)
);

CREATE TABLE permission_surface_permissions (
    surface_id    UUID NOT NULL,
    permission_id UUID NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID,
    PRIMARY KEY (surface_id, permission_id),
    CONSTRAINT permission_surface_permissions_surface_fk
        FOREIGN KEY (surface_id)
        REFERENCES permission_surfaces(id)
        ON DELETE RESTRICT,
    CONSTRAINT permission_surface_permissions_permission_fk
        FOREIGN KEY (permission_id)
        REFERENCES permissions(id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_permission_surfaces_enabled_catalog
    ON permission_surfaces(sort_order, surface_key)
    WHERE enabled = TRUE;
CREATE INDEX idx_permission_surface_permissions_permission
    ON permission_surface_permissions(permission_id, surface_id);

COMMENT ON TABLE permission_surfaces IS
    '迁移拥有的稳定页面权限目录；运行时一次加载，不从路由或权限码前缀推导';
COMMENT ON COLUMN permission_surfaces.id IS
    '页面系统 UUID；种子值固定，surface_key 和中文标题不是关联外键';
COMMENT ON COLUMN permission_surfaces.surface_key IS
    '稳定页面机器键；只用于 API 选择，不作为跨表关系主键';
COMMENT ON COLUMN permission_surfaces.enabled IS
    'FALSE 保留页面身份与审计历史，同时从运行时目录隐藏';
COMMENT ON TABLE permission_surface_permissions IS
    '页面 UUID 与权限 UUID 的精确多对多目录；新增权限码必须由后续迁移显式登记';

INSERT INTO permission_surfaces (id, surface_key, name, sort_order) VALUES
    ('32800000-0000-4000-8000-000000000001', 'basic.goods', '货品资料', 1),
    ('32800000-0000-4000-8000-000000000002', 'basic.mould', '模具资料', 2),
    ('32800000-0000-4000-8000-000000000003', 'basic.client', '客户资料', 3),
    ('32800000-0000-4000-8000-000000000004', 'basic.supplier', '供应商资料', 4),
    ('32800000-0000-4000-8000-000000000005', 'basic.color', '颜色', 5),
    ('32800000-0000-4000-8000-000000000006', 'basic.unit', '基本单位', 6),
    ('32800000-0000-4000-8000-000000000007', 'basic.currency', '币种', 7),
    ('32800000-0000-4000-8000-000000000008', 'basic.warehouse', '仓库资料', 8),
    ('32800000-0000-4000-8000-000000000009', 'basic.account', '账户', 9),
    ('32800000-0000-4000-8000-000000000010', 'basic.payment-style', '收付款类别', 10),
    ('32800000-0000-4000-8000-000000000011', 'basic.hub', '基础资料', 11),
    ('32800000-0000-4000-8000-000000000012', 'org.employee', '员工档案', 12),
    ('32800000-0000-4000-8000-000000000013', 'org.department', '部门与岗位', 13),
    ('32800000-0000-4000-8000-000000000014', 'hr.payroll', '工资管理', 14),
    ('32800000-0000-4000-8000-000000000015', 'hr.expense', '报销审批', 15),
    ('32800000-0000-4000-8000-000000000016', 'hr.notice', '通知发布', 16),
    ('32800000-0000-4000-8000-000000000017', 'hr.suggestion', '建议箱', 17),
    ('32800000-0000-4000-8000-000000000018', 'hr.visitor-approval', '访客审批', 18),
    ('32800000-0000-4000-8000-000000000019', 'hr.visitor-security', '访客核验', 19),
    ('32800000-0000-4000-8000-000000000020', 'hr.profile', '信息变更审核', 20),
    ('32800000-0000-4000-8000-000000000021', 'hr.rd-task', '工程研发任务', 21),
    ('32800000-0000-4000-8000-000000000022', 'hr.task', '人事任务', 22),
    ('32800000-0000-4000-8000-000000000023', 'quality.lab-test', '检测记录', 23),
    ('32800000-0000-4000-8000-000000000024', 'quality.sales-return', '销售退货质检', 24),
    ('32800000-0000-4000-8000-000000000025', 'quality.inspection', '品质待检任务', 25),
    ('32800000-0000-4000-8000-000000000026', 'website.inquiry', '官网询盘', 26),
    ('32800000-0000-4000-8000-000000000027', 'sales.quote', '销售报价', 27),
    ('32800000-0000-4000-8000-000000000028', 'sales.order', '销售订货', 28),
    ('32800000-0000-4000-8000-000000000029', 'sales.shipment', '销售出货', 29),
    ('32800000-0000-4000-8000-000000000030', 'sales.other-shipment', '其他出货', 30),
    ('32800000-0000-4000-8000-000000000031', 'sales.return', '销售退货', 31),
    ('32800000-0000-4000-8000-000000000032', 'sales.report', '销售报表', 32),
    ('32800000-0000-4000-8000-000000000033', 'sales.hub', '销售管理', 33),
    ('32800000-0000-4000-8000-000000000034', 'sales.scarcity', '销售稀缺分配', 34),
    ('32800000-0000-4000-8000-000000000035', 'sales.progress', '销售订单进度', 35),
    ('32800000-0000-4000-8000-000000000036', 'purchase.request', '采购申请', 36),
    ('32800000-0000-4000-8000-000000000037', 'purchase.order', '采购订货', 37),
    ('32800000-0000-4000-8000-000000000038', 'purchase.receipt', '采购收货', 38),
    ('32800000-0000-4000-8000-000000000039', 'purchase.return', '采购退货', 39),
    ('32800000-0000-4000-8000-000000000040', 'purchase.report', '采购报表', 40),
    ('32800000-0000-4000-8000-000000000041', 'purchase.inspection', '待检处置', 41),
    ('32800000-0000-4000-8000-000000000042', 'purchase.arrival-exception', '供应商退回任务', 42),
    ('32800000-0000-4000-8000-000000000043', 'purchase.hub', '采购管理', 43),
    ('32800000-0000-4000-8000-000000000044', 'subcontract.inquiry', '委外询价', 44),
    ('32800000-0000-4000-8000-000000000045', 'subcontract.application', '委外申请', 45),
    ('32800000-0000-4000-8000-000000000046', 'subcontract.order', '委外订货', 46),
    ('32800000-0000-4000-8000-000000000047', 'subcontract.receipt', '委外进仓', 47),
    ('32800000-0000-4000-8000-000000000048', 'subcontract.material-issue', '委外发料', 48),
    ('32800000-0000-4000-8000-000000000049', 'subcontract.return', '委外退货', 49),
    ('32800000-0000-4000-8000-000000000050', 'subcontract.material-return', '委外退料', 50),
    ('32800000-0000-4000-8000-000000000051', 'subcontract.waste', '委外损耗', 51),
    ('32800000-0000-4000-8000-000000000052', 'subcontract.report', '委外报表', 52),
    ('32800000-0000-4000-8000-000000000053', 'subcontract.hub', '委外管理', 53),
    ('32800000-0000-4000-8000-000000000054', 'production.plan', '生产计划', 54),
    ('32800000-0000-4000-8000-000000000055', 'production.daily-report', '生产日报', 55),
    ('32800000-0000-4000-8000-000000000056', 'production.report', '生产报表', 56),
    ('32800000-0000-4000-8000-000000000057', 'production.material-analysis', '物料分析', 57),
    ('32800000-0000-4000-8000-000000000058', 'production.material-analysis-history', '物料分析记录', 58),
    ('32800000-0000-4000-8000-000000000059', 'production.where-used', '物料反查', 59),
    ('32800000-0000-4000-8000-000000000060', 'production.hub', '生产管理', 60),
    ('32800000-0000-4000-8000-000000000061', 'warehouse.stock-balance', '库存余额', 61),
    ('32800000-0000-4000-8000-000000000062', 'warehouse.stock-movement', '出入库流水', 62),
    ('32800000-0000-4000-8000-000000000063', 'warehouse.instant-inventory', '即时库存', 63),
    ('32800000-0000-4000-8000-000000000064', 'warehouse.stock-document', '库存单据', 64),
    ('32800000-0000-4000-8000-000000000065', 'warehouse.inbound', '到货与入库', 65),
    ('32800000-0000-4000-8000-000000000066', 'warehouse.report', '仓库报表', 66),
    ('32800000-0000-4000-8000-000000000067', 'warehouse.subcontract-outbound', '委外出仓', 67),
    ('32800000-0000-4000-8000-000000000068', 'warehouse.shelf-label', '货架目视化', 68),
    ('32800000-0000-4000-8000-000000000069', 'warehouse.hub', '仓库管理', 69),
    ('32800000-0000-4000-8000-000000000070', 'operations.warehouse', '仓库履约工作台', 70),
    ('32800000-0000-4000-8000-000000000071', 'operations.purchase', '采购履约工作台', 71),
    ('32800000-0000-4000-8000-000000000072', 'operations.subcontract', '委外履约工作台', 72),
    ('32800000-0000-4000-8000-000000000073', 'finance.receipt', '收款单', 73),
    ('32800000-0000-4000-8000-000000000074', 'finance.payment', '付款单', 74),
    ('32800000-0000-4000-8000-000000000075', 'finance.expense', '费用单', 75),
    ('32800000-0000-4000-8000-000000000076', 'finance.other-income', '其他收入', 76),
    ('32800000-0000-4000-8000-000000000077', 'finance.bank-transfer', '银行转账', 77),
    ('32800000-0000-4000-8000-000000000078', 'finance.ar-ap', '应收应付台账', 78),
    ('32800000-0000-4000-8000-000000000079', 'finance.reconciliation', '财务对账', 79),
    ('32800000-0000-4000-8000-000000000080', 'finance.report', '财务报表', 80),
    ('32800000-0000-4000-8000-000000000081', 'finance.asset', '资产与待摊', 81),
    ('32800000-0000-4000-8000-000000000082', 'finance.order-approval', '采购与委外财务审批', 82),
    ('32800000-0000-4000-8000-000000000083', 'finance.sales-order-confirmation', '销售订单财务确认', 83),
    ('32800000-0000-4000-8000-000000000084', 'finance.checks', '账户与支票', 84),
    ('32800000-0000-4000-8000-000000000085', 'finance.hub', '钱流管理', 85);

-- These are migration-only representations of the former Java exact/prefix
-- registry. They are dropped at commit and never consulted by runtime code.
CREATE TEMP TABLE v328_permission_surface_rules (
    surface_key  VARCHAR(128) PRIMARY KEY,
    exact_codes  TEXT[] NOT NULL,
    code_prefixes TEXT[] NOT NULL
) ON COMMIT DROP;

INSERT INTO v328_permission_surface_rules
    (surface_key, exact_codes, code_prefixes)
VALUES
    ('basic.goods',
     ARRAY['stock:view', 'color:view', 'color:edit', 'unit:view', 'unit:edit'],
     ARRAY['goods:', 'material_category:']),
    ('basic.mould', ARRAY[]::TEXT[], ARRAY['mould:', 'mould_category:']),
    ('basic.client', ARRAY['client:view:all'],
     ARRAY['client:', 'client_category:', 'client_address:']),
    ('basic.supplier', ARRAY[]::TEXT[], ARRAY['supplier:', 'supplier_category:']),
    ('basic.color', ARRAY[]::TEXT[], ARRAY['color:']),
    ('basic.unit', ARRAY[]::TEXT[], ARRAY['unit:']),
    ('basic.currency', ARRAY[]::TEXT[], ARRAY['currency:']),
    ('basic.warehouse', ARRAY[]::TEXT[], ARRAY['warehouse:']),
    ('basic.account', ARRAY[]::TEXT[], ARRAY['account:']),
    ('basic.payment-style', ARRAY[]::TEXT[], ARRAY['payment_style:']),
    ('basic.hub',
     ARRAY[
         'goods:view', 'material_category:view',
         'mould:view', 'mould_category:view',
         'client:view', 'client_category:view',
         'supplier:view', 'supplier_category:view',
         'color:view', 'unit:view', 'currency:view',
         'warehouse:view', 'account:view', 'payment_style:view'
     ],
     ARRAY[]::TEXT[]),
    ('org.employee',
     ARRAY['department:view', 'attachment:view', 'attachment:manage'],
     ARRAY['employee:']),
    ('org.department',
     ARRAY[
         'department:view', 'department:edit', 'employee:view',
         'employee:create', 'employee:pii:edit', 'employee:export'
     ],
     ARRAY[]::TEXT[]),
    ('hr.payroll', ARRAY[]::TEXT[], ARRAY['payroll:']),
    ('hr.expense', ARRAY[]::TEXT[], ARRAY['expense:']),
    ('hr.notice', ARRAY[]::TEXT[], ARRAY['notice:']),
    ('hr.suggestion', ARRAY[]::TEXT[], ARRAY['suggestion:']),
    ('hr.visitor-approval',
     ARRAY['visitor:view', 'visitor:approve', 'visitor:blacklist'],
     ARRAY[]::TEXT[]),
    ('hr.visitor-security',
     ARRAY['visitor:view', 'visitor:check-in', 'visitor:blacklist'],
     ARRAY[]::TEXT[]),
    ('hr.profile', ARRAY[]::TEXT[], ARRAY['profile:']),
    ('hr.rd-task', ARRAY[]::TEXT[], ARRAY['rd_task:']),
    ('hr.task',
     ARRAY['employee:view', 'employee:edit', 'notice:publish'],
     ARRAY[]::TEXT[]),
    ('quality.lab-test', ARRAY[]::TEXT[], ARRAY['lab:test:']),
    ('quality.sales-return', ARRAY[]::TEXT[], ARRAY['sales_return_quality:']),
    ('quality.inspection', ARRAY[]::TEXT[], ARRAY['procurement_inspection:']),
    ('website.inquiry', ARRAY[]::TEXT[], ARRAY['webinquiry:']),
    ('sales.quote',
     ARRAY['sales:view:all', 'currency:edit', 'payment_style:edit'],
     ARRAY['sales_quote:']),
    ('sales.order',
     ARRAY[
         'sales:view:all', 'finance_shipment_audit',
         'currency:edit', 'payment_style:edit'
     ],
     ARRAY['sales_order:']),
    ('sales.shipment',
     ARRAY['sales:view:all', 'finance_shipment_audit'],
     ARRAY['sales_shipment:']),
    ('sales.other-shipment', ARRAY['sales:view:all'], ARRAY['sales_other_shipment:']),
    ('sales.return', ARRAY['sales:view:all'],
     ARRAY['sales_return:', 'sales_return_quality:']),
    ('sales.report', ARRAY['sales:view:all'], ARRAY['sales_report:']),
    ('sales.hub',
     ARRAY[
         'sales_quote:view', 'sales_order:view', 'sales_shipment:view',
         'sales_other_shipment:view', 'sales_return:view',
         'sales_return_quality:view', 'sales_report:view',
         'sales_order:priority', 'sales_order:reallocate'
     ],
     ARRAY[]::TEXT[]),
    ('sales.scarcity',
     ARRAY['sales_order:priority', 'sales_order:reallocate'],
     ARRAY[]::TEXT[]),
    ('sales.progress',
     ARRAY[
         'sales:view:all', 'sales_shipment:view', 'purchase_order:view',
         'subcontract_order:view', 'production_plan:view',
         'production_material_analysis:view'
     ],
     ARRAY['sales_order:']),
    ('purchase.request', ARRAY['purchase:view:all'], ARRAY['purchase_request:']),
    ('purchase.order', ARRAY['purchase:view:all'], ARRAY['purchase_order:']),
    ('purchase.receipt', ARRAY['purchase:view:all'], ARRAY['purchase_receipt:']),
    ('purchase.return', ARRAY['purchase:view:all'], ARRAY['purchase_return:']),
    ('purchase.report', ARRAY['purchase:view:all'], ARRAY['purchase_report:']),
    ('purchase.inspection', ARRAY[]::TEXT[], ARRAY['procurement_inspection:']),
    ('purchase.arrival-exception',
     ARRAY['supplier_return_task:handle'],
     ARRAY[]::TEXT[]),
    ('purchase.hub',
     ARRAY[
         'purchase_request:view', 'purchase_order:view',
         'purchase_receipt:view', 'purchase_return:view',
         'purchase_report:view', 'supplier_return_task:handle'
     ],
     ARRAY[]::TEXT[]),
    ('subcontract.inquiry',
     ARRAY['subcontract:view:all'], ARRAY['subcontract_inquiry:']),
    ('subcontract.application',
     ARRAY['subcontract:view:all'], ARRAY['subcontract_application:']),
    ('subcontract.order',
     ARRAY['subcontract:view:all'], ARRAY['subcontract_order:']),
    ('subcontract.receipt',
     ARRAY['subcontract:view:all'], ARRAY['subcontract_receipt:']),
    ('subcontract.material-issue',
     ARRAY['subcontract:view:all'], ARRAY['subcontract_material_issue:']),
    ('subcontract.return',
     ARRAY['subcontract:view:all'], ARRAY['subcontract_return:']),
    ('subcontract.material-return',
     ARRAY['subcontract:view:all'], ARRAY['subcontract_material_return:']),
    ('subcontract.waste',
     ARRAY['subcontract:view:all'], ARRAY['subcontract_waste:']),
    ('subcontract.report',
     ARRAY['subcontract:view:all'], ARRAY['subcontract_report:']),
    ('subcontract.hub',
     ARRAY[
         'subcontract_inquiry:view', 'subcontract_application:view',
         'subcontract_order:view', 'subcontract_receipt:view',
         'subcontract_material_issue:view', 'subcontract_return:view',
         'subcontract_material_return:view', 'subcontract_waste:view',
         'subcontract_report:view'
     ],
     ARRAY[]::TEXT[]),
    ('production.plan',
     ARRAY[
         'production_plan:view:all',
         'planning_supply_request:view', 'production_material_analysis:view',
         'production_material_analysis:manage',
         'production_daily_report:edit'
     ],
     ARRAY['production_plan:']),
    ('production.daily-report',
     ARRAY['production_plan:view:all'], ARRAY['production_daily_report:']),
    ('production.report',
     ARRAY['production_plan:view:all'], ARRAY['production_report:']),
    ('production.material-analysis',
     ARRAY['production_plan:approve'], ARRAY['production_material_analysis:']),
    ('production.material-analysis-history',
     ARRAY[]::TEXT[], ARRAY['production_material_analysis:view']),
    ('production.where-used',
     ARRAY[]::TEXT[], ARRAY['production_where_used:']),
    ('production.hub',
     ARRAY[
         'production_plan:view', 'production_plan:edit',
         'production_material_analysis:view',
         'production_material_analysis:manage',
         'production_daily_report:view', 'production_report:view',
         'production_where_used:view'
     ],
     ARRAY[]::TEXT[]),
    ('warehouse.stock-balance',
     ARRAY['stock:view', 'stock:balance:adjust'], ARRAY[]::TEXT[]),
    ('warehouse.stock-movement', ARRAY['stock:view'], ARRAY[]::TEXT[]),
    ('warehouse.instant-inventory',
     ARRAY['stock:view', 'stock_report:export'], ARRAY[]::TEXT[]),
    ('warehouse.stock-document',
     ARRAY['stock:view', 'stock_doc:view:all'], ARRAY['stock_doc:']),
    ('warehouse.inbound',
     ARRAY['purchase_receipt:edit', 'subcontract_receipt:edit'],
     ARRAY['warehouse_inbound:', 'procurement_inspection:']),
    ('warehouse.report', ARRAY[]::TEXT[], ARRAY['stock_report:']),
    ('warehouse.subcontract-outbound',
     ARRAY[]::TEXT[], ARRAY['subcontract_outbound:']),
    ('warehouse.shelf-label',
     ARRAY['stock:view', 'stock_report:export'], ARRAY[]::TEXT[]),
    ('warehouse.hub',
     ARRAY[
         'stock:view', 'stock_doc:view', 'stock_report:view',
         'warehouse_inbound:view', 'procurement_inspection:view',
         'subcontract_outbound:view', 'purchase_receipt:view',
         'subcontract_receipt:view'
     ],
     ARRAY[]::TEXT[]),
    ('operations.warehouse',
     ARRAY['stock:view', 'stock_doc:view:all'], ARRAY['stock_doc:']),
    ('operations.purchase',
     ARRAY['purchase:view:all'],
     ARRAY[
         'purchase_request:', 'purchase_order:',
         'purchase_receipt:', 'purchase_return:'
     ]),
    ('operations.subcontract',
     ARRAY['subcontract:view:all'],
     ARRAY[
         'subcontract_inquiry:', 'subcontract_application:',
         'subcontract_order:', 'subcontract_receipt:',
         'subcontract_material_issue:', 'subcontract_return:',
         'subcontract_material_return:', 'subcontract_waste:'
     ]),
    ('finance.receipt',
     ARRAY['finance:view:all', 'finance_post:execute'], ARRAY['finance_receipt:']),
    ('finance.payment',
     ARRAY['finance:view:all', 'finance_post:execute'], ARRAY['finance_payment:']),
    ('finance.expense',
     ARRAY['finance:view:all', 'finance_post:execute'], ARRAY['finance_expense:']),
    ('finance.other-income',
     ARRAY['finance:view:all', 'finance_post:execute'], ARRAY['finance_other_income:']),
    ('finance.bank-transfer',
     ARRAY['finance:view:all', 'finance_post:execute'], ARRAY['finance_bank_transfer:']),
    ('finance.ar-ap',
     ARRAY['finance:view:all', 'finance_report:export'], ARRAY['ar_ap_ledger:']),
    ('finance.reconciliation',
     ARRAY['finance:view:all'], ARRAY['finance_reconciliation:']),
    ('finance.report', ARRAY['finance:view:all'], ARRAY['finance_report:']),
    ('finance.asset',
     ARRAY['finance_asset_period:manage'], ARRAY['finance_asset:']),
    ('finance.order-approval',
     ARRAY[]::TEXT[], ARRAY['finance_order_approval:']),
    ('finance.sales-order-confirmation',
     ARRAY[]::TEXT[], ARRAY['sales_order_finance:']),
    ('finance.checks', ARRAY['account:view'], ARRAY[]::TEXT[]),
    ('finance.hub',
     ARRAY[
         'account:view', 'finance_receipt:view', 'finance_payment:view',
         'finance_expense:view', 'finance_other_income:view',
         'finance_bank_transfer:view', 'finance_report:view',
         'finance_asset:view', 'finance_order_approval:view',
         'sales_order_finance:view', 'ar_ap_ledger:view',
         'finance_reconciliation:view'
     ],
     ARRAY[]::TEXT[]);

DO $$
DECLARE
    missing_exact TEXT;
    missing_prefix TEXT;
    invalid_rule_count BIGINT;
BEGIN
    SELECT count(*)
    INTO invalid_rule_count
    FROM v328_permission_surface_rules rule
    LEFT JOIN permission_surfaces surface
      ON surface.surface_key = rule.surface_key
    WHERE surface.id IS NULL;

    IF invalid_rule_count <> 0
       OR (SELECT count(*) FROM v328_permission_surface_rules) <> 85
       OR (SELECT count(*) FROM permission_surfaces) <> 85 THEN
        RAISE EXCEPTION
            'V328 page catalog must contain exactly 85 matching surfaces and rules';
    END IF;

    SELECT string_agg(rule.surface_key || '=' || exact_code.value, ', '
                      ORDER BY rule.surface_key, exact_code.value)
    INTO missing_exact
    FROM v328_permission_surface_rules rule
    CROSS JOIN LATERAL unnest(rule.exact_codes) AS exact_code(value)
    LEFT JOIN permissions permission
      ON permission.code = exact_code.value
    WHERE permission.id IS NULL;

    SELECT string_agg(rule.surface_key || '=' || code_prefix.value, ', '
                      ORDER BY rule.surface_key, code_prefix.value)
    INTO missing_prefix
    FROM v328_permission_surface_rules rule
    CROSS JOIN LATERAL unnest(rule.code_prefixes) AS code_prefix(value)
    WHERE NOT EXISTS (
        SELECT 1
        FROM permissions permission
        WHERE left(permission.code, length(code_prefix.value)) = code_prefix.value
    );

    IF missing_exact IS NOT NULL OR missing_prefix IS NOT NULL THEN
        RAISE EXCEPTION
            'V328 page catalog has unmapped legacy rules; exact=%, prefix=%',
            missing_exact,
            missing_prefix;
    END IF;
END;
$$;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM v328_permission_surface_rules rule
JOIN permission_surfaces surface
  ON surface.surface_key = rule.surface_key
JOIN permissions permission
  ON permission.code = ANY (rule.exact_codes)
  OR EXISTS (
      SELECT 1
      FROM unnest(rule.code_prefixes) AS code_prefix(value)
      WHERE left(permission.code, length(code_prefix.value)) = code_prefix.value
  )
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- Split V328 codes whose predecessor was an exact composite permission (or
-- whose business family differs from the established prefix) are associated
-- explicitly. No prefix survives this migration.
CREATE TEMP TABLE v328_new_surface_permissions (
    surface_key VARCHAR(128) NOT NULL,
    permission_code TEXT NOT NULL,
    PRIMARY KEY (surface_key, permission_code)
) ON COMMIT DROP;

INSERT INTO v328_new_surface_permissions (surface_key, permission_code) VALUES
    ('basic.payment-style', 'settlement_method:create'),
    ('org.employee', 'attachment:download'),
    ('org.employee', 'attachment:upload'),
    ('org.employee', 'attachment:delete'),
    ('org.department', 'department:create'),
    ('org.department', 'department:delete'),
    ('org.department', 'department:move'),
    ('org.department', 'department:manager_assign'),
    ('org.department', 'position:create'),
    ('org.department', 'position:edit'),
    ('org.department', 'position:delete'),
    ('hr.visitor-security', 'visitor:verify'),
    ('purchase.arrival-exception', 'supplier_return_task:view'),
    ('purchase.arrival-exception', 'supplier_return_task:complete'),
    ('purchase.hub', 'supplier_return_task:view'),
    ('production.plan', 'production_execution:assign'),
    ('production.plan', 'production_execution:release_defer'),
    ('production.plan', 'production_execution:dispatch'),
    ('production.plan', 'production_execution:start'),
    ('production.plan', 'production_execution:cancel'),
    ('production.plan', 'production_execution:reverse'),
    ('production.plan', 'production_mrp:generate_purchase'),
    ('production.plan', 'production_mrp:generate_draw'),
    ('production.plan', 'production_mrp:generate_finished_in'),
    ('production.plan', 'production_planning_package:generate'),
    ('production.plan', 'production_planning_package:draft_edit'),
    ('production.plan', 'production_planning_package:cancel'),
    ('production.plan', 'production_planning_package:reverse'),
    ('production.plan', 'production_material:settle'),
    ('production.plan', 'production_material:reverse'),
    ('production.plan', 'production_material:close');

DO $$
DECLARE
    missing_additions TEXT;
BEGIN
    SELECT string_agg(
               addition.surface_key || '=' || addition.permission_code,
               ', ' ORDER BY addition.surface_key, addition.permission_code)
    INTO missing_additions
    FROM v328_new_surface_permissions addition
    LEFT JOIN permission_surfaces surface
      ON surface.surface_key = addition.surface_key
    LEFT JOIN permissions permission
      ON permission.code = addition.permission_code
    WHERE surface.id IS NULL OR permission.id IS NULL;

    IF missing_additions IS NOT NULL THEN
        RAISE EXCEPTION
            'V328 page catalog has missing split-code associations: %',
            missing_additions;
    END IF;
END;
$$;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM v328_new_surface_permissions addition
JOIN permission_surfaces surface
  ON surface.surface_key = addition.surface_key
JOIN permissions permission
  ON permission.code = addition.permission_code
ON CONFLICT (surface_id, permission_id) DO NOTHING;

DO $$
DECLARE
    empty_surfaces TEXT;
BEGIN
    SELECT string_agg(surface.surface_key, ', ' ORDER BY surface.surface_key)
    INTO empty_surfaces
    FROM permission_surfaces surface
    WHERE NOT EXISTS (
        SELECT 1
        FROM permission_surface_permissions link
        WHERE link.surface_id = surface.id
    );

    IF empty_surfaces IS NOT NULL THEN
        RAISE EXCEPTION
            'V328 page catalog contains surfaces without exact associations: %',
            empty_surfaces;
    END IF;
END;
$$;

CREATE TRIGGER trg_set_updated_at_permission_surfaces
BEFORE UPDATE ON permission_surfaces
FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_audit_permission_surfaces
AFTER INSERT OR UPDATE OR DELETE ON permission_surfaces
FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE TRIGGER trg_audit_permission_surface_permissions
AFTER INSERT OR UPDATE OR DELETE ON permission_surface_permissions
FOR EACH ROW EXECUTE FUNCTION fn_audit();
