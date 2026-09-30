-- Actual valuation is an append-only authority. This migration never replaces historical vouchers.
CREATE VIEW v_stock_actual_cogs_postings AS
SELECT posting.id posting_id,posting.event_id,posting.node_id,posting.owner_id shipment_item_id,
       item.shipment_id,shipment.client_id,item.goods_id,pool.warehouse_id,pool.color_id,
       event.operation,event.source_doc_type,event.source_doc_id,event.source_item_id,
       (event.occurred_at AT TIME ZONE 'Asia/Shanghai')::date business_date,
       to_char(event.occurred_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM') source_period,
       posting.amount_delta_local amount_local,posting.created_at,
       COALESCE(revision.revision,1) value_revision,
       (node.id IS NULL OR item.id IS NULL OR shipment.id IS NULL OR node.value_model<>'EXACT_SOURCE_SHARES' OR node.pending_parents>0
         OR EXISTS(SELECT 1 FROM stock_value_jobs job WHERE job.event_id=posting.event_id AND job.status='PENDING')
         OR EXISTS(SELECT 1 FROM stock_value_tasks task WHERE task.event_id=posting.event_id AND task.status='PENDING')) pending
FROM stock_value_postings posting
JOIN stock_value_events event ON event.id=posting.event_id
LEFT JOIN stock_value_nodes node ON node.id=posting.node_id
LEFT JOIN stock_value_node_revisions revision ON revision.node_id=posting.node_id
  AND revision.event_id=posting.event_id AND revision.task_id IS NOT DISTINCT FROM posting.task_id
LEFT JOIN stock_value_pools pool ON pool.id=node.pool_id
LEFT JOIN sales_shipment_items item ON item.id=posting.owner_id
LEFT JOIN sales_shipments shipment ON shipment.id=item.shipment_id
WHERE posting.owner_kind='COGS';

CREATE VIEW v_stock_actual_sales_cost_coverage AS
SELECT item.id shipment_item_id,item.shipment_id,shipment.client_id,item.goods_id,
       shipment.bill_date business_date,
       NOT EXISTS(SELECT 1 FROM stock_movements movement
                  JOIN stock_value_events event ON event.movement_id=movement.id
                  JOIN stock_value_nodes node ON node.id=event.result_node_id
                  WHERE movement.source_item_id=item.id AND movement.source_doc_type='SALES_SHIPMENT'
                    AND movement.direction=-1 AND node.owner_kind='COGS'
                    AND node.value_model='EXACT_SOURCE_SHARES' AND node.pending_parents=0) pending
FROM sales_shipment_items item JOIN sales_shipments shipment ON shipment.id=item.shipment_id
WHERE NOT item.is_deleted AND NOT shipment.is_deleted AND shipment.status=1
UNION ALL
SELECT item.id,item.shipment_id,shipment.client_id,item.goods_id,
       (event.occurred_at AT TIME ZONE 'Asia/Shanghai')::date,
       (node.value_model<>'EXACT_SOURCE_SHARES' OR node.pending_parents>0)
FROM stock_value_position_transfers transfer
JOIN stock_value_events event ON event.id=transfer.event_id
JOIN stock_value_nodes node ON (node.id=transfer.source_root_id OR node.id=transfer.target_node_id) AND node.owner_kind='COGS'
JOIN sales_shipment_items item ON item.id=node.owner_id
JOIN sales_shipments shipment ON shipment.id=item.shipment_id;

CREATE VIEW v_stock_actual_finished_receipts AS
SELECT movement.id movement_id,movement.goods_id,movement.warehouse_id,movement.color_id,
       (movement.transaction_date AT TIME ZONE 'Asia/Shanghai')::date business_date,
       output.execution_segment_id cost_object_id,output.withdrawn_movement_id,
       CASE WHEN output.withdrawn_movement_id IS NOT NULL THEN 0 ELSE movement.qty END effective_qty,
       CASE WHEN output.withdrawn_movement_id IS NOT NULL THEN 0
            WHEN node.value_model='EXACT_SOURCE_SHARES' THEN node.basis_value_local ELSE NULL END known_amount_local,
       (output.source_node_id IS NULL OR node.value_model<>'EXACT_SOURCE_SHARES' OR node.pending_parents>0
         OR object.state<>'FINAL' OR object.business_refresh_pending
         OR EXISTS(SELECT 1 FROM stock_value_production_cost_dirty dirty
                   WHERE dirty.execution_segment_id=object.execution_segment_id AND dirty.observed_revision>dirty.cleared_revision)
         OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks task
                   WHERE task.execution_segment_id=object.execution_segment_id AND task.status='PENDING')) pending
FROM stock_movements movement
LEFT JOIN stock_value_production_cost_outputs output ON output.movement_id=movement.id
LEFT JOIN stock_value_production_cost_objects object ON object.execution_segment_id=output.execution_segment_id
LEFT JOIN stock_value_nodes node ON node.id=output.source_node_id
WHERE movement.movement_type=13 AND movement.direction=1;

CREATE TABLE inventory_cost_gl_policy (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK(singleton),
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    effective_from DATE,
    reconciliation_reference TEXT,
    version BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_by UUID REFERENCES users(id),
    CHECK(NOT enabled OR (effective_from IS NOT NULL AND length(btrim(reconciliation_reference))>=8))
);
INSERT INTO inventory_cost_gl_policy(singleton) VALUES(TRUE);

CREATE TABLE inventory_cost_gl_periods (
    period CHAR(7) PRIMARY KEY CHECK(fn_finance_period_is_valid(period::text)),
    status TEXT NOT NULL DEFAULT 'OPEN' CHECK(status IN('OPEN','CLOSED')),
    version BIGINT NOT NULL DEFAULT 0,
    close_reason TEXT,closed_at TIMESTAMPTZ,closed_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),created_by UUID REFERENCES users(id),
    CHECK(status<>'CLOSED' OR (closed_at IS NOT NULL AND closed_by IS NOT NULL AND length(btrim(close_reason))>0))
);

CREATE TABLE inventory_cost_gl_period_choices (
    posting_id UUID PRIMARY KEY REFERENCES stock_value_postings(id),
    target_period CHAR(7) NOT NULL CHECK(fn_finance_period_is_valid(target_period::text)),
    reason TEXT NOT NULL CHECK(length(btrim(reason))>=4),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),created_by UUID NOT NULL REFERENCES users(id)
);

CREATE TABLE inventory_cost_gl_links (
    posting_id UUID PRIMARY KEY REFERENCES stock_value_postings(id),
    voucher_id UUID NOT NULL UNIQUE REFERENCES gl_vouchers(id),
    source_period CHAR(7) NOT NULL,target_period CHAR(7) NOT NULL,
    source_event_id UUID NOT NULL REFERENCES stock_value_events(id),
    source_node_id UUID REFERENCES stock_value_nodes(id),
    amount_local NUMERIC NOT NULL CHECK(amount_local<>0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),created_by UUID NOT NULL REFERENCES users(id)
);
CREATE INDEX idx_inventory_cost_gl_policy_actor ON inventory_cost_gl_policy(updated_by);
CREATE INDEX idx_inventory_cost_gl_period_closed_actor ON inventory_cost_gl_periods(closed_by);
CREATE INDEX idx_inventory_cost_gl_period_created_actor ON inventory_cost_gl_periods(created_by);
CREATE INDEX idx_inventory_cost_gl_choice_actor ON inventory_cost_gl_period_choices(created_by);
CREATE INDEX idx_inventory_cost_gl_choice_period ON inventory_cost_gl_period_choices(target_period);
CREATE INDEX idx_inventory_cost_gl_link_event ON inventory_cost_gl_links(source_event_id);
CREATE INDEX idx_inventory_cost_gl_link_node ON inventory_cost_gl_links(source_node_id);
CREATE INDEX idx_inventory_cost_gl_link_actor ON inventory_cost_gl_links(created_by);
CREATE INDEX idx_inventory_cost_gl_link_period ON inventory_cost_gl_links(target_period);

CREATE VIEW v_inventory_cost_gl_status AS
SELECT cost.*,COALESCE(choice.target_period,cost.source_period)::text target_period,link.voucher_id,
       CASE WHEN link.posting_id IS NOT NULL THEN 'POSTED'
            WHEN NOT policy.enabled THEN 'DISABLED_PENDING_RECONCILIATION'
            WHEN cost.business_date<policy.effective_from
              AND (cost.created_at AT TIME ZONE 'Asia/Shanghai')::date<policy.effective_from THEN 'BEFORE_CUTOVER'
            WHEN cost.shipment_item_id IS NULL OR cost.shipment_id IS NULL THEN 'SOURCE_IDENTITY_PENDING'
            WHEN cost.pending THEN 'COST_PENDING'
            WHEN EXISTS(SELECT 1 FROM gl_vouchers legacy WHERE legacy.source='AUTO' AND legacy.source_type='COST_CARRY'
                        AND legacy.source_doc_id=cost.shipment_id AND legacy.status=1 AND NOT legacy.is_deleted)
                 THEN 'LEGACY_VOUCHER_RECONCILIATION_REQUIRED'
            WHEN EXISTS(SELECT 1 FROM inventory_cost_gl_periods period
                        WHERE period.period=COALESCE(choice.target_period,cost.source_period) AND period.status='CLOSED')
                 THEN 'TARGET_PERIOD_CLOSED'
            WHEN choice.posting_id IS NULL AND (cost.business_date<policy.effective_from
                 OR (cost.created_at AT TIME ZONE 'Asia/Shanghai')::date>=(date_trunc('month',cost.business_date)::date+interval '1 month'))
                 THEN 'TARGET_PERIOD_REQUIRED'
            ELSE 'READY' END posting_status
FROM v_stock_actual_cogs_postings cost CROSS JOIN inventory_cost_gl_policy policy
LEFT JOIN inventory_cost_gl_period_choices choice ON choice.posting_id=cost.posting_id
LEFT JOIN inventory_cost_gl_links link ON link.posting_id=cost.posting_id;

CREATE TRIGGER inventory_cost_gl_links_immutable BEFORE UPDATE OR DELETE ON inventory_cost_gl_links
FOR EACH ROW EXECUTE FUNCTION fn_stock_value_append_only();
CREATE TRIGGER inventory_cost_gl_period_choices_immutable BEFORE UPDATE OR DELETE ON inventory_cost_gl_period_choices
FOR EACH ROW EXECUTE FUNCTION fn_stock_value_append_only();

CREATE FUNCTION fn_guard_inventory_cost_gl_voucher() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE identity UUID;
BEGIN
    IF TG_TABLE_NAME='gl_vouchers' THEN identity:=OLD.id; ELSE identity:=OLD.voucher_id; END IF;
    IF EXISTS(SELECT 1 FROM inventory_cost_gl_links WHERE voucher_id=identity) THEN
        RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='实际库存成本凭证不可改写或删除；差额必须关联新价值过账';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER inventory_cost_gl_voucher_immutable BEFORE UPDATE OR DELETE ON gl_vouchers
FOR EACH ROW EXECUTE FUNCTION fn_guard_inventory_cost_gl_voucher();
CREATE TRIGGER inventory_cost_gl_entry_immutable BEFORE UPDATE OR DELETE ON gl_entries
FOR EACH ROW EXECUTE FUNCTION fn_guard_inventory_cost_gl_voucher();

CREATE FUNCTION fn_guard_inventory_cost_gl_link() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE cost RECORD; debit NUMERIC;credit NUMERIC;voucher RECORD;
BEGIN
    SELECT * INTO cost FROM v_stock_actual_cogs_postings WHERE posting_id=NEW.posting_id;
    SELECT * INTO voucher FROM gl_vouchers WHERE id=NEW.voucher_id;
    IF cost.posting_id IS NULL OR cost.pending OR cost.shipment_id IS NULL OR NEW.amount_local<>cost.amount_local
       OR NEW.source_event_id IS DISTINCT FROM cost.event_id OR NEW.source_node_id IS DISTINCT FROM cost.node_id
       OR NEW.source_period IS DISTINCT FROM cost.source_period
       OR voucher.source_type IS DISTINCT FROM 'ACTUAL_COGS' OR voucher.source_doc_id IS DISTINCT FROM NEW.posting_id
       OR voucher.period IS DISTINCT FROM NEW.target_period THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='实际库存成本过账来源、金额或凭证期间不一致';
    END IF;
    IF EXISTS(SELECT 1 FROM inventory_cost_gl_periods WHERE period=NEW.target_period AND status='CLOSED') THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='实际成本会计期间已关闭';
    END IF;
    SELECT sum(amount) FILTER(WHERE direction=1),sum(amount) FILTER(WHERE direction=-1)
      INTO debit,credit FROM gl_entries WHERE voucher_id=NEW.voucher_id AND NOT is_deleted;
    IF debit IS DISTINCT FROM NEW.amount_local OR credit IS DISTINCT FROM NEW.amount_local
       OR (SELECT count(*) FROM gl_entries WHERE voucher_id=NEW.voucher_id AND NOT is_deleted)<>2
       OR EXISTS(SELECT 1 FROM gl_entries WHERE voucher_id=NEW.voucher_id AND NOT is_deleted
                 AND style_id IS DISTINCT FROM system_posting_style_id(CASE WHEN direction=1 THEN 'SALES_COST' ELSE 'INVENTORY_ASSET' END)) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='实际成本凭证借贷与原价值变动不一致';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER inventory_cost_gl_link_guard AFTER INSERT ON inventory_cost_gl_links
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_inventory_cost_gl_link();

COMMENT ON VIEW v_stock_actual_cogs_postings IS '本币库存价值COGS实际变动；含退货、冲回、后补差额，不读货品预算';
COMMENT ON TABLE inventory_cost_gl_policy IS '切换须有新旧对账证据；默认不启用，不重写既有成本凭证';

SELECT fn_audit_track_table('inventory_cost_gl_policy','FULL','data_change',false);
SELECT fn_audit_track_table('inventory_cost_gl_periods','FULL','data_change',false);
SELECT fn_audit_track_table('inventory_cost_gl_period_choices','FULL','data_change',false);
-- Immutable link rows retain actor, exact value event and voucher identity; the value ledger is the audit authority.
SELECT fn_audit_track_table('inventory_cost_gl_links','NONE','data_change',false);

DO $cost_gl_reset$
DECLARE definition TEXT;anchor TEXT:='(''stock_value_postings'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF length(definition)-length(replace(definition,anchor,''))<>length(anchor) THEN
        RAISE EXCEPTION 'V754 business reset anchor mismatch';
    END IF;
    EXECUTE replace(definition,anchor,anchor||', (''inventory_cost_gl_policy'', ''PRESERVE''), (''inventory_cost_gl_periods'', ''CLEAR''), (''inventory_cost_gl_period_choices'', ''CLEAR''), (''inventory_cost_gl_links'', ''CLEAR'')');
END;
$cost_gl_reset$;
