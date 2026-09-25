-- A shared batch owns one real supply action and one manufacturing anchor.
-- Original material paths remain the beneficiaries of exact allocation slices.
CREATE TABLE preplan_aggregate_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id UUID NOT NULL REFERENCES production_material_analyses(id),
    action_id UUID NOT NULL UNIQUE REFERENCES preplan_supply_actions(id) DEFERRABLE INITIALLY DEFERRED,
    anchor_analysis_item_id UUID UNIQUE REFERENCES production_material_analysis_items(id) DEFERRABLE INITIALLY DEFERRED,
    plan_id UUID UNIQUE REFERENCES production_plans(id) DEFERRABLE INITIALLY DEFERRED,
    route TEXT NOT NULL CHECK(route IN('BUY','MAKE','SUBCONTRACT')),
    compatibility_key VARCHAR(64) NOT NULL CHECK(compatibility_key~'^[0-9a-f]{64}$'),
    configuration_snapshot JSONB NOT NULL CHECK(jsonb_typeof(configuration_snapshot)='object'),
    row_version BIGINT NOT NULL DEFAULT 0 CHECK(row_version>=0),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_preplan_aggregate_batch_compatible ON preplan_aggregate_batches(analysis_id,compatibility_key,created_at,id);
CREATE TABLE preplan_aggregate_batch_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id UUID NOT NULL REFERENCES preplan_aggregate_batches(id),
    event_type TEXT NOT NULL CHECK(event_type IN('CREATE','APPEND','ALIAS_APPEND','CANCEL')),
    allocation_deltas JSONB NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(allocation_deltas)='object'),
    alias_deltas JSONB NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(alias_deltas)='object'),
    source_capacity_deltas JSONB NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(source_capacity_deltas)='object'),
    canonical_capacity_deltas JSONB NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(canonical_capacity_deltas)='object'),
    intent_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(intent_snapshot)='object'),
    public_delta NUMERIC(18,4) NOT NULL DEFAULT 0,
    safety_delta NUMERIC(18,4) NOT NULL DEFAULT 0,
    expected_version BIGINT NOT NULL,
    resulting_version BIGINT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[0-9a-f]{64}$'),
    transaction_id BIGINT NOT NULL DEFAULT txid_current(),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(batch_id,idempotency_key),
    CHECK(resulting_version=expected_version+1)
);
CREATE INDEX idx_preplan_aggregate_event_tx ON preplan_aggregate_batch_events(batch_id,transaction_id);
CREATE TABLE preplan_aggregate_material_aliases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id UUID NOT NULL REFERENCES preplan_aggregate_batches(id),
    source_parent_material_id UUID NOT NULL REFERENCES production_material_analysis_materials(id),
    source_material_id UUID NOT NULL REFERENCES production_material_analysis_materials(id),
    aggregate_material_id UUID NOT NULL REFERENCES production_material_analysis_materials(id),
    relative_bom_path UUID[] NOT NULL CHECK(cardinality(relative_bom_path)>0),
    -- Zero freezes an unconsumed original private source without transferring
    -- stock or creating a demand allocation; the old surplus cannot become public silently.
    qty NUMERIC(18,4) NOT NULL CHECK(qty>=0),
    source_capacity_qty NUMERIC(18,4) NOT NULL CHECK(source_capacity_qty>=qty),
    canonical_capacity_qty NUMERIC(18,4) NOT NULL CHECK(canonical_capacity_qty>=qty),
    capacity_version BIGINT NOT NULL CHECK(capacity_version>=0),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(batch_id,source_material_id),
    CHECK(source_material_id<>aggregate_material_id AND source_material_id<>source_parent_material_id)
);
CREATE INDEX idx_preplan_aggregate_alias_source ON preplan_aggregate_material_aliases(source_material_id,batch_id);
CREATE INDEX idx_preplan_aggregate_alias_target ON preplan_aggregate_material_aliases(aggregate_material_id,batch_id);

-- Preserve every existing source kind and quantity rule. Only an explicit
-- system aggregate anchor may have zero private demand and positive public output.
DO $source_kind$
DECLARE expression TEXT;
BEGIN
    SELECT regexp_replace(pg_get_constraintdef(oid),'^CHECK ','') INTO expression FROM pg_constraint
      WHERE conrelid='production_material_analysis_items'::regclass AND conname='production_material_analysis_item_source_type_chk';
    ALTER TABLE production_material_analysis_items DROP CONSTRAINT production_material_analysis_item_source_type_chk;
    EXECUTE 'ALTER TABLE production_material_analysis_items ADD CONSTRAINT production_material_analysis_item_source_type_chk CHECK ('||expression||' OR source_type=''AGGREGATE_MAKE'')';
    SELECT regexp_replace(pg_get_constraintdef(oid),'^CHECK ','') INTO expression FROM pg_constraint
      WHERE conrelid='production_material_analysis_items'::regclass AND conname='production_material_analysis_item_qty_chk';
    ALTER TABLE production_material_analysis_items DROP CONSTRAINT production_material_analysis_item_qty_chk;
    EXECUTE 'ALTER TABLE production_material_analysis_items ADD CONSTRAINT production_material_analysis_item_qty_chk CHECK ('||expression||' OR (source_type=''AGGREGATE_MAKE'' AND requested_qty=0 AND submitted_qty=0 AND approved_qty=0 AND ready_now_qty=0 AND ready_by_date_qty=0))';
END; $source_kind$;

DO $command_kind$
DECLARE expression TEXT;
BEGIN
    SELECT regexp_replace(pg_get_constraintdef(oid),'^CHECK ','') INTO expression FROM pg_constraint
      WHERE conrelid='production_material_analysis_commands'::regclass AND conname='production_material_analysis_command_operation_chk';
    ALTER TABLE production_material_analysis_commands DROP CONSTRAINT production_material_analysis_command_operation_chk;
    EXECUTE 'ALTER TABLE production_material_analysis_commands ADD CONSTRAINT production_material_analysis_command_operation_chk CHECK ('||expression||' OR operation IN(''AGGREGATE_ORDER'',''AGGREGATE_CANCEL''))';
END; $command_kind$;

ALTER TABLE preplan_supply_actions DROP CONSTRAINT preplan_supply_action_public_surplus_qty_chk;
ALTER TABLE preplan_supply_actions ADD CONSTRAINT preplan_supply_action_public_surplus_qty_chk CHECK(public_surplus_qty>=0 AND (public_surplus_qty=0 OR route IN('BUY','SUBCONTRACT','MAKE')));
DO $shared_public$
DECLARE definition TEXT; anchor TEXT:=E'BEGIN\n';
BEGIN
    SELECT pg_get_functiondef('fn_guard_preplan_public_surplus_shape()'::regprocedure) INTO definition;
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V712 public supply guard anchor changed'; END IF;
    EXECUTE replace(definition,anchor,anchor||'
    IF NEW.route=''MAKE'' AND NEW.operation_type=''SUPPLY'' AND EXISTS(
        SELECT 1 FROM preplan_aggregate_batches batch WHERE batch.action_id=NEW.id
          AND batch.analysis_id=NEW.analysis_id AND batch.route=''MAKE'' AND batch.anchor_analysis_item_id IS NOT NULL) THEN
        RETURN NEW;
    END IF;
');
END; $shared_public$;

CREATE FUNCTION fn_preplan_aggregate_alias_qty(p_alias UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN action.status='CANCELLED' THEN 0 ELSE alias.qty+COALESCE((
        SELECT SUM((event.alias_deltas->>alias.id::text)::numeric) FROM preplan_aggregate_batch_events event
        WHERE event.batch_id=alias.batch_id AND event.event_type IN('APPEND','ALIAS_APPEND') AND event.alias_deltas?alias.id::text),0) END
    FROM preplan_aggregate_material_aliases alias JOIN preplan_aggregate_batches batch ON batch.id=alias.batch_id
    JOIN preplan_supply_actions action ON action.id=batch.action_id WHERE alias.id=p_alias;
$$;
CREATE FUNCTION fn_preplan_aggregate_alias_source_capacity(p_alias UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT alias.source_capacity_qty+COALESCE((SELECT SUM((event.source_capacity_deltas->>alias.id::text)::numeric)
        FROM preplan_aggregate_batch_events event WHERE event.batch_id=alias.batch_id AND event.source_capacity_deltas?alias.id::text),0)
    FROM preplan_aggregate_material_aliases alias WHERE alias.id=p_alias;
$$;
CREATE FUNCTION fn_preplan_aggregate_material_capacity(p_material UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(MAX(alias.canonical_capacity_qty+COALESCE((
        SELECT SUM((event.canonical_capacity_deltas->>p_material::text)::numeric) FROM preplan_aggregate_batch_events event
        WHERE event.batch_id=alias.batch_id AND event.resulting_version>alias.capacity_version
          AND event.canonical_capacity_deltas?p_material::text),0)),0)
    FROM preplan_aggregate_material_aliases alias JOIN preplan_aggregate_batches batch ON batch.id=alias.batch_id
    JOIN preplan_supply_actions action ON action.id=batch.action_id
    WHERE alias.aggregate_material_id=p_material AND action.status<>'CANCELLED';
$$;

CREATE FUNCTION fn_aggregate_batch_append_ready(p_action UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM preplan_aggregate_batches batch
      JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id AND event.event_type='APPEND'
        AND event.transaction_id=txid_current() AND event.resulting_version=batch.row_version
      WHERE batch.action_id=p_action AND batch.plan_id IS NOT NULL AND fn_material_analysis_plan_growable(batch.plan_id));
$$;

DO $aggregate_growth$
DECLARE definition TEXT; anchor TEXT:='SELECT EXISTS (';
BEGIN
    SELECT pg_get_functiondef('fn_preplan_supply_action_growable(uuid)'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V712 supply growable anchor changed'; END IF;
    EXECUTE replace(definition,anchor,'SELECT fn_aggregate_batch_append_ready(p_action) OR EXISTS (');
END; $aggregate_growth$;

-- Unknown-material requests are the same explicit execution boundary as DRAW_REQUEST.
DO $discovery_growth_boundary$
DECLARE definition TEXT; anchor TEXT:='SELECT EXISTS (';
BEGIN
    SELECT pg_get_functiondef('fn_material_analysis_plan_growable(uuid)'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V712 plan growable anchor changed'; END IF;
    EXECUTE replace(definition,anchor,'SELECT NOT EXISTS(SELECT 1 FROM production_material_discovery_requests request
        JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
        WHERE segment.plan_id=p_plan AND request.status<>''CANCELLED'') AND EXISTS (');
END; $discovery_growth_boundary$;

CREATE FUNCTION fn_guard_aggregate_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE version BIGINT; entry RECORD;
BEGIN
    SELECT row_version INTO version FROM preplan_aggregate_batches WHERE id=NEW.batch_id FOR UPDATE;
    IF version IS NULL OR NEW.expected_version<>version OR NEW.resulting_version<>version+1 OR NEW.transaction_id<>txid_current() THEN
        RAISE EXCEPTION 'Aggregate event has a stale batch version' USING ERRCODE='23514';
    END IF;
    FOR entry IN SELECT * FROM jsonb_each(NEW.allocation_deltas) UNION ALL SELECT * FROM jsonb_each(NEW.alias_deltas)
        UNION ALL SELECT * FROM jsonb_each(NEW.source_capacity_deltas) UNION ALL SELECT * FROM jsonb_each(NEW.canonical_capacity_deltas) LOOP
        IF jsonb_typeof(entry.value)<>'number' OR entry.value::text::numeric<=0
           OR entry.value::text::numeric<>round(entry.value::text::numeric,4) OR entry.value::text::numeric>=100000000000000 THEN
            RAISE EXCEPTION 'Aggregate source increments require exact positive base quantities' USING ERRCODE='23514';
        END IF;
    END LOOP;
    IF NEW.public_delta<0 OR NEW.safety_delta<0 THEN RAISE EXCEPTION 'Aggregate append quantities cannot be negative' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_aggregate_event BEFORE INSERT ON preplan_aggregate_batch_events FOR EACH ROW EXECUTE FUNCTION fn_guard_aggregate_event();

CREATE FUNCTION fn_complete_aggregate_alias_deltas(p_batch UUID,p_key TEXT,p_deltas JSONB,p_source_capacities JSONB,p_canonical_capacities JSONB) RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE batch preplan_aggregate_batches%ROWTYPE; event preplan_aggregate_batch_events%ROWTYPE;
BEGIN
    SELECT * INTO batch FROM preplan_aggregate_batches WHERE id=p_batch FOR UPDATE;
    SELECT * INTO event FROM preplan_aggregate_batch_events WHERE batch_id=p_batch AND idempotency_key=p_key AND event_type='APPEND' AND transaction_id=txid_current();
    IF batch.id IS NULL OR event.id IS NULL OR (p_deltas='{}'::jsonb AND p_source_capacities='{}'::jsonb AND p_canonical_capacities='{}'::jsonb) OR EXISTS(
        SELECT 1 FROM jsonb_object_keys(p_deltas) source WHERE NOT EXISTS(SELECT 1 FROM preplan_aggregate_material_aliases alias WHERE alias.id=source::uuid AND alias.batch_id=p_batch)) THEN
        RAISE EXCEPTION 'Alias growth lacks the current shared batch append proof' USING ERRCODE='23514';
    END IF;
    INSERT INTO preplan_aggregate_batch_events(batch_id,event_type,alias_deltas,source_capacity_deltas,canonical_capacity_deltas,expected_version,resulting_version,idempotency_key,request_hash,created_by)
    VALUES(p_batch,'ALIAS_APPEND',p_deltas,p_source_capacities,p_canonical_capacities,batch.row_version,batch.row_version+1,p_key||':ALIAS',event.request_hash,event.created_by);
    UPDATE preplan_aggregate_batches SET row_version=row_version+1 WHERE id=p_batch;
    RETURN TRUE;
END; $$;

CREATE FUNCTION fn_aggregate_relative_bom_path(p_material UUID,p_parent UUID DEFAULT NULL)
RETURNS UUID[] LANGUAGE plpgsql STABLE AS $$
DECLARE current_row production_material_analysis_materials%ROWTYPE; parent_row production_material_analysis_materials%ROWTYPE;
        result UUID[]:='{}'::uuid[]; steps INTEGER:=0;
BEGIN
    SELECT * INTO current_row FROM production_material_analysis_materials WHERE id=p_material;
    IF current_row.id IS NULL THEN RETURN NULL; END IF;
    IF p_parent IS NOT NULL THEN
        SELECT * INTO parent_row FROM production_material_analysis_materials WHERE id=p_parent;
        IF parent_row.id IS NULL OR parent_row.analysis_item_id<>current_row.analysis_item_id THEN RETURN NULL; END IF;
    END IF;
    LOOP
        IF current_row.id=p_parent THEN RETURN result; END IF;
        IF current_row.bom_item_id IS NOT NULL THEN result:=array_prepend(current_row.bom_item_id,result); END IF;
        IF current_row.parent_node_key IS NULL THEN
            IF p_parent IS NULL OR parent_row.node_role='ROOT_SUPPLY' THEN RETURN result; END IF;
            RETURN NULL;
        END IF;
        steps:=steps+1;
        IF steps>256 THEN RAISE EXCEPTION 'Aggregate BOM source path contains a cycle' USING ERRCODE='23514'; END IF;
        SELECT parent.* INTO current_row FROM production_material_analysis_materials parent
        WHERE parent.analysis_id=current_row.analysis_id AND parent.analysis_item_id=current_row.analysis_item_id
          AND parent.node_key=current_row.parent_node_key;
        IF current_row.id IS NULL THEN RETURN NULL; END IF;
    END LOOP;
END; $$;

CREATE FUNCTION fn_guard_aggregate_batch_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' OR TG_TABLE_NAME IN('preplan_aggregate_batch_events','preplan_aggregate_material_aliases') THEN
        RAISE EXCEPTION 'Aggregate batch source evidence is append-only' USING ERRCODE='23514';
    END IF;
    IF (OLD.id,OLD.analysis_id,OLD.action_id,OLD.route,OLD.compatibility_key,OLD.configuration_snapshot,OLD.created_by,OLD.created_at)
        IS DISTINCT FROM (NEW.id,NEW.analysis_id,NEW.action_id,NEW.route,NEW.compatibility_key,NEW.configuration_snapshot,NEW.created_by,NEW.created_at)
       OR (OLD.anchor_analysis_item_id IS NOT NULL AND OLD.anchor_analysis_item_id IS DISTINCT FROM NEW.anchor_analysis_item_id)
       OR (OLD.plan_id IS NOT NULL AND OLD.plan_id IS DISTINCT FROM NEW.plan_id)
       OR NEW.row_version<OLD.row_version THEN
        RAISE EXCEPTION 'Aggregate batch identity is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_aggregate_batch_history BEFORE UPDATE OR DELETE ON preplan_aggregate_batches FOR EACH ROW EXECUTE FUNCTION fn_guard_aggregate_batch_history();
CREATE TRIGGER trg_aggregate_batch_event_history BEFORE UPDATE OR DELETE ON preplan_aggregate_batch_events FOR EACH ROW EXECUTE FUNCTION fn_guard_aggregate_batch_history();
CREATE TRIGGER trg_aggregate_alias_history BEFORE UPDATE OR DELETE ON preplan_aggregate_material_aliases FOR EACH ROW EXECUTE FUNCTION fn_guard_aggregate_batch_history();

-- A shared subcontract preparation belongs to its explicit batch, never an arbitrary member.
ALTER TABLE preplan_subcontract_make_tasks ALTER COLUMN analysis_material_id DROP NOT NULL;
CREATE UNIQUE INDEX uq_preplan_aggregate_subcontract_task ON preplan_subcontract_make_tasks(preparation_item_id)
    WHERE status='ACTIVE' AND analysis_material_id IS NULL;
CREATE FUNCTION fn_guard_aggregate_subcontract_task() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.analysis_material_id IS NOT NULL AND EXISTS(SELECT 1 FROM production_material_analysis_items anchor
        WHERE anchor.id=NEW.preparation_item_id AND anchor.source_type='AGGREGATE_MAKE') THEN
        RAISE EXCEPTION 'Shared subcontract preparation cannot impersonate one source material' USING ERRCODE='23514';
    END IF;
    IF NEW.analysis_material_id IS NULL AND NOT EXISTS(
        SELECT 1 FROM preplan_aggregate_batches batch
        JOIN preplan_supply_actions action ON action.id=batch.action_id
        JOIN production_material_analysis_items anchor ON anchor.id=batch.anchor_analysis_item_id
        WHERE batch.analysis_id=NEW.analysis_id AND batch.action_id=NEW.supply_action_id
          AND batch.anchor_analysis_item_id=NEW.preparation_item_id AND batch.route='SUBCONTRACT'
          AND anchor.source_type='AGGREGATE_MAKE'
          AND (action.goods_id,action.color_id,action.unit_id,action.warehouse_id)
              IS NOT DISTINCT FROM (NEW.goods_id,NEW.color_id,NEW.unit_id,NEW.warehouse_id)
          AND NEW.required_qty=action.requested_qty+action.public_surplus_qty) THEN
        RAISE EXCEPTION 'Shared subcontract task requires exact aggregate source proof' USING ERRCODE='23514';
    END IF;
    IF TG_OP='UPDATE' AND (OLD.analysis_material_id IS NULL OR NEW.analysis_material_id IS NULL)
        AND (OLD.analysis_id,OLD.analysis_material_id,OLD.supply_action_id,OLD.preparation_item_id)
        IS DISTINCT FROM (NEW.analysis_id,NEW.analysis_material_id,NEW.supply_action_id,NEW.preparation_item_id) THEN
        RAISE EXCEPTION 'Subcontract preparation source identity is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_aggregate_subcontract_task BEFORE INSERT OR UPDATE ON preplan_subcontract_make_tasks
    FOR EACH ROW EXECUTE FUNCTION fn_guard_aggregate_subcontract_task();

CREATE FUNCTION fn_assert_aggregate_batch(p_batch UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE batch preplan_aggregate_batches%ROWTYPE; action preplan_supply_actions%ROWTYPE;
BEGIN
    SELECT * INTO batch FROM preplan_aggregate_batches WHERE id=p_batch;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT * INTO action FROM preplan_supply_actions WHERE id=batch.action_id;
    IF action.id IS NULL OR (action.analysis_id,action.route) IS DISTINCT FROM (batch.analysis_id,batch.route)
       OR action.requested_qty+action.public_surplus_qty+action.safety_replenishment_qty<=0 THEN
        RAISE EXCEPTION 'Aggregate batch lacks its exact supply action' USING ERRCODE='23514';
    END IF;
    IF jsonb_typeof(batch.configuration_snapshot->'materialLineIds') IS DISTINCT FROM 'array'
       OR jsonb_array_length(batch.configuration_snapshot->'materialLineIds')=0
       OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(batch.configuration_snapshot->'materialLineIds') member
           WHERE NOT EXISTS(SELECT 1 FROM production_material_analysis_materials material WHERE material.id=member::uuid
             AND material.analysis_id=batch.analysis_id AND (material.goods_id,material.color_id,material.unit_id)
                IS NOT DISTINCT FROM (action.goods_id,action.color_id,action.unit_id))) THEN
        RAISE EXCEPTION 'Aggregate batch must retain its complete original material context' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT 1 FROM preplan_supply_action_allocations allocation
        JOIN production_material_analysis_materials source ON source.id=allocation.analysis_material_id
        WHERE allocation.action_id=action.id AND (source.analysis_id<>batch.analysis_id
          OR (source.goods_id,source.color_id,source.unit_id) IS DISTINCT FROM (action.goods_id,action.color_id,action.unit_id))) THEN
        RAISE EXCEPTION 'Aggregate source material dimensions must agree' USING ERRCODE='23514';
    END IF;
    IF batch.anchor_analysis_item_id IS NOT NULL AND NOT EXISTS(
        SELECT 1 FROM production_material_analysis_items anchor WHERE anchor.id=batch.anchor_analysis_item_id
          AND anchor.analysis_id=batch.analysis_id AND anchor.source_type='AGGREGATE_MAKE'
          AND anchor.parent_analysis_material_id IS NULL
          AND (anchor.goods_id,anchor.color_id,anchor.unit_id) IS NOT DISTINCT FROM (action.goods_id,action.color_id,action.unit_id)) THEN
        RAISE EXCEPTION 'Shared manufacturing needs an explicit aggregate anchor' USING ERRCODE='23514';
    END IF;
    IF batch.plan_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM production_plans plan
        WHERE plan.id=batch.plan_id AND plan.material_analysis_id=batch.analysis_id
          AND plan.material_analysis_item_id=batch.anchor_analysis_item_id) THEN
        RAISE EXCEPTION 'Shared plan must belong to its aggregate anchor' USING ERRCODE='23514';
    END IF;
END; $$;
CREATE FUNCTION fn_check_aggregate_batch() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='preplan_aggregate_batches' THEN PERFORM fn_assert_aggregate_batch(NEW.id);
    ELSE PERFORM fn_assert_aggregate_batch(NEW.batch_id); END IF;
    RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER trg_check_aggregate_batch AFTER INSERT OR UPDATE ON preplan_aggregate_batches DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_aggregate_batch();
CREATE CONSTRAINT TRIGGER trg_check_aggregate_batch_event AFTER INSERT ON preplan_aggregate_batch_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_aggregate_batch();

CREATE FUNCTION fn_guard_aggregate_anchor() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.source_type='AGGREGATE_MAKE' AND NOT EXISTS(SELECT 1 FROM preplan_aggregate_batches batch
        JOIN preplan_supply_actions action ON action.id=batch.action_id WHERE batch.anchor_analysis_item_id=NEW.id
          AND batch.analysis_id=NEW.analysis_id AND batch.route IN('MAKE','SUBCONTRACT')
          AND (action.goods_id,action.color_id,action.unit_id) IS NOT DISTINCT FROM (NEW.goods_id,NEW.color_id,NEW.unit_id)) THEN
        RAISE EXCEPTION 'Aggregate anchor must be backed by the shared batch source proof' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_aggregate_anchor BEFORE INSERT OR UPDATE OF source_type,goods_id,color_id,unit_id,parent_analysis_material_id ON production_material_analysis_items FOR EACH ROW EXECUTE FUNCTION fn_guard_aggregate_anchor();

CREATE FUNCTION fn_guard_aggregate_alias() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE batch preplan_aggregate_batches%ROWTYPE; source production_material_analysis_materials%ROWTYPE; target production_material_analysis_materials%ROWTYPE;
BEGIN
    SELECT * INTO batch FROM preplan_aggregate_batches WHERE id=NEW.batch_id;
    SELECT * INTO source FROM production_material_analysis_materials WHERE id=NEW.source_material_id;
    SELECT * INTO target FROM production_material_analysis_materials WHERE id=NEW.aggregate_material_id;
    IF batch.id IS NULL OR source.id IS NULL OR target.id IS NULL
       OR source.analysis_id<>batch.analysis_id OR target.analysis_id<>batch.analysis_id
       OR target.analysis_item_id<>batch.anchor_analysis_item_id
       OR (source.goods_id,source.color_id,source.unit_id) IS DISTINCT FROM (target.goods_id,target.color_id,target.unit_id)
       OR NEW.relative_bom_path IS DISTINCT FROM fn_aggregate_relative_bom_path(source.id,NEW.source_parent_material_id)
       OR NEW.relative_bom_path IS DISTINCT FROM fn_aggregate_relative_bom_path(target.id,NULL)
       OR NOT EXISTS(SELECT 1 FROM preplan_supply_action_allocations allocation WHERE allocation.action_id=batch.action_id
           AND allocation.analysis_material_id=NEW.source_parent_material_id) THEN
        RAISE EXCEPTION 'Aggregate material alias must retain its exact original BOM edge path' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_aggregate_alias BEFORE INSERT ON preplan_aggregate_material_aliases FOR EACH ROW EXECUTE FUNCTION fn_guard_aggregate_alias();

-- V250's externalization handshake recognizes only verified aggregate anchors.
DO $handshake$
DECLARE definition TEXT; anchor TEXT:='item.source_type = ''MAKE_COMPONENT''';
BEGIN
    SELECT pg_get_functiondef('fn_guard_preplan_supply_allocation_history()'::regprocedure) INTO definition;
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V712 allocation handshake anchor changed'; END IF;
    definition:=replace(definition,anchor,'(item.source_type = ''MAKE_COMPONENT'' OR (item.source_type=''AGGREGATE_MAKE''
        AND EXISTS(SELECT 1 FROM preplan_aggregate_batches batch WHERE batch.anchor_analysis_item_id=item.id AND batch.action_id=NEW.action_id)))');
    anchor:='item.source_type = ''SUBCONTRACT_MAKE''';
    IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'V712 subcontract allocation handshake anchor changed'; END IF;
    EXECUTE replace(definition,anchor,'(item.source_type = ''SUBCONTRACT_MAKE'' OR (item.source_type=''AGGREGATE_MAKE''
        AND EXISTS(SELECT 1 FROM preplan_aggregate_batches batch WHERE batch.anchor_analysis_item_id=item.id AND batch.action_id=NEW.action_id AND batch.route=''SUBCONTRACT'')))');
END; $handshake$;

SELECT fn_audit_track_table('preplan_aggregate_batches','FULL','data_change',false);
SELECT fn_audit_track_table('preplan_aggregate_batch_events','NONE','data_change',false);
SELECT fn_audit_track_table('preplan_aggregate_material_aliases','NONE','data_change',false);
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT:='(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'V712 reset policy anchor changed'; END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n (''preplan_aggregate_batches'', ''CLEAR''),\n (''preplan_aggregate_batch_events'', ''CLEAR''),\n (''preplan_aggregate_material_aliases'', ''CLEAR'')');
END; $reset_policy$;

-- Aggregate allocation checks: statement-scoped scheduling
-- This is a signal, never a cached quantity or a substitute for SUM(actual allocations).
ALTER TABLE preplan_supply_actions ADD COLUMN aggregate_allocation_check_revision BIGINT NOT NULL DEFAULT 0
    CHECK(aggregate_allocation_check_revision>=0);

CREATE FUNCTION fn_preplan_aggregate_allocation_scope(p_action UUID) RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM preplan_aggregate_batches shared WHERE shared.action_id=p_action) THEN RETURN TRUE; END IF;
    RETURN EXISTS(
        SELECT 1 FROM preplan_supply_actions action
        JOIN preplan_subcontract_make_task_batches notified ON notified.application_id=action.external_document_id
        JOIN preplan_subcontract_make_tasks task ON task.id=notified.task_id
        JOIN preplan_aggregate_batches shared ON shared.action_id=task.supply_action_id
          AND shared.anchor_analysis_item_id=task.preparation_item_id AND shared.analysis_id=task.analysis_id
          AND shared.route='SUBCONTRACT'
        WHERE action.id=p_action AND action.analysis_id=shared.analysis_id
          AND action.external_document_type='SUBCONTRACT_APPLICATION'
          AND (EXISTS(SELECT 1 FROM preplan_supply_action_allocations slice
                  WHERE slice.id=notified.allocation_id AND slice.action_id=action.id
                    AND slice.external_item_id=notified.application_item_id)
            OR (notified.allocation_id IS NULL AND action.requested_qty=0
                AND action.public_surplus_external_item_id=notified.application_item_id)));
END $$;

CREATE OR REPLACE FUNCTION fn_check_preplan_supply_action_allocation() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_action_id UUID; v_requested NUMERIC(18,4); v_allocated NUMERIC(18,4);
BEGIN
    IF TG_TABLE_NAME='preplan_supply_actions' THEN v_action_id:=COALESCE(NEW.id,OLD.id);
    ELSE v_action_id:=COALESCE(NEW.action_id,OLD.action_id); END IF;
    IF TG_TABLE_NAME='preplan_supply_action_allocations' AND fn_preplan_aggregate_allocation_scope(v_action_id) THEN
        RETURN NULL;
    END IF;
    IF TG_NARGS>0 AND TG_ARGV[0]='AGGREGATE_SIGNAL' AND NOT fn_preplan_aggregate_allocation_scope(v_action_id) THEN
        RETURN NULL;
    END IF;
    SELECT requested_qty INTO v_requested FROM preplan_supply_actions WHERE id=v_action_id;
    IF v_requested IS NULL THEN RETURN NULL; END IF;
    SELECT COALESCE(SUM(allocated_qty),0) INTO v_allocated FROM preplan_supply_action_allocations WHERE action_id=v_action_id;
    IF v_requested IS DISTINCT FROM v_allocated THEN
        RAISE EXCEPTION 'preplan supply action allocation total % must equal requested quantity %',v_allocated,v_requested
            USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END $$;

-- The same constraint name on BOTH relations is intentional: SET CONSTRAINTS
-- trg_check_preplan_supply_action_allocation IMMEDIATE must still validate the
-- aggregate allocation at the statement boundary. Updating a separate signal
-- column does not fire the independently named header_total constraint early.
CREATE CONSTRAINT TRIGGER trg_check_preplan_supply_action_allocation
    AFTER UPDATE OF aggregate_allocation_check_revision ON preplan_supply_actions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (OLD.aggregate_allocation_check_revision IS DISTINCT FROM NEW.aggregate_allocation_check_revision)
    EXECUTE FUNCTION fn_check_preplan_supply_action_allocation('AGGREGATE_SIGNAL');

CREATE FUNCTION fn_signal_preplan_aggregate_allocation(p_action UUID) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF fn_preplan_aggregate_allocation_scope(p_action) THEN
        UPDATE preplan_supply_actions SET aggregate_allocation_check_revision=aggregate_allocation_check_revision+1 WHERE id=p_action;
    END IF;
END $$;

CREATE FUNCTION fn_signal_preplan_aggregate_allocation_statement() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_action_id UUID;
BEGIN
    IF TG_OP='INSERT' THEN
        FOR v_action_id IN SELECT affected.action_id FROM (SELECT DISTINCT changed.action_id FROM aa_new changed) affected
            WHERE fn_preplan_aggregate_allocation_scope(affected.action_id) ORDER BY affected.action_id LOOP
            PERFORM fn_signal_preplan_aggregate_allocation(v_action_id);
        END LOOP;
    ELSIF TG_OP='DELETE' THEN
        FOR v_action_id IN SELECT affected.action_id FROM (SELECT DISTINCT changed.action_id FROM aa_old changed) affected
            WHERE fn_preplan_aggregate_allocation_scope(affected.action_id) ORDER BY affected.action_id LOOP
            PERFORM fn_signal_preplan_aggregate_allocation(v_action_id);
        END LOOP;
    ELSE
        FOR v_action_id IN SELECT affected.action_id FROM (
                SELECT changed.action_id FROM aa_old changed UNION SELECT changed.action_id FROM aa_new changed) affected
            WHERE fn_preplan_aggregate_allocation_scope(affected.action_id) ORDER BY affected.action_id LOOP
            PERFORM fn_signal_preplan_aggregate_allocation(v_action_id);
        END LOOP;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_signal_aggregate_allocation_insert AFTER INSERT ON preplan_supply_action_allocations
    REFERENCING NEW TABLE AS aa_new FOR EACH STATEMENT EXECUTE FUNCTION fn_signal_preplan_aggregate_allocation_statement();
CREATE TRIGGER trg_signal_aggregate_allocation_update AFTER UPDATE ON preplan_supply_action_allocations
    REFERENCING OLD TABLE AS aa_old NEW TABLE AS aa_new FOR EACH STATEMENT EXECUTE FUNCTION fn_signal_preplan_aggregate_allocation_statement();
CREATE TRIGGER trg_signal_aggregate_allocation_delete AFTER DELETE ON preplan_supply_action_allocations
    REFERENCING OLD TABLE AS aa_old FOR EACH STATEMENT EXECUTE FUNCTION fn_signal_preplan_aggregate_allocation_statement();

-- Allocation changes may precede the immutable shared proof in the same
-- transaction. Late binding must queue the SAME named constraint as well.
CREATE FUNCTION fn_signal_aggregate_batch_allocation() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN PERFORM fn_signal_preplan_aggregate_allocation(NEW.action_id); RETURN NULL; END $$;
CREATE TRIGGER trg_signal_aggregate_batch_allocation AFTER INSERT ON preplan_aggregate_batches
    FOR EACH ROW EXECUTE FUNCTION fn_signal_aggregate_batch_allocation();

CREATE FUNCTION fn_signal_aggregate_notification_allocation() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_action_id UUID;
BEGIN
    FOR v_action_id IN SELECT affected.id FROM (
        SELECT DISTINCT action.id FROM aa_notifications notified
        JOIN preplan_supply_actions action ON action.external_document_id=notified.application_id
        WHERE action.external_document_type='SUBCONTRACT_APPLICATION'
          AND (EXISTS(SELECT 1 FROM preplan_supply_action_allocations slice WHERE slice.id=notified.allocation_id
                  AND slice.action_id=action.id AND slice.external_item_id=notified.application_item_id)
            OR (notified.allocation_id IS NULL AND action.requested_qty=0 AND action.public_surplus_external_item_id=notified.application_item_id))) affected
        WHERE fn_preplan_aggregate_allocation_scope(affected.id) ORDER BY affected.id LOOP
        PERFORM fn_signal_preplan_aggregate_allocation(v_action_id);
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_signal_aggregate_notification_allocation AFTER INSERT ON preplan_subcontract_make_task_batches
    REFERENCING NEW TABLE AS aa_notifications FOR EACH STATEMENT EXECUTE FUNCTION fn_signal_aggregate_notification_allocation();
