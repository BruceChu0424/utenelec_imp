-- V500: actual moving-average value core. No historical qty/amount/GL rewrite.
CREATE TABLE stock_value_pools (
    id UUID PRIMARY KEY,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    goods_id UUID NOT NULL REFERENCES goods(id),
    color_id UUID REFERENCES colors(id),
    state TEXT NOT NULL CHECK (state IN ('ACTIVE','LEGACY_UNVERIFIED')),
    head_node_id UUID,
    legacy_balance_id UUID,
    legacy_qty NUMERIC(18,4),
    legacy_amount_local NUMERIC(18,4),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE NULLS NOT DISTINCT (warehouse_id, goods_id, color_id),
    CHECK (state <> 'LEGACY_UNVERIFIED' OR head_node_id IS NULL)
);

CREATE TABLE stock_value_events (
    id UUID PRIMARY KEY,
    operation TEXT NOT NULL CHECK (operation IN ('RECEIVE','ISSUE','RETURN_ISSUE','COST_ADJUST','COST_ADJUST_REVERSE')),
    source_event_id UUID NOT NULL,
    source_doc_type VARCHAR(80) NOT NULL,
    source_doc_id UUID NOT NULL,
    source_item_id UUID NOT NULL,
    source_version BIGINT NOT NULL CHECK (source_version >= 0),
    actor_user_id UUID NOT NULL REFERENCES users(id),
    actor_employee_id UUID NOT NULL REFERENCES employees(id),
    occurred_at TIMESTAMPTZ NOT NULL,
    idempotency_key VARCHAR(160) NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 160),
    request_hash CHAR(64) NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    request_payload JSONB NOT NULL,
    pool_id UUID NOT NULL REFERENCES stock_value_pools(id),
    movement_id UUID REFERENCES stock_movements(id) DEFERRABLE INITIALLY DEFERRED,
    qty_base NUMERIC(18,4),
    qty_before NUMERIC(18,4),
    known_value_local NUMERIC(18,4) NOT NULL,
    result_node_id UUID NOT NULL,
    result_head_id UUID,
    result_state TEXT NOT NULL CHECK (result_state IN ('FINAL','PENDING')),
    source_node_id UUID,
    result_source_revision BIGINT,
    previous_adjustment_id UUID REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    reversal_of_event_id UUID UNIQUE REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    before_source_final BOOLEAN,
    after_source_final BOOLEAN,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (operation, source_event_id, source_item_id),
    UNIQUE (operation, source_item_id, idempotency_key),
    CHECK ((operation IN ('RECEIVE','ISSUE','RETURN_ISSUE') AND movement_id IS NOT NULL
            AND qty_base > 0 AND qty_before >= 0 AND known_value_local >= 0)
        OR (operation IN ('COST_ADJUST','COST_ADJUST_REVERSE') AND movement_id IS NULL
            AND source_node_id IS NOT NULL AND result_source_revision > 1)),
    CHECK ((operation='COST_ADJUST_REVERSE') = (reversal_of_event_id IS NOT NULL))
);
CREATE UNIQUE INDEX uq_stock_value_event_movement ON stock_value_events(movement_id) WHERE movement_id IS NOT NULL;

CREATE TABLE stock_value_nodes (
    id UUID PRIMARY KEY,
    pool_id UUID NOT NULL REFERENCES stock_value_pools(id),
    kind TEXT NOT NULL CHECK (kind IN ('SOURCE','POOL','ISSUE_POSITION','RETURN_SOURCE')),
    owner_kind TEXT CHECK (owner_kind IN ('COGS','WIP','SUBCONTRACT_WIP','LOSS','IN_TRANSIT','EXTERNAL')),
    owner_id UUID,
    movement_id UUID UNIQUE REFERENCES stock_movements(id) DEFERRABLE INITIALLY DEFERRED,
    root_issue_id UUID REFERENCES stock_value_nodes(id) DEFERRABLE INITIALLY DEFERRED,
    quantity_basis NUMERIC(18,4) NOT NULL CHECK (quantity_basis >= 0),
    range_from NUMERIC(18,4) NOT NULL CHECK (range_from >= 0),
    range_to NUMERIC(18,4) NOT NULL CHECK (range_to >= range_from),
    initial_known_value NUMERIC(18,4) NOT NULL CHECK (initial_known_value >= 0),
    initial_pending INTEGER NOT NULL CHECK (initial_pending >= 0),
    creation_event_id UUID NOT NULL REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    node_sequence BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
    basis_value_local NUMERIC(18,4) NOT NULL CHECK (basis_value_local >= 0),
    pending_parents INTEGER NOT NULL CHECK (pending_parents >= 0),
    revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
    active BOOLEAN NOT NULL,
    source_final BOOLEAN NOT NULL,
    return_head_id UUID REFERENCES stock_value_nodes(id) DEFERRABLE INITIALLY DEFERRED,
    adjustment_head_id UUID REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    owned_value_local NUMERIC(18,4) GENERATED ALWAYS AS (
        CASE WHEN active AND kind='POOL' THEN basis_value_local
             WHEN active AND kind='ISSUE_POSITION' THEN
                round(basis_value_local*range_to/quantity_basis,4)
                -round(basis_value_local*range_from/quantity_basis,4)
             ELSE 0 END) STORED,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CHECK (kind <> 'ISSUE_POSITION' OR (quantity_basis>0 AND range_to<=quantity_basis
        AND owner_kind IS NOT NULL AND owner_id IS NOT NULL AND root_issue_id IS NOT NULL)),
    CHECK (kind NOT IN ('SOURCE','RETURN_SOURCE') OR active=false),
    CHECK (kind <> 'POOL' OR quantity_basis>0 OR basis_value_local=0)
);
ALTER TABLE stock_value_pools ADD CONSTRAINT stock_value_pool_head_fk FOREIGN KEY(head_node_id)
    REFERENCES stock_value_nodes(id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE stock_value_events ADD CONSTRAINT stock_value_event_result_fk FOREIGN KEY(result_node_id)
    REFERENCES stock_value_nodes(id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE stock_value_events ADD CONSTRAINT stock_value_event_head_fk FOREIGN KEY(result_head_id)
    REFERENCES stock_value_nodes(id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE stock_value_events ADD CONSTRAINT stock_value_event_source_fk FOREIGN KEY(source_node_id)
    REFERENCES stock_value_nodes(id) DEFERRABLE INITIALLY DEFERRED;
CREATE INDEX idx_stock_value_nodes_owner ON stock_value_nodes(owner_kind, owner_id, id) WHERE active;

CREATE TABLE stock_value_edges (
    id UUID PRIMARY KEY,
    parent_node_id UUID NOT NULL REFERENCES stock_value_nodes(id),
    child_node_id UUID NOT NULL REFERENCES stock_value_nodes(id),
    interval_from NUMERIC(18,4) NOT NULL CHECK(interval_from>=0),
    interval_to NUMERIC(18,4) NOT NULL CHECK(interval_to>=interval_from),
    denominator NUMERIC(18,4) NOT NULL CHECK(denominator>0 AND interval_to<=denominator),
    creation_event_id UUID NOT NULL REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    initial_parent_revision BIGINT NOT NULL CHECK(initial_parent_revision>0),
    initial_allocated_amount NUMERIC(18,4) NOT NULL,
    last_parent_revision BIGINT NOT NULL,
    allocated_amount_local NUMERIC(18,4) NOT NULL CHECK(allocated_amount_local>=0),
    pending_contribution BOOLEAN NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(parent_node_id,child_node_id),
    CHECK(parent_node_id<>child_node_id AND last_parent_revision>=initial_parent_revision)
);
CREATE INDEX idx_stock_value_edges_parent ON stock_value_edges(parent_node_id,id);
CREATE INDEX idx_stock_value_edges_child ON stock_value_edges(child_node_id,id);

CREATE TABLE stock_value_jobs (
    event_id UUID PRIMARY KEY REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    source_node_id UUID NOT NULL REFERENCES stock_value_nodes(id),
    pending_tasks BIGINT NOT NULL CHECK(pending_tasks>=0),
    processed_tasks BIGINT NOT NULL DEFAULT 0 CHECK(processed_tasks>=0),
    clearing_remaining_local NUMERIC(18,4) NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('PENDING','APPLIED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CHECK(status<>'APPLIED' OR (pending_tasks=0 AND clearing_remaining_local=0))
);
CREATE INDEX idx_stock_value_jobs_pending ON stock_value_jobs(event_id) WHERE status='PENDING';

CREATE TABLE stock_value_tasks (
    id UUID PRIMARY KEY,
    task_sequence BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
    event_id UUID NOT NULL REFERENCES stock_value_jobs(event_id) DEFERRABLE INITIALLY DEFERRED,
    edge_id UUID NOT NULL REFERENCES stock_value_edges(id),
    parent_revision BIGINT NOT NULL CHECK(parent_revision>0),
    target_amount_local NUMERIC(18,4) NOT NULL CHECK(target_amount_local>=0),
    target_pending BOOLEAN NOT NULL,
    status TEXT NOT NULL DEFAULT 'PENDING' CHECK(status IN ('PENDING','APPLIED')),
    applied_delta_local NUMERIC(18,4),
    applied_child_revision BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(edge_id,parent_revision),
    CHECK(status<>'APPLIED' OR (applied_delta_local IS NOT NULL AND applied_child_revision IS NOT NULL))
);
CREATE INDEX idx_stock_value_tasks_pending ON stock_value_tasks(task_sequence) WHERE status='PENDING';
CREATE INDEX idx_stock_value_tasks_job ON stock_value_tasks(event_id,status);

CREATE TABLE stock_value_node_revisions (
    node_id UUID NOT NULL REFERENCES stock_value_nodes(id),
    revision BIGINT NOT NULL CHECK(revision>1),
    event_id UUID NOT NULL REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    task_id UUID UNIQUE REFERENCES stock_value_tasks(id) DEFERRABLE INITIALLY DEFERRED,
    before_value NUMERIC(18,4) NOT NULL,
    after_value NUMERIC(18,4) NOT NULL CHECK(after_value>=0),
    before_pending INTEGER NOT NULL,
    after_pending INTEGER NOT NULL CHECK(after_pending>=0),
    before_final BOOLEAN NOT NULL,
    after_final BOOLEAN NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(node_id,revision)
);

CREATE TABLE stock_value_postings (
    id UUID PRIMARY KEY,
    event_id UUID NOT NULL REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    task_id UUID REFERENCES stock_value_tasks(id) DEFERRABLE INITIALLY DEFERRED,
    node_id UUID REFERENCES stock_value_nodes(id),
    owner_kind TEXT NOT NULL CHECK(owner_kind IN ('INVENTORY','COGS','WIP','SUBCONTRACT_WIP','LOSS','IN_TRANSIT','EXTERNAL','SOURCE','CLEARING')),
    owner_id UUID NOT NULL,
    amount_delta_local NUMERIC(18,4) NOT NULL CHECK(amount_delta_local<>0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE NULLS NOT DISTINCT(event_id,task_id,node_id,owner_kind,owner_id)
);
CREATE INDEX idx_stock_value_postings_owner ON stock_value_postings(owner_kind,owner_id,event_id);
CREATE INDEX idx_stock_value_postings_task ON stock_value_postings(task_id) WHERE task_id IS NOT NULL;

CREATE FUNCTION fn_stock_value_append_only() RETURNS trigger LANGUAGE plpgsql AS $guard$
BEGIN RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='库存价值事实只允许追加；请使用原事件关联的反向或调整'; END;
$guard$;
CREATE TRIGGER trg_stock_value_events_immutable BEFORE UPDATE OR DELETE ON stock_value_events
    FOR EACH ROW EXECUTE FUNCTION fn_stock_value_append_only();
CREATE TRIGGER trg_stock_value_revisions_immutable BEFORE UPDATE OR DELETE ON stock_value_node_revisions
    FOR EACH ROW EXECUTE FUNCTION fn_stock_value_append_only();
CREATE TRIGGER trg_stock_value_postings_immutable BEFORE UPDATE OR DELETE ON stock_value_postings
    FOR EACH ROW EXECUTE FUNCTION fn_stock_value_append_only();

CREATE FUNCTION fn_guard_stock_value_projection_identity() RETURNS trigger LANGUAGE plpgsql AS $guard$
DECLARE allowed TEXT[];
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='库存价值来源和分配记录不可删除'; END IF;
    IF TG_TABLE_NAME='stock_value_nodes' THEN
        allowed:=ARRAY['basis_value_local','pending_parents','revision','active','source_final','return_head_id','adjustment_head_id','owned_value_local'];
        IF (OLD.active=false AND NEW.active=true) OR NEW.revision<OLD.revision THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='库存价值节点不可倒退或复活';
        END IF;
    ELSIF TG_TABLE_NAME='stock_value_edges' THEN
        allowed:=ARRAY['last_parent_revision','allocated_amount_local','pending_contribution'];
        IF NEW.last_parent_revision<>OLD.last_parent_revision+1 THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='库存价值分配revision必须连续';
        END IF;
    ELSIF TG_TABLE_NAME='stock_value_tasks' THEN
        allowed:=ARRAY['status','applied_delta_local','applied_child_revision'];
        IF OLD.status<>'PENDING' OR NEW.status<>'APPLIED' THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='库存价值任务只能完成一次';
        END IF;
    ELSE
        allowed:=ARRAY['head_node_id'];
        IF OLD.state='LEGACY_UNVERIFIED' THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='历史期初成本未核定，不能伪装成实际成本';
        END IF;
        IF OLD.head_node_id IS NOT NULL AND NEW.head_node_id IS NULL THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='已建立的库存价值基准不可解除';
        END IF;
    END IF;
    IF (to_jsonb(NEW)-allowed) IS DISTINCT FROM (to_jsonb(OLD)-allowed) THEN
        RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='库存价值来源、分配比例和责任快照不可改写';
    END IF;
    RETURN NEW;
END;
$guard$;
CREATE TRIGGER trg_stock_value_node_identity BEFORE UPDATE OR DELETE ON stock_value_nodes
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_value_projection_identity();
CREATE TRIGGER trg_stock_value_edge_identity BEFORE UPDATE OR DELETE ON stock_value_edges
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_value_projection_identity();
CREATE TRIGGER trg_stock_value_task_identity BEFORE UPDATE OR DELETE ON stock_value_tasks
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_value_projection_identity();
CREATE TRIGGER trg_stock_value_pool_identity BEFORE UPDATE OR DELETE ON stock_value_pools
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_value_projection_identity();

CREATE FUNCTION fn_guard_stock_value_edge_direction() RETURNS trigger LANGUAGE plpgsql AS $guard$
DECLARE parent_sequence BIGINT; child_sequence BIGINT;
BEGIN
    SELECT node_sequence INTO parent_sequence FROM stock_value_nodes WHERE id=NEW.parent_node_id FOR UPDATE;
    SELECT node_sequence INTO child_sequence FROM stock_value_nodes WHERE id=NEW.child_node_id;
    IF parent_sequence IS NULL OR child_sequence IS NULL OR parent_sequence>=child_sequence THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='库存价值分配必须指向后继节点，不能形成循环';
    END IF;
    IF (SELECT count(*) FROM stock_value_edges WHERE parent_node_id=NEW.parent_node_id)>=2 THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='库存核心每次只允许有界二分或携转';
    END IF;
    RETURN NEW;
END;
$guard$;
CREATE TRIGGER trg_stock_value_edge_direction BEFORE INSERT ON stock_value_edges
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_value_edge_direction();

CREATE FUNCTION fn_check_stock_value_node_revision() RETURNS trigger LANGUAGE plpgsql AS $guard$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM stock_value_node_revisions r WHERE r.node_id=NEW.id AND r.revision=NEW.revision
        AND r.after_value=NEW.basis_value_local AND r.after_pending=NEW.pending_parents AND r.after_final=NEW.source_final) THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='价值投影修改必须有对应追加revision事实';
    END IF;
    RETURN NULL;
END;
$guard$;
CREATE CONSTRAINT TRIGGER trg_stock_value_revision_fact AFTER UPDATE OF basis_value_local,pending_parents,revision,source_final ON stock_value_nodes
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_node_revision();

CREATE FUNCTION fn_check_stock_value_pool(p_pool_id UUID) RETURNS void LANGUAGE plpgsql AS $guard$
DECLARE p stock_value_pools%ROWTYPE; n stock_value_nodes%ROWTYPE; actual_qty NUMERIC; actual_value NUMERIC; row_count BIGINT;
BEGIN
    SELECT * INTO p FROM stock_value_pools WHERE id=p_pool_id;
    IF p.id IS NULL OR p.state='LEGACY_UNVERIFIED' OR p.head_node_id IS NULL THEN RETURN; END IF;
    SELECT * INTO n FROM stock_value_nodes WHERE id=p.head_node_id;
    SELECT count(*),sum(qty),sum(amount_local) INTO row_count,actual_qty,actual_value FROM stock_balances
        WHERE warehouse_id=p.warehouse_id AND goods_id=p.goods_id AND color_id IS NOT DISTINCT FROM p.color_id;
    IF n.id IS NULL OR n.pool_id<>p.id OR n.kind<>'POOL' OR NOT n.active OR row_count<>1
       OR actual_qty IS DISTINCT FROM n.quantity_basis OR actual_value IS DISTINCT FROM n.basis_value_local THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='物理库存与价值池必须在同一事务完成且数量/已确认金额一致';
    END IF;
END;
$guard$;

CREATE FUNCTION fn_check_stock_value_pool_head() RETURNS trigger LANGUAGE plpgsql AS $guard$
BEGIN PERFORM fn_check_stock_value_pool(NEW.id); RETURN NULL; END;
$guard$;
CREATE CONSTRAINT TRIGGER trg_stock_value_pool_head_complete AFTER INSERT OR UPDATE ON stock_value_pools
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_pool_head();

CREATE FUNCTION fn_check_stock_value_node_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $guard$
DECLARE n stock_value_nodes%ROWTYPE; remainder stock_value_nodes%ROWTYPE; outgoing BIGINT;
BEGIN
    SELECT * INTO n FROM stock_value_nodes WHERE id=NEW.id;
    SELECT count(*) INTO outgoing FROM stock_value_edges WHERE parent_node_id=n.id;
    IF (n.active AND outgoing<>0) OR (NOT n.active AND outgoing=0)
       OR (n.kind IN ('SOURCE','RETURN_SOURCE') AND outgoing<>1) THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='当前价值位置与冻结后继关系不一致';
    END IF;
    IF n.kind<>'SOURCE' AND NOT EXISTS(SELECT 1 FROM stock_value_edges WHERE child_node_id=n.id) THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='价值节点缺少确切输入来源';
    END IF;
    IF n.kind='POOL' THEN PERFORM fn_check_stock_value_pool(n.pool_id); END IF;
    IF n.kind='ISSUE_POSITION' AND n.id=n.root_issue_id THEN
        SELECT * INTO remainder FROM stock_value_nodes WHERE id=n.return_head_id;
        IF remainder.id IS NULL OR NOT remainder.active OR remainder.root_issue_id<>n.id
           OR remainder.kind<>'ISSUE_POSITION' OR remainder.quantity_basis<>n.quantity_basis
           OR remainder.range_to<>n.quantity_basis THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='原出库尚可退回位置不一致';
        END IF;
    END IF;
    RETURN NULL;
END;
$guard$;
CREATE CONSTRAINT TRIGGER trg_stock_value_node_lifecycle AFTER INSERT OR UPDATE ON stock_value_nodes
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_node_lifecycle();

CREATE FUNCTION fn_check_stock_value_event() RETURNS trigger LANGUAGE plpgsql AS $guard$
DECLARE p stock_value_pools%ROWTYPE; m stock_movements%ROWTYPE; expected_direction INTEGER;
BEGIN
    IF coalesce((SELECT sum(amount_delta_local) FROM stock_value_postings WHERE event_id=NEW.id AND task_id IS NULL),0)<>0 THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='库存价值事件两端不平';
    END IF;
    IF NEW.movement_id IS NOT NULL THEN
        SELECT * INTO p FROM stock_value_pools WHERE id=NEW.pool_id;
        SELECT * INTO m FROM stock_movements WHERE id=NEW.movement_id;
        expected_direction:=CASE WHEN NEW.operation='ISSUE' THEN -1 ELSE 1 END;
        IF m.id IS NULL OR m.goods_id<>p.goods_id OR m.warehouse_id<>p.warehouse_id
           OR m.color_id IS DISTINCT FROM p.color_id OR m.direction<>expected_direction OR m.qty<>NEW.qty_base
           OR m.source_doc_type<>NEW.source_doc_type OR m.source_doc_id IS DISTINCT FROM NEW.source_doc_id
           OR m.source_item_id IS DISTINCT FROM NEW.source_item_id
           OR m.amount_local IS DISTINCT FROM NEW.known_value_local THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='价值事件必须对应原物理库存movement UUID和精确明细';
        END IF;
    END IF;
    PERFORM fn_check_stock_value_pool(NEW.pool_id);
    RETURN NULL;
END;
$guard$;
CREATE CONSTRAINT TRIGGER trg_stock_value_event_complete AFTER INSERT ON stock_value_events
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_event();

CREATE FUNCTION fn_check_stock_value_task() RETURNS trigger LANGUAGE plpgsql AS $guard$
DECLARE p_pool UUID;
BEGIN
    IF NEW.status='APPLIED' THEN
        IF coalesce((SELECT sum(amount_delta_local) FROM stock_value_postings WHERE task_id=NEW.id),0)<>0 THEN
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='库存价值传播两端不平';
        END IF;
        SELECT n.pool_id INTO p_pool FROM stock_value_edges e JOIN stock_value_nodes n ON n.id=e.child_node_id WHERE e.id=NEW.edge_id;
        PERFORM fn_check_stock_value_pool(p_pool);
    END IF;
    RETURN NULL;
END;
$guard$;
CREATE CONSTRAINT TRIGGER trg_stock_value_task_complete AFTER UPDATE ON stock_value_tasks
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_task();

CREATE FUNCTION fn_check_managed_stock_value_balance() RETURNS trigger LANGUAGE plpgsql AS $guard$
DECLARE pool_id UUID;
BEGIN
    IF TG_OP<>'INSERT' THEN
        SELECT id INTO pool_id FROM stock_value_pools WHERE warehouse_id=OLD.warehouse_id AND goods_id=OLD.goods_id
            AND color_id IS NOT DISTINCT FROM OLD.color_id;
        PERFORM fn_check_stock_value_pool(pool_id);
    END IF;
    IF TG_OP<>'DELETE' THEN
        SELECT id INTO pool_id FROM stock_value_pools WHERE warehouse_id=NEW.warehouse_id AND goods_id=NEW.goods_id
            AND color_id IS NOT DISTINCT FROM NEW.color_id;
        PERFORM fn_check_stock_value_pool(pool_id);
    END IF;
    RETURN NULL;
END;
$guard$;
CREATE CONSTRAINT TRIGGER trg_stock_balance_managed_value AFTER INSERT OR UPDATE OR DELETE ON stock_balances
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_managed_stock_value_balance();

-- Evidence-only legacy metadata. Never adopt an old amount as approved actual cost.
INSERT INTO stock_value_pools(id,warehouse_id,goods_id,color_id,state,legacy_balance_id,legacy_qty,legacy_amount_local)
SELECT gen_random_uuid(),warehouse_id,goods_id,color_id,'LEGACY_UNVERIFIED',min(id::text)::uuid,sum(qty),sum(amount_local)
FROM stock_balances GROUP BY warehouse_id,goods_id,color_id
HAVING sum(qty)<>0 OR sum(amount_local)<>0 OR count(*) FILTER(WHERE amount_local IS NULL)>0;
