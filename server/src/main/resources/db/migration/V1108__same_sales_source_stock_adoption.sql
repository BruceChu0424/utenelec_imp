-- New analyses carry total-coverage source quantities; historical partial/net
-- quantities stay byte-for-byte unchanged and retain their legacy interpretation.
ALTER TABLE production_material_analysis_items ADD COLUMN planning_quantity_mode text NOT NULL DEFAULT 'LEGACY_INCREMENTAL'
    CHECK(planning_quantity_mode IN('LEGACY_INCREMENTAL','COVERAGE_TOTAL'));

-- Explicit planning acknowledgement of already-private sales stock. No stock
-- reservation is created, moved, released or relabelled as public by this ledger.
CREATE TABLE preplan_sales_stock_adoptions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    adoption_sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
    analysis_id uuid NOT NULL REFERENCES production_material_analyses(id),
    analysis_item_id uuid NOT NULL REFERENCES production_material_analysis_items(id),
    root_material_id uuid NOT NULL REFERENCES production_material_analysis_materials(id),
    reservation_id uuid NOT NULL REFERENCES stock_reservations(id),
    qty_base numeric(18,4) NOT NULL CHECK(qty_base>0),
    idempotency_key text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid NOT NULL REFERENCES users(id)
);
CREATE INDEX idx_preplan_sales_stock_adoption_reservation ON preplan_sales_stock_adoptions(reservation_id);
CREATE INDEX idx_preplan_sales_stock_adoption_item ON preplan_sales_stock_adoptions(analysis_item_id);
CREATE INDEX idx_preplan_sales_stock_adoption_analysis ON preplan_sales_stock_adoptions(analysis_id);
CREATE INDEX idx_preplan_sales_stock_adoption_root ON preplan_sales_stock_adoptions(root_material_id);
CREATE INDEX idx_preplan_sales_stock_adoption_actor ON preplan_sales_stock_adoptions(created_by);

CREATE OR REPLACE FUNCTION fn_preplan_adopted_sales_stock_base(item_id uuid)
RETURNS numeric LANGUAGE SQL STABLE AS $$
    SELECT COALESCE(SUM(LEAST(adopt.qty_base,GREATEST(reservation.qty-reservation.released_qty-
        COALESCE((SELECT SUM(previous.qty_base) FROM preplan_sales_stock_adoptions previous
          JOIN production_material_analyses previous_analysis ON previous_analysis.id=previous.analysis_id
          WHERE previous.reservation_id=adopt.reservation_id AND previous.id<>adopt.id
            AND previous.adoption_sequence<adopt.adoption_sequence
            AND NOT previous_analysis.is_deleted AND previous_analysis.status<>'CANCELLED'),0),0))),0)
    FROM preplan_sales_stock_adoptions adopt
    JOIN production_material_analyses analysis ON analysis.id=adopt.analysis_id
    JOIN stock_reservations reservation ON reservation.id=adopt.reservation_id
    WHERE adopt.analysis_item_id=item_id AND NOT analysis.is_deleted AND analysis.status<>'CANCELLED'
      AND NOT reservation.is_deleted
$$;

CREATE OR REPLACE FUNCTION fn_root_fulfilled_source_qty(item_id UUID)
RETURNS NUMERIC LANGUAGE SQL STABLE AS $$
    SELECT LEAST(GREATEST(item.requested_qty-item.submitted_qty-item.approved_qty,0),
           GREATEST(TRUNC((COALESCE((SELECT SUM(CASE WHEN event.event_kind='FULFILL'
                     THEN event.qty_base ELSE -event.qty_base END)
                     FROM preplan_root_output_events event WHERE event.analysis_item_id=item.id),0)
                 + fn_preplan_adopted_sales_stock_base(item.id))
                 / COALESCE(NULLIF(root.per_product_qty,0),1),4),0))
    FROM production_material_analysis_items item
    LEFT JOIN production_material_analysis_materials root ON root.id=item.root_material_id
    WHERE item.id=item_id
$$;

CREATE OR REPLACE FUNCTION fn_guard_preplan_sales_stock_adoption()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source production_material_analysis_items%ROWTYPE;
        material production_material_analysis_materials%ROWTYPE;
        reservation stock_reservations%ROWTYPE;
        used numeric;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'sales stock adoptions are append-only' USING ERRCODE='23514'; END IF;
    SELECT * INTO STRICT source FROM production_material_analysis_items WHERE id=NEW.analysis_item_id FOR UPDATE;
    SELECT * INTO STRICT material FROM production_material_analysis_materials WHERE id=NEW.root_material_id;
    SELECT * INTO STRICT reservation FROM stock_reservations WHERE id=NEW.reservation_id FOR UPDATE;
    IF source.analysis_id<>NEW.analysis_id OR source.root_material_id IS DISTINCT FROM NEW.root_material_id
       OR material.analysis_item_id<>source.id OR material.node_role<>'ROOT_SUPPLY'
       OR reservation.order_item_id IS DISTINCT FROM source.sales_order_item_id
       OR reservation.owner_type<>'SALES_ORDER_ITEM' OR reservation.owner_id IS DISTINCT FROM source.sales_order_item_id
       OR reservation.goods_id<>source.goods_id OR reservation.color_id IS DISTINCT FROM source.color_id
       OR reservation.source_doc_type NOT IN('SALES_ORDER','SALES_ORDER_CHANGE')
       OR reservation.status<>0 OR reservation.is_deleted OR source.is_deleted OR source.planning_quantity_mode<>'COVERAGE_TOTAL' THEN
        RAISE EXCEPTION 'sales stock adoption requires its unchanged private sales source' USING ERRCODE='23514';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM production_material_analyses analysis
        JOIN sales_order_items sales_item ON sales_item.id=source.sales_order_item_id
        JOIN sales_orders document ON document.id=sales_item.order_id
        WHERE analysis.id=NEW.analysis_id AND NOT analysis.is_deleted AND analysis.status IN('ACTIVE','PARTIALLY_PLANNED')
          AND NOT sales_item.is_deleted AND NOT document.is_deleted AND document.status=1 AND document.finance_confirmed
          AND NOT document.is_closed AND NOT document.is_stopped) THEN
        RAISE EXCEPTION 'sales stock adoption source is no longer eligible' USING ERRCODE='23514';
    END IF;
    SELECT COALESCE(SUM(adopt.qty_base),0) INTO used FROM preplan_sales_stock_adoptions adopt
      JOIN production_material_analyses analysis ON analysis.id=adopt.analysis_id
      WHERE adopt.reservation_id=NEW.reservation_id AND NOT analysis.is_deleted AND analysis.status<>'CANCELLED';
    IF used+NEW.qty_base>reservation.qty-reservation.consumed_qty-reservation.released_qty
       OR NEW.qty_base>(source.requested_qty-source.submitted_qty-source.approved_qty-source.root_fulfilled_qty)*material.per_product_qty THEN
        RAISE EXCEPTION 'sales stock adoption exceeds its remaining private source' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_preplan_sales_stock_adoption BEFORE INSERT OR UPDATE OR DELETE
    ON preplan_sales_stock_adoptions FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_sales_stock_adoption();
CREATE TRIGGER trg_project_preplan_sales_stock_adoption AFTER INSERT ON preplan_sales_stock_adoptions
    FOR EACH ROW EXECUTE FUNCTION fn_project_root_output_quantity();
CREATE TRIGGER trg_audit_preplan_sales_stock_adoption AFTER INSERT OR UPDATE OR DELETE
    ON preplan_sales_stock_adoptions FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE OR REPLACE FUNCTION fn_refresh_adopted_sales_stock_quantity()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='stock_reservations' THEN
        UPDATE production_material_analysis_items item
        SET root_fulfilled_qty=fn_root_fulfilled_source_qty(item.id),updated_at=now()
        WHERE item.id IN(SELECT adopt.analysis_item_id FROM preplan_sales_stock_adoptions adopt WHERE adopt.reservation_id=NEW.id);
    ELSE
        UPDATE production_material_analysis_items item
        SET root_fulfilled_qty=fn_root_fulfilled_source_qty(item.id),updated_at=now()
        WHERE item.analysis_id=NEW.id AND EXISTS(SELECT 1 FROM preplan_sales_stock_adoptions adopt WHERE adopt.analysis_item_id=item.id);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_refresh_adopted_sales_reservation AFTER UPDATE OF qty,released_qty,is_deleted
    ON stock_reservations FOR EACH ROW WHEN((OLD.qty,OLD.released_qty,OLD.is_deleted) IS DISTINCT FROM (NEW.qty,NEW.released_qty,NEW.is_deleted))
    EXECUTE FUNCTION fn_refresh_adopted_sales_stock_quantity();
CREATE TRIGGER trg_refresh_cancelled_sales_stock_adoption AFTER UPDATE OF status,is_deleted
    ON production_material_analyses FOR EACH ROW WHEN((OLD.status,OLD.is_deleted) IS DISTINCT FROM (NEW.status,NEW.is_deleted))
    EXECUTE FUNCTION fn_refresh_adopted_sales_stock_quantity();

COMMENT ON TABLE preplan_sales_stock_adoptions IS
  'Append-only acknowledgement of same-sales private stock by planning. Existing reservation identity, warehouse, ownership and shipment authority stay unchanged.';

CREATE OR REPLACE FUNCTION fn_guard_planning_quantity_mode()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.planning_quantity_mode IS DISTINCT FROM OLD.planning_quantity_mode THEN
        RAISE EXCEPTION 'planning source quantity basis is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_planning_quantity_mode BEFORE UPDATE OF planning_quantity_mode
    ON production_material_analysis_items FOR EACH ROW EXECUTE FUNCTION fn_guard_planning_quantity_mode();
