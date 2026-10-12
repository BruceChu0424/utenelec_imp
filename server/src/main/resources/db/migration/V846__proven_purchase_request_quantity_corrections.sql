-- A sanctioned correction is an immutable command, not a generic source-row exemption.
CREATE TABLE purchase_request_qty_revisions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id UUID NOT NULL,
    request_item_id UUID NOT NULL,
    expected_version BIGINT NOT NULL CHECK(expected_version>=0),
    old_qty NUMERIC(18,4) NOT NULL CHECK(old_qty>=0),
    new_qty NUMERIC(18,4) NOT NULL CHECK(new_qty>0 AND new_qty<>old_qty),
    before_item JSONB NOT NULL,
    source_minimum_base NUMERIC NOT NULL CHECK(source_minimum_base>=0),
    actor_user_id UUID NOT NULL REFERENCES users(id),
    actor_employee_id UUID NOT NULL REFERENCES employees(id),
    created_txid BIGINT NOT NULL DEFAULT txid_current(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(created_txid,request_item_id),
    UNIQUE(request_item_id,expected_version)
);
CREATE INDEX idx_purchase_request_qty_revision_document ON purchase_request_qty_revisions(request_id,request_item_id,expected_version);

CREATE FUNCTION fn_purchase_request_qty_source_minimum(p_item UUID) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT GREATEST(
        COALESCE((SELECT SUM(GREATEST(allocated_qty-released_qty,0)) FROM production_material_supply_pegs
                  WHERE supply_type='PURCHASE_REQUEST_ITEM' AND supply_item_id=p_item),0),
        COALESCE((SELECT SUM(allocation.allocated_qty) FROM preplan_supply_action_allocations allocation
                  JOIN preplan_supply_actions action ON action.id=allocation.action_id
                  WHERE action.route='BUY' AND allocation.external_item_id=p_item),0)
        +COALESCE((SELECT SUM(public_surplus_qty) FROM preplan_supply_actions
                   WHERE route='BUY' AND public_surplus_external_item_id=p_item),0)
        +COALESCE((SELECT SUM(safety_replenishment_qty) FROM preplan_supply_actions
                   WHERE route='BUY' AND safety_external_item_id=p_item),0))
$$;

CREATE FUNCTION fn_purchase_request_qty_correction_available(p_item UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM purchase_request_items item JOIN purchase_requests header ON header.id=item.request_id
        WHERE item.id=p_item AND NOT item.is_deleted AND NOT header.is_deleted AND header.legacy_id IS NULL
          AND header.status=1 AND NOT header.is_closed AND NOT COALESCE(header.is_stopped,FALSE)
          AND COALESCE(item.ordered_qty,0)=0 AND COALESCE(item.gift_ordered_qty,0)=0
          AND NOT EXISTS(SELECT 1 FROM purchase_order_items oi JOIN purchase_orders oh ON oh.id=oi.order_id
              WHERE NOT oi.is_deleted AND NOT oh.is_deleted AND (oi.request_item_id=item.id OR EXISTS(
                  SELECT 1 FROM purchase_order_item_sources source WHERE source.order_item_id=oi.id AND source.request_item_id=item.id)))
          AND NOT EXISTS(SELECT 1 FROM production_material_supply_pegs peg WHERE peg.supply_type='PURCHASE_REQUEST_ITEM'
              AND peg.supply_item_id=item.id AND (peg.consumed_qty>0 OR peg.released_qty>0))
          AND NOT EXISTS(SELECT 1 FROM preplan_supply_actions action WHERE action.route='BUY'
              AND (action.safety_external_item_id=item.id OR action.public_surplus_external_item_id=item.id OR EXISTS(
                  SELECT 1 FROM preplan_supply_action_allocations allocation WHERE allocation.action_id=action.id AND allocation.external_item_id=item.id))
              AND (fn_preplan_action_has_future_transfer(action.id) OR fn_preplan_action_has_shared_claims(action.id))))
$$;

CREATE FUNCTION fn_prepare_purchase_request_qty_revision() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE item JSONB; employee UUID; physical NUMERIC;
BEGIN
    SELECT to_jsonb(line) INTO item FROM purchase_request_items line
        JOIN purchase_requests header ON header.id=line.request_id
        WHERE line.id=NEW.request_item_id AND header.id=NEW.request_id FOR UPDATE OF header,line;
    SELECT u.employee_id INTO employee FROM users u JOIN employees e ON e.id=u.employee_id
        WHERE u.id=NEW.actor_user_id AND u.status='active' AND NOT u.is_deleted AND e.status='active' AND NOT e.is_deleted;
    physical:=ROUND((NEW.new_qty+CASE WHEN item->>'quantity_semantics'='CHARGED_PLUS_GIFT_V1'
        THEN COALESCE((item->>'gift_qty')::numeric,0) ELSE 0 END)*(item->>'unit_rate')::numeric,4);
    IF item IS NULL OR NEW.created_txid<>txid_current()
       OR NEW.actor_user_id::text IS DISTINCT FROM NULLIF(current_setting('app.actor_id',TRUE),'')
       OR employee IS NULL OR employee IS DISTINCT FROM NEW.actor_employee_id
       OR NEW.before_item IS DISTINCT FROM item OR NEW.expected_version IS DISTINCT FROM (item->>'row_version')::bigint
       OR NEW.old_qty IS DISTINCT FROM (item->>'qty')::numeric
       OR NOT fn_purchase_request_qty_correction_available(NEW.request_item_id)
       OR NEW.source_minimum_base IS DISTINCT FROM fn_purchase_request_qty_source_minimum(NEW.request_item_id)
       OR physical IS NULL OR physical<=0 OR physical<NEW.source_minimum_base THEN
        RAISE EXCEPTION 'Purchase request correction lacks current source, version, actor or uncommitted demand proof'
            USING ERRCODE='23514',CONSTRAINT='purchase_request_qty_revision_proof_guard';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_prepare_purchase_request_qty_revision BEFORE INSERT ON purchase_request_qty_revisions
    FOR EACH ROW EXECUTE FUNCTION fn_prepare_purchase_request_qty_revision();
CREATE TRIGGER trg_purchase_request_qty_revision_immutable BEFORE UPDATE OR DELETE ON purchase_request_qty_revisions
    FOR EACH ROW EXECUTE FUNCTION fn_forbid_procurement_source_revision_mutation();
-- Own immutable actor/before-image/quantity event; source-row changes retain normal auditing.
SELECT fn_audit_track_table('purchase_request_qty_revisions','NONE','data_change',false);

CREATE FUNCTION fn_is_proven_purchase_request_qty_revision(p_table TEXT,p_old JSONB,p_new JSONB) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT p_table='purchase_request_items'
       AND (p_old-ARRAY['qty','updated_at','updated_by','row_version']) IS NOT DISTINCT FROM
           (p_new-ARRAY['qty','updated_at','updated_by','row_version'])
       AND (p_new->>'row_version')::bigint=(p_old->>'row_version')::bigint+1
       AND EXISTS(SELECT 1 FROM purchase_request_qty_revisions proof
           WHERE proof.created_txid=txid_current() AND proof.request_id=(p_old->>'request_id')::uuid
             AND proof.request_item_id=(p_old->>'id')::uuid AND proof.before_item=p_old
             AND proof.expected_version=(p_old->>'row_version')::bigint
             AND proof.old_qty=(p_old->>'qty')::numeric AND proof.new_qty=(p_new->>'qty')::numeric
             AND proof.actor_user_id::text=NULLIF(current_setting('app.actor_id',TRUE),'')
             AND proof.actor_user_id::text=p_new->>'updated_by')
$$;

CREATE FUNCTION fn_check_purchase_request_qty_revision() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE current_item JSONB;
BEGIN
    SELECT to_jsonb(item) INTO current_item FROM purchase_request_items item WHERE item.id=NEW.request_item_id;
    IF current_item IS NULL OR NOT fn_is_proven_purchase_request_qty_revision('purchase_request_items',NEW.before_item,current_item) THEN
        RAISE EXCEPTION 'Purchase request quantity proof did not commit its exact source update'
            USING ERRCODE='23514',CONSTRAINT='purchase_request_qty_revision_complete_guard';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_purchase_request_qty_revision_complete AFTER INSERT ON purchase_request_qty_revisions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_purchase_request_qty_revision();
ALTER TABLE purchase_request_qty_revisions ENABLE ALWAYS TRIGGER trg_prepare_purchase_request_qty_revision;
ALTER TABLE purchase_request_qty_revisions ENABLE ALWAYS TRIGGER trg_purchase_request_qty_revision_immutable;
ALTER TABLE purchase_request_qty_revisions ENABLE ALWAYS TRIGGER trg_purchase_request_qty_revision_complete;

DO $patch$
DECLARE definition TEXT; anchor TEXT := 'OR fn_is_proven_procurement_qty_revision(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW))';
BEGIN
    SELECT pg_get_functiondef('fn_guard_production_supply_source_item()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V846 production source guard shape changed';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E'\n       OR fn_is_proven_purchase_request_qty_revision(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW))');
END $patch$;

DO $patch$
DECLARE definition TEXT; anchor TEXT := '(''purchase_request_items'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V846 reset catalog shape changed';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''purchase_request_qty_revisions'', ''CLEAR'')');
END $patch$;
