-- V922/V923 finality includes separately accepted finished-product loss, not only physical receipts.
-- Reversing the linked component waste must not silently erase the settled portion of a closed promise.
CREATE FUNCTION fn_guard_terminated_subcontract_settled_loss() RETURNS TRIGGER LANGUAGE plpgsql AS $function$
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
        RAISE EXCEPTION '该损耗已计入订单财务结束时核定的履约数量，不能直接红冲；请联系财务核对后续处置。'
            USING ERRCODE='23514',CONSTRAINT='subcontract_terminated_settled_loss_basis_guard';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER trg_subcontract_terminated_waste_basis BEFORE UPDATE OR DELETE ON subcontract_wastes
    FOR EACH ROW EXECUTE FUNCTION fn_guard_terminated_subcontract_settled_loss();
CREATE TRIGGER trg_subcontract_terminated_loss_basis BEFORE INSERT OR UPDATE OR DELETE ON subcontract_short_delivery_cases
    FOR EACH ROW EXECUTE FUNCTION fn_guard_terminated_subcontract_settled_loss();
ALTER TABLE subcontract_wastes ENABLE ALWAYS TRIGGER trg_subcontract_terminated_waste_basis;
ALTER TABLE subcontract_short_delivery_cases ENABLE ALWAYS TRIGGER trg_subcontract_terminated_loss_basis;
