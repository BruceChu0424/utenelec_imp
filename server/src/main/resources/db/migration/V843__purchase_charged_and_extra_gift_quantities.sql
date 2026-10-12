-- Forward only: existing documents retain their recorded physical facts. No posted quantity/money rewrite.
ALTER TABLE purchase_requests ADD COLUMN quantity_semantics TEXT NOT NULL DEFAULT 'LEGACY_RECORDED'
    CHECK(quantity_semantics IN ('LEGACY_RECORDED','CHARGED_PLUS_GIFT_V1'));
ALTER TABLE purchase_orders ADD COLUMN quantity_semantics TEXT NOT NULL DEFAULT 'LEGACY_RECORDED'
    CHECK(quantity_semantics IN ('LEGACY_RECORDED','CHARGED_PLUS_GIFT_V1'));
ALTER TABLE purchase_receipts ADD COLUMN quantity_semantics TEXT NOT NULL DEFAULT 'LEGACY_RECORDED'
    CHECK(quantity_semantics IN ('LEGACY_RECORDED','CHARGED_PLUS_GIFT_V1'));
ALTER TABLE purchase_returns ADD COLUMN quantity_semantics TEXT NOT NULL DEFAULT 'LEGACY_RECORDED'
    CHECK(quantity_semantics IN ('LEGACY_RECORDED','CHARGED_PLUS_GIFT_V1'));
ALTER TABLE purchase_request_items ADD COLUMN quantity_semantics TEXT NOT NULL DEFAULT 'LEGACY_RECORDED'
    CHECK(quantity_semantics IN ('LEGACY_RECORDED','CHARGED_PLUS_GIFT_V1'));
ALTER TABLE purchase_order_items ADD COLUMN quantity_semantics TEXT NOT NULL DEFAULT 'LEGACY_RECORDED'
    CHECK(quantity_semantics IN ('LEGACY_RECORDED','CHARGED_PLUS_GIFT_V1'));
ALTER TABLE purchase_receipt_items ADD COLUMN quantity_semantics TEXT NOT NULL DEFAULT 'LEGACY_RECORDED'
    CHECK(quantity_semantics IN ('LEGACY_RECORDED','CHARGED_PLUS_GIFT_V1'));
ALTER TABLE purchase_return_items ADD COLUMN quantity_semantics TEXT NOT NULL DEFAULT 'LEGACY_RECORDED'
    CHECK(quantity_semantics IN ('LEGACY_RECORDED','CHARGED_PLUS_GIFT_V1'));
ALTER TABLE purchase_request_items ADD COLUMN gift_ordered_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(gift_ordered_qty>=0);
ALTER TABLE purchase_order_items ADD COLUMN gift_received_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(gift_received_qty>=0);
ALTER TABLE purchase_order_items ADD COLUMN gift_returned_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(gift_returned_qty>=0);
ALTER TABLE purchase_receipt_items ADD COLUMN gift_returned_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(gift_returned_qty>=0);
ALTER TABLE purchase_return_items ADD COLUMN gift_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(gift_qty>=0);
ALTER TABLE purchase_receipt_items ADD COLUMN charged_base_qty NUMERIC(18,4), ADD COLUMN gift_base_qty NUMERIC(18,4);
ALTER TABLE purchase_return_items ADD COLUMN charged_base_qty NUMERIC(18,4), ADD COLUMN gift_base_qty NUMERIC(18,4);
ALTER TABLE purchase_request_items ADD CONSTRAINT purchase_request_items_gift_semantics_qty_chk CHECK(quantity_semantics='LEGACY_RECORDED' OR (qty>=0 AND gift_qty>=0 AND qty+gift_qty>0 AND qty+gift_qty<100000000000000));
ALTER TABLE purchase_order_items ADD CONSTRAINT purchase_order_items_gift_semantics_qty_chk CHECK(quantity_semantics='LEGACY_RECORDED' OR (qty>=0 AND gift_qty>=0 AND qty+gift_qty>0 AND qty+gift_qty<100000000000000));
ALTER TABLE purchase_receipt_items ADD CONSTRAINT purchase_receipt_items_gift_semantics_qty_chk CHECK(quantity_semantics='LEGACY_RECORDED' OR (qty>=0 AND gift_qty>=0 AND qty+gift_qty>0 AND qty+gift_qty<100000000000000));
ALTER TABLE purchase_return_items ADD CONSTRAINT purchase_return_items_gift_semantics_qty_chk CHECK(quantity_semantics='LEGACY_RECORDED' OR (qty>=0 AND gift_qty>=0 AND qty+gift_qty>0 AND qty+gift_qty<100000000000000));
ALTER TABLE purchase_order_item_sources ADD COLUMN allocated_gift_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK(allocated_gift_qty>=0);
ALTER TABLE procurement_inspection_items ADD COLUMN quantity_tranche TEXT NOT NULL DEFAULT 'LEGACY' CHECK(quantity_tranche IN('LEGACY','CHARGED','GIFT'));
ALTER TABLE procurement_inspection_items DROP CONSTRAINT procurement_inspection_items_item_uk;
ALTER TABLE procurement_inspection_items ADD CONSTRAINT procurement_inspection_items_item_tranche_uk UNIQUE(receipt_type,receipt_item_id,quantity_tranche);
ALTER TABLE procurement_receipt_consideration_parts ADD COLUMN quantity_tranche TEXT NOT NULL DEFAULT 'LEGACY' CHECK(quantity_tranche IN('LEGACY','CHARGED','GIFT'));
ALTER TABLE procurement_receipt_consideration_parts ADD CONSTRAINT procurement_consideration_gift_zero_chk CHECK(quantity_tranche<>'GIFT' OR (billing_mode='STANDARD' AND nominal_original=0 AND nominal_local=0 AND payable_original=0 AND payable_local=0));
COMMENT ON COLUMN purchase_receipt_items.quantity_semantics IS 'LEGACY_RECORDED preserves posted history; V1 qty is charged and gift_qty is additional free physical stock';
COMMENT ON COLUMN procurement_inspection_items.quantity_tranche IS 'Independent quality/warehouse identity for charged and free physical quantities';

-- Same serialized row-level backstops as charged quantities; no inferred historic gift stock.
CREATE TRIGGER trg_purchase_request_gift_ordered_guard BEFORE INSERT OR UPDATE OF gift_ordered_qty ON purchase_request_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity('gift_ordered_qty','gift_qty','');
CREATE TRIGGER trg_purchase_order_gift_returned_guard BEFORE INSERT OR UPDATE OF gift_returned_qty ON purchase_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_return_allowance('gift_returned_qty','gift_received_qty','');
CREATE TRIGGER trg_purchase_receipt_gift_returned_guard BEFORE INSERT OR UPDATE OF gift_returned_qty ON purchase_receipt_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_return_allowance('gift_returned_qty','gift_qty','');

CREATE OR REPLACE FUNCTION fn_assert_procurement_consideration_receipt(p_type TEXT,p_receipt UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_header RECORD;
    v_item RECORD;
    v_total RECORD;
    v_ap RECORD;
    v_table TEXT;
BEGIN
    IF p_receipt IS NULL THEN RETURN; END IF;
    IF p_type NOT IN ('PURCHASE','SUBCONTRACT') THEN
        RAISE EXCEPTION 'unknown consideration receipt type' USING ERRCODE='23514';
    END IF;
    v_table:=CASE p_type WHEN 'PURCHASE' THEN 'purchase_receipts' ELSE 'subcontract_receipts' END;
    EXECUTE format('SELECT status,is_deleted,consideration_required,supplier_id,currency_id,exchange_rate,
        settlement_method_id FROM %I WHERE id=$1 FOR UPDATE',v_table) INTO v_header USING p_receipt;
    IF v_header.status IS NULL THEN
        RAISE EXCEPTION 'consideration source receipt is missing' USING ERRCODE='23514';
    END IF;
    IF v_header.status<>1 OR v_header.is_deleted THEN
        IF EXISTS(SELECT 1 FROM procurement_receipt_consideration_parts
            WHERE receipt_type=p_type AND receipt_id=p_receipt
              AND fn_procurement_consideration_active('CONSIDERATION',id)) THEN
            RAISE EXCEPTION 'active consideration requires an approved receipt' USING ERRCODE='23514';
        END IF;
        RETURN;
    END IF;
    IF NOT v_header.consideration_required THEN RETURN; END IF;
    v_table:=CASE p_type WHEN 'PURCHASE' THEN 'purchase_receipt_items' ELSE 'subcontract_receipt_items' END;
    FOR v_item IN EXECUTE format('SELECT id,%s,amount_original,amount_local,replacement_intent
        FROM %I WHERE receipt_id=$1 AND is_deleted=FALSE ORDER BY id',
        CASE p_type WHEN 'PURCHASE' THEN
            'CASE WHEN quantity_semantics=''CHARGED_PLUS_GIFT_V1'' THEN charged_base_qty+gift_base_qty ELSE qty*unit_rate END base_qty,
             CASE WHEN quantity_semantics=''CHARGED_PLUS_GIFT_V1'' THEN charged_base_qty ELSE qty*unit_rate END amount_base_qty,
             CASE WHEN quantity_semantics=''CHARGED_PLUS_GIFT_V1'' THEN gift_base_qty ELSE 0 END gift_base_qty,quantity_semantics'
        ELSE 'qty*unit_rate base_qty,qty*unit_rate amount_base_qty,0::numeric gift_base_qty,''LEGACY_RECORDED''::text quantity_semantics' END,
        v_table) USING p_receipt
    LOOP
        SELECT COUNT(*) n,COALESCE(SUM(base_qty),0) qty,
               COALESCE(SUM(nominal_original),0) original,COALESCE(SUM(nominal_local),0) local,
               COALESCE(SUM(base_qty) FILTER(WHERE quantity_tranche='GIFT'),0) gift_qty,
               COALESCE(SUM(base_qty) FILTER(WHERE quantity_tranche='CHARGED'),0) charged_qty
        INTO v_total FROM procurement_receipt_consideration_parts
        WHERE receipt_type=p_type AND receipt_id=p_receipt AND receipt_item_id=v_item.id
          AND fn_procurement_consideration_active('CONSIDERATION',id);
        IF v_item.replacement_intent IS NULL OR v_total.n=0 OR v_total.qty<>v_item.base_qty
           OR (v_item.quantity_semantics='CHARGED_PLUS_GIFT_V1' AND
               (v_total.gift_qty<>v_item.gift_base_qty OR v_total.charged_qty<>v_item.amount_base_qty))
           OR EXISTS(SELECT 1 FROM procurement_receipt_consideration_parts part
               WHERE part.receipt_type=p_type AND part.receipt_id=p_receipt AND part.receipt_item_id=v_item.id
                 AND fn_procurement_consideration_active('CONSIDERATION',part.id)
                 AND ((part.quantity_tranche='GIFT' AND (part.nominal_original<>0 OR part.nominal_local<>0))
                      OR (part.quantity_tranche<>'GIFT' AND part.nominal_original IS NOT NULL
                       AND part.nominal_original*v_item.amount_base_qty<>v_item.amount_original*part.base_qty)
                      OR (part.quantity_tranche<>'GIFT' AND part.nominal_local IS NOT NULL
                       AND part.nominal_local*v_item.amount_base_qty<>v_item.amount_local*part.base_qty))) THEN
            RAISE EXCEPTION 'receipt consideration quantity or nominal amount is not conserved'
                USING ERRCODE='23514',CONSTRAINT='procurement_receipt_consideration_capacity';
        END IF;
        IF (v_item.replacement_intent='NORMAL')=EXISTS(
            SELECT 1 FROM procurement_receipt_consideration_parts
            WHERE receipt_type=p_type AND receipt_item_id=v_item.id AND billing_mode<>'STANDARD'
              AND fn_procurement_consideration_active('CONSIDERATION',id)) THEN
            RAISE EXCEPTION 'receipt consideration differs from its confirmed arrival intent' USING ERRCODE='23514';
        END IF;
    END LOOP;
    SELECT COALESCE(SUM(payable_original),0) original,COALESCE(SUM(payable_local),0) local
    INTO v_total FROM procurement_receipt_consideration_parts
    WHERE receipt_type=p_type AND receipt_id=p_receipt
      AND fn_procurement_consideration_active('CONSIDERATION',id);
    SELECT COUNT(*) n,COALESCE(SUM(amount_original),0) original,
           COALESCE(SUM(amount_original_local),0) local,
           COALESCE(BOOL_AND(supplier_id=v_header.supplier_id AND currency_id=v_header.currency_id
               AND exchange_rate=v_header.exchange_rate
               AND settlement_type_id IS NOT DISTINCT FROM v_header.settlement_method_id),TRUE) identity_matches
    INTO v_ap FROM ar_ap_ledger WHERE source_doc_type=p_type||'_RECEIPT' AND source_doc_id=p_receipt
        AND direction='AP' AND status=1 AND is_deleted=FALSE;
    IF v_ap.n<>(CASE WHEN v_total.original=0 AND v_total.local=0 THEN 0 ELSE 1 END)
        OR NOT v_ap.identity_matches OR (v_ap.original,v_ap.local) IS DISTINCT FROM (v_total.original,v_total.local) THEN
        RAISE EXCEPTION 'receipt payable must equal chargeable consideration only'
            USING ERRCODE='23514',CONSTRAINT='procurement_receipt_consideration_payable';
    END IF;
END;
$$;


-- Confirmed zero cost has real physical/custody evidence and no fictitious zero monetary posting.
CREATE OR REPLACE FUNCTION fn_check_stock_value_reverse_store() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE original stock_value_events%ROWTYPE;archived stock_value_nodes%ROWTYPE;removed stock_value_nodes%ROWTYPE;
    next_pool stock_value_nodes%ROWTYPE;original_head stock_value_nodes%ROWTYPE;previous_pool stock_value_nodes%ROWTYPE;
    qty NUMERIC;amount NUMERIC;parts BIGINT;
BEGIN
    IF NEW.operation<>'POSITION_STORE_REVERSE' THEN RETURN NULL; END IF;
    SELECT * INTO original FROM stock_value_events WHERE id=NEW.position_store_reversal_of;
    SELECT * INTO archived FROM stock_value_nodes WHERE id=NEW.result_node_id;
    SELECT * INTO next_pool FROM stock_value_nodes WHERE id=NEW.result_head_id;
    SELECT parent.* INTO removed FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id
        WHERE edge.child_node_id=archived.id AND edge.creation_event_id=NEW.id;
    SELECT * INTO original_head FROM stock_value_nodes WHERE id=original.result_head_id;
    SELECT parent.* INTO previous_pool FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id
        WHERE edge.child_node_id=original_head.id AND parent.kind='POOL';
    SELECT count(*),coalesce(sum(qty_base),0),coalesce(sum(initial_value_local),0) INTO parts,qty,amount
        FROM stock_value_position_transfers WHERE event_id=NEW.id AND reversal_of_transfer_id IS NOT NULL;
    IF original.id IS NULL OR archived.id IS NULL OR removed.id IS NULL OR next_pool.id IS NULL OR original_head.id IS NULL
        OR original.operation<>'POSITION_STORE' OR original.pool_id<>NEW.pool_id
        OR original.qty_base<>NEW.qty_base OR NEW.source_node_id<>original.result_node_id
        OR NOT fn_stock_value_unused_receipt_head(removed.id,original.result_head_id)
        OR archived.kind<>'REVERSED_POOL_CURSOR' OR archived.creation_event_id<>NEW.id OR archived.pool_id<>NEW.pool_id
        OR removed.kind<>'POOL' OR removed.active OR removed.quantity_basis<>NEW.qty_before
        OR next_pool.kind<>'POOL' OR next_pool.creation_event_id<>NEW.id OR next_pool.pool_id<>NEW.pool_id
        OR next_pool.quantity_basis<>NEW.qty_before-NEW.qty_base OR next_pool.quantity_basis<>coalesce(previous_pool.quantity_basis,0)
        OR next_pool.initial_known_value<>coalesce(previous_pool.basis_value_local,0)
        OR removed.basis_value_local<>next_pool.initial_known_value+NEW.known_value_local
        OR archived.initial_known_value<>removed.basis_value_local
        OR parts=0 OR parts>100 OR qty<>NEW.qty_base OR amount<>NEW.known_value_local
        OR parts<>(SELECT count(*) FROM stock_value_position_transfers WHERE event_id=original.id)
        OR EXISTS(SELECT 1 FROM stock_value_production_cost_outputs WHERE source_node_id=original.result_node_id)
        OR (NEW.known_value_local<>0 AND NOT EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=NEW.id AND node_id=removed.id
            AND owner_kind='INVENTORY' AND amount_delta_local=-NEW.known_value_local))
        OR (NEW.known_value_local=0 AND (NEW.result_state<>'FINAL' OR NOT EXISTS(SELECT 1 FROM stock_value_nodes source WHERE source.id=NEW.source_node_id AND source.source_final AND source.pending_parents=0 AND source.basis_value_local=0)
            OR EXISTS(SELECT 1 FROM stock_value_postings WHERE event_id=NEW.id AND node_id=removed.id AND owner_kind='INVENTORY')))
        OR EXISTS(SELECT 1 FROM stock_value_position_transfers transfer WHERE transfer.event_id=NEW.id AND ((transfer.initial_value_local<>0 AND NOT EXISTS(
            SELECT 1 FROM stock_value_postings posting WHERE posting.event_id=NEW.id AND posting.node_id=transfer.target_node_id
                AND posting.owner_kind='QUALITY_PASSED' AND posting.amount_delta_local=transfer.initial_value_local))
                OR (transfer.initial_value_local=0 AND EXISTS(SELECT 1 FROM stock_value_postings posting WHERE posting.event_id=NEW.id AND posting.node_id=transfer.target_node_id AND posting.owner_kind='QUALITY_PASSED')))) THEN
        RAISE EXCEPTION 'unused purchase stock withdrawal must pair the original receipt, restored custody and physical balance' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
