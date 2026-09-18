-- =====================================================================
-- V596：到货「先入库后质检」(上架待检) —— ADR-090
-- =====================================================================
-- 背景(2026-09-16 用户口径)：「入库必须先要品质部质检，一天来的货多了就堆在一起，
-- 或者质检没空；能不能先入库后质检：原本的流程保留，但加个选项——入库任务中心那里
-- 直接入库，品质部照样发过去，但顶部标红提示『货品已入库，需到对应储放区域检查』。」
--
-- 设计结论(为什么不是「先记一笔库存、不合格再出库」)：
--   · V446 起「品质放行」与「仓库入库」是两个独立事实；任何写 stock_balances 的采购/委外
--     入库流水都必须挂在一个品质 PASS 事件上(fn_validate_procurement_iqc_stock_in_item /
--     fn_guard_legacy_procurement_iqc_auto_stock_in)，价值账(V517)也要求先有品质切片。
--     没有 PASS 就先写库存，等于回到 V222 之前「未检品当现货」的 P0 缺口，还要为不合格
--     再造一种出库流水与红冲语义。
--   · 因此「先入库」= 实物先上架落位：把实际叶仓 + 库位记在待检明细行上(本迁移四列)，
--     即时库存把它算到实际仓的「待检量」里；品质合格时由系统按这个位置自动完成正式入库
--     (走 V446 同一套批次/流水/价值/守卫，只是不再需要仓库再点一次确认)；不合格的从
--     库位取出，走 V440 既有的退回/贷项链路——既不需要出库单，也不删任何入库记录。
--
-- 本迁移：只加列、加一个事件动作、给入库批次加一个来源列、一个权限码；不新增表、
-- 不改任何既有行。

-- ① 待检明细行记住「已上架」事实(四列同进同出)。
ALTER TABLE procurement_inspection_items
    ADD COLUMN pre_stocked_warehouse_id UUID REFERENCES warehouses(id) ON DELETE RESTRICT,
    ADD COLUMN pre_stocked_place VARCHAR(100),
    ADD COLUMN pre_stocked_at TIMESTAMPTZ,
    ADD COLUMN pre_stocked_by_employee_id UUID REFERENCES employees(id) ON DELETE RESTRICT;

ALTER TABLE procurement_inspection_items
    ADD CONSTRAINT procurement_inspection_items_pre_stocked_shape_chk CHECK (
        (pre_stocked_warehouse_id IS NULL
            AND pre_stocked_place IS NULL
            AND pre_stocked_at IS NULL
            AND pre_stocked_by_employee_id IS NULL)
        OR (pre_stocked_warehouse_id IS NOT NULL
            AND pre_stocked_place IS NOT NULL
            AND pre_stocked_place = btrim(pre_stocked_place)
            AND length(pre_stocked_place) BETWEEN 1 AND 100
            AND pre_stocked_at IS NOT NULL
            AND pre_stocked_by_employee_id IS NOT NULL));

-- 即时库存「待检量」按实际上架仓聚合、品质部按仓/库位找货：都按这条部分索引定位。
CREATE INDEX idx_procurement_inspection_items_pre_stocked
    ON procurement_inspection_items(pre_stocked_warehouse_id, goods_id, color_id)
    WHERE pre_stocked_at IS NOT NULL AND status IN ('PENDING', 'PARTIAL');

COMMENT ON COLUMN procurement_inspection_items.pre_stocked_warehouse_id IS
    '先入库后检(V596)：实物已上架的实际记账叶仓；NULL=按原流程等品质放行后再由仓库确认入库';
COMMENT ON COLUMN procurement_inspection_items.pre_stocked_place IS
    '先入库后检(V596)：实物已上架的库位；品质部按此到储放区域检验';
COMMENT ON COLUMN procurement_inspection_items.pre_stocked_at IS
    '先入库后检(V596)：上架时间；出结论后不可再改(见 fn_guard_procurement_iqc_pre_stock_mutation)';
COMMENT ON COLUMN procurement_inspection_items.pre_stocked_by_employee_id IS
    '先入库后检(V596)：做出「先上架」决定的仓库员工';

-- ② 记账叶仓判定收口成一个只读函数(与 V563 fn_guard_iqc_actual_warehouse_selection 同口径，
--    另加「线边仓不能收到货」：线边仓是车间料架，采购/委外到货不该上架到车间)。
CREATE OR REPLACE FUNCTION fn_warehouse_is_active_accounting_leaf(p_warehouse UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE ancestry AS (
        SELECT id, parent_id, status, is_deleted, ARRAY[id] AS path
        FROM warehouses WHERE id = p_warehouse
        UNION ALL
        SELECT parent.id, parent.parent_id, parent.status, parent.is_deleted, child.path || parent.id
        FROM ancestry child
        JOIN warehouses parent ON parent.id = child.parent_id
        WHERE NOT parent.id = ANY(child.path)
    )
    SELECT EXISTS (
        SELECT 1 FROM warehouses leaf
        WHERE leaf.id = p_warehouse
          AND leaf.is_accountable
          AND NOT leaf.is_deleted
          AND leaf.status = '使用'
          AND NOT EXISTS (SELECT 1 FROM warehouses child
                          WHERE child.parent_id = leaf.id AND NOT child.is_deleted)
          AND EXISTS (SELECT 1 FROM ancestry WHERE parent_id IS NULL)
          AND NOT EXISTS (SELECT 1 FROM ancestry
                          WHERE is_deleted OR status IS DISTINCT FROM '使用'))
$$;

COMMENT ON FUNCTION fn_warehouse_is_active_accounting_leaf(UUID) IS
    '仓库是否为「启用、参与核算、无子仓、祖先链全部启用」的记账叶仓(V596；与 V563 入库选仓守卫同口径)';

-- ③ 守卫：上架事实只能在「尚无任何结论」时写入或改动；一旦出了结论就是历史事实，不得再改；
--    上架仓必须是记账叶仓且不是线边仓。
CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_pre_stock_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF (NEW.pre_stocked_warehouse_id, NEW.pre_stocked_place,
        NEW.pre_stocked_at, NEW.pre_stocked_by_employee_id)
       IS NOT DISTINCT FROM
       (OLD.pre_stocked_warehouse_id, OLD.pre_stocked_place,
        OLD.pre_stocked_at, OLD.pre_stocked_by_employee_id) THEN
        RETURN NEW;
    END IF;
    IF OLD.status <> 'PENDING' OR NEW.status <> 'PENDING'
       OR OLD.passed_base_qty <> 0 OR OLD.failed_base_qty <> 0 THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'IQC pre-stock location can only change before any quality decision',
            DETAIL = '待检明细已有品质结论，上架位置是历史事实，不能再改。',
            CONSTRAINT = 'procurement_iqc_pre_stock_before_decision_chk';
    END IF;
    IF NEW.pre_stocked_warehouse_id IS NOT NULL THEN
        IF NOT fn_warehouse_is_active_accounting_leaf(NEW.pre_stocked_warehouse_id) THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'IQC pre-stock requires an active accounting leaf warehouse',
                DETAIL = '先入库上架只能落到启用中的记账叶仓。',
                CONSTRAINT = 'procurement_iqc_pre_stock_leaf_warehouse_chk';
        END IF;
        IF EXISTS (SELECT 1 FROM warehouses w
                   WHERE w.id = NEW.pre_stocked_warehouse_id AND w.is_line_side) THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'IQC pre-stock cannot target a line-side warehouse',
                DETAIL = '线边仓是车间料架，采购/委外到货不能上架到线边仓。',
                CONSTRAINT = 'procurement_iqc_pre_stock_not_line_side_chk';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_procurement_iqc_pre_stock_mutation
    BEFORE UPDATE OF pre_stocked_warehouse_id, pre_stocked_place,
                     pre_stocked_at, pre_stocked_by_employee_id
    ON procurement_inspection_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_pre_stock_mutation();

-- ④ 事件账多一种动作：PRE_STOCKED(base_qty=上架时的待检量，reason=「仓库 / 库位」)。
--    reason 校验沿用原约束(PRE_STOCKED 不在豁免名单里，因此必须写明位置)。
ALTER TABLE procurement_inspection_events
    DROP CONSTRAINT procurement_inspection_events_action_chk;
ALTER TABLE procurement_inspection_events
    ADD CONSTRAINT procurement_inspection_events_action_chk CHECK (
        action IN ('RECEIVED', 'PASS', 'FAIL', 'PRODUCTION_WOKEN',
                   'RECEIPT_RESOLVED', 'RECEIPT_REVERSED', 'PRE_STOCKED')
    ) NOT VALID;
ALTER TABLE procurement_inspection_events
    VALIDATE CONSTRAINT procurement_inspection_events_action_chk;

-- ⑤ 入库批次记住来源：仓库手工确认 / 品质合格时按上架位置自动转正。
ALTER TABLE procurement_iqc_stock_in_batches
    ADD COLUMN origin TEXT NOT NULL DEFAULT 'WAREHOUSE_CONFIRM';
ALTER TABLE procurement_iqc_stock_in_batches
    ADD CONSTRAINT procurement_iqc_stock_in_batch_origin_chk
        CHECK (origin IN ('WAREHOUSE_CONFIRM', 'PRE_STOCKED_AUTO'));

COMMENT ON COLUMN procurement_iqc_stock_in_batches.origin IS
    'WAREHOUSE_CONFIRM=仓库确认入库(V446)；PRE_STOCKED_AUTO=先入库后检的合格自动转正(V596)：仓库先上架、品质合格时系统按上架位置入库';

-- 自动转正批次的每一行都必须落在该明细行记录的上架仓 + 库位上，不能落到别处。
CREATE OR REPLACE FUNCTION fn_guard_procurement_iqc_pre_stocked_auto_batch_item()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_origin TEXT;
    v_warehouse UUID;
    v_place TEXT;
BEGIN
    SELECT origin INTO v_origin FROM procurement_iqc_stock_in_batches WHERE id = NEW.batch_id;
    IF v_origin IS DISTINCT FROM 'PRE_STOCKED_AUTO' THEN
        RETURN NEW;
    END IF;
    SELECT pre_stocked_warehouse_id, pre_stocked_place
    INTO v_warehouse, v_place
    FROM procurement_inspection_items WHERE id = NEW.inspection_item_id;
    IF v_warehouse IS NULL
       OR v_warehouse IS DISTINCT FROM NEW.warehouse_id
       OR v_place IS DISTINCT FROM NEW.place_snapshot THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'automatic stock-in must land on the recorded pre-stock warehouse and place',
            DETAIL = '先入库后检的自动转正只能落在明细行记录的上架仓与库位。',
            CONSTRAINT = 'procurement_iqc_pre_stocked_auto_batch_item_chk';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_procurement_iqc_pre_stocked_auto_batch_item
    BEFORE INSERT ON procurement_iqc_stock_in_batch_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_iqc_pre_stocked_auto_batch_item();

-- ⑥ 到货登记幂等命令表(V419)多一种完成结果：STOCKED_PENDING_INSPECTION(登记+送检+上架同事务)。
--    其余三个分支逐字保留；先 NOT VALID 再 VALIDATE，已有行不受影响。
ALTER TABLE warehouse_arrival_registration_commands
    DROP CONSTRAINT warehouse_arrival_registration_command_state_chk;
ALTER TABLE warehouse_arrival_registration_commands
    ADD CONSTRAINT warehouse_arrival_registration_command_state_chk CHECK (
        (status = 'PENDING' AND outcome IS NULL
            AND purchase_receipt_id IS NULL AND subcontract_receipt_id IS NULL
            AND receipt_bill_no_snapshot IS NULL AND exception_id IS NULL AND completed_at IS NULL)
        OR (status = 'COMPLETED'
            AND outcome IN ('SUBMITTED_FOR_INSPECTION', 'STOCKED_PENDING_INSPECTION')
            AND num_nonnulls(purchase_receipt_id, subcontract_receipt_id) = 1
            AND length(btrim(receipt_bill_no_snapshot)) BETWEEN 1 AND 100
            AND exception_id IS NULL AND completed_at IS NOT NULL)
        OR (status = 'QUARANTINED' AND outcome = 'EXCESS_QUARANTINED'
            AND num_nonnulls(purchase_receipt_id, subcontract_receipt_id) = 1
            AND length(btrim(receipt_bill_no_snapshot)) BETWEEN 1 AND 100
            AND exception_id IS NOT NULL AND completed_at IS NOT NULL)
    ) NOT VALID;
ALTER TABLE warehouse_arrival_registration_commands
    VALIDATE CONSTRAINT warehouse_arrival_registration_command_state_chk;

-- ⑦ 权限码：先入库后检是一个独立的、可回收的决定(把未检品放进真实库位)，不靠
--    warehouse_inbound:stock_in 或 warehouse_iqc_stock_in:confirm 顺带。幂等 ON CONFLICT。
INSERT INTO permissions (code, name, module, category, sort_order, action_type, description,
                         active, assignable, bulk_assignable, sensitivity)
VALUES ('warehouse_iqc_stock_in:before_inspection', '到货先入库后质检(上架待检)', '仓库管理', 'IQC 合格入库', 319,
        'EXECUTE',
        '采购/委外到货在品质结论前先上架到实际叶仓与库位；品质部到库位检验，合格由系统按上架位置'
        || '自动完成正式入库，不合格从库位取出走既有退回链路。原「先质检后入库」流程保留为默认。',
        TRUE, TRUE, TRUE, 'NORMAL')
ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name, module = EXCLUDED.module, category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order, action_type = EXCLUDED.action_type,
    description = EXCLUDED.description, active = EXCLUDED.active,
    assignable = EXCLUDED.assignable, bulk_assignable = EXCLUDED.bulk_assignable,
    sensitivity = EXCLUDED.sensitivity;

-- 默认授予仓储部与其上级 PMC 运营部、总经办(与 IQC 确认入库同一批岗位；采购部不默认持有)。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'warehouse_iqc_stock_in:before_inspection'
WHERE d.is_deleted = FALSE
  AND d.code IN ('DEPT_PMC', 'SUB_WH', 'GM')
ON CONFLICT DO NOTHING;

-- 登记到到货登记/入库任务中心/品质部检查结果三个权限面，权限管理页的委派候选与按钮一致。
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code = 'warehouse_iqc_stock_in:before_inspection'
 AND permission.active = TRUE
WHERE surface.surface_key IN ('warehouse.inbound', 'warehouse.inbound-tasks',
                              'warehouse.quality-results', 'warehouse.iqc-stock-in')
ON CONFLICT (surface_id, permission_id) DO NOTHING;
