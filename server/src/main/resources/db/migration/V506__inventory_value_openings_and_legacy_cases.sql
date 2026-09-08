-- V506: controlled stock value opening and isolated legacy balance cases.
-- Physical quantity, historical movements and historical GL are unchanged.
CREATE TABLE stock_value_openings (
    event_id UUID PRIMARY KEY REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    pool_id UUID NOT NULL UNIQUE REFERENCES stock_value_pools(id),
    source_node_id UUID NOT NULL UNIQUE REFERENCES stock_value_nodes(id) DEFERRABLE INITIALLY DEFERRED,
    head_node_id UUID NOT NULL REFERENCES stock_value_nodes(id) DEFERRABLE INITIALLY DEFERRED,
    stock_balance_id UUID NOT NULL REFERENCES stock_balances(id) DEFERRABLE INITIALLY DEFERRED,
    observed_qty NUMERIC(18,4) NOT NULL CHECK(observed_qty>=0),
    observed_recorded_value NUMERIC(18,4),
    before_balance JSONB NOT NULL,
    known_value_local NUMERIC(18,4) CHECK(known_value_local>=0),
    opening_mode TEXT NOT NULL CHECK(opening_mode IN ('PENDING_REVIEW','APPROVED_OPENING','EMPTY_CYCLE_START')),
    reason TEXT NOT NULL CHECK(length(btrim(reason)) BETWEEN 1 AND 1000),
    created_txid BIGINT NOT NULL DEFAULT txid_current(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CHECK(opening_mode<>'APPROVED_OPENING' OR known_value_local IS NOT NULL),
    CHECK((opening_mode='EMPTY_CYCLE_START' AND observed_qty=0 AND known_value_local=0)
        OR (opening_mode<>'EMPTY_CYCLE_START' AND observed_qty>0))
);
COMMENT ON TABLE stock_value_openings IS
    'Controlled actual-value opening: unchanged physical qty, immutable old recorded balance, never a fabricated movement or a rewrite of old GL.';
CREATE TRIGGER trg_stock_value_opening_immutable BEFORE UPDATE OR DELETE ON stock_value_openings
    FOR EACH ROW EXECUTE FUNCTION fn_stock_value_append_only();

CREATE TABLE stock_value_legacy_balance_cases (
    id UUID PRIMARY KEY,
    opening_event_id UUID NOT NULL UNIQUE REFERENCES stock_value_events(id) DEFERRABLE INITIALLY DEFERRED,
    pool_id UUID NOT NULL REFERENCES stock_value_pools(id),
    observed_recorded_value NUMERIC(18,4),
    original_balance JSONB NOT NULL,
    original_pool JSONB NOT NULL,
    opened_by_user_id UUID NOT NULL REFERENCES users(id),
    opened_by_employee_id UUID NOT NULL REFERENCES employees(id),
    state TEXT NOT NULL DEFAULT 'OPEN' CHECK(state IN ('OPEN','RESOLVED')),
    version BIGINT NOT NULL DEFAULT 1 CHECK(version>0),
    resolution_event_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CHECK((state='OPEN' AND resolution_event_id IS NULL) OR (state='RESOLVED' AND resolution_event_id IS NOT NULL))
);
CREATE INDEX idx_stock_value_legacy_balance_cases_open ON stock_value_legacy_balance_cases(pool_id,id) WHERE state='OPEN';
CREATE TABLE stock_value_legacy_balance_case_events (
    id UUID PRIMARY KEY,
    case_id UUID NOT NULL REFERENCES stock_value_legacy_balance_cases(id),
    event_type TEXT NOT NULL CHECK(event_type IN ('OPENED','NOTE','RESOLVED')),
    source_event_id UUID NOT NULL,
    source_doc_id UUID NOT NULL,
    source_item_id UUID NOT NULL,
    source_version BIGINT NOT NULL CHECK(source_version>=0),
    actor_user_id UUID NOT NULL REFERENCES users(id),
    actor_employee_id UUID NOT NULL REFERENCES employees(id),
    occurred_at TIMESTAMPTZ NOT NULL,
    idempotency_key VARCHAR(160) NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
    request_hash CHAR(64) NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),
    request_payload JSONB NOT NULL,
    note TEXT NOT NULL CHECK(length(btrim(note)) BETWEEN 1 AND 1000),
    approval_decision_id UUID,
    approval_evidence JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(event_type,source_event_id,source_item_id),
    UNIQUE(event_type,source_item_id,idempotency_key),
    CHECK((event_type='RESOLVED' AND approval_decision_id IS NOT NULL AND approval_evidence IS NOT NULL)
        OR (event_type<>'RESOLVED' AND approval_decision_id IS NULL AND approval_evidence IS NULL))
);
ALTER TABLE stock_value_legacy_balance_cases ADD CONSTRAINT stock_value_legacy_case_resolution_fk
    FOREIGN KEY(resolution_event_id) REFERENCES stock_value_legacy_balance_case_events(id) DEFERRABLE INITIALLY DEFERRED;
CREATE UNIQUE INDEX uq_stock_value_legacy_case_open_event ON stock_value_legacy_balance_case_events(case_id) WHERE event_type='OPENED';
CREATE UNIQUE INDEX uq_stock_value_legacy_case_resolved_event ON stock_value_legacy_balance_case_events(case_id) WHERE event_type='RESOLVED';
CREATE INDEX idx_stock_value_legacy_case_events_case ON stock_value_legacy_balance_case_events(case_id,created_at,id);
CREATE TRIGGER trg_stock_value_legacy_case_events_immutable BEFORE UPDATE OR DELETE ON stock_value_legacy_balance_case_events
    FOR EACH ROW EXECUTE FUNCTION fn_stock_value_append_only();

CREATE FUNCTION fn_guard_stock_value_legacy_case() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='历史余额核对证据不能删除'; END IF;
    IF (to_jsonb(NEW)-ARRAY['state','version','resolution_event_id']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['state','version','resolution_event_id'])
       OR OLD.state<>'OPEN' OR NEW.state<>'RESOLVED' OR NEW.version<>OLD.version+1
       OR NOT EXISTS(SELECT 1 FROM stock_value_legacy_balance_case_events e WHERE e.id=NEW.resolution_event_id
            AND e.case_id=OLD.id AND e.event_type='RESOLVED' AND e.approval_decision_id IS NOT NULL AND e.approval_evidence IS NOT NULL) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='旧金额和原证据不可改写，办结必须保留独立财务批准及前向处理证据';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_stock_value_legacy_case_guard BEFORE UPDATE OR DELETE ON stock_value_legacy_balance_cases
    FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_value_legacy_case();

CREATE FUNCTION fn_check_stock_value_legacy_case_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE current_case stock_value_legacy_balance_cases%ROWTYPE; proof JSONB; kind TEXT; adjustment NUMERIC;
BEGIN
    SELECT * INTO current_case FROM stock_value_legacy_balance_cases WHERE id=NEW.case_id;
    IF NEW.event_type='RESOLVED' THEN
        proof:=NEW.approval_evidence;kind:=proof->>'kind';adjustment:=(proof->>'adjustmentLocal')::numeric;
        IF current_case.state<>'RESOLVED' OR current_case.resolution_event_id<>NEW.id
           OR (proof->>'case')::uuid IS DISTINCT FROM NEW.case_id
           OR (proof->>'approvalDecision')::uuid IS DISTINCT FROM NEW.approval_decision_id
           OR COALESCE((proof->>'decisionVersion')::bigint,0)<1
           OR proof->>'approvedByUser' IS NULL OR proof->>'approvedByEmployee' IS NULL OR proof->>'approvedAt' IS NULL
           OR COALESCE(proof->>'evidenceHash','') !~ '^[0-9a-f]{64}$'
           OR kind NOT IN ('FORWARD_ADJUSTMENT','NO_ADJUSTMENT_REQUIRED') OR kind IS NULL OR adjustment IS NULL
           OR (kind='FORWARD_ADJUSTMENT' AND (adjustment=0 OR proof->>'forwardGlEvent' IS NULL))
           OR (kind='NO_ADJUSTMENT_REQUIRED' AND (adjustment<>0 OR proof->>'forwardGlEvent' IS NOT NULL)) THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='历史余额办结必须同时保存本案批准决定与对应前向处理证据';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_legacy_case_event_complete AFTER INSERT ON stock_value_legacy_balance_case_events
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_legacy_case_event();

DO $opening_shape$
DECLARE candidate RECORD; matched INTEGER:=0;
BEGIN
    FOR candidate IN SELECT conname FROM pg_constraint WHERE conrelid='stock_value_events'::regclass AND contype='c'
        AND pg_get_constraintdef(oid) LIKE '%operation%' AND pg_get_constraintdef(oid) NOT LIKE '%reversal_of_event_id%'
    LOOP
        EXECUTE format('ALTER TABLE stock_value_events DROP CONSTRAINT %I',candidate.conname);matched:=matched+1;
    END LOOP;
    IF matched<>2 THEN RAISE EXCEPTION 'V506 expected the exact V500 operation and event-shape constraints'; END IF;
END;
$opening_shape$;
ALTER TABLE stock_value_events ADD CONSTRAINT stock_value_event_operation_v506_check
    CHECK(operation IN ('RECEIVE','ISSUE','RETURN_ISSUE','COST_ADJUST','COST_ADJUST_REVERSE','OPENING','EMPTY_OPENING'));
ALTER TABLE stock_value_events ADD CONSTRAINT stock_value_event_shape_v506_check CHECK(
    (operation IN ('RECEIVE','ISSUE','RETURN_ISSUE') AND movement_id IS NOT NULL
        AND qty_base IS NOT NULL AND qty_base>0 AND qty_before IS NOT NULL AND qty_before>=0 AND known_value_local>=0)
    OR (operation IN ('COST_ADJUST','COST_ADJUST_REVERSE') AND movement_id IS NULL
        AND source_node_id IS NOT NULL AND result_source_revision IS NOT NULL AND result_source_revision>1)
    OR (operation IN ('OPENING','EMPTY_OPENING') AND movement_id IS NULL AND source_node_id IS NOT NULL
        AND result_source_revision=1 AND qty_base IS NOT NULL AND ((operation='OPENING' AND qty_base>0) OR (operation='EMPTY_OPENING' AND qty_base=0 AND known_value_local=0))
        AND qty_before IS NOT NULL AND qty_before=qty_base AND known_value_local>=0 AND after_source_final IS NOT NULL));

CREATE FUNCTION fn_prepare_stock_value_opening() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pool stock_value_pools%ROWTYPE; balance stock_balances%ROWTYPE;
BEGIN
    SELECT * INTO pool FROM stock_value_pools WHERE id=NEW.pool_id FOR UPDATE;
    SELECT * INTO balance FROM stock_balances WHERE id=NEW.stock_balance_id FOR UPDATE;
    IF pool.id IS NULL OR pool.state<>'LEGACY_UNVERIFIED' OR pool.head_node_id IS NOT NULL
       OR balance.id IS NULL OR balance.qty<>NEW.observed_qty OR balance.warehouse_id<>pool.warehouse_id
       OR balance.goods_id<>pool.goods_id OR balance.color_id IS DISTINCT FROM pool.color_id
       OR balance.amount_local IS DISTINCT FROM NEW.observed_recorded_value
       OR NEW.before_balance IS DISTINCT FROM to_jsonb(balance) OR NEW.created_txid<>txid_current() THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='开账必须先锁定并完整保留原库存数量与旧金额证据';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_prepare_stock_value_opening BEFORE INSERT ON stock_value_openings
    FOR EACH ROW EXECUTE FUNCTION fn_prepare_stock_value_opening();

CREATE OR REPLACE FUNCTION fn_guard_stock_value_projection_identity() RETURNS trigger LANGUAGE plpgsql AS $guard$
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
            IF NEW.state='ACTIVE' AND OLD.head_node_id IS NULL AND EXISTS(
                SELECT 1 FROM stock_value_openings opening JOIN stock_value_events event ON event.id=opening.event_id
                JOIN stock_balances balance ON balance.id=opening.stock_balance_id
                WHERE opening.pool_id=OLD.id AND opening.head_node_id=NEW.head_node_id AND opening.created_txid=txid_current()
                    AND event.operation IN ('OPENING','EMPTY_OPENING') AND event.pool_id=OLD.id AND event.result_head_id=NEW.head_node_id
                    AND balance.qty=opening.observed_qty AND balance.amount_local IS NOT DISTINCT FROM opening.observed_recorded_value)
                THEN allowed:=ARRAY['head_node_id','state'];
            ELSE RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='旧库存须有完整受控开账事实，不能直接解除未核定状态'; END IF;
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

CREATE FUNCTION fn_check_stock_value_opening() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE event stock_value_events%ROWTYPE; source stock_value_nodes%ROWTYPE; head stock_value_nodes%ROWTYPE;
BEGIN
    SELECT * INTO event FROM stock_value_events WHERE id=NEW.event_id;
    SELECT * INTO source FROM stock_value_nodes WHERE id=NEW.source_node_id;
    SELECT * INTO head FROM stock_value_nodes WHERE id=NEW.head_node_id;
    IF event.id IS NULL OR (NEW.opening_mode<>'EMPTY_CYCLE_START' AND (event.operation<>'OPENING' OR event.source_doc_type<>'INVENTORY_OPENING'))
       OR (NEW.opening_mode='EMPTY_CYCLE_START' AND (event.operation<>'EMPTY_OPENING' OR event.source_doc_type<>'INVENTORY_EMPTY_CYCLE'))
       OR event.pool_id<>NEW.pool_id OR event.movement_id IS NOT NULL OR event.qty_base<>NEW.observed_qty
       OR event.qty_before<>NEW.observed_qty OR event.known_value_local<>COALESCE(NEW.known_value_local,0)
       OR event.result_node_id<>NEW.source_node_id OR event.result_head_id<>NEW.head_node_id
       OR event.source_node_id<>NEW.source_node_id OR event.after_source_final<>(NEW.opening_mode<>'PENDING_REVIEW')
       OR source.id IS NULL OR source.kind<>'SOURCE' OR source.movement_id IS NOT NULL
       OR source.pool_id<>NEW.pool_id OR source.creation_event_id<>event.id OR source.quantity_basis<>NEW.observed_qty
       OR source.initial_known_value<>event.known_value_local OR source.initial_pending<>(CASE WHEN NEW.opening_mode='PENDING_REVIEW' THEN 1 ELSE 0 END)
       OR head.id IS NULL OR head.kind<>'POOL' OR head.pool_id<>NEW.pool_id OR head.quantity_basis<>NEW.observed_qty
       OR head.initial_known_value<>event.known_value_local OR head.creation_event_id<>event.id
       OR NOT EXISTS(SELECT 1 FROM stock_value_edges WHERE parent_node_id=source.id AND child_node_id=head.id
            AND interval_from=0 AND interval_to=1 AND denominator=1 AND creation_event_id=event.id) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='期初数量、成本状态和原库存来源必须完整对应，不得伪造实物流转';
    END IF;
    IF NEW.opening_mode='EMPTY_CYCLE_START' AND NOT EXISTS(SELECT 1 FROM stock_value_legacy_balance_cases c
        JOIN stock_value_legacy_balance_case_events e ON e.case_id=c.id AND e.event_type='OPENED'
        WHERE c.opening_event_id=event.id AND c.pool_id=NEW.pool_id AND c.observed_recorded_value IS NOT DISTINCT FROM NEW.observed_recorded_value
          AND c.original_balance=NEW.before_balance AND c.opened_by_user_id=event.actor_user_id AND c.opened_by_employee_id=event.actor_employee_id
          AND c.original_pool->>'state'='LEGACY_UNVERIFIED' AND (c.original_pool->>'id')::uuid=NEW.pool_id
          AND e.source_event_id=event.source_event_id AND e.source_doc_id=event.source_doc_id AND e.source_item_id=event.source_item_id
          AND e.source_version=event.source_version AND e.occurred_at=event.occurred_at
          AND e.actor_user_id=event.actor_user_id AND e.actor_employee_id=event.actor_employee_id) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='零数量旧金额必须独立立案保存，不能清零后丢失历史';
    END IF;
    -- Later physical actions may already have advanced the head in this same transaction.
    -- Opening itself proves the frozen initial head, and the existing guard proves the final physical projection.
    PERFORM fn_check_stock_value_pool(NEW.pool_id);
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_stock_value_opening_complete AFTER INSERT ON stock_value_openings
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_stock_value_opening();

-- The initial V500 proof is now enforced even in replica mode; V500 bytes stay immutable.
DO $value_guard_mode$
DECLARE guard RECORD;
BEGIN
    FOR guard IN SELECT relation.relname,trigger.tgname FROM pg_trigger trigger
        JOIN pg_class relation ON relation.oid=trigger.tgrelid JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
        JOIN pg_proc function ON function.oid=trigger.tgfoid
        WHERE namespace.nspname='public' AND NOT trigger.tgisinternal AND function.proname<>'fn_audit'
          AND (relation.relname IN ('stock_value_pools','stock_value_events','stock_value_nodes','stock_value_edges',
                    'stock_value_jobs','stock_value_tasks','stock_value_node_revisions','stock_value_postings','stock_value_openings',
                    'stock_value_legacy_balance_cases','stock_value_legacy_balance_case_events')
               OR function.proname='fn_check_managed_stock_value_balance')
    LOOP EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER %I',guard.relname,guard.tgname); END LOOP;
END;
$value_guard_mode$;

-- Runtime policy is extended here while V506 is still a forward candidate; V504 is untouched.
DO $opening_reset_policy$
DECLARE definition TEXT; needle TEXT:='(''stock_value_postings'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1
       OR position('(''stock_value_openings'',' IN definition)>0 THEN
        RAISE EXCEPTION 'V506 cannot safely register inventory opening facts in reset policy';
    END IF;
    EXECUTE replace(definition,needle,needle || E',\n            (''stock_value_openings'', ''CLEAR''),\n            (''stock_value_legacy_balance_cases'', ''CLEAR''),\n            (''stock_value_legacy_balance_case_events'', ''CLEAR'')');
END;
$opening_reset_policy$;
