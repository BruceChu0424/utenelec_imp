-- V582: 销售出货仓库作业一步式确认出库。
--
-- 财务放行后，仓库原本要点四次（待拣货 → 开始拣货 → 拣货完成 → 交接出库），
-- 外加 EXCEPTION 登记异常/恢复待拣的回路。三个中间态既不占库存也不产生任何
-- 会计事实，只是把同一批校验拆成三次点击。本迁移把它们整体删除：
--
--     PENDING_PICK --（确认出库）--> SHIPPED
--
-- 在途老单统一拨回 PENDING_PICK 并释放其拣货占用；已 SHIPPED 的历史事实
-- （含 picking_started_*/picked_* 时间戳与事件账里的 PICKING/PICKED/EXCEPTION 行）
-- 一律原样保留——追加式事件账不可改写，也不伪造历史。
--
-- 覆盖声明：本迁移取代
--   · 162 号《V566 销售无仓提交与仓库实仓拣货》里「填仓发生在 PENDING_PICK → PICKING」
--     与「targetStatus=PICKING 时接受 warehouseId / stockPlaces」两条口径；
--   · ADR-030 关于「仓库开始作业后须先异常退拣才能财务反审」的表述；
--   · ADR-082 里「仅未放行且仓库未作业的退回单」中的「仓库未作业」判定
--     （现等价于「仍是 PENDING_PICK」）。

-- ---------------------------------------------------------------------------
-- 1) V566 的三个物理取证触发器改锚点：PICKING → SHIPPED
--    必须先于下面的数据拨回执行，否则拨回动作本身会被旧函数拦住。
-- ---------------------------------------------------------------------------

-- 1.1 选仓时机：一步式在同一事务里既改 warehouse_id 又把单据推到 SHIPPED。
--     事务中途的 flush 会先落一行「仍是 PENDING_PICK」的中间版本，最终版本
--     才与 status=1 一起变成 SHIPPED，两种形态都必须放行。
CREATE OR REPLACE FUNCTION fn_guard_sales_shipment_picking_warehouse() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' THEN
        IF NEW.warehouse_chosen_at_pick AND NEW.shipment_kind='LEGACY' THEN
            RAISE EXCEPTION 'Historical shipments cannot change warehouse-selection policy' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.warehouse_chosen_at_pick IS DISTINCT FROM OLD.warehouse_chosen_at_pick THEN
        RAISE EXCEPTION 'Shipment warehouse-selection mode is immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.warehouse_chosen_at_pick AND NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id THEN
        IF OLD.status<>0 OR NEW.status NOT IN (0,1)
           OR OLD.warehouse_work_status<>'PENDING_PICK'
           OR NEW.warehouse_work_status NOT IN ('PENDING_PICK','SHIPPED')
           OR (NEW.status=1 AND NEW.warehouse_work_status<>'SHIPPED')
           OR OLD.finance_audit<>1 OR NEW.finance_audit<>1
           OR NEW.review_revision<>OLD.review_revision OR NEW.warehouse_id IS NULL THEN
            RAISE EXCEPTION 'Physical shipment warehouse is selected only when a finance-released task confirms its outbound' USING ERRCODE='23514';
        END IF;
    END IF;
    -- 叶子仓校验不能只挂在「换仓」那一支：V582 把在途单拨回 PENDING_PICK 时保留了
    -- 上次选的仓，操作员再次选同一个仓时 warehouse_id 不变、整支会被跳过。
    -- 确认出库这一跳对推迟选仓的单据无条件复核，历史已出库行（OLD 已是 SHIPPED）不受影响。
    IF NEW.warehouse_chosen_at_pick
       AND (NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
            OR (OLD.warehouse_work_status='PENDING_PICK' AND NEW.warehouse_work_status='SHIPPED')) THEN
        IF NOT EXISTS(SELECT 1 FROM warehouses warehouse WHERE warehouse.id=NEW.warehouse_id
            AND NOT warehouse.is_deleted AND warehouse.is_accountable
            AND warehouse.status='使用' AND NOT EXISTS(SELECT 1 FROM warehouses child
                WHERE child.parent_id=warehouse.id AND NOT child.is_deleted)) THEN
            RAISE EXCEPTION 'Shipment outbound requires an active actual leaf warehouse' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END $$;

-- 1.4 财务门禁：唯一还能进入的实物态只剩 SHIPPED。
CREATE OR REPLACE FUNCTION fn_guard_sales_shipment_finance_release()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='UPDATE' AND OLD.finance_gate_version=0 AND OLD.status=0 AND OLD.warehouse_work_status='LEGACY_PENDING'
       AND (NEW.status IS DISTINCT FROM OLD.status OR NEW.finance_gate_version IS DISTINCT FROM OLD.finance_gate_version
            OR NEW.finance_audit IS DISTINCT FROM OLD.finance_audit OR NEW.finance_auditor_id IS DISTINCT FROM OLD.finance_auditor_id
            OR NEW.finance_audited_at IS DISTINCT FROM OLD.finance_audited_at OR NEW.warehouse_work_status IS DISTINCT FROM OLD.warehouse_work_status) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='legacy pending sales shipment is read-only and must be manually rebuilt';
    END IF;
    IF TG_OP='INSERT' AND NEW.finance_gate_version<>2
       AND COALESCE(current_setting('uten.legacy_reference_import',TRUE),'')='' THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='new customer shipments require the current confirmation workflow';
    END IF;
    IF TG_OP='UPDATE' AND NEW.finance_gate_version<OLD.finance_gate_version THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='sales shipment finance gate version cannot be downgraded';
    END IF;
    IF NEW.finance_gate_version>=1 THEN
        IF NEW.finance_audit NOT IN (0,1)
           OR (NEW.finance_audit=0 AND (NEW.finance_auditor_id IS NOT NULL OR NEW.finance_audited_at IS NOT NULL))
           OR (NEW.finance_audit=1 AND (NEW.finance_auditor_id IS NULL OR NEW.finance_audited_at IS NULL)) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='sales shipment finance audit facts are incomplete';
        END IF;
        IF NEW.warehouse_work_status='SHIPPED' AND NEW.finance_audit<>1 THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='finance approval is required before warehouse outbound';
        END IF;
    END IF;
    RETURN NEW;
END $$;

-- 1.2 已出库单必须有一条与表头逐字段相等的不可变实仓事件。
--     新流程按 SHIPPED 事件 + handed_over_by/at 取证；V582 之前的历史单
--     仍按原 PICKING 事件 + picking_started_by/at 取证，两条分支都算数。
CREATE OR REPLACE FUNCTION fn_assert_sales_shipment_picking_warehouse() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE document sales_shipments%ROWTYPE;
BEGIN
    SELECT * INTO document FROM sales_shipments WHERE id=NEW.id;
    IF document.warehouse_chosen_at_pick AND document.warehouse_work_status='SHIPPED' THEN
        IF document.warehouse_id IS NULL OR NOT EXISTS(SELECT 1 FROM sales_shipment_warehouse_events event
            WHERE event.shipment_id=document.id
              AND event.warehouse_id=document.warehouse_id
              AND event.review_revision=document.review_revision
              AND ((event.to_status='SHIPPED'
                      AND event.actor_employee_id=document.handed_over_by
                      AND event.occurred_at=document.handed_over_at)
                OR (event.to_status='PICKING'
                      AND event.actor_employee_id=document.picking_started_by
                      AND event.occurred_at=document.picking_started_at))) THEN
            RAISE EXCEPTION 'Physical shipment warehouse requires an immutable warehouse outbound event' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NULL;
END $$;

-- 1.3 库位证据改挂在确认出库那一条事件上。写入该事件时单据必须仍是
--     财务已放行的 PENDING_PICK——status=1/SHIPPED 由同事务末尾一起落盘。
CREATE OR REPLACE FUNCTION fn_guard_sales_shipment_picking_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE document sales_shipments%ROWTYPE; entry RECORD;
BEGIN
    IF NEW.to_status<>'SHIPPED' THEN
        IF NEW.line_stock_places<>'{}'::jsonb THEN
            RAISE EXCEPTION 'Actual stock locations are recorded by the outbound confirmation' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    SELECT * INTO document FROM sales_shipments WHERE id=NEW.shipment_id;
    IF NEW.warehouse_id IS DISTINCT FROM document.warehouse_id OR NEW.review_revision IS DISTINCT FROM document.review_revision
       OR document.warehouse_work_status<>'PENDING_PICK' OR document.finance_audit<>1
       OR NEW.actor_employee_id IS DISTINCT FROM document.handed_over_by
       OR NEW.occurred_at IS DISTINCT FROM document.handed_over_at THEN
        RAISE EXCEPTION 'Outbound evidence must match the finance-released physical execution' USING ERRCODE='23514';
    END IF;
    FOR entry IN SELECT * FROM jsonb_each(NEW.line_stock_places) LOOP
        IF entry.key !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
           OR jsonb_typeof(entry.value)<>'string' OR length(entry.value#>>'{}')>200 THEN
            RAISE EXCEPTION 'Outbound locations require exact shipment item UUIDs and at most 200 characters' USING ERRCODE='23514';
        END IF;
        IF NOT EXISTS(SELECT 1 FROM sales_shipment_items item WHERE item.id=entry.key::uuid
            AND item.shipment_id=document.id AND NOT item.is_deleted) THEN
            RAISE EXCEPTION 'Outbound location does not belong to this shipment' USING ERRCODE='23514';
        END IF;
    END LOOP;
    RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------
-- 2) 在途老单拨回待出库
-- ---------------------------------------------------------------------------

-- 2.1 失败闸：中间态的单据不可能已经消耗过拣货占用。真出现就是状态与出库事实
--     矛盾，必须人工核对，禁止盲拨。
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM stock_reservations reservation
        JOIN sales_shipments document ON document.id = reservation.source_doc_id
        WHERE reservation.owner_type = 'CUSTOMER_SHIPMENT_ITEM'
          AND reservation.source_doc_type = 'SALES_SHIPMENT'
          AND NOT reservation.is_deleted AND reservation.status = 0
          AND reservation.consumed_qty > 0
          AND document.warehouse_work_status IN ('PICKING','PICKED','EXCEPTION')) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='在途客户零星发货存在已消耗的拣货占用，状态与出库事实矛盾，必须人工核对后再升级';
    END IF;
END $$;

-- 2.2 释放在途拣货占用（与 CustomerShipmentInventoryService.releaseUnpicked 同语义）。
--     EXCEPTION 态同样持有占用：原 EXCEPTION 分支不释放，只有显式恢复待拣才释放。
--     不释放会同时造成幽灵占用、单据永远不可编辑/删除，以及新占用撞
--     uq_customer_shipment_item_active_reservation 唯一索引。
UPDATE stock_reservations reservation
SET released_qty   = reservation.qty,
    status         = 1,
    release_reason = 'CUSTOMER_SHIPMENT_UNPICKED',
    updated_at     = now()
FROM sales_shipments document
WHERE document.id = reservation.source_doc_id
  AND reservation.owner_type      = 'CUSTOMER_SHIPMENT_ITEM'
  AND reservation.source_doc_type = 'SALES_SHIPMENT'
  AND reservation.status = 0 AND NOT reservation.is_deleted AND reservation.consumed_qty = 0
  AND document.warehouse_work_status IN ('PICKING','PICKED','EXCEPTION');

-- 2.3 追加事件账留证（append-only，必须先于状态列改写，from_status 才是真实旧态）。
--     from_status='EXCEPTION' → to_status='PENDING_PICK' 按 V188 要求必须带原因。
INSERT INTO sales_shipment_warehouse_events (
    shipment_id, from_status, to_status, reason, actor_employee_id, occurred_at)
SELECT id, warehouse_work_status, 'PENDING_PICK',
       'V582 仓库作业一步式改造：在途拣货任务统一拨回待出库并释放拣货占用',
       warehouse_work_updated_by, now()
FROM sales_shipments
WHERE warehouse_work_status IN ('PICKING','PICKED','EXCEPTION');

-- 2.4 拨回状态列。picking/picked 时间戳一并清空：留着会产生「待出库却带拣货时间」
--     的自相矛盾行。已 SHIPPED 的历史行不在本次范围内，其时间戳原样保留。
UPDATE sales_shipments
SET warehouse_work_status      = 'PENDING_PICK',
    picking_started_at         = NULL,
    picking_started_by         = NULL,
    picked_at                  = NULL,
    picked_by                  = NULL,
    warehouse_exception_reason = NULL,
    warehouse_work_updated_at  = now()
WHERE warehouse_work_status IN ('PICKING','PICKED','EXCEPTION');

-- 2.5 重开待办通知：这批单当年「开始拣货」时以 WAREHOUSE_STARTED 办结过，
--     拨回后红徽章会自动恢复（角标读 sales_shipments 表），但待办弹窗/审核收件台
--     读的是 notices 行，不重开就永远看不到。只改值不改行数。
UPDATE notices
SET resolved_at = NULL, resolved_reason = NULL
WHERE aggregate_kind = 'SALES_SHIPMENT'
  AND resolved_reason = 'WAREHOUSE_STARTED'
  AND aggregate_id IN (
      SELECT id FROM sales_shipments
      WHERE status = 0 AND NOT is_deleted AND NOT rejected
        AND finance_audit = 1 AND warehouse_work_status = 'PENDING_PICK');

-- ---------------------------------------------------------------------------
-- 3) 收窄表头状态白名单与配套索引/视图
-- ---------------------------------------------------------------------------

ALTER TABLE sales_shipments
    DROP CONSTRAINT IF EXISTS sales_shipments_warehouse_work_status_chk;
ALTER TABLE sales_shipments
    ADD CONSTRAINT sales_shipments_warehouse_work_status_chk CHECK (
        warehouse_work_status IN (
            'LEGACY_PENDING',
            'PENDING_PICK',
            'SHIPPED',
            'CANCELLED',
            'REVERSED'
        )
    );

COMMENT ON COLUMN sales_shipments.warehouse_work_status IS
    '仓库执行状态：财务放行后 PENDING_PICK →（仓库一步确认出库）→ SHIPPED；历史草稿 LEGACY_PENDING 只读。V582 起没有 PICKING/PICKED/EXCEPTION 中间态';
COMMENT ON COLUMN sales_shipments.picking_started_at IS
    'V582 前两阶段拣货的历史证据；一步式确认出库只留 handed_over_at，不再写入本列';
COMMENT ON COLUMN sales_shipments.picked_at IS
    'V582 前两阶段拣货的历史证据；一步式确认出库只留 handed_over_at，不再写入本列';
COMMENT ON COLUMN sales_shipment_warehouse_events.line_stock_places IS
    'Actual outbound location text keyed by exact shipment item UUID, separate from current goods placement hints.';

-- 待办角标（countPendingWarehouseWork）的部分索引谓词必须与新枚举逐值一致，
-- 否则 60s 轮询的计数查询用不上索引。
DROP INDEX IF EXISTS idx_sales_shipments_warehouse_pending;
CREATE INDEX idx_sales_shipments_warehouse_pending
    ON sales_shipments (warehouse_work_status)
    WHERE finance_audit = 1
      AND rejected = FALSE
      AND is_deleted = FALSE
      AND warehouse_work_status IN ('LEGACY_PENDING','PENDING_PICK');

-- 财务门禁迁移异常清单：去掉已不存在的三个状态，避免口径撒谎。
CREATE OR REPLACE VIEW v_sales_shipment_finance_gate_migration_exceptions AS
SELECT id AS shipment_id,
       legacy_id,
       bill_no,
       status,
       warehouse_work_status,
       finance_audit,
       finance_gate_version
FROM sales_shipments
WHERE COALESCE(is_deleted, FALSE) = FALSE
  AND finance_gate_version = 0
  AND status = 0
  AND warehouse_work_status IN ('LEGACY_PENDING', 'PENDING_PICK');
