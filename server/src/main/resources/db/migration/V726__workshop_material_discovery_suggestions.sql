-- Workshop suggestions are immutable application intent. Warehouse configuration,
-- actual stock postings and closed-production BOM learning retain their own facts.
ALTER TABLE production_material_discovery_requests
    ADD COLUMN requested_materials JSONB NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(requested_materials) = 'array' AND jsonb_array_length(requested_materials) <= 100);

CREATE OR REPLACE FUNCTION fn_guard_material_discovery_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' OR TG_TABLE_NAME='production_material_discovery_lines' THEN
        RAISE EXCEPTION 'Material discovery evidence is append-only' USING ERRCODE='23514';
    END IF;
    IF OLD.status<>'PENDING' OR NEW.status NOT IN('CONFIGURED','CANCELLED')
       OR (NEW.id,NEW.execution_segment_id,NEW.expected_version,NEW.created_by,NEW.created_at,NEW.idempotency_key,NEW.request_hash,NEW.requested_materials)
          IS DISTINCT FROM (OLD.id,OLD.execution_segment_id,OLD.expected_version,OLD.created_by,OLD.created_at,OLD.idempotency_key,OLD.request_hash,OLD.requested_materials)
       OR NEW.row_version<>OLD.row_version+1 THEN
        RAISE EXCEPTION 'Invalid material discovery transition' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END; $$;
