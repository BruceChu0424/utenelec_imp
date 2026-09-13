-- Readiness still reserves a complete kit; only an explicit workshop request
-- exposes execution DRAWs to warehouse fulfillment. Existing material facts stay intact.
ALTER TABLE production_execution_segment_events
    ADD COLUMN draw_document_ids UUID[],
    DROP CONSTRAINT production_execution_segment_events_action_check,
    ADD CONSTRAINT production_execution_segment_events_action_check CHECK (action IN (
        'ASSIGNMENT','DISPATCH','START','CANCEL','REVERSE','REOPEN_COMPLETION',
        'RELEASE_DEFER','AUTO_START_ON_REPORT','RECHECK_MATERIAL','DRAW_REQUEST')),
    ADD CONSTRAINT production_execution_draw_request_shape_chk CHECK (
        (action = 'DRAW_REQUEST' AND draw_document_ids IS NOT NULL AND cardinality(draw_document_ids) > 0
         AND array_position(draw_document_ids, NULL) IS NULL AND created_by IS NOT NULL
         AND resulting_version = expected_version + 1)
        OR (action <> 'DRAW_REQUEST' AND draw_document_ids IS NULL));

CREATE INDEX idx_execution_draw_request_documents
    ON production_execution_segment_events USING gin(draw_document_ids)
    WHERE action = 'DRAW_REQUEST';
CREATE INDEX idx_execution_draw_request_actor_key
    ON production_execution_segment_events(created_by, idempotency_key)
    WHERE action = 'DRAW_REQUEST';

CREATE OR REPLACE FUNCTION fn_production_draw_requested(p_document_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM stock_documents document
        WHERE document.id=p_document_id AND document.doc_type='DRAW' AND NOT document.is_deleted)
    AND (NOT EXISTS (
        SELECT 1 FROM production_planning_package_documents mapping
        WHERE mapping.document_id=p_document_id AND mapping.document_type='DRAW'
          AND mapping.execution_segment_id IS NOT NULL)
    OR EXISTS (
        SELECT 1 FROM production_execution_segment_events event
        WHERE event.action='DRAW_REQUEST'
          AND event.draw_document_ids @> ARRAY[p_document_id])
    OR EXISTS (
        SELECT 1 FROM stock_document_items item
        JOIN production_material_stock_postings posting
          ON posting.stock_document_item_id=item.id AND posting.posting_type='ISSUE'
        WHERE item.doc_id=p_document_id));
$$;

-- Reuse the existing audited event ledger and its reset policy. No historic
-- request is fabricated, and a rebuilt DRAW UUID never inherits an old request.
CREATE OR REPLACE FUNCTION fn_guard_production_draw_request_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        IF OLD.action='DRAW_REQUEST' OR (TG_OP='UPDATE' AND NEW.action='DRAW_REQUEST') THEN
            RAISE EXCEPTION 'Workshop DRAW request events are append-only' USING ERRCODE='55000';
        END IF;
        IF TG_OP='DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    IF NEW.action <> 'DRAW_REQUEST' THEN RETURN NEW; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM production_execution_segments segment
        WHERE segment.id=NEW.execution_segment_id AND NOT segment.is_deleted
          AND segment.status IN ('READY','DISPATCHED')
          AND segment.material_requirement_mode='DEMANDED'
          AND segment.lock_version=NEW.resulting_version)
       OR EXISTS (
        SELECT 1 FROM unnest(NEW.draw_document_ids) AS requested(document_id)
        WHERE NOT EXISTS (
            SELECT 1 FROM production_planning_package_documents mapping
            JOIN stock_documents document ON document.id=mapping.document_id
            WHERE mapping.execution_segment_id=NEW.execution_segment_id
              AND mapping.document_id=requested.document_id AND mapping.document_type='DRAW'
              AND document.doc_type='DRAW' AND document.status IN (0,1) AND NOT document.is_deleted))
       OR cardinality(NEW.draw_document_ids) <> (
          SELECT count(DISTINCT id) FROM unnest(NEW.draw_document_ids) id) THEN
        RAISE EXCEPTION 'Workshop DRAW request has stale or invalid execution documents' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_production_draw_request_event
    BEFORE INSERT OR UPDATE OR DELETE ON production_execution_segment_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_draw_request_event();
ALTER TABLE production_execution_segment_events ENABLE ALWAYS TRIGGER trg_guard_production_draw_request_event;

COMMENT ON COLUMN production_execution_segment_events.draw_document_ids IS
    'Exact warehouse DRAW UUIDs explicitly requested by the workshop; NULL on untouched historical events.';
COMMENT ON FUNCTION fn_production_draw_requested(UUID) IS
    'Warehouse visibility and command gate: explicit exact-DRAW workshop request or genuine prior issue; non-execution documents retain their independent workflow.';
