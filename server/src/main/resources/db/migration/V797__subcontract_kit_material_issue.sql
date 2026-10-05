-- =====================================================================
-- V797：委外领料制——多直属子件整体外发（COMPONENT_OUTBOUND 泛化）
-- =====================================================================
-- 业务口径（用户 2026-10-03 拍板）：委外流程与自制同构，不再判断层级。
--   * 委外目标件的**全部**合规直属 BOM 边（PER_UNIT × 真实投入阶段）都是
--     发给委外商的材料——每条边一条 COMPONENT_OUTBOUND 计划行；
--   * 不再「先自制父件再整件发外」（新单不再产生 MAKE_THEN_OUTBOUND /
--     PREPARED_OUTBOUND 行，历史行按原链路走完）；
--   * 子件各自走采购/自制路线备料；全部子件共同支持的件数（配套可领件数，
--     fn_subcontract_component_kit_capacity）> 0 时通知委外领料；
--   * 分批领料、分批回厂：回厂按冻结单耗逐子件核销（Java
--     consumeIssuedMaterials 已按子件分组，本迁移把 DB 守恒断言对齐到同一口径）；
--   * 目标件无合规边（无 BOM / 仅期间料 / 仅整包批量料）仍走 DIRECT_OUTBOUND
--     现货外协，语义不变。
--
-- 本迁移只改「判定边界」：唯一子件判据泛化为 ≥1 合规边；守卫/守恒/可用量/
-- 权益批次四个函数逐条扩展。历史行字节不变；不新增表。
-- =====================================================================

-- ---------------------------------------------------------------------
-- ① 新判据：该货品是否「至少一条合规直属子件边」（委外领料制的目标件）。
--    与旧 fn_subcontract_sole_component_goods（恰好 1 条）的差别只在数量：
--    唯一性要求删除。子件自身可以有更深 BOM（子件走自己的备料路线）。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_subcontract_component_outbound_goods(p_goods_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM goods_bom_items edge
        JOIN goods child ON child.id = edge.component_goods_id
         AND child.is_deleted = FALSE
         AND COALESCE(child.auto_created, FALSE) = FALSE
         AND child.issue_method <> 'PERIODIC'
        WHERE edge.goods_id = p_goods_id
          AND edge.is_deleted = FALSE
          AND edge.consumption_basis = 'PER_UNIT'
          AND edge.control_stage IN ('START', 'ASSEMBLY', 'FINISH')
          AND edge.qty > 0)
$$;

COMMENT ON FUNCTION fn_subcontract_component_outbound_goods(UUID) IS
    'V797: goods with at least one immediate PER_UNIT productive BOM component — subcontract dispatches every such component to the supplier (kit-based issue, no depth check, no make-first).';

-- ---------------------------------------------------------------------
-- ② 边集：目标件的全部合规直属子件边（多子件计划行的取数来源）。
--    单耗口径与守卫 fn_guard_subcontract_target_quantity_basis_insert 一致：
--    bom_unit_qty = order_unit_rate × edge.qty。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_subcontract_component_edges(p_goods_id UUID)
RETURNS TABLE(component_goods_id UUID, color_id UUID, unit_id UUID, qty NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT edge.component_goods_id, edge.color_id, child.unit_id, edge.qty
    FROM goods_bom_items edge
    JOIN goods child ON child.id = edge.component_goods_id
     AND child.is_deleted = FALSE
     AND COALESCE(child.auto_created, FALSE) = FALSE
     AND child.issue_method <> 'PERIODIC'
    WHERE edge.goods_id = p_goods_id
      AND edge.is_deleted = FALSE
      AND edge.consumption_basis = 'PER_UNIT'
      AND edge.control_stage IN ('START', 'ASSEMBLY', 'FINISH')
      AND edge.qty > 0
    ORDER BY edge.id
$$;

COMMENT ON FUNCTION fn_subcontract_component_edges(UUID) IS
    'V797: all immediate PER_UNIT productive BOM components of a subcontract target; each becomes one COMPONENT_OUTBOUND plan line.';

-- ---------------------------------------------------------------------
-- ③ 子件可用量：component 集合从「唯一子件」泛化为全部合规边。
--    V646 原文的 fn_subcontract_sole_component_goods 唯一性把关删除，边合规
--    过滤（PER_UNIT/投入阶段/qty>0/非期间料）在本函数内置，V740 注入的
--    PERIODIC 过滤一并内联，不再依赖运行时锚点。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_subcontract_component_available_stock(p_application_item_id UUID,p_order_item_id UUID)
RETURNS TABLE(warehouse_id UUID,goods_id UUID,color_id UUID,available_qty NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH target AS (
        SELECT app.goods_id, app.color_id FROM subcontract_application_items app
        WHERE app.id=p_application_item_id AND p_order_item_id IS NULL AND NOT app.is_deleted
        UNION ALL
        SELECT item.goods_id,item.color_id FROM subcontract_order_items item
        WHERE item.id=p_order_item_id AND NOT item.is_deleted
    ), component AS (
        SELECT edge.component_goods_id AS goods_id,edge.color_id
        FROM target JOIN goods_bom_items edge ON edge.goods_id=target.goods_id AND NOT edge.is_deleted
        WHERE edge.consumption_basis='PER_UNIT'
          AND edge.control_stage IN ('START','ASSEMBLY','FINISH')
          AND edge.qty>0
    ), owned AS (
        SELECT lot.warehouse_id,lot.goods_id,lot.color_id,SUM(lot.remaining_qty) AS qty
        FROM fn_subcontract_component_entitled_lots(p_application_item_id,p_order_item_id) lot
        GROUP BY lot.warehouse_id,lot.goods_id,lot.color_id
    )
    SELECT stock.warehouse_id,stock.goods_id,stock.color_id,
           GREATEST(stock.available_qty+COALESCE(owned.qty,0),0)
    FROM component JOIN v_stock_available stock ON stock.goods_id=component.goods_id
      AND stock.color_id IS NOT DISTINCT FROM component.color_id
    JOIN goods edge_component ON edge_component.id=stock.goods_id
      AND NOT edge_component.is_deleted
      AND NOT COALESCE(edge_component.auto_created,FALSE)
      AND edge_component.issue_method<>'PERIODIC'
    JOIN warehouses warehouse ON warehouse.id=stock.warehouse_id
      AND NOT warehouse.is_deleted AND NOT warehouse.is_defective AND NOT warehouse.is_line_side
      AND fn_warehouse_is_operational_leaf(warehouse.id)
    LEFT JOIN owned ON owned.warehouse_id=stock.warehouse_id AND owned.goods_id=stock.goods_id
      AND owned.color_id IS NOT DISTINCT FROM stock.color_id
$$;

-- ---------------------------------------------------------------------
-- ④ 权益批次：children 集合按「每条合规边一行」展开（原本靠唯一子件判据
--    退化为一条）。edge JOIN 上 V740 的 PERIODIC 过滤内联；判据换 ①。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_subcontract_component_entitled_lots(p_application_item_id UUID, p_order_item_id UUID)
RETURNS TABLE(application_item_id UUID, entitlement_event_id UUID, stock_reservation_id UUID,
    beneficiary_analysis_id UUID, beneficiary_analysis_material_id UUID,
    source_exact_peg_id UUID, reallocation_id UUID, warehouse_id UUID,
    goods_id UUID, color_id UUID, remaining_qty NUMERIC, parent_material_id UUID)
LANGUAGE sql STABLE AS $$
    WITH applications AS (
        SELECT app.id,app.qty*COALESCE(app.unit_rate,1) AS parent_qty
        FROM subcontract_application_items app WHERE app.id=p_application_item_id AND p_order_item_id IS NULL
        UNION
        SELECT source.application_item_id,source.alloc_qty*COALESCE(item.unit_rate,1)
        FROM subcontract_order_item_sources source JOIN subcontract_order_items item ON item.id=source.order_item_id
        WHERE source.order_item_id=p_order_item_id AND source.alloc_qty>0
    ), children AS (
        SELECT DISTINCT app.id AS application_item_id, child.analysis_id, child.id AS material_id,parent.id AS parent_material_id,
               edge.component_goods_id, edge.color_id,
               fn_subcontract_component_parent_capacity(app.id,allocation.id,selected.parent_qty*edge.qty) AS capacity_qty
        FROM applications selected
        JOIN subcontract_application_items app ON app.id=selected.id AND NOT app.is_deleted
        JOIN goods_bom_items edge ON edge.goods_id=app.goods_id AND NOT edge.is_deleted
        JOIN goods edge_component ON edge_component.id=edge.component_goods_id
          AND NOT edge_component.is_deleted AND NOT COALESCE(edge_component.auto_created,FALSE)
          AND edge_component.issue_method<>'PERIODIC'
        JOIN preplan_supply_actions action ON action.external_document_type='SUBCONTRACT_APPLICATION'
          AND action.route='SUBCONTRACT' AND action.status<>'CANCELLED'
        JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
          AND allocation.analysis_id=action.analysis_id
          AND (allocation.external_item_id=app.id OR action.public_surplus_external_item_id=app.id)
        JOIN production_material_analysis_materials parent ON parent.id=allocation.analysis_material_id
          AND parent.analysis_id=allocation.analysis_id AND parent.active
          AND parent.goods_id=app.goods_id AND parent.color_id IS NOT DISTINCT FROM app.color_id
        JOIN production_material_analysis_materials child ON child.analysis_id=parent.analysis_id
          AND child.analysis_item_id=parent.analysis_item_id AND child.parent_node_key=parent.node_key
          AND child.bom_item_id=edge.id AND child.active
          AND child.goods_id=edge.component_goods_id AND child.color_id IS NOT DISTINCT FROM edge.color_id
        WHERE fn_subcontract_component_outbound_goods(app.goods_id)
    ), child_capacities AS (
        SELECT application_item_id,analysis_id,material_id,parent_material_id,component_goods_id,color_id,
               SUM(capacity_qty) AS capacity_qty
        FROM children GROUP BY application_item_id,analysis_id,material_id,parent_material_id,component_goods_id,color_id
    ), remaining_capacities AS (
        SELECT child.*,
               GREATEST(child.capacity_qty-COALESCE((
                 SELECT SUM(handoff.qty-target.released_qty)
                 FROM subcontract_component_stock_handoffs handoff
                 JOIN subcontract_material_plan_items pi ON pi.id=handoff.plan_item_id
                 JOIN stock_reservations target ON target.id=handoff.target_reservation_id
                 WHERE p_order_item_id IS NOT NULL AND pi.order_item_id=p_order_item_id
                   AND handoff.application_item_id=child.application_item_id
                   AND handoff.child_material_id=child.material_id),0),0) AS remaining_capacity
        FROM child_capacities child
    ), application_ranges AS (
        SELECT child.*,
               SUM(remaining_capacity) OVER(PARTITION BY material_id ORDER BY application_item_id)
                   -remaining_capacity AS range_start,
               SUM(remaining_capacity) OVER(PARTITION BY material_id ORDER BY application_item_id) AS range_end
        FROM remaining_capacities child WHERE remaining_capacity>0
    ), source_lots AS (
        SELECT DISTINCT ON (lot.entitlement_event_id)
               lot.entitlement_event_id,lot.stock_reservation_id,lot.beneficiary_analysis_id,
               lot.beneficiary_analysis_material_id,lot.source_exact_peg_id,lot.reallocation_id,
               reservation.warehouse_id,reservation.goods_id,reservation.color_id,
               LEAST(lot.remaining_qty,reservation.qty-reservation.consumed_qty-reservation.released_qty) AS remaining_qty
        FROM application_ranges child
        JOIN v_preplan_stock_entitlement_lot_balance lot
          ON lot.beneficiary_analysis_id=child.analysis_id AND lot.beneficiary_analysis_material_id=child.material_id
          AND lot.remaining_qty>0
        JOIN stock_reservations reservation ON reservation.id=lot.stock_reservation_id
          AND reservation.owner_type='PREPLAN_ANALYSIS' AND reservation.status=0 AND NOT reservation.is_deleted
          AND reservation.goods_id=child.component_goods_id AND reservation.color_id IS NOT DISTINCT FROM child.color_id
          AND reservation.qty-reservation.consumed_qty-reservation.released_qty>0
        JOIN warehouses warehouse ON warehouse.id=reservation.warehouse_id
          AND NOT warehouse.is_deleted AND NOT warehouse.is_defective AND NOT warehouse.is_line_side
          AND fn_warehouse_is_operational_leaf(warehouse.id)
        ORDER BY lot.entitlement_event_id
    ), lot_ranges AS (
        SELECT lot.*,
               SUM(remaining_qty) OVER(PARTITION BY beneficiary_analysis_material_id ORDER BY entitlement_event_id)
                   -remaining_qty AS range_start,
               SUM(remaining_qty) OVER(PARTITION BY beneficiary_analysis_material_id ORDER BY entitlement_event_id) AS range_end
        FROM source_lots lot
    )
    -- A single owned lot may cover several applications of the same parent.
    -- Intersect disjoint capacity and stock intervals, rather than duplicating
    -- the lot or allowing the first application to hide the later ones.
    SELECT child.application_item_id,lot.entitlement_event_id,lot.stock_reservation_id,
           lot.beneficiary_analysis_id,lot.beneficiary_analysis_material_id,
           lot.source_exact_peg_id,lot.reallocation_id,lot.warehouse_id,
           lot.goods_id,lot.color_id,
           LEAST(child.range_end,lot.range_end)-GREATEST(child.range_start,lot.range_start),
           child.parent_material_id
    FROM application_ranges child JOIN lot_ranges lot
      ON lot.beneficiary_analysis_material_id=child.material_id
      AND child.range_start<lot.range_end AND child.range_start<lot.range_end
    ORDER BY child.material_id,child.application_item_id,lot.entitlement_event_id
$$;

-- ---------------------------------------------------------------------
-- ⑤ 权益接管：循环只吃「本计划行那颗子件」的 lot。单子件时代 lot 集合天然
--    只有一颗子件，不过滤也对；多子件不过滤会把别的子件的权益挪过来。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_subcontract_take_component_entitlements(
    p_plan_item UUID,p_issue UUID,p_warehouse UUID,p_qty NUMERIC,p_actor UUID)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE
    plan_item subcontract_material_plan_items%ROWTYPE;
    lot RECORD; source stock_reservations%ROWTYPE;
    take_qty NUMERIC; remaining NUMERIC:=p_qty;
    target_id UUID; release_id UUID; handoff_id UUID; balance_id UUID;
BEGIN
    SELECT * INTO STRICT plan_item FROM subcontract_material_plan_items
      WHERE id=p_plan_item AND flow_mode='COMPONENT_OUTBOUND' AND NOT is_deleted FOR UPDATE;
    IF p_qty<=0 OR p_actor IS NULL OR NOT EXISTS(
        SELECT 1 FROM subcontract_material_issues issue JOIN subcontract_material_issue_items item ON item.issue_id=issue.id
        WHERE issue.id=p_issue AND issue.status=0 AND NOT issue.is_deleted
          AND issue.warehouse_id=p_warehouse AND item.plan_item_id=p_plan_item AND NOT item.is_deleted AND item.qty=p_qty
    ) THEN RAISE EXCEPTION 'invalid component custody handoff' USING ERRCODE='23514'; END IF;
    SELECT id INTO STRICT balance_id FROM stock_balances
      WHERE warehouse_id=p_warehouse AND goods_id=plan_item.goods_id
        AND color_id IS NOT DISTINCT FROM plan_item.color_id;
    FOR lot IN SELECT * FROM fn_subcontract_component_entitled_lots(NULL,plan_item.order_item_id)
               WHERE warehouse_id=p_warehouse
                 AND goods_id=plan_item.goods_id
                 AND color_id IS NOT DISTINCT FROM plan_item.color_id
               ORDER BY entitlement_event_id LOOP
        EXIT WHEN remaining<=0;
        PERFORM 1 FROM preplan_stock_entitlement_events WHERE id=lot.entitlement_event_id FOR UPDATE;
        SELECT * INTO STRICT source FROM stock_reservations WHERE id=lot.stock_reservation_id FOR UPDATE;
        take_qty:=LEAST(remaining,lot.remaining_qty,source.qty-source.consumed_qty-source.released_qty);
        IF take_qty<=0 OR source.status<>0 THEN CONTINUE; END IF;
        handoff_id:=gen_random_uuid(); target_id:=gen_random_uuid(); release_id:=gen_random_uuid();
        INSERT INTO preplan_stock_entitlement_events(id,event_group_id,stock_reservation_id,
            beneficiary_analysis_id,beneficiary_analysis_material_id,event_type,qty,
            source_entitlement_event_id,reallocation_id,idempotency_key,created_by)
        VALUES(release_id,handoff_id,source.id,lot.beneficiary_analysis_id,lot.beneficiary_analysis_material_id,
            'RELEASE',take_qty,lot.entitlement_event_id,lot.reallocation_id,'SC-COMPONENT-OUT:'||handoff_id,p_actor);
        UPDATE stock_reservations SET released_qty=released_qty+take_qty,
            status=CASE WHEN consumed_qty+released_qty+take_qty=qty THEN 1 ELSE 0 END,
            release_reason='TRANSFERRED_TO_SUBCONTRACT',lock_version=lock_version+1,updated_at=now(),updated_by=p_actor
        WHERE id=source.id;
        INSERT INTO stock_reservations(id,goods_id,color_id,warehouse_id,qty,consumed_qty,released_qty,status,source,
            source_doc_type,source_doc_id,owner_type,owner_id,purpose,supply_type,supply_id,idempotency_key,created_by,updated_by)
        VALUES(target_id,source.goods_id,source.color_id,p_warehouse,take_qty,0,0,0,0,
            'SUBCONTRACT_OUTBOUND_DRAFT',p_issue,'SUBCONTRACT_OUTBOUND',p_plan_item,'SUBCONTRACT_OUTBOUND',
            'STOCK_BALANCE',balance_id,'SC-COMPONENT-STOCK:'||handoff_id,p_actor,p_actor);
        INSERT INTO subcontract_component_stock_handoffs(id,plan_item_id,application_item_id,parent_material_id,child_material_id,
            source_entitlement_event_id,source_reservation_id,target_reservation_id,release_event_id,qty,created_by)
        VALUES(handoff_id,p_plan_item,lot.application_item_id,lot.parent_material_id,lot.beneficiary_analysis_material_id,
            lot.entitlement_event_id,source.id,target_id,release_id,take_qty,p_actor);
        remaining:=remaining-take_qty;
    END LOOP;
    RETURN p_qty-remaining;
END $$;

-- ---------------------------------------------------------------------
-- ⑥ 数量基准守卫：COMPONENT 分支去掉「唯一子件」要求，改为「该行匹配某条
--    合规边」。同一订货明细内 COMPONENT 与目标件行互斥的防线保留。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_guard_subcontract_target_quantity_basis_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.flow_mode = 'LEGACY_BOM_COMPONENT' THEN RETURN NEW; END IF;

    -- 同一订货明细内不得混用 COMPONENT_OUTBOUND 与其它新流向。
    IF EXISTS (
        SELECT 1 FROM subcontract_material_plan_items sibling
        WHERE sibling.order_item_id = NEW.order_item_id
          AND sibling.is_deleted = FALSE
          AND sibling.preparation_status <> 'CANCELLED'
          AND (sibling.flow_mode = 'COMPONENT_OUTBOUND')
              IS DISTINCT FROM (NEW.flow_mode = 'COMPONENT_OUTBOUND')
    ) THEN
        RAISE EXCEPTION 'subcontract order item cannot mix component outbound with target outbound'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_component_outbound_exclusive_guard';
    END IF;

    IF NEW.flow_mode = 'COMPONENT_OUTBOUND' THEN
        IF NOT EXISTS (
            SELECT 1
            FROM subcontract_order_items oi
            JOIN goods_bom_items edge
              ON edge.goods_id = oi.goods_id
             AND edge.is_deleted = FALSE
            JOIN goods child
              ON child.id = edge.component_goods_id
             AND child.is_deleted = FALSE
             AND COALESCE(child.auto_created, FALSE) = FALSE
             AND child.issue_method <> 'PERIODIC'
            WHERE oi.id = NEW.order_item_id
              AND NEW.parent_goods_id = oi.goods_id
              AND NEW.parent_color_id IS NOT DISTINCT FROM oi.color_id
              AND edge.component_goods_id = NEW.goods_id
              AND NEW.unit_id = child.unit_id
              AND NEW.unit_rate = 1
              AND NEW.bom_unit_qty = ROUND(COALESCE(oi.unit_rate, 1) * edge.qty, 6)
              AND NEW.color_id IS NOT DISTINCT FROM edge.color_id
              AND edge.consumption_basis = 'PER_UNIT'
              AND edge.control_stage IN ('START', 'ASSEMBLY', 'FINISH')
              AND edge.qty > 0
        ) THEN
            RAISE EXCEPTION 'component outbound requires a PER_UNIT productive BOM component of the ordered target'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'subcontract_component_outbound_basis_guard';
        END IF;
        RETURN NEW;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM subcontract_order_items oi JOIN goods g ON g.id=oi.goods_id
        WHERE oi.id=NEW.order_item_id AND NEW.goods_id=oi.goods_id
          AND NEW.unit_id=g.unit_id AND NEW.unit_rate=1 AND NEW.bom_unit_qty=oi.unit_rate
    ) THEN
        RAISE EXCEPTION 'target outbound requires basic unit quantities and frozen order conversion'
            USING ERRCODE='23514',CONSTRAINT='subcontract_target_quantity_basis_guard';
    END IF;
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
-- ⑦ 回厂守恒：从「单值折算因子」改为「按子件（货品+颜色）分组断言」。
--    每组：consumed(子件基本量) 必须精确等于
--    received(父件基本量) × bom_unit_qty/order_unit_rate，且不得超过该组
--    已审发料量——与 Java consumeIssuedMaterials 的 ComponentKey 分组、
--    组内 FIFO 分摊完全同口径（同子件多计划行时分摊顺序不影响组合计）。
--    组内冻结单耗不一致 → 拒绝（与 Java 侧「无法确定回厂消费口径」同 fail-closed）。
--
--    本文整合 V638/V642 的两处运行时补丁语义（本迁移为全文重写，绝不静默
--    回退）：V638 目标件合计计入 PREPARED_OUTBOUND 行；V642 财务已批准的
--    委外商自带料不计入守恒台账。先自检 live 定义确已带上 V642 净额片段。
-- ---------------------------------------------------------------------
DO $kit_receipt_guard_preflight$
DECLARE
    definition TEXT;
BEGIN
    SELECT pg_get_functiondef(
        'fn_assert_subcontract_target_outbound_receipt(uuid)'::regprocedure) INTO definition;
    IF strpos(definition, 'procurement_arrival_exceptions finance_excess') = 0 THEN
        RAISE EXCEPTION 'V797 receipt guard preflight failed: V642 supplier-material netting missing'
            USING ERRCODE = '23514';
    END IF;
    IF strpos(definition, '''PREPARED_OUTBOUND''') = 0 THEN
        RAISE EXCEPTION 'V797 receipt guard preflight failed: V638 prepared-outbound tally missing'
            USING ERRCODE = '23514';
    END IF;
END;
$kit_receipt_guard_preflight$;

CREATE OR REPLACE FUNCTION fn_assert_subcontract_target_outbound_receipt(
    p_order_item_id UUID
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_received NUMERIC;
    v_replacement NUMERIC;
    v_issued NUMERIC;
    v_consumed NUMERIC;
    v_per_base NUMERIC;
    v_expected NUMERIC;
    r RECORD;
BEGIN
    IF p_order_item_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM subcontract_material_plan_items plan_item
        WHERE plan_item.order_item_id=p_order_item_id
          AND plan_item.flow_mode IN (
              'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','COMPONENT_OUTBOUND')
    ) THEN RETURN; END IF;

    PERFORM 1 FROM subcontract_order_items WHERE id=p_order_item_id FOR NO KEY UPDATE;

    SELECT COALESCE(SUM(item.qty*COALESCE(item.unit_rate,1)),0) INTO v_received
    FROM subcontract_receipt_items item
    JOIN subcontract_receipts receipt ON receipt.id=item.receipt_id
      AND receipt.status=1 AND receipt.is_deleted=FALSE
    WHERE item.order_item_id=p_order_item_id AND item.is_deleted=FALSE;

    SELECT COALESCE(SUM(allocation.allocated_base_qty),0) INTO v_replacement
    FROM procurement_iqc_replacement_allocations allocation
    JOIN procurement_iqc_rejection_cases rejection ON rejection.id=allocation.case_id
      AND rejection.receipt_type='SUBCONTRACT' AND rejection.order_item_id=p_order_item_id
      AND rejection.is_deleted=FALSE AND rejection.status<>'REVERSED'
      AND rejection.return_recorded_at IS NOT NULL
    JOIN subcontract_receipt_items original_item ON original_item.id=rejection.receipt_item_id
      AND original_item.receipt_id=rejection.receipt_id AND original_item.order_item_id=p_order_item_id
      AND original_item.is_deleted=FALSE
    JOIN subcontract_receipts original_receipt ON original_receipt.id=original_item.receipt_id
      AND original_receipt.status=1 AND original_receipt.is_deleted=FALSE
    JOIN subcontract_receipt_items replacement_item ON replacement_item.id=allocation.replacement_receipt_item_id
      AND replacement_item.order_item_id=p_order_item_id AND replacement_item.is_deleted=FALSE
      AND replacement_item.goods_id=rejection.goods_id
      AND replacement_item.color_id IS NOT DISTINCT FROM rejection.color_id
    JOIN subcontract_receipts replacement_receipt ON replacement_receipt.id=replacement_item.receipt_id
      AND replacement_receipt.status=1 AND replacement_receipt.is_deleted=FALSE
      AND replacement_receipt.supplier_id=rejection.supplier_id
    WHERE allocation.replacement_receipt_type='SUBCONTRACT' AND allocation.status='ACTIVE';

    -- V642(ADR-101): 财务已批准的委外商自带料不计入守恒台账（自带料额度自钳位，
    -- v_received 不会被压成负数, 原有 <0 兜底仍有效）。
    v_received:=v_received-v_replacement-LEAST(
        GREATEST(COALESCE((
            SELECT SUM(finance_excess.approved_excess_qty*COALESCE(excess_oi.unit_rate,1))
            FROM procurement_arrival_exceptions finance_excess
            JOIN subcontract_order_items excess_oi ON excess_oi.id=finance_excess.order_item_id
            WHERE finance_excess.order_type='SUBCONTRACT'
              AND finance_excess.order_item_id=p_order_item_id
              AND finance_excess.status IN ('RECEIPT_ADJUSTED','RECEIPT_POSTED','CLOSED')
              AND finance_excess.decision IN ('APPROVE_ALL','APPROVE_CUSTOM')
              AND finance_excess.approved_excess_qty>0),0),0),
        GREATEST(v_received-v_replacement,0));
    IF v_received<0 THEN
        RAISE EXCEPTION 'subcontract target receipt exceeds approved target-item outbound'
            USING ERRCODE='23514',CONSTRAINT='subcontract_target_outbound_first_guard';
    END IF;

    -- V797: 逐子件（货品+颜色）分组断言守恒。
    FOR r IN
        SELECT grouped.goods_id, grouped.color_id, grouped.per_base,
               grouped.issued_base, grouped.consumed_base,
               (SELECT COUNT(DISTINCT pi2.bom_unit_qty)
                FROM subcontract_material_plan_items pi2
                WHERE pi2.order_item_id=p_order_item_id
                  AND pi2.is_deleted=FALSE
                  AND pi2.flow_mode='COMPONENT_OUTBOUND'
                  AND pi2.goods_id=grouped.goods_id
                  AND pi2.color_id IS NOT DISTINCT FROM grouped.color_id) AS distinct_rates
        FROM (
            SELECT plan_item.goods_id, plan_item.color_id,
                   plan_item.bom_unit_qty / NULLIF(COALESCE(oi.unit_rate,1),0) AS per_base,
                   COALESCE((
                       SELECT SUM(item.qty*COALESCE(item.unit_rate,1))
                       FROM subcontract_material_issue_items item
                       JOIN subcontract_material_issues issue ON issue.id=item.issue_id
                         AND issue.status=1 AND issue.is_deleted=FALSE
                       WHERE item.plan_item_id IN (
                           SELECT inner_pi.id FROM subcontract_material_plan_items inner_pi
                           WHERE inner_pi.order_item_id=p_order_item_id
                             AND inner_pi.is_deleted=FALSE
                             AND inner_pi.flow_mode='COMPONENT_OUTBOUND'
                             AND inner_pi.goods_id=plan_item.goods_id
                             AND inner_pi.color_id IS NOT DISTINCT FROM plan_item.color_id)
                         AND item.is_deleted=FALSE
                   ),0) AS issued_base,
                   COALESCE((
                       SELECT SUM(item.consumed_qty)
                       FROM subcontract_material_issue_items item
                       JOIN subcontract_material_issues issue ON issue.id=item.issue_id
                         AND issue.status=1 AND issue.is_deleted=FALSE
                       WHERE item.plan_item_id IN (
                           SELECT inner_pi.id FROM subcontract_material_plan_items inner_pi
                           WHERE inner_pi.order_item_id=p_order_item_id
                             AND inner_pi.is_deleted=FALSE
                             AND inner_pi.flow_mode='COMPONENT_OUTBOUND'
                             AND inner_pi.goods_id=plan_item.goods_id
                             AND inner_pi.color_id IS NOT DISTINCT FROM plan_item.color_id)
                         AND item.is_deleted=FALSE
                   ),0) AS consumed_base
            FROM subcontract_material_plan_items plan_item
            JOIN subcontract_order_items oi ON oi.id=plan_item.order_item_id
            WHERE plan_item.order_item_id=p_order_item_id
              AND plan_item.is_deleted=FALSE
              AND plan_item.flow_mode='COMPONENT_OUTBOUND'
            GROUP BY plan_item.goods_id, plan_item.color_id,
                     plan_item.bom_unit_qty / NULLIF(COALESCE(oi.unit_rate,1),0)
        ) grouped
    LOOP
        IF r.distinct_rates>1 THEN
            RAISE EXCEPTION 'subcontract component lines of one child carry divergent frozen unit rates'
                USING ERRCODE='23514',CONSTRAINT='subcontract_component_outbound_basis_guard';
        END IF;
        IF r.per_base IS NULL OR r.per_base<=0 THEN
            RAISE EXCEPTION 'component outbound lacks a usable frozen unit conversion'
                USING ERRCODE='23514',CONSTRAINT='subcontract_component_outbound_basis_guard';
        END IF;
        v_expected:=ROUND(v_received*r.per_base,4);
        IF v_expected>r.issued_base THEN
            RAISE EXCEPTION 'subcontract target receipt exceeds approved target-item outbound'
                USING ERRCODE='23514',CONSTRAINT='subcontract_target_outbound_first_guard';
        END IF;
        IF r.consumed_base<>v_expected THEN
            RAISE EXCEPTION 'subcontract target receipt lacks exact supplier-held consumption'
                USING ERRCODE='23514',CONSTRAINT='subcontract_target_outbound_consumption_guard';
        END IF;
    END LOOP;

    -- 目标件流向（发出去的就是目标件）保持合计口径；V638：合计计入
    -- PREPARED_OUTBOUND 行（前置自制订货超量的混合明细）。
    SELECT COALESCE(SUM(item.qty*COALESCE(item.unit_rate,1)),0),
           COALESCE(SUM(item.consumed_qty),0)
      INTO v_issued,v_consumed
    FROM subcontract_material_issue_items item
    JOIN subcontract_material_issues issue ON issue.id=item.issue_id
      AND issue.status=1 AND issue.is_deleted=FALSE
    JOIN subcontract_material_plan_items plan_item ON plan_item.id=item.plan_item_id
      AND plan_item.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
    WHERE item.order_item_id=p_order_item_id AND item.is_deleted=FALSE;

    IF v_received>v_issued THEN
        RAISE EXCEPTION 'subcontract target receipt exceeds approved target-item outbound'
            USING ERRCODE='23514',CONSTRAINT='subcontract_target_outbound_first_guard';
    END IF;
    IF v_consumed<>v_received THEN
        RAISE EXCEPTION 'subcontract target receipt lacks exact supplier-held consumption'
            USING ERRCODE='23514',CONSTRAINT='subcontract_target_outbound_consumption_guard';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- ⑧ 配套可领件数：全部 COMPONENT 行共同支持的父件件数。
--    每行 kit 上限 = MIN(计划余量, 子件可用量合计 ÷ 冻结单耗)；明细可领 = MIN over 行。
--    口径与生产的 fn_execution_material_output_capacity（短板效应）同构：
--    任何一种必需子件不足，本批可领件数就是它限定的那个数。
--    可用量来自 fn_subcontract_component_available_stock（公共 v_stock_available
--    已扣除全部生效预留——含未审草稿占用的公共份额；entitled lots 已扣除
--    handoff 转出的权益），**不再显式扣减未审草稿**，否则同一批草稿被算两遍。
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_subcontract_component_kit_capacity(p_order_item_id UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT MIN(edge_capacity.kit_qty)
    FROM (
        SELECT LEAST(
                   GREATEST(pi.planned_qty-pi.issued_qty,0),
                   ROUND(COALESCE(stock.total,0) / NULLIF(pi.bom_unit_qty,0),4)
               ) AS kit_qty
        FROM subcontract_material_plan_items pi
        LEFT JOIN LATERAL (
            SELECT SUM(s.available_qty) AS total
            FROM fn_subcontract_component_available_stock(NULL::uuid,pi.order_item_id) s
            WHERE s.goods_id=pi.goods_id
              AND s.color_id IS NOT DISTINCT FROM pi.color_id
        ) stock ON TRUE
        WHERE pi.order_item_id=p_order_item_id
          AND pi.is_deleted=FALSE
          AND pi.flow_mode='COMPONENT_OUTBOUND'
          AND pi.preparation_status='READY_OUTBOUND'
    ) edge_capacity
    WHERE edge_capacity.kit_qty IS NOT NULL
$$;

COMMENT ON FUNCTION fn_subcontract_component_kit_capacity(UUID) IS
    'V797: kit-requisition capacity of an order item = min over component lines of (usable child stock / frozen per-unit usage), floored by remaining plan quantity. Draft reservations are already reflected in v_stock_available; do not deduct them twice.';

-- ---------------------------------------------------------------------
-- ⑨ 注释
-- ---------------------------------------------------------------------
COMMENT ON COLUMN subcontract_material_plan_items.flow_mode IS
    'V436 flow: legacy BOM-component issue, direct target outbound, MAKE target then outbound; V458: PREPARED_OUTBOUND = 下单前前置自制已完成（历史，新单不再产生）; V581/V797: COMPONENT_OUTBOUND = 目标件的每条合规直属子件边一行，全部子件发给委外商组装加工，回厂交目标件（V797 起不再要求唯一子件、不再判断层级；新单不再产生 MAKE_THEN/PREPARED）';

COMMENT ON FUNCTION fn_subcontract_sole_component_goods(UUID) IS
    'V581/V646/V740 历史判据（恰好一个合规直属子件）。V797 起委外分流使用 fn_subcontract_component_outbound_goods（≥1 条合规边）；本函数保留仅供历史迁移回放，当前源码不得再引用。';
