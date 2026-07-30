-- V138: stable, bounded paging indexes for long-lived payroll and expense data.
--
-- Query shapes:
--   payroll slips: active + department subtree + optional period, ordered by
--                  payroll_year DESC, payroll_month DESC, employee_code, id
--   my claims:     applicant + optional status set/date range, ordered newest first
--   work queues:   department + status set/date range, ordered oldest first
--
-- Partial indexes keep terminal/inactive history from inflating hot work-queue indexes.

CREATE INDEX idx_payroll_slips_active_department_period
    ON payroll_slips (
        department_id_snapshot,
        payroll_year DESC,
        payroll_month DESC,
        employee_code_snapshot,
        id
    )
    INCLUDE (status, viewed_at, downloaded_at)
    WHERE active = TRUE;

CREATE INDEX idx_expense_claims_applicant_status_created
    ON expense_claims (
        applicant_id,
        status,
        created_at DESC,
        id DESC
    );

CREATE INDEX idx_expense_claims_queue_department_status_created
    ON expense_claims (
        applicant_department_id,
        status,
        created_at,
        id
    )
    WHERE status IN ('SUBMITTED', 'REVIEWING', 'APPROVED');
