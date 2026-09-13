-- Preserve the frozen DRAW demand. Workshop intent grants only selected line quantities.
ALTER TABLE production_execution_segment_events ADD COLUMN draw_item_quantities JSONB;
ALTER TABLE production_execution_segment_events ADD CONSTRAINT production_draw_quantities_shape_chk
    CHECK (draw_item_quantities IS NULL OR (action='DRAW_REQUEST'
        AND jsonb_typeof(draw_item_quantities)='object' AND draw_item_quantities<>'{}'::jsonb));

CREATE FUNCTION fn_production_draw_item_requested_qty(p_item_id UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE
      WHEN NOT EXISTS (SELECT 1 FROM production_planning_package_documents mapping
          WHERE mapping.document_id=item.doc_id AND mapping.document_type='DRAW'
            AND mapping.execution_segment_id IS NOT NULL) THEN item.qty
      WHEN EXISTS (SELECT 1 FROM production_execution_segment_events event
          WHERE event.action='DRAW_REQUEST' AND event.draw_document_ids @> ARRAY[item.doc_id]
            AND event.draw_item_quantities IS NULL) THEN item.qty
      WHEN NOT EXISTS (SELECT 1 FROM production_execution_segment_events event
          WHERE event.action='DRAW_REQUEST' AND event.draw_document_ids @> ARRAY[item.doc_id])
        AND EXISTS (SELECT 1 FROM stock_document_items sibling
          JOIN production_material_stock_postings posting ON posting.stock_document_item_id=sibling.id
          WHERE sibling.doc_id=item.doc_id AND posting.posting_type='ISSUE') THEN item.qty
      ELSE COALESCE((SELECT sum((event.draw_item_quantities ->> item.id::text)::numeric)
          FROM production_execution_segment_events event
          WHERE event.action='DRAW_REQUEST' AND event.draw_document_ids @> ARRAY[item.doc_id]),0)
      END::numeric
    FROM stock_document_items item WHERE item.id=p_item_id AND NOT item.is_deleted;
$$;

CREATE FUNCTION fn_production_draw_fully_requested(p_document_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT fn_production_draw_requested(p_document_id)
      AND NOT EXISTS (SELECT 1 FROM stock_document_items item
          WHERE item.doc_id=p_document_id AND NOT item.is_deleted
            AND fn_production_draw_item_requested_qty(item.id)<item.qty);
$$;

CREATE FUNCTION fn_production_draw_pending(p_document_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT fn_production_draw_requested(p_document_id)
      AND EXISTS (SELECT 1 FROM stock_document_items item
          WHERE item.doc_id=p_document_id AND NOT item.is_deleted
            AND fn_production_draw_item_requested_qty(item.id)>COALESCE(item.issued_qty,0));
$$;

CREATE FUNCTION fn_guard_production_draw_quantities()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE entry RECORD; current_qty NUMERIC; requested_qty NUMERIC;
BEGIN
    IF NEW.action<>'DRAW_REQUEST' OR NEW.draw_item_quantities IS NULL THEN RETURN NEW; END IF;
    -- The command holds plan, package, segment and document locks. Item locks also
    -- serialize direct event inserts with physical issue and reject stale quantities.
    PERFORM item.id FROM stock_document_items item
      WHERE item.id::text IN (SELECT jsonb_object_keys(NEW.draw_item_quantities))
      ORDER BY item.id FOR UPDATE;
    FOR entry IN SELECT key,value FROM jsonb_each(NEW.draw_item_quantities) LOOP
        IF jsonb_typeof(entry.value)<>'number' THEN
            RAISE EXCEPTION 'DRAW request quantity must be numeric' USING ERRCODE='23514';
        END IF;
        requested_qty := entry.value::text::numeric;
        IF requested_qty<=0 OR requested_qty<>round(requested_qty,4) THEN
            RAISE EXCEPTION 'DRAW request quantity must be positive with at most four decimals' USING ERRCODE='23514';
        END IF;
        SELECT item.qty INTO current_qty FROM stock_document_items item
          JOIN production_planning_package_documents mapping ON mapping.document_id=item.doc_id
            AND mapping.document_type='DRAW' AND mapping.execution_segment_id=NEW.execution_segment_id
          JOIN production_planning_package_document_items item_mapping
            ON item_mapping.document_item_id=item.id AND item_mapping.document_type='DRAW'
          JOIN production_material_demands demand ON demand.id=item_mapping.demand_id
            AND demand.execution_segment_id=NEW.execution_segment_id AND NOT demand.is_deleted
          WHERE item.id::text=entry.key AND NOT item.is_deleted AND item.doc_id=ANY(NEW.draw_document_ids);
        IF NOT FOUND OR requested_qty+fn_production_draw_item_requested_qty(entry.key::uuid)>current_qty THEN
            RAISE EXCEPTION 'DRAW request exceeds remaining unrequested quantity or exact task source' USING ERRCODE='23514';
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM unnest(NEW.draw_document_ids) document_id
      WHERE NOT EXISTS (SELECT 1 FROM stock_document_items item WHERE item.doc_id=document_id
        AND NOT item.is_deleted AND NEW.draw_item_quantities ? item.id::text)) THEN
        RAISE EXCEPTION 'DRAW request includes an unselected document' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_production_draw_quantities BEFORE INSERT ON production_execution_segment_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_draw_quantities();
ALTER TABLE production_execution_segment_events ENABLE ALWAYS TRIGGER trg_guard_production_draw_quantities;

CREATE FUNCTION fn_guard_production_draw_issue_requested_qty()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF COALESCE(NEW.issued_qty,0)>COALESCE(OLD.issued_qty,0)
      AND EXISTS (SELECT 1 FROM stock_documents document WHERE document.id=NEW.doc_id AND document.doc_type='DRAW')
      AND NEW.issued_qty>fn_production_draw_item_requested_qty(NEW.id) THEN
        RAISE EXCEPTION 'Physical DRAW issue exceeds workshop requested quantity' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_production_draw_issue_requested_qty BEFORE UPDATE OF issued_qty ON stock_document_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_draw_issue_requested_qty();
ALTER TABLE stock_document_items ENABLE ALWAYS TRIGGER trg_guard_production_draw_issue_requested_qty;

COMMENT ON COLUMN production_execution_segment_events.draw_item_quantities IS
    'Append-only exact DRAW item UUID to requested quantity in document units. NULL preserves historical whole-document intent.';
