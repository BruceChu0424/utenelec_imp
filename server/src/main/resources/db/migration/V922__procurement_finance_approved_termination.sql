-- A termination decision is separate from the commercial approval of an effective order.
ALTER TABLE procurement_order_approval_cases
    ADD COLUMN request_type TEXT NOT NULL DEFAULT 'ORDER'
        CHECK (request_type IN ('ORDER','CLOSE','CLOSE_AND_REORDER')),
    ADD COLUMN replacement_order_id UUID,
    ADD COLUMN decided_txid BIGINT;
ALTER TABLE purchase_orders ADD COLUMN termination_case_id UUID
    REFERENCES procurement_order_approval_cases(id) ON DELETE RESTRICT;
ALTER TABLE subcontract_orders ADD COLUMN termination_case_id UUID
    REFERENCES procurement_order_approval_cases(id) ON DELETE RESTRICT;
CREATE INDEX idx_procurement_termination_cases ON procurement_order_approval_cases(order_type,order_id,attempt DESC)
    WHERE request_type <> 'ORDER';

-- Historical commercial inconsistencies do not prevent a finance-reviewed stop. No amount is changed.
DROP TRIGGER trg_guard_procurement_finance_commercial_snapshot ON procurement_order_approval_cases;
CREATE TRIGGER trg_guard_procurement_finance_commercial_snapshot
    BEFORE INSERT OR UPDATE OF status,order_type,order_id ON procurement_order_approval_cases
    FOR EACH ROW WHEN (NEW.request_type = 'ORDER')
    EXECUTE FUNCTION fn_guard_procurement_finance_commercial_snapshot();
ALTER TABLE procurement_order_approval_cases ENABLE ALWAYS TRIGGER trg_guard_procurement_finance_commercial_snapshot;

CREATE OR REPLACE FUNCTION fn_procurement_order_latest_approval_status(p_order_type TEXT,p_order_id UUID)
RETURNS TEXT LANGUAGE sql STABLE AS $function$
    SELECT approval.status FROM procurement_order_approval_cases approval
    WHERE approval.order_type=p_order_type AND approval.order_id=p_order_id AND approval.request_type='ORDER'
    ORDER BY approval.attempt DESC LIMIT 1
$function$;

CREATE FUNCTION fn_guard_procurement_termination() RETURNS TRIGGER LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_OP='INSERT' THEN
        IF NEW.termination_case_id IS NOT NULL THEN
            RAISE EXCEPTION 'A new order cannot start with a termination decision' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.termination_case_id IS NOT NULL THEN
        IF NEW.termination_case_id IS DISTINCT FROM OLD.termination_case_id
           OR NEW.status IS DISTINCT FROM OLD.status OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted THEN
            RAISE EXCEPTION 'Finance-approved termination is permanent; retain the historical order' USING ERRCODE='23514';
        END IF;
        -- Later receipt/return/quality recalculations must not reopen delivery obligations.
        NEW.is_closed := TRUE;
    ELSIF NEW.termination_case_id IS NOT NULL THEN
        IF NEW.status <> 1 OR NEW.is_deleted OR NOT EXISTS (
            SELECT 1 FROM procurement_order_approval_cases c WHERE c.id=NEW.termination_case_id
              AND c.order_id=OLD.id AND c.order_type=TG_ARGV[0] AND c.status='APPROVED'
              AND c.request_type IN ('CLOSE','CLOSE_AND_REORDER')
        ) THEN RAISE EXCEPTION 'Termination requires an approved finance decision for this order' USING ERRCODE='23514';
        END IF;
        NEW.is_closed := TRUE;
    END IF;
    RETURN NEW;
END
$function$;
CREATE TRIGGER trg_purchase_order_termination BEFORE INSERT OR UPDATE ON purchase_orders
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_termination('PURCHASE');
CREATE TRIGGER trg_subcontract_order_termination BEFORE INSERT OR UPDATE ON subcontract_orders
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_termination('SUBCONTRACT');
ALTER TABLE purchase_orders ENABLE ALWAYS TRIGGER trg_purchase_order_termination;
ALTER TABLE subcontract_orders ENABLE ALWAYS TRIGGER trg_subcontract_order_termination;

CREATE FUNCTION fn_guard_procurement_termination_case_identity() RETURNS TRIGGER LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.request_type IS DISTINCT FROM OLD.request_type
       OR (OLD.decided_txid IS NOT NULL AND NEW.decided_txid IS DISTINCT FROM OLD.decided_txid)
       OR (OLD.replacement_order_id IS NOT NULL AND NEW.replacement_order_id IS DISTINCT FROM OLD.replacement_order_id) THEN
        RAISE EXCEPTION 'Procurement termination decision identity is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END
$function$;
CREATE TRIGGER trg_procurement_termination_case_identity BEFORE UPDATE ON procurement_order_approval_cases
    FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_termination_case_identity();

-- Keep the approved retained quantity, source commitments and production pegs on one final basis.
CREATE FUNCTION fn_guard_terminated_procurement_receipt_basis() RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE changed BOOLEAN; kind TEXT; item_id UUID; terminal BOOLEAN;
BEGIN
    IF TG_TABLE_NAME IN ('purchase_order_items','subcontract_order_items') THEN
        changed := (NEW.received_qty,NEW.returned_qty) IS DISTINCT FROM (OLD.received_qty,OLD.returned_qty)
            OR (to_jsonb(NEW)->'gift_received_qty',to_jsonb(NEW)->'gift_returned_qty')
                IS DISTINCT FROM (to_jsonb(OLD)->'gift_received_qty',to_jsonb(OLD)->'gift_returned_qty');
        kind:=TG_ARGV[0];item_id:=NEW.id;
    ELSIF TG_TABLE_NAME='procurement_inspection_items' THEN
        changed := (NEW.received_base_qty,NEW.passed_base_qty,NEW.failed_base_qty,NEW.status)
            IS DISTINCT FROM (OLD.received_base_qty,OLD.passed_base_qty,OLD.failed_base_qty,OLD.status);
        kind:=NEW.receipt_type;
        IF kind='PURCHASE' THEN
            SELECT order_item_id INTO item_id FROM purchase_receipt_items WHERE id=NEW.receipt_item_id;
        ELSE
            SELECT order_item_id INTO item_id FROM subcontract_receipt_items WHERE id=NEW.receipt_item_id;
        END IF;
    ELSE
        changed := (NEW.return_recorded_at,NEW.failed_qty,NEW.failed_base_qty)
            IS DISTINCT FROM (OLD.return_recorded_at,OLD.failed_qty,OLD.failed_base_qty);
        kind:=NEW.receipt_type;item_id:=NEW.order_item_id;
    END IF;
    IF NOT changed OR item_id IS NULL THEN RETURN NEW; END IF;
    IF kind='PURCHASE' THEN
        SELECT EXISTS(SELECT 1 FROM purchase_order_items i JOIN purchase_orders h ON h.id=i.order_id
            WHERE i.id=item_id AND h.termination_case_id IS NOT NULL) INTO terminal;
    ELSE
        SELECT EXISTS(SELECT 1 FROM subcontract_order_items i JOIN subcontract_orders h ON h.id=i.order_id
            WHERE i.id=item_id AND h.termination_case_id IS NOT NULL) INTO terminal;
    END IF;
    IF terminal THEN
        RAISE EXCEPTION '该订单已按当前实收量经财务批准结束，不能直接新增退货或红冲原收退货；请先联系财务核对后续处置。'
            USING ERRCODE='23514',CONSTRAINT='procurement_terminated_receipt_basis_guard';
    END IF;
    RETURN NEW;
END
$function$;
CREATE TRIGGER trg_purchase_terminated_receipt_basis BEFORE UPDATE ON purchase_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_terminated_procurement_receipt_basis('PURCHASE');
CREATE TRIGGER trg_subcontract_terminated_receipt_basis BEFORE UPDATE ON subcontract_order_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_terminated_procurement_receipt_basis('SUBCONTRACT');
CREATE TRIGGER trg_inspection_terminated_receipt_basis BEFORE UPDATE ON procurement_inspection_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_terminated_procurement_receipt_basis();
CREATE TRIGGER trg_iqc_return_terminated_receipt_basis BEFORE UPDATE ON procurement_iqc_rejection_cases
    FOR EACH ROW EXECUTE FUNCTION fn_guard_terminated_procurement_receipt_basis();
ALTER TABLE purchase_order_items ENABLE ALWAYS TRIGGER trg_purchase_terminated_receipt_basis;
ALTER TABLE subcontract_order_items ENABLE ALWAYS TRIGGER trg_subcontract_terminated_receipt_basis;
ALTER TABLE procurement_inspection_items ENABLE ALWAYS TRIGGER trg_inspection_terminated_receipt_basis;
ALTER TABLE procurement_iqc_rejection_cases ENABLE ALWAYS TRIGGER trg_iqc_return_terminated_receipt_basis;
