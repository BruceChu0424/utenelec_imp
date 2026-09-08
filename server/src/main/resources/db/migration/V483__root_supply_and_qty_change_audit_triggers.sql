-- V483: forward audit repair for the V478 root-supply output ledger and the
-- V482 sales-order quantity-change fact ledger. Both creating migrations stay
-- immutable; this migration touches only these two reviewed business tables.
DROP TRIGGER IF EXISTS trg_audit_preplan_root_output_events
    ON preplan_root_output_events;

CREATE TRIGGER trg_audit_preplan_root_output_events
AFTER INSERT OR UPDATE OR DELETE ON preplan_root_output_events
FOR EACH ROW EXECUTE FUNCTION fn_audit();

DROP TRIGGER IF EXISTS trg_audit_sales_order_qty_change_logs
    ON sales_order_qty_change_logs;

CREATE TRIGGER trg_audit_sales_order_qty_change_logs
AFTER INSERT OR UPDATE OR DELETE ON sales_order_qty_change_logs
FOR EACH ROW EXECUTE FUNCTION fn_audit();
