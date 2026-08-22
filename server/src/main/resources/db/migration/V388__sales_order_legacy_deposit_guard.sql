-- V388: sales_orders.deposit is a completed legacy migration snapshot.
-- New business rows store zero/null and no future writer may rewrite history.
CREATE OR REPLACE FUNCTION fn_guard_sales_order_legacy_deposit()
RETURNS TRIGGER AS $v388$
BEGIN
    IF TG_OP='INSERT' THEN
        IF COALESCE(NEW.deposit,0)<>0 THEN
            RAISE EXCEPTION USING ERRCODE='23514',
                MESSAGE='sales order deposit is a legacy snapshot; register customer advance in finance',
                CONSTRAINT='sales_orders_legacy_deposit_guard';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.deposit IS DISTINCT FROM OLD.deposit THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE='sales order legacy deposit snapshot is immutable',
            CONSTRAINT='sales_orders_legacy_deposit_guard';
    END IF;
    RETURN NEW;
END;
$v388$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_sales_order_legacy_deposit
    BEFORE INSERT OR UPDATE OF deposit ON sales_orders
    FOR EACH ROW EXECUTE FUNCTION fn_guard_sales_order_legacy_deposit();
