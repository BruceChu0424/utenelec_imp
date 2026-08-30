-- V427: ordered whole-report production participants.
--
-- This is an operational snapshot for one production daily report. It does
-- not allocate quantity to a person, prove line-level contribution, or create
-- any piece-rate/payroll fact. production_daily_reports.worker_id remains the
-- first responsible employee for legacy clients and list/report compatibility.

CREATE TABLE production_daily_report_workers (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id   UUID NOT NULL
        REFERENCES production_daily_reports(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL
        REFERENCES employees(id) ON DELETE RESTRICT,
    sort_order  INTEGER NOT NULL,
    CONSTRAINT production_daily_report_worker_sort_chk
        CHECK (sort_order BETWEEN 1 AND 100),
    CONSTRAINT uq_production_daily_report_worker_employee
        UNIQUE (report_id, employee_id),
    CONSTRAINT uq_production_daily_report_worker_sort
        UNIQUE (report_id, sort_order)
);

CREATE INDEX idx_production_daily_report_worker_employee
    ON production_daily_report_workers(employee_id, report_id);

INSERT INTO production_daily_report_workers(
    report_id, employee_id, sort_order)
SELECT report.id, report.worker_id, 1
FROM production_daily_reports report
JOIN employees employee ON employee.id = report.worker_id
WHERE report.worker_id IS NOT NULL
ON CONFLICT (report_id, employee_id) DO NOTHING;

CREATE TRIGGER trg_audit_production_daily_report_workers
    AFTER INSERT OR UPDATE OR DELETE
    ON production_daily_report_workers
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE production_daily_report_workers IS
    'Ordered whole-report production participants; not line contribution or piece-rate/payroll evidence';
COMMENT ON COLUMN production_daily_report_workers.sort_order IS
    'Stable display order; position 1 mirrors production_daily_reports.worker_id';
