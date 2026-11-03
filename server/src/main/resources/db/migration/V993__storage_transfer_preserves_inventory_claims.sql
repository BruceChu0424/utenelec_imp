-- Storage locations share fulfillment claims within their main warehouse.
-- The reservation ID, owner, original supply and lifecycle never change on a move.
-- Defective warehouses and workshop custody remain separate physical channels.
CREATE FUNCTION fn_stock_storage_same_pool(p_origin UUID,p_actual UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT COALESCE(p_origin=p_actual OR (
   fn_warehouse_same_main(p_origin,p_actual)
   AND EXISTS(SELECT 1 FROM warehouses WHERE id=p_origin AND NOT is_deleted
     AND is_accountable AND NOT is_defective AND NOT is_line_side)
   AND EXISTS(SELECT 1 FROM warehouses WHERE id=p_actual AND NOT is_deleted
     AND is_accountable AND NOT is_defective AND NOT is_line_side)),FALSE)
$$;

CREATE TABLE stock_reservation_storage_positions(
 reservation_id UUID NOT NULL REFERENCES stock_reservations(id),
 warehouse_id UUID NOT NULL REFERENCES warehouses(id),
 qty NUMERIC(18,4) NOT NULL CHECK(qty>=0),
 PRIMARY KEY(reservation_id,warehouse_id));
CREATE TABLE stock_reservation_storage_events(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 reservation_id UUID NOT NULL REFERENCES stock_reservations(id),
 event_type TEXT NOT NULL CHECK(event_type IN('OPEN','TRANSFER','REVERSE','CONSUME','RESTORE','RELEASE')),
 from_warehouse_id UUID REFERENCES warehouses(id),to_warehouse_id UUID REFERENCES warehouses(id),
 qty NUMERIC(18,4) NOT NULL CHECK(qty>0),
 document_id UUID,document_item_id UUID,
 reverse_of UUID UNIQUE REFERENCES stock_reservation_storage_events(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),transaction_id XID8 NOT NULL DEFAULT pg_current_xact_id());
CREATE INDEX idx_stock_storage_event_document ON stock_reservation_storage_events(document_id,document_item_id);
CREATE INDEX idx_stock_storage_event_reservation ON stock_reservation_storage_events(reservation_id,created_at,id);
CREATE INDEX idx_stock_storage_position_warehouse ON stock_reservation_storage_positions(warehouse_id,reservation_id) INCLUDE(qty);
CREATE INDEX idx_stock_storage_claim_dimension ON stock_reservations(goods_id,color_id,id)
 INCLUDE(warehouse_id,order_item_id,qty,consumed_qty,released_qty) WHERE NOT is_deleted AND status=0;

CREATE FUNCTION fn_stock_storage_history_immutable() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION '仓库流转与锁定来源记录只允许追加' USING ERRCODE='23514'; END $$;
CREATE TRIGGER trg_stock_storage_history_immutable BEFORE UPDATE OR DELETE ON stock_reservation_storage_events
 FOR EACH ROW EXECUTE FUNCTION fn_stock_storage_history_immutable();
CREATE TRIGGER trg_stock_storage_position_no_delete BEFORE DELETE ON stock_reservation_storage_positions
 FOR EACH ROW EXECUTE FUNCTION fn_stock_storage_history_immutable();

CREATE FUNCTION fn_guard_stock_storage_transfer_event() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE original stock_reservation_storage_events%ROWTYPE; document stock_documents%ROWTYPE;
 item stock_document_items%ROWTYPE; moved NUMERIC;
BEGIN
 IF NEW.event_type='TRANSFER' THEN
   SELECT * INTO STRICT document FROM stock_documents WHERE id=NEW.document_id;
   SELECT * INTO STRICT item FROM stock_document_items WHERE id=NEW.document_item_id AND doc_id=document.id;
   SELECT COALESCE(SUM(event.qty),0) INTO moved FROM stock_reservation_storage_events event
     WHERE event.document_id=document.id AND event.document_item_id=item.id AND event.event_type='TRANSFER'
       AND NOT EXISTS(SELECT 1 FROM stock_reservation_storage_events counter WHERE counter.reverse_of=event.id);
   IF document.doc_type<>'TRANSFER' OR document.transfer_kind<>'NORMAL'
     OR NEW.from_warehouse_id<>document.warehouse_id OR NEW.to_warehouse_id<>document.to_warehouse_id
     OR moved+NEW.qty>item.base_qty
     OR NOT EXISTS(SELECT 1 FROM stock_reservations r WHERE r.id=NEW.reservation_id
       AND r.goods_id=item.goods_id AND r.color_id IS NOT DISTINCT FROM item.color_id)
     OR NOT EXISTS(SELECT 1 FROM stock_movements m WHERE m.source_doc_type='STOCK_DOC'
       AND m.source_doc_id=document.id AND m.source_item_id=item.id AND m.direction=-1 AND m.movement_type=8
       AND m.warehouse_id=NEW.from_warehouse_id AND m.qty=item.base_qty AND m.xmin=pg_current_xact_id()::xid)
     OR NOT EXISTS(SELECT 1 FROM stock_movements m WHERE m.source_doc_type='STOCK_DOC'
       AND m.source_doc_id=document.id AND m.source_item_id=item.id AND m.direction=1 AND m.movement_type=7
       AND m.warehouse_id=NEW.to_warehouse_id AND m.qty=item.base_qty AND m.xmin=pg_current_xact_id()::xid) THEN
     RAISE EXCEPTION '锁定移仓缺少同一事务的两仓实物调拨凭证' USING ERRCODE='23514';
   END IF;
 ELSIF NEW.event_type='REVERSE' THEN
   SELECT * INTO STRICT original FROM stock_reservation_storage_events WHERE id=NEW.reverse_of;
   IF original.event_type<>'TRANSFER' OR NEW.reservation_id<>original.reservation_id OR NEW.qty<>original.qty
     OR NEW.from_warehouse_id<>original.to_warehouse_id OR NEW.to_warehouse_id<>original.from_warehouse_id
     OR NEW.document_id<>original.document_id OR NEW.document_item_id<>original.document_item_id THEN
     RAISE EXCEPTION '锁定调回必须镜像原调拨来源' USING ERRCODE='23514';
   END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_stock_storage_transfer_event BEFORE INSERT ON stock_reservation_storage_events
 FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_storage_transfer_event();

CREATE FUNCTION fn_stock_claim_open_at(p_reservation UUID,p_warehouse UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT COALESCE((SELECT CASE WHEN EXISTS(SELECT 1 FROM stock_reservation_storage_positions WHERE reservation_id=r.id)
   THEN COALESCE((SELECT qty FROM stock_reservation_storage_positions WHERE reservation_id=r.id AND warehouse_id=p_warehouse),0)
   WHEN r.warehouse_id IS NULL OR r.warehouse_id=p_warehouse THEN r.qty-r.consumed_qty-r.released_qty ELSE 0 END
   FROM stock_reservations r WHERE r.id=p_reservation AND NOT r.is_deleted AND r.status=0),0)
$$;

CREATE VIEW v_stock_reservation_storage_locations AS
SELECT r.id AS reservation_id,r.order_item_id,r.goods_id,r.color_id,r.owner_type,r.owner_id,
 p.warehouse_id,p.qty AS open_qty
FROM stock_reservations r JOIN stock_reservation_storage_positions p ON p.reservation_id=r.id
WHERE NOT r.is_deleted AND r.status=0 AND p.qty>0
UNION ALL
SELECT r.id,r.order_item_id,r.goods_id,r.color_id,r.owner_type,r.owner_id,r.warehouse_id,
 r.qty-r.consumed_qty-r.released_qty
FROM stock_reservations r WHERE NOT r.is_deleted AND r.status=0
 AND r.qty-r.consumed_qty-r.released_qty>0
 AND NOT EXISTS(SELECT 1 FROM stock_reservation_storage_positions p WHERE p.reservation_id=r.id);

CREATE FUNCTION fn_stock_claim_consume(p_reservation UUID,p_warehouse UUID,p_qty NUMERIC,p_doc UUID,p_item UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM stock_reservation_storage_positions WHERE reservation_id=p_reservation) THEN RETURN; END IF;
 UPDATE stock_reservation_storage_positions SET qty=qty-p_qty
 WHERE reservation_id=p_reservation AND warehouse_id=p_warehouse AND qty>=p_qty;
 IF NOT FOUND THEN RAISE EXCEPTION '原任务在实际取料仓的锁定数量不足' USING ERRCODE='23514'; END IF;
 INSERT INTO stock_reservation_storage_events(reservation_id,event_type,from_warehouse_id,qty,document_id,document_item_id)
 VALUES(p_reservation,'CONSUME',p_warehouse,p_qty,p_doc,p_item);
END $$;

CREATE FUNCTION fn_stock_claim_restore(p_reservation UUID,p_warehouse UUID,p_qty NUMERIC,p_doc UUID,p_item UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM stock_reservation_storage_positions WHERE reservation_id=p_reservation) THEN RETURN; END IF;
 INSERT INTO stock_reservation_storage_positions VALUES(p_reservation,p_warehouse,p_qty)
 ON CONFLICT(reservation_id,warehouse_id) DO UPDATE SET qty=stock_reservation_storage_positions.qty+EXCLUDED.qty;
 INSERT INTO stock_reservation_storage_events(reservation_id,event_type,to_warehouse_id,qty,document_id,document_item_id)
 VALUES(p_reservation,'RESTORE',p_warehouse,p_qty,p_doc,p_item);
END $$;

CREATE FUNCTION fn_stock_claim_storage_lifecycle() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE remaining NUMERIC; part RECORD; take NUMERIC;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM stock_reservation_storage_positions WHERE reservation_id=NEW.id) THEN RETURN NEW; END IF;
 remaining:=NEW.released_qty-OLD.released_qty;
 IF remaining<0 THEN RAISE EXCEPTION '已移仓预留不能无来源恢复释放量' USING ERRCODE='23514'; END IF;
 FOR part IN SELECT * FROM stock_reservation_storage_positions WHERE reservation_id=NEW.id ORDER BY warehouse_id FOR UPDATE LOOP
   EXIT WHEN remaining<=0;
   take:=LEAST(part.qty,remaining);
   IF take>0 THEN
     UPDATE stock_reservation_storage_positions SET qty=qty-take WHERE reservation_id=NEW.id AND warehouse_id=part.warehouse_id;
     INSERT INTO stock_reservation_storage_events(reservation_id,event_type,from_warehouse_id,qty)
     VALUES(NEW.id,'RELEASE',part.warehouse_id,take);
     remaining:=remaining-take;
   END IF;
 END LOOP;
 IF remaining>0 THEN RAISE EXCEPTION '移仓预留的释放量超过剩余锁定' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_stock_claim_storage_lifecycle AFTER UPDATE OF released_qty ON stock_reservations
 FOR EACH ROW WHEN(OLD.released_qty IS DISTINCT FROM NEW.released_qty) EXECUTE FUNCTION fn_stock_claim_storage_lifecycle();

CREATE FUNCTION fn_check_stock_claim_storage_total() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE selected UUID; expected NUMERIC; actual NUMERIC;
BEGIN
 IF TG_TABLE_NAME='stock_reservations' THEN selected:=NEW.id; ELSE selected:=NEW.reservation_id; END IF;
 SELECT CASE WHEN is_deleted OR status<>0 THEN 0 ELSE qty-consumed_qty-released_qty END INTO expected FROM stock_reservations WHERE id=selected;
 SELECT SUM(qty) INTO actual FROM stock_reservation_storage_positions WHERE reservation_id=selected;
 IF actual IS NOT NULL AND actual<>expected THEN RAISE EXCEPTION '移仓前后预留锁定总量不一致' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM stock_reservation_storage_positions location WHERE location.reservation_id=selected
   AND location.qty<>(SELECT COALESCE(SUM(
     CASE WHEN event.to_warehouse_id=location.warehouse_id THEN event.qty ELSE 0 END
     -CASE WHEN event.from_warehouse_id=location.warehouse_id THEN event.qty ELSE 0 END),0)
     FROM stock_reservation_storage_events event WHERE event.reservation_id=selected)) THEN
   RAISE EXCEPTION '锁定仓位必须与不可变流转记录一致' USING ERRCODE='23514';
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_check_stock_claim_storage_position AFTER INSERT OR UPDATE ON stock_reservation_storage_positions
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_claim_storage_total();
CREATE CONSTRAINT TRIGGER trg_check_stock_claim_storage_reservation AFTER UPDATE ON stock_reservations
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_claim_storage_total();

-- Readers follow the actual location projection; source warehouse on the
-- original reservation remains historical evidence, never a second lock.
CREATE OR REPLACE VIEW v_stock_usable AS
SELECT balance.warehouse_id,balance.goods_id,balance.color_id,balance.qty AS on_hand_qty,
 balance.weight AS on_hand_weight,COALESCE(held.qty,0) AS reserved_qty,
 balance.qty-COALESCE(held.qty,0) AS available_qty
FROM stock_balances balance JOIN warehouses warehouse ON warehouse.id=balance.warehouse_id
LEFT JOIN LATERAL(SELECT SUM(r.open_qty) AS qty
 FROM v_stock_reservation_storage_locations r WHERE r.warehouse_id=balance.warehouse_id
 AND r.goods_id=balance.goods_id AND r.color_id IS NOT DISTINCT FROM balance.color_id) held ON TRUE
WHERE fn_warehouse_counts_as_usable(warehouse.id)
 AND fn_stock_measurement_usable(balance.warehouse_id,balance.goods_id,balance.color_id);

CREATE OR REPLACE VIEW v_stock_available AS
SELECT balance.warehouse_id,balance.goods_id,balance.color_id,balance.qty AS on_hand_qty,
 balance.weight AS on_hand_weight,COALESCE(held.qty,0) AS reserved_qty,
 balance.qty-COALESCE(held.qty,0) AS available_qty
FROM stock_balances balance
LEFT JOIN LATERAL(SELECT SUM(r.open_qty) AS qty
 FROM v_stock_reservation_storage_locations r WHERE (r.warehouse_id IS NULL OR r.warehouse_id=balance.warehouse_id)
 AND r.goods_id=balance.goods_id AND r.color_id IS NOT DISTINCT FROM balance.color_id) held ON TRUE
WHERE fn_stock_measurement_usable(balance.warehouse_id,balance.goods_id,balance.color_id);

CREATE FUNCTION fn_stock_storage_movable(p_warehouse UUID,p_goods UUID,p_color UUID,
 p_exclude_order_items UUID[] DEFAULT NULL,p_keep_safety BOOLEAN DEFAULT TRUE)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT GREATEST(LEAST(
   COALESCE((SELECT on_hand_qty FROM v_stock_usable WHERE warehouse_id=p_warehouse
     AND goods_id=p_goods AND color_id IS NOT DISTINCT FROM p_color),0)
   -COALESCE((SELECT SUM(fn_stock_claim_open_at(id,p_warehouse)) FROM stock_reservations
     WHERE NOT is_deleted AND status=0 AND goods_id=p_goods AND color_id IS NOT DISTINCT FROM p_color
       AND warehouse_id IS NOT NULL
       AND (p_exclude_order_items IS NULL OR order_item_id IS NULL OR order_item_id<>ALL(p_exclude_order_items))),0),
   COALESCE((SELECT SUM(on_hand_qty) FROM v_stock_usable WHERE goods_id=p_goods
       AND color_id IS NOT DISTINCT FROM p_color AND fn_stock_storage_same_pool(warehouse_id,p_warehouse)),0)
     -COALESCE((SELECT SUM(qty-consumed_qty-released_qty) FROM stock_reservations
       WHERE NOT is_deleted AND status=0 AND goods_id=p_goods AND color_id IS NOT DISTINCT FROM p_color
         AND (warehouse_id IS NULL OR fn_stock_storage_same_pool(warehouse_id,p_warehouse))
         AND (p_exclude_order_items IS NULL OR order_item_id IS NULL OR order_item_id<>ALL(p_exclude_order_items))),0)
     -CASE WHEN p_keep_safety THEN COALESCE((SELECT GREATEST(min_qty,0) FROM goods WHERE id=p_goods),0) ELSE 0 END),0)
$$;

CREATE FUNCTION fn_stock_relocate_claims(p_doc UUID,p_item UUID,p_reverse BOOLEAN)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE document stock_documents%ROWTYPE; item stock_document_items%ROWTYPE;
 source_id UUID; target_id UUID; remaining NUMERIC; physical NUMERIC; part RECORD; take NUMERIC;
BEGIN
 SELECT * INTO STRICT document FROM stock_documents WHERE id=p_doc;
 SELECT * INTO STRICT item FROM stock_document_items WHERE id=p_item AND doc_id=p_doc;
 IF document.doc_type<>'TRANSFER' OR document.transfer_kind<>'NORMAL'
   OR NOT fn_warehouse_counts_as_usable(document.warehouse_id) OR NOT fn_warehouse_counts_as_usable(document.to_warehouse_id)
   OR NOT fn_stock_storage_same_pool(document.warehouse_id,document.to_warehouse_id) THEN RETURN; END IF;
 source_id:=document.warehouse_id;target_id:=document.to_warehouse_id;
 IF p_reverse THEN
   FOR part IN SELECT event.* FROM stock_reservation_storage_events event
     WHERE event.document_id=p_doc AND event.document_item_id=p_item AND event.event_type='TRANSFER'
       AND NOT EXISTS(SELECT 1 FROM stock_reservation_storage_events counter WHERE counter.reverse_of=event.id)
     ORDER BY event.created_at DESC,event.id DESC LOOP
     UPDATE stock_reservation_storage_positions SET qty=qty-part.qty
       WHERE reservation_id=part.reservation_id AND warehouse_id=target_id AND qty>=part.qty;
     IF NOT FOUND THEN RAISE EXCEPTION '目标仓原调拨的锁定已被使用或继续移仓，不能撤回原调拨' USING ERRCODE='23514'; END IF;
     INSERT INTO stock_reservation_storage_positions VALUES(part.reservation_id,source_id,part.qty)
       ON CONFLICT(reservation_id,warehouse_id) DO UPDATE SET qty=stock_reservation_storage_positions.qty+EXCLUDED.qty;
     INSERT INTO stock_reservation_storage_events(reservation_id,event_type,from_warehouse_id,to_warehouse_id,qty,document_id,document_item_id,reverse_of)
       VALUES(part.reservation_id,'REVERSE',target_id,source_id,part.qty,p_doc,p_item,part.id);
   END LOOP;
   RETURN;
 END IF;
 SELECT COALESCE(qty,0) INTO physical FROM stock_balances WHERE warehouse_id=source_id AND goods_id=item.goods_id AND color_id IS NOT DISTINCT FROM item.color_id;
 SELECT LEAST(item.base_qty,GREATEST(SUM(fn_stock_claim_open_at(id,source_id))-COALESCE(physical,0),0)) INTO remaining
   FROM stock_reservations WHERE goods_id=item.goods_id AND color_id IS NOT DISTINCT FROM item.color_id
     AND warehouse_id IS NOT NULL AND NOT is_deleted AND status=0;
 FOR part IN SELECT r.*,fn_stock_claim_open_at(r.id,source_id) AS local_open FROM stock_reservations r
   WHERE r.goods_id=item.goods_id AND r.color_id IS NOT DISTINCT FROM item.color_id
     AND r.warehouse_id IS NOT NULL AND NOT r.is_deleted AND r.status=0
     AND fn_stock_claim_open_at(r.id,source_id)>0 ORDER BY r.created_at,r.id FOR UPDATE OF r LOOP
   EXIT WHEN COALESCE(remaining,0)<=0;
   take:=LEAST(remaining,part.local_open);
   IF NOT EXISTS(SELECT 1 FROM stock_reservation_storage_positions WHERE reservation_id=part.id) THEN
     INSERT INTO stock_reservation_storage_positions VALUES(part.id,part.warehouse_id,part.qty-part.consumed_qty-part.released_qty);
     INSERT INTO stock_reservation_storage_events(reservation_id,event_type,to_warehouse_id,qty)
       VALUES(part.id,'OPEN',part.warehouse_id,part.qty-part.consumed_qty-part.released_qty);
   END IF;
   UPDATE stock_reservation_storage_positions SET qty=qty-take WHERE reservation_id=part.id AND warehouse_id=source_id;
   INSERT INTO stock_reservation_storage_positions VALUES(part.id,target_id,take)
     ON CONFLICT(reservation_id,warehouse_id) DO UPDATE SET qty=stock_reservation_storage_positions.qty+EXCLUDED.qty;
   INSERT INTO stock_reservation_storage_events(reservation_id,event_type,from_warehouse_id,to_warehouse_id,qty,document_id,document_item_id)
     VALUES(part.id,'TRANSFER',source_id,target_id,take,p_doc,p_item);
   remaining:=remaining-take;
 END LOOP;
END $$;

-- A location move must not multiply a goods-level public buffer.
CREATE OR REPLACE FUNCTION fn_stock_global_usable(p_goods UUID,p_color UUID,
 p_exclude_order_items UUID[] DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
 SELECT GREATEST(
   COALESCE((SELECT SUM(GREATEST(pool.qty-COALESCE((SELECT GREATEST(min_qty,0) FROM goods WHERE id=p_goods),0),0))
     FROM (SELECT fn_warehouse_main_id(warehouse_id),SUM(on_hand_qty) AS qty
       FROM v_stock_usable WHERE goods_id=p_goods AND color_id IS NOT DISTINCT FROM p_color
       GROUP BY fn_warehouse_main_id(warehouse_id)) pool),0)
   -COALESCE((SELECT SUM(qty-consumed_qty-released_qty) FROM stock_reservations reservation
     WHERE NOT is_deleted AND status=0 AND goods_id=p_goods AND color_id IS NOT DISTINCT FROM p_color
       AND (warehouse_id IS NULL OR EXISTS(SELECT 1 FROM warehouses warehouse
         WHERE warehouse.id=reservation.warehouse_id AND NOT warehouse.is_deleted
           AND warehouse.is_accountable AND NOT warehouse.is_defective AND NOT warehouse.is_line_side))
       AND (p_exclude_order_items IS NULL OR order_item_id IS NULL
         OR order_item_id<>ALL(p_exclude_order_items))),0),0)
$$;

CREATE FUNCTION fn_stock_storage_transfer_authorized(p_document UUID,p_item UUID,p_warehouse UUID,
 p_goods UUID,p_color UUID,p_qty NUMERIC,p_type SMALLINT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM stock_documents document
   JOIN stock_document_items item ON item.doc_id=document.id
   WHERE document.id=p_document AND item.id=p_item AND NOT document.is_deleted AND NOT item.is_deleted
     AND document.doc_type='TRANSFER' AND document.transfer_kind='NORMAL'
     AND fn_warehouse_counts_as_usable(document.warehouse_id)
     AND fn_warehouse_counts_as_usable(document.to_warehouse_id)
     AND document.warehouse_id<>document.to_warehouse_id
     AND fn_stock_storage_same_pool(document.warehouse_id,document.to_warehouse_id)
     AND item.goods_id=p_goods AND item.color_id IS NOT DISTINCT FROM p_color AND item.base_qty=p_qty
     AND ((p_type=8 AND document.status=0 AND document.warehouse_id=p_warehouse)
       OR (p_type=7 AND document.status=1 AND document.to_warehouse_id=p_warehouse)))
$$;

-- Consumption uses the actual picking warehouse; provenance continues to name
-- the original receipt/balance. Never rewrite immutable source identities.
DO $physical_pick$
DECLARE definition TEXT; patched TEXT;
BEGIN
 SELECT pg_get_functiondef('fn_guard_material_stock_posting_physical_warehouse_v489()'::regprocedure) INTO definition;
 patched:=replace(definition,'document.warehouse_id=reservation.warehouse_id',
   '(document.warehouse_id=reservation.warehouse_id OR (NEW.posting_type=''ISSUE'' AND EXISTS(SELECT 1 FROM stock_reservation_storage_events location WHERE location.reservation_id=reservation.id AND location.event_type=''CONSUME'' AND location.document_id=document.id AND location.document_item_id=item.id AND location.from_warehouse_id=document.warehouse_id AND location.qty=NEW.qty_base AND location.transaction_id=pg_current_xact_id())))');
 IF patched=definition THEN RAISE EXCEPTION 'V991 physical posting warehouse anchor drifted'; END IF;
 EXECUTE patched;
END $physical_pick$;

DO $allocation_budget$
DECLARE definition TEXT; patched TEXT;
BEGIN
 SELECT pg_get_functiondef('fn_guard_production_stock_allocation()'::regprocedure) INTO definition;
 patched:=replace(definition,'v_new_open > GREATEST(v_balance.qty - v_other_reserved, 0)',
   'v_new_open-v_old_open > fn_stock_storage_movable(NEW.warehouse_id,NEW.goods_id,NEW.color_id,NULL,FALSE)');
 IF patched=definition THEN RAISE EXCEPTION 'V991 allocation capacity anchor drifted'; END IF;
 EXECUTE patched;
 SELECT pg_get_functiondef('fn_check_main_warehouse_public_stock_budget()'::regprocedure) INTO definition;
 patched:=replace(definition,'SUM(reservation.qty-reservation.consumed_qty-reservation.released_qty)',
   'SUM(fn_stock_claim_open_at(reservation.id,balance.warehouse_id))');
 patched:=replace(patched,'AND (reservation.warehouse_id IS NULL OR reservation.warehouse_id=balance.warehouse_id)','');
 IF patched=definition THEN RAISE EXCEPTION 'V991 main-warehouse safety anchor drifted'; END IF;
 EXECUTE patched;
END $allocation_budget$;

SELECT fn_audit_track_table('stock_reservation_storage_events','FULL','data_change',false);

COMMENT ON FUNCTION fn_stock_storage_same_pool(UUID,UUID) IS
 'Only normal storage siblings share existing claims; workshop custody and defective stock remain exact-location scoped.';
COMMENT ON FUNCTION fn_stock_storage_movable(UUID,UUID,UUID,UUID[],BOOLEAN) IS
 'Min(actual location quantity, main-storage stock minus unchanged claims and one public buffer).';
