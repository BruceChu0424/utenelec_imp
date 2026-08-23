-- V384: an order-bound customer advance can only be registered while the
-- approved order is still active.  Closed/stopped orders must use formal AR receipt flows.
CREATE OR REPLACE FUNCTION fn_guard_finance_receipt_order()
RETURNS TRIGGER AS $v384$
DECLARE
    v_client UUID; v_currency UUID; v_status SMALLINT; v_deleted BOOLEAN;
    v_stopped BOOLEAN; v_closed BOOLEAN;
BEGIN
    IF NEW.sales_order_id IS NULL THEN RETURN NEW; END IF;
    SELECT client_id,currency_id,status,is_deleted,is_stopped,is_closed
      INTO v_client,v_currency,v_status,v_deleted,v_stopped,v_closed
    FROM sales_orders WHERE id=NEW.sales_order_id;
    IF v_client IS NULL OR COALESCE(v_deleted,FALSE) OR v_status<>1
       OR COALESCE(v_stopped,FALSE) OR COALESCE(v_closed,FALSE)
       OR v_client<>NEW.client_id OR v_currency IS DISTINCT FROM NEW.currency_id THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='bound customer prepayment requires an active approved, open sales order with the same client and currency',
            CONSTRAINT='finance_receipts_sales_order_identity_guard';
    END IF;
    RETURN NEW;
END;
$v384$ LANGUAGE plpgsql;
