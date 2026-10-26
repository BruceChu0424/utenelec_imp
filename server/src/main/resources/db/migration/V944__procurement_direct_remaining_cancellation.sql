-- Procurement/subcontract directly cancel only the unfulfilled remainder.
-- APPROVED is the compatible terminal storage code; executionMode records the business actor's decision.
-- Existing pending requests stay historical until their owner explicitly rechecks and executes.
ALTER TABLE procurement_order_approval_events DROP CONSTRAINT procurement_order_approval_events_event_type_check;
ALTER TABLE procurement_order_approval_events ADD CONSTRAINT procurement_order_approval_events_event_type_check
    CHECK(event_type IN ('SUBMITTED','APPROVED','REJECTED','CANCELED','REASSIGNED','FINANCE_EDIT','CLOSED'));

ALTER TABLE procurement_order_approval_cases ADD CONSTRAINT procurement_direct_closure_identity
    CHECK(COALESCE(submission_snapshot #>> '{closureRequest,executionMode}','')<>'DIRECT'
        OR (request_type IN ('CLOSE','CLOSE_AND_REORDER') AND status='APPROVED' AND decided_txid IS NOT NULL
            AND decided_by_user_id=submitted_by_user_id AND decided_by_employee_id=submitted_by_employee_id));

CREATE OR REPLACE FUNCTION fn_guard_procurement_termination() RETURNS TRIGGER LANGUAGE plpgsql AS $function$
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
            RAISE EXCEPTION 'Procurement termination is permanent; retain the historical order' USING ERRCODE='23514';
        END IF;
        -- Later receipt/return/quality recalculations must not reopen delivery obligations.
        NEW.is_closed := TRUE;
    ELSIF NEW.termination_case_id IS NOT NULL THEN
        IF NEW.status <> 1 OR NEW.is_deleted OR NOT EXISTS (
            SELECT 1 FROM procurement_order_approval_cases c WHERE c.id=NEW.termination_case_id
              AND c.order_id=OLD.id AND c.order_type=TG_ARGV[0] AND c.status='APPROVED'
              AND c.request_type IN ('CLOSE','CLOSE_AND_REORDER')
        ) THEN RAISE EXCEPTION 'Termination requires a completed closure decision for this order' USING ERRCODE='23514';
        END IF;
        NEW.is_closed := TRUE;
    END IF;
    RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION fn_guard_terminated_procurement_receipt_basis() RETURNS TRIGGER LANGUAGE plpgsql AS $function$
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
        RAISE EXCEPTION '该订单已按当前实收量取消剩余数量并结束，不能直接新增退货或红冲原收退货；请先联系财务核对后续处置。'
            USING ERRCODE='23514',CONSTRAINT='procurement_terminated_receipt_basis_guard';
    END IF;
    RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION fn_guard_terminated_subcontract_settled_loss() RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE old_effective BOOLEAN; new_effective BOOLEAN; immutable_changed BOOLEAN; terminal BOOLEAN;
BEGIN
    IF TG_TABLE_NAME='subcontract_wastes' THEN
        immutable_changed:=TG_OP='DELETE';
        IF TG_OP='UPDATE' THEN
            immutable_changed:=(NEW.status,NEW.is_deleted) IS DISTINCT FROM (OLD.status,OLD.is_deleted);
        END IF;
        IF NOT immutable_changed THEN
            IF TG_OP='DELETE' THEN RETURN OLD; END IF;
            RETURN NEW;
        END IF;
        SELECT EXISTS(SELECT 1 FROM subcontract_short_delivery_cases loss
            JOIN subcontract_orders orders ON orders.id=loss.order_id
            WHERE loss.waste_id=OLD.id AND loss.status='ACCEPTED_LOSS' AND loss.decision='ACCEPT_LOSS'
              AND loss.closed_at IS NOT NULL AND loss.loss_qty>0 AND loss.qty_change_log_id IS NULL
              AND orders.termination_case_id IS NOT NULL) INTO terminal;
    ELSE
        old_effective:=FALSE;new_effective:=FALSE;immutable_changed:=TG_OP<>'UPDATE';
        IF TG_OP<>'INSERT' THEN
            old_effective:=OLD.status='ACCEPTED_LOSS' AND OLD.decision='ACCEPT_LOSS'
                AND OLD.closed_at IS NOT NULL AND OLD.loss_qty>0 AND OLD.qty_change_log_id IS NULL;
        END IF;
        IF TG_OP<>'DELETE' THEN
            new_effective:=NEW.status='ACCEPTED_LOSS' AND NEW.decision='ACCEPT_LOSS'
                AND NEW.closed_at IS NOT NULL AND NEW.loss_qty>0 AND NEW.qty_change_log_id IS NULL;
        END IF;
        IF TG_OP='UPDATE' THEN
            immutable_changed:=(NEW.status,NEW.decision,NEW.order_id,NEW.order_item_id,NEW.loss_qty,
                NEW.waste_id,NEW.qty_change_log_id,NEW.closed_at)
                IS DISTINCT FROM (OLD.status,OLD.decision,OLD.order_id,OLD.order_item_id,OLD.loss_qty,
                OLD.waste_id,OLD.qty_change_log_id,OLD.closed_at);
        END IF;
        IF NOT immutable_changed OR NOT (COALESCE(old_effective,FALSE) OR COALESCE(new_effective,FALSE)) THEN
            IF TG_OP='DELETE' THEN RETURN OLD; END IF;
            RETURN NEW;
        END IF;
        terminal:=FALSE;
        IF old_effective THEN
            SELECT termination_case_id IS NOT NULL INTO terminal FROM subcontract_orders WHERE id=OLD.order_id;
        END IF;
        IF NOT COALESCE(terminal,FALSE) AND new_effective THEN
            SELECT termination_case_id IS NOT NULL INTO terminal FROM subcontract_orders WHERE id=NEW.order_id;
        END IF;
    END IF;
    IF COALESCE(terminal,FALSE) THEN
        RAISE EXCEPTION '该损耗已计入订单结束时核定的履约数量，不能直接红冲；请联系财务核对后续处置。'
            USING ERRCODE='23514',CONSTRAINT='subcontract_terminated_settled_loss_basis_guard';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END
$function$;

