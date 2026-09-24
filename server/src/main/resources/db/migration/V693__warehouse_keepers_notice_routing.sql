-- =====================================================================
-- V693 (ADR-115) 仓库负责人(仓管员) + 仓库类通知按仓分发 + 「我的仓库」范围
-- =====================================================================
-- 背景(2026-09-24 用户原话): 「多个仓库由多个人员负责, 但仓库的通知是统一全部收到的;
--   成品仓库只要注意产成品出入库, 其他仓库领料、委外、采购、产成品的出入库都有涉及,
--   没有一个快速找到自己仓库相关单据的方法」。
--   此前仓库类通知(领料待出库、IQC 待入库、成品入库待审、销售待拣货、委外出仓、预计到货…)
--   一律发给仓库部门(SUB_WH)子树内持对应权限的全部账号, 单据落在哪个仓只写进正文。
--
-- 本迁移只建事实与读函数, 不改任何已有数据:
--   1. warehouse_keepers: 仓库 × 员工 的负责关系(主档附属设置, 人工在「仓库资料」维护)。
--      登记在主仓(有下级的仓)上 = 负责它下面全部子仓(主仓负责人/仓库主管)。
--   2. fn_warehouse_scope_ids(ids): 仓库查询范围 = 自身 + 全部未软删后代
--      (与 WarehouseScopeService.scopeOf 同口径, 给列表 SQL 用)。
--   3. fn_warehouse_keeper_user_ids(ids): 这些仓库的有效负责人账号
--      = 本仓 + 各级上级仓登记的负责人中, 员工在职且账号启用的 users.id。
--      通知分发: 有有效负责人 → 只发给通知池里的负责人; 没有 → 照旧发给整个通知池。
--   4. fn_user_warehouse_scope_ids(user): 该账号负责的仓库集合(「我的仓库」)
--      = 自己是有效负责人的仓 + 还没有任何有效负责人的仓(与通知分发同口径:
--      没指定负责人的仓库照旧人人都收到, 列表里也人人都看得到, 不会有单据掉进无人区)。
--
-- 为什么是员工而不是账号: 负责人是组织事实(与 moulds.keeper_id 同款指向 employees),
--   账号停用/重建不应让负责关系丢失; 读函数统一经 users.employee_id 换成账号并过滤停用。
--
-- 登记(新表三处 + 迁移头): 审计三清单 FULL(master 组); 清库策略 PRESERVE(随仓库/员工主档保留,
--   沿用 V686 锚点补丁法); 主档引用目录豁免 OWN_CONFIG(仓库自己的附属设置)。
-- =====================================================================

CREATE TABLE warehouse_keepers (
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    employee_id  UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    PRIMARY KEY (warehouse_id, employee_id)
);

CREATE INDEX idx_warehouse_keepers_employee ON warehouse_keepers(employee_id);

COMMENT ON TABLE warehouse_keepers IS
    'ADR-115 仓库负责人(仓管员): 仓库 × 员工。登记在主仓上即负责全部子仓; 仓库类通知只发给有效负责人(无负责人时发给整个仓库部门), 任务中心「我的仓库」按它筛选';
COMMENT ON COLUMN warehouse_keepers.employee_id IS
    '负责人员工(employees.id); 离职或账号停用时读函数自动排除, 关系行保留供复职/交接';

-- ---------------------------------------------------------------------
-- 仓库查询范围: 自身 + 全部未软删后代(给定 id 即使已软删也保留, 历史单据仍可按它筛)。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_warehouse_scope_ids(p_warehouse_ids UUID[])
RETURNS UUID[]
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE scope(id) AS (
        SELECT warehouse.id
        FROM warehouses warehouse
        WHERE warehouse.id = ANY(COALESCE(p_warehouse_ids, ARRAY[]::UUID[]))
        UNION
        SELECT child.id
        FROM warehouses child
        JOIN scope parent ON child.parent_id = parent.id
        WHERE NOT child.is_deleted
    )
    SELECT COALESCE(array_agg(id ORDER BY id), ARRAY[]::UUID[]) FROM scope;
$$;

COMMENT ON FUNCTION fn_warehouse_scope_ids(UUID[]) IS
    'ADR-115 仓库查询范围: 给定仓库 + 全部未软删后代(父仓 = 自身 + 子仓聚合), 与 WarehouseScopeService.scopeOf 同口径';

-- ---------------------------------------------------------------------
-- 仓库的有效负责人账号: 本仓 + 各级上级仓的负责人, 员工在职、账号启用。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_warehouse_keeper_user_ids(p_warehouse_ids UUID[])
RETURNS UUID[]
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE lineage(id) AS (
        SELECT warehouse.id
        FROM warehouses warehouse
        WHERE warehouse.id = ANY(COALESCE(p_warehouse_ids, ARRAY[]::UUID[]))
        UNION
        SELECT warehouse.parent_id
        FROM warehouses warehouse
        JOIN lineage child ON warehouse.id = child.id
        WHERE warehouse.parent_id IS NOT NULL
    )
    SELECT COALESCE(array_agg(DISTINCT account.id ORDER BY account.id), ARRAY[]::UUID[])
    FROM warehouse_keepers keeper
    JOIN lineage ON lineage.id = keeper.warehouse_id
    JOIN employees employee
      ON employee.id = keeper.employee_id
     AND employee.is_deleted = FALSE
     AND employee.status <> 'resigned'
    JOIN users account
      ON account.employee_id = employee.id
     AND account.is_deleted = FALSE
     AND account.status = 'active';
$$;

COMMENT ON FUNCTION fn_warehouse_keeper_user_ids(UUID[]) IS
    'ADR-115 仓库有效负责人账号: 本仓与各级上级仓登记的负责人中员工在职且账号启用者; 空数组 = 未指定负责人(通知照旧发给整个仓库部门)';

-- ---------------------------------------------------------------------
-- 账号负责的仓库集合(「我的仓库」): 自己是有效负责人的仓 + 没有任何有效负责人的仓。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_user_warehouse_scope_ids(p_user_id UUID)
RETURNS UUID[]
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE lineage(warehouse_id, ancestor_id) AS (
        SELECT warehouse.id, warehouse.id
        FROM warehouses warehouse
        WHERE NOT warehouse.is_deleted
        UNION
        SELECT lineage.warehouse_id, ancestor.parent_id
        FROM lineage
        JOIN warehouses ancestor ON ancestor.id = lineage.ancestor_id
        WHERE ancestor.parent_id IS NOT NULL
    ), effective AS (
        SELECT DISTINCT lineage.warehouse_id, account.id AS user_id
        FROM lineage
        JOIN warehouse_keepers keeper ON keeper.warehouse_id = lineage.ancestor_id
        JOIN employees employee
          ON employee.id = keeper.employee_id
         AND employee.is_deleted = FALSE
         AND employee.status <> 'resigned'
        JOIN users account
          ON account.employee_id = employee.id
         AND account.is_deleted = FALSE
         AND account.status = 'active'
    )
    SELECT COALESCE(array_agg(warehouse.id ORDER BY warehouse.id), ARRAY[]::UUID[])
    FROM warehouses warehouse
    WHERE NOT warehouse.is_deleted
      AND (EXISTS (SELECT 1 FROM effective
                   WHERE effective.warehouse_id = warehouse.id
                     AND effective.user_id = p_user_id)
           OR NOT EXISTS (SELECT 1 FROM effective
                          WHERE effective.warehouse_id = warehouse.id));
$$;

COMMENT ON FUNCTION fn_user_warehouse_scope_ids(UUID) IS
    'ADR-115 「我的仓库」: 账号是有效负责人的仓 + 尚无有效负责人的仓(与仓库类通知分发同口径)';

-- 审计: 人工维护的主档附属关系, 按 ADR-105 三清单登记为 FULL(master 组)。
SELECT public.fn_audit_track_table('warehouse_keepers', 'FULL', 'data_change', false);

-- 清库策略: 负责关系随仓库/员工主档保留(PRESERVE)。沿用 V686 的锚点补丁法, 锚点缺失即失败。
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V693 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor || E',\n            (''warehouse_keepers'', ''PRESERVE'')');
END;
$reset_policy$;
