-- V307: 计划前物料分析合格入库的精确行归属子账。
--
-- V298 把 IQC PASS 形成的库存预留绑定到 analysis_id，能阻止其它分析抢占，
-- 但同一分析内相同物料的多个产品/BOM 路径仍共用一个池。本迁移保留
-- stock_reservations 作为唯一物理预留账，并以一对一子账记录：
--   供应行动分摊行 -> 原始物料分析行 -> 当前受益物料分析行。
-- origin_* 永久保存采购/委外到货的原始谱系；beneficiary_* 仅预留给未来经过
-- 显式审批的跨分析调拨/归还账。V307 初始必须等于 origin_* 且整行禁止更新，
-- 只有补齐 entitlement/loan/可逆转移桥后，新的前向迁移才可替换本守卫。
-- 历史 V298 预留不回填：没有子账的 PREPLAN_ANALYSIS 预留继续按分析级池处理。

ALTER TABLE preplan_supply_action_allocations
    ADD CONSTRAINT preplan_supply_action_allocations_analysis_id_id_uk
        UNIQUE (analysis_id, id);

CREATE TABLE preplan_analysis_stock_exact_pegs (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    stock_reservation_id            UUID NOT NULL
        REFERENCES stock_reservations(id) ON DELETE RESTRICT,
    supply_action_allocation_id     UUID NOT NULL,
    origin_analysis_id              UUID NOT NULL,
    origin_analysis_material_id     UUID NOT NULL,
    beneficiary_analysis_id         UUID NOT NULL,
    beneficiary_analysis_material_id UUID NOT NULL,
    qty                             NUMERIC(18,4) NOT NULL,
    source_receipt_type             TEXT NOT NULL,
    source_receipt_id               UUID NOT NULL,
    source_disposition_event_id     UUID NOT NULL
        REFERENCES procurement_inspection_events(id) ON DELETE RESTRICT,
    beneficiary_reason              TEXT NOT NULL DEFAULT 'ORIGIN_RECEIPT',
    idempotency_key                 TEXT NOT NULL,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                      UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    updated_by                      UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT preplan_exact_peg_qty_chk CHECK (qty > 0),
    CONSTRAINT preplan_exact_peg_receipt_type_chk
        CHECK (source_receipt_type IN ('PURCHASE', 'SUBCONTRACT')),
    CONSTRAINT preplan_exact_peg_reason_chk CHECK (
        beneficiary_reason = btrim(beneficiary_reason)
        AND length(beneficiary_reason) BETWEEN 2 AND 1000),
    CONSTRAINT preplan_exact_peg_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 200),
    CONSTRAINT preplan_exact_peg_origin_allocation_fk
        FOREIGN KEY (origin_analysis_id, supply_action_allocation_id)
        REFERENCES preplan_supply_action_allocations(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_exact_peg_origin_material_fk
        FOREIGN KEY (origin_analysis_id, origin_analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_exact_peg_beneficiary_material_fk
        FOREIGN KEY (beneficiary_analysis_id, beneficiary_analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_exact_peg_reservation_uk UNIQUE (stock_reservation_id),
    CONSTRAINT preplan_exact_peg_idempotency_uk UNIQUE (idempotency_key)
);

CREATE INDEX idx_preplan_exact_peg_beneficiary
    ON preplan_analysis_stock_exact_pegs(
        beneficiary_analysis_id, beneficiary_analysis_material_id,
        stock_reservation_id);

CREATE INDEX idx_preplan_exact_peg_origin_allocation
    ON preplan_analysis_stock_exact_pegs(
        origin_analysis_id, supply_action_allocation_id);

CREATE INDEX idx_preplan_exact_peg_receipt
    ON preplan_analysis_stock_exact_pegs(
        source_receipt_type, source_receipt_id, source_disposition_event_id);

-- 行身份与数量守恒。库存锁把同一 goods/color 的并发 PASS 串行化；本约束触发器
-- 再 fail closed，防止绕过服务直接伪造错误的物料行、受益行或超分摊数量。
CREATE OR REPLACE FUNCTION fn_check_preplan_analysis_stock_exact_peg()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_reservation stock_reservations%ROWTYPE;
    v_allocation preplan_supply_action_allocations%ROWTYPE;
    v_origin production_material_analysis_materials%ROWTYPE;
    v_beneficiary production_material_analysis_materials%ROWTYPE;
    v_event procurement_inspection_events%ROWTYPE;
    v_inspection procurement_inspection_items%ROWTYPE;
    v_total NUMERIC(18,4);
    v_event_total NUMERIC(18,4);
BEGIN
    SELECT * INTO v_reservation
    FROM stock_reservations
    WHERE id = NEW.stock_reservation_id;

    SELECT * INTO v_allocation
    FROM preplan_supply_action_allocations
    WHERE id = NEW.supply_action_allocation_id
    FOR UPDATE;

    SELECT * INTO v_origin
    FROM production_material_analysis_materials
    WHERE id = NEW.origin_analysis_material_id;

    SELECT * INTO v_beneficiary
    FROM production_material_analysis_materials
    WHERE id = NEW.beneficiary_analysis_material_id;

    SELECT * INTO v_event
    FROM procurement_inspection_events
    WHERE id = NEW.source_disposition_event_id
    FOR UPDATE;

    SELECT * INTO v_inspection
    FROM procurement_inspection_items
    WHERE id = v_event.inspection_item_id;

    IF v_reservation.id IS NULL
       OR v_allocation.id IS NULL
       OR v_origin.id IS NULL
       OR v_beneficiary.id IS NULL
       OR v_event.id IS NULL
       OR v_inspection.id IS NULL
       OR v_reservation.owner_type <> 'PREPLAN_ANALYSIS'
       OR v_reservation.purpose <> 'PREPLAN_MATERIAL'
       OR v_reservation.is_deleted IS DISTINCT FROM FALSE
       OR v_reservation.status <> 0
       OR v_reservation.consumed_qty <> 0
       OR v_reservation.released_qty <> 0
       OR v_reservation.owner_id <> NEW.origin_analysis_id
       OR v_reservation.qty IS DISTINCT FROM NEW.qty
       OR v_reservation.source_doc_type
            <> NEW.source_receipt_type || '_RECEIPT'
       OR v_reservation.source_doc_id <> NEW.source_receipt_id
       OR v_reservation.supply_id IS DISTINCT FROM v_allocation.external_item_id
       OR (NEW.source_receipt_type = 'PURCHASE'
           AND v_reservation.supply_type <> 'PURCHASE_REQUEST_ITEM')
       OR (NEW.source_receipt_type = 'SUBCONTRACT'
           AND v_reservation.supply_type <> 'SUBCONTRACT_APPLICATION_ITEM')
       OR v_allocation.analysis_id <> NEW.origin_analysis_id
       OR v_allocation.analysis_material_id <> NEW.origin_analysis_material_id
       OR v_origin.analysis_id <> NEW.origin_analysis_id
       OR v_beneficiary.analysis_id <> NEW.beneficiary_analysis_id
       OR v_origin.goods_id <> v_reservation.goods_id
       OR v_origin.color_id IS DISTINCT FROM v_reservation.color_id
       OR v_beneficiary.goods_id <> v_origin.goods_id
       OR v_beneficiary.color_id IS DISTINCT FROM v_origin.color_id
       OR v_beneficiary.unit_id <> v_origin.unit_id
       OR v_event.action <> 'PASS'
       OR v_event.base_qty < NEW.qty
       OR v_inspection.receipt_type <> NEW.source_receipt_type
       OR v_inspection.receipt_id <> NEW.source_receipt_id
       OR v_inspection.warehouse_id <> v_reservation.warehouse_id
       OR v_inspection.goods_id <> v_reservation.goods_id
       OR v_inspection.color_id IS DISTINCT FROM v_reservation.color_id
       OR v_inspection.unit_id <> v_origin.unit_id
       OR (NEW.source_receipt_type = 'PURCHASE' AND NOT EXISTS (
           SELECT 1
           FROM purchase_receipt_items receipt_item
           JOIN purchase_order_items order_item
             ON order_item.id = receipt_item.order_item_id
            AND order_item.is_deleted = FALSE
           WHERE receipt_item.id = v_inspection.receipt_item_id
             AND receipt_item.receipt_id = NEW.source_receipt_id
             AND receipt_item.is_deleted = FALSE
             AND order_item.request_item_id = v_allocation.external_item_id
       ))
       OR (NEW.source_receipt_type = 'SUBCONTRACT' AND NOT EXISTS (
           SELECT 1
           FROM subcontract_receipt_items receipt_item
           JOIN subcontract_order_items order_item
             ON order_item.id = receipt_item.order_item_id
            AND order_item.is_deleted = FALSE
           WHERE receipt_item.id = v_inspection.receipt_item_id
             AND receipt_item.receipt_id = NEW.source_receipt_id
             AND receipt_item.is_deleted = FALSE
             AND order_item.application_item_id = v_allocation.external_item_id
       )) THEN
        RAISE EXCEPTION 'invalid preplan exact stock peg identity or dimension'
            USING ERRCODE = '23514';
    END IF;

    IF TG_OP = 'INSERT'
       AND (NEW.beneficiary_analysis_id <> NEW.origin_analysis_id
            OR NEW.beneficiary_analysis_material_id
                <> NEW.origin_analysis_material_id
            OR NEW.beneficiary_reason <> 'ORIGIN_RECEIPT') THEN
        RAISE EXCEPTION 'new preplan exact stock peg must start at its origin material'
            USING ERRCODE = '23514';
    END IF;

    SELECT COALESCE(SUM(CASE
               WHEN reservation.release_reason = 'TRANSFERRED_TO_PLAN'
               THEN peg.qty
               ELSE reservation.qty - reservation.consumed_qty
                    - reservation.released_qty
           END), 0) INTO v_total
    FROM preplan_analysis_stock_exact_pegs peg
    JOIN stock_reservations reservation
      ON reservation.id = peg.stock_reservation_id
    WHERE peg.supply_action_allocation_id = NEW.supply_action_allocation_id
      AND peg.id <> NEW.id
      AND reservation.is_deleted = FALSE
      AND (reservation.status = 0
           OR reservation.release_reason = 'TRANSFERRED_TO_PLAN');

    IF v_total + GREATEST(
            v_reservation.qty - v_reservation.consumed_qty
                - v_reservation.released_qty, 0)
       > v_allocation.allocated_qty THEN
        RAISE EXCEPTION 'preplan exact stock peg exceeds supply allocation capacity'
            USING ERRCODE = '23514';
    END IF;

    SELECT COALESCE(SUM(peg.qty), 0) INTO v_event_total
    FROM preplan_analysis_stock_exact_pegs peg
    WHERE peg.source_disposition_event_id = NEW.source_disposition_event_id
      AND peg.id <> NEW.id;
    IF v_event_total + NEW.qty > v_event.base_qty THEN
        RAISE EXCEPTION 'preplan exact stock pegs exceed IQC PASS event quantity'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_check_preplan_analysis_stock_exact_peg
    AFTER INSERT OR UPDATE ON preplan_analysis_stock_exact_pegs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE FUNCTION fn_check_preplan_analysis_stock_exact_peg();

-- V307 尚无跨分析 entitlement/loan/可逆转移桥，故 exact 子账整行不可更新或删除。
-- beneficiary_* 只是无破坏的 schema 扩展点，不是可绕过业务边界的写入口。
CREATE OR REPLACE FUNCTION fn_guard_preplan_analysis_stock_exact_peg()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'preplan exact stock pegs are append-only'
            USING ERRCODE = '55000';
    END IF;
    RAISE EXCEPTION 'preplan exact stock peg origin and beneficiary are immutable until an approved transfer ledger exists'
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_guard_preplan_analysis_stock_exact_peg
    BEFORE UPDATE OR DELETE ON preplan_analysis_stock_exact_pegs
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_analysis_stock_exact_peg();

-- Material rows are refreshable projections, but any row named by an exact peg has
-- immutable business identity/dimension. active may toggle inside refresh and is checked
-- by the deferred final-state constraint below.
CREATE OR REPLACE FUNCTION fn_guard_pma_material_exact_peg_identity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM preplan_analysis_stock_exact_pegs peg
        WHERE peg.origin_analysis_material_id = OLD.id
           OR peg.beneficiary_analysis_material_id = OLD.id
    ) AND (
        NEW.analysis_id IS DISTINCT FROM OLD.analysis_id
        OR NEW.analysis_item_id IS DISTINCT FROM OLD.analysis_item_id
        OR NEW.node_key IS DISTINCT FROM OLD.node_key
        OR NEW.goods_id IS DISTINCT FROM OLD.goods_id
        OR NEW.color_id IS DISTINCT FROM OLD.color_id
        OR NEW.unit_id IS DISTINCT FROM OLD.unit_id
    ) THEN
        RAISE EXCEPTION 'material identity referenced by a preplan exact stock peg is immutable'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_pma_material_exact_peg_identity
    BEFORE UPDATE OF analysis_id, analysis_item_id, node_key, goods_id, color_id, unit_id
    ON production_material_analysis_materials
    FOR EACH ROW EXECUTE FUNCTION fn_guard_pma_material_exact_peg_identity();

CREATE OR REPLACE FUNCTION fn_validate_pma_material_exact_peg_endpoint()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM preplan_analysis_stock_exact_pegs peg
        JOIN stock_reservations reservation
          ON reservation.id = peg.stock_reservation_id
         AND reservation.is_deleted = FALSE
         AND reservation.status = 0
        JOIN procurement_inspection_events event
          ON event.id = peg.source_disposition_event_id
        JOIN procurement_inspection_items inspection
          ON inspection.id = event.inspection_item_id
        LEFT JOIN production_material_analysis_materials beneficiary
          ON beneficiary.id = peg.beneficiary_analysis_material_id
         AND beneficiary.analysis_id = peg.beneficiary_analysis_id
        WHERE peg.beneficiary_analysis_material_id = NEW.id
          AND (
              beneficiary.id IS NULL
              OR beneficiary.active IS DISTINCT FROM TRUE
              OR beneficiary.goods_id IS DISTINCT FROM reservation.goods_id
              OR beneficiary.color_id IS DISTINCT FROM reservation.color_id
              OR beneficiary.unit_id IS DISTINCT FROM inspection.unit_id
          )
    ) THEN
        RAISE EXCEPTION 'effective preplan exact stock peg requires an active matching material endpoint'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_pma_material_exact_peg_endpoint
    AFTER INSERT OR UPDATE ON production_material_analysis_materials
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_pma_material_exact_peg_endpoint();

CREATE TRIGGER trg_audit_preplan_analysis_stock_exact_pegs
    AFTER INSERT OR UPDATE OR DELETE ON preplan_analysis_stock_exact_pegs
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE preplan_analysis_stock_exact_pegs IS
    'V307 IQC PASS 精确归属子账；物理预留仍唯一记录在 stock_reservations，历史 V298 无子账行保持分析级兼容';
COMMENT ON COLUMN preplan_analysis_stock_exact_pegs.origin_analysis_material_id IS
    '不可变原始物料分析行：来自 preplan_supply_action_allocations 的精确供应容量';
COMMENT ON COLUMN preplan_analysis_stock_exact_pegs.beneficiary_analysis_material_id IS
    '预留受益物料分析行；V307 初始等于 origin 且禁止更新，未来须由完整调拨/归还账的前向迁移显式放开';
