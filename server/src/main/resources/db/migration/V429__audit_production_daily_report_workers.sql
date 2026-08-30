-- V429: forward audit repair for the V427 production daily-report participant table.
-- V427 remains immutable; this migration touches only the one reviewed business table.
DROP TRIGGER IF EXISTS trg_audit_production_daily_report_workers
    ON production_daily_report_workers;

CREATE TRIGGER trg_audit_production_daily_report_workers
AFTER INSERT OR UPDATE OR DELETE ON production_daily_report_workers
FOR EACH ROW EXECUTE FUNCTION fn_audit();
