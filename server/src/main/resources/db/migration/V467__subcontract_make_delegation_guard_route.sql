-- V467: 放开 V337 委托触发器的 MAKE 单路线形状，允许有子层委外件
-- （SUBCONTRACT / SUBCONTRACT_MAKE / SUBCONTRACT_MAKE_TASK）与自制共用
-- preplan_make_entitlement_delegations 迁移 exact 权益。
--
-- 2026-09-04 事故：b0a62cd1 让 notify 循环对 SUBCONTRACT 也调
-- delegateMakeEntitlements（修复委外子树自锁缺料），但 V337 的
-- fn_check_preplan_make_entitlement_delegation 仍写死
-- action.route='MAKE' / external_document_type='PREPLAN_MAKE_TASK' /
-- parent.confirmed_route='MAKE' / child.source_type='MAKE_COMPONENT'，
-- 真库 INSERT 被 23514「invalid preplan MAKE entitlement delegation」拒绝，
-- 「下达委外」整体事务回滚（前端只看到一闪而过的完整性冲突提示）。
--
-- 事件侧触发器（fn_check_preplan_stock_entitlement_event 的
-- MAKE_DELEGATE_OUT/IN 分支）与总量校验器
-- （fn_validate_preplan_make_delegation_totals）按 delegation 头对账、
-- 不看路线，本迁移只改头触发器。配对口径与
-- PreplanStockEntitlementService.delegateMakeEntitlements 的
-- (route, 子行类型, 单据类型) IN (...) 完全一致。不加表、表计数不变。

CREATE OR REPLACE FUNCTION fn_check_preplan_make_entitlement_delegation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    analysis production_material_analyses%ROWTYPE;
    action preplan_supply_actions%ROWTYPE;
    parent_material production_material_analysis_materials%ROWTYPE;
    source_material production_material_analysis_materials%ROWTYPE;
    target_material production_material_analysis_materials%ROWTYPE;
    child_item production_material_analysis_items%ROWTYPE;
    reservation stock_reservations%ROWTYPE;
    source_event preplan_stock_entitlement_events%ROWTYPE;
    source_remaining NUMERIC(18,4);
    target_effective NUMERIC(18,4);
    expected_document_type TEXT;
    expected_source_type TEXT;
BEGIN
    SELECT * INTO analysis FROM production_material_analyses
    WHERE id = NEW.analysis_id;
    SELECT * INTO action FROM preplan_supply_actions
    WHERE id = NEW.supply_action_id FOR UPDATE;
    SELECT * INTO child_item FROM production_material_analysis_items
    WHERE id = NEW.child_analysis_item_id FOR UPDATE;
    SELECT * INTO parent_material FROM production_material_analysis_materials
    WHERE id = NEW.parent_analysis_material_id FOR UPDATE;
    SELECT * INTO source_material FROM production_material_analysis_materials
    WHERE id = NEW.source_analysis_material_id FOR UPDATE;
    SELECT * INTO target_material FROM production_material_analysis_materials
    WHERE id = NEW.target_analysis_material_id FOR UPDATE;
    SELECT * INTO reservation FROM stock_reservations
    WHERE id = NEW.stock_reservation_id FOR UPDATE;
    SELECT * INTO source_event FROM preplan_stock_entitlement_events
    WHERE id = NEW.source_entitlement_event_id FOR UPDATE;
    -- V467：路线→（单据类型, 子行类型）配对；未知路线映射为 NULL，
    -- 经 IS DISTINCT FROM 保持 V337 的 NULL 严格失败关闭语义。
    expected_document_type := CASE action.route
        WHEN 'MAKE' THEN 'PREPLAN_MAKE_TASK'
        WHEN 'SUBCONTRACT' THEN 'SUBCONTRACT_MAKE_TASK'
        ELSE NULL END;
    expected_source_type := CASE action.route
        WHEN 'MAKE' THEN 'MAKE_COMPONENT'
        WHEN 'SUBCONTRACT' THEN 'SUBCONTRACT_MAKE'
        ELSE NULL END;
    source_remaining := source_event.qty - COALESCE((
        SELECT SUM(used.qty)
        FROM preplan_stock_entitlement_events used
        WHERE used.source_entitlement_event_id = source_event.id
          AND used.event_type IN (
              'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT', 'PRIORITY_OUT',
              'FORMALIZE', 'RELEASE')), 0);
    SELECT COALESCE(SUM(balance.effective_qty), 0)
    INTO target_effective
    FROM v_preplan_stock_entitlement_beneficiary_balance balance
    JOIN stock_reservations owned
      ON owned.id = balance.stock_reservation_id
     AND owned.is_deleted = FALSE
     AND owned.status = 0
     AND owned.warehouse_id = analysis.warehouse_id
    WHERE balance.beneficiary_analysis_id = NEW.analysis_id
      AND balance.beneficiary_analysis_material_id = target_material.id;

    IF analysis.id IS NULL
       OR analysis.is_deleted IS DISTINCT FROM FALSE
       OR analysis.status NOT IN ('ACTIVE', 'PARTIALLY_PLANNED')
       OR action.id IS NULL
       OR action.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR action.route NOT IN ('MAKE', 'SUBCONTRACT')
       OR action.status = 'CANCELLED'
       OR expected_document_type IS NULL
       OR action.external_document_type IS DISTINCT FROM expected_document_type
       OR action.external_document_id IS DISTINCT FROM NEW.child_analysis_item_id
       OR parent_material.id IS NULL
       OR parent_material.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR parent_material.active IS DISTINCT FROM TRUE
       OR parent_material.confirmed_route IS DISTINCT FROM action.route
       OR child_item.id IS NULL
       OR child_item.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR child_item.source_type IS DISTINCT FROM expected_source_type
       OR child_item.is_deleted IS DISTINCT FROM FALSE
       OR child_item.parent_analysis_material_id IS DISTINCT FROM parent_material.id
       OR NOT EXISTS (
            SELECT 1 FROM preplan_supply_action_allocations allocation
            WHERE allocation.action_id = action.id
              AND allocation.analysis_id = NEW.analysis_id
              AND allocation.analysis_material_id = parent_material.id)
       OR source_material.id IS NULL
       OR source_material.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR source_material.analysis_item_id
            IS DISTINCT FROM parent_material.analysis_item_id
       OR source_material.parent_node_key IS DISTINCT FROM parent_material.node_key
       OR source_material.active IS DISTINCT FROM TRUE
       OR target_material.id IS NULL
       OR target_material.analysis_id IS DISTINCT FROM NEW.analysis_id
       OR target_material.analysis_item_id IS DISTINCT FROM child_item.id
       OR target_material.depth <> 1
       OR target_material.active IS DISTINCT FROM TRUE
       OR target_material.bom_item_id IS DISTINCT FROM source_material.bom_item_id
       OR target_material.goods_id IS DISTINCT FROM source_material.goods_id
       OR target_material.color_id IS DISTINCT FROM source_material.color_id
       OR target_material.unit_id IS DISTINCT FROM source_material.unit_id
       OR target_material.required_qty <= 0
       OR target_effective + NEW.qty > target_material.required_qty
       OR reservation.id IS NULL
       OR reservation.owner_type IS DISTINCT FROM 'PREPLAN_ANALYSIS'
       OR reservation.owner_id IS DISTINCT FROM NEW.analysis_id
       OR reservation.purpose IS DISTINCT FROM 'PREPLAN_MATERIAL'
       OR reservation.status <> 0
       OR reservation.is_deleted IS DISTINCT FROM FALSE
       OR reservation.warehouse_id IS DISTINCT FROM analysis.warehouse_id
       OR reservation.goods_id IS DISTINCT FROM source_material.goods_id
       OR reservation.color_id IS DISTINCT FROM source_material.color_id
       OR source_event.id IS NULL
       OR source_event.stock_reservation_id IS DISTINCT FROM reservation.id
       OR source_event.beneficiary_analysis_id IS DISTINCT FROM NEW.analysis_id
       OR source_event.beneficiary_analysis_material_id
            IS DISTINCT FROM source_material.id
       OR source_event.event_type NOT IN (
            'ORIGIN_IQC', 'ORIGIN_MAKE', 'MAKE_DELEGATE_IN',
            'REALLOCATE_IN', 'PRIORITY_IN', 'RESTORE')
       OR source_event.source_exact_peg_id IS NULL
       OR NEW.qty > source_remaining THEN
        RAISE EXCEPTION 'invalid preplan MAKE entitlement delegation'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON TABLE preplan_make_entitlement_delegations IS
    '同一分析内 MAKE/SUBCONTRACT 父路径到子分析任务（MAKE_COMPONENT 或 SUBCONTRACT_MAKE）的不可变权益转移头；余额与撤回由 append-only entitlement 事件派生';
COMMENT ON COLUMN
    preplan_make_entitlement_delegations.source_analysis_material_id IS
    '父树中 child ownership 生效后不再承载需求的原直接子件路径';
COMMENT ON COLUMN
    preplan_make_entitlement_delegations.target_analysis_material_id IS
    '子任务（MAKE_COMPONENT/SUBCONTRACT_MAKE child）中同一 BOM edge 的 depth=1 接管路径';
