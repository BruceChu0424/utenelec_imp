-- Existing approved advances retain their historical order reference when the
-- order closes. Reversing that money fact must not require reopening the order.
-- New registrations, changed identities and a new approval still require an
-- active matching order. No historical money or allocation is rewritten.
CREATE OR REPLACE FUNCTION fn_guard_finance_receipt_order()
RETURNS TRIGGER AS $v499$
DECLARE
    v_client UUID; v_currency UUID; v_status SMALLINT; v_deleted BOOLEAN;
    v_stopped BOOLEAN; v_closed BOOLEAN;
BEGIN
    IF NEW.sales_order_id IS NULL THEN RETURN NEW; END IF;
    IF TG_OP='UPDATE' THEN
        IF NEW.sales_order_id IS NOT DISTINCT FROM OLD.sales_order_id
           AND NEW.client_id IS NOT DISTINCT FROM OLD.client_id
           AND NEW.currency_id IS NOT DISTINCT FROM OLD.currency_id
           AND NEW.receipt_kind IS NOT DISTINCT FROM OLD.receipt_kind
           AND NOT (NEW.status=1 AND OLD.status IS DISTINCT FROM 1) THEN
            RETURN NEW;
        END IF;
    END IF;
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
$v499$ LANGUAGE plpgsql;

DROP TRIGGER trg_guard_finance_receipt_order ON finance_receipts;
CREATE TRIGGER trg_guard_finance_receipt_order
    BEFORE INSERT OR UPDATE OF sales_order_id,client_id,currency_id,receipt_kind,status
    ON finance_receipts FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_receipt_order();
