-- V486: 采购/委外订货单「财务批准后改量」事实账 + 委外准备中心权限面退役。
--
-- 口径对齐销售 V482（2026-09-05 用户确认）：
--   * 财务批准前的修改 = 草稿直接编辑（既有能力，不变）；
--   * 财务批准后的修改 = change-qty 受控改量：立即生效 + 自动创建复核 case
--     重回财务审批队列，审核页展示「上次批准之后」的修改清单（以前 → 现在）；
--   * 每行一次数量修改写入本表（append-only），audit_log 触发器留痕。
--
-- 同批退役：委外准备中心页面（/subcontract/preparations）下线——委外不再有
-- 「自己分析产品」的入口；有子层委外件由系统自动发单给计划（草稿期建前置
-- 生产分析），计划在物料分析工作台安排车间。subcontract_preparation:view/start
-- 权限按 V441 模式停用（保留授权行作审计追溯，不再可分配）。

CREATE TABLE procurement_order_qty_change_logs (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_type             TEXT NOT NULL
        CHECK (order_type IN ('PURCHASE', 'SUBCONTRACT')),
    order_id               UUID NOT NULL,
    order_item_id          UUID NOT NULL,
    old_qty                NUMERIC(18,4) NOT NULL CHECK (old_qty > 0),
    new_qty                NUMERIC(18,4) NOT NULL CHECK (new_qty > 0),
    case_id                UUID,
    changed_by_employee_id UUID
        REFERENCES employees(id) ON DELETE SET NULL,
    changed_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE procurement_order_qty_change_logs IS
    '已批采购/委外订货单改量事实账：每行一次数量修改（old→new），case_id 指向'
    '本次改量自动创建的财务复核 case（procurement_order_approval_cases）；审批'
    '任务列表按 case 标注「改后待复核 · 改量 N 处」，复核通过后旧清单自然隐藏'
    '（表 append-only 保留审计轨迹）。order_id/order_item_id/case_id 不加外键：'
    'PURCHASE 行指向 purchase_orders、SUBCONTRACT 行指向 subcontract_orders，'
    '跨表无法用单一 FK 表达，服务端按 order_type 校验存在性与归属。';

CREATE INDEX idx_procurement_order_qty_change_logs_order
    ON procurement_order_qty_change_logs(order_type, order_id, changed_at DESC);

DROP TRIGGER IF EXISTS trg_audit_procurement_order_qty_change_logs
    ON procurement_order_qty_change_logs;
CREATE TRIGGER trg_audit_procurement_order_qty_change_logs
AFTER INSERT OR UPDATE OR DELETE ON procurement_order_qty_change_logs
FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- ===== 新权限码：采购/委外订货单受控改量（默认不授任何部门，管理员显式授权）=====
INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description,
     active, assignable)
VALUES
    ('purchase_order:change_qty',
     '采购订货单批准后改量', '采购管理', '采购订货', 330,
     'EDIT', '财务批准后对采购订货单做受控改量（立即生效并重回财务复核）',
     TRUE, TRUE),
    ('subcontract_order:change_qty',
     '委外订货单批准后改量', '委外管理', '委外订货', 330,
     'EDIT', '财务批准后对委外订货单做受控改量（立即生效并重回财务复核）',
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
    ('purchase.order', 'purchase_order:change_qty'),
    ('subcontract.order', 'subcontract_order:change_qty')
)
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM mapping
JOIN permission_surfaces surface ON surface.surface_key = mapping.surface_key
JOIN permissions permission ON permission.code = mapping.permission_code
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- ===== 退役委外准备中心权限面（V441 模式：停用不删除，保留授权审计追溯）=====
DO $$
DECLARE
    historical_grants_before BIGINT;
    historical_grants_after BIGINT;
BEGIN
    SELECT count(*)
    INTO historical_grants_before
    FROM (
        SELECT permission_id FROM department_permissions
        UNION ALL SELECT permission_id FROM role_permissions
        UNION ALL SELECT permission_id FROM user_permission_overrides
        UNION ALL SELECT permission_id FROM manager_permission_delegations
    ) source
    JOIN permissions permission ON permission.id = source.permission_id
    WHERE permission.code IN ('subcontract_preparation:view',
                              'subcontract_preparation:start');

    UPDATE permissions
    SET active = FALSE,
        assignable = FALSE,
        name = CASE code
            WHEN 'subcontract_preparation:view'
                THEN '历史委外前置自制任务查看（已停用）'
            ELSE '历史委外前置自制启动（已停用）' END,
        description =
            '委外准备中心页面已下线（2026-09-05）：有子层委外件由系统自动发单给'
            '计划并在计划侧物料分析工作台安排车间；保留本权限行和既有授权仅用于'
            '审计追溯'
    WHERE code IN ('subcontract_preparation:view',
                   'subcontract_preparation:start');

    SELECT count(*)
    INTO historical_grants_after
    FROM (
        SELECT permission_id FROM department_permissions
        UNION ALL SELECT permission_id FROM role_permissions
        UNION ALL SELECT permission_id FROM user_permission_overrides
        UNION ALL SELECT permission_id FROM manager_permission_delegations
    ) source
    JOIN permissions permission ON permission.id = source.permission_id
    WHERE permission.code IN ('subcontract_preparation:view',
                              'subcontract_preparation:start');

    IF historical_grants_after <> historical_grants_before THEN
        RAISE EXCEPTION 'V486 changed historical preparation grants';
    END IF;

    UPDATE permission_surfaces
    SET enabled = FALSE,
        name = '委外前置自制（已退役）'
    WHERE surface_key = 'subcontract.preparation';

    IF NOT EXISTS (
        SELECT 1 FROM permissions
        WHERE code IN ('subcontract_preparation:view',
                       'subcontract_preparation:start')
          AND active = FALSE
          AND assignable = FALSE
    ) THEN
        RAISE EXCEPTION 'V486 failed to retire preparation permissions';
    END IF;
END;
$$;

-- ===== 系统测试清空白名单：改量事实账随清空（V484 同款机制）=====
DO $$
DECLARE definition TEXT;
        needle TEXT := '(''sales_order_qty_change_logs'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF position(needle IN definition) = 0 THEN
        RAISE EXCEPTION 'V486 cannot extend business_data_reset policy safely';
    END IF;
    definition := replace(definition, needle,
      '(''procurement_order_qty_change_logs'', ''CLEAR''), ' || needle);
    EXECUTE definition;
END;
$$;

-- 权限快照刷新（停用权限后强制 access-token 授权快照过期重建）。
UPDATE authorization_state
SET epoch = epoch + 1,
    updated_at = CURRENT_TIMESTAMP
WHERE singleton_id = 1;
