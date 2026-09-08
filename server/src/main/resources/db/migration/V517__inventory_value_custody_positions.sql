-- V509: exact value custody. No historical quantity, amount or GL rewrite.
-- Historical events have no invented transaction identity. New bindings use
-- this actual creation transaction, never a date/code lookup.
ALTER TABLE stock_value_events ADD COLUMN created_txid BIGINT;
ALTER TABLE stock_value_events ALTER COLUMN created_txid SET DEFAULT txid_current();
ALTER TABLE stock_value_events DROP CONSTRAINT stock_value_event_operation_v506_check;
ALTER TABLE stock_value_events DROP CONSTRAINT stock_value_event_shape_v506_check;
ALTER TABLE stock_value_events ADD CONSTRAINT stock_value_event_operation_v509_check CHECK(operation IN (
    'RECEIVE','ISSUE','RETURN_ISSUE','COST_ADJUST','COST_ADJUST_REVERSE','OPENING','EMPTY_OPENING',
    'POSITION_ACQUIRE','POSITION_MOVE','POSITION_STORE','COST_ALLOCATE'));
ALTER TABLE stock_value_events ADD CONSTRAINT stock_value_event_shape_v509_check CHECK(
    (operation IN ('RECEIVE','ISSUE','RETURN_ISSUE','POSITION_STORE') AND movement_id IS NOT NULL
        AND qty_base IS NOT NULL AND qty_base>0 AND qty_before IS NOT NULL AND qty_before>=0 AND known_value_local>=0)
    OR (operation IN ('COST_ADJUST','COST_ADJUST_REVERSE','COST_ALLOCATE') AND movement_id IS NULL
        AND source_node_id IS NOT NULL AND result_source_revision IS NOT NULL AND result_source_revision>1)
    OR (operation IN ('OPENING','EMPTY_OPENING') AND movement_id IS NULL AND source_node_id IS NOT NULL
        AND result_source_revision=1 AND qty_base IS NOT NULL
        AND ((operation='OPENING' AND qty_base>0) OR (operation='EMPTY_OPENING' AND qty_base=0 AND known_value_local=0))
        AND qty_before IS NOT NULL AND qty_before=qty_base AND known_value_local>=0 AND after_source_final IS NOT NULL)
    OR (operation IN ('POSITION_ACQUIRE','POSITION_MOVE') AND movement_id IS NULL
        AND qty_base IS NOT NULL AND qty_base>0 AND qty_before IS NULL AND known_value_local>=0 AND result_head_id IS NULL
        AND (operation<>'POSITION_ACQUIRE' OR (source_node_id IS NOT NULL AND result_source_revision IS NOT NULL AND result_source_revision=1))));

DO $owners$
DECLARE item RECORD; found_count INTEGER;
BEGIN
    FOR item IN SELECT unnest(ARRAY['stock_value_nodes','stock_value_postings']) AS table_name LOOP
        SELECT count(*) INTO found_count FROM pg_constraint WHERE conrelid=item.table_name::regclass AND contype='c'
            AND pg_get_constraintdef(oid) LIKE '%owner_kind%ANY%';
        IF found_count<>1 THEN RAISE EXCEPTION 'V509 expected one exact owner vocabulary constraint on %',item.table_name; END IF;
        EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I',item.table_name,
            (SELECT conname FROM pg_constraint WHERE conrelid=item.table_name::regclass AND contype='c'
                AND pg_get_constraintdef(oid) LIKE '%owner_kind%ANY%'));
    END LOOP;
END;
$owners$;
ALTER TABLE stock_value_nodes ADD CONSTRAINT stock_value_node_owner_v509_check CHECK(owner_kind IN (
    'COGS','WIP','SUBCONTRACT_WIP','LOSS','IN_TRANSIT','EXTERNAL','QUALITY_PENDING','QUALITY_PASSED',
    'REJECTED_HOLD','SUPPLIER_CUSTODY','RETURN_INSPECTION','COST_WIP'));
ALTER TABLE stock_value_postings ADD CONSTRAINT stock_value_posting_owner_v509_check CHECK(owner_kind IN (
    'INVENTORY','SOURCE','CLEARING','COGS','WIP','SUBCONTRACT_WIP','LOSS','IN_TRANSIT','EXTERNAL',
    'QUALITY_PENDING','QUALITY_PASSED','REJECTED_HOLD','SUPPLIER_CUSTODY','RETURN_INSPECTION','COST_WIP'));

CREATE TABLE stock_value_acquisition_sources (
    source_node_id UUID PRIMARY KEY REFERENCES stock_value_nodes(id) DEFERRABLE INITIALLY DEFERRED,
    event_id UUID NOT NULL UNIQUE REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    evidence_id UUID NOT NULL UNIQUE,
    evidence_version BIGINT NOT NULL CHECK(evidence_version>0),
    authority_type VARCHAR(80) NOT NULL CHECK(authority_type ~ '^[A-Z][A-Z0-9_]{0,79}$'),
    authority_id UUID NOT NULL,
    authority_version BIGINT NOT NULL CHECK(authority_version>0),
    evidence_hash CHAR(64) NOT NULL CHECK(evidence_hash ~ '^[0-9a-f]{64}$'),
    quantity_basis NUMERIC(18,4) NOT NULL CHECK(quantity_basis>0),
    carried_qty_base NUMERIC(18,4) NOT NULL CHECK(carried_qty_base>=0 AND carried_qty_base<=quantity_basis),
    initial_known_value NUMERIC(18,4) CHECK(initial_known_value>=0),
    initial_complete BOOLEAN NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CHECK(NOT initial_complete OR initial_known_value IS NOT NULL)
);
CREATE INDEX idx_stock_value_acquisition_authority ON stock_value_acquisition_sources(authority_type,authority_id,source_node_id);
COMMENT ON TABLE stock_value_acquisition_sources IS 'Approved acquisition component only. AP/GL authority is external; company-owned material value is carried from exact positions, never inferred from supplier charges.';

CREATE TABLE stock_value_position_transfers (
    id UUID PRIMARY KEY,
    event_id UUID NOT NULL REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    source_slice_id UUID NOT NULL,
    source_root_id UUID NOT NULL REFERENCES stock_value_nodes(id),
    source_node_id UUID NOT NULL UNIQUE REFERENCES stock_value_nodes(id),
    remaining_node_id UUID NOT NULL UNIQUE REFERENCES stock_value_nodes(id),
    target_node_id UUID NOT NULL REFERENCES stock_value_nodes(id),
    qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
    range_from NUMERIC(18,4) NOT NULL CHECK(range_from>=0),
    range_to NUMERIC(18,4) NOT NULL,
    quantity_basis NUMERIC(18,4) NOT NULL CHECK(quantity_basis>0),
    source_revision BIGINT NOT NULL CHECK(source_revision>0),
    initial_value_local NUMERIC(18,4) NOT NULL CHECK(initial_value_local>=0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(event_id,source_slice_id),
    CHECK(range_to=range_from+qty_base AND range_to<=quantity_basis)
);
CREATE INDEX idx_stock_value_position_transfer_root ON stock_value_position_transfers(source_root_id,id);
CREATE INDEX idx_stock_value_position_transfer_target ON stock_value_position_transfers(target_node_id,id);
CREATE TRIGGER trg_stock_value_acquisition_immutable BEFORE UPDATE OR DELETE ON stock_value_acquisition_sources
    FOR EACH ROW EXECUTE FUNCTION fn_stock_value_append_only();
CREATE TRIGGER trg_stock_value_position_transfer_immutable BEFORE UPDATE OR DELETE ON stock_value_position_transfers
    FOR EACH ROW EXECUTE FUNCTION fn_stock_value_append_only();

CREATE FUNCTION fn_check_stock_value_position_transfer() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source stock_value_nodes%ROWTYPE; remaining stock_value_nodes%ROWTYPE; target stock_value_nodes%ROWTYPE;
    original_value NUMERIC; event stock_value_events%ROWTYPE;
BEGIN
    SELECT * INTO source FROM stock_value_nodes WHERE id=NEW.source_node_id;
    SELECT * INTO remaining FROM stock_value_nodes WHERE id=NEW.remaining_node_id;
    SELECT * INTO target FROM stock_value_nodes WHERE id=NEW.target_node_id;
    SELECT * INTO event FROM stock_value_events WHERE id=NEW.event_id;
    IF NEW.source_revision=1 THEN original_value:=source.initial_known_value;
    ELSE SELECT after_value INTO original_value FROM stock_value_node_revisions WHERE node_id=source.id AND revision=NEW.source_revision; END IF;
    IF source.kind<>'ISSUE_POSITION' OR source.root_issue_id<>NEW.source_root_id OR source.active
       OR source.range_from<>NEW.range_from OR source.quantity_basis<>NEW.quantity_basis
       OR source.range_to<NEW.range_to OR original_value IS NULL
       OR NEW.initial_value_local<>round(original_value*NEW.range_to/NEW.quantity_basis,4)-round(original_value*NEW.range_from/NEW.quantity_basis,4)
       OR remaining.root_issue_id<>NEW.source_root_id OR remaining.quantity_basis<>NEW.quantity_basis
       OR remaining.range_from<>NEW.range_to OR remaining.range_to<>source.range_to
       OR remaining.owner_kind IS DISTINCT FROM source.owner_kind OR remaining.owner_id IS DISTINCT FROM source.owner_id
       OR remaining.creation_event_id<>NEW.event_id OR target.creation_event_id<>NEW.event_id
       OR event.operation NOT IN ('POSITION_ACQUIRE','POSITION_MOVE','POSITION_STORE')
       OR event.result_node_id<>target.id
       OR NOT EXISTS(SELECT 1 FROM stock_value_edges e WHERE e.parent_node_id=source.id AND e.child_node_id=target.id
            AND e.creation_event_id=NEW.event_id AND e.initial_parent_revision=NEW.source_revision
            AND e.interval_from=NEW.range_from AND e.interval_to=NEW.range_to AND e.denominator=NEW.quantity_basis
            AND e.initial_allocated_amount=NEW.initial_value_local)
       OR NOT EXISTS(SELECT 1 FROM stock_value_edges e WHERE e.parent_node_id=source.id AND e.child_node_id=remaining.id
            AND e.creation_event_id=NEW.event_id AND e.initial_parent_revision=NEW.source_revision
            AND e.interval_from=0 AND e.interval_to=1 AND e.denominator=1 AND e.initial_allocated_amount=original_value)
       OR EXISTS(SELECT 1 FROM stock_value_pools a,stock_value_pools b WHERE a.id=source.pool_id AND b.id=target.pool_id
            AND (a.goods_id<>b.goods_id OR a.color_id IS DISTINCT FROM b.color_id)) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='价值位置携转必须按原范围、原成本及同货品颜色保存两端来源';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_position_transfer_complete AFTER INSERT ON stock_value_position_transfers
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_position_transfer();

CREATE FUNCTION fn_check_stock_value_position_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target stock_value_nodes%ROWTYPE; source stock_value_nodes%ROWTYPE; proof stock_value_acquisition_sources%ROWTYPE;
    carried_qty NUMERIC; carried_value NUMERIC; transfer_count BIGINT;
BEGIN
    IF NEW.operation NOT IN ('POSITION_ACQUIRE','POSITION_MOVE','POSITION_STORE') THEN RETURN NULL; END IF;
    SELECT * INTO target FROM stock_value_nodes WHERE id=NEW.result_node_id;
    SELECT count(*),coalesce(sum(qty_base),0),coalesce(sum(initial_value_local),0)
        INTO transfer_count,carried_qty,carried_value FROM stock_value_position_transfers WHERE event_id=NEW.id;
    IF transfer_count>100 OR target.creation_event_id<>NEW.id OR target.quantity_basis<>NEW.qty_base
       OR target.initial_known_value<>NEW.known_value_local
       OR (NEW.operation='POSITION_STORE' AND (target.kind<>'RETURN_SOURCE' OR target.movement_id IS DISTINCT FROM NEW.movement_id))
       OR (NEW.operation<>'POSITION_STORE' AND (target.kind<>'ISSUE_POSITION' OR target.root_issue_id<>target.id)) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='价值携转结果必须对应同一事件的完整来源和目标';
    END IF;
    IF NEW.operation='POSITION_ACQUIRE' THEN
        SELECT * INTO proof FROM stock_value_acquisition_sources WHERE event_id=NEW.id;
        SELECT * INTO source FROM stock_value_nodes WHERE id=NEW.source_node_id;
        IF proof.source_node_id IS NULL OR proof.source_node_id<>source.id OR source.kind<>'SOURCE'
           OR source.creation_event_id<>NEW.id OR source.movement_id IS NOT NULL
           OR proof.quantity_basis<>NEW.qty_base OR proof.carried_qty_base<>carried_qty
           OR source.initial_known_value<>coalesce(proof.initial_known_value,0)
           OR source.initial_pending<>(CASE WHEN proof.initial_complete THEN 0 ELSE 1 END)
           OR target.initial_known_value<>source.initial_known_value+carried_value
           OR NOT EXISTS(SELECT 1 FROM stock_value_edges WHERE parent_node_id=source.id AND child_node_id=target.id
                AND interval_from=0 AND interval_to=1 AND denominator=1 AND creation_event_id=NEW.id) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='新取得价值必须有独立批准依据，承接旧实物不能重复增加来源金额';
        END IF;
    ELSIF transfer_count=0 OR carried_qty<>NEW.qty_base OR carried_value<>NEW.known_value_local THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='纯位置携转的数量和金额必须等于全部原切片之和';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_position_event_complete AFTER INSERT ON stock_value_events
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_position_event();
CREATE FUNCTION fn_check_stock_value_acquisition_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM stock_value_events e WHERE e.id=NEW.event_id AND e.operation='POSITION_ACQUIRE'
        AND e.source_node_id=NEW.source_node_id AND e.result_source_revision=1
        AND e.qty_base=NEW.quantity_basis) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='取得成本依据只能绑定自己的首次取得事件';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_acquisition_complete AFTER INSERT ON stock_value_acquisition_sources
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_acquisition_source();
ALTER TABLE stock_value_acquisition_sources ENABLE ALWAYS TRIGGER trg_stock_value_acquisition_immutable;
ALTER TABLE stock_value_acquisition_sources ENABLE ALWAYS TRIGGER trg_stock_value_acquisition_complete;
ALTER TABLE stock_value_position_transfers ENABLE ALWAYS TRIGGER trg_stock_value_position_transfer_immutable;
ALTER TABLE stock_value_position_transfers ENABLE ALWAYS TRIGGER trg_stock_value_position_transfer_complete;
ALTER TABLE stock_value_events ENABLE ALWAYS TRIGGER trg_stock_value_position_event_complete;

DO $reset$
DECLARE definition TEXT; anchor TEXT:= '(''stock_value_postings'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF length(definition)-length(replace(definition,anchor,''))<>length(anchor) THEN
        RAISE EXCEPTION 'V509 expected one reset policy anchor';
    END IF;
    EXECUTE replace(definition,anchor,anchor||', (''stock_value_acquisition_sources'', ''CLEAR''), (''stock_value_position_transfers'', ''CLEAR'')');
END;
$reset$;

-- A production input retains its full upstream value; distribution is a
-- separately proven projection. A signed interim deficit is cost in transfer,
-- never a negative physical balance or an unreported loss.
ALTER TABLE stock_value_nodes ADD COLUMN distributed_value_local NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(distributed_value_local>=0);
ALTER TABLE stock_value_nodes DROP COLUMN owned_value_local;
ALTER TABLE stock_value_nodes ADD COLUMN owned_value_local NUMERIC(18,4) GENERATED ALWAYS AS (
    CASE WHEN active AND kind='POOL' THEN basis_value_local
         WHEN active AND kind='ISSUE_POSITION' THEN round(basis_value_local*range_to/quantity_basis,4)
            -round(basis_value_local*range_from/quantity_basis,4)-distributed_value_local
         ELSE 0 END) STORED;
ALTER TABLE stock_value_nodes ADD CONSTRAINT stock_value_distribution_owner_check CHECK(
    distributed_value_local=0 OR (kind='ISSUE_POSITION' AND owner_kind='COST_WIP' AND active));
DO $identity$
DECLARE definition TEXT; anchor TEXT:='''adjustment_head_id'',''owned_value_local'']';
BEGIN
    SELECT pg_get_functiondef('fn_guard_stock_value_projection_identity()'::regprocedure) INTO definition;
    IF length(definition)-length(replace(definition,anchor,''))<>length(anchor) THEN RAISE EXCEPTION 'V509 node projection identity anchor mismatch'; END IF;
    EXECUTE replace(definition,anchor,'''adjustment_head_id'',''owned_value_local'',''distributed_value_local'']');
END;
$identity$;

CREATE TABLE stock_value_production_cost_objects (
    execution_segment_id UUID PRIMARY KEY,
    product_pool_id UUID NOT NULL REFERENCES stock_value_pools(id),
    version BIGINT NOT NULL DEFAULT 0 CHECK(version>=0),
    current_revision_id UUID,
    state TEXT NOT NULL DEFAULT 'PROVISIONAL' CHECK(state IN ('APPLYING','PROVISIONAL','FINAL','PENDING_BASIS','PENDING_CLASSIFICATION')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE stock_value_production_cost_inputs (
    input_node_id UUID PRIMARY KEY REFERENCES stock_value_nodes(id),
    execution_segment_id UUID NOT NULL REFERENCES stock_value_production_cost_objects(execution_segment_id),
    approved_posting_id UUID NOT NULL UNIQUE,
    input_kind TEXT NOT NULL CHECK(input_kind IN ('CONSUMED','NORMAL_LOSS','CONFIRMED_PROCESSING_FEE')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX idx_stock_value_cost_inputs_segment ON stock_value_production_cost_inputs(execution_segment_id,input_node_id);
CREATE TABLE stock_value_production_cost_outputs (
    source_node_id UUID PRIMARY KEY REFERENCES stock_value_nodes(id),
    execution_segment_id UUID NOT NULL REFERENCES stock_value_production_cost_objects(execution_segment_id),
    movement_id UUID NOT NULL UNIQUE REFERENCES stock_movements(id) DEFERRABLE INITIALLY DEFERRED,
    qty_base NUMERIC(18,4) NOT NULL CHECK(qty_base>0),
    output_sequence BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX idx_stock_value_cost_outputs_segment ON stock_value_production_cost_outputs(execution_segment_id,output_sequence);
CREATE FUNCTION fn_check_stock_value_cost_output_binding() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n stock_value_nodes%ROWTYPE; e stock_value_events%ROWTYPE; m stock_movements%ROWTYPE;
BEGIN
    SELECT * INTO n FROM stock_value_nodes WHERE id=NEW.source_node_id;
    SELECT * INTO e FROM stock_value_events WHERE id=n.creation_event_id;
    SELECT * INTO m FROM stock_movements WHERE id=NEW.movement_id;
    IF n.kind NOT IN ('SOURCE','RETURN_SOURCE') OR n.movement_id IS DISTINCT FROM NEW.movement_id
       OR m.id IS NULL OR m.direction<>1 OR m.qty<>NEW.qty_base OR n.quantity_basis<>NEW.qty_base
       OR e.created_txid IS DISTINCT FROM txid_current() THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='产出执行归属必须在同一原始入库事务按精确movement绑定，不能事后重挂';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_cost_output_binding AFTER INSERT ON stock_value_production_cost_outputs
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_cost_output_binding();
ALTER TABLE stock_value_production_cost_outputs ENABLE ALWAYS TRIGGER trg_stock_value_cost_output_binding;
CREATE TABLE stock_value_production_cost_revisions (
    id UUID PRIMARY KEY,
    execution_segment_id UUID NOT NULL REFERENCES stock_value_production_cost_objects(execution_segment_id),
    version BIGINT NOT NULL CHECK(version>0),
    previous_version BIGINT NOT NULL CHECK(previous_version=version-1),
    source_event_id UUID NOT NULL,
    source_doc_type VARCHAR(80) NOT NULL,
    source_doc_id UUID NOT NULL,
    source_item_id UUID NOT NULL,
    source_version BIGINT NOT NULL,
    actor_user_id UUID NOT NULL REFERENCES users(id),
    actor_employee_id UUID NOT NULL REFERENCES employees(id),
    occurred_at TIMESTAMPTZ NOT NULL,
    idempotency_key VARCHAR(160) NOT NULL,
    request_hash CHAR(64) NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),
    request_payload JSONB NOT NULL,
    target_qty_base NUMERIC(18,4) NOT NULL CHECK(target_qty_base>=0),
    output_qty_base NUMERIC(18,4) NOT NULL CHECK(output_qty_base>=0),
    scope_complete BOOLEAN NOT NULL,
    approval_evidence_id UUID NOT NULL,
    approval_evidence_hash CHAR(64) NOT NULL CHECK(approval_evidence_hash ~ '^[0-9a-f]{64}$'),
    input_snapshot JSONB NOT NULL,
    output_snapshot JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(execution_segment_id,version),
    UNIQUE(source_event_id,source_item_id),
    UNIQUE(source_item_id,idempotency_key)
);
ALTER TABLE stock_value_production_cost_objects ADD CONSTRAINT stock_value_cost_current_revision_fk
    FOREIGN KEY(current_revision_id) REFERENCES stock_value_production_cost_revisions(id) DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE stock_value_production_cost_tasks (
    id UUID PRIMARY KEY,
    task_sequence BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
    revision_id UUID NOT NULL REFERENCES stock_value_production_cost_revisions(id),
    execution_segment_id UUID NOT NULL REFERENCES stock_value_production_cost_objects(execution_segment_id),
    input_node_id UUID NOT NULL REFERENCES stock_value_nodes(id),
    output_source_node_id UUID NOT NULL REFERENCES stock_value_nodes(id),
    input_revision BIGINT NOT NULL CHECK(input_revision>0),
    input_value_local NUMERIC(18,4) NOT NULL CHECK(input_value_local>=0),
    input_pending INTEGER NOT NULL CHECK(input_pending>=0),
    output_from NUMERIC(18,4) NOT NULL CHECK(output_from>=0),
    output_to NUMERIC(18,4) NOT NULL CHECK(output_to>=output_from),
    denominator NUMERIC(18,4) NOT NULL CHECK(denominator>=0),
    desired_value_local NUMERIC(18,4) NOT NULL CHECK(desired_value_local>=0),
    status TEXT NOT NULL DEFAULT 'PENDING' CHECK(status IN ('PENDING','APPLIED')),
    before_share_local NUMERIC(18,4),
    before_distributed_local NUMERIC(18,4),
    after_distributed_local NUMERIC(18,4),
    value_event_id UUID UNIQUE REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    UNIQUE(revision_id,input_node_id,output_source_node_id),
    CHECK(status<>'APPLIED' OR (before_share_local IS NOT NULL AND before_distributed_local IS NOT NULL
        AND after_distributed_local IS NOT NULL AND value_event_id IS NOT NULL))
);
CREATE INDEX idx_stock_value_cost_tasks_pending ON stock_value_production_cost_tasks(task_sequence) WHERE status='PENDING';
CREATE INDEX idx_stock_value_cost_tasks_revision ON stock_value_production_cost_tasks(revision_id,status,output_source_node_id);
CREATE TABLE stock_value_production_cost_shares (
    input_node_id UUID NOT NULL REFERENCES stock_value_production_cost_inputs(input_node_id),
    output_source_node_id UUID NOT NULL REFERENCES stock_value_production_cost_outputs(source_node_id),
    allocated_value_local NUMERIC(18,4) NOT NULL CHECK(allocated_value_local>=0),
    last_task_id UUID NOT NULL REFERENCES stock_value_production_cost_tasks(id),
    PRIMARY KEY(input_node_id,output_source_node_id)
);
CREATE INDEX idx_stock_value_cost_shares_output ON stock_value_production_cost_shares(output_source_node_id,input_node_id);
CREATE TABLE stock_value_production_cost_dirty (
    input_node_id UUID PRIMARY KEY REFERENCES stock_value_nodes(id),
    execution_segment_id UUID NOT NULL,
    source_event_id UUID NOT NULL REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    observed_revision BIGINT NOT NULL CHECK(observed_revision>0),
    cleared_revision BIGINT NOT NULL DEFAULT 0 CHECK(cleared_revision>=0 AND cleared_revision<=observed_revision)
);
CREATE INDEX idx_stock_value_cost_dirty_pending ON stock_value_production_cost_dirty(execution_segment_id,input_node_id)
    WHERE observed_revision>cleared_revision;

DO $facts$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['stock_value_production_cost_inputs','stock_value_production_cost_outputs','stock_value_production_cost_revisions'] LOOP
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_stock_value_append_only()',t||'_immutable',t);
        EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER %I',t,t||'_immutable');
    END LOOP;
END;
$facts$;

CREATE FUNCTION fn_guard_stock_value_cost_projection() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE allowed TEXT[];
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='生产成本来源和分配不可删除'; END IF;
    IF TG_TABLE_NAME='stock_value_production_cost_objects' THEN
        allowed:=ARRAY['version','current_revision_id','state'];
        IF NEW.version<OLD.version OR NEW.version>OLD.version+1 THEN RAISE EXCEPTION '生产成本版本必须连续'; END IF;
    ELSIF TG_TABLE_NAME='stock_value_production_cost_tasks' THEN
        allowed:=ARRAY['status','before_share_local','before_distributed_local','after_distributed_local','value_event_id'];
        IF OLD.status<>'PENDING' OR NEW.status<>'APPLIED' THEN RAISE EXCEPTION '生产成本任务只能完成一次'; END IF;
    ELSIF TG_TABLE_NAME='stock_value_production_cost_shares' THEN
        allowed:=ARRAY['allocated_value_local','last_task_id'];
    ELSE
        allowed:=ARRAY['source_event_id','observed_revision','cleared_revision'];
        IF NEW.observed_revision<OLD.observed_revision OR NEW.cleared_revision<OLD.cleared_revision THEN RAISE EXCEPTION '成本重分摊观察版本不能倒退'; END IF;
    END IF;
    IF (to_jsonb(NEW)-allowed) IS DISTINCT FROM (to_jsonb(OLD)-allowed) THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='生产成本责任、来源和冻结分母不可改写';
    END IF;
    RETURN NEW;
END;
$$;
DO $projection$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['stock_value_production_cost_objects','stock_value_production_cost_tasks','stock_value_production_cost_shares','stock_value_production_cost_dirty'] LOOP
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_value_cost_projection()',t||'_identity',t);
        EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER %I',t,t||'_identity');
    END LOOP;
END;
$projection$;

CREATE FUNCTION fn_check_stock_value_cost_distribution() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE current_node stock_value_nodes%ROWTYPE;
BEGIN
    SELECT * INTO current_node FROM stock_value_nodes WHERE id=NEW.id;
    IF current_node.distributed_value_local IS DISTINCT FROM
        (SELECT coalesce(sum(allocated_value_local),0) FROM stock_value_production_cost_shares WHERE input_node_id=NEW.id) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='在制已分配投影必须等于原输入对每个成品的当前份额';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_cost_distribution AFTER INSERT OR UPDATE OF distributed_value_local ON stock_value_nodes
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_cost_distribution();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_cost_distribution;

CREATE FUNCTION fn_check_stock_value_cost_task() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e stock_value_events%ROWTYPE; share stock_value_production_cost_shares%ROWTYPE;
BEGIN
    IF NEW.status<>'APPLIED' THEN RETURN NULL; END IF;
    SELECT * INTO e FROM stock_value_events WHERE id=NEW.value_event_id;
    SELECT * INTO share FROM stock_value_production_cost_shares
        WHERE input_node_id=NEW.input_node_id AND output_source_node_id=NEW.output_source_node_id;
    IF e.operation IS DISTINCT FROM 'COST_ALLOCATE' OR e.source_node_id IS DISTINCT FROM NEW.output_source_node_id
       OR e.known_value_local IS DISTINCT FROM NEW.desired_value_local-NEW.before_share_local
       OR NEW.after_distributed_local IS DISTINCT FROM NEW.before_distributed_local+e.known_value_local
       OR e.source_doc_id IS DISTINCT FROM NEW.execution_segment_id OR e.source_item_id IS DISTINCT FROM NEW.id
       OR NOT EXISTS(SELECT 1 FROM stock_value_node_revisions n WHERE n.event_id=e.id
            AND n.node_id=NEW.output_source_node_id AND n.revision=e.result_source_revision
            AND n.after_value-n.before_value=e.known_value_local)
       OR EXISTS(SELECT 1 FROM stock_value_production_cost_revisions r WHERE r.id=NEW.revision_id
            AND r.target_qty_base>0 AND r.output_qty_base>r.target_qty_base AND NEW.desired_value_local<>NEW.before_share_local)
       OR NOT EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=e.id AND node_id=NEW.input_node_id
            AND owner_kind='COST_WIP' AND owner_id=NEW.execution_segment_id AND amount_delta_local=-e.known_value_local)
            AND e.known_value_local<>0 THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='生产分配必须在同一事件减少原在制份额并增加精确成品来源';
    END IF;
    IF share.last_task_id=NEW.id AND share.allocated_value_local<>NEW.desired_value_local THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='生产当前份额与本次追加分配事件不一致';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_cost_task_complete AFTER UPDATE ON stock_value_production_cost_tasks
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_cost_task();
ALTER TABLE stock_value_production_cost_tasks ENABLE ALWAYS TRIGGER trg_stock_value_cost_task_complete;

CREATE FUNCTION fn_check_stock_value_cost_share() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE t stock_value_production_cost_tasks%ROWTYPE;
BEGIN
    SELECT * INTO t FROM stock_value_production_cost_tasks WHERE id=NEW.last_task_id;
    IF t.status IS DISTINCT FROM 'APPLIED' OR t.input_node_id IS DISTINCT FROM NEW.input_node_id
       OR t.output_source_node_id IS DISTINCT FROM NEW.output_source_node_id OR t.desired_value_local IS DISTINCT FROM NEW.allocated_value_local THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='生产当前分配份额必须有已经完成的对应版本任务';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_cost_share_complete AFTER INSERT OR UPDATE ON stock_value_production_cost_shares
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_cost_share();
ALTER TABLE stock_value_production_cost_shares ENABLE ALWAYS TRIGGER trg_stock_value_cost_share_complete;

CREATE FUNCTION fn_check_stock_value_cost_object() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE current_object stock_value_production_cost_objects%ROWTYPE; r stock_value_production_cost_revisions%ROWTYPE; expected TEXT;
BEGIN
    SELECT * INTO current_object FROM stock_value_production_cost_objects WHERE execution_segment_id=NEW.execution_segment_id;
    IF current_object.version=0 THEN RETURN NULL; END IF;
    SELECT * INTO r FROM stock_value_production_cost_revisions WHERE id=current_object.current_revision_id;
    IF r.id IS NULL OR r.version<>current_object.version OR r.execution_segment_id<>current_object.execution_segment_id THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='生产成本当前版本必须对应本执行段的追加批准方案';
    END IF;
    expected:=CASE WHEN EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE revision_id=r.id AND status='PENDING') THEN 'APPLYING'
        WHEN r.target_qty_base=0 THEN 'PENDING_CLASSIFICATION' WHEN r.output_qty_base>r.target_qty_base THEN 'PENDING_BASIS'
        WHEN r.scope_complete AND jsonb_array_length(r.input_snapshot)>0 AND jsonb_array_length(r.output_snapshot)>0
            AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(r.input_snapshot) i WHERE (i->>'pending')::integer>0) THEN 'FINAL'
        ELSE 'PROVISIONAL' END;
    IF current_object.state<>expected THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='生产成本状态与实际分配任务及完整性依据不一致'; END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_cost_object_complete AFTER INSERT OR UPDATE ON stock_value_production_cost_objects
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_cost_object();
ALTER TABLE stock_value_production_cost_objects ENABLE ALWAYS TRIGGER trg_stock_value_cost_object_complete;

CREATE FUNCTION fn_check_stock_value_cost_dirty() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM stock_value_nodes n JOIN stock_value_node_revisions r ON r.node_id=n.id
        WHERE n.id=NEW.input_node_id AND n.owner_kind='COST_WIP' AND n.owner_id=NEW.execution_segment_id
            AND r.revision=NEW.observed_revision AND r.event_id=NEW.source_event_id)
       OR (NEW.cleared_revision>0 AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_revisions p
            CROSS JOIN LATERAL jsonb_array_elements(p.input_snapshot) i WHERE p.execution_segment_id=NEW.execution_segment_id
                AND (i->>'node')::uuid=NEW.input_node_id AND (i->>'revision')::bigint>=NEW.cleared_revision)) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='成本后补观察与清除必须对应真实来源revision和已建立的重新分配方案';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_cost_dirty_complete AFTER INSERT OR UPDATE ON stock_value_production_cost_dirty
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_cost_dirty();
ALTER TABLE stock_value_production_cost_dirty ENABLE ALWAYS TRIGGER trg_stock_value_cost_dirty_complete;

CREATE FUNCTION fn_check_stock_value_cost_task_plan() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r stock_value_production_cost_revisions%ROWTYPE; i JSONB; o JSONB; actual NUMERIC; actual_pending INTEGER; expected NUMERIC;
BEGIN
    SELECT * INTO r FROM stock_value_production_cost_revisions WHERE id=NEW.revision_id;
    SELECT value INTO i FROM jsonb_array_elements(r.input_snapshot) WHERE (value->>'node')::uuid=NEW.input_node_id;
    SELECT value INTO o FROM jsonb_array_elements(r.output_snapshot) WHERE (value->>'source')::uuid=NEW.output_source_node_id;
    IF NEW.input_revision=1 THEN SELECT initial_known_value,initial_pending INTO actual,actual_pending FROM stock_value_nodes WHERE id=NEW.input_node_id;
    ELSE SELECT after_value,after_pending INTO actual,actual_pending FROM stock_value_node_revisions WHERE node_id=NEW.input_node_id AND revision=NEW.input_revision; END IF;
    IF r.id IS NULL OR i IS NULL OR o IS NULL OR actual IS NULL OR actual<>NEW.input_value_local OR actual_pending<>NEW.input_pending
       OR r.execution_segment_id<>NEW.execution_segment_id OR NEW.input_revision<>(i->>'revision')::bigint
       OR NEW.input_value_local<>(i->>'value')::numeric OR NEW.input_pending<>(i->>'pending')::integer
       OR NEW.output_from<>(o->>'from')::numeric OR NEW.output_to<>(o->>'to')::numeric OR NEW.denominator<>r.target_qty_base
       OR NOT EXISTS(SELECT 1 FROM stock_value_production_cost_inputs x JOIN stock_value_nodes n ON n.id=x.input_node_id
            WHERE x.input_node_id=NEW.input_node_id AND x.execution_segment_id=NEW.execution_segment_id
                AND n.kind='ISSUE_POSITION' AND n.owner_kind='COST_WIP' AND n.owner_id=NEW.execution_segment_id
                AND n.id=n.root_issue_id AND n.range_from=0 AND n.range_to=n.quantity_basis)
       OR NOT EXISTS(SELECT 1 FROM stock_value_production_cost_outputs x WHERE x.source_node_id=NEW.output_source_node_id
            AND x.execution_segment_id=NEW.execution_segment_id AND x.movement_id=(o->>'movement')::uuid
            AND x.qty_base=NEW.output_to-NEW.output_from) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='生产分配任务必须采用本版本冻结的真实耗用revision和产出movement切片';
    END IF;
    IF NEW.denominator=0 THEN expected:=0;
    ELSIF r.output_qty_base>r.target_qty_base THEN expected:=NEW.desired_value_local; -- no monetary redistribution; completion checks old share below
    ELSE expected:=round(NEW.input_value_local*NEW.output_to/NEW.denominator,4)-round(NEW.input_value_local*NEW.output_from/NEW.denominator,4); END IF;
    IF NEW.desired_value_local<>expected THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='生产分配金额必须按冻结分母和累计四位尾差计算'; END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_cost_task_plan AFTER INSERT ON stock_value_production_cost_tasks
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_cost_task_plan();
ALTER TABLE stock_value_production_cost_tasks ENABLE ALWAYS TRIGGER trg_stock_value_cost_task_plan;

DO $cost_reset$
DECLARE definition TEXT; anchor TEXT:= '(''stock_value_postings'', ''CLEAR'')'; t TEXT; addition TEXT:='';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF length(definition)-length(replace(definition,anchor,''))<>length(anchor) THEN RAISE EXCEPTION 'V509 cost reset anchor mismatch'; END IF;
    FOREACH t IN ARRAY ARRAY['stock_value_production_cost_objects','stock_value_production_cost_inputs','stock_value_production_cost_outputs',
        'stock_value_production_cost_revisions','stock_value_production_cost_tasks','stock_value_production_cost_shares','stock_value_production_cost_dirty'] LOOP
        addition:=addition||format(', (%L, ''CLEAR'')',t);
    END LOOP;
    EXECUTE replace(definition,anchor,anchor||addition);
END;
$cost_reset$;

-- Exact authorities reuse source/edge/revision references. The old finite
-- amount columns remain compatibility projections; they are not source facts.
ALTER TABLE stock_value_nodes ADD COLUMN creation_txid BIGINT;
ALTER TABLE stock_value_nodes ALTER COLUMN creation_txid SET DEFAULT txid_current();
ALTER TABLE stock_value_nodes ADD COLUMN value_model TEXT NOT NULL DEFAULT 'LEGACY_4_PROJECTION'
    CHECK(value_model IN ('LEGACY_4_PROJECTION','EXACT_SOURCE_SHARES'));
ALTER TABLE stock_value_nodes ADD COLUMN source_initial_amount_exact NUMERIC;
ALTER TABLE stock_value_nodes ADD COLUMN source_amount_exact NUMERIC;
ALTER TABLE stock_value_nodes ADD COLUMN initial_bound_lower NUMERIC;
ALTER TABLE stock_value_nodes ADD COLUMN initial_bound_upper NUMERIC;
ALTER TABLE stock_value_nodes ADD COLUMN initial_bound_scale INTEGER;
ALTER TABLE stock_value_nodes ADD COLUMN bound_lower NUMERIC;
ALTER TABLE stock_value_nodes ADD COLUMN bound_upper NUMERIC;
ALTER TABLE stock_value_nodes ADD COLUMN bound_scale INTEGER;
ALTER TABLE stock_value_nodes ADD COLUMN bound_revision BIGINT;
ALTER TABLE stock_value_nodes ADD CONSTRAINT stock_value_exact_source_check CHECK(
    (source_amount_exact IS NULL OR (kind='SOURCE' AND source_amount_exact NOT IN ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)
        AND source_amount_exact>=0 AND source_amount_exact<power(10::numeric,40) AND scale(trim_scale(source_amount_exact))<=30))
    AND (source_initial_amount_exact IS NULL OR (kind='SOURCE' AND source_initial_amount_exact NOT IN ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)
        AND source_initial_amount_exact>=0 AND source_initial_amount_exact<power(10::numeric,40) AND scale(trim_scale(source_initial_amount_exact))<=30)));
ALTER TABLE stock_value_nodes ADD CONSTRAINT stock_value_bounds_check CHECK(
    (bound_lower IS NULL AND bound_upper IS NULL AND bound_scale IS NULL)
    OR (bound_lower IS NOT NULL AND bound_upper IS NOT NULL AND bound_lower<=bound_upper AND bound_scale BETWEEN 0 AND 256));

ALTER TABLE stock_value_edges ADD COLUMN creation_txid BIGINT;
ALTER TABLE stock_value_edges ALTER COLUMN creation_txid SET DEFAULT txid_current();
ALTER TABLE stock_value_edges ADD COLUMN initial_bound_lower NUMERIC;
ALTER TABLE stock_value_edges ADD COLUMN initial_bound_upper NUMERIC;
ALTER TABLE stock_value_edges ADD COLUMN allocated_bound_lower NUMERIC;
ALTER TABLE stock_value_edges ADD COLUMN allocated_bound_upper NUMERIC;
ALTER TABLE stock_value_edges ADD COLUMN bound_scale INTEGER;
ALTER TABLE stock_value_edges ADD COLUMN bound_parent_revision BIGINT;
ALTER TABLE stock_value_node_revisions ADD COLUMN creation_txid BIGINT;
ALTER TABLE stock_value_node_revisions ALTER COLUMN creation_txid SET DEFAULT txid_current();
ALTER TABLE stock_value_node_revisions ADD COLUMN before_source_amount_exact NUMERIC;
ALTER TABLE stock_value_node_revisions ADD COLUMN after_source_amount_exact NUMERIC;
ALTER TABLE stock_value_node_revisions ADD COLUMN before_bound_lower NUMERIC;
ALTER TABLE stock_value_node_revisions ADD COLUMN before_bound_upper NUMERIC;
ALTER TABLE stock_value_node_revisions ADD COLUMN before_bound_scale INTEGER;
ALTER TABLE stock_value_node_revisions ADD COLUMN after_bound_lower NUMERIC;
ALTER TABLE stock_value_node_revisions ADD COLUMN after_bound_upper NUMERIC;
ALTER TABLE stock_value_node_revisions ADD COLUMN after_bound_scale INTEGER;
ALTER TABLE stock_value_events ADD COLUMN source_delta_exact NUMERIC;
ALTER TABLE stock_value_production_cost_tasks ADD COLUMN previous_task_id UUID REFERENCES stock_value_production_cost_tasks(id);
ALTER TABLE stock_value_production_cost_tasks ADD COLUMN exact_basis_task_id UUID REFERENCES stock_value_production_cost_tasks(id);

CREATE FUNCTION fn_guard_stock_value_exact_revision_metadata() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE permitted TEXT[]:=ARRAY['before_source_amount_exact','after_source_amount_exact','before_bound_lower','before_bound_upper',
    'before_bound_scale','after_bound_lower','after_bound_upper','after_bound_scale'];
BEGIN
    IF TG_OP='DELETE' OR OLD.creation_txid IS DISTINCT FROM txid_current()
       OR (to_jsonb(NEW)-permitted) IS DISTINCT FROM (to_jsonb(OLD)-permitted)
       OR OLD.before_bound_lower IS NOT NULL OR OLD.after_bound_lower IS NOT NULL
       OR OLD.before_source_amount_exact IS NOT NULL OR OLD.after_source_amount_exact IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='价值revision事实不可改写；精确源和精度界只能在原事务初始化一次';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER trg_stock_value_revisions_immutable ON stock_value_node_revisions;
CREATE TRIGGER trg_stock_value_revisions_immutable BEFORE UPDATE OR DELETE ON stock_value_node_revisions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_value_exact_revision_metadata();
ALTER TABLE stock_value_node_revisions ENABLE ALWAYS TRIGGER trg_stock_value_revisions_immutable;

DO $exact_identity$
DECLARE definition TEXT; anchor TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_stock_value_projection_identity()'::regprocedure) INTO definition;
    anchor:='''adjustment_head_id'',''owned_value_local'',''distributed_value_local'']';
    IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'V509 exact node identity anchor missing'; END IF;
    definition:=replace(definition,anchor,'''adjustment_head_id'',''owned_value_local'',''distributed_value_local'',
        ''value_model'',''source_initial_amount_exact'',''source_amount_exact'',''initial_bound_lower'',''initial_bound_upper'',
        ''initial_bound_scale'',''bound_lower'',''bound_upper'',''bound_scale'',''bound_revision'']');
    anchor:='allowed:=ARRAY[''last_parent_revision'',''allocated_amount_local'',''pending_contribution''];';
    IF strpos(definition,anchor)=0 THEN RAISE EXCEPTION 'V509 exact edge identity anchor missing'; END IF;
    definition:=replace(definition,anchor,'allowed:=ARRAY[''last_parent_revision'',''allocated_amount_local'',''pending_contribution'',
        ''initial_bound_lower'',''initial_bound_upper'',''allocated_bound_lower'',''allocated_bound_upper'',''bound_scale'',''bound_parent_revision''];');
    definition:=replace(definition,'IF NEW.last_parent_revision<>OLD.last_parent_revision+1 THEN',
        'IF NEW.last_parent_revision<>OLD.last_parent_revision+1 AND NOT (NEW.last_parent_revision=OLD.last_parent_revision
            AND NEW.allocated_amount_local=OLD.allocated_amount_local AND NEW.pending_contribution=OLD.pending_contribution) THEN');
    EXECUTE definition;
    SELECT pg_get_functiondef('fn_guard_stock_value_cost_projection()'::regprocedure) INTO definition;
    definition:=replace(definition,'''after_distributed_local'',''value_event_id'']',
        '''after_distributed_local'',''value_event_id'',''previous_task_id'',''exact_basis_task_id'']');
    EXECUTE definition;
END;
$exact_identity$;

-- Only monetary projections are widened for the approved finite-source range;
-- quantities/rates and all historical numeric values retain their semantics.
CREATE TEMP TABLE v509_monthly_projection_definition(definition TEXT,indexes TEXT[],owner_name TEXT,comment_text TEXT,
    grants JSONB,options TEXT[],tablespace_name TEXT) ON COMMIT DROP;
DO $monthly_before$
BEGIN
    IF to_regclass('public.stock_monthly_mv') IS NOT NULL THEN
        INSERT INTO v509_monthly_projection_definition
        SELECT pg_get_viewdef(c.oid,true),ARRAY(SELECT pg_get_indexdef(i.indexrelid) FROM pg_index i WHERE i.indrelid=c.oid ORDER BY i.indexrelid),
            pg_get_userbyid(c.relowner),obj_description(c.oid,'pg_class'),
            coalesce((SELECT jsonb_agg(jsonb_build_object('grantee',CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
                'privilege',a.privilege_type,'grantable',a.is_grantable)) FROM aclexplode(c.relacl) a),'[]'::jsonb),c.reloptions,
            (SELECT spcname FROM pg_tablespace WHERE oid=c.reltablespace)
        FROM pg_class c WHERE c.oid='public.stock_monthly_mv'::regclass AND c.relkind='m';
        IF NOT FOUND THEN RAISE EXCEPTION 'V509 expected stock_monthly_mv to remain a materialized projection'; END IF;
        DROP MATERIALIZED VIEW stock_monthly_mv;
    END IF;
END;
$monthly_before$;
ALTER TABLE stock_value_nodes DROP COLUMN owned_value_local;
DROP TRIGGER trg_stock_value_revision_fact ON stock_value_nodes;
DROP TRIGGER trg_stock_value_cost_distribution ON stock_value_nodes;
DO $projection_width$
DECLARE t TEXT; c TEXT;
BEGIN
    FOR t,c IN SELECT * FROM (VALUES
        ('stock_balances','amount_local'),('stock_movements','amount_local'),
        ('stock_value_pools','legacy_amount_local'),('stock_value_events','known_value_local'),
        ('stock_value_nodes','initial_known_value'),('stock_value_nodes','basis_value_local'),('stock_value_nodes','distributed_value_local'),
        ('stock_value_edges','initial_allocated_amount'),('stock_value_edges','allocated_amount_local'),
        ('stock_value_jobs','clearing_remaining_local'),('stock_value_tasks','target_amount_local'),('stock_value_tasks','applied_delta_local'),
        ('stock_value_node_revisions','before_value'),('stock_value_node_revisions','after_value'),('stock_value_postings','amount_delta_local'),
        ('stock_value_openings','known_value_local'),('stock_value_openings','observed_recorded_value'),
        ('stock_value_legacy_balance_cases','observed_recorded_value'),('stock_value_acquisition_sources','initial_known_value'),
        ('stock_value_position_transfers','initial_value_local'),('stock_value_production_cost_tasks','input_value_local'),
        ('stock_value_production_cost_tasks','desired_value_local'),('stock_value_production_cost_tasks','before_share_local'),
        ('stock_value_production_cost_tasks','before_distributed_local'),('stock_value_production_cost_tasks','after_distributed_local'),
        ('stock_value_production_cost_shares','allocated_value_local')) v(t,c) LOOP
        EXECUTE format('ALTER TABLE %I ALTER COLUMN %I TYPE NUMERIC',t,c);
    END LOOP;
END;
$projection_width$;
ALTER TABLE stock_value_nodes ADD COLUMN owned_value_local NUMERIC GENERATED ALWAYS AS (
    CASE WHEN active AND kind='POOL' THEN basis_value_local
         WHEN active AND kind='ISSUE_POSITION' THEN round(basis_value_local*range_to/quantity_basis,4)
            -round(basis_value_local*range_from/quantity_basis,4)-distributed_value_local ELSE 0 END) STORED;
CREATE CONSTRAINT TRIGGER trg_stock_value_revision_fact AFTER UPDATE OF basis_value_local,pending_parents,revision,source_final ON stock_value_nodes
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_node_revision();
CREATE CONSTRAINT TRIGGER trg_stock_value_cost_distribution AFTER INSERT OR UPDATE OF distributed_value_local ON stock_value_nodes
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_cost_distribution();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_revision_fact;
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_cost_distribution;
DO $monthly_after$
DECLARE saved RECORD; statement TEXT; item TEXT; grant_row JSONB;
BEGIN
    FOR saved IN SELECT * FROM v509_monthly_projection_definition LOOP
        statement:='CREATE MATERIALIZED VIEW public.stock_monthly_mv';
        IF coalesce(array_length(saved.options,1),0)>0 THEN statement:=statement||' WITH ('||array_to_string(saved.options,',')||')'; END IF;
        IF saved.tablespace_name IS NOT NULL THEN statement:=statement||format(' TABLESPACE %I',saved.tablespace_name); END IF;
        EXECUTE statement||' AS '||rtrim(saved.definition,E';\n\r ')||' WITH DATA';
        FOREACH item IN ARRAY saved.indexes LOOP EXECUTE item; END LOOP;
        EXECUTE format('COMMENT ON MATERIALIZED VIEW public.stock_monthly_mv IS %L',saved.comment_text);
        FOR grant_row IN SELECT value FROM jsonb_array_elements(saved.grants) LOOP
            EXECUTE 'GRANT '||(grant_row->>'privilege')||' ON public.stock_monthly_mv TO '
                ||CASE WHEN grant_row->>'grantee'='PUBLIC' THEN 'PUBLIC' ELSE quote_ident(grant_row->>'grantee') END
                ||CASE WHEN (grant_row->>'grantable')::boolean THEN ' WITH GRANT OPTION' ELSE '' END;
        END LOOP;
        EXECUTE format('ALTER MATERIALIZED VIEW public.stock_monthly_mv OWNER TO %I',saved.owner_name);
    END LOOP;
END;
$monthly_after$;

CREATE FUNCTION fn_guard_stock_value_exact_identity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.value_model IS DISTINCT FROM OLD.value_model OR NEW.source_initial_amount_exact IS DISTINCT FROM OLD.source_initial_amount_exact)
       AND (OLD.creation_txid IS DISTINCT FROM txid_current() OR OLD.revision<>1) THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='原始金额和精确模型身份只能在原创建事务确定';
    END IF;
    IF NEW.source_amount_exact IS DISTINCT FROM OLD.source_amount_exact
       AND OLD.creation_txid IS DISTINCT FROM txid_current()
       AND NOT EXISTS(SELECT 1 FROM stock_value_node_revisions r WHERE r.node_id=NEW.id AND r.revision=NEW.revision
            AND r.creation_txid=txid_current() AND r.after_source_amount_exact IS NOT DISTINCT FROM NEW.source_amount_exact) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='来源原额改变必须有同事务精确金额revision';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_stock_value_exact_identity BEFORE UPDATE ON stock_value_nodes
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_value_exact_identity();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_exact_identity;

CREATE FUNCTION fn_check_stock_value_source_exact_revision() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e stock_value_events%ROWTYPE;
BEGIN
    SELECT * INTO e FROM stock_value_events WHERE id=NEW.event_id;
    IF NEW.before_source_amount_exact IS DISTINCT FROM NEW.after_source_amount_exact THEN
        IF e.operation NOT IN ('COST_ADJUST','COST_ADJUST_REVERSE') OR e.source_delta_exact IS NULL
           OR NEW.after_source_amount_exact-NEW.before_source_amount_exact IS DISTINCT FROM e.source_delta_exact THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='来源精确原额只能按实际批准增减额改变，不能使用显示投影差';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_source_exact_revision AFTER INSERT OR UPDATE ON stock_value_node_revisions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_source_exact_revision();
ALTER TABLE stock_value_node_revisions ENABLE ALWAYS TRIGGER trg_stock_value_source_exact_revision;

ALTER TABLE stock_value_production_cost_tasks ADD COLUMN exact_share_lower NUMERIC;
ALTER TABLE stock_value_production_cost_tasks ADD COLUMN exact_share_upper NUMERIC;
ALTER TABLE stock_value_production_cost_tasks ADD COLUMN exact_share_scale INTEGER;
DO $share_identity$
DECLARE definition TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_stock_value_cost_projection()'::regprocedure) INTO definition;
    definition:=replace(definition,'''previous_task_id'',''exact_basis_task_id'']',
        '''previous_task_id'',''exact_basis_task_id'',''exact_share_lower'',''exact_share_upper'',''exact_share_scale'']');
    EXECUTE definition;
END;
$share_identity$;

CREATE FUNCTION fn_stock_value_reference_bounds(p_node UUID,p_revision BIGINT)
RETURNS TABLE(lower_value NUMERIC,upper_value NUMERIC) LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN n.revision=p_revision AND n.bound_revision=p_revision THEN n.bound_lower
                WHEN p_revision=1 THEN n.initial_bound_lower ELSE r.after_bound_lower END,
           CASE WHEN n.revision=p_revision AND n.bound_revision=p_revision THEN n.bound_upper
                WHEN p_revision=1 THEN n.initial_bound_upper ELSE r.after_bound_upper END
    FROM stock_value_nodes n LEFT JOIN stock_value_node_revisions r ON r.node_id=n.id AND r.revision=p_revision
    WHERE n.id=p_node
$$;

CREATE FUNCTION fn_check_stock_value_exact_bounds() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n stock_value_nodes%ROWTYPE; expected_lower NUMERIC; expected_upper NUMERIC; unknown_count BIGINT;
BEGIN
    SELECT * INTO n FROM stock_value_nodes WHERE id=NEW.id;
    IF n.value_model<>'EXACT_SOURCE_SHARES' THEN RETURN NULL; END IF;
    IF n.kind='SOURCE' THEN
        IF n.source_initial_amount_exact IS NULL OR n.source_amount_exact IS NULL
           OR n.initial_bound_lower IS DISTINCT FROM n.source_initial_amount_exact
           OR n.initial_bound_upper IS DISTINCT FROM n.source_initial_amount_exact THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='取得来源必须保留未裁剪原额，不能拿四位显示金额当原额';
        END IF;
    ELSE
        SELECT coalesce(sum(initial_bound_lower),0),coalesce(sum(initial_bound_upper),0),
            count(*) FILTER(WHERE initial_bound_lower IS NULL OR initial_bound_upper IS NULL)
            INTO expected_lower,expected_upper,unknown_count FROM stock_value_edges WHERE child_node_id=n.id;
        IF (unknown_count>0 AND (n.initial_bound_lower IS NOT NULL OR n.initial_bound_upper IS NOT NULL))
           OR (unknown_count=0 AND (n.initial_bound_lower IS NULL OR n.initial_bound_upper IS NULL
                OR n.initial_bound_lower>expected_lower OR n.initial_bound_upper<expected_upper)) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='初始金额界必须覆盖原输入份额，不能反馈已舍入缓存';
        END IF;
    END IF;
    SELECT coalesce(sum(lo),0),coalesce(sum(hi),0),count(*) FILTER(WHERE lo IS NULL OR hi IS NULL)
        INTO expected_lower,expected_upper,unknown_count FROM (
            SELECT allocated_bound_lower lo,allocated_bound_upper hi FROM stock_value_edges WHERE child_node_id=n.id
            UNION ALL SELECT t.exact_share_lower,t.exact_share_upper FROM stock_value_production_cost_shares s
                JOIN stock_value_production_cost_tasks t ON t.id=s.last_task_id WHERE s.output_source_node_id=n.id
        ) contributions;
    IF n.kind='SOURCE' THEN expected_lower:=expected_lower+n.source_amount_exact;expected_upper:=expected_upper+n.source_amount_exact; END IF;
    IF n.bound_revision IS DISTINCT FROM n.revision
       OR (unknown_count>0 AND (n.bound_lower IS NOT NULL OR n.bound_upper IS NOT NULL))
       OR (unknown_count=0 AND (n.bound_lower IS NULL OR n.bound_upper IS NULL OR n.bound_lower>expected_lower OR n.bound_upper<expected_upper)) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='金额精度界必须覆盖同版来源表达式，显示缓存不能改变权威';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_exact_bounds AFTER INSERT OR UPDATE ON stock_value_nodes
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_exact_bounds();
ALTER TABLE stock_value_nodes ENABLE ALWAYS TRIGGER trg_stock_value_exact_bounds;

CREATE FUNCTION fn_check_stock_value_edge_bounds() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e stock_value_edges%ROWTYPE; lo NUMERIC; hi NUMERIC; model TEXT;
BEGIN
    SELECT * INTO e FROM stock_value_edges WHERE id=NEW.id;
    SELECT value_model INTO model FROM stock_value_nodes WHERE id=e.child_node_id;
    IF model<>'EXACT_SOURCE_SHARES' THEN RETURN NULL; END IF;
    SELECT lower_value,upper_value INTO lo,hi FROM fn_stock_value_reference_bounds(e.parent_node_id,e.initial_parent_revision);
    IF (lo IS NULL OR hi IS NULL) AND (e.initial_bound_lower IS NOT NULL OR e.initial_bound_upper IS NOT NULL)
       OR (lo IS NOT NULL AND hi IS NOT NULL AND (e.initial_bound_lower IS NULL OR e.initial_bound_upper IS NULL
           OR e.initial_bound_lower*e.denominator>lo*(e.interval_to-e.interval_from)
           OR e.initial_bound_upper*e.denominator<hi*(e.interval_to-e.interval_from))) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='分配精度界必须覆盖原节点版本乘精确数量份额';
    END IF;
    SELECT lower_value,upper_value INTO lo,hi FROM fn_stock_value_reference_bounds(e.parent_node_id,e.last_parent_revision);
    IF e.bound_parent_revision IS DISTINCT FROM e.last_parent_revision
       OR ((lo IS NULL OR hi IS NULL) AND (e.allocated_bound_lower IS NOT NULL OR e.allocated_bound_upper IS NOT NULL))
       OR (lo IS NOT NULL AND hi IS NOT NULL AND (e.allocated_bound_lower IS NULL OR e.allocated_bound_upper IS NULL
           OR e.allocated_bound_lower*e.denominator>lo*(e.interval_to-e.interval_from)
           OR e.allocated_bound_upper*e.denominator<hi*(e.interval_to-e.interval_from))) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='当前分配界与准确的来源revision不一致';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_edge_bounds AFTER INSERT OR UPDATE ON stock_value_edges
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_edge_bounds();
ALTER TABLE stock_value_edges ENABLE ALWAYS TRIGGER trg_stock_value_edge_bounds;

-- The actual IQC item and frozen stock parts precede valuation, using a reserved
-- movement UUID. The same transaction must still finish the physical record.
DO $iqc_reference$
DECLARE constraint_name TEXT; definition TEXT; pattern TEXT;
BEGIN
    IF to_regclass('public.procurement_iqc_stock_in_batch_items') IS NOT NULL THEN
        SELECT c.conname INTO STRICT constraint_name FROM pg_constraint c
        WHERE c.contype='f' AND c.conrelid='procurement_iqc_stock_in_batch_items'::regclass
          AND c.confrelid='stock_movements'::regclass
          AND c.conkey=ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid='procurement_iqc_stock_in_batch_items'::regclass AND attname='stock_movement_id')]::smallint[];
        EXECUTE format('ALTER TABLE procurement_iqc_stock_in_batch_items ALTER CONSTRAINT %I DEFERRABLE INITIALLY DEFERRED',constraint_name);
        SELECT pg_get_functiondef('fn_validate_procurement_iqc_stock_in_item()'::regprocedure) INTO definition;
        pattern:='OR[[:space:]]+COALESCE\(v_movement\.amount_local, 0\)[[:space:]]+IS DISTINCT FROM NEW\.amount_local';
        IF regexp_count(definition,pattern)<>1 THEN RAISE EXCEPTION 'V509 expected the exact legacy IQC movement/nominal-amount comparison'; END IF;
        definition:=regexp_replace(definition,pattern,
            'OR NOT EXISTS(SELECT 1 FROM stock_value_events value_event WHERE value_event.movement_id=NEW.stock_movement_id
                AND value_event.source_item_id=NEW.id AND value_event.operation=''POSITION_STORE''
                AND value_event.known_value_local IS NOT DISTINCT FROM v_movement.amount_local)');
        EXECUTE definition;
    END IF;
END;
$iqc_reference$;
