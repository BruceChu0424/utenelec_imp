-- Consumption corrections retain the original cost source, input and output tasks.
ALTER TABLE stock_value_nodes ADD COLUMN returned_consumption_qty NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE stock_value_nodes ADD COLUMN consumption_return_head_id UUID REFERENCES stock_value_nodes(id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE stock_value_nodes ADD CONSTRAINT stock_value_consumption_return_owner CHECK(
    returned_consumption_qty=0 AND consumption_return_head_id IS NULL
    OR kind='ISSUE_POSITION' AND owner_kind='COST_WIP' AND root_issue_id=id AND active
        AND returned_consumption_qty>0 AND returned_consumption_qty<=quantity_basis AND consumption_return_head_id IS NOT NULL);
DO $kind$
DECLARE constraint_name TEXT;
BEGIN
    SELECT conname INTO constraint_name FROM pg_constraint WHERE conrelid='stock_value_nodes'::regclass
        AND contype='c' AND pg_get_constraintdef(oid) LIKE '%kind = ANY%' AND pg_get_constraintdef(oid) LIKE '%RETURN_SOURCE%';
    IF constraint_name IS NULL THEN RAISE EXCEPTION 'inventory node vocabulary not found'; END IF;
    EXECUTE format('ALTER TABLE stock_value_nodes DROP CONSTRAINT %I',constraint_name);
END;
$kind$;
ALTER TABLE stock_value_nodes ADD CONSTRAINT stock_value_node_kind_v524 CHECK(kind IN('SOURCE','POOL','ISSUE_POSITION','RETURN_SOURCE','COST_RETURN_CURSOR'));
ALTER TABLE stock_value_nodes ADD CONSTRAINT stock_value_cost_cursor_shape CHECK(kind<>'COST_RETURN_CURSOR'
    OR (root_issue_id IS NOT NULL AND quantity_basis>0 AND range_from>0 AND range_to=quantity_basis
        AND owner_kind IS NULL AND owner_id IS NULL AND distributed_value_local=0));
ALTER TABLE stock_value_nodes DROP COLUMN owned_value_local;
ALTER TABLE stock_value_nodes ADD COLUMN owned_value_local NUMERIC GENERATED ALWAYS AS (
    CASE WHEN active AND kind='POOL' THEN basis_value_local
         WHEN active AND kind='ISSUE_POSITION' THEN round(basis_value_local*range_to/quantity_basis,4)
            -round(basis_value_local*range_from/quantity_basis,4)-distributed_value_local
            -round(basis_value_local*returned_consumption_qty/quantity_basis,4)
         ELSE 0 END) STORED;

ALTER TABLE stock_value_events DROP CONSTRAINT stock_value_event_operation_v509_check;
ALTER TABLE stock_value_events ADD CONSTRAINT stock_value_event_operation_v524_check CHECK(operation IN(
    'RECEIVE','ISSUE','RETURN_ISSUE','COST_ADJUST','COST_ADJUST_REVERSE','OPENING','EMPTY_OPENING',
    'POSITION_ACQUIRE','POSITION_MOVE','POSITION_STORE','COST_ALLOCATE','CONSUMPTION_RETURN'));
DO $shape$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
        WHERE conrelid='stock_value_events'::regclass AND conname='stock_value_event_shape_v509_check';
    IF definition IS NULL THEN RAISE EXCEPTION 'inventory event shape guard not found'; END IF;
    definition:=substring(definition FROM 8 FOR length(definition)-8);
    ALTER TABLE stock_value_events DROP CONSTRAINT stock_value_event_shape_v509_check;
    EXECUTE 'ALTER TABLE stock_value_events ADD CONSTRAINT stock_value_event_shape_v524_check CHECK ('||definition
        ||' OR (operation=''CONSUMPTION_RETURN'' AND movement_id IS NULL AND qty_base>0 AND qty_before>=0'
        ||' AND source_node_id IS NOT NULL AND result_source_revision>0 AND result_head_id IS NOT NULL AND known_value_local>=0))';
END;
$shape$;
DO $identity$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_stock_value_projection_identity()'::regprocedure) INTO definition;
    IF position('''distributed_value_local''' IN definition)=0 THEN RAISE EXCEPTION 'inventory cost projection guard not found'; END IF;
    EXECUTE replace(definition,'''distributed_value_local''','''distributed_value_local'',''returned_consumption_qty'',''consumption_return_head_id''');
END;
$identity$;

CREATE OR REPLACE FUNCTION fn_check_stock_value_node_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n stock_value_nodes%ROWTYPE; remainder stock_value_nodes%ROWTYPE; outgoing BIGINT;
BEGIN
    SELECT * INTO n FROM stock_value_nodes WHERE id=NEW.id;
    SELECT count(*) INTO outgoing FROM stock_value_edges WHERE parent_node_id=n.id;
    IF (n.active AND outgoing<>0 AND NOT(n.kind='ISSUE_POSITION' AND n.owner_kind='COST_WIP' AND n.returned_consumption_qty>0 AND outgoing=2))
       OR (NOT n.active AND outgoing=0) OR (n.kind IN('SOURCE','RETURN_SOURCE') AND outgoing<>1) THEN
        RAISE EXCEPTION 'current value ownership and frozen successors disagree' USING ERRCODE='23514';
    END IF;
    IF n.kind<>'SOURCE' AND NOT EXISTS(SELECT 1 FROM stock_value_edges WHERE child_node_id=n.id) THEN
        RAISE EXCEPTION 'value node requires an exact input source' USING ERRCODE='23514';
    END IF;
    IF n.kind='POOL' THEN PERFORM fn_check_stock_value_pool(n.pool_id); END IF;
    IF n.kind='ISSUE_POSITION' AND n.id=n.root_issue_id THEN
        SELECT * INTO remainder FROM stock_value_nodes WHERE id=n.return_head_id;
        IF remainder.id IS NULL OR NOT remainder.active OR remainder.root_issue_id<>n.id
            OR remainder.kind<>'ISSUE_POSITION' OR remainder.quantity_basis<>n.quantity_basis OR remainder.range_to<>n.quantity_basis THEN
            RAISE EXCEPTION 'original issue remaining position is inconsistent' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION fn_assert_consumption_return(p_event UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE e stock_value_events%ROWTYPE; root stock_value_nodes%ROWTYPE; source stock_value_nodes%ROWTYPE;
    target stock_value_nodes%ROWTYPE; cursor stock_value_nodes%ROWTYPE; expected NUMERIC;
BEGIN
    SELECT * INTO e FROM stock_value_events WHERE id=p_event;
    IF e.operation IS DISTINCT FROM 'CONSUMPTION_RETURN' THEN RETURN; END IF;
    SELECT * INTO root FROM stock_value_nodes WHERE id=e.source_node_id;
    SELECT * INTO target FROM stock_value_nodes WHERE id=e.result_node_id;
    SELECT * INTO cursor FROM stock_value_nodes WHERE id=e.result_head_id;
    SELECT parent.* INTO source FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id
        WHERE edge.creation_event_id=e.id AND edge.child_node_id=target.id;
    expected:=round(source.basis_value_local*(e.qty_before+e.qty_base)/source.quantity_basis,4)
        -round(source.basis_value_local*e.qty_before/source.quantity_basis,4);
    IF root.id IS NULL OR root.kind<>'ISSUE_POSITION' OR root.owner_kind<>'COST_WIP' OR root.root_issue_id<>root.id
       OR source.id IS NULL OR (source.id<>root.id AND (source.kind<>'COST_RETURN_CURSOR' OR source.root_issue_id<>root.id))
       OR source.range_from<>e.qty_before OR e.qty_before+e.qty_base>root.quantity_basis
       OR target.id IS NULL OR target.kind<>'ISSUE_POSITION' OR target.owner_kind NOT IN('WIP','SUBCONTRACT_WIP')
       OR target.pool_id<>root.pool_id OR target.quantity_basis<>e.qty_base
       OR target.initial_known_value<>expected OR e.known_value_local<>expected
       OR cursor.id IS NULL OR cursor.kind<>'COST_RETURN_CURSOR' OR cursor.root_issue_id<>root.id
       OR cursor.quantity_basis<>root.quantity_basis OR cursor.range_from<>e.qty_before+e.qty_base
       OR cursor.pool_id<>root.pool_id OR cursor.initial_known_value<>source.basis_value_local
       OR NOT EXISTS(SELECT 1 FROM stock_value_edges WHERE creation_event_id=e.id AND parent_node_id=source.id AND child_node_id=target.id
            AND interval_from=e.qty_before AND interval_to=e.qty_before+e.qty_base AND denominator=root.quantity_basis)
       OR NOT EXISTS(SELECT 1 FROM stock_value_edges WHERE creation_event_id=e.id AND parent_node_id=source.id AND child_node_id=cursor.id
            AND interval_from=0 AND interval_to=1 AND denominator=1)
       OR NOT EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=e.id AND node_id=root.id AND owner_kind='COST_WIP'
            AND amount_delta_local=-expected)
       OR NOT EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=e.id AND node_id=target.id AND amount_delta_local=expected) THEN
        RAISE EXCEPTION 'consumption return must carry its original cost interval to the exact restored material' USING ERRCODE='23514';
    END IF;
END;
$$;
CREATE FUNCTION fn_check_consumption_return() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE root stock_value_nodes%ROWTYPE; cursor stock_value_nodes%ROWTYPE; returned NUMERIC;
BEGIN
    IF TG_TABLE_NAME='stock_value_events' THEN PERFORM fn_assert_consumption_return(NEW.id);RETURN NULL; END IF;
    SELECT * INTO root FROM stock_value_nodes WHERE id=NEW.id;
    IF root.kind<>'ISSUE_POSITION' OR root.owner_kind<>'COST_WIP' THEN RETURN NULL; END IF;
    SELECT coalesce(sum(qty_base),0) INTO returned FROM stock_value_events WHERE operation='CONSUMPTION_RETURN' AND source_node_id=root.id;
    IF root.returned_consumption_qty<>returned THEN RAISE EXCEPTION 'consumption return quantity requires its immutable events' USING ERRCODE='23514'; END IF;
    IF returned>0 THEN
        SELECT * INTO cursor FROM stock_value_nodes WHERE id=root.consumption_return_head_id;
        IF cursor.id IS NULL OR NOT cursor.active OR cursor.root_issue_id<>root.id OR cursor.range_from<>returned
            OR cursor.kind<>'COST_RETURN_CURSOR' THEN RAISE EXCEPTION 'consumption return cursor is not the current original remainder' USING ERRCODE='23514'; END IF;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_consumption_return_event AFTER INSERT ON stock_value_events
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_consumption_return();
CREATE CONSTRAINT TRIGGER trg_consumption_return_quantity AFTER INSERT OR UPDATE ON stock_value_nodes
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_consumption_return();
ALTER TABLE stock_value_events ENABLE ALWAYS TRIGGER trg_consumption_return_event;
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_consumption_return_quantity;

ALTER TABLE stock_value_production_cost_tasks ADD COLUMN input_returned_qty NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE stock_value_production_cost_tasks ADD COLUMN input_quantity_basis NUMERIC(18,4) NOT NULL DEFAULT 1;
ALTER TABLE stock_value_production_cost_tasks ADD COLUMN input_return_cursor_id UUID REFERENCES stock_value_nodes(id);
ALTER TABLE stock_value_production_cost_tasks ADD CONSTRAINT stock_value_task_effective_input CHECK(
    input_quantity_basis>0 AND input_returned_qty>=0 AND input_returned_qty<=input_quantity_basis);
DO $task_factor$
DECLARE definition TEXT;needle TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_check_stock_value_cost_task_plan()'::regprocedure) INTO definition;
    needle:='round(NEW.input_value_local*NEW.output_to/NEW.denominator,4)-round(NEW.input_value_local*NEW.output_from/NEW.denominator,4)';
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'cost task allocation proof changed'; END IF;
    definition:=replace(definition,needle,
        'round(NEW.input_value_local*(NEW.input_quantity_basis-NEW.input_returned_qty)*NEW.output_to/(NEW.denominator*NEW.input_quantity_basis),4)'
        ||'-round(NEW.input_value_local*(NEW.input_quantity_basis-NEW.input_returned_qty)*NEW.output_from/(NEW.denominator*NEW.input_quantity_basis),4)');
    definition:=replace(definition,'OR NEW.input_value_local<>(i->>''value'')::numeric',
        'OR NEW.input_returned_qty<>coalesce((i->>''returnedQty'')::numeric,0) OR NEW.input_quantity_basis<>coalesce((i->>''quantityBasis'')::numeric,1)'
        ||' OR NEW.input_return_cursor_id IS DISTINCT FROM (i->>''returnCursor'')::uuid OR NEW.input_value_local<>(i->>''value'')::numeric');
    EXECUTE definition;
END;
$task_factor$;

CREATE FUNCTION fn_check_consumption_task_factor() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE cursor stock_value_nodes%ROWTYPE; basis stock_value_nodes%ROWTYPE; plan stock_value_production_cost_revisions%ROWTYPE;
    expression JSONB; lo NUMERIC;hi NUMERIC;denom NUMERIC;numerator NUMERIC;
BEGIN
    SELECT * INTO plan FROM stock_value_production_cost_revisions WHERE id=NEW.revision_id;
    SELECT input INTO expression FROM jsonb_array_elements(plan.input_snapshot) input WHERE (input->>'node')::uuid=NEW.input_node_id;
    IF expression ? 'quantityBasis' THEN
        SELECT * INTO basis FROM stock_value_nodes WHERE id=NEW.input_node_id;
        IF NEW.input_quantity_basis<>basis.quantity_basis THEN RAISE EXCEPTION 'effective input must keep the original quantity denominator' USING ERRCODE='23514'; END IF;
    END IF;
    IF NEW.input_returned_qty=0 THEN
        IF NEW.input_return_cursor_id IS NOT NULL THEN RAISE EXCEPTION 'zero returned input cannot carry a return cursor' USING ERRCODE='23514'; END IF;
    ELSE
        SELECT * INTO cursor FROM stock_value_nodes WHERE id=NEW.input_return_cursor_id;
        IF cursor.id IS NULL OR cursor.kind<>'COST_RETURN_CURSOR' OR cursor.root_issue_id<>NEW.input_node_id
            OR cursor.quantity_basis<>NEW.input_quantity_basis OR cursor.range_from<>NEW.input_returned_qty
            OR NOT EXISTS(SELECT 1 FROM stock_value_events event WHERE event.id=cursor.creation_event_id
                AND event.operation='CONSUMPTION_RETURN' AND event.source_node_id=NEW.input_node_id AND event.result_head_id=cursor.id) THEN
            RAISE EXCEPTION 'effective input ratio must reference its immutable original consumption return' USING ERRCODE='23514';
        END IF;
    END IF;
    IF NEW.status='APPLIED' AND plan.output_qty_base<=plan.target_qty_base THEN
        IF NEW.denominator=0 THEN lo:=0;hi:=0;denom:=1;numerator:=0;
        ELSE
            SELECT lower_value,upper_value INTO lo,hi FROM fn_stock_value_reference_bounds(NEW.input_node_id,NEW.input_revision);
            denom:=NEW.denominator*NEW.input_quantity_basis;
            numerator:=(NEW.output_to-NEW.output_from)*(NEW.input_quantity_basis-NEW.input_returned_qty);
        END IF;
        IF (lo IS NULL OR hi IS NULL) AND (NEW.exact_share_lower IS NOT NULL OR NEW.exact_share_upper IS NOT NULL)
            OR lo IS NOT NULL AND hi IS NOT NULL AND (NEW.exact_share_lower IS NULL OR NEW.exact_share_upper IS NULL
                OR NEW.exact_share_lower*denom>lo*numerator OR NEW.exact_share_upper*denom<hi*numerator) THEN
            RAISE EXCEPTION 'effective production allocation bounds must cover the exact original input and unreturned ratio' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_consumption_task_factor AFTER INSERT OR UPDATE ON stock_value_production_cost_tasks
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_consumption_task_factor();
ALTER TABLE stock_value_production_cost_tasks ENABLE ALWAYS TRIGGER trg_consumption_task_factor;

-- Correcting an explicit material settlement reopens completion through the same
-- semantic-event boundary as a finished-in reversal, without reversing physical output.
CREATE FUNCTION fn_is_material_completion_reopen_authorized(p_segment UUID,p_version BIGINT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM production_material_settlement_events settlement
        JOIN production_execution_segments segment ON segment.plan_id=settlement.plan_id AND segment.id=p_segment
        JOIN production_execution_segment_events event ON event.execution_segment_id=segment.id
            AND event.action='REOPEN_COMPLETION' AND event.idempotency_key='MATERIAL_SETTLEMENT_REVERSE:'||settlement.id::text
            AND event.expected_version=p_version AND event.resulting_version=p_version+1
            AND event.request_hash=settlement.request_hash AND event.created_by=settlement.created_by
        WHERE settlement.event_type='REVERSE' AND settlement.xmin::text=pg_current_xact_id()::text
            AND settlement.id::text=current_setting('app.production_completion_reopen_settlement_id',true));
$$;
DO $reopen$
DECLARE definition TEXT;needle TEXT:='SELECT EXISTS (';
BEGIN
    SELECT pg_get_functiondef('fn_is_completion_reopen_authorized(uuid,bigint)'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN
        RAISE EXCEPTION 'completion reopening authorization changed before V524';
    END IF;
    EXECUTE replace(definition,needle,'SELECT fn_is_material_completion_reopen_authorized(p_segment_id,p_expected_version) OR EXISTS (');
END;
$reopen$;
CREATE FUNCTION fn_check_material_completion_reopen() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE settlement UUID;
BEGIN
    IF NEW.action<>'REOPEN_COMPLETION' OR NEW.idempotency_key NOT LIKE 'MATERIAL_SETTLEMENT_REVERSE:%' THEN RETURN NULL; END IF;
    settlement:=substring(NEW.idempotency_key FROM length('MATERIAL_SETTLEMENT_REVERSE:')+1)::uuid;
    IF NOT EXISTS(SELECT 1 FROM production_material_settlement_postings posting
        JOIN production_material_demands demand ON demand.id=posting.demand_id
        WHERE posting.event_id=settlement AND posting.source_posting_id IS NOT NULL
            AND demand.execution_segment_id=NEW.execution_segment_id AND posting.created_by=NEW.created_by) THEN
        RAISE EXCEPTION 'reopened completion requires the same actual material settlement reversal' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_material_completion_reopen AFTER INSERT ON production_execution_segment_events
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_material_completion_reopen();
ALTER TABLE production_execution_segment_events ENABLE ALWAYS TRIGGER trg_material_completion_reopen;

CREATE OR REPLACE FUNCTION fn_guard_cost_business_refresh_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.business_refresh_event_id IS NULL AND NEW.business_refresh_actor_id IS NULL AND NOT NEW.business_refresh_pending THEN RETURN NEW; END IF;
    IF NEW.business_refresh_event_id IS NULL OR NEW.business_refresh_actor_id IS NULL OR NOT (
        EXISTS(SELECT 1 FROM stock_value_production_cost_outputs output
            JOIN stock_value_events event ON event.movement_id=output.movement_id
            WHERE output.execution_segment_id=NEW.execution_segment_id AND output.movement_id=NEW.business_refresh_event_id
                AND event.actor_user_id=NEW.business_refresh_actor_id)
        OR EXISTS(SELECT 1 FROM production_material_settlement_events event
            JOIN production_material_settlement_postings posting ON posting.event_id=event.id
            JOIN production_material_demands demand ON demand.id=posting.demand_id
            WHERE event.id=NEW.business_refresh_event_id AND event.created_by=NEW.business_refresh_actor_id
                AND demand.execution_segment_id=NEW.execution_segment_id)
        OR EXISTS(SELECT 1 FROM production_daily_reports report
            JOIN production_daily_report_items item ON item.report_id=report.id
            WHERE report.id=NEW.business_refresh_event_id AND report.status IN(1,-1) AND NOT report.is_deleted
                AND report.updated_by=NEW.business_refresh_actor_id
                AND item.execution_segment_id=NEW.execution_segment_id AND item.is_final AND NOT item.is_deleted)) THEN
        RAISE EXCEPTION 'cost refresh requires the real output, settlement or final-report event and original actor' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

-- Retain V508's active-capacity and RC checks while restoring the final-report
-- quantity window which V508's replacement function accidentally removed.
DO $final_report_allocation$
DECLARE definition TEXT;needle TEXT:='IF TG_OP IN (''UPDATE'', ''DELETE'') THEN';
BEGIN
    SELECT pg_get_functiondef('fn_validate_execution_segment_sales_allocation()'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'execution allocation identity guard changed before V524'; END IF;
    EXECUTE replace(definition,needle,$condition$
    IF TG_OP='DELETE' OR (TG_OP='UPDATE' AND (
        (to_jsonb(NEW)-'allocated_qty') IS DISTINCT FROM (to_jsonb(OLD)-'allocated_qty')
        OR coalesce(current_setting('app.cap_segment_allocations',true),'off')<>'on'
        OR NOT EXISTS(SELECT 1 FROM production_daily_reports report
            JOIN production_daily_report_items item ON item.report_id=report.id
            JOIN plan_order_item_links link ON link.id=NEW.plan_order_item_link_id AND link.plan_item_id=item.plan_item_id
            WHERE report.id::text=current_setting('app.cap_segment_report_id',true) AND NOT report.is_deleted
                AND item.is_final AND NOT item.is_deleted AND item.execution_segment_id=NEW.execution_segment_id
                AND NEW.allocated_qty=link.allocated_qty
                AND (report.status=0 AND NEW.allocated_qty<=OLD.allocated_qty OR report.status=1 AND NEW.allocated_qty>=OLD.allocated_qty))
    )) THEN$condition$);
END;
$final_report_allocation$;
CREATE FUNCTION fn_check_final_report_allocation_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM production_daily_reports report
        JOIN production_daily_report_items item ON item.report_id=report.id
        JOIN plan_order_item_links link ON link.id=NEW.plan_order_item_link_id AND link.plan_item_id=item.plan_item_id
        WHERE item.execution_segment_id=NEW.execution_segment_id AND item.is_final AND NOT item.is_deleted
            AND NOT report.is_deleted AND report.xmin::text=pg_current_xact_id()::text
            AND (NEW.allocated_qty<OLD.allocated_qty AND report.status=1
                OR NEW.allocated_qty>OLD.allocated_qty AND report.status=-1
                OR NEW.allocated_qty=OLD.allocated_qty AND report.status IN(1,-1))) THEN
        RAISE EXCEPTION 'execution target quantity changes require the same transaction final-report approval or reversal' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_final_report_allocation_change AFTER UPDATE ON execution_segment_sales_allocations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_final_report_allocation_change();
ALTER TABLE execution_segment_sales_allocations ENABLE ALWAYS TRIGGER trg_final_report_allocation_change;

CREATE FUNCTION fn_is_final_report_target_change(p_segment UUID,p_before NUMERIC,p_after NUMERIC)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT coalesce(coalesce(current_setting('app.cap_segment_allocations',true),'off')='on'
        AND p_after=(SELECT sum(allocated_qty) FROM execution_segment_sales_allocations WHERE execution_segment_id=p_segment)
        AND EXISTS(SELECT 1 FROM production_daily_reports report
            JOIN production_daily_report_items item ON item.report_id=report.id
            WHERE report.id::text=current_setting('app.cap_segment_report_id',true)
                AND item.execution_segment_id=p_segment AND item.is_final AND NOT item.is_deleted AND NOT report.is_deleted
                AND (report.status=0 AND p_after<=p_before OR report.status=1 AND p_after>=p_before)),false);
$$;
DO $final_report_target$
DECLARE definition TEXT;needle TEXT:='OR OLD.planned_qty IS DISTINCT FROM NEW.planned_qty';
BEGIN
    SELECT pg_get_functiondef('fn_validate_production_execution_segment()'::regprocedure) INTO definition;
    IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'execution frozen target guard changed before V524'; END IF;
    EXECUTE replace(definition,needle,
        'OR (OLD.planned_qty IS DISTINCT FROM NEW.planned_qty AND NOT fn_is_final_report_target_change(OLD.id,OLD.planned_qty,NEW.planned_qty))');
END;
$final_report_target$;
CREATE FUNCTION fn_check_final_report_target_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.planned_qty IS NOT DISTINCT FROM OLD.planned_qty THEN RETURN NULL; END IF;
    IF NOT EXISTS(SELECT 1 FROM production_daily_reports report
        JOIN production_daily_report_items item ON item.report_id=report.id
        WHERE item.execution_segment_id=NEW.id AND item.is_final AND NOT item.is_deleted AND NOT report.is_deleted
            AND report.xmin::text=pg_current_xact_id()::text
            AND (NEW.planned_qty<OLD.planned_qty AND report.status=1 OR NEW.planned_qty>OLD.planned_qty AND report.status=-1)) THEN
        RAISE EXCEPTION 'execution target changes require the actual final-report approval or reversal' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_final_report_target_change AFTER UPDATE ON production_execution_segments
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_final_report_target_change();
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_final_report_target_change;

-- The material requirement keeps its original batch basis even when a final
-- report cancels unproduced output. Existing inconsistent history stays unverified.
ALTER TABLE production_execution_segments ADD COLUMN material_snapshot_product_qty NUMERIC(18,4)
    CHECK(material_snapshot_product_qty>0);
CREATE TEMP TABLE v524_verified_material_basis ON COMMIT DROP AS
    SELECT segment.id,segment.planned_qty,segment.lock_version,segment.updated_at
    FROM production_execution_segments segment
    JOIN production_planning_packages package ON package.id=segment.package_id
    WHERE package.status='CONFIRMED' AND NOT package.is_deleted AND NOT segment.is_deleted
        AND segment.status NOT IN('CANCELLED','REVERSED')
        AND ((segment.material_requirement_mode='ZERO_MATERIAL' AND NOT EXISTS(
            SELECT 1 FROM production_material_demands demand WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted))
            OR (segment.material_requirement_mode='DEMANDED' AND EXISTS(
            SELECT 1 FROM production_material_demands demand WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted)))
        AND NOT EXISTS(SELECT 1 FROM production_material_demands demand WHERE demand.execution_segment_id=segment.id AND NOT demand.is_deleted
            AND (demand.requirement_mode='LINEAR' AND demand.required_qty IS DISTINCT FROM ceil(segment.planned_qty*demand.per_product_qty*10000)/10000
                OR demand.requirement_mode='EXACT_SNAPSHOT' AND demand.required_for_product_qty IS DISTINCT FROM segment.planned_qty
                OR demand.requirement_mode NOT IN('LINEAR','EXACT_SNAPSHOT') OR demand.package_id<>segment.package_id
                OR demand.plan_id<>segment.plan_id OR demand.source_plan_item_id<>segment.source_plan_item_id
                OR demand.warehouse_id IS DISTINCT FROM package.warehouse_id));
-- Only the new verified metadata column is populated; preserve old business versions and timestamps.
ALTER TABLE production_execution_segments DISABLE TRIGGER trg_validate_production_execution_segment;
UPDATE production_execution_segments segment SET material_snapshot_product_qty=verified.planned_qty
    FROM v524_verified_material_basis verified WHERE verified.id=segment.id;
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_validate_production_execution_segment;
DO $basis_preserved$
BEGIN
    IF EXISTS(SELECT 1 FROM production_execution_segments segment JOIN v524_verified_material_basis verified ON verified.id=segment.id
        WHERE segment.lock_version<>verified.lock_version OR segment.updated_at IS DISTINCT FROM verified.updated_at
            OR segment.planned_qty<>verified.planned_qty) THEN
        RAISE EXCEPTION 'material basis registration changed an existing business quantity or version';
    END IF;
END;
$basis_preserved$;
CREATE FUNCTION fn_guard_material_snapshot_product_qty() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' THEN
        IF NEW.material_snapshot_product_qty IS NOT NULL AND NEW.material_snapshot_product_qty<>NEW.planned_qty THEN
            RAISE EXCEPTION 'new material snapshot basis must equal its original approved target' USING ERRCODE='23514';
        END IF;
        NEW.material_snapshot_product_qty:=NEW.planned_qty;
    ELSIF NEW.material_snapshot_product_qty IS DISTINCT FROM OLD.material_snapshot_product_qty THEN
        RAISE EXCEPTION 'original material snapshot quantity is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_00_material_snapshot_product_qty BEFORE INSERT OR UPDATE ON production_execution_segments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_material_snapshot_product_qty();
ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_00_material_snapshot_product_qty;
DO $material_basis$
DECLARE definition TEXT;needle TEXT:='v_segment.planned_qty';
BEGIN
    SELECT pg_get_functiondef('fn_assert_execution_segment_integrity(uuid)'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>2 THEN
        RAISE EXCEPTION 'material snapshot equations changed before V524';
    END IF;
    EXECUTE replace(definition,needle,'coalesce(v_segment.material_snapshot_product_qty,v_segment.planned_qty)');
    SELECT pg_get_functiondef('fn_is_final_report_target_change(uuid,numeric,numeric)'::regprocedure) INTO definition;
    EXECUTE replace(definition,'AND p_after=',
        'AND EXISTS(SELECT 1 FROM production_execution_segments WHERE id=p_segment AND material_snapshot_product_qty IS NOT NULL) AND p_after=');
END;
$material_basis$;
