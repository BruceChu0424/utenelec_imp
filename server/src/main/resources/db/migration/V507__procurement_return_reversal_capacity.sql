-- V132's generic return reversal guard predates approved arrival excess and
-- proven IQC returns. A legal supplier-return reversal could be rejected even
-- though the same received quantity was accepted by V201/V440.
-- Keep sales and legacy material-return semantics byte-for-byte in behavior.
-- No history is rewritten; only future returned_qty mutations are checked.
CREATE OR REPLACE FUNCTION fn_guard_return_allowance()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_new_row jsonb := to_jsonb(NEW);
    v_old_row jsonb;
    v_return_name text := TG_ARGV[0];
    v_processed_name text := TG_ARGV[1];
    v_base_name text := NULLIF(TG_ARGV[2], '');
    v_new_returned numeric;
    v_old_returned numeric;
    v_processed numeric;
    v_base numeric;
    v_rate numeric := 1;
    v_iqc_base numeric := 0;
    v_excess_base numeric := 0;
    v_prefix text;
    v_type text;
BEGIN
    v_old_row := CASE WHEN TG_OP='INSERT' THEN '{}'::jsonb ELSE to_jsonb(OLD) END;
    v_new_returned := COALESCE((v_new_row->>v_return_name)::numeric,0);
    v_old_returned := COALESCE((v_old_row->>v_return_name)::numeric,0);
    v_processed := COALESCE((v_new_row->>v_processed_name)::numeric,0);
    v_base := CASE WHEN v_base_name IS NULL THEN 0 ELSE COALESCE((v_new_row->>v_base_name)::numeric,0) END;
    IF v_new_returned<0 THEN
        RAISE EXCEPTION '% cannot be negative',v_return_name USING ERRCODE='23514',CONSTRAINT=TG_NAME;
    END IF;
    IF v_new_returned>v_old_returned AND v_new_returned>v_processed THEN
        RAISE EXCEPTION '% exceeds processed quantity',v_return_name USING ERRCODE='23514',CONSTRAINT=TG_NAME;
    END IF;
    IF v_base_name IS NOT NULL AND v_new_returned<v_old_returned THEN
        IF TG_TABLE_NAME IN ('purchase_order_items','subcontract_order_items')
           AND v_return_name='returned_qty' AND v_processed_name='received_qty' AND v_base_name='qty' THEN
            v_prefix := CASE WHEN TG_TABLE_NAME='purchase_order_items' THEN 'purchase' ELSE 'subcontract' END;
            v_type := CASE WHEN v_prefix='purchase' THEN 'PURCHASE' ELSE 'SUBCONTRACT' END;
            v_rate := COALESCE((v_new_row->>'unit_rate')::numeric,1);
            -- Both product-return services update the exact receipt item's
            -- returned_qty first, then its order counter in this transaction.
            -- This sees the post-command net slice even before the return head
            -- moves to REVERSED; using its old status would reject a legal undo.
            EXECUTE format($query$
                WITH receipts AS (
                    SELECT ri.id,ri.qty*COALESCE(ri.unit_rate,1) AS gross_base,
                           COALESCE(ri.returned_qty,0)*COALESCE(ri.unit_rate,1) AS returned_base,
                           COALESCE((SELECT SUM(rejection.failed_base_qty)
                               FROM procurement_iqc_rejection_cases rejection
                               WHERE rejection.receipt_type=$2 AND rejection.receipt_id=r.id
                                 AND rejection.receipt_item_id=ri.id AND rejection.order_item_id=$1
                                 AND rejection.is_deleted=FALSE AND rejection.return_recorded_at IS NOT NULL
                                 AND rejection.status IN ('RETURN_RECORDED','CREDIT_CONFIRMED',
                                     'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')),0) AS iqc_base,
                           COALESCE((SELECT SUM(exception.approved_excess_qty*COALESCE(ri.unit_rate,1))
                               FROM procurement_arrival_exceptions exception
                               WHERE exception.order_type=$2 AND exception.order_item_id=$1
                                 AND exception.receipt_id=r.id AND exception.receipt_item_id=ri.id
                                 AND exception.status IN ('RECEIPT_POSTED','CLOSED')),0) AS excess_base
                    FROM %I ri JOIN %I r ON r.id=ri.receipt_id
                    WHERE ri.order_item_id=$1 AND ri.is_deleted=FALSE AND r.is_deleted=FALSE AND r.status=1
                )
                SELECT COALESCE(SUM(iqc_base),0),
                       COALESCE(SUM(LEAST(excess_base,GREATEST(gross_base-returned_base-iqc_base,0))),0)
                FROM receipts
                $query$,v_prefix||'_receipt_items',v_prefix||'_receipts')
                INTO v_iqc_base,v_excess_base USING NEW.id,v_type;
        END IF;
        IF v_processed*v_rate>(v_base+v_new_returned)*v_rate+v_iqc_base+v_excess_base THEN
            RAISE EXCEPTION 'return reversal would exceed source quantity'
                USING ERRCODE='23514',CONSTRAINT=TG_NAME;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- A repaired piece has already consumed its original target/material once.
-- Count only genuinely new production receipts against supplier-held material;
-- a replacement requires the exact returned IQC source, never an order total.
CREATE OR REPLACE FUNCTION fn_assert_subcontract_target_outbound_receipt(
    p_order_item_id UUID
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_issued NUMERIC;
    v_received NUMERIC;
    v_consumed NUMERIC;
    v_replacement NUMERIC;
BEGIN
    IF p_order_item_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM subcontract_material_plan_items plan_item
        WHERE plan_item.order_item_id=p_order_item_id
          AND plan_item.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND')
    ) THEN RETURN; END IF;

    -- FK KEY SHARE remains compatible; ordinary source writes already hold
    -- this row through the common commercial-source prefix.
    PERFORM 1 FROM subcontract_order_items WHERE id=p_order_item_id FOR NO KEY UPDATE;
    SELECT COALESCE(SUM(item.qty*COALESCE(item.unit_rate,1)),0),
           COALESCE(SUM(item.consumed_qty),0)
      INTO v_issued,v_consumed
    FROM subcontract_material_issue_items item
    JOIN subcontract_material_issues issue ON issue.id=item.issue_id
      AND issue.status=1 AND issue.is_deleted=FALSE
    JOIN subcontract_material_plan_items plan_item ON plan_item.id=item.plan_item_id
      AND plan_item.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND')
    WHERE item.order_item_id=p_order_item_id AND item.is_deleted=FALSE;

    SELECT COALESCE(SUM(item.qty*COALESCE(item.unit_rate,1)),0) INTO v_received
    FROM subcontract_receipt_items item
    JOIN subcontract_receipts receipt ON receipt.id=item.receipt_id
      AND receipt.status=1 AND receipt.is_deleted=FALSE
    WHERE item.order_item_id=p_order_item_id AND item.is_deleted=FALSE;

    SELECT COALESCE(SUM(allocation.allocated_base_qty),0) INTO v_replacement
    FROM procurement_iqc_replacement_allocations allocation
    JOIN procurement_iqc_rejection_cases rejection ON rejection.id=allocation.case_id
      AND rejection.receipt_type='SUBCONTRACT' AND rejection.order_item_id=p_order_item_id
      AND rejection.is_deleted=FALSE AND rejection.status<>'REVERSED'
      AND rejection.return_recorded_at IS NOT NULL
    JOIN subcontract_receipt_items original_item ON original_item.id=rejection.receipt_item_id
      AND original_item.receipt_id=rejection.receipt_id AND original_item.order_item_id=p_order_item_id
      AND original_item.is_deleted=FALSE
    JOIN subcontract_receipts original_receipt ON original_receipt.id=original_item.receipt_id
      AND original_receipt.status=1 AND original_receipt.is_deleted=FALSE
    JOIN subcontract_receipt_items replacement_item ON replacement_item.id=allocation.replacement_receipt_item_id
      AND replacement_item.receipt_id=allocation.replacement_receipt_id
      AND replacement_item.order_item_id=p_order_item_id AND replacement_item.is_deleted=FALSE
      AND replacement_item.goods_id=rejection.goods_id
      AND replacement_item.color_id IS NOT DISTINCT FROM rejection.color_id
    JOIN subcontract_receipts replacement_receipt ON replacement_receipt.id=replacement_item.receipt_id
      AND replacement_receipt.status=1 AND replacement_receipt.is_deleted=FALSE
      AND replacement_receipt.supplier_id=rejection.supplier_id
    WHERE allocation.replacement_receipt_type='SUBCONTRACT' AND allocation.status='ACTIVE';

    v_received:=v_received-v_replacement;
    IF v_received<0 OR v_received>v_issued THEN
        RAISE EXCEPTION 'subcontract target receipt exceeds approved target-item outbound'
            USING ERRCODE='23514',CONSTRAINT='subcontract_target_outbound_first_guard';
    END IF;
    IF v_consumed<>v_received THEN
        RAISE EXCEPTION 'subcontract target receipt lacks exact supplier-held consumption'
            USING ERRCODE='23514',CONSTRAINT='subcontract_target_outbound_consumption_guard';
    END IF;
END;
$$;

-- Changing the evidence alone must not silently reopen consumed capacity.
-- The existing receipt/issue triggers cover their own identities and status.
CREATE OR REPLACE FUNCTION fn_check_subcontract_target_iqc_replacement()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_cases UUID[]:=ARRAY[]::UUID[];
    v_items UUID[]:=ARRAY[]::UUID[];
    v_item UUID;
BEGIN
    IF TG_TABLE_NAME='procurement_iqc_replacement_allocations' THEN
        IF TG_OP<>'INSERT' AND OLD.replacement_receipt_type='SUBCONTRACT' THEN v_cases:=array_append(v_cases,OLD.case_id); END IF;
        IF TG_OP<>'DELETE' AND NEW.replacement_receipt_type='SUBCONTRACT' THEN v_cases:=array_append(v_cases,NEW.case_id); END IF;
    ELSE
        IF TG_OP='UPDATE' AND (NEW.receipt_type,NEW.order_item_id,NEW.receipt_id,NEW.receipt_item_id,NEW.supplier_id,
            NEW.goods_id,NEW.color_id,NEW.is_deleted,NEW.status='REVERSED',NEW.return_recorded_at IS NULL)
            IS NOT DISTINCT FROM (OLD.receipt_type,OLD.order_item_id,OLD.receipt_id,OLD.receipt_item_id,OLD.supplier_id,
            OLD.goods_id,OLD.color_id,OLD.is_deleted,OLD.status='REVERSED',OLD.return_recorded_at IS NULL) THEN
            RETURN NULL;
        END IF;
        IF TG_OP<>'INSERT' AND OLD.receipt_type='SUBCONTRACT' THEN v_items:=array_append(v_items,OLD.order_item_id); END IF;
        IF TG_OP<>'DELETE' AND NEW.receipt_type='SUBCONTRACT' THEN v_items:=array_append(v_items,NEW.order_item_id); END IF;
    END IF;
    FOR v_item IN SELECT DISTINCT rejection.order_item_id
        FROM procurement_iqc_rejection_cases rejection
        WHERE rejection.id=ANY(v_cases) AND rejection.receipt_type='SUBCONTRACT'
        UNION SELECT unnest(v_items)
        ORDER BY 1
    LOOP
        PERFORM fn_assert_subcontract_target_outbound_receipt(v_item);
    END LOOP;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_subcontract_target_iqc_allocation_guard
    AFTER INSERT OR UPDATE OR DELETE ON procurement_iqc_replacement_allocations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_target_iqc_replacement();
CREATE CONSTRAINT TRIGGER trg_subcontract_target_iqc_case_guard
    AFTER INSERT OR UPDATE OR DELETE ON procurement_iqc_rejection_cases
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_target_iqc_replacement();
ALTER TABLE procurement_iqc_replacement_allocations ENABLE ALWAYS TRIGGER trg_subcontract_target_iqc_allocation_guard;
ALTER TABLE procurement_iqc_rejection_cases ENABLE ALWAYS TRIGGER trg_subcontract_target_iqc_case_guard;
ALTER TABLE subcontract_receipts ENABLE ALWAYS TRIGGER trg_subcontract_target_receipt_header_guard;
ALTER TABLE subcontract_receipt_items ENABLE ALWAYS TRIGGER trg_subcontract_target_receipt_item_guard;
ALTER TABLE subcontract_material_issue_items ENABLE ALWAYS TRIGGER trg_subcontract_target_issue_consumption_guard;
ALTER TABLE subcontract_material_issues ENABLE ALWAYS TRIGGER trg_subcontract_target_issue_header_guard;
