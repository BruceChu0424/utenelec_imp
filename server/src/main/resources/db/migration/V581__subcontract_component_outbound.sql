-- =====================================================================
-- V581：委外「单一叶子子件」直接发料出仓（COMPONENT_OUTBOUND）
-- =====================================================================
-- 业务口径（ADR-085）：委外目标件的活动 BOM 恰好只有 1 个直属子件、且该子件
-- 自身没有活动 BOM 时，公司不再先把目标件自制出来再整件发外，而是**把那一个
-- 子件发给委外商**，委外商加工后交回目标件；回厂按冻结单耗倒扣该子件。
--
-- 物理形态与 V304 的 LEGACY_BOM_COMPONENT 完全一致（父件=目标件、子件=待发
-- 材料、bom_unit_qty=冻结单耗），但**必须是新的独立取值**：LEGACY 行是不可
-- 改写的历史事实（无预留、无 BOM 快照、无出仓分配断言），新流向要享受 V436
-- 以后的专属预留、出仓分配断言与 V507 守恒，两者不能混为一谈。
--
-- 本迁移只做前向放开：新增第 5 个 flow_mode 取值，并把既有守卫按新流向逐条
-- 扩展。历史行字节不变；不新增表；不改已应用迁移。
--
-- 关键判据（DB 与 Java 逐字同口径，任一条不满足即回落 MAKE_THEN_OUTBOUND）：
--   * 目标件的活动 BOM 边恰好 1 条
--       活动 = bom.is_deleted=FALSE
--            AND child.is_deleted=FALSE
--            AND COALESCE(child.auto_created,FALSE)=FALSE   -- 自动补位 stub 不算
--   * 该边 consumption_basis='PER_UNIT'（PER_PACKAGE/FIXED_BATCH 带取整，
--     压不成一个标量单耗）
--   * 该边 control_stage IN ('START','ASSEMBLY','FINISH')（SHIP/REFERENCE 不是
--     真实投入料）
--   * 该子件自身没有活动 BOM 边（真正的一层）
-- =====================================================================

-- ---------------------------------------------------------------------
-- ① flow_mode 取值白名单：四值 → 五值
-- ---------------------------------------------------------------------
ALTER TABLE subcontract_material_plan_items
    DROP CONSTRAINT subcontract_material_plan_item_flow_mode_chk,
    DROP CONSTRAINT subcontract_material_plan_item_preparation_shape_chk;

ALTER TABLE subcontract_material_plan_items
    ADD CONSTRAINT subcontract_material_plan_item_flow_mode_chk CHECK (
        flow_mode IN (
            'LEGACY_BOM_COMPONENT',
            'DIRECT_OUTBOUND',
            'MAKE_THEN_OUTBOUND',
            'PREPARED_OUTBOUND',
            'COMPONENT_OUTBOUND'
        )
    ),
    -- COMPONENT_OUTBOUND 的准备形态与 DIRECT_OUTBOUND 逐字相同（批准即待出仓、
    -- prepared=planned、不挂前置自制分析）；差别只在「发的是子件」，那由
    -- fn_guard_subcontract_target_quantity_basis_insert 的专属分支把关。
    -- 注意：这里刻意不约束 preparation_warehouse_id——仓库存草稿时要写它。
    ADD CONSTRAINT subcontract_material_plan_item_preparation_shape_chk CHECK (
        (
            flow_mode = 'LEGACY_BOM_COMPONENT'
            AND preparation_status IN ('LEGACY_READY', 'CANCELLED')
            AND preparation_analysis_id IS NULL
            AND preparation_analysis_item_id IS NULL
            AND preparation_started_by IS NULL
            AND preparation_started_at IS NULL
        )
        OR
        (
            flow_mode IN ('DIRECT_OUTBOUND', 'COMPONENT_OUTBOUND')
            AND preparation_status IN (
                'READY_OUTBOUND', 'OUTBOUND_COMPLETE', 'CANCELLED'
            )
            AND prepared_qty = planned_qty
            AND preparation_analysis_id IS NULL
            AND preparation_analysis_item_id IS NULL
            AND preparation_started_by IS NULL
            AND preparation_started_at IS NULL
        )
        OR
        (
            flow_mode = 'MAKE_THEN_OUTBOUND'
            AND (
                (
                    preparation_status = 'ACTION_REQUIRED'
                    AND preparation_analysis_id IS NULL
                    AND preparation_analysis_item_id IS NULL
                    AND preparation_started_by IS NULL
                    AND preparation_started_at IS NULL
                    AND prepared_qty = 0
                )
                OR
                (
                    preparation_status IN (
                        'IN_PREPARATION', 'WAITING_FQC', 'WAITING_INBOUND',
                        'READY_OUTBOUND', 'OUTBOUND_COMPLETE'
                    )
                    AND preparation_warehouse_id IS NOT NULL
                    AND preparation_analysis_id IS NOT NULL
                    AND preparation_analysis_item_id IS NOT NULL
                    AND preparation_started_by IS NOT NULL
                    AND preparation_started_at IS NOT NULL
                )
                OR preparation_status = 'CANCELLED'
            )
        )
        OR
        (
            flow_mode = 'PREPARED_OUTBOUND'
            AND (
                (
                    preparation_status IN (
                        'READY_OUTBOUND', 'OUTBOUND_COMPLETE'
                    )
                    AND prepared_qty = planned_qty
                    AND preparation_warehouse_id IS NOT NULL
                    AND preparation_analysis_id IS NOT NULL
                    AND preparation_analysis_item_id IS NOT NULL
                    AND preparation_started_by IS NULL
                    AND preparation_started_at IS NULL
                )
                OR preparation_status = 'CANCELLED'
            )
        )
    );

-- ---------------------------------------------------------------------
-- ② BOM 快照 CHECK：加 COMPONENT_OUTBOUND 分支
--    该约束已被 V529 在运行时按 pg_get_constraintdef 改写过（DIRECT 分支的
--    `= false` 换成 `IS NOT NULL`），所以这里同样读库内现行定义再重建，
--    绝不照抄 V458 原文，否则会把 V529 的放开静默回退。
-- ---------------------------------------------------------------------
DO $component_snapshot$
DECLARE
    definition TEXT;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO definition
      FROM pg_constraint
     WHERE conrelid = 'subcontract_material_plan_items'::regclass
       AND conname = 'subcontract_material_plan_item_bom_snapshot_chk';
    IF definition IS NULL THEN
        RAISE EXCEPTION 'subcontract BOM snapshot guard is missing before V581';
    END IF;
    -- V529 把 DIRECT 分支的 `bom_has_children_snapshot = false` 放开成
    -- `IS NOT NULL`（有合格目标件现货的带 BOM 直下单也能直发）。下面整条重写，
    -- 先确认库内确实是 V529 之后的形态，避免把那次放开静默回退。
    IF position('IS NOT NULL' IN definition) = 0 THEN
        RAISE EXCEPTION 'subcontract BOM snapshot guard is not at the V529 shape before V581';
    END IF;
    IF position('COMPONENT_OUTBOUND' IN definition) > 0 THEN
        RAISE EXCEPTION 'subcontract BOM snapshot guard already knows COMPONENT_OUTBOUND before V581';
    END IF;
END;
$component_snapshot$;

ALTER TABLE subcontract_material_plan_items
    DROP CONSTRAINT subcontract_material_plan_item_bom_snapshot_chk;

ALTER TABLE subcontract_material_plan_items
    ADD CONSTRAINT subcontract_material_plan_item_bom_snapshot_chk CHECK (
        (flow_mode = 'LEGACY_BOM_COMPONENT'
            AND bom_has_children_snapshot IS NULL
            AND preparation_bom_fingerprint IS NULL)
        OR
        -- V529 放开：DIRECT 描述的是物理路线，不是「没有 BOM」。
        (flow_mode = 'DIRECT_OUTBOUND'
            AND bom_has_children_snapshot IS NOT NULL
            AND preparation_bom_fingerprint ~ '^[0-9a-f]{64}$')
        OR
        (flow_mode = 'MAKE_THEN_OUTBOUND'
            AND bom_has_children_snapshot = TRUE
            AND preparation_bom_fingerprint ~ '^[0-9a-f]{64}$')
        OR
        (flow_mode = 'PREPARED_OUTBOUND'
            AND bom_has_children_snapshot IS NOT NULL
            AND preparation_bom_fingerprint ~ '^[0-9a-f]{64}$')
        OR
        -- V581：目标件确实有子层（就是那个要发出去的子件），指纹记的是
        -- **目标件**的 BOM 指纹，用于出仓前检测 BOM 漂移。
        (flow_mode = 'COMPONENT_OUTBOUND'
            AND bom_has_children_snapshot = TRUE
            AND preparation_bom_fingerprint ~ '^[0-9a-f]{64}$')
    ) NOT VALID;

-- ---------------------------------------------------------------------
-- ③ 形态判据函数：只有一个叶子子件的货品。
--    这是 COMPONENT_OUTBOUND 的唯一口径来源——数量基准守卫、物料分析的
--    子层展开分类、以及 Java 侧的
--    SubcontractMaterialPlanService.soleOutboundComponent /
--    MaterialAnalysisCommandService.soleComponentSubcontractGoodsIds
--    必须逐字同口径。改判据时四处一起改。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_subcontract_sole_component_goods(p_goods_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM goods_bom_items edge
        JOIN goods child ON child.id = edge.component_goods_id
         AND child.is_deleted = FALSE
         AND COALESCE(child.auto_created, FALSE) = FALSE
        WHERE edge.goods_id = p_goods_id
          AND edge.is_deleted = FALSE
          AND edge.consumption_basis = 'PER_UNIT'
          AND edge.control_stage IN ('START', 'ASSEMBLY', 'FINISH')
          AND edge.qty > 0
          -- 活动边恰好这一条
          AND (SELECT COUNT(*)
                 FROM goods_bom_items only_edge
                 JOIN goods only_child
                   ON only_child.id = only_edge.component_goods_id
                  AND only_child.is_deleted = FALSE
                  AND COALESCE(only_child.auto_created, FALSE) = FALSE
                WHERE only_edge.goods_id = p_goods_id
                  AND only_edge.is_deleted = FALSE) = 1
          -- 子件自身没有活动边（真正的一层）
          AND NOT EXISTS (
                SELECT 1
                  FROM goods_bom_items grand
                  JOIN goods grand_child
                    ON grand_child.id = grand.component_goods_id
                   AND grand_child.is_deleted = FALSE
                   AND COALESCE(grand_child.auto_created, FALSE) = FALSE
                 WHERE grand.goods_id = edge.component_goods_id
                   AND grand.is_deleted = FALSE)
    );
$$;

COMMENT ON FUNCTION fn_subcontract_sole_component_goods(UUID) IS
    'V581：该货品的活动 BOM 是否恰好只有一个 PER_UNIT 投入的叶子子件（是则委外直接发该子件，不先自制）';

-- ---------------------------------------------------------------------
-- ④ 数量基准守卫：V502 对「非 LEGACY 行必须 goods_id = 订货货品」的硬闸
--    对 COMPONENT_OUTBOUND 加专属分支（发的是子件，父件才等于订货货品），
--    并顺带焊死「同一订货明细混用 COMPONENT 与其它新流向」——回厂消费按
--    货色分组逐组扣满，混行会两组都扣不够而把单据永久卡死。
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
            WHERE oi.id = NEW.order_item_id
              AND NEW.parent_goods_id = oi.goods_id
              AND NEW.parent_color_id IS NOT DISTINCT FROM oi.color_id
              AND edge.component_goods_id = NEW.goods_id
              AND NEW.unit_id = child.unit_id
              AND NEW.unit_rate = 1
              AND NEW.bom_unit_qty = ROUND(COALESCE(oi.unit_rate, 1) * edge.qty, 6)
              AND NEW.color_id IS NOT DISTINCT FROM edge.color_id
              AND fn_subcontract_sole_component_goods(oi.goods_id)
        ) THEN
            RAISE EXCEPTION 'component outbound requires the single childless PER_UNIT BOM component of the ordered target'
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

-- V502 的 v_subcontract_quantity_basis_issues 视图**刻意不加** COMPONENT：
-- 它的判据 `pi.bom_unit_qty <> oi.unit_rate` 对 COMPONENT 恒为真（单耗≠换算率），
-- 一旦加进白名单，出仓/回厂 approve 的一致性预检会把每张单都判成异常。
COMMENT ON VIEW v_subcontract_quantity_basis_issues IS
    'V502委外基本量/父件换算率差异（只覆盖目标件同一性的三种流向；V581 的 COMPONENT_OUTBOUND 发的是子件，不属于本视图口径）。已执行历史不自动更改，继续出回仓前须核对原单与实物并走对应反向。';

-- ---------------------------------------------------------------------
-- ⑤ 出仓分配断言：COMPONENT 行同样要求「已审出仓量 = 专属预留精确覆盖」。
--    其 plan_item.goods_id 与 issue_item.goods_id 天然都是子件，原有的
--    货色一致性判断无需改写。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_assert_subcontract_outbound_issue_allocation(
    p_issue_item_id UUID
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_expected NUMERIC;
    v_allocated NUMERIC;
BEGIN
    SELECT CASE WHEN issue.status = 1 AND NOT issue.is_deleted
                     AND NOT issue_item.is_deleted
                THEN issue_item.qty ELSE 0 END
      INTO v_expected
    FROM subcontract_material_issue_items issue_item
    JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
    JOIN subcontract_material_plan_items plan_item
      ON plan_item.id = issue_item.plan_item_id
     AND plan_item.flow_mode IN (
         'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND',
         'COMPONENT_OUTBOUND')
    WHERE issue_item.id = p_issue_item_id;
    IF NOT FOUND THEN RETURN; END IF;

    IF EXISTS (
        SELECT 1
        FROM subcontract_outbound_issue_reservation_allocations allocation
        JOIN subcontract_material_issue_items issue_item
          ON issue_item.id = allocation.issue_item_id
        JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
        JOIN subcontract_material_plan_items plan_item
          ON plan_item.id = issue_item.plan_item_id
        JOIN stock_reservations reservation
          ON reservation.id = allocation.reservation_id
        WHERE allocation.issue_item_id = p_issue_item_id
          AND allocation.status = 'EFFECTIVE'
          AND (allocation.issue_id <> issue_item.issue_id
            OR allocation.plan_item_id <> issue_item.plan_item_id
            OR reservation.owner_type <> 'SUBCONTRACT_OUTBOUND'
            OR reservation.purpose <> 'SUBCONTRACT_OUTBOUND'
            OR reservation.owner_id <> allocation.plan_item_id
            OR reservation.warehouse_id IS DISTINCT FROM issue.warehouse_id
            OR reservation.goods_id IS DISTINCT FROM issue_item.goods_id
            OR reservation.color_id IS DISTINCT FROM issue_item.color_id
            OR plan_item.goods_id IS DISTINCT FROM issue_item.goods_id
            OR plan_item.color_id IS DISTINCT FROM issue_item.color_id)
    ) THEN
        RAISE EXCEPTION 'subcontract outbound allocation provenance is inconsistent'
            USING ERRCODE = '23514';
    END IF;

    SELECT COALESCE(SUM(allocated_qty),0) INTO v_allocated
    FROM subcontract_outbound_issue_reservation_allocations
    WHERE issue_item_id = p_issue_item_id AND status = 'EFFECTIVE';
    IF v_allocated <> v_expected THEN
        RAISE EXCEPTION 'approved subcontract target issue lacks exact reservation coverage'
            USING ERRCODE = '23514';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- ⑥ 先出后进 + 供应商处消费守恒：COMPONENT 行的发出量是**子件基本量**，
--    回厂量是**目标件基本量**，必须按冻结单耗折算后再比，否则
--    「发 1 个子件、回 1 个目标件」在单耗≠1 时会被误判成超收。
--
--    折算因子 v_per_base = bom_unit_qty / order_item.unit_rate
--             = 每 1 个目标件基本单位所消耗的子件基本量。
--    因 ③ 已禁止混行，同一订货明细的 flow_mode 唯一，可取单值因子。
--
--    PREPARED_OUTBOUND 在本函数原本就不在白名单内（既有口径），本次不动。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_assert_subcontract_target_outbound_receipt(
    p_order_item_id UUID
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_issued NUMERIC;
    v_received NUMERIC;
    v_consumed NUMERIC;
    v_replacement NUMERIC;
    v_component BOOLEAN;
    v_per_base NUMERIC;
    v_expected NUMERIC;
BEGIN
    IF p_order_item_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM subcontract_material_plan_items plan_item
        WHERE plan_item.order_item_id=p_order_item_id
          AND plan_item.flow_mode IN (
              'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','COMPONENT_OUTBOUND')
    ) THEN RETURN; END IF;

    -- FK KEY SHARE remains compatible; ordinary source writes already hold
    -- this row through the common commercial-source prefix.
    PERFORM 1 FROM subcontract_order_items WHERE id=p_order_item_id FOR NO KEY UPDATE;

    SELECT BOOL_OR(plan_item.flow_mode='COMPONENT_OUTBOUND'),
           MAX(plan_item.bom_unit_qty / NULLIF(COALESCE(oi.unit_rate,1),0))
             FILTER (WHERE plan_item.flow_mode='COMPONENT_OUTBOUND')
      INTO v_component, v_per_base
    FROM subcontract_material_plan_items plan_item
    JOIN subcontract_order_items oi ON oi.id=plan_item.order_item_id
    WHERE plan_item.order_item_id=p_order_item_id
      AND plan_item.is_deleted=FALSE;

    SELECT COALESCE(SUM(item.qty*COALESCE(item.unit_rate,1)),0),
           COALESCE(SUM(item.consumed_qty),0)
      INTO v_issued,v_consumed
    FROM subcontract_material_issue_items item
    JOIN subcontract_material_issues issue ON issue.id=item.issue_id
      AND issue.status=1 AND issue.is_deleted=FALSE
    JOIN subcontract_material_plan_items plan_item ON plan_item.id=item.plan_item_id
      AND plan_item.flow_mode IN (
          'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','COMPONENT_OUTBOUND')
    WHERE item.order_item_id=p_order_item_id AND item.is_deleted=FALSE;

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
      AND replacement_item.receipt_id=allocation.replacement_receipt_id
      AND replacement_item.order_item_id=p_order_item_id AND replacement_item.is_deleted=FALSE
      AND replacement_item.goods_id=rejection.goods_id
      AND replacement_item.color_id IS NOT DISTINCT FROM rejection.color_id
    JOIN subcontract_receipts replacement_receipt ON replacement_receipt.id=replacement_item.receipt_id
      AND replacement_receipt.status=1 AND replacement_receipt.is_deleted=FALSE
      AND replacement_receipt.supplier_id=rejection.supplier_id
    WHERE allocation.replacement_receipt_type='SUBCONTRACT' AND allocation.status='ACTIVE';

    v_received:=v_received-v_replacement;

    IF COALESCE(v_component,FALSE) THEN
        IF v_per_base IS NULL OR v_per_base<=0 THEN
            RAISE EXCEPTION 'component outbound lacks a usable frozen unit conversion'
                USING ERRCODE='23514',CONSTRAINT='subcontract_component_outbound_basis_guard';
        END IF;
        v_expected:=ROUND(v_received*v_per_base,4);
    ELSE
        v_expected:=v_received;
    END IF;

    IF v_received<0 OR v_expected>v_issued THEN
        RAISE EXCEPTION 'subcontract target receipt exceeds approved target-item outbound'
            USING ERRCODE='23514',CONSTRAINT='subcontract_target_outbound_first_guard';
    END IF;
    IF v_consumed<>v_expected THEN
        RAISE EXCEPTION 'subcontract target receipt lacks exact supplier-held consumption'
            USING ERRCODE='23514',CONSTRAINT='subcontract_target_outbound_consumption_guard';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- ⑦ 损耗补量口子先焊死：V525 的补量算式只认 DIRECT_OUTBOUND，COMPONENT 行
--    会被静默跳过（守卫缺位）。本期不支持 COMPONENT 的损耗补量，用 CHECK
--    显式拒绝，避免出现「有额度却无人校验」的 fail-open。
-- ---------------------------------------------------------------------
ALTER TABLE subcontract_material_plan_items
    ADD CONSTRAINT subcontract_component_outbound_no_loss_replacement_chk
    CHECK (flow_mode <> 'COMPONENT_OUTBOUND'
           OR COALESCE(loss_replacement_qty_base, 0) = 0) NOT VALID;

-- ---------------------------------------------------------------------
-- ⑧ 注释
-- ---------------------------------------------------------------------
COMMENT ON COLUMN subcontract_material_plan_items.flow_mode IS
    'V436 flow: legacy BOM-component issue, direct target outbound, MAKE target then outbound; V458: PREPARED_OUTBOUND = 下单前前置自制已完成，批准即待出仓; V581: COMPONENT_OUTBOUND = 目标件只有一个叶子子件，直接发该子件给委外商，回厂交目标件';

COMMENT ON COLUMN subcontract_material_plan_items.bom_unit_qty IS
    '冻结单耗/换算率：目标件流向（DIRECT/MAKE_THEN/PREPARED）记订货单位换算率；LEGACY 与 V581 COMPONENT_OUTBOUND 记「每 1 个目标件订货单位消耗多少子件基本量」';

COMMENT ON COLUMN subcontract_material_plan_items.planned_qty IS
    '计划出仓量（发出物的基本单位）：目标件流向记目标件基本量；COMPONENT_OUTBOUND 记子件基本量';
