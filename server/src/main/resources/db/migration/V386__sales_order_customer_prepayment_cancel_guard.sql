-- V386: raw SQL cannot stop, reverse or delete an order while finance-owned
-- customer-advance facts remain bound to it. Natural fulfillment close is allowed.
CREATE OR REPLACE FUNCTION fn_guard_sales_order_customer_prepayment_cancel()
RETURNS TRIGGER AS $v386$
DECLARE v_order_id UUID; v_should_guard BOOLEAN; v_blocking BOOLEAN;
BEGIN
    v_order_id:=OLD.id;
    v_should_guard:=TG_OP='DELETE';
    IF TG_OP='UPDATE' THEN
        v_should_guard:=(COALESCE(OLD.is_stopped,FALSE)=FALSE AND COALESCE(NEW.is_stopped,FALSE)=TRUE)
            OR (OLD.status IS DISTINCT FROM -1 AND NEW.status=-1)
            OR (COALESCE(OLD.is_deleted,FALSE)=FALSE AND COALESCE(NEW.is_deleted,FALSE)=TRUE);
    END IF;
    IF NOT v_should_guard THEN
        IF TG_OP='DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    SELECT EXISTS(
        SELECT 1 FROM finance_receipts receipt
        WHERE receipt.sales_order_id=v_order_id
          AND receipt.receipt_kind='CUSTOMER_PREPAYMENT'
          AND receipt.status=1 AND COALESCE(receipt.is_deleted,FALSE)=FALSE)
      OR EXISTS(
        SELECT 1 FROM customer_open_item_offsets offset_row
        WHERE offset_row.sales_order_id=v_order_id
          AND offset_row.status='APPLIED')
      INTO v_blocking;
    IF v_blocking THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='sales order has bound or historically applied customer prepayment; refund, reverse or transfer finance facts first',
            CONSTRAINT='sales_orders_customer_prepayment_cancel_guard';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$v386$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_sales_order_customer_prepayment_cancel
    BEFORE UPDATE OR DELETE ON sales_orders
    FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_order_customer_prepayment_cancel();
