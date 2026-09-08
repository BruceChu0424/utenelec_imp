-- Preserve the original event and stock movement as two immutable facts with one
-- explicit relationship. Never infer historical identity from date, SKU or bill number.
CREATE TABLE production_material_movement_links (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id UUID NOT NULL REFERENCES production_material_stock_events(id),
    document_item_id UUID NOT NULL REFERENCES stock_document_items(id),
    movement_id UUID NOT NULL UNIQUE REFERENCES stock_movements(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    created_by UUID REFERENCES users(id),
    UNIQUE(event_id,document_item_id)
);
CREATE INDEX idx_material_postings_event_item ON production_material_stock_postings(event_id,stock_document_item_id);
CREATE TRIGGER trg_audit_production_material_movement_links AFTER INSERT OR UPDATE OR DELETE ON production_material_movement_links
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE production_material_movement_links ENABLE ALWAYS TRIGGER trg_audit_production_material_movement_links;
CREATE FUNCTION fn_guard_material_movement_link() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP<>'INSERT' THEN
        RAISE EXCEPTION 'production material movement identity is immutable' USING ERRCODE='55000';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM stock_movements movement JOIN production_material_stock_events event ON event.id=NEW.event_id
        WHERE movement.id=NEW.movement_id
          AND movement.xmin::text=pg_current_xact_id()::text AND event.xmin::text=pg_current_xact_id()::text) THEN
        RAISE EXCEPTION 'production material movement link must be created with both original facts in the same transaction'
            USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_material_movement_link BEFORE INSERT OR UPDATE OR DELETE ON production_material_movement_links
    FOR EACH ROW EXECUTE FUNCTION fn_guard_material_movement_link();
ALTER TABLE production_material_movement_links ENABLE ALWAYS TRIGGER trg_guard_material_movement_link;

CREATE FUNCTION fn_assert_material_movement_link(p_event UUID,p_item UUID) RETURNS void LANGUAGE plpgsql AS $$
DECLARE event production_material_stock_events%ROWTYPE;item stock_document_items%ROWTYPE;
    movement stock_movements%ROWTYPE;link production_material_movement_links%ROWTYPE;
    document stock_documents%ROWTYPE;quantity NUMERIC;expected_direction SMALLINT;expected_type SMALLINT;
BEGIN
    SELECT * INTO event FROM production_material_stock_events WHERE id=p_event;
    SELECT * INTO item FROM stock_document_items WHERE id=p_item;
    SELECT * INTO document FROM stock_documents WHERE id=event.stock_document_id;
    SELECT * INTO link FROM production_material_movement_links WHERE event_id=p_event AND document_item_id=p_item;
    SELECT * INTO movement FROM stock_movements WHERE id=link.movement_id;
    SELECT SUM(qty_base) INTO quantity FROM production_material_stock_postings WHERE event_id=p_event AND stock_document_item_id=p_item;
    expected_direction:=CASE event.event_type WHEN 'ISSUE' THEN -1 WHEN 'ISSUE_REVERSE' THEN 1 WHEN 'GOOD_RETURN' THEN 1 WHEN 'GOOD_RETURN_REVERSE' THEN -1 END;
    expected_type:=CASE WHEN event.event_type IN('ISSUE','ISSUE_REVERSE') THEN 5 ELSE 6 END;
    IF event.id IS NULL OR item.id IS NULL OR document.id IS NULL OR link.id IS NULL OR movement.id IS NULL OR quantity IS NULL
        OR item.doc_id<>event.stock_document_id OR movement.source_doc_type<>'STOCK_DOC'
        OR movement.source_doc_id<>event.stock_document_id OR movement.source_item_id<>p_item
        OR movement.goods_id<>item.goods_id OR movement.color_id IS DISTINCT FROM item.color_id
        OR movement.warehouse_id IS DISTINCT FROM document.warehouse_id
        OR movement.direction<>expected_direction OR movement.movement_type<>expected_type OR movement.qty<>quantity
        OR movement.unit_id IS DISTINCT FROM item.unit_id OR movement.unit_rate IS DISTINCT FROM item.unit_rate
        OR EXISTS(SELECT 1 FROM production_material_stock_postings posting
            JOIN production_material_demands demand ON demand.id=posting.demand_id
            WHERE posting.event_id=p_event AND posting.stock_document_item_id=p_item
              AND (posting.posting_type<>event.event_type OR demand.goods_id<>movement.goods_id
                  OR demand.color_id IS DISTINCT FROM movement.color_id)) THEN
        RAISE EXCEPTION 'production material event, exact item, physical movement and posted base quantity must agree'
            USING ERRCODE='23514',CONSTRAINT='production_material_exact_movement_guard';
    END IF;
END;
$$;
CREATE FUNCTION fn_check_material_movement_link() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE physical_link production_material_movement_links%ROWTYPE;
BEGIN
    IF TG_TABLE_NAME='stock_movements' THEN
        SELECT * INTO physical_link FROM production_material_movement_links WHERE movement_id=NEW.id;
        IF physical_link.id IS NULL THEN
            RAISE EXCEPTION 'production physical movement requires its exact material event'
                USING ERRCODE='23514',CONSTRAINT='production_material_exact_movement_guard';
        END IF;
        PERFORM fn_assert_material_movement_link(physical_link.event_id,physical_link.document_item_id);
    ELSIF TG_TABLE_NAME='production_material_movement_links' THEN
        PERFORM fn_assert_material_movement_link(NEW.event_id,NEW.document_item_id);
    ELSE
        PERFORM fn_assert_material_movement_link(NEW.event_id,NEW.stock_document_item_id);
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_material_movement_link_complete AFTER INSERT ON production_material_movement_links
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_material_movement_link();
CREATE CONSTRAINT TRIGGER trg_material_posting_movement_complete AFTER INSERT ON production_material_stock_postings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_material_movement_link();
CREATE CONSTRAINT TRIGGER trg_material_physical_event_complete AFTER INSERT ON stock_movements
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN(NEW.source_doc_type='STOCK_DOC' AND NEW.movement_type IN(5,6))
    EXECUTE FUNCTION fn_check_material_movement_link();
ALTER TABLE production_material_movement_links ENABLE ALWAYS TRIGGER trg_material_movement_link_complete;
ALTER TABLE production_material_stock_postings ENABLE ALWAYS TRIGGER trg_material_posting_movement_complete;
ALTER TABLE stock_movements ENABLE ALWAYS TRIGGER trg_material_physical_event_complete;

DO $reset$
DECLARE definition TEXT;needle TEXT:='(''stock_value_postings'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1
        OR position('(''production_material_movement_links'',' IN definition)>0 THEN
        RAISE EXCEPTION 'V514 cannot safely register production material movement links';
    END IF;
    EXECUTE replace(definition,needle,needle||E',\n            (''production_material_movement_links'', ''CLEAR'')');
END;
$reset$;
