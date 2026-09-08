-- V503 candidate: approved quantity changes keep commercial identity and exact source/peg history.
CREATE TABLE procurement_order_source_revisions (
    id UUID PRIMARY KEY REFERENCES procurement_order_qty_change_logs(id) DEFERRABLE INITIALLY DEFERRED,
    revision_sequence BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
    order_type TEXT NOT NULL CHECK(order_type IN ('PURCHASE','SUBCONTRACT')),
    order_id UUID NOT NULL,
    order_item_id UUID NOT NULL,
    old_qty NUMERIC(18,4) NOT NULL CHECK(old_qty>0),
    new_qty NUMERIC(18,4) NOT NULL CHECK(new_qty>0 AND new_qty<>old_qty),
    unit_rate NUMERIC(18,6) NOT NULL CHECK(unit_rate>0),
    before_item JSONB NOT NULL,
    approval_attempt_before INTEGER NOT NULL CHECK(approval_attempt_before>=0),
    actor_user_id UUID NOT NULL REFERENCES users(id),
    actor_employee_id UUID NOT NULL REFERENCES employees(id),
    created_txid BIGINT NOT NULL DEFAULT txid_current(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(created_txid,order_type,order_item_id)
);
CREATE INDEX idx_procurement_source_revision_order ON procurement_order_source_revisions(order_type,order_id,revision_sequence);

CREATE TABLE procurement_order_source_revision_allocations (
    revision_id UUID NOT NULL REFERENCES procurement_order_source_revisions(id),
    source_row_id UUID NOT NULL,
    source_item_id UUID NOT NULL,
    allocation_sequence BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
    line_no INTEGER NOT NULL CHECK(line_no>0),
    before_alloc_qty NUMERIC(18,4) NOT NULL CHECK(before_alloc_qty>=0),
    after_alloc_qty NUMERIC(18,4) NOT NULL CHECK(after_alloc_qty>=0),
    before_ordered_qty NUMERIC(18,4) NOT NULL CHECK(before_ordered_qty>=0),
    after_ordered_qty NUMERIC(18,4) NOT NULL CHECK(after_ordered_qty>=0),
    protected_base_qty NUMERIC(18,4) NOT NULL CHECK(protected_base_qty>=0),
    before_peg_qty_base NUMERIC(18,4) NOT NULL CHECK(before_peg_qty_base>=0),
    after_peg_qty_base NUMERIC(18,4) NOT NULL CHECK(after_peg_qty_base>=0),
    PRIMARY KEY(revision_id,source_row_id),
    UNIQUE(revision_id,source_item_id),
    CHECK(after_ordered_qty-before_ordered_qty=after_alloc_qty-before_alloc_qty)
);
CREATE INDEX idx_procurement_source_revision_allocation_source ON procurement_order_source_revision_allocations(source_item_id,allocation_sequence);

CREATE TABLE procurement_order_source_revision_peg_changes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    change_sequence BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
    revision_id UUID NOT NULL REFERENCES procurement_order_source_revisions(id),
    order_type TEXT NOT NULL CHECK(order_type IN ('PURCHASE','SUBCONTRACT')),
    transfer_id UUID NOT NULL,
    source_peg_id UUID NOT NULL REFERENCES production_material_supply_pegs(id),
    target_peg_id UUID NOT NULL REFERENCES production_material_supply_pegs(id) DEFERRABLE INITIALLY DEFERRED,
    change_kind TEXT NOT NULL CHECK(change_kind IN ('CREATE','ADJUST')),
    qty_delta_base NUMERIC(18,4) NOT NULL CHECK(qty_delta_base<>0),
    before_source_released NUMERIC(18,4) NOT NULL CHECK(before_source_released>=0),
    after_source_released NUMERIC(18,4) NOT NULL CHECK(after_source_released>=0),
    before_target_allocated NUMERIC(18,4) NOT NULL CHECK(before_target_allocated>=0),
    after_target_allocated NUMERIC(18,4) NOT NULL CHECK(after_target_allocated>0),
    before_target_released NUMERIC(18,4) NOT NULL CHECK(before_target_released>=0),
    after_target_released NUMERIC(18,4) NOT NULL CHECK(after_target_released>=0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(revision_id,order_type,transfer_id),
    CHECK(after_source_released-before_source_released=qty_delta_base),
    CHECK(after_target_allocated-before_target_allocated=GREATEST(qty_delta_base,0)),
    CHECK(after_target_released-before_target_released=GREATEST(-qty_delta_base,0)),
    CHECK(change_kind<>'CREATE' OR (qty_delta_base>0 AND before_target_allocated=0 AND before_target_released=0))
);
CREATE INDEX idx_procurement_source_revision_peg_transfer ON procurement_order_source_revision_peg_changes(order_type,transfer_id,change_sequence);

CREATE FUNCTION fn_forbid_procurement_source_revision_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='订货改量和来源份额事实只能追加，不能改写或删除'; END;
$$;
CREATE TRIGGER trg_procurement_source_revision_immutable BEFORE UPDATE OR DELETE ON procurement_order_source_revisions
    FOR EACH ROW EXECUTE FUNCTION fn_forbid_procurement_source_revision_mutation();
CREATE TRIGGER trg_procurement_source_allocation_revision_immutable BEFORE UPDATE OR DELETE ON procurement_order_source_revision_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_forbid_procurement_source_revision_mutation();
CREATE TRIGGER trg_procurement_source_peg_revision_immutable BEFORE UPDATE OR DELETE ON procurement_order_source_revision_peg_changes
    FOR EACH ROW EXECUTE FUNCTION fn_forbid_procurement_source_revision_mutation();
CREATE TRIGGER trg_procurement_qty_revision_immutable BEFORE UPDATE OR DELETE ON procurement_order_qty_change_logs
    FOR EACH ROW EXECUTE FUNCTION fn_forbid_procurement_source_revision_mutation();
CREATE TRIGGER trg_audit_procurement_order_source_revisions AFTER INSERT ON procurement_order_source_revisions
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_procurement_order_source_revision_allocations AFTER INSERT ON procurement_order_source_revision_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_procurement_order_source_revision_peg_changes AFTER INSERT ON procurement_order_source_revision_peg_changes
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- Keep exhausted anchors as history and as the only eligible sources for a later increase.
ALTER TABLE purchase_order_item_sources DROP CONSTRAINT purchase_order_item_sources_alloc_chk,
    ADD CONSTRAINT purchase_order_item_sources_alloc_chk CHECK(alloc_qty>=0);
ALTER TABLE subcontract_order_item_sources DROP CONSTRAINT subcontract_order_item_sources_alloc_chk,
    ADD CONSTRAINT subcontract_order_item_sources_alloc_chk CHECK(alloc_qty>=0);

CREATE FUNCTION fn_procurement_transfer_net_qty(p_type TEXT,p_id UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT transferred_qty FROM production_material_peg_transfers WHERE p_type='PURCHASE' AND id=p_id),
                    (SELECT transferred_qty FROM production_material_subcontract_peg_transfers WHERE p_type='SUBCONTRACT' AND id=p_id),0)
        +COALESCE((SELECT SUM(qty_delta_base) FROM procurement_order_source_revision_peg_changes
                   WHERE order_type=p_type AND transfer_id=p_id AND change_kind='ADJUST'),0)
$$;
CREATE FUNCTION fn_procurement_transfer_added_qty(p_type TEXT,p_id UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(GREATEST(qty_delta_base,0)),0) FROM procurement_order_source_revision_peg_changes
    WHERE order_type=p_type AND transfer_id=p_id AND change_kind='ADJUST'
$$;
CREATE FUNCTION fn_procurement_transfer_released_qty(p_type TEXT,p_id UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(GREATEST(-qty_delta_base,0)),0) FROM procurement_order_source_revision_peg_changes
    WHERE order_type=p_type AND transfer_id=p_id AND change_kind='ADJUST'
$$;

CREATE FUNCTION fn_prepare_procurement_source_revision() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE prefix TEXT; item JSONB; header_status SMALLINT; deleted BOOLEAN; latest_attempt INTEGER;
BEGIN
    prefix:=CASE NEW.order_type WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END;
    EXECUTE format('SELECT to_jsonb(i),h.status,h.is_deleted FROM %I i JOIN %I h ON h.id=i.order_id
        WHERE i.id=$1 AND h.id=$2 FOR UPDATE OF h,i',prefix||'_order_items',prefix||'_orders')
        INTO item,header_status,deleted USING NEW.order_item_id,NEW.order_id;
    SELECT COALESCE(MAX(attempt),0) INTO latest_attempt FROM procurement_order_approval_cases
        WHERE order_type=NEW.order_type AND order_id=NEW.order_id;
    IF item IS NULL OR header_status<>1 OR deleted OR COALESCE((item->>'is_deleted')::boolean,FALSE)
       OR NEW.created_txid<>txid_current() OR NEW.before_item IS DISTINCT FROM item
       OR NEW.old_qty IS DISTINCT FROM (item->>'qty')::numeric
       OR NEW.unit_rate IS DISTINCT FROM COALESCE((item->>'unit_rate')::numeric,1)
       OR NEW.approval_attempt_before<>latest_attempt
       OR EXISTS(SELECT 1 FROM procurement_order_approval_cases WHERE order_type=NEW.order_type
                    AND order_id=NEW.order_id AND status='PENDING') THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='仅允许按无在审任务的已批准订单原事实准备改量';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_prepare_procurement_source_revision BEFORE INSERT ON procurement_order_source_revisions
    FOR EACH ROW EXECUTE FUNCTION fn_prepare_procurement_source_revision();

CREATE FUNCTION fn_is_proven_procurement_qty_revision(p_table TEXT,p_old JSONB,p_new JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE prefix TEXT; kind TEXT; exchange NUMERIC; expected_original NUMERIC; expected_local NUMERIC;
BEGIN
    IF p_table NOT IN ('purchase_order_items','subcontract_order_items') THEN RETURN FALSE; END IF;
    prefix:=CASE p_table WHEN 'purchase_order_items' THEN 'purchase' ELSE 'subcontract' END;
    kind:=CASE prefix WHEN 'purchase' THEN 'PURCHASE' ELSE 'SUBCONTRACT' END;
    IF (p_old-ARRAY['qty','amount_original','amount_local','updated_at','updated_by'])
         IS DISTINCT FROM (p_new-ARRAY['qty','amount_original','amount_local','updated_at','updated_by']) THEN RETURN FALSE; END IF;
    IF NOT EXISTS(SELECT 1 FROM procurement_order_source_revisions r WHERE r.created_txid=txid_current()
        AND r.order_type=kind AND r.order_id=(p_old->>'order_id')::uuid AND r.order_item_id=(p_old->>'id')::uuid
        AND r.old_qty=(p_old->>'qty')::numeric AND r.new_qty=(p_new->>'qty')::numeric
        AND (r.before_item-ARRAY['updated_at','updated_by'])=(p_old-ARRAY['updated_at','updated_by'])) THEN RETURN FALSE; END IF;
    EXECUTE format('SELECT exchange_rate FROM %I WHERE id=$1 AND status=1 AND is_deleted=FALSE',prefix||'_orders')
        INTO exchange USING (p_old->>'order_id')::uuid;
    IF exchange IS NULL OR exchange<=0 THEN RETURN FALSE; END IF;
    expected_original:=round((p_new->>'qty')::numeric*(p_old->>'price')::numeric,4);
    expected_local:=round(expected_original*exchange,4);
    RETURN expected_original IS NOT NULL AND expected_original=(p_new->>'amount_original')::numeric
        AND expected_local=(p_new->>'amount_local')::numeric;
END;
$$;

CREATE FUNCTION fn_is_proven_procurement_header_revision(p_kind TEXT,p_old JSONB,p_new JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE expected_original NUMERIC; expected_local NUMERIC; prefix TEXT;
BEGIN
    IF (p_old-ARRAY['total_original','total_local','updated_at','updated_by'])
        IS DISTINCT FROM (p_new-ARRAY['total_original','total_local','updated_at','updated_by']) THEN RETURN FALSE; END IF;
    IF NOT EXISTS(SELECT 1 FROM procurement_order_source_revisions WHERE created_txid=txid_current()
        AND order_type=p_kind AND order_id=(p_old->>'id')::uuid) THEN RETURN FALSE; END IF;
    prefix:=CASE p_kind WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END;
    -- Hibernate may flush the header before its modified items; prove the prepared final amounts.
    EXECUTE format('SELECT COALESCE(SUM(CASE WHEN r.id IS NULL THEN i.amount_original ELSE round(r.new_qty*i.price,4) END),0),
        COALESCE(SUM(CASE WHEN r.id IS NULL THEN i.amount_local ELSE round(round(r.new_qty*i.price,4)*$2,4) END),0)
        FROM %I i LEFT JOIN procurement_order_source_revisions r ON r.order_item_id=i.id AND r.order_type=$3
            AND r.created_txid=txid_current() WHERE i.order_id=$1 AND i.is_deleted=FALSE',prefix||'_order_items')
        INTO expected_original,expected_local USING (p_old->>'id')::uuid,(p_old->>'exchange_rate')::numeric,p_kind;
    RETURN expected_original=(p_new->>'total_original')::numeric AND expected_local=(p_new->>'total_local')::numeric;
END;
$$;

CREATE FUNCTION fn_prepare_procurement_source_allocation() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r procurement_order_source_revisions%ROWTYPE; prefix TEXT; source_column TEXT; source_table TEXT;
    source_type TEXT; source_peg_type TEXT; transfer_table TEXT; current_alloc NUMERIC; current_ordered NUMERIC;
    source_qty NUMERIC; pending_qty NUMERIC; current_peg NUMERIC; prior_delta NUMERIC; production_source BOOLEAN; expected_peg NUMERIC;
BEGIN
    SELECT * INTO r FROM procurement_order_source_revisions WHERE id=NEW.revision_id;
    IF r.created_txid IS DISTINCT FROM txid_current() THEN RAISE EXCEPTION '来源改量准备必须处于同一事务'; END IF;
    prefix:=CASE r.order_type WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END;
    source_type:=CASE r.order_type WHEN 'PURCHASE' THEN 'request' ELSE 'application' END;
    source_column:=source_type||'_item_id'; source_table:=prefix||'_'||source_type||'_items';
    source_peg_type:=CASE r.order_type WHEN 'PURCHASE' THEN 'PURCHASE_REQUEST_ITEM' ELSE 'SUBCONTRACT_APPLICATION_ITEM' END;
    transfer_table:=CASE r.order_type WHEN 'PURCHASE' THEN 'production_material_peg_transfers' ELSE 'production_material_subcontract_peg_transfers' END;
    EXECUTE format('SELECT s.alloc_qty,i.ordered_qty,i.qty FROM %I s JOIN %I i ON i.id=s.%I
        WHERE s.id=$1 AND s.order_item_id=$2 AND i.id=$3 AND s.line_no=$4 FOR UPDATE OF s,i',
        prefix||'_order_item_sources',source_table,source_column)
        INTO current_alloc,current_ordered,source_qty USING NEW.source_row_id,r.order_item_id,NEW.source_item_id,NEW.line_no;
    SELECT COALESCE(SUM(a.after_ordered_qty-a.before_ordered_qty),0) INTO prior_delta
        FROM procurement_order_source_revision_allocations a JOIN procurement_order_source_revisions revision ON revision.id=a.revision_id
        WHERE revision.created_txid=txid_current() AND revision.order_type=r.order_type AND a.source_item_id=NEW.source_item_id;
    EXECUTE format('SELECT COALESCE(SUM(p.alloc_qty),0) FROM %I p JOIN %I i ON i.id=p.order_item_id
        JOIN %I h ON h.id=i.order_id WHERE p.%I=$1 AND h.status=0 AND h.is_deleted=FALSE AND i.is_deleted=FALSE
        AND EXISTS(SELECT 1 FROM procurement_order_approval_cases c WHERE c.order_type=$2 AND c.order_id=h.id AND c.status=''PENDING'')',
        prefix||'_order_item_sources',prefix||'_order_items',prefix||'_orders',source_column)
        INTO pending_qty USING NEW.source_item_id,r.order_type;
    EXECUTE format('SELECT COALESCE(SUM(fn_procurement_transfer_net_qty($1,t.id)),0) FROM %I t
        WHERE t.order_item_id=$2 AND t.%I=$3 AND t.status=''EFFECTIVE''',transfer_table,source_column)
        INTO current_peg USING r.order_type,r.order_item_id,NEW.source_item_id;
    SELECT EXISTS(SELECT 1 FROM production_material_supply_pegs WHERE supply_type=source_peg_type AND supply_item_id=NEW.source_item_id)
        INTO production_source;
    expected_peg:=CASE WHEN NEW.after_alloc_qty<NEW.before_alloc_qty THEN LEAST(current_peg,round(NEW.after_alloc_qty*r.unit_rate,4))
        WHEN production_source THEN current_peg+round(NEW.after_alloc_qty*r.unit_rate,4)-round(NEW.before_alloc_qty*r.unit_rate,4)
        ELSE current_peg END;
    IF current_alloc IS NULL OR current_alloc<>NEW.before_alloc_qty
       OR COALESCE(current_ordered,0)+prior_delta<>NEW.before_ordered_qty
       OR (NEW.after_alloc_qty>NEW.before_alloc_qty AND NEW.after_ordered_qty>source_qty-pending_qty)
       OR round(NEW.after_alloc_qty*r.unit_rate,4)<NEW.protected_base_qty
       OR current_peg<>NEW.before_peg_qty_base OR current_peg>round(NEW.before_alloc_qty*r.unit_rate,4)
       OR expected_peg<>NEW.after_peg_qty_base THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='订货来源份额、待订容量或原生产挂接不能证明，禁止猜测改量';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_prepare_procurement_source_allocation BEFORE INSERT ON procurement_order_source_revision_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_prepare_procurement_source_allocation();

CREATE OR REPLACE FUNCTION fn_guard_approved_order_item_source() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE kind TEXT:=CASE TG_TABLE_NAME WHEN 'purchase_order_item_sources' THEN 'PURCHASE' ELSE 'SUBCONTRACT' END;
    prefix TEXT; item_id UUID; v_order_id UUID; approved BOOLEAN;
BEGIN
    prefix:=CASE kind WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END;
    item_id:=CASE WHEN TG_OP='DELETE' THEN OLD.order_item_id ELSE NEW.order_item_id END;
    EXECUTE format('SELECT h.id,h.status<>0 FROM %I i JOIN %I h ON h.id=i.order_id WHERE i.id=$1',prefix||'_order_items',prefix||'_orders')
        INTO v_order_id,approved USING item_id;
    IF NOT COALESCE(approved,FALSE) AND NOT procurement_order_commercial_locked(kind,v_order_id) THEN
        IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;
    IF TG_OP='UPDATE' AND (to_jsonb(NEW)-'alloc_qty')=(to_jsonb(OLD)-'alloc_qty') THEN
        IF NEW.alloc_qty=OLD.alloc_qty OR EXISTS(SELECT 1 FROM procurement_order_source_revision_allocations a
            JOIN procurement_order_source_revisions r ON r.id=a.revision_id
            WHERE r.created_txid=txid_current() AND r.order_type=kind AND r.order_id=v_order_id
              AND r.order_item_id=item_id AND a.source_row_id=OLD.id AND a.before_alloc_qty=OLD.alloc_qty AND a.after_alloc_qty=NEW.alloc_qty)
            THEN RETURN NEW; END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='已送财审的订单来源只能按同事务改量事实调整份额，不能改换或删除来源';
END;
$$;

CREATE FUNCTION fn_check_procurement_source_revision() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r procurement_order_source_revisions%ROWTYPE; prefix TEXT; source_type TEXT; source_column TEXT; transfer_table TEXT;
    item JSONB; sum_before NUMERIC; sum_after NUMERIC; source_count BIGINT; recorded_count BIGINT; a RECORD;
    current_alloc NUMERIC; current_ordered NUMERIC; last_ordered NUMERIC; current_peg NUMERIC; posted_delta NUMERIC;
    header_original NUMERIC; header_local NUMERIC; item_original NUMERIC; item_local NUMERIC;
BEGIN
    SELECT * INTO r FROM procurement_order_source_revisions WHERE id=NEW.id;
    prefix:=CASE r.order_type WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END;
    source_type:=CASE r.order_type WHEN 'PURCHASE' THEN 'request' ELSE 'application' END;
    source_column:=source_type||'_item_id';
    transfer_table:=CASE r.order_type WHEN 'PURCHASE' THEN 'production_material_peg_transfers' ELSE 'production_material_subcontract_peg_transfers' END;
    EXECUTE format('SELECT to_jsonb(i) FROM %I i WHERE i.id=$1',prefix||'_order_items') INTO item USING r.order_item_id;
    IF NOT fn_is_proven_procurement_qty_revision(prefix||'_order_items',r.before_item,item)
       OR NOT EXISTS(SELECT 1 FROM procurement_order_qty_change_logs log JOIN procurement_order_approval_cases c ON c.id=log.case_id
          WHERE log.id=r.id AND log.order_type=r.order_type AND log.order_id=r.order_id AND log.order_item_id=r.order_item_id
            AND log.old_qty=r.old_qty AND log.new_qty=r.new_qty AND log.changed_by_employee_id=r.actor_employee_id
            AND c.order_type=r.order_type AND c.order_id=r.order_id AND c.status='PENDING' AND c.attempt=r.approval_attempt_before+1
            AND EXISTS(SELECT 1 FROM procurement_order_approval_events e WHERE e.case_id=c.id AND e.event_type='SUBMITTED'
                AND e.actor_user_id=r.actor_user_id AND e.actor_employee_id=r.actor_employee_id AND e.event_snapshot->>'reconfirmation'='true')) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='批准后改量必须同事务完成原数量差异账和新的财务复核，不能只解开冻结';
    END IF;
    EXECUTE format('SELECT h.total_original,h.total_local,COALESCE(SUM(i.amount_original),0),COALESCE(SUM(i.amount_local),0)
        FROM %I h JOIN %I i ON i.order_id=h.id AND i.is_deleted=FALSE WHERE h.id=$1 GROUP BY h.id',prefix||'_orders',prefix||'_order_items')
        INTO header_original,header_local,item_original,item_local USING r.order_id;
    IF header_original IS DISTINCT FROM item_original OR header_local IS DISTINCT FROM item_local THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='改后订单金额必须等于冻结单价和汇率计算的明细合计';
    END IF;
    SELECT count(*),COALESCE(SUM(before_alloc_qty),0),COALESCE(SUM(after_alloc_qty),0)
        INTO recorded_count,sum_before,sum_after FROM procurement_order_source_revision_allocations WHERE revision_id=r.id;
    EXECUTE format('SELECT count(*) FROM %I WHERE order_item_id=$1',prefix||'_order_item_sources') INTO source_count USING r.order_item_id;
    IF source_count<>recorded_count OR (recorded_count>0 AND (sum_before<>r.old_qty OR sum_after<>r.new_qty))
       OR (recorded_count=0 AND r.before_item->>source_column IS NOT NULL) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='改前改后来源份额必须逐行保留且合计等于订单数量';
    END IF;
    FOR a IN SELECT * FROM procurement_order_source_revision_allocations WHERE revision_id=r.id LOOP
        EXECUTE format('SELECT s.alloc_qty,i.ordered_qty FROM %I s JOIN %I i ON i.id=s.%I
            WHERE s.id=$1 AND s.order_item_id=$2 AND s.%I=$3 AND s.line_no=$4',prefix||'_order_item_sources',prefix||'_'||source_type||'_items',source_column,source_column)
            INTO current_alloc,current_ordered USING a.source_row_id,r.order_item_id,a.source_item_id,a.line_no;
        SELECT allocation.after_ordered_qty INTO last_ordered FROM procurement_order_source_revision_allocations allocation
            JOIN procurement_order_source_revisions revision ON revision.id=allocation.revision_id
            WHERE revision.created_txid=r.created_txid AND revision.order_type=r.order_type AND allocation.source_item_id=a.source_item_id
            ORDER BY allocation.allocation_sequence DESC LIMIT 1;
        EXECUTE format('SELECT COALESCE(SUM(fn_procurement_transfer_net_qty($1,t.id)),0) FROM %I t
            WHERE t.order_item_id=$2 AND t.%I=$3 AND t.status=''EFFECTIVE''',transfer_table,source_column)
            INTO current_peg USING r.order_type,r.order_item_id,a.source_item_id;
        EXECUTE format('SELECT COALESCE(SUM(change.qty_delta_base),0) FROM procurement_order_source_revision_peg_changes change
            JOIN %I t ON t.id=change.transfer_id WHERE change.revision_id=$1 AND change.order_type=$2 AND t.%I=$3',transfer_table,source_column)
            INTO posted_delta USING r.id,r.order_type,a.source_item_id;
        IF current_alloc IS DISTINCT FROM a.after_alloc_qty OR current_ordered IS DISTINCT FROM last_ordered
           OR current_peg<>a.after_peg_qty_base OR posted_delta<>a.after_peg_qty_base-a.before_peg_qty_base THEN
            RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='订单来源、申请已订和生产供给反向必须同事务守恒';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_procurement_source_revision_complete AFTER INSERT ON procurement_order_source_revisions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_procurement_source_revision();

CREATE FUNCTION fn_prepare_procurement_source_peg_revision() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r procurement_order_source_revisions%ROWTYPE; s production_material_supply_pegs%ROWTYPE;
    t production_material_supply_pegs%ROWTYPE; transfer_table TEXT; mapping RECORD;
BEGIN
    SELECT * INTO r FROM procurement_order_source_revisions WHERE id=NEW.revision_id;
    SELECT * INTO s FROM production_material_supply_pegs WHERE id=NEW.source_peg_id FOR UPDATE;
    SELECT * INTO t FROM production_material_supply_pegs WHERE id=NEW.target_peg_id FOR UPDATE;
    transfer_table:=CASE NEW.order_type WHEN 'PURCHASE' THEN 'production_material_peg_transfers' ELSE 'production_material_subcontract_peg_transfers' END;
    EXECUTE format('SELECT * FROM %I WHERE id=$1',transfer_table) INTO mapping USING NEW.transfer_id;
    IF r.order_type<>NEW.order_type OR r.created_txid<>txid_current() OR s.id IS NULL
       OR s.supply_type<>(CASE NEW.order_type WHEN 'PURCHASE' THEN 'PURCHASE_REQUEST_ITEM' ELSE 'SUBCONTRACT_APPLICATION_ITEM' END)
       OR s.released_qty<>NEW.before_source_released
       OR COALESCE(t.allocated_qty,0)<>NEW.before_target_allocated OR COALESCE(t.released_qty,0)<>NEW.before_target_released
       OR NOT EXISTS(SELECT 1 FROM procurement_order_source_revision_allocations a
            WHERE a.revision_id=r.id AND a.source_item_id=s.supply_item_id)
       OR (NEW.change_kind='CREATE' AND (mapping.id IS NOT NULL OR t.id IS NOT NULL))
       OR (NEW.change_kind='ADJUST' AND (mapping.id IS NULL OR mapping.from_peg_id<>s.id OR mapping.to_peg_id<>t.id
            OR mapping.order_item_id<>r.order_item_id OR mapping.status<>'EFFECTIVE')) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='生产供给调整必须先冻结原两端数量，不能事后编造变化';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_prepare_procurement_source_peg_revision BEFORE INSERT ON procurement_order_source_revision_peg_changes
    FOR EACH ROW EXECUTE FUNCTION fn_prepare_procurement_source_peg_revision();

CREATE FUNCTION fn_check_procurement_source_peg_revision() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r procurement_order_source_revisions%ROWTYPE; transfer_table TEXT; source_column TEXT; t RECORD;
    latest_source NUMERIC; latest_allocated NUMERIC; latest_released NUMERIC;
BEGIN
    SELECT * INTO r FROM procurement_order_source_revisions WHERE id=NEW.revision_id;
    transfer_table:=CASE NEW.order_type WHEN 'PURCHASE' THEN 'production_material_peg_transfers' ELSE 'production_material_subcontract_peg_transfers' END;
    source_column:=CASE NEW.order_type WHEN 'PURCHASE' THEN 'request_item_id' ELSE 'application_item_id' END;
    EXECUTE format('SELECT transfer.*,s.released_qty AS source_released,p.allocated_qty AS target_allocated,p.released_qty AS target_released
        FROM %I transfer JOIN production_material_supply_pegs s ON s.id=transfer.from_peg_id
        JOIN production_material_supply_pegs p ON p.id=transfer.to_peg_id WHERE transfer.id=$1',transfer_table)
        INTO t USING NEW.transfer_id;
    IF t.id IS NULL OR r.order_type<>NEW.order_type OR t.order_item_id<>r.order_item_id OR r.created_txid<>txid_current()
       OR t.from_peg_id<>NEW.source_peg_id OR t.to_peg_id<>NEW.target_peg_id
       OR fn_procurement_transfer_net_qty(NEW.order_type,t.id)<0 OR t.status<>'EFFECTIVE' THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='生产供给调整必须锚定本次订单的原申请迁移';
    END IF;
    -- Later changes in this transaction may share a source peg; prove its final projection against the last fact.
    EXECUTE format('SELECT c.after_source_released FROM procurement_order_source_revision_peg_changes c JOIN %I x ON x.id=c.transfer_id
        JOIN procurement_order_source_revisions revision ON revision.id=c.revision_id
        WHERE c.order_type=$1 AND x.from_peg_id=$2 AND revision.created_txid=$3 ORDER BY c.change_sequence DESC LIMIT 1',transfer_table)
        INTO latest_source USING NEW.order_type,t.from_peg_id,r.created_txid;
    SELECT c.after_target_allocated,c.after_target_released INTO latest_allocated,latest_released
        FROM procurement_order_source_revision_peg_changes c JOIN procurement_order_source_revisions revision ON revision.id=c.revision_id
        WHERE c.order_type=NEW.order_type AND c.transfer_id=NEW.transfer_id AND revision.created_txid=r.created_txid
        ORDER BY c.change_sequence DESC LIMIT 1;
    IF t.source_released<>latest_source OR t.target_allocated<>latest_allocated OR t.target_released<>latest_released THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='生产订单供给与原申请的数量调整必须两端对应';
    END IF;
    IF NEW.change_kind='CREATE' AND (t.transferred_qty<>NEW.qty_delta_base OR EXISTS(
        SELECT 1 FROM procurement_order_source_revision_peg_changes previous WHERE previous.order_type=NEW.order_type
            AND previous.transfer_id=NEW.transfer_id AND previous.id<>NEW.id AND previous.change_kind='CREATE')) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='新增迁移只能记录该原申请剩余量的一次真实转入';
    END IF;
    IF NEW.order_type='PURCHASE' THEN
        PERFORM fn_assert_purchase_transfer_row(t.id);
        PERFORM fn_assert_purchase_peg_transfer_coverage(t.from_peg_id);
        PERFORM fn_assert_purchase_peg_transfer_coverage(t.to_peg_id);
    ELSE
        PERFORM fn_assert_subcontract_transfer(t.id);
        PERFORM fn_assert_subcontract_peg_transfer_coverage(t.from_peg_id);
        PERFORM fn_assert_subcontract_peg_transfer_coverage(t.to_peg_id);
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_procurement_source_peg_revision_complete AFTER INSERT ON procurement_order_source_revision_peg_changes
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_procurement_source_peg_revision();

-- Financial/source facts cannot be rewritten by a connection switched to replica mode.
-- Keep generic audit configuration unchanged; these are the proof/identity constraints themselves.
DO $$
DECLARE guard RECORD;
BEGIN
    FOR guard IN
        SELECT relation.relname,trigger.tgname FROM pg_trigger trigger
        JOIN pg_class relation ON relation.oid=trigger.tgrelid JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
        JOIN pg_proc function ON function.oid=trigger.tgfoid
        WHERE namespace.nspname='public' AND NOT trigger.tgisinternal AND function.proname<>'fn_audit'
          AND (relation.relname IN ('procurement_order_source_revisions','procurement_order_source_revision_allocations',
                'procurement_order_source_revision_peg_changes','production_material_peg_transfers',
                'production_material_subcontract_peg_transfers','production_material_supply_pegs')
            OR function.proname IN ('fn_forbid_procurement_source_revision_mutation','fn_guard_approved_order_item_source',
                'fn_validate_order_item_source_total','fn_guard_production_order_snapshot_approval',
                'fn_guard_production_supply_source_item','fn_guard_procurement_order_item_commercial_mutation',
                'fn_guard_procurement_order_header_commercial_mutation'))
    LOOP EXECUTE format('ALTER TABLE %I ENABLE ALWAYS TRIGGER %I',guard.relname,guard.tgname); END LOOP;
END;
$$;

-- Retained guards, with precise command/partial-transfer additions.
CREATE OR REPLACE FUNCTION fn_guard_production_order_snapshot_approval()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_supply_type TEXT;
    v_constraint TEXT;
    v_upstream_item_id UUID;
    v_protected BOOLEAN;
    v_header_is_draft BOOLEAN;
    v_is_approval_lock BOOLEAN;
    v_provenance_is_exact BOOLEAN := FALSE;
BEGIN
    -- ORM full-row UPDATE mentioning unchanged snapshot columns is not a snapshot edit.
    IF ROW(NEW.goods_code_snapshot,NEW.goods_name_snapshot,NEW.goods_snapshot_source,NEW.goods_snapshot_locked_at)
       IS NOT DISTINCT FROM ROW(OLD.goods_code_snapshot,OLD.goods_name_snapshot,OLD.goods_snapshot_source,OLD.goods_snapshot_locked_at) THEN
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME = 'purchase_order_items' THEN
        v_supply_type := 'PURCHASE_ORDER_ITEM';
        v_constraint := 'production_purchase_order_item_supply_guard';
        v_upstream_item_id := OLD.request_item_id;
        PERFORM 1
        FROM purchase_orders header
        WHERE header.id = OLD.order_id
          AND header.status = 0
          AND COALESCE(header.is_deleted, FALSE) = FALSE
        FOR SHARE;
        v_header_is_draft := FOUND;

        IF NEW.goods_snapshot_source = 'REQUEST_ITEM_AT_APPROVAL' THEN
            PERFORM 1
            FROM purchase_request_items upstream
            WHERE upstream.id = NEW.request_item_id
              AND upstream.goods_id = NEW.goods_id
              AND upstream.goods_code_snapshot
                    IS NOT DISTINCT FROM NEW.goods_code_snapshot
              AND upstream.goods_name_snapshot
                    IS NOT DISTINCT FROM NEW.goods_name_snapshot
            FOR SHARE;
            v_provenance_is_exact := FOUND;
        ELSIF NEW.goods_snapshot_source = 'MASTER_AT_APPROVAL' THEN
            PERFORM 1
            FROM goods master
            WHERE master.id = NEW.goods_id
              AND master.code IS NOT DISTINCT FROM NEW.goods_code_snapshot
              AND master.name IS NOT DISTINCT FROM NEW.goods_name_snapshot
            FOR SHARE;
            v_provenance_is_exact := FOUND;
        END IF;
    ELSIF TG_TABLE_NAME = 'subcontract_order_items' THEN
        v_supply_type := 'SUBCONTRACT_ORDER_ITEM';
        v_constraint := 'production_subcontract_order_item_supply_guard';
        v_upstream_item_id := OLD.application_item_id;
        PERFORM 1
        FROM subcontract_orders header
        WHERE header.id = OLD.order_id
          AND header.status = 0
          AND COALESCE(header.is_deleted, FALSE) = FALSE
        FOR SHARE;
        v_header_is_draft := FOUND;

        IF NEW.goods_snapshot_source = 'APPLICATION_ITEM_AT_APPROVAL' THEN
            PERFORM 1
            FROM subcontract_application_items upstream
            WHERE upstream.id = NEW.application_item_id
              AND upstream.goods_id = NEW.goods_id
              AND upstream.goods_code_snapshot
                    IS NOT DISTINCT FROM NEW.goods_code_snapshot
              AND upstream.goods_name_snapshot
                    IS NOT DISTINCT FROM NEW.goods_name_snapshot
            FOR SHARE;
            v_provenance_is_exact := FOUND;
        ELSIF NEW.goods_snapshot_source = 'MASTER_AT_APPROVAL' THEN
            PERFORM 1
            FROM goods master
            WHERE master.id = NEW.goods_id
              AND master.code IS NOT DISTINCT FROM NEW.goods_code_snapshot
              AND master.name IS NOT DISTINCT FROM NEW.goods_name_snapshot
            FOR SHARE;
            v_provenance_is_exact := FOUND;
        END IF;
    ELSE
        RAISE EXCEPTION 'unsupported production order snapshot table'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_order_snapshot_table_guard';
    END IF;

    v_is_approval_lock :=
        fn_is_production_order_snapshot_approval_lock(
            TG_TABLE_NAME, to_jsonb(OLD), to_jsonb(NEW));

    -- Every first lock is an approval operation, even if the row is linked to
    -- production later in the same transaction.  Validate it while the header
    -- still exposes the update-time DRAFT state.
    IF OLD.goods_snapshot_locked_at IS NULL
       AND NEW.goods_snapshot_locked_at IS NOT NULL THEN
        IF v_is_approval_lock
           AND v_header_is_draft
           AND v_provenance_is_exact THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION
            'order goods snapshot can only be locked once during draft approval'
            USING ERRCODE = '23514', CONSTRAINT = v_constraint;
    END IF;

    v_protected := fn_has_protected_production_supply_peg(
        v_supply_type, OLD.id);
    IF NEW.id IS DISTINCT FROM OLD.id THEN
        v_protected := v_protected
            OR fn_has_protected_production_supply_peg(
                v_supply_type, NEW.id);
    END IF;
    IF OLD.order_id IS NOT NULL AND v_upstream_item_id IS NOT NULL THEN
        v_protected := v_protected
            OR fn_has_protected_preplan_order_context(
                v_supply_type, OLD.order_id, v_upstream_item_id);
    END IF;

    IF v_protected THEN
        RAISE EXCEPTION
            'production-linked supply source item cannot be changed or deleted'
            USING ERRCODE = '23514', CONSTRAINT = v_constraint;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION fn_production_supply_identity_unchanged(p_old JSONB,p_new JSONB)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
    SELECT NOT EXISTS(SELECT 1 FROM unnest(ARRAY['id','order_id','plan_id','request_item_id','application_item_id',
        'goods_id','color_id','unit_id','unit_rate','qty','is_deleted','goods_code_snapshot','goods_name_snapshot',
        'goods_snapshot_source','goods_snapshot_locked_at']) field WHERE p_old->field IS DISTINCT FROM p_new->field)
$$;

CREATE OR REPLACE FUNCTION fn_guard_production_supply_source_item()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_supply_type text;
    v_constraint text;
    v_old_order_id uuid;
    v_new_order_id uuid;
    v_old_upstream_item_id uuid;
    v_new_upstream_item_id uuid;
    v_protected boolean;
BEGIN
    IF TG_OP='UPDATE' AND (fn_production_supply_identity_unchanged(to_jsonb(OLD),to_jsonb(NEW))
       OR fn_is_proven_procurement_qty_revision(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW))) THEN RETURN NEW; END IF;
    IF TG_TABLE_NAME = 'purchase_request_items' THEN
        v_supply_type := 'PURCHASE_REQUEST_ITEM';
        v_constraint :=
            'production_purchase_request_item_supply_guard';
    ELSIF TG_TABLE_NAME = 'subcontract_application_items' THEN
        v_supply_type := 'SUBCONTRACT_APPLICATION_ITEM';
        v_constraint :=
            'production_subcontract_application_item_supply_guard';
    ELSIF TG_TABLE_NAME = 'purchase_order_items' THEN
        v_supply_type := 'PURCHASE_ORDER_ITEM';
        v_constraint :=
            'production_purchase_order_item_supply_guard';
        v_old_order_id := OLD.order_id;
        v_old_upstream_item_id := OLD.request_item_id;
        IF TG_OP = 'UPDATE' THEN
            v_new_order_id := NEW.order_id;
            v_new_upstream_item_id := NEW.request_item_id;
        END IF;
    ELSIF TG_TABLE_NAME = 'subcontract_order_items' THEN
        v_supply_type := 'SUBCONTRACT_ORDER_ITEM';
        v_constraint :=
            'production_subcontract_order_item_supply_guard';
        v_old_order_id := OLD.order_id;
        v_old_upstream_item_id := OLD.application_item_id;
        IF TG_OP = 'UPDATE' THEN
            v_new_order_id := NEW.order_id;
            v_new_upstream_item_id := NEW.application_item_id;
        END IF;
    ELSIF TG_TABLE_NAME = 'production_plan_items' THEN
        v_supply_type := 'PRODUCTION_PLAN_ITEM';
        v_constraint := 'production_plan_item_supply_guard';
    ELSE
        RAISE EXCEPTION 'unsupported production supply source table'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_supply_source_table_guard';
    END IF;

    v_protected := fn_has_protected_production_supply_peg(
        v_supply_type, OLD.id);
    IF TG_OP = 'UPDATE' THEN
        v_protected := v_protected
            OR fn_has_protected_production_supply_peg(
                v_supply_type, NEW.id);
    END IF;
    IF v_old_order_id IS NOT NULL
       AND v_old_upstream_item_id IS NOT NULL THEN
        v_protected := v_protected
            OR fn_has_protected_preplan_order_context(
                v_supply_type, v_old_order_id,
                v_old_upstream_item_id);
    END IF;
    IF TG_OP = 'UPDATE'
       AND v_new_order_id IS NOT NULL
       AND v_new_upstream_item_id IS NOT NULL THEN
        v_protected := v_protected
            OR fn_has_protected_preplan_order_context(
                v_supply_type, v_new_order_id,
                v_new_upstream_item_id);
    END IF;

    IF v_protected THEN
        IF TG_OP = 'UPDATE'
           AND fn_is_production_order_snapshot_approval_lock(
               TG_TABLE_NAME, to_jsonb(OLD), to_jsonb(NEW)) THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION
            'production-linked supply source item cannot be changed or deleted'
            USING ERRCODE = '23514',
                  CONSTRAINT = v_constraint;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_procurement_order_item_commercial_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_type TEXT:=TG_ARGV[0];
    v_order_id UUID:=CASE WHEN TG_OP='DELETE' THEN OLD.order_id ELSE NEW.order_id END;
BEGIN
    IF TG_OP='UPDATE' AND fn_is_proven_procurement_qty_revision(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW)) THEN RETURN NEW; END IF;
    IF NOT procurement_order_commercial_locked(v_type,v_order_id)
       AND (TG_OP<>'UPDATE'
            OR NOT procurement_order_commercial_locked(v_type,OLD.order_id)) THEN
        IF TG_OP='DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    IF TG_OP IN('INSERT','DELETE') THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance-reviewed procurement order items cannot be inserted or deleted',
            CONSTRAINT='procurement_order_commercial_item_freeze_guard';
    END IF;
    IF NEW.order_id IS DISTINCT FROM OLD.order_id
       OR NEW.bill_no IS DISTINCT FROM OLD.bill_no
       OR NEW.bill_date IS DISTINCT FROM OLD.bill_date
       OR NEW.line_no IS DISTINCT FROM OLD.line_no
       OR NEW.goods_id IS DISTINCT FROM OLD.goods_id
       OR NEW.color_id IS DISTINCT FROM OLD.color_id
       OR NEW.unit_id IS DISTINCT FROM OLD.unit_id
       OR NEW.unit_rate IS DISTINCT FROM OLD.unit_rate
       OR NEW.qty IS DISTINCT FROM OLD.qty
       OR NEW.price IS DISTINCT FROM OLD.price
       OR NEW.amount_original IS DISTINCT FROM OLD.amount_original
       OR NEW.amount_local IS DISTINCT FROM OLD.amount_local
       OR NEW.deliver_date IS DISTINCT FROM OLD.deliver_date
       OR NEW.weight IS DISTINCT FROM OLD.weight
       OR NEW.source_doc_no IS DISTINCT FROM OLD.source_doc_no
       OR NEW.remark IS DISTINCT FROM OLD.remark
       OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance-reviewed procurement order item commercial facts are frozen',
            CONSTRAINT='procurement_order_commercial_item_freeze_guard';
    END IF;
    IF v_type='PURCHASE'
       AND NEW.request_item_id IS DISTINCT FROM OLD.request_item_id THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance-reviewed purchase source item is frozen',
            CONSTRAINT='procurement_order_commercial_item_freeze_guard';
    END IF;
    IF v_type='SUBCONTRACT'
       AND NEW.application_item_id IS DISTINCT FROM OLD.application_item_id THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance-reviewed subcontract source item is frozen',
            CONSTRAINT='procurement_order_commercial_item_freeze_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_procurement_order_header_commercial_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_type TEXT:=TG_ARGV[0];
BEGIN
    IF fn_is_proven_procurement_header_revision(v_type,to_jsonb(OLD),to_jsonb(NEW)) THEN RETURN NEW; END IF;
    IF procurement_order_commercial_locked(v_type,OLD.id)
       AND (NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
        OR NEW.currency_id IS DISTINCT FROM OLD.currency_id
        OR NEW.exchange_rate IS DISTINCT FROM OLD.exchange_rate
        OR NEW.tax_rate IS DISTINCT FROM OLD.tax_rate
        OR NEW.settlement_method_id IS DISTINCT FROM OLD.settlement_method_id
        OR NEW.total_original IS DISTINCT FROM OLD.total_original
        OR NEW.total_local IS DISTINCT FROM OLD.total_local) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance-reviewed procurement order commercial header is frozen',
            CONSTRAINT='procurement_order_commercial_header_freeze_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_purchase_transfer_row(
    p_transfer_id UUID
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_material_peg_transfers transfer
        JOIN production_material_supply_pegs source
          ON source.id = transfer.from_peg_id
        JOIN production_material_supply_pegs target
          ON target.id = transfer.to_peg_id
        JOIN purchase_order_items order_item
          ON order_item.id = transfer.order_item_id
        WHERE transfer.id = p_transfer_id
          AND (
              source.supply_type <> 'PURCHASE_REQUEST_ITEM'
              OR source.supply_item_id <> transfer.request_item_id
              OR source.demand_id <> transfer.demand_id
              OR target.supply_type <> 'PURCHASE_ORDER_ITEM'
              OR target.supply_item_id <> transfer.order_item_id
              OR target.demand_id <> transfer.demand_id
              OR target.allocated_qty <> transfer.transferred_qty + fn_procurement_transfer_added_qty('PURCHASE',transfer.id)
              OR NOT (EXISTS(SELECT 1 FROM purchase_order_item_sources source WHERE source.order_item_id=order_item.id AND source.request_item_id=transfer.request_item_id)
                    OR (order_item.request_item_id=transfer.request_item_id
                        AND NOT EXISTS(SELECT 1 FROM purchase_order_item_sources source WHERE source.order_item_id=order_item.id)))
              OR (
                  transfer.status = 'EFFECTIVE'
                  AND target.status = 'REVERSED'
              )
              OR (
                  transfer.status = 'REVERSED'
                  AND (
                      target.status <> 'REVERSED'
                      OR target.consumed_qty <> 0
                      OR target.released_qty <> target.allocated_qty
                  )
              )
          )
    ) THEN
        RAISE EXCEPTION
            'purchase supply transfer provenance is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_purchase_transfer_provenance_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_purchase_peg_transfer_coverage(
    p_peg_id UUID
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_type       text;
    v_allocated  numeric;
    v_consumed   numeric;
    v_released   numeric;
    v_status     text;
    v_active     numeric;
    v_has_link   boolean;
BEGIN
    SELECT supply_type, allocated_qty, consumed_qty, released_qty, status
    INTO v_type, v_allocated, v_consumed, v_released, v_status
    FROM production_material_supply_pegs
    WHERE id = p_peg_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_type = 'PURCHASE_REQUEST_ITEM' THEN
        SELECT COALESCE(SUM(fn_procurement_transfer_net_qty('PURCHASE',id)), 0)
        INTO v_active
        FROM production_material_peg_transfers
        WHERE from_peg_id = p_peg_id
          AND status = 'EFFECTIVE';

        IF v_active > v_released THEN
            RAISE EXCEPTION
                'active order transfers exceed request peg release'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_purchase_transfer_source_guard';
        END IF;
        RETURN;
    END IF;

    IF v_type <> 'PURCHASE_ORDER_ITEM' THEN
        RETURN;
    END IF;

    SELECT EXISTS (
               SELECT 1
               FROM production_material_peg_transfers
               WHERE to_peg_id = p_peg_id
           ),
           COALESCE(SUM(fn_procurement_transfer_net_qty('PURCHASE',id))
               FILTER (WHERE status = 'EFFECTIVE'), 0)
    INTO v_has_link, v_active
    FROM production_material_peg_transfers
    WHERE to_peg_id = p_peg_id;

    IF NOT v_has_link THEN
        RETURN;
    END IF;

    IF v_status = 'REVERSED' THEN
        IF v_active <> 0
           OR v_consumed <> 0
           OR v_released <> v_allocated THEN
            RAISE EXCEPTION
                'reversed order peg is not fully unwound'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_purchase_transfer_target_guard';
        END IF;
    ELSIF v_active <> v_allocated - COALESCE((
        SELECT SUM(fn_procurement_transfer_released_qty('PURCHASE',id)) FROM production_material_peg_transfers
        WHERE to_peg_id=p_peg_id AND status='EFFECTIVE'),0) THEN
        RAISE EXCEPTION
            'order peg is not exactly covered by its active transfer'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_purchase_transfer_target_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_purchase_order_source_share(
    p_order_item_id UUID,
    p_request_item_id UUID,
    p_total_base NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    WITH bounds AS (
        SELECT src.request_item_id,
               src.alloc_qty * COALESCE(item.unit_rate, 1) AS alloc_base,
               COALESCE(SUM(src.alloc_qty) OVER w, 0)
                   * COALESCE(item.unit_rate, 1)
                   - src.alloc_qty * COALESCE(item.unit_rate, 1) AS prefix_base,
               ROW_NUMBER() OVER w AS rn,
               COUNT(*) OVER (PARTITION BY src.order_item_id) AS source_count
        FROM purchase_order_item_sources src
        JOIN purchase_order_items item ON item.id = src.order_item_id
        WHERE src.order_item_id = p_order_item_id AND src.alloc_qty>0
        WINDOW w AS (
            PARTITION BY src.order_item_id ORDER BY src.line_no, src.id)
    )
    SELECT COALESCE((
        SELECT CASE
            WHEN b.rn = b.source_count
                THEN GREATEST(COALESCE(p_total_base, 0) - b.prefix_base, 0)
            ELSE GREATEST(
                LEAST(b.alloc_base, COALESCE(p_total_base, 0) - b.prefix_base),
                0)
        END
        FROM bounds b
        WHERE b.request_item_id = p_request_item_id
    ), 0);
$$;

CREATE OR REPLACE FUNCTION fn_assert_subcontract_transfer(
    p_transfer_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_material_subcontract_peg_transfers transfer
        JOIN production_material_supply_pegs source
          ON source.id = transfer.from_peg_id
        JOIN production_material_supply_pegs target
          ON target.id = transfer.to_peg_id
        JOIN subcontract_order_items order_item
          ON order_item.id = transfer.order_item_id
        WHERE transfer.id = p_transfer_id
          AND (
              source.supply_type <> 'SUBCONTRACT_APPLICATION_ITEM'
              OR source.supply_item_id <> transfer.application_item_id
              OR source.demand_id <> transfer.demand_id
              OR target.supply_type <> 'SUBCONTRACT_ORDER_ITEM'
              OR target.supply_item_id <> transfer.order_item_id
              OR target.demand_id <> transfer.demand_id
              OR target.allocated_qty <> transfer.transferred_qty + fn_procurement_transfer_added_qty('SUBCONTRACT',transfer.id)
              OR NOT (EXISTS(SELECT 1 FROM subcontract_order_item_sources source WHERE source.order_item_id=order_item.id AND source.application_item_id=transfer.application_item_id)
                    OR (order_item.application_item_id=transfer.application_item_id
                        AND NOT EXISTS(SELECT 1 FROM subcontract_order_item_sources source WHERE source.order_item_id=order_item.id)))
              OR (
                  transfer.status = 'EFFECTIVE'
                  AND target.status = 'REVERSED'
              )
              OR (
                  transfer.status = 'REVERSED'
                  AND (
                      target.status <> 'REVERSED'
                      OR target.consumed_qty <> 0
                      OR target.released_qty <> target.allocated_qty
                  )
              )
          )
    ) THEN
        RAISE EXCEPTION
            'subcontract supply transfer provenance is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_subcontract_transfer_provenance_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION
    fn_assert_subcontract_peg_transfer_coverage(p_peg_id UUID)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_type       text;
    v_allocated  numeric;
    v_consumed   numeric;
    v_released   numeric;
    v_status     text;
    v_active     numeric;
    v_has_link   boolean;
BEGIN
    SELECT supply_type, allocated_qty, consumed_qty,
           released_qty, status
    INTO v_type, v_allocated, v_consumed,
         v_released, v_status
    FROM production_material_supply_pegs
    WHERE id = p_peg_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_type = 'SUBCONTRACT_APPLICATION_ITEM' THEN
        SELECT COALESCE(SUM(fn_procurement_transfer_net_qty('SUBCONTRACT',id)), 0)
        INTO v_active
        FROM production_material_subcontract_peg_transfers
        WHERE from_peg_id = p_peg_id
          AND status = 'EFFECTIVE';

        IF v_active > v_released THEN
            RAISE EXCEPTION
                'active subcontract transfers exceed application peg release'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                        'production_subcontract_transfer_source_guard';
        END IF;
        RETURN;
    END IF;

    IF v_type <> 'SUBCONTRACT_ORDER_ITEM' THEN
        RETURN;
    END IF;

    SELECT EXISTS (
               SELECT 1
               FROM production_material_subcontract_peg_transfers
               WHERE to_peg_id = p_peg_id
           ),
           COALESCE(SUM(fn_procurement_transfer_net_qty('SUBCONTRACT',id))
               FILTER (WHERE status = 'EFFECTIVE'), 0)
    INTO v_has_link, v_active
    FROM production_material_subcontract_peg_transfers
    WHERE to_peg_id = p_peg_id;

    IF NOT v_has_link THEN
        RETURN;
    END IF;

    IF v_status = 'REVERSED' THEN
        IF v_active <> 0
           OR v_consumed <> 0
           OR v_released <> v_allocated THEN
            RAISE EXCEPTION
                'reversed subcontract order peg is not fully unwound'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                        'production_subcontract_transfer_target_guard';
        END IF;
    ELSIF v_active <> v_allocated - COALESCE((
        SELECT SUM(fn_procurement_transfer_released_qty('SUBCONTRACT',id)) FROM production_material_subcontract_peg_transfers
        WHERE to_peg_id=p_peg_id AND status='EFFECTIVE'),0) THEN
        RAISE EXCEPTION
            'subcontract order peg is not exactly covered by active transfer'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                    'production_subcontract_transfer_target_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_subcontract_order_source_share(
    p_order_item_id UUID,
    p_application_item_id UUID,
    p_total_base NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    WITH bounds AS (
        SELECT src.application_item_id,
               src.alloc_qty * COALESCE(item.unit_rate, 1) AS alloc_base,
               COALESCE(SUM(src.alloc_qty) OVER w, 0)
                   * COALESCE(item.unit_rate, 1)
                   - src.alloc_qty * COALESCE(item.unit_rate, 1) AS prefix_base,
               ROW_NUMBER() OVER w AS rn,
               COUNT(*) OVER (PARTITION BY src.order_item_id) AS source_count
        FROM subcontract_order_item_sources src
        JOIN subcontract_order_items item ON item.id = src.order_item_id
        WHERE src.order_item_id = p_order_item_id AND src.alloc_qty>0
        WINDOW w AS (
            PARTITION BY src.order_item_id ORDER BY src.line_no, src.id)
    )
    SELECT COALESCE((
        SELECT CASE
            WHEN b.rn = b.source_count
                THEN GREATEST(COALESCE(p_total_base, 0) - b.prefix_base, 0)
            ELSE GREATEST(
                LEAST(b.alloc_base, COALESCE(p_total_base, 0) - b.prefix_base),
                0)
        END
        FROM bounds b
        WHERE b.application_item_id = p_application_item_id
    ), 0);
$$;

CREATE OR REPLACE VIEW v_preplan_buy_action_slice_progress AS
WITH slice_items AS (
    SELECT DISTINCT action.id AS action_id,
           'DEMAND'::TEXT AS slice_type,
           allocation.external_item_id AS request_item_id
    FROM preplan_supply_actions action
    JOIN preplan_supply_action_allocations allocation
      ON allocation.action_id = action.id
     AND allocation.external_item_id IS NOT NULL
    WHERE action.route = 'BUY'
    UNION ALL
    SELECT action.id, 'SAFETY', action.safety_external_item_id
    FROM preplan_supply_actions action
    WHERE action.route = 'BUY'
      AND action.safety_external_item_id IS NOT NULL
), request_progress AS (
    SELECT slice.action_id, slice.slice_type,
           COUNT(*)::BIGINT AS item_count,
           BOOL_AND(
               item.is_deleted = FALSE
               AND request.id IS NOT NULL
               AND request.is_deleted = FALSE
               AND request.status IN (0,1)
               AND COALESCE(request.is_stopped,FALSE) = FALSE
               AND request.id = action.external_document_id
           ) AS source_valid,
           SUM(GREATEST(
               COALESCE(item.qty,0) - COALESCE(item.ordered_qty,0), 0
           ) * COALESCE(item.unit_rate,1))::numeric AS unordered_qty
    FROM slice_items slice
    JOIN preplan_supply_actions action ON action.id = slice.action_id
    LEFT JOIN purchase_request_items item
      ON item.id = slice.request_item_id
    LEFT JOIN purchase_requests request
      ON request.id = item.request_id
    GROUP BY slice.action_id, slice.slice_type
), item_receipts AS (
    -- 每条已生效订货行的到货事实（与 V446 receipt_by_order_item 同一 CASE
    -- 口径，先按订货行汇总，供来源 FIFO 分摊）。V466：新增已退回不合格量
    -- （实物退回登记后原订单重新欠货，计入在途）。
    SELECT order_item.id AS order_item_id,
           COALESCE(SUM(CASE
               WHEN receipt.id IS NULL THEN 0
               WHEN inspection.id IS NULL
               THEN receipt_item.qty * COALESCE(receipt_item.unit_rate,1)
               WHEN inspection.status = 'REVERSED' THEN 0
               ELSE inspection.warehouse_stocked_base_qty
           END),0)::numeric AS passed_qty,
           COALESCE(SUM(CASE
               WHEN inspection.id IS NULL OR inspection.status = 'REVERSED'
               THEN 0 ELSE inspection.failed_base_qty
           END),0)::numeric AS failed_qty,
           COALESCE(SUM(CASE
               WHEN inspection.id IS NULL OR inspection.status = 'REVERSED'
               THEN 0
               ELSE GREATEST(
                   inspection.received_base_qty
                       - inspection.failed_base_qty
                       - inspection.warehouse_stocked_base_qty,
                   0
               )
           END),0)::numeric AS pending_qty,
           COALESCE((
               SELECT SUM(rejection.failed_base_qty)
               FROM procurement_iqc_rejection_cases rejection
               WHERE rejection.receipt_type = 'PURCHASE'
                 AND rejection.order_item_id = order_item.id
                 AND rejection.is_deleted = FALSE
                 AND rejection.return_recorded_at IS NOT NULL
                 AND rejection.status IN (
                     'RETURN_RECORDED','CREDIT_CONFIRMED',
                     'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
           ),0)::numeric AS returned_failure_base
    FROM purchase_order_items order_item
    JOIN purchase_orders purchase_order
      ON purchase_order.id = order_item.order_id
     AND purchase_order.status = 1
     AND purchase_order.is_deleted = FALSE
    LEFT JOIN purchase_receipt_items receipt_item
      ON receipt_item.order_item_id = order_item.id
     AND receipt_item.is_deleted = FALSE
    LEFT JOIN purchase_receipts receipt
      ON receipt.id = receipt_item.receipt_id
     AND receipt.status = 1
     AND receipt.is_deleted = FALSE
    LEFT JOIN procurement_inspection_items inspection
      ON receipt.id IS NOT NULL
     AND inspection.receipt_type = 'PURCHASE'
     AND inspection.receipt_item_id = receipt_item.id
    WHERE order_item.is_deleted = FALSE
    GROUP BY order_item.id
), source_slices AS (
    -- 订货行 × 来源申请行：alloc/prefix（BASE 单位）与末位标记。
    SELECT src.order_item_id,
           src.request_item_id,
           src.alloc_qty * COALESCE(order_item.unit_rate, 1) AS alloc_base,
           COALESCE(SUM(src.alloc_qty) OVER w, 0)
               * COALESCE(order_item.unit_rate, 1)
               - src.alloc_qty * COALESCE(order_item.unit_rate, 1) AS prefix_base,
           ROW_NUMBER() OVER w AS rn,
           COUNT(*) OVER (PARTITION BY src.order_item_id) AS source_count
    FROM purchase_order_item_sources src
    JOIN purchase_order_items order_item
      ON order_item.id = src.order_item_id
     AND order_item.is_deleted = FALSE
    WHERE src.alloc_qty>0
    WINDOW w AS (
        PARTITION BY src.order_item_id ORDER BY src.line_no, src.id)
), source_progress AS (
    SELECT slice.action_id, slice.slice_type,
           slice.request_item_id,
           sl.order_item_id,
           purchase_order.id IS NOT NULL AS order_exists,
           CASE WHEN sl.rn = sl.source_count
               THEN GREATEST(
                   GREATEST(
                       COALESCE(order_item.qty,0) - COALESCE(order_item.received_qty,0)
                       + COALESCE(order_item.returned_qty,0), 0)
                       * COALESCE(order_item.unit_rate,1)
                   + COALESCE(receipt.returned_failure_base,0)
                   - sl.prefix_base, 0)
               ELSE GREATEST(LEAST(
                   sl.alloc_base,
                   GREATEST(
                       COALESCE(order_item.qty,0) - COALESCE(order_item.received_qty,0)
                       + COALESCE(order_item.returned_qty,0), 0)
                       * COALESCE(order_item.unit_rate,1)
                   + COALESCE(receipt.returned_failure_base,0)
                   - sl.prefix_base), 0)
           END AS open_order_qty,
           CASE WHEN sl.rn = sl.source_count
               THEN GREATEST(
                   GREATEST(COALESCE(receipt.passed_qty,0)
                       - COALESCE(order_item.returned_qty,0)
                           * COALESCE(order_item.unit_rate,1), 0)
                   - sl.prefix_base, 0)
               ELSE GREATEST(LEAST(
                   sl.alloc_base,
                   GREATEST(COALESCE(receipt.passed_qty,0)
                       - COALESCE(order_item.returned_qty,0)
                           * COALESCE(order_item.unit_rate,1), 0)
                   - sl.prefix_base), 0)
           END AS qualified_qty,
           CASE WHEN sl.rn = sl.source_count
               THEN GREATEST(COALESCE(receipt.failed_qty,0) - sl.prefix_base, 0)
               ELSE GREATEST(LEAST(
                   sl.alloc_base,
                   COALESCE(receipt.failed_qty,0) - sl.prefix_base), 0)
           END AS failed_qty,
           CASE WHEN sl.rn = sl.source_count
               THEN GREATEST(COALESCE(receipt.pending_qty,0) - sl.prefix_base, 0)
               ELSE GREATEST(LEAST(
                   sl.alloc_base,
                   COALESCE(receipt.pending_qty,0) - sl.prefix_base), 0)
           END AS pending_qty
    FROM slice_items slice
    JOIN source_slices sl
      ON sl.request_item_id = slice.request_item_id
    JOIN purchase_order_items order_item
      ON order_item.id = sl.order_item_id
    JOIN purchase_orders purchase_order
      ON purchase_order.id = order_item.order_id
     AND purchase_order.status = 1
     AND purchase_order.is_deleted = FALSE
    LEFT JOIN item_receipts receipt ON receipt.order_item_id = order_item.id
), order_progress AS (
    SELECT slice.action_id, slice.slice_type,
           BOOL_OR(sp.order_exists) AS order_exists,
           COALESCE(SUM(sp.open_order_qty),0)::numeric AS open_order_qty,
           COALESCE(SUM(sp.qualified_qty),0)::numeric AS qualified_qty,
           COALESCE(SUM(sp.failed_qty),0)::numeric AS failed_qty,
           COALESCE(SUM(sp.pending_qty),0)::numeric AS pending_qty
    FROM slice_items slice
    LEFT JOIN source_progress sp
      ON sp.action_id = slice.action_id
     AND sp.slice_type = slice.slice_type
     AND sp.request_item_id = slice.request_item_id
    GROUP BY slice.action_id, slice.slice_type
), kind_progress AS (
    SELECT request.action_id, request.slice_type,
           request.item_count, request.source_valid,
           COALESCE(request.unordered_qty,0) AS unordered_qty,
           COALESCE(orders.order_exists,FALSE) AS order_exists,
           COALESCE(orders.open_order_qty,0) AS open_order_qty,
           COALESCE(orders.qualified_qty,0) AS qualified_qty,
           COALESCE(orders.failed_qty,0) AS failed_qty,
           COALESCE(orders.pending_qty,0) AS pending_qty
    FROM request_progress request
    LEFT JOIN order_progress orders
      ON orders.action_id = request.action_id
     AND orders.slice_type = request.slice_type
)
SELECT action.id AS action_id,
       action.requested_qty AS demand_requested_qty,
       action.safety_replenishment_qty AS safety_requested_qty,
       (action.requested_qty = 0 OR COALESCE(demand.item_count,0) > 0
          AND COALESCE(demand.source_valid,FALSE)) AS demand_source_valid,
       (action.safety_replenishment_qty = 0 OR COALESCE(safety.item_count,0) > 0
          AND COALESCE(safety.source_valid,FALSE)) AS safety_source_valid,
       COALESCE(demand.qualified_qty,0) AS demand_qualified_qty,
       COALESCE(safety.qualified_qty,0) AS safety_qualified_qty,
       COALESCE(demand.failed_qty,0) AS demand_failed_qty,
       COALESCE(safety.failed_qty,0) AS safety_failed_qty,
       COALESCE(demand.unordered_qty,0)
          + COALESCE(demand.open_order_qty,0)
          + COALESCE(demand.pending_qty,0) AS demand_future_qty,
       COALESCE(safety.unordered_qty,0)
          + COALESCE(safety.open_order_qty,0)
          + COALESCE(safety.pending_qty,0) AS safety_future_qty,
       COALESCE(demand.pending_qty,0) AS demand_pending_qty,
       COALESCE(safety.pending_qty,0) AS safety_pending_qty,
       COALESCE(demand.order_exists,FALSE) AS demand_order_exists,
       COALESCE(safety.order_exists,FALSE) AS safety_order_exists
FROM preplan_supply_actions action
LEFT JOIN kind_progress demand
  ON demand.action_id = action.id AND demand.slice_type = 'DEMAND'
LEFT JOIN kind_progress safety
  ON safety.action_id = action.id AND safety.slice_type = 'SAFETY'
WHERE action.route = 'BUY';
