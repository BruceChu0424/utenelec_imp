-- New request fulfillment is physical; extra gifts keep their own source counter.
-- Closure uses original-unit fulfillment translated through each real frozen IQC
-- tranche. A converted gift residual must never be rounded a second time.
CREATE FUNCTION fn_purchase_order_tranche_stocked_qty(p_order_item UUID,p_tranche TEXT) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(CASE WHEN inspection.warehouse_stocked_base_qty=inspection.received_base_qty
        THEN CASE WHEN p_tranche='GIFT' THEN item.gift_qty ELSE item.qty END
        ELSE (CASE WHEN p_tranche='GIFT' THEN item.gift_qty ELSE item.qty END)
            *inspection.warehouse_stocked_base_qty/NULLIF(inspection.received_base_qty,0) END),0)
    FROM purchase_receipt_items item JOIN purchase_receipts receipt ON receipt.id=item.receipt_id
    JOIN procurement_inspection_items inspection ON inspection.receipt_type='PURCHASE'
        AND inspection.receipt_item_id=item.id AND inspection.quantity_tranche=p_tranche
    WHERE item.order_item_id=p_order_item AND item.quantity_semantics='CHARGED_PLUS_GIFT_V1'
        AND p_tranche IN('CHARGED','GIFT') AND NOT item.is_deleted AND NOT receipt.is_deleted
        AND receipt.status=1 AND inspection.status<>'REVERSED' AND inspection.received_base_qty>0;
$$;
-- Existing over-order/public-surplus authority is preserved. A request is not a finance-approved supplier promise.
DROP TRIGGER trg_purchase_request_gift_ordered_guard ON purchase_request_items;
ALTER TABLE purchase_receipt_items ADD COLUMN gift_replacement_intent TEXT CHECK(gift_replacement_intent IN('NORMAL','RETURN_REPLACEMENT'));

ALTER TABLE procurement_receipt_consideration_parts DROP CONSTRAINT procurement_consideration_gift_zero_chk;
ALTER TABLE procurement_receipt_consideration_parts ADD CONSTRAINT procurement_consideration_gift_zero_chk
    CHECK(quantity_tranche<>'GIFT' OR (billing_mode IN('STANDARD','NO_CHARGE')
        AND nominal_original IS NOT NULL AND nominal_local IS NOT NULL
        AND nominal_original=0 AND nominal_local=0 AND payable_original=0 AND payable_local=0));

CREATE OR REPLACE FUNCTION fn_guard_purchase_gift_input_facts()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_old JSONB:=to_jsonb(OLD);v_new JSONB:=to_jsonb(NEW);v_status SMALLINT;
    v_header_table TEXT;v_parent_column TEXT;
BEGIN
    IF TG_TABLE_NAME IN ('purchase_requests','purchase_orders','purchase_receipts','purchase_returns') THEN
        IF OLD.status<>0 AND NEW.quantity_semantics IS DISTINCT FROM OLD.quantity_semantics THEN
            RAISE EXCEPTION 'posted purchase quantity semantics are immutable' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME='procurement_inspection_items' THEN
        IF NEW.quantity_tranche IS DISTINCT FROM OLD.quantity_tranche THEN
            RAISE EXCEPTION 'received inspection quantity tranche is immutable' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME='purchase_order_item_sources' THEN
        SELECT h.status INTO v_status FROM purchase_order_items i JOIN purchase_orders h ON h.id=i.order_id WHERE i.id=OLD.order_item_id;
        IF v_status<>0 AND NEW.allocated_gift_qty IS DISTINCT FROM OLD.allocated_gift_qty THEN
            RAISE EXCEPTION 'posted gift source allocation is immutable' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    v_header_table:=CASE TG_TABLE_NAME WHEN 'purchase_request_items' THEN 'purchase_requests'
        WHEN 'purchase_order_items' THEN 'purchase_orders' WHEN 'purchase_receipt_items' THEN 'purchase_receipts'
        WHEN 'purchase_return_items' THEN 'purchase_returns' END;
    v_parent_column:=CASE TG_TABLE_NAME WHEN 'purchase_request_items' THEN 'request_id'
        WHEN 'purchase_order_items' THEN 'order_id' WHEN 'purchase_receipt_items' THEN 'receipt_id'
        WHEN 'purchase_return_items' THEN 'return_id' END;
    EXECUTE format('SELECT status FROM %I WHERE id=$1',v_header_table) INTO v_status USING (v_old->>v_parent_column)::UUID;
    IF v_status<>0 AND (v_new->'quantity_semantics',v_new->'gift_qty',v_new->'charged_base_qty',v_new->'gift_base_qty',v_new->'gift_replacement_intent')
            IS DISTINCT FROM (v_old->'quantity_semantics',v_old->'gift_qty',v_old->'charged_base_qty',v_old->'gift_base_qty',v_old->'gift_replacement_intent') THEN
        RAISE EXCEPTION 'posted charged/free input and base facts are immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['purchase_requests','purchase_orders','purchase_receipts','purchase_returns',
        'purchase_request_items','purchase_order_items','purchase_receipt_items','purchase_return_items',
        'purchase_order_item_sources','procurement_inspection_items'] LOOP
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_purchase_gift_input_facts()',
            'trg_'||t||'_gift_input_facts',t);
    END LOOP;
END;
$$;

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
             CASE WHEN quantity_semantics=''CHARGED_PLUS_GIFT_V1'' THEN gift_base_qty ELSE 0 END gift_base_qty,quantity_semantics,gift_replacement_intent'
        ELSE 'qty*unit_rate base_qty,qty*unit_rate amount_base_qty,0::numeric gift_base_qty,''LEGACY_RECORDED''::text quantity_semantics,NULL::text gift_replacement_intent' END,
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
        IF v_item.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN
            IF (v_item.amount_base_qty>0 AND (v_item.replacement_intent='NORMAL')=EXISTS(
                SELECT 1 FROM procurement_receipt_consideration_parts WHERE receipt_type=p_type AND receipt_item_id=v_item.id
                    AND quantity_tranche='CHARGED' AND billing_mode<>'STANDARD' AND fn_procurement_consideration_active('CONSIDERATION',id)))
               OR (v_item.gift_base_qty>0 AND (v_item.gift_replacement_intent IS NULL OR
                    (v_item.gift_replacement_intent='NORMAL')=EXISTS(SELECT 1 FROM procurement_receipt_consideration_parts
                    WHERE receipt_type=p_type AND receipt_item_id=v_item.id AND quantity_tranche='GIFT' AND billing_mode<>'STANDARD'
                        AND fn_procurement_consideration_active('CONSIDERATION',id)))) THEN
                RAISE EXCEPTION 'charged/free consideration differs from its own confirmed arrival intent' USING ERRCODE='23514';
            END IF;
        ELSE
        IF (v_item.replacement_intent='NORMAL')=EXISTS(
            SELECT 1 FROM procurement_receipt_consideration_parts
            WHERE receipt_type=p_type AND receipt_item_id=v_item.id AND billing_mode<>'STANDARD'
              AND fn_procurement_consideration_active('CONSIDERATION',id)) THEN
            RAISE EXCEPTION 'receipt consideration differs from its confirmed arrival intent' USING ERRCODE='23514';
        END IF;
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



CREATE OR REPLACE FUNCTION fn_assert_procurement_quality_consideration(p_event UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_event RECORD; v_part RECORD; v_total RECORD; v_before NUMERIC;
BEGIN
    SELECT event.id,event.action,event.base_qty,inspection.receipt_type,inspection.receipt_id,
           inspection.receipt_item_id,inspection.status inspection_status,inspection.quantity_tranche
    INTO v_event FROM procurement_inspection_events event
    JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id
    WHERE event.id=p_event;
    IF NOT FOUND OR v_event.action NOT IN ('PASS','FAIL') THEN RETURN; END IF;
    IF NOT EXISTS(SELECT 1 FROM procurement_receipt_consideration_parts
        WHERE receipt_type=v_event.receipt_type AND receipt_item_id=v_event.receipt_item_id) THEN RETURN; END IF;
    SELECT COALESCE(SUM(base_qty),0) qty INTO v_total FROM procurement_iqc_quality_consideration_parts
    WHERE inspection_event_id=p_event AND fn_procurement_consideration_active('QUALITY',id);
    IF v_total.qty<>(CASE WHEN v_event.inspection_status='REVERSED' THEN 0 ELSE v_event.base_qty END) THEN
        RAISE EXCEPTION 'quality event consideration is not conserved' USING ERRCODE='23514';
    END IF;
    FOR v_part IN
        SELECT quality.*,part.base_qty capacity,part.nominal_original,part.nominal_local,
               part.receipt_type,part.receipt_item_id,part.quantity_tranche,event.occurred_at
        FROM procurement_iqc_quality_consideration_parts quality
        JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
        JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
        WHERE quality.inspection_event_id=p_event AND fn_procurement_consideration_active('QUALITY',quality.id)
    LOOP
        IF (v_part.receipt_type,v_part.receipt_item_id,v_part.quantity_tranche) IS DISTINCT FROM
           (v_event.receipt_type,v_event.receipt_item_id,v_event.quantity_tranche) THEN
            RAISE EXCEPTION 'quality consideration has a different receipt source' USING ERRCODE='23514';
        END IF;
        SELECT COALESCE(SUM(prior.base_qty),0) INTO v_before
        FROM procurement_iqc_quality_consideration_parts prior
        JOIN procurement_inspection_events event ON event.id=prior.inspection_event_id
        WHERE prior.consideration_part_id=v_part.consideration_part_id
          AND (event.occurred_at,event.id)<(v_part.occurred_at,p_event)
          AND fn_procurement_consideration_active('QUALITY',prior.id);
        IF v_before+v_part.base_qty>v_part.capacity
           OR (v_part.amount_original IS NOT NULL AND v_part.amount_original*v_part.capacity
                IS DISTINCT FROM v_part.nominal_original*v_part.base_qty)
           OR (v_part.amount_local IS NOT NULL AND v_part.amount_local*v_part.capacity
                IS DISTINCT FROM v_part.nominal_local*v_part.base_qty) THEN
            RAISE EXCEPTION 'quality consideration exceeds its cumulative quantity or amount slice' USING ERRCODE='23514';
        END IF;
    END LOOP;
END;
$$;


-- Exact V518 failure/funding guard retained; only free physical tranches never borrow sibling payable.
CREATE OR REPLACE FUNCTION fn_assert_procurement_iqc_funding(p_id UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_fund RECORD;
    v_source RECORD;
    v_used RECORD;
    v_settled RECORD;
BEGIN
    IF p_id IS NULL THEN RETURN; END IF;
    SELECT * INTO v_fund FROM procurement_iqc_funding_slices WHERE id=p_id FOR UPDATE;
    IF NOT FOUND OR NOT fn_procurement_consideration_active('FUNDING',p_id) THEN RETURN; END IF;
    IF NOT EXISTS(WITH RECURSIVE ancestors AS (
        SELECT id,parent_funding_slice_id,ARRAY[id] path FROM procurement_iqc_funding_slices WHERE id=p_id
        UNION ALL SELECT parent.id,parent.parent_funding_slice_id,child.path||parent.id
        FROM procurement_iqc_funding_slices parent JOIN ancestors child ON child.parent_funding_slice_id=parent.id
        WHERE NOT parent.id=ANY(child.path))
        SELECT 1 FROM ancestors WHERE id=v_fund.root_funding_slice_id AND parent_funding_slice_id IS NULL) THEN
        RAISE EXCEPTION 'funding ancestry is cyclic or disconnected from its original root' USING ERRCODE='23514';
    END IF;
    SELECT quality.base_qty,quality.amount_original,quality.amount_local,event.action,
           event.inspection_item_id,part.billing_mode,part.funding_slice_id,
           part.receipt_type,part.receipt_id,part.receipt_item_id,
           rejection.inspection_item_id case_inspection,
           parent.root_funding_slice_id parent_root,parent.root_case_id parent_root_case,
           parent.root_receipt_item_id parent_root_item,parent.source_ap_ledger_id parent_ap,
           ledger.id own_ap
    INTO v_source
    FROM procurement_iqc_quality_consideration_parts quality
    JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
    JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
    JOIN procurement_iqc_rejection_cases rejection ON rejection.id=v_fund.case_id
    LEFT JOIN procurement_iqc_funding_slices parent ON parent.id=part.funding_slice_id
    LEFT JOIN ar_ap_ledger ledger ON ledger.source_doc_id=part.receipt_id
      AND part.quantity_tranche<>'GIFT'
      AND ledger.source_doc_type=part.receipt_type||'_RECEIPT'
      AND ledger.direction='AP' AND ledger.status=1 AND ledger.is_deleted=FALSE
    WHERE quality.id=v_fund.quality_part_id
      AND fn_procurement_consideration_active('QUALITY',quality.id)
      AND fn_procurement_consideration_active('CONSIDERATION',part.id);
    IF NOT FOUND OR v_source.action<>'FAIL' OR v_source.case_inspection<>v_source.inspection_item_id
       OR (v_fund.base_qty,v_fund.amount_original,v_fund.amount_local)
          IS DISTINCT FROM (v_source.base_qty,v_source.amount_original,v_source.amount_local) THEN
        RAISE EXCEPTION 'funding slice lacks its exact physical failure' USING ERRCODE='23514';
    END IF;
    IF v_source.billing_mode='NO_CHARGE' THEN
        IF (v_fund.parent_funding_slice_id,v_fund.root_funding_slice_id,v_fund.root_case_id,
            v_fund.root_receipt_item_id,v_fund.source_ap_ledger_id)
           IS DISTINCT FROM (v_source.funding_slice_id,v_source.parent_root,v_source.parent_root_case,
            v_source.parent_root_item,v_source.parent_ap) THEN
            RAISE EXCEPTION 'free replacement must carry its original funding root' USING ERRCODE='23514';
        END IF;
    ELSIF v_fund.parent_funding_slice_id IS NOT NULL OR v_fund.root_funding_slice_id<>v_fund.id
       OR v_fund.root_case_id<>v_fund.case_id OR v_fund.root_receipt_item_id<>v_source.receipt_item_id
       OR v_fund.source_ap_ledger_id IS DISTINCT FROM v_source.own_ap
       OR (v_fund.source_ap_ledger_id IS NULL AND (v_fund.amount_original<>0 OR v_fund.amount_local<>0)) THEN
        RAISE EXCEPTION 'paid failure must use its own receipt funding' USING ERRCODE='23514';
    END IF;
    SELECT COALESCE(SUM(qty),0) qty,COALESCE(SUM(original),0) original,COALESCE(SUM(local),0) local
    INTO v_used FROM (
        SELECT base_qty qty,nominal_original original,nominal_local local
        FROM procurement_receipt_consideration_parts WHERE funding_slice_id=p_id AND billing_mode='NO_CHARGE'
          AND fn_procurement_consideration_active('CONSIDERATION',id)
        UNION ALL
        SELECT base_qty,amount_original,amount_local FROM procurement_iqc_credit_slices
        WHERE funding_slice_id=p_id AND fn_procurement_consideration_active('CREDIT',id)
    ) usage;
    IF v_used.qty>v_fund.base_qty THEN
        RAISE EXCEPTION 'free replacement and credit exceed the same funding slice'
            USING ERRCODE='23514',CONSTRAINT='procurement_iqc_funding_capacity';
    END IF;
    SELECT COALESCE(SUM(base_qty),0) qty,COALESCE(SUM(amount_original),0) original,
           COALESCE(SUM(amount_local),0) local INTO v_settled
    FROM procurement_iqc_funding_settlements
    WHERE funding_slice_id=p_id AND fn_procurement_consideration_active('SETTLEMENT',id);
    IF v_settled.qty>v_fund.base_qty THEN
        RAISE EXCEPTION 'funding is settled more than once across replacement generations'
            USING ERRCODE='23514',CONSTRAINT='procurement_iqc_funding_settlement_capacity';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_guard_procurement_iqc_replacement_identity()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_case RECORD;
    v_receipt_id UUID;
    v_order_item_id UUID;
    v_goods_id UUID;
    v_color_id UUID;
    v_unit_id UUID;
    v_unit_rate NUMERIC(18,6);
    v_receipt_qty NUMERIC(18,4);
    v_receipt_base NUMERIC(18,4);
    v_receipt_original NUMERIC;
    v_receipt_local NUMERIC;
    v_case_qty NUMERIC(18,4);
    v_case_base NUMERIC(18,4);
    v_case_original NUMERIC;
    v_case_local NUMERIC;
    v_item_qty NUMERIC(18,4);
    v_item_base NUMERIC(18,4);
    v_item_original NUMERIC;
    v_item_local NUMERIC;
BEGIN
    SELECT receipt_type,order_item_id,goods_id,color_id,unit_id,unit_rate,
           failed_qty,failed_base_qty,failed_amount_original,
           failed_amount_local,return_recorded_at,status,
           (SELECT quantity_tranche FROM procurement_inspection_items inspection WHERE inspection.id=procurement_iqc_rejection_cases.inspection_item_id) quantity_tranche
      INTO v_case
    FROM procurement_iqc_rejection_cases
    WHERE id=NEW.case_id AND is_deleted=FALSE
    FOR UPDATE;
    IF NOT FOUND OR v_case.return_recorded_at IS NULL
       OR v_case.status NOT IN(
           'RETURN_RECORDED','CREDIT_CONFIRMED',
           'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
       OR v_case.receipt_type<>NEW.replacement_receipt_type THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='replacement allocation requires an active physically returned IQC case',
            CONSTRAINT='procurement_iqc_replacement_case_guard';
    END IF;

    IF NEW.replacement_receipt_type='PURCHASE' THEN
        SELECT item.receipt_id,item.order_item_id,item.goods_id,item.color_id,
               item.unit_id,item.unit_rate,
               CASE WHEN v_case.quantity_tranche='GIFT' THEN item.gift_qty ELSE item.qty END,
               CASE WHEN v_case.quantity_tranche='GIFT' THEN 0 ELSE item.amount_original END,
               CASE WHEN v_case.quantity_tranche='GIFT' THEN 0 ELSE item.amount_local END,
               CASE WHEN item.quantity_semantics='CHARGED_PLUS_GIFT_V1'
                    THEN CASE WHEN v_case.quantity_tranche='GIFT' THEN item.gift_base_qty ELSE item.charged_base_qty END
                    ELSE round(item.qty*item.unit_rate,4) END
          INTO v_receipt_id,v_order_item_id,v_goods_id,v_color_id,
               v_unit_id,v_unit_rate,v_receipt_qty,v_receipt_original,
               v_receipt_local,v_receipt_base
        FROM purchase_receipt_items item
        JOIN purchase_receipts receipt ON receipt.id=item.receipt_id
        WHERE item.id=NEW.replacement_receipt_item_id
          AND receipt.id=NEW.replacement_receipt_id
          AND receipt.status IN(0,1)
          AND (v_case.quantity_tranche<>'GIFT' OR item.quantity_semantics='CHARGED_PLUS_GIFT_V1')
          AND item.is_deleted=FALSE AND receipt.is_deleted=FALSE;
    ELSE
        IF v_case.quantity_tranche='GIFT' THEN RAISE EXCEPTION 'subcontract does not have a purchase free tranche' USING ERRCODE='23514'; END IF;
        SELECT item.receipt_id,item.order_item_id,item.goods_id,item.color_id,
               item.unit_id,item.unit_rate,item.qty,item.amount_original,
               item.amount_local
          INTO v_receipt_id,v_order_item_id,v_goods_id,v_color_id,
               v_unit_id,v_unit_rate,v_receipt_qty,v_receipt_original,
               v_receipt_local
        FROM subcontract_receipt_items item
        JOIN subcontract_receipts receipt ON receipt.id=item.receipt_id
        WHERE item.id=NEW.replacement_receipt_item_id
          AND receipt.id=NEW.replacement_receipt_id
          AND receipt.status IN(0,1)
          AND item.is_deleted=FALSE AND receipt.is_deleted=FALSE;
        v_receipt_base:=round(v_receipt_qty*v_unit_rate,4);
    END IF;
    IF v_receipt_id IS NULL
       OR v_order_item_id<>v_case.order_item_id
       OR v_goods_id<>v_case.goods_id
       OR v_color_id IS DISTINCT FROM v_case.color_id
       OR v_unit_id IS DISTINCT FROM v_case.unit_id
       OR v_unit_rate IS DISTINCT FROM v_case.unit_rate THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='replacement receipt item differs from the returned IQC source identity',
            CONSTRAINT='procurement_iqc_replacement_receipt_identity_guard';
    END IF;

    IF v_case.quantity_tranche='GIFT' AND (NEW.allocated_amount_original IS DISTINCT FROM 0::numeric OR NEW.allocated_amount_local IS DISTINCT FROM 0::numeric) THEN
        RAISE EXCEPTION 'free replacement cannot borrow charged consideration' USING ERRCODE='23514';
    END IF;
    IF NEW.status='ACTIVE' THEN
        SELECT COALESCE(SUM(allocated_qty),0),
               COALESCE(SUM(allocated_base_qty),0),
               COALESCE(SUM(allocated_amount_original),0),
               COALESCE(SUM(allocated_amount_local),0)
          INTO v_case_qty,v_case_base,v_case_original,v_case_local
        FROM procurement_iqc_replacement_allocations
        WHERE case_id=NEW.case_id AND status='ACTIVE'
          AND id<>NEW.id;
        v_case_qty:=v_case_qty+NEW.allocated_qty;
        v_case_base:=v_case_base+NEW.allocated_base_qty;
        v_case_original:=v_case_original+NEW.allocated_amount_original;
        v_case_local:=v_case_local+NEW.allocated_amount_local;
        IF v_case_qty>v_case.failed_qty
           OR v_case_base>v_case.failed_base_qty THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='replacement allocation exceeds the returned IQC failure slice',
                CONSTRAINT='procurement_iqc_replacement_case_capacity_guard';
        END IF;

        SELECT COALESCE(SUM(allocated_qty),0),
               COALESCE(SUM(allocated_base_qty),0),
               COALESCE(SUM(allocated_amount_original),0),
               COALESCE(SUM(allocated_amount_local),0)
          INTO v_item_qty,v_item_base,v_item_original,v_item_local
        FROM procurement_iqc_replacement_allocations allocation
        WHERE replacement_receipt_item_id=NEW.replacement_receipt_item_id
          AND status='ACTIVE' AND id<>NEW.id
          AND (v_case.quantity_tranche='GIFT')=EXISTS(SELECT 1 FROM procurement_iqc_rejection_cases prior
              JOIN procurement_inspection_items inspection ON inspection.id=prior.inspection_item_id
              WHERE prior.id=allocation.case_id AND inspection.quantity_tranche='GIFT');
        v_item_qty:=v_item_qty+NEW.allocated_qty;
        v_item_base:=v_item_base+NEW.allocated_base_qty;
        v_item_original:=v_item_original+NEW.allocated_amount_original;
        v_item_local:=v_item_local+NEW.allocated_amount_local;
        IF v_item_qty>v_receipt_qty
           OR v_receipt_base IS NULL OR v_item_base>v_receipt_base THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='replacement allocations exceed the authoritative receipt item',
                CONSTRAINT='procurement_iqc_replacement_item_capacity_guard';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- The ordered quantity remains the charged snapshot. A zero charged snapshot is
-- meaningful only for an explicitly free-only purchase source, never for an empty
-- legacy or subcontract task. Free capacity continues to come from that source.
ALTER TABLE inbound_expectation_items DROP CONSTRAINT inbound_expectation_items_ordered_qty_check;
ALTER TABLE inbound_expectation_items ADD CONSTRAINT inbound_expectation_items_ordered_qty_check CHECK(ordered_qty>=0);
CREATE OR REPLACE FUNCTION fn_guard_inbound_expectation_free_only_source() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.ordered_qty=0 AND NOT EXISTS(
        SELECT 1 FROM inbound_expectations expectation
        JOIN purchase_order_items item ON item.id=NEW.order_item_id AND item.order_id=expectation.order_id
        WHERE expectation.id=NEW.expectation_id AND expectation.order_type='PURCHASE'
          AND NOT item.is_deleted AND item.quantity_semantics='CHARGED_PLUS_GIFT_V1'
          AND item.qty=0 AND item.gift_qty>0
          AND item.amount_original=0 AND item.amount_local=0
    ) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='zero charged arrival snapshot requires an explicit free-only purchase source',
            CONSTRAINT='inbound_expectation_free_only_source_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_inbound_expectation_free_only_source_guard
BEFORE INSERT OR UPDATE OF ordered_qty,expectation_id,order_item_id ON inbound_expectation_items
FOR EACH ROW EXECUTE FUNCTION fn_guard_inbound_expectation_free_only_source();



-- Received/ordinary-returned and actually returned quality failures are separate physical facts.
CREATE FUNCTION fn_purchase_order_gift_remaining_qty(p_item UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN item.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN
        GREATEST(COALESCE(item.gift_qty,0)-COALESCE(item.gift_received_qty,0)+COALESCE(item.gift_returned_qty,0)
            +COALESCE((SELECT SUM(rejection.failed_qty) FROM procurement_iqc_rejection_cases rejection
                JOIN procurement_inspection_items inspection ON inspection.id=rejection.inspection_item_id
                WHERE rejection.order_item_id=item.id AND rejection.receipt_type='PURCHASE'
                    AND inspection.quantity_tranche='GIFT' AND NOT rejection.is_deleted AND rejection.return_recorded_at IS NOT NULL
                    AND rejection.status IN('RETURN_RECORDED','CREDIT_CONFIRMED','CLOSED_NO_CREDIT','FINANCE_EXCEPTION')),0),0)
        ELSE 0 END
    FROM purchase_order_items item WHERE item.id=p_item AND NOT item.is_deleted;
$$;

CREATE OR REPLACE FUNCTION public.fn_guard_procurement_finance_commercial_snapshot()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_currency UUID;
    v_rate NUMERIC;
    v_tax NUMERIC;
    v_settlement UUID;
    v_total_original NUMERIC;
    v_total_local NUMERIC;
    v_item_original NUMERIC;
    v_item_local NUMERIC;
    v_item_count BIGINT;
    v_invalid_items BIGINT;
    v_order_found BOOLEAN:=FALSE;
    v_currency_active BOOLEAN;
    v_settlement_active BOOLEAN;
BEGIN
    IF NEW.status NOT IN ('PENDING', 'APPROVED') THEN RETURN NEW; END IF;
    IF NEW.order_type='PURCHASE' THEN
        SELECT currency_id,exchange_rate,tax_rate,settlement_method_id,
               total_original,total_local
          INTO v_currency,v_rate,v_tax,v_settlement,v_total_original,v_total_local
          FROM purchase_orders
         WHERE id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE
         FOR UPDATE;
        v_order_found:=FOUND;
        PERFORM 1 FROM purchase_order_items
         WHERE order_id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE
         ORDER BY id FOR UPDATE;
        SELECT COUNT(*),COALESCE(SUM(amount_original),0),COALESCE(SUM(amount_local),0),
               COUNT(*) FILTER(WHERE qty IS NULL OR qty<0 OR (qty=0 AND (quantity_semantics<>'CHARGED_PLUS_GIFT_V1' OR gift_qty IS NULL OR gift_qty<=0 OR price IS DISTINCT FROM 0::numeric OR total_amount_input IS NOT NULL OR amount_original IS DISTINCT FROM 0::numeric OR amount_local IS DISTINCT FROM 0::numeric)) OR price IS NULL OR price<0
                 OR amount_original IS NULL OR amount_original<0
                 OR amount_local IS NULL OR amount_local<0
                 OR amount_original<>fn_business_columns_amount(COALESCE(total_amount_input,qty*price),extra_columns)
                 OR (total_amount_input IS NOT NULL AND price<>fn_procurement_reference_price(total_amount_input,qty))
                 OR amount_local<>(amount_original*v_rate))
          INTO v_item_count,v_item_original,v_item_local,v_invalid_items
          FROM purchase_order_items
         WHERE order_id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE;
    ELSIF NEW.order_type='SUBCONTRACT' THEN
        SELECT currency_id,exchange_rate,tax_rate,settlement_method_id,
               total_original,total_local
          INTO v_currency,v_rate,v_tax,v_settlement,v_total_original,v_total_local
          FROM subcontract_orders
         WHERE id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE
         FOR UPDATE;
        v_order_found:=FOUND;
        PERFORM 1 FROM subcontract_order_items
         WHERE order_id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE
         ORDER BY id FOR UPDATE;
        SELECT COUNT(*),COALESCE(SUM(amount_original),0),COALESCE(SUM(amount_local),0),
               COUNT(*) FILTER(WHERE qty IS NULL OR qty<=0 OR price IS NULL OR price<0
                 OR amount_original IS NULL OR amount_original<0
                 OR amount_local IS NULL OR amount_local<0
                 OR amount_original<>fn_business_columns_amount(COALESCE(total_amount_input,qty*price),extra_columns)
                 OR (total_amount_input IS NOT NULL AND price<>fn_procurement_reference_price(total_amount_input,qty))
                 OR amount_local<>(amount_original*v_rate))
          INTO v_item_count,v_item_original,v_item_local,v_invalid_items
          FROM subcontract_order_items
         WHERE order_id=NEW.order_id AND COALESCE(is_deleted,FALSE)=FALSE;
    ELSE
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='unsupported procurement finance order type',
            CONSTRAINT='procurement_finance_commercial_snapshot_guard';
    END IF;
    IF NOT v_order_found THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='procurement finance source order is missing',
            CONSTRAINT='procurement_finance_commercial_snapshot_guard';
    END IF;
    SELECT EXISTS(SELECT 1 FROM currencies
        WHERE id=v_currency AND status='使用' AND COALESCE(is_deleted,FALSE)=FALSE)
      INTO v_currency_active;
    SELECT EXISTS(SELECT 1 FROM settlement_methods
        WHERE id=v_settlement AND status='使用' AND COALESCE(is_deleted,FALSE)=FALSE)
      INTO v_settlement_active;
    IF v_currency IS NULL OR NOT COALESCE(v_currency_active,FALSE)
       OR v_rate IS NULL OR v_rate<=0
       OR v_tax IS NULL OR v_tax<0 OR v_tax>100
       OR v_settlement IS NULL OR NOT COALESCE(v_settlement_active,FALSE) THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='finance review requires active currency, positive rate, 0..100 tax and active settlement method',
            CONSTRAINT='procurement_finance_commercial_snapshot_guard';
    END IF;
    IF v_item_count=0 OR v_invalid_items<>0
       OR v_total_original IS DISTINCT FROM v_item_original
       OR v_total_local IS DISTINCT FROM v_item_local
       OR NEW.amount_snapshot IS DISTINCT FROM v_total_local THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='procurement finance snapshot amount or locked item set is incomplete/inconsistent',
            CONSTRAINT='procurement_finance_commercial_snapshot_guard';
    END IF;
    RETURN NEW;
END;
$function$;

