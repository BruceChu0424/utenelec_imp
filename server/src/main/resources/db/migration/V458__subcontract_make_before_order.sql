-- V458: 委外件「先自制、后通知委外」与分批通知
--
-- 业务反转（ADR-061）：物料分析准备对有子层级的委外件不再立即生成委外申请；
-- 改为在原分析内创建 SUBCONTRACT_MAKE 前置自制任务，走完整自制链
-- （齐套检查 → 计划向导 → DRAW 领料 → 报工 → FQC → 成品实收入库）。
-- 成品入库量进入 preplan_subcontract_make_tasks 账本并以
-- SUBCONTRACT_PREPARE_TASK 专属预留扣住库存；满批自动、未满批可手动
-- 按「已产未通知量」分批生成委外申请。订货财务批准时，来源为该账本的
-- 订货行以 PREPARED_OUTBOUND 流向立即进入待出仓，预留转换为
-- SUBCONTRACT_OUTBOUND 专属预留。
--
-- 直下单（委外部直接新建订货单）保持 V436 的 MAKE_THEN_OUTBOUND
-- 先自制后出仓语义，但整批门禁放宽为分批：prepared_qty > 0 即可
-- 释放出仓（数据库形状本就允许，门禁只在应用层）。
--
-- 历史字节不动：LEGACY_BOM_COMPONENT / 既有 MAKE_THEN_OUTBOUND 行为不变。

-- ====================== 1) 分析明细来源类型扩展 ======================

ALTER TABLE production_material_analysis_items
    DROP CONSTRAINT production_material_analysis_item_source_type_chk,
    DROP CONSTRAINT production_material_analysis_item_parent_shape_chk;

ALTER TABLE production_material_analysis_items
    ADD CONSTRAINT production_material_analysis_item_source_type_chk CHECK (
        source_type IN (
            'SALES_ORDER_ITEM', 'REWORK', 'TRIAL', 'SAMPLE',
            'STOCK', 'OTHER', 'MAKE_COMPONENT', 'SUBCONTRACT_MAKE'
        )
    ),
    ADD CONSTRAINT production_material_analysis_item_parent_shape_chk CHECK (
        (source_type IN ('MAKE_COMPONENT', 'SUBCONTRACT_MAKE')
            AND parent_analysis_material_id IS NOT NULL)
        OR
        (source_type NOT IN ('MAKE_COMPONENT', 'SUBCONTRACT_MAKE')
            AND parent_analysis_material_id IS NULL)
    );

DROP INDEX uq_production_material_analysis_make_component_parent;

CREATE UNIQUE INDEX uq_production_material_analysis_make_component_parent
    ON production_material_analysis_items(parent_analysis_material_id)
    WHERE source_type IN ('MAKE_COMPONENT', 'SUBCONTRACT_MAKE')
      AND is_deleted = FALSE;

CREATE OR REPLACE FUNCTION fn_validate_make_component_source_dimension()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_parent production_material_analysis_materials%ROWTYPE;
BEGIN
    IF NEW.source_type NOT IN ('MAKE_COMPONENT', 'SUBCONTRACT_MAKE') THEN
        RETURN NEW;
    END IF;
    SELECT * INTO v_parent
    FROM production_material_analysis_materials
    WHERE analysis_id = NEW.analysis_id
      AND id = NEW.parent_analysis_material_id;
    IF v_parent.id IS NULL
       OR v_parent.goods_id IS DISTINCT FROM NEW.goods_id
       OR v_parent.color_id IS DISTINCT FROM NEW.color_id
       OR v_parent.unit_id IS DISTINCT FROM NEW.unit_id THEN
        RAISE EXCEPTION 'delegated analysis item must match its parent material dimension'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON CONSTRAINT production_material_analysis_item_source_type_chk
    ON production_material_analysis_items IS
    'V458: SUBCONTRACT_MAKE = 有子层级委外件的前置自制任务行，子树需求委托给该行';

-- ====================== 2) 备料动作外部单据类型扩展 ======================

ALTER TABLE preplan_supply_actions
    DROP CONSTRAINT preplan_supply_action_external_chk;

ALTER TABLE preplan_supply_actions
    ADD CONSTRAINT preplan_supply_action_external_chk CHECK (
        (status = 'OPEN'
            AND external_document_type IS NULL
            AND external_document_id IS NULL)
        OR
        (status IN ('CREATED', 'IN_PROGRESS', 'DONE')
            AND external_document_type IN (
                'PURCHASE_REQUEST', 'SUBCONTRACT_APPLICATION',
                'PREPLAN_MAKE_TASK', 'SUBCONTRACT_MAKE_TASK'
            )
            AND external_document_id IS NOT NULL)
        OR status = 'CANCELLED'
    );

-- ====================== 3) 委外件前置自制任务账本 ======================

CREATE TABLE preplan_subcontract_make_tasks (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id            UUID NOT NULL
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    analysis_material_id   UUID NOT NULL,
    supply_action_id       UUID NOT NULL
        REFERENCES preplan_supply_actions(id) ON DELETE RESTRICT,
    preparation_item_id    UUID NOT NULL,
    goods_id               UUID NOT NULL
        REFERENCES goods(id) ON DELETE RESTRICT,
    color_id               UUID
        REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id                UUID NOT NULL
        REFERENCES units(id) ON DELETE RESTRICT,
    warehouse_id           UUID NOT NULL
        REFERENCES warehouses(id) ON DELETE RESTRICT,
    required_qty           NUMERIC(18,4) NOT NULL CHECK (required_qty > 0),
    produced_qty           NUMERIC(18,4) NOT NULL DEFAULT 0
        CHECK (produced_qty >= 0),
    notified_qty           NUMERIC(18,4) NOT NULL DEFAULT 0
        CHECK (notified_qty >= 0 AND notified_qty <= required_qty),
    status                 TEXT NOT NULL DEFAULT 'ACTIVE'
        CHECK (status IN ('ACTIVE', 'CANCELLED')),
    version                BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0),
    created_by             UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by             UUID REFERENCES users(id) ON DELETE RESTRICT,
    updated_at             TIMESTAMPTZ,
    CONSTRAINT preplan_subcontract_make_task_lineage_fk
        FOREIGN KEY (analysis_id, analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_subcontract_make_task_item_fk
        FOREIGN KEY (analysis_id, preparation_item_id)
        REFERENCES production_material_analysis_items(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_subcontract_make_task_qty_chk CHECK (
        notified_qty <= produced_qty
    ),
    CONSTRAINT preplan_subcontract_make_task_cancel_shape_chk CHECK (
        (status = 'ACTIVE')
        OR
        (status = 'CANCELLED' AND produced_qty = 0 AND notified_qty = 0)
    )
);

CREATE INDEX idx_preplan_subcontract_make_tasks_analysis
    ON preplan_subcontract_make_tasks(analysis_id, status);

CREATE INDEX idx_preplan_subcontract_make_tasks_open
    ON preplan_subcontract_make_tasks(status, updated_at, id)
    WHERE status = 'ACTIVE';

-- 每个分析行同时至多一个进行中的委外前置自制任务（重新下达走增量行）。
CREATE UNIQUE INDEX uq_preplan_subcontract_make_task_material
    ON preplan_subcontract_make_tasks(analysis_material_id)
    WHERE status = 'ACTIVE';

CREATE TABLE preplan_subcontract_make_task_batches (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id               UUID NOT NULL
        REFERENCES preplan_subcontract_make_tasks(id) ON DELETE RESTRICT,
    application_id        UUID NOT NULL
        REFERENCES subcontract_applications(id) ON DELETE RESTRICT,
    application_item_id   UUID NOT NULL
        REFERENCES subcontract_application_items(id) ON DELETE RESTRICT,
    allocation_id         UUID NOT NULL
        REFERENCES preplan_supply_action_allocations(id) ON DELETE RESTRICT,
    notify_qty            NUMERIC(18,4) NOT NULL CHECK (notify_qty > 0),
    idempotency_key       TEXT NOT NULL,
    created_by            UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT preplan_subcontract_make_task_batch_key_chk CHECK (
        length(btrim(idempotency_key)) BETWEEN 8 AND 128
    ),
    UNIQUE (task_id, idempotency_key),
    UNIQUE (application_item_id),
    UNIQUE (allocation_id)
);

CREATE INDEX idx_preplan_subcontract_make_task_batches_task
    ON preplan_subcontract_make_task_batches(task_id);

-- 批次通知量守恒：每任务已通知量必须等于其批次之和（可延迟校验）。
CREATE OR REPLACE FUNCTION fn_assert_subcontract_make_task_batches()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM preplan_subcontract_make_tasks task
        WHERE task.status = 'ACTIVE'
          AND task.notified_qty <> (
              SELECT COALESCE(SUM(batch.notify_qty), 0)
              FROM preplan_subcontract_make_task_batches batch
              WHERE batch.task_id = task.id
          )
    ) THEN
        RAISE EXCEPTION
            'subcontract make task notified qty lacks exact batch coverage'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_make_task_batch_conservation_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_subcontract_make_task_batches()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM fn_assert_subcontract_make_task_batches();
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_subcontract_make_task_batch_guard
    AFTER INSERT OR UPDATE OR DELETE ON preplan_subcontract_make_task_batches
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_make_task_batches();

CREATE CONSTRAINT TRIGGER trg_subcontract_make_task_qty_guard
    AFTER UPDATE OF notified_qty, status ON preplan_subcontract_make_tasks
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_make_task_batches();

COMMENT ON TABLE preplan_subcontract_make_tasks IS
    '有子层级委外件的前置自制任务账本：required/produced/notified 守恒，驱动满批自动与分批通知委外';

-- ====================== 4) 计划行流向扩展：PREPARED_OUTBOUND ======================

ALTER TABLE subcontract_material_plan_items
    DROP CONSTRAINT subcontract_material_plan_item_flow_mode_chk,
    DROP CONSTRAINT subcontract_material_plan_item_bom_snapshot_chk,
    DROP CONSTRAINT subcontract_material_plan_item_preparation_shape_chk;

ALTER TABLE subcontract_material_plan_items
    ADD CONSTRAINT subcontract_material_plan_item_flow_mode_chk CHECK (
        flow_mode IN (
            'LEGACY_BOM_COMPONENT',
            'DIRECT_OUTBOUND',
            'MAKE_THEN_OUTBOUND',
            'PREPARED_OUTBOUND'
        )
    ),
    ADD CONSTRAINT subcontract_material_plan_item_bom_snapshot_chk CHECK (
        (flow_mode = 'LEGACY_BOM_COMPONENT'
            AND bom_has_children_snapshot IS NULL
            AND preparation_bom_fingerprint IS NULL)
        OR
        (flow_mode = 'DIRECT_OUTBOUND'
            AND bom_has_children_snapshot = FALSE
            AND preparation_bom_fingerprint ~ '^[0-9a-f]{64}$')
        OR
        (flow_mode = 'MAKE_THEN_OUTBOUND'
            AND bom_has_children_snapshot = TRUE
            AND preparation_bom_fingerprint ~ '^[0-9a-f]{64}$')
        OR
        (flow_mode = 'PREPARED_OUTBOUND'
            AND bom_has_children_snapshot IS NOT NULL
            AND preparation_bom_fingerprint ~ '^[0-9a-f]{64}$')
    ) NOT VALID,
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
            flow_mode = 'DIRECT_OUTBOUND'
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

COMMENT ON COLUMN subcontract_material_plan_items.flow_mode IS
    'V436 flow: legacy BOM-component issue, direct target outbound, MAKE target then outbound; V458: PREPARED_OUTBOUND = 下单前前置自制已完成，批准即待出仓';

-- 来源断言扩展：PREPARED_OUTBOUND 行指向原分析的 SUBCONTRACT_MAKE 行，
-- 且订货行必须能通过委外申请明细追溯到该任务的批次账本。
CREATE OR REPLACE FUNCTION fn_assert_subcontract_preparation_source(
    p_plan_item_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM subcontract_material_plan_items plan_item
        WHERE plan_item.id = p_plan_item_id
          AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
          AND plan_item.preparation_analysis_id IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM production_material_analysis_items analysis_item
              WHERE analysis_item.analysis_id = plan_item.preparation_analysis_id
                AND analysis_item.id = plan_item.preparation_analysis_item_id
                AND analysis_item.is_deleted = FALSE
                AND analysis_item.source_type = 'SUBCONTRACT_PREPARATION'
                AND analysis_item.source_ref =
                    'SC-PREP:' || plan_item.order_item_id::text
                AND analysis_item.goods_id = plan_item.goods_id
                AND analysis_item.color_id IS NOT DISTINCT FROM plan_item.color_id
                AND analysis_item.unit_id = plan_item.unit_id
                AND analysis_item.requested_qty = plan_item.planned_qty
          )
    ) THEN
        RAISE EXCEPTION
            'subcontract preparation analysis lineage is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_preparation_analysis_lineage_guard';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM subcontract_material_plan_items plan_item
        WHERE plan_item.id = p_plan_item_id
          AND plan_item.flow_mode = 'PREPARED_OUTBOUND'
          AND NOT EXISTS (
              SELECT 1
              FROM subcontract_order_items order_item
              JOIN subcontract_application_items application_item
                ON application_item.id = order_item.application_item_id
               AND application_item.is_deleted = FALSE
              JOIN preplan_subcontract_make_task_batches batch
                ON batch.application_item_id = application_item.id
              JOIN preplan_subcontract_make_tasks task
                ON task.id = batch.task_id
               AND task.status = 'ACTIVE'
               AND task.analysis_id = plan_item.preparation_analysis_id
               AND task.preparation_item_id =
                   plan_item.preparation_analysis_item_id
              JOIN production_material_analysis_items analysis_item
                ON analysis_item.analysis_id = task.analysis_id
               AND analysis_item.id = task.preparation_item_id
               AND analysis_item.is_deleted = FALSE
               AND analysis_item.source_type = 'SUBCONTRACT_MAKE'
               AND analysis_item.goods_id = plan_item.goods_id
               AND analysis_item.color_id IS NOT DISTINCT FROM plan_item.color_id
               AND analysis_item.unit_id = plan_item.unit_id
               AND analysis_item.requested_qty >= plan_item.planned_qty
              WHERE order_item.id = plan_item.order_item_id
                AND order_item.is_deleted = FALSE
                AND batch.notify_qty >= plan_item.planned_qty
          )
    ) THEN
        RAISE EXCEPTION
            'subcontract prepared-outbound lineage is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_prepared_outbound_lineage_guard';
    END IF;
END;
$$;

-- ====================== 5) 库存预留 owner 扩展 ======================

ALTER TABLE stock_reservations
    DROP CONSTRAINT stock_reservations_owner_type_chk,
    DROP CONSTRAINT stock_reservations_purpose_chk,
    DROP CONSTRAINT stock_reservations_owner_shape_chk;

ALTER TABLE stock_reservations
    ADD CONSTRAINT stock_reservations_owner_type_chk CHECK (
        owner_type IN (
            'SALES_ORDER_ITEM', 'PRODUCTION_MATERIAL_DEMAND',
            'PREPLAN_ANALYSIS', 'SUBCONTRACT_OUTBOUND',
            'SUBCONTRACT_PREPARE_TASK'
        )
    ),
    ADD CONSTRAINT stock_reservations_purpose_chk CHECK (
        purpose IN (
            'SALES_FULFILLMENT', 'PRODUCTION_MATERIAL',
            'PREPLAN_MATERIAL', 'SUBCONTRACT_OUTBOUND',
            'SUBCONTRACT_PREPARE_TASK'
        )
    ),
    ADD CONSTRAINT stock_reservations_owner_shape_chk CHECK (
        (
            owner_type = 'SALES_ORDER_ITEM'
            AND purpose = 'SALES_FULFILLMENT'
            AND order_item_id IS NOT NULL
            AND owner_id = order_item_id
            AND demand_id IS NULL
        )
        OR
        (
            owner_type = 'PRODUCTION_MATERIAL_DEMAND'
            AND purpose = 'PRODUCTION_MATERIAL'
            AND order_item_id IS NULL
            AND demand_id IS NOT NULL
            AND owner_id = demand_id
            AND warehouse_id IS NOT NULL
            AND supply_type = 'STOCK_BALANCE'
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
        OR
        (
            owner_type = 'PREPLAN_ANALYSIS'
            AND purpose = 'PREPLAN_MATERIAL'
            AND order_item_id IS NULL
            AND demand_id IS NULL
            AND owner_id IS NOT NULL
            AND warehouse_id IS NOT NULL
            AND supply_type IN (
                'PURCHASE_REQUEST_ITEM',
                'SUBCONTRACT_APPLICATION_ITEM',
                'PRODUCTION_PLAN_ITEM',
                'MATERIAL_REALLOCATION_PRIORITY'
            )
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
        OR
        (
            owner_type = 'SUBCONTRACT_OUTBOUND'
            AND purpose = 'SUBCONTRACT_OUTBOUND'
            AND order_item_id IS NULL
            AND demand_id IS NULL
            AND owner_id IS NOT NULL
            AND warehouse_id IS NOT NULL
            AND supply_type IN ('STOCK_BALANCE', 'PRODUCTION_FINISHED_IN')
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
        OR
        (
            owner_type = 'SUBCONTRACT_PREPARE_TASK'
            AND purpose = 'SUBCONTRACT_PREPARE_TASK'
            AND order_item_id IS NULL
            AND demand_id IS NULL
            AND owner_id IS NOT NULL
            AND warehouse_id IS NOT NULL
            AND supply_type = 'PRODUCTION_FINISHED_IN'
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
    );

CREATE INDEX idx_stock_reservation_subcontract_prepare_task_owner
    ON stock_reservations(owner_id, status)
    WHERE is_deleted = FALSE
      AND owner_type = 'SUBCONTRACT_PREPARE_TASK';

COMMENT ON COLUMN stock_reservations.owner_type IS
    'V90 体系 + V436 SUBCONTRACT_OUTBOUND + V458 SUBCONTRACT_PREPARE_TASK（前置自制产出在通知/订货前扣住公共可用量）';

-- 出仓分配断言与 FINISHED_IN 血缘断言接受 PREPARED_OUTBOUND。
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
         'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
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

CREATE OR REPLACE FUNCTION fn_assert_subcontract_preparation_finished_source(
    p_reservation_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM stock_reservations reservation
        WHERE reservation.id = p_reservation_id
          AND reservation.owner_type = 'SUBCONTRACT_OUTBOUND'
          AND reservation.supply_type = 'PRODUCTION_FINISHED_IN'
          AND (reservation.qty - reservation.consumed_qty
               - reservation.released_qty > 0
               OR reservation.consumed_qty > 0)
    ) AND NOT EXISTS (
        SELECT 1
        FROM stock_reservations reservation
        JOIN subcontract_material_plan_items plan_item
          ON plan_item.id = reservation.owner_id
         AND plan_item.flow_mode IN (
             'MAKE_THEN_OUTBOUND', 'PREPARED_OUTBOUND')
         AND plan_item.is_deleted = FALSE
        JOIN stock_document_items stock_item
          ON stock_item.id = reservation.supply_id
         AND stock_item.doc_id = reservation.source_doc_id
         AND stock_item.bill_type = 'FINISHED_IN'
         AND stock_item.is_deleted = FALSE
        JOIN stock_documents stock_doc
          ON stock_doc.id = stock_item.doc_id
         AND stock_doc.doc_type = 'FINISHED_IN'
         AND stock_doc.status = 1
         AND stock_doc.is_deleted = FALSE
        JOIN production_plan_items production_item
          ON production_item.id = stock_item.upstream_item_id
         AND production_item.is_deleted = FALSE
        JOIN production_plans production_plan
          ON production_plan.id = production_item.plan_id
         AND production_plan.status = 1
         AND production_plan.is_deleted = FALSE
        JOIN production_material_analysis_plan_links analysis_link
          ON analysis_link.plan_id = production_plan.id
         AND analysis_link.analysis_id = plan_item.preparation_analysis_id
         AND analysis_link.analysis_item_id =
             plan_item.preparation_analysis_item_id
         AND analysis_link.allocation_status = 'APPROVED'
        WHERE reservation.id = p_reservation_id
          AND reservation.purpose = 'SUBCONTRACT_OUTBOUND'
          AND reservation.source_doc_type = 'PRODUCTION_INBOUND'
          AND reservation.warehouse_id = stock_doc.warehouse_id
          AND reservation.warehouse_id = plan_item.preparation_warehouse_id
          AND reservation.goods_id = stock_item.goods_id
          AND reservation.goods_id = production_item.goods_id
          AND reservation.goods_id = plan_item.goods_id
          AND reservation.color_id IS NOT DISTINCT FROM stock_item.color_id
          AND reservation.color_id IS NOT DISTINCT FROM production_item.color_id
          AND reservation.color_id IS NOT DISTINCT FROM plan_item.color_id
          AND stock_item.unit_id = production_item.unit_id
          AND stock_item.unit_id = plan_item.unit_id
          AND COALESCE(stock_item.unit_rate, 1) = 1
          AND COALESCE(production_item.unit_rate, 1) = 1
          AND reservation.qty = stock_item.qty * COALESCE(stock_item.unit_rate, 1)
          AND production_plan.material_analysis_id = plan_item.preparation_analysis_id
          AND production_plan.material_analysis_item_id =
              plan_item.preparation_analysis_item_id
    ) THEN
        RAISE EXCEPTION 'subcontract preparation FINISHED_IN reservation lineage is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_preparation_finished_source_guard';
    END IF;
END;
$$;

-- ====================== 6) 审计覆盖 ======================

CREATE TRIGGER trg_audit_preplan_subcontract_make_tasks
    AFTER INSERT OR UPDATE OR DELETE ON preplan_subcontract_make_tasks
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE TRIGGER trg_audit_preplan_subcontract_make_task_batches
    AFTER INSERT OR UPDATE OR DELETE ON preplan_subcontract_make_task_batches
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
