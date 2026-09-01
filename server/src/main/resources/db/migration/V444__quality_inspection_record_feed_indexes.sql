-- V444: read-path indexes for the event-level IQC/FQC detection-record center.
--
-- The facts remain in their existing append-only ledgers.  This migration adds
-- only global newest-first feed indexes; it does not relabel historical rows or
-- create a second quality authority.

CREATE INDEX idx_procurement_inspection_events_record_feed
    ON procurement_inspection_events (occurred_at DESC, id DESC)
    INCLUDE (inspection_item_id, action, base_qty, actor_employee_id)
    WHERE action IN ('PASS', 'FAIL', 'RECEIPT_REVERSED');

CREATE INDEX idx_production_fqc_decision_events_record_feed
    ON production_fqc_decision_events (decided_at DESC, id DESC)
    INCLUDE (inspection_id, decision, pass_qty, fail_qty,
             disposition_code, decided_by_employee_id);

CREATE INDEX idx_production_fqc_cancellation_events_record_feed
    ON production_fqc_cancellation_events (created_at DESC, id DESC)
    INCLUDE (inspection_id, reason_code, created_by);

COMMENT ON INDEX idx_procurement_inspection_events_record_feed IS
    'Newest-first IQC PASS/FAIL/reversal evidence feed for the read-only quality record center';
COMMENT ON INDEX idx_production_fqc_decision_events_record_feed IS
    'Newest-first production FQC decision evidence feed for the read-only quality record center';
COMMENT ON INDEX idx_production_fqc_cancellation_events_record_feed IS
    'Newest-first production FQC cancellation evidence feed for the read-only quality record center';
